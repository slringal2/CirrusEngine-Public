#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <istream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>

namespace cirrus
{
inline constexpr std::size_t maxCloudFormations = 24;

// GPUの CloudFormation.shape.z と対応する。
inline constexpr std::array<std::string_view, 7> formationKinds{
    "tower", "vortex", "lenticular", "anvil", "roll", "fluctus", "mammatus"};

struct FormationMode
{
    std::string_view name, label;
};

inline constexpr std::array<FormationMode, 10> formationModes{{
    {"none", "OFF"}, {"towers", "TOWERS"}, {"vortex", "VORTEX"}, {"mixed", "MIXED"},
    {"lenticular", "LENTICULAR"}, {"anvil", "ANVIL"}, {"roll", "ROLL"},
    {"fluctus", "FLUCTUS"}, {"mammatus", "MAMMATUS"}, {"showcase", "SHOWCASE"},
}};

// HLSL CloudFormationと同じ3個のfloat4。距離はm、spinはrad/s。
struct alignas(16) CloudFormation
{
    float x = 0, base = 1800, z = 0, radius = 2500;
    float height = 9000, density = 1, kind = 0, seed = 0;
    // レンズ雲などの追加形状では leanX にワールドXZ上の向き[rad]を入れる。
    float spin = 0, turns = 1.5f, leanX = 0.12f, leanZ = -0.04f;
};

static_assert(sizeof(CloudFormation) == 48);

struct FormationSet
{
    std::array<CloudFormation, maxCloudFormations> items{};
    std::size_t count = 0;
};

inline bool validFormation(const CloudFormation &f)
{
    const std::array values{f.x,    f.base, f.z,    f.radius, f.height, f.density,
                            f.kind, f.seed, f.spin, f.turns,  f.leanX,  f.leanZ};
    for (float value : values)
        if (!std::isfinite(value))
            return false;
    return std::abs(f.x) <= 150000 && std::abs(f.z) <= 150000 && f.base >= 100 && f.base <= 18000
           && f.radius >= 300 && f.radius <= 20000 && f.height >= 300 && f.height <= 16000
           && f.base + f.height <= 28000 && f.density >= 0 && f.density <= 3
           && f.kind >= 0 && f.kind < static_cast<float>(formationKinds.size())
           && std::floor(f.kind) == f.kind && std::abs(f.spin) <= 0.53f
           && f.turns >= 0.2f && f.turns <= 4;
}

inline FormationSet formationPreset(std::string_view name)
{
    if (std::none_of(formationModes.begin(), formationModes.end(),
                     [name](const FormationMode &mode) { return mode.name == name; }))
        throw std::runtime_error(
            "Unknown formation preset. Use none, towers, vortex, mixed, lenticular, "
            "anvil, roll, fluctus, mammatus or showcase.");

    const CloudFormation tower{-5600, 1800, 7000, 6200, 8600, 1.05f, 0, 17, 0, 1.5f, 0.13f, -0.03f};
    const CloudFormation vortex{6400, 900, 12000, 7000, 4400, 0.85f, 1, 31, 0.035f, 1.6f, 0, 0};
    constexpr std::array<CloudFormation, 5> special{{
        {-5750, 4700, 10500, 2800, 1280, 0.76f, 2, 47, 0, 1.5f, -0.36f, 0},
        {7800, 1900, 16600, 4600, 9100, 1.00f, 3, 59, 0, 1.5f, 0.25f, 0},
        {-2400, 2450, 15500, 4200, 1300, 0.84f, 4, 71, 0, 1.5f, 0.15f, 0},
        {2200, 6400, 21400, 4400, 1650, 0.79f, 5, 83, 0, 1.5f, -0.20f, 0},
        {-11500, 5400, 19700, 3600, 1950, 0.82f, 6, 97, 0, 1.5f, 0.55f, 0},
    }};
    FormationSet result;
    auto add = [&result](const CloudFormation &formation)
    {
        result.items[result.count++] = formation;
    };
    if (name == "towers" || name == "mixed")
        add(tower);
    if (name == "vortex" || name == "mixed")
        add(vortex);
    if (name == "showcase")
    {
        // 見晴らしの良い側に形を分散させ、同じ高度・同じ奥行きへの集中を避ける。
        add({-14000, 2100, 26000, 3500, 8100, 0.94f, 0, 17, 0, 1.5f, 0.13f, -0.03f});
        add({13700, 1250, 25600, 5000, 4000, 0.86f, 1, 31, 0.035f, 1.6f, 0, 0});
        for (const auto &formation : special)
            add(formation);
        add({-12200, 7500, 31000, 2300, 980, 0.71f, 2, 107, 0, 1.5f, 0.78f, 0});
        add({15400, 4800, 32700, 3500, 1520, 0.72f, 5, 113, 0, 1.5f, 0.50f, 0});
        add({2100, 10100, 27200, 3100, 1280, 0.64f, 6, 127, 0, 1.5f, 0.62f, 0});
        add({-6500, 3500, 36000, 5200, 1100, 0.70f, 4, 139, 0, 1.5f, -0.42f, 0});
        add({1800, 1800, 42000, 3900, 11200, 0.96f, 3, 151, 0, 1.5f, -0.32f, 0});
    }
    else
    {
        for (std::size_t i = 0; i < special.size(); ++i)
            if (name == formationKinds[i + 2])
                add(special[i]);
    }
    return result;
}

// 1行1領域。#以降はコメント。旧形式と新しい局所形状を同じファイルに混在させられる。
// tower x z radius base height density
// vortex x z radius base height density spin_deg_per_second turns
// lenticular|anvil|roll|fluctus|mammatus x z radius base height density [yaw_degrees]
inline FormationSet readFormations(std::istream &input)
{
    FormationSet result;
    std::string line;
    std::size_t lineNumber = 0;
    while (std::getline(input, line))
    {
        ++lineNumber;
        line = line.substr(0, line.find('#'));
        std::istringstream row(line);
        std::string kind;
        if (!(row >> kind))
            continue;
        auto fail = [&]()
        {
            throw std::runtime_error("Invalid cloud formation at line "
                                     + std::to_string(lineNumber));
        };
        CloudFormation f;
        if (!(row >> f.x >> f.z >> f.radius >> f.base >> f.height >> f.density))
            fail();
        f.seed = static_cast<float>(result.count * 23 + 17);
        const auto type = std::find(formationKinds.begin(), formationKinds.end(), std::string_view(kind));
        if (type == formationKinds.end())
            fail();
        f.kind = static_cast<float>(type - formationKinds.begin());
        if (f.kind == 1)
        {
            float degrees = 0;
            f.leanX = f.leanZ = 0;
            if (!(row >> degrees >> f.turns))
                fail();
            f.spin = degrees * 0.01745329252f;
        }
        else if (f.kind >= 2)
        {
            float yaw = 0;
            row >> std::ws;
            if (!row.eof() && (!(row >> yaw) || !std::isfinite(yaw) || std::abs(yaw) > 180))
                fail();
            f.leanX = yaw * 0.01745329252f;
            f.leanZ = 0;
        }
        std::string extra;
        if (row >> extra || !validFormation(f) || result.count >= maxCloudFormations)
            fail();
        result.items[result.count++] = f;
    }
    if (input.bad())
        throw std::runtime_error("Cannot read cloud formation file");
    return result;
}
}
