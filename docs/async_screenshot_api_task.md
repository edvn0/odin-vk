# Task: Add Asynchronous Offscreen Screenshot Capture

## Goal

Add an asynchronous screenshot/readback API to the Vulkan renderer so the current offscreen render target can be captured without stalling the CPU.

The immediate interactive trigger should be:

- `Ctrl+P` requests a screenshot.
- The screenshot captures the **next successfully submitted frame**.
- The renderer must **not call `vkWaitSemaphores`** or otherwise block the CPU for screenshot capture.
- Completion should be detected by polling the renderer's existing timeline semaphore.
- Once ready, the screenshot should be handed to the existing async I/O system for writing.
- The renderer should expose a reusable API so future agent tooling can request captures programmatically without relying on keyboard input.

The keyboard shortcut and agent tooling must use the same underlying renderer API.

---

## Existing Renderer Context

The renderer already has:

- A global Vulkan timeline semaphore:
  - `ctx.timeline_semaphore`
  - `ctx.timeline_value`
- A unique timeline value allocated for each successful frame submission.
- Per-frame completion values:
  - `ctx.frames[slot].completion_value`
- Triple-buffered offscreen images:
  - `ctx.offscreen_images[MAX_FRAMES_IN_FLIGHT]`
- Triple-buffered depth images.
- A two-pass rendering structure:
  1. Render meshes into an offscreen color target.
  2. Sample the offscreen target into the swapchain.
- An existing async I/O thread in `vk_io`.
- An existing synchronous debug readback helper:
  - `simulation_debug_readback`
  - This helper should **not** be used as the model for screenshot capture because it explicitly waits on the GPU.

The screenshot implementation should integrate into the existing frame submission/timeline architecture.

---

# Desired Public API

Add renderer-side screenshot types similar to:

```odin
Screenshot_Handle :: struct {
	index:      u16,
	generation: u16,
}

Screenshot_Status :: enum {
	Invalid,
	Queued,
	Submitted,
	Ready,
	Failed,
}

Screenshot_Target :: enum {
	Offscreen,
}

Screenshot_Desc :: struct {
	target: Screenshot_Target,
}

Screenshot_View :: struct {
	pixels:       []u8,
	width:        u32,
	height:       u32,
	row_stride:   u32,
	format:       vk.Format,
	frame_number: u64,
}
```

Expose an API similar to:

```odin
screenshot_request :: proc(
	ctx: ^Context,
	desc := Screenshot_Desc{target = .Offscreen},
) -> Screenshot_Handle

screenshot_status :: proc(
	ctx: ^Context,
	handle: Screenshot_Handle,
) -> Screenshot_Status

screenshot_map :: proc(
	ctx: ^Context,
	handle: Screenshot_Handle,
) -> (Screenshot_View, bool)

screenshot_release :: proc(
	ctx: ^Context,
	handle: Screenshot_Handle,
)
```

The exact internal representation is flexible, but the external behavior should follow this model.

---

# Screenshot State Machine

Use this lifecycle:

```text
Queued
  |
  | frame command buffer records screenshot copy
  v
Submitted
  |
  | timeline semaphore reaches completion_value
  v
Ready
  |
  | caller consumes data
  v
Released
```

Possible failure state:

```text
Queued / Submitted -> Failed
```

A screenshot request must remain `Queued` until it is actually attached to a successfully submitted frame.

Do not consume a screenshot request merely because `run_frame()` was called.

For example, this must remain safe:

```text
Ctrl+P
  |
screenshot_request()
  |
AcquireNextImageKHR -> TIMEOUT
  |
frame skipped
```

The request must stay queued and be attached to the next successfully submitted frame instead.

---

# Interactive Ctrl+P Trigger

Add `Ctrl+P` handling to the SDL event loop.

Requirements:

- Trigger only once per physical key press.
- Ignore SDL key repeat.
- Do not queue another interactive screenshot while the previous Ctrl+P capture is still pending.
- This single-capture restriction belongs in the application/UI layer, **not** the renderer.
- The renderer itself should support multiple outstanding screenshot requests.

Example shape:

```odin
capture: render.Screenshot_Handle
capture_pending := false

for sdl2.PollEvent(&event) {
	if event.type == .KEYDOWN {
		if event.key.keysym.sym == .ESCAPE {
			running = false
		}

		ctrl_down := (event.key.keysym.mod & sdl2.KMOD_CTRL) != 0

		if ctrl_down &&
		   event.key.keysym.sym == .p &&
		   event.key.repeat == 0 &&
		   !capture_pending {
			capture = render.screenshot_request(
				&ctx,
				{
					target = .Offscreen,
				},
			)

			capture_pending = true
			fmt.println("screenshot requested")
		}
	}
}
```

Adjust SDL/Odin enum spelling as required by the actual bindings.

---

# Polling Completion

