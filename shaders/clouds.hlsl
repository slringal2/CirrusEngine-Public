#include "common.hlsli"

#ifndef CIRRUS_CLASSIC_FAST
#define CIRRUS_CLASSIC_FAST 0
#endif

static const bool CLASSIC_FAST = CIRRUS_CLASSIC_FAST != 0;
static const float MAX_CLOUD_DISTANCE = 100000;
Texture3D<float4> NearCloudLighting : register(t28);
Texture3D<float4> CloudOcclusion : register(t29);
Texture2D<uint> PreviousReconstruction : register(t30);
RWTexture3D<float4> CloudOcclusionOutput : register(u0);
RWTexture3D<float4> NearCloudOutput : register(u0);
RWTexture3D<float> NearCloudMomentOutput : register(u1);
RWTexture2D<float2> ShadowOutput : register(u0);
RWTexture2D<float4> CloudOutput : register(u0);
RWTexture2D<float2> MetadataOutput : register(u1);
RWTexture2D<uint> ReconstructionOutput : register(u2);

// Bauer (2019), slide 35. 太陽側から透過率で重み付けした遮蔽深度を作る。
[numthreads(8, 8, 1)]
void ShadowCS(uint3 id : SV_DispatchThreadID)
{
    uint w, h;
    ShadowOutput.GetDimensions(w, h);
    if (any(id.xy >= uint2(w, h)))
        return;
    if (SunDirection.y <= 0.015 || Controls.z < 0.5 || Controls.w < 0.5)
    {
        ShadowOutput[id.xy] = float2(1, 0);
        return;
    }
    float2 uv = (id.xy + 0.5) / float2(w, h);
    float2 xz = ShadowRegion.xy + (uv - 0.5) * ShadowRegion.z;
    // テクセルは雲影の基準平面上の XZ。そこから太陽側へ戻した点を積分の始点にする。
    float distance = cloudShadowRayLength();
    float3 origin = float3(xz.x, FormationLayer.z, xz.y) + SunDirection.xyz * distance;
    // 高い局所雲が存在し得る上層を最大 24 区間、通常の雲海側を 40 区間に分ける。
    float lower = min(distance, (CloudLayer.x + CloudLayer.y - FormationLayer.z)
                               / max(SunDirection.y, 0.02));
    float upper = distance - lower;
    int upperSteps = upper > 1 ? 24 : 0;
    float transmittance = 1;
    float shadowDepth = distance;

    [loop]
    for (int i = 0; i < upperSteps + 40; i++)
    {
        float ds = i < upperSteps ? upper / 24 : lower / 40;
        float t = i < upperSteps ? (i + 0.5) * ds : upper + (i - upperSteps + 0.5) * ds;
        float density = cloudDensity(origin - SunDirection.xyz * t, true);
        if (density <= 0.0001)
            continue;

        // 最初の遮蔽点で始め、Tが高い間は奥へ更新する。厚い雲を抜けると更新が弱くなる。
        // 累積透過率の 4 乗で深度を更新するため、不透明になるほど手前の情報が残る。
        if (transmittance == 1)
            shadowDepth = t;
        transmittance *= exp(-density * cloudExtinction() * ds);
        float tSquared = transmittance * transmittance;
        shadowDepth = lerp(shadowDepth, t, tSquared * tSquared);
        if (transmittance < 0.001)
            break;
    }

    // 半透明の雲を保つため透過率も保持し、指数値は遮蔽量で重み付けしてから濾過する。
    // R に層全体の透過率、G に遮蔽量 × 指数化深度を保存し、cloudShadow() で一緒に読む。
    float encodedDepth = exp(CLOUD_SHADOW_EXPONENT * shadowDepth / distance);
    ShadowOutput[id.xy] = float2(transmittance, (1 - transmittance) * encodedDepth);
}

