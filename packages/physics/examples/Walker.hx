// title: Walker
// summary: A capsule character of @hxmc/physics (Character: steered, grounded by a ray, jumping) walking among crates it pushes and onto a platform, the camera following; arrow keys, WASD or a gamepad's stick walk, space, A or the lower right corner jumps
// tags: 3d, physics
// demo: canvas 512x384
import hxmc.gfx.*;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.os.*;
import hxmc.physics.*;
import hxmc.scene.*;
import hxmc.scene.input.Actions;
import hxmc.scene.math.*;
import hxmc.scene.render.*;

// A character in a physics world: Character's capsule body moves its node
// (drawn with Shapes.capsule), crates are dynamic boxes it pushes, a
// platform and a ramp of steps are static boxes; input through Actions,
// read at each fixed step (the frame's Stages), the camera following
// behind. Escape closes.
//
//   haxe -cp packages/os/src -cp packages/gfx/src -cp packages/3d/src -cp packages/physics/src
//     -cp packages/physics/examples -main Walker --custom-target hxmc=walker -D hxmc.libc=glibc
class Walker {
	public final world = new World("walker");
	public final physics = new PhysicsWorld();
	public final renderer:Renderer;
	public final camera:Camera;
	public final hero:Character;
	final eye:Node;

	public function new(device:Device) {
		renderer = new Renderer(device).use(new Shadows(device, 1024));
		var ground = new Material("ground", new Vec4(0.42, 0.5, 0.38, 1), 0, 0.9);
		var stone = new Material("stone", new Vec4(0.55, 0.55, 0.6, 1), 0, 0.7);
		var wood = new Material("wood", new Vec4(0.75, 0.5, 0.28, 1), 0, 0.6);
		var floor = world.node("floor");
		MeshRenderer.attach(floor, Shapes.box(device, ground, 24, 0.2, 24));
		floor.position = new Vec3(0, -0.1, 0);
		physics.add(new Body(Plane(new Vec3(0, 1, 0), 0), new Vec3(0, 0, 0), 0));
		// (a platform, and steps up to it)
		for (b in [[4, 0.5, -3, 2, 0.5, 1.5], [1.6, 0.15, -3, 0.4, 0.15, 1], [2.3, 0.3, -3, 0.3, 0.3, 1]]) {
			var n = world.node("stone");
			var half = new Vec3(b[3], b[4], b[5]);
			n.position = new Vec3(b[0], b[1], b[2]);
			MeshRenderer.attach(n, Shapes.box(device, stone, half.x * 2, half.y * 2, half.z * 2));
			physics.add(new Body(Box(half), n.position, 0));
		}
		var crate = Shapes.box(device, wood, 0.6, 0.6, 0.6);
		for (k in 0...4) {
			var n = world.node("crate" + k);
			MeshRenderer.attach(n, crate);
			var b = physics.add(new Body(Box(new Vec3(0.3, 0.3, 0.3)), new Vec3(-1.5 + 0.9 * (k % 2), 0.3 + 0.6 * Std.int(k / 2), 1.2), 8), n);
			b.friction = 0.6;
		}
		var body = world.node("hero");
		MeshRenderer.attach(body, Shapes.capsule(device, new Material("hero", new Vec4(0.95, 0.35, 0.2, 1), 0, 0.4), 0.3, 0.6));
		hero = new Character(physics, new Vec3(-3, 0.9, 3), body);
		var sun = world.node("sun");
		Light.attach(sun, Light.directional(new Vec3(1, 0.96, 0.9), 2.6));
		sun.rotation = Quat.fromEuler(-1.0, -0.6, 0);
		eye = world.node("eye");
		camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
		follow();
	}

	// a fixed step: the character steered (move: x right, z towards the
	// camera), the world stepped, the camera behind
	public function step(dt:Float, move:Vec3, jump:Bool) {
		hero.update(dt, move, jump);
		physics.step(dt);
		follow();
	}

	function follow() {
		var p = hero.body.position;
		eye.position = new Vec3(p.x + 1.2, p.y + 2.2, p.z + 5);
		eye.lookAt(new Vec3(p.x + 0.3, p.y + 0.3, p.z - 1));
	}

	public function draw(enc:Encoder)
		renderer.draw(enc, world, camera);

	static function main() {
		var window = new Window("Walker", 640, 480);
		var device = Device.create(window.surface);
		var scene = new Walker(device);
		var actions = new Actions();
		actions.bind("x", KeyAxis(0xFF51, 0xFF53)).bind("x", KeyAxis(0x61, 0x64));
		actions.bind("z", KeyAxis(0xFF52, 0xFF54)).bind("z", KeyAxis(0x77, 0x73));
		actions.bind("jump", Key(0x20)).bind("jump", Region(0.75, 0.6, 1, 1));
		// (a gamepad too: the left stick walks, A jumps)
		Gamepads.enable();
		actions.bind("x", PadAxis(0, 1)).bind("z", PadAxis(1, 1)).bind("jump", PadButton(0));
		var stages = new Stages(new FixedStep(1 / 60)), last = Sys.time();
		stages.on(FixedUpdate, dt -> {
			actions.step();
			scene.step(dt, new Vec3(actions.axis("x"), 0, actions.axis("z")), actions.pressed("jump"));
		});
		App.run(() -> {
			var now = Sys.time();
			stages.frame(Math.min(now - last, 0.25));
			last = now;
			var enc = device.beginFrame();
			if (enc == null) return;
			scene.draw(enc);
			device.endFrame();
		}, e -> {
			actions.event(e);
			switch e.kind {
				case Close: window.close();
				case KeyDown if (e.key == 0xFF1B): window.close();
				case _:
			}
		});
	}
}
