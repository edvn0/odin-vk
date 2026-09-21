package main

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:text/table"

import "config"
import "render"
import ds "data_structures"
import "vendor:sdl2"
import vk "vendor:vulkan"

debug_callback :: proc "system" (
	message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_types: vk.DebugUtilsMessageTypeFlagsEXT,
	callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	context = runtime.default_context()

	if .ERROR in message_severity {

		fmt.eprintln("========================================")
		fmt.eprintln("VULKAN VALIDATION:")
		fmt.eprintln(callback_data.pMessage)
		fmt.eprintln("")
		fmt.eprintln("Call trace:")

		bt := trace.capture()

		locations, err := trace.resolve(bt)
		if err == nil {
			trace.print(locations)
			trace.locations_destroy(locations)
		} else {
			fmt.eprintfln("failed to resolve call trace: %v", err)
		}

		fmt.eprintln("========================================")
	}

	return false
}

init_window :: proc(ctx: ^render.Context) {
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

init_vulkan :: proc(ctx: ^render.Context) {
	vk.load_proc_addresses_global(rawptr(sdl2.Vulkan_GetVkGetInstanceProcAddr()))

	app_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "odin_vk_compute",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName        = "none",
		engineVersion      = vk.MAKE_VERSION(1, 0, 0),
		apiVersion         = vk.API_VERSION_1_3,
	}

	layer_name: cstring
	if ODIN_DEBUG {
		layer_name = cstring("VK_LAYER_KHRONOS_validation")
	} else {
		layer_name = nil
	}
	layer_count := layer_name != nil ? 1 : 0

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
		enabledLayerCount       = u32(layer_count),
		ppEnabledLayerNames     = layer_count > 0 ? &layer_name : nil,
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

	vk.GetPhysicalDeviceProperties(ctx.physical_device, &ctx.physical_device_properties)
	push_constant_supported_size := min(
		128,
		ctx.physical_device_properties.limits.maxPushConstantsSize,
	)

	fmt.printfln(
		"Push constants size supported: %d, use %d",
		ctx.physical_device_properties.limits.maxPushConstantsSize,
		push_constant_supported_size,
	)

	ctx.global_push_constant_range = vk.PushConstantRange {
		stageFlags = vk.ShaderStageFlags_ALL,
		offset     = 0,
		size       = push_constant_supported_size,
	}

	create_descriptor_set_layout(ctx)
	render.create_bindless_descriptor_set(ctx)
	create_pipeline_layout(ctx)

	create_swapchain(ctx)
	create_command_pool(ctx)
	render.init_resource_pools(ctx)
	for i in 0 ..< render.MAX_FRAMES_IN_FLIGHT {
		handle := create_buffer(ctx, config.BUFFER_SIZE, {.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS})
		ctx.frames[i].buffer = handle
	}
	seed_initial_generation(ctx)
	create_sync_objects(ctx)

	ctx.shaders = make(map[render.Shader_Key]render.Shader_Handle)

	files := find_all_spirv_files_in_directory("./shaders")
	defer ds.destroy(&files)

	log_buffer := strings.builder_make()
	defer strings.builder_destroy(&log_buffer)

	shader_table: table.Table
	table.init(&shader_table)
	defer table.destroy(&shader_table)

	table.padding(&shader_table, 1, 1)
	table.header(&shader_table, "Name", "Stage Flags")

	for file_name in ds.slice(&files) {
		loaded := load_spirv_file(ctx, file_name)

		key := render.Shader_Key {
			name  = loaded.name,
			stage = loaded.stage,
		}

		if key in ctx.shaders {
			fmt.panicf("duplicate shader '%s' stage %v", loaded.name, loaded.stage)
		}

		ctx.shaders[key] = loaded.handle

		table.row(&shader_table, loaded.name, table.format(&shader_table, "%v", vk.ShaderStageFlags(loaded.stage)))
	}

	writer := strings.to_writer(&log_buffer)
	table.write_plain_table(writer, &shader_table, table.ascii_width_proc)

	fmt.println(strings.to_string(log_buffer))
}

