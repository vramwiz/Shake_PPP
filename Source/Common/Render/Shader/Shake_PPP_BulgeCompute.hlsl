Texture2D<float4> InputTexture : register(t0);
Texture2D<float> WeightTexture : register(t1);
SamplerState LinearClampSampler : register(s0);
RWTexture2D<float4> OutputTexture : register(u0);

cbuffer BulgeConstants : register(b0)
{
    uint4 ImageAndActiveOrigin; // width, height, activeLeft, activeTop
    uint4 ActiveSizeAndPadding; // activeWidth, activeHeight, unused, unused
    float4 AmountShapeCenterX;  // amount, shapeExponent, centerX, centerY
    float4 OuterAndGravity;     // halfWidth, halfHeight, gravityResponse, variableOuter
    float4 GravityDirection;    // directionX, directionY, opacity, shading
    float4 DisplayAndLight;     // highlight, lightX, lightY, lightZ
    float4 HalfVector;          // halfX, halfY, halfZ, unused
    float4 MovableArc;          // startAngle, span, direction, enabled
};

float RawWeightAt(int2 pixel)
{
    if (pixel.x < 0 || pixel.y < 0 ||
        pixel.x >= int(ImageAndActiveOrigin.x) ||
        pixel.y >= int(ImageAndActiveOrigin.y))
        return 0.0;
    return WeightTexture.Load(int3(pixel, 0));
}

float SampleWeight(float2 position, bool coverageOnly)
{
    if (position.x < 0.0 || position.y < 0.0 ||
        position.x > float(ImageAndActiveOrigin.x - 1) ||
        position.y > float(ImageAndActiveOrigin.y - 1))
        return 0.0;
    int2 p0 = int2(position);
    int2 p1 = min(p0 + 1, int2(ImageAndActiveOrigin.xy) - 1);
    float2 fraction = position - float2(p0);
    float w00 = RawWeightAt(p0);
    float w01 = RawWeightAt(int2(p1.x, p0.y));
    float w10 = RawWeightAt(int2(p0.x, p1.y));
    float w11 = RawWeightAt(p1);
    if (coverageOnly)
    {
        w00 = w00 > 0.0 ? 1.0 : 0.0;
        w01 = w01 > 0.0 ? 1.0 : 0.0;
        w10 = w10 > 0.0 ? 1.0 : 0.0;
        w11 = w11 > 0.0 ? 1.0 : 0.0;
    }
    return lerp(lerp(w00, w01, fraction.x),
        lerp(w10, w11, fraction.x), fraction.y);
}

float DistributionWeight(float rawWeight, float exponent)
{
    if (abs(exponent - 1.0) <= 0.000001)
        return rawWeight;
    float scaled = saturate(rawWeight) * 2048.0;
    float index0 = floor(scaled);
    float index1 = min(index0 + 1.0, 2048.0);
    float value0 = pow(index0 / 2048.0, exponent);
    float value1 = pow(index1 / 2048.0, exponent);
    return lerp(value0, value1, scaled - index0);
}

float DistributionSlope(float rawWeight, float exponent)
{
    if (abs(exponent - 1.0) <= 0.000001)
        return 1.0;
    float index0 = floor(saturate(rawWeight) * 2048.0);
    float index1 = min(index0 + 1.0, 2048.0);
    return (pow(index1 / 2048.0, exponent) -
        pow(index0 / 2048.0, exponent)) * 2048.0;
}

