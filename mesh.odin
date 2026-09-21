package main

import "core:bufio"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strconv"
import "core:strings"
import "render"
import vk "vendor:vulkan"

// Compressed vertex, 20 bytes. Must match struct Vertex in
// shaders/mesh_vertex.slang exactly. Every field is a plain u32, so the
// layout is identical under std430 and scalar rules for a raw device
// pointer, and the shader decodes each field with the helpers there.
//
//   position_xy: f16 x (low 16), f16 y (high 16)
//   position_z:  f16 z (low 16), high 16 bits reserved (zero)
//   uv:          f16 u (low 16), f16 v (high 16)
//   normal:      octahedral, snorm16 x (low 16), snorm16 y (high 16)
//   tangent:     octahedral, unorm15 x (bits 0-14), unorm15 y (bits 15-29),
//                bit 31 set = bitangent sign is -1
//
// f16 positions are model-space, so they hold roughly 3 significant digits
// and overflow past +-65504. Fine for Suzanne-sized assets; large meshes
// want meshlet-relative quantization instead.
Mesh_Vertex :: struct {
	position_xy: u32,
	position_z:  u32,
	uv:          u32,
	normal:      u32,
	tangent:     u32,
}

#assert(size_of(Mesh_Vertex) == 20)

// Must match MESHLET_TRIANGLES in shaders/suzanne.mesh.slang.
MESH_MESHLET_TRIANGLES :: 64
MESH_MESHLET_VERTICES :: MESH_MESHLET_TRIANGLES * 3

// Must match TASK_GROUP_MESHLETS in shaders/suzanne.task.slang.
MESH_TASK_GROUP_MESHLETS :: 32

// One per meshlet, read by the task shader to frustum-cull whole meshlets
// before they ever reach the mesh shader. xyz is the model-space center,
// w is the radius.
Meshlet_Bounds :: struct {
	center_and_radius: [4]f32,
}

// ---------------------------------------------------------------------------
// Packing
// ---------------------------------------------------------------------------

pack_half2 :: proc(low, high: f32) -> u32 {
	return u32(transmute(u16)f16(low)) | (u32(transmute(u16)f16(high)) << 16)
}

unpack_half_low :: proc(packed: u32) -> f32 {
	return f32(transmute(f16)u16(packed & 0xFFFF))
}

unpack_half_high :: proc(packed: u32) -> f32 {
	return f32(transmute(f16)u16(packed >> 16))
}

pack_snorm16 :: proc(v: f32) -> u32 {
	return u32(u16(i16(math.round(clamp(v, -1, 1) * 32767))))
}

pack_unorm15 :: proc(v: f32) -> u32 {
	return u32(math.round(clamp(v * 0.5 + 0.5, 0, 1) * 32767))
}

sign_not_zero :: proc(v: f32) -> f32 {
	return v >= 0 ? 1 : -1
}

// Maps a unit vector onto the [-1, 1]^2 octahedral square.
oct_encode :: proc(n: [3]f32) -> [2]f32 {
	l1 := abs(n.x) + abs(n.y) + abs(n.z)
	p := [2]f32{n.x, n.y} / l1

	if n.z < 0 {
		p = {(1 - abs(p.y)) * sign_not_zero(p.x), (1 - abs(p.x)) * sign_not_zero(p.y)}
	}

	return p
}

pack_normal :: proc(n: [3]f32) -> u32 {
	e := oct_encode(n)
	return pack_snorm16(e.x) | (pack_snorm16(e.y) << 16)
}

pack_tangent :: proc(t: [3]f32, handedness: f32) -> u32 {
	e := oct_encode(t)
	packed := pack_unorm15(e.x) | (pack_unorm15(e.y) << 15)
	if handedness < 0 {
		packed |= 1 << 31
	}
	return packed
}

decode_position :: proc(v: Mesh_Vertex) -> [3]f32 {
	return {
		unpack_half_low(v.position_xy),
		unpack_half_high(v.position_xy),
		unpack_half_low(v.position_z),
	}
}

// ---------------------------------------------------------------------------
// Meshlet bounds
// ---------------------------------------------------------------------------

