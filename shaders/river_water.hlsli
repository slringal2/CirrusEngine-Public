#ifndef CIRRUS_RIVER_WATER
#define CIRRUS_RIVER_WATER

float2 projectedUV(float4 clip)
{
    return clip.xy / max(clip.w, 0.001) * float2(0.5, -0.5) + 0.5;
}

float screenEdge(float2 uv)
{
    return min(min(uv.x, uv.y), min(1 - uv.x, 1 - uv.y));
}

float3 reflectedSky(float3 direction)
{
    float3 sky = SkyAmbient.Load(int3(0, 0, 0)).rgb
                 * (0.74 + 0.58 * exp(-max(0, direction.y) * 4));
    float4 clip = mul(float4(direction, 0), ViewProjection);
    float2 uv = projectedUV(clip);
    float coverage = smoothstep(0, 0.10, screenEdge(uv));
    [branch]
    if (clip.w > 0 && coverage > 0)
    {
        float3 localSky = SkyTexture.SampleLevel(LinearClamp, uv, 0).rgb;
        float4 clouds = CloudTexture.SampleLevel(LinearClamp, uv, 0);
        float cloudDistance = CloudMetadata.SampleLevel(LinearClamp, uv, 0).x;
        float depth = geometryDepth(uv);
        float opaque = hasGeometry(depth) ? length(worldPosition(uv, depth) - CameraTime.xyz)
                                          : Atmosphere.z;
        float cloudWeight = 1 - smoothstep(opaque * 0.94, opaque + 25, cloudDistance);
        localSky = lerp(localSky, localSky * clouds.a + clouds.rgb, cloudWeight);
        sky = lerp(sky, localSky, coverage);
    }
    return sky;
}

float reflectionDepthError(float4 clip, float2 uv, out float depth)
{
    depth = geometryDepth(uv);
    // With reversed Z, this is positive on the far side of the sampled object.
    return (clip.w * depth - clip.z) / max(depth, 0.000001);
}

float4 reflectRiverBank(float3 position, float3 direction, float distance)
{
    float4 origin = mul(float4(position + float3(0, 0.08, 0), 1), ViewProjection);
    float4 stepVector = mul(float4(direction, 0), ViewProjection);
    float previous = 0;
    float previousError = -1;
    float stride = 0.28 + distance * 0.006;
    float travel = stride;
    [loop]
    for (int i = 0; i < 15; ++i)
    {
        float4 clip = origin + stepVector * travel;
        float2 uv = projectedUV(clip);
        if (clip.w <= 0.15 || screenEdge(uv) <= 0 || travel > 210)
            break;
        float depth;
        float difference = reflectionDepthError(clip, uv, depth);
        if (hasGeometry(depth) && previousError <= 0 && difference > 0)
        {
            float low = previous, high = travel;
            [unroll]
            for (int j = 0; j < 4; ++j)
            {
                float middle = (low + high) * 0.5;
                float4 candidate = origin + stepVector * middle;
                float candidateDepth;
                if (reflectionDepthError(candidate, projectedUV(candidate), candidateDepth) > 0)
                    high = middle;
                else
                    low = middle;
            }
            clip = origin + stepVector * high;
            uv = projectedUV(clip);
            difference = reflectionDepthError(clip, uv, depth);
            float3 p = worldPosition(uv, max(depth, 0.000001));
            if (hasGeometry(depth) && p.y > riverLevel(p.z) + 0.09
                && difference < 0.25 + high * 0.021)
            {
                float thickness = 0.25 + high * 0.021;
                float confidence = smoothstep(0, 0.075, screenEdge(uv))
                                   * (1 - smoothstep(95, 210, high))
                                   * (1 - smoothstep(thickness * 0.28, thickness, difference));
                return float4(surfaceLighting(uv, depth), confidence);
            }
        }
        previous = travel;
        previousError = difference;
        stride *= 1.44;
        travel += stride;
    }
    return 0;
}

float3 riverNormal(float3 p, float distance)
{
    float2 flow = normalize(float2((riverCenter(p.z + 2) - riverCenter(p.z - 2)) * 0.25, 1));
    float2 across = float2(flow.y, -flow.x);
    // Long surface waves drift downstream. Small ripples get steeper in wind and rain.
    float current = lerp(0.36, 1.12, smoothstep(0.2, 11.0, -riverBankDistance(p.x, p.z)));
    float2 advected = p.xz - flow * (CameraTime.w * current);
    float u = dot(advected, flow), v = dot(advected, across);
    float gust = saturate(length(WeatherEffects.yz) / 34);
    float rain = smoothstep(0.1, 0.95, Weather.y);
    float warp = DetailNoise.SampleLevel(LinearWrap, float3(p.xz * 0.112, 0.43), 0).g;
    float longWave = cos(u * 1.66 + v * 0.51 + warp * 3.5);
    float crossWave = cos(u * 2.70 - v * 1.14 + warp * 4.7 + CameraTime.w * 0.65);
    float ripple = cos(u * 9.5 + v * 4.6 + warp * 9 - CameraTime.w * 2.0);
    float rippleFade = 1 - smoothstep(18, 75, distance);
    float2 slope = flow * (0.019 * longWave + 0.013 * crossWave)
                   + across * (0.010 * longWave - 0.013 * crossWave);
    slope += normalize(flow * 0.73 + across * 0.38) * ripple * rippleFade * (0.009 + 0.040 * rain);
    return normalize(float3(slope.x, 1, riverGrade + slope.y) * float3(0.70 + gust, 1, 0.70 + gust));
}