create_surface :: proc(ctx: ^render.Context) {
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

pick_physical_device :: proc(ctx: ^render.Context) {
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

create_logical_device :: proc(ctx: ^render.Context) {
	priority: f32 = 1.0
	queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = ctx.compute_family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}

	features_12 := vk.PhysicalDeviceVulkan12Features {
		sType                                        = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		bufferDeviceAddress                          = true,
		timelineSemaphore                            = true,
		runtimeDescriptorArray                       = true,
		shaderSampledImageArrayNonUniformIndexing    = true,
		shaderStorageImageArrayNonUniformIndexing    = true,
		descriptorBindingPartiallyBound              = true,
		descriptorBindingSampledImageUpdateAfterBind = true,
		descriptorBindingStorageImageUpdateAfterBind = true,
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

create_swapchain :: proc(ctx: ^render.Context) {
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

	find_supported_present_mode := proc(ctx: ^render.Context) -> vk.PresentModeKHR {
		present_mode_count: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(ctx.physical_device, ctx.surface, &present_mode_count, nil)
		present_modes := make([]vk.PresentModeKHR, present_mode_count)
		defer delete(present_modes)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(ctx.physical_device, ctx.surface, &present_mode_count, raw_data(present_modes))

		fmt.printfln("Available present modes: %v", present_modes)
		for mode in present_modes {
			if mode == .MAILBOX {
				return .MAILBOX
			}
		}
		fmt.printfln("Selected FIFO present mode as fallback because MAILBOX was not available")
		return .FIFO
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
		presentMode      = find_supported_present_mode(ctx),
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

create_pipeline_layout :: proc(ctx: ^render.Context) {
	ctx.pipeline_layout = vk.PipelineLayout{}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pSetLayouts            = &ctx.bindless_descriptor_set_layout,
		setLayoutCount         = 1,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &ctx.global_push_constant_range,
	}
	if res := vk.CreatePipelineLayout(ctx.device, &layout_info, nil, &ctx.pipeline_layout);
	   res != .SUCCESS {
		fmt.panicf("failed to create pipeline layout: %v", res)
	}
}

create_descriptor_set_layout :: proc(ctx: ^render.Context) {
	/*
		Set 0, Binding 0: Bindless Sampler2D[]
		Set 0, Binding 1: Bindless Texture2D[]
		Set 0, Binding 2: Bindless RWTexture2D[]
		Set 0, Binding 3: Bindless Texture3D[]
		Set 0, Binding 4: Bindless RWTexture3D[]
		Set 0, Binding 5: Bindless Sampler3D[]
		Set 0, Binding 6: Bindless ComparisonSampler[]
		Set 0, Binding 7: Bindless DepthTexture2D[]
	*/

	ctx.bindless_descriptor_set_layout = vk.DescriptorSetLayout{}

	bindings := []vk.DescriptorSetLayoutBinding {
		{
			binding         = 0,
			descriptorType  = .SAMPLER,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags      = vk.ShaderStageFlags_ALL,
		},
		{
			binding         = 1,
			descriptorType  = .SAMPLED_IMAGE,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags      = vk.ShaderStageFlags_ALL,
		},
		{
			binding         = 2,
			descriptorType  = .STORAGE_IMAGE,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags      = vk.ShaderStageFlags_ALL,
		},
		{
			binding         = 3,
			descriptorType  = .SAMPLED_IMAGE,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags      = vk.ShaderStageFlags_ALL,
		},
		{
			binding         = 4,
			descriptorType  = .STORAGE_IMAGE,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags      = vk.ShaderStageFlags_ALL,
		},
		{
			binding         = 5,
			descriptorType  = .SAMPLER,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags      = vk.ShaderStageFlags_ALL,
		},
		{
			binding         = 6,
			descriptorType  = .SAMPLER,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags      = vk.ShaderStageFlags_ALL,
		},
		{
			binding         = 7,
			descriptorType  = .SAMPLED_IMAGE,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags      = vk.ShaderStageFlags_ALL,
		},
	}

	bindless_binding_flags := vk.DescriptorBindingFlags {
		(.PARTIALLY_BOUND | .UPDATE_AFTER_BIND),
	}

	binding_flags := []vk.DescriptorBindingFlags {
		bindless_binding_flags,
		bindless_binding_flags,
		bindless_binding_flags,
		bindless_binding_flags,
		bindless_binding_flags,
		bindless_binding_flags,
		bindless_binding_flags,
		bindless_binding_flags,
	}

	binding_flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = u32(len(binding_flags)),
		pBindingFlags = raw_data(binding_flags),
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &binding_flags_info,
		flags        = {.UPDATE_AFTER_BIND_POOL},
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings),
	}

	if res := vk.CreateDescriptorSetLayout(
		ctx.device,
		&layout_info,
		nil,
		&ctx.bindless_descriptor_set_layout,
	); res != .SUCCESS {
		fmt.panicf("failed to create bindless descriptor set layout: %v", res)
	}
}
create_command_pool :: proc(ctx: ^render.Context) {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = ctx.compute_family,
	}

	if res := vk.CreateCommandPool(ctx.device, &pool_info, nil, &ctx.command_pool);
	   res != .SUCCESS {
		fmt.panicf("failed to create command pool: %v", res)
	}

	command_buffers: [render.MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer

	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = ctx.command_pool,
		level              = .PRIMARY,
		commandBufferCount = render.MAX_FRAMES_IN_FLIGHT,
	}

	if res := vk.AllocateCommandBuffers(ctx.device, &alloc_info, raw_data(command_buffers[:]));
	   res != .SUCCESS {
		fmt.panicf("failed to allocate command buffers: %v", res)
	}

	for i in 0 ..< render.MAX_FRAMES_IN_FLIGHT {
		ctx.frames[i].command_buffer = command_buffers[i]
	}
}

create_buffer :: proc(ctx: ^render.Context, size: vk.DeviceSize, usage: vk.BufferUsageFlags = {.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS}) -> render.Buffer_Handle {
	buffer: render.Buffer

	usage_with_device_address := usage | {.SHADER_DEVICE_ADDRESS}
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage_with_device_address,
		sharingMode = .EXCLUSIVE,
	}

	if res := vk.CreateBuffer(ctx.device, &buffer_info, nil, &buffer.object); res != .SUCCESS {
		fmt.panicf("failed to create buffer: %v", res)
	}

	mem_reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(ctx.device, buffer.object, &mem_reqs)

	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(ctx.physical_device, &mem_props)

	mem_type_index := max(u32)
	wanted := vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT}

	for i in 0 ..< mem_props.memoryTypeCount {
		if (mem_reqs.memoryTypeBits & (1 << i)) != 0 &&
		   (mem_props.memoryTypes[i].propertyFlags & wanted) == wanted {
			mem_type_index = i
			break
		}
	}

	if mem_type_index == max(u32) {
		vk.DestroyBuffer(ctx.device, buffer.object, nil)

		fmt.panicf("no suitable memory type found")
	}

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

	if res := vk.AllocateMemory(ctx.device, &alloc_info, nil, &buffer.memory); res != .SUCCESS {
		vk.DestroyBuffer(ctx.device, buffer.object, nil)

		fmt.panicf("failed to allocate buffer memory: %v", res)
	}

	if res := vk.BindBufferMemory(ctx.device, buffer.object, buffer.memory, 0); res != .SUCCESS {
		vk.FreeMemory(ctx.device, buffer.memory, nil)

		vk.DestroyBuffer(ctx.device, buffer.object, nil)

		fmt.panicf("failed to bind buffer memory: %v", res)
	}

	if res := vk.MapMemory(ctx.device, buffer.memory, 0, size, {}, &buffer.mapped);
	   res != .SUCCESS {
		vk.FreeMemory(ctx.device, buffer.memory, nil)

		vk.DestroyBuffer(ctx.device, buffer.object, nil)

		fmt.panicf("failed to map buffer memory: %v", res)
	}

	address_info := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = buffer.object,
	}

	buffer.device_address = vk.GetBufferDeviceAddress(ctx.device, &address_info)

	cells := (^[config.CELL_COUNT]u32)(buffer.mapped)
	for i in 0 ..< config.CELL_COUNT {
		cells[i] = 0
	}

	return render.resource_add(&ctx.buffer_pool, buffer)
}