// Bounds are built from the decoded f16 positions, so culling matches
// exactly what the mesh shader will see.
compute_meshlet_bounds :: proc(
	vertices: []Mesh_Vertex,
	meshlet_count: u32,
	allocator := context.allocator,
) -> []Meshlet_Bounds {
	bounds := make([]Meshlet_Bounds, meshlet_count, allocator)

	for m in 0 ..< meshlet_count {
		lo := int(m) * MESH_MESHLET_VERTICES
		hi := min(lo + MESH_MESHLET_VERTICES, len(vertices))
		meshlet_verts := vertices[lo:hi]

		center: [3]f32
		for v in meshlet_verts {
			center += decode_position(v)
		}
		center /= f32(len(meshlet_verts))

		radius_sq: f32 = 0
		for v in meshlet_verts {
			d := decode_position(v) - center
			radius_sq = max(radius_sq, linalg.dot(d, d))
		}

		bounds[m] = Meshlet_Bounds {
			center_and_radius = {center.x, center.y, center.z, math.sqrt(radius_sq)},
		}
	}

	return bounds
}

// ---------------------------------------------------------------------------
// OBJ parsing (streamed line by line)
// ---------------------------------------------------------------------------

// Zero-based indices into Obj_Mesh arrays; -1 means absent.
Obj_Corner :: struct {
	position_index: i32,
	texcoord_index: i32,
	normal_index:   i32,
}

Obj_Mesh :: struct {
	positions:        [dynamic][3]f32,
	normals:          [dynamic][3]f32,
	texcoords:        [dynamic][2]f32,
	triangle_corners: [dynamic]Obj_Corner, // three per triangle
}

parse_next_f32 :: proc(it: ^string) -> f32 {
	token, ok := strings.fields_iterator(it)
	if !ok {
		return 0
	}
	return f32(strconv.parse_f64(token) or_else 0)
}

// OBJ indices are 1-based; negative values are relative to the end of the
// list as it stands when the face is read.
resolve_obj_index :: proc(token: string, count: int) -> i32 {
	if len(token) == 0 {
		return -1
	}

	raw := strconv.parse_int(token) or_else 0
	switch {
	case raw > 0:
		return i32(raw - 1)
	case raw < 0:
		return i32(count + raw)
	}
	return -1
}

// Face corners are "position/texcoord/normal"; texcoord and normal may be
// absent ("1", "1/2", "1//3").
parse_obj_corner :: proc(token: string, mesh: ^Obj_Mesh) -> Obj_Corner {
	rest := token
	position_str, _ := strings.split_iterator(&rest, "/")
	texcoord_str, _ := strings.split_iterator(&rest, "/")
	normal_str, _ := strings.split_iterator(&rest, "/")

	return Obj_Corner {
		position_index = resolve_obj_index(position_str, len(mesh.positions)),
		texcoord_index = resolve_obj_index(texcoord_str, len(mesh.texcoords)),
		normal_index = resolve_obj_index(normal_str, len(mesh.normals)),
	}
}

validate_obj_corner :: proc(c: Obj_Corner, mesh: ^Obj_Mesh, path: string, line_number: int) {
	if c.position_index < 0 || int(c.position_index) >= len(mesh.positions) {
		fmt.panicf("%s:%d: face position index out of range", path, line_number)
	}
	if c.texcoord_index >= 0 && int(c.texcoord_index) >= len(mesh.texcoords) {
		fmt.panicf("%s:%d: face texcoord index out of range", path, line_number)
	}
	if c.normal_index >= 0 && int(c.normal_index) >= len(mesh.normals) {
		fmt.panicf("%s:%d: face normal index out of range", path, line_number)
	}
}

