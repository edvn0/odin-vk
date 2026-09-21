import bindless;

struct PC
{
    uint texture_index;
    uint sampler_index;
}

[shader("fragment")]
float4 main(
    float2 uv: TEXCOORD0,
    uniform PC pc) : SV_Target
{
    return sampled_2d[pc.texture_index].Sample(samplers_2d[pc.sampler_index], uv);
}
