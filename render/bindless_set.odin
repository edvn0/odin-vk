package render

import fmt "core:fmt"
import vk "vendor:vulkan"

MAX_BINDLESS_ARRAY_SIZE :: 1024
BINDLESS_BINDING_COUNT :: 8
MAX_BINDLESS_RESOURCES :: MAX_BINDLESS_ARRAY_SIZE * BINDLESS_BINDING_COUNT

Bindless_Resource_Kind :: enum u8 {
	SAMPLER_2D,
	TEXTURE_2D,
	STORAGE_IMAGE_2D,
	TEXTURE_3D,
	STORAGE_IMAGE_3D,
	SAMPLER_3D,
	COMPARISON_SAMPLER,
	TEXTURE_2D_DEPTH,
}

bindless_binding :: proc(kind: Bindless_Resource_Kind) -> u32 {
	switch kind {
	case .SAMPLER_2D:
		return 0
	case .TEXTURE_2D:
		return 1
	case .STORAGE_IMAGE_2D:
		return 2
	case .TEXTURE_3D:
		return 3
	case .STORAGE_IMAGE_3D:
		return 4
	case .SAMPLER_3D:
		return 5
	case .COMPARISON_SAMPLER:
		return 6
	case .TEXTURE_2D_DEPTH:
		return 7
	}

	unreachable()
}

Bindless_Handle :: struct {
	index:      u32,
	generation: u32,
	kind:       Bindless_Resource_Kind,
}

Bindless_Slot_Allocator :: struct {
	free_indices: [MAX_BINDLESS_ARRAY_SIZE]u32,
	generations:  [MAX_BINDLESS_ARRAY_SIZE]u32,

	// allocated means that this generation still owns the slot.
	allocated:    [MAX_BINDLESS_ARRAY_SIZE]bool,

	// retiring means that CPU code must no longer use the handle, but the
	// slot cannot yet be recycled because the GPU may still reference it.
	retiring:     [MAX_BINDLESS_ARRAY_SIZE]bool,
	free_count:   u32,
}

Deferred_Bindless_Free :: struct {
	handle:       Bindless_Handle,
	retire_value: u64,
}

Bindless_Descriptor_Set :: struct {
	pool:                vk.DescriptorPool,
	set:                 vk.DescriptorSet,
	allocators:          []Bindless_Slot_Allocator,
	deferred_frees:      []Deferred_Bindless_Free,
	deferred_free_count: u32,
}

bindless_handle_matches :: proc(ctx: ^Context, handle: Bindless_Handle) -> bool {
	if handle.index >= MAX_BINDLESS_ARRAY_SIZE {
		return false
	}

	binding := bindless_binding(handle.kind)
	allocator := &ctx.bindless.allocators[binding]

	index := int(handle.index)

	return allocator.allocated[index] && allocator.generations[index] == handle.generation
}

bindless_handle_valid :: proc(ctx: ^Context, handle: Bindless_Handle) -> bool {
	if !bindless_handle_matches(ctx, handle) {
		return false
	}

	binding := bindless_binding(handle.kind)
	allocator := &ctx.bindless.allocators[binding]

	return !allocator.retiring[int(handle.index)]
}

bindless_slot_allocator_init :: proc(allocator: ^Bindless_Slot_Allocator) {
	allocator.free_count = MAX_BINDLESS_ARRAY_SIZE

	for i in 0 ..< MAX_BINDLESS_ARRAY_SIZE {
		allocator.free_indices[i] = u32(MAX_BINDLESS_ARRAY_SIZE - 1 - i)

		allocator.generations[i] = 1
		allocator.allocated[i] = false
		allocator.retiring[i] = false
	}
}

bindless_allocate_slot :: proc(
	ctx: ^Context,
	kind: Bindless_Resource_Kind,
) -> (
	Bindless_Handle,
	bool,
) {
	binding := bindless_binding(kind)
	allocator := &ctx.bindless.allocators[binding]

	if allocator.free_count == 0 {
		return {}, false
	}

	allocator.free_count -= 1

	index := allocator.free_indices[allocator.free_count]
	slot := int(index)

	assert(!allocator.allocated[slot])
	assert(!allocator.retiring[slot])

	allocator.allocated[slot] = true

	return Bindless_Handle{index = index, generation = allocator.generations[slot], kind = kind},
		true
}

