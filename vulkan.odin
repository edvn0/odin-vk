package main

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:io"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:text/table"

import "config"
import ds "data_structures"
import "render"
import "vendor:sdl2"
import vk "vendor:vulkan"

print_backtrace :: proc() {
	capture := trace.capture(1)

	locations, err := trace.resolve(capture)
	if err != nil {
		fmt.eprintfln("failed to resolve call trace: %v", err)
		return
	}
	defer trace.locations_destroy(locations)

	trace.print(locations)
}

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

		print_backtrace()

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
		sdl2.WINDOW_VULKAN | sdl2.WINDOW_SHOWN | sdl2.WINDOW_RESIZABLE,
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
	defer delete(sdl_extensions)
	sdl2.Vulkan_GetInstanceExtensions(ctx.window, &ext_count, raw_data(sdl_extensions))

	all_extensions := make([]cstring, ext_count + 1)
	defer delete(all_extensions)
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
		256,
		ctx.physical_device_properties.limits.maxPushConstantsSize,
	)

	if ctx.physical_device_properties.limits.maxPushConstantsSize < 256 {
		fmt.printfln("Push constants size not supported: %d", ctx.physical_device_properties.limits.maxPushConstantsSize)
		fmt.panicf("Push constants size not supported: %d", ctx.physical_device_properties.limits.maxPushConstantsSize)
	}

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
	init_simulation(ctx)
	init_render_targets(ctx)
	init_mesh(ctx, "./assets/suzanne.obj")
	create_sync_objects(ctx)

	ctx.shaders = make(map[render.Shader_Key]render.Shader_Handle)

	files := find_all_spirv_files_in_directory("./shaders")
	defer ds.destroy(&files)

	// A mesh shader must declare NO_TASK_SHADER when it has no accompanying
	// task shader (see load_spirv_file); find out which mesh shader names
	// do have one by name (e.g. "suzanne.task.spv" pairs with
	// "suzanne.mesh.spv") before loading any of them.
	names_with_task_shader := make(map[string]bool, allocator = context.temp_allocator)
	for file_name in ds.slice(&files) {
		stem, extension := os.split_filename(os.base(file_name))
		if extension != "spv" do continue
		name, stage_name := os.split_filename(stem)
		if stage_name == "task" {
			names_with_task_shader[name] = true
		}
	}

	log_buffer := strings.builder_make()
	defer strings.builder_destroy(&log_buffer)

	shader_table: table.Table
	table.init(&shader_table)
	defer table.destroy(&shader_table)

	table.padding(&shader_table, 1, 1)
	table.header(&shader_table, "Name", "Stage Flags")

	for file_name in ds.slice(&files) {
		stem, _ := os.split_filename(os.base(file_name))
		name, _ := os.split_filename(stem)
		has_task_shader := names_with_task_shader[name]

		loaded := load_spirv_file(ctx, file_name, has_task_shader)
		owned_name := strings.clone(loaded.name, context.allocator)
		key := render.Shader_Key {
			name  = owned_name,
			stage = loaded.stage,
		}

		if key in ctx.shaders {
			fmt.panicf("duplicate shader '%s' stage %v", owned_name, loaded.stage)
		}

		ctx.shaders[key] = loaded.handle

		table.row(
			&shader_table,
			owned_name,
			table.format(&shader_table, "%v", vk.ShaderStageFlags(loaded.stage)),
		)
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
	"VK_EXT_extended_dynamic_state3",
	"VK_EXT_vertex_input_dynamic_state",
	"VK_EXT_mesh_shader",
}

FIFO_LATEST_READY_EXTENSION :: "VK_KHR_present_mode_fifo_latest_ready"


device_supports_extension :: proc(device: vk.PhysicalDevice, name: cstring) -> bool {
	count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil)

	available := make([]vk.ExtensionProperties, count)
	defer delete(available)

	vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(available))

	for &ext in available {
		if cstring(raw_data(ext.extensionName[:])) == name {
			return true
		}
	}

	return false
}


device_supports_extensions :: proc(device: vk.PhysicalDevice, required: []cstring) -> bool {
	for name in required {
		if !device_supports_extension(device, name) {
			return false
		}
	}

	return true
}


