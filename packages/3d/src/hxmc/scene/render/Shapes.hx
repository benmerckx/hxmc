package hxmc.scene.render;

import hxmc.gfx.Device;

// Meshes made in code (no file): a box, a UV sphere, a plane; positions,
// normals and uvs for the renderer, each one primitive of material.
class Shapes {
	// a box of width, height and depth, centred, flat faces
	public static function box(device:Device, material:Material, w = 1.0, h = 1.0, d = 1.0):Mesh {
		var p:Array<Float> = [], n:Array<Float> = [], uv:Array<Float> = [], idx:Array<Int> = [];
		var faces = [
			[0, 0, 1, 1, 0, 0, 0, 1, 0], [0, 0, -1, -1, 0, 0, 0, 1, 0], [1, 0, 0, 0, 0, -1, 0, 1, 0],
			[-1, 0, 0, 0, 0, 1, 0, 1, 0], [0, 1, 0, 1, 0, 0, 0, 0, -1], [0, -1, 0, 1, 0, 0, 0, 0, 1]
		];
		var half = [w / 2, h / 2, d / 2];
		for (f in faces) {
			var base = Std.int(p.length / 3);
			for (c in [[-1, -1], [1, -1], [1, 1], [-1, 1]]) {
				for (k in 0...3) {
					p.push((f[k] + f[3 + k] * c[0] + f[6 + k] * c[1]) * half[k]);
					n.push(f[k]);
				}
				uv.push((c[0] + 1) / 2);
				uv.push((1 - c[1]) / 2);
			}
			for (k in [0, 1, 2, 0, 2, 3])
				idx.push(base + k);
		}
		var m = new Mesh();
		m.add(device, p, n, uv, idx, material);
		return m;
	}

	// a sphere of radius, segments around and rings from pole to pole
	public static function sphere(device:Device, material:Material, radius = 0.5, segments = 32, rings = 16):Mesh {
		var p:Array<Float> = [], n:Array<Float> = [], uv:Array<Float> = [], idx:Array<Int> = [];
		for (r in 0...rings + 1) {
			var th = Math.PI * r / rings;
			for (s in 0...segments + 1) {
				var ph = 2 * Math.PI * s / segments;
				var x = Math.sin(th) * Math.cos(ph), y = Math.cos(th), z = -Math.sin(th) * Math.sin(ph);
				p.push(x * radius);
				p.push(y * radius);
				p.push(z * radius);
				n.push(x);
				n.push(y);
				n.push(z);
				uv.push(s / segments);
				uv.push(r / rings);
			}
		}
		for (r in 0...rings)
			for (s in 0...segments) {
				var a = r * (segments + 1) + s, b = a + segments + 1;
				if (r > 0) for (k in [a, b, a + 1]) idx.push(k);
				if (r < rings - 1) for (k in [a + 1, b, b + 1]) idx.push(k);
			}
		var m = new Mesh();
		m.add(device, p, n, uv, idx, material);
		return m;
	}

	// a capsule along y: the points within radius of the segment from -half
	// to half (physics' Capsule(radius, half)), segments around, rings in
	// each end's hemisphere
	public static function capsule(device:Device, material:Material, radius = 0.3, half = 0.6, segments = 24, rings = 8):Mesh {
		var p:Array<Float> = [], n:Array<Float> = [], uv:Array<Float> = [], idx:Array<Int> = [];
		// (rows from the top pole to the bottom one: the upper hemisphere's,
		// then the lower's, the two equators' rows apart by the side)
		var rows = 2 * rings + 2;
		for (r in 0...rows) {
			var upper = r <= rings;
			var th = Math.PI / 2 * (upper ? r : r - 1) / rings;
			var y = Math.cos(th), ring = Math.sin(th), shift = upper ? half : -half;
			for (s in 0...segments + 1) {
				var ph = 2 * Math.PI * s / segments;
				var x = ring * Math.cos(ph), z = -ring * Math.sin(ph);
				p.push(x * radius);
				p.push(y * radius + shift);
				p.push(z * radius);
				n.push(x);
				n.push(y);
				n.push(z);
				uv.push(s / segments);
				uv.push(r / (rows - 1));
			}
		}
		for (r in 0...rows - 1)
			for (s in 0...segments) {
				var a = r * (segments + 1) + s, b = a + segments + 1;
				if (r > 0) for (k in [a, b, a + 1]) idx.push(k);
				if (r < rows - 2) for (k in [a + 1, b, b + 1]) idx.push(k);
			}
		var m = new Mesh();
		m.add(device, p, n, uv, idx, material);
		return m;
	}

	// a square of size on y = 0, facing up
	public static function plane(device:Device, material:Material, size = 1.0):Mesh {
		var h = size / 2;
		var m = new Mesh();
		m.add(device, [-h, 0, h, h, 0, h, h, 0, -h, -h, 0, -h], [0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0], [0, 1, 1, 1, 1, 0, 0, 0], [0, 1, 2, 0, 2, 3],
			material);
		return m;
	}
}