// 太陽方向の二次レイで自己遮蔽を評価する。Cumulusはレイの終点から先を雲影マップで補う。
float lightOpticalDepth(float3 p)
{
    if (SunDirection.y <= 0)
        return 0;
    float height = altitude(p);
    float distanceLimit = CUMULUS_CLOUDS ? lerp(1250, 5000, Weather.x) : 20000;
    float distance = min((FormationLayer.y - height) / max(SunDirection.y, 0.05), distanceLimit);
    distance = max(distance, 0);
    float tau = 0;
    float begin = 0;
    // 自己遮蔽は 35 m の細かい区間から始め、遠方へ進むたびに区間長を 1.65 倍にする。
    float stepLength = 35;
    int steps = (int)RenderSize.w;

    [loop]
    for (int i = 0; i < steps; i++)
    {
        float end = min(distance, begin + stepLength);
        float sampleDistance = 0.5 * (begin + end);
        float3 samplePosition = p + SunDirection.xyz * sampleDistance;
        if (!CUMULUS_CLOUDS)
        {
            // Classicは太陽方向を軸に位置をずらし、離れた雲塊の遮蔽も拾う。
            float3 cone = float3(sin(i * 2.39996), cos(i * 2.39996), sin(i * 1.3))
                          * (sampleDistance * 0.006);
            samplePosition += cone;
        }
        tau += cloudDensity(samplePosition, CUMULUS_CLOUDS || i < 6)
               * cloudExtinction() * (end - begin);
        begin = end;
        stepLength *= 1.65;
        if (begin >= distance || tau > (CUMULUS_CLOUDS ? 14 : 18))
            break;
    }

    if (CUMULUS_CLOUDS)
    {
        // 透過率を光学的厚さに変換する。exp(-tau) は近傍と遠方の透過率の積になる。
        float distantVisibility = cloudShadow(p + SunDirection.xyz * begin);
        tau -= log(max(distantVisibility, 0.0001));
    }
    return tau;
}

float classicSkyVisibility(float3 p)
{
    // 上に重なる雲の密度で天空光を減衰させる。直接計算とキャッシュ生成で同じ式を使う。
    float upDensity = cloudDensity(p + float3(0, 120, 0), false) * 120
                      + cloudDensity(p + float3(0, 360, 0), false) * 240
                      + cloudDensity(p + float3(0, 900, 0), false) * 540;
    return exp(-upDensity * cloudExtinction() * 0.6);
}

float2 cloudPhases(float mu)
{
    float single = CUMULUS_CLOUDS ? hg(mu, 0.80) : 0.85 * hg(mu, 0.70) + 0.15 * hg(mu, -0.20);
    float broad = CUMULUS_CLOUDS ? hg(mu, 0.80 * (2.0 / 3.0))
                                  : 0.85 * hg(mu, 0.35) + 0.15 * hg(mu, -0.10);
    return float2(single, broad);
}

float3 shadeCloud(float3 p, float2 cloud, float tau, float skyVisibility, float2 phases,
                  float3 skyAmbient)
{
    float density = cloud.x, h = cloud.y;
    float3 sunlight = SolarExposure.rgb * sunTransmittance(p);
    float3 lighting;
    if (CUMULUS_CLOUDS)
    {
        float backScatter = remap01(density * cloudExtinction(), 0.0015, 0.012) / PI;
        float single = max(phases.x, backScatter) * exp(-tau);
        float multiple = 0.53 * max(phases.y, backScatter * 0.36) * exp(-tau * 0.35);
        float3 ambient = skyAmbient * lerp(0.19, 0.86, exp(-tau * 0.28))
                         * lerp(1, 0.52, Weather.y);
        lighting = sunlight * (single + multiple) + ambient;
    }
    else
    {
        float single = phases.x * exp(-tau);
        float multiple = 0.32 * phases.y * exp(-tau * 0.45)
                         + 0.18 / (4 * PI) * exp(-tau * 0.12);
        float powder = 1 - exp(-density * 4);
        float3 ambient = lerp(float3(0.08, 0.11, 0.17), float3(0.38, 0.51, 0.70), h)
                         * (0.07 + 0.93 * saturate(SunDirection.y * 3 + 0.10));
        ambient *= (0.12 + 0.88 * skyVisibility) * lerp(1, 0.53, Weather.y);
        lighting = sunlight * (single + multiple) * (0.85 + 0.15 * powder) + ambient;
    }
    // 直射が届きにくい雲にも、周りから多重散乱した光を加える。
    float daylight = smoothstep(-0.04, 0.22, SunDirection.y);
    float fill = (1 - exp(-tau * 0.25)) * daylight * lerp(1, 0.62, Weather.y);
    lighting += float3(0.12, 0.135, 0.155) * fill;
    return lighting + lightningIrradiance(p) * (0.3 + 0.7 * h);
}

float2 nearSliceDepth(uint z, uint slices)
{
    float2 f = float2(z, z + 1) / slices;
    return NearCloudParams.x * f * f;
}