device_supports_fifo_latest_ready :: proc(device: vk.PhysicalDevice) -> bool {
	if !device_supports_extension(device, FIFO_LATEST_READY_EXTENSION) {
		return false
	}

	fifo_features := vk.PhysicalDevicePresentModeFifoLatestReadyFeaturesKHR {
		sType = .PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_KHR,
	}

	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &fifo_features,
	}

	vk.GetPhysicalDeviceFeatures2(device, &features)

	return fifo_features.presentModeFifoLatestReady == true
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
		defer delete(families)
		vk.GetPhysicalDeviceQueueFamilyProperties(device, &family_count, raw_data(families))

		for family, i in families {
			if .COMPUTE not_in family.queueFlags do continue

			present_supported: b32
			vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), ctx.surface, &present_supported)
			if !present_supported do continue

			ctx.physical_device = device
			ctx.compute_family = u32(i)

			device_info := vk.PhysicalDeviceProperties{}
			vk.GetPhysicalDeviceProperties(device, &device_info)

			name := cstring(raw_data(device_info.deviceName[:]))

			fmt.printfln(
				"Selected physical device %v with compute+present queue family %d",
				name,
				i,
			)
			delete(devices)
			return
		}
	}
	delete(devices)
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

	features := vk.PhysicalDeviceFeatures {
		shaderInt16               = true,
		geometryShader            = true,
		tessellationShader        = true,
		multiDrawIndirect         = true,
		drawIndirectFirstInstance = true,
	}


	features_11 := vk.PhysicalDeviceVulkan11Features {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		shaderDrawParameters = true,
	}

	features_12 := vk.PhysicalDeviceVulkan12Features {
		pNext                                        = &features_11,
		sType                                        = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		bufferDeviceAddress                          = true,
		timelineSemaphore                            = true,
		runtimeDescriptorArray                       = true,
		shaderSampledImageArrayNonUniformIndexing    = true,
		shaderStorageImageArrayNonUniformIndexing    = true,
		descriptorBindingPartiallyBound              = true,
		descriptorBindingSampledImageUpdateAfterBind = true,
		descriptorBindingStorageImageUpdateAfterBind = true,
		shaderFloat16                                = true,
	}

	features_13 := vk.PhysicalDeviceVulkan13Features {
		pNext            = &features_12,
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		synchronization2 = true,
		dynamicRendering = true,
	}

	features_mesh_shader := vk.PhysicalDeviceMeshShaderFeaturesEXT {
		sType      = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT,
		pNext      = &features_13,
		meshShader = true,
		taskShader = true,
	}

	features_shader_object := vk.PhysicalDeviceShaderObjectFeaturesEXT {
		sType        = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
		pNext        = &features_mesh_shader,
		shaderObject = true,
	}

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

	features_vertex_input := vk.PhysicalDeviceVertexInputDynamicStateFeaturesEXT {
		sType                   = .PHYSICAL_DEVICE_VERTEX_INPUT_DYNAMIC_STATE_FEATURES_EXT,
		pNext                   = &features_present_wait,
		vertexInputDynamicState = true,
	}

	features_eds3 := vk.PhysicalDeviceExtendedDynamicState3FeaturesEXT {
		sType                                      = .PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT,
		pNext                                      = &features_vertex_input,
		extendedDynamicState3PolygonMode           = true,
		extendedDynamicState3RasterizationSamples  = true,
		extendedDynamicState3SampleMask            = true,
		extendedDynamicState3AlphaToCoverageEnable = true,
		extendedDynamicState3ColorBlendEnable      = true,
		extendedDynamicState3ColorBlendEquation    = true,
		extendedDynamicState3ColorWriteMask        = true,
	}

	has_fifo_latest_ready := device_supports_fifo_latest_ready(ctx.physical_device)

	features_fifo_latest_ready := vk.PhysicalDevicePresentModeFifoLatestReadyFeaturesKHR {
		sType                      = .PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_KHR,
		pNext                      = &features_eds3,
		presentModeFifoLatestReady = true,
	}

	// Add the optional extension only when both the extension and its
	// corresponding feature are actually supported.
	optional_extension_count := 0
	if has_fifo_latest_ready {
		optional_extension_count = 1
	}

	device_extensions := make(
		[]cstring,
		len(REQUIRED_DEVICE_EXTENSIONS) + optional_extension_count,
	)
	defer delete(device_extensions)

	copy(device_extensions, REQUIRED_DEVICE_EXTENSIONS)

	if has_fifo_latest_ready {
		device_extensions[len(REQUIRED_DEVICE_EXTENSIONS)] = FIFO_LATEST_READY_EXTENSION
	}

	device_pnext: rawptr = &features_eds3

	if has_fifo_latest_ready {
		device_pnext = &features_fifo_latest_ready
	}

	device_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = device_pnext,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions),
		pEnabledFeatures        = &features,
	}

	if res := vk.CreateDevice(ctx.physical_device, &device_info, nil, &ctx.device);
	   res != .SUCCESS {
		fmt.panicf("failed to create device: %v", res)
	}

	if has_fifo_latest_ready {
		fmt.println("FIFO latest-ready presentation supported")
	} else {
		fmt.println("FIFO latest-ready presentation unavailable; using fallback")
	}

	vk.GetDeviceQueue(ctx.device, ctx.compute_family, 0, &ctx.compute_queue)
}

