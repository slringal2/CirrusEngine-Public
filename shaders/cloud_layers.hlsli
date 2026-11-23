// それぞれの雲種を独立した2Dテクスチャで定義する。
float2 cloudShellRoots(float3 worldOrigin, float3 ray, float shellHeight)
{
    float3 origin = worldOrigin - planetCenter();
    float y = worldOrigin.y;
    float b = dot(origin, ray);
    // 大きい半径の二乗同士を直接引かず、カメラのすぐそばでも境界の精度を保つ。
    float c = dot(origin.xz, origin.xz) + (y - shellHeight) * (2 * PLANET_RADIUS + y + shellHeight);
    float discriminant = b * b - c;
    if (discriminant < 0)
        return float2(-1, -1);
    float root = sqrt(discriminant);
    float stableRoot = -b - (b >= 0 ? root : -root);
    float other = abs(stableRoot) > 0.0001 ? c / stableRoot : -b;
    return float2(min(stableRoot, other), max(stableRoot, other));
}

// 球殻には手前側と向こう側がある。カメラ内側からの出射や地形で切った端も残す。
float4 textureCloudIntervals(float3 origin, float3 ray, float nearDistance, float farDistance,
                             float4 layer)
{
    float4 result = 0;
    float2 outer = cloudShellRoots(origin, ray, layer.x + layer.y);
    float2 span = float2(max(nearDistance, outer.x), min(farDistance, outer.y));
    if (span.y > span.x)
    {
        float2 inner = cloudShellRoots(origin, ray, layer.x - layer.y);
        if (inner.y > inner.x)
            result = float4(span.x, min(span.y, inner.x), max(span.x, inner.y), span.y);
        else
        {
            // 内球の接線をまたいでも、カメラから見た手前・奥の区間を連続に保つ。
            float closest = clamp(-dot(origin - planetCenter(), ray), span.x, span.y);
            result = float4(span.x, closest, closest, span.y);
        }
    }
    return result;
}

bool hasTextureCloudInterval(float3 origin, float3 ray, float nearDistance, float farDistance)
{
    [loop]
    for (int i = 0; i < TEXTURE_CLOUD_LAYER_COUNT; ++i)
    {
        float4 layer = TextureCloudLayers[i];
        if (layer.z <= 0)
            continue;
        float4 spans = textureCloudIntervals(origin, ray, nearDistance, farDistance, layer);
        if (spans.y > spans.x || spans.w > spans.z)
            return true;
    }
    return false;
}

static const int TEXTURE_CLOUD_HIT_LIMIT = TEXTURE_CLOUD_LAYER_COUNT * 2;
struct TextureCloudHits
{
    // x: 区間中点、yz: 区間端 [m]、w: マスクと高度の番号。
    float4 items[TEXTURE_CLOUD_HIT_LIMIT];
    int count;
};

float4 textureCloudHit(float2 span, int layer)
{
    float midpoint = span.y > span.x ? (span.x + span.y) * 0.5 : 1e9;
    return float4(midpoint, span, (float)layer);
}

TextureCloudHits gatherTextureCloudHits(float3 origin, float3 ray, float nearDistance, float farDistance)
{
    TextureCloudHits hits;
    hits.count = 0;
    [unroll]
    for (int layerIndex = 0; layerIndex < TEXTURE_CLOUD_LAYER_COUNT; ++layerIndex)
    {
        float4 layer = TextureCloudLayers[layerIndex];
        float4 spans = 0;
        if (layer.z > 0)
            spans = textureCloudIntervals(origin, ray, nearDistance, farDistance, layer);
        hits.items[layerIndex * 2] = textureCloudHit(spans.xy, layerIndex);
        hits.items[layerIndex * 2 + 1] = textureCloudHit(spans.zw, layerIndex);
        hits.count += (spans.y > spans.x ? 1 : 0) + (spans.w > spans.z ? 1 : 0);
    }
    // 6枠を固定長で整列し、交差しなかった枠を末尾へ送る。
    [branch]
    if (hits.count > 0)
    {
        [unroll]
        for (int tail = TEXTURE_CLOUD_HIT_LIMIT - 1; tail > 0; --tail)
        {
            [unroll]
            for (int slot = 0; slot < TEXTURE_CLOUD_HIT_LIMIT - 1; ++slot)
            {
                if (slot < tail)
                {
                    float4 a = hits.items[slot];
                    float4 b = hits.items[slot + 1];
                    bool ordered = a.x <= b.x;
                    hits.items[slot] = ordered ? a : b;
                    hits.items[slot + 1] = ordered ? b : a;
                }
            }
        }
    }
    return hits;
}

