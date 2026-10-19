import hxmc.gfx.shader.Vec3;
import hxmc.physics.*;
import hxmc.scene.*;

// @hxmc/physics (make 3d-check: on Eval, natively and as wasm32-wasi): a
// ball comes to rest on a plane and on a box, bounces by its restitution,
// two balls trade momentum, raycasts, sleeping and waking, a body moving
// its node; the same steps give the same numbers everywhere (a checksum
// of a pile of balls after 300 steps).
class PhysicsTest {
	// the pile's checksum after 300 steps (Eval, native and wasm32-wasi alike)
	static inline var CHECKSUM = 24618742;
	static var checks = 0;
	static var failed = 0;

	static function check(what:String, ok:Bool) {
		checks++;
		if (!ok) {
			failed++;
			Sys.println('PhysicsTest: FAIL: $what');
		}
	}

	static function near(a:Float, b:Float, eps:Float):Bool
		return Math.abs(a - b) <= eps;

	static function main() {
		var dt = 1 / 60;
		// resting on a plane
		var w = new PhysicsWorld();
		w.add(new Body(Plane(new Vec3(0, 1, 0), 0), new Vec3(0, 0, 0), 0));
		var ball = w.add(new Body(Sphere(0.5), new Vec3(0, 3, 0)));
		for (_ in 0...300)
			w.step(dt);
		check("rests on the plane", near(ball.position.y, 0.5, 0.01) && ball.sleeping);
		// bouncing: restitution 0.8 from 2 m, the first bounce back up to about 0.8^2 of it
		var w2 = new PhysicsWorld();
		var floor = w2.add(new Body(Plane(new Vec3(0, 1, 0), 0), new Vec3(0, 0, 0), 0));
		floor.restitution = 1;
		var b2 = w2.add(new Body(Sphere(0.1), new Vec3(0, 2.1, 0)));
		b2.restitution = 0.8;
		var falling = true, peak = 0.0;
		for (_ in 0...200) {
			w2.step(dt);
			if (falling && b2.velocity.y > 0) falling = false;
			if (!falling && b2.velocity.y >= 0) peak = Math.max(peak, b2.position.y - 0.1);
		}
		check('bounces to about 0.64 of its height (${Math.round(peak * 100) / 100} m)', peak > 2 * 0.64 * 0.85 && peak < 2 * 0.64 * 1.15);
		// two balls: momentum kept
		var w3 = new PhysicsWorld();
		w3.gravity = new Vec3(0, 0, 0);
		var a = w3.add(new Body(Sphere(0.5), new Vec3(-2, 0, 0), 1)), b = w3.add(new Body(Sphere(0.5), new Vec3(2, 0, 0), 3));
		a.velocity = new Vec3(4, 0, 0);
		a.restitution = b.restitution = 1;
		a.friction = b.friction = 0;
		for (_ in 0...120)
			w3.step(dt);
		var p = a.velocity.x * 1 + b.velocity.x * 3;
		check('momentum kept ($p)', near(p, 4, 1e-9) && a.velocity.x < 0 && b.velocity.x > 0);
		var energy = 0.5 * a.velocity.x * a.velocity.x + 1.5 * b.velocity.x * b.velocity.x;
		check('an elastic collision keeps energy ($energy)', near(energy, 8, 1e-6));
		// a box as a step
		var w4 = new PhysicsWorld();
		w4.add(new Body(Box(new Vec3(1, 0.5, 1)), new Vec3(0, 0.5, 0), 0));
		var onBox = w4.add(new Body(Sphere(0.25), new Vec3(0.2, 2, 0)));
		for (_ in 0...240)
			w4.step(dt);
		check("rests on the box", near(onBox.position.y, 1.25, 0.01));
		// raycasts
		var hit = w4.raycast(new Vec3(0.2, 5, 0), new Vec3(0, -1, 0));
		check("raycast hits the ball first", hit != null && hit.body == onBox && near(hit.distance, 5 - 1.5, 0.02));
		var boxHit = w4.raycast(new Vec3(-5, 0.5, 0), new Vec3(1, 0, 0));
		check("raycast hits the box", boxHit != null && near(boxHit.distance, 4, 1e-9));
		check("raycast misses", w4.raycast(new Vec3(-5, 5, 0), new Vec3(-1, 0, 0)) == null);
		// sleeping, then woken by an impulse
		check("asleep", onBox.sleeping);
		onBox.applyImpulse(new Vec3(0, 3, 0));
		w4.step(dt);
		check("woken by an impulse", !onBox.sleeping && onBox.position.y > 1.25);
		// a node moved by its body
		var world = new World();
		var node = world.node("ball");
		var w5 = new PhysicsWorld();
		w5.add(new Body(Plane(new Vec3(0, 1, 0), 0), new Vec3(0, 0, 0), 0));
		var nb = w5.add(new Body(Sphere(0.5), new Vec3(1, 4, 2)), node);
		w5.step(dt);
		check("the node follows its body", node.position.y == nb.position.y && node.position.x == 1);
		// boxes: tilted, one falls flat on the plane; a second stacks on it
		var w6 = new PhysicsWorld();
		w6.add(new Body(Plane(new Vec3(0, 1, 0), 0), new Vec3(0, 0, 0), 0));
		var box = w6.add(new Body(Box(new Vec3(0.5, 0.25, 0.5)), new Vec3(0, 1.5, 0)));
		box.orientation = hxmc.scene.math.Quat.axisAngle(new Vec3(1, 0, 1), 0.5);
		var turned = false;
		var top:Null<Body> = null;
		for (k in 0...600) {
			// (the second box dropped once the first lies still)
			if (k == 300) top = w6.add(new Body(Box(new Vec3(0.3, 0.3, 0.3)), box.position + new Vec3(0.05, 1.5, 0)));
			w6.step(dt);
			var a = box.angular;
			if (a.x * a.x + a.y * a.y + a.z * a.z > 0.01) turned = true;
		}
		var up = box.orientation.rotate(new Vec3(0, 1, 0));
		check('a tilted box tumbles flat (up ${Math.round(up.y * 1000) / 1000}, y ${Math.round(box.position.y * 1000) / 1000})',
			turned && Math.abs(up.y) > 0.99 && near(box.position.y, 0.25, 0.03));
		check('a box stacks on it (y ${Math.round(top.position.y * 1000) / 1000})', near(top.position.y, 0.5 + 0.3, 0.05));
		// crates of one size stacked three high (their corners on each other's edges) stay stacked
		var sw = new PhysicsWorld();
		sw.add(new Body(Plane(new Vec3(0, 1, 0), 0), new Vec3(0, 0, 0), 0));
		var crates = [for (k in 0...3) sw.add(new Body(Box(new Vec3(0.3, 0.3, 0.3)), new Vec3(0, 0.3 + 0.6 * k, 0)))];
		for (_ in 0...300)
			sw.step(dt);
		var stacked = true;
		for (k in 0...3)
			if (!near(crates[k].position.y, 0.3 + 0.6 * k, 0.02) || !near(crates[k].position.x, 0, 0.05)) stacked = false;
		check('crates of one size stack (top y ${Math.round(crates[2].position.y * 1000) / 1000})', stacked);
		// a turned box's raycast: from above at a corner's reach
		var rb = new PhysicsWorld();
		var turnedBox = rb.add(new Body(Box(new Vec3(1, 1, 1)), new Vec3(0, 0, 0), 0));
		turnedBox.orientation = hxmc.scene.math.Quat.axisAngle(new Vec3(0, 0, 1), Math.PI / 4);
		var rh = rb.raycast(new Vec3(0, 5, 0), new Vec3(0, -1, 0));
		check("raycast on a turned box", rh != null && near(rh.distance, 5 - Math.sqrt(2), 1e-9));
		// capsules: one kept upright stands on the plane and on a box, one tilted falls flat
		var cw = new PhysicsWorld();
		cw.add(new Body(Plane(new Vec3(0, 1, 0), 0), new Vec3(0, 0, 0), 0));
		cw.add(new Body(Box(new Vec3(1, 0.5, 1)), new Vec3(4, 0.5, 0), 0));
		var standing = cw.add(new Body(Capsule(0.3, 0.6), new Vec3(0, 2, 0)));
		standing.rotates = false;
		var onStep = cw.add(new Body(Capsule(0.3, 0.6), new Vec3(4.2, 3, 0)));
		onStep.rotates = false;
		var lying = cw.add(new Body(Capsule(0.25, 0.5), new Vec3(-3, 2, 0)));
		lying.orientation = hxmc.scene.math.Quat.axisAngle(new Vec3(0, 0, 1), 0.4);
		for (_ in 0...400)
			cw.step(dt);
		check('an upright capsule stands on the plane (y ${Math.round(standing.position.y * 1000) / 1000})',
			near(standing.position.y, 0.9, 0.01) && standing.orientation.rotate(new Vec3(0, 1, 0)).y > 0.9999);
		check('and on a box (y ${Math.round(onStep.position.y * 1000) / 1000})', near(onStep.position.y, 1.9, 0.01));
		var axis = lying.orientation.rotate(new Vec3(0, 1, 0));
		check('a tilted capsule falls flat (axis y ${Math.round(axis.y * 1000) / 1000}, y ${Math.round(lying.position.y * 1000) / 1000})',
			Math.abs(axis.y) < 0.02 && near(lying.position.y, 0.25, 0.01));
		// capsules' contacts and raycasts
		var cap = new Body(Capsule(0.5, 1), new Vec3(0, 0, 0), 0);
		var contacts = [];
		Collide.test(cap, new Body(Sphere(0.5), new Vec3(0.9, 0.5, 0)), contacts);
		check("capsule and sphere: along the side", contacts.length == 1 && near(contacts[0].depth, 0.1, 1e-9) && near(contacts[0].normal.x, 1, 1e-9));
		var across = new Body(Capsule(0.5, 1), new Vec3(0, 0, 0), 0);
		across.orientation = hxmc.scene.math.Quat.axisAngle(new Vec3(0, 0, 1), Math.PI / 2);
		var other = new Body(Capsule(0.5, 1), new Vec3(0, 0.9, 0), 0);
		other.orientation = hxmc.scene.math.Quat.axisAngle(new Vec3(1, 0, 0), Math.PI / 2);
		contacts = [];
		Collide.test(across, other, contacts);
		check("crossed capsules", contacts.length == 1 && near(contacts[0].depth, 0.1, 1e-9) && near(contacts[0].normal.y, 1, 1e-9));
		var cr = new PhysicsWorld();
		cr.add(new Body(Capsule(0.5, 1), new Vec3(0, 0, 0), 0));
		var endHit = cr.raycast(new Vec3(0, 5, 0), new Vec3(0, -1, 0)), side = cr.raycast(new Vec3(-5, 0.7, 0), new Vec3(1, 0, 0));
		check("a capsule's raycasts: its end, its side", endHit != null && near(endHit.distance, 3.5, 1e-9) && side != null && near(side.distance, 4.5, 1e-9)
			&& cr.raycast(new Vec3(-5, 1.6, 0), new Vec3(1, 0, 0)) == null);
		// a character walks, stops at a wall and jumps
		var chw = new PhysicsWorld();
		chw.add(new Body(Plane(new Vec3(0, 1, 0), 0), new Vec3(0, 0, 0), 0));
		chw.add(new Body(Box(new Vec3(0.5, 2, 3)), new Vec3(6, 2, 0), 0));
		var hero = new Character(chw, new Vec3(0, 0.95, 0));
		for (_ in 0...30) {
			hero.update(dt, new Vec3(0, 0, 0), false);
			chw.step(dt);
		}
		check("a character stands on the ground", hero.grounded && near(hero.body.position.y, 0.9, 0.01));
		for (_ in 0...60) {
			hero.update(dt, new Vec3(1, 0, 0), false);
			chw.step(dt);
		}
		check('walks at its speed (${Math.round(hero.body.velocity.x * 100) / 100} m/s)', near(hero.body.velocity.x, hero.speed, 0.05) && hero.grounded);
		for (_ in 0...120) {
			hero.update(dt, new Vec3(1, 0, 0), false);
			chw.step(dt);
		}
		check('stops at the wall (x ${Math.round(hero.body.position.x * 1000) / 1000})', near(hero.body.position.x, 5.5 - 0.3, 0.03)
			&& hero.body.orientation.rotate(new Vec3(0, 1, 0)).y > 0.9999);
		var peak = 0.0;
		hero.update(dt, new Vec3(0, 0, 0), true);
		chw.step(dt);
		check("leaves the ground", !hero.grounded);
		for (_ in 0...90) {
			hero.update(dt, new Vec3(0, 0, 0), false);
			chw.step(dt);
			peak = Math.max(peak, hero.body.position.y - 0.9);
		}
		var expected = hero.jumpSpeed * hero.jumpSpeed / (2 * 9.81);
		check('jumps about v^2 / 2g high (${Math.round(peak * 100) / 100} m)', near(peak, expected, 0.1) && hero.grounded);
		// a character climbs a step onto a platform, not a wall
		var stw = new PhysicsWorld();
		stw.add(new Body(Plane(new Vec3(0, 1, 0), 0), new Vec3(0, 0, 0), 0));
		stw.add(new Body(Box(new Vec3(1.5, 0.125, 2)), new Vec3(3.5, 0.125, 0), 0));
		stw.add(new Body(Box(new Vec3(0.5, 1, 2)), new Vec3(5.5, 1, 0), 0));
		var climber = new Character(stw, new Vec3(0, 0.95, 0));
		for (_ in 0...180) {
			climber.update(dt, new Vec3(1, 0, 0), false);
			stw.step(dt);
		}
		check('a character climbs a step (y ${Math.round(climber.body.position.y * 1000) / 1000}, x ${Math.round(climber.body.position.x * 1000) / 1000})',
			near(climber.body.position.y, 0.25 + 0.9, 0.02) && near(climber.body.position.x, 5 - 0.3, 0.05));
		// joints: a pendulum on a ball joint swings at its period and keeps its length
		var jw = new PhysicsWorld();
		var bob = jw.add(new Body(Sphere(0.1), new Vec3(Math.sin(0.2), 3 - Math.cos(0.2), 0)));
		// (the bob's point at the pivot: a rod of 1 m, the bob's frame turning with it)
		jw.join(Joint.ball(bob, new Vec3(-Math.sin(0.2), Math.cos(0.2), 0), null, new Vec3(0, 3, 0)));
		var worst = 0.0, crossings = [], last = bob.position.x;
		for (k in 0...400) {
			jw.step(dt);
			var d = bob.position - new Vec3(0, 3, 0);
			worst = Math.max(worst, Math.abs(Math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) - 1));
			if (last > 0 && bob.position.x <= 0) crossings.push(k * dt);
			last = bob.position.x;
		}
		var period = crossings.length >= 2 ? crossings[crossings.length - 1] - crossings[crossings.length - 2] : 0;
		check('a pendulum keeps its length (off by ${Math.round(worst * 1000)} mm)', worst < 0.01);
		check('and swings at 2 pi sqrt(l / g) (${Math.round(period * 1000) / 1000} s)', near(period, 2 * Math.PI * Math.sqrt(1 / 9.81), 0.05));
		// a door on a hinge: pushed at its free edge, it swings about its
		// hinge, which stays put, its axis upright
		var hw = new PhysicsWorld();
		hw.gravity = new Vec3(0, 0, 0);
		var door = hw.add(new Body(Box(new Vec3(0.5, 1, 0.05)), new Vec3(0.5, 1, 0)));
		hw.join(Joint.hinge(door, new Vec3(-0.5, 0, 0), new Vec3(0, 1, 0), null, new Vec3(0, 1, 0), new Vec3(0, 1, 0)));
		door.applyImpulse(new Vec3(0, 0.3, -1.5), new Vec3(1, 1.6, 0));
		// (about 4.5 radians a second about the hinge: a sixth of a second)
		for (_ in 0...10)
			hw.step(dt);
		var hinge = door.position + door.orientation.rotate(new Vec3(-0.5, 0, 0)), up = door.orientation.rotate(new Vec3(0, 1, 0));
		var swung = door.orientation.rotate(new Vec3(1, 0, 0));
		check('a door swings on its hinge (x axis z ${Math.round(swung.z * 1000) / 1000}, hinge off ${Math.round(Math.sqrt((hinge.x * hinge.x) + (hinge.y - 1) * (hinge.y - 1) + hinge.z * hinge.z) * 1000)} mm, up ${Math.round(up.y * 1000) / 1000})',
			near(hinge.x, 0, 0.01) && near(hinge.y, 1, 0.01) && near(hinge.z, 0, 0.01) && up.y > 0.999 && swung.z < -0.3);
		// a chain of five links on distance joints hangs from a point, links apart
		var cw2 = new PhysicsWorld();
		var links = [for (k in 0...5) cw2.add(new Body(Sphere(0.08), new Vec3(0.3 * (k + 1), 4, 0)))];
		cw2.join(Joint.distanceOf(links[0], new Vec3(0, 0, 0), null, new Vec3(0, 4, 0)));
		for (k in 1...5)
			cw2.join(Joint.distanceOf(links[k], new Vec3(0, 0, 0), links[k - 1], new Vec3(0, 0, 0)));
		for (_ in 0...600)
			cw2.step(dt);
		var held = true;
		for (k in 0...5) {
			var prev = k == 0 ? new Vec3(0, 4, 0) : links[k - 1].position, d = links[k].position - prev;
			if (Math.abs(Math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) - 0.3) > 0.02) held = false;
		}
		check('a chain hangs, its links apart (bottom y ${Math.round(links[4].position.y * 1000) / 1000})', held && links[4].position.y < 4 - 1.3);
		// determinism: a pile of balls in a box of planes
		var pile = new PhysicsWorld();
		pile.add(new Body(Plane(new Vec3(0, 1, 0), 0), new Vec3(0, 0, 0), 0));
		for (n in [new Vec3(1, 0, 0), new Vec3(-1, 0, 0), new Vec3(0, 0, 1), new Vec3(0, 0, -1)])
			pile.add(new Body(Plane(n, -2), new Vec3(0, 0, 0), 0));
		for (k in 0...12)
			pile.add(new Body(Sphere(0.3), new Vec3((k % 3) * 0.7 - 0.7 + k * 0.01, 1 + k * 0.5, (k % 2) * 0.4 - 0.2)));
		// (and boxes, landing on the balls and tumbling: rotation in the checksum)
		for (k in 0...3)
			pile.add(new Body(Box(new Vec3(0.25, 0.2, 0.3)), new Vec3(k * 0.6 - 0.6, 8 + k, 0.1 * k)));
		for (_ in 0...300)
			pile.step(dt);
		var sum = 0.0;
		for (bd in pile.bodies)
			sum += bd.position.x * 3 + bd.position.y * 5 + bd.position.z * 7 + bd.orientation.x * 11 + bd.orientation.y * 13;
		var inside = true;
		for (bd in pile.bodies)
			if (!bd.isStatic() && (Math.abs(bd.position.x) > 1.75 || Math.abs(bd.position.z) > 1.75 || bd.position.y < 0.19)) inside = false;
		check("the pile stays in its box", inside);
		Sys.println('PhysicsTest: pile checksum ${Math.round(sum * 1e6)}');
		// (the value on Eval, natively and as wasm32-wasi alike)
		check("the pile's checksum, the same on every target", Math.round(sum * 1e6) == CHECKSUM);
		Sys.println('PhysicsTest: $checks checks, ' + (failed == 0 ? "ok" : '$failed FAILED'));
		if (failed > 0) Sys.exit(1);
	}
}
