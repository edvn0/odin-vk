package render

import config "../config"
import "core:fmt"
import vk "vendor:vulkan"

wait_timeline :: proc(ctx: ^Context, value: u64) {
	if value == 0 {
		return
	}

	completed: u64
	if res := vk.GetSemaphoreCounterValue(ctx.device, ctx.timeline_semaphore, &completed);
	   res != .SUCCESS {
		fmt.panicf("vkGetSemaphoreCounterValue failed: %v", res)
	}

	value_to_wait_for := value
	semaphore := ctx.timeline_semaphore

	wait_info := vk.SemaphoreWaitInfo {
		sType          = .SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores    = &semaphore,
		pValues        = &value_to_wait_for,
	}

	if res := vk.WaitSemaphores(ctx.device, &wait_info, max(u64)); res != .SUCCESS {
		fmt.panicf("vkWaitSemaphores failed waiting for %d: %v", value, res)
	}
}

run_compute :: proc(ctx: ^Context, slot: int) -> (row: [config.CELL_COUNT]u32, submitted: bool) {
	prev_slot := (slot + (MAX_FRAMES_IN_FLIGHT - 1)) % MAX_FRAMES_IN_FLIGHT

	wait_timeline(ctx, ctx.frames[slot].completion_value)

	collect_bindless_retirements(ctx)

	buffer, found := resource_try_get(&ctx.buffer_pool, ctx.frames[slot].buffer)
	if !found {
		fmt.panicf("failed to get buffer for slot %d", slot)
	}

	prev_buffer, buffer_found := resource_try_get(&ctx.buffer_pool, ctx.frames[prev_slot].buffer)
	if !buffer_found {
		fmt.panicf("failed to get previous buffer for slot %d", prev_slot)
	}

	row = (^[config.CELL_COUNT]u32)(buffer.mapped)^

	image_available := ctx.frames[slot].image_available

	image_index: u32
	ACQUIRE_TIMEOUT_NS :: u64(100_000_000)
	acquire_result := vk.AcquireNextImageKHR(
		ctx.device,
		ctx.swapchain.handle,
		ACQUIRE_TIMEOUT_NS,
		image_available,
		0,
		&image_index,
	)

	if acquire_result == .TIMEOUT || acquire_result == .NOT_READY {
		return row, false
	}

	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		return row, false
	}

	if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		fmt.panicf("failed to acquire swapchain image: %v", acquire_result)
	}

	image := ctx.swapchain.images[image_index]

	render_finished := ctx.render_finished_semaphores[image_index]

	cmd := ctx.frames[slot].command_buffer

	if res := vk.ResetCommandBuffer(cmd, {}); res != .SUCCESS {
		fmt.panicf("failed to reset command buffer: %v", res)
	}

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}

	if res := vk.BeginCommandBuffer(cmd, &begin_info); res != .SUCCESS {
		fmt.panicf("failed to begin command buffer: %v", res)
	}

	vk.CmdBindDescriptorSets(cmd, .COMPUTE, ctx.pipeline_layout, 0, 1, &ctx.bindless.set, 0, nil)

	compute_stage := vk.ShaderStageFlags{.COMPUTE}
	compute_shader := get_shader(ctx, "conway_1d", compute_stage)
	vk.CmdBindShadersEXT(cmd, 1, &compute_stage, &compute_shader.object)

	push := PushConstants {
		prev = prev_buffer.device_address,
		curr = buffer.device_address,
	}

	vk.CmdPushConstants(
		cmd,
		ctx.pipeline_layout,
		ctx.global_push_constant_range.stageFlags,
		0,
		cast(u32)(size_of(PushConstants)),
		&push,
	)

	vk.CmdDispatch(cmd, 1, 1, 1)

	//
	// Make shader writes available to the host after this submission has
	// completed.
	//
	memory_barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask  = {.HOST},
		dstAccessMask = {.HOST_READ},
	}

	dependency_info := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = &memory_barrier,
	}

	vk.CmdPipelineBarrier2(cmd, &dependency_info)

	clear_range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		levelCount = 1,
		layerCount = 1,
	}

	//
	// Acquired swapchain image -> transfer destination.
	//
	to_transfer_dst := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.TOP_OF_PIPE},
		dstStageMask        = {.CLEAR},
		dstAccessMask       = {.TRANSFER_WRITE},
		oldLayout           = .UNDEFINED,
		newLayout           = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = clear_range,
	}

	to_transfer_dst_deps := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &to_transfer_dst,
	}

	vk.CmdPipelineBarrier2(cmd, &to_transfer_dst_deps)

	clear_color := vk.ClearColorValue{}

	if row[config.CELL_COUNT / 2] != 0 {
		clear_color.float32 = {1, 1, 1, 1}
	} else {
		clear_color.float32 = {0, 0, 0, 1}
	}

	vk.CmdClearColorImage(cmd, image, .TRANSFER_DST_OPTIMAL, &clear_color, 1, &clear_range)

	//
	// Transfer destination -> presentation.
	//
	to_present := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.CLEAR},
		srcAccessMask       = {.TRANSFER_WRITE},
		dstStageMask        = {.BOTTOM_OF_PIPE},
		oldLayout           = .TRANSFER_DST_OPTIMAL,
		newLayout           = .PRESENT_SRC_KHR,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = clear_range,
	}

	to_present_deps := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &to_present,
	}

	vk.CmdPipelineBarrier2(cmd, &to_present_deps)

	if res := vk.EndCommandBuffer(cmd); res != .SUCCESS {
		fmt.panicf("failed to end command buffer: %v", res)
	}

	//
	// Allocate a unique completion epoch for this submission.
	//
	ctx.timeline_value += 1
	submission_value := ctx.timeline_value

	//
	// vkAcquireNextImageKHR signals this binary semaphore.
	//
	wait_semaphores := [1]vk.Semaphore{image_available}

	wait_stage_masks := [1]vk.PipelineStageFlags{{.TRANSFER}}

	//
	// Binary semaphores must use timeline value zero.
	//
	wait_values := [1]u64{0}

	//
	// Signal:
	//
	//   render_finished       binary semaphore for presentation
	//   timeline_semaphore    global GPU completion timeline
	//
	signal_semaphores := [2]vk.Semaphore{render_finished, ctx.timeline_semaphore}

	signal_values := [2]u64{0, submission_value}

	timeline_submit := vk.TimelineSemaphoreSubmitInfo {
		sType                     = .TIMELINE_SEMAPHORE_SUBMIT_INFO,
		waitSemaphoreValueCount   = 1,
		pWaitSemaphoreValues      = raw_data(wait_values[:]),
		signalSemaphoreValueCount = 2,
		pSignalSemaphoreValues    = raw_data(signal_values[:]),
	}

	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		pNext                = &timeline_submit,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = raw_data(wait_semaphores[:]),
		pWaitDstStageMask    = raw_data(wait_stage_masks[:]),
		commandBufferCount   = 1,
		pCommandBuffers      = &cmd,
		signalSemaphoreCount = 2,
		pSignalSemaphores    = raw_data(signal_semaphores[:]),
	}

	//
	// IMPORTANT:
	//
	// Do not record completion_value unless the submit actually succeeded.
	// Otherwise we'd later wait forever for a timeline value that can never
	// be signalled.
	//
	if res := vk.QueueSubmit(ctx.compute_queue, 1, &submit_info, 0); res != .SUCCESS {
		fmt.panicf("vkQueueSubmit failed for timeline value %d: %v", submission_value, res)
	}

	ctx.frames[slot].completion_value = submission_value

	//
	// Queue presentation, but DO NOT wait for presentation to finish.
	//
	ctx.present_id += 1
	present_id := ctx.present_id

	present_ids := [1]u64{present_id}

	present_id_info := vk.PresentIdKHR {
		sType          = .PRESENT_ID_KHR,
		swapchainCount = 1,
		pPresentIds    = raw_data(present_ids[:]),
	}

	swapchains := [1]vk.SwapchainKHR{ctx.swapchain.handle}

	image_indices := [1]u32{image_index}

	present_wait_semaphores := [1]vk.Semaphore{render_finished}

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		pNext              = &present_id_info,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = raw_data(present_wait_semaphores[:]),
		swapchainCount     = 1,
		pSwapchains        = raw_data(swapchains[:]),
		pImageIndices      = raw_data(image_indices[:]),
	}

	present_result := vk.QueuePresentKHR(ctx.compute_queue, &present_info)

	if present_result == .ERROR_OUT_OF_DATE_KHR {
		return row, true
	}

	if present_result != .SUCCESS && present_result != .SUBOPTIMAL_KHR {
		fmt.panicf("failed to present swapchain image: %v", present_result)
	}

	return row, true
}
