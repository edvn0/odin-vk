struct VSOutput
{
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
VSOutput main(uint vertex_id: SV_VertexID)
{
    VSOutput o;

    float2 uv = float2((vertex_id << 1) & 2, vertex_id & 2);

    o.uv = uv;
    o.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);

    return o;
}