// 視錐台の各セルに、消散で割った散乱光と単位距離あたりの消散を保存する。
[numthreads(4, 4, 4)]
void LightNearCloudCS(uint3 id : SV_DispatchThreadID)
{
    uint width, height, slices;
    NearCloudOutput.GetDimensions(width, height, slices);
    if (any(id >= uint3(width, height, slices)))
        return;
    float2 uv = (id.xy + 0.5) / float2(width, height);
    float3 ray = worldRay(uv);
    float2 depths = nearSliceDepth(id.z, slices);
    float distance = (depths.x + depths.y) * 0.5 / viewDepthCosine(ray);
    float3 p = CameraTime.xyz + ray * distance;
    float2 cloud = cloudDensitySample(p, true);
    if (cloud.x < 0.001)
    {
        NearCloudOutput[id] = 0;
        return;
    }
    float tau = lightOpticalDepth(p);
    float skyVisibility = CUMULUS_CLOUDS ? 1 : classicSkyVisibility(p);
    float3 skyAmbient = CUMULUS_CLOUDS ? SkyAmbient.Load(int3(0, 0, 0)).rgb : 0;
    float2 phases = cloudPhases(dot(ray, SunDirection.xyz));
    float3 light = shadeCloud(p, cloud, tau, skyVisibility, phases, skyAmbient);
    NearCloudOutput[id] = float4(light, cloud.x * cloudExtinction());
}

// 視点側から各列を積分し、各スライス奥面での光・透過率・距離モーメントを累積する。
[numthreads(8, 8, 1)]
void IntegrateNearCloudCS(uint3 id : SV_DispatchThreadID)
{
    uint width, height, slices;
    NearCloudOutput.GetDimensions(width, height, slices);
    if (any(id.xy >= uint2(width, height)))
        return;
    float2 uv = (id.xy + 0.5) / float2(width, height);
    float inverseCosine = 1 / viewDepthCosine(worldRay(uv));
    float3 radiance = 0;
    float T = 1, moment = 0;
    [loop]
    for (uint z = 0; z < slices; ++z)
    {
        float2 depths = nearSliceDepth(z, slices);
        float4 medium = NearCloudLighting.Load(int4(id.xy, z, 0));
        float interval = (depths.y - depths.x) * inverseCosine;
        float segmentT = exp(-medium.a * interval);
        float weight = T * (1 - segmentT);
        radiance += weight * medium.rgb;
        moment += weight * (depths.x + depths.y) * 0.5;
        T *= segmentT;
        NearCloudOutput[uint3(id.xy, z)] = float4(radiance, T);
        NearCloudMomentOutput[uint3(id.xy, z)] = moment;
    }
}

float3 scaleOcclusionForVariance(float3 values)
{
    // 太陽側の光学的厚さ、天空光の可視性、密度のばらつきを一つの指標にまとめる。
    return values * float3(1, 4, 2);
}

[numthreads(4, 4, 4)]
void CloudOcclusionCS(uint3 id : SV_DispatchThreadID)
{
    uint3 size;
    CloudOcclusionOutput.GetDimensions(size.x, size.y, size.z);
    if (any(id >= size))
        return;

    float3 uvw = (id + 0.5) / float3(size);
    float2 xz = CloudOcclusionRegion.xy + Wind.xy + (uvw.xz - 0.5) * CloudOcclusionRegion.z;
    float height = CloudLayer.x + uvw.y * CloudLayer.y;
    // 高度の逆変換。planetCenter は探索カメラに追従するため、同じ曲率を使う。
    float2 radial = xz - planetCenter().xz;
    float radialSquared = dot(radial, radial);
    float radius = PLANET_RADIUS + height;
    float y = height - radialSquared / (radius + sqrt(max(radius * radius - radialSquared, 0)));
    float3 p = float3(xz.x, y, xz.y);
    float density = cloudDensity(p, true);
    if (density < 0.12)
    {
        // 空や薄い雲の近くを補間した結果は、分散の条件で直接計算へ戻す。
        CloudOcclusionOutput[id] = float4(0, 0, 0, 16);
        return;
    }

    float3 values = float3(lightOpticalDepth(p), classicSkyVisibility(p), density);
    float3 scaled = scaleOcclusionForVariance(values);
    CloudOcclusionOutput[id] = float4(values, dot(scaled, scaled));
}

