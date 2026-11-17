#include "common.hlsli"
#include "geometry.hlsli"

cbuffer Material : register(b3)
{
    float4 BaseColorFactor;
    float4 RoughMetalNormalAO; // x: metallic, y: roughness
    float4 EmissiveCutoff;
    uint4 MaterialFlags; // texture mask, mesh kind, two-sided, UV1 mask
};

Texture2D<float4> BaseColorTexture : register(t32);
Texture2D<float4> MetalRoughTexture : register(t33);
Texture2D<float4> NormalTexture : register(t34);
Texture2D<float4> OcclusionTexture : register(t35);
Texture2D<float4> EmissiveTexture : register(t36);
SamplerState BaseColorSampler : register(s3);
SamplerState MetalRoughSampler : register(s4);
SamplerState NormalSampler : register(s5);
SamplerState OcclusionSampler : register(s6);
SamplerState EmissiveSampler : register(s7);

struct MeshInput
{
    float3 position : POSITION;
    float3 normal : NORMAL;
    float4 tangent : TANGENT;
    float2 uv : TEXCOORD0;
    float2 uv1 : TEXCOORD1;
    float4 color : COLOR;
    float4 positionScale : INSTANCE0;
    float4 rotationVariation : INSTANCE1;
};

struct MeshVarying
{
    float4 position : SV_Position;
    float3 world : TEXCOORD0;
    float3 normal : TEXCOORD1;
    float4 tangent : TEXCOORD2;
    float4 uv : TEXCOORD3;
    float4 color : COLOR;
};

float3 rotateY(float3 p, float2 rotation)
{
    return float3(p.x * rotation.x + p.z * rotation.y, p.y,
                  p.z * rotation.x - p.x * rotation.y);
}

MeshVarying MeshVS(MeshInput v)
{
    MeshVarying o;
    o.world = rotateY(v.position, v.rotationVariation.xy) * v.positionScale.w + v.positionScale.xyz;
    if (MaterialFlags.y != 0)
    {
        float2 wind = normalize(WeatherEffects.yz + 0.0001);
        float sway = 0.35 + 0.65 * sin(CameraTime.w * 2.6 + v.rotationVariation.w
                                     + dot(v.positionScale.xz, float2(0.13, 0.08)));
        float bend = MaterialFlags.y == 1 ? 0.38 : 0.0018;
        float strength = min(length(WeatherEffects.yz) / 24, 1.5);
        o.world.xz += v.position.y * v.position.y * sway * bend * strength * wind * v.positionScale.w;
    }
    o.position = mul(float4(o.world, 1), GeometryProjection);
    o.normal = rotateY(v.normal, v.rotationVariation.xy);
    o.tangent = float4(rotateY(v.tangent.xyz, v.rotationVariation.xy), v.tangent.w);
    o.uv = float4(v.uv, v.uv1);
    o.color = float4(v.color.rgb * v.rotationVariation.z, v.color.a);
    return o;
}

float2 textureUV(MeshVarying v, uint mask)
{
    return (MaterialFlags.w & mask) != 0 ? v.uv.zw : v.uv.xy;
}

float4 baseColor(MeshVarying v)
{
    float4 value = v.color * BaseColorFactor;
    if ((MaterialFlags.x & 1) != 0)
        value *= BaseColorTexture.Sample(BaseColorSampler, textureUV(v, 1));
    return value;
}

void clipFoliage(MeshVarying v, float alpha)
{
    float cutoff = EmissiveCutoff.w;
    if (MaterialFlags.y == 3)
    {
        // Subpixel needles darken in averaged mips. Keep the silhouette of the whole spray.
        float2 footprint = fwidth(v.uv.xy);
        cutoff = lerp(cutoff, 0.069, smoothstep(0.018, 0.14, max(footprint.x, footprint.y)));
    }
    clip(alpha - cutoff);
}

float3 materialNormal(MeshVarying v, bool front)
{
    float3 normal = normalize(v.normal);
    if (!front && MaterialFlags.y == 0)
        normal = -normal;
    if ((MaterialFlags.x & 4) == 0)
        return normal;

    float2 uv = textureUV(v, 4);
    float3 sampleNormal = NormalTexture.Sample(NormalSampler, uv).xyz * 2 - 1;
    sampleNormal.xy *= RoughMetalNormalAO.z;
    float3 tangent;
    float handedness;
    if (abs(v.tangent.w) > 0.5 && (MaterialFlags.w & 4) == 0)
    {
        tangent = v.tangent.xyz;
        handedness = v.tangent.w;
    }
    else
    {
        // Derive the tangent frame from the actual UV set used by the normal texture.
        float2 dx = ddx(uv), dy = ddy(uv);
        float3 px = ddx(v.world), py = ddy(v.world);
        float det = dx.x * dy.y - dx.y * dy.x;
        if (abs(det) < 1e-10)
            return normal;
        tangent = (px * dy.y - py * dx.y) / det;
        float3 bitangent = (py * dx.x - px * dy.x) / det;
        handedness = dot(cross(normal, tangent), bitangent) < 0 ? -1 : 1;
    }
    tangent -= normal * dot(normal, tangent);
    if (dot(tangent, tangent) < 1e-10)
        return normal;
    tangent = normalize(tangent);
    float3 bitangent = cross(normal, tangent) * handedness;
    return normalize(tangent * sampleNormal.x + bitangent * sampleNormal.y + normal * sampleNormal.z);
}

GBuffer MeshPS(MeshVarying v, bool front : SV_IsFrontFace)
{
    float4 color = baseColor(v);
    if (EmissiveCutoff.w >= 0)
        clipFoliage(v, color.a);
    float metallic = RoughMetalNormalAO.x;
    float roughness = RoughMetalNormalAO.y;
    if ((MaterialFlags.x & 2) != 0)
    {
        float2 mr = MetalRoughTexture.Sample(MetalRoughSampler, textureUV(v, 2)).bg;
        metallic *= mr.x;
        roughness *= mr.y;
    }
    float ao = 1;
    if ((MaterialFlags.x & 8) != 0)
        ao = lerp(1, OcclusionTexture.Sample(OcclusionSampler, textureUV(v, 8)).r, RoughMetalNormalAO.w);
    float3 emission = EmissiveCutoff.rgb;
    if ((MaterialFlags.x & 16) != 0)
        emission *= EmissiveTexture.Sample(EmissiveSampler, textureUV(v, 16)).rgb;
    bool foliage = MaterialFlags.y == 1 || MaterialFlags.y == 3;
    if (MaterialFlags.y != 0)
    {
        color.rgb *= lerp(1, 0.73, WeatherEffects.x);
        roughness *= lerp(1, 0.63, WeatherEffects.x);
    }
    // Negative AO identifies thin foliage in the deferred lighting pass.
    return encodeMaterial(color.rgb, roughness, materialNormal(v, front), metallic, emission,
                          foliage ? -ao : ao);
}

void MeshShadowPS(MeshVarying v)
{
    clipFoliage(v, baseColor(v).a);
}