create_swapchain :: proc(ctx: ^render.Context, old_swapchain: vk.SwapchainKHR = 0) {
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
		// Some presentation engines (e.g. Wayland) report no fixed extent
		// here, so fall back to the window's actual drawable size.
		width, height: i32
		sdl2.Vulkan_GetDrawableSize(ctx.window, &width, &height)
		extent = vk.Extent2D{u32(width), u32(height)}

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

		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			ctx.physical_device,
			ctx.surface,
			&present_mode_count,
			nil,
		)

		present_modes := make([]vk.PresentModeKHR, present_mode_count)
		defer delete(present_modes)

		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			ctx.physical_device,
			ctx.surface,
			&present_mode_count,
			raw_data(present_modes),
		)

		has_fifo_latest_ready := device_supports_fifo_latest_ready(ctx.physical_device)

		has_mailbox := false
		has_latest_ready := false

		for mode in present_modes {
			#partial switch mode {
			case .MAILBOX:
				has_mailbox = true

			case .FIFO_LATEST_READY:
				has_latest_ready = true

			case:
			}
		}

		selected_mode := vk.PresentModeKHR.FIFO

		if has_mailbox {
			selected_mode = .MAILBOX
		}

		if has_fifo_latest_ready && has_latest_ready {
			selected_mode = .FIFO_LATEST_READY
		}

		fmt.printfln("Selected present mode: %v", selected_mode)

		return selected_mode
	}

	swapchain_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = ctx.surface,
		minImageCount    = image_count,
		imageFormat      = chosen_format.format,
		imageColorSpace  = chosen_format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = find_supported_present_mode(ctx),
		clipped          = true,
		oldSwapchain     = old_swapchain,
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

