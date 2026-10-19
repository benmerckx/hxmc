package hxmc.scene.render;

import haxe.io.Bytes;
import hxmc.scene.math.Aabb;

// A primitive's vertices and indices in the renderer's layout, made from
// arrays (Mesh.add at run time, the asset step's packer at build time:
// one implementation, free of the GPU so that it runs on Eval): 32 bytes a
// vertex (position, normal, uv), 64 with joints and weights (skinned);
// indices of 16 bits where the vertices allow, else 32; tangents (x, y, z
// and the bitangent's sign, 16 bytes a vertex) in a buffer of their own,
// for normal maps (NormalMaps): drawn without them, the vertices are as
// any other's.
class VertexData {
	public final vertices:Bytes;
	public final indices:Bytes;
	public final wide:Bool;
	public final count:Int;
	public final skinned:Bool;
	public final bounds:Aabb;
	public final tangents:Null<Bytes>;

	public function new(vertices:Bytes, indices:Bytes, wide:Bool, count:Int, skinned:Bool, bounds:Aabb, ?tangents:Bytes) {
		this.tangents = tangents;
		this.vertices = vertices;
		this.indices = indices;
		this.wide = wide;
		this.count = count;
		this.skinned = skinned;
		this.bounds = bounds;
	}

	// normals null: computed from the triangles (smooth where vertices are
	// shared); indices null: 0, 1, 2, ...
	public static function make(positions:Array<Float>, normals:Null<Array<Float>>, uvs:Null<Array<Float>>, indices:Null<Array<Int>>,
			?joints:Array<Float>, ?weights:Array<Float>, ?tangents:Array<Float>):VertexData {
		var n = Std.int(positions.length / 3);
		if (indices == null) indices = [for (i in 0...n) i];
		if (normals == null) normals = smoothNormals(positions, indices);
		var skinned = joints != null && weights != null, stride = skinned ? 64 : 32;
		var v = Bytes.alloc(n * stride);
		for (i in 0...n) {
			var p = stride * i;
			for (k in 0...3) {
				v.setFloat(p + 4 * k, positions[3 * i + k]);
				v.setFloat(p + 12 + 4 * k, normals[3 * i + k]);
			}
			v.setFloat(p + 24, uvs != null ? uvs[2 * i] : 0);
			v.setFloat(p + 28, uvs != null ? uvs[2 * i + 1] : 0);
			if (skinned)
				for (k in 0...4) {
					v.setFloat(p + 32 + 4 * k, joints[4 * i + k]);
					v.setFloat(p + 48 + 4 * k, weights[4 * i + k]);
				}
		}
		var wide = n > 65535;
		var ib = Bytes.alloc(indices.length * (wide ? 4 : 2));
		for (k in 0...indices.length)
			if (wide) ib.setInt32(4 * k, indices[k]) else ib.setUInt16(2 * k, indices[k]);
		var tb:Null<Bytes> = null;
		if (tangents != null) {
			tb = Bytes.alloc(n * 16);
			for (k in 0...n * 4)
				tb.setFloat(4 * k, tangents[k]);
		}
		return new VertexData(v, ib, wide, indices.length, skinned, Aabb.ofPoints(positions), tb);
	}

	// how loaders make tangents where a file has none (GltfScene): set by
	// NormalMaps when made (computeTangents), so that a program without
	// normal maps links neither; null: no tangents loaded
	public static var tangentsFrom:Null<(positions:Array<Float>, normals:Array<Float>, uvs:Array<Float>, indices:Array<Int>) -> Array<Float>>;

