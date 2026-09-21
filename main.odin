package main

import "base:runtime"
import "core:fmt"
import "core:nbio"
import "core:os"
import "vendor:sdl2"
import vk "vendor:vulkan"

CELL_COUNT :: 64
BUFFER_SIZE :: CELL_COUNT * size_of(u32)

Buffer :: struct {
	handle:         vk.Buffer,
	memory:         vk.DeviceMemory,
	device_address: vk.DeviceAddress,
	mapped:         rawptr,
}

// Pushed to the shader: pointers to the generation it reads from and the
// generation it writes to. Mirrors the GLSL PushConstants block exactly.
PushConstants :: struct {
	prev: vk.DeviceAddress,
	curr: vk.DeviceAddress,
}

Swapchain :: struct {
	handle:      vk.SwapchainKHR,
	images:      []vk.Image,
	image_views: []vk.ImageView,
	format:      vk.Format,
	extent:      vk.Extent2D,
}

Context :: struct {
	window:          ^sdl2.Window,
	instance:        vk.Instance,
	physical_device: vk.PhysicalDevice,
	device:          vk.Device,
	compute_queue:   vk.Queue,
	compute_family:  u32,
	surface:         vk.SurfaceKHR,
	swapchain:       Swapchain,
	command_pool:    vk.CommandPool,
	command_buffers: [3]vk.CommandBuffer,

	// vkAcquireNextImageKHR and vkQueuePresentKHR still require binary, not
	// timeline, semaphores. image_available is per-frame-in-flight (indexed
	// by slot); render_finished must be per-swapchain-image (indexed by the
	// acquired image_index) - reusing the same render_finished semaphore
	// before the presentation engine is done with its prior signal is a
	// validation error, and frame-in-flight count doesn't necessarily match
	// swapchain image count.
	image_available_semaphores: [3]vk.Semaphore,
	render_finished_semaphores: []vk.Semaphore,

	// One shared timeline semaphore tracks GPU progress across every
	// submission. buffer_ready_value[slot] is the timeline value that must
	// be reached before that slot's buffer is safe to read or overwrite -
	// it replaces the old per-slot vk.Fence array.
	timeline_semaphore: vk.Semaphore,
	timeline_value:     u64,
	buffer_ready_value: [3]u64,

	// Monotonically increasing id handed to vkQueuePresentKHR via
	// VkPresentIdKHR, then passed back to vkWaitForPresentKHR to block
	// until that specific present has actually completed.
	present_id: u64,

	compute_shader:  vk.ShaderEXT,
	pipeline_layout: vk.PipelineLayout,
	buffers:         [3]Buffer,
	debug_messenger: vk.DebugUtilsMessengerEXT,
	output_handle:   nbio.Handle,
	output_offset:   int,
}

debug_callback :: proc "system" (
	message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_types: vk.DebugUtilsMessageTypeFlagsEXT,
	callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	context = runtime.default_context()
	fmt.eprintln(callback_data.pMessage)
	return false
}

OUTPUT_PATH :: "rows.txt"

main :: proc() {
	ctx: Context
	init_window(&ctx)
	init_vulkan(&ctx)
	defer cleanup(&ctx)

	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintfln("could not start event loop: %v", err)
		return
	}
	defer nbio.release_thread_event_loop()

	handle, ferr := nbio.open_sync(OUTPUT_PATH, mode = {.Write, .Create, .Trunc})
	if ferr != nil {
		fmt.eprintfln("could not open %s: %v", OUTPUT_PATH, ferr)
		return
	}
	ctx.output_handle = handle
	defer nbio.close(handle)

	running := true
	frame := 0

	for running {
		event: sdl2.Event
		for sdl2.PollEvent(&event) {
			if event.type == .QUIT do running = false
			if event.type == .KEYDOWN && event.key.keysym.sym == .ESCAPE do running = false
		}

		// vkWaitForPresentKHR inside run_compute now paces frames against
		// the presentation engine instead of a fixed sdl2.Delay.
		row := run_compute(&ctx, frame % 3)
		print_row_async(&ctx, row)

		nbio.tick(timeout = 0)

		frame += 1
	}
}

