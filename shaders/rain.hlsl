#include "common.hlsli"

struct RainVarying
{
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float3 world : TEXCOORD1;
    float opacity : TEXCOORD2;
};

// インスタンスごとに6頂点の細い四角形を作る。CPU側の雨粒バッファは不要。
RainVarying RainVS(uint vertex : SV_VertexID, uint instance : SV_InstanceID)
{
    RainVarying o = (RainVarying)0;
    float3 random = hash33(float3(instance + 1, instance * 0.37 + 11, 93.2));
    // 降水量の間引きは位置とは別の乱数を使い、雨域に偏った空白を作らない。
    float selection = hash12(float2(instance + 91.7, 31.3));
    float3 extent = float3(240, 140, 240);
    float3 velocity = float3(WeatherEffects.y * 0.30, -28 - random.z * 10, WeatherEffects.z * 0.30);

    // 世界座標上で風と重力に沿って移動し、カメラ周囲の箱の端でだけ循環させる。
    float3 drift = float3(Wind.x * 0.30, velocity.y * CameraTime.w, Wind.y * 0.30);
    float3 local = (frac((random * extent + drift - CameraTime.xyz) / extent + 0.5)
                    - 0.5) * extent;
    float3 p = CameraTime.xyz + local;
    float4 head = mul(float4(p, 1), ViewProjection);
    if (selection > Weather.y || head.w < 11 || p.y > CloudLayer.x + 80 || WeatherEffects.w < 0.5)
    {
        o.position = float4(-2, -2, 0, 1);
        return o;
    }

    // 短い露光時間の移動量を雨筋の長さにする。投影するのでカメラの向きにも追従する。
    float4 tail = mul(float4(p - velocity * 0.026, 1), ViewProjection);
    float2 headNdc = head.xy / head.w;
    float2 tailNdc = tail.xy / max(tail.w, 1);
    float2 screenDirection = (tailNdc - headNdc) * Resolution.xy;
    float2 perpendicular = normalize(float2(-screenDirection.y, screenDirection.x) + 1e-5);
    float2 width = perpendicular * (0.75 + random.y * 0.5) * Resolution.zw;
    static const float2 corners[6] = {
        float2(-1, 0), float2(-1, 1), float2(1, 0),
        float2(-1, 1), float2(1, 1), float2(1, 0)
    };
    float2 corner = corners[vertex];
    o.position = lerp(head, tail, corner.y);
    o.position.xy = (lerp(headNdc, tailNdc, corner.y) + width * corner.x) * o.position.w;
    o.uv = corner;
    o.world = p;
    float boundary = max(abs(local.x) / (extent.x * 0.5), abs(local.z) / (extent.z * 0.5));
    o.opacity = (1 - smoothstep(0.72, 1, boundary)) * (0.22 + random.y * 0.18)
                * saturate((Weather.y - selection) * 18);
    return o;
}

float4 RainPS(RainVarying v) : SV_Target
{
    float2 uv = v.position.xy * Resolution.zw;
    float distance = length(v.world - CameraTime.xyz);
    // 地形の後ろには雨を描かない。交差部分は柔らかく消して輪郭の縞を避ける。
    float fade = saturate((sceneDistance(uv) - distance) / 2);
    float profile = exp(-v.uv.x * v.uv.x * 2.5) * saturate(1 - abs(v.uv.y * 2 - 1));
    float alpha = saturate(v.opacity * profile * fade);
    float sunlight = saturate(SunDirection.y * 3 + 0.1);
    float3 color = float3(0.55, 0.66, 0.80) * (0.18 + sunlight * 0.28)
                   * lerp(0.55, 1, cloudShadow(v.world));
    color += lightningIrradiance(v.world) * 0.08;
    // RGBは乗算済みの散乱光、Aは雨粒の不透明度。HDRのまま最後の合成へ渡す。
    return float4(color * alpha, alpha);
}
