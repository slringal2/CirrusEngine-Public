#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <limits>
#include <vector>
#include <array>
#ifndef CIRRUS_RIVER_PROFILE
#define CIRRUS_RIVER_PROFILE

// The terrain generator and the water shader measure the channel in the same metres.
#ifdef __cplusplus
#include <cmath>
namespace cirrus
{
using std::abs;
using std::cos;
using std::sin;
#define CIRRUS_RIVER_INLINE inline
#else
#define CIRRUS_RIVER_INLINE
#endif

static const float riverDatum = 123.4f;
static const float riverGrade = 0.0022f;
static const float riverExtent = 2640.0f;

CIRRUS_RIVER_INLINE float riverLevel(float z)
{
    return riverDatum - z * riverGrade;
}

CIRRUS_RIVER_INLINE float riverCenter(float z)
{
    return 49.0f - 25.0f * cos((z - 78.0f) * 0.0108f) + 14.0f * sin(z * 0.003f);
}

CIRRUS_RIVER_INLINE float riverHalfWidth(float z)
{
    return 14.5f + 3.2f * sin(z * 0.017f) + 1.8f * cos(z * 0.042f);
}

CIRRUS_RIVER_INLINE float riverBankDistance(float x, float z)
{
    return abs(x - riverCenter(z)) - riverHalfWidth(z);
}

#undef CIRRUS_RIVER_INLINE
#ifdef __cplusplus
}
#endif
#endif

