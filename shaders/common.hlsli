#ifndef CIRRUS_COMMON
#define CIRRUS_COMMON

// ワールド座標・距離の単位はm。地表の原点を y=0 とする球形の惑星を使う。
static const float PI = 3.14159265359;
static const float PLANET_RADIUS = 6360000.0;
static const float ATMOSPHERE_HEIGHT = 100000.0;
static const float CLOUD_SHADOW_EXPONENT = 10.0;
static const float3 PLANET_CENTER = float3(0, -6360000.0, 0);
static const float3 BETA_R = float3(5.802e-6, 13.558e-6, 33.100e-6);
static const float3 BETA_M = 3.996e-6;
static const float3 BETA_O = float3(0.650e-6, 1.881e-6, 0.085e-6);

struct CloudFormation
{
    float4 position; // x, 雲底高度, z, 半径 [m]
    float4 shape;    // 高さ[m], 密度倍率, 種類(0:入道雲/1:渦), シード
    float4 motion;   // 角速度[rad/s], 巻き込み強度, 高度による傾きX/Z
};

// C++ の FrameData と同じ並び・16バイト単位で共有する。片側だけ並べ替えない。
cbuffer Frame : register(b0)
{
    float4x4 ViewProjection;
    float4x4 InverseViewProjection;
    float4x4 PreviousViewProjection;
    float4x4 LightViewProjection;
    float4 CameraTime;       // xyz: カメラ位置[m]、w: シミュレーション時間[s]
    float4 PreviousCamera;
    float4 SunDirection;     // xyz: サンプル位置から太陽に向かう単位ベクトル
    float4 SolarExposure;    // rgb: 太陽光、w: 表示用露出
    float4 Resolution;       // xy: 画面サイズ、zw: その逆数
    float4 CloudLayer;       // 雲底高度[m]、厚み[m]、被覆率、密度倍率
    float4 Weather;          // 雲の形状、降水量、湿度、地表霧の消散係数
    float4 Wind;             // xy: 積分したXZ移動量[m]、z: 細部の縦移動、w: ジッタ用番号
    float4 PreviousWind;     // xy: 前回の移動量、z: 履歴の重み、w: 履歴有効フラグ
    float4 ShadowRegion;     // xy: 雲影範囲のXZ中心、z: 幅[m]、w: テクスチャ解像度
    float4 RenderSize;       // xy: 雲の描画サイズ、z: 視線サンプル数、w: 光サンプル数
    float4 Controls;         // デバッグ表示、稲妻の強さ、雲影有効、雲有効
    float4 Atmosphere;       // x: エアロゾル倍率、z: 遠方距離[m]
    float4 TextureInspection; // x: 断面位置[0,1]、y: 法線軸、z: プレビュー左端[pixel]
    float4 WeatherEffects;    // 地面の濡れ[0,1]、風速X/Z[m/s]、雨粒の有効フラグ
    float4 LightningSource;   // xyz: 放電の始点[m]、w: 枝形状のシード
    float4 LightningTarget;   // xyz: 落雷地点[m]、w: 放電からの経過時間[s]
    float4 CloudPerformance;  // xy: 雲影生成後の風の移動量[m]、z: 照明共有、w: 雲影の経過秒
    float4 Checkerboard;      // x: 今回は半数を計算、y: 偶奇、z: 生バッファの幅
    float4 FormationControls; // 領域数, 強度, 回転の積算位相[s], フレームの回転位相差[s]
    float4 FormationLayer;    // 全領域を含む雲底・雲頂高度、雲影の投影面[m]
    CloudFormation Formations[8];
};

Texture3D<float4> BaseNoise : register(t0);
Texture3D<float4> DetailNoise : register(t1);
Texture2D<float4> WeatherMap : register(t2);
Texture2D<float2> CloudShadowMap : register(t3);
Texture2D<float> SceneDepth : register(t4);
Texture2D<float4> GAlbedo : register(t5);
Texture2D<float4> GNormal : register(t6);
Texture2D<float4> SkyTexture : register(t7);
Texture2D<float4> CloudTexture : register(t8);
Texture2D<float2> CloudMetadata : register(t9);
Texture2D<float4> HistoryTexture : register(t10);
Texture2D<float2> HistoryMetadata : register(t11);
Texture2D<float4> AerialScatter : register(t12);
Texture2D<float4> AerialTransmittance : register(t13);
Texture2D<float4> FogTexture : register(t14);
Texture2D<float> TerrainShadow : register(t15);
Texture2D<float4> TransmittanceLUT : register(t16);
Texture2D<float4> RawCloudTexture : register(t17);
Texture2D<float4> RainTexture : register(t18);
Texture2D<uint> CloudReconstruction : register(t19);
Texture3D<float> TowerControlVolume : register(t20);
Texture3D<float4> CloudWarpVolume : register(t21);
Texture2D<float2> CloudMap : register(t22);
Texture2D<float4> CloudHeightLut : register(t23);
Texture2D<float2> CloudDisplacement : register(t24);
Texture2D<float4> SkyAmbient : register(t25);
SamplerState LinearClamp : register(s0);
SamplerState LinearWrap : register(s1);
SamplerComparisonState ShadowCompare : register(s2);

