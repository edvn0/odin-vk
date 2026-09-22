package maths

import maths "core:math/linalg"

Quat :: maths.Quaternionf32;

Vec3 :: maths.Vector3f32;

make_quat_full :: proc(x, y, z, w: f32) -> Quat {
	assert(x >= 0.0 && y >= 0.0 && z >= 0.0 && w >= 0.0);
	return maths.quaternion_from_euler_angles(x, y, z, .XYZ)
}

make_quat :: proc {
	make_quat_full,
}

make_vec3 :: proc(x, y, z: f32) -> Vec3 {
	return Vec3{x, y, z}
}