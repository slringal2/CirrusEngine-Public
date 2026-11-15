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
inline constexpr std::size_t maxCloudFormations = 8;

// HLSL CloudFormationと同じ3個のfloat4。距離はm、spinはrad/s。
struct alignas(16) CloudFormation
{
    float x = 0, base = 1800, z = 0, radius = 2500;
    float height = 9000, density = 1, kind = 0, seed = 0;
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
           && (f.kind == 0 || f.kind == 1) && std::abs(f.spin) <= 0.53f && f.turns >= 0.2f
           && f.turns <= 4;
}

inline FormationSet formationPreset(std::string_view name)
{
    FormationSet result;
    const CloudFormation tower{-5600, 1800, 7000, 6200, 8600, 1.05f, 0, 17, 0, 1.5f, 0.13f, -0.03f};
    const CloudFormation vortex{6400, 900, 12000, 7000, 4400, 0.85f, 1, 31, 0.035f, 1.6f, 0, 0};
    if (name == "towers" || name == "mixed")
        result.items[result.count++] = tower;
    if (name == "vortex" || name == "mixed")
        result.items[result.count++] = vortex;
    if (name != "none" && result.count == 0)
        throw std::runtime_error("Formations must be none, towers, vortex or mixed");
    return result;
}

// 1行1領域。#以降はコメント。省略・余分な列・非有限値は読み込み時に拒否する。
// tower x z radius base height density
// vortex x z radius base height density spin_deg_per_second turns
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
        if (kind == "vortex")
        {
            float degrees = 0;
            f.kind = 1;
            f.leanX = f.leanZ = 0;
            if (!(row >> degrees >> f.turns))
                fail();
            f.spin = degrees * 0.01745329252f;
        }
        else if (kind != "tower")
            fail();
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