bool sharedCloudOcclusion(float3 p, float h, float density, out float2 visibility)
{
    visibility = 0;
    float2 xz = (p.xz - Wind.xy - CloudOcclusionRegion.xy) / CloudOcclusionRegion.z + 0.5;
    if (any(xz < 0.02) || any(xz > 0.98))
        return false;

    float4 cached = CloudOcclusion.SampleLevel(LinearClamp, float3(xz.x, h, xz.y), 0);
    float3 scaled = scaleOcclusionForVariance(cached.xyz);
    // trilinear(E[x²]) - trilinear(E[x])² が小さく、密度も近いときだけ共有する。
    float variance = max(cached.w - dot(scaled, scaled), 0);
    float tolerance = 0.18 + 0.012 * min(cached.x, 10);
    if (variance > tolerance * tolerance
        || abs(cached.z - density) > max(0.035, density * 0.15))
        return false;
    visibility = cached.xy;
    return true;
}

struct CloudRayResult
{
    // color.rgb は HDR 散乱光、color.a は残存透過率。metadata.xy は雲とシーンの距離 [m]。
    float4 color;
    float2 metadata;
};

float2 cloudLayerRoots(float3 ray, float shellHeight)
{
    float3 origin = CameraTime.xyz - planetCenter();
    float y = CameraTime.y;
    float b = dot(origin, ray);
    // 惑星半径の二乗同士を引くと、雲層の境界を横切るときに精度を失う。
    float c = dot(origin.xz, origin.xz)
              + (y - shellHeight) * (2 * PLANET_RADIUS + y + shellHeight);
    float discriminant = b * b - c;
    if (discriminant < 0)
        return float2(-1, -1);
    float root = sqrt(discriminant);
    float farRoot = -b - (b >= 0 ? root : -root);
    float other = abs(farRoot) > 0.0001 ? c / farRoot : -b;
    return float2(min(farRoot, other), max(farRoot, other));
}

// 地形と視錐台の奥面で切った遠景雲の区間。
float2 cloudSegment(float3 ray, float scene)
{
    float margin = 430 * NearCloudParams.y;
    float2 outer = cloudLayerRoots(ray, CloudLayer.x + CloudLayer.y + margin);
    float2 inner = cloudLayerRoots(ray, CloudLayer.x - margin);
    float firstDistance = nearCloudRayEnd(ray);
    float lastDistance = min(scene, MAX_CLOUD_DISTANCE);
    float start = max(outer.x, firstDistance), end = min(outer.y, lastDistance);
    if (inner.y > inner.x)
    {
        // 内球に入る手前と、反対側で雲層に戻る区間の両方を候補に残す。
        float before = min(end, inner.x);
        float after = max(start, inner.y);
        if (before <= start)
            start = after;
        else if (after >= end)
            end = before;
    }
    bool hit = end > start;
    [loop]
    for (int i = 0; i < (int)FormationControls.x; ++i)
    {
        if (Formations[i].shape.y <= 0)
            continue;
        float2 extra = formationRayInterval(CameraTime.xyz, ray, Formations[i]);
        extra.x = max(extra.x, firstDistance);
        extra.y = min(extra.y, lastDistance);
        if (extra.y > extra.x)
        {
            start = hit ? min(start, extra.x) : extra.x;
            end = hit ? max(end, extra.y) : extra.y;
            hit = true;
        }
    }
    return float2(start, end);
}

float coarseCloudStep(float3 p, out float height, out float h, out BackgroundCloudSample background)
{
    height = altitude(p);
    h = (height - CloudLayer.x) / CloudLayer.y;
    background = sampleBackgroundCloud(p, h);
    float density = background.density * CloudLayer.w;
    return compositeFormationDensity(p, height, h, false, density).x;
}

