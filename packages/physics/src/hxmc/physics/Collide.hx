package hxmc.physics;

import hxmc.gfx.shader.Vec3;
import hxmc.scene.math.Aabb;

// The contact tests, each adding its contacts to out: sphere against
// sphere, plane and box; box against plane (its corners under it) and box
// (separating axes among the faces' normals, the corners through the face
// of least overlap: a small core's approximation, edges crossing get one
// contact midway); capsules as spheres at the nearest
// points of their segments (against a plane or a box: its two ends and
// the segment's point nearest the box); and the ray tests of each shape.
class Collide {
	public static function test(a:Body, b:Body, out:Array<Contact>) {
		var from = out.length;
		switch [a.shape, b.shape] {
			case [Sphere(ra), Sphere(rb)]: spheres(a, a.position, ra, b, b.position, rb, out);
			case [Plane(n, o), Sphere(r)]: planeSphere(a, n, o, b, b.position, r, out);
			case [Sphere(r), Plane(n, o)]:
				planeSphere(b, n, o, a, a.position, r, out);
				flip(out, from);
			case [Box(h), Sphere(r)]: boxSphere(a, h, b, b.position, r, out);
			case [Sphere(r), Box(h)]:
				boxSphere(b, h, a, a.position, r, out);
				flip(out, from);
			case [Capsule(ra, ha), Sphere(rb)]: spheres(a, nearestOn(a, ha, b.position), ra, b, b.position, rb, out);
			case [Sphere(ra), Capsule(rb, hb)]: spheres(a, a.position, ra, b, nearestOn(b, hb, a.position), rb, out);
			case [Capsule(ra, ha), Capsule(rb, hb)]: capsules(a, ra, ha, b, rb, hb, out);
			case [Plane(n, o), Capsule(r, h)]: planeCapsule(a, n, o, b, r, h, out);
			case [Capsule(r, h), Plane(n, o)]:
				planeCapsule(b, n, o, a, r, h, out);
				flip(out, from);
			case [Box(bh), Capsule(r, h)]: boxCapsule(a, bh, b, r, h, out);
			case [Capsule(r, h), Box(bh)]:
				boxCapsule(b, bh, a, r, h, out);
				flip(out, from);
			case [Plane(n, o), Box(h)]: planeBox(a, n, o, b, h, out);
			case [Box(h), Plane(n, o)]:
				planeBox(b, n, o, a, h, out);
				flip(out, from);
			case [Box(ha), Box(hb)]: boxes(a, ha, b, hb, out);
			case _:
		}
	}

	// the contacts from index from on, turned around (a and b swapped)
	static function flip(out:Array<Contact>, from:Int) {
		for (k in from...out.length) {
			var c = out[k];
			out[k] = new Contact(c.b, c.a, c.normal * -1, c.point, c.depth);
		}
	}

	// (spheres of a and b centred at ca and cb: a sphere's at its position, a capsule's on its segment)
	static function spheres(a:Body, ca:Vec3, ra:Float, b:Body, cb:Vec3, rb:Float, out:Array<Contact>) {
		var d = cb - ca;
		var d2 = dot(d, d), r = ra + rb;
		if (d2 >= r * r) return;
		var l = Math.sqrt(d2);
		var n = l > 1e-12 ? d / l : new Vec3(0, 1, 0);
		out.push(new Contact(a, b, n, ca + n * (ra - (r - l) / 2), r - l));
	}

	static function planeSphere(plane:Body, n:Vec3, offset:Float, s:Body, c:Vec3, r:Float, out:Array<Contact>) {
		var dist = dot(n, c) - offset;
		if (dist < r) out.push(new Contact(plane, s, n, c - n * dist, r - dist));
	}

	// a capsule's segment's ends in the world
	static inline function endA(b:Body, h:Float):Vec3
		return b.position + b.orientation.rotate(new Vec3(0, -h, 0));

