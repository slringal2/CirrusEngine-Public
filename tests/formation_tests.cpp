#include "cloud_formations.hpp"
#include <iostream>
#include <sstream>
#include <string>

int main()
{
    using namespace cirrus;
    int failures = 0, checks = 0;
    auto check = [&](bool condition, const char *message)
    {
        ++checks;
        if (!condition)
        {
            ++failures;
            std::cerr << message << '\n';
        }
    };
    for (const auto &mode : formationModes)
    {
        auto set = formationPreset(mode.name);
        for (size_t i = 0; i < set.count; ++i)
            check(validFormation(set.items[i]), "Preset outside supported volume bounds");
    }
    std::istringstream valid("# layout\n tower -5600 7000 2800 1800 9400 1.05\n"
                             "vortex 6400 12000 7000 1800 4200 0.85 -2 1.6 # reverse\n");
    const auto parsed = readFormations(valid);
    check(parsed.count == 2, "Did not load both independent regions");
    check(parsed.items[0].x == -5600 && parsed.items[0].z == 7000,
          "World-space coordinates changed during parsing");
    check(parsed.items[0].base + parsed.items[0].height > 11000,
          "Tower cannot extend above the ordinary cloud layer");
    check(parsed.items[1].spin < -0.034f && parsed.items[1].spin > -0.036f,
          "Signed degrees/second did not convert to radians/second");
    for (const auto line : {"tower 1 2 3", "tower 0 0 0 1800 9000 1", "tower 0 0 3000 1800 9000 -1",
                            "tower 0 0 3000 1800 nan 1", "tower 0 0 3000 1800 9000 1 extra",
                            "unknown 0 0 3000 1800 9000 1", "vortex 0 0 7000 1800 4200 1 90 1.6",
                            "vortex 0 0 7000 1800 4200 1 2 0", "tower 0 0 3000 18000 16000 1"})
    {
        bool rejected = false;
        try
        {
            std::istringstream input(line);
            readFormations(input);
        }
        catch (const std::runtime_error &)
        {
            rejected = true;
        }
        check(rejected, "Invalid formation file was accepted");
    }
    std::string overflow;
    for (std::size_t i = 0; i <= maxCloudFormations; ++i)
        overflow += "tower 0 0 3000 1800 9000 1\n";
    bool rejected = false;
    try
    {
        std::istringstream input(overflow);
        readFormations(input);
    }
    catch (const std::runtime_error &)
    {
        rejected = true;
    }
    check(rejected, "More regions than the GPU constant array were accepted");
    std::cout << checks << " cloud formation checks; " << failures << " failures\n";
    return failures ? 1 : 0;
}