init_window :: proc(ctx: ^Context) {
	sdl2.Init(sdl2.INIT_VIDEO)
	ctx.window = sdl2.CreateWindow(
		"odin vulkan compute",
		sdl2.WINDOWPOS_CENTERED,
		sdl2.WINDOWPOS_CENTERED,
		800,
		600,
		sdl2.WINDOW_VULKAN | sdl2.WINDOW_SHOWN,
	)
}

init_vulkan :: proc(ctx: ^Context) {
	vk.load_proc_addresses_global(rawptr(sdl2.Vulkan_GetVkGetInstanceProcAddr()))

	app_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "odin_vk_compute",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName        = "none",
		engineVersion      = vk.MAKE_VERSION(1, 0, 0),
		apiVersion         = vk.API_VERSION_1_3,
	}

	layer_name := cstring("VK_LAYER_KHRONOS_validation")

	// A real windowed surface is required here: VK_EXT_headless_surface
	// reports no present support on this system's NVIDIA driver (its
	// headless surface exists for API compliance only, not actual
	// presentation), so vkWaitForPresentKHR needs SDL2's native surface.
	ext_count: u32
	sdl2.Vulkan_GetInstanceExtensions(ctx.window, &ext_count, nil)
	sdl_extensions := make([]cstring, ext_count)
	sdl2.Vulkan_GetInstanceExtensions(ctx.window, &ext_count, raw_data(sdl_extensions))

	all_extensions := make([]cstring, ext_count + 1)
	copy(all_extensions, sdl_extensions)
	all_extensions[ext_count] = "VK_EXT_debug_utils"

	debug_info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.VERBOSE, .WARNING, .ERROR},
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = debug_callback,
	}

	instance_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pNext                   = &debug_info,
		pApplicationInfo        = &app_info,
		enabledExtensionCount   = u32(len(all_extensions)),
		ppEnabledExtensionNames = raw_data(all_extensions),
		enabledLayerCount       = 1,
		ppEnabledLayerNames     = &layer_name,
	}

	if res := vk.CreateInstance(&instance_info, nil, &ctx.instance); res != .SUCCESS {
		fmt.panicf("failed to create instance: %v", res)
	}
	vk.load_proc_addresses_instance(ctx.instance)

	vk.CreateDebugUtilsMessengerEXT(ctx.instance, &debug_info, nil, &ctx.debug_messenger)

	create_surface(ctx)
	pick_physical_device(ctx)
	create_logical_device(ctx)
	vk.load_proc_addresses_device(ctx.device)

	create_swapchain(ctx)

	create_command_pool(ctx)
	for i in 0 ..< 3 {
		create_buffer(ctx, i)
	}
	seed_initial_generation(ctx)
	create_compute_shader(ctx)
	create_sync_objects(ctx)
}

create_surface :: proc(ctx: ^Context) {
	if !sdl2.Vulkan_CreateSurface(ctx.window, ctx.instance, &ctx.surface) {
		fmt.panicf("failed to create SDL2 vulkan surface")
	}
}

REQUIRED_DEVICE_EXTENSIONS :: []cstring {
	"VK_KHR_swapchain",
	"VK_EXT_shader_object",
	"VK_KHR_present_id",
	"VK_KHR_present_wait",
}

device_supports_extensions :: proc(device: vk.PhysicalDevice, required: []cstring) -> bool {
	count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil)
	available := make([]vk.ExtensionProperties, count)
	defer delete(available)
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(available))

	for name in required {
		found := false
		for &ext in available {
			if cstring(raw_data(ext.extensionName[:])) == name {
				found = true
				break
			}
		}
		if !found do return false
	}
	return true
}

pick_physical_device :: proc(ctx: ^Context) {
	count: u32
	vk.EnumeratePhysicalDevices(ctx.instance, &count, nil)
	devices := make([]vk.PhysicalDevice, count)
	vk.EnumeratePhysicalDevices(ctx.instance, &count, raw_data(devices))

	for device in devices {
		if !device_supports_extensions(device, REQUIRED_DEVICE_EXTENSIONS) do continue

		family_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(device, &family_count, nil)
		families := make([]vk.QueueFamilyProperties, family_count)
		vk.GetPhysicalDeviceQueueFamilyProperties(device, &family_count, raw_data(families))

		for family, i in families {
			if .COMPUTE not_in family.queueFlags do continue

			present_supported: b32
			vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), ctx.surface, &present_supported)
			if !present_supported do continue

			ctx.physical_device = device
			ctx.compute_family = u32(i)
			return
		}
	}
	fmt.panicf("no compute+present capable gpu found with required extension support")
}

