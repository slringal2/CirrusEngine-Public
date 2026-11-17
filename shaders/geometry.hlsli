#ifndef CIRRUS_GEOMETRY
#define CIRRUS_GEOMETRY

cbuffer GeometryPass : register(b2)
{
    float4x4 GeometryProjection;
};

struct GBuffer
{
    float4 albedo : SV_Target0;
    float4 normal : SV_Target1;
    float4 surface : SV_Target2;
};

GBuffer encodeMaterial(float3 albedo, float roughness, float3 normal, float metallic,
                       float3 emissive, float occlusion)
{
    GBuffer o;
    o.albedo = float4(albedo, roughness);
    o.normal = float4(normalize(normal) * 0.5 + 0.5, metallic);
    o.surface = float4(emissive, occlusion);
    return o;
}

#endif
