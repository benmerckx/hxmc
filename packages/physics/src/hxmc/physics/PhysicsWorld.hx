package hxmc.physics;

import hxmc.gfx.shader.Vec3;
import hxmc.scene.Node;
import hxmc.scene.math.Quat;

// A small rigid-body world (docs/plans/3d.md, step 6): bodies under
// gravity, stepped at a fixed rate (hxmc.scene.FixedStep's dt): velocities
// integrated (semi-implicit Euler, orientations too), contacts found
// (a sweep-and-prune broad phase, then Collide: spheres, boxes, capsules, planes), resolved by sequential impulses at the contact points (linear
// and angular: boxes tumble) with restitution and friction, the impulses
// accumulated and clamped over the iterations, overlap pushed apart,
// resting bodies put to sleep. A body added with a node moves and turns
// that node. Deterministic: the same steps give the same result on every
// target.
class PhysicsWorld {
	public var gravity = new Vec3(0, -9.81, 0);
	public var iterations = 10;
	public final bodies:Array<Body> = [];
	// the last step's contacts (statistics)
	public var contacts(default, null) = 0;
	// speeds under which a body counts as still, and the steps it must stay
	// still to sleep
	public var sleepSpeed = 0.05;
	public var sleepSteps = 30;

	final pending:Array<Contact> = [];
	public final joints:Array<Joint> = [];

	public function new() {}

	public function add(body:Body, ?node:Node):Body {
		bodies.push(body);
		if (node != null) {
			body.node = node;
			node.position = body.position;
			node.rotation = body.orientation;
		}
		return body;
	}

	public function remove(body:Body)
		bodies.remove(body);

	// a joint between bodies (Joint.ball, Joint.distanceOf), solved with the contacts
	public function join(joint:Joint):Joint {
		joints.push(joint);
		return joint;
	}

	public function unjoin(joint:Joint)
		joints.remove(joint);

	public function step(dt:Float) {
		for (b in bodies)
			if (!b.isStatic() && !b.sleeping) b.velocity = b.velocity + gravity * dt;
		pending.resize(0);
		broadPhase();
		contacts = pending.length;
		for (c in pending) {
			// (a moving body touching a sleeping one wakes it)
			if (c.a.sleeping && !c.b.isStatic() && !c.b.sleeping) c.a.wake();
			if (c.b.sleeping && !c.a.isStatic() && !c.a.sleeping) c.b.wake();
			// (the bounce: from the approach speed, none at resting speeds)
			var vn = dot(c.b.velocityAt(c.point) - c.a.velocityAt(c.point), c.normal);
			c.bounce = vn < -0.5 ? -Math.min(c.a.restitution, c.b.restitution) * vn : 0;
		}
		for (j in joints)
			j.wake();
		for (_ in 0...iterations) {
			for (c in pending)
				resolve(c);
			for (j in joints)
				j.solve(dt);
		}
		for (b in bodies)
			if (!b.isStatic() && !b.sleeping) {
				b.position = b.position + b.velocity * dt;
				var w = b.angular, q = b.orientation;
				// (dq = w q / 2: w as a quaternion of no scalar part)
				var spin = new Quat(w.x, w.y, w.z, 0) * q;
				b.orientation = new Quat(q.x + spin.x * dt / 2, q.y + spin.y * dt / 2, q.z + spin.z * dt / 2, q.w + spin.w * dt / 2).normalized();
			}
		// (what is still overlapping, pushed apart: 20% of it a step, past a slop)
		for (c in pending) {
			var total = c.a.invMass + c.b.invMass;
			if (total == 0) continue;
			var push = Math.max(c.depth - 0.005, 0) * 0.2 / total;
			if (!c.a.sleeping) c.a.position = c.a.position - c.normal * (push * c.a.invMass);
			if (!c.b.sleeping) c.b.position = c.b.position + c.normal * (push * c.b.invMass);
		}
		for (b in bodies) {
			if (b.isStatic() || b.sleeping) continue;
			var v = b.velocity, w = b.angular;
			if (dot(v, v) < sleepSpeed * sleepSpeed && dot(w, w) < sleepSpeed * sleepSpeed) {
				if (++b.still >= sleepSteps) b.sleep();
			} else
				b.still = 0;
		}
		for (b in bodies)
			if (!b.node.isNone && b.node.valid && !b.isStatic()) {
				b.node.position = b.position;
				b.node.rotation = b.orientation;
			}
	}

	// the pairs whose bounds overlap, by sweep and prune along x: the
	// bodies sorted by their bounds' start (insertion sort: the order
	// changes little between steps), each tested against those starting
	// before its end; planes, unbounded, against every body. Pairs in the
	// order of the bodies list, so the result does not depend on the sort.
	final order:Array<Body> = [];
	final pairs:Array<Int> = [];

