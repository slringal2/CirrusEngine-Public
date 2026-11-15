#include "cloud_volume.hpp"
#include <iostream>
#include <queue>

int main()
{
    using namespace cirrus;
    int failures = 0;
    auto check = [&](bool passed, const char *message)
    {
        if (!passed)
        {
            ++failures;
            std::cerr << message << '\n';
        }
    };
    constexpr int size = 64;
    const auto field = bakeCloudControlVolume(size);
    check(field.size() == size * size * size, "3D upload size mismatch");
    check(field == bakeCloudControlVolume(size), "Control asset is not deterministic");
    bool finite = true, emptyBorder = true, highCloud = false;
    std::size_t occupied = 0;
    for (int z = 0; z < size; ++z)
        for (int y = 0; y < size; ++y)
            for (int x = 0; x < size; ++x)
            {
                const float v = field[(z * size + y) * size + x];
                finite &= std::isfinite(v) && v >= 0 && v <= 1;
                if (x == 0 || y == 0 || z == 0 || x == size - 1 || y == size - 1 || z == size - 1)
                    emptyBorder &= v == 0;
                occupied += v > 0.08f;
                highCloud |= y > size * 0.9f && v > 0.08f;
            }
    check(finite, "Control texture contains invalid normalized values");
    check(emptyBorder, "Clamp sampling can extrude a nonempty boundary into a wall");
    check(occupied > 1000 && highCloud, "Volume lost the tower or its upper cloud heads");

    // 小さなセル群が途切れた島ばかりになっていないか、3Dの接続を検査する。
    std::vector<bool> visited(field.size());
    std::size_t largest = 0;
    const std::array offsets{-1, 1, -size, size, -size * size, size * size};
    for (std::size_t i = 0; i < field.size(); ++i)
    {
        if (visited[i] || field[i] <= 0.08f)
            continue;
        std::queue<std::size_t> queue;
        queue.push(i);
        visited[i] = true;
        std::size_t connected = 0;
        while (!queue.empty())
        {
            const auto current = queue.front();
            queue.pop();
            ++connected;
            for (int offset : offsets)
            {
                const auto next = static_cast<std::ptrdiff_t>(current) + offset;
                if (next < 0 || next >= static_cast<std::ptrdiff_t>(field.size()))
                    continue;
                // 6面は空なので、行末から次行への誤接続は発生しない。
                if (!visited[next] && field[next] > 0.08f)
                {
                    visited[next] = true;
                    queue.push(static_cast<std::size_t>(next));
                }
            }
        }
        largest = std::max(largest, connected);
    }
    check(largest >= occupied * 0.97, "The cloud asset fragmented into disconnected pieces");
    const auto warp = bakeCloudWarpVolume();
    bool validWarp = true, smoothSeams = true;
    for (int z = 0; z < cloudWarpSize; ++z)
        for (int y = 0; y < cloudWarpSize; ++y)
            for (int x = 0; x < cloudWarpSize; ++x)
            {
                const auto index = (z * cloudWarpSize + y) * cloudWarpSize + x;
                for (int c = 0; c < 3; ++c)
                {
                    validWarp &=
                        std::isfinite(warp[index][c]) && warp[index][c] >= 0 && warp[index][c] <= 1;
                    if (x == 0)
                        smoothSeams &=
                            std::abs(warp[index][c] - warp[index + cloudWarpSize - 1][c]) < 0.015f;
                    if (y == 0)
                        smoothSeams &=
                            std::abs(warp[index][c]
                                     - warp[index + (cloudWarpSize - 1) * cloudWarpSize][c])
                            < 0.015f;
                    if (z == 0)
                        smoothSeams &=
                            std::abs(
                                warp[index][c]
                                - warp[index + (cloudWarpSize - 1) * cloudWarpSize * cloudWarpSize]
                                      [c])
                            < 0.015f;
                }
            }
    check(validWarp && smoothSeams, "Warp vector field is invalid or not tileable");
    for (int invalid : {7, 257})
    {
        bool rejected = false;
        try
        {
            bakeCloudControlVolume(invalid);
        }
        catch (const std::invalid_argument &)
        {
            rejected = true;
        }
        check(rejected, "Invalid voxel dimensions accepted");
    }
    std::cout << "3D cloud asset: " << occupied << " occupied voxels, largest component " << largest
              << ", " << failures << " failures\n";
    return failures ? 1 : 0;
}