// Parses v, vt, vn, and f (n-gons are fan-triangulated). Everything else
// is ignored. The file is streamed through a bufio.Scanner, so only one
// line of raw text is held at a time.
parse_obj :: proc(path: string, allocator := context.allocator) -> Obj_Mesh {
	file, open_err := os.open(path)
	if open_err != nil {
		fmt.panicf("failed to open OBJ file '%s': %v", path, open_err)
	}
	defer os.close(file)

	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, os.to_stream(file), context.temp_allocator)
	defer bufio.scanner_destroy(&scanner)

	mesh := Obj_Mesh {
		positions        = make([dynamic][3]f32, allocator),
		normals          = make([dynamic][3]f32, allocator),
		texcoords        = make([dynamic][2]f32, allocator),
		triangle_corners = make([dynamic]Obj_Corner, allocator),
	}

	face := make([dynamic]Obj_Corner, context.temp_allocator)
	line_number := 0

	for bufio.scan(&scanner) {
		line_number += 1

		// Only valid until the next scan; everything is parsed immediately.
		it := bufio.scanner_text(&scanner)

		kind, has_kind := strings.fields_iterator(&it)
		if !has_kind {
			continue
		}

		switch kind {
		case "v":
			x := parse_next_f32(&it)
			y := parse_next_f32(&it)
			z := parse_next_f32(&it)
			append(&mesh.positions, [3]f32{x, y, z})

		case "vn":
			x := parse_next_f32(&it)
			y := parse_next_f32(&it)
			z := parse_next_f32(&it)
			append(&mesh.normals, [3]f32{x, y, z})

		case "vt":
			u := parse_next_f32(&it)
			v := parse_next_f32(&it)
			append(&mesh.texcoords, [2]f32{u, v})

		case "f":
			clear(&face)

			for token in strings.fields_iterator(&it) {
				corner := parse_obj_corner(token, &mesh)
				validate_obj_corner(corner, &mesh, path, line_number)
				append(&face, corner)
			}

			if len(face) < 3 {
				fmt.panicf("%s:%d: face has fewer than 3 corners", path, line_number)
			}

			for i in 1 ..< len(face) - 1 {
				append(&mesh.triangle_corners, face[0], face[i], face[i + 1])
			}
		}
	}

	if scan_err := bufio.scanner_error(&scanner); scan_err != nil {
		fmt.panicf("error reading OBJ file '%s': %v", path, scan_err)
	}

	return mesh
}

// ---------------------------------------------------------------------------
// Tangent frames + vertex compression
// ---------------------------------------------------------------------------

corner_uv :: proc(mesh: ^Obj_Mesh, c: Obj_Corner) -> [2]f32 {
	return c.texcoord_index >= 0 ? mesh.texcoords[c.texcoord_index] : [2]f32{0, 0}
}

any_perpendicular :: proc(n: [3]f32) -> [3]f32 {
	axis := abs(n.x) < 0.9 ? [3]f32{1, 0, 0} : [3]f32{0, 1, 0}
	return linalg.normalize(linalg.cross(n, axis))
}

