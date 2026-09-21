# Vulkan Cellular Automaton Rendering Handoff

## Context

The renderer can now run a compute shader each frame and present through Vulkan.

The current simulation is **not Conway's Game of Life yet**. It is currently a **1D Rule 30 cellular automaton**.

The current compute flow:

- Uses per-frame buffers.
- Computes the next Rule 30 row with a compute shader.
- Uses mapped host-visible buffers.
- Reads the row on the CPU.
- Prints the row asynchronously using `vk_io`.
- Clears the swapchain image to white or black depending on one cell in the current row.
- Uses a global timeline semaphore for GPU completion.
- Uses shader objects via `vkCmdBindShadersEXT`.
- Uses bindless descriptors.
- Presents directly from the same queue currently used for compute submission.

The goal now is to:

1. Render the automaton directly on the GPU.
2. Avoid CPU readback in the normal rendering path.
3. First visualize Rule 30 as a 2D history.
4. Then optionally move the simulation itself to a true 2D Conway Game of Life grid.

---

## Important Architectural Issue

The current code conflates:

- **frames in flight**, and
- **simulation generations**.

These should be separated.

Current code derives the previous simulation state from the frame slot:

```odin
prev_slot := (slot + (MAX_FRAMES_IN_FLIGHT - 1)) % MAX_FRAMES_IN_FLIGHT
```

That is not a good long-term model for a cellular automaton.

A cellular automaton has a strict dependency chain:

```text
generation N
    ↓
generation N + 1
    ↓
generation N + 2
```

Frames-in-flight should instead own only renderer submission resources such as:

- command buffers,
- acquire semaphores,
- frame reuse completion values,
- other transient per-frame state.

The simulation should have its own ping-pong state.

Recommended shape:

```odin
Simulation :: struct {
    buffers:          [2]Buffer_Handle,
    current:          int,
    generation:       u64,
    completion_value: u64,

    width:             u32,
    height:            u32,

    display_image:     Image_Handle,
}
```

Simulation indexing:

```odin
prev_index := sim.current
curr_index := 1 - sim.current

prev := sim.buffers[prev_index]
curr := sim.buffers[curr_index]

//
// dispatch prev -> curr
//

sim.current = curr_index
sim.generation += 1
```

Do not derive this from:

```odin
frame % MAX_FRAMES_IN_FLIGHT
```

---

## Current Host Readback Issue

The current code does this before the newly submitted compute work has finished:

```odin
row = (^[config.CELL_COUNT]u32)(buffer.mapped)^
```

Then later:

```odin
vk.CmdDispatch(...)
vk.QueueSubmit(...)
return row, true
```

That returned `row` is therefore the buffer contents from before the new dispatch completes.

The host visibility barrier:

```odin
memory_barrier := vk.MemoryBarrier2 {
    sType         = .MEMORY_BARRIER_2,
    srcStageMask  = {.COMPUTE_SHADER},
    srcAccessMask = {.SHADER_WRITE},
    dstStageMask  = {.HOST},
    dstAccessMask = {.HOST_READ},
}
```

is valid for making the writes visible to the host, but the CPU still must wait for the submission to complete before reading the result.

For the normal renderer path, the preferred solution is:

> Do not read the simulation result back to the CPU at all.

Keep CPU readback only as an optional debugging path.

---

# Recommended Immediate Step: Rule 30 History Image

Before converting to true Conway, visualize the existing Rule 30 automaton as a 2D history.

Each simulation generation becomes one row of an image:

```text
...............................#................................
..............................###...............................
.............................##..#...............................
............................##.####..............................
...........................##..#...#.............................
```

This gives a useful visual result with very little renderer restructuring.

---

## GPU Flow

Recommended frame flow:

```text
previous simulation buffer
        |
        v
Rule 30 compute
        |
        v
current simulation buffer
        |
        +--------------------+
        |                    |
        v                    v
next simulation state   storage image write
                             |
                             v
                      visualization image
                             |
                             v
                       vkCmdBlitImage
                             |
                             v
                         swapchain
```

