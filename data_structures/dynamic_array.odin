package data_structures

import "base:runtime"
import "core:fmt"

Dynamic_Array :: struct($T: typeid) {
	data:     ^T,
	length:   int,
	capacity: int,
    allocator: runtime.Allocator,

}

calloc :: proc(
	arr: ^Dynamic_Array($T),
	capacity: int,
) -> bool {
	if capacity <= 0 {
		arr^ = {}
		return true
	}

	ctx := runtime.default_context()
	arr.allocator = ctx.allocator

	byte_count := capacity * size_of(T)

	memory, err := arr.allocator.procedure(
		arr.allocator.data,
		.Alloc,
		byte_count,
		align_of(T),
		nil,
		0,
	)

	if err != .None || memory == nil {
		return false
	}

	arr.data = cast(^T)raw_data(memory)
	arr.length = 0
	arr.capacity = capacity

	return true
}

realloc :: proc(
	arr: ^Dynamic_Array($T),
	new_capacity: int,
) -> bool {
	if new_capacity < 0 {
		return false
	}

	if new_capacity == arr.capacity {
		return true
	}

	ctx := runtime.default_context()

	// realloc(ptr, 0) semantics: release the allocation.
	if new_capacity == 0 {
		if arr.data != nil {
			_, err := arr.allocator.procedure(
				arr.allocator.data,
				.Free,
				0,
				align_of(T),
				arr.data,
				arr.capacity * size_of(T),
			)

			if err != .None {
				return false
			}
		}

		arr^ = {}
		return true
	}

	old_size := arr.capacity * size_of(T)
	new_size := new_capacity * size_of(T)

	memory, err := arr.allocator.procedure(
		arr.allocator.data,
		.Resize_Non_Zeroed,
		new_size,
		align_of(T),
		arr.data,
		old_size,
	)

	if err != .None || memory == nil {
		// Just like C realloc: leave the original allocation alone
		// when allocation fails.
		return false
	}

	arr.data = cast(^T)raw_data(memory)
	arr.capacity = new_capacity

	if arr.length > new_capacity {
		arr.length = new_capacity
	}

	return true
}

destroy :: proc(arr: ^Dynamic_Array($T)) {
	if arr.data == nil {
		return
	}

	fmt.eprintln("destroying dynamic array")

	arr.allocator.procedure(
		arr.allocator.data,
		.Free,
		0,
		align_of(T),
		arr.data,
		arr.capacity * size_of(T),
	)

	arr^ = {}
}

reserve :: proc(
	arr: ^Dynamic_Array($T),
	min_capacity: int,
) -> bool {
	if min_capacity <= arr.capacity {
		return true
	}

	new_capacity := arr.capacity

	if new_capacity == 0 {
		new_capacity = 8
	}

	for new_capacity < min_capacity {
		new_capacity *= 2
	}

	return realloc(arr, new_capacity)
}

append :: proc(
	arr: ^Dynamic_Array($T),
	value: T,
) -> bool {
	if arr.length == arr.capacity {
		new_capacity := 8
		if arr.capacity != 0 {
			new_capacity = arr.capacity * 2
		}

		if !realloc(arr, new_capacity) {
			return false
		}
	}

	data := cast([^]T)arr.data
	data[arr.length] = value
	arr.length += 1

	return true
}

pop :: proc(
	arr: ^Dynamic_Array($T),
) -> (value: T, ok: bool) {
	if arr.length == 0 {
		return {}, false
	}

	arr.length -= 1

	data := cast([^]T)arr.data
	value = data[arr.length]

	return value, true
}

get :: proc(
	arr: ^Dynamic_Array($T),
	index: int,
) -> (^T, bool) {
	if index < 0 || index >= arr.length {
		return nil, false
	}

	data := cast([^]T)arr.data
	return &data[index], true
}

slice :: proc(arr: ^Dynamic_Array($T)) -> []T {
	if arr.data == nil || arr.length == 0 {
		return nil
	}

	return (cast([^]T)arr.data)[:arr.length]
}

// Iteration support for Dynamic_Array

for_each :: proc(arr: ^Dynamic_Array($T), callback: proc(value: T)) {
	data := cast([^]T)arr.data
	for i in 0 ..< arr.length {
		callback(data[i])
	}
}

Dynamic_Array_Iterator :: struct($T: typeid) {
	array: ^Dynamic_Array(T),
	index: int,
}

iterator_make :: proc(
	arr: ^Dynamic_Array($T),
) -> Dynamic_Array_Iterator(T) {
	return {
		array = arr,
		index = 0,
	}
}

iterate :: proc(
	it: ^Dynamic_Array_Iterator($T),
) -> (value: ^T, index: int, ok: bool) {
	if it.index >= it.array.length {
		return nil, 0, false
	}

	index = it.index
	value = &cast([^]T)it.array.data[it.index]

	it.index += 1

	return value, index, true
}
