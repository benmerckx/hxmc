// title: Orbits
// summary: A small solar system as a scene graph: planets on turning nodes, a moon on a planet's, a fixed-step clock, the star a point light, a debug overlay of frame times (O)
// tags: 3d, scene graph, pbr
// demo: canvas 512x384
import hxmc.gfx.*;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.os.*;
import hxmc.scene.*;
import hxmc.scene.math.*;
import hxmc.scene.render.*;

// @hxmc/3d's world: each orbit is a node turning about y, its planet a
// child placed at the orbit's radius (and turning on its own axis), a
// moon on the planet's own orbit node, so one rotation each and the
// scene graph's world matrices do the rest. The simulation runs at 60
// steps a second (FixedStep) whatever the display's rate; under `hxmc dev`
// the clock survives a rebuild (hxmc.dev.Hot.keep). A debug overlay
// (hxmc.scene.debug, drawn with @hxmc/ui) shows the frame times and the
// renderer's draws; O toggles it. Escape closes.
//
//   haxe -cp packages/os/src -cp packages/gfx/src -cp packages/text/src -cp packages/ui/src
//     -cp packages/3d/src -cp packages/3d/examples -main Orbits --custom-target hxmc=orbits -D hxmc.libc=glibc
class Orbits {
	final world = new World("orbits");
	final orbits:Array<Node> = [];
	final speeds:Array<Float> = [];
	final spins:Array<Node> = [];
	public final camera:Camera;
	public final renderer:Renderer;

	public function new(device:Device) {
		renderer = new Renderer(device);
		renderer.sky = new Vec3(0.1, 0.12, 0.18);
		renderer.ground = new Vec3(0.03, 0.03, 0.04);
		var star = world.node("star");
		MeshRenderer.attach(star, Shapes.sphere(device, new Material("star", new Vec4(1, 0.8, 0.4, 1), 0, 1, new Vec3(1.1, 0.6, 0.15)), 0.8));
		// (the star's light: a point light at its centre)
		Light.attach(star, Light.pointLight(new Vec3(1, 0.9, 0.75), 11, 30));
		var planets = [
			{r: 1.8, size: 0.26, speed: 1.1, color: new Vec4(0.6, 0.6, 0.62, 1), metal: 0.0, rough: 0.8},
			{r: 2.9, size: 0.42, speed: 0.7, color: new Vec4(0.15, 0.4, 0.95, 1), metal: 0.0, rough: 0.35},
			{r: 4.2, size: 0.36, speed: 0.45, color: new Vec4(0.95, 0.5, 0.2, 1), metal: 0.0, rough: 0.55},
			{r: 5.5, size: 0.52, speed: 0.3, color: new Vec4(0.95, 0.8, 0.5, 1), metal: 0.6, rough: 0.45}
		];
		for (k in 0...planets.length) {
			var p = planets[k];
			var orbit = world.node("orbit" + k);
			orbit.rotation = Quat.axisAngle(new Vec3(0, 1, 0), k * 1.7);
			var planet = world.node("planet" + k, orbit);
			planet.position = new Vec3(p.r, 0, 0);
			MeshRenderer.attach(planet, Shapes.sphere(device, new Material("planet" + k, p.color, p.metal, p.rough), p.size));
			orbits.push(orbit);
			speeds.push(p.speed);
			spins.push(planet);
			if (k == 1) {
				// a moon: an orbit node under the planet, a box on it
				var moonOrbit = world.node("moon orbit", planet);
				moonOrbit.rotation = Quat.axisAngle(new Vec3(0.2, 1, 0), 0.5);
				var moon = world.node("moon", moonOrbit);
				moon.position = new Vec3(0.7, 0, 0);
				MeshRenderer.attach(moon, Shapes.box(device, new Material("moon", new Vec4(0.8, 0.8, 0.85, 1), 0, 0.6), 0.2, 0.2, 0.2));
				orbits.push(moonOrbit);
				speeds.push(2.5);
			}
		}
		var eye = world.node("eye");
		camera = Camera.attach(eye, Camera.perspective(0.75, 0.1, 100));
		eye.position = new Vec3(0, 4.6, 8.8);
		eye.lookAt(new Vec3(0, -0.4, 0));
	}

	// the simulation at time t (seconds): each orbit's turn, each planet's spin
	public function at(t:Float) {
		for (k in 0...orbits.length)
			orbits[k].rotation = Quat.axisAngle(new Vec3(0, 1, 0), k * 1.7 + speeds[k] * t);
		for (p in spins)
			p.rotation = Quat.axisAngle(new Vec3(0.1, 1, 0), t * 2);
	}

	public function draw(enc:Encoder)
		renderer.draw(enc, world, camera);

	static function main() {
		var window = new Window("Orbits", 640, 480);
		var device = Device.create(window.surface);
		var orbits = new Orbits(device);
		// (the debug overlay, drawn with @hxmc/ui: frame times and draws; O toggles it)
		var overlay = new hxmc.scene.debug.Overlay(device), stats = new hxmc.scene.debug.FrameStats(), showStats = true;
		overlay.scale = window.scale;
		// (under `hxmc dev` the clock is carried across a reload: the planets stay where they were)
		var clock = hxmc.dev.Hot.keep("orbits.clock", () -> new FixedStep(1 / 60)), last = Sys.time();
		App.run(() -> {
			var now = Sys.time();
			clock.advance(Math.min(now - last, 0.25), _ -> orbits.at(clock.time));
			stats.add(now - last);
			last = now;
			var enc = device.beginFrame();
			if (enc == null) return;
			orbits.draw(enc);
			if (showStats) {
				stats.from(orbits.renderer);
				overlay.draw(enc, stats);
			}
			device.endFrame();
		}, e -> switch e.kind {
			case Close: window.close();
			case KeyDown if (e.key == 0xFF1B): window.close();
			case KeyDown if (e.key == 0x6F): showStats = !showStats;
			case _:
		});
	}
}
