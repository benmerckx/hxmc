package hxmc.physics;

import hxmc.gfx.shader.Vec3;

// A body's shape, in the body's frame (centred on its position, turned by
// its orientation): a sphere of a radius, a box of half extents, a capsule
// (the points within radius of the segment from -half to +half along the
// body's y: characters), or a plane (static only) of points p with
// normal . p = offset, in the world.
enum Shape {
	Sphere(radius:Float);
	Box(half:Vec3);
	Capsule(radius:Float, half:Float);
	Plane(normal:Vec3, offset:Float);
}
