#include "common.hlsli"

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

struct CloudRayResult
{
    // color.rgb は HDR 散乱光、color.a は残存透過率。metadata.xy は雲とシーンの距離 [m]。
    float4 color;
    float2 metadata;
};

// 地形深度で切った雲層の区間。空間補間せずに「雲なし」を確定できる。
float2 cloudSegment(float3 ray, float scene)
{
    float2 outer =
        sphereIntersection(CameraTime.xyz, ray, PLANET_RADIUS + CloudLayer.x + CloudLayer.y);
    float2 inner = sphereIntersection(CameraTime.xyz, ray, PLANET_RADIUS + CloudLayer.x);
    float start = max(outer.x, 0), end = min(outer.y, scene);
    if (altitude(CameraTime.xyz) < CloudLayer.x)
        start = max(start, inner.y);
    else if (inner.x > 0)
        end = min(end, inner.x);
    bool hit = end > start;
    [loop]
    for (int i = 0; i < (int)FormationControls.x; ++i)
    {
        if (Formations[i].shape.y <= 0)
            continue;
        float2 extra = formationRayInterval(CameraTime.xyz, ray, Formations[i]);
        extra.x = max(extra.x, 0);
        extra.y = min(extra.y, min(scene, 100000.0));
        if (extra.y > extra.x)
        {
            start = hit ? min(start, extra.x) : extra.x;
            end = hit ? max(end, extra.y) : extra.y;
            hit = true;
        }
    }
    return float2(start, min(end, 100000.0));
}

