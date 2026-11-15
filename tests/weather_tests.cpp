#include "weather.hpp"
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>

int main()
{
    using namespace cirrus;
    int checks = 0, failures = 0;
    auto check = [&](bool ok, const char *label)
    {
        ++checks;
        if (!ok)
        {
            ++failures;
            std::cerr << label << '\n';
        }
    };
    for (int from = 0; from < 5; ++from)
        for (int to = 0; to < 5; ++to)
        {
            WeatherSystem w(static_cast<WeatherKind>(from));
            const auto start = w.state();
            w.transitionTo(static_cast<WeatherKind>(to), 2.0);
            check(w.state().coverage == start.coverage, "Transition starts continuously");
            for (int i = 0; i < 120; ++i)
            {
                w.update(1.0 / 60.0);
                check(valid(w.state()), "Blended parameters remain physical");
            }
            const auto end = preset(static_cast<WeatherKind>(to));
            check(std::abs(w.state().coverage - end.coverage) < 1e-5f,
                  "Transition reaches coverage target");
            check(std::abs(w.state().cloudBase - end.cloudBase) < 0.01f,
                  "Transition reaches altitude target");
            const auto interrupted = w.state();
            const auto drift = w.wind();
            w.transitionTo(WeatherKind::Storm, 8);
            check(w.state().coverage == interrupted.coverage,
                  "Interrupted transition has no parameter jump");
            check(w.wind().x == drift.x && w.wind().z == drift.z,
                  "Changing wind velocity does not teleport clouds");
            w.update(0);
            check(w.wind().x == drift.x, "Pause preserves wind phase");
        }
    WeatherSystem a(WeatherKind::Clear), b(WeatherKind::Clear);
    a.transitionTo(WeatherKind::Storm, 3);
    b.transitionTo(WeatherKind::Storm, 3);
    a.update(3);
    for (int i = 0; i < 180; ++i)
        b.update(1.0 / 60.0);
    check(std::abs(a.wind().x - b.wind().x) < 1e-6,
          "Wind integration is stable across frame rates");
    a.setAutomatic(true);
    b.setAutomatic(true);
    a.update(600);
    b.update(600);
    check(a.target() == b.target(), "Seeded automatic weather is reproducible");
    check(std::abs(a.state().coverage - b.state().coverage) < 1e-6,
          "Automatic interpolation is reproducible");
    check(valid(a.state()), "Long automatic run remains valid");

    WeatherSystem demo(WeatherKind::Clear);
    demo.setDemo(true);
    demo.update(12);
    check(demo.target() == WeatherKind::Overcast && demo.state().precipitation == 0,
          "Demo builds an overcast sky before rain starts");
    demo.update(8);
    check(std::abs(demo.state().precipitation - 0.65f) < 1e-5f,
          "Demo reaches steady rain at 20 seconds");
    check(demo.wetness() > 0.2f, "Rain gradually wets the ground");
    demo.update(10);
    check(demo.target() == WeatherKind::Storm && demo.state().precipitation > 0.999f,
          "Demo reaches a thunderstorm at 30 seconds");
    check(demo.lightningSerial() > 0, "Thunderstorm produces natural lightning");
    demo.update(18);
    check(demo.target() == WeatherKind::Clear && demo.state().precipitation < 1e-5f,
          "Demo returns to clear weather without rain");
    check(demo.wetness() > 0.3f, "Ground remains wet after the rain ends");
    check(demo.demoTime() < 1e-5, "Demo loops at 48 seconds");

    WeatherSystem movie(WeatherKind::Clear);
    movie.setDemo(true);
    for (int i = 0; i < 48 * 24; ++i)
        movie.update(1.0 / 24.0);
    check(std::abs(movie.wind().x - demo.wind().x) < 0.1,
          "Demo wind remains continuous with movie or large time steps");
    check(std::abs(movie.wetness() - demo.wetness()) < 0.001f,
          "Wetness does not depend on render frame rate");
    const auto beforeManual = movie.state();
    const auto beforeWind = movie.wind();
    movie.transitionTo(WeatherKind::Rain, 3);
    check(!movie.demo(), "Manual preset selection stops the demo");
    check(movie.state().coverage == beforeManual.coverage && movie.wind().x == beforeWind.x,
          "Interrupting the demo does not jump clouds or weather");
    movie.setDemo(true);
    movie.setAutomatic(true);
    check(!movie.demo() && movie.automatic(), "Automatic scheduler replaces demo mode");
    movie.setDemo(true);
    check(movie.demo() && !movie.automatic(), "Demo mode replaces automatic scheduler");

    WeatherSystem dry(WeatherKind::Clear), rain(WeatherKind::Rain);
    dry.update(30);
    rain.update(30);
    check(dry.lightningSerial() == 0 && rain.lightningSerial() == 0,
          "Clear weather and ordinary rain do not generate lightning");
    rain.triggerLightning();
    const auto strikeSeed = rain.lightningSeed();
    check(rain.lightning() >= 0.99f && rain.lightningAge() == 0,
          "Manual lightning triggers an immediate flash");
    rain.update(0.12);
    check(rain.lightning() > 0.5f && rain.lightningSeed() == strikeSeed,
          "Return stroke reuses the same bolt geometry");
    rain.update(0.6);
    check(rain.lightning() == 0, "Lightning expires instead of remaining bright");
    WeatherSystem stormA(WeatherKind::Storm, 42), stormB(WeatherKind::Storm, 42);
    stormA.update(24);
    stormB.update(24);
    check(stormA.lightningSerial() > 1 && stormA.lightningSerial() == stormB.lightningSerial()
              && stormA.lightningSeed() == stormB.lightningSeed(),
          "Natural lightning is repeated and reproducible from its seed");
    stormA.setImmediate(WeatherKind::Clear);
    stormA.update(1);
    check(stormA.wetness() > 0.9f, "Clearing weather does not instantly dry the ground");
    stormA.update(300);
    check(stormA.wetness() < 0.02f && stormA.wetness() >= 0,
          "Dry weather eventually dries the ground");
    for (double dt :
         {-1.0, std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::infinity()})
    {
        bool threw = false;
        try
        {
            a.update(dt);
        }
        catch (const std::invalid_argument &)
        {
            threw = true;
        }
        check(threw, "Reject invalid delta time");
    }
    bool threw = false;
    try
    {
        parseWeather("typo");
    }
    catch (const std::invalid_argument &)
    {
        threw = true;
    }
    check(threw, "Reject unknown preset");
    std::cout << "Weather checks: " << checks << ", failures: " << failures << '\n';
    return failures ? 1 : 0;
}