using namespace cirrus;
namespace old {
struct XMFLOAT2 {float x, y;};
constexpr XMFLOAT2 ridgeMin{-3690, 1000}, ridgeMax{5610, 10300};
constexpr int ridgeSize = 513;
constexpr int cells = 32;
constexpr int baseTile = 128;
struct World {
  std::vector<uint16_t> ridgeHeights_;
  float valleyRidges(float x,float z) const;
  float terrainHeight(float x,float z) const;
  float ground(float x,float z) const;
};
float random01(int x, int z, uint32_t seed = 0)
{
    uint32_t n = uint32_t(x) * 0x9e3779b9u ^ uint32_t(z) * 0x85ebca6bu ^ seed * 0xc2b2ae35u;
    n ^= n >> 16;
    n *= 0x7feb352du;
    n ^= n >> 15;
    n *= 0x846ca68bu;
    return static_cast<float>((n ^ (n >> 16)) >> 8) / 16777216.0f;
}

float smooth(float a, float b, float x)
{
    float f = std::clamp((x - a) / (b - a), 0.0f, 1.0f);
    return f * f * (3 - 2 * f);
}

float noise(float x, float z, uint32_t seed)
{
    int ix = static_cast<int>(std::floor(x)), iz = static_cast<int>(std::floor(z));
    float u = smooth(0, 1, x - ix), v = smooth(0, 1, z - iz);
    return std::lerp(std::lerp(random01(ix, iz, seed), random01(ix + 1, iz, seed), u),
                     std::lerp(random01(ix, iz + 1, seed), random01(ix + 1, iz + 1, seed), u), v);
}

float interpolateTerrain(float a, float b, float c, float d, float u, float v)
{
    // The diagonal is shared with the rendered terrain indices.
    return u + v <= 1 ? a + (b - a) * u + (c - a) * v : d + (c - d) * (1 - u) + (b - d) * (1 - v);
}

float World::valleyRidges(float x, float z) const
{
    float u = (x - ridgeMin.x) / (ridgeMax.x - ridgeMin.x);
    float v = (z - ridgeMin.y) / (ridgeMax.y - ridgeMin.y);
    if (u <= 0 || v <= 0 || u >= 1 || v >= 1)
        return 0;

    float sx = u * (ridgeSize - 1), sz = v * (ridgeSize - 1);
    int ix = std::min(static_cast<int>(sx), ridgeSize - 2);
    int iz = std::min(static_cast<int>(sz), ridgeSize - 2);
    size_t i = iz * ridgeSize + ix;
    float front = std::lerp(static_cast<float>(ridgeHeights_[i]),
                            static_cast<float>(ridgeHeights_[i + 1]), sx - ix);
    float back = std::lerp(static_cast<float>(ridgeHeights_[i + ridgeSize]),
                           static_cast<float>(ridgeHeights_[i + ridgeSize + 1]), sx - ix);
    float weight = smooth(0, 0.12f, u) * (1 - smooth(0.87f, 1, u)) * smooth(0, 0.14f, v)
                   * (1 - smooth(0.86f, 1, v));
    return std::lerp(front, back, sz - iz) * weight / 24;
}

float World::terrainHeight(float x, float z) const
{
    float region = noise(x / 5900, z / 5900, 12);
    float rolling = 32 * noise(x / 400, z / 400, 11) + 90 * noise(x / 1600, z / 1600, 23);
    float mountainWeight = smooth(0.44f, 0.73f, region);
    float ridge = 1 - std::abs(2 * noise(x / 2600, z / 2600, 8) - 1);
    float mountains = mountainWeight
                      * (260 * ridge * ridge + 680 * noise(x / 3400, z / 3400, 10)
                         + 125 * noise(x / 750, z / 750, 17));
    float soil = 2.0f * noise(x / 48, z / 48, 21);
    soil += 1.1f * (noise(x / 19, z / 27, 76) - 0.5f);
    float upland = 105 + rolling + mountains + soil + valleyRidges(x, z);
    if (std::abs(z) >= riverExtent || x < -116 || x > 222)
        return upland;

    float sandbars = noise(x / 8, z / 16, 71);
    float bank = riverBankDistance(x, z) + (sandbars - 0.5f) * 4.4f;
    float depth = 1.45f + 1.95f * noise(x / 28, z / 78, 72);
    float wetBed = riverLevel(z) - depth * smooth(0, 13, -bank);
    float dryBank = std::max(bank, 0.0f) * (0.27f + 0.18f * noise(x / 37, z / 53, 73));
    dryBank += (noise(x / 17, z / 27, 74) - 0.43f) * 1.9f * smooth(0.5f, 17.0f, bank);
    float strength = (1 - smooth(8, 88, bank)) * (1 - smooth(2180, riverExtent, std::abs(z)));
    return std::lerp(upland, wetBed + dryBank, strength);
}

float World::ground(float x, float z) const
{
    constexpr float step = baseTile / cells;
    const float x0 = std::floor(x / step) * step, z0 = std::floor(z / step) * step;
    return interpolateTerrain(terrainHeight(x0, z0), terrainHeight(x0 + step, z0),
                              terrainHeight(x0, z0 + step), terrainHeight(x0 + step, z0 + step),
                              (x - x0) / step, (z - z0) / step);
}
}
namespace changed {
struct XMFLOAT2 {float x, y;};
constexpr XMFLOAT2 ridgeMin{-3690, 1000}, ridgeMax{5610, 10300};
constexpr int ridgeSize = 513;
constexpr int cells = 32;
constexpr int baseTile = 128;
struct World {
  std::vector<uint16_t> ridgeHeights_;
  float valleyRidges(float x,float z) const;
  float terrainHeight(float x,float z) const;
  float ground(float x,float z) const;
};
float random01(int x, int z, uint32_t seed = 0)
{
    uint32_t n = uint32_t(x) * 0x9e3779b9u ^ uint32_t(z) * 0x85ebca6bu ^ seed * 0xc2b2ae35u;
    n ^= n >> 16;
    n *= 0x7feb352du;
    n ^= n >> 15;
    n *= 0x846ca68bu;
    return static_cast<float>((n ^ (n >> 16)) >> 8) / 16777216.0f;
}

float smooth(float a, float b, float x)
{
    float f = std::clamp((x - a) / (b - a), 0.0f, 1.0f);
    return f * f * (3 - 2 * f);
}

float noise(float x, float z, uint32_t seed)
{
    int ix = static_cast<int>(std::floor(x)), iz = static_cast<int>(std::floor(z));
    float u = smooth(0, 1, x - ix), v = smooth(0, 1, z - iz);
    return std::lerp(std::lerp(random01(ix, iz, seed), random01(ix + 1, iz, seed), u),
                     std::lerp(random01(ix, iz + 1, seed), random01(ix + 1, iz + 1, seed), u), v);
}

float interpolateTerrain(float a, float b, float c, float d, float u, float v)
{
    // The diagonal is shared with the rendered terrain indices.
    return u + v <= 1 ? a + (b - a) * u + (c - a) * v : d + (c - d) * (1 - u) + (b - d) * (1 - v);
}

template <typename Sample>
float sampleRidgeField(const std::vector<Sample> &field, float x, float z)
{
    float u = (x - ridgeMin.x) / (ridgeMax.x - ridgeMin.x);
    float v = (z - ridgeMin.y) / (ridgeMax.y - ridgeMin.y);
    if (u <= 0 || v <= 0 || u >= 1 || v >= 1)
        return 0;

    float sx = u * (ridgeSize - 1), sz = v * (ridgeSize - 1);
    int ix = std::min(static_cast<int>(sx), ridgeSize - 2);
    int iz = std::min(static_cast<int>(sz), ridgeSize - 2);
    size_t i = iz * ridgeSize + ix;
    float front = std::lerp(static_cast<float>(field[i]), static_cast<float>(field[i + 1]), sx - ix);
    float back = std::lerp(static_cast<float>(field[i + ridgeSize]),
                           static_cast<float>(field[i + ridgeSize + 1]), sx - ix);
    float weight = smooth(0, 0.12f, u) * (1 - smooth(0.87f, 1, u)) * smooth(0, 0.14f, v)
                   * (1 - smooth(0.86f, 1, v));
    return std::lerp(front, back, sz - iz) * weight;
}

float World::valleyRidges(float x, float z) const
{
    return sampleRidgeField(ridgeHeights_, x, z) / 24;
}

float World::terrainHeight(float x, float z) const
{
    float region = noise(x / 5900, z / 5900, 12);
    float rolling = 32 * noise(x / 400, z / 400, 11) + 90 * noise(x / 1600, z / 1600, 23);
    float mountainWeight = smooth(0.44f, 0.73f, region);
    float ridge = 1 - std::abs(2 * noise(x / 2600, z / 2600, 8) - 1);
    float mountains = mountainWeight
                      * (260 * ridge * ridge + 680 * noise(x / 3400, z / 3400, 10)
                         + 125 * noise(x / 750, z / 750, 17));
    float soil = 2.0f * noise(x / 48, z / 48, 21);
    soil += 1.1f * (noise(x / 19, z / 27, 76) - 0.5f);
    float upland = 105 + rolling + mountains + soil + valleyRidges(x, z);
    if (std::abs(z) >= riverExtent || x < -116 || x > 222)
        return upland;

    float sandbars = noise(x / 8, z / 16, 71);
    float bank = riverBankDistance(x, z) + (sandbars - 0.5f) * 4.4f;
    float depth = 1.45f + 1.95f * noise(x / 28, z / 78, 72);
    float wetBed = riverLevel(z) - depth * smooth(0, 13, -bank);
    float dryBank = std::max(bank, 0.0f) * (0.27f + 0.18f * noise(x / 37, z / 53, 73));
    dryBank += (noise(x / 17, z / 27, 74) - 0.43f) * 1.9f * smooth(0.5f, 17.0f, bank);
    float strength = (1 - smooth(8, 88, bank)) * (1 - smooth(2180, riverExtent, std::abs(z)));
    return std::lerp(upland, wetBed + dryBank, strength);
}

float World::ground(float x, float z) const
{
    constexpr float step = baseTile / cells;
    const float x0 = std::floor(x / step) * step, z0 = std::floor(z / step) * step;
    return interpolateTerrain(terrainHeight(x0, z0), terrainHeight(x0 + step, z0),
                              terrainHeight(x0, z0 + step), terrainHeight(x0 + step, z0 + step),
                              (x - x0) / step, (z - z0) / step);
}
}

