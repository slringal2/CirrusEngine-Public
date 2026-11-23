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

// A Z row follows the river. The second coordinate measures signed distance from its centre.
// This chart stays continuous even far from the origin, including at the bends.
struct RiverSurface
{
    float3 normal;
    float bubbles;
    float riffle;
};

RiverSurface riverSurface(float3 p, float waterColumn, float footprint)
{
    float bankOffset = p.x - riverCenter(p.z);
    float channelSlope = (riverCenter(p.z + 2) - riverCenter(p.z - 2)) * 0.25;
    float channelWidth = riverHalfWidth(p.z);
    float fromShore = channelWidth - abs(bankOffset);
    float channel = smoothstep(0.3, 9.0, fromShore);
    float constriction = 1 - smoothstep(10.0, 19.5, channelWidth);

    // The 3.2-second charts overlap. Each reset happens at zero weight, so the
    // velocity difference between bank and centre never stretches a wave indefinitely.
    const float period = 3.2;
    const float meanSpeed = 0.84;
    float speed = lerp(0.42, 1.07 + 0.28 * constriction, channel);
    float phaseA = frac(CameraTime.w / period);
    float phaseB = frac(phaseA + 0.5);
    float blendA = 1 - abs(2 * phaseA - 1);
    float u = p.z - meanSpeed * CameraTime.w;
    float2 drift = (float2(phaseA, phaseB) - 0.5) * period * (speed - meanSpeed);
    float3 flowUV = float3(u * 0.041, bankOffset * 0.098, 0.37);
    float3 a = DetailNoise.SampleLevel(LinearWrap, flowUV - float3(drift.x * 0.041, 0, 0), 0).rgb;
    float3 b = DetailNoise.SampleLevel(LinearWrap, flowUV - float3(drift.y * 0.041, 0, 0), 0).rgb;
    float3 field = lerp(b, a, blendA);

    float rain = smoothstep(0.1, 0.95, Weather.y);
    float wind = saturate(length(WeatherEffects.yz) / 34);
    float shallow = smoothstep(0.045, 0.30, waterColumn) * (1 - smoothstep(0.75, 2.1, waterColumn));
    float riffle = shallow * channel * (0.4 + 0.6 * constriction) * smoothstep(0.24, 0.77, field.r);

    // Gradients in the river chart. Wave packets interrupt the crests and break
    // up reflected banks. The pixel's footprint extinguishes unresolved wavelengths.
    float longPhase = u * 1.7 + bankOffset * 0.40 + field.r * 4.8;
    float crossPhase = u * 3.8 - bankOffset * 2.15 + field.g * 4.0;
    float longSlope = cos(longPhase) * (0.021 + 0.027 * field.g) * (1 - smoothstep(0.35, 1.5, footprint));
    float crossSlope = cos(crossPhase) * (0.006 + 0.066 * riffle) * (1 - smoothstep(0.14, 0.70, footprint));
    float2 gradient = longSlope * float2(1, 0.24) + crossSlope * float2(1, -0.57);

    float ripplePhase = u * 11.1 + bankOffset * 5.2 + field.b * 6.0 - CameraTime.w * 1.2;
    float ripple = cos(ripplePhase) * (0.008 + 0.016 * wind + 0.027 * rain + 0.034 * riffle);
    gradient += ripple * float2(1, 0.47) * (1 - smoothstep(0.05, 0.25, footprint));
    gradient *= 0.62 + 0.55 * wind + 0.28 * field.r;
    RiverSurface surface;
    surface.normal = normalize(float3(-gradient.y, 1, riverGrade - gradient.x + channelSlope * gradient.y));
    surface.riffle = riffle;
    surface.bubbles = smoothstep(0.57, 0.83, field.b) * smoothstep(0.40, 0.73, field.g)
                      * riffle * (1 - smoothstep(0.06, 0.31, footprint));
    return surface;
}

