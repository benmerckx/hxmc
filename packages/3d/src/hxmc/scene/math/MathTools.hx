package hxmc.scene.math;

import hxmc.gfx.shader.Mat4;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;

// What the scene needs of gfx's Mat4 and Vec3 beyond the shaders' builtins,
// as a static extension (using hxmc.scene.math.MathTools): one set of math
// types for the CPU and the GPU, these functions on top. Matrices are
// gfx's: columns c0..c3, m * v transforms a column vector, a * b applies b
// first, right-handed (a camera looks down -z).
class MathTools {
	// the translation t, then the rotation r, then the scale s (applied to a
	// point: scaled, turned, moved), as glTF's TRS
	public static function compose(t:Vec3, r:Quat, s:Vec3):Mat4 {
		var m = r.toMat4();
		return new Mat4(m.c0 * s.x, m.c1 * s.y, m.c2 * s.z, new Vec4(t.x, t.y, t.z, 1));
	}

	// the translation, rotation and scale of an affine matrix (compose's
	// inverse; a negative determinant puts the reflection in x's scale)
	public static function decompose(m:Mat4):{t:Vec3, r:Quat, s:Vec3} {
		var sx = len3(m.c0), sy = len3(m.c1), sz = len3(m.c2);
		if (determinant(m) < 0) sx = -sx;
		var r = Quat.fromMat4(new Mat4(m.c0 / sx, m.c1 / sy, m.c2 / sz, new Vec4(0, 0, 0, 1)));
		return {t: new Vec3(m.c3.x, m.c3.y, m.c3.z), r: r.normalized(), s: new Vec3(sx, sy, sz)};
	}