No CPU readback is required.

---

## Display Image

Create a persistent GPU image for the visualization.

Example:

```text
width:  CELL_COUNT
height: HISTORY_HEIGHT, e.g. 1024

format:
VK_FORMAT_R8G8B8A8_UNORM

usage:
VK_IMAGE_USAGE_STORAGE_BIT
VK_IMAGE_USAGE_TRANSFER_SRC_BIT
```

Keep the image in `GENERAL` while the compute shader writes to it.

Each generation writes:

```odin
row_index := sim.generation % HISTORY_HEIGHT
```

---

## Rule 30 Compute Shader

The current shader should compute the new cell and also write the result into the history image.

Conceptually:

```slang
import bindless;

struct PC
{
    Ptr<uint> prev;
    Ptr<uint> curr;

    uint row;
    uint image_index;
};

static const uint CELL_COUNT = 64;
static const uint RULE_30 = 0x1E;

[shader("compute")]
[numthreads(64, 1, 1)]
void main(
    uint3 tid : SV_DispatchThreadID,
    uniform PC pc)
{
    uint x = tid.x;

    if (x >= CELL_COUNT)
        return;

    uint left =
        pc.prev[(x + CELL_COUNT - 1) % CELL_COUNT];

    uint mid =
        pc.prev[x];

    uint right =
        pc.prev[(x + 1) % CELL_COUNT];

    uint pattern =
        (left << 2) |
        (mid  << 1) |
        right;

    uint alive =
        (RULE_30 >> pattern) & 1;

    pc.curr[x] = alive;

    float value =
        alive != 0 ? 1.0 : 0.0;

    bindless_rw_images[pc.image_index][int2(x, pc.row)] =
        float4(value, value, value, 1.0);
}
```

Adjust the exact bindless storage image access to match the existing `bindless` Slang module.

---

# Rendering the History Image

After the compute dispatch, make the storage image available for transfer reads.

Example synchronization:

```odin
image_barrier := vk.ImageMemoryBarrier2 {
    sType         = .IMAGE_MEMORY_BARRIER_2,

    srcStageMask  = {.COMPUTE_SHADER},
    srcAccessMask = {.SHADER_WRITE},

    dstStageMask  = {.BLIT},
    dstAccessMask = {.TRANSFER_READ},

    oldLayout = .GENERAL,
    newLayout = .TRANSFER_SRC_OPTIMAL,

    srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
    dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,

    image = display_image,

    subresourceRange = {
        aspectMask = {.COLOR},
        levelCount = 1,
        layerCount = 1,
    },
}
```

Then transition the acquired swapchain image into:

```text
TRANSFER_DST_OPTIMAL
```

as the code already does.

Instead of:

```odin
vk.CmdClearColorImage(...)
```

use:

```odin
vk.CmdBlitImage(...)
```

Blit:

```text
source:
CELL_COUNT x HISTORY_HEIGHT

destination:
swapchain width x swapchain height
```

Use:

```text
VK_FILTER_NEAREST
```

to retain hard cell boundaries.

Then transition:

```text
swapchain:
TRANSFER_DST_OPTIMAL
    ->
PRESENT_SRC_KHR
```

and return the display image:

```text
TRANSFER_SRC_OPTIMAL
    ->
GENERAL
```

so compute can write into it next frame.

---

# Simulation Synchronization

The next generation depends on the immediately previous generation.

The current wait:

```odin
wait_timeline(
    ctx,
    ctx.frames[slot].completion_value,
)
```

only ensures that resources associated with that frame slot can be reused.

It does **not** explicitly model the automaton dependency.

For a first correct implementation, use a separate simulation timeline value:

```odin
wait_timeline(
    ctx,
    ctx.simulation.completion_value,
)
```

before submitting the next generation.

After successful submission:

```odin
ctx.simulation.completion_value =
    submission_value
```