float3 shadeRiver(float2 uv, float3 ray, float distance, float opaqueDistance, float3 bottom)
{
    float3 p = CameraTime.xyz + ray * distance;
    float3 normal = riverNormal(p, distance);
    float nv = max(dot(normal, -ray), 0.012);
    float fresnel = 0.0204 + 0.9796 * pow(1 - saturate(nv), 5);
    float3 reflectionDirection = reflect(ray, normal);
    float3 reflected = reflectedSky(reflectionDirection);
    [branch]
    if (distance < 260 && fresnel > 0.066)
    {
        float4 bank = reflectRiverBank(p, reflectionDirection, distance);
        float weight = bank.a * (1 - smoothstep(140, 260, distance));
        reflected = lerp(reflected, bank.rgb, weight);
    }

    // 視線に沿った川面から川底までの距離 [m] を、水中を通る長さとして使う。
    float depth = min(opaqueDistance - distance, 18);
    float2 bentUV = uv + normal.xz * float2(0.19, -0.24) * saturate(depth * 0.21);
    [branch]
    if (depth < 6 && screenEdge(bentUV) > 0)
    {
        float bentDepth = geometryDepth(bentUV);
        float3 hit = worldPosition(bentUV, max(bentDepth, 0.000001));
        float submergence = riverLevel(hit.z) - hit.y;
        if (hasGeometry(bentDepth) && submergence > 0.025
            && abs(hit.z) < riverExtent && riverBankDistance(hit.x, hit.z) < 3.4
            && abs(length(hit - CameraTime.xyz) - opaqueDistance) < 3.5)
        {
            float blend = smoothstep(0.0, 0.9, depth) * 0.86;
            bottom = lerp(bottom, surfaceLighting(bentUV, bentDepth), blend);
        }
    }
    float sun = cloudShadow(p) * terrainShadow(p);
    float daylight = 0.035 + 0.965 * smoothstep(-0.08, 0.43, SunDirection.y);
    // absorption は RGB の残存透過率。赤の吸収が最も強く、距離とともに青緑が残る。
    float3 absorption = exp(-float3(0.56, 0.24, 0.19) * depth);
    float3 scatter = float3(0.023, 0.076, 0.066) * daylight * (0.70 + 0.30 * sun);
    scatter += float3(0.035, 0.083, 0.092) * lightningIrradiance(p);
    // 川底から届く光が弱まる分だけ水中の散乱色を混ぜる。大気の減衰は CompositePS で掛ける。
    float3 refracted = bottom * absorption + scatter * (1 - absorption);

    float3 halfVector = normalize(SunDirection.xyz - ray);
    float nh = saturate(dot(normal, halfVector));
    float roughness = lerp(0.069, 0.17, saturate(length(WeatherEffects.yz) / 36 + Weather.y * 0.3));
    float alphaSquared = pow(roughness, 4);
    float denom = nh * nh * (alphaSquared - 1) + 1;
    float lobe = alphaSquared / max(PI * denom * denom, 1e-7);
    float3 sunlight = SolarExposure.rgb * sunTransmittance(p);
    float3 glint = sunlight * min(3.0, 0.0204 * lobe / (4 * nv))
                   * saturate(SunDirection.y * 10) * sun;

    // Broken streaks of bubbles appear in fast, shallow water while fresh water stays clear.
    float bankDepth = depth * max(0.02, -ray.y);
    float grain = DetailNoise.SampleLevel(LinearWrap,
                                         float3(p.x * 0.76, 0.18, (p.z - CameraTime.w) * 0.42), 0).b;
    float foam = smoothstep(0.72, 0.91, grain) * smoothstep(0.02, 0.11, bankDepth)
                 * (1 - smoothstep(0.17, 0.61, bankDepth)) * (1 - smoothstep(70, 160, distance));
    float3 radiance = lerp(refracted, reflected, fresnel) + glint;
    return lerp(radiance, float3(0.31, 0.37, 0.36) * daylight, foam * 0.35);
}

#endif