	static inline function endB(b:Body, h:Float):Vec3
		return b.position + b.orientation.rotate(new Vec3(0, h, 0));

	// the point of a capsule's segment nearest p
	static function nearestOn(b:Body, h:Float, p:Vec3):Vec3 {
		var a = endA(b, h), ab = endB(b, h) - a;
		var len2 = dot(ab, ab);
		var t = len2 > 1e-18 ? clamp(dot(p - a, ab) / len2, 0, 1) : 0;
		return a + ab * t;
	}

	// two capsules: their segments' nearest points (Ericson's closest points of two segments)
	static function capsules(a:Body, ra:Float, ha:Float, b:Body, rb:Float, hb:Float, out:Array<Contact>) {
		var p1 = endA(a, ha), q1 = endB(a, ha), p2 = endA(b, hb), q2 = endB(b, hb);
		var d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2;
		var aa = dot(d1, d1), ee = dot(d2, d2), f = dot(d2, r);
		var s = 0.0, t = 0.0;
		if (aa <= 1e-18 && ee <= 1e-18) {} else if (aa <= 1e-18) t = clamp(f / ee, 0, 1) else {
			var c = dot(d1, r);
			if (ee <= 1e-18) s = clamp(-c / aa, 0, 1) else {
				var bb = dot(d1, d2), den = aa * ee - bb * bb;
				s = den > 1e-18 ? clamp((bb * f - c * ee) / den, 0, 1) : 0;
				t = (bb * s + f) / ee;
				if (t < 0) {
					t = 0;
					s = clamp(-c / aa, 0, 1);
				} else if (t > 1) {
					t = 1;
					s = clamp((bb - c) / aa, 0, 1);
				}
			}
		}
		spheres(a, p1 + d1 * s, ra, b, p2 + d2 * t, rb, out);
	}

	// a capsule on a plane: its ends' spheres (lying down: two contacts)
	static function planeCapsule(plane:Body, n:Vec3, offset:Float, c:Body, r:Float, h:Float, out:Array<Contact>) {
		planeSphere(plane, n, offset, c, endA(c, h), r, out);
		planeSphere(plane, n, offset, c, endB(c, h), r, out);
	}

	// a capsule against a box: its ends' spheres, and the sphere at the
	// segment's point nearest the box (found by projecting back and forth)
	// where it is not an end
	static function boxCapsule(box:Body, bh:Vec3, c:Body, r:Float, h:Float, out:Array<Contact>) {
		boxSphere(box, bh, c, endA(c, h), r, out);
		boxSphere(box, bh, c, endB(c, h), r, out);
		var inv = box.orientation.conjugate();
		var p = c.position;
		for (_ in 0...4) {
			var l = inv.rotate(p - box.position);
			var q = box.position + box.orientation.rotate(new Vec3(clamp(l.x, -bh.x, bh.x), clamp(l.y, -bh.y, bh.y), clamp(l.z, -bh.z, bh.z)));
			p = nearestOn(c, h, q);
		}
		var a = endA(c, h), b = endB(c, h);
		var da = p - a, db = p - b, m = 0.05 * h;
		if (dot(da, da) > m * m && dot(db, db) > m * m) boxSphere(box, bh, c, p, r, out);
	}

	static function boxSphere(box:Body, h:Vec3, s:Body, c:Vec3, r:Float, out:Array<Contact>) {
		var inv = box.orientation.conjugate();
		var p = inv.rotate(c - box.position);
		var q = new Vec3(clamp(p.x, -h.x, h.x), clamp(p.y, -h.y, h.y), clamp(p.z, -h.z, h.z));
		var d = p - q;
		var d2 = dot(d, d);
		if (d2 > 1e-18) {
			if (d2 >= r * r) return;
			var l = Math.sqrt(d2);
			out.push(new Contact(box, s, box.orientation.rotate(d / l), box.position + box.orientation.rotate(q), r - l));
			return;
		}
		// (the centre inside the box: out through the nearest face)
		var dx = h.x - Math.abs(p.x), dy = h.y - Math.abs(p.y), dz = h.z - Math.abs(p.z);
		var n = dx <= dy && dx <= dz ? new Vec3(p.x < 0 ? -1 : 1, 0, 0) : dy <= dz ? new Vec3(0, p.y < 0 ? -1 : 1, 0) : new Vec3(0, 0, p.z < 0 ? -1 : 1);
		out.push(new Contact(box, s, box.orientation.rotate(n), c, Math.min(dx, Math.min(dy, dz)) + r));
	}

