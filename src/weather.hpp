#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace cirrus
{
enum class WeatherKind
{
    Clear,
    PartlyCloudy,
    Overcast,
    Rain,
    Storm,
    Count
};

struct WeatherState
{
    // coverage/cloudType/precipitation/humidity は0～1、density は密度倍率。
    float coverage = 0.48f;
    float density = 0.65f;
    // 雲底と厚みはm、風速はm/s、fogDensityは地表での消散係数[1/m]。
    float cloudBase = 1700.0f;
    float cloudThickness = 3400.0f;
    float cloudType = 0.7f;
    float precipitation = 0.0f;
    float humidity = 0.4f;
    float fogDensity = 0.000015f;
    float windX = 13.0f;
    float windZ = 6.0f;
};

struct WindOffset
{
    // 風速を積分した累積移動量[m]。天候切り替えで雲の位置を飛ばさない。
    double x = 0.0, z = 0.0;
};

WeatherState preset(WeatherKind kind);
std::string_view weatherName(WeatherKind kind);
WeatherKind parseWeather(std::string_view name);
bool valid(const WeatherState &state);

class WeatherSystem
{
  public:
    explicit WeatherSystem(WeatherKind kind = WeatherKind::PartlyCloudy, uint32_t seed = 1337);
    void transitionTo(WeatherKind kind, double seconds = 18.0);
    void setImmediate(WeatherKind kind);
    void update(double seconds);

    void setAutomatic(bool enabled)
    {
        automatic_ = enabled;
        autoElapsed_ = 0.0;
        if (enabled)
            demo_ = false;
    }

    void setDemo(bool enabled);

    bool demo() const
    {
        return demo_;
    }

    double demoTime() const
    {
        return demoElapsed_;
    }

    static constexpr double demoDuration = 48.0;

    // 雨が止んでも地面はすぐには乾かさない。雷は一つのイベント内で複数回光る。
    float wetness() const
    {
        return wetness_;
    }

    void triggerLightning();

    uint32_t lightningSerial() const
    {
        return flashCount_;
    }

    uint32_t lightningSeed() const
    {
        return flashSeed_;
    }

    double lightningAge() const
    {
        return time_ - flashTime_;
    }

    bool automatic() const
    {
        return automatic_;
    }

    const WeatherState &state() const
    {
        return current_;
    }

    WeatherKind target() const
    {
        return targetKind_;
    }

    WindOffset wind() const
    {
        return wind_;
    }

    double transitionProgress() const;

    double time() const
    {
        return time_;
    }

    float lightning() const;

  private:
    void beginTransition(WeatherKind kind, double seconds);
    void updateDemo(double dt);
    uint32_t random();
    WeatherState current_, start_, target_;
    WeatherKind targetKind_;
    WindOffset wind_;
    double elapsed_ = 0.0, duration_ = 0.0, time_ = 0.0;
    double autoElapsed_ = 0.0, autoInterval_ = 90.0;
    double flashTime_ = -100.0, nextFlash_ = 12.0;
    double demoElapsed_ = 0;
    std::size_t demoStep_ = 0;
    float wetness_ = 0;
    uint32_t flashCount_ = 0, flashSeed_ = 0;
    bool automatic_ = false, demo_ = false, stormActive_ = false;
    uint32_t seed_;
};
}
