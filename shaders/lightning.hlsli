#ifndef CIRRUS_LIGHTNING
#define CIRRUS_LIGHTNING

float3 lightningNode(float t)
{
    float2 noise = hash33(float3(t * 73 + 5, LightningSource.w, 21)).xy * 2 - 1;
    float3 p = lerp(LightningSource.xyz, LightningTarget.xyz, t);
    p.xz += noise * sin(t * PI) * 260;
    return p;
}

// 視線と世界座標の線分の最短距離から、細い芯と周囲の光を描く。
float lightningSegment(float3 ray, float3 a, float3 b, float scene, float cloudT, float width)
{
    float3 segment = b - a;
    float3 w = CameraTime.xyz - a;
    float c = max(dot(segment, segment), 1e-4);
    float projection = dot(ray, segment);
    float d = dot(ray, w), e = dot(segment, w);
    float rayT = (projection * e - c * d) / max(c - projection * projection, 1e-4);
    float u = saturate((e + projection * rayT) / c);
    float3 closest = a + segment * u;
    rayT = dot(closest - CameraTime.xyz, ray);
    if (rayT <= 10 || rayT >= scene)
        return 0;
    float separation = length(CameraTime.xyz + ray * rayT - closest);
    float pixel = rayT * 1.2 / Resolution.y;
    float radius = width + pixel * 0.75;
    float core = exp(-separation * separation / (radius * radius));
    float glow = exp(-separation / (pixel * 3 + 12)) * 0.12;
    float insideCloud = smoothstep(CloudLayer.x - 80, CloudLayer.x + 400, closest.y);
    float visibility = lerp(1, max(cloudT, 0.025), insideCloud);
    return (core + glow) * visibility * exp(-Weather.w * rayT * 0.15);
}

float3 lightningBolt(float3 ray, float scene, float cloudT)
{
    if (Controls.y < 0.002)
        return 0;
    float value = 0;
    float3 previous = lightningNode(0);
    [loop]
    for (int i = 1; i <= 20; ++i)
    {
        float3 next = lightningNode(i / 20.0);
        value += lightningSegment(ray, previous, next, scene, cloudT, 1.8);
        previous = next;
    }
    [unroll]
    for (int branch = 0; branch < 2; ++branch)
    {
        float t = 0.30 + branch * 0.25;
        float3 root = lightningNode(t);
        float3 random = hash33(float3(LightningSource.w, branch + 42, 16)) * 2 - 1;
        float3 end = root + float3((branch ? 1 : -1) * 650, -750, random.z * 450);
        previous = root;
        [unroll]
        for (int j = 1; j <= 6; ++j)
        {
            float f = j / 6.0;
            float3 next = lerp(root, end, f);
            next.xz += (hash33(float3(j, branch + LightningSource.w, 7)).xy - 0.5)
                       * sin(f * PI) * 170;
            value += lightningSegment(ray, previous, next, scene, cloudT, 0.75) * 0.45;
            previous = next;
        }
    }
    return value * Controls.y * float3(24, 31, 46);
}

#endif
