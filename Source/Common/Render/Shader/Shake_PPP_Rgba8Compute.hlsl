Texture2D<float4> InputTexture : register(t0);
RWTexture2D<float4> OutputTexture : register(u0);

cbuffer BulgeConstants : register(b0)
{
    uint4 ImageAndActiveOrigin;
    uint4 ActiveSizeAndPadding;
    float4 AmountShapeCenterX;
    float4 OuterAndGravity;
    float4 GravityDirection;
};

[numthreads(16, 16, 1)]
void Main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    if (dispatchThreadId.x >= ImageAndActiveOrigin.x ||
        dispatchThreadId.y >= ImageAndActiveOrigin.y)
        return;

    OutputTexture[dispatchThreadId.xy] = saturate(
        InputTexture.Load(int3(dispatchThreadId.xy, 0)));
}
