#include "common.hlsli"
#include "geometry.hlsli"
#include "meadow.hlsli"

cbuffer GrassLod : register(b4)
{
    float4 GrassMap;   // origin XZ, sample spacing, sample count
    int4 GrassGrid;    // first XZ cell, grid width
    float4 GrassFade;  // fade-in start/end and fade-out start/end, in metres
    float GrassSpacing;
    uint GrassRows;
    uint GrassLodIndex;
};

struct GrassSite
{
    float3 root;
    uint seed;
    float2 grade;
    float moisture;
    float bank;
};

Texture2D<float> GrassHeight : register(t42);
StructuredBuffer<GrassSite> GrassSites : register(t43);
Texture2D<float4> BladeGrain : register(t44);
AppendStructuredBuffer<GrassSite> SelectedGrass : register(u0);

uint grassHash(uint v)
{
    v ^= v >> 16;
    v *= 0x7feb352du;
    v ^= v >> 15;
    v *= 0x846ca68bu;
    return v ^ (v >> 16);
}

float grassRandom(uint v)
{
    return (grassHash(v) >> 8) * (1.0 / 16777216.0);
}

float grassHeight(float2 p, out float2 grade)
{
    float2 samplePosition = (p - GrassMap.xy) / GrassMap.z;
    int2 q = clamp(int2(floor(samplePosition)), 0, (int)GrassMap.w - 2);
    float2 f = saturate(samplePosition - q);
    float h00 = GrassHeight.Load(int3(q, 0));
    float h10 = GrassHeight.Load(int3(q + int2(1, 0), 0));
    float h01 = GrassHeight.Load(int3(q + int2(0, 1), 0));
    float h11 = GrassHeight.Load(int3(q + 1, 0));
    bool lower = f.x + f.y <= 1;
    float2 rise = lower ? float2(h10 - h00, h01 - h00) : float2(h11 - h01, h11 - h10);
    grade = rise / GrassMap.z;
    return lower ? h00 + dot(rise, f) : h11 + dot(rise, f - 1);
}

[numthreads(8, 8, 1)]
void GrassPlacementCS(uint3 id : SV_DispatchThreadID)
{
    if (any(id.xy >= (uint)GrassGrid.z))
        return;
    int2 cell = GrassGrid.xy + int2(id.xy);
    uint seed = grassHash(asuint(cell.x) * 0x9e3779b9u ^ asuint(cell.y) * 0x85ebca6bu);
    float2 offset = 0.09 + 0.82 * float2(grassRandom(seed + 10u), grassRandom(seed + 31u));
    float2 p = (cell + offset) * GrassSpacing;
    float distance = length(p - CameraTime.xz);
    if (distance < GrassFade.x || distance >= GrassFade.w)
        return;
    float transition = smoothstep(GrassFade.x, GrassFade.y, distance)
                       * (1 - smoothstep(GrassFade.z, GrassFade.w, distance));
    float weight = grassRandom(seed + 56u);
    if (weight > transition)
        return;

    float2 grade;
    float height = grassHeight(p, grade);
    float3 root = float3(p.x, height, p.y);
    float4 clip = mul(float4(root + float3(0, 0.5, 0), 1), ViewProjection);
    // Grass just off camera can still cast a shadow onto the foreground.
    bool castsNearby = GrassLodIndex == 0 && distance < 12;
    if (!castsNearby && (clip.w < -0.7 || any(abs(clip.xy) > clip.w + 2.4)))
        return;

    float bank = (abs(p.y) < riverExtent && abs(p.x - 49) < 87) ? riverBankDistance(p.x, p.y) : 100;
    if (bank < 4.3 && height <= riverLevel(p.y) + 0.072)
        return;
    float moisture = meadowMoisture(p);
    float shore = 1 - smoothstep(0.4, 10.5, abs(bank - 3.2));
    float density = lerp(0.63, 0.98, moisture);
    float path = 1 - meadowTrail(p);
    density *= path * path
               * (1 - smoothstep(0.61, 1.18, length(grade)))
               * (1 - smoothstep(660, 995, height));
    density *= smoothstep(-0.6, 1.8, bank);
    if (grassRandom(seed + 91u) > density)
        return;

    GrassSite site;
    site.root = root;
    site.seed = seed;
    site.grade = grade;
    site.moisture = moisture;
    site.bank = shore;
    SelectedGrass.Append(site);
}

struct GrassVarying
{
    float4 position : SV_Position;
    float3 normal : NORMAL;
    float3 color : COLOR;
    float bladeLength : TEXCOORD0;
    float2 grainUV : TEXCOORD1;
};