	static function corners(b:Body, h:Vec3):Array<Vec3>
		return [
			for (k in 0...8)
				b.position + b.orientation.rotate(new Vec3((k & 1) == 0 ? -h.x : h.x, (k & 2) == 0 ? -h.y : h.y, (k & 4) == 0 ? -h.z : h.z))
		];

	static function planeBox(plane:Body, n:Vec3, offset:Float, box:Body, h:Vec3, out:Array<Contact>) {
		for (c in corners(box, h)) {
			var dist = dot(n, c) - offset;
			if (dist < 0) out.push(new Contact(plane, box, n, c, -dist));
		}
	}

	// two boxes: separating axes among their faces' normals (none: no
	// contact; edge against edge axes are not tried), the one of least
	// overlap the contact normal; the contacts are the other box's corners
	// through that face (within the face, 2% of slack: boxes of one size
	// stacked touch at their corners), or, where no corner is through it
	// (edges crossing), one contact between the two
	static function boxes(a:Body, ha:Vec3, b:Body, hb:Vec3, out:Array<Contact>) {
		var ma = a.orientation.toMat4(), mb = b.orientation.toMat4();
		var axesA = [new Vec3(ma.c0.x, ma.c0.y, ma.c0.z), new Vec3(ma.c1.x, ma.c1.y, ma.c1.z), new Vec3(ma.c2.x, ma.c2.y, ma.c2.z)];
		var axesB = [new Vec3(mb.c0.x, mb.c0.y, mb.c0.z), new Vec3(mb.c1.x, mb.c1.y, mb.c1.z), new Vec3(mb.c2.x, mb.c2.y, mb.c2.z)];
		var ea = [ha.x, ha.y, ha.z], eb = [hb.x, hb.y, hb.z];
		var d = b.position - a.position;
		var best = 1e30, bestAxis = -1;
		for (k in 0...6) {
			var l = k < 3 ? axesA[k] : axesB[k - 3];
			var ra = 0.0, rb = 0.0;
			for (i in 0...3) {
				ra += ea[i] * Math.abs(dot(axesA[i], l));
				rb += eb[i] * Math.abs(dot(axesB[i], l));
			}
			var overlap = ra + rb - Math.abs(dot(d, l));
			if (overlap <= 0) return;
			// (a's faces first on a tie, then by order: the same choice everywhere)
			if (overlap < best - 1e-9) {
				best = overlap;
				bestAxis = k;
			}
		}
		var axis = bestAxis < 3 ? axesA[bestAxis] : axesB[bestAxis - 3];
		// (the normal from a to b)
		var n = dot(d, axis) < 0 ? axis * -1 : axis;
		// the faces across n (each box's axis nearest it) and how far each
		// box reaches along n
		var ka = 0, kb = 0, ra = 0.0, rb = 0.0;
		for (i in 0...3) {
			if (Math.abs(dot(axesA[i], n)) > Math.abs(dot(axesA[ka], n))) ka = i;
			if (Math.abs(dot(axesB[i], n)) > Math.abs(dot(axesB[kb], n))) kb = i;
			ra += ea[i] * Math.abs(dot(axesA[i], n));
			rb += eb[i] * Math.abs(dot(axesB[i], n));
		}
		var planeA = dot(a.position, n) + ra, planeB = dot(b.position, n) - rb;
		var tolA = 0.02 * Math.min(ea[0], Math.min(ea[1], ea[2])), tolB = 0.02 * Math.min(eb[0], Math.min(eb[1], eb[2]));
		var count = out.length;
		// a's corners past b's face, within it; b's past a's (the corners of
		// where the two faces overlap, those of a box face to face once)
		for (c in corners(a, ha)) {
			var depth = dot(c, n) - planeB;
			if (depth > 0 && inFace(c - b.position, axesB, eb, kb, tolB)) out.push(new Contact(a, b, n, c, depth));
		}
		var mine = out.length;
		for (c in corners(b, hb)) {
			var depth = planeA - dot(c, n);
			if (depth <= 0 || !inFace(c - a.position, axesA, ea, ka, tolA)) continue;
			var seen = false;
			for (m in count...mine) {
				var e = out[m].point - c;
				if (dot(e, e) < 1e-8) seen = true;
			}
			if (!seen) out.push(new Contact(a, b, n, c, depth));
		}
		if (out.length == count) {
			// (no corner through: edges crossing; a contact midway)
			out.push(new Contact(a, b, n, a.position + d * 0.5, best));
		}
	}