create_logical_device :: proc(ctx: ^Context) {
	priority: f32 = 1.0
	queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = ctx.compute_family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}

	features_12 := vk.PhysicalDeviceVulkan12Features {
		sType               = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		bufferDeviceAddress = true,
		timelineSemaphore   = true,
	}

	// VK_EXT_shader_object requires dynamicRendering to be enabled, even
	// though this app never records a render pass.
	features_13 := vk.PhysicalDeviceVulkan13Features {
		pNext            = &features_12,
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		synchronization2 = true,
		dynamicRendering = true,
	}

	features_shader_object := vk.PhysicalDeviceShaderObjectFeaturesEXT {
		sType        = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
		pNext        = &features_13,
		shaderObject = true,
	}

	// VK_KHR_present_wait requires VK_KHR_present_id to also be enabled.
	features_present_id := vk.PhysicalDevicePresentIdFeaturesKHR {
		sType     = .PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR,
		pNext     = &features_shader_object,
		presentId = true,
	}

	features_present_wait := vk.PhysicalDevicePresentWaitFeaturesKHR {
		sType       = .PHYSICAL_DEVICE_PRESENT_WAIT_FEATURES_KHR,
		pNext       = &features_present_id,
		presentWait = true,
	}

	device_extensions := REQUIRED_DEVICE_EXTENSIONS
	device_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features_present_wait,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions),
	}

	if res := vk.CreateDevice(ctx.physical_device, &device_info, nil, &ctx.device);
	   res != .SUCCESS {
		fmt.panicf("failed to create device: %v", res)
	}
	vk.GetDeviceQueue(ctx.device, ctx.compute_family, 0, &ctx.compute_queue)
}

// Some presentation engines (e.g. Wayland) report no fixed extent
// (currentExtent comes back as 0xFFFFFFFF), so fall back to the window size
// picked in init_window.
FALLBACK_SWAPCHAIN_EXTENT :: vk.Extent2D{800, 600}

create_swapchain :: proc(ctx: ^Context) {
	capabilities: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface, &capabilities)

	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(ctx.physical_device, ctx.surface, &format_count, nil)
	formats := make([]vk.SurfaceFormatKHR, format_count)
	defer delete(formats)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		ctx.physical_device,
		ctx.surface,
		&format_count,
		raw_data(formats),
	)

	chosen_format := formats[0]
	for format in formats {
		if format.format == .B8G8R8A8_UNORM && format.colorSpace == .SRGB_NONLINEAR {
			chosen_format = format
			break
		}
	}

	extent := capabilities.currentExtent
	if extent.width == max(u32) {
		extent = FALLBACK_SWAPCHAIN_EXTENT
		extent.width = clamp(
			extent.width,
			capabilities.minImageExtent.width,
			capabilities.maxImageExtent.width,
		)
		extent.height = clamp(
			extent.height,
			capabilities.minImageExtent.height,
			capabilities.maxImageExtent.height,
		)
	}

	image_count := capabilities.minImageCount + 1
	if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.maxImageCount
	}

	swapchain_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = ctx.surface,
		minImageCount    = image_count,
		imageFormat      = chosen_format.format,
		imageColorSpace  = chosen_format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT, .TRANSFER_DST},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = .FIFO,
		clipped          = true,
	}
	if res := vk.CreateSwapchainKHR(ctx.device, &swapchain_info, nil, &ctx.swapchain.handle);
	   res != .SUCCESS {
		fmt.panicf("failed to create swapchain: %v", res)
	}
	ctx.swapchain.format = chosen_format.format
	ctx.swapchain.extent = extent

	actual_count: u32
	vk.GetSwapchainImagesKHR(ctx.device, ctx.swapchain.handle, &actual_count, nil)
	ctx.swapchain.images = make([]vk.Image, actual_count)
	vk.GetSwapchainImagesKHR(
		ctx.device,
		ctx.swapchain.handle,
		&actual_count,
		raw_data(ctx.swapchain.images),
	)

	ctx.swapchain.image_views = make([]vk.ImageView, actual_count)
	for image, i in ctx.swapchain.images {
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = ctx.swapchain.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		if res := vk.CreateImageView(ctx.device, &view_info, nil, &ctx.swapchain.image_views[i]);
		   res != .SUCCESS {
			fmt.panicf("failed to create swapchain image view %d: %v", i, res)
		}
	}
}

