package main

import "core:fmt"
import "core:os"
import "render"
import vk "vendor:vulkan"

Loaded_Shader :: struct {
	name:   string,
	stage:  vk.ShaderStageFlags,
	handle: render.Shader_Handle,
}

load_spirv_file :: proc(
	ctx: ^render.Context,
	file_name: string,
) -> Loaded_Shader {
	//
	// Expected filename:
	//
	//     <name>.<stage>.spv
	//
	// Examples:
	//
	//     forward.vert.spv
	//     forward.frag.spv
	//     cull.comp.spv
	//

	file := os.base(file_name)

	stem, extension := os.split_filename(file)
	if extension != "spv" {
		fmt.panicf(
			"invalid shader filename '%s': expected <name>.<stage>.spv",
			file_name,
		)
	}

	name, stage_name := os.split_filename(stem)

	if name == "" || stage_name == "" {
		fmt.panicf(
			"invalid shader filename '%s': expected <name>.<stage>.spv",
			file_name,
		)
	}

	stage:      vk.ShaderStageFlags
	next_stage: vk.ShaderStageFlags

	switch stage_name {
	case "vert":
		stage = {.VERTEX}
		next_stage = {.FRAGMENT}

	case "frag":
		stage = {.FRAGMENT}

	case "comp":
		stage = {.COMPUTE}

	case:
		fmt.panicf(
			"invalid shader stage '%s' in '%s': expected vert, frag, or comp",
			stage_name,
			file_name,
		)
	}

	code, err := os.read_entire_file_from_path(
		file_name,
		context.allocator,
	)
	if err != nil {
		fmt.panicf(
			"failed to read SPIR-V '%s': %v",
			file_name,
			err,
		)
	}
	defer delete(code)

	if len(code) == 0 {
		fmt.panicf(
			"SPIR-V file '%s' is empty",
			file_name,
		)
	}

	if len(code) % size_of(u32) != 0 {
		fmt.panicf(
			"invalid SPIR-V file '%s': size %d is not a multiple of 4",
			file_name,
			len(code),
		)
	}

	SPIRV_MAGIC :: u32(0x07230203)
	if len(code) < size_of(u32) ||
	   (^[1]u32)(raw_data(code))[0] != SPIRV_MAGIC {
		fmt.panicf(
			"invalid SPIR-V file '%s': invalid magic number",
			file_name,
		)
	}

	shader_info := vk.ShaderCreateInfoEXT {
		sType    = .SHADER_CREATE_INFO_EXT,
		stage    = stage,
		nextStage = next_stage,

		codeType = .SPIRV,
		codeSize = len(code),
		pCode    = raw_data(code),
		pName    = "main",

		setLayoutCount = 1,
		pSetLayouts    = &ctx.bindless_descriptor_set_layout,

		pushConstantRangeCount = 1,
		pPushConstantRanges    = &ctx.global_push_constant_range,
	}

	shader: vk.ShaderEXT

	if result := vk.CreateShadersEXT(
		ctx.device,
		1,
		&shader_info,
		nil,
		&shader,
	); result != .SUCCESS {
		fmt.panicf(
			"failed to create shader '%s': %v",
			file_name,
			result,
		)
	}

	handle, add_err := render.resource_try_add(
		&ctx.shader_pool,
		render.Shader {
			object = shader,
			stage  = stage,
		},
	)

	if add_err != nil {
		vk.DestroyShaderEXT(
			ctx.device,
			shader,
			nil,
		)

		fmt.panicf(
			"failed to add shader '%s' to shader pool: %v",
			file_name,
			add_err,
		)
	}

	return Loaded_Shader {
		name   = name,
		stage  = stage,
		handle = handle,
	}
}