bindless_free_completed :: proc(ctx: ^Context, handle: Bindless_Handle) {
	assert(bindless_handle_matches(ctx, handle))

	binding := bindless_binding(handle.kind)
	allocator := &ctx.bindless.allocators[binding]

	index := int(handle.index)

	assert(allocator.retiring[index])
	assert(allocator.free_count < MAX_BINDLESS_ARRAY_SIZE)

	allocator.allocated[index] = false
	allocator.retiring[index] = false

	allocator.generations[index] += 1

	// Reserve generation zero as invalid.
	if allocator.generations[index] == 0 {
		allocator.generations[index] = 1
	}

	allocator.free_indices[allocator.free_count] = handle.index
	allocator.free_count += 1
}

bindless_retire :: proc(ctx: ^Context, handle: Bindless_Handle, retire_value: u64) -> bool {
	if !bindless_handle_matches(ctx, handle) {
		return false
	}

	binding := bindless_binding(handle.kind)
	allocator := &ctx.bindless.allocators[binding]

	index := int(handle.index)

	// Already waiting for the GPU.
	if allocator.retiring[index] {
		return false
	}

	if ctx.bindless.deferred_free_count >= MAX_BINDLESS_RESOURCES {
		// This should be impossible if the allocator invariants hold.
		fmt.panicf("bindless deferred free queue overflow")
	}

	allocator.retiring[index] = true

	queue_index := ctx.bindless.deferred_free_count

	ctx.bindless.deferred_frees[queue_index] = Deferred_Bindless_Free {
		handle       = handle,
		retire_value = retire_value,
	}

	ctx.bindless.deferred_free_count += 1

	return true
}

bindless_retire_submitted :: proc(ctx: ^Context, handle: Bindless_Handle) -> bool {
	return bindless_retire(ctx, handle, ctx.timeline_value)
}

get_completed_timeline_value :: proc(ctx: ^Context) -> u64 {
	value: u64

	if res := vk.GetSemaphoreCounterValue(ctx.device, ctx.timeline_semaphore, &value);
	   res != .SUCCESS {
		fmt.panicf("vkGetSemaphoreCounterValue failed: %v", res)
	}

	return value
}

collect_bindless_retirements :: proc(ctx: ^Context) {
	if ctx.bindless.deferred_free_count == 0 {
		return
	}

	completed_value := get_completed_timeline_value(ctx)

	i := 0

	for i < int(ctx.bindless.deferred_free_count) {
		deferred := ctx.bindless.deferred_frees[i]

		if deferred.retire_value > completed_value {
			i += 1
			continue
		}

		bindless_free_completed(ctx, deferred.handle)

		last_index := int(ctx.bindless.deferred_free_count) - 1

		if i != last_index {
			ctx.bindless.deferred_frees[i] = ctx.bindless.deferred_frees[last_index]
		}

		ctx.bindless.deferred_free_count -= 1
	}
}