float coarseCloudStep(float3 p, out float height, out float h, out BackgroundCloudSample background)
{
    height = altitude(p);
    h = (height - CloudLayer.x) / CloudLayer.y;
    background = backgroundCloudShape(p, h);
    return compositeFormationDensity(p, height, h, false, background.density * CloudLayer.w).x;
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

    int steps = (int)RenderSize.z;
    float emptyStep = clamp(5 * (end - start) / steps, 175, 850);
    // 同じピクセルでもフレームごとに区間内の採取位置をずらし、帯状の誤差を分散する。
    float jitter = frac(hash12(pixel) + Wind.w * 0.61803398875);

    // T はカメラから現在位置まで残った光の割合。radiance は蓄積した散乱光。
    float T = 1;
    float3 radiance = 0;
    float distanceMoment = 0, weightSum = 0;
    float mu = dot(ray, SunDirection.xyz);
    // 太陽円盤は背景よりずっと明るいので、その付近では透過率をさらに追う。
    // 通常は T < 0.005 で打ち切り、太陽方向に近い視線は 0.00005 まで積分する。
    float transmittanceLimit = mu > 0.9996 ? 0.00005 : 0.005;
    float phase = CUMULUS_CLOUDS ? hg(mu, 0.80) : 0.85 * hg(mu, 0.70) + 0.15 * hg(mu, -0.20);
    float broadPhase = CUMULUS_CLOUDS ? hg(mu, 0.80 * (2.0 / 3.0))
                                      : 0.85 * hg(mu, 0.35) + 0.15 * hg(mu, -0.10);
    float isotropicPhase = 1 / (4 * PI);
    float3 skyAmbient = CUMULUS_CLOUDS ? SkyAmbient.Load(int3(0, 0, 0)).rgb : 0;
    float cachedTau = 0, cachedSkyVisibility = 1, cachedDensity = 0, cachedDistance = -1e9;
    bool haveLighting = false;
    int refinement = 0;
    float cursor = start;

    [loop]
    for (int i = 0; i < steps && cursor < end; i++)
    {
        // 区間を同じ予算内で最後まで積分できる歩幅を下限にする。
        float remainingDistance = end - cursor;
        float minStep = remainingDistance / (steps - i);
        float distanceScale = lerp(0.60, 1, saturate(cursor / 18000));
        float baseStep = emptyStep * distanceScale;
        float ds = min(remainingDistance, max(minStep, baseStep * exp2(-refinement)));
        float t = cursor + jitter * ds;
        float3 p = CameraTime.xyz + ray * t;
        float height, backgroundHeight;
        BackgroundCloudSample background;
        float coarse = coarseCloudStep(p, height, backgroundHeight, background);

        // Bauer (2019), slide 50. 粗い形状に当たった区間を同じ始点から最大3回二分する。
        [loop]
        while (coarse >= 0.001 && refinement < 3 && ds > minStep * 1.15)
        {
            refinement++;
            ds = max(minStep, ds * 0.5);
            t = cursor + jitter * ds;
            p = CameraTime.xyz + ray * t;
            coarse = coarseCloudStep(p, height, backgroundHeight, background);
        }
        cursor += ds;
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
        // h はその点に寄与する雲の内部での相対高度。雷の寄与を雲の上側で強める。
        float h = cloudSample.y;
        float reuseDistance = clamp(t * 2.4 / RenderSize.y, 20, 160);
        // 距離と密度の近い点では遮蔽を再利用する。Cumulusは奇数ステップでのみ再利用する。
        // 視線側の密度・透過率は区間ごとに求め、空の区間で照明のキャッシュを無効にする。
        bool reuseLighting = CloudPerformance.z > 0.5 && haveLighting
                             && (!CUMULUS_CLOUDS || (i & 1) != 0)
                             && t - cachedDistance < reuseDistance
                             && abs(density - cachedDensity) < max(0.04, density * 0.2);
        [branch]
        if (!reuseLighting)
        {
            cachedTau = lightOpticalDepth(p);
            if (!CUMULUS_CLOUDS)
            {
                // 上へ120/360/900 mの点を調べ、雲の上から届く光を厚みに応じて減らす。
                float upDensity = cloudDensity(p + float3(0, 120, 0), false) * 120
                                  + cloudDensity(p + float3(0, 360, 0), false) * 240
                                  + cloudDensity(p + float3(0, 900, 0), false) * 540;
                cachedSkyVisibility = exp(-upDensity * cloudExtinction() * 0.6);
            }
            cachedDensity = density;
            cachedDistance = t;
            haveLighting = true;
        }
        float tau = cachedTau;

        float extinction = density * cloudExtinction();
        // tau は雲による遮蔽。太陽 → サンプル間の大気による波長別の減衰を別途掛ける。
        float3 sunlight = SolarExposure.rgb * sunTransmittance(p);

        float3 lighting;
        if (CUMULUS_CLOUDS)
        {
            // 2オクターブのHG。消散が強い雲では後方にも散るよう位相に下限を置く。
            float backScatter = remap01(extinction, 0.0015, 0.012) / PI;
            float single = max(phase, backScatter) * exp(-tau);
            float multiple = 0.53 * max(broadPhase, backScatter * 0.36) * exp(-tau * 0.35);
            float3 ambient = skyAmbient * lerp(0.19, 0.86, exp(-tau * 0.28))
                             * lerp(1, 0.52, Weather.y);
            lighting = sunlight * (single + multiple) + ambient;
        }
        else
        {
            // 単一散乱に広い位相と等方の2項を足し、上に雲が重なる場所では天空光を抑える。
            float single = phase * exp(-tau);
            float multiple = 0.32 * broadPhase * exp(-tau * 0.45)
                             + 0.18 * isotropicPhase * exp(-tau * 0.12);
            float powder = 1 - exp(-density * 4);
            float3 ambient = lerp(float3(0.08, 0.11, 0.17), float3(0.38, 0.51, 0.70), h)
                             * (0.07 + 0.93 * saturate(SunDirection.y * 3 + 0.10));
            ambient *= (0.12 + 0.88 * cachedSkyVisibility) * lerp(1, 0.53, Weather.y);
            lighting = sunlight * (single + multiple) * (0.85 + 0.15 * powder) + ambient;
        }
        lighting += lightningIrradiance(p) * (0.3 + 0.7 * h);

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

[numthreads(8, 8, 1)]
void CloudCS(uint3 id : SV_DispatchThreadID)
{
    uint2 size = uint2(Checkerboard.x > 0.5 ? Checkerboard.z : RenderSize.x, RenderSize.y);
    if (any(id.xy >= size))
        return;
    uint2 pixel = id.xy;
    if (Checkerboard.x > 0.5)
        pixel.x = id.x * 2 + ((id.y + (uint)Checkerboard.y) & 1);
    // 奇数幅の末尾にできる未使用セルも初期化する。
    if (pixel.x >= (uint)RenderSize.x)
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
    return Checkerboard.x < 0.5 || ((pixel.x + pixel.y) & 1) == (int)Checkerboard.y;
}

int2 rawPixel(int2 pixel)
{
    return int2(Checkerboard.x > 0.5 ? pixel.x >> 1 : pixel.x, pixel.y);
}

[numthreads(8, 8, 1)]
void TemporalCS(uint3 id : SV_DispatchThreadID)
{
    if (any(id.xy >= (uint2)RenderSize.xy))
        return;
    int2 pixel = id.xy;
    float2 uv = (id.xy + 0.5) / RenderSize.xy;
    bool traced = tracedPixel(pixel);
    float scene = sceneDistance(uv);
    float4 current = float4(0, 0, 0, 1);
    float2 meta = float2(Atmosphere.z, scene);
    if (!traced)
    {
        float2 interval = cloudSegment(worldRay(uv), scene);
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
    // 生バッファは横方向に詰めている。未計算画素を絶対に読み出さない。
    // 欠けた画素の代表距離は、同じ地形深度を持つ上下左右から推定する。
    [unroll]
    for (int y = -1; y <= 1; y++)
        [unroll]
        for (int x = -1; x <= 1; x++)
        {
            int2 q = pixel + int2(x, y);
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
            if (!traced && abs(x) + abs(y) == 1)
            {
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
    // 深度境界では、小さい重みの合計だけが閾値を超える場合がある。
    // 色の有効範囲が空なら履歴をクランプせず、必ず修復に回す。
    if (!traced && (!haveBounds || neighborWeight <= 0.001))
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

    // 0: 今回計算、1: 履歴から再構成、2: 履歴不成立のため後段で再計算。
    ReconstructionOutput[pixel] = traced ? 0 : (valid > 0.5 ? 1 : 2);
    float4 old = clamp(HistoryTexture.SampleLevel(LinearClamp, previousUV, 0), minimum, maximum);
    float historyWeight = Checkerboard.x > 0.5 ? min(PreviousWind.z, 0.8) : PreviousWind.z;
    float weight = valid * (traced ? historyWeight : 1);
    CloudOutput[id.xy] = lerp(current, old, weight);
    MetadataOutput[id.xy] = meta;
}

// 履歴がない露出部分は空間補間で済ませず、そのフレームでレイマーチする。
// UAVと同じテクスチャをSRVに束縛せず、独立したR32_UINTマスクだけを読む。
[numthreads(8, 8, 1)]
void RepairCS(uint3 id : SV_DispatchThreadID)
{
    if (any(id.xy >= (uint2)RenderSize.xy))
        return;
    if (CloudReconstruction.Load(int3(id.xy, 0)) != 2)
        return;
    CloudRayResult result = traceCloudRay(id.xy);
    CloudOutput[id.xy] = result.color;
    MetadataOutput[id.xy] = result.metadata;
}