This serializes generations on the CPU side.

That is acceptable initially because the automaton itself is sequential.

Later, improve this by expressing the dependency entirely on the GPU:

```text
submission N
signals timeline value N

submission N+1
waits on timeline value N
signals timeline value N+1
```

Then the CPU does not need to block between generations.

---

# Desired Long-Term Submission Structure

A better eventual design is:

```text
CPU
 |
 | record frame
 |
 +---- submit generation N+1
 |       waits on simulation timeline N
 |       waits on acquired swapchain image
 |
 |       compute Rule 30 / Conway
 |       write visualization image
 |       blit to swapchain
 |
 |       signals:
 |           render_finished binary semaphore
 |           simulation timeline N+1
 |
 +---- present
```

The CPU can continue running without waiting for the simulation unless:

- resources must be reused,
- debug readback is requested,
- shutdown / teardown requires completion.

---

# Moving to True 2D Conway

After Rule 30 visualization works, convert the simulation state from:

```odin
[config.CELL_COUNT]u32
```

to:

```odin
GRID_WIDTH * GRID_HEIGHT
```

stored linearly.

Example dimensions:

```odin
GRID_WIDTH  :: 256
GRID_HEIGHT :: 256
```

Each cell remains a `u32` initially for simplicity.

---

## Conway Shader

Recommended workgroup:

```slang
[numthreads(8, 8, 1)]
```

Example shader:

```slang
struct PC
{
    Ptr<uint> prev;
    Ptr<uint> curr;

    uint width;
    uint height;

    uint image_index;
};

[shader("compute")]
[numthreads(8, 8, 1)]
void main(
    uint3 tid : SV_DispatchThreadID,
    uniform PC pc)
{
    uint x = tid.x;
    uint y = tid.y;

    if (x >= pc.width ||
        y >= pc.height)
    {
        return;
    }

    int neighbour_count = 0;

    for (int dy = -1; dy <= 1; ++dy)
    {
        for (int dx = -1; dx <= 1; ++dx)
        {
            if (dx == 0 && dy == 0)
                continue;

            uint nx = uint(
                (
                    int(x) +
                    dx +
                    int(pc.width)
                ) %
                int(pc.width)
            );

            uint ny = uint(
                (
                    int(y) +
                    dy +
                    int(pc.height)
                ) %
                int(pc.height)
            );

            neighbour_count +=
                pc.prev[
                    ny * pc.width + nx
                ] != 0
                    ? 1
                    : 0;
        }
    }

    uint index =
        y * pc.width + x;

    bool alive =
        pc.prev[index] != 0;

    bool next_alive =
        neighbour_count == 3 ||
        (
            alive &&
            neighbour_count == 2
        );

    uint next =
        next_alive ? 1 : 0;

    pc.curr[index] = next;

    float value =
        next != 0 ? 1.0 : 0.0;

    bindless_rw_images[
        pc.image_index
    ][int2(x, y)] =
        float4(
            value,
            value,
            value,
            1.0
        );
}
```

This uses wrapping / toroidal boundaries.

Alternative boundary behavior can be added later.

---

## Conway Dispatch

For an `8 x 8` workgroup:

```odin
group_x :=
    (GRID_WIDTH + 7) / 8

group_y :=
    (GRID_HEIGHT + 7) / 8

vk.CmdDispatch(
    cmd,
    group_x,
    group_y,
    1,
)
```

---

# Main Loop After GPU Visualization

The normal main loop should eventually look approximately like:

```odin
running := true
frame := 0

for running {
    event: sdl2.Event

    for sdl2.PollEvent(&event) {
        if event.type == .QUIT {
            running = false
        }

        if event.type == .KEYDOWN &&
           event.key.keysym.sym == .ESCAPE
        {
            running = false
        }
    }

    slot :=
        frame %
        render.MAX_FRAMES_IN_FLIGHT

    submitted :=
        render.run_frame(
            &ctx,
            slot,
        )

    if submitted {
        frame += 1
    }
}
```

