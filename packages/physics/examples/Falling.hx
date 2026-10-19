// title: Falling
// summary: Balls and tumbling boxes dropped into a walled box by @hxmc/physics (contacts with angular impulses, restitution, friction, sleeping at a fixed step), drawn by @hxmc/3d with shadows; click to drop more
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

// A physics world beside a scene: each ball a Body keyed on its Node (the
// body moves the node after each step), the floor a static plane drawn as
// a box, the walls static boxes; the simulation at 60 steps a second
// (the frame's Stages: FixedUpdate). A click drops another ball; Escape closes.
//
//   haxe -cp packages/os/src -cp packages/gfx/src -cp packages/3d/src -cp packages/physics/src
//     -cp packages/physics/examples -main Falling --custom-target hxmc=falling -D hxmc.libc=glibc
class Falling {
	public final world = new World("falling");
	public final physics = new PhysicsWorld();
	public final renderer:Renderer;
	public final camera:Camera;
	final device:Device;
	final ballMesh:Array<Mesh> = [];
	final boxMesh:Array<Mesh> = [];
	var dropped = 0;

	public function new(device:Device) {
		this.device = device;
		renderer = new Renderer(device).use(new Shadows(device, 1024));
		var ground = new Material("ground", new Vec4(0.5, 0.52, 0.56, 1), 0, 0.8);
		var wallMaterial = new Material("wall", new Vec4(0.35, 0.45, 0.6, 1), 0, 0.6);
		var floor = world.node("floor");
		MeshRenderer.attach(floor, Shapes.box(device, ground, 6, 0.2, 6));
		floor.position = new Vec3(0, -0.1, 0);
		physics.add(new Body(Plane(new Vec3(0, 1, 0), 0), new Vec3(0, 0, 0), 0));
		for (w in [[2.6, 0, 0.2, 3], [-2.6, 0, 0.2, 3], [0, 2.6, 3, 0.2], [0, -2.6, 3, 0.2]]) {
			var n = world.node("wall");
			var half = new Vec3(w[2], 0.4, w[3]);
			n.position = new Vec3(w[0], 0.4, w[1]);
			MeshRenderer.attach(n, Shapes.box(device, wallMaterial, half.x * 2, half.y * 2, half.z * 2));
			physics.add(new Body(Box(half), n.position, 0));
		}
		for (c in [new Vec4(0.95, 0.4, 0.15, 1), new Vec4(0.95, 0.8, 0.3, 1), new Vec4(0.2, 0.6, 0.95, 1), new Vec4(0.85, 0.85, 0.9, 1)])
{
			var m = new Material("ball", c, c.x > 0.8 && c.y > 0.8 ? 1 : 0, 0.35);
			ballMesh.push(Shapes.sphere(device, m, 0.3, 24, 12));
			boxMesh.push(Shapes.box(device, m, 0.5, 0.4, 0.6));
		}
		var sun = world.node("sun");
		Light.attach(sun, Light.directional(new Vec3(1, 0.96, 0.9), 2.6));
		sun.rotation = Quat.fromEuler(-1.0, -0.6, 0);
		var eye = world.node("eye");
		camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
		eye.position = new Vec3(0, 5.2, 7.2);
		eye.lookAt(new Vec3(0, 0.3, 0));
		for (_ in 0...14)
			drop();
	}

	// another ball, above the box (its place from how many fell before: the same every run)
	public function drop() {
		var k = dropped++;
		var n = world.node("body" + k);
		var x = ((k * 7) % 9) / 9 * 3 - 1.5, z = ((k * 5) % 7) / 7 * 3 - 1.5;
		// (every third a box, tilted: it lands on a corner and tumbles)
		var box = k % 3 == 2;
		MeshRenderer.attach(n, box ? boxMesh[k % boxMesh.length] : ballMesh[k % ballMesh.length]);
		var b = new Body(box ? Box(new Vec3(0.25, 0.2, 0.3)) : Sphere(0.3), new Vec3(x, 2 + k * 0.45, z));
		if (box) b.orientation = Quat.axisAngle(new Vec3(1, 0.3, 0.6), 0.4 + k * 0.2);
		b.restitution = 0.5;
		physics.add(b, n);
	}

	public function draw(enc:Encoder)
		renderer.draw(enc, world, camera);

	static function main() {
		var window = new Window("Falling", 640, 480);
		var device = Device.create(window.surface);
		var scene = new Falling(device);
		// (the frame's stages: physics at the fixed rate)
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
			case MouseDown: scene.drop();
			case _:
		});
	}
}