	// whether r (from a box's centre) lies within its face across axis k (slack tol)
	static function inFace(r:Vec3, axes:Array<Vec3>, e:Array<Float>, k:Int, tol:Float):Bool {
		for (i in 0...3)
			if (i != k && Math.abs(dot(r, axes[i])) > e[i] + tol) return false;
		return true;
	}

	static inline function clamp(x:Float, lo:Float, hi:Float):Float
		return x < lo ? lo : x > hi ? hi : x;

	static inline function dot(a:Vec3, b:Vec3):Float
		return a.x * b.x + a.y * b.y + a.z * b.z;

	// the distance along unit d from o to the body's shape, -1 for a miss
	public static function ray(b:Body, o:Vec3, d:Vec3):Float {
		return switch b.shape {
			case Sphere(r):
				var m = o - b.position;
				var bq = dot(m, d), cq = dot(m, m) - r * r;
				if (cq > 0 && bq > 0) -1 else {
					var disc = bq * bq - cq;
					if (disc < 0) -1 else Math.max(-bq - Math.sqrt(disc), 0);
				}
			case Plane(n, offset):
				var den = dot(n, d);
				if (Math.abs(den) < 1e-12) -1 else {
					var t = (offset - dot(n, o)) / den;
					t >= 0 ? t : -1;
				}
			case Box(h):
				// (in the box's frame)
				var inv = b.orientation.conjugate();
				new Aabb(h * -1, h).ray(inv.rotate(o - b.position), inv.rotate(d));
			case Capsule(r, h):
				// (in the capsule's frame: its side, a cylinder along y, then its ends' spheres)
				var inv = b.orientation.conjugate();
				var lo = inv.rotate(o - b.position), ld = inv.rotate(d);
				var best = -1.0;
				var qa = ld.x * ld.x + ld.z * ld.z, qb = lo.x * ld.x + lo.z * ld.z, qc = lo.x * lo.x + lo.z * lo.z - r * r;
				if (qc <= 0 && Math.abs(lo.y) <= h) best = 0 else if (qa > 1e-18) {
					var disc = qb * qb - qa * qc;
					if (disc >= 0) {
						var t = (-qb - Math.sqrt(disc)) / qa;
						if (t >= 0 && Math.abs(lo.y + ld.y * t) <= h) best = t;
					}
				}
				if (best < 0)
					for (end in [new Vec3(0, -h, 0), new Vec3(0, h, 0)]) {
						var m = lo - end;
						var bq = dot(m, ld), cq = dot(m, m) - r * r;
						if (cq > 0 && bq > 0) continue;
						var disc = bq * bq - cq;
						if (disc < 0) continue;
						var t = Math.max(-bq - Math.sqrt(disc), 0);
						if (best < 0 || t < best) best = t;
					}
				best;
		}
	}
}
