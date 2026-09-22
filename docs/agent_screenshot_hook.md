# Agent Screenshot Hook

A way for an external process (e.g. an agent driving this session from a
shell) to pull a screenshot out of the running renderer without synthesizing
keyboard input, for visual debugging. It reuses the same async screenshot
API described in `docs/async_screenshot_api_task.md` end to end -- there is
no separate agent-only capture path.

## Triggering a capture

While the app is running, create the file:

```text
captures/request
```

Content is ignored; existence is the signal. The main loop (`main.odin`)
polls for it once per frame alongside SDL event handling. When found, it:

1. Deletes the file.
2. If no hook-triggered capture is already pending, calls
   `render.screenshot_request(&ctx, {target = .Offscreen})` -- the exact
   same call `Ctrl+P` makes.

```bash
touch captures/request
```

is enough. If a hook capture is already in flight, the touch is ignored
until that one is consumed (mirrors the `Ctrl+P` debounce, just scoped to
the hook's own handle -- the two trigger sources track separate pending
captures, since the renderer supports multiple outstanding requests).

## Reading the result

The capture is attached to the next successfully submitted frame, same as
`Ctrl+P`: no GPU stall, completion is detected by polling the renderer's
timeline semaphore. Once ready, `consume_capture` in `main.odin` maps it,
writes it to `captures/`, and releases it. Each capture produces three
files, named `hook_frame_<frame_number>.<ext>` (zero-padded to 8 digits):

| File | Contents |
| --- | --- |
| `hook_frame_NNNNNNNN.bmp` | Uncompressed 24bpp BMP -- open it directly to look at the frame. |
| `hook_frame_NNNNNNNN.rgba` | Raw format-preserving pixels straight from the readback buffer (see `Screenshot_View`: width/height/row_stride/format). |
| `hook_frame_NNNNNNNN.json` | `{"frame", "target", "width", "height", "row_stride", "format"}` metadata for the `.rgba` file. |

All three are written asynchronously via `vk_io.write_file_async`, so
watch the `captures/` directory rather than assuming the files exist the
instant the console prints `screenshot ready (hook): ...`.

`Ctrl+P` captures land next to these with a `ctrlp_` prefix instead, using
the same three-file shape.

## End-to-end example

```bash
# app already running
touch captures/request
# poll briefly for the files to land
while [ ! -f captures/hook_frame_*.bmp ] 2>/dev/null; do sleep 0.1; done
```

Then read the newest `captures/hook_frame_*.bmp`.

## Calling the renderer API directly instead

The file trigger exists because an external process can't call into a
running Odin process's functions directly. Code running inside the process
(future in-process agent tooling, other subsystems, etc.) should skip the
file dance and call the renderer API directly, exactly like the hook does
internally:

```odin
handle := render.screenshot_request(&ctx, {target = .Offscreen})

// ... later, once per frame:
render.screenshot_poll(&ctx)
if render.screenshot_status(&ctx, handle) == .Ready {
	view, ok := render.screenshot_map(&ctx, handle)
	if ok {
		// view.pixels / .width / .height / .row_stride / .format / .frame_number
	}
	render.screenshot_release(&ctx, handle)
}
```

This is the same public API documented in
`docs/async_screenshot_api_task.md`; the file hook is just one more caller
of it, not a parallel implementation.
