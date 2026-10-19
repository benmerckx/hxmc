package hxmc.physics;

import hxmc.gfx.shader.Vec3;
import hxmc.scene.Node;
import hxmc.scene.math.Quat;

// A rigid body: its shape, position and orientation, linear and angular
// velocity (world space, radians a second), mass (0: static, never moved)
// and its inertia from its shape, how much it bounces (restitution, 0 to
// 1) and grips (friction). A body added with a node writes its position
// and orientation to the node after each step.
class Body {
	public final shape:Shape;
	public var position:Vec3;
	public var orientation:Quat = Quat.identity();
	public var velocity:Vec3 = new Vec3(0, 0, 0);
	public var angular:Vec3 = new Vec3(0, 0, 0);
	public final mass:Float;
	public final invMass:Float;
	// the inverse inertia's diagonal in the body's frame
	public final invInertia:Vec3;
	public var restitution = 0.3;
	public var friction = 0.4;
	// whether contacts turn it (false: it keeps its orientation, as a
	// character's capsule standing up)
	public var rotates = true;
	public var node:Node = Node.NONE;
	// resting: not moved until something touches it
	public var sleeping(default, null) = false;
	@:allow(hxmc.physics) var still = 0;
	// (the bounds in the world, made by bounds(): the broad phase's)
	@:allow(hxmc.physics) var minX = 0.0;
	@:allow(hxmc.physics) var maxX = 0.0;
	@:allow(hxmc.physics) var minY = 0.0;
	@:allow(hxmc.physics) var maxY = 0.0;
	@:allow(hxmc.physics) var minZ = 0.0;
	@:allow(hxmc.physics) var maxZ = 0.0;

	public function new(shape:Shape, position:Vec3, mass = 1.0) {
		this.shape = shape;
		this.position = position;
		switch shape {
			case Plane(_, _):
				if (mass > 0) throw "hxmc.physics: planes are static (mass 0)";
			case _:
		}
		this.mass = mass;
		invMass = mass > 0 ? 1 / mass : 0;
		invInertia = if (mass <= 0) new Vec3(0, 0, 0) else switch shape {
			case Sphere(r):
				var i = 2 / 5 * mass * r * r;
				new Vec3(1 / i, 1 / i, 1 / i);
			case Box(h):
				var x = 2 * h.x, y = 2 * h.y, z = 2 * h.z;
				new Vec3(12 / (mass * (y * y + z * z)), 12 / (mass * (x * x + z * z)), 12 / (mass * (x * x + y * y)));
			case Capsule(r, h):
				// (as a solid cylinder of its whole length: close enough to tumble)
				var l = 2 * (h + r), across = mass * (3 * r * r + l * l) / 12, along = mass * r * r / 2;
				new Vec3(1 / across, 1 / along, 1 / across);
			case _: new Vec3(0, 0, 0);
		}
	}

	// the world bounds of the shape (a sphere's, a turned box's extent)
	@:allow(hxmc.physics) function bounds() {
		var ex = 0.0, ey = 0.0, ez = 0.0;
		switch shape {
			case Sphere(r):
				ex = ey = ez = r;
			case Box(h):
				var m = orientation.toMat4();
				ex = Math.abs(m.c0.x) * h.x + Math.abs(m.c1.x) * h.y + Math.abs(m.c2.x) * h.z;
				ey = Math.abs(m.c0.y) * h.x + Math.abs(m.c1.y) * h.y + Math.abs(m.c2.y) * h.z;
				ez = Math.abs(m.c0.z) * h.x + Math.abs(m.c1.z) * h.y + Math.abs(m.c2.z) * h.z;
			case Capsule(r, h):
				var a = orientation.rotate(new Vec3(0, h, 0));
				ex = Math.abs(a.x) + r;
				ey = Math.abs(a.y) + r;
				ez = Math.abs(a.z) + r;
			case Plane(_, _):
				ex = ey = ez = 1e30;
		}
		// (a margin: contacts begin at touching)
		var p = position, m = 0.01;
		minX = p.x - ex - m;
		maxX = p.x + ex + m;
		minY = p.y - ey - m;
		maxY = p.y + ey + m;
		minZ = p.z - ez - m;
		maxZ = p.z + ez + m;
	}

	public inline function isStatic():Bool
		return invMass == 0;

	public function wake() {
		sleeping = false;
		still = 0;
	}

	@:allow(hxmc.physics) function sleep() {
		sleeping = true;
		velocity = new Vec3(0, 0, 0);
		angular = new Vec3(0, 0, 0);
	}

	// the inverse inertia (world space) times v
	public function applyInvInertia(v:Vec3):Vec3 {
		if (isStatic() || !rotates) return new Vec3(0, 0, 0);
		var local = orientation.conjugate().rotate(v);
		return orientation.rotate(new Vec3(local.x * invInertia.x, local.y * invInertia.y, local.z * invInertia.z));
	}

	// an impulse j at the world point p (null: the centre)
	public function applyImpulse(j:Vec3, ?p:Vec3) {
		if (isStatic()) return;
		velocity = velocity + j * invMass;
		if (p != null) angular = angular + applyInvInertia(cross(p - position, j));
		wake();
	}

	// the velocity of the body's point p
	public inline function velocityAt(p:Vec3):Vec3
		return velocity + cross(angular, p - position);

	static inline function cross(a:Vec3, b:Vec3):Vec3
		return new Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}