[numthreads(16, 16, 1)]
void Main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    if (dispatchThreadId.x >= ActiveSizeAndPadding.x ||
        dispatchThreadId.y >= ActiveSizeAndPadding.y)
        return;

    uint2 pixel = ImageAndActiveOrigin.zw + dispatchThreadId.xy;
    float2 position = float2(pixel);
    float amount = AmountShapeCenterX.x;
    bool variableOuter = OuterAndGravity.w > 0.5;
    float2 center = AmountShapeCenterX.zw;
    float2 halfSize = max(OuterAndGravity.xy, float2(1.0, 1.0));
    float gravityResponse = OuterAndGravity.z;
    float2 gravityDirection = GravityDirection.xy;
    float2 radialDirection = (position - center) / halfSize;
    float radialLength = length(radialDirection);
    float mobility = 1.0;
    if (MovableArc.w > 0.5 && radialLength > 0.000001)
    {
        const float twoPi = 6.283185307179586;
        float angle = atan2(radialDirection.y, radialDirection.x);
        float distanceFromStart = fmod(MovableArc.z *
            (angle - MovableArc.x) + twoPi, twoPi);
        if (distanceFromStart > MovableArc.y)
            mobility = 0.0;
        else
        {
            // Broad quintic shoulder keeps the contour tangent and curvature
            // continuous where the movable arc joins the fixed arc.
            float fadeAngle = min(MovableArc.y * 0.5,
                0.785398163397448);
            if (fadeAngle > 0.000001)
            {
                float edgeDistance = min(distanceFromStart,
                    MovableArc.y - distanceFromStart);
                float t = saturate(edgeDistance / fadeAngle);
                mobility = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
            }
        }
    }
    float outerScale = variableOuter ? max(0.05,
        1.0 + (amount - 1.0) * 0.35 * mobility) : 1.0;
    float2 basePosition = variableOuter ?
        center + (position - center) / outerScale : position;
    float rawWeight = variableOuter ?
        SampleWeight(basePosition, false) :
        WeightTexture.Load(int3(pixel, 0));
    float coverage = variableOuter ?
        max(SampleWeight(position, true),
            SampleWeight(basePosition, true)) : 1.0;
    if ((!variableOuter && rawWeight <= 0.0) ||
        (variableOuter && coverage <= 0.0))
        return;

    float shapeExponent = AmountShapeCenterX.y;
    float shapedWeight = DistributionWeight(rawWeight, shapeExponent);

    float projection = dot((basePosition - center) / halfSize,
        gravityDirection);
    projection = clamp(projection, -1.0, 1.0);
    float gravityFactor = 1.0 + gravityResponse * projection * 0.75;
    float weight = saturate(shapedWeight * gravityFactor);

    float scale = variableOuter ?
        max(0.05, 1.0 + (amount / outerScale - 1.0) * weight) :
        max(0.05, 1.0 + (amount - 1.0) * weight);
    float sagAmount = min(halfSize.x, halfSize.y) * 0.35 *
        gravityResponse * abs(amount - 1.0) * weight;
    float2 sag = gravityDirection * sagAmount;
    float2 sourcePosition = variableOuter ?
        center + (basePosition - center - sag / outerScale) / scale :
        center + (position - center - sag) / scale;
    sourcePosition = clamp(sourcePosition, float2(0.0, 0.0),
        float2(ImageAndActiveOrigin.xy) - 1.0);
    float2 uv = (sourcePosition + 0.5) /
        float2(ImageAndActiveOrigin.xy);
    float4 output = InputTexture.SampleLevel(
        LinearClampSampler, uv, 0.0);
    if (variableOuter)
    {
        float4 original = InputTexture.Load(int3(pixel, 0));
        output = lerp(original, output, coverage);
    }

    float opacityResponse = GravityDirection.z;
    float shadingStrength = GravityDirection.w;
    float highlightStrength = DisplayAndLight.x;
    if (opacityResponse > 0.0 || shadingStrength > 0.0 ||
        highlightStrength > 0.0)
        output = floor(output * 255.0 + 0.5) / 255.0;

    if (shadingStrength > 0.0 || highlightStrength > 0.0)
    {
        int2 p = variableOuter ?
            clamp(int2(floor(basePosition + 0.5)), int2(0, 0),
                int2(ImageAndActiveOrigin.xy) - 1) : int2(pixel);
        float lightingRawWeight = RawWeightAt(p);
        float rawGradientX = (RawWeightAt(p + int2(1, 0)) -
            RawWeightAt(p - int2(1, 0))) * 0.5;
        float rawGradientY = (RawWeightAt(p + int2(0, 1)) -
            RawWeightAt(p - int2(0, 1))) * 0.5;
        float shapeSlope = DistributionSlope(lightingRawWeight,
            shapeExponent);
        float2 gradient = float2(rawGradientX, rawGradientY) * shapeSlope;
        float lightingShapedWeight = DistributionWeight(lightingRawWeight,
            shapeExponent);
        float unclampedProjection = dot((float2(p) - center) / halfSize,
            gravityDirection);
        if (gravityResponse > 0.000001 && abs(amount - 1.0) > 0.000001)
        {
            float2 gravityGradient = 0.0;
            if (unclampedProjection > -1.0 && unclampedProjection < 1.0)
                gravityGradient = gravityResponse * 0.75 *
                    gravityDirection / halfSize;
            float lightingGravityFactor = 1.0 + gravityResponse *
                clamp(unclampedProjection, -1.0, 1.0) * 0.75;
            if (lightingShapedWeight * lightingGravityFactor <= 0.0 ||
                lightingShapedWeight * lightingGravityFactor >= 1.0)
                gradient = 0.0;
            else
                gradient = gradient * lightingGravityFactor +
                    lightingShapedWeight * gravityGradient;
        }
        gradient *= (amount - 1.0) * min(halfSize.x, halfSize.y);
        float3 normal = normalize(float3(-gradient, 1.0));
        float3 light = DisplayAndLight.yzw;
        float shade = clamp(1.0 + shadingStrength * 1.25 *
            (dot(normal, light) - light.z), 0.25, 1.75);
        float specular = saturate(dot(normal, HalfVector.xyz));
        specular *= specular;
        specular *= specular;
        specular *= specular;
        specular *= specular;
        float highlight = saturate(highlightStrength * weight *
            min(1.0, abs(amount - 1.0) * 2.0) * specular);
        output.rgb = saturate(output.rgb * shade);
        output.rgb += (1.0 - output.rgb) * highlight;
    }

    if (opacityResponse > 0.0)
    {
        float totalScale = outerScale * scale;
        float opacityFactor = 1.0 + opacityResponse *
            (1.0 / (totalScale * totalScale) - 1.0);
        output.a = saturate(output.a * opacityFactor);
    }
    OutputTexture[pixel] = floor(saturate(output) * 255.0 + 0.5) / 255.0;
}
