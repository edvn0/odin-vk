module ubo;

import draw_data;

public struct UBO
{
    public float dt;
    public uint should_step;
    public Ptr<DrawData, Access.Read> draw_data;
}