// Rebuilds the swapchain and everything sized off it (the swapchain-image
// views, the per-swapchain-image render-finished semaphores, and the
// offscreen target). Command buffers, the simulation's ping-pong buffers
// and display image, and the bindless slots they occupy are all untouched:
// none of them depend on the window size.
recreate_swapchain :: proc(ctx: ^render.Context) {
	// A minimized window has a zero-sized drawable area, which Vulkan
	// rejects as a swapchain extent. Block until it is shown again.
	width, height: i32
	sdl2.Vulkan_GetDrawableSize(ctx.window, &width, &height)
	for width == 0 || height == 0 {
		sdl2.WaitEventTimeout(nil, 100)
		sdl2.Vulkan_GetDrawableSize(ctx.window, &width, &height)
	}

	if res := vk.DeviceWaitIdle(ctx.device); res != .SUCCESS {
		fmt.panicf("vkDeviceWaitIdle failed before swapchain recreation: %v", res)
	}

	old_swapchain := ctx.swapchain.handle
	old_image_views := ctx.swapchain.image_views
	old_images := ctx.swapchain.images

	create_swapchain(ctx, old_swapchain)

	for view in old_image_views {
		vk.DestroyImageView(ctx.device, view, nil)
	}
	delete(old_image_views)
	delete(old_images)
	vk.DestroySwapchainKHR(ctx.device, old_swapchain, nil)

	destroy_render_finished_semaphores(ctx)
	create_render_finished_semaphores(ctx)

	recreate_offscreen_target(ctx)

	ctx.framebuffer_resized = false
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
			binding = 0,
			descriptorType = .SAMPLER,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags = vk.ShaderStageFlags_ALL,
		},
		{
			binding = 1,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags = vk.ShaderStageFlags_ALL,
		},
		{
			binding = 2,
			descriptorType = .STORAGE_IMAGE,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags = vk.ShaderStageFlags_ALL,
		},
		{
			binding = 3,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags = vk.ShaderStageFlags_ALL,
		},
		{
			binding = 4,
			descriptorType = .STORAGE_IMAGE,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags = vk.ShaderStageFlags_ALL,
		},
		{
			binding = 5,
			descriptorType = .SAMPLER,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags = vk.ShaderStageFlags_ALL,
		},
		{
			binding = 6,
			descriptorType = .SAMPLER,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags = vk.ShaderStageFlags_ALL,
		},
		{
			binding = 7,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = render.MAX_BINDLESS_ARRAY_SIZE,
			stageFlags = vk.ShaderStageFlags_ALL,
		},
	}

	bindless_binding_flags := vk.DescriptorBindingFlags{(.PARTIALLY_BOUND | .UPDATE_AFTER_BIND)}

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

create_buffer :: proc(
	ctx: ^render.Context,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags = {.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
) -> render.Buffer_Handle {
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

	return render.resource_add(&ctx.buffer_pool, buffer)
}

create_image :: proc(
	ctx: ^render.Context,
	width: u32,
	height: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	aspect: vk.ImageAspectFlags = {.COLOR},
) -> render.Image_Handle {
	image: render.Image
	image.format = format

	image_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format,
		extent        = {width, height, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = usage,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}

	if res := vk.CreateImage(ctx.device, &image_info, nil, &image.object); res != .SUCCESS {
		fmt.panicf("failed to create image: %v", res)
	}

	mem_reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(ctx.device, image.object, &mem_reqs)

	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(ctx.physical_device, &mem_props)

	mem_type_index := max(u32)
	wanted := vk.MemoryPropertyFlags{.DEVICE_LOCAL}

	for i in 0 ..< mem_props.memoryTypeCount {
		if (mem_reqs.memoryTypeBits & (1 << i)) != 0 &&
		   (mem_props.memoryTypes[i].propertyFlags & wanted) == wanted {
			mem_type_index = i
			break
		}
	}

	if mem_type_index == max(u32) {
		vk.DestroyImage(ctx.device, image.object, nil)

		fmt.panicf("no suitable memory type found for image")
	}

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = mem_type_index,
	}

	if res := vk.AllocateMemory(ctx.device, &alloc_info, nil, &image.memory); res != .SUCCESS {
		vk.DestroyImage(ctx.device, image.object, nil)

		fmt.panicf("failed to allocate image memory: %v", res)
	}

	if res := vk.BindImageMemory(ctx.device, image.object, image.memory, 0); res != .SUCCESS {
		vk.FreeMemory(ctx.device, image.memory, nil)
		vk.DestroyImage(ctx.device, image.object, nil)

		fmt.panicf("failed to bind image memory: %v", res)
	}

	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = image.object,
		viewType = .D2,
		format = format,
		subresourceRange = {aspectMask = aspect, levelCount = 1, layerCount = 1},
	}

	if res := vk.CreateImageView(ctx.device, &view_info, nil, &image.view); res != .SUCCESS {
		vk.FreeMemory(ctx.device, image.memory, nil)
		vk.DestroyImage(ctx.device, image.object, nil)

		fmt.panicf("failed to create image view: %v", res)
	}

	return render.resource_add(&ctx.image_pool, image)
}

