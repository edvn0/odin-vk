package main

// Compiles every top-level .slang file in ./shaders to SPIR-V via slangc.
// Run with: odin run build_shaders

import "core:fmt"
import "core:os"
import "core:strings"

SHADERS_DIR :: "shaders"
INCLUDE_DIR :: "shaders/include"

main :: proc() {
	entries, dir_err := os.read_all_directory_by_path(SHADERS_DIR, context.allocator)
	if dir_err != nil {
		fmt.eprintfln("failed to read '%s': %v", SHADERS_DIR, dir_err)
		os.exit(1)
	}

	ok := true

	for entry in entries {
		if entry.type != .Regular || os.ext(entry.name) != ".slang" {
			continue
		}

		input := entry.fullpath
		output := strings.concatenate({input[:len(input) - len(".slang")], ".spv"})
		defer delete(output)

		fmt.printfln("compiling %s -> %s", input, output)

		process, start_err := os.process_start(
			{
				command = {
					"slangc",
					"-O3",
					"-g3",
					"-fvk-use-scalar-layout",
					"-I", INCLUDE_DIR,
					"-target", "spirv",
					"-profile", "spirv_1_6",
					input,
					"-o", output,
				},
				stdout = os.stdout,
				stderr = os.stderr,
			},
		)
		if start_err != nil {
			fmt.eprintfln("failed to start slangc for '%s': %v", input, start_err)
			ok = false
			continue
		}

		state, wait_err := os.process_wait(process)
		if wait_err != nil {
			fmt.eprintfln("failed to wait on slangc for '%s': %v", input, wait_err)
			ok = false
			continue
		}

		if !state.success {
			fmt.eprintfln("slangc failed for '%s' (exit code %d)", input, state.exit_code)
			ok = false
		}
	}

	if !ok {
		os.exit(1)
	}
}
