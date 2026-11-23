#ifndef CIRRUS_COMMON
#define CIRRUS_COMMON

#include "river_profile.hlsli"

#ifndef CIRRUS_CUMULUS_CLOUDS
#define CIRRUS_CUMULUS_CLOUDS 0
#endif

static const bool CUMULUS_CLOUDS = CIRRUS_CUMULUS_CLOUDS != 0;

// ワールド座標・距離の単位はm。地表の原点を y=0 とする球形の惑星を使う。
static const float PI = 3.14159265359;
static const float PLANET_RADIUS = 6360000.0;
static const float ATMOSPHERE_HEIGHT = 100000.0;
static const float CLOUD_SHADOW_EXPONENT = 10.0;
static const int TEXTURE_CLOUD_LAYER_COUNT = 3;
static const float3 PLANET_CENTER = float3(0, -6360000.0, 0);
// 基準の係数はすべて [m⁻¹]。実際のサンプルでは高度に応じた相対密度を掛ける。
// R は空気分子、M はエアロゾル、O はオゾン。O は透過を減らす吸収にだけ使う。
// R の青成分は赤の約 5.7 倍。M は RGB 共通で、白っぽい霞を作る。
static const float3 BETA_R = float3(5.802e-6, 13.558e-6, 33.100e-6);
static const float3 BETA_M = 3.996e-6;
static const float3 BETA_O = float3(0.650e-6, 1.881e-6, 0.085e-6);

struct CloudFormation
{
    float4 position; // x, 雲底高度, z, 半径 [m]
    float4 shape;    // 高さ[m], 密度倍率, 種類(0:入道雲、1:渦、2～6:特殊形状), シード
    float4 motion;   // 角速度[rad/s], 巻き込み強度, 高度による傾きX/Z
};