	static inline function len3(v:Vec4):Float
		return Math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);

	public static function transpose(m:Mat4):Mat4
		return new Mat4(new Vec4(m.c0.x, m.c1.x, m.c2.x, m.c3.x), new Vec4(m.c0.y, m.c1.y, m.c2.y, m.c3.y), new Vec4(m.c0.z, m.c1.z, m.c2.z, m.c3.z),
			new Vec4(m.c0.w, m.c1.w, m.c2.w, m.c3.w));

	public static function determinant(m:Mat4):Float {
		var a = m.c0, b = m.c1, c = m.c2, d = m.c3;
		var s0 = a.x * b.y - b.x * a.y, s1 = a.x * c.y - c.x * a.y, s2 = a.x * d.y - d.x * a.y;
		var s3 = b.x * c.y - c.x * b.y, s4 = b.x * d.y - d.x * b.y, s5 = c.x * d.y - d.x * c.y;
		var c5 = c.z * d.w - d.z * c.w, c4 = b.z * d.w - d.z * b.w, c3 = b.z * c.w - c.z * b.w;
		var c2 = a.z * d.w - d.z * a.w, c1 = a.z * c.w - c.z * a.w, c0 = a.z * b.w - b.z * a.w;
		return s0 * c5 - s1 * c4 + s2 * c3 + s3 * c2 - s4 * c1 + s5 * c0;
	}

	// the inverse (by cofactors); a singular matrix gives the identity
	public static function inverse(m:Mat4):Mat4 {
		// (rows i, columns j: m.cj's component i)
		var a00 = m.c0.x, a10 = m.c0.y, a20 = m.c0.z, a30 = m.c0.w;
		var a01 = m.c1.x, a11 = m.c1.y, a21 = m.c1.z, a31 = m.c1.w;
		var a02 = m.c2.x, a12 = m.c2.y, a22 = m.c2.z, a32 = m.c2.w;
		var a03 = m.c3.x, a13 = m.c3.y, a23 = m.c3.z, a33 = m.c3.w;
		var b00 = a00 * a11 - a01 * a10, b01 = a00 * a12 - a02 * a10, b02 = a00 * a13 - a03 * a10;
		var b03 = a01 * a12 - a02 * a11, b04 = a01 * a13 - a03 * a11, b05 = a02 * a13 - a03 * a12;
		var b06 = a20 * a31 - a21 * a30, b07 = a20 * a32 - a22 * a30, b08 = a20 * a33 - a23 * a30;
		var b09 = a21 * a32 - a22 * a31, b10 = a21 * a33 - a23 * a31, b11 = a22 * a33 - a23 * a32;
		var det = b00 * b11 - b01 * b10 + b02 * b09 + b03 * b08 - b04 * b07 + b05 * b06;
		if (det == 0) return Mat4.identity();
		var k = 1 / det;
		// (the inverse's row i, column j)
		var i00 = (a11 * b11 - a12 * b10 + a13 * b09) * k, i01 = (a02 * b10 - a01 * b11 - a03 * b09) * k;
		var i02 = (a31 * b05 - a32 * b04 + a33 * b03) * k, i03 = (a22 * b04 - a21 * b05 - a23 * b03) * k;
		var i10 = (a12 * b08 - a10 * b11 - a13 * b07) * k, i11 = (a00 * b11 - a02 * b08 + a03 * b07) * k;
		var i12 = (a32 * b02 - a30 * b05 - a33 * b01) * k, i13 = (a20 * b05 - a22 * b02 + a23 * b01) * k;
		var i20 = (a10 * b10 - a11 * b08 + a13 * b06) * k, i21 = (a01 * b08 - a00 * b10 - a03 * b06) * k;
		var i22 = (a30 * b04 - a31 * b02 + a33 * b00) * k, i23 = (a21 * b02 - a20 * b04 - a23 * b00) * k;
		var i30 = (a11 * b07 - a10 * b09 - a12 * b06) * k, i31 = (a00 * b09 - a01 * b07 + a02 * b06) * k;
		var i32 = (a31 * b01 - a30 * b03 - a32 * b00) * k, i33 = (a20 * b03 - a21 * b01 + a22 * b00) * k;
		return new Mat4(new Vec4(i00, i10, i20, i30), new Vec4(i01, i11, i21, i31), new Vec4(i02, i12, i22, i32), new Vec4(i03, i13, i23, i33));
	}

	// a view matrix: the camera at eye looking at target, up roughly up
	public static function lookAt(eye:Vec3, target:Vec3, up:Vec3):Mat4 {
		var f = norm(target - eye);
		var s = norm(cross3(f, up));
		var u = cross3(s, f);
		return new Mat4(new Vec4(s.x, u.x, -f.x, 0), new Vec4(s.y, u.y, -f.y, 0), new Vec4(s.z, u.z, -f.z, 0),
			new Vec4(-dot3(s, eye), -dot3(u, eye), dot3(f, eye), 1));
	}

	// the rotation that turns -z towards dir, +y as near up as it can
	public static function lookRotation(dir:Vec3, up:Vec3):Quat {
		var f = norm(dir);
		var s = norm(cross3(f, up));
		var u = cross3(s, f);
		return Quat.fromMat4(new Mat4(new Vec4(s.x, s.y, s.z, 0), new Vec4(u.x, u.y, u.z, 0), new Vec4(-f.x, -f.y, -f.z, 0), new Vec4(0, 0, 0, 1)));
	}

	public static inline function transformPoint(m:Mat4, p:Vec3):Vec3 {
		var v = m * new Vec4(p.x, p.y, p.z, 1);
		return new Vec3(v.x / v.w, v.y / v.w, v.z / v.w);
	}

	public static inline function transformDir(m:Mat4, d:Vec3):Vec3 {
		var v = m * new Vec4(d.x, d.y, d.z, 0);
		return new Vec3(v.x, v.y, v.z);
	}

	// the matrix for normals: the inverse transpose (its translation dropped)
	public static function normalMatrix(m:Mat4):Mat4 {
		var n = transpose(inverse(m));
		return new Mat4(new Vec4(n.c0.x, n.c0.y, n.c0.z, 0), new Vec4(n.c1.x, n.c1.y, n.c1.z, 0), new Vec4(n.c2.x, n.c2.y, n.c2.z, 0),
			new Vec4(0, 0, 0, 1));
	}

	// (the shaders' builtins for Vec3, here without ShaderMath's overloads)
	static inline function dot3(a:Vec3, b:Vec3):Float
		return a.x * b.x + a.y * b.y + a.z * b.z;

	static inline function cross3(a:Vec3, b:Vec3):Vec3
		return new Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);

	static inline function norm(a:Vec3):Vec3
		return a / Math.sqrt(dot3(a, a));

	// whether two matrices agree to eps in every element (tests, caches)
	public static function near(a:Mat4, b:Mat4, eps = 1e-9):Bool {
		for (k in 0...4) {
			var x = col(a, k), y = col(b, k);
			if (Math.abs(x.x - y.x) > eps || Math.abs(x.y - y.y) > eps || Math.abs(x.z - y.z) > eps || Math.abs(x.w - y.w) > eps) return false;
		}
		return true;
	}

	public static inline function col(m:Mat4, k:Int):Vec4
		return k == 0 ? m.c0 : k == 1 ? m.c1 : k == 2 ? m.c2 : m.c3;
}
