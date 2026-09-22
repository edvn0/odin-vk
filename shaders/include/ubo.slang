// Per-frame data shared by the rendering and compute passes. One instance
// per frame-in-flight slot (see Context.ubo_buffers in render/types.odin),
// written by the CPU and read here via device address. Layout must match
// render.UBO in render/types.odin byte-for-byte.
struct UBO
{
    float dt;
    uint should_step; // compute-only: gates the Game of Life step this frame
}