float4 sampleTextureCloudMap(int layer, float2 uv, float mip)
{
    // Shader Model 5では、リソースの参照先を明示的に選ぶ。
    float4 texel = 0;
    [branch]
    if (layer == 0)
        texel = CloudTypeTexture0.SampleLevel(LinearWrap, uv, mip);
    else if (layer == 1)
        texel = CloudTypeTexture1.SampleLevel(LinearWrap, uv, mip);
    else
        texel = CloudTypeTexture2.SampleLevel(LinearWrap, uv, mip);
    return texel;
}

float4 sampleTextureCloudMapGrad(int layer, float2 uv, float2 dUVdx, float2 dUVdy)
{
    float4 texel = 0;
    [branch]
    if (layer == 0)
        texel = CloudTypeTexture0.SampleGrad(AnisotropicWrap, uv, dUVdx, dUVdy);
    else if (layer == 1)
        texel = CloudTypeTexture1.SampleGrad(AnisotropicWrap, uv, dUVdx, dUVdy);
    else
        texel = CloudTypeTexture2.SampleGrad(AnisotropicWrap, uv, dUVdx, dUVdy);
    return texel;
}

float2 textureCloudColumn(float4 texel, int layer)
{
    // Gは厚み、Bは中心高度。密度だけの画像は上下対称のプロファイルにする。
    bool shaped = TextureCloudMaps[layer].y > 0.5;
    float center = shaped ? (2 * texel.b - 1) * 0.24 : 0;
    float halfWidth = shaped ? lerp(0.23, 1, texel.g) * (1 - abs(center)) : 1;
    return float2(center, halfWidth);
}

struct TextureCloudRegion
{
    float typeWeight;
    float coverage;
};

TextureCloudRegion sampleTextureCloudRegion(float2 advectedXZ, int layer, float footprint)
{
    TextureCloudRegion region;
    region.typeWeight = 1;
    region.coverage = 1;
    [branch]
    if (TextureCloudRegions.x > 0)
    {
        float mip = log2(max(1, footprint * TextureCloudRegions.z));
        float type = HighCloudTypeMap.SampleLevel(LinearWrap, advectedXZ * TextureCloudRegions.x, mip);
        // The scalar type ramp blends the two adjacent entries in the layer catalog.
        float index = type * TextureCloudMaps[layer].z;
        region.typeWeight = saturate(1 - abs(index - layer));
    }
    [branch]
    if (TextureCloudRegions.y > 0)
    {
        float mip = log2(max(1, footprint * TextureCloudRegions.w));
        region.coverage = HighCloudCoverageMap.SampleLevel(LinearWrap, advectedXZ * TextureCloudRegions.y, mip);
    }
    return region;
}

float regionalCloudDensity(float density, TextureCloudRegion region)
{
    // Nubis: inverse coverage erodes the weaker parts of the cloud shape first.
    float cutoff = 1 - region.coverage;
    return region.typeWeight * max(0, density - cutoff) / max(region.coverage, 0.0001);
}

float textureCloudExtinction(float3 p, float height, int layerIndex, float footprint)
{
    float4 layer = TextureCloudLayers[layerIndex];
    float h = (height - layer.x) / layer.y;
    float extinction = 0;
    [branch]
    if (layer.z > 0 && abs(h) < 1)
    {
        float2 advectedXZ = p.xz - Wind.xy;
        TextureCloudRegion region = sampleTextureCloudRegion(advectedXZ, layerIndex, footprint);
        [branch]
        if (region.typeWeight > 0 && region.coverage > 0)
        {
            float mip = log2(max(1, footprint * layer.w * TextureCloudMaps[layerIndex].x));
            float4 texel = sampleTextureCloudMap(layerIndex, advectedXZ * layer.w, mip);
            float2 column = textureCloudColumn(texel, layerIndex);
            h = (h - column.x) / column.y;
            float density = regionalCloudDensity(texel.r * texel.a, region);
            extinction = layer.z * density * saturate(1 - h * h) / column.y;
        }
    }
    return extinction;
}

float nearbyTextureCloudExtinction(float3 p)
{
    float height = altitude(p);
    float extinction = 0;
    [loop]
    for (int i = 0; i < TEXTURE_CLOUD_LAYER_COUNT; ++i)
        extinction += textureCloudExtinction(p, height, i, 0);
    return extinction;
}

float integratedCloudProfile(float h)
{
    h = clamp(h, -1, 1);
    return h * (1 - h * h / 3);
}

struct TextureCloudFootprint
{
    float2 dx;
    float2 dy;
};