Screenshot completion must be non-blocking.

Do **not** call:

```odin
vk.WaitSemaphores(...)
```

for screenshot capture.

Instead, inspect the timeline semaphore with:

```odin
vk.GetSemaphoreCounterValue(...)
```

A convenient implementation is to have `screenshot_status()` perform the polling:

```odin
screenshot_status :: proc(
	ctx: ^Context,
	handle: Screenshot_Handle,
) -> Screenshot_Status {
	req, found := screenshot_try_get(ctx, handle)
	if !found {
		return .Invalid
	}

	if req.state != .Submitted {
		return req.state
	}

	completed: u64
	res := vk.GetSemaphoreCounterValue(
		ctx.device,
		ctx.timeline_semaphore,
		&completed,
	)

	if res != .SUCCESS {
		req.state = .Failed
		return .Failed
	}

	if completed >= req.completion_value {
		req.state = .Ready
	}

	return req.state
}
```

The exact implementation can instead batch-poll requests in a `screenshot_poll()` function if cleaner, but polling must remain non-blocking.

---

# Renderer Integration

## Capture Point

The offscreen image currently follows approximately this flow:

```text
Pass A:
    render mesh -> offscreen image

barrier:
    COLOR_ATTACHMENT_OPTIMAL
      -> SHADER_READ_ONLY_OPTIMAL

Pass B:
    sample offscreen image -> swapchain image
```

The screenshot copy should happen **after Pass B has finished**.

At that point:

- Pass B is finished reading the offscreen image.
- No other work in the current frame needs the offscreen image.
- The image can safely transition to `TRANSFER_SRC_OPTIMAL`.
- The next use of the offscreen image already discards previous contents via `oldLayout = UNDEFINED`, so it does not need to transition back to shader-read layout after capture.

Desired frame structure:

```text
Pass A
    render -> offscreen

barrier
    offscreen COLOR_ATTACHMENT
           -> SHADER_READ

Pass B
    sample offscreen -> swapchain

if screenshot queued:
    barrier
        offscreen SHADER_READ
               -> TRANSFER_SRC

    vkCmdCopyImageToBuffer2(
        offscreen,
        screenshot_staging_buffer
    )

    barrier
        staging TRANSFER_WRITE
             -> HOST_READ

submit

timeline semaphore = N

request.completion_value = N
request.state = Submitted
```

---

# GPU Readback Buffer

Each active screenshot needs a host-readable staging/readback buffer.

Required Vulkan buffer usage:

```odin
vk.BufferUsageFlags{.TRANSFER_DST}
```

The memory must be:

- host visible
- mapped, preferably persistently mapped

If the selected memory is not `HOST_COHERENT`, call:

```odin
vkInvalidateMappedMemoryRanges(...)
```

before exposing data through `screenshot_map()` after the request becomes ready.

Do not assume all host-visible memory is coherent.

---

# Offscreen Image Usage

The offscreen color image must include:

```odin
vk.ImageUsageFlags {
	.COLOR_ATTACHMENT,
	.SAMPLED,
	.TRANSFER_SRC,
}
```

If `TRANSFER_SRC` is currently missing, add it when the offscreen images are created.

---

# Record Screenshot Copy

Add an internal helper similar to:

```odin
record_screenshot_readback :: proc(
	ctx: ^Context,
	cmd: vk.CommandBuffer,
	handle: Screenshot_Handle,
	image: ^Image,
)
```

The implementation should:

1. Look up the screenshot request.
2. Ensure its readback buffer is large enough.
3. Transition the source image:
   - `SHADER_READ_ONLY_OPTIMAL`
   - -> `TRANSFER_SRC_OPTIMAL`
4. Copy the color image to the staging buffer with `vk.CmdCopyImageToBuffer2`.
5. Insert a transfer-write -> host-read buffer barrier.
6. Do not wait on the GPU.
7. Leave the offscreen image in `TRANSFER_SRC_OPTIMAL`.

Example barrier shape:

```odin
to_transfer := vk.ImageMemoryBarrier2 {
	sType = .IMAGE_MEMORY_BARRIER_2,

	srcStageMask  = {.FRAGMENT_SHADER},
	srcAccessMask = {.SHADER_READ},

	dstStageMask  = {.COPY},
	dstAccessMask = {.TRANSFER_READ},

	oldLayout = .SHADER_READ_ONLY_OPTIMAL,
	newLayout = .TRANSFER_SRC_OPTIMAL,

	srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
	dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,

	image            = image.object,
	subresourceRange = full_range,
}
```

Then:

