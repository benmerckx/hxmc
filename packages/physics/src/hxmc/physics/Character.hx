package hxmc.physics;

import hxmc.gfx.shader.Vec3;
import hxmc.scene.Node;

// A walking character: an upright capsule body (it does not turn, no
// friction or bounce of its own) whose horizontal velocity is steered
// towards the wanted one (accelerating at most acceleration; in the air a
// share of it, airControl), which jumps from the ground, and which pushes
// and is pushed as any body. Grounded: a ray down from its centre finds
// something within reach of its feet (on an edge the centre may miss it).
// Steps up to stepHeight are climbed: walking into something its feet
// meet but a ray at that height does not, it is lifted onto its top.
//   var hero = new Character(physics, new Vec3(0, 1, 0), heroNode);
//   // each fixed step, before physics.step(dt):
//   hero.update(dt, new Vec3(right, 0, -forward), actions.pressed("jump"));
class Character {
	public final body:Body;
	public final world:PhysicsWorld;
	public final radius:Float;
	public final half:Float;
	// the walking speed (m/s), the jump's starting speed up, how fast the
	// velocity turns to the wanted one (m/s each second) and the share of
	// that in the air
	public var speed = 4.0;
	public var jumpSpeed = 5.0;
	public var acceleration = 40.0;
	public var airControl = 0.3;
	// how far under its feet ground still counts
	public var groundReach = 0.08;
	// the highest step it walks up (metres)
	public var stepHeight = 0.35;
	// whether it stood on something at the last update
	public var grounded(default, null) = false;
	// the ground's body and distance below the feet (when grounded)
	public var ground(default, null):Null<Body>;

	public function new(world:PhysicsWorld, position:Vec3, ?node:Node, radius = 0.3, height = 1.8, mass = 70.0) {
		this.world = world;
		this.radius = radius;
		half = Math.max(height / 2 - radius, 0);
		body = new Body(Capsule(radius, half), position, mass);
		body.rotates = false;
		body.friction = 0;
		body.restitution = 0;
		world.add(body, node);
	}

	// a step in the way (along x, z) climbed: low ahead, clear at the step's
	// height, its top found from above
	function climb(x:Float, z:Float) {
		var l = Math.sqrt(x * x + z * z);
		if (l < 1e-9) return;
		var dir = new Vec3(x / l, 0, z / l), p = body.position;
		var feet = p.y - half - radius, reach = radius + 0.12;
		var low = world.raycast(new Vec3(p.x, feet + 0.04, p.z), dir, reach, body);
		if (low == null) return;
		var top = feet + stepHeight;
		if (world.raycast(new Vec3(p.x, top, p.z), dir, reach + 0.05, body) != null) return;
		var ahead = low.distance + 0.06;
		var down = world.raycast(new Vec3(p.x + dir.x * ahead, top, p.z + dir.z * ahead), new Vec3(0, -1, 0), stepHeight, body);
		if (down == null) return;
		var rise = top - down.distance - feet;
		if (rise <= 0.01) return;
		body.position = new Vec3(p.x, p.y + rise + 0.01, p.z);
		body.wake();
	}

	// steers towards move (x and z: a direction of length up to 1, times
	// speed; y ignored), jumping when asked and grounded
	public function update(dt:Float, move:Vec3, jump:Bool) {
		var hit = world.raycast(body.position, new Vec3(0, -1, 0), half + radius + groundReach, body);
		grounded = hit != null && body.velocity.y <= jumpSpeed * 0.5;
		ground = hit != null ? hit.body : null;
		var l = Math.sqrt(move.x * move.x + move.z * move.z);
		var mx = move.x, mz = move.z;
		if (l > 1) {
			mx /= l;
			mz /= l;
		}
		if (grounded && l > 0) climb(mx / Math.max(l, 1), mz / Math.max(l, 1));
		var v = body.velocity;
		var dx = mx * speed - v.x, dz = mz * speed - v.z;
		var dl = Math.sqrt(dx * dx + dz * dz), most = acceleration * (grounded ? 1 : airControl) * dt;
		if (dl > most) {
			dx *= most / dl;
			dz *= most / dl;
		}
		var vy = v.y;
		if (jump && grounded) {
			vy = jumpSpeed;
			grounded = false;
		}
		// (a resting character sleeps until it is steered again)
		if (dx != 0 || dz != 0 || vy != v.y) {
			body.wake();
			body.velocity = new Vec3(v.x + dx, vy, v.z + dz);
		}
	}
}