// 通常描画と、履歴が使えない画素の修復で同じ積分を使う。
CloudRayResult traceCloudRay(uint2 pixel)
{
    float2 uv = (pixel + 0.5) / RenderSize.xy;
    float3 ray = worldRay(uv);
    float scene = sceneDistance(uv);
    CloudRayResult result;
    // 雲がない画素は散乱光 0、透過率 1。背景色がそのまま通る初期値。
    result.color = float4(0, 0, 0, 1);
    result.metadata = float2(Atmosphere.z, scene);

    // 雲底・雲頂の球面と、入道雲や渦の境界に当たる範囲をまとめる。
    // 100 km とシーン深度の手前で積分する。歩行シーンの深度には川面も含まれる。
    float2 interval = cloudSegment(ray, scene);
    float start = interval.x, end = interval.y;
    if (end <= start || Controls.w < 0.5)
    {
        return result;
    }

    int distantSteps = (int)RenderSize.z;
    // 視錐台のすぐ先も小さな歩幅で進み、近い雲塊から遠景へつなぐ。
    bool nearView = NearCloudParams.x > 0 || NearCloudParams.y > 0;
    float fineDistance = nearView ? max(0, min(end, NearCloudParams.w) - start) : 0;
    int fineSteps = (int)ceil(fineDistance / 40);
    float fineStepLength = fineDistance / max(fineSteps, 1);
    int steps = distantSteps + fineSteps;
    float emptyStep = nearView ? 175 : clamp(5 * (end - start) / distantSteps, 175, 850);

    // 雲と同じ高度では、地形深度が跳ぶと手前のサンプル位置まで変わり、地平線に帯が出る。
    // この視点では距離に応じて歩幅を広げ、地形や雲層の端で止まるまで同じ間隔で進む。
    float growthStart = max(max(start, NearCloudParams.w), 1);
    float minStepGrowth = nearView
        ? exp2(log2(MAX_CLOUD_DISTANCE / growthStart) / distantSteps) - 1 : 0;
    // Fastは2×2内で区間の採取位置をそろえ、別フレームで描いた画素間の差を抑える。
    // 境界に近い位置を避け、位相更新や修復でも同じ位置を読む。
    float jitter = CLASSIC_FAST ? lerp(0.25, 0.75, hash12(pixel >> 1))
                                : frac(hash12(pixel) + Wind.w * 0.61803398875);

    // T はカメラから現在位置まで残った光の割合。radiance は蓄積した散乱光。
    float T = 1;
    float3 radiance = 0;
    float distanceMoment = 0, weightSum = 0;
    float mu = dot(ray, SunDirection.xyz);
    // 太陽円盤は背景よりずっと明るいので、その付近では透過率をさらに追う。
    // 通常は T < 0.005 で打ち切り、太陽方向に近い視線は 0.00005 まで積分する。
    float transmittanceLimit = mu > 0.9996 ? 0.00005 : 0.005;
    float2 phases = cloudPhases(mu);
    float3 skyAmbient = CUMULUS_CLOUDS ? SkyAmbient.Load(int3(0, 0, 0)).rgb : 0;
    float cachedTau = 0, cachedSkyVisibility = 1, cachedDensity = 0, cachedDistance = -1e9;
    bool haveLighting = false, cachedFromVolume = false;
    bool shareAcrossRays = CLASSIC_FAST && CloudOcclusionRegion.w > 0.5 && mu < 0.96;
    int refinement = 0;
    float cursor = start;

    [loop]
    for (int i = 0; i < steps && cursor < end; i++)
    {
        // 区間を同じ予算内で最後まで積分できる歩幅を下限にする。
        bool fineStep = i < fineSteps;
        float remainingDistance = end - cursor;
        float minStep = nearView ? cursor * minStepGrowth : remainingDistance / (steps - i);
        minStep = min(minStep, remainingDistance);
        float distanceScale = lerp(0.60, 1, saturate(cursor / 18000));
        float baseStep = emptyStep * distanceScale;
        float ds = fineStep ? min(fineStepLength, remainingDistance)
                            : min(remainingDistance, max(minStep, baseStep * exp2(-refinement)));
        float t = cursor + (fineStep ? 0.5 : jitter) * ds;
        float3 p = CameraTime.xyz + ray * t;
        float height, backgroundHeight;
        BackgroundCloudSample background;
        float coarse = coarseCloudStep(p, height, backgroundHeight, background);

        // Bauer (2019), slide 50. 粗い形状に当たった区間を同じ始点から最大3回二分する。
        [loop]
        while (!fineStep && coarse >= 0.001 && refinement < 3 && ds > minStep * 1.15)
        {
            refinement++;
            ds = max(minStep, ds * 0.5);
            t = cursor + jitter * ds;
            p = CameraTime.xyz + ray * t;
            coarse = coarseCloudStep(p, height, backgroundHeight, background);
        }
        cursor = fineStep && i + 1 == fineSteps ? start + fineDistance : cursor + ds;
        if (coarse < 0.001)
        {
            refinement = max(0, refinement - 1);
            haveLighting = false;
            continue;
        }
        // 粗い形状で読んだノイズ座標を使い、ここでは縁の侵食だけを追加する。
        float backgroundDensity = detailBackgroundCloud(background) * CloudLayer.w;
        float2 cloudSample = compositeFormationDensity(p, height, backgroundHeight, true,
                                                       backgroundDensity);
        float density = cloudSample.x;
        if (density < 0.001)
        {
            haveLighting = false;
            continue;
        }
        float reuseDistance = clamp(t * 2.4 / RenderSize.y, 20, 160);
        // 距離と密度の近い点では遮蔽を再利用する。Cumulusは奇数ステップでのみ再利用する。
        // 視線側の密度・透過率は区間ごとに求め、空の区間で照明のキャッシュを無効にする。
        bool allowSharedOcclusion = shareAcrossRays && t >= 1500 && density >= 0.12
                                    && backgroundHeight > 0.06 && backgroundHeight < 0.94;
        float densityTolerance =
            cachedFromVolume ? max(0.025, density * 0.12) : max(0.04, density * 0.2);
        bool reuseLighting = CloudPerformance.z > 0.5 && haveLighting
                             && (!CUMULUS_CLOUDS || (i & 1) != 0)
                             && (!cachedFromVolume || allowSharedOcclusion)
                             && t - cachedDistance < reuseDistance
                             && abs(density - cachedDensity) < densityTolerance;
        [branch]
        if (!reuseLighting)
        {
            float2 visibility = 0;
            cachedFromVolume = false;
            [branch]
            if (allowSharedOcclusion)
                cachedFromVolume = sharedCloudOcclusion(p, backgroundHeight, density, visibility);
            [branch]
            if (cachedFromVolume)
            {
                cachedTau = visibility.x;
                cachedSkyVisibility = visibility.y;
            }
            else
            {
                cachedTau = lightOpticalDepth(p);
                if (!CUMULUS_CLOUDS)
                    cachedSkyVisibility = classicSkyVisibility(p);
            }
            cachedDensity = density;
            cachedDistance = t;
            haveLighting = true;
        }
        float extinction = density * cloudExtinction();
        float3 lighting = shadeCloud(p, cloudSample, cachedTau, cachedSkyVisibility, phases,
                                      skyAmbient);

        // 前から後ろへ合成する。今回失われる透過光の割合を散乱光の重みにする。
        // attenuation はこの区間だけの透過率。T は視点から区間の手前までの累積透過率。
        float attenuation = exp(-extinction * ds);
        float weight = T * (1 - attenuation);
        radiance += weight * lighting;
        // 同じ重みで距離の平均も取る。明るさに依存しないため暗い雲にも代表距離が付く。
        distanceMoment += weight * t;
        weightSum += weight;
        T *= attenuation;
        if (T < transmittanceLimit)
            break;
    }

    // RGB は視点までの透過減衰を織り込んだ散乱光、A は背後の光に掛ける残存透過率 T。
    // meta.x の代表距離は時間方向の再投影と空気遠近の積分先に使う。
    result.color = float4(radiance, T);
    result.metadata =
        float2(weightSum > 0.0001 ? distanceMoment / weightSum : Atmosphere.z, scene);
    return result;
}

