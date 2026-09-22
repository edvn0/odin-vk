import mesh_vertex;
import ubo;

struct Bounds
{
    float4 center_and_radius; // xyz = model-space center, w = radius
}

struct PC
{
    Ptr<Vertex> vertices; // unused here, read by the mesh shader
    Ptr<Bounds> bounds;
    Ptr<UBO> ubo; // unused here, part of the shared PC layout (see suzanne.mesh.slang)
    float angle;
    float aspect;
    uint count; // unused here, read by the mesh shader
    uint meshlet_count;
    uint texture_index; // unused here, read by the fragment shader
    uint sampler_index; // unused here, read by the fragment shader
}

static const uint TASK_GROUP_MESHLETS = 32;

// Fixed camera: must match shaders/suzanne.mesh.slang exactly.
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

struct Payload
{
    uint base_meshlet;
    uint visible_mask; // bit i set => meshlet (base_meshlet + i) is visible
}

[shader("amplification")]
[numthreads(TASK_GROUP_MESHLETS, 1, 1)]
void main(
    uint group_id: SV_GroupID,
    uint thread_id: SV_GroupThreadID,
    uniform PC pc)
{
    uint meshlet_id = group_id * TASK_GROUP_MESHLETS + thread_id;

    bool visible = false;

    if (meshlet_id < pc.meshlet_count)
    {
        Bounds b = pc.bounds[meshlet_id];

        float3 center = rotate_y(b.center_and_radius.xyz, pc.angle);
        float radius = b.center_and_radius.w;

        float3 view_pos = center - EYE;
        float view_z = -view_pos.z; // positive distance along the view axis

        float tan_half_fovy = tan(FOVY * 0.5);
        float tan_half_fovx = tan_half_fovy * pc.aspect;

        bool in_depth_range = (view_z + radius) > NEAR && (view_z - radius) < FAR;
        bool in_horizontal_range = abs(view_pos.x) - radius < view_z * tan_half_fovx;
        bool in_vertical_range = abs(view_pos.y) - radius < view_z * tan_half_fovy;

        visible = in_depth_range && in_horizontal_range && in_vertical_range;
    }

    uint bit = visible ? (1u << thread_id) : 0u;

    Payload payload;
    payload.base_meshlet = group_id * TASK_GROUP_MESHLETS;
    payload.visible_mask = WaveActiveBitOr(bit);

    DispatchMesh(TASK_GROUP_MESHLETS, 1, 1, payload);
}
