package main

import "core:fmt"
import "vendor:sdl2"
import "render"
import vk_io "vk_io"

write_grid_snapshot :: proc(
	io: ^vk_io.IO_State,
	cells: []u32,
	width: u32,
) {
	height := u32(len(cells)) / width
	buffer := make([]u8, len(cells) + int(height), context.temp_allocator)

	out := 0
	for y in 0 ..< height {
		for x in 0 ..< width {
			buffer[out] = '#' if cells[y * width + x] != 0 else '.'
			out += 1
		}
		buffer[out] = '\n'
		out += 1
	}

	vk_io.write_async(io, buffer)
}

main :: proc() {
	ctx: render.Context
	init_window(&ctx)
	init_vulkan(&ctx)
	defer cleanup(&ctx)

	if !vk_io.io_start(&ctx.io) {
		fmt.eprintln("could not start I/O thread")
		return
	}
	defer vk_io.io_stop(&ctx.io)

	running := true
	frame := 0

	for running {
		event: sdl2.Event

		for sdl2.PollEvent(&event) {
			if event.type == .QUIT {
				running = false
			}

			if event.type == .KEYDOWN && event.key.keysym.sym == .ESCAPE {
				running = false
			}

			if event.type == .WINDOWEVENT &&
			   (event.window.event == .RESIZED || event.window.event == .SIZE_CHANGED) {
				ctx.framebuffer_resized = true
			}
		}

		if ctx.framebuffer_resized {
			recreate_swapchain(&ctx)
		}

		slot := frame % render.MAX_FRAMES_IN_FLIGHT
		switch render.run_frame(&ctx, slot) {
		case .Submitted:
			when ODIN_DEBUG {
				grid := render.simulation_debug_readback(&ctx, context.temp_allocator)
				write_grid_snapshot(&ctx.io, grid, ctx.simulation.width)
			}

			frame += 1

		case .Skipped:
		// Nothing was ready this tick; try again next iteration.

		case .Swapchain_Out_Of_Date:
			recreate_swapchain(&ctx)
		}
	}
}