create_command_pool :: proc(ctx: ^Context) {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = ctx.compute_family,
	}
	vk.CreateCommandPool(ctx.device, &pool_info, nil, &ctx.command_pool)

	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = ctx.command_pool,
		level              = .PRIMARY,
		commandBufferCount = 3,
	}
	vk.AllocateCommandBuffers(ctx.device, &alloc_info, raw_data(ctx.command_buffers[:]))
}

create_buffer :: proc(ctx: ^Context, index: int) {
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = BUFFER_SIZE,
		usage       = {.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
		sharingMode = .EXCLUSIVE,
	}
	vk.CreateBuffer(ctx.device, &buffer_info, nil, &ctx.buffers[index].handle)

	mem_reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(ctx.device, ctx.buffers[index].handle, &mem_reqs)

	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(ctx.physical_device, &mem_props)

	mem_type_index: u32 = max(u32)
	wanted := vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT}
	for i in 0 ..< mem_props.memoryTypeCount {
		if (mem_reqs.memoryTypeBits & (1 << i)) != 0 &&
		   (mem_props.memoryTypes[i].propertyFlags & wanted) == wanted {
			mem_type_index = i
			break
		}
	}
	if mem_type_index == max(u32) do fmt.panicf("no suitable memory type found")

	alloc_flags := vk.MemoryAllocateFlagsInfo {
		sType = .MEMORY_ALLOCATE_FLAGS_INFO,
		flags = {.DEVICE_ADDRESS},
	}
	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		pNext           = &alloc_flags,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = mem_type_index,
	}
	vk.AllocateMemory(ctx.device, &alloc_info, nil, &ctx.buffers[index].memory)
	vk.BindBufferMemory(ctx.device, ctx.buffers[index].handle, ctx.buffers[index].memory, 0)
	vk.MapMemory(
		ctx.device,
		ctx.buffers[index].memory,
		0,
		BUFFER_SIZE,
		{},
		&ctx.buffers[index].mapped,
	)
	address := vk.GetBufferDeviceAddress(
		ctx.device,
		&vk.BufferDeviceAddressInfo {
			sType = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = ctx.buffers[index].handle,
		},
	)
	ctx.buffers[index].device_address = address

	cells := (^[CELL_COUNT]u32)(ctx.buffers[index].mapped)
	for i in 0 ..< CELL_COUNT do cells[i] = 0
}

// Generation 0's dispatch reads slot (0 + 2) % 3 == 2 as its "previous"
// generation, so that's where the single seed cell goes.
seed_initial_generation :: proc(ctx: ^Context) {
	cells := (^[CELL_COUNT]u32)(ctx.buffers[2].mapped)
	cells[CELL_COUNT / 2] = 1
}

// VK_EXT_shader_object shaders are built directly from SPIR-V - no
// VkShaderModule or VkPipeline involved. A VkPipelineLayout is still needed
// so vkCmdPushConstants has something to check push constant compatibility
// against; its ranges must match what's declared here.
create_compute_shader :: proc(ctx: ^Context) {
	code, err := os.read_entire_file_from_path("comp.spv", context.allocator)
	if err != nil do fmt.panicf("failed to read comp.spv - compile comp.comp with glslc first (%v)", err)
	defer delete(code)

	push_constant_range := vk.PushConstantRange {
		stageFlags = {.COMPUTE},
		offset     = 0,
		size       = size_of(PushConstants),
	}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_constant_range,
	}
	vk.CreatePipelineLayout(ctx.device, &layout_info, nil, &ctx.pipeline_layout)

	shader_info := vk.ShaderCreateInfoEXT {
		sType                  = .SHADER_CREATE_INFO_EXT,
		stage                  = {.COMPUTE},
		codeType               = .SPIRV,
		codeSize               = len(code),
		pCode                  = raw_data(code),
		pName                  = "main",
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_constant_range,
	}
	if res := vk.CreateShadersEXT(ctx.device, 1, &shader_info, nil, &ctx.compute_shader);
	   res != .SUCCESS {
		fmt.panicf("failed to create compute shader object: %v", res)
	}
}

