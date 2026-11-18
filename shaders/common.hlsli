#ifndef CIRRUS_COMMON
#define CIRRUS_COMMON

#include "river_profile.hlsli"

// ワールド座標・距離の単位はm。地表の原点を y=0 とする球形の惑星を使う。
static const float PI = 3.14159265359;
static const float PLANET_RADIUS = 6360000.0;
static const float ATMOSPHERE_HEIGHT = 100000.0;
static const float CLOUD_SHADOW_EXPONENT = 10.0;
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
    float4 Checkerboard;      // x: 今回は半数を計算、y: 偶奇、z: 生バッファの幅
    float4 WorldRendering;    // x: exploration / reversed Z, y: near shadows, z: solar clock
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
Texture2D<float> NearTerrainShadow : register(t26);
Texture2D<float4> GSurface : register(t27);
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

float2 cloudPlacement(float2 advectedXZ)
{
    return CloudMap.SampleLevel(LinearWrap, advectedXZ / 65536.0, 0);
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

struct BackgroundCloudSample
{
    float density;
    float3 shapePosition;
    float3 warp;
};

BackgroundCloudSample backgroundCloudShape(float3 p, float h)
{
    BackgroundCloudSample result = (BackgroundCloudSample)0;
    if (h <= 0 || h >= 1)
        return result;

    // 天候デモと同じ65.536 km周期の場で、雲量と鉛直方向の雲種を決める。
    float3 shapePosition = p - float3(Wind.x, 0, Wind.y);
    float3 regional = WeatherMap.SampleLevel(LinearWrap, shapePosition.xz / 65536.0, 0).rgb;
    float coverage = saturate(CloudLayer.z + (regional.r - 0.5) * 1.05);
    float type = saturate(Weather.x + (regional.b - 0.5) * 0.32);
    float bottom = smoothstep(0.0, 0.055, h);
    float top = 1 - smoothstep(lerp(0.20, 0.38, type), lerp(0.46, 0.98, type), h);
    float profile = bottom * top;
    float threshold = 1 - coverage;
    // 大きな形の値は最大1。高度プロファイルだけで空と判定できる点は3Dノイズを読まない。
    if (profile <= threshold)
        return result;

    shapePosition.xz += float2(h * h * 480.0, -h * 220.0);
    shapePosition.y *= lerp(1.5, 0.9, type);
    // 低周波の変位で大きな雲塊を曲げ、中間スケールのWorleyで大小の膨らみを付ける。
    float3 warp = BaseNoise.SampleLevel(LinearWrap, shapePosition * 0.00018 + 0.37, 1).gba - 0.5;
    shapePosition += warp * 340.0;
    float base = BaseNoise.SampleLevel(LinearWrap,
                                      shapePosition * 0.000115 + float3(0.13, 0.27, 0.38), 0).r;
    float3 billows = DetailNoise.SampleLevel(LinearWrap, shapePosition * 0.00075, 0).rgb;
    float cells = dot(billows, float3(0.55, 0.30, 0.15));
    float shape = saturate(base + (cells - 0.43) * 0.65) * profile;
    result.density = saturate(remap01(shape, threshold, 1) * 2.1);
    result.shapePosition = shapePosition;
    result.warp = warp;
    return result;
}

float detailBackgroundCloud(BackgroundCloudSample background)
{
    if (background.density <= 0)
        return 0;
    // 表面の凹凸と薄い縁を別の周波数で削り、密度の高い中心を残す。
    float3 detailPosition = background.shapePosition - float3(0, Wind.z, 0);
    float3 noise = DetailNoise.SampleLevel(LinearWrap,
                                          detailPosition * 0.0022 + background.warp * 0.17, 0).rgb;
    float erosion = dot(1 - noise, float3(0.625, 0.25, 0.125));
    float fine = DetailNoise.SampleLevel(LinearWrap, detailPosition * 0.0067, 0).g;
    float edgeErosion = (erosion * 0.38 + (1 - fine) * 0.10) * (1 - background.density * 0.55);
    return remap01(background.density, edgeErosion, 1);
}

// 視線・太陽遮蔽・雲影に共通の背景雲海＋局所形状を返す。
float2 cloudDensitySample(float3 p, bool detail)
{
    if (Controls.w < 0.5)
        return 0;
    float height = altitude(p);
    float h = (height - CloudLayer.x) / CloudLayer.y;
    BackgroundCloudSample background = backgroundCloudShape(p, h);
    float density = detail ? detailBackgroundCloud(background) : background.density;
    return compositeFormationDensity(p, height, h, detail, density * CloudLayer.w);
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