No automaton row should need to be returned.

Instead of:

```odin
run_compute :: proc(
    ctx: ^Context,
    slot: int,
) -> (
    row: [config.CELL_COUNT]u32,
    submitted: bool,
)
```

prefer something like:

```odin
run_frame :: proc(
    ctx: ^Context,
    slot: int,
) -> bool
```

The simulation remains entirely GPU-side.

---

# Debug Readback

Keep the existing row printing capability only as a debug facility.

Possible API:

```odin
read_simulation_state :: proc(
    ctx: ^Context,
) -> []u32
```

This function may explicitly:

1. wait for the simulation timeline value,
2. invalidate mapped memory if required,
3. copy the mapped simulation state,
4. return or print it.

Do not perform this every normal rendered frame.

---

# Suggested Refactor

Current `run_compute` is doing too much:

- waits,
- buffer management,
- compute dispatch,
- visualization,
- swapchain transitions,
- submission,
- presentation.

Suggested split:

```text
simulation.odin

    simulation_init
    simulation_destroy
    simulation_record_step
    simulation_seed
    simulation_debug_readback

render_frame.odin

    begin_frame
    acquire_image
    record_visualization_blit
    submit_frame
    present_frame

sync.odin

    wait_timeline
    transition_image
```

Keep the exact split lightweight; the important part is separating simulation state from frame state.

---

# Immediate Implementation Order

Recommended order:

1. Introduce `Simulation`.
2. Add two simulation buffers independent of frames-in-flight.
3. Ping-pong simulation buffers.
4. Add persistent RGBA8 storage image.
5. Modify Rule 30 shader to write one row into the storage image.
6. Replace swapchain clear with `vkCmdBlitImage`.
7. Use nearest-neighbour filtering.
8. Make simulation dependency use its own timeline value.
9. Remove CPU row readback from the normal path.
10. Verify scrolling / wrapping Rule 30 history.
11. Change the compute shader to a 2D Conway implementation.
12. Change simulation buffers to `width * height`.
13. Dispatch `ceil(width / 8) x ceil(height / 8)`.
14. Write Conway cells directly to the visualization image.

---

# Expected End State

Normal frame:

```text
poll SDL
    ↓
acquire swapchain image
    ↓
dispatch cellular automaton
    ↓
write simulation result
    ↓
write storage visualization image
    ↓
barrier compute -> transfer
    ↓
blit visualization -> swapchain
    ↓
transition swapchain -> PRESENT_SRC_KHR
    ↓
submit
    ↓
present
```

No CPU copy is required.

Simulation state:

```text
buffer A <------+
   |            |
   v            |
buffer B -------+
```

with alternating generations.

Frames-in-flight remain independent of simulation generations.

---

# Current Main Technical Caveats

The implementation should explicitly account for these:

- Do not read mapped simulation memory before the relevant timeline value has completed.
- Do not use FIF slot selection to determine the previous automaton generation.
- Make the compute-to-image dependency explicit.
- Make the storage-image-to-transfer dependency explicit.
- Keep the display image in `GENERAL` for compute writes.
- Transition it to `TRANSFER_SRC_OPTIMAL` only for blitting.
- Return it to `GENERAL` afterwards.
- Continue transitioning swapchain images to `TRANSFER_DST_OPTIMAL` before blitting.
- Continue transitioning swapchain images to `PRESENT_SRC_KHR` before presentation.
- Use `VK_FILTER_NEAREST`.
- Prefer GPU timeline dependencies over host waits once the initial version is correct.
- Keep host readback strictly optional.

---

# Terminology

Current implementation:

```text
Rule 30
1-dimensional cellular automaton
```

Target optional implementation:

```text
Conway's Game of Life
2-dimensional cellular automaton
```

Do not refer to the current shader as Conway unless it has actually been changed to the 2D neighbour-based Conway rules.
