package render

import "../maths"
import io "../vk_io"
import "vendor:sdl2"
import vk "vendor:vulkan"

Shader :: struct {
	handle: Shader_Handle,
	object: vk.ShaderEXT,
	stage:  vk.ShaderStageFlags,
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
	handle:         Buffer_Handle,
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
	extent: vk.Extent3D,
}

PushConstants :: struct {
	prev:        vk.DeviceAddress,
	curr:        vk.DeviceAddress,
	ubo:         vk.DeviceAddress,
	width:       u32,
	height:      u32,
	image_index: u32,
}

UBO :: struct {
	dt:          f32,
	should_step: u32,
	draw_data:   vk.DeviceAddress,
}

Sample_Push_Constants :: struct {
	texture_index: u32,
	sampler_index: u32,
}

Mesh_Push_Constants :: struct {
	vertices:      vk.DeviceAddress,
	bounds:        vk.DeviceAddress,
	ubo:           vk.DeviceAddress,
	angle:         f32,
	aspect:        f32,
	count:         u32,
	meshlet_count: u32,
	texture_index: u32,
	sampler_index: u32,
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
}

/**
    float4 quat_rotation;
    float3 translation;
    float scale;
    uint material_index;
*/
Draw_Data :: struct {
	quat_rotation:  maths.Quat,
	translation:    maths.Vec3,
	scale:          f32,
	material_index: u32,
}

Mesh_Submission :: struct {
	mesh:            Mesh,
	draw_data_index: u32,
}

Draw_Stream :: struct {
	// CPU-side state for the frame currently being built.
	draw_data:   [dynamic]Draw_Data,
	submissions: [dynamic]Mesh_Submission,

	// GPU-side storage. Each FIF slot can independently grow.
	buffers:     [MAX_FRAMES_IN_FLIGHT]Buffer_Handle,
	capacities:  [MAX_FRAMES_IN_FLIGHT]int,
}

Simulation :: struct {
	buffers:               [2]Buffer_Handle,
	current:               int,
	generation:            u64,
	completion_value:      u64,

	// Seconds of frame time banked since the automaton last actually
	// stepped; see config.SIM_STEP_INTERVAL.
	accumulated_time:      f32,
	width:                 u32,
	height:                u32,
	display_image:         Image_Handle,
	display_image_index:   u32, // bindless storage-image slot, for the compute write
	display_texture_index: u32, // bindless sampled-texture slot, allocated but currently unsampled
}

// A flat, non-indexed triangle list uploaded once at startup and drawn every
// frame by the mesh shader, one meshlet (MESH_MESHLET_TRIANGLES triangles)
// per CmdDrawMeshTasksEXT workgroup. See shaders/suzanne.mesh.slang.
Mesh :: struct {
	vertex_buffer: Buffer_Handle,
	vertex_count:  u32,
	meshlet_count: u32,
	rotation:      f32,

	// One Meshlet_Bounds per meshlet (see mesh.odin), read by the task
	// shader to frustum-cull whole meshlets before dispatching mesh
	// shader workgroups for them.
	bounds_buffer: Buffer_Handle,
}

Screenshot_Request :: struct {
	handle:           Screenshot_Handle,
	state:            Screenshot_Status,
	target:           Screenshot_Target,
	readback_buffer:  Buffer_Handle,
	completion_value: u64,
	frame_number:     u64,
	width:            u32,
	height:           u32,
	row_stride:       u32,
	format:           vk.Format,
}

Screenshot_System :: struct {
	requests:        [dynamic]Screenshot_Request,
	next_generation: u16,
}

Context :: struct {
	window:                         ^sdl2.Window,
	instance:                       vk.Instance,
	physical_device:                vk.PhysicalDevice,
	device:                         vk.Device,
	compute_queue:                  vk.Queue,
	compute_family:                 u32,
	surface:                        vk.SurfaceKHR,
	swapchain:                      Swapchain,
	command_pool:                   vk.CommandPool,
	frames:                         [MAX_FRAMES_IN_FLIGHT]Frame_Data,
	simulation:                     Simulation,
	ubo_buffers:                    [MAX_FRAMES_IN_FLIGHT]Buffer_Handle,
	offscreen_images:               [MAX_FRAMES_IN_FLIGHT]Image_Handle,
	offscreen_texture_indices:      [MAX_FRAMES_IN_FLIGHT]u32,
	depth_images:                   [MAX_FRAMES_IN_FLIGHT]Image_Handle,
	draw_stream:                    Draw_Stream,
	mesh:                           Mesh,
	nearest_sampler:                vk.Sampler,
	nearest_sampler_index:          u32,
	physical_device_properties:     vk.PhysicalDeviceProperties,
	render_finished_semaphores:     []vk.Semaphore,
	bindless_descriptor_set_layout: vk.DescriptorSetLayout,
	bindless:                       Bindless_Descriptor_Set,
	global_push_constant_range:     vk.PushConstantRange,
	timeline_semaphore:             vk.Semaphore,
	timeline_value:                 u64,
	present_id:                     u64,
	shader_pool:                    Resource_Pool(Shader, Shader_Handle),
	buffer_pool:                    Resource_Pool(Buffer, Buffer_Handle),
	image_pool:                     Resource_Pool(Image, Image_Handle),
	shaders:                        map[Shader_Key]Shader_Handle,
	pipeline_layout:                vk.PipelineLayout,
	debug_messenger:                vk.DebugUtilsMessengerEXT,
	io:                             io.IO_State,
	framebuffer_resized:            bool,
	screenshots:                    Screenshot_System,
	frame_number:                   u64,
}

Frame_Result :: enum {
	Submitted,
	Skipped,
	Swapchain_Out_Of_Date,
}

init_resource_pools :: proc(ctx: ^Context) {
	resource_pool_init(&ctx.shader_pool, shader_destroy_object)
	resource_pool_init(&ctx.buffer_pool, buffer_destroy_object)
	resource_pool_init(&ctx.image_pool, image_destroy_object)
}