```odin
region := vk.BufferImageCopy2 {
	sType = .BUFFER_IMAGE_COPY_2,

	bufferOffset      = 0,
	bufferRowLength   = 0,
	bufferImageHeight = 0,

	imageSubresource = {
		aspectMask     = {.COLOR},
		mipLevel       = 0,
		baseArrayLayer = 0,
		layerCount     = 1,
	},

	imageOffset = {},
	imageExtent = {
		width  = width,
		height = height,
		depth  = 1,
	},
}

copy_info := vk.CopyImageToBufferInfo2 {
	sType = .COPY_IMAGE_TO_BUFFER_INFO_2,

	srcImage       = image.object,
	srcImageLayout = .TRANSFER_SRC_OPTIMAL,
	dstBuffer      = readback.object,

	regionCount = 1,
	pRegions    = &region,
}

vk.CmdCopyImageToBuffer2(cmd, &copy_info)
```

Then make the host read dependency explicit:

```odin
buffer_barrier := vk.BufferMemoryBarrier2 {
	sType = .BUFFER_MEMORY_BARRIER_2,

	srcStageMask  = {.COPY},
	srcAccessMask = {.TRANSFER_WRITE},

	dstStageMask  = {.HOST},
	dstAccessMask = {.HOST_READ},

	srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
	dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,

	buffer = readback.object,
	offset = 0,
	size   = vk.WHOLE_SIZE,
}
```

Use the Vulkan stage names supported by the actual Odin bindings if they differ.

---

# Attaching a Request to a Frame

Inside `run_frame()`:

1. After swapchain acquisition succeeds, locate at most one queued screenshot for the current frame.
2. Record its image-to-buffer copy after Pass B.
3. Finish the command buffer.
4. Allocate the normal frame `submission_value`.
5. Submit the frame normally.
6. **Only if `vk.QueueSubmit` succeeds**, mark the screenshot as submitted.

Example:

```odin
if screenshot_requested {
	req, found := screenshot_try_get(ctx, screenshot_handle)
	assert(found)

	req.state = .Submitted
	req.completion_value = submission_value
	req.frame_number = ctx.frame_number
}
```

Do not assign the completion value before `QueueSubmit()` succeeds.

Otherwise a failed submission could leave a request waiting forever for a timeline value that can never be signalled.

---

# Frame Numbering

Add a monotonically increasing renderer/application frame identifier if one does not already exist:

```odin
frame_number: u64
```

Store it in the screenshot request when the capture is attached to a frame.

Expose it through:

```odin
Screenshot_View.frame_number
```

This lets agents correlate a screenshot with renderer state/log output.

---

# Image Metadata

It would be useful to make `Image` carry its dimensions instead of relying on swapchain extent externally.

Current direction:

```odin
Image :: struct {
	handle: Image_Handle,
	object: vk.Image,
	memory: vk.DeviceMemory,
	view:   vk.ImageView,
	format: vk.Format,
	extent: vk.Extent3D,
}
```

This is strongly preferred because future screenshot requests may target resources other than the main offscreen target.

---

# Consuming the Capture in Main

After running/submitting frames, check the pending Ctrl+P screenshot:

```odin
if capture_pending &&
   render.screenshot_status(&ctx, capture) == .Ready {

	view, ok := render.screenshot_map(&ctx, capture)
	if ok {
		fmt.printf(
			"screenshot ready: %dx%d, frame=%d\n",
			view.width,
			view.height,
			view.frame_number,
		)

		save_screenshot_async(&ctx.io, view)
	}

	render.screenshot_release(&ctx, capture)
	capture_pending = false
}
```

The CPU must not stall while waiting for this state.

---

# Async File Output

Do not make PNG/JPEG encoding part of the core renderer API.

The renderer should expose:

- raw pixel bytes
- width
- height
- row stride
- Vulkan format
- captured frame number

The application/tooling layer should handle:

- format conversion if needed
- PNG encoding
- filesystem output
- agent-facing metadata

The existing `vk_io` worker should be used for file output if practical.

Important lifetime rule:

`Screenshot_View.pixels` may refer directly to mapped staging-buffer memory.

Therefore the async I/O request must own/copy the bytes it needs before:

```odin
screenshot_release(...)
```

recycles or destroys the screenshot readback buffer.

Do not enqueue a borrowed slice into another thread and immediately release its backing storage.

---

# Agent-Facing Output

For now, Ctrl+P should save something similar to:

```text
captures/
    frame_00000184.png
    frame_00000184.json
```

Example metadata:

```json
{
  "frame": 184,
  "target": "offscreen",
  "width": 1280,
  "height": 720,
  "format": "VK_FORMAT_R8G8B8A8_UNORM"
}
```

The important architectural goal is that future agent tooling can do:

```odin
handle := render.screenshot_request(&ctx)
```

without needing to synthesize keyboard input.

---

# Pixel Format Handling

Do not bake presentation/tonemapping assumptions into the renderer-side readback API.

If the offscreen image is directly PNG-friendly, for example:

```text
VK_FORMAT_R8G8B8A8_UNORM
```

