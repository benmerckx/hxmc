package hxmc.scene.math;

import hxmc.gfx.shader.Mat4;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;

// A rotation as a unit quaternion (x, y, z the vector part, w the scalar
// part), an immutable value as gfx's math types are (a @:hxmc.struct value
// on hxmc's targets: copied, never allocated). a * b rotates by b first,
// then by a, as Mat4's product applies its right side first; angles in
// radians, rotations counter-clockwise looking down the axis towards the
// origin (right-handed, as Mat4.rotationX/Y/Z).
@:forward(x, y, z, w)
abstract Quat(QuatData) {
	public inline function new(x:Float, y:Float, z:Float, w:Float)
		this = new QuatData(x, y, z, w);

	public static inline function identity():Quat
		return new Quat(0, 0, 0, 1);

	// a turn by angle about axis (of any length but zero)
	public static function axisAngle(axis:Vec3, angle:Float):Quat {
		var l = Math.sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z);
		var s = Math.sin(angle / 2) / l;
		return new Quat(axis.x * s, axis.y * s, axis.z * s, Math.cos(angle / 2));
	}

	// the turns about x, then y, then z (Mat4.rotationZ(z) * rotationY(y) * rotationX(x))
	public static function fromEuler(x:Float, y:Float, z:Float):Quat
		return axisAngle(new Vec3(0, 0, 1), z) * axisAngle(new Vec3(0, 1, 0), y) * axisAngle(new Vec3(1, 0, 0), x);

	// the rotation of a matrix's upper 3x3 (orthonormal: no scale)
	public static function fromMat4(m:Mat4):Quat {
		var m00 = m.c0.x, m11 = m.c1.y, m22 = m.c2.z, tr = m00 + m11 + m22;
		if (tr > 0) {
			var s = Math.sqrt(tr + 1) * 2;
			return new Quat((m.c1.z - m.c2.y) / s, (m.c2.x - m.c0.z) / s, (m.c0.y - m.c1.x) / s, s / 4);
		}
		if (m00 > m11 && m00 > m22) {
			var s = Math.sqrt(1 + m00 - m11 - m22) * 2;
			return new Quat(s / 4, (m.c1.x + m.c0.y) / s, (m.c2.x + m.c0.z) / s, (m.c1.z - m.c2.y) / s);
		}
		if (m11 > m22) {
			var s = Math.sqrt(1 + m11 - m00 - m22) * 2;
			return new Quat((m.c1.x + m.c0.y) / s, s / 4, (m.c2.y + m.c1.z) / s, (m.c2.x - m.c0.z) / s);
		}
		var s = Math.sqrt(1 + m22 - m00 - m11) * 2;
		return new Quat((m.c2.x + m.c0.z) / s, (m.c2.y + m.c1.z) / s, s / 4, (m.c0.y - m.c1.x) / s);
	}

	@:op(A * B) static inline function mul(a:Quat, b:Quat):Quat
		return new Quat(a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y, a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
			a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w, a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z);

	public inline function dot(b:Quat):Float
		return this.x * b.x + this.y * b.y + this.z * b.z + this.w * b.w;

	public inline function length():Float
		return Math.sqrt(dot(cast this));

	public function normalized():Quat {
		var l = length();
		return l == 0 ? identity() : new Quat(this.x / l, this.y / l, this.z / l, this.w / l);
	}

	// the inverse of a unit quaternion
	public inline function conjugate():Quat
		return new Quat(-this.x, -this.y, -this.z, this.w);

	// v turned (v + 2w(q x v) + 2q x (q x v), q the vector part)
	public function rotate(v:Vec3):Vec3 {
		var tx = 2 * (this.y * v.z - this.z * v.y), ty = 2 * (this.z * v.x - this.x * v.z), tz = 2 * (this.x * v.y - this.y * v.x);
		return new Vec3(v.x + this.w * tx + (this.y * tz - this.z * ty), v.y + this.w * ty + (this.z * tx - this.x * tz),
			v.z + this.w * tz + (this.x * ty - this.y * tx));
	}

	public function toMat4():Mat4 {
		var x = this.x, y = this.y, z = this.z, w = this.w;
		var xx = x * x, yy = y * y, zz = z * z, xy = x * y, xz = x * z, yz = y * z, wx = w * x, wy = w * y, wz = w * z;
		return new Mat4(new Vec4(1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy), 0), new Vec4(2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx), 0),
			new Vec4(2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy), 0), new Vec4(0, 0, 0, 1));
	}

	// from a to b by t along the shorter arc, at a constant speed
	public static function slerp(a:Quat, b:Quat, t:Float):Quat {
		var d = a.dot(b);
		// (the shorter way: q and -q are the same rotation)
		if (d < 0) {
			b = new Quat(-b.x, -b.y, -b.z, -b.w);
			d = -d;
		}
		if (d > 0.9995)
			return new Quat(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t).normalized();
		var th = Math.acos(d), s = Math.sin(th);
		var wa = Math.sin((1 - t) * th) / s, wb = Math.sin(t * th) / s;
		return new Quat(a.x * wa + b.x * wb, a.y * wa + b.y * wb, a.z * wa + b.z * wb, a.w * wa + b.w * wb);
	}

	public inline function toVec4():Vec4
		return new Vec4(this.x, this.y, this.z, this.w);
}

@:hxmc.struct @:noCompletion final class QuatData {
	public final x:Float;
	public final y:Float;
	public final z:Float;
	public final w:Float;

	public inline function new(x:Float, y:Float, z:Float, w:Float) {
		this.x = x;
		this.y = y;
		this.z = z;
		this.w = w;
	}
}