bool fourPhaseClouds()
{
    return CLASSIC_FAST && Checkerboard.x > 1.5;
}

int2 checkerboardOffset()
{
    int phase = (int)Checkerboard.y;
    return int2(phase & 1, phase >> 1);
}

[numthreads(8, 8, 1)]
void CloudCS(uint3 id : SV_DispatchThreadID)
{
    uint2 size = (uint2)(Checkerboard.x > 0.5 ? Checkerboard.zw : RenderSize.xy);
    if (any(id.xy >= size))
        return;
    uint2 pixel = id.xy;
    if (fourPhaseClouds())
        pixel = id.xy * 2 + (uint2)checkerboardOffset();
    else if (Checkerboard.x > 0.5)
        pixel.x = id.x * 2 + ((id.y + (uint)Checkerboard.y) & 1);
    // 奇数の幅や高さで最後にできる未使用セルも初期化する。
    if (any(pixel >= (uint2)RenderSize.xy))
    {
        CloudOutput[id.xy] = float4(0, 0, 0, 1);
        MetadataOutput[id.xy] = Atmosphere.zz;
        return;
    }
    CloudRayResult result = traceCloudRay(pixel);
    CloudOutput[id.xy] = result.color;
    MetadataOutput[id.xy] = result.metadata;
}

bool tracedPixel(int2 pixel)
{
    if (fourPhaseClouds())
        return all((pixel & 1) == checkerboardOffset());
    return Checkerboard.x < 0.5 || ((pixel.x + pixel.y) & 1) == (int)Checkerboard.y;
}