float3 shadeRiver(float2 uv, float3 ray, float distance, float opaqueDistance, float3 bottom)
{
    float3 p = CameraTime.xyz + ray * distance;
    float path = min(max(opaqueDistance - distance, 0), 18);
    float belowSurface = max(0, -(ray.y + riverGrade * ray.z));
    // Use the uncapped ray length here. A long grazing ray can still reach a shallow bed.
    float column = max(0, opaqueDistance - distance) * belowSurface;
    float footprint = 2 * distance / (max(Resolution.y, 1) * max(0.02, belowSurface));
    RiverSurface surface = riverSurface(p, column, footprint);
    float3 normal = surface.normal;
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

    // Follow Snell's ray to an approximate bed depth, then test the projected hit
    // against opaque geometry. If the bed leaves the viewport, attenuation still works.
    [branch]
    if (column > 0.025 && column < 4.5 && distance < 155)
    {
        float3 waterRay = refract(ray, normal, 1.0 / 1.333);
        float travel = column / max(0.1, -(waterRay.y + riverGrade * waterRay.z));
        float3 predicted = p + waterRay * travel;
        float4 bentClip = mul(float4(predicted, 1), ViewProjection);
        float2 bentUV = projectedUV(bentClip);
        if (bentClip.w > 0.15 && screenEdge(bentUV) > 0)
        {
            float bentDepth = geometryDepth(bentUV);
            float3 hit = worldPosition(bentUV, max(bentDepth, 0.000001));
            float submergence = riverLevel(hit.z) - hit.y;
            float error = length(hit - predicted);
            float confidence = (1 - smoothstep(0.7, 2.4, error)) * smoothstep(0, 0.04, screenEdge(bentUV));
            confidence *= 1 - smoothstep(95, 155, distance);
            confidence *= 1 - smoothstep(3.5, 4.5, column);
            if (hasGeometry(bentDepth) && submergence > 0.025 && confidence > 0
                && abs(hit.z) < riverExtent && riverBankDistance(hit.x, hit.z) < 3.4)
            {
                bottom = lerp(bottom, surfaceLighting(bentUV, bentDepth), confidence);
                path = lerp(path, min(length(hit - p), 18), confidence);
            }
        }
    }
    float sun = cloudShadow(p) * terrainShadow(p);
    float daylight = 0.035 + 0.965 * smoothstep(-0.08, 0.43, SunDirection.y);
    // absorption は RGB の残存透過率。赤の吸収が最も強く、距離とともに青緑が残る。
    float3 absorption = exp(-float3(0.56, 0.24, 0.19) * path);
    float3 scatter = float3(0.023, 0.076, 0.066) * daylight * (0.70 + 0.30 * sun);
    scatter += float3(0.035, 0.083, 0.092) * lightningIrradiance(p);
    // 川底から届く光が弱まる分だけ水中の散乱色を混ぜる。大気の減衰は CompositePS で掛ける。
    float3 refracted = bottom * absorption + scatter * (1 - absorption);

    float3 halfVector = normalize(SunDirection.xyz - ray);
    float nh = saturate(dot(normal, halfVector));
    float roughness = lerp(0.069, 0.17, saturate(length(WeatherEffects.yz) / 36 + Weather.y * 0.3));
    roughness = min(0.26, roughness + 0.042 * surface.riffle + 0.036 * smoothstep(0.06, 0.58, footprint));
    float alphaSquared = pow(roughness, 4);
    float denom = nh * nh * (alphaSquared - 1) + 1;
    float lobe = alphaSquared / max(PI * denom * denom, 1e-7);
    float3 sunlight = SolarExposure.rgb * sunTransmittance(p);
    float3 glint = sunlight * min(3.0, 0.0204 * lobe / (4 * nv))
                   * saturate(SunDirection.y * 10) * sun;

    float3 radiance = lerp(refracted, reflected, fresnel) + glint;
    float3 bubbleLight = float3(0.45, 0.49, 0.46) * daylight * (0.55 + 0.45 * sun);
    return lerp(radiance, bubbleLight, surface.bubbles * 0.60);
}

#endif
