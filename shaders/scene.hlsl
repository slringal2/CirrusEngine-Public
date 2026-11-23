#include "common.hlsli"
#include "lightning.hlsli"
#include "geometry.hlsli"
#include "screen_lighting.hlsli"
#include "meadow.hlsli"

Texture2D<float4> CompositeColor : register(t28);
Texture2D<float4> CloudAerialScatter : register(t32);
Texture2D<float4> CloudAerialTransmittance : register(t33);
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

struct RidgeSurface
{
    float3 color;
    float3 bump;
};

// Use explicit gradients so the two rock mappings can crossfade at foothill elevations
// and fully skip the unused material above or below that narrow transition.
RidgeSurface sampleRidgeRock(float3 uv, float3 dx, float3 dy, float3 normal)
{
    float3 w = ridgeWeights(normal);
    RidgeSurface result;
    result.color = RidgeRock.SampleGrad(AnisotropicWrap, uv.zy, dx.zy, dy.zy).rgb * w.x
                   + RidgeRock.SampleGrad(AnisotropicWrap, uv.xz, dx.xz, dy.xz).rgb * w.y
                   + RidgeRock.SampleGrad(AnisotropicWrap, uv.xy, dx.xy, dy.xy).rgb * w.z;
    float2 faceX = RidgeRockNormal.SampleGrad(AnisotropicWrap, uv.zy, dx.zy, dy.zy).xy * 2 - 1;
    float2 faceY = RidgeRockNormal.SampleGrad(AnisotropicWrap, uv.xz, dx.xz, dy.xz).xy * 2 - 1;
    float2 faceZ = RidgeRockNormal.SampleGrad(AnisotropicWrap, uv.xy, dx.xy, dy.xy).xy * 2 - 1;
    result.bump = float3(0, -faceX.y, faceX.x) * w.x
                  + float3(faceY.x, 0, -faceY.y) * w.y
                  + float3(faceZ.x, -faceZ.y, 0) * w.z;
    return result;
}

struct RockPatch
{
    float3 color;
    float2 bump;
};

// Adjacent triangles use the same offsets at their shared vertices. Positions stay
// continuous through the blend, while neighbouring rock photographs start at different UVs.
RockPatch randomRockPatch(float2 uv, float2 dx, float2 dy)
{
    float2 lattice = float2(uv.x - uv.y * 0.57735027, uv.y * 1.15470054) * 0.84;
    float2 cell = floor(lattice), f = frac(lattice);
    bool upper = f.x + f.y > 1;
    float2 corner0 = upper ? cell + 1 : cell;
    float3 w = upper ? float3(f.x + f.y - 1, 1 - f.y, 1 - f.x)
                     : float3(1 - f.x - f.y, f.x, f.y);
    w = w * w * (3 - 2 * w);
    w /= dot(w, 1.0.xxx);
    RockPatch patch;
    patch.color = 0;
    patch.bump = 0;
    [unroll] for (int i = 0; i < 3; ++i)
    {
        float2 corner = i == 0 ? corner0 : (i == 1 ? cell + float2(1, 0) : cell + float2(0, 1));
        float2 offset = float2(hash12(corner + float2(23, 91)), hash12(corner + float2(159, 43)));
        float2 sampleUv = uv + offset;
        patch.color += w[i] * RidgeRock.SampleGrad(AnisotropicWrap, sampleUv, dx, dy).rgb;
        patch.bump += w[i] * (RidgeRockNormal.SampleGrad(AnisotropicWrap, sampleUv, dx, dy).xy * 2 - 1);
    }
    return patch;
}