// Builds a flat, non-indexed triangle list of compressed vertices.
//
// Tangents are accumulated per unique OBJ corner (position/texcoord/normal
// triple), so they are smooth across triangles that share a corner and
// split along UV seams and hard edges, the same places the OBJ splits.
// Corners with no normal get an area-weighted smooth normal instead.
build_mesh_vertices :: proc(mesh: ^Obj_Mesh, allocator := context.allocator) -> []Mesh_Vertex {
	corner_count := len(mesh.triangle_corners)

	// Deduplicate corners into slots.
	slot_of := make(map[Obj_Corner]u32, allocator = context.temp_allocator)
	corner_slots := make([]u32, corner_count, context.temp_allocator)
	slot_keys := make([dynamic]Obj_Corner, context.temp_allocator)

	for c, i in mesh.triangle_corners {
		slot, found := slot_of[c]
		if !found {
			slot = u32(len(slot_keys))
			slot_of[c] = slot
			append(&slot_keys, c)
		}
		corner_slots[i] = slot
	}

	slot_count := len(slot_keys)
	normal_accum := make([][3]f32, slot_count, context.temp_allocator)
	tangent_accum := make([][3]f32, slot_count, context.temp_allocator)
	bitangent_accum := make([][3]f32, slot_count, context.temp_allocator)

	// Per-triangle tangent/bitangent from the UV gradient.
	for tri := 0; tri < corner_count; tri += 3 {
		c0 := mesh.triangle_corners[tri]
		c1 := mesh.triangle_corners[tri + 1]
		c2 := mesh.triangle_corners[tri + 2]

		p0 := mesh.positions[c0.position_index]
		e1 := mesh.positions[c1.position_index] - p0
		e2 := mesh.positions[c2.position_index] - p0

		// Unnormalized, so larger triangles weigh more.
		face_normal := linalg.cross(e1, e2)

		uv0 := corner_uv(mesh, c0)
		d1 := corner_uv(mesh, c1) - uv0
		d2 := corner_uv(mesh, c2) - uv0

		tangent, bitangent: [3]f32
		det := d1.x * d2.y - d2.x * d1.y
		if abs(det) > 1e-12 {
			r := 1 / det
			tangent = (e1 * d2.y - e2 * d1.y) * r
			bitangent = (e2 * d1.x - e1 * d2.x) * r
		}

		for k in 0 ..< 3 {
			s := corner_slots[tri + k]
			normal_accum[s] += face_normal
			tangent_accum[s] += tangent
			bitangent_accum[s] += bitangent
		}
	}

	// Orthonormalize per slot and pack.
	packed_normals := make([]u32, slot_count, context.temp_allocator)
	packed_tangents := make([]u32, slot_count, context.temp_allocator)

	for key, s in slot_keys {
		n := key.normal_index >= 0 ? mesh.normals[key.normal_index] : normal_accum[s]
		n = linalg.normalize0(n)
		if n == ([3]f32{}) {
			n = {0, 0, 1}
		}

		// Gram-Schmidt against the normal.
		t := tangent_accum[s]
		t -= n * linalg.dot(n, t)
		if linalg.dot(t, t) < 1e-12 {
			t = any_perpendicular(n)
		} else {
			t = linalg.normalize(t)
		}

		handedness: f32 = linalg.dot(linalg.cross(n, t), bitangent_accum[s]) < 0 ? -1 : 1

		packed_normals[s] = pack_normal(n)
		packed_tangents[s] = pack_tangent(t, handedness)
	}

	vertices := make([]Mesh_Vertex, corner_count, allocator)

	for c, i in mesh.triangle_corners {
		s := corner_slots[i]
		p := mesh.positions[c.position_index]
		uv := corner_uv(mesh, c)

		vertices[i] = Mesh_Vertex {
			position_xy = pack_half2(p.x, p.y),
			position_z  = pack_half2(p.z, 0),
			uv          = pack_half2(uv.x, uv.y),
			normal      = packed_normals[s],
			tangent     = packed_tangents[s],
		}
	}

	return vertices
}

// ---------------------------------------------------------------------------
// GPU upload
// ---------------------------------------------------------------------------

init_mesh :: proc(ctx: ^render.Context, obj_path: string) {
	obj := parse_obj(obj_path, context.temp_allocator)
	vertices := build_mesh_vertices(&obj, context.temp_allocator)
	vertex_count := u32(len(vertices))

	if vertex_count == 0 || vertex_count % 3 != 0 {
		fmt.panicf("mesh '%s' did not produce a whole number of triangles", obj_path)
	}

	size := vk.DeviceSize(vertex_count) * size_of(Mesh_Vertex)
	handle := create_buffer(ctx, size, {.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS})

	buffer, found := render.resource_try_get(&ctx.buffer_pool, handle)
	if !found {
		fmt.panicf("failed to get freshly created mesh vertex buffer")
	}

	dst := ([^]Mesh_Vertex)(buffer.mapped)
	copy(dst[:vertex_count], vertices)

	meshlet_count := (vertex_count + MESH_MESHLET_VERTICES - 1) / MESH_MESHLET_VERTICES

	bounds := compute_meshlet_bounds(vertices, meshlet_count, context.temp_allocator)

	bounds_size := vk.DeviceSize(meshlet_count) * size_of(Meshlet_Bounds)
	bounds_handle := create_buffer(ctx, bounds_size, {.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS})

	bounds_buffer, bounds_found := render.resource_try_get(&ctx.buffer_pool, bounds_handle)
	if !bounds_found {
		fmt.panicf("failed to get freshly created meshlet bounds buffer")
	}

	bounds_dst := ([^]Meshlet_Bounds)(bounds_buffer.mapped)
	copy(bounds_dst[:meshlet_count], bounds)

	ctx.mesh = render.Mesh {
		vertex_buffer = handle,
		vertex_count  = vertex_count,
		meshlet_count = meshlet_count,
		bounds_buffer = bounds_handle,
	}

	fmt.printfln(
		"Loaded mesh '%s': %d triangles, %d meshlets, %d bytes of vertex data",
		obj_path,
		vertex_count / 3,
		ctx.mesh.meshlet_count,
		int(size),
	)
}