GrassVarying GrassVS(uint vertex : SV_VertexID, uint instance : SV_InstanceID)
{
    GrassSite site = GrassSites[instance];
    uint rows = GrassRows;
    uint blade = (vertex >> 1) / rows;
    uint row = (vertex >> 1) % rows;
    float t = (float)row / (rows - 1);
    float edge = (vertex & 1u) ? 1 : -1;
    uint seed = site.seed ^ (blade * 0x9e3779b9u);
    uint bits = grassHash(seed + 172u);
    float r0 = (bits & 1023u) / 1023.0;
    float r1 = ((bits >> 10) & 1023u) / 1023.0;
    float r2 = (bits >> 20) / 4095.0;
    float angle = r0 * (2 * PI) + blade * 2.3999632;
    float2 direction;
    sincos(angle, direction.x, direction.y);
    float2 widthAxis = float2(-direction.y, direction.x);
    float2 offset = direction * GrassSpacing * (0.13 + 0.52 * r1);
    float3 root = site.root + float3(offset.x, dot(offset, site.grade) - 0.022, offset.y);
    float seedHead = GrassLodIndex < 2 && blade == 0 && r2 < lerp(0.092, 0.031, site.moisture)
                     ? 1 : 0;
    float sward = ((site.seed >> 22) & 1023u) / 1023.0;
    float height = lerp(0.14, 0.49, r2) * lerp(0.77, 1.22, sward);
    height *= (1 + site.bank * 0.60 + seedHead * 1.06);
    float spread = lerp(0.18, 0.66, r1) * height;

    float windSpeed = length(WeatherEffects.yz);
    float2 wind = WeatherEffects.yz / max(windSpeed, 0.01);
    float gust = meadowGust(site.root.xz, wind);
    float windBend = (0.12 + 0.66 * gust) * min(windSpeed / 26.0, 1.7);
    float2 lean = direction * spread + wind * (height * windBend);
    float2 drift = lean * (t * t);
    // The wider, shorter ribbons at distance preserve coverage at fewer triangles.
    float distanceLod = GrassLodIndex * 0.5;
    float width = GrassSpacing * lerp(0.028, 0.074, r0);
    width *= lerp(1, 1.25, distanceLod);
    float taper = (0.63 + 1.17 * t) * (1 - t) * (1 + 0.45 * t);
    width *= taper * lerp(1.0, 0.46 + 0.62 * smoothstep(0.48, 0.81, t), seedHead);
    float2 horizontal = drift + widthAxis * (edge * width);
    float upright = height * (t - (0.17 + 0.14 * gust) * t * t * t);
    float3 p = root + float3(horizontal.x, upright, horizontal.y);

    GrassVarying o;
    o.position = mul(float4(p, 1), GeometryProjection);
    float2 crossBladeNormal = direction * 0.44 + widthAxis * (0.35 * edge) - lean * t;
    o.normal = normalize(float3(crossBladeNormal.x, 1.0, crossBladeNormal.y));
    float3 base = meadowColor(site.moisture) * lerp(0.67, 1.36, r1);
    float3 tips = base * float3(1.24, 1.13, 1.08);
    float bract = seedHead * smoothstep(0.58, 0.91, t);
    tips = lerp(tips, float3(0.35, 0.29, 0.115), bract);
    // At distance a pixel averages tips and roots across several blades.
    o.color = lerp(base * lerp(0.28, 0.69, distanceLod), tips, smoothstep(0, 0.94, t));
    o.color *= (0.91 + 0.18 * gust) * lerp(1, 0.72, WeatherEffects.x);
    o.bladeLength = t;
    float variant = (float)((bits >> 14) & 3u);
    o.grainUV = float2(0.015 + 0.97 * (edge * 0.5 + 0.5),
                      (variant + 0.018 + 0.964 * (1 - t)) * 0.25);
    return o;
}

GBuffer GrassPS(GrassVarying v)
{
    float rootAO = lerp(0.61, 0.92, GrassLodIndex * 0.5);
    float ao = lerp(rootAO, 0.98, v.bladeLength);
    float roughness = lerp(0.84, 0.56, WeatherEffects.x);
    float3 color = v.color;
    [branch]
    if (GrassLodIndex == 0)
    {
        float detail = BladeGrain.Sample(LinearClamp, v.grainUV).r;
        color *= 0.69 + 0.59 * detail;
    }
    return encodeMaterial(color, roughness, v.normal, 0, 0, -ao);
}