// C++ の FrameData と同じ並び・16バイト単位で共有する。片側だけ並べ替えない。
cbuffer Frame : register(b0)
{
    float4x4 ViewProjection;
    float4x4 InverseViewProjection;
    float4x4 PreviousViewProjection;
    float4x4 LightViewProjection;
    float4x4 NearLightViewProjection;
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
    float4 Checkerboard;      // x: 0=全画素 / 1=2相 / 2=4相、y: 位相、zw: 生バッファのサイズ
    float4 WorldRendering;    // x: exploration / reversed Z, y: near shadows, z: solar clock
    float4 FormationControls; // 領域数, 強度, 回転の積算位相[s], フレームの回転位相差[s]
    float4 FormationLayer;    // 体積雲の雲底・雲頂、雲影の投影面、薄層込みの影の上端[m]
    CloudFormation Formations[24];
    float4 CloudOcclusionRegion; // xy: 風を引いたXZ中心[m]、z: 幅[m]、w: 有効フラグ
    float4 CameraForward;  // xyz: カメラの前方単位ベクトル
    float4 NearCloudParams; // x: 視錐台の奥行き[m]、y: 近い雲の変形量、z: スライス数、w: 変形範囲[m]
    float4 CloudSampling; // x: 詳細ノイズ解像度、y: 安定サンプリング、z: 遠い光サンプルの統合、w: 雲TAAの位相+1（0は無効）
    float4x4 GrassLightViewProjection;
    float4 GroundLighting; // x: SSAO、y: 接触影、z: 草影の有効フラグ。w: 焦点距離[pixel]
    float4 SceneDepthProjection; // x/y: 透視投影の深度係数 A/B
    float4 CloudShapeTuning; // x: 雲の水平サイズの逆数、y: 雲縁の侵食倍率
    // 中央高度[m]、半厚[m]、ピーク消散係数[m^-1]、水平タイル周期の逆数[m^-1]。
    float4 TextureCloudLayers[TEXTURE_CLOUD_LAYER_COUNT];
    // x: shape-map size, y: use thickness/height channels, z: last index in the type ramp.
    float4 TextureCloudMaps[TEXTURE_CLOUD_LAYER_COUNT];
    // xy: inverse periods of the type and coverage maps. zw: texels per metre.
    float4 TextureCloudRegions;
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
Texture2D<float4> CloudMap : register(t22);
Texture2D<float4> CloudHeightLut : register(t23);
Texture2D<float2> CloudDisplacement : register(t24);
Texture2D<float4> SkyAmbient : register(t25);
Texture2D<float> NearTerrainShadow : register(t26);
Texture2D<float4> GSurface : register(t27);
Texture3D<float4> NearCloudIntegrated : register(t31);
Texture2D<float4> CloudTypeTexture0 : register(t45);
Texture2D<float4> CloudTypeTexture1 : register(t46);
Texture2D<float4> CloudTypeTexture2 : register(t47);
Texture2D<float> HighCloudTypeMap : register(t48);
Texture2D<float> HighCloudCoverageMap : register(t49);
SamplerState LinearClamp : register(s0);
SamplerState LinearWrap : register(s1);
SamplerComparisonState ShadowCompare : register(s2);
SamplerState AnisotropicWrap : register(s8);

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

float3 planetCenter()
{
    // Exploration is a planar terrain chart. Center its local atmospheric horizon on the camera.
    return PLANET_CENTER + float3(CameraTime.x, 0, CameraTime.z) * WorldRendering.x;
}

float altitude(float3 p)
{
    return length(p - planetCenter()) - PLANET_RADIUS;
}

float2 sphereIntersection(float3 origin, float3 direction, float radius)
{
    float3 o = origin - planetCenter();
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
    float sampleDepth = WorldRendering.x > 0.5 ? 0.0008 : 0.995;
    return normalize(worldPosition(uv, sampleDepth) - CameraTime.xyz);
}

float viewDepthCosine(float3 ray)
{
    return max(dot(ray, CameraForward.xyz), 0.001);
}

float nearCloudRayEnd(float3 ray)
{
    return NearCloudParams.x / viewDepthCosine(ray);
}

struct NearCloudSample
{
    float4 color;
    float3 uv;
    float scale;
};

NearCloudSample sampleNearCloud(float2 uv, float3 ray, float scene)
{
    const float4 clear = float4(0, 0, 0, 1);
    NearCloudSample result;
    result.color = clear;
    result.uv = float3(uv, 0);
    result.scale = 0;

    [branch]
    if (NearCloudParams.x > 0)
    {
        // スライスの奥側の面に累積値を置く。地形が途中にある場合はその面まで補間する。
        float slices = NearCloudParams.z;
        float normalizedDepth = saturate(scene * viewDepthCosine(ray) / NearCloudParams.x);
        float squaredSlice = normalizedDepth * slices * slices;
        float previousFace = floor(sqrt(squaredSlice));
        float fraction = saturate((squaredSlice - previousFace * previousFace) / (2 * previousFace + 1));
        result.uv.z = (previousFace + fraction - 0.5) / slices;

        // 格子の最初の面までは、視点の透明な値から補間する。
        result.scale = saturate(squaredSlice);
        float4 integrated = NearCloudIntegrated.SampleLevel(LinearClamp, result.uv, 0);
        result.color = lerp(clear, integrated, result.scale);
    }
    return result;
}

float geometryDepth(float2 uv)
{
    int2 pixel = clamp(int2(uv * Resolution.xy), 0, int2(Resolution.xy) - 1);
    return WorldRendering.x > 0.5 ? SceneDepth.Load(int3(pixel, 0))
                                  : SceneDepth.SampleLevel(LinearClamp, uv, 0);
}

bool hasGeometry(float depth)
{
    return WorldRendering.x > 0.5 ? depth > 0 : depth < 0.999999;
}

float riverSurfaceDistance(float3 ray, float opaqueDistance)
{
    float slope = ray.y + ray.z * riverGrade;
    if (slope >= -0.00001)
        return opaqueDistance;
    float distance = (riverLevel(CameraTime.z) - CameraTime.y) / slope;
    if (distance < 0.15 || distance >= opaqueDistance)
        return opaqueDistance;
    float2 p = CameraTime.xz + ray.xz * distance;
    if (abs(p.y) >= riverExtent || p.x < -15 || p.x > 114)
        return opaqueDistance;
    return riverBankDistance(p.x, p.y) <= 4.3 ? distance : opaqueDistance;
}

float sceneDistance(float2 uv)
{
    float depth = geometryDepth(uv);
    float distance = hasGeometry(depth) ? length(worldPosition(uv, depth) - CameraTime.xyz)
                                        : Atmosphere.z;
    [branch]
    if (WorldRendering.x > 0.5)
        distance = riverSurfaceDistance(worldRay(uv), distance);
    return distance;
}

float hg(float cosine, float g)
{
    // Henyey-Greenstein位相関数。g>0 は前方散乱、g<0 は後方散乱を強める。
    // 呼び出し側の cosine はカメラ → サンプルとサンプル → 太陽の内積。
    // 太陽を見ると +1 に近くなる。位相関数は光を方向ごとに配分する係数 [sr⁻¹]。
    return (1 - g * g) / (4 * PI * pow(max(1 + g * g - 2 * g * cosine, 0.001), 1.5));
}

float rayleighPhase(float cosine)
{
    // 二乗なので太陽を向く場合と背にする場合が対称。RGB の波長差は BETA_R で扱う。
    return 3.0 / (16 * PI) * (1 + cosine * cosine);
}

float3 atmosphericDensity(float h)
{
    // x と y は高度が 8 km と 1.2 km 上がるごとに 1/e へ減る。
    // z は高度 25 km を頂点に、上下 15 km の範囲で直線的に減るオゾン層。
    h = max(h, 0);
    return float3(exp(-h / 8000.0), exp(-h / 1200.0), saturate(1 - abs(h - 25000.0) / 15000.0));
}

float3 atmosphereExtinction(float3 d)
{
    // 消散は散乱と吸収で光線から失われる割合。Mie の 1.11 は吸収分を含める倍率。
    // Atmosphere.x は湿度に応じた倍率で、Mie の消散と散乱源の両方に掛かる。
    return BETA_R * d.x + BETA_M * (1.11 * Atmosphere.x * d.y) + BETA_O * d.z;
}

float3 sunTransmittance(float3 p)
{
    // TransmittanceCS と同じ座標変換。U はその地点の天頂と太陽方向の内積を正規化する。
    // V の平方根写像で、密度が急に変わる地表付近へ LUT のサンプルを多く割り当てる。
    float h = clamp(altitude(p), 1.0, ATMOSPHERE_HEIGHT - 1);
    float mu = dot(normalize(p - planetCenter()), SunDirection.xyz);
    return TransmittanceLUT
        .SampleLevel(LinearClamp, float2(mu * 0.5 + 0.5, sqrt(h / ATMOSPHERE_HEIGHT)), 0)
        .rgb;
}

float cumulusAmount()
{
    // 降水の少ない天候で、雲塊が上へ盛り上がる形を強める。
    return smoothstep(0.38, 0.88, Weather.x) * (1 - smoothstep(0.18, 0.67, Weather.y));
}

float4 cloudPlacement(float2 advectedXZ)
{
    return CloudMap.SampleLevel(LinearWrap, advectedXZ / 65536.0, 0);
}

// 雲量をゼロへ動かすと、地域的な雲量の上振れも連続して消える。
float cloudCoverageFade()
{
    return smoothstep(0, 0.1, CloudLayer.z);
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

struct CloudBodySample
{
    float density;
    float3 shapePosition;
    float3 warp;
    float shape;
    float profile;
    float threshold;
    float localHeight;
};

// 上昇域の肩で、上下の房の間に雲水を残す。空域・薄い柱・雲底・雲頂への寄与は消える。
float thermalCoreWeight(float localHeight, float depth, float coverage, float convection)
{
    float column = smoothstep(0.38, 0.81, depth) * smoothstep(0.10, 0.39, coverage);
    float middle = smoothstep(0.03, 0.20, localHeight) * (1 - smoothstep(0.52, 0.88, localHeight));
    return 0.52 * convection * column * middle;
}

float supportCloudInterior(float envelope, float coreWeight)
{
    return lerp(envelope, 1, coreWeight * smoothstep(0.15, 0.53, envelope));
}

// 配置マップが決めた上面から内向きに削り、粗い密度を空区間判定の上限に保つ。
float crownInset(float localHeight, float cells, float convection)
{
    float hollows = 1 - smoothstep(0.22, 0.73, cells);
    return 0.17 * convection * smoothstep(0.12, 0.67, localHeight) * hollows;
}

float cumulusDensity(float shape, float threshold, float erosion, float cumulus)
{
    float density = saturate(remap01(shape, threshold, 1) * lerp(1.85, 1.72, cumulus));
    // 薄い縁を強く削り、密度の高い中心を残す。
    density = remap01(density, erosion * (1 - density * 0.55), 1);
    return density * lerp(1, smoothstep(0, 0.28, density), cumulus * 0.60);
}

// 密度の参照点を上空の風に逆らって戻す。これを配置マップより前に行うと、
// 密度と雲頂が同じ方向へ張り出す。高さ h は雲層全体に対する割合。
void bendConvectiveTop(inout float3 material, inout float h, float convection)
{
    const float anchoredHeight = 0.13;
    if (h <= anchoredHeight || convection <= 0)
        return;

    float2 wind = WeatherEffects.yz;
    float speed = length(wind);
    if (speed <= 0)
        return;

    float2 downwind = wind / speed;
    float2 crosswind = float2(-downwind.y, downwind.x);
    float strength = convection * saturate(speed / 15);
    float2 region = CloudDisplacement.SampleLevel(
        LinearWrap, material.xz * (2.0 / 65536.0) + float2(0.19, 0.43), 0);
    float rise = h - anchoredHeight;
    float exposure = smoothstep(0.23, 0.78, region.x);
    float2 shear = downwind * lerp(0.52, 1.42, exposure)
                   + crosswind * ((region.y - 0.5) * 0.26);
    // 肩では上ほど強く傾け、雲頂の中ではずれの増加を抑えて丸みを残す。
    float bend = rise * rise;
    float capHeight = lerp(0.47, 0.61, region.y);
    float capRatio = bend / (capHeight * capHeight);
    bend *= rsqrt(1 + capRatio * capRatio);
    material.xz -= shear * (strength * min(CloudLayer.y, 4600) * bend);

    // 雲の肩を、風向に沿った鉛直面内で巻く。中心と半径を区画ごとに変える。
    // 変形量は区画の端より手前でゼロになるため、隣の区画へ滑らかにつながる。
    float spacing = 2048.0 / CloudShapeTuning.x;
    float2 cell = material.xz / spacing + (region - 0.5) * 0.46;
    float3 seed = hash33(float3(floor(cell), 31.72));
    float2 offset = (frac(cell) - lerp(0.43, 0.57, seed.xy)) * spacing;
    float radius = spacing * lerp(0.33, 0.415, seed.z);
    float radialSq = dot(offset, offset) / (radius * radius);
    if (radialSq >= 1)
        return;

    // 渦の高さはその場所の雲頂から決めるので、低い積雲にも高い積雲にも付く。
    float4 column = cloudPlacement(material.xz - offset);
    float depth = max(1, (column.a - column.b) * CloudLayer.y);
    float pivot = lerp(column.b, column.a, lerp(0.55, 0.76, seed.x));
    float verticalRadius = max(1, min(radius * 0.84, depth * lerp(0.29, 0.46, seed.y)));
    float2 plane = float2(dot(offset, downwind) / radius,
                          (h - pivot) * CloudLayer.y / verticalRadius);
    float distanceSq = radialSq + plane.y * plane.y;
    if (distanceSq >= 1)
        return;

    float falloff = 1 - smoothstep(0.03, 1, distanceSq);
    float heightMask = smoothstep(anchoredHeight, 0.30, h) * (1 - smoothstep(0.86, 0.98, h));
    float turn = strength * heightMask * falloff;
    float sine, cosine;
    sincos(lerp(0.80, 1.53, seed.z) * turn, sine, cosine);
    float2 source = float2(cosine * plane.x - sine * plane.y,
                           sine * plane.x + cosine * plane.y);
    // 風下側では元の高さを広めに参照し、描画される縁を少し薄くする。
    source.y *= 1 + 0.23 * turn * smoothstep(-0.15, 0.70, plane.x);
    float dy = (source.y - plane.y) * verticalRadius;
    material.xz += downwind * ((source.x - plane.x) * radius);
    material.y += dy;
    h += dy / CloudLayer.y;
}

CloudBodySample cumulusCloudShape(
    float3 shapePosition, float h, float4 placement, float cumulus)
{
    CloudBodySample result = (CloudBodySample)0;
    float localHeight = (h - placement.b) / max(placement.a - placement.b, 0.01);
    float upperWeight = smoothstep(0.25, 0.72, localHeight) * lerp(1, 0.28, cumulus);
    float coverage = lerp(placement.r, placement.g, upperWeight);
    float type = saturate(Weather.x + (placement.g - placement.r) * 0.70);

    // 雲底の短い立ち上がりと雲頂の丸みを別に設定し、降水時の分布へ連続して補間する。
    float bottom = smoothstep(0, lerp(0.055, 0.075, cumulus), localHeight);
    float crownStart = lerp(lerp(0.20, 0.38, type), 0.66, cumulus);
    float crownEnd = lerp(lerp(0.46, 0.98, type), 1.0, cumulus);
    float profile = bottom * (1 - smoothstep(crownStart, crownEnd, localHeight));
    float threshold = 1 - coverage;
    // 形状ノイズの最大値は1。被覆率と高度だけで空なら、3Dノイズを読まない。
    if (profile <= threshold)
        return result;

    shapePosition.xz *= lerp(1, 1.06, cumulus) * CloudShapeTuning.x;
    shapePosition.y *= lerp(lerp(1.5, 0.9, type), 0.83, cumulus);
    // Perlin–Worley の大きな塊に GBA の小さな膨らみを重ねる。
    float4 base = BaseNoise.SampleLevel(LinearWrap,
                                      shapePosition * 0.000115 + float3(0.13, 0.27, 0.38), 0);
    float crest = dot(base.ba, float2(0.60, 0.40));
    profile = bottom * (1 - smoothstep(crownStart, crownEnd,
                                       localHeight + crownInset(localHeight, crest, cumulus)));
    float billows = dot(base.gba, float3(0.15, 0.50, 0.35));
    float envelope = saturate(base.r + (billows - 0.44) * 0.42 + 0.065);
    envelope = lerp(envelope, 0.09 + 0.91 * envelope, cumulus);
    // Cumulus の内部はこの直前の補強で連続する。雲内の飛行時にも外縁が見える密度を使う。
    result.shape = envelope * profile;
    result.profile = profile;
    result.localHeight = localHeight;
    result.threshold = threshold;
    result.density = cumulusDensity(result.shape, threshold, 0, cumulus);
    result.shapePosition = shapePosition;
    result.warp = base.gba - 0.5;
    return result;
}

CloudBodySample cloudBodyShape(float3 shapePosition, float h, float4 placement, float convection)
{
    CloudBodySample result = (CloudBodySample)0;
    // 配置と密度を一緒に曲げたあと、内部ノイズに従来の小さな傾きを加える。
    float noiseShear = CUMULUS_CLOUDS ? lerp(1, 0.55, convection) : 1;
    shapePosition.xz += float2(h * h * 480.0, -h * 220.0) * noiseShear;
    if (CUMULUS_CLOUDS)
        return cumulusCloudShape(shapePosition, h, placement, convection);

    // 曇天の雲頂は雲種から 0.46～0.98 に写像される。晴天では地図上の局所的な厚みを使う。
    float type = lerp(saturate((placement.a - 0.46) / 0.52), Weather.x, convection);
    float crownStart = lerp(lerp(0.20, 0.38, type),
                            lerp(placement.b, placement.a, 0.64), convection);
    float bottom = smoothstep(placement.b, placement.b + 0.055, h);
    float top = 1 - smoothstep(crownStart, placement.a, h);
    float profile = bottom * top;
    float threshold = 1 - placement.r;
    // 大きな形の値は最大1。高度プロファイルだけで空と判定できる点は3Dノイズを読まない。
    if (profile <= threshold)
        return result;

    shapePosition.xz *= CloudShapeTuning.x;
    shapePosition.y *= lerp(1.5, 0.9, type);
    // 低周波の変位で大きな雲塊を曲げ、中間スケールのWorleyで大小の膨らみを付ける。
    float3 warp = BaseNoise.SampleLevel(LinearWrap, shapePosition * 0.00018 + 0.37, 1).gba - 0.5;
    shapePosition += warp * 340.0;
    float base = BaseNoise.SampleLevel(LinearWrap,
                                      shapePosition * 0.000115 + float3(0.13, 0.27, 0.38), 0).r;
    // Worleyが最大値を取っても閾値に届かない点では、そのテクスチャを読む必要がない。
    float depth = max(placement.a - placement.b, 0.01);
    float localHeight = saturate((h - placement.b) / depth);
    float coreWeight = thermalCoreWeight(localHeight, depth, placement.r, convection);
    // 密度の補強は単調増加。細部が最大のときの値にも同じ関数を使えば、早期終了は安全。
    float upperEnvelope = supportCloudInterior(saturate(base + 0.371), coreWeight);
    if (upperEnvelope * profile <= threshold)
        return result;
    float3 billows = DetailNoise.SampleLevel(LinearWrap, shapePosition * 0.00075, 0).rgb;
    float cells = dot(billows, float3(0.55, 0.30, 0.15));

    float inset = depth * crownInset(localHeight, cells, convection);
    profile = bottom * (1 - smoothstep(crownStart, placement.a, h + inset));
    float envelope = saturate(base + (cells - 0.43) * 0.65);
    float shape = supportCloudInterior(envelope, coreWeight) * profile;
    result.localHeight = localHeight;
    result.density = saturate(remap01(shape, threshold, 1) * 2.1);
    result.shapePosition = shapePosition;
    result.warp = warp;
    return result;
}

// 粗い本体・雲頂は詳細形状の密度上限。風下の混合量を保持し、空区間の判定と
// 表面の詳細化に同じ希釈率と輸送密度を使う。
struct BackgroundCloudSample
{
    CloudBodySample body;
    CloudBodySample head;
    float headWeight;
    float density;
    float dilution;
    float carriedDensity;
};

struct CloudWindMargin
{
    float reach;       // 風速と雲の厚みから求めた移送距離の基準 [m]
    float exposure;    // 外気と混ざる風下の肩 [0, 1]
};

void shapeDownwindCrown(inout BackgroundCloudSample result, inout float3 bodyPosition,
                        inout float4 column, float h, float2 downwind, float strength,
                        float convection, out CloudWindMargin margin)
{
    // Zhao & Austin (2005), Fig. 4 の浅い積雲の鉛直断面。風上側の柱を親にして
    // 上部だけを運ぶ。局所的な雲の厚みで距離を制限し、雲底に続く本体を残す。
    float columnDepth = max(0.01, column.a - column.b);
    float reach = strength * min(0.34 * columnDepth * CloudLayer.y, 900.0 / CloudShapeTuning.x);
    float3 headPosition = bodyPosition;
    headPosition.xz -= downwind * reach;
    float4 parent = cloudPlacement(headPosition.xz);
    float parentDepth = max(0.01, parent.a - parent.b);
    float level = (h - parent.b) / parentDepth;
    float slope = parent.a - column.a + 0.65 * (parent.r - column.r);
    float flank = strength * smoothstep(-0.025, 0.10, slope) * smoothstep(0.13, 0.25, h);

    // 風下へ雲頂と被覆率が落ちる縁を選び、肩のすぐ下だけ少し風上へ引く。
    float shoulder = lerp(0.50, 0.63, saturate((parent.a - 0.34) / 0.58));
    float neck = smoothstep(shoulder - 0.34, shoulder - 0.15, level)
                 * (1 - smoothstep(shoulder - 0.15, shoulder + 0.025, level));
    result.headWeight = flank * smoothstep(shoulder - 0.14, shoulder + 0.10, level);
    // 肩の上下で効果を滑らかに消し、厚い中心と雲底を支える柱を残す。
    float band = smoothstep(shoulder - 0.30, shoulder - 0.045, level)
                 * (1 - smoothstep(shoulder + 0.14, shoulder + 0.36, level));
    margin.reach = reach;
    margin.exposure = saturate(strength * 1.55) * smoothstep(-0.035, 0.095, slope)
                      * smoothstep(0.13, 0.25, h) * band;
    float bodyAdvance = reach * (0.54 * result.headWeight - 0.34 * flank * neck);
    [branch]
    if (bodyAdvance != 0)
    {
        // 密度を逆向きに読む。肩も頭についていくため根元につながった丸みが残る。
        bodyPosition.xz -= downwind * bodyAdvance;
        column = cloudPlacement(bodyPosition.xz);
    }

    [branch]
    if (result.headWeight > 0)
    {
        // 頭はまとまった体積として移す。同じ距離だけ平行移動したノイズで輪郭を保ち、
        // 高さ方向のみ中心へ寄せて読み、先端が細い筋にならないようにする。
        float center = parent.b + parentDepth * (shoulder + 0.16);
        float headH = lerp(h, center, 0.20 * flank * (1 - smoothstep(0.84, 0.98, h)));
        headPosition.y += (headH - h) * CloudLayer.y;
        result.head = cloudBodyShape(headPosition, headH, parent, convection);
    }
}

BackgroundCloudSample unmixedCloudShape(float3 p, float h, out CloudWindMargin margin)
{
    margin = (CloudWindMargin)0;
    BackgroundCloudSample result = (BackgroundCloudSample)0;
    if (h > 0 && h < 1 && CloudLayer.z > 0 && CloudLayer.w > 0)
    {
        float3 material = p - float3(Wind.x, 0, Wind.y);
        float convection = cumulusAmount();
        bendConvectiveTop(material, h, convection);
        float4 column = cloudPlacement(material.xz);
        float2 wind = WeatherEffects.yz;
        float speed = length(wind);
        if (convection > 0 && h > 0.13 && speed > 0)
            shapeDownwindCrown(result, material, column, h, wind / max(speed, 0.0001),
                               convection * saturate(speed / 15), convection, margin);

        result.body = cloudBodyShape(material, h, column, convection);
        result.density = max(result.body.density, result.head.density * result.headWeight);
    }
    return result;
}

float cloudDetailLod(float footprint, float frequency)
{
    // テクスチャ上の投影幅に合わせる。footprint=0は従来どおりミップ0。
    return log2(max(1, footprint * frequency * CloudSampling.x * 0.65));
}

float detailCumulusCloud(CloudBodySample background, float footprint, float baseFray)
{
    float cumulus = cumulusAmount();
    float3 detailPosition = background.shapePosition - float3(0, Wind.z, 0);
    float3 detailUv = detailPosition * 0.00075 + background.warp * 0.07;
    float4 noise = DetailNoise.SampleLevel(LinearWrap, detailUv, cloudDetailLod(footprint, 0.00075));
    // RGBで膨らみを刻み、B/Aで縁を侵食する。粗い形から密度を削るため、空区間の外へは広がらない。
    float3 lobeWeights =
        lerp(float3(0.115, 0.054, 0.036), float3(0.205, 0.042, 0.026), cumulus);
    float detail = CloudShapeTuning.y;
    float shape = background.shape - dot(1 - noise.rgb, lobeWeights) * background.profile * detail;
    // 雲底では細い隙間が残る向きに高周波のWorleyを反転する。
    float2 edgeNoise = lerp(1 - noise.ba, noise.ab, baseFray);
    float erosion = dot(edgeNoise, float2(0.21, 0.23)) * detail;
    return cumulusDensity(shape, background.threshold, erosion, cumulus);
}

float detailCloudBody(CloudBodySample background, float footprint)
{
    if (background.density <= 0 || CloudShapeTuning.y <= 0)
        return background.density;
    footprint *= max(1, CloudShapeTuning.x);
    // 雲底に近いほど反転した別帯域を使う。移行中も縁に凹凸が残る。
    float baseFray = cumulusAmount() * (1 - smoothstep(0.04, 0.33, background.localHeight));
    if (CUMULUS_CLOUDS)
        return detailCumulusCloud(background, footprint, baseFray);

    // 表面の凹凸と薄い縁を別の周波数で削り、密度の高い中心を残す。
    float3 detailPosition = background.shapePosition - float3(0, Wind.z, 0);
    float3 noise = DetailNoise.SampleLevel(LinearWrap, detailPosition * 0.0022 + background.warp * 0.17,
                                          cloudDetailLod(footprint, 0.0022)).rgb;
    float erosion = dot(lerp(1 - noise, noise.gbr, baseFray), float3(0.625, 0.25, 0.125));
    // 画素内で細部が平均化されるときは、低周波側のGで代用して別サンプルを省く。
    float fineBlend = smoothstep(22, 85, footprint);
    float fine = noise.g;
    [branch]
    if (fineBlend < 1)
    {
        float fineNoise = DetailNoise.SampleLevel(LinearWrap, detailPosition * 0.0067,
                                                  cloudDetailLod(footprint, 0.0067)).g;
        fine = lerp(fineNoise, fine, fineBlend);
    }
    float edgeErosion = (erosion * 0.38 + (1 - fine) * 0.10) * (1 - background.density * 0.55);
    return remap01(background.density, edgeErosion * CloudShapeTuning.y, 1);
}

float detailBackgroundCloud(BackgroundCloudSample background, float footprint = 0)
{
    if (background.density <= 0 || CloudShapeTuning.y <= 0)
        return background.density;

    float density = detailCloudBody(background.body, footprint);
    // 細部の侵食は密度を下げるだけ。本体を上回り得る頭だけ追加で細部を読む。
    [branch]
    if (background.head.density * background.headWeight > density)
    {
        float head = detailCloudBody(background.head, footprint);
        density = max(density, head * background.headWeight);
    }
    return density * (1 - background.dilution) + background.carriedDensity;
}

// 風下の肩から曲線に沿って上流の雲体を参照し、運ばれた滴の消散を近似する。
// 供給元は元の雲体だけなので、すでに運ばれた密度を再び足すことはない。
BackgroundCloudSample backgroundCloudShape(float3 p, float h)
{
    CloudWindMargin margin;
    BackgroundCloudSample cloud = unmixedCloudShape(p, h, margin);
    float mixing = margin.exposure * (1 - smoothstep(0.20, 0.78, cloud.density));
    [branch]
    if (mixing > 0)
    {
        float2 wind = WeatherEffects.yz;
        float2 downwind = wind / max(length(wind), 0.0001);
        float2 crosswind = float2(-downwind.y, downwind.x);
        float3 material = p - float3(Wind.x, 0, Wind.y);
        // 低周波の既存ノイズを風と少し違う速さで運び、房ごとに曲率を変える。
        float3 flowUV = material * float3(0.00020, 0.00035, 0.00020);
        flowUV.xz -= 0.000035 * Wind.xy;
        float2 eddy = BaseNoise.SampleLevel(LinearWrap, flowUV + float3(0.24, 0.47, 0.13), 1).ba;
        float roll = smoothstep(0.20, 0.76, eddy.x);
        // 軌道に沿う距離は一次、下降と横方向のずれは二次で増える。
        float progress = 0.18 + 0.82 * mixing;
        float travel = margin.reach * lerp(2.40, 3.65, roll) * progress;
        float drop = travel * progress * lerp(0.26, 0.61, roll);
        float side = (eddy.y - 0.5) * 0.5 * travel * progress;
        float3 source = p;
        source.xz -= downwind * travel + crosswind * side;
        source.y += drop;
        float sourceH = (altitude(source) - CloudLayer.x) / CloudLayer.y;

        // 本当に雲水がある場所からだけ運ぶ。希薄な先端では輸送幅に合うミップを使う。
        float water = 0;
        if (sourceH > 0 && sourceH < 1)
        {
            float3 donorMaterial = source - float3(Wind.x, 0, Wind.y);
            float convection = cumulusAmount();
            bendConvectiveTop(donorMaterial, sourceH, convection);
            CloudBodySample donor = cloudBodyShape(donorMaterial, sourceH,
                                                   cloudPlacement(donorMaterial.xz), convection);
            water = detailCloudBody(donor, max(1, 0.23 * travel));
        }
        // 湿った空気中では雲水が長く残る。混合の重みの合計は1以下。
        cloud.dilution = 0.72 * mixing;
        float retention = exp2(-progress * lerp(1.95, 1.35, saturate(Weather.z)));
        cloud.carriedDensity = cloud.dilution * water * retention;
        cloud.density = cloud.density * (1 - cloud.dilution) + cloud.carriedDensity;
    }
    return cloud;
}

BackgroundCloudSample sampleBackgroundCloud(float3 p, float h)
{
    // 日照で発達する肩だけに、移流する小さな3D変位を与える。輪郭、雲影、
    // 近景と遠景が同じ場所を読むので、房の細かな凹凸も視点に固定されない。
    float growth = cumulusAmount() * smoothstep(0.10, 0.37, h);
    if (growth > 0 && h < 1 && CloudLayer.z > 0 && CloudLayer.w > 0)
    {
        float scale = CloudShapeTuning.x;
        float3 material = p - float3(Wind.x, 0, Wind.y);
        // 周期内4セルの変位場。標準サイズで格子間隔は約258 m、各成分の変位は最大±50 m。
        float3 uvw = material * (0.00097 * scale) + float3(0.39, 0.17, 0.57);
        float3 offset = CloudWarpVolume.SampleLevel(LinearWrap, uvw, 0).rgb - 0.5;
        float taper = 1 - smoothstep(0.89, 1, h);
        // Cumulus は近くの淡い房が多く、小さい変位で肩の細部が現れる。
        float amplitude = CUMULUS_CLOUDS ? 65.0 : 100.0;
        p += offset * (amplitude * growth * taper / scale);
        h = (altitude(p) - CloudLayer.x) / CloudLayer.y;
    }

    [branch]
    if (NearCloudParams.y > 0)
    {
        float3 offset = p - CameraTime.xyz;
        float radius = NearCloudParams.w;
        [branch]
        if (dot(offset, offset) < radius * radius)
        {
            // 風に沿う3D変位を近くで強く使い、遠方の雲底・雲頂へ滑らかにつなぐ。
            float strength = NearCloudParams.y * (1 - smoothstep(720, radius, length(offset)));
            float3 advected = p - float3(Wind.x, 0, Wind.y);
            float3 warp = CloudWarpVolume.SampleLevel(
                LinearWrap, advected * 0.00023 + float3(0.13, 0.31, 0.61), 0).rgb - 0.5;
            p += warp * float3(240, 820, 240) * strength * lerp(1, 0.45, Weather.y);
            h = (altitude(p) - CloudLayer.x) / CloudLayer.y;
        }
    }
    return backgroundCloudShape(p, h);
}

// 視線・太陽遮蔽・雲影に共通の背景雲海＋局所形状を返す。
float2 cloudDensitySample(float3 p, bool detail, float footprint = 0)
{
    if (Controls.w < 0.5)
        return 0;
    float height = altitude(p);
    float h = (height - CloudLayer.x) / CloudLayer.y;
    BackgroundCloudSample background = sampleBackgroundCloud(p, h);
    float density = detail ? detailBackgroundCloud(background, footprint) : background.density;
    return compositeFormationDensity(p, height, h, detail, density * CloudLayer.w);
}

float cloudDensity(float3 p, bool detail, float footprint = 0)
{
    return cloudDensitySample(p, detail, footprint).x;
}

float cloudExtinction()
{
    // 密度が1のときの消散係数[1/m]。区間長を掛けると光学的厚さになる。
    return 0.006;
}

#include "cloud_layers.hlsli"

float cloudShadowRayLength()
{
    return min((FormationLayer.w - FormationLayer.z) / max(SunDirection.y, 0.02), 85000);
}

float cloudShadow(float3 p)
{
    if (Controls.z < 0.5 || Controls.w < 0.5 || SunDirection.y <= 0.015)
        return 1;

    // 光線方向の距離を基準にする。雲より上の受光点には影が掛からない。
    // 受光点を太陽方向へたどってマップの基準平面に投影する。
    // receiver は ShadowCS と共通の深度で、太陽側の始点が 0、基準平面が 1。
    float projectionDistance = (FormationLayer.z - p.y) / max(SunDirection.y, 0.02);
    float rayLength = cloudShadowRayLength();
    float receiver = 1 + projectionDistance / rayLength;
    if (receiver <= 0)
        return 1;
    float2 projected = p.xz + SunDirection.xz * projectionDistance;
    // キャッシュ生成時からの風による移動量を引き、生成時の座標で参照する。
    projected -= CloudPerformance.xy;
    float2 uv = (projected - ShadowRegion.xy) / ShadowRegion.z + 0.5;
    float border = saturate(min(min(uv.x, uv.y), min(1 - uv.x, 1 - uv.y)) * 25);
    float texelSize = ShadowRegion.z / ShadowRegion.w;
    // 雲から遠いほど太陽の見かけの大きさによる半影が広がる。m からテクセル数へ換算する。
    float penumbra = max(FormationLayer.x - p.y, 0) * (0.0093 / SunDirection.y);
    float mip = clamp(log2(1.5 + penumbra / texelSize), 0, 5);
    float2 moments = CloudShadowMap.SampleLevel(LinearClamp, uv, mip);
    // Rは雲層全体の透過率。Gを復号すると遮蔽深度より太陽側で1に近づく。
    // 遮蔽物より地面側では R に近づく。範囲の端と地平線近くでは影を徐々に薄める。
    float visibility = saturate(moments.x + moments.y * exp(-CLOUD_SHADOW_EXPONENT * receiver));
    return lerp(1, visibility, border * smoothstep(0.015, 0.045, SunDirection.y));
}

float sampleTerrainShadow(Texture2D<float> shadow, float3 coord, float bias)
{
    float2 uv = coord.xy * float2(0.5, -0.5) + 0.5;
    if (any(uv <= 0) || any(uv >= 1) || coord.z <= 0 || coord.z >= 1)
        return 1;
    float value = 0;

    // 2048²の深度を3x3 PCFで比較する。小さなバイアスで自己遮蔽の縞を抑える。
    [unroll]
    for (int y = -1; y <= 1; y++)
        [unroll]
        for (int x = -1; x <= 1; x++)
            value += shadow.SampleCmpLevelZero(
                ShadowCompare, uv + float2(x, y) / 2048.0, coord.z - bias);

    return value / 9;
}

float terrainShadow(float3 p)
{
    float weight = 0;
    float3 coord = 0;
    if (WorldRendering.y > 0.5)
    {
        float4 nearClip = mul(float4(p, 1), NearLightViewProjection);
        coord = nearClip.xyz / nearClip.w;
        weight = (1 - smoothstep(0.79, 0.99, max(abs(coord.x), abs(coord.y))))
                 * smoothstep(0, 0.035, coord.z) * (1 - smoothstep(0.94, 1, coord.z));
    }
    float value = 1;
    [branch]
    if (weight < 1)
    {
        float4 farClip = mul(float4(p, 1), LightViewProjection);
        value = sampleTerrainShadow(TerrainShadow, farClip.xyz / farClip.w, 0.0004);
    }
    [branch]
    if (weight > 0)
        value = lerp(value, sampleTerrainShadow(NearTerrainShadow, coord, 0.000055), weight);
    return value;
}

struct AtmosphereResult
{
    // 散乱光は視点へ届くまでの減衰を含む。透過率は終点から持ち込む光に掛ける RGB の比率。
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
    // 直線上では視線と太陽の角度は一定。位相関数を求めてから各区間の積分へ入る。
    float cosine = dot(direction, SunDirection.xyz);
    float rp = rayleighPhase(cosine), mp = hg(cosine, 0.76);
    [loop]
    for (int i = 0; i < steps; i++)
    {
        // 区間の中点で密度を評価し、Beer–Lambert 則でこの区間だけの透過率を求める。
        float3 p = origin + direction * ((i + 0.5) * ds);
        float3 d = atmosphericDensity(altitude(p));
        float3 extinction = atmosphereExtinction(d);
        float3 segment = exp(-extinction * ds);
        // 太陽 → 中点の大気透過を LUT から取得し、位相を掛けて視線に入る光を求める。
        float3 sunT = sunTransmittance(p);
        float3 source =
            (BETA_R * d.x * rp + BETA_M * (d.y * Atmosphere.x * mp)) * SolarExposure.rgb * sunT;
        // 高次の散乱は等方的な補助項で近似する。
        // 直達光の減衰が強いほど補助項の係数を上げ、太陽が地平線下へ向かうと減らす。
        float3 multiple = (BETA_R * d.x + BETA_M * d.y * Atmosphere.x)
                          * (0.007 + 0.015 * (1 - sunT)) * SolarExposure.rgb
                          * saturate(SunDirection.y * 3 + 0.25);
        // 区間内の係数を一定とみなし、(1-exp(-sigma*ds))/sigma で積分する。
        // result.transmittance は視点 → 区間手前の積。寄与を足してからこの区間の透過率を掛ける。
        result.scattering +=
            result.transmittance * (source + multiple) * (1 - segment) / max(extinction, 1e-8);
        result.transmittance *= segment;
    }
    return result;
}

#endif
