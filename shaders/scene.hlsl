#include "common.hlsli"
#include "lightning.hlsli"
#include "geometry.hlsli"
#include "meadow.hlsli"

Texture2D<float4> CompositeColor : register(t28);
Texture2D<float4> GroundMeadow : register(t37);
Texture2D<float4> GroundSoil : register(t38);
Texture2D<float4> GroundSoilNormal : register(t39);
Texture2D<float4> RiverGravel : register(t40);
Texture2D<float4> RiverGravelNormal : register(t41);
Texture2D<float4> RidgeRock : register(t42);
Texture2D<float4> RidgeRockNormal : register(t43);

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
    o.position = mul(float4(v.position, 1), GeometryProjection);
    o.normal = v.normal;
    o.material = v.material;
    o.world = v.position;
    return o;
}

float4 ShadowVS(Vertex v) : SV_Position
{
    return mul(float4(v.position, 1), GeometryProjection);
}

float3 ridgeWeights(float3 normal)
{
    float3 weights = abs(normal);
    weights *= weights * weights;
    return weights / dot(weights, 1.0.xxx);
}

GBuffer GeometryPS(GeometryVarying v)
{
    // G-bufferに線形アルベド・粗さと法線を保存し、照明は後の合成パスで計算する。
    float variation = WeatherMap.SampleLevel(LinearWrap, v.world.xz * 0.00018, 0).r;
    float grain = DetailNoise.SampleLevel(LinearWrap, v.world * 0.002, 0).r;
    float fine = DetailNoise.SampleLevel(LinearWrap, v.world * 0.027, 0).b;
    float wet = WeatherEffects.x;
    float3 albedo = v.material.rgb * lerp(0.8, 1.2, variation) * lerp(1, 0.62, wet);
    albedo *= lerp(0.68, 1.28, grain) * lerp(0.91, 1.07, fine);
    float3 normal = normalize(v.normal);
    float roughness = lerp(v.material.a, 0.18, wet);
    if (WorldRendering.x > 0.5)
    {
        float2 xz = v.world.xz;
        float z = xz.y;
        float ruts = DetailNoise.Sample(LinearWrap, v.world * float3(0.19, 0.17, 0.028)).g;
        float trail = meadowTrail(xz);
        float moisture = meadowMoisture(xz);
        float erosion = smoothstep(0.12, 0.45, 1 - normal.y);
        float soilCover = saturate(max(trail, (1 - smoothstep(0, 0.32, moisture)) * 0.38
                                               + erosion * 0.31));
        float3 grassTexture = GroundMeadow.Sample(LinearWrap, xz * 0.58).rgb;
        float fineCover = dot(grassTexture, float3(0.25, 0.64, 0.11));
        float3 meadow = meadowColor(moisture) * (0.66 + 0.92 * fineCover);
        float windSpeed = length(WeatherEffects.yz);
        float2 wind = WeatherEffects.yz / max(windSpeed, 0.01);
        float fieldWave = meadowGust(xz, wind);
        float distantGrass = smoothstep(65, 250, length(xz - CameraTime.xz));
        meadow *= 1 + (fieldWave - 0.5) * min(windSpeed / 20, 1.3) * distantGrass * 0.12;
        float3 earth = GroundSoil.Sample(LinearWrap, xz * 0.52).rgb * (0.70 + 0.32 * ruts);
        float bank = riverBankDistance(v.world.x, z);
        float gravel = (1 - smoothstep(-0.6, 5.4, bank + (ruts - 0.5) * 4))
                       * (1 - smoothstep(2180, riverExtent, abs(z)));
        float nearWater = (1 - smoothstep(0.05, 0.75, v.world.y - riverLevel(z))) * gravel;
        float3 pebbles = RiverGravel.Sample(LinearWrap, xz * 0.52).rgb
                         * lerp(1.08, 0.59, nearWater);
        float3 ground = lerp(meadow, earth, saturate(soilCover));
        ground = lerp(ground, pebbles, gravel);
        float scree = smoothstep(0.15, 0.43, 1 - normal.y);
        float exposed = saturate(max(scree, smoothstep(650, 1140, v.world.y))
                                 * (0.68 + 0.54 * grain));
        exposed *= 1 - max(gravel, trail);
        float3 projection = v.world * 0.013 + 0.34;
        float3 weights = ridgeWeights(normal);
        float3 ridge = RidgeRock.Sample(LinearWrap, projection.zy).rgb * weights.x
                       + RidgeRock.Sample(LinearWrap, projection.xz).rgb * weights.y
                       + RidgeRock.Sample(LinearWrap, projection.xy).rgb * weights.z;
        float fault = meadowNoise(xz * 0.0031 + float2(22, v.world.y * 0.0038));
        ridge *= 0.72 + 0.66 * fault;
        float stoneLuma = dot(ridge, float3(0.25, 0.64, 0.11));
        ridge = lerp(ridge, stoneLuma * float3(0.91, 1.00, 1.09), 0.72);
        float distant = smoothstep(310, 1600, length(xz - CameraTime.xz));
        float thicket = smoothstep(0.24, 0.72, meadowNoise(xz * 0.0064 + 16));
        thicket *= distant * (1 - smoothstep(640, 1020, v.world.y));
        ground *= lerp(1, float3(0.33, 0.51, 0.45), thicket * (1 - max(gravel, trail)));
        ground = lerp(ground, ridge, exposed);
        float snowline = 1120 + 290 * meadowNoise(xz * 0.005 + 27);
        float snow = smoothstep(snowline - 46, snowline + 102, v.world.y)
                     * smoothstep(0.42, 0.82, normal.y);
        ground = lerp(ground, float3(0.53, 0.59, 0.66) * (0.79 + 0.25 * fine), snow);
        albedo = ground * (0.77 + 0.45 * variation) * lerp(1, 0.62, wet);

        float3 soilNormal = GroundSoilNormal.Sample(LinearWrap, xz * 0.52).xyz * 2 - 1;
        float3 pebbleNormal = RiverGravelNormal.Sample(LinearWrap, xz * 0.52).xyz * 2 - 1;
        float2 bump = lerp(soilNormal.xy * (0.32 + 0.24 * soilCover), pebbleNormal.xy * 0.72,
                          gravel);
        float2 faceX = RidgeRockNormal.Sample(LinearWrap, projection.zy).xy * 2 - 1;
        float2 faceY = RidgeRockNormal.Sample(LinearWrap, projection.xz).xy * 2 - 1;
        float2 faceZ = RidgeRockNormal.Sample(LinearWrap, projection.xy).xy * 2 - 1;
        float3 ridgeBump = float3(0, -faceX.y, faceX.x) * weights.x
                           + float3(faceY.x, 0, -faceY.y) * weights.y
                           + float3(faceZ.x, -faceZ.y, 0) * weights.z;
        normal = normalize(normal + lerp(float3(bump.x, 0, -bump.y), ridgeBump * 0.37, exposed));
        roughness = lerp(roughness, 0.62, nearWater * (1 - wet));
    }
    return encodeMaterial(albedo, roughness, normal, 0, 0, 1);
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
    float4 packedNormal = GNormal.SampleLevel(LinearClamp, uv, 0);
    float4 surface = GSurface.SampleLevel(LinearClamp, uv, 0);
    float3 normal = normalize(packedNormal.xyz * 2 - 1);
    float metallic = saturate(packedNormal.w);
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
    float3 F0 = lerp(0.04, material.rgb, metallic);
    float3 F = F0 + (1 - F0) * pow(1 - vh, 5);
    float3 specular = D * G * F / max(4 * nl * nv, 0.001);
    // 地表と霧は同じ雲影・地形影を読む。直達光に太陽側の大気透過率も掛ける。
    float cloudVisibility = cloudShadow(world);
    float shadow = cloudVisibility * terrainShadow(world);
    float3 solar = SolarExposure.rgb * sunTransmittance(world);
    float3 diffuse = material.rgb * (1 - metallic);
    float3 direct = ((1 - F) * diffuse / PI + specular) * solar * nl * shadow;
    float hemisphere = saturate(normal.y * 0.5 + 0.5);
    float3 ambient = lerp(float3(0.08, 0.075, 0.055), float3(0.29, 0.37, 0.49), hemisphere);
    ambient *= 0.04 + 0.96 * saturate(SunDirection.y * 3 + 0.15);
    ambient *= lerp(1, 0.58, Weather.z) * lerp(0.74, 1, cloudVisibility);
    if (WorldRendering.x > 0.5)
    {
        // 歩行シーンでは天空の平均色を明るさで割り、間接光に空の色味を反映する。
        float3 skyLight = SkyAmbient.Load(int3(0, 0, 0)).rgb;
        float skyLuma = dot(skyLight, float3(0.213, 0.715, 0.072));
        float3 tint = clamp(skyLight / max(skyLuma, 0.014), 0.52, 1.45);
        ambient *= lerp(1, tint, 0.29);
    }
    if (WorldRendering.z > 0.5)
    {
        float night = smoothstep(0.025, 0.20, -L.y);
        float moon = 0.45 + 0.55 * saturate(dot(normal, -L));
        ambient += float3(0.018, 0.042, 0.080) * moon * night * lerp(1, 0.42, Weather.z);
    }
    float3 flashDirection = normalize(LightningSource.xyz - world + float3(0, 0.001, 0));
    float3 flash = (diffuse + metallic * F0) * lightningIrradiance(world)
                   * (0.15 + 0.85 * saturate(dot(normal, flashDirection)));
    // GSurface.a の大きさは間接光の遮蔽係数、負の符号は葉や草の透過光を足す目印。
    // 光源越しに見る角度ほど葉の透過光を強める。大気・雲と同じ太陽色を使う。
    float3 indirect = (diffuse + F0 * metallic * lerp(0.47, 0.16, rough)) * ambient * abs(surface.a);
    float forwardLight = pow(saturate(dot(-V, L)), 3);
    float3 leafTransmission = surface.a < 0
        ? diffuse * float3(0.84, 1.0, 0.34) * (0.035 + 0.17 * forwardLight) * solar
          * cloudVisibility * saturate(L.y * 3) * lerp(0.28, 1, shadow)
        : 0;
    return direct + indirect + flash + surface.rgb + leafTransmission;
}