struct Probe {
    int mismatches=0, nonfinite=0, positive=0;
    float maxAbs=0;
    void check(float old, float current) {
        mismatches+=std::bit_cast<uint32_t>(old)!=std::bit_cast<uint32_t>(current);
        nonfinite+=!std::isfinite(old)||!std::isfinite(current);
        positive+=old>0;
        maxAbs=std::max(maxAbs,std::abs(old-current));
    }
};
struct Group {
    int count=0;
    Probe ridge, terrain, ground;
};
int main(int argc,char** argv) {
    if(argc!=2)return 2;
    old::World a; changed::World b;
    a.ridgeHeights_.resize(513*513);
    std::ifstream input(argv[1],std::ios::binary);
    if(!input.read(reinterpret_cast<char*>(a.ridgeHeights_.data()),513*513*2))return 2;
    b.ridgeHeights_=a.ridgeHeights_;
    std::array<Group,5> groups;
    auto check=[&](int which,float x,float z) {
        auto& g=groups[which]; g.count++;
        g.ridge.check(a.valleyRidges(x,z),b.valleyRidges(x,z));
        g.terrain.check(a.terrainHeight(x,z),b.terrainHeight(x,z));
        g.ground.check(a.ground(x,z),b.ground(x,z));
    };
    constexpr float spacing=9300.0f/512;
    for(int row=0;row<=512;row++)for(int col=0;col<=512;col++){
        const float x=-3690+col*spacing,z=1000+row*spacing;
        check(0,x,z);
        if(row<512 && col<512){
            check(1,x+0.5f*spacing,z+0.5f*spacing);
            check(2,x+0.25f*spacing,z+0.625f*spacing);
            check(2,x+0.75f*spacing,z+0.125f*spacing);
        }
    }
    // Four borders, the four fade thresholds, and samples immediately on either side.
    for(int n=0;n<=512;n++)for(int w=-1;w<=1;w++){
        float x=-3690+n*spacing,z=1000+n*spacing;
        auto nudge=[&](float v){
            return w==0?v:std::nextafter(v,w<0?-std::numeric_limits<float>::infinity():std::numeric_limits<float>::infinity()); };
        for(float u: {0.f,0.12f,0.87f,1.f})check(3,nudge(-3690+9300*u),z);
        for(float v: {0.f,0.14f,0.86f,1.f})check(3,x,nudge(1000+9300*v));
    }
    for(int z=-2700;z<=2700;z+=5)
        for(int lateral=-100;lateral<=100;lateral+=2)
            check(4,riverCenter(static_cast<float>(z))+lateral,static_cast<float>(z));
    const char* titles[]={"all_grid_nodes","all_cell_centers","two_off_center_samples_per_cell","edges_and_fade_thresholds_adjacent_floats","channel_transects"};
    std::cout << "{\n";int failures=0;
    for(size_t i=0;i<groups.size();i++) {
       const auto& g=groups[i];
       std::cout << "  \""<<titles[i]<<"\": {\"points\":"<<g.count;
       auto output=[&](const char* key,const Probe& p) {
           std::cout << ",\""<<key<<"\":{\"different_float_bits\":"<<p.mismatches<<",\"nonfinite\":"<<p.nonfinite<<",\"max_abs_m\":"<<p.maxAbs<<",\"positive_old\":"<<p.positive<<"}";
           failures+=p.mismatches+p.nonfinite;
       };
       output("ridge",g.ridge);output("terrain",g.terrain);output("ground",g.ground);
       std::cout << "}"<<(i+1<groups.size()?",":"")<<"\n";
    }
    std::cout << "}\n";return failures?1:0;
}
