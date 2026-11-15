#include "weather.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace cirrus
{
namespace
{
WeatherState blend(const WeatherState &a, const WeatherState &b, float t)
{
    auto f = [t](float x, float y)
    {
        return x + (y - x) * t;
    };
    return {f(a.coverage, b.coverage),   f(a.density, b.density),
            f(a.cloudBase, b.cloudBase), f(a.cloudThickness, b.cloudThickness),
            f(a.cloudType, b.cloudType), f(a.precipitation, b.precipitation),
            f(a.humidity, b.humidity),   f(a.fogDensity, b.fogDensity),
            f(a.windX, b.windX),         f(a.windZ, b.windZ)};
}
}

WeatherState preset(WeatherKind kind)
{
    switch (kind)
    {
    case WeatherKind::Clear:
        return {0.15f, 0.95f, 2400, 2200, 0.95f, 0, 0.22f, 0.000006f, 9, 4};
    case WeatherKind::PartlyCloudy:
        return {0.28f, 1.12f, 2100, 3000, 0.95f, 0, 0.42f, 0.000012f, 13, 6};
    case WeatherKind::Overcast:
        return {0.86f, 0.85f, 1400, 2700, 0.20f, 0, 0.72f, 0.000032f, 16, 8};
    case WeatherKind::Rain:
        return {0.93f, 1.05f, 1150, 3900, 0.50f, 0.65f, 0.90f, 0.000062f, 21, 11};
    case WeatherKind::Storm:
        return {0.98f, 1.45f, 1000, 5900, 1.0f, 1.0f, 1.0f, 0.000095f, 34, 17};
    default:
        throw std::invalid_argument("Invalid weather preset");
    }
}

std::string_view weatherName(WeatherKind kind)
{
    constexpr std::array names{"Clear", "Partly cloudy", "Overcast", "Rain", "Storm"};
    const auto i = static_cast<size_t>(kind);
    if (i >= names.size())
        throw std::invalid_argument("Invalid weather preset");
    return names[i];
}

WeatherKind parseWeather(std::string_view name)
{
    if (name == "clear")
        return WeatherKind::Clear;
    if (name == "partly")
        return WeatherKind::PartlyCloudy;
    if (name == "overcast")
        return WeatherKind::Overcast;
    if (name == "rain")
        return WeatherKind::Rain;
    if (name == "storm")
        return WeatherKind::Storm;
    throw std::invalid_argument("Weather must be clear, partly, overcast, rain or storm");
}

bool valid(const WeatherState &s)
{
    const std::array values{s.coverage,  s.density,       s.cloudBase, s.cloudThickness,
                            s.cloudType, s.precipitation, s.humidity,  s.fogDensity,
                            s.windX,     s.windZ};
    for (float v : values)
        if (!std::isfinite(v))
            return false;
    return s.coverage >= 0 && s.coverage <= 1 && s.density >= 0 && s.cloudBase >= 100
           && s.cloudThickness >= 100 && s.cloudType >= 0 && s.cloudType <= 1
           && s.precipitation >= 0 && s.precipitation <= 1 && s.humidity >= 0 && s.humidity <= 1
           && s.fogDensity >= 0;
}

WeatherSystem::WeatherSystem(WeatherKind kind, uint32_t seed)
    : current_(preset(kind)), start_(current_), target_(current_), targetKind_(kind), seed_(seed)
{
    wetness_ = current_.precipitation;
}

void WeatherSystem::transitionTo(WeatherKind kind, double seconds)
{
    beginTransition(kind, seconds);
    demo_ = false;
}

void WeatherSystem::beginTransition(WeatherKind kind, double seconds)
{
    if (!std::isfinite(seconds) || seconds < 0)
        throw std::invalid_argument("Invalid transition duration");
    const WeatherState next = preset(kind);
    // 遷移の途中でも、その時点の状態から次の天候へつなぐ。
    start_ = current_;
    target_ = next;
    targetKind_ = kind;
    elapsed_ = 0;
    duration_ = seconds;
    if (duration_ == 0)
        current_ = target_;
}

void WeatherSystem::setImmediate(WeatherKind kind)
{
    transitionTo(kind, 0.0);
}

void WeatherSystem::setDemo(bool enabled)
{
    demo_ = enabled;
    if (!enabled)
        return;
    automatic_ = false;
    demoElapsed_ = 0;
    demoStep_ = 0;
    beginTransition(WeatherKind::Clear, 4.0);
}

void WeatherSystem::updateDemo(double dt)
{
    struct Cue
    {
        double time;
        WeatherKind kind;
        double transition;
    };

    constexpr std::array cues{Cue{4, WeatherKind::Overcast, 8}, Cue{14, WeatherKind::Rain, 6},
                              Cue{24, WeatherKind::Storm, 6}, Cue{36, WeatherKind::Rain, 4},
                              Cue{40, WeatherKind::Clear, 8}};
    demoElapsed_ += dt;
    if (demoElapsed_ >= demoDuration - 1e-8)
    {
        demoElapsed_ = std::max(0.0, demoElapsed_ - demoDuration);
        demoStep_ = 0;
    }
    if (demoStep_ < cues.size() && demoElapsed_ + 1e-8 >= cues[demoStep_].time)
    {
        const auto &cue = cues[demoStep_++];
        beginTransition(cue.kind, cue.transition);
    }
}

void WeatherSystem::triggerLightning()
{
    flashTime_ = time_;
    flashSeed_ = random();
    ++flashCount_;
    nextFlash_ = time_ + 4.5 + (random() % 450) / 100.0;
}

double WeatherSystem::transitionProgress() const
{
    return duration_ == 0 ? 1.0 : std::clamp(elapsed_ / duration_, 0.0, 1.0);
}

uint32_t WeatherSystem::random()
{
    seed_ = seed_ * 1664525u + 1013904223u;
    return seed_;
}

void WeatherSystem::update(double seconds)
{
    if (!std::isfinite(seconds) || seconds < 0)
        throw std::invalid_argument("Invalid weather delta time");
    // 最大1/60秒ずつ進める。フレーム時間が長い場合も風の積分精度を保つ。
    while (seconds > 1e-9)
    {
        const double dt = std::min(seconds, 1.0 / 60.0);
        const float oldX = current_.windX, oldZ = current_.windZ;
        elapsed_ += dt;
        double t = transitionProgress();
        // smoothstepで開始・終了時の変化を緩やかにする。
        t = t * t * (3.0 - 2.0 * t);
        current_ = blend(start_, target_, static_cast<float>(t));

        // 前後の風速の平均×dtで移動量を積分する（台形則）。
        // 現在の風速×総時間にすると、天候変更で雲の座標が飛んでしまう。
        wind_.x += (oldX + current_.windX) * 0.5 * dt;
        wind_.z += (oldZ + current_.windZ) * 0.5 * dt;
        time_ += dt;
        const float wetTarget = std::clamp(current_.precipitation * 1.4f, 0.0f, 1.0f);
        const double wetTime = wetTarget > wetness_ ? 6.0 : 65.0;
        wetness_ += (wetTarget - wetness_) * static_cast<float>(-std::expm1(-dt / wetTime));

        // 雷雨へ入ったら間もなく最初の雷、その後は4.5～9秒間隔。
        const bool storm = current_.precipitation > 0.85f;
        if (storm && !stormActive_)
            nextFlash_ = time_ + 0.9;
        stormActive_ = storm;
        if (storm && time_ + 1e-8 >= nextFlash_)
            triggerLightning();

        if (demo_)
            updateDemo(dt);
        // 自動天候は隣接プリセットへ遷移する。乱数はseedから再現できる。
        if (automatic_)
        {
            autoElapsed_ += dt;
            if (autoElapsed_ >= autoInterval_)
            {
                autoElapsed_ -= autoInterval_;
                const int i = static_cast<int>(targetKind_);
                const int step = (random() & 1) ? 1 : -1;
                beginTransition(static_cast<WeatherKind>(std::clamp(i + step, 0, 4)), 25.0);
                autoInterval_ = 65.0 + (random() % 6000) / 100.0;
            }
        }
        seconds -= dt;
    }
}

float WeatherSystem::lightning() const
{
    const double t = time_ - flashTime_;
    if (t < 0 || t > 0.65)
        return 0;
    const double primary = std::exp(-t * 24.0);
    const double secondary = t >= 0.11 ? 0.85 * std::exp(-(t - 0.11) * 36.0) : 0;
    const double third = t >= 0.23 ? 0.40 * std::exp(-(t - 0.23) * 38.0) : 0;
    return static_cast<float>(primary + secondary + third);
}
}
