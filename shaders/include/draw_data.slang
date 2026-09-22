module draw_data;

import mesh_vertex;

public struct DrawData
{
    float4 quat_rotation;
    float3 translation;
    float scale;
    uint material_index;
}

float3 rotate_by_quaternion(float4 q, float3 v)
{
    float3 t = 2.0 * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}

float3 transform_position(DrawData data, float3 p)
{
    return data.translation +
           rotate_by_quaternion(data.quat_rotation, p * data.scale);
}


public void transform(in DrawData data, DecodedVertex vertex)
{
    vertex.position = transform_position(data, vertex.position);
}