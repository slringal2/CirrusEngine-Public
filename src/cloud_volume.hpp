#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace cirrus
{
// 巨視的な3D形状を起動時だけ焼く。最終密度・照明はGPU側で評価する。
// 128^3 R16_FLOAT = 4 MiB。全ての入道雲インスタンスで1枚を共有する。
inline constexpr int cloudControlSize = 128;
inline constexpr int cloudWarpSize = 64;
inline constexpr float cloudControlExtent = 1.4f;

struct CloudControlCell
{
    std::array<float, 3> center, radii;
    float weight;
};

inline std::vector<CloudControlCell> cloudControlCells()
{
    // 対流柱、側面の新しい上昇セル、成熟した頂部、風下へ広がる上部。
    std::vector<CloudControlCell> cells{{{0, 0.17f, 0}, {0.61f, 0.25f, 0.57f}, 4.0f},
                                        {{-0.10f, 0.36f, 0.01f}, {0.47f, 0.31f, 0.46f}, 3.8f},
                                        {{-0.18f, 0.55f, 0.05f}, {0.44f, 0.27f, 0.44f}, 4.2f},
                                        {{-0.22f, 0.74f, 0.04f}, {0.39f, 0.23f, 0.38f}, 4.8f},
                                        {{-0.29f, 0.85f, 0.03f}, {0.30f, 0.145f, 0.29f}, 4.4f},
                                        {{0.20f, 0.66f, -0.21f}, {0.41f, 0.23f, 0.36f}, 4.4f},
                                        {{0.43f, 0.49f, -0.11f}, {0.35f, 0.24f, 0.36f}, 3.4f},
                                        {{-0.43f, 0.44f, 0.24f}, {0.37f, 0.28f, 0.35f}, 3.5f},
                                        {{0.30f, 0.77f, 0.15f}, {0.77f, 0.13f, 0.60f}, 1.0f}};

    // 固定seedの階層的な突起。親の外周へ子・孫を付け、大中小のスケールを分離する。
    // 流体計算ではなく、再現可能な手続きモデリング用のアセット生成。
    std::uint32_t randomState = 0x43525553u;
    auto random = [&]()
    {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return static_cast<float>(randomState >> 8) / 16777216.0f;
    };
    for (int level = 0; level < 2; ++level)
    {
        const std::size_t begin = level == 0 ? 1 : 9;
        const std::size_t end = cells.size();
        const int children = level == 0 ? 9 : 3;
        for (std::size_t i = begin; i < end; ++i)
        {
            if (level == 0 && i == 8)
                continue; // 薄いanvilの縦横比を対流の子セルへ引き継がない。
            const auto parent = cells[i];
            for (int child = 0; child < children; ++child)
            {
                const float azimuth = random() * 6.28318530718f;
                const float y = -0.35f + random() * 1.25f;
                const float horizontal = std::sqrt(1 - y * y);
                const std::array direction{horizontal * std::cos(azimuth), y,
                                           horizontal * std::sin(azimuth)};
                const float scale = (level == 0 ? 0.30f : 0.35f) + random() * 0.13f;
                CloudControlCell cell{};
                for (int axis = 0; axis < 3; ++axis)
                {
                    // 高さ8600m / 半径6200mの標準配置でほぼ球になる比率。
                    cell.radii[axis] = parent.radii[0] * scale * (axis == 1 ? 0.72f : 1.0f);
                    cell.center[axis] =
                        parent.center[axis] + parent.radii[axis] * direction[axis] * 0.78f;
                }
                cell.center[1] =
                    std::clamp(cell.center[1], cell.radii[1] + 0.015f, 0.985f - cell.radii[1]);
                cell.weight = level == 0 ? 3.2f : 2.4f;
                cells.push_back(cell);
            }
        }
    }
    return cells;
}

inline std::vector<float> bakeCloudControlVolume(int size = cloudControlSize)
{
    if (size < 8 || size > 256)
        throw std::invalid_argument("Cloud control resolution must be in [8,256]");
    std::vector<float> field(static_cast<std::size_t>(size) * size * size, 0);
    const std::array origin{-cloudControlExtent, 0.0f, -cloudControlExtent};
    const std::array extent{cloudControlExtent * 2, 1.0f, cloudControlExtent * 2};
    for (const auto &cell : cloudControlCells())
    {
        std::array<int, 3> lower{}, upper{};
        for (int axis = 0; axis < 3; ++axis)
        {
            const float center = (cell.center[axis] - origin[axis]) / extent[axis] * size - 0.5f;
            const float radius = cell.radii[axis] / extent[axis] * size;
            lower[axis] = std::max(0, static_cast<int>(std::ceil(center - radius)));
            upper[axis] = std::min(size - 1, static_cast<int>(std::floor(center + radius)));
        }
        // 各セルの支持領域だけを焼く。全ボクセル×全セルの総当たりを避ける。
        for (int z = lower[2]; z <= upper[2]; ++z)
            for (int y = lower[1]; y <= upper[1]; ++y)
                for (int x = lower[0]; x <= upper[0]; ++x)
                {
                    const std::array voxel{x, y, z};
                    float distanceSquared = 0;
                    for (int axis = 0; axis < 3; ++axis)
                    {
                        const float position =
                            origin[axis] + (voxel[axis] + 0.5f) / size * extent[axis];
                        const float q = (position - cell.center[axis]) / cell.radii[axis];
                        distanceSquared += q * q;
                    }
                    const float k = std::max(0.0f, 1 - distanceSquared);
                    field[(static_cast<std::size_t>(z) * size + y) * size + x] +=
                        cell.weight * k * k * k;
                }
    }
    for (int z = 0; z < size; ++z)
        for (int y = 0; y < size; ++y)
            for (int x = 0; x < size; ++x)
            {
                auto &value = field[(static_cast<std::size_t>(z) * size + y) * size + x];
                value = value / std::sqrt(1 + value * value);
                // 外周のclampサンプルで壁が生じないよう、6面を厳密に空にする。
                if (x == 0 || y == 0 || z == 0 || x == size - 1 || y == size - 1 || z == size - 1)
                    value = 0;
            }
    return field;
}

// 周期的なC2補間のベクトル場。Worleyの距離場の尖りを座標変形へ持ち込まない。
inline std::vector<std::array<float, 4>> bakeCloudWarpVolume(int size = cloudWarpSize)
{
    if (size < 8 || size > 256)
        throw std::invalid_argument("Cloud warp resolution must be in [8,256]");
    auto hash = [](int x, int y, int z, int channel)
    {
        std::uint32_t n = static_cast<std::uint32_t>(x & 3) * 73856093u
                          ^ static_cast<std::uint32_t>(y & 3) * 19349663u
                          ^ static_cast<std::uint32_t>(z & 3) * 83492791u
                          ^ static_cast<std::uint32_t>(channel + 1) * 0x9e3779b9u;
        n = (n ^ (n >> 16)) * 0x7feb352du;
        n = (n ^ (n >> 15)) * 0x846ca68bu;
        n ^= n >> 16;
        return static_cast<float>(n >> 8) / 16777216.0f;
    };
    std::vector<std::array<float, 4>> field(static_cast<std::size_t>(size) * size * size);
    for (int z = 0; z < size; ++z)
        for (int y = 0; y < size; ++y)
            for (int x = 0; x < size; ++x)
            {
                const std::array voxel{x, y, z};
                std::array<int, 3> grid{};
                std::array<float, 3> blend{};
                for (int axis = 0; axis < 3; ++axis)
                {
                    const float p = (voxel[axis] + 0.5f) / size * 4;
                    grid[axis] = static_cast<int>(p);
                    const float f = p - grid[axis];
                    blend[axis] = f * f * f * (f * (f * 6 - 15) + 10);
                }
                auto &result = field[(static_cast<std::size_t>(z) * size + y) * size + x];
                for (int dz = 0; dz < 2; ++dz)
                    for (int dy = 0; dy < 2; ++dy)
                        for (int dx = 0; dx < 2; ++dx)
                        {
                            const float weight = (dx ? blend[0] : 1 - blend[0])
                                                 * (dy ? blend[1] : 1 - blend[1])
                                                 * (dz ? blend[2] : 1 - blend[2]);
                            for (int channel = 0; channel < 3; ++channel)
                                result[channel] +=
                                    weight
                                    * hash(grid[0] + dx, grid[1] + dy, grid[2] + dz, channel);
                        }
                result[3] = 1;
            }
    return field;
}
}