	// each vertex's tangent (x, y, z: along the uvs' u, at right angles to
	// its normal; w: 1 or -1, the bitangent n x t's sign, the bitangent
	// pointing up the image) from its
	// triangles' uvs (Lengyel's method, summed over the triangles: glTF asks
	// for MikkTSpace's where a file has none, which agrees on meshes whose
	// uvs are not mirrored within a triangle fan)
	public static function computeTangents(positions:Array<Float>, normals:Array<Float>, uvs:Array<Float>, indices:Array<Int>):Array<Float> {
		var n = Std.int(positions.length / 3);
		var tan = [for (_ in 0...3 * n) 0.0], bit = [for (_ in 0...3 * n) 0.0];
		var t = 0;
		while (t + 2 < indices.length) {
			var a = indices[t], b = indices[t + 1], c = indices[t + 2];
			var e1x = positions[3 * b] - positions[3 * a], e1y = positions[3 * b + 1] - positions[3 * a + 1], e1z = positions[3 * b + 2] - positions[3 * a + 2];
			var e2x = positions[3 * c] - positions[3 * a], e2y = positions[3 * c + 1] - positions[3 * a + 1], e2z = positions[3 * c + 2] - positions[3 * a + 2];
			var du1 = uvs[2 * b] - uvs[2 * a], dv1 = uvs[2 * b + 1] - uvs[2 * a + 1];
			var du2 = uvs[2 * c] - uvs[2 * a], dv2 = uvs[2 * c + 1] - uvs[2 * a + 1];
			var det = du1 * dv2 - du2 * dv1;
			if (det != 0) {
				var r = 1 / det;
				var tx = (e1x * dv2 - e2x * dv1) * r, ty = (e1y * dv2 - e2y * dv1) * r, tz = (e1z * dv2 - e2z * dv1) * r;
				var bx = (e2x * du1 - e1x * du2) * r, by = (e2y * du1 - e1y * du2) * r, bz = (e2z * du1 - e1z * du2) * r;
				for (k in [a, b, c]) {
					tan[3 * k] += tx;
					tan[3 * k + 1] += ty;
					tan[3 * k + 2] += tz;
					bit[3 * k] += bx;
					bit[3 * k + 1] += by;
					bit[3 * k + 2] += bz;
				}
			}
			t += 3;
		}
		var out = [];
		for (i in 0...n) {
			var nx = normals[3 * i], ny = normals[3 * i + 1], nz = normals[3 * i + 2];
			var tx = tan[3 * i], ty = tan[3 * i + 1], tz = tan[3 * i + 2];
			// (Gram-Schmidt: made at right angles to the normal)
			var d = nx * tx + ny * ty + nz * tz;
			tx -= nx * d;
			ty -= ny * d;
			tz -= nz * d;
			var l = Math.sqrt(tx * tx + ty * ty + tz * tz);
			if (l < 1e-12) {
				// (no uvs to follow: any direction at right angles to the normal)
				if (Math.abs(nx) < 0.9) {
					tx = 0;
					ty = nz;
					tz = -ny;
				} else {
					tx = -nz;
					ty = 0;
					tz = nx;
				}
				l = Math.sqrt(tx * tx + ty * ty + tz * tz);
			}
			tx /= l;
			ty /= l;
			tz /= l;
			// (the handedness: whether n x t points against the uvs' v, up the
			// image as glTF's uvs run down it: a normal map's green is up)
			var cx = ny * tz - nz * ty, cy = nz * tx - nx * tz, cz = nx * ty - ny * tx;
			var w = cx * bit[3 * i] + cy * bit[3 * i + 1] + cz * bit[3 * i + 2] > 0 ? -1.0 : 1.0;
			out.push(tx);
			out.push(ty);
			out.push(tz);
			out.push(w);
		}
		return out;
	}

	// each vertex's normal: the sum of its triangles' (area-weighted), normalized
	public static function smoothNormals(positions:Array<Float>, indices:Array<Int>):Array<Float> {
		var out = [for (_ in 0...positions.length) 0.0];
		var t = 0;
		while (t + 2 < indices.length) {
			var a = 3 * indices[t], b = 3 * indices[t + 1], c = 3 * indices[t + 2];
			var ux = positions[b] - positions[a], uy = positions[b + 1] - positions[a + 1], uz = positions[b + 2] - positions[a + 2];
			var vx = positions[c] - positions[a], vy = positions[c + 1] - positions[a + 1], vz = positions[c + 2] - positions[a + 2];
			var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
			for (k in [a, b, c]) {
				out[k] += nx;
				out[k + 1] += ny;
				out[k + 2] += nz;
			}
			t += 3;
		}
		var i = 0;
		while (i < out.length) {
			var l = Math.sqrt(out[i] * out[i] + out[i + 1] * out[i + 1] + out[i + 2] * out[i + 2]);
			if (l > 0) {
				out[i] /= l;
				out[i + 1] /= l;
				out[i + 2] /= l;
			} else
				out[i + 1] = 1;
			i += 3;
		}
		return out;
	}
}
