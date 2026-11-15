// common.hlsliから、ノイズ・高度関数・定数を定義した後に読み込む。
// 一次資料のページと採用範囲: docs/cloud-research.md。
float2 rotateCloud(float2 p, float angle)
{
    float s, c;
    sincos(angle, s, c);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

// Webanck et al., Procedural Cloudscapes (2018), §4.2:
// プリミティブは最終表面ではなく、雲の存在確率を制御する滑らかな場に使う。
// セルのcompact kernelの合成は src/cloud_volume.hpp で一度だけ焼く。

// Nubis3 (2023), PDF pp.84, 123-125: 3Dの形状プロファイルをノイズで高詳細化。
// ボリュームの作成方法とノイズの係数は独自。流体アセット・SDF加速は未実装。
float2 sampleTowerCloud(float3 p, float2 q, float h, CloudFormation f, bool detail)
{
    float3 offset = frac(float3(f.shape.w * 0.137, f.shape.w * 0.271, f.shape.w * 0.419));
    // 滑らかな独立3成分のベクトル場。Worleyは密度の侵食にだけ使う。
    float3 warp = CloudWarpVolume.SampleLevel(LinearWrap, p * 0.00018 + offset, 0).rgb - 0.5;
    float2 local = rotateCloud(q - f.motion.zw * h, f.shape.w * 0.37);
    float3 uv = float3((local.x + 1.4) / 2.8, h, (local.y + 1.4) / 2.8);
    float3 displacement = warp * min(850, f.position.w * 0.14);
    uv += displacement / float3(f.position.w * 2.8, f.shape.x, f.position.w * 2.8);
    if (any(uv <= 0) || any(uv >= 1))
        return float2(0, h);
    float profile = TowerControlVolume.SampleLevel(LinearClamp, uv, 0);
    if (profile < 0.001)
        return float2(0, h);
    float density = detail ? erodeCloudShape(profile, p + offset * 1900, 0.83) : profile;
    return float2(pow(max(density, 0), 0.7) * f.shape.y * FormationControls.y, h);
}

float2 sampleVortexCloud(float3 q, float height, float bottom, float top,
                        float coverage, float seed, bool detail)
{
    float h = (height - bottom) / max(top - bottom, 1);
    if (h <= 0 || h >= 1 || coverage <= 0.001)
        return float2(0, saturate(h));
    float3 profile = cloudHeightProfile(h);
    float threshold = min(profile.x, profile.y);
    float density = smoothstep(threshold, threshold + 0.25, coverage);
    if (density > 0)
    {
        // 大きな帯の内部も3Dで濃淡を変え、同じ断面が続くのを避ける。
        float cell = BaseNoise.SampleLevel(LinearWrap,
                                            q * 0.00023 + frac(seed * 0.07), 0).r;
        density *= smoothstep(0.20, 0.66, cell);
    }
    if (detail && density > 0)
    {
        float3 offset = frac(seed * float3(0.137, 0.271, 0.419)) * 1900;
        density = erodeCloudShape(density, q + offset, profile.z);
    }
    return float2(density, h);
}

// Nubis Evolved (2022), pp.149-150: 半径ごとの回転速度と位相を分離。
// 速度値は本実装のアートパラメータ。各帯の境界で速度を連続補間する。
float vortexRotationFactor(float radius)
{
    static const float speeds[6] = {1.65, 1.42, 1.10, 0.78, 0.53, 0.35};
    float ring = saturate(radius / 1.12) * 5;
    int index = min((int)floor(ring), 4);
    float t = saturate(ring - index);
    return lerp(speeds[index], speeds[index + 1], t * t * (3 - 2 * t));
}

float2 compositeFormationDensity(float3 p, float height, float backgroundHeight,
                                 bool detail, float background)
{
    backgroundHeight = saturate(backgroundHeight);
    if (FormationControls.x < 0.5 || FormationControls.y <= 0)
        return float2(background, backgroundHeight);
    float extra = 0;
    float extraHeightMoment = 0;
    float cloudSea = background;
    float seaHeightMoment = background * backgroundHeight;
    float2 advected = p.xz - Wind.xy;
    [loop]
    for (int i = 0; i < (int)FormationControls.x; ++i)
    {
        CloudFormation f = Formations[i];
        if (f.shape.y <= 0)
            continue;
        float h = (height - f.position.y) / f.shape.x;
        float2 q = (advected - f.position.xz) / f.position.w;
        float r = length(q);
        if (r > 1.7)
            continue;
        float3 noisePosition = float3(advected.x, height, advected.y);
        if (f.shape.z < 0.5)
        {
            if (h <= 0 || h >= 1)
                continue;
            float2 cloud = sampleTowerCloud(noisePosition, q, h, f, detail);
            extra += cloud.x;
            extraHeightMoment += cloud.x * cloud.y;
        }
        else
        {
            if (height < min(f.position.y, CloudLayer.x) - 120
                || height > max(f.position.y + f.shape.x, CloudLayer.x + CloudLayer.y) + 120)
                continue;
            float angle = f.motion.x * FormationControls.z * vortexRotationFactor(r);
            float2 rotating = rotateCloud(q, -angle);
            float skew = f.motion.y * 1.8 * (1 - smoothstep(0.10, 1.10, r));
            float2 twisted = rotateCloud(rotating, -skew);
            float2 seedUV = frac(f.shape.w * float2(0.137, 0.419));

            // 巻き込まれた大きな雲量場に、引き延ばしていない細かい斑を重ねる。
            float belt = WeatherMap.SampleLevel(LinearWrap,
                twisted * float2(0.24, 0.46) + seedUV, 0).r;
            float patch = CloudDisplacement.SampleLevel(LinearWrap,
                rotating * 0.47 + seedUV.yx, 0).x;
            float eyeRadius = 0.145 + (patch - 0.5) * 0.14;
            float eye = smoothstep(eyeRadius * 0.69, eyeRadius * 1.40, r);
            float wallDistance = (r - eyeRadius - 0.085) / 0.135;
            float eyewall = exp(-wallDistance * wallDistance);
            float coverage = saturate(0.58 + (belt - 0.5) * 0.94 + (patch - 0.5) * 0.72
                                      + eyewall * (0.07 + 0.16 * patch)) * eye;
            float top = f.position.y + f.shape.x
                * saturate(0.57 + 0.28 * belt + 0.22 * patch * eyewall);
            noisePosition.xz = f.position.xz + rotating * f.position.w;
            float2 cloud = sampleVortexCloud(noisePosition, height, f.position.y, top,
                                             coverage, f.shape.w, detail);
            float density = cloud.x * f.shape.y * FormationControls.y;
            float lowCloud = background * eye * (1 - smoothstep(0.26, 0.62, h)) * 0.48;
            float influence = (1 - smoothstep(0.82, 1.20, r)) * saturate(FormationControls.y);
            cloudSea = lerp(cloudSea, density + lowCloud, influence);
            seaHeightMoment = lerp(seaHeightMoment,
                                   density * cloud.y + lowCloud * backgroundHeight, influence);
        }
    }
    float total = cloudSea + extra;
    return float2(min(total, 3), total > 0.0001
        ? saturate((seaHeightMoment + extraHeightMoment) / total) : backgroundHeight);
}

// 風で移流する座標系で局所渦の回転も戻す。背景との境は徐々に補正を弱める。
float2 rotateFormationMotion(float2 p, float altitudeValue, float delta)
{
    [loop]
    for (int i = 0; i < (int)FormationControls.x; ++i)
    {
        CloudFormation f = Formations[i];
        if (f.shape.z < 0.5 || f.shape.y <= 0)
            continue;
        float2 local = p - f.position.xz;
        float r = length(local) / f.position.w;
        float influence = (1 - smoothstep(0.82, 1.20, r)) * saturate(FormationControls.y)
            * smoothstep(min(f.position.y, CloudLayer.x) - 120, min(f.position.y, CloudLayer.x), altitudeValue)
            * (1 - smoothstep(max(f.position.y + f.shape.x, CloudLayer.x + CloudLayer.y),
                              max(f.position.y + f.shape.x, CloudLayer.x + CloudLayer.y) + 120, altitudeValue));
        p = lerp(p, f.position.xz + rotateCloud(local, f.motion.x * delta * vortexRotationFactor(r)), influence);
    }
    return p;
}

float3 previousCloudPosition(float3 p)
{
    p.xz = rotateFormationMotion(p.xz - Wind.xy, altitude(p), -FormationControls.w) + PreviousWind.xy;
    return p;
}

float3 currentCloudPosition(float3 p)
{
    p.xz = rotateFormationMotion(p.xz - PreviousWind.xy, altitude(p), FormationControls.w) + Wind.xy;
    return p;
}

// 球面高度の曲率も含む保守的なAABB。雲海より上の領域をレイ区間へ追加する。
float2 formationRayInterval(float3 origin, float3 ray, CloudFormation f)
{
    float2 center = f.position.xz + Wind.xy;
    float radius = f.position.w * 1.85;
    float farRadius = length(center) + radius;
    float nearRadius = max(0, length(center) - radius);
    float3 lower = float3(center.x - radius,
        f.position.y - farRadius * farRadius / (2 * PLANET_RADIUS) - 120, center.y - radius);
    float3 upper = float3(center.x + radius,
        f.position.y + f.shape.x - nearRadius * nearRadius / (2 * PLANET_RADIUS) + 120, center.y + radius);
    float3 safeRay = float3(abs(ray.x) < 1e-6 ? 1e-6 : ray.x,
                           abs(ray.y) < 1e-6 ? 1e-6 : ray.y,
                           abs(ray.z) < 1e-6 ? 1e-6 : ray.z);
    float3 a = (lower - origin) / safeRay, b = (upper - origin) / safeRay;
    float3 nearPoint = min(a, b), farPoint = max(a, b);
    return float2(max(max(nearPoint.x, nearPoint.y), nearPoint.z),
                  min(min(farPoint.x, farPoint.y), farPoint.z));
}
