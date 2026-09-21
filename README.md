# Odin Vulkan + dedicated nbio event loop

The original single-file program is split by responsibility:

- `main.odin` — application lifecycle and SDL event loop.
- `types.odin` — shared renderer/Vulkan data structures and constants.
- `io.odin` — dedicated `nbio` thread, cross-thread writes, draining and shutdown.
- `vulkan.odin` — Vulkan/SDL initialization, resource creation and cleanup.
- `renderer.odin` — per-frame compute, synchronization, presentation and frame pacing.

All `.odin` files remain in the same `package main`, so no package API layer is needed yet.

Build or run the directory as a unit, for example:

```sh
odin run .
```

`comp.spv` is still expected in the process working directory, exactly as in the original program.
