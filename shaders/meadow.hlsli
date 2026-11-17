#ifndef CIRRUS_MEADOW
#define CIRRUS_MEADOW

float meadowNoise(float2 p)
{
    float2 cell = floor(p);
    float2 f = frac(p);
    f = f * f * (3 - 2 * f);
    return lerp(lerp(hash12(cell), hash12(cell + float2(1, 0)), f.x),
                lerp(hash12(cell + float2(0, 1)), hash12(cell + 1), f.x), f.y);
}

float meadowMoisture(float2 p)
{
    float wide = meadowNoise(float2(p.x + p.y * 0.41, p.y - p.x * 0.31) * 0.018 + 31);
    float patch = meadowNoise(p * float2(0.102, 0.073) + 17);
    return smoothstep(0.13, 0.87, wide * 0.73 + patch * 0.27);
}

float meadowTrail(float2 p)
{
    float center = 4 * sin(p.y * 0.022) + 11 * sin(p.y * 0.008);
    float edge = (meadowNoise(p * float2(0.23, 0.51)) - 0.5) * 0.78;
    return 1 - smoothstep(0.76, 1.94, abs(p.x - center) + edge);
}

float meadowGust(float2 p, float2 direction)
{
    float2 along = float2(dot(p, direction), dot(p, float2(-direction.y, direction.x)));
    float sweep = sin(along.x * 0.32 + along.y * 0.059 - CameraTime.w * 1.80);
    float roll = sin(along.x * 0.69 - along.y * 0.21 - CameraTime.w * 2.6);
    return saturate(0.48 + 0.37 * sweep + 0.15 * roll);
}

float3 meadowColor(float moisture)
{
    return lerp(float3(0.123, 0.140, 0.044), float3(0.044, 0.122, 0.034), moisture);
}

#endif