#include "river_water.hlsli"

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
            // 通常のバイリニア重みに、シーン距離の差が大きいほど急に減る係数を掛ける。
            // 近傍の雲が現在の手前の地形より奥にある場合は、さらに重みを下げる。
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
    // 散乱光と透過率に同じ正規化重みを使い、遠景の霧が手前の輪郭ににじむのを抑える。
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
        || view == 24 || view == 25 || view == 26 || view == 28 || view == 30)
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
    if (view == 29)
        return float4(GNormal.SampleLevel(LinearClamp, uv, 0).aaa, 1);
    if (view == 30)
    {
        float depth = WorldRendering.y > 0.5 ? NearTerrainShadow.SampleLevel(LinearClamp, uv, 0) : 1;
        return float4(depth.xxx, 1);
    }
    if (view == 31)
    {
        float depth = geometryDepth(uv);
        float opaque = hasGeometry(depth) ? length(worldPosition(uv, depth) - CameraTime.xyz)
                                          : Atmosphere.z;
        float water = WorldRendering.x > 0.5
                      && riverSurfaceDistance(worldRay(uv), opaque) < opaque ? 1 : 0;
        return float4(water.xxx, 1);
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

    float depth = geometryDepth(uv);
    bool geometry = hasGeometry(depth);
    float3 ray = worldRay(uv);
    float opaque = geometry ? length(worldPosition(uv, depth) - CameraTime.xyz) : Atmosphere.z;
    float scene = opaque;
    [branch]
    if (WorldRendering.x > 0.5)
        scene = riverSurfaceDistance(ray, opaque);
    bool water = scene < opaque;
    float3 sky = SkyTexture.SampleLevel(LinearClamp, uv, 0).rgb;
    // 低解像度の空に太陽円盤を足す。位置と輪郭はフル解像度の視線、色は大気透過率で決まる。
    // ここに足した太陽光も、後段で空の一部として雲と霧による減衰を受ける。
    float solarDisk =
        1 - smoothstep(0.0046, 0.0062, acos(clamp(dot(ray, SunDirection.xyz), -1, 1)));
    sky += solarDisk * SolarExposure.rgb * sunTransmittance(CameraTime.xyz) * 22;
    if (WorldRendering.z > 0.5 && SunDirection.y < 0.02)
    {
        float night = 1 - smoothstep(-0.13, 0.02, SunDirection.y);
        float2 angles = float2(atan2(ray.x, ray.z), asin(clamp(ray.y, -1, 1)));
        float2 grid = angles * float2(185, 185);
        float2 cell = floor(grid);
        float2 center = 0.24 + 0.52 * float2(hash12(cell + 1.27), hash12(cell + 8.13));
        float star = (1 - smoothstep(0.07, 0.25, length(frac(grid) - center)))
                     * smoothstep(0.988, 1, hash12(cell)) * smoothstep(0, 0.18, ray.y);
        float moonDistance = acos(clamp(dot(ray, -SunDirection.xyz), -1, 1));
        float moon = 1 - smoothstep(0.0039, 0.0051, moonDistance);
        float halo = exp(-moonDistance * 9) * 0.012;
        sky += night * (float3(0.0010, 0.0028, 0.0062) * (0.55 + 0.45 * saturate(ray.y))
                        + float3(0.37, 0.43, 0.56) * (moon + halo) + star * 0.27);
    }
    float4 cloud = upsampleClouds(uv, scene);
    float3 scattering, transmission;
    float4 fog;
    upsampleAerial(uv, scene, scattering, transmission, fog);

    // 線形色空間で背景・雲・空気遠近法・霧を合成する。cloud.a は透過率。
    float3 surface = geometry ? surfaceLighting(uv, depth) : 0;
    [branch]
    if (water)
        surface = shadeRiver(uv, ray, scene, opaque, surface);
    // 地形と川面の色は空気を通って減衰し、途中の空気が散乱させた光が足される。
    // 空の背景色は SkyCS 側で大気散乱を積分済み。
    float3 base = geometry || water ? surface * transmission + scattering : sky;
    // 背景は雲の残存透過率を掛ける。雲自身の RGB は手前の空気の透過率を掛ける。
    // 雲が覆う割合 (1 - cloud.a) にも代表距離までに手前の空気が散乱させた光を足す。
    float3 color = base * cloud.a + cloud.rgb * transmission + scattering * (1 - cloud.a);
    // 霧は手前に重ね、A で背後の光を減衰させた後に RGB の霧散乱光を加える。
    color = color * fog.a + fog.rgb;
    color += lightningBolt(ray, scene, cloud.a);
    float4 rain = RainTexture.SampleLevel(LinearClamp, uv, 0);
    // RainPS の A は不透明度で RGB は乗算済み。背後の光に掛ける透過率は 1 - rain.a。
    color = color * (1 - rain.a) + rain.rgb;
    // 表示用のトーンマップとガンマ補正は、すべての照明・合成が済んでから行う。
    color = aces(max(color, 0) * SolarExposure.w);
    color = pow(color, 1 / 2.2);
    float dither = (hash12(v.position.xy + Wind.ww) - 0.5) / 255;
    return float4(saturate(color + dither), 1);
}

