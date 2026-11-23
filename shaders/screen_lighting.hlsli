// 地表のG-bufferから求めた、間接光と直射光の局所的な可視性。
Texture2D<float4> ScreenVisibility : register(t29);
Texture2D<float> GrassShadowDepth : register(t30);
RWTexture2D<float4> ScreenVisibilityOutput : register(u0);

static const float SCREEN_LIGHTING_DEPTH = 90;
static const float2 aoDisk[12] = {
    float2(0.16, 0.09), float2(-0.23, 0.16), float2(0.03, -0.35), float2(0.27, 0.33),
    float2(-0.47, -0.04), float2(0.43, -0.39), float2(-0.12, 0.63), float2(-0.53, -0.43),
    float2(0.75, 0.02), float2(-0.60, 0.55), float2(0.18, -0.84), float2(0.37, 0.85)
};

float linearSceneDepth(float depth)
{
    // clip.z = A * view.z + B、clip.w = view.z。係数は通常Zと反転Zの投影から受け取る。
    return SceneDepthProjection.y / (depth - SceneDepthProjection.x);
}

float screenAmbientVisibility(int2 pixel, float3 position, float3 normal, float z)
{
    const float radius = 1.65;
    float pixelRadius = clamp(radius * GroundLighting.w / z, 3, 56);
    float blocking = 0;
    // 時刻に依存しないディスクを使う。近傍点が法線側にあるときだけ天空光を遮る。
    [unroll]
    for (int i = 0; i < 12; ++i)
    {
        int2 q = pixel + int2(round(aoDisk[i] * pixelRadius));
        if (any(q < 0) || any(q >= int2(Resolution.xy)))
            continue;
        float depth = SceneDepth.Load(int3(q, 0));
        if (!hasGeometry(depth))
            continue;
        float3 delta = worldPosition((q + 0.5) * Resolution.zw, depth) - position;
        float distance2 = dot(delta, delta);
        float height = saturate((dot(delta, normal) - 0.022) * rsqrt(max(distance2, 0.001)));
        float falloff = saturate(1 - distance2 / (radius * radius));
        blocking += height * falloff * falloff;
    }
    float fade = 1 - smoothstep(40, SCREEN_LIGHTING_DEPTH, z);
    return 1 - min(0.54, blocking * (3.15 / 12.0)) * fade;
}

float screenSunVisibility(int2 pixel, float3 position, float3 normal, float z)
{
    const float maxDistance = 3.2;
    float3 start = position + normal * 0.025 + SunDirection.xyz * 0.035;
    float4 clipStart = mul(float4(start, 1), ViewProjection);
    float4 clipEnd = mul(float4(start + SunDirection.xyz * maxDistance, 1), ViewProjection);
    float occlusion = 0;
    [loop]
    for (int i = 0; i < 14; ++i)
    {
        // 斜めの光で草や地形の接触部を拾えるよう、始点付近を密に調べる。
        float fraction = (i + 1) / 14.0;
        float t = fraction * fraction;
        float4 clip = lerp(clipStart, clipEnd, t);
        if (clip.w <= 0.05)
            break;
        float2 uv = clip.xy / clip.w * float2(0.5, -0.5) + 0.5;
        if (any(uv <= 0) || any(uv >= 1))
            break;
        int2 q = int2(uv * Resolution.xy);
        if (all(q == pixel))
            continue;

        float depth = SceneDepth.Load(int3(q, 0));
        if (!hasGeometry(depth))
            continue;
        float separation = clip.w - linearSceneDepth(depth);
        // 奥行き差の上限で、画面上で重なる離れた地形を遮蔽物から除く。
        float pixelWidth = clip.w / GroundLighting.w;
        float bias = 0.010 + pixelWidth * 0.63;
        float thickness = max(0.068 + t * 0.10, bias + 1.6 * pixelWidth);
        float hit = smoothstep(bias, bias + 0.018, separation)
                    * (1 - smoothstep(thickness * 0.65, thickness, separation));
        float edge = min(min(uv.x, 1 - uv.x), min(uv.y, 1 - uv.y));
        float weight = smoothstep(0, 0.035, edge) * (1 - smoothstep(0.55, 1, t));
        occlusion = max(occlusion, hit * weight);
        if (occlusion > 0.97)
            break;
    }
    float fade = (1 - smoothstep(30, 72, z)) * smoothstep(0.02, 0.09, SunDirection.y);
    return 1 - 0.82 * occlusion * fade;
}