// Rotate relative to the valley and bend the rock volume continuously. Like the colour,
// its normal map follows the deformed coordinates. The transpose of the deformation
// Jacobian maps the sampled height gradient back to world space before deferred lighting.
RidgeSurface mountainRock(float3 world, float3 normal)
{
    float mountain = smoothstep(260, 475, world.y);
    const float cosine = 0.88235294, sine = 0.47058824;
    float3x3 rotation = float3x3(cosine, 0, sine, 0, 1, 0, -sine, 0, cosine);
    float3 rockSpace = mul(rotation, world);
    const float3x3 frequency = float3x3(0, 0.011, 0.021, -0.013, 0, 0.017, 0.023, -0.012, 0);
    float3 wave, slope;
    sincos(mul(frequency, rockSpace) + float3(0.7, 1.6, 2.8), wave, slope);
    const float3 amplitude = float3(15, 18, 14);
    float3 coarseUv = world * 0.013 + 0.34;
    float3 alpineUv = (rockSpace + amplitude * wave) * 0.040 + 0.34;
    float3 coarseDx = ddx(coarseUv), coarseDy = ddy(coarseUv);
    float3 alpineDx = ddx(alpineUv), alpineDy = ddy(alpineUv);
    RidgeSurface result;
    result.color = 0;
    result.bump = 0;
    [branch] if (mountain < 1)
    {
        RidgeSurface low = sampleRidgeRock(coarseUv, coarseDx, coarseDy, normal);
        result.color = low.color * (1 - mountain);
        result.bump = low.bump * (1 - mountain);
    }
    [branch] if (mountain > 0)
    {
        float3 w = ridgeWeights(mul(rotation, normal));
        RockPatch x = randomRockPatch(alpineUv.zy, alpineDx.zy, alpineDy.zy);
        RockPatch y = randomRockPatch(alpineUv.xz, alpineDx.xz, alpineDy.xz);
        RockPatch z = randomRockPatch(alpineUv.xy, alpineDx.xy, alpineDy.xy);
        float3 color = x.color * w.x + y.color * w.y + z.color * w.z;
        float3 bump = float3(0, -x.bump.y, x.bump.x) * w.x
                      + float3(y.bump.x, 0, -y.bump.y) * w.y
                      + float3(z.bump.x, -z.bump.y, 0) * w.z;
        float3 gradient = bump + mul(bump * amplitude * slope, frequency);
        result.color += color * mountain;
        result.bump += mul(gradient, rotation) * mountain;
    }
    return result;
}

// 細かい模様は1画素に入らなくなったら平均値へ寄せる。上空での斑点や格子を抑える。
float filteredTerrainNoise(float2 p)
{
    float footprint = max(length(ddx(p)), length(ddy(p)));
    return lerp(meadowNoise(p), 0.5, smoothstep(0.28, 1.10, footprint));
}

