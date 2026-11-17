#include "common.hlsli"

// renderer.cpp がパスごとに出力テクスチャを割り当てる。
// AerialCS は u0 に空気遠近の散乱光、u1 に透過率、u2 に地表霧を書き込む。
RWTexture2D<float4> Output0 : register(u0);
RWTexture2D<float4> Output1 : register(u1);
RWTexture2D<float4> Output2 : register(u2);

// 高度と太陽方向の組ごとに、大気を抜けるまでの透過率をLUTへ保存する。
[numthreads(8, 8, 1)]
void TransmittanceCS(uint3 id : SV_DispatchThreadID)
{
    uint w, h;
    Output0.GetDimensions(w, h);
    if (any(id.xy >= uint2(w, h)))
        return;
    // V の二乗で地表付近を細かく刻む。mu はその高度での天頂と太陽方向の内積。
    float2 uv = (id.xy + 0.5) / float2(w, h);
    float height = uv.y * uv.y * ATMOSPHERE_HEIGHT;
    float mu = uv.x * 2 - 1;
    float2 chartOrigin = planetCenter().xz;
    float3 p = float3(chartOrigin.x, height, chartOrigin.y);
    float3 d = float3(sqrt(saturate(1 - mu * mu)), mu, 0);
    float2 ground = sphereIntersection(p, d, PLANET_RADIUS);
    // 太陽への経路が先に地表の球と交差したときは直達光が遮られる。
    if (ground.x > 0)
    {
        Output0[id.xy] = float4(0, 0, 0, 1);
        return;
    }
    float length = sphereIntersection(p, d, PLANET_RADIUS + ATMOSPHERE_HEIGHT).y;
    float ds = length / 64;
    // 各区間の消散係数 [m⁻¹] × 区間長 [m] を足して RGB の光学的厚さを求める。
    // テクセルに保存する exp(-optical) は太陽光が大気を通り抜けて残る割合。
    float3 optical = 0;

    [loop]
    for (int i = 0; i < 64; i++)
        optical += atmosphereExtinction(atmosphericDensity(altitude(p + d * ((i + 0.5) * ds)))) * ds;

    Output0[id.xy] = float4(exp(-optical), 1);
}

// 空の背景色は32区間の大気散乱から作る。太陽円盤は最後にフル解像度で描く。
// 固定サイズのテクスチャの各画素から、そのフレームのカメラの視線を復元する。
[numthreads(8, 8, 1)]
void SkyCS(uint3 id : SV_DispatchThreadID)
{
    uint w, h;
    Output0.GetDimensions(w, h);
    if (any(id.xy >= uint2(w, h)))
        return;
    float2 uv = (id.xy + 0.5) / float2(w, h);
    float3 ray = worldRay(uv);
    // 空の積分終点は大気上端。惑星の球に当たる下向きの視線では地表まで。
    float t = sphereIntersection(CameraTime.xyz, ray, PLANET_RADIUS + ATMOSPHERE_HEIGHT).y;
    float2 ground = sphereIntersection(CameraTime.xyz, ray, PLANET_RADIUS);
    if (ground.x > 0)
        t = min(t, ground.x);
    AtmosphereResult a = integrateAtmosphere(CameraTime.xyz, ray, max(t, 0), 32);
    float night = 1 - smoothstep(-0.13, 0.02, SunDirection.y);
    float stars = pow(hash12(floor(ray.xz / max(abs(ray.y), 0.06) * 950)), 170.0) * night * 0.55;
    float3 color = a.scattering + float3(0.0004, 0.0008, 0.0016) + stars;
    float moon = 1 - smoothstep(0.0038, 0.0055, acos(clamp(dot(ray, -SunDirection.xyz), -1, 1)));
    color += float3(0.35, 0.40, 0.50) * moon * night;
    if (WorldRendering.z > 0.5)
        color = a.scattering + float3(0.0004, 0.0008, 0.0016);
    Output0[id.xy] = float4(color, 1);
}

groupshared float4 SkySum[64];

// Bauer (2019), slide 36. 放物面に空を投影した方向で散乱を評価し、1色へ並列縮約する。
[numthreads(8, 8, 1)]
void SkyAmbientCS(uint3 id : SV_GroupThreadID, uint index : SV_GroupIndex)
{
    // 円の中の2D座標を上半球の方向に戻す。円周が地平線に対応する。
    float2 disk = (id.xy + 0.5) * 0.25 - 1;
    float radiusSquared = dot(disk, disk);
    float4 sampleValue = 0;
    if (radiusSquared < 1)
    {
        float denominator = 1 + radiusSquared;
        float3 ray = float3(2 * disk.x, 1 - radiusSquared, 2 * disk.y) / denominator;
        float t = sphereIntersection(CameraTime.xyz, ray, PLANET_RADIUS + ATMOSPHERE_HEIGHT).y;
        AtmosphereResult a = integrateAtmosphere(CameraTime.xyz, ray, max(t, 0), 24);
        // 同じ円盤面積でも方向ごとの立体角が異なるため分母の二乗で補正する。
        // 太陽側をやや強く採り、RGB の重み付き合計と重みの合計を別々に保存する。
        float sunWeight = lerp(0.65, 1.35, saturate(dot(ray, SunDirection.xyz)));
        float weight = sunWeight / (denominator * denominator);
        sampleValue = float4(a.scattering * weight, weight);
    }
    SkySum[index] = sampleValue;
    GroupMemoryBarrierWithGroupSync();

    // 各段でペアを足し、同期してから次の段へ進む。最終的な重み付き平均が空の環境光になる。
    [unroll]
    for (uint stride = 32; stride != 0; stride >>= 1)
    {
        if (index < stride)
            SkySum[index] += SkySum[index + stride];
        GroupMemoryBarrierWithGroupSync();
    }
    if (index == 0)
        Output0[uint2(0, 0)] = float4(SkySum[0].rgb / SkySum[0].a, 1);
}