seed_initial_generation :: proc(ctx: ^render.Context) {
	frame := ctx.frames[2]
	buffer, found := render.resource_try_get(&ctx.buffer_pool, frame.buffer)
	if !found {
		fmt.panicf("failed to get buffer from buffer pool")
	}

	cells := (^[config.CELL_COUNT]u32)(buffer.mapped)
	cells[config.CELL_COUNT / 2] = 1
}

find_all_spirv_files_in_directory :: proc(directory: string) -> ds.Dynamic_Array(string) {
	ctx := runtime.default_context()
	allocator := ctx.allocator

	directory_file, err := os.open(directory, {.Read})
	if err != nil {
		fmt.panicf("failed to open directory: %v", err)
	}
	defer os.close(directory_file)

	files, dir_err := os.read_directory(directory_file, 0, allocator)
	if dir_err != nil {
		fmt.panicf("failed to read directory: %v", dir_err)
	}

	output_files := ds.Dynamic_Array(string) {
		allocator = allocator,
	}

	for file in files {
		if strings.has_suffix(file.name, ".spv") && file.type != os.File_Type.Directory {
			name := strings.clone(file.name, allocator)
			string_slice_to_concat := []string{directory, "/", name}
			name_with_path := strings.concatenate(string_slice_to_concat, allocator)
			ds.append(&output_files, name_with_path)
		}
	}

	return output_files
}