create_bindless_descriptor_set :: proc(ctx: ^Context) {
	pool_sizes := []vk.DescriptorPoolSize {
		{type = .SAMPLER, descriptorCount = MAX_BINDLESS_ARRAY_SIZE * 3},
		{type = .SAMPLED_IMAGE, descriptorCount = MAX_BINDLESS_ARRAY_SIZE * 3},
		{type = .STORAGE_IMAGE, descriptorCount = MAX_BINDLESS_ARRAY_SIZE * 2},
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = 1,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}

	if res := vk.CreateDescriptorPool(ctx.device, &pool_info, nil, &ctx.bindless.pool);
	   res != .SUCCESS {
		delete(ctx.bindless.deferred_frees)
		delete(ctx.bindless.allocators)
		ctx.bindless.deferred_frees = nil
		ctx.bindless.allocators = nil

		fmt.panicf("failed to create bindless descriptor pool: %v", res)
	}

	allocate_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = ctx.bindless.pool,
		descriptorSetCount = 1,
		pSetLayouts        = &ctx.bindless_descriptor_set_layout,
	}

	if res := vk.AllocateDescriptorSets(ctx.device, &allocate_info, &ctx.bindless.set);
	   res != .SUCCESS {
		vk.DestroyDescriptorPool(ctx.device, ctx.bindless.pool, nil)

		delete(ctx.bindless.deferred_frees)
		delete(ctx.bindless.allocators)

		ctx.bindless.pool = {}
		ctx.bindless.deferred_frees = nil
		ctx.bindless.allocators = nil

		fmt.panicf("failed to allocate bindless descriptor set: %v", res)
	}

	ctx.bindless.allocators = make([]Bindless_Slot_Allocator, BINDLESS_BINDING_COUNT)

	ctx.bindless.deferred_frees = make([]Deferred_Bindless_Free, MAX_BINDLESS_RESOURCES)

	for &allocator in ctx.bindless.allocators {
		bindless_slot_allocator_init(&allocator)
	}
}

destroy_bindless_descriptor_set :: proc(ctx: ^Context) {
	if ctx.bindless.pool != {} {
		vk.DestroyDescriptorPool(ctx.device, ctx.bindless.pool, nil)
	}

	delete(ctx.bindless.deferred_frees)
	delete(ctx.bindless.allocators)

	ctx.bindless = {}
}

bindless_allocate_sampled_image :: proc(
	ctx: ^Context,
	kind: Bindless_Resource_Kind,
	image_view: vk.ImageView,
	image_layout: vk.ImageLayout = .SHADER_READ_ONLY_OPTIMAL,
) -> (
	Bindless_Handle,
	bool,
) {
	assert(kind == .TEXTURE_2D || kind == .TEXTURE_3D)

	handle, ok := bindless_allocate_slot(ctx, kind)
	if !ok {
		return {}, false
	}

	image_info := vk.DescriptorImageInfo {
		sampler     = {},
		imageView   = image_view,
		imageLayout = image_layout,
	}

	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = ctx.bindless.set,
		dstBinding      = bindless_binding(kind),
		dstArrayElement = handle.index,
		descriptorCount = 1,
		descriptorType  = .SAMPLED_IMAGE,
		pImageInfo      = &image_info,
	}

	vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)

	return handle, true
}
bindless_allocate_storage_image :: proc(
	ctx: ^Context,
	kind: Bindless_Resource_Kind,
	image_view: vk.ImageView,
) -> (
	Bindless_Handle,
	bool,
) {
	assert(kind == .STORAGE_IMAGE_2D || kind == .STORAGE_IMAGE_3D)

	handle, ok := bindless_allocate_slot(ctx, kind)
	if !ok {
		return {}, false
	}

	image_info := vk.DescriptorImageInfo {
		sampler     = {},
		imageView   = image_view,
		imageLayout = .GENERAL,
	}

	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = ctx.bindless.set,
		dstBinding      = bindless_binding(kind),
		dstArrayElement = handle.index,
		descriptorCount = 1,
		descriptorType  = .STORAGE_IMAGE,
		pImageInfo      = &image_info,
	}

	vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)

	return handle, true
}
bindless_allocate_sampler :: proc(
	ctx: ^Context,
	kind: Bindless_Resource_Kind,
	sampler: vk.Sampler,
) -> (
	Bindless_Handle,
	bool,
) {
	assert(kind == .SAMPLER_2D || kind == .SAMPLER_3D)

	handle, ok := bindless_allocate_slot(ctx, kind)
	if !ok {
		return {}, false
	}

	image_info := vk.DescriptorImageInfo {
		sampler     = sampler,
		imageView   = {},
		imageLayout = .UNDEFINED,
	}

	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = ctx.bindless.set,
		dstBinding      = bindless_binding(kind),
		dstArrayElement = handle.index,
		descriptorCount = 1,
		descriptorType  = .SAMPLER,
		pImageInfo      = &image_info,
	}

	vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)

	return handle, true
}
bindless_allocate_texture_2d :: proc(
	ctx: ^Context,
	image_view: vk.ImageView,
	image_layout: vk.ImageLayout = .SHADER_READ_ONLY_OPTIMAL,
) -> (
	Bindless_Handle,
	bool,
) {
	return bindless_allocate_sampled_image(ctx, .TEXTURE_2D, image_view, image_layout)
}

