struct Vertex
{
    uint position_xy; // f16 x | f16 y << 16
    uint position_z;  // f16 z, high 16 bits reserved
    uint uv;          // f16 u | f16 v << 16
    uint normal;      // octahedral snorm16 x | snorm16 y << 16
    uint tangent;     // octahedral unorm15 x | unorm15 y << 15 | sign << 31
};

float3 decode_position(Vertex v)
{
    return float3(
        f16tof32(v.position_xy),
        f16tof32(v.position_xy >> 16),
        f16tof32(v.position_z));
}

float2 decode_uv(Vertex v)
{
    return float2(f16tof32(v.uv), f16tof32(v.uv >> 16));
}

float3 oct_decode(float2 e)
{
    float3 n = float3(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
    float t = saturate(-n.z);
    n.x += n.x >= 0.0 ? -t : t;
    n.y += n.y >= 0.0 ? -t : t;
    return normalize(n);
}

float3 decode_normal(Vertex v)
{
    // Sign-extend each 16-bit half.
    int x = int(v.normal << 16) >> 16;
    int y = int(v.normal) >> 16;
    float2 e = max(float2(x, y) / 32767.0, -1.0);
    return oct_decode(e);
}

// xyz = tangent, w = bitangent sign.
// bitangent = cross(normal, tangent.xyz) * tangent.w
float4 decode_tangent(Vertex v)
{
    float2 e = float2(v.tangent & 0x7FFF, (v.tangent >> 15) & 0x7FFF) / 32767.0 * 2.0 - 1.0;
    float handedness = (v.tangent >> 31) != 0 ? -1.0 : 1.0;
    return float4(oct_decode(e), handedness);
}
