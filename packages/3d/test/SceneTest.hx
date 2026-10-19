import hxmc.gfx.shader.Mat4;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.*;
import hxmc.scene.math.*;

using hxmc.scene.math.MathTools;

// packages/3d's step 1 (make 3d-check: on Eval and natively): the math
// (Quat, MathTools on gfx's Mat4, Aabb) against gfx's own matrices and
// against each other, the scene graph's matrices and their cache, the
// camera and the fixed-step clock. Exits 1 on a failed check.
class SceneTest {
	static var checks = 0;
	static var failed = 0;

	static function check(what:String, ok:Bool) {
		checks++;
		if (!ok) {
			failed++;
			Sys.println('SceneTest: FAIL: $what');
		}
	}

	static function near(a:Float, b:Float, eps = 1e-9):Bool
		return Math.abs(a - b) <= eps;

	static function nearV(a:Vec3, b:Vec3, eps = 1e-9):Bool
		return near(a.x, b.x, eps) && near(a.y, b.y, eps) && near(a.z, b.z, eps);

	static function nearQ(a:Quat, b:Quat, eps = 1e-9):Bool
		return Math.abs(Math.abs(a.dot(b)) - 1) <= eps;

	public static function main() {
		quats();
		matrices();
		boxes();
		nodes();
		cameras();
		clock();
		hot();
		stages();
		assets();
		Sys.println('SceneTest: $checks checks, ' + (failed == 0 ? "ok" : '$failed FAILED'));
		if (failed > 0) Sys.exit(1);
	}

	static function quats() {
		var x = new Vec3(1, 0, 0), y = new Vec3(0, 1, 0), z = new Vec3(0, 0, 1);
		for (a in [0.0, 0.3, -1.2, Math.PI, 2.5]) {
			check('axisAngle(x, $a) is rotationX', Quat.axisAngle(x, a).toMat4().near(Mat4.rotationX(a), 1e-12));
			check('axisAngle(y, $a) is rotationY', Quat.axisAngle(y, a).toMat4().near(Mat4.rotationY(a), 1e-12));
			check('axisAngle(z, $a) is rotationZ', Quat.axisAngle(z, a).toMat4().near(Mat4.rotationZ(a), 1e-12));
		}
		var q = Quat.fromEuler(0.4, -0.7, 1.1);
		check("fromEuler is rotZ * rotY * rotX", q.toMat4().near(Mat4.rotationZ(1.1) * Mat4.rotationY(-0.7) * Mat4.rotationX(0.4), 1e-12));
		var p = Quat.axisAngle(new Vec3(1, 2, 3), 0.8), v = new Vec3(0.3, -2, 5);
		check("rotate is toMat4 * v", nearV(p.rotate(v), p.toMat4().transformDir(v), 1e-12));
		check("q * p is toMat4 * toMat4", (q * p).toMat4().near(q.toMat4() * p.toMat4(), 1e-12));
		check("q * conjugate is the identity", nearQ(q * q.conjugate(), Quat.identity()));
		check("unit length", near(q.length(), 1, 1e-12));
		for (r in [q, p, Quat.axisAngle(x, Math.PI), Quat.axisAngle(y, Math.PI), Quat.axisAngle(z, Math.PI), Quat.axisAngle(new Vec3(1, 1, 0), 3)])
			check("fromMat4(toMat4) round trip", nearQ(Quat.fromMat4(r.toMat4()), r, 1e-12));
		var a = Quat.axisAngle(y, 0.2), b = Quat.axisAngle(y, 1.4);
		check("slerp at 0", nearQ(Quat.slerp(a, b, 0), a));
		check("slerp at 1", nearQ(Quat.slerp(a, b, 1), b));
		check("slerp halfway", nearQ(Quat.slerp(a, b, 0.5), Quat.axisAngle(y, 0.8), 1e-12));
		check("slerp the short way", nearQ(Quat.slerp(a, new Quat(-b.x, -b.y, -b.z, -b.w), 0.25), Quat.axisAngle(y, 0.5), 1e-12));
	}