create_sync_objects :: proc(ctx: ^Context) {
	timeline_type_info := vk.SemaphoreTypeCreateInfo {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = .TIMELINE,
		initialValue  = 0,
	}
	timeline_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &timeline_type_info,
	}
	vk.CreateSemaphore(ctx.device, &timeline_info, nil, &ctx.timeline_semaphore)

	binary_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	for i in 0 ..< 3 {
		vk.CreateSemaphore(ctx.device, &binary_info, nil, &ctx.image_available_semaphores[i])
	}

	ctx.render_finished_semaphores = make([]vk.Semaphore, len(ctx.swapchain.images))
	for i in 0 ..< len(ctx.swapchain.images) {
		vk.CreateSemaphore(ctx.device, &binary_info, nil, &ctx.render_finished_semaphores[i])
	}
}

// Blocks the host until the shared timeline semaphore reaches value. A
// value of 0 means "nothing submitted for this slot yet" - nothing to wait
// on.
wait_timeline :: proc(ctx: ^Context, value: u64) {
	if value == 0 do return
	value := value
	semaphore := ctx.timeline_semaphore
	wait_info := vk.SemaphoreWaitInfo {
		sType          = .SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores    = &semaphore,
		pValues        = &value,
	}
	vk.WaitSemaphores(ctx.device, &wait_info, max(u64))
}

// slot is this call's write target (frame % 3). prev_slot is always
// (slot + 2) % 3, since generations advance in lockstep with slots: whatever
// slot was written one call ago is always exactly two steps ahead in the
// 3-wide ring from the current slot.
run_compute :: proc(ctx: ^Context, slot: int) -> [CELL_COUNT]u32 {
	prev_slot := (slot + 2) % 3

	// This slot free to reuse as a write target.
	wait_timeline(ctx, ctx.buffer_ready_value[slot])
	row := (^[CELL_COUNT]u32)(ctx.buffers[slot].mapped)^

	// The generation we're about to read from must have finished computing.
	// A single shared timeline only ever grows, and submissions to the same
	// queue complete in submission order, so waiting on prev_slot's value
	// here transitively covers slot's own older value too - this is really
	// the one wait that matters.
	wait_timeline(ctx, ctx.buffer_ready_value[prev_slot])

	image_available := ctx.image_available_semaphores[slot]

	image_index: u32
	if res := vk.AcquireNextImageKHR(
		ctx.device,
		ctx.swapchain.handle,
		max(u64),
		image_available,
		0,
		&image_index,
	); res != .SUCCESS && res != .SUBOPTIMAL_KHR {
		fmt.panicf("failed to acquire swapchain image: %v", res)
	}
	image := ctx.swapchain.images[image_index]
	// Must be indexed by image_index, not slot: see the field comment on
	// Context.render_finished_semaphores.
	render_finished := ctx.render_finished_semaphores[image_index]

	cmd := ctx.command_buffers[slot]
	vk.ResetCommandBuffer(cmd, {})

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(cmd, &begin_info)

	compute_stage := vk.ShaderStageFlags{.COMPUTE}
	vk.CmdBindShadersEXT(cmd, 1, &compute_stage, &ctx.compute_shader)

	push := PushConstants {
		prev = ctx.buffers[prev_slot].device_address,
		curr = ctx.buffers[slot].device_address,
	}
	vk.CmdPushConstants(cmd, ctx.pipeline_layout, {.COMPUTE}, 0, size_of(PushConstants), &push)
	vk.CmdDispatch(cmd, 1, 1, 1)

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

	// Undefined -> transfer dst, so the acquired swapchain image can be
	// cleared.
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

	// Visualize the automaton's middle cell as the clear color, so the
	// swapchain actually reflects the simulation instead of being unused.
	clear_color := vk.ClearColorValue {
		float32 = row[CELL_COUNT / 2] != 0 ? {1, 1, 1, 1} : {0, 0, 0, 1},
	}
	vk.CmdClearColorImage(cmd, image, .TRANSFER_DST_OPTIMAL, &clear_color, 1, &clear_range)

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

	vk.EndCommandBuffer(cmd)

	ctx.timeline_value += 1
	new_value := ctx.timeline_value

	wait_semaphores := [1]vk.Semaphore{image_available}
	wait_stage_masks := [1]vk.PipelineStageFlags{{.TRANSFER}}
	wait_values := [1]u64{0}

	signal_semaphores := [2]vk.Semaphore{render_finished, ctx.timeline_semaphore}
	signal_values := [2]u64{0, new_value}

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
	vk.QueueSubmit(ctx.compute_queue, 1, &submit_info, 0)
	ctx.buffer_ready_value[slot] = new_value

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
	if res := vk.QueuePresentKHR(ctx.compute_queue, &present_info);
	   res != .SUCCESS && res != .SUBOPTIMAL_KHR {
		fmt.panicf("failed to present swapchain image: %v", res)
	}

	// Frame pacing: block until the presentation engine has actually
	// finished with this present (vkWaitForPresentKHR), rather than
	// sleeping a fixed amount.
	if res := vk.WaitForPresentKHR(ctx.device, ctx.swapchain.handle, present_id, max(u64));
	   res != .SUCCESS && res != .TIMEOUT {
		fmt.panicf("vkWaitForPresentKHR failed: %v", res)
	}

	return row
}

