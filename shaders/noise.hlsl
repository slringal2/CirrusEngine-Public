#include "common.hlsli"

cbuffer NoiseParameters : register(b1)
{
    uint NoiseSize;
    uint NoiseKind;
    uint2 Padding;
};

RWTexture3D<float4> NoiseOutput : register(u0);
RWTexture2D<float4> WeatherOutput : register(u0);
RWTexture2D<float2> DisplacementOutput : register(u1);
RWTexture2D<float4> CloudMapOutput : register(u0);
RWTexture2D<float4> CloudHeightOutput : register(u1);

float3 periodicCell(float3 p, float period)
{
    // 格子座標を周期内へ戻すことで、テクスチャの継ぎ目を連続にする。
    return p - floor(p / period) * period;
}

float valueNoise(float3 p, float period)
{
    float3 i = floor(p), f = frac(p);
    f = f * f * f * (f * (f * 6 - 15) + 10);
    float n000 = hash33(periodicCell(i, period)).x,
          n100 = hash33(periodicCell(i + float3(1, 0, 0), period)).x;
    float n010 = hash33(periodicCell(i + float3(0, 1, 0), period)).x,
          n110 = hash33(periodicCell(i + float3(1, 1, 0), period)).x;
    float n001 = hash33(periodicCell(i + float3(0, 0, 1), period)).x,
          n101 = hash33(periodicCell(i + float3(1, 0, 1), period)).x;
    float n011 = hash33(periodicCell(i + float3(0, 1, 1), period)).x,
          n111 = hash33(periodicCell(i + 1, period)).x;
    return lerp(lerp(lerp(n000, n100, f.x), lerp(n010, n110, f.x), f.y),
                lerp(lerp(n001, n101, f.x), lerp(n011, n111, f.x), f.y), f.z);
}

float gradientNoise(float3 p, float period)
{
    // 周囲8頂点のランダムな勾配を5次補間するPerlin型の勾配ノイズ。
    float3 i = floor(p), f = frac(p), u = f * f * f * (f * (f * 6 - 15) + 10);
    float value = 0;
    [unroll]
    for (int z = 0; z <= 1; z++)
        [unroll]
        for (int y = 0; y <= 1; y++)
            [unroll]
            for (int x = 0; x <= 1; x++)
            {
                float3 o = float3(x, y, z),
                       g = normalize(hash33(periodicCell(i + o, period)) * 2 - 1 + 0.00001);
                float3 weight = lerp(1 - u, u, o);
                value += dot(g, f - o) * weight.x * weight.y * weight.z;
            }

    return saturate(value * 1.35 + 0.5);
}

float worley(float3 p, float period)
{
    // 隣接27セルから最も近い特徴点までの距離F1を求め、1-F1を返す。
    float3 i = floor(p), f = frac(p);
    float d = 4;
    [loop]
    for (int z = -1; z <= 1; z++)
        [loop]
        for (int y = -1; y <= 1; y++)
            [loop]
            for (int x = -1; x <= 1; x++)
            {
                float3 o = float3(x, y, z);
                float3 delta = o + hash33(periodicCell(i + o, period)) - f;
                d = min(d, dot(delta, delta));
            }

    return saturate(1 - sqrt(d));
}

[numthreads(8, 8, 8)]
void NoiseCS(uint3 id : SV_DispatchThreadID)
{
    if (any(id >= NoiseSize))
        return;
    float3 p = (id + 0.5) / NoiseSize;
    float w0 = worley(p * 4, 4), w1 = worley(p * 8, 8), w2 = worley(p * 16, 16);

    // 詳細用ボリュームの RGBA に、4/8/16/32 セルの Worley を格納する。
    if (NoiseKind == 1)
    {
        float w3 = worley(p * 32, 32);
        NoiseOutput[id] = float4(w0, w1, w2, w3);
        return;
    }

    // 4オクターブのPerlinと3オクターブのWorleyで、雲塊用の密度を作る。
    float perlin = gradientNoise(p * 4, 4) * 0.533333 + gradientNoise(p * 8, 8) * 0.266667
                   + gradientNoise(p * 16, 16) * 0.133333 + gradientNoise(p * 32, 32) * 0.066667;
    perlin = remap01(perlin, 0.28, 0.72);
    float worleyFBM = w0 * 0.625 + w1 * 0.25 + w2 * 0.125;
    // R: Perlin-Worleyの膨張合成、GBA: 可視化用のWorley各帯域。
    float perlinWorley = lerp(worleyFBM, 1, perlin);
    NoiseOutput[id] = float4(remap01(perlinWorley, 0.42, 0.94), w0, w1, w2);
}

// 周期境界をまたいで、不規則な中心と半径を持つ積雲の水平断面を作る。
float cumulusCore(float2 uv)
{
    const float cells = 15;
    float2 position = uv * cells;
    float2 origin = floor(position);
    float2 local = frac(position);
    float core = 0;
    [unroll]
    for (int y = -1; y <= 1; ++y)
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            float2 neighbor = float2(x, y);
            float3 cell = periodicCell(float3(origin + neighbor, 0), cells);
            float3 seed = hash33(cell + float3(3.1, 7.4, 12.8));
            float2 center = neighbor + lerp(0.09, 0.91, seed.xy);
            float radius = lerp(0.29, 0.65, seed.z);
            float2 delta = (local - center) / radius;
            core = max(core, saturate(1 - dot(delta, delta)));
        }
    return core;
}

