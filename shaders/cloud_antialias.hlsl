#include "common.hlsli"

RWTexture2D<float4> CloudOutput : register(u0);
RWTexture2D<float2> MetadataOutput : register(u1);

// 雲色（乗算済みHDR）と透過率だけを安定化する。8x8画素で1画素の縁を共有し、
// 3x3の統計を各スレッドがテクスチャから9回ずつ読むのを避ける。
groupshared float4 aaTileColor[100];
groupshared float2 aaTileDepth[100];

float4 reprojectCloudAA(float2 uv, float anchor, float4 current, float4 lower, float4 upper,
                        float contrast, bool carried)
{
    float3 world = previousCloudPosition(CameraTime.xyz + worldRay(uv) * anchor);
    float4 clip = mul(float4(world, 1), PreviousViewProjection);
    if (clip.w <= 0)
        return current;
    float2 oldUV = clip.xy / clip.w * float2(0.5, -0.5) + 0.5;
    if (any(oldUV <= 0) || any(oldUV >= 1))
        return current;

    float expected = length(world - PreviousCamera.xyz);
    float2 grid = oldUV * RenderSize.xy - 0.5;
    int2 origin = int2(floor(grid));
    float2 f = frac(grid);
    float4 history = 0;
    float weightSum = 0;
    [unroll]
    for (int y = 0; y < 2; ++y)
        [unroll]
        for (int x = 0; x < 2; ++x)
        {
            int2 q = origin + int2(x, y);
            if (any(q < 0) || any(q >= int2(RenderSize.xy)))
                continue;
            float2 oldDepth = HistoryMetadata.Load(int3(q, 0));
            // 雲の奥行きが違う画素や、前フレームで地形に隠れていた画素は混ぜない。
            if (abs(oldDepth.x - expected) > max(110, expected * 0.085)
                || oldDepth.y + max(18, expected * 0.012) < expected)
                continue;
            float weight = (x == 0 ? 1 - f.x : f.x) * (y == 0 ? 1 - f.y : f.y);
            history += weight * HistoryTexture.Load(int3(q, 0));
            weightSum += weight;
        }
    if (weightSum < 0.05)
        return current;

    float4 limited = clamp(history / weightSum, lower, upper);
    float motion = length((oldUV - uv) * RenderSize.xy);
    float weight = lerp(carried ? 0.92 : 0.84, 0.55, smoothstep(0.7, 6, motion));
    return lerp(current, limited, weight * weightSum * contrast);
}

[numthreads(8, 8, 1)]
void CloudAntialiasCS(uint3 id : SV_DispatchThreadID, uint3 group : SV_GroupID, uint lane : SV_GroupIndex)
{
    int2 size = int2(RenderSize.xy);
    int2 tileOrigin = int2(group.xy) * 8 - 1;
    for (uint i = lane; i < 100; i += 64)
    {
        int2 q = clamp(tileOrigin + int2(i % 10, i / 10), 0, size - 1);
        aaTileColor[i] = CloudTexture.Load(int3(q, 0));
        aaTileDepth[i] = CloudMetadata.Load(int3(q, 0));
    }
    GroupMemoryBarrierWithGroupSync();
    if (any(id.xy >= (uint2)size))
        return;

    int centerIndex = (int(id.y & 7) + 1) * 10 + int(id.x & 7) + 1;
    float4 center = aaTileColor[centerIndex];
    float2 depth = aaTileDepth[centerIndex];
    uint state = CloudReconstruction.Load(int3(id.xy, 0)) & 3u;
    if (state == 3u)
    {
        CloudOutput[id.xy] = center;
        MetadataOutput[id.xy] = depth;
        return;
    }

    float4 low = center, high = center, sum = 0, squares = 0;
    float total = 0, best = 0, anchor = Atmosphere.z;
    [unroll]
    for (int dy = -1; dy <= 1; ++dy)
        [unroll]
        for (int dx = -1; dx <= 1; ++dx)
        {
            int neighbor = centerIndex + dy * 10 + dx;
            float2 m = aaTileDepth[neighbor];
            if (abs(m.y - depth.y) > max(35, 0.025 * min(m.y, depth.y)))
                continue;
            float4 c = aaTileColor[neighbor];
            float w = (dx == 0 ? 2 : 1) * (dy == 0 ? 2 : 1);
            low = min(low, c);
            high = max(high, c);
            sum += w * c;
            squares += w * c * c;
            total += w;
            // 雲と空が交互に出る画素では、空の遠方クリップ面を再投影せず、
            // 同じ背景の近傍のうち、光をいちばん遮る雲の距離を借りる。
            float support = w * (1 - c.a);
            if (support > best && m.x < Atmosphere.z * 0.99 && m.x <= depth.y + 25)
            {
                anchor = m.x;
                best = support;
            }
        }
    if (center.a < 0.97 && depth.x < Atmosphere.z * 0.99)
        anchor = depth.x;
    float4 mean = sum / max(1, total);
    const float3 luminance = float3(0.2126, 0.7152, 0.0722);
    float intensity = 0.10 + dot(mean.rgb, luminance);
    float contrast = smoothstep(0.015, 0.16, max(high.a - low.a, dot(high.rgb - low.rgb, luminance) / intensity));
    float residual = max(abs(center.a - mean.a), abs(dot(center.rgb - mean.rgb, luminance)) / intensity);
    float spatial = contrast * lerp(0.15, 0.82, smoothstep(0.025, 0.19, residual));
    float4 color = lerp(center, mean, spatial);

    [branch]
    if (PreviousWind.w > 0.5 && contrast > 0 && anchor < Atmosphere.z * 0.99)
    {
        float4 deviation = sqrt(max(0, squares / max(1, total) - mean * mean));
        float4 radius = 1.65 * deviation + float4(0.003, 0.003, 0.003, 0.012);
        color = reprojectCloudAA((id.xy + 0.5) / RenderSize.xy, anchor, color,
                                 max(low, mean - radius), min(high, mean + radius), contrast, state == 1u);
    }
    CloudOutput[id.xy] = color;
    MetadataOutput[id.xy] = float2(color.a < 0.9999 ? anchor : Atmosphere.z, depth.y);
}
