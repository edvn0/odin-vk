package render

import "base:runtime"
import "core:fmt"
import hm "core:container/handle_map"
import vk "vendor:vulkan"
import trace "core:debug/trace"

//
// Strongly typed handles.
//
// Structurally these are the same as hm.Handle32, but keeping them as
// distinct types prevents accidentally passing a Buffer_Handle to the
// shader pool, etc.
//

Shader_Handle :: struct {
	idx: u16,
	gen: u16,
}

Buffer_Handle :: struct {
	idx: u16,
	gen: u16,
}

Image_Handle :: struct {
	idx: u16,
	gen: u16,
}


//
// Generic resource pool.
//
// T must contain:
//
//     handle: Handle
//
// because that is required by core:container/handle_map.
//
// The destroy callback is stored in the pool so callers do not need to
// provide it every time they destroy a resource.
//

Resource_Pool :: struct($T, $Handle: typeid) {
	storage: hm.Dynamic_Handle_Map(T, Handle),
	destroy: proc(ctx: ^Context, resource: ^T),
}


resource_pool_init :: proc(
	pool: ^Resource_Pool($T, $Handle),
	destroy: proc(ctx: ^Context, resource: ^T),
	allocator := context.allocator,
) {
	assert(destroy != nil)

	hm.dynamic_init(&pool.storage, allocator)
	pool.destroy = destroy
}


//
// Only use this if the pool is known to contain no live resources.
//
// Normally resource_destroy_all is what you want at shutdown.
//

resource_pool_deinit_empty :: proc(
	pool: ^Resource_Pool($T, $Handle),
) {
	assert(resource_len(pool) == 0)

	hm.dynamic_destroy(&pool.storage)
	pool^ = {}
}


resource_len :: proc(
	pool: ^Resource_Pool($T, $Handle),
) -> uint {
	return hm.len(pool.storage)
}


resource_is_valid :: proc(
	pool: ^Resource_Pool($T, $Handle),
	handle: Handle,
) -> bool {
	return hm.is_valid(&pool.storage, handle)
}


resource_try_add :: proc(
	pool: ^Resource_Pool($T, $Handle),
	value: T,
) -> (Handle, runtime.Allocator_Error) {
	return hm.add(&pool.storage, value)
}


resource_add :: proc(
	pool: ^Resource_Pool($T, $Handle),
	value: T,
) -> Handle {
	handle, err := resource_try_add(pool, value)
	if err != nil {
		fmt.panicf(
			"failed to add resource to pool: %v",
			err,
		)
	}

	return handle
}

get_shader :: proc(
	ctx: ^Context,
	name: string,
	stage: vk.ShaderStageFlags,
) -> ^Shader {
	key := Shader_Key {
		name  = name,
		stage = stage,
	}

	handle, found := ctx.shaders[key]
	if !found {
		bt := trace.capture()

		locations, err := trace.resolve(bt)
		if err == nil {
			trace.print(locations)
			trace.locations_destroy(locations)
		} else {
			fmt.eprintfln("failed to resolve call trace: %v", err)
		}
		fmt.panicf(
			"shader '%s' stage %v not found",
			name,
			stage,
		)
	}

	shader, resource_found := resource_try_get(
		&ctx.shader_pool,
		handle,
	)
	if !resource_found {
		fmt.panicf(
			"stale shader handle for '%s'",
			name,
		)
	}

	return shader
}

resource_try_get :: proc(
	pool: ^Resource_Pool($T, $Handle),
	handle: Handle,
) -> (^T, bool) {
	return hm.get(&pool.storage, handle)
}


resource_get :: proc(
	pool: ^Resource_Pool($T, $Handle),
	handle: Handle,
) -> ^T {
	resource, ok := resource_try_get(pool, handle)
	if !ok {
		fmt.panicf(
			"invalid resource handle: idx=%v gen=%v",
			handle.idx,
			handle.gen,
		)
	}

	return resource
}


//
// Removes a resource from the pool without destroying the underlying object.
//
// This is intentionally separate from resource_destroy. Most Vulkan resources
// should use resource_destroy instead.
//

resource_try_remove :: proc(
	pool: ^Resource_Pool($T, $Handle),
	handle: Handle,
) -> (bool, runtime.Allocator_Error) {
	return hm.remove(&pool.storage, handle)
}


resource_remove :: proc(
	pool: ^Resource_Pool($T, $Handle),
	handle: Handle,
) -> bool {
	found, err := resource_try_remove(pool, handle)
	if err != nil {
		fmt.panicf(
			"failed to remove resource from pool: %v",
			err,
		)
	}

	return found
}


//
// Invalidate the handle first, then destroy the underlying resource.
//
// hm.remove may allocate when appending the slot to its free-index list.
// We therefore must not destroy the Vulkan object before remove succeeds.
//
// Copying T first lets us retain the Vulkan object information after the
// handle-map entry has been invalidated.
//

resource_try_destroy :: proc(
	ctx: ^Context,
	pool: ^Resource_Pool($T, $Handle),
	handle: Handle,
) -> (bool, runtime.Allocator_Error) {
	resource, ok := resource_try_get(pool, handle)
	if !ok {
		return false, nil
	}

	resource_to_destroy := resource^

	found, err := hm.remove(&pool.storage, handle)
	if err != nil {
		return false, err
	}

	if !found {
		return false, nil
	}

	pool.destroy(ctx, &resource_to_destroy)

	return true, nil
}


resource_destroy :: proc(
	ctx: ^Context,
	pool: ^Resource_Pool($T, $Handle),
	handle: Handle,
) -> bool {
	found, err := resource_try_destroy(ctx, pool, handle)
	if err != nil {
		fmt.panicf(
			"failed to destroy resource: %v",
			err,
		)
	}

	return found
}


//
// Destroy every currently live object and then free the handle-map storage.
//
// We do not remove entries one-by-one here because the entire pool is about
// to disappear anyway. The iterator already skips dead slots.
//

resource_destroy_all :: proc(
	ctx: ^Context,
	pool: ^Resource_Pool($T, $Handle),
) {
	if pool.destroy != nil {
		it := hm.iterator_make(&pool.storage)

		for resource, _ in hm.iterate(&it) {
			pool.destroy(ctx, resource)
		}
	}

	hm.dynamic_destroy(&pool.storage)
	pool^ = {}
}


//
// Vulkan destruction policies
//

shader_destroy_object :: proc(
	ctx: ^Context,
	shader: ^Shader,
) {
	vk.DestroyShaderEXT(
		ctx.device,
		shader.object,
		nil,
	)
}


buffer_destroy_object :: proc(
	ctx: ^Context,
	buffer: ^Buffer,
) {
	if buffer.mapped != nil {
		vk.UnmapMemory(
			ctx.device,
			buffer.memory,
		)
	}

	vk.DestroyBuffer(
		ctx.device,
		buffer.object,
		nil,
	)

	vk.FreeMemory(
		ctx.device,
		buffer.memory,
		nil,
	)
}


image_destroy_object :: proc(
	ctx: ^Context,
	image: ^Image,
) {
	vk.DestroyImageView(
		ctx.device,
		image.view,
		nil,
	)

	vk.DestroyImage(
		ctx.device,
		image.object,
		nil,
	)

	vk.FreeMemory(
		ctx.device,
		image.memory,
		nil,
	)
}