// One-shot UNDEFINED -> GENERAL transition so the compute shader can write
// into the display image on its very first dispatch.
transition_image_to_general :: proc(ctx: ^render.Context, image: vk.Image) {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = ctx.command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	cmd: vk.CommandBuffer
	if res := vk.AllocateCommandBuffers(ctx.device, &alloc_info, &cmd); res != .SUCCESS {
		fmt.panicf("failed to allocate one-shot command buffer: %v", res)
	}
	defer vk.FreeCommandBuffers(ctx.device, ctx.command_pool, 1, &cmd)

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}

	if res := vk.BeginCommandBuffer(cmd, &begin_info); res != .SUCCESS {
		fmt.panicf("failed to begin one-shot command buffer: %v", res)
	}

	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.TOP_OF_PIPE},
		dstStageMask = {.COMPUTE_SHADER},
		dstAccessMask = {.SHADER_WRITE},
		oldLayout = .UNDEFINED,
		newLayout = .GENERAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}

	dependency_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}

	vk.CmdPipelineBarrier2(cmd, &dependency_info)

	if res := vk.EndCommandBuffer(cmd); res != .SUCCESS {
		fmt.panicf("failed to end one-shot command buffer: %v", res)
	}

	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cmd,
	}

	if res := vk.QueueSubmit(ctx.compute_queue, 1, &submit_info, 0); res != .SUCCESS {
		fmt.panicf("failed to submit one-shot command buffer: %v", res)
	}

	if res := vk.QueueWaitIdle(ctx.compute_queue); res != .SUCCESS {
		fmt.panicf("failed to wait for one-shot command buffer: %v", res)
	}
}

init_simulation :: proc(ctx: ^render.Context) {
	ctx.simulation.width = config.GRID_WIDTH
	ctx.simulation.height = config.GRID_HEIGHT

	for i in 0 ..< 2 {
		ctx.simulation.buffers[i] = create_buffer(
			ctx,
			config.BUFFER_SIZE,
			{.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
		)
	}

	for slot in 0 ..< render.MAX_FRAMES_IN_FLIGHT {
		ctx.ubo_buffers[slot] = create_buffer(
			ctx,
			size_of(render.UBO),
			{.UNIFORM_BUFFER, .SHADER_DEVICE_ADDRESS},
		)
	}

	// Seed generation zero with a random population in buffers[current],
	// which run_frame will read as "prev" for the first dispatch.
	seed_buffer, found := render.resource_try_get(
		&ctx.buffer_pool,
		ctx.simulation.buffers[ctx.simulation.current],
	)
	if !found {
		fmt.panicf("failed to get simulation seed buffer")
	}
	cells := (^[config.CELL_COUNT]u32)(seed_buffer.mapped)
	for i in 0 ..< config.CELL_COUNT {
		cells[i] = 1 if rand.float32() < 0.25 else 0
	}

	ctx.simulation.display_image = create_image(
		ctx,
		ctx.simulation.width,
		ctx.simulation.height,
		.R8G8B8A8_UNORM,
		{.STORAGE, .SAMPLED},
	)

	display_image, image_found := render.resource_try_get(
		&ctx.image_pool,
		ctx.simulation.display_image,
	)
	if !image_found {
		fmt.panicf("failed to get freshly created display image")
	}

	transition_image_to_general(ctx, display_image.object)

	storage_handle, storage_ok := render.bindless_allocate_storage_image_2d(
		ctx,
		display_image.view,
	)
	if !storage_ok {
		fmt.panicf("failed to allocate bindless storage slot for display image")
	}
	ctx.simulation.display_image_index = storage_handle.index

	texture_handle, texture_ok := render.bindless_allocate_texture_2d(ctx, display_image.view)
	if !texture_ok {
		fmt.panicf("failed to allocate bindless texture slot for display image")
	}
	ctx.simulation.display_texture_index = texture_handle.index
}

// D32_SFLOAT is guaranteed by the Vulkan spec to support the
// DEPTH_STENCIL_ATTACHMENT usage with optimal tiling, so no format query is
// needed here.
DEPTH_FORMAT :: vk.Format.D32_SFLOAT

// The offscreen targets the mesh is drawn into (one per frame-in-flight
// slot), their depth buffers, and the sampler the swapchain-final pass uses
// to read an offscreen target (and to read the display image).
init_render_targets :: proc(ctx: ^render.Context) {
	for slot in 0 ..< render.MAX_FRAMES_IN_FLIGHT {
		create_offscreen_image(ctx, slot)
		create_depth_image(ctx, slot)

		offscreen_image, found := render.resource_try_get(
			&ctx.image_pool,
			ctx.offscreen_images[slot],
		)
		if !found {
			fmt.panicf("failed to get freshly created offscreen image for slot %d", slot)
		}

		texture_handle, texture_ok := render.bindless_allocate_texture_2d(
			ctx,
			offscreen_image.view,
		)
		if !texture_ok {
			fmt.panicf("failed to allocate bindless texture slot for offscreen image %d", slot)
		}
		ctx.offscreen_texture_indices[slot] = texture_handle.index
	}

	sampler_info := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .NEAREST,
		minFilter    = .NEAREST,
		mipmapMode   = .NEAREST,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		maxLod       = 0,
	}

	if res := vk.CreateSampler(ctx.device, &sampler_info, nil, &ctx.nearest_sampler);
	   res != .SUCCESS {
		fmt.panicf("failed to create nearest sampler: %v", res)
	}

	sampler_handle, sampler_ok := render.bindless_allocate_sampler_2d(ctx, ctx.nearest_sampler)
	if !sampler_ok {
		fmt.panicf("failed to allocate bindless slot for nearest sampler")
	}
	ctx.nearest_sampler_index = sampler_handle.index
}