int2 rawPixel(int2 pixel)
{
    if (fourPhaseClouds())
        return pixel >> 1;
    return int2(Checkerboard.x > 0.5 ? pixel.x >> 1 : pixel.x, pixel.y);
}

[numthreads(8, 8, 1)]
void TemporalCS(uint3 id : SV_DispatchThreadID)
{
    if (any(id.xy >= (uint2)RenderSize.xy))
        return;
    int2 pixel = id.xy;
    float2 uv = (id.xy + 0.5) / RenderSize.xy;
    bool fourPhase = fourPhaseClouds();
    bool traced = tracedPixel(pixel);
    bool nearSun = false;
    float scene = sceneDistance(uv);
    float4 current = float4(0, 0, 0, 1);
    float2 meta = float2(Atmosphere.z, scene);
    if (!traced)
    {
        float3 ray = worldRay(uv);
        float2 interval = cloudSegment(ray, scene);
        nearSun = fourPhase && dot(ray, SunDirection.xyz) > 0.995;
        if (interval.y <= interval.x || Controls.w < 0.5)
        {
            CloudOutput[pixel] = current;
            MetadataOutput[pixel] = meta;
            ReconstructionOutput[pixel] = 3; // 地形遮蔽などで雲がないと解析的に確定。
            return;
        }
    }
    if (traced)
    {
        current = CloudTexture.Load(int3(rawPixel(pixel), 0));
        meta = CloudMetadata.Load(int3(rawPixel(pixel), 0));
    }

    float4 minimum = traced ? current : 1e10;
    float4 maximum = traced ? current : -1e10;
    bool haveBounds = traced;
    float4 neighbors = 0;
    float neighborWeight = 0, distanceMoment = 0, opacityWeight = 0;
    // 4相では未計算画素を囲む4点から距離を推定する。
    // 今回描いた画素は上下左右のサンプルを使い、履歴を片側の色だけで制限しない。
    int2 first = pixel - 1;
    if (fourPhase)
        first = traced ? pixel - 2 : pixel - ((pixel - checkerboardOffset()) & 1);
    int stride = fourPhase ? 2 : 1;
    [unroll]
    for (int y = 0; y < 3; ++y)
        [unroll]
        for (int x = 0; x < 3; ++x)
        {
            int offset = abs(x - 1) + abs(y - 1);
            if (fourPhase && (traced ? offset > 1 : (x == 2 || y == 2)))
                continue;
            int2 q = first + int2(x, y) * stride;
            if (any(q < 0) || any(q >= (int2)RenderSize.xy) || !tracedPixel(q))
                continue;
            float4 v = CloudTexture.Load(int3(rawPixel(q), 0));
            float2 m = CloudMetadata.Load(int3(rawPixel(q), 0));
            float w = Checkerboard.x > 0.5
                      ? exp(-abs(m.y - scene) / max(80, scene * 0.02)) : 1;
            if (w > 0.001)
            {
                haveBounds = true;
                minimum = min(minimum, v);
                maximum = max(maximum, v);
            }
            if (!traced && (fourPhase || offset == 1))
            {
                if (fourPhase)
                {
                    float2 spatial = saturate(1 - abs(float2(q - pixel)) * 0.5);
                    w *= spatial.x * spatial.y;
                }
                neighbors += v * w;
                neighborWeight += w;
                float opacity = (1 - v.a) * w;
                distanceMoment += m.x * opacity;
                opacityWeight += opacity;
            }
        }
    if (!traced && neighborWeight > 0.001)
    {
        current = neighbors / neighborWeight;
        meta.x = opacityWeight > 0.0001 ? distanceMoment / opacityWeight : Atmosphere.z;
    }
    // 4相では雲の縁や明暗差が大きい箇所、太陽円盤の近くも直接積分する。
    const float3 luminance = float3(0.2126, 0.7152, 0.0722);
    bool detailEdge = false;
    if (fourPhase && !traced && haveBounds)
    {
        float contrast = dot(maximum.rgb - minimum.rgb, luminance);
        detailEdge = maximum.a - minimum.a > 0.18
                     || (minimum.a < 0.92 && maximum.a > 0.99)
                     || contrast > 0.05 + 0.3 * dot(maximum.rgb, luminance);
    }
    if (!traced && (!haveBounds || neighborWeight <= 0.001 || nearSun || detailEdge))
    {
        CloudOutput[pixel] = current;
        MetadataOutput[pixel] = meta;
        ReconstructionOutput[pixel] = 2;
        return;
    }

    // 雲の代表位置を前フレームへ戻す。風の移動分も引いて同じ雲塊を対応させる。
    float3 world = previousCloudPosition(CameraTime.xyz + worldRay(uv) * meta.x);
    float4 previousClip = mul(float4(world, 1), PreviousViewProjection);
    float2 previousUV = previousClip.xy / max(previousClip.w, 0.001) * float2(0.5, -0.5) + 0.5;
    float valid = PreviousWind.w;
    if (previousClip.w <= 0 || any(previousUV < 0.002) || any(previousUV > 0.998))
        valid = 0;
    float2 oldMeta = HistoryMetadata.SampleLevel(LinearClamp, previousUV, 0);
    float expected = length(world - PreviousCamera.xyz);

    // 距離が合わない履歴や、前フレームでは地形の裏にあった履歴は捨てる。
    if (abs(oldMeta.x - expected) > max(900, expected * 0.1))
        valid = 0;
    if (oldMeta.y < expected - 200 && oldMeta.y < Atmosphere.z * 0.99)
        valid = 0;
    if (!traced)
    {
        if (neighborWeight <= 0.001)
            valid = 0;
        // 前回の距離を今の視線へ戻し、斜面や雲の端で誤った履歴を継がない。
        float3 oldPosition = PreviousCamera.xyz
                             + normalize(world - PreviousCamera.xyz) * oldMeta.x;
        oldPosition = currentCloudPosition(oldPosition);
        float4 clip = mul(float4(oldPosition, 1), ViewProjection);
        float2 projectedUV = clip.xy / max(clip.w, 0.001) * float2(0.5, -0.5) + 0.5;
        if (clip.w <= 0 || any(abs(projectedUV - uv) * RenderSize.xy > 1.5))
            valid = 0;
        float distance = dot(oldPosition - CameraTime.xyz, worldRay(uv));
        if (distance <= 0 || (distance > scene + 100 && oldMeta.x < Atmosphere.z * 0.99))
            valid = 0;
        if (valid > 0.5)
        {
            meta.x = min(distance, Atmosphere.z);
        }
    }

    float4 old = HistoryTexture.SampleLevel(LinearClamp, previousUV, 0);
    float4 clampedHistory = clamp(old, minimum, maximum);
    float historyWeight = Checkerboard.x > 0.5 ? min(PreviousWind.z, 0.8) : PreviousWind.z;
    uint age = 0;
    if (fourPhase && valid > 0.5)
    {
        int2 historyPixel = clamp(int2(previousUV * RenderSize.xy), 0, int2(RenderSize.xy) - 1);
        age = (PreviousReconstruction.Load(int3(historyPixel, 0)) >> 2) + 1;
        if (traced)
        {
            // 前回の更新から空いた時間に合わせ、古い明るさの残り方を調整する。
            historyWeight = pow(abs(historyWeight), (float)min(age, 4u));
        }
        else
        {
            // 位相ごとの色の範囲は履歴の採否に使う。有効な色を毎フレーム切り詰めると明滅する。
            float brightnessError = abs(dot(old.rgb - clampedHistory.rgb, luminance));
            float brightnessTolerance = 0.04 + 0.15 * dot(clampedHistory.rgb, luminance);
            if (age > 3 || abs(old.a - clampedHistory.a) > 0.06
                || brightnessError > brightnessTolerance)
                valid = 0;
        }
    }
    // 下位2bitは計算・履歴・修復・透明。履歴を採用したときは上位に経過フレーム数。
    ReconstructionOutput[pixel] = traced ? 0u : (valid > 0.5 ? (1u | (age << 2)) : 2u);
    float weight = valid * (traced ? historyWeight : 1);
    float4 history = fourPhase && !traced ? old : clampedHistory;
    CloudOutput[id.xy] = lerp(current, history, weight);
    MetadataOutput[id.xy] = meta;
}

// 履歴がない露出部分は空間補間で済ませず、そのフレームでレイマーチする。
// UAVと同じテクスチャをSRVに束縛せず、独立したR32_UINTマスクだけを読む。
[numthreads(8, 8, 1)]
void RepairCS(uint3 id : SV_DispatchThreadID)
{
    if (any(id.xy >= (uint2)RenderSize.xy))
        return;
    if ((CloudReconstruction.Load(int3(id.xy, 0)) & 3u) != 2u)
        return;
    CloudRayResult result = traceCloudRay(id.xy);
    CloudOutput[id.xy] = result.color;
    MetadataOutput[id.xy] = result.metadata;
}
