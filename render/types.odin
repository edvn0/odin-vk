package render

import "vendor:sdl2"
import vk "vendor:vulkan"
import io "../vk_io"

Shader :: struct {
	handle: Shader_Handle,
	object: vk.ShaderEXT,
	stage: vk.ShaderStageFlags,
}

Shader_Set :: struct {
	vertex:                  Shader_Handle,
	tessellation_control:    Shader_Handle,
	tessellation_evaluation: Shader_Handle,
	geometry:                Shader_Handle,
	fragment:                Shader_Handle,
}

Shader_Key :: struct {
	name:  string,
	stage: vk.ShaderStageFlags,
}

Buffer :: struct {
	handle: Buffer_Handle,

	object:         vk.Buffer,
	memory:         vk.DeviceMemory,
	device_address: vk.DeviceAddress,
	mapped:         rawptr,
}


Image :: struct {
	handle: Image_Handle,

	object: vk.Image,
	memory: vk.DeviceMemory,
	view:   vk.ImageView,
	format: vk.Format,
}

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

MAX_FRAMES_IN_FLIGHT :: 3

Frame_Data :: struct {
	command_buffer:   vk.CommandBuffer,
	image_available:  vk.Semaphore,
	completion_value: u64,

	buffer: Buffer_Handle,
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
		frames: [MAX_FRAMES_IN_FLIGHT]Frame_Data,

	physical_device_properties: vk.PhysicalDeviceProperties,

	render_finished_semaphores: []vk.Semaphore,

	bindless_descriptor_set_layout: vk.DescriptorSetLayout,
	bindless:                       Bindless_Descriptor_Set,
	global_push_constant_range: vk.PushConstantRange,

	timeline_semaphore: vk.Semaphore,
	timeline_value:     u64,
	present_id: u64,

    shader_pool: Resource_Pool(Shader, Shader_Handle),
	buffer_pool: Resource_Pool(Buffer, Buffer_Handle),
	image_pool:  Resource_Pool(Image, Image_Handle),

	shaders: map[Shader_Key]Shader_Handle,

	pipeline_layout: vk.PipelineLayout,
	debug_messenger: vk.DebugUtilsMessengerEXT,
	io:              io.IO_State,
}

init_resource_pools :: proc(ctx: ^Context) {
	resource_pool_init(&ctx.shader_pool, shader_destroy_object)
	resource_pool_init(&ctx.buffer_pool, buffer_destroy_object)
	resource_pool_init(&ctx.image_pool, image_destroy_object)
}