// Formats the row into a heap-allocated line and submits it as an async
// write; the write is positional (nbio does not track a file offset for
// you), so we advance ctx.output_offset ourselves before the write even
// completes. The line is freed in the completion callback via a boxed
// slice stashed in the operation's user_data, since Callback is a plain
// proc pointer with no closure capture.
print_row_async :: proc(ctx: ^Context, row: [CELL_COUNT]u32) {
	line := make([]u8, CELL_COUNT + 1)
	for i in 0 ..< CELL_COUNT {
		line[i] = '#' if row[i] != 0 else '.'
	}
	line[CELL_COUNT] = '\n'

	offset := ctx.output_offset
	ctx.output_offset += len(line)

	// VERIFY against `odin doc core:nbio` - param name/order not confirmed
	// (docs truncated before this proc). Should mirror the Write struct:
	// handle, buf, offset, then callback + optional timeout/loop.
	op := nbio.write(ctx.output_handle, offset, line, on_row_written)
	op.user_data[0] = new_clone(line)
}

on_row_written :: proc(op: ^nbio.Operation) {
	if op.write.err != nil {
		fmt.eprintln("row write failed:", op.write.err)
	}
	line_ptr := (^[]u8)(op.user_data[0])
	delete(line_ptr^)
	free(line_ptr)
}

destroy_buffer :: proc(device: vk.Device, buffer: Buffer, allocator: ^vk.AllocationCallbacks) {
	vk.UnmapMemory(device, buffer.memory)
	vk.FreeMemory(device, buffer.memory, allocator)
	vk.DestroyBuffer(device, buffer.handle, allocator)
}

cleanup :: proc(ctx: ^Context) {
	vk.DeviceWaitIdle(ctx.device)
	vk.DestroyDebugUtilsMessengerEXT(ctx.instance, ctx.debug_messenger, nil)

	for frame in 0 ..< 3 {
		vk.DestroySemaphore(ctx.device, ctx.image_available_semaphores[frame], nil)
		destroy_buffer(ctx.device, ctx.buffers[frame], nil)
	}
	for semaphore in ctx.render_finished_semaphores {
		vk.DestroySemaphore(ctx.device, semaphore, nil)
	}
	delete(ctx.render_finished_semaphores)
	vk.DestroySemaphore(ctx.device, ctx.timeline_semaphore, nil)
	vk.DestroyShaderEXT(ctx.device, ctx.compute_shader, nil)
	vk.DestroyPipelineLayout(ctx.device, ctx.pipeline_layout, nil)
	vk.DestroyCommandPool(ctx.device, ctx.command_pool, nil)

	for view in ctx.swapchain.image_views {
		vk.DestroyImageView(ctx.device, view, nil)
	}
	delete(ctx.swapchain.image_views)
	delete(ctx.swapchain.images)
	vk.DestroySwapchainKHR(ctx.device, ctx.swapchain.handle, nil)

	vk.DestroyDevice(ctx.device, nil)
	vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
	vk.DestroyInstance(ctx.instance, nil)
	sdl2.DestroyWindow(ctx.window)
	sdl2.Quit()
}