[numthreads(8, 8, 1)]
void AerialCS(uint3 id : SV_DispatchThreadID)
{
    uint w, h;
    Output0.GetDimensions(w, h);
    if (any(id.xy >= uint2(w, h)))
        return;
    float2 uv = (id.xy + 0.5) / float2(w, h);
    float3 ray = worldRay(uv);
    // scene は地形や川面までの距離、meta.x は雲の散乱を代表する距離。
    // cloudT が 1 に近いほど雲が薄く、このパスでは 0.995 を積分先の切り替えに使う。
    float scene = sceneDistance(uv);
    float2 meta = CloudMetadata.SampleLevel(LinearClamp, uv, 0);
    float cloudT = CloudTexture.SampleLevel(LinearClamp, uv, 0).a;

    // 雲の代表距離か地形までを積分する空気遠近法。
    // 視線上に広がる雲の寄与をこの代表距離にまとめる近似。大気の積分は最大 100 km。
    float distance = cloudT < 0.995 ? min(meta.x, scene) : scene;
    bool geometry = scene < Atmosphere.z * 0.99;
    AtmosphereResult a;
    a.scattering = 0;
    a.transmittance = 1;
    if (geometry || cloudT < 0.995)
        a = integrateAtmosphere(CameraTime.xyz, ray, min(distance, 100000), 16);
    // 描画合成時の空気遠近は「遠方の色 × 透過率 + 手前の空気が足した光」。
    Output0[id.xy] = float4(a.scattering, 1);
    Output1[id.xy] = float4(a.transmittance, 1);

    // 地表霧は別に24区間を積分する。雲影・地形影を受けるため光芒が現れる。
    // 最長 50 km。手前に地形があるか、雲が十分濃いときはそこで区間を切る。
    float fogDistance = min(min(scene, cloudT < 0.8 ? meta.x : 50000), 50000);
    float T = 1;
    float3 scattering = 0;
    float phase = hg(dot(ray, SunDirection.xyz), 0.58);
    float3 skyAmbient = SkyAmbient.Load(int3(0, 0, 0)).rgb;
    [loop]
    for (int i = 0; i < 24; i++)
    {
        // 高度の急変や近くの霧を細かくするため、区間幅を距離とともに広げる。
        float a = i / 24.0;
        float b = (i + 1) / 24.0;
        float start = a * a * fogDistance;
        float end = b * b * fogDistance;
        float t = 0.5 * (start + end);
        float ds = end - start;
        float3 p = CameraTime.xyz + ray * t;
        float height = altitude(p);
        float2 advected = p.xz - Wind.xy;
        // Weather.w は地表付近の消散係数 [m⁻¹]。高度 520 m で 1/e になり、風で動く天候マップでむらを付ける。
        float density = Weather.w * exp(-max(height, 0) / 520.0);
        float modulation = WeatherMap.SampleLevel(LinearWrap, advected / 65536, 1).g;
        density *= lerp(0.65, 1.35, modulation);
        if (WorldRendering.x > 0.5)
        {
            // 低い太陽で目立つ谷底の霧と、遠い丘を薄く覆う霞を足す。
            // 距離の smoothstep で徐々に効かせ、カメラに近い草原のコントラストを保つ。
            float valley = exp(-abs(height - 148) / 146);
            float lowSun = 1 - smoothstep(0.08, 0.65, max(SunDirection.y, 0));
            density += 0.000068 * valley * smoothstep(60, 520, t) * (0.38 + 0.62 * lowSun);
            float foothills = exp(-max(0, height - 200) / 930.0);
            density += 0.000049 * foothills * smoothstep(380, 1560, t);
        }
        // 降雨時は下層の雲マップから雨霧を置き、雲底から地表へ薄める。
        if (Weather.y > 0 && Controls.w > 0.5 && height < CloudLayer.x)
        {
            float placement = cloudPlacement(advected).r;
            float rainMask = smoothstep(0.47, 0.81, placement);
            float belowCloud = CloudLayer.x - height;
            float falloff = exp(-max(belowCloud, 0) / 780.0) * smoothstep(0, 160, belowCloud);
            density += 0.00038 * Weather.y * rainMask * falloff;
        }
        float segment = exp(-density * ds);
        // 直達光には太陽 → 中点の大気・雲・地形の遮蔽と前方散乱を掛ける。
        // 空の環境光と雷の光を足すので、直達光が遮られた区間にも散乱光が残る。
        float shadow = cloudShadow(p) * terrainShadow(p);
        float3 lighting = SolarExposure.rgb * sunTransmittance(p) * shadow * phase + skyAmbient * 0.25;
        lighting += lightningIrradiance(p) * 0.35;
        // (1 - segment) はこの区間の消散割合。手前の霧を通過する割合 T も掛けて足す。
        scattering += T * lighting * (1 - segment);
        T *= segment;
    }
    // 地表霧は全色共通の透過率を使う。RGB が散乱光、A が背後の光に掛ける T。
    Output2[id.xy] = float4(scattering, T);
}
