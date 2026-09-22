import bindless;
import mesh_vertex;
import ubo;

struct Bounds
{
    float4 center_and_radius;
}

struct PC
{
    Ptr<Vertex> vertices;
    Ptr<Bounds> bounds;
    Ptr<UBO> ubo; // unused here, part of the shared PC layout (see suzanne.mesh.slang)
    float angle;
    float aspect;
    uint count;
    uint meshlet_count;
    uint texture_index;
    uint sampler_index;
}

struct FS_In
{
    [[vk::location(0)]]
    float3 normal;
    [[vk::location(1)]]
    float2 uv;
};

[shader("fragment")]
float4 main(FS_In input, uniform PC pc) : SV_Target
{
    float3 light_dir = normalize(float3(0.4, 0.8, 0.5));
    float3 n = normalize(input.normal);
    float n_dot_l = max(dot(n, light_dir), 0.0);

    float life = sampled_2d[pc.texture_index].Sample(samplers_2d[pc.sampler_index], input.uv).r;

    float3 dead_color = float3(0.15, 0.17, 0.22);
    float3 alive_color = float3(0.85, 0.9, 1.0);
    float3 base_color = lerp(dead_color, alive_color, life);

    float3 color = base_color * (0.25 + 0.75 * n_dot_l);

    return float4(color, 1.0);
}