	static function matrices() {
		var m = MathTools.compose(new Vec3(1, -2, 3), Quat.fromEuler(0.3, 0.2, -0.9), new Vec3(2, 0.5, 1.5));
		check("inverse * m", (m.inverse() * m).near(Mat4.identity(), 1e-12));
		check("m * inverse", (m * m.inverse()).near(Mat4.identity(), 1e-12));
		var proj = Mat4.perspective(1, 1.5, 0.1, 100);
		check("perspective's inverse", (proj.inverse() * proj).near(Mat4.identity(), 1e-9));
		check("determinant of a scaling", near(Mat4.scaling(2, 3, 4).determinant(), 24));
		check("determinant of m", near(m.determinant(), 2 * 0.5 * 1.5, 1e-12));
		check("transpose twice", m.transpose().transpose().near(m));
		check("transpose of a rotation is its inverse", Mat4.rotationY(0.7).transpose().near(Mat4.rotationY(-0.7), 1e-12));
		check("compose is T * R * S",
			m.near(Mat4.translation(1, -2, 3) * Quat.fromEuler(0.3, 0.2, -0.9).toMat4() * Mat4.scaling(2, 0.5, 1.5), 1e-12));
		var d = m.decompose();
		check("decompose: translation", nearV(d.t, new Vec3(1, -2, 3), 1e-12));
		check("decompose: rotation", nearQ(d.r, Quat.fromEuler(0.3, 0.2, -0.9), 1e-12));
		check("decompose: scale", nearV(d.s, new Vec3(2, 0.5, 1.5), 1e-12));
		var eye = new Vec3(3, 4, 5), target = new Vec3(0, 1, 0);
		var view = MathTools.lookAt(eye, target, new Vec3(0, 1, 0));
		check("lookAt: the eye at the origin", nearV(view.transformPoint(eye), new Vec3(0, 0, 0), 1e-12));
		var t = view.transformPoint(target);
		check("lookAt: the target down -z", near(t.x, 0, 1e-12) && near(t.y, 0, 1e-12) && t.z < 0);
		var r = MathTools.lookRotation(target - eye, new Vec3(0, 1, 0));
		check("lookRotation is lookAt's camera", MathTools.compose(eye, r, new Vec3(1, 1, 1)).inverse().near(view, 1e-12));
		check("transformPoint", nearV(Mat4.translation(1, 2, 3).transformPoint(new Vec3(1, 1, 1)), new Vec3(2, 3, 4)));
		check("transformDir ignores translation", nearV(Mat4.translation(1, 2, 3).transformDir(new Vec3(1, 1, 1)), new Vec3(1, 1, 1)));
		var n = MathTools.normalMatrix(Mat4.scaling(2, 1, 1));
		check("normalMatrix of a scaling", nearV(n.transformDir(new Vec3(1, 1, 0)), new Vec3(0.5, 1, 0)));
	}

	static function boxes() {
		var b = new Aabb(new Vec3(-1, -1, -1), new Vec3(1, 1, 1));
		check("contains", b.contains(new Vec3(0.5, -0.5, 1)) && !b.contains(new Vec3(1.5, 0, 0)));
		check("empty", Aabb.empty().isEmpty() && !b.isEmpty());
		check("union with empty", nearV(Aabb.empty().union(b).min, b.min) && nearV(Aabb.empty().union(b).max, b.max));
		var p = Aabb.ofPoints([0, 1, 2, -3, 5, 1, 2, -1, 0]);
		check("ofPoints", nearV(p.min, new Vec3(-3, -1, 0)) && nearV(p.max, new Vec3(2, 5, 2)));
		var t = b.transform(Mat4.translation(5, 0, 0) * Mat4.rotationZ(Math.PI / 4));
		var s = Math.sqrt(2);
		check("transform", nearV(t.min, new Vec3(5 - s, -s, -1), 1e-12) && nearV(t.max, new Vec3(5 + s, s, 1), 1e-12));
		check("intersects", b.intersects(new Aabb(new Vec3(0.5, 0.5, 0.5), new Vec3(3, 3, 3))) && !b.intersects(t));
		check("ray hits", near(b.ray(new Vec3(-5, 0, 0), new Vec3(1, 0, 0)), 4));
		check("ray misses", b.ray(new Vec3(-5, 2, 0), new Vec3(1, 0, 0)) == -1);
		check("ray from inside", b.ray(new Vec3(0, 0, 0), new Vec3(0, 0, 1)) == 0);
		check("ray pointing away", b.ray(new Vec3(-5, 0, 0), new Vec3(-1, 0, 0)) == -1);
		check("centre and size", nearV(t.center(), new Vec3(5, 0, 0), 1e-12) && nearV(b.size(), new Vec3(2, 2, 2)));
	}

