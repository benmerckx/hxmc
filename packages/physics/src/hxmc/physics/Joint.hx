package hxmc.physics;

import hxmc.gfx.shader.Vec3;

// A joint holding two bodies together at points (anchors, each in its
// body's frame; b null: a fixed point of the world, its anchor in world
// space): Ball, the two points kept at one place (a ball and socket: chains,
// pendulums, ragdolls' shoulders), or Distance, kept the length apart
// (rigid rods, ropes pulled tight), or Hinge, a ball joint whose bodies
// also keep an axis each lined up (axisA in a's frame, axisB in b's or the
// world's: doors, wheels, levers). Solved with the contacts, impulses
// on the three axes at once (Ball) or along the line between the points
// (Distance), the drift pulled back a share a step.
//   physics.join(Joint.ball(lamp, new Vec3(0, 0.5, 0), null, new Vec3(0, 3, 0)));
class Joint {
	public final a:Body;
	public final b:Null<Body>;
	public final anchorA:Vec3;
	public final anchorB:Vec3;
	// Distance's length (Ball: 0)
	public final length:Float;
	public final distance:Bool;
	// Hinge's axes (null: not a hinge)
	public final axisA:Null<Vec3>;
	public final axisB:Null<Vec3>;
	// the share of the drift pulled back a step (0 to 1)
	public var stiffness = 0.2;

	function new(a:Body, anchorA:Vec3, b:Null<Body>, anchorB:Vec3, distance:Bool, length:Float, ?axisA:Vec3, ?axisB:Vec3) {
		this.axisA = axisA;
		this.axisB = axisB;
		this.a = a;
		this.b = b;
		this.anchorA = anchorA;
		this.anchorB = anchorB;
		this.distance = distance;
		this.length = length;
	}

	public static function ball(a:Body, anchorA:Vec3, b:Null<Body>, anchorB:Vec3):Joint
		return new Joint(a, anchorA, b, anchorB, false, 0);

	// a hinge about axisA (in a's frame), lined up with axisB (in b's, or
	// the world's when b is null)
	public static function hinge(a:Body, anchorA:Vec3, axisA:Vec3, b:Null<Body>, anchorB:Vec3, axisB:Vec3):Joint
		return new Joint(a, anchorA, b, anchorB, false, 0, unit(axisA), unit(axisB));

	static function unit(v:Vec3):Vec3 {
		var l = Math.sqrt(dot(v, v));
		return v / l;
	}

	// (length: by default the points' distance now)
	public static function distanceOf(a:Body, anchorA:Vec3, b:Null<Body>, anchorB:Vec3, ?length:Float):Joint {
		var j = new Joint(a, anchorA, b, anchorB, true, 0, null, null);
		if (length == null) {
			var d = j.pointB() - j.pointA();
			length = Math.sqrt(dot(d, d));
		}
		return new Joint(a, anchorA, b, anchorB, true, length);
	}

	public inline function pointA():Vec3
		return a.position + a.orientation.rotate(anchorA);

	public inline function pointB():Vec3
		return b == null ? anchorB : b.position + b.orientation.rotate(anchorB);

	@:allow(hxmc.physics) function wake() {
		if (b == null) return;
		// (one end moving wakes the other)
		if (a.sleeping && !b.sleeping && !b.isStatic()) a.wake();
		if (b.sleeping && !a.sleeping && !a.isStatic()) b.wake();
	}

	@:allow(hxmc.physics) function solve(dt:Float) {
		var pa = pointA(), pb = pointB();
		var err = pb - pa;
		if (distance) {
			var l = Math.sqrt(dot(err, err));
			if (l < 1e-9) return;
			var n = err / l;
			push(pa, pb, n, (l - length) * stiffness / dt);
		} else {
			ballPush(pa, pb, err * (stiffness / dt));
			if (axisA != null) align(dt);
		}
	}

