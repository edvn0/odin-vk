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
	prev:        vk.DeviceAddress,
	curr:        vk.DeviceAddress,
	width:       u32,
	height:      u32,
	image_index: u32,
}

// Pushed to the fullscreen-triangle vertex+fragment pair used by the
// swapchain-final dynamic rendering pass.
Sample_Push_Constants :: struct {
	texture_index: u32,
	sampler_index: u32,
}

// Pushed to the mesh+fragment shader pair that draws the mesh into the
// offscreen target. The camera is fixed (see the shader), so only the
// model's spin angle and the current aspect ratio need to travel with it.
// texture_index/sampler_index point at the bindless GoL display image,
// which the fragment shader samples (by UV) to tint the mesh's surface.
// Shared unmodified across the task, mesh and fragment stages: they're all
// bound to the same push constant range, so their PC struct layouts must
// agree byte-for-byte even though each stage only reads some of it.
Mesh_Push_Constants :: struct {
	vertices:      vk.DeviceAddress,
	bounds:        vk.DeviceAddress,
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

//
// The simulation owns its own ping-pong buffers and generation counter,
// independent of frames-in-flight. Frames-in-flight only own transient
// per-submission renderer resources (command buffers, acquire semaphores).
//
Simulation :: struct {
	buffers:          [2]Buffer_Handle,
	current:          int,
	generation:       u64,
	completion_value: u64,

	width:  u32,
	height: u32,

	display_image:        Image_Handle,
	display_image_index:  u32, // bindless storage-image slot, for the compute write
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
	frames:          [MAX_FRAMES_IN_FLIGHT]Frame_Data,
	simulation:      Simulation,

	// Offscreen target that the mesh is drawn into first; the
	// swapchain-final pass then samples it, rather than the mesh pass
	// drawing to the swapchain directly. This gives future post-processing
	// passes somewhere to sit between the two.
	//
	// One per frame-in-flight slot, not a single shared image: with only
	// one instance, frame N+1's mesh pass could start writing it while
	// frame N's swapchain-final pass was still reading it (the per-slot
	// command-buffer wait only guarantees frame N-MAX_FRAMES_IN_FLIGHT is
	// done, not frame N-1), which was observed to intermittently hang the
	// GPU. Indexing by slot gives each frame-in-flight its own image, so
	// there is nothing left to race.
	offscreen_images:         [MAX_FRAMES_IN_FLIGHT]Image_Handle,
	offscreen_texture_indices: [MAX_FRAMES_IN_FLIGHT]u32,

	// Depth buffer for the offscreen mesh pass. Same one-per-slot reasoning
	// as offscreen_images above.
	depth_images: [MAX_FRAMES_IN_FLIGHT]Image_Handle,

	mesh: Mesh,

	nearest_sampler:       vk.Sampler,
	nearest_sampler_index: u32,

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

	// Set by the platform layer on a window resize event, and whenever
	// vkQueuePresentKHR reports VK_SUBOPTIMAL_KHR. The main loop checks
	// this and recreates the swapchain (and everything sized off it)
	// before the next frame.
	framebuffer_resized: bool,
}

// What the caller of run_frame should do next.
Frame_Result :: enum {
	Submitted,              // a generation was recorded, submitted and presented
	Skipped,                // no swapchain image was available this tick; try again
	Swapchain_Out_Of_Date,  // the swapchain must be recreated before the next frame
}

init_resource_pools :: proc(ctx: ^Context) {
	resource_pool_init(&ctx.shader_pool, shader_destroy_object)
	resource_pool_init(&ctx.buffer_pool, buffer_destroy_object)
	resource_pool_init(&ctx.image_pool, image_destroy_object)
}