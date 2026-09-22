import mesh_vertex;
import ubo;

struct Bounds
{
    float4 center_and_radius; // unused here, read by the task shader
}

struct PC
{
    Ptr<Vertex> vertices;
    Ptr<Bounds> bounds; // unused here, read by the task shader
    Ptr<UBO> ubo; // unused here, available for future per-frame effects
    float angle;
    float aspect;
    uint count;
    uint meshlet_count; // unused here, read by the task shader
    uint texture_index; // unused here, read by the fragment shader
    uint sampler_index; // unused here, read by the fragment shader
}

struct MeshOutput
{
    float4 position : SV_Position;
    [[vk::location(0)]]
    float3 normal;
    [[vk::location(1)]]
    float2 uv;
};

static const uint MESHLET_TRIANGLES = 64;
static const uint MESHLET_VERTICES = MESHLET_TRIANGLES * 3;

// Must match TASK_GROUP_MESHLETS in shaders/suzanne.task.slang.
static const uint TASK_GROUP_MESHLETS = 32;

struct Payload
{
    uint base_meshlet;
    uint visible_mask; // bit i set => meshlet (base_meshlet + i) is visible
}

// Fixed camera: looking down -Z at the origin from EYE, no roll. Must
// match shaders/suzanne.task.slang exactly.
static const float FOVY = 0.78539816; // 45 degrees
static const float NEAR = 0.1;
static const float FAR = 10.0;
static const float3 EYE = float3(0.0, 0.0, 3.0);

float3 rotate_y(float3 v, float angle)
{
    float s = sin(angle);
    float c = cos(angle);
    return float3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}

// Vulkan clip space (Y-down NDC, depth in [0, 1]) perspective projection
// for the fixed axis-aligned camera above.
float4 project(float3 view_pos, float aspect)
{
    float f = 1.0 / tan(FOVY * 0.5);

    float4 clip;
    clip.x = (f / aspect) * view_pos.x;
    clip.y = -f * view_pos.y;
    clip.z = (FAR * -view_pos.z - FAR * NEAR) / (FAR - NEAR);
    clip.w = -view_pos.z;
    return clip;
}

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(MESHLET_TRIANGLES, 1, 1)]
void main(
    uint group_id: SV_GroupID,
    uint thread_id: SV_GroupThreadID,
    in payload Payload task_payload,
    uniform PC pc,
    OutputVertices<MeshOutput, MESHLET_VERTICES> verts,
    OutputIndices<uint3, MESHLET_TRIANGLES> triangles)
{
    uint meshlet_id = task_payload.base_meshlet + group_id;

    if ((task_payload.visible_mask & (1u << group_id)) == 0)
    {
        SetMeshOutputCounts(0, 0);
        return;
    }

    uint global_base = meshlet_id * MESHLET_VERTICES;

    uint remaining_verts = global_base < pc.count ? min(MESHLET_VERTICES, pc.count - global_base) : 0;
    uint remaining_prims = remaining_verts / 3;

    SetMeshOutputCounts(remaining_verts, remaining_prims);

    if (thread_id >= remaining_prims)
        return;

    uint local_base = thread_id * 3;
    triangles[thread_id] = uint3(local_base, local_base + 1, local_base + 2);

    for (uint i = 0; i < 3; ++i)
    {
        Vertex v = pc.vertices[global_base + local_base + i];
        float3 pos = decode_position(v);
        float3 world_pos = rotate_y(pos, pc.angle);
        float3 world_normal = rotate_y(decode_normal(v), pc.angle);

        MeshOutput o;
        o.position = project(world_pos - EYE, pc.aspect);
        o.normal = world_normal;
        o.uv = decode_uv(v);

        verts[local_base + i] = o;
    }
}