create_sync_objects :: proc(ctx: ^render.Context) {
	timeline_type_info := vk.SemaphoreTypeCreateInfo {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = .TIMELINE,
		initialValue  = 0,
	}

	timeline_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &timeline_type_info,
	}

	if res := vk.CreateSemaphore(ctx.device, &timeline_info, nil, &ctx.timeline_semaphore);
	   res != .SUCCESS {
		fmt.panicf("failed to create timeline semaphore: %v", res)
	}

	binary_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}

	for i in 0 ..< 3 {
		if res := vk.CreateSemaphore(
			ctx.device,
			&binary_info,
			nil,
			&ctx.frames[i].image_available,
		); res != .SUCCESS {
			fmt.panicf("failed to create image-available semaphore %d: %v", i, res)
		}
	}

	ctx.render_finished_semaphores = make([]vk.Semaphore, len(ctx.swapchain.images))

	for i in 0 ..< len(ctx.swapchain.images) {
		if res := vk.CreateSemaphore(
			ctx.device,
			&binary_info,
			nil,
			&ctx.render_finished_semaphores[i],
		); res != .SUCCESS {
			fmt.panicf("failed to create render-finished semaphore %d: %v", i, res)
		}
	}
}

destroy_buffer :: proc(ctx: ^render.Context, buffer: ^render.Buffer) {
	vk.UnmapMemory(ctx.device, buffer.memory)
	vk.FreeMemory(ctx.device, buffer.memory, nil)
	vk.DestroyBuffer(ctx.device, buffer.object, nil)
}

cleanup :: proc(ctx: ^render.Context) {
	vk.DeviceWaitIdle(ctx.device)
	vk.DestroyDebugUtilsMessengerEXT(ctx.instance, ctx.debug_messenger, nil)

	for frame in 0 ..< 3 {
		vk.DestroySemaphore(ctx.device, ctx.frames[frame].image_available, nil)
	}

	render.resource_destroy_all(ctx, &ctx.buffer_pool)
	render.resource_destroy_all(ctx, &ctx.shader_pool)
	render.resource_destroy_all(ctx, &ctx.image_pool)

	for semaphore in ctx.render_finished_semaphores {
		vk.DestroySemaphore(ctx.device, semaphore, nil)
	}
	delete(ctx.render_finished_semaphores)
	vk.DestroySemaphore(ctx.device, ctx.timeline_semaphore, nil)

	vk.DestroyPipelineLayout(ctx.device, ctx.pipeline_layout, nil)
	render.destroy_bindless_descriptor_set(ctx)
	vk.DestroyDescriptorSetLayout(ctx.device, ctx.bindless_descriptor_set_layout, nil)

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

	fmt.printfln("Cleanup complete.")
}