// 2D天候マップ。RGBA は被覆率、湿度、雲形の地域差、積雲中心への近さ。
[numthreads(8, 8, 1)]
void WeatherCS(uint3 id : SV_DispatchThreadID)
{
    if (any(id.xy >= 512))
        return;
    float2 uv = (id.xy + 0.5) / 512.0;
    float3 p = float3(uv * 8, 1.7);
    float coverage = 0, weight = 0.571;
    [unroll]
    for (int i = 0; i < 4; i++)
    {
        coverage += valueNoise(p, 8 * exp2(i)) * weight;
        p *= 2;
        weight *= 0.5;
    }
    float type = valueNoise(float3(uv * 16, 3.2), 16);
    float rain = valueNoise(float3(uv * 8, 5.6), 8);
    // 同じ周期を持つ独立2成分。雲のレイマーチでXY面とXZ面から参照する。
    float2 coarse = float2(valueNoise(float3(uv * 9, 2.17), 9),
                           valueNoise(float3(uv * 9, 5.31), 9));
    float2 fine = float2(valueNoise(float3(uv * 23, 8.46), 23),
                         valueNoise(float3(uv * 23, 1.57), 23));
    DisplacementOutput[id.xy] = lerp(coarse, fine, 0.32);
    float2 cumulusUv = uv + float2(0.038, 0.067) + (coarse - 0.5) * 0.018;
    WeatherOutput[id.xy] = float4(coverage, rain, type, cumulusCore(cumulusUv));
}

float2 cloudHeightThreshold(float h, float type)
{
    float lower = smoothstep(0.00, lerp(0.055, 0.095, type), h)
                  * (1 - smoothstep(lerp(0.15, 0.31, type), lerp(0.49, 0.79, type), h));
    float upper = smoothstep(lerp(0.23, 0.10, type), lerp(0.39, 0.30, type), h)
                  * (1 - smoothstep(lerp(0.53, 0.56, type), lerp(0.87, 1.00, type), h));
    return lerp(float2(1, 1), lerp(float2(0.42, 0.56), float2(0.51, 0.53), type),
                float2(lower, upper));
}

// Bauer (SIGGRAPH 2019), slides 14–18. 雲配置と高度形状は天候が変わったときに焼く。
[numthreads(8, 8, 1)]
void CloudMapCS(uint3 id : SV_DispatchThreadID)
{
    uint w, h;
    CloudMapOutput.GetDimensions(w, h);
    if (any(id.xy >= uint2(w, h)))
        return;
    float2 uv = (id.xy + 0.5) / float2(w, h);
    // R/G は下層・上層の被覆率。大きな天候分布を共有し、上層にだけずらした分布を混ぜる。
    float4 regional = WeatherMap.SampleLevel(LinearWrap, uv, 0);
    float upper = WeatherMap.SampleLevel(LinearWrap, uv + float2(0.37, 0.17), 0).r;
    float2 mask = float2(regional.r, lerp(regional.r, upper, 0.46));
    float lowSun = 1 - smoothstep(-0.08, 0.45, SunDirection.y);
    float2 weatherBias = CloudLayer.z - 0.018 + float2(0.018, 0) * lowSun;
    weatherBias.y += (Weather.x - 0.65) * 0.06 + regional.g * Weather.y * 0.04;
    float2 coverage = saturate((mask - 0.5) * 1.05 + weatherBias);
    float2 heightBounds = float2(0, 1);
    if (CUMULUS_CLOUDS)
    {
        float cumulus = cumulusAmount();
        float core = regional.a;
        float separation = smoothstep(0.03, 0.42, core);
        float2 cumulusCoverage = saturate(coverage + core * 0.22) * separation;
        coverage = lerp(coverage, cumulusCoverage, cumulus);

        // 1 - r² の平方根から雲の厚みを求め、B/Aに雲底と雲頂を書き込む。
        float2 structure = CloudDisplacement.SampleLevel(LinearWrap, uv * 3 + float2(0.19, 0.34), 0);
        float centerHeight = lerp(0.28, 0.67, smoothstep(0.16, 0.84, structure.y));
        float halfThickness = sqrt(core) * lerp(0.28, 0.56, structure.x);
        float2 cumulusBounds = clamp(centerHeight + float2(-1, 1) * halfThickness, 0, 1);
        heightBounds = lerp(heightBounds, cumulusBounds, cumulus);
    }
    CloudMapOutput[id.xy] = float4(coverage, heightBounds);

    if (id.x == 0 && id.y < 128)
    {
        float altitudeFraction = (id.y + 0.5) / 128;
        float2 threshold = cloudHeightThreshold(altitudeFraction, Weather.x);
        float softness = lerp(0.71, 0.85, smoothstep(0.15, 0.86, altitudeFraction));
        CloudHeightOutput[uint2(0, id.y)] = float4(threshold, softness, 1);
    }
}
