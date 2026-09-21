package vk_io

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:nbio"
import "core:sync"
import "core:thread"

OUTPUT_PATH :: "rows.txt"

IO_STARTING ::  0
IO_READY    ::  1
IO_FAILED   :: -1

IO_State :: struct {
	loop:          ^nbio.Event_Loop,
	output_handle: nbio.Handle,
	thread:        ^thread.Thread,

	output_offset: int,

	startup_done: sync.One_Shot_Event,

	start_state:    i32,
	stop_requested: i32,
	pending_writes: i32,
}

Write_Request :: struct {
	io:   ^IO_State,
	data: []u8,
}

io_start :: proc(io: ^IO_State) -> bool {
	io.thread = thread.create_and_start_with_data(
		rawptr(io),
		io_thread_main,
		name = "nbio-io",
	)

	if io.thread == nil {
		return false
	}

	sync.one_shot_event_wait(&io.startup_done)

	if intrinsics.atomic_load(&io.start_state) == IO_READY {
		return true
	}

	thread.destroy(io.thread)
	io.thread = nil

	return false
}

io_stop :: proc(io: ^IO_State) {
	if io.thread == nil do return

	intrinsics.atomic_store(&io.stop_requested, 1)

	if io.loop != nil {
		nbio.wake_up(io.loop)
	}

	thread.destroy(io.thread)

	io.thread = nil
	io.loop = nil
}

io_thread_main :: proc(data: rawptr) {
	io := (^IO_State)(data)

	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintfln("could not acquire nbio event loop: %v", err)

		intrinsics.atomic_store(&io.start_state, IO_FAILED)
		sync.one_shot_event_signal(&io.startup_done)

		return
	}
	defer nbio.release_thread_event_loop()

	io.loop = nbio.current_thread_event_loop()

	handle, ferr := nbio.open_sync(
		OUTPUT_PATH,
		mode = {.Write, .Create, .Trunc},
		l = io.loop,
	)
	if ferr != nil {
		fmt.eprintfln("could not open %s: %v", OUTPUT_PATH, ferr)

		io.loop = nil

		intrinsics.atomic_store(&io.start_state, IO_FAILED)
		sync.one_shot_event_signal(&io.startup_done)

		return
	}

	io.output_handle = handle

	intrinsics.atomic_store(&io.start_state, IO_READY)
	sync.one_shot_event_signal(&io.startup_done)

	for {
		stop_requested := intrinsics.atomic_load(&io.stop_requested) != 0
		pending_writes := intrinsics.atomic_load(&io.pending_writes)

		if stop_requested && pending_writes == 0 {
			break
		}

		if err := nbio.tick(); err != nil {
			fmt.panicf("nbio.tick failed: %v", err)
		}
	}

	nbio.close(io.output_handle, on_output_closed, l = io.loop)

	if err := nbio.run(); err != nil {
		fmt.eprintfln("nbio.run while closing output failed: %v", err)
	}
}

on_output_closed :: proc(op: ^nbio.Operation) {
	if op.close.err != nil {
		fmt.eprintln("output close failed:", op.close.err)
	}
}

write_async :: proc(io: ^IO_State, data: []u8) -> bool {
	if len(data) == 0 {
		return true
	}

	if intrinsics.atomic_load(&io.stop_requested) != 0 {
		return false
	}

	heap := runtime.heap_allocator()

	req := new(Write_Request, heap)
	if req == nil {
		fmt.eprintln("could not allocate async write request")
		return false
	}

	req.io = io

	req.data = make([]u8, len(data), heap)
	if req.data == nil {
		free(req, heap)
		fmt.eprintln("could not allocate async write buffer")
		return false
	}

	copy(req.data, data)

	offset := io.output_offset
	io.output_offset += len(req.data)

	// Must happen before publishing the operation. The callback may execute
	// immediately after nbio sees it.
	intrinsics.atomic_add(&io.pending_writes, 1)

	nbio.write_poly(
		io.output_handle,
		offset,
		req.data,
		req,
		on_write_completed,
		l = io.loop,
	)

	return true
}

on_write_completed :: proc(op: ^nbio.Operation, req: ^Write_Request) {
	if op.write.err != nil {
		fmt.eprintln("async write failed:", op.write.err)
	}

	io := req.io
	heap := runtime.heap_allocator()

	delete(req.data, heap)
	free(req, heap)

	intrinsics.atomic_sub(&io.pending_writes, 1)
}