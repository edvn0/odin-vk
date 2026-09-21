package main

import "core:fmt"
import "vendor:sdl2"
import "render"
import vk_io "vk_io"

write_conway_row :: proc(
	io: ^vk_io.IO_State,
	row: []u32,
) {
	buffer := make([]u8, len(row) + 1, context.temp_allocator)

	for cell, i in row {
		buffer[i] = '#' if cell != 0 else '.'
	}

	buffer[len(row)] = '\n'

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
		}

		slot := frame % render.MAX_FRAMES_IN_FLIGHT
		row, submitted := render.run_compute(&ctx, slot)
		if submitted {
			write_conway_row(&ctx.io, row[:len(row)])
			frame += 1
		}
	}
}