	function broadPhase() {
		order.resize(0);
		for (b in bodies)
			if (!b.shape.match(Plane(_, _))) order.push(b);
		for (b in order)
			b.bounds();
		for (i in 1...order.length) {
			var b = order[i], j = i - 1;
			while (j >= 0 && order[j].minX > b.minX) {
				order[j + 1] = order[j];
				j--;
			}
			order[j + 1] = b;
		}
		pairs.resize(0);
		var index = new Map<Body, Int>();
		for (k in 0...bodies.length)
			index.set(bodies[k], k);
		for (i in 0...order.length) {
			var a = order[i];
			for (j in i + 1...order.length) {
				var b = order[j];
				if (b.minX > a.maxX) break;
				if (a.maxY < b.minY || b.maxY < a.minY || a.maxZ < b.minZ || b.maxZ < a.minZ) continue;
				var ia = index.get(a), ib = index.get(b);
				pairs.push(ia < ib ? ia * 65536 + ib : ib * 65536 + ia);
			}
		}
		for (k in 0...bodies.length)
			if (bodies[k].shape.match(Plane(_, _)))
				for (j in 0...bodies.length)
					if (j != k && !bodies[j].shape.match(Plane(_, _))) pairs.push(k < j ? k * 65536 + j : j * 65536 + k);
		pairs.sort((x, y) -> x - y);
		for (p in pairs) {
			var a = bodies[p >> 16], b = bodies[p & 0xFFFF];
			if ((a.isStatic() || a.sleeping) && (b.isStatic() || b.sleeping)) continue;
			Collide.test(a, b, pending);
		}
	}

	// one contact's impulses at its point: along the normal up to the
	// bounce (accumulated, never pulling), then along two tangents
	// (friction, within the Coulomb cone of the normal impulse)
	function resolve(c:Contact) {
		var a = c.a, b = c.b;
		if (a.invMass + b.invMass == 0) return;
		var n = c.normal;
		var vn = dot(b.velocityAt(c.point) - a.velocityAt(c.point), n);
		var k = mass(c, n);
		var jn = Math.max(c.normalImpulse + (c.bounce - vn) / k, 0);
		var dj = jn - c.normalImpulse;
		c.normalImpulse = jn;
		apply(c, n * dj);
		// friction: two tangents of the normal
		var t1 = Math.abs(n.x) > 0.7 ? normalize(cross(n, new Vec3(0, 1, 0))) : normalize(cross(n, new Vec3(1, 0, 0)));
		var t2 = cross(n, t1);
		var mu = Math.sqrt(a.friction * b.friction), limit = mu * c.normalImpulse;
		for (axis in 0...2) {
			var t = axis == 0 ? t1 : t2;
			var vt = dot(b.velocityAt(c.point) - a.velocityAt(c.point), t);
			var acc = axis == 0 ? c.tangentImpulse1 : c.tangentImpulse2;
			var jt = Math.max(-limit, Math.min(limit, acc - vt / mass(c, t)));
			var d = jt - acc;
			if (axis == 0) c.tangentImpulse1 = jt else c.tangentImpulse2 = jt;
			apply(c, t * d);
		}
	}

	// the effective mass's inverse along dir at the contact
	static function mass(c:Contact, dir:Vec3):Float {
		var ra = c.point - c.a.position, rb = c.point - c.b.position;
		var ka = cross(c.a.applyInvInertia(cross(ra, dir)), ra), kb = cross(c.b.applyInvInertia(cross(rb, dir)), rb);
		return c.a.invMass + c.b.invMass + dot(dir, ka) + dot(dir, kb);
	}

	// an impulse j at the contact: -j on a, j on b
	static function apply(c:Contact, j:Vec3) {
		var a = c.a, b = c.b;
		if (!a.isStatic() && !a.sleeping) {
			a.velocity = a.velocity - j * a.invMass;
			a.angular = a.angular - a.applyInvInertia(cross(c.point - a.position, j));
		}
		if (!b.isStatic() && !b.sleeping) {
			b.velocity = b.velocity + j * b.invMass;
			b.angular = b.angular + b.applyInvInertia(cross(c.point - b.position, j));
		}
	}

	// the first body a ray hits (dir of any length but zero), within
	// maxDistance (ignore: a body left out, as a character's own)
	public function raycast(origin:Vec3, dir:Vec3, maxDistance = 1e9, ?ignore:Body):Null<{body:Body, distance:Float, point:Vec3}> {
		var l = Math.sqrt(dot(dir, dir));
		var d = dir / l;
		var best:Null<Body> = null, bestT = maxDistance;
		for (b in bodies) {
			if (b == ignore) continue;
			var t = Collide.ray(b, origin, d);
			if (t >= 0 && t < bestT) {
				bestT = t;
				best = b;
			}
		}
		return best == null ? null : {body: best, distance: bestT, point: origin + d * bestT};
	}

	static inline function dot(a:Vec3, b:Vec3):Float
		return a.x * b.x + a.y * b.y + a.z * b.z;

	static inline function cross(a:Vec3, b:Vec3):Vec3
		return new Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);

	static inline function normalize(a:Vec3):Vec3
		return a / Math.sqrt(dot(a, a));
}
