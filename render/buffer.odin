package render

import vk "vendor:vulkan"
import fmt "core:fmt"

create_buffer :: proc(
	ctx: ^Context,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags = {.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
) -> Buffer_Handle {
	buffer: Buffer

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
	if buffer.device_address == 0 {
		vk.UnmapMemory(ctx.device, buffer.memory)
		vk.FreeMemory(ctx.device, buffer.memory, nil)
		vk.DestroyBuffer(ctx.device, buffer.object, nil)

		fmt.panicf("failed to get buffer device address")
	}

	return resource_add(&ctx.buffer_pool, buffer)
}