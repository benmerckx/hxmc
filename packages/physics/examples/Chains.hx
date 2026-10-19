// title: Chains
// summary: Chains of balls on @hxmc/physics' distance joints hanging from a beam, a heavy ball on a ball joint swinging through them; click to swing it again
// tags: 3d, physics
// demo: canvas 512x384
import hxmc.gfx.*;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.os.*;
import hxmc.physics.*;
import hxmc.scene.*;
import hxmc.scene.math.*;
import hxmc.scene.render.*;

// Joints: each chain's links held apart by Joint.distanceOf (the first to a
// point of the beam), the wrecking ball on a Joint.ball about a pivot above;
// links and ball collide as any bodies. A click pulls the ball back up;
// Escape closes.
//
//   haxe -cp packages/os/src -cp packages/gfx/src -cp packages/3d/src -cp packages/physics/src
//     -cp packages/physics/examples -main Chains --custom-target hxmc=chains -D hxmc.libc=glibc
class Chains {
	public final world = new World("chains");
	public final physics = new PhysicsWorld();
	public final renderer:Renderer;
	public final camera:Camera;
	public final wrecker:Body;

	public function new(device:Device) {
		renderer = new Renderer(device).use(new Shadows(device, 1024));
		var floor = world.node("floor");
		MeshRenderer.attach(floor, Shapes.box(device, new Material("floor", new Vec4(0.5, 0.52, 0.56, 1), 0, 0.8), 10, 0.2, 6));
		floor.position = new Vec3(0, -0.1, 0);
		physics.add(new Body(Plane(new Vec3(0, 1, 0), 0), new Vec3(0, 0, 0), 0));
		var beam = world.node("beam");
		MeshRenderer.attach(beam, Shapes.box(device, new Material("beam", new Vec4(0.45, 0.3, 0.2, 1), 0, 0.7), 5, 0.2, 0.2));
		beam.position = new Vec3(0, 3.6, 0);
		var link = Shapes.sphere(device, new Material("link", new Vec4(0.85, 0.85, 0.9, 1), 1, 0.3), 0.12, 16, 8);
		for (c in 0...5) {
			var x = -1.6 + c * 0.8, prev:Null<Body> = null;
			for (k in 0...8) {
				var n = world.node("link");
				MeshRenderer.attach(n, link);
				var b = physics.add(new Body(Sphere(0.12), new Vec3(x, 3.2 - k * 0.3, 0), 0.5), n);
				physics.join(prev == null ? Joint.distanceOf(b, new Vec3(0, 0, 0), null, new Vec3(x, 3.5, 0)) : Joint.distanceOf(b, new Vec3(0, 0, 0), prev,
					new Vec3(0, 0, 0)));
				prev = b;
			}
		}
		var ball = world.node("wrecker");
		MeshRenderer.attach(ball, Shapes.sphere(device, new Material("wrecker", new Vec4(0.9, 0.35, 0.15, 1), 0, 0.4), 0.35, 24, 12));
		wrecker = physics.add(new Body(Sphere(0.35), new Vec3(0, 3.6, 2.6), 8), ball);
		physics.join(Joint.ball(wrecker, new Vec3(0, 0, -2.6), null, new Vec3(0, 3.6, 0)));
		var sun = world.node("sun");
		Light.attach(sun, Light.directional(new Vec3(1, 0.96, 0.9), 2.6));
		sun.rotation = Quat.fromEuler(-1.0, -0.6, 0);
		var eye = world.node("eye");
		camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
		eye.position = new Vec3(3.8, 3.2, 5.2);
		eye.lookAt(new Vec3(0, 1.3, 0.4));
	}

	// the ball pulled back up towards the camera, at rest
	public function swing() {
		wrecker.position = new Vec3(0, 3.6, 2.6);
		wrecker.velocity = new Vec3(0, 0, 0);
		wrecker.angular = new Vec3(0, 0, 0);
		wrecker.orientation = Quat.identity();
		wrecker.wake();
	}

	public function draw(enc:Encoder)
		renderer.draw(enc, world, camera);

	static function main() {
		var window = new Window("Chains", 640, 480);
		var device = Device.create(window.surface);
		var scene = new Chains(device);
		var stages = new Stages(new FixedStep(1 / 60)), last = Sys.time();
		stages.on(FixedUpdate, dt -> scene.physics.step(dt));
		App.run(() -> {
			var now = Sys.time();
			stages.frame(Math.min(now - last, 0.25));
			last = now;
			var enc = device.beginFrame();
			if (enc == null) return;
			scene.draw(enc);
			device.endFrame();
		}, e -> switch e.kind {
			case Close: window.close();
			case KeyDown if (e.key == 0xFF1B): window.close();
			case MouseDown: scene.swing();
			case _:
		});
	}
}