[numthreads(8, 8, 1)]
void ScreenLightingCS(uint3 id : SV_DispatchThreadID)
{
    uint2 size;
    ScreenVisibilityOutput.GetDimensions(size.x, size.y);
    if (any(id.xy >= size))
        return;
    // 2×2の右下の実画素から位置と法線を取る。奇数幅の端は最後の画素に丸める。
    int2 pixel = min(int2(id.xy * 2 + 1), int2(Resolution.xy) - 1);
    float depth = SceneDepth.Load(int3(pixel, 0));
    float4 visibility = float4(1, 1, 0, 0);
    if (hasGeometry(depth))
    {
        float z = linearSceneDepth(depth);
        if (z < SCREEN_LIGHTING_DEPTH)
        {
            float3 world = worldPosition((pixel + 0.5) * Resolution.zw, depth);
            float3 normal = normalize(GNormal.Load(int3(pixel, 0)).xyz * 2 - 1);
            if (GroundLighting.x > 0.5)
                visibility.r = screenAmbientVisibility(pixel, world, normal, z);
            if (GroundLighting.y > 0.5 && z < 72 && dot(normal, SunDirection.xyz) > 0)
                visibility.g = screenSunVisibility(pixel, world, normal, z);
            // B/Aに半解像度の参照点を記録し、合成時の補間で地形の境目を保つ。
            visibility.ba = float2(z, normal.y);
        }
    }
    ScreenVisibilityOutput[id.xy] = visibility;
}

float2 sampleScreenLighting(float2 uv, float depth, float3 normal)
{
    float2 visibility = float2(1, 1);
    float z = linearSceneDepth(depth);
    [branch]
    if ((GroundLighting.x + GroundLighting.y) > 0.5 && z < SCREEN_LIGHTING_DEPTH)
    {
        uint2 size;
        ScreenVisibility.GetDimensions(size.x, size.y);
        float2 p = (uv * Resolution.xy - 1.5) * 0.5;
        int2 base = int2(floor(p));
        float2 f = frac(p);
        float2 sum = 0;
        float total = 0;
        [unroll]
        for (int y = 0; y < 2; ++y)
            [unroll]
            for (int x = 0; x < 2; ++x)
            {
                int2 q = clamp(base + int2(x, y), 0, int2(size) - 1);
                float4 sampleValue = ScreenVisibility.Load(int3(q, 0));
                float w = (x == 0 ? 1 - f.x : f.x) * (y == 0 ? 1 - f.y : f.y);
                w *= exp2(-abs(sampleValue.b - z) / max(0.075, z * 0.027))
                     * saturate(1 - abs(sampleValue.a - normal.y) * 1.6);
                w *= sampleValue.b > 0 ? 1 : 0;
                sum += sampleValue.rg * w;
                total += w;
            }
        if (total > 0.01)
            visibility = sum / total;
    }
    return visibility;
}

float grassShadowVisibility(float3 position, float3 normal)
{
    float visibility = 1;
    float range = length(position.xz - CameraTime.xz);
    float fade = 1 - smoothstep(14, 24, range);
    [branch]
    if (GroundLighting.z > 0.5 && fade > 0)
    {
        float4 clip = mul(float4(position + normal * 0.018, 1), GrassLightViewProjection);
        float3 coord = clip.xyz / clip.w;
        float border = max(abs(coord.x), abs(coord.y));
        if (border < 1 && coord.z > 0 && coord.z < 1)
        {
            uint2 size;
            GrassShadowDepth.GetDimensions(size.x, size.y);
            float2 uv = coord.xy * float2(0.5, -0.5) + 0.5;
            float2 offset = 0.48 / float2(size);
            float samples = 0;
            [unroll]
            for (int y = -1; y <= 1; y += 2)
                [unroll]
                for (int x = -1; x <= 1; x += 2)
                    samples += GrassShadowDepth.SampleCmpLevelZero(
                        ShadowCompare, uv + float2(x, y) * offset, coord.z - 0.00009);

            float weight = fade * (1 - smoothstep(0.83, 1, border))
                           * smoothstep(0.02, 0.09, SunDirection.y);
            visibility = lerp(1, samples * 0.25, weight * 0.90);
        }
    }
    return visibility;
}