create_offscreen_image :: proc(ctx: ^render.Context, slot: int) {
	ctx.offscreen_images[slot] = create_image(
		ctx,
		ctx.swapchain.extent.width,
		ctx.swapchain.extent.height,
		ctx.swapchain.format,
		{.COLOR_ATTACHMENT, .SAMPLED},
	)
}

create_depth_image :: proc(ctx: ^render.Context, slot: int) {
	ctx.depth_images[slot] = create_image(
		ctx,
		ctx.swapchain.extent.width,
		ctx.swapchain.extent.height,
		DEPTH_FORMAT,
		{.DEPTH_STENCIL_ATTACHMENT},
		{.DEPTH},
	)
}

// Called after recreate_swapchain has resized the swapchain: every slot's
// offscreen target and depth buffer are sized to match it, so all must be
// rebuilt. Each offscreen target's bindless texture slot is reused in place
// (see bindless_update_texture_2d) rather than freed and reallocated; the
// depth images have no bindless slot to update, they are only ever render
// targets.
recreate_offscreen_target :: proc(ctx: ^render.Context) {
	for slot in 0 ..< render.MAX_FRAMES_IN_FLIGHT {
		render.resource_destroy(ctx, &ctx.image_pool, ctx.offscreen_images[slot])
		render.resource_destroy(ctx, &ctx.image_pool, ctx.depth_images[slot])

		create_offscreen_image(ctx, slot)
		create_depth_image(ctx, slot)

		offscreen_image, found := render.resource_try_get(
			&ctx.image_pool,
			ctx.offscreen_images[slot],
		)
		if !found {
			fmt.panicf("failed to get recreated offscreen image for slot %d", slot)
		}

		render.bindless_update_texture_2d(
			ctx,
			ctx.offscreen_texture_indices[slot],
			offscreen_image.view,
		)
	}
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

	create_render_finished_semaphores(ctx)
}

// Sized to the swapchain's image count, so this is redone whenever the
// swapchain is recreated (that count can change across recreation).
create_render_finished_semaphores :: proc(ctx: ^render.Context) {
	binary_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
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

destroy_render_finished_semaphores :: proc(ctx: ^render.Context) {
	for semaphore in ctx.render_finished_semaphores {
		vk.DestroySemaphore(ctx.device, semaphore, nil)
	}
	delete(ctx.render_finished_semaphores)
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

	for key in ctx.shaders {
		delete(key.name)
	}
	delete(ctx.shaders)

	vk.DestroySampler(ctx.device, ctx.nearest_sampler, nil)

	render.resource_destroy_all(ctx, &ctx.buffer_pool)
	render.resource_destroy_all(ctx, &ctx.shader_pool)
	render.resource_destroy_all(ctx, &ctx.image_pool)

	destroy_render_finished_semaphores(ctx)
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
