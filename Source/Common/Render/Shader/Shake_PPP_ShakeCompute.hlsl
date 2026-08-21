Texture2D<float4> InputTexture : register(t0);
Texture2D<float> WeightTexture : register(t1);
SamplerState LinearClampSampler : register(s0);
RWTexture2D<float4> OutputTexture : register(u0);

cbuffer ShakeConstants : register(b0)
{
    uint4 ImageAndActiveOrigin;
    uint4 ActiveSizeAndPadding;
    float4 DisplacementAndMode;
    float4 PaddingA;
    float4 PaddingB;
};

float LoadWeight(int2 pixel, bool coverageOnly)
{
    if (pixel.x < 0 || pixel.y < 0 ||
        pixel.x >= int(ImageAndActiveOrigin.x) ||
        pixel.y >= int(ImageAndActiveOrigin.y))
        return 0.0;
    float value = WeightTexture.Load(int3(pixel, 0));
    return coverageOnly ? (value > 0.0 ? 1.0 : 0.0) : value;
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
    float top = lerp(LoadWeight(p0, coverageOnly),
        LoadWeight(int2(p1.x, p0.y), coverageOnly), fraction.x);
    float bottom = lerp(LoadWeight(int2(p0.x, p1.y), coverageOnly),
        LoadWeight(p1, coverageOnly), fraction.x);
    return lerp(top, bottom, fraction.y);
}

[numthreads(16, 16, 1)]
void Main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    if (dispatchThreadId.x >= ActiveSizeAndPadding.x ||
        dispatchThreadId.y >= ActiveSizeAndPadding.y)
        return;

    uint2 pixel = ImageAndActiveOrigin.zw + dispatchThreadId.xy;
    float2 position = float2(pixel);
    float2 displacement = DisplacementAndMode.xy;
    float4 original = InputTexture.Load(int3(pixel, 0));
    float2 sourcePosition;
    float blend;

    if (DisplacementAndMode.z < 0.5)
    {
        float weight = WeightTexture.Load(int3(pixel, 0));
        if (weight <= 0.0)
            return;
        sourcePosition = position - displacement * weight;
        blend = weight * weight;
    }
    else
    {
        const float outerMotionRatio = 0.35;
        float2 shift = displacement * outerMotionRatio;
        float2 basePosition = position - shift;
        float weight = SampleWeight(basePosition, false);
        blend = max(SampleWeight(position, true),
            SampleWeight(basePosition, true));
        if (blend <= 0.0)
            return;
        sourcePosition = basePosition - displacement *
            (1.0 - outerMotionRatio) * weight;
    }

    sourcePosition = clamp(sourcePosition, float2(0.0, 0.0),
        float2(ImageAndActiveOrigin.xy) - 1.0);
    float2 uv = (sourcePosition + 0.5) /
        float2(ImageAndActiveOrigin.xy);
    float4 sampled = InputTexture.SampleLevel(
        LinearClampSampler, uv, 0.0);
    OutputTexture[pixel] = lerp(original, sampled, blend);
}