GBuffer GeometryPS(GeometryVarying v)
{
    // G-bufferに線形アルベド・粗さと法線を保存し、照明は後の合成パスで計算する。
    float variation = WeatherMap.SampleLevel(LinearWrap, v.world.xz * 0.00018, 0).r;
    float grain = DetailNoise.Sample(LinearWrap, v.world * 0.002).r;
    float fine = DetailNoise.Sample(LinearWrap, v.world * 0.027).b;
    float wet = WeatherEffects.x;
    float3 albedo = v.material.rgb * lerp(0.8, 1.2, variation) * lerp(1, 0.62, wet);
    albedo *= lerp(0.68, 1.28, grain) * lerp(0.91, 1.07, fine);
    float3 normal = normalize(v.normal);
    float roughness = lerp(v.material.a, 0.18, wet);
    if (WorldRendering.x > 0.5)
    {
        float2 xz = v.world.xz;
        float z = xz.y;
        float distance = length(v.world - CameraTime.xyz);
        // 世界座標で複数の縮尺を混ぜ、同じ向きの模様が遠方まで並ぶのを避ける。
        float2 turned = float2(xz.x * 0.81 - z * 0.5864, xz.x * 0.5864 + z * 0.81);
        float region = filteredTerrainNoise(turned * 0.00115 + float2(37, 18));
        float patches = filteredTerrainNoise(xz * 0.0048 + float2(16, 41));
        float meadowRegion = smoothstep(0.19, 0.81, 0.68 * region + 0.32 * patches);
        float ruts = DetailNoise.Sample(LinearWrap, v.world * float3(0.19, 0.17, 0.028)).g;
        float trail = meadowTrail(xz);
        float moisture = lerp(meadowMoisture(xz), meadowRegion, smoothstep(320, 1350, distance));
        float erosion = smoothstep(0.12, 0.45, 1 - normal.y);
        float soilCover = saturate(max(trail, (1 - smoothstep(0, 0.32, moisture)) * 0.38
                                               + erosion * 0.31));
        float3 grassFine = GroundMeadow.Sample(AnisotropicWrap, xz * 0.58).rgb;
        float3 grassWide = GroundMeadow.Sample(AnisotropicWrap, turned * 0.21 + float2(6.2, 1.9)).rgb;
        float3 grassTexture = lerp(grassFine, grassWide, 0.36 + 0.22 * patches);
        float fineCover = dot(grassTexture, float3(0.25, 0.64, 0.11));
        float3 grassTint = lerp(float3(1.15, 1.04, 0.84), float3(0.89, 1.04, 0.93), meadowRegion);
        float3 meadow = meadowColor(moisture) * grassTint * (0.73 + 0.77 * fineCover);
        float windSpeed = length(WeatherEffects.yz);
        float2 wind = WeatherEffects.yz / max(windSpeed, 0.01);
        float fieldWave = meadowGust(xz, wind);
        float grassMotion = smoothstep(65, 250, distance) * (1 - smoothstep(700, 1700, distance));
        meadow *= 1 + (fieldWave - 0.5) * min(windSpeed / 20, 1.3) * grassMotion * 0.12;
        float3 soilFine = GroundSoil.Sample(AnisotropicWrap, xz * 0.52).rgb;
        float3 soilWide = GroundSoil.Sample(AnisotropicWrap, turned * 0.17 + float2(4.1, 2.3)).rgb;
        float3 earth = lerp(soilFine, soilWide, 0.30 + 0.19 * region) * (0.79 + 0.26 * ruts);
        float bank = riverBankDistance(v.world.x, z);
        float gravel = (1 - smoothstep(-0.6, 5.4, bank + (ruts - 0.5) * 4))
                       * (1 - smoothstep(2180, riverExtent, abs(z)));
        float nearWater = (1 - smoothstep(0.05, 0.75, v.world.y - riverLevel(z))) * gravel;
        float3 pebbles = RiverGravel.Sample(AnisotropicWrap, xz * 0.52).rgb
                         * lerp(1.08, 0.59, nearWater);
        float3 ground = lerp(meadow, earth, saturate(soilCover));
        ground = lerp(ground, pebbles, gravel);
        // Open-world COLOR.x stores the signed neighbourhood height difference from the DEM.
        float hollow = max(v.material.x, 0.0);
        float crest = max(-v.material.x, 0.0);
        float alpine = smoothstep(590, 1040, v.world.y);
        float cliff = smoothstep(0.13, 0.42, 1 - normal.y);
        float exposed = saturate(max(cliff, alpine * (0.80 + 0.38 * crest - 0.27 * hollow))
                                 * (0.78 + 0.46 * grain));
        exposed *= 1 - max(gravel, trail);
        RidgeSurface rockSample = mountainRock(v.world, normal);
        float3 ridge = rockSample.color;
        // Use world-space fractures at the scale of a cliff face. Pixel derivatives fade
        // undersampled structure to its mean; near rock grain still comes from the photos.
        float fault = filteredTerrainNoise(xz * 0.0031 + float2(22, v.world.y * 0.0038));
        float2 rockPlane = float2(dot(xz, float2(0.0084, 0.0041)),
                                  v.world.y * 0.014 + dot(xz, float2(0.0018, -0.0036)));
        float fracture = filteredTerrainNoise(rockPlane);
        float joints = smoothstep(0.56, 0.82, fracture) * (0.45 + 0.55 * cliff);
        float stoneLuma = dot(ridge, float3(0.25, 0.64, 0.11));
        float3 rockTint = lerp(float3(0.83, 0.91, 1.02), float3(1.18, 1.04, 0.87), fault);
        ridge = lerp(ridge, stoneLuma * rockTint, 0.77);
        ridge *= (0.75 + 0.66 * fault) * (1 - 0.27 * joints);
        float distant = smoothstep(310, 1600, distance);
        float thicket = smoothstep(0.40, 0.79, 0.60 * meadowRegion + 0.40 * patches);
        thicket *= distant * (1 - smoothstep(640, 1020, v.world.y));
        ground *= lerp(1, float3(0.62, 0.74, 0.64), thicket * (1 - max(gravel, trail)));
        ground = lerp(ground, ridge, exposed);
        // Loose rock gathers below scarps. A stable aspect term keeps the snow pattern
        // fixed through time of day, while the existing lighting pass moves the shadows.
        float talus = alpine * hollow * smoothstep(0.52, 0.82, normal.y) * (1 - gravel);
        float pebbleLuma = dot(pebbles, float3(0.25, 0.64, 0.11));
        float3 debris = float3(0.88, 0.83, 0.75) * (0.065 + 0.48 * stoneLuma + 0.42 * pebbleLuma);
        ground = lerp(ground, debris, talus);
        float snowLine = 1330 + (patches - 0.5) * 115 + (region - 0.5) * 135
                         + 175 * crest - 245 * hollow - 92 * normal.z;
        float snowShelf = smoothstep(0.50 - 0.14 * hollow, 0.86 - 0.15 * hollow, normal.y);
        float snow = smoothstep(snowLine - 55, snowLine + 85, v.world.y) * snowShelf;
        ground = lerp(ground, float3(0.69, 0.74, 0.78) * (0.92 + 0.10 * fine), snow);
        albedo = ground * (0.77 + 0.45 * variation) * lerp(1, 0.62, wet);

        float3 soilNormal = GroundSoilNormal.Sample(AnisotropicWrap, xz * 0.52).xyz * 2 - 1;
        float3 pebbleNormal = RiverGravelNormal.Sample(AnisotropicWrap, xz * 0.52).xyz * 2 - 1;
        float2 bump = lerp(soilNormal.xy * (0.32 + 0.24 * soilCover), pebbleNormal.xy * 0.72,
                          gravel);
        float3 ridgeBump = rockSample.bump;
        float groundDetail = 1 - smoothstep(62, 480, distance);
        float rockDetail = 1 - smoothstep(750, 3400, distance);
        float3 groundBump = float3(bump.x, 0, -bump.y) * groundDetail;
        float3 materialBump = lerp(groundBump, ridgeBump * (0.40 * rockDetail), exposed);
        normal = normalize(normal + materialBump * (1 - 0.85 * snow));
        float dryRoughness = lerp(lerp(v.material.a, 0.77, exposed), 0.96, talus);
        roughness = lerp(dryRoughness, lerp(0.18, 0.33, exposed), wet);
        roughness = lerp(roughness, 0.84, snow);
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
    float3 halfVector = V + L;
    float3 H = halfVector * rsqrt(max(dot(halfVector, halfVector), 1e-8));
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
    // 通常の地形影と、草・接触影のうち最も強い遮蔽を直射光に使う。
    float2 localVisibility = sampleScreenLighting(uv, depth, normal);
    float cloudVisibility = cloudShadow(world);
    float geometryVisibility = min(terrainShadow(world), grassShadowVisibility(world, normal));
    float shadow = cloudVisibility * min(geometryVisibility, localVisibility.g);
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
    float ambientVisibility = abs(surface.a) * localVisibility.r;
    float3 indirect = (diffuse + F0 * metallic * lerp(0.47, 0.16, rough)) * ambient * ambientVisibility;
    float forwardLight = pow(saturate(dot(-V, L)), 3);
    float3 leafTransmission = surface.a < 0
        ? diffuse * float3(0.84, 1.0, 0.34) * (0.035 + 0.17 * forwardLight) * solar
          * cloudVisibility * saturate(L.y * 3) * lerp(0.28, 1, shadow)
        : 0;
    // 雲影で失われた直射とは別に、空と周囲の地表から届く拡散光を足す。
    float overcastFill = (1 - saturate(cloudVisibility)) * smoothstep(-0.035, 0.22, L.y);
    float3 shadowFill = diffuse * float3(0.19, 0.19, 0.17) * overcastFill
                        * lerp(0.36, 1, hemisphere) * lerp(0.46, 1, abs(surface.a));
    return direct + indirect + shadowFill + flash + surface.rgb + leafTransmission;
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

struct AerialSample
{
    float3 scattering;
    float3 transmission;
    float4 fog;
    float3 cloudScattering;
    float3 cloudTransmission;
};

AerialSample upsampleAerial(float2 uv, float scene, bool hasCloud)
{
    // 背景では地形の輪郭を保ち、雲では雲がある近傍を使って補間する。
    uint w, h;
    AerialScatter.GetDimensions(w, h);
    float2 size = float2(w, h);
    float2 p = uv * size - 0.5;
    int2 base = (int2)floor(p);
    float2 f = frac(p);
    AerialSample sampleValue;
    sampleValue.scattering = 0;
    sampleValue.transmission = 0;
    sampleValue.fog = 0;
    sampleValue.cloudScattering = 0;
    sampleValue.cloudTransmission = 1;
    float3 cloudScattering = 0, cloudTransmission = 0;
    float sum = 0, cloudSum = 0;
    [unroll]
    for (int y = 0; y < 2; y++)
        [unroll]
        for (int x = 0; x < 2; x++)
        {
            int2 q = clamp(base + int2(x, y), int2(0, 0), int2(w, h) - 1);
            float2 qUV = (q + 0.5) / size;
            float depth = sceneDistance(qUV);
            float depthTolerance = max(80, scene * 0.035);
            float bilinear = (x ? f.x : 1 - f.x) * (y ? f.y : 1 - f.y);
            float difference = abs(depth - scene) / depthTolerance;
            float weight = bilinear * exp(-min(difference, 40));
            sampleValue.scattering += AerialScatter.Load(int3(q, 0)).rgb * weight;
            sampleValue.transmission += AerialTransmittance.Load(int3(q, 0)).rgb * weight;
            sampleValue.fog += FogTexture.Load(int3(q, 0)) * weight;
            sum += weight;

            [branch]
            if (hasCloud)
            {
                float4 cloudS = CloudAerialScatter.Load(int3(q, 0));
                float4 cloudT = CloudAerialTransmittance.Load(int3(q, 0));
                float behindSurface = max(cloudT.a * 100000 - scene, 0) / depthTolerance;
                float cloudWeight = bilinear * cloudS.a * exp(-min(behindSurface, 40));
                cloudScattering += cloudS.rgb * cloudWeight;
                cloudTransmission += cloudT.rgb * cloudWeight;
                cloudSum += cloudWeight;
            }
        }

    if (sum > 0.00001)
    {
        sampleValue.scattering /= sum;
        sampleValue.transmission /= sum;
        sampleValue.fog /= sum;
    }
    else
    {
        sampleValue.scattering = AerialScatter.SampleLevel(LinearClamp, uv, 0).rgb;
        sampleValue.transmission = AerialTransmittance.SampleLevel(LinearClamp, uv, 0).rgb;
        sampleValue.fog = FogTexture.SampleLevel(LinearClamp, uv, 0);
    }
    if (cloudSum > 0.00001)
    {
        sampleValue.cloudScattering = cloudScattering / cloudSum;
        sampleValue.cloudTransmission = cloudTransmission / cloudSum;
    }
    return sampleValue;
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
        || view == 24 || view == 25 || view == 26 || view == 28 || view == 30
        || (view >= 35 && view <= 37))
        aspect = 1;
    else if (view == 38 || view == 39)
    {
        uint w = 0, h = 0;
        if (view == 38)
            HighCloudTypeMap.GetDimensions(w, h);
        else
            HighCloudCoverageMap.GetDimensions(w, h);
        aspect = w > 0 && h > 0 ? (float)w / h : 1;
    }
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
        return float4(CloudMap.SampleLevel(LinearWrap, uv, 0).rg, 0, 1);
    if (view == 27)
        return float4(cloudHeightProfile(uv.y), 1);
    if (view >= 35 && view <= 37)
    {
        float4 texel = sampleTextureCloudMap(view - 35, uv, 0);
        float value = texel.r * texel.a;
        return float4(value.xxx, 1);
    }
    if (view == 38)
        return float4(HighCloudTypeMap.SampleLevel(LinearClamp, uv, 0).xxx, 1);
    if (view == 39)
        return float4(HighCloudCoverageMap.SampleLevel(LinearClamp, uv, 0).xxx, 1);
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
    if (view >= 32 && view <= 34)
    {
        float depth = geometryDepth(uv);
        float visibility = 1;
        if (hasGeometry(depth))
        {
            float3 normal = normalize(GNormal.SampleLevel(LinearClamp, uv, 0).xyz * 2 - 1);
            if (view == 34)
                visibility = grassShadowVisibility(worldPosition(uv, depth), normal);
            else
            {
                float2 screen = sampleScreenLighting(uv, depth, normal);
                visibility = view == 32 ? screen.r : screen.g;
            }
        }
        return float4(visibility.xxx, 1);
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
        uint state = CloudReconstruction.Load(int3(pixel, 0)) & 3u;
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
    float4 farCloud = upsampleClouds(uv, scene);
    float4 nearCloud = sampleNearCloud(uv, ray, scene).color;
    float cloudT = nearCloud.a * farCloud.a;
    AerialSample aerial = upsampleAerial(uv, scene, cloudT < 0.9999);

    // 線形色空間で背景・雲・空気遠近法・霧を合成する。cloud.a は透過率。
    float3 surface = geometry ? surfaceLighting(uv, depth) : 0;
    [branch]
    if (water)
        surface = shadeRiver(uv, ray, scene, opaque, surface);
    // 地形と川面の色は空気を通って減衰し、途中の空気が散乱させた光が足される。
    // 空の背景色は SkyCS 側で大気散乱を積分済み。
    float3 base = geometry || water ? surface * aerial.transmission + aerial.scattering : sky;
    base = base * aerial.fog.a + aerial.fog.rgb;
    // 手前と奥の雲の散乱光を合成してから、カメラと雲の間にある大気と霧を掛ける。
    // 薄い雲の隙間から見える背景は、背景までの大気と霧を通った色のまま透過する。
    float3 cloudRadiance = nearCloud.rgb + nearCloud.a * farCloud.rgb;
    float3 color = base * cloudT + cloudRadiance * aerial.cloudTransmission
                   + aerial.cloudScattering * (1 - cloudT);
    color += lightningBolt(ray, scene, cloudT);
    float4 rain = RainTexture.SampleLevel(LinearClamp, uv, 0);
    // RainPS の A は不透明度で RGB は乗算済み。背後の光に掛ける透過率は 1 - rain.a。
    color = color * (1 - rain.a) + rain.rgb;
    // 表示用のトーンマップとガンマ補正は、すべての照明・合成が済んでから行う。
    color = aces(max(color, 0) * SolarExposure.w);
    color = pow(color, 1 / 2.2);
    // Low/Mediumは表示用の1階調のディザも固定し、静止部分に毎フレームのきらつきを加えない。
    float ditherPhase = CloudSampling.y > 0.5 ? 0 : Wind.w;
    float dither = (hash12(v.position.xy + ditherPhase) - 0.5) / 255;
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