TextureCloudFootprint projectTextureCloudFootprint(float3 origin, float3 ray, float distance,
                                                  float3 rayDx, float3 rayDy)
{
    float3 normal = (origin + ray * distance - PLANET_CENTER) / PLANET_RADIUS;
    // Project one-pixel ray differentials onto the local tangent of the cloud shell.
    // Limit growth near a grazing intersection, where the tangent approximation breaks down.
    float facing = dot(normal, ray);
    float divisor = facing >= 0 ? max(facing, 0.025) : min(facing, -0.025);
    TextureCloudFootprint footprint;
    footprint.dx = distance * (rayDx.xz - ray.xz * (dot(normal, rayDx) / divisor));
    footprint.dy = distance * (rayDy.xz - ray.xz * (dot(normal, rayDy) / divisor));
    return footprint;
}

float textureCloudOpticalDepth(float3 origin, float3 ray, float4 hit, float scalarFootprint,
                               TextureCloudFootprint pixel, bool anisotropic, int maxSamples)
{
    // XZ方向に模様が移る分だけ区間を分割する。層の厚さをそのままミップ幅に使わない。
    int layerIndex = (int)hit.w;
    float4 layer = TextureCloudLayers[layerIndex];
    float ds = hit.z - hit.y;
    float raySlope = length(ray.xz);
    float span = ds * raySlope;
    float texelSize = 1 / (layer.w * TextureCloudMaps[layerIndex].x);
    float sampleWidth = scalarFootprint;
    if (anisotropic)
    {
        float2 direction = ray.xz / max(raySlope, 0.0001);
        sampleWidth = length(float2(dot(pixel.dx, direction), dot(pixel.dy, direction)));
    }
    int samples = clamp((int)ceil(span / max(sampleWidth, 2 * texelSize)), 1, maxSamples);
    float stepLength = ds / samples;
    float filterWidth = max(scalarFootprint, span * 0.65 / samples);
    float mip = log2(max(1, filterWidth / texelSize));
    // A vertical ray crosses less than one regional texel in most shots.
    // Near the horizon, evaluate the control maps along the longer path.
    bool longRegionPath = span * max(TextureCloudRegions.z, TextureCloudRegions.w) > 1;
    TextureCloudRegion region;
    region.typeWeight = 1;
    region.coverage = 1;
    [branch]
    if (!longRegionPath)
        region = sampleTextureCloudRegion(origin.xz + ray.xz * hit.x - Wind.xy, layerIndex, filterWidth);
    int activeSamples = region.typeWeight > 0 && region.coverage > 0 ? samples : 0;
    float2 gradientX = 0, gradientY = 0;
    if (anisotropic)
    {
        // Add the subsegment's travel to the pixel footprint along the horizontal ray.
        // Factor the combined 2D covariance into two texture gradients for SampleGrad.
        float2 travel = ray.xz * (stepLength * 0.65);
        float3 x = float3(pixel.dx.x, pixel.dy.x, travel.x);
        float3 y = float3(pixel.dx.y, pixel.dy.y, travel.y);
        float width = sqrt(max(dot(x, x), 0.000001));
        float skew = dot(x, y) / width;
        float height = sqrt(max(dot(y, y) - skew * skew, 0.000001));
        gradientX = float2(width, skew) * layer.w;
        gradientY = float2(0, height) * layer.w;
    }
    float h0 = (altitude(origin + ray * hit.y) - layer.x) / layer.y;
    float tau = 0;
    [loop]
    for (int step = 0; step < activeSamples; ++step)
    {
        float end = hit.y + (step + 1) * stepLength;
        float h1 = (altitude(origin + ray * end) - layer.x) / layer.y;
        float2 advectedXZ = origin.xz + ray.xz * (end - 0.5 * stepLength) - Wind.xy;
        [branch]
        if (longRegionPath)
        {
            region = sampleTextureCloudRegion(advectedXZ, layerIndex, filterWidth);
            if (region.typeWeight <= 0 || region.coverage <= 0)
            {
                h0 = h1;
                continue;
            }
        }
        float2 uv = advectedXZ * layer.w;
        float4 texel;
        [branch]
        if (anisotropic)
            texel = sampleTextureCloudMapGrad(layerIndex, uv, gradientX, gradientY);
        else
            texel = sampleTextureCloudMap(layerIndex, uv, mip);
        float2 column = textureCloudColumn(texel, layerIndex);
        float a = (h0 - column.x) / column.y;
        float b = (h1 - column.x) / column.y;
        float delta = b - a;
        float mid = (a + b) * 0.5;
        // テクスチャを読む回数を抑えながら、各柱の鉛直密度を解析的に積分する。
        float meanDensity = abs(delta) > 0.0001
            ? saturate((integratedCloudProfile(b) - integratedCloudProfile(a)) / delta)
            : saturate(1 - mid * mid);
        float density = regionalCloudDensity(texel.r * texel.a, region);
        tau += stepLength * layer.z * density * meanDensity / column.y;
        h0 = h1;
    }
    return min(16, tau);
}