float luma(float3 color)
{
    return dot(color, float3(0.299, 0.587, 0.114));
}

// A single-pass luminance edge filter in the spirit of FXAA Console.
float4 ResolveEdgesPS(ScreenVarying v) : SV_Target
{
    float2 px = Resolution.zw;
    float3 center = CompositeColor.SampleLevel(LinearClamp, v.uv, 0).rgb;
    float nw = luma(CompositeColor.SampleLevel(LinearClamp, v.uv - px, 0).rgb);
    float ne = luma(CompositeColor.SampleLevel(LinearClamp, v.uv + float2(px.x, -px.y), 0).rgb);
    float sw = luma(CompositeColor.SampleLevel(LinearClamp, v.uv + float2(-px.x, px.y), 0).rgb);
    float se = luma(CompositeColor.SampleLevel(LinearClamp, v.uv + px, 0).rgb);
    float low = min(luma(center), min(min(nw, ne), min(sw, se)));
    float high = max(luma(center), max(max(nw, ne), max(sw, se)));
    float3 color = center;
    [branch]
    if (high - low > max(0.037, high * 0.125))
    {
        float2 edge = float2(sw + se - nw - ne, nw + sw - ne - se);
        float reduce = max((nw + ne + sw + se) * 0.027, 0.006);
        edge = clamp(edge / (min(abs(edge.x), abs(edge.y)) + reduce), -6, 6) * px;
        float3 inner = 0.5 * (CompositeColor.SampleLevel(LinearClamp, v.uv - edge / 6, 0).rgb
                             + CompositeColor.SampleLevel(LinearClamp, v.uv + edge / 6, 0).rgb);
        float3 outer = 0.5 * inner
            + 0.25 * (CompositeColor.SampleLevel(LinearClamp, v.uv - edge * 0.5, 0).rgb
                      + CompositeColor.SampleLevel(LinearClamp, v.uv + edge * 0.5, 0).rgb);
        color = luma(outer) < low || luma(outer) > high ? inner : outer;
    }
    return float4(color, 1);
}
