package render

import "core:fmt"
import "core:math"
import vk "vendor:vulkan"

import "../config"

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

//
// Each frame does two independent things and one draw:
//
//   previous simulation buffer -> Game of Life compute -> current simulation
//   buffer -> display image (full grid). Kept running per current design,
//   but nothing samples the display image any more (see Mesh in types.odin).
//
//   Suzanne mesh buffer -> mesh shader (pass A, one meshlet per workgroup,
//   depth-tested) -> offscreen target -> fragment shader (pass B, sampled
//   draw) -> swapchain.
//
// No CPU readback happens on this path. Use simulation_debug_readback for
// that, as an explicitly opt-in debug facility.
//
run_frame :: proc(ctx: ^Context, slot: int, dt: f32) -> Frame_Result {
	wait_timeline(ctx, ctx.frames[slot].completion_value)

	collect_bindless_retirements(ctx)

	// Gate the automaton's generation on accumulated wall-clock time rather
	// than the render/present rate, so it advances at a fixed pace
	// regardless of framerate. The compute shader always dispatches (it
	// still needs to keep the ping-pong buffers and display image
	// consistent every frame); should_step just tells it whether to apply
	// the Game of Life rule this time or leave the grid as-is.
	ctx.simulation.accumulated_time += dt
	should_step := ctx.simulation.accumulated_time >= config.SIM_STEP_INTERVAL
	if should_step {
		ctx.simulation.accumulated_time -= config.SIM_STEP_INTERVAL
	}

	ubo_buffer, ubo_found := resource_try_get(&ctx.buffer_pool, ctx.ubo_buffers[slot])
	if !ubo_found {
		fmt.panicf("failed to get UBO buffer")
	}

	(^UBO)(ubo_buffer.mapped)^ = UBO {
		dt          = dt,
		should_step = 1 if should_step else 0,
	}

	prev_index := ctx.simulation.current
	curr_index := 1 - ctx.simulation.current

	prev_buffer, prev_found := resource_try_get(&ctx.buffer_pool, ctx.simulation.buffers[prev_index])
	if !prev_found {
		fmt.panicf("failed to get previous simulation buffer")
	}

	curr_buffer, curr_found := resource_try_get(&ctx.buffer_pool, ctx.simulation.buffers[curr_index])
	if !curr_found {
		fmt.panicf("failed to get current simulation buffer")
	}

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
		return .Skipped
	}

	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		return .Swapchain_Out_Of_Date
	}

	if acquire_result == .SUBOPTIMAL_KHR {
		ctx.framebuffer_resized = true
	} else if acquire_result != .SUCCESS {
		fmt.panicf("failed to acquire swapchain image: %v", acquire_result)
	}

	swapchain_image := ctx.swapchain.images[image_index]

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
	compute_shader := get_shader(ctx, "game_of_life", compute_stage)
	vk.CmdBindShadersEXT(cmd, 1, &compute_stage, &compute_shader.object)

	push := PushConstants {
		prev        = prev_buffer.device_address,
		curr        = curr_buffer.device_address,
		ubo         = ubo_buffer.device_address,
		width       = ctx.simulation.width,
		height      = ctx.simulation.height,
		image_index = ctx.simulation.display_image_index,
	}

	vk.CmdPushConstants(
		cmd,
		ctx.pipeline_layout,
		ctx.global_push_constant_range.stageFlags,
		0,
		cast(u32)(size_of(PushConstants)),
		&push,
	)

	// Must match the compute shader's [numthreads(16, 16, 1)].
	GOL_THREADS_PER_GROUP :: 16
	group_x := (ctx.simulation.width + GOL_THREADS_PER_GROUP - 1) / GOL_THREADS_PER_GROUP
	group_y := (ctx.simulation.height + GOL_THREADS_PER_GROUP - 1) / GOL_THREADS_PER_GROUP
	vk.CmdDispatch(cmd, group_x, group_y, 1)

	full_range := vk.ImageSubresourceRange {
		aspectMask = {.COLOR},
		levelCount = 1,
		layerCount = 1,
	}

	offscreen_image, offscreen_found := resource_try_get(&ctx.image_pool, ctx.offscreen_images[slot])
	if !offscreen_found {
		fmt.panicf("failed to get offscreen image")
	}

	depth_image, depth_found := resource_try_get(&ctx.image_pool, ctx.depth_images[slot])
	if !depth_found {
		fmt.panicf("failed to get depth image")
	}

	// Sampled by the mesh pass's fragment shader to tint Suzanne's surface
	// with the Game of Life pattern.
	display_image, display_found := resource_try_get(&ctx.image_pool, ctx.simulation.display_image)
	if !display_found {
		fmt.panicf("failed to get display image")
	}

	depth_range := vk.ImageSubresourceRange {
		aspectMask = {.DEPTH},
		levelCount = 1,
		layerCount = 1,
	}

	//
	// Offscreen image -> color attachment, depth image -> depth attachment,
	// both for the mesh pass (pass A). Contents of both are discarded
	// (cleared) every frame, so oldLayout is UNDEFINED regardless of what
	// they held last frame.
	//
	offscreen_to_attachment := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.TOP_OF_PIPE},
		dstStageMask        = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask       = {.COLOR_ATTACHMENT_WRITE},
		oldLayout           = .UNDEFINED,
		newLayout           = .COLOR_ATTACHMENT_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = offscreen_image.object,
		subresourceRange    = full_range,
	}

	depth_to_attachment := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.TOP_OF_PIPE},
		dstStageMask        = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		dstAccessMask       = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
		oldLayout           = .UNDEFINED,
		newLayout           = .DEPTH_ATTACHMENT_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = depth_image.object,
		subresourceRange    = depth_range,
	}

	// Compute writes (display image) -> fragment-shader read for the mesh
	// pass, which samples it to tint Suzanne's surface.
	display_to_shader_read := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.COMPUTE_SHADER},
		srcAccessMask       = {.SHADER_WRITE},
		dstStageMask        = {.FRAGMENT_SHADER},
		dstAccessMask       = {.SHADER_READ},
		oldLayout           = .GENERAL,
		newLayout           = .SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = display_image.object,
		subresourceRange    = full_range,
	}

	pre_pass_a_barriers := [3]vk.ImageMemoryBarrier2 {
		offscreen_to_attachment,
		depth_to_attachment,
		display_to_shader_read,
	}

	pre_pass_a_deps := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 3,
		pImageMemoryBarriers    = raw_data(pre_pass_a_barriers[:]),
	}

	vk.CmdPipelineBarrier2(cmd, &pre_pass_a_deps)
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, ctx.pipeline_layout, 0, 1, &ctx.bindless.set, 0, nil)

	viewport := vk.Viewport {
		width    = f32(ctx.swapchain.extent.width),
		height   = f32(ctx.swapchain.extent.height),
		maxDepth = 1,
	}
	scissor := vk.Rect2D {
		extent = ctx.swapchain.extent,
	}
	vk.CmdSetViewportWithCount(cmd, 1, &viewport)
	vk.CmdSetScissorWithCount(cmd, 1, &scissor)

	vk.CmdSetVertexInputEXT(cmd, 0, nil, 0, nil)
	vk.CmdSetPrimitiveTopology(cmd, .TRIANGLE_LIST)
	vk.CmdSetPrimitiveRestartEnable(cmd, false)
	vk.CmdSetRasterizerDiscardEnable(cmd, false)
	vk.CmdSetFrontFace(cmd, .COUNTER_CLOCKWISE)
	vk.CmdSetPolygonModeEXT(cmd, .FILL)
	vk.CmdSetRasterizationSamplesEXT(cmd, {._1})
	sample_mask := vk.SampleMask(0xFFFFFFFF)
	vk.CmdSetSampleMaskEXT(cmd, {._1}, &sample_mask)
	vk.CmdSetAlphaToCoverageEnableEXT(cmd, false)
	vk.CmdSetDepthBoundsTestEnable(cmd, false)
	vk.CmdSetDepthBiasEnable(cmd, false)
	vk.CmdSetStencilTestEnable(cmd, false)
	vk.CmdSetDepthClampEnableEXT(cmd, false)
	color_blend_enable := b32(false)
	vk.CmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enable)
	color_write_mask := vk.ColorComponentFlags{.R, .G, .B, .A}
	vk.CmdSetColorWriteMaskEXT(cmd, 0, 1, &color_write_mask)

	task_shader := get_shader(ctx, "suzanne", {.TASK_EXT})
	mesh_shader := get_shader(ctx, "suzanne", {.MESH_EXT})
	mesh_fragment_shader := get_shader(ctx, "suzanne", {.FRAGMENT})

	mesh_pass_stages := [7]vk.ShaderStageFlags {
		{.TASK_EXT},
		{.MESH_EXT},
		{.VERTEX},
		{.TESSELLATION_CONTROL},
		{.TESSELLATION_EVALUATION},
		{.GEOMETRY},
		{.FRAGMENT},
	}
	mesh_pass_shaders := [7]vk.ShaderEXT {
		task_shader.object,
		mesh_shader.object,
		{},
		{},
		{},
		{},
		mesh_fragment_shader.object,
	}
	vk.CmdBindShadersEXT(cmd, 7, raw_data(mesh_pass_stages[:]), raw_data(mesh_pass_shaders[:]))

	vk.CmdSetDepthTestEnable(cmd, true)
	vk.CmdSetDepthWriteEnable(cmd, true)
	vk.CmdSetDepthCompareOp(cmd, .LESS)
	// Suzanne is a closed opaque mesh: without this, both sides of every
	// triangle rasterize and whichever one happens to land last (e.g. an
	// interior back face) can visually win, showing through the surface.
	vk.CmdSetCullMode(cmd, {.BACK})

	offscreen_attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = offscreen_image.view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .STORE,
		clearValue  = {color = {float32 = {0.05, 0.05, 0.08, 1}}},
	}

	depth_attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = depth_image.view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp      = .CLEAR,
		storeOp     = .DONT_CARE,
		clearValue  = {depthStencil = {depth = 1}},
	}

	offscreen_rendering_info := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = {extent = ctx.swapchain.extent},
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &offscreen_attachment,
		pDepthAttachment     = &depth_attachment,
	}

	vk.CmdBeginRendering(cmd, &offscreen_rendering_info)

	mesh_buffer, mesh_buffer_found := resource_try_get(&ctx.buffer_pool, ctx.mesh.vertex_buffer)
	if !mesh_buffer_found {
		fmt.panicf("failed to get mesh vertex buffer")
	}

	bounds_buffer, bounds_buffer_found := resource_try_get(&ctx.buffer_pool, ctx.mesh.bounds_buffer)
	if !bounds_buffer_found {
		fmt.panicf("failed to get mesh bounds buffer")
	}

	mesh_push := Mesh_Push_Constants {
		vertices      = mesh_buffer.device_address,
		bounds        = bounds_buffer.device_address,
		ubo           = ubo_buffer.device_address,
		angle         = ctx.mesh.rotation,
		aspect        = f32(ctx.swapchain.extent.width) / f32(ctx.swapchain.extent.height),
		count         = ctx.mesh.vertex_count,
		meshlet_count = ctx.mesh.meshlet_count,
		texture_index = ctx.simulation.display_texture_index,
		sampler_index = ctx.nearest_sampler_index,
	}
	vk.CmdPushConstants(
		cmd,
		ctx.pipeline_layout,
		ctx.global_push_constant_range.stageFlags,
		0,
		size_of(Mesh_Push_Constants),
		&mesh_push,
	)

	// The task shader dispatches TASK_GROUP_MESHLETS-sized batches of
	// meshlets (see shaders/suzanne.task.slang); each of these task
	// workgroups then amplifies into up to TASK_GROUP_MESHLETS mesh
	// workgroups of its own via DispatchMesh.
	MESH_TASK_GROUP_MESHLETS :: 32
	task_group_count := (ctx.mesh.meshlet_count + MESH_TASK_GROUP_MESHLETS - 1) / MESH_TASK_GROUP_MESHLETS
	vk.CmdDrawMeshTasksEXT(cmd, task_group_count, 1, 1)

	vk.CmdEndRendering(cmd)

	//
	// Offscreen target -> fragment-shader read for the swapchain-final pass.
	// Acquired swapchain image -> color attachment for that pass. Display
	// image -> GENERAL, ready for the next frame's compute write.
	//
	offscreen_to_shader_read := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask       = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask        = {.FRAGMENT_SHADER},
		dstAccessMask       = {.SHADER_READ},
		oldLayout           = .COLOR_ATTACHMENT_OPTIMAL,
		newLayout           = .SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = offscreen_image.object,
		subresourceRange    = full_range,
	}

	swapchain_to_attachment := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.TOP_OF_PIPE},
		dstStageMask        = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask       = {.COLOR_ATTACHMENT_WRITE},
		oldLayout           = .UNDEFINED,
		newLayout           = .COLOR_ATTACHMENT_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = swapchain_image,
		subresourceRange    = full_range,
	}

	display_to_general := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.FRAGMENT_SHADER},
		srcAccessMask       = {.SHADER_READ},
		dstStageMask        = {.COMPUTE_SHADER},
		dstAccessMask       = {.SHADER_WRITE},
		oldLayout           = .SHADER_READ_ONLY_OPTIMAL,
		newLayout           = .GENERAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = display_image.object,
		subresourceRange    = full_range,
	}

	pre_pass_b_barriers := [3]vk.ImageMemoryBarrier2 {
		offscreen_to_shader_read,
		swapchain_to_attachment,
		display_to_general,
	}

	pre_pass_b_deps := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 3,
		pImageMemoryBarriers    = raw_data(pre_pass_b_barriers[:]),
	}

	vk.CmdPipelineBarrier2(cmd, &pre_pass_b_deps)

	//
	// Pass B: sample the offscreen target into the swapchain image.
	//
	swapchain_attachment := vk.RenderingAttachmentInfo {
		sType       = .RENDERING_ATTACHMENT_INFO,
		imageView   = ctx.swapchain.image_views[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp      = .DONT_CARE,
		storeOp     = .STORE,
	}

	swapchain_rendering_info := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = {extent = ctx.swapchain.extent},
		layerCount           = 1,
		colorAttachmentCount = 1,
		pColorAttachments    = &swapchain_attachment,
	}

	vk.CmdBeginRendering(cmd, &swapchain_rendering_info)

	// Switch back to the classic vertex pipeline: unbind TASK_EXT/MESH_EXT
	// (bound by the mesh pass above) and bind VERTEX/FRAGMENT.
	classic_pass_stages := [7]vk.ShaderStageFlags {
		{.TASK_EXT},
		{.MESH_EXT},
		{.VERTEX},
		{.TESSELLATION_CONTROL},
		{.TESSELLATION_EVALUATION},
		{.GEOMETRY},
		{.FRAGMENT},
	}
	fullscreen_vertex_shader := get_shader(ctx, "fullscreen", {.VERTEX})
	sample_fragment_shader := get_shader(ctx, "sample", {.FRAGMENT})
	classic_pass_shaders := [7]vk.ShaderEXT {
		{},
		{},
		fullscreen_vertex_shader.object,
		{},
		{},
		{},
		sample_fragment_shader.object,
	}
	vk.CmdBindShadersEXT(cmd, 7, raw_data(classic_pass_stages[:]), raw_data(classic_pass_shaders[:]))

	vk.CmdSetDepthTestEnable(cmd, false)
	vk.CmdSetDepthWriteEnable(cmd, false)
	vk.CmdSetCullMode(cmd, {})

	swapchain_push := Sample_Push_Constants {
		texture_index = ctx.offscreen_texture_indices[slot],
		sampler_index = ctx.nearest_sampler_index,
	}
	vk.CmdPushConstants(
		cmd,
		ctx.pipeline_layout,
		ctx.global_push_constant_range.stageFlags,
		0,
		size_of(Sample_Push_Constants),
		&swapchain_push,
	)

	vk.CmdDraw(cmd, 3, 1, 0, 0)

	vk.CmdEndRendering(cmd)

	//
	// Swapchain image -> presentation.
	//
	swapchain_to_present := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask       = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask        = {.BOTTOM_OF_PIPE},
		oldLayout           = .COLOR_ATTACHMENT_OPTIMAL,
		newLayout           = .PRESENT_SRC_KHR,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = swapchain_image,
		subresourceRange    = full_range,
	}

	post_pass_b_barriers := [1]vk.ImageMemoryBarrier2{swapchain_to_present}

	post_pass_b_deps := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = raw_data(post_pass_b_barriers[:]),
	}

	vk.CmdPipelineBarrier2(cmd, &post_pass_b_deps)

	if res := vk.EndCommandBuffer(cmd); res != .SUCCESS {
		fmt.panicf("failed to end command buffer: %v", res)
	}

	//
	// Allocate a unique completion epoch for this submission.
	//
	ctx.timeline_value += 1
	submission_value := ctx.timeline_value

	//
	// Wait for:
	//
	//   image_available     binary semaphore from vkAcquireNextImageKHR
	//   timeline_semaphore   previous generation's compute writes, so the GPU
	//                        (not the CPU) enforces the automaton's
	//                        generation-to-generation dependency
	//
	wait_semaphores := [2]vk.Semaphore{image_available, ctx.timeline_semaphore}

	wait_stage_masks := [2]vk.PipelineStageFlags{{.COLOR_ATTACHMENT_OUTPUT}, {.COMPUTE_SHADER}}

	//
	// Binary semaphores must use timeline value zero.
	//
	wait_values := [2]u64{0, ctx.simulation.completion_value}

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
		waitSemaphoreValueCount   = 2,
		pWaitSemaphoreValues      = raw_data(wait_values[:]),
		signalSemaphoreValueCount = 2,
		pSignalSemaphoreValues    = raw_data(signal_values[:]),
	}

	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		pNext                = &timeline_submit,
		waitSemaphoreCount   = 2,
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
	ctx.simulation.completion_value = submission_value
	ctx.simulation.current = curr_index
	ctx.simulation.generation += 1

	// The same dt written into this frame's UBO above, so the mesh spins at
	// a fixed rate in real time regardless of the render/present rate.
	MESH_SPIN_RADIANS_PER_SECOND :: 0.6
	ctx.mesh.rotation = math.mod(ctx.mesh.rotation + MESH_SPIN_RADIANS_PER_SECOND * dt, 2 * math.PI)

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
		return .Swapchain_Out_Of_Date
	}

	if present_result == .SUBOPTIMAL_KHR {
		ctx.framebuffer_resized = true
	} else if present_result != .SUCCESS {
		fmt.panicf("failed to present swapchain image: %v", present_result)
	}

	return .Submitted
}

//
// Debug-only CPU readback of the simulation's current grid. Waits for the
// simulation timeline value so the mapped buffer contents are safe to read,
// then copies them out. Not part of the normal rendering path: calling this
// every frame reintroduces the host stall the GPU-only flow was written to
// avoid.
//
simulation_debug_readback :: proc(ctx: ^Context, allocator := context.allocator) -> []u32 {
	wait_timeline(ctx, ctx.simulation.completion_value)

	buffer, found := resource_try_get(&ctx.buffer_pool, ctx.simulation.buffers[ctx.simulation.current])
	if !found {
		fmt.panicf("failed to get current simulation buffer for debug readback")
	}

	raw := ([^]u32)(buffer.mapped)

	cell_count := int(ctx.simulation.width) * int(ctx.simulation.height)
	result := make([]u32, cell_count, allocator)
	copy(result, raw[:cell_count])

	return result
}