	static function nodes() {
		var world = new World("scene");
		var root = world.root;
		var arm = world.node("arm"), hand = arm.add(world.node("hand"));
		check("handles", !arm.isNone && arm.valid && arm.parent == root && hand.parent == arm && world.count == 3);
		arm.position = new Vec3(2, 0, 0);
		arm.rotation = Quat.axisAngle(new Vec3(0, 0, 1), Math.PI / 2);
		hand.position = new Vec3(1, 0, 0);
		hand.scale = new Vec3(2, 2, 2);
		check("TRS read back", nearV(hand.position, new Vec3(1, 0, 0)) && nearV(hand.scale, new Vec3(2, 2, 2)) && nearQ(arm.rotation, Quat.axisAngle(new Vec3(0, 0, 1), Math.PI / 2)));
		check("world is the parent's world * local", hand.worldMatrix().near(arm.worldMatrix() * hand.localMatrix(), 1e-12));
		check("a child's position turned with its parent", nearV(hand.worldPosition(), new Vec3(2, 1, 0), 1e-12));
		var v = @:privateAccess world.versionOf(hand.slot);
		hand.worldMatrix();
		check("a still node's world is cached", @:privateAccess world.versionOf(hand.slot) == v);
		arm.position = new Vec3(0, 0, 0);
		check("moving the parent moves the child", nearV(hand.worldPosition(), new Vec3(0, 1, 0), 1e-12));
		check("the child's world recomputed once", @:privateAccess world.versionOf(hand.slot) == v + 1);
		var other = world.node("other");
		other.position = new Vec3(0, 0, -3);
		other.add(hand);
		check("reparented", hand.parent == other && arm.children().hasNext() == false && nearV(hand.worldPosition(), new Vec3(1, 0, -3), 1e-12));
		check("find", root.find("hand") == hand && root.find("nothing").isNone);
		var order = [];
		root.walk(n -> order.push(n.name));
		check("walk: parents first", order.join(",") == "scene,arm,other,hand");
		check("children in order", [for (c in root.children()) c.name].join(",") == "arm,other");
		var threw = try {
			hand.add(other);
			false;
		} catch (e:String) true;
		check("no cycles", threw && other.parent == root);
		hand.visible = false;
		check("shown", !hand.shown() && other.shown());
		var m = MathTools.compose(new Vec3(1, 2, 3), Quat.fromEuler(0.1, 0.2, 0.3), new Vec3(1, 2, 1));
		var n = world.node();
		n.setMatrix(m);
		check("setMatrix", n.localMatrix().near(m, 1e-12));
		var t = world.node();
		t.position = new Vec3(0, 0, 5);
		t.lookAt(new Vec3(0, 0, 0));
		check("lookAt turns -z to the target", nearV(t.worldMatrix().transformDir(new Vec3(0, 0, -1)), new Vec3(0, 0, -1), 1e-12));
		// disposal: the subtree's handles go stale, their slots are reused
		var kind = new StoreKind<String>("tag");
		world.store(kind).set(hand, "a hand");
		var before = world.count;
		other.dispose();
		check("disposed: the subtree", !other.valid && !hand.valid && world.count == before - 2 && world.store(kind).length == 0);
		var stale = try {
			hand.position;
			false;
		} catch (e:String) true;
		check("a stale handle throws", stale);
		var reused = world.node("again");
		check("a slot reused, a new generation", reused != hand && reused != other && reused.valid && !hand.valid);
		check("detach", {
			arm.detach();
			arm.parent.isNone && !world.inTree(arm) && arm.valid;
		});
		var w2 = new World("second");
		var x = w2.node("x");
		check("two worlds", x.world == w2 && arm.world == world && w2.root.find("x") == x);
		w2.dispose();
	}

	static function cameras() {
		var world = new World();
		var eye = world.node("eye");
		var cam = Camera.attach(eye, Camera.perspective(Math.PI / 3, 0.1, 100));
		eye.position = new Vec3(4, 3, 6);
		eye.lookAt(new Vec3(0, 1, 0));
		check("the camera's node", cam.node == eye && Camera.of(eye) == cam && Camera.first(world) == cam);
		check("view puts the eye at the origin", nearV(cam.view().transformPoint(eye.position), new Vec3(0, 0, 0), 1e-12));
		var c = cam.viewProjection(1.5).transformPoint(new Vec3(0, 1, 0));
		check("the target at the view's centre", near(c.x, 0, 1e-12) && near(c.y, 0, 1e-12) && c.z > 0 && c.z < 1);
		var r = cam.ray(0, 0, 1.5);
		var toTarget = new Vec3(0, 1, 0) - eye.position;
		check("the centre's ray points at the target",
			nearV(r.dir, toTarget / Math.sqrt(toTarget.x * toTarget.x + toTarget.y * toTarget.y + toTarget.z * toTarget.z), 1e-9));
		var o = Camera.orthographic(4, 0.1, 10);
		var top = o.projection(2).transformPoint(new Vec3(4, 2, -5));
		check("orthographic: its height and aspect", near(top.x, 1, 1e-12) && near(top.y, 1, 1e-12));
		var other = world.node();
		Camera.attach(other, cam);
		check("a camera moves to its new node", Camera.of(eye) == null && cam.node == other);
		world.dispose();
	}

