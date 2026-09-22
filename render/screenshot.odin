package render

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

import vk "vendor:vulkan"