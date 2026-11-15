#include "common.hlsli"
#include "lightning.hlsli"

struct Vertex
{
    float3 position : POSITION;
    float3 normal : NORMAL;
    float4 material : COLOR;
};

struct GeometryVarying
{
    float4 position : SV_Position;
    float3 normal : NORMAL;
    float4 material : COLOR;
    float3 world : TEXCOORD;
};

GeometryVarying GeometryVS(Vertex v)
{
    GeometryVarying o;
    o.position = mul(float4(v.position, 1), ViewProjection);
    o.normal = v.normal;
    o.material = v.material;
    o.world = v.position;
    return o;
}

float4 ShadowVS(Vertex v) : SV_Position
{
    return mul(float4(v.position, 1), LightViewProjection);
}

struct GBuffer
{
    float4 albedo : SV_Target0;
    float4 normal : SV_Target1;
};

GBuffer GeometryPS(GeometryVarying v)
{
    // G-bufferに線形アルベド・粗さと法線を保存し、照明は後の合成パスで計算する。
    GBuffer o;
    float variation = WeatherMap.SampleLevel(LinearWrap, v.world.xz * 0.00018, 0).r;
    float grain = DetailNoise.SampleLevel(LinearWrap, v.world * 0.002, 0).r;
    float fine = DetailNoise.SampleLevel(LinearWrap, v.world * 0.027, 0).b;
    float wet = WeatherEffects.x;
    float3 albedo = v.material.rgb * lerp(0.8, 1.2, variation) * lerp(1, 0.62, wet);
    albedo *= lerp(0.68, 1.28, grain) * lerp(0.91, 1.07, fine);
    o.albedo = float4(albedo, lerp(v.material.a, 0.18, wet));
    o.normal = float4(normalize(v.normal) * 0.5 + 0.5, 0);
    return o;
}

struct ScreenVarying
{
    float4 position : SV_Position;
    float2 uv : TEXCOORD;
};