the tooling layer can encode it directly.

If the offscreen target is HDR, for example:

```text
VK_FORMAT_R16G16B16A16_SFLOAT
```

the renderer should return the raw format-preserving pixel data.

The tooling layer should then convert or tonemap FP16 -> RGBA8 when generating a PNG for an agent.

Keep the screenshot API format-preserving.

---

# Multiple Outstanding Requests

The renderer itself must support more than one outstanding screenshot request.

Do **not** put a global rule in the renderer that only one capture may exist.

The current Ctrl+P UI may intentionally do:

```odin
if !capture_pending {
	// request screenshot
}
```

but that is only an interaction-level restriction.

Future tooling should be able to queue captures such as:

```text
capture before operation
capture after operation
capture offscreen target
capture normal buffer
capture shadow map
```

without needing a separate implementation.

A generational handle/resource-pool style implementation is preferred because the renderer already uses this pattern for other resources.

---

# Recommended Internal Types

Something along these lines is sufficient:

```odin
Screenshot_Request :: struct {
	state: Screenshot_Status,
	target: Screenshot_Target,

	readback_buffer: Buffer_Handle,

	completion_value: u64,
	frame_number:     u64,

	width:      u32,
	height:     u32,
	row_stride: u32,
	format:     vk.Format,
}

Screenshot_System :: struct {
	// Prefer the project's existing generational resource-pool abstraction
	// rather than necessarily using a raw dynamic array.
}
```

Add to `Context`:

```odin
screenshots: Screenshot_System,
frame_number: u64,
```

Use existing project abstractions where appropriate rather than duplicating resource-management infrastructure.

---

# Important Synchronization Requirements

The implementation must satisfy all of the following:

- No `vkDeviceWaitIdle`.
- No screenshot-related `vkQueueWaitIdle`.
- No screenshot-related `vkWaitSemaphores`.
- No host stall waiting for the screenshot.
- The offscreen image must not be copied until Pass B has finished sampling it.
- The staging buffer must not be read before the frame's timeline completion value has been reached.
- A timeline completion value must only be associated with the screenshot after successful queue submission.
- The screenshot request must survive skipped/out-of-date acquisition attempts until it is actually recorded into a submitted frame.
- Non-coherent mapped memory must be invalidated before CPU reading.
- Async I/O must own the pixel bytes before screenshot backing storage is released/reused.

---

# Expected Ctrl+P Flow

```text
CPU                                             GPU

Ctrl+P
  |
  +-- screenshot_request()
  |      state = Queued
  |
  +-- run_frame()
  |      |
  |      +-- Pass A --------------------------> offscreen render
  |      |
  |      +-- Pass B --------------------------> sample offscreen -> swapchain
  |      |
  |      +-- screenshot copy -----------------> offscreen -> staging buffer
  |      |
  |      +-- QueueSubmit(value = 381)
  |
  +-- request.state = Submitted
  |   request.completion_value = 381
  |
  +-- application continues immediately
  |
  +-- screenshot_status()
  |      timeline = 379
  |      -> Submitted
  |
  +-- application continues
  |
  +-- screenshot_status()
         timeline = 383
         -> Ready
                |
                +-- copy/encode/write asynchronously
```

---

# Acceptance Criteria

The task is complete when:

1. Pressing `Ctrl+P` requests an offscreen screenshot.
2. Holding `Ctrl+P` does not flood requests due to key repeat.
3. Rendering continues normally while the capture is in flight.
4. No screenshot path calls a blocking GPU wait.
5. If swapchain acquisition is skipped/out-of-date immediately after pressing `Ctrl+P`, the screenshot remains queued.
6. The screenshot is captured from the next successfully submitted frame.
7. The image copy happens after Pass B has finished sampling the offscreen target.
8. Completion is determined using the existing timeline semaphore.
9. `screenshot_status()` eventually reports `Ready`.
10. `screenshot_map()` returns valid pixels and metadata.
11. The capture can be asynchronously written to disk.
12. The screenshot's backing resource is safely released/reused afterward.
13. The renderer supports multiple outstanding screenshot handles even though Ctrl+P currently allows one interactive capture at a time.
14. The screenshot API is independent of SDL and can later be called directly by agent tooling.
15. No validation-layer synchronization/layout errors are introduced.
16. Screenshot requests do not materially affect normal frame latency when no capture is requested.

---

# Scope Notes

For the initial implementation:

- Only `Screenshot_Target.Offscreen` needs to work.
- Do not implement depth/shadow/G-buffer visualization yet.
- Do not build a separate agent-only screenshot implementation.
- Do not introduce a CPU wait just to simplify ownership.
- Prefer existing resource pools, handles, mapped-buffer helpers, and async I/O abstractions already present in the codebase.

Design the API so arbitrary image capture can be added later without breaking the public screenshot interface.