bindless_allocate_texture_3d :: proc(
	ctx: ^Context,
	image_view: vk.ImageView,
	image_layout: vk.ImageLayout = .SHADER_READ_ONLY_OPTIMAL,
) -> (
	Bindless_Handle,
	bool,
) {
	return bindless_allocate_sampled_image(ctx, .TEXTURE_3D, image_view, image_layout)
}

bindless_allocate_storage_image_2d :: proc(
	ctx: ^Context,
	image_view: vk.ImageView,
) -> (
	Bindless_Handle,
	bool,
) {
	return bindless_allocate_storage_image(ctx, .STORAGE_IMAGE_2D, image_view)
}

bindless_allocate_storage_image_3d :: proc(
	ctx: ^Context,
	image_view: vk.ImageView,
) -> (
	Bindless_Handle,
	bool,
) {
	return bindless_allocate_storage_image(ctx, .STORAGE_IMAGE_3D, image_view)
}

bindless_allocate_sampler_internal :: proc(
	ctx: ^Context,
	kind: Bindless_Resource_Kind,
	sampler: vk.Sampler,
) -> (
	Bindless_Handle,
	bool,
) {
	assert(kind == .SAMPLER_2D || kind == .SAMPLER_3D || kind == .COMPARISON_SAMPLER)

	handle, ok := bindless_allocate_slot(ctx, kind)
	if !ok {
		return {}, false
	}

	image_info := vk.DescriptorImageInfo {
		sampler     = sampler,
		imageView   = {},
		imageLayout = .UNDEFINED,
	}

	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = ctx.bindless.set,
		dstBinding      = bindless_binding(kind),
		dstArrayElement = handle.index,
		descriptorCount = 1,
		descriptorType  = .SAMPLER,
		pImageInfo      = &image_info,
	}

	vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)

	return handle, true
}

bindless_allocate_sampler_2d :: proc(
	ctx: ^Context,
	sampler: vk.Sampler,
) -> (
	Bindless_Handle,
	bool,
) {
	return bindless_allocate_sampler_internal(ctx, .SAMPLER_2D, sampler)
}

bindless_allocate_sampler_3d :: proc(
	ctx: ^Context,
	sampler: vk.Sampler,
) -> (
	Bindless_Handle,
	bool,
) {
	return bindless_allocate_sampler_internal(ctx, .SAMPLER_3D, sampler)
}

bindless_allocate_comparison_sampler :: proc(
	ctx: ^Context,
	sampler: vk.Sampler,
) -> (
	Bindless_Handle,
	bool,
) {
	return bindless_allocate_sampler_internal(ctx, .COMPARISON_SAMPLER, sampler)
}

bindless_allocate_depth_texture_2d :: proc(
	ctx: ^Context,
	image_view: vk.ImageView,
	image_layout: vk.ImageLayout = .DEPTH_READ_ONLY_OPTIMAL,
) -> (
	Bindless_Handle,
	bool,
) {
	handle, ok := bindless_allocate_slot(ctx, .TEXTURE_2D_DEPTH)
	if !ok {
		return {}, false
	}

	image_info := vk.DescriptorImageInfo {
		sampler     = {},
		imageView   = image_view,
		imageLayout = image_layout,
	}

	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = ctx.bindless.set,
		dstBinding      = bindless_binding(.TEXTURE_2D_DEPTH),
		dstArrayElement = handle.index,
		descriptorCount = 1,
		descriptorType  = .SAMPLED_IMAGE,
		pImageInfo      = &image_info,
	}

	vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)

	return handle, true
}