ScreenVarying FullscreenVS(uint id : SV_VertexID)
{
    ScreenVarying o;
    o.uv = float2((id << 1) & 2, id & 2);
    o.position = float4(o.uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

float3 surfaceLighting(float2 uv, float depth)
{
    // 深度から位置を復元し、GGXの反射と拡散反射に雲影・地形影を掛ける。
    float4 material = GAlbedo.SampleLevel(LinearClamp, uv, 0);
    float3 normal = normalize(GNormal.SampleLevel(LinearClamp, uv, 0).xyz * 2 - 1);
    float3 world = worldPosition(uv, depth), V = normalize(CameraTime.xyz - world),
           L = SunDirection.xyz;
    float3 H = normalize(V + L);
    float nl = saturate(dot(normal, L)), nv = max(dot(normal, V), 0.001);
    float nh = saturate(dot(normal, H)), vh = saturate(dot(V, H));
    float rough = max(material.a, 0.06), a2 = rough * rough * rough * rough;
    float denom = nh * nh * (a2 - 1) + 1;
    float D = a2 / (PI * denom * denom + 1e-6);
    float k = (rough + 1) * (rough + 1) / 8;
    float G = (nl / (nl * (1 - k) + k)) * (nv / (nv * (1 - k) + k));
    float3 F = 0.04 + 0.96 * pow(1 - vh, 5);
    float3 specular = D * G * F / max(4 * nl * nv, 0.001);
    float shadow = cloudShadow(world) * terrainShadow(world);
    float3 solar = SolarExposure.rgb * sunTransmittance(world);
    float3 direct = ((1 - F) * material.rgb / PI + specular) * solar * nl * shadow;
    float hemisphere = saturate(normal.y * 0.5 + 0.5);
    float3 ambient = lerp(float3(0.08, 0.075, 0.055), float3(0.29, 0.37, 0.49), hemisphere);
    ambient *= 0.04 + 0.96 * saturate(SunDirection.y * 3 + 0.15);
    ambient *= lerp(1, 0.58, Weather.z) * lerp(0.74, 1, cloudShadow(world));
    float3 flashDirection = normalize(LightningSource.xyz - world + float3(0, 0.001, 0));
    float3 flash = material.rgb * lightningIrradiance(world)
                   * (0.15 + 0.85 * saturate(dot(normal, flashDirection)));
    return direct + material.rgb * ambient + flash;
}

float4 upsampleClouds(float2 uv, float scene)
{
    // 低解像度の雲を4近傍から補間する。地形との距離差で重みを落とし縁漏れを抑える。
    float2 p = uv * RenderSize.xy - 0.5;
    int2 base = (int2)floor(p);
    float2 f = frac(p);
    float4 value = 0;
    float sum = 0;
    [unroll]
    for (int y = 0; y < 2; y++)
        [unroll]
        for (int x = 0; x < 2; x++)
        {
            int2 q = clamp(base + int2(x, y), int2(0, 0), (int2)RenderSize.xy - 1);
            float2 meta = CloudMetadata.Load(int3(q, 0));
            float weight = (x ? f.x : 1 - f.x) * (y ? f.y : 1 - f.y);
            float difference = abs(meta.y - scene) / max(scene * 0.035, 80);
            weight *= exp(-min(difference, 40));
            if (meta.x > scene + 100 && scene < Atmosphere.z * 0.99)
                weight *= 0.001;
            value += CloudTexture.Load(int3(q, 0)) * weight;
            sum += weight;
        }

    return sum > 0.00001 ? value / sum : float4(0, 0, 0, 1);
}

float3 aces(float3 x)
{
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

void upsampleAerial(float2 uv, float scene, out float3 scattering, out float3 transmission,
                   out float4 fog)
{
    // 空気遠近法・霧も深度差を考慮して補間する。
    uint w, h;
    AerialScatter.GetDimensions(w, h);
    float2 size = float2(w, h);
    float2 p = uv * size - 0.5;
    int2 base = (int2)floor(p);
    float2 f = frac(p);
    scattering = 0;
    transmission = 0;
    fog = 0;
    float sum = 0;
    [unroll]
    for (int y = 0; y < 2; y++)
        [unroll]
        for (int x = 0; x < 2; x++)
        {
            int2 q = clamp(base + int2(x, y), int2(0, 0), int2(w, h) - 1);
            float2 qUV = (q + 0.5) / size;
            float depth = sceneDistance(qUV);
            float difference = abs(depth - scene) / max(80, scene * 0.035);
            float weight = (x ? f.x : 1 - f.x) * (y ? f.y : 1 - f.y) * exp(-min(difference, 40));
            scattering += AerialScatter.Load(int3(q, 0)).rgb * weight;
            transmission += AerialTransmittance.Load(int3(q, 0)).rgb * weight;
            fog += FogTexture.Load(int3(q, 0)) * weight;
            sum += weight;
        }

    if (sum > 0.00001)
    {
        scattering /= sum;
        transmission /= sum;
        fog /= sum;
    }
    else
    {
        scattering = AerialScatter.SampleLevel(LinearClamp, uv, 0).rgb;
        transmission = AerialTransmittance.SampleLevel(LinearClamp, uv, 0).rgb;
        fog = FogTexture.SampleLevel(LinearClamp, uv, 0);
    }
}

// HDRの散乱光だけ表示用に変換する。透過率・深度・法線にはこの変換を掛けない。
float3 previewRadiance(float3 radiance)
{
    return pow(aces(max(radiance, 0) * SolarExposure.w), 1 / 2.2);
}

float2 fitTextureUV(float2 uv, float aspect, float screenAspect)
{
    float2 scale = screenAspect > aspect ? float2(screenAspect / aspect, 1)
                                         : float2(1, aspect / screenAspect);
    return (uv - 0.5) * scale + 0.5;
}

float3 noiseSlice(float2 uv)
{
    float slice = TextureInspection.x;
    if (TextureInspection.y < 0.5)
        return float3(slice, uv.x, uv.y);
    if (TextureInspection.y < 1.5)
        return float3(uv.x, slice, uv.y);
    return float3(uv, slice);
}

// C++のDebugViewと同じ番号。画面用テクスチャは画面UV、マップ類は元の縦横比で表示。
float4 textureDebugView(float2 uv, int view)
{
    float aspect = Resolution.x / Resolution.y;
    if (view == 2 || view == 6 || view == 7 || view == 8 || view == 9 || view == 11
        || view == 24 || view == 25 || view == 26 || view == 28)
        aspect = 1;
    else if (view == 18)
        aspect = 4;
    else if (view == 12)
        aspect = 320.0 / 180.0;
    else if (view == 19 || view == 20)
    {
        uint w, h;
        RawCloudTexture.GetDimensions(w, h);
        aspect = (float)w / h;
    }

    // 一覧パネルを表示中は、右側の空き領域へ縦横比を保って収める。
    float2 previewSize = Resolution.xy;
    if (TextureInspection.z > 0)
    {
        float2 origin = float2(TextureInspection.z, 24);
        previewSize = max(Resolution.xy - origin - float2(24, 84), 1);
        uv = (uv * Resolution.xy - origin) / previewSize;
    }
    uv = fitTextureUV(uv, aspect, previewSize.x / previewSize.y);

    if (any(uv < 0) || any(uv > 1))
        return float4(0.035, 0.045, 0.040, 1);

    if (view == 1)
        return float4(CloudTexture.SampleLevel(LinearClamp, uv, 0).aaa, 1);
    if (view == 2)
        return float4(CloudShadowMap.SampleLevel(LinearClamp, uv, 0).rrr, 1);
    if (view == 3)
        return float4(GNormal.SampleLevel(LinearClamp, uv, 0).rgb, 1);
    if (view == 4)
        return float4(pow(max(GAlbedo.SampleLevel(LinearClamp, uv, 0).rgb, 0), 1 / 2.2), 1);
    if (view == 5)
        return float4(previewRadiance(FogTexture.SampleLevel(LinearClamp, uv, 0).rgb), 1);
    if (view == 6)
        return float4(WeatherMap.SampleLevel(LinearWrap, uv, 0).rgb, 1);
    if (view == 7)
        return float4(BaseNoise.SampleLevel(LinearWrap, noiseSlice(uv), 0).rrr, 1);
    if (view == 8)
        return float4(DetailNoise.SampleLevel(LinearWrap, noiseSlice(uv), 0).rgb, 1);
    if (view == 9)
        return float4(BaseNoise.SampleLevel(LinearWrap, noiseSlice(uv), 0).gba, 1);
    if (view == 24)
        return float4(TowerControlVolume.SampleLevel(LinearClamp, noiseSlice(uv), 0).xxx, 1);
    if (view == 25)
        return float4(CloudWarpVolume.SampleLevel(LinearWrap, noiseSlice(uv), 0).rgb, 1);
    if (view == 26)
        return float4(CloudMap.SampleLevel(LinearWrap, uv, 0), 0, 1);
    if (view == 27)
        return float4(cloudHeightProfile(uv.y), 1);
    if (view == 28)
    {
        float2 moments = CloudShadowMap.SampleLevel(LinearClamp, uv, 0);
        float encoded = moments.y / max(1 - moments.x, 0.0001);
        float depth = moments.x >= 0.999 ? 1 : log(max(encoded, 1)) / CLOUD_SHADOW_EXPONENT;
        return float4(saturate(depth).xxx, 1);
    }
    if (view == 10)
    {
        // 通常の射影深度は遠方がほぼ白になるため、復元した距離を対数表示する。
        float depth = saturate(log2(1 + sceneDistance(uv)) / log2(1 + Atmosphere.z));
        return float4(depth.xxx, 1);
    }
    if (view == 11)
        return float4(TerrainShadow.SampleLevel(LinearClamp, uv, 0).xxx, 1);
    if (view == 12)
        return float4(previewRadiance(SkyTexture.SampleLevel(LinearClamp, uv, 0).rgb), 1);
    if (view == 13)
        return float4(previewRadiance(CloudTexture.SampleLevel(LinearClamp, uv, 0).rgb), 1);
    if (view == 14)
    {
        float distance = CloudMetadata.SampleLevel(LinearClamp, uv, 0).x;
        float depth = saturate(log2(1 + distance) / log2(1 + Atmosphere.z));
        return float4(depth.xxx, 1);
    }
    if (view == 15)
        return float4(previewRadiance(AerialScatter.SampleLevel(LinearClamp, uv, 0).rgb), 1);
    if (view == 16)
        return float4(AerialTransmittance.SampleLevel(LinearClamp, uv, 0).rgb, 1);
    if (view == 17)
        return float4(FogTexture.SampleLevel(LinearClamp, uv, 0).aaa, 1);
    if (view == 18)
        return float4(TransmittanceLUT.SampleLevel(LinearClamp, uv, 0).rgb, 1);
    if (view == 19)
        return float4(previewRadiance(RawCloudTexture.SampleLevel(LinearClamp, uv, 0).rgb), 1);
    if (view == 20)
        return float4(RawCloudTexture.SampleLevel(LinearClamp, uv, 0).aaa, 1);
    if (view == 21)
        return float4(GAlbedo.SampleLevel(LinearClamp, uv, 0).aaa, 1);
    if (view == 22)
        return float4(previewRadiance(RainTexture.SampleLevel(LinearClamp, uv, 0).rgb), 1);
    if (view == 23)
    {
        int2 pixel = min((int2)(uv * RenderSize.xy), (int2)RenderSize.xy - 1);
        uint state = CloudReconstruction.Load(int3(pixel, 0));
        return float4(state == 3 ? float3(0.25, 0.25, 0.25)
                                : (state == 0 ? float3(0.15, 0.85, 0.3)
                                : (state == 1 ? float3(0.15, 0.4, 1) : float3(1, 0.15, 0.1))), 1);
    }

    return float4(0, 0, 0, 1);
}

float4 CompositePS(ScreenVarying v) : SV_Target
{
    float2 uv = v.uv;
    if (Controls.x > 0)
        return textureDebugView(uv, (int)Controls.x);

    float depth = SceneDepth.SampleLevel(LinearClamp, uv, 0);
    float scene = sceneDistance(uv);
    bool geometry = depth < 0.999999;
    float3 ray = worldRay(uv);
    float3 sky = SkyTexture.SampleLevel(LinearClamp, uv, 0).rgb;
    float solarDisk =
        1 - smoothstep(0.0046, 0.0062, acos(clamp(dot(ray, SunDirection.xyz), -1, 1)));
    sky += solarDisk * SolarExposure.rgb * sunTransmittance(CameraTime.xyz) * 22;
    float4 cloud = upsampleClouds(uv, scene);
    float3 scattering, transmission;
    float4 fog;
    upsampleAerial(uv, scene, scattering, transmission, fog);

    // 線形色空間で背景・雲・空気遠近法・霧を合成する。cloud.a は透過率。
    float3 base = geometry ? surfaceLighting(uv, depth) * transmission + scattering : sky;
    float3 color = base * cloud.a + cloud.rgb * transmission + scattering * (1 - cloud.a);
    color = color * fog.a + fog.rgb;
    color += lightningBolt(ray, scene, cloud.a);
    float4 rain = RainTexture.SampleLevel(LinearClamp, uv, 0);
    color = color * (1 - rain.a) + rain.rgb;
    // 表示用のトーンマップとガンマ補正は、すべての照明・合成が済んでから行う。
    color = aces(max(color, 0) * SolarExposure.w);
    color = pow(color, 1 / 2.2);
    float dither = (hash12(v.position.xy + Wind.ww) - 0.5) / 255;
    return float4(saturate(color + dither), 1);
}
