package render

import vk "vendor:vulkan"

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

screenshot_request :: proc(
	ctx: ^Context,
	desc := Screenshot_Desc{target = .Offscreen},
) -> Screenshot_Handle {
	ctx.screenshots.next_generation += 1
	generation := ctx.screenshots.next_generation

	for &req, i in ctx.screenshots.requests {
		if req.state == .Invalid {
			req.handle = Screenshot_Handle {
				index      = u16(i),
				generation = generation,
			}
			req.state = .Queued
			req.target = desc.target
			req.completion_value = 0
			req.frame_number = 0

			return req.handle
		}
	}

	handle := Screenshot_Handle {
		index      = u16(len(ctx.screenshots.requests)),
		generation = generation,
	}

	append(
		&ctx.screenshots.requests,
		Screenshot_Request{handle = handle, state = .Queued, target = desc.target},
	)

	return handle
}

screenshot_try_get :: proc(
	ctx: ^Context,
	handle: Screenshot_Handle,
) -> (^Screenshot_Request, bool) {
	if int(handle.index) >= len(ctx.screenshots.requests) {
		return nil, false
	}

	req := &ctx.screenshots.requests[handle.index]
	if req.state == .Invalid || req.handle.generation != handle.generation {
		return nil, false
	}

	return req, true
}

//
// Non-blocking. Advances every Submitted request whose timeline completion
// value has been reached to Ready (or Failed, if the semaphore query itself
// fails). Call this once per frame; screenshot_status then just reads back
// the state this leaves behind.
//
screenshot_poll :: proc(ctx: ^Context) {
	any_submitted := false
	for &req in ctx.screenshots.requests {
		if req.state == .Submitted {
			any_submitted = true
			break
		}
	}

	if !any_submitted {
		return
	}

	completed: u64
	res := vk.GetSemaphoreCounterValue(ctx.device, ctx.timeline_semaphore, &completed)

	for &req in ctx.screenshots.requests {
		if req.state != .Submitted {
			continue
		}

		if res != .SUCCESS {
			req.state = .Failed
			continue
		}

		if completed >= req.completion_value {
			req.state = .Ready
		}
	}
}

screenshot_status :: proc(ctx: ^Context, handle: Screenshot_Handle) -> Screenshot_Status {
	req, found := screenshot_try_get(ctx, handle)
	if !found {
		return .Invalid
	}

	return req.state
}

screenshot_map :: proc(ctx: ^Context, handle: Screenshot_Handle) -> (Screenshot_View, bool) {
	req, found := screenshot_try_get(ctx, handle)
	if !found || req.state != .Ready {
		return {}, false
	}

	buffer, buffer_found := resource_try_get(&ctx.buffer_pool, req.readback_buffer)
	if !buffer_found {
		return {}, false
	}

	size := int(req.row_stride) * int(req.height)
	pixels := ([^]u8)(buffer.mapped)[:size]

	return Screenshot_View {
		pixels = pixels,
		width = req.width,
		height = req.height,
		row_stride = req.row_stride,
		format = req.format,
		frame_number = req.frame_number,
	}, true
}

screenshot_release :: proc(ctx: ^Context, handle: Screenshot_Handle) {
	req, found := screenshot_try_get(ctx, handle)
	if !found {
		return
	}

	if resource_is_valid(&ctx.buffer_pool, req.readback_buffer) {
		resource_destroy(ctx, &ctx.buffer_pool, req.readback_buffer)
	}

	req.readback_buffer = {}
	req.state = .Invalid
}

screenshot_format_bytes_per_pixel :: proc(format: vk.Format) -> u32 {
	#partial switch format {
	case .R8G8B8A8_UNORM, .B8G8R8A8_UNORM, .R8G8B8A8_SRGB, .B8G8R8A8_SRGB:
		return 4
	case .R16G16B16A16_SFLOAT:
		return 8
	case:
		panic("screenshot: unsupported readback format")
	}
}

//
// Records the offscreen-target -> staging-buffer copy for a request that is
// being attached to the frame currently being recorded. Must be called after
// Pass B has finished sampling the offscreen image (i.e. while it is still
// SHADER_READ_ONLY_OPTIMAL) and before the command buffer is ended.
//
// Allocates (or reallocates, if this slot's previous readback buffer is the
// wrong size) a host-visible, host-coherent staging buffer sized for the
// image's current extent/format -- create_buffer only selects HOST_COHERENT
// memory, so there is no non-coherent-memory case to invalidate here.
//
// Leaves the source image in TRANSFER_SRC_OPTIMAL; the next frame discards
// its contents via oldLayout = UNDEFINED, so no transition back is needed.
//
record_screenshot_readback :: proc(
	ctx: ^Context,
	cmd: vk.CommandBuffer,
	handle: Screenshot_Handle,
	image: ^Image,
) {
	req, found := screenshot_try_get(ctx, handle)
	if !found {
		return
	}

	bytes_per_pixel := screenshot_format_bytes_per_pixel(image.format)
	width := image.extent.width
	height := image.extent.height
	row_stride := width * bytes_per_pixel
	size := vk.DeviceSize(row_stride) * vk.DeviceSize(height)

	if resource_is_valid(&ctx.buffer_pool, req.readback_buffer) {
		resource_destroy(ctx, &ctx.buffer_pool, req.readback_buffer)
	}
	req.readback_buffer = create_buffer(ctx, size, {.TRANSFER_DST})

	req.width = width
	req.height = height
	req.row_stride = row_stride
	req.format = image.format

	full_range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		levelCount = 1,
		layerCount = 1,
	}

	to_transfer := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.FRAGMENT_SHADER},
		srcAccessMask       = {.SHADER_READ},
		dstStageMask        = {.COPY},
		dstAccessMask       = {.TRANSFER_READ},
		oldLayout           = .SHADER_READ_ONLY_OPTIMAL,
		newLayout           = .TRANSFER_SRC_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image.object,
		subresourceRange    = full_range,
	}

	to_transfer_deps := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &to_transfer,
	}

	vk.CmdPipelineBarrier2(cmd, &to_transfer_deps)

	readback_buffer := resource_get(&ctx.buffer_pool, req.readback_buffer)

	region := vk.BufferImageCopy2 {
		sType = .BUFFER_IMAGE_COPY_2,
		imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
		imageExtent = {width = width, height = height, depth = 1},
	}

	copy_info := vk.CopyImageToBufferInfo2 {
		sType          = .COPY_IMAGE_TO_BUFFER_INFO_2,
		srcImage       = image.object,
		srcImageLayout = .TRANSFER_SRC_OPTIMAL,
		dstBuffer      = readback_buffer.object,
		regionCount    = 1,
		pRegions       = &region,
	}

	vk.CmdCopyImageToBuffer2(cmd, &copy_info)

	buffer_barrier := vk.BufferMemoryBarrier2 {
		sType               = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask        = {.COPY},
		srcAccessMask       = {.TRANSFER_WRITE},
		dstStageMask        = {.HOST},
		dstAccessMask       = {.HOST_READ},
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		buffer              = readback_buffer.object,
		offset              = 0,
		size                = vk.DeviceSize(vk.WHOLE_SIZE),
	}

	buffer_deps := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = 1,
		pBufferMemoryBarriers    = &buffer_barrier,
	}

	vk.CmdPipelineBarrier2(cmd, &buffer_deps)
}