	// Hinge's axes kept lined up: no turning of one against the other but
	// about the axis, the misalignment pulled back
	function align(dt:Float) {
		var wa = a.orientation.rotate(axisA), wb = b == null ? axisB : b.orientation.rotate(axisB);
		var err = cross(wa, wb);
		// (two directions across the axis)
		var t1 = Math.abs(wa.x) < 0.9 ? unit(cross(wa, new Vec3(1, 0, 0))) : unit(cross(wa, new Vec3(0, 1, 0)));
		var t2 = cross(wa, t1);
		for (t in [t1, t2]) {
			var k = dot(t, a.applyInvInertia(t)) + (b == null ? 0 : dot(t, b.applyInvInertia(t)));
			if (k < 1e-12) continue;
			var rel = (b == null ? 0 : dot(b.angular, t)) - dot(a.angular, t);
			var lambda = -(rel + dot(err, t) * stiffness / dt) / k;
			var j = t * lambda;
			if (!a.isStatic() && !a.sleeping) a.angular = a.angular - a.applyInvInertia(j);
			if (b != null && !b.isStatic() && !b.sleeping) b.angular = b.angular + b.applyInvInertia(j);
		}
	}

	// Ball's impulse: the points' relative velocity made -bias on all three
	// axes at once (the 3x3 effective mass inverted: the axes are coupled
	// through the bodies' turning, which one axis at a time solves slowly)
	function ballPush(pa:Vec3, pb:Vec3, bias:Vec3) {
		var ra = pa - a.position, rb = b == null ? new Vec3(0, 0, 0) : pb - b.position;
		var c0 = column(new Vec3(1, 0, 0), ra, rb), c1 = column(new Vec3(0, 1, 0), ra, rb), c2 = column(new Vec3(0, 0, 1), ra, rb);
		var det = dot(c0, cross(c1, c2));
		if (Math.abs(det) < 1e-18) return;
		var va = a.velocityAt(pa), vb = b == null ? new Vec3(0, 0, 0) : b.velocityAt(pb);
		var rhs = (vb - va + bias) * -1;
		// (Cramer's rule: the columns' cross products are the inverse's rows)
		var r0 = cross(c1, c2), r1 = cross(c2, c0), r2 = cross(c0, c1);
		var j = new Vec3(dot(r0, rhs), dot(r1, rhs), dot(r2, rhs)) / det;
		if (!a.isStatic() && !a.sleeping) {
			a.velocity = a.velocity - j * a.invMass;
			a.angular = a.angular - a.applyInvInertia(cross(ra, j));
		}
		if (b != null && !b.isStatic() && !b.sleeping) {
			b.velocity = b.velocity + j * b.invMass;
			b.angular = b.angular + b.applyInvInertia(cross(rb, j));
		}
	}

	// an impulse along unit d making the points' relative speed along it
	// -bias (the drift, b's point less a's, closing)
	function push(pa:Vec3, pb:Vec3, d:Vec3, bias:Float) {
		var ra = pa - a.position;
		var va = a.velocityAt(pa), vb = b == null ? new Vec3(0, 0, 0) : b.velocityAt(pb);
		var k = a.invMass + dot(d, cross(a.applyInvInertia(cross(ra, d)), ra));
		var rb = b == null ? new Vec3(0, 0, 0) : pb - b.position;
		if (b != null) k += b.invMass + dot(d, cross(b.applyInvInertia(cross(rb, d)), rb));
		if (k < 1e-12) return;
		// (the relative speed along d wanted: the drift closing)
		var lambda = -(dot(vb - va, d) + bias) / k;
		var j = d * lambda;
		if (!a.isStatic() && !a.sleeping) {
			a.velocity = a.velocity - j * a.invMass;
			a.angular = a.angular - a.applyInvInertia(cross(ra, j));
		}
		if (b != null && !b.isStatic() && !b.sleeping) {
			b.velocity = b.velocity + j * b.invMass;
			b.angular = b.angular + b.applyInvInertia(cross(rb, j));
		}
	}

	// the effective mass's column for direction d (the points at ra, rb from the centres)
	function column(d:Vec3, ra:Vec3, rb:Vec3):Vec3 {
		var k = d * a.invMass + cross(a.applyInvInertia(cross(ra, d)), ra);
		if (b != null) k = k + d * b.invMass + cross(b.applyInvInertia(cross(rb, d)), rb);
		return k;
	}

	static inline function dot(a:Vec3, b:Vec3):Float
		return a.x * b.x + a.y * b.y + a.z * b.z;

	static inline function cross(a:Vec3, b:Vec3):Vec3
		return new Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}