	static function hot() {
		// (a reload: the world made again as main makes it, the old transforms put back by path)
		function build():World {
			var w = new World();
			var a = w.node("a"), b = w.node("b", a);
			w.node("b", a);
			w.node("gone");
			return w;
		}
		var old = build();
		var a = old.root.find("a"), b2 = [for (c in a.children()) c][1];
		a.position = new Vec3(1, 2, 3);
		b2.rotation = Quat.axisAngle(new Vec3(0, 1, 0), 0.4);
		var saved = HotWorld.save(old);
		check("paths", saved.paths.join(",") == ",/a,/a/b,/a/b#1,/gone" && saved.trs.length == 50);
		var fresh = new World();
		var fa = fresh.node("a");
		fresh.node("b", fa);
		var fb2 = fresh.node("b", fa);
		var added = fresh.node("added");
		added.position = new Vec3(9, 9, 9);
		check("restored by path", HotWorld.restore(fresh, saved) == 4);
		check("restored values", nearV(fa.position, new Vec3(1, 2, 3)) && nearQ(fb2.rotation, Quat.axisAngle(new Vec3(0, 1, 0), 0.4), 1e-12)
			&& nearV(added.position, new Vec3(9, 9, 9)));
		HotWorld.keep(fresh, "test.world");
		old.dispose();
		fresh.dispose();
	}

	static function stages() {
		var s = new Stages(new FixedStep(0.25));
		var log = [];
		var alpha = -1.0;
		s.on(PreRender, a -> {
			log.push("pre");
			alpha = a;
		});
		s.on(Update, dt -> log.push("update " + dt));
		s.on(FixedUpdate, dt -> log.push("fixed " + dt));
		var off = s.on(Input, _ -> log.push("input"));
		s.on(LateUpdate, _ -> log.push("late"));
		s.frame(0.6);
		check("stages in order, fixed steps as the frame holds", log.join(",") == "input,fixed 0.25,fixed 0.25,update 0.6,late,pre" && near(alpha, 0.4, 1e-9));
		off();
		log = [];
		s.frame(0.15);
		check("removed; a fixed step from what was left", log.join(",") == "fixed 0.25,update 0.15,late,pre");
	}

	static function assets() {
		var a = new Asset<Int>(), got = [];
		a.then(v -> got.push("then " + v));
		check("loading", a.state.match(Loading) && !a.ready);
		var polls = 0;
		Assets.track(() -> {
			polls++;
			if (polls < 3) return false;
			a.resolve(7);
			return true;
		});
		check("still loading", Assets.poll() == 1 && !a.ready);
		check("loaded on a later poll", Assets.poll() == 0 && a.ready && a.value == 7 && got.join(",") == "then 7");
		a.onChange(v -> got.push("changed " + v));
		a.then(v -> got.push("late " + v));
		a.resolve(8);
		check("then at once when ready; onChange on a swap", got.join(",") == "then 7,late 7,changed 8" && a.value == 8);
		var b = new Asset<String>();
		b.fail("gone");
		check("failed", switch b.state {
			case Failed(e): e == "gone";
			case _: false;
		});
	}

	static function clock() {
		var dt = 1 / 60, s = new FixedStep(dt), n = 0;
		check("three frames of a step", s.advance(dt, _ -> n++) == 1 && s.advance(dt, _ -> n++) == 1 && s.advance(dt, _ -> n++) == 1 && n == 3);
		check("time", near(s.time, 3 * dt, 1e-12));
		check("half a step: no step", s.advance(dt / 2, _ -> n++) == 0 && near(s.alpha, 0.5, 1e-9));
		check("the other half", s.advance(dt / 2, _ -> n++) == 1 && near(s.alpha, 0, 1e-9));
		var taken = s.advance(1.0, _ -> n++);
		check("a stall: at most maxSteps", taken == 5 && s.accumulator < dt);
		var saved = s.save(), t = new FixedStep(dt);
		t.restore(saved);
		check("save and restore", t.steps == s.steps && near(t.time, s.time) && near(t.alpha, s.alpha));
		// at 144 Hz frames: 60 steps a second still
		var u = new FixedStep(dt), steps = 0;
		for (i in 0...144)
			steps += u.advance(1 / 144, _ -> {});
		check("144 Hz frames: 60 steps a second", steps == 60 || steps == 59);
	}
}
