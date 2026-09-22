package main

import "core:debug/trace"
import "core:fmt"
import "core:os"
import "maths"
import "render"
import "vendor:sdl2"
import vk_io "vk_io"

CAPTURES_DIR :: "captures"

// An external process (e.g. an agent driving this session) requests a
// capture by creating this file; any content is ignored. The main loop
// polls for it, same as it polls SDL for Ctrl+P, and consumes it through the
// identical render.screenshot_request/status/map/release API -- there is no
// separate agent-only capture path, per docs/async_screenshot_api_task.md.
DEBUG_CAPTURE_REQUEST_PATH :: "captures/request"

// The renderer keeps screenshot pixels format-preserving (no PNG/JPEG
// encoding in the core API -- see docs/async_screenshot_api_task.md). This
// writes the raw pixels, a small JSON sidecar describing how to interpret
// them, and a BMP (so a capture can just be opened/viewed) -- all
// asynchronously via the existing io thread. `tag` identifies the trigger
// source (e.g. "ctrlp", "hook") and namespaces the output filenames.
save_screenshot_async :: proc(io: ^vk_io.IO_State, tag: string, view: render.Screenshot_View) {
	pixels_path := fmt.tprintf("%s/%s_frame_%08d.rgba", CAPTURES_DIR, tag, view.frame_number)
	vk_io.write_file_async(io, pixels_path, view.pixels)

	metadata := fmt.tprintf(
		"{{\"frame\":%d,\"target\":\"offscreen\",\"width\":%d,\"height\":%d,\"row_stride\":%d,\"format\":\"%v\"}}\n",
		view.frame_number,
		view.width,
		view.height,
		view.row_stride,
		view.format,
	)
	metadata_path := fmt.tprintf("%s/%s_frame_%08d.json", CAPTURES_DIR, tag, view.frame_number)
	vk_io.write_file_async(io, metadata_path, transmute([]u8)metadata)

	bmp := encode_bmp(view, context.temp_allocator)
	bmp_path := fmt.tprintf("%s/%s_frame_%08d.bmp", CAPTURES_DIR, tag, view.frame_number)
	vk_io.write_file_async(io, bmp_path, bmp)
}

// Consumes a capture once it's Ready: maps it, saves it, releases it, and
// clears the caller's pending flag. Shared by every trigger source so they
// all go through the same map/save/release sequence.
consume_capture :: proc(
	ctx: ^render.Context,
	capture: ^render.Screenshot_Handle,
	pending: ^bool,
	tag: string,
) {
	if !pending^ || render.screenshot_status(ctx, capture^) != .Ready {
		return
	}

	view, ok := render.screenshot_map(ctx, capture^)
	if ok {
		fmt.printf(
			"screenshot ready (%s): %dx%d, frame=%d\n",
			tag,
			view.width,
			view.height,
			view.frame_number,
		)

		save_screenshot_async(&ctx.io, tag, view)
	}

	render.screenshot_release(ctx, capture^)
	pending^ = false
}

BMP_File_Header :: struct #packed {
	magic:       [2]u8,
	file_size:   u32le,
	reserved:    u32le,
	data_offset: u32le,
}

BMP_Info_Header :: struct #packed {
	header_size:      u32le,
	width:            i32le,
	height:           i32le,
	planes:           u16le,
	bits_per_pixel:   u16le,
	compression:      u32le,
	image_size:       u32le,
	x_pixels_per_m:   i32le,
	y_pixels_per_m:   i32le,
	colors_used:      u32le,
	colors_important: u32le,
}

encode_bmp :: proc(view: render.Screenshot_View, allocator := context.allocator) -> []u8 {
	width := int(view.width)
	height := int(view.height)
	src_bpp := int(view.row_stride) / width

	bgr_order: bool
	#partial switch view.format {
	case .B8G8R8A8_UNORM, .B8G8R8A8_SRGB:
		bgr_order = true
	case .R8G8B8A8_UNORM, .R8G8B8A8_SRGB:
		bgr_order = false
	case:
		panic("encode_bmp: unsupported screenshot format")
	}

	row_size := ((width * 3 + 3) / 4) * 4
	pixel_data_offset := size_of(BMP_File_Header) + size_of(BMP_Info_Header)
	pixel_data_size := row_size * height
	file_size := pixel_data_offset + pixel_data_size

	buffer := make([]u8, file_size, allocator)

	(^BMP_File_Header)(raw_data(buffer))^ = BMP_File_Header {
		magic       = {'B', 'M'},
		file_size   = u32le(file_size),
		data_offset = u32le(pixel_data_offset),
	}

	(^BMP_Info_Header)(&buffer[size_of(BMP_File_Header)])^ = BMP_Info_Header {
		header_size    = size_of(BMP_Info_Header),
		width          = i32le(width),
		height         = i32le(height),
		planes         = 1,
		bits_per_pixel = 24,
		image_size     = u32le(pixel_data_size),
	}

	for y in 0 ..< height {
		src_row := y * int(view.row_stride)
		dst_row := pixel_data_offset + (height - 1 - y) * row_size

		for x in 0 ..< width {
			src := src_row + x * src_bpp
			dst := dst_row + x * 3

			if bgr_order {
				buffer[dst + 0] = view.pixels[src + 0]
				buffer[dst + 1] = view.pixels[src + 1]
				buffer[dst + 2] = view.pixels[src + 2]
			} else {
				buffer[dst + 0] = view.pixels[src + 2]
				buffer[dst + 1] = view.pixels[src + 1]
				buffer[dst + 2] = view.pixels[src + 0]
			}
		}
	}

	return buffer
}

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

	if err := os.make_directory(CAPTURES_DIR); err != nil && err != .Exist {
		fmt.eprintln("could not create captures directory:", err)
	}

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

	debug_capture: render.Screenshot_Handle
	debug_capture_pending := false

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

		if os.exists(DEBUG_CAPTURE_REQUEST_PATH) {
			os.remove(DEBUG_CAPTURE_REQUEST_PATH)

			if !debug_capture_pending {
				debug_capture = render.screenshot_request(&ctx, {target = .Offscreen})
				debug_capture_pending = true
				fmt.println("screenshot requested via debug hook")
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

		consume_capture(&ctx, &capture, &capture_pending, "ctrlp")
		consume_capture(&ctx, &debug_capture, &debug_capture_pending, "hook")
	}
}
