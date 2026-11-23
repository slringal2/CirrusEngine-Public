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
    // Advect a world-space pattern with the weather's accumulated wind displacement.
    // Fixed wave axes keep distant grass in phase when the wind changes direction.
    float2 q = p - Wind.xy * 0.58;
    const float2 frontA = float2(0.87, 0.49);
    const float2 frontB = float2(-0.49, 0.87);
    float alignment = dot(direction, frontA);
    float envelope = sin(dot(q, float2(0.064, -0.041)));
    float sweep = sin(dot(q, frontA) * 0.28 + 1.4 * envelope);
    float crossSweep = sin(dot(q, frontB) * 0.39 - envelope);
    float crest = lerp(crossSweep, sweep, alignment * alignment);
    return saturate(0.45 + 0.36 * crest + 0.19 * envelope);
}

float3 meadowColor(float moisture)
{
    return lerp(float3(0.178, 0.151, 0.045), float3(0.049, 0.157, 0.039), moisture);
}

#endif
