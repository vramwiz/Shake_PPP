Texture2D<float4> InputTexture : register(t0);
Texture2D<float> WeightTexture : register(t1);
SamplerState LinearClampSampler : register(s0);
RWTexture2D<float4> OutputTexture : register(u0);

cbuffer BulgeConstants : register(b0)
{
    uint4 ImageAndActiveOrigin; // width, height, activeLeft, activeTop
    uint4 ActiveSizeAndPadding; // activeWidth, activeHeight, unused, unused
    float4 AmountShapeCenterX;  // amount, shapeExponent, centerX, centerY
    float4 OuterAndGravity;     // halfWidth, halfHeight, gravityResponse, unused
    float4 GravityDirection;    // directionX, directionY, opacity, shading
    float4 DisplayAndLight;     // highlight, lightX, lightY, lightZ
    float4 HalfVector;          // halfX, halfY, halfZ, unused
};

float RawWeightAt(int2 pixel)
{
    if (pixel.x < 0 || pixel.y < 0 ||
        pixel.x >= int(ImageAndActiveOrigin.x) ||
        pixel.y >= int(ImageAndActiveOrigin.y))
        return 0.0;
    return WeightTexture.Load(int3(pixel, 0));
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
    float rawWeight = WeightTexture.Load(int3(pixel, 0));
    if (rawWeight <= 0.0)
        return;

    float shapeExponent = AmountShapeCenterX.y;
    float shapedWeight = DistributionWeight(rawWeight, shapeExponent);

    float2 center = AmountShapeCenterX.zw;
    float2 halfSize = max(OuterAndGravity.xy, float2(1.0, 1.0));
    float gravityResponse = OuterAndGravity.z;
    float2 gravityDirection = GravityDirection.xy;
    float2 position = float2(pixel);
    float projection = dot((position - center) / halfSize,
        gravityDirection);
    projection = clamp(projection, -1.0, 1.0);
    float gravityFactor = 1.0 + gravityResponse * projection * 0.75;
    float weight = saturate(shapedWeight * gravityFactor);

    float amount = AmountShapeCenterX.x;
    float scale = max(0.05, 1.0 + (amount - 1.0) * weight);
    float sagAmount = min(halfSize.x, halfSize.y) * 0.35 *
        gravityResponse * abs(amount - 1.0) * weight;
    float2 sag = gravityDirection * sagAmount;
    float2 sourcePosition = center + (position - center - sag) / scale;
    sourcePosition = clamp(sourcePosition, float2(0.0, 0.0),
        float2(ImageAndActiveOrigin.xy) - 1.0);
    float2 uv = (sourcePosition + 0.5) /
        float2(ImageAndActiveOrigin.xy);
    float4 output = InputTexture.SampleLevel(
        LinearClampSampler, uv, 0.0);

    float opacityResponse = GravityDirection.z;
    float shadingStrength = GravityDirection.w;
    float highlightStrength = DisplayAndLight.x;
    if (opacityResponse > 0.0 || shadingStrength > 0.0 ||
        highlightStrength > 0.0)
        output = floor(output * 255.0 + 0.5) / 255.0;

    if (shadingStrength > 0.0 || highlightStrength > 0.0)
    {
        int2 p = int2(pixel);
        float rawGradientX = (RawWeightAt(p + int2(1, 0)) -
            RawWeightAt(p - int2(1, 0))) * 0.5;
        float rawGradientY = (RawWeightAt(p + int2(0, 1)) -
            RawWeightAt(p - int2(0, 1))) * 0.5;
        float shapeSlope = DistributionSlope(rawWeight, shapeExponent);
        float2 gradient = float2(rawGradientX, rawGradientY) * shapeSlope;
        float unclampedProjection = dot((position - center) / halfSize,
            gravityDirection);
        if (gravityResponse > 0.000001 && abs(amount - 1.0) > 0.000001)
        {
            float2 gravityGradient = 0.0;
            if (unclampedProjection > -1.0 && unclampedProjection < 1.0)
                gravityGradient = gravityResponse * 0.75 *
                    gravityDirection / halfSize;
            if (shapedWeight * gravityFactor <= 0.0 ||
                shapedWeight * gravityFactor >= 1.0)
                gradient = 0.0;
            else
                gradient = gradient * gravityFactor +
                    shapedWeight * gravityGradient;
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
        float opacityFactor = 1.0 + opacityResponse *
            (1.0 / (scale * scale) - 1.0);
        output.a = saturate(output.a * opacityFactor);
    }
    OutputTexture[pixel] = floor(saturate(output) * 255.0 + 0.5) / 255.0;
}
