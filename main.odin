package main

import "core:debug/trace"
import "core:fmt"
import "maths"
import "render"
import "vendor:sdl2"
import vk_io "vk_io"

write_grid_snapshot :: proc(io: ^vk_io.IO_State, cells: []u32, width: u32) {
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
	track: trace.Tracking_Allocator
	trace.tracking_allocator_init(&track, context.allocator)
	defer trace.tracking_allocator_destroy(&track)

	context.allocator = trace.tracking_allocator(&track)
	defer trace.tracking_allocator_print_results(&track)

	context.assertion_failure_proc = trace.assertion_failure_proc

	_main()
}

_main :: proc() {
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

	perf_frequency := f32(sdl2.GetPerformanceFrequency())
	last_counter := sdl2.GetPerformanceCounter()

	capture: render.Screenshot_Handle
	capture_pending := false

	for running {
		now_counter := sdl2.GetPerformanceCounter()
		dt := f32(now_counter - last_counter) / perf_frequency
		last_counter = now_counter

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

			if event.type == .KEYDOWN {
				if event.key.keysym.sym == .ESCAPE {
					running = false
				}

				ctrl_down := (event.key.keysym.mod & sdl2.KMOD_CTRL) != {}

				if ctrl_down &&
				   event.key.keysym.sym == .p &&
				   event.key.repeat == 0 &&
				   !capture_pending {
					capture = render.screenshot_request(&ctx, {target = .Offscreen})

					capture_pending = true
					fmt.println("screenshot requested")
				}
			}

		}

		if ctx.framebuffer_resized {
			recreate_swapchain(&ctx)
		}

		render.begin_frame(&ctx)

		render.submit_mesh(
			&ctx,
			ctx.mesh,
			render.Draw_Data {
				quat_rotation = maths.make_quat(0, 0, 0, 1),
				translation = maths.make_vec3(0, 1, 0),
				scale = 1.0,
				material_index = 0,
			},
		)

		render.submit_mesh(
			&ctx,
			ctx.mesh,
			render.Draw_Data {
				quat_rotation = maths.make_quat(0, 0, 0, 1),
				translation = maths.make_vec3(-1, 0, -3),
				scale = 1.0,
				material_index = 4,
			},
		)

		render.submit_mesh(
			&ctx,
			ctx.mesh,
			render.Draw_Data {
				quat_rotation = maths.make_quat(0, 0, 0, 1),
				translation = maths.make_vec3(0, 1, 2),
				scale = 1.0,
				material_index = 7,
			},
		)
		slot := frame % render.MAX_FRAMES_IN_FLIGHT
		switch render.run_frame(&ctx, slot, dt) {
		case .Submitted:
			when ODIN_DEBUG {
				grid := render.simulation_debug_readback(&ctx, context.temp_allocator)
				write_grid_snapshot(&ctx.io, grid, ctx.simulation.width)
			}
			frame += 1
		case .Skipped:
		case .Swapchain_Out_Of_Date:
			recreate_swapchain(&ctx)
		}

		render.screenshot_poll(&ctx)

		if capture_pending && render.screenshot_status(&ctx, capture) == .Ready {
			// consume it
			render.screenshot_release(&ctx, capture)
			capture_pending = false
		}
	}
}
