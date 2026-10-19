package hxmc.scene.math;

import hxmc.gfx.shader.Mat4;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;

// An axis-aligned box, min to max (an empty one: min above max, Aabb.empty),
// immutable as the math types are.
@:structInit final class Aabb {
	public final min:Vec3;
	public final max:Vec3;

	public inline function new(min:Vec3, max:Vec3) {
		this.min = min;
		this.max = max;
	}

	public static function empty():Aabb
		return new Aabb(new Vec3(Math.POSITIVE_INFINITY, Math.POSITIVE_INFINITY, Math.POSITIVE_INFINITY),
			new Vec3(Math.NEGATIVE_INFINITY, Math.NEGATIVE_INFINITY, Math.NEGATIVE_INFINITY));

	// the box around points given as x, y, z triples
	public static function ofPoints(xyz:Array<Float>):Aabb {
		if (xyz.length < 3) return empty();
		var x0 = xyz[0], y0 = xyz[1], z0 = xyz[2], x1 = x0, y1 = y0, z1 = z0;
		var i = 3;
		while (i + 2 < xyz.length) {
			var x = xyz[i], y = xyz[i + 1], z = xyz[i + 2];
			if (x < x0) x0 = x;
			if (x > x1) x1 = x;
			if (y < y0) y0 = y;
			if (y > y1) y1 = y;
			if (z < z0) z0 = z;
			if (z > z1) z1 = z;
			i += 3;
		}
		return new Aabb(new Vec3(x0, y0, z0), new Vec3(x1, y1, z1));
	}

	public inline function isEmpty():Bool
		return min.x > max.x || min.y > max.y || min.z > max.z;

	public inline function center():Vec3
		return (min + max) * 0.5;

	public inline function size():Vec3
		return max - min;

	public function union(b:Aabb):Aabb
		return new Aabb(new Vec3(Math.min(min.x, b.min.x), Math.min(min.y, b.min.y), Math.min(min.z, b.min.z)),
			new Vec3(Math.max(max.x, b.max.x), Math.max(max.y, b.max.y), Math.max(max.z, b.max.z)));

	public function contains(p:Vec3):Bool
		return p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y && p.z >= min.z && p.z <= max.z;

	public function intersects(b:Aabb):Bool
		return min.x <= b.max.x && max.x >= b.min.x && min.y <= b.max.y && max.y >= b.min.y && min.z <= b.max.z && max.z >= b.min.z;

	// the box around this one transformed by m (Arvo's: the centre moved,
	// the extent through the matrix's absolute values)
	public function transform(m:Mat4):Aabb {
		if (isEmpty()) return this;
		var c = center(), e = (max - min) * 0.5;
		var tc = m * new Vec4(c.x, c.y, c.z, 1);
		var ex = Math.abs(m.c0.x) * e.x + Math.abs(m.c1.x) * e.y + Math.abs(m.c2.x) * e.z;
		var ey = Math.abs(m.c0.y) * e.x + Math.abs(m.c1.y) * e.y + Math.abs(m.c2.y) * e.z;
		var ez = Math.abs(m.c0.z) * e.x + Math.abs(m.c1.z) * e.y + Math.abs(m.c2.z) * e.z;
		return new Aabb(new Vec3(tc.x - ex, tc.y - ey, tc.z - ez), new Vec3(tc.x + ex, tc.y + ey, tc.z + ez));
	}

	// the distance along dir (any length: in its units) from origin to the
	// box, 0 from inside; -1 when the ray misses it (the slab test)
	public function ray(origin:Vec3, dir:Vec3):Float {
		var t0 = 0.0, t1 = Math.POSITIVE_INFINITY;
		for (k in 0...3) {
			var o = k == 0 ? origin.x : k == 1 ? origin.y : origin.z;
			var d = k == 0 ? dir.x : k == 1 ? dir.y : dir.z;
			var lo = k == 0 ? min.x : k == 1 ? min.y : min.z;
			var hi = k == 0 ? max.x : k == 1 ? max.y : max.z;
			if (d == 0) {
				if (o < lo || o > hi) return -1;
				continue;
			}
			var a = (lo - o) / d, b = (hi - o) / d;
			if (a > b) {
				var t = a;
				a = b;
				b = t;
			}
			if (a > t0) t0 = a;
			if (b < t1) t1 = b;
			if (t0 > t1) return -1;
		}
		return t0;
	}
}
