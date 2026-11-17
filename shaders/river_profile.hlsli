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