float hash12(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float3 hash33(float3 p)
{
    p = frac(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return frac((p.xxy + p.yxx) * p.zyx);
}

// 雷は一つの世界座標の光源として雲・地面・霧・雨を照らす。
float3 lightningIrradiance(float3 p)
{
    float3 irradiance = 0;
    [branch]
    if (Controls.y > 0)
    {
        float3 delta = p - LightningSource.xyz;
        float distanceSquared = dot(delta, delta);
        float falloff = exp(-sqrt(distanceSquared) / 14000.0) / (1 + distanceSquared / 16000000.0);
        irradiance = Controls.y * float3(8, 11, 18) * falloff;
    }
    return irradiance;
}

float remap01(float v, float a, float b)
{
    return saturate((v - a) / max(b - a, 0.0001));
}

float altitude(float3 p)
{
    return length(p - PLANET_CENTER) - PLANET_RADIUS;
}

float2 sphereIntersection(float3 origin, float3 direction, float radius)
{
    float3 o = origin - PLANET_CENTER;
    float b = dot(o, direction), c = dot(o, o) - radius * radius;
    float d = b * b - c;
    if (d < 0)
        return float2(-1, -1);
    d = sqrt(d);
    return float2(-b - d, -b + d);
}

float3 worldPosition(float2 uv, float depth)
{
    float4 p = mul(float4(uv * float2(2, -2) + float2(-1, 1), depth, 1), InverseViewProjection);
    return p.xyz / p.w;
}

float3 worldRay(float2 uv)
{
    return normalize(worldPosition(uv, 0.995) - CameraTime.xyz);
}

float sceneDistance(float2 uv)
{
    float d = SceneDepth.SampleLevel(LinearClamp, uv, 0);
    return d >= 0.999999 ? Atmosphere.z : length(worldPosition(uv, d) - CameraTime.xyz);
}

float hg(float cosine, float g)
{
    // Henyey-Greenstein位相関数。g>0 は前方散乱、g<0 は後方散乱を強める。
    return (1 - g * g) / (4 * PI * pow(max(1 + g * g - 2 * g * cosine, 0.001), 1.5));
}

float rayleighPhase(float cosine)
{
    return 3.0 / (16 * PI) * (1 + cosine * cosine);
}

float3 atmosphericDensity(float h)
{
    h = max(h, 0);
    return float3(exp(-h / 8000.0), exp(-h / 1200.0), saturate(1 - abs(h - 25000.0) / 15000.0));
}

float3 atmosphereExtinction(float3 d)
{
    return BETA_R * d.x + BETA_M * (1.11 * Atmosphere.x * d.y) + BETA_O * d.z;
}

float3 sunTransmittance(float3 p)
{
    float h = clamp(altitude(p), 1.0, ATMOSPHERE_HEIGHT - 1);
    float mu = dot(normalize(p - PLANET_CENTER), SunDirection.xyz);
    return TransmittanceLUT
        .SampleLevel(LinearClamp, float2(mu * 0.5 + 0.5, sqrt(h / ATMOSPHERE_HEIGHT)), 0)
        .rgb;
}

float2 cloudPlacement(float2 advectedXZ)
{
    return CloudMap.SampleLevel(LinearWrap, advectedXZ / 32768.0, 0);
}

float3 cloudHeightProfile(float h)
{
    return CloudHeightLut.SampleLevel(LinearClamp, float2(0.5, h), 0).rgb;
}

// 2枚分の2D変位サンプルで3D座標をずらし、Perlin–Worleyを一度読む。
float erodeCloudShape(float baseDensity, float3 p, float softness)
{
    float2 xy = CloudDisplacement.SampleLevel(LinearWrap, p.xy / 6900.0, 0) - 0.5;
    float2 xz = CloudDisplacement.SampleLevel(LinearWrap,
                                              p.xz / 8500.0 + float2(0.36, 0.17), 0) - 0.5;
    float3 q = p + float3(0.5 * (xy.x + xz.x), xy.y, xz.y) * 790;
    q.y -= Wind.z;
    float perlinWorley = BaseNoise.SampleLevel(LinearWrap,
                                              q * 0.00056 + float3(0.13, 0.27, 0.38), 0).r;
    float erosion = lerp(0.07, 0.69, 1 - perlinWorley);
    return remap01(baseDensity, erosion, softness);
}

#include "formations.hlsli"

float backgroundCloudDensity(float3 p, float h, bool detail)
{
    if (h <= 0 || h >= 1)
        return 0;

    float3 advected = p - float3(Wind.x, 0, Wind.y);
    float2 displacement = float2(410, -260) * h * h;
    float2 placement = cloudPlacement(advected.xz + displacement);
    float3 profile = cloudHeightProfile(h);
    float2 shape = smoothstep(profile.xy, profile.xy + float2(0.19, 0.22), placement);
    float density = max(shape.x, shape.y);
    if (detail && density > 0)
        density = erodeCloudShape(density, advected, profile.z);
    return density * CloudLayer.w;
}

// 視線・太陽遮蔽・雲影に共通の背景雲海＋局所形状を返す。
float2 cloudDensitySample(float3 p, bool detail)
{
    if (Controls.w < 0.5)
        return 0;
    float height = altitude(p);
    float h = (height - CloudLayer.x) / CloudLayer.y;
    return compositeFormationDensity(p, height, h, detail, backgroundCloudDensity(p, h, detail));
}

float cloudDensity(float3 p, bool detail)
{
    return cloudDensitySample(p, detail).x;
}

float cloudExtinction()
{
    // 密度が1のときの消散係数[1/m]。区間長を掛けると光学的厚さになる。
    return 0.006;
}

float cloudShadowRayLength()
{
    return min((FormationLayer.y - FormationLayer.z) / max(SunDirection.y, 0.02), 85000);
}

float cloudShadow(float3 p)
{
    if (Controls.z < 0.5 || Controls.w < 0.5 || SunDirection.y <= 0.015)
        return 1;

    // 光線方向の距離を基準にする。雲より上の受光点には影が掛からない。
    float projectionDistance = (FormationLayer.z - p.y) / max(SunDirection.y, 0.02);
    float rayLength = cloudShadowRayLength();
    float receiver = 1 + projectionDistance / rayLength;
    if (receiver <= 0)
        return 1;
    float2 projected = p.xz + SunDirection.xz * projectionDistance;
    projected -= CloudPerformance.xy;
    float2 uv = (projected - ShadowRegion.xy) / ShadowRegion.z + 0.5;
    float border = saturate(min(min(uv.x, uv.y), min(1 - uv.x, 1 - uv.y)) * 25);
    float texelSize = ShadowRegion.z / ShadowRegion.w;
    float penumbra = max(FormationLayer.x - p.y, 0) * (0.0093 / SunDirection.y);
    float mip = clamp(log2(1.5 + penumbra / texelSize), 0, 5);
    float2 moments = CloudShadowMap.SampleLevel(LinearClamp, uv, mip);
    // Rは雲層全体の透過率。Gを復号すると遮蔽深度より太陽側で1に近づく。
    float visibility = saturate(moments.x + moments.y * exp(-CLOUD_SHADOW_EXPONENT * receiver));
    return lerp(1, visibility, border * smoothstep(0.015, 0.045, SunDirection.y));
}

float terrainShadow(float3 p)
{
    // 地形の影はこちらの深度マップで計算する。雲影の透過率とは別の方式。
    float4 clip = mul(float4(p, 1), LightViewProjection);
    float3 coord = clip.xyz / clip.w;
    float2 uv = coord.xy * float2(0.5, -0.5) + 0.5;
    if (any(uv <= 0) || any(uv >= 1) || coord.z <= 0 || coord.z >= 1)
        return 1;
    float value = 0;

    // 2048²の深度を3x3 PCFで比較する。小さなバイアスで自己遮蔽の縞を抑える。
    [unroll]
    for (int y = -1; y <= 1; y++)
        [unroll]
        for (int x = -1; x <= 1; x++)
            value += TerrainShadow.SampleCmpLevelZero(
                ShadowCompare, uv + float2(x, y) / 2048.0, coord.z - 0.0004);

    return value / 9;
}

struct AtmosphereResult
{
    float3 scattering;
    float3 transmittance;
};

AtmosphereResult integrateAtmosphere(float3 origin, float3 direction, float distance, int steps)
{
    // 空気分子のRayleigh散乱、エアロゾルのMie散乱近似、オゾン吸収を積分する。
    AtmosphereResult result;
    result.scattering = 0;
    result.transmittance = 1;
    float ds = distance / steps;
    float cosine = dot(direction, SunDirection.xyz);
    float rp = rayleighPhase(cosine), mp = hg(cosine, 0.76);
    [loop]
    for (int i = 0; i < steps; i++)
    {
        float3 p = origin + direction * ((i + 0.5) * ds);
        float3 d = atmosphericDensity(altitude(p));
        float3 extinction = atmosphereExtinction(d);
        float3 segment = exp(-extinction * ds);
        float3 sunT = sunTransmittance(p);
        float3 source =
            (BETA_R * d.x * rp + BETA_M * (d.y * Atmosphere.x * mp)) * SolarExposure.rgb * sunT;
        // 高次の散乱は等方的な補助項で近似する。
        float3 multiple = (BETA_R * d.x + BETA_M * d.y * Atmosphere.x)
                          * (0.007 + 0.015 * (1 - sunT)) * SolarExposure.rgb
                          * saturate(SunDirection.y * 3 + 0.25);
        // 区間内の係数を一定とみなし、(1-exp(-sigma*ds))/sigma で積分する。
        result.scattering +=
            result.transmittance * (source + multiple) * (1 - segment) / max(extinction, 1e-8);
        result.transmittance *= segment;
    }
    return result;
}

#endif
