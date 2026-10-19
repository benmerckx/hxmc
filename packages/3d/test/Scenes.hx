import hxmc.gfx.*;
import hxmc.gfx.shader.Vec3;
import hxmc.scene.*;
import hxmc.scene.gltf.*;
import hxmc.scene.render.*;

// packages/3d's test scenes (RenderTest natively, SceneWebTest in the
// browser), each a frame against packages/3d/test/<name>.png:
//   gltf   the sample glTF scene (examples/sample.glb) from its camera,
//          lit by the renderer's sun and sky
//   shadows the same with a shadow map (Shadows, 512x512)
//   physics @hxmc/physics' Falling example after STEPS steps
//   instances 169 nodes on two meshes: instanced draws (RenderTest checks
//          their count)
//   skin   the skinned sample (examples/skinned.glb) bent by its animation,
//          casting its shadow
//   overlay the sample scene under the debug overlay (FrameStats, Overlay)
//   textured the textured sample (a PNG in the file, decoded by @hxmc/ui)
//   normals  the normal-mapped sample (NormalMaps, tangents computed)
//   blend    see-through materials over opaque ones, farthest first
//   packedskin, packednormals  the skinned and the normal-mapped samples
//            packed at build time (Pack: skins, animations, images,
//            tangents): skin.png's and normals.png's frames
//   cascades two shadow cascades over a long street of pillars: sharp near
//            the camera, the whole street's map beyond
//   environment  spheres from mirror to rough, metal and not, lit by an
//            environment map (Environment) drawn behind them
//   morph    the morph sample's targets played by its animation at 1.5 s
//            (half the bump, half the wave), two instances, one bent apart
//   chains   physics' Chains example after 1.2 s: the ball through the chains
//   walker   physics' Walker example: the character walked through the crates, jumping
//   packed the sample scene from the asset step's packed file: gltf.png
//   spot   two spot lights and a point light, no sun
//   sky    the shadows scene under a sky (Sky, drawn at an injection point)
//   lazy   the skinned sample loaded in the background (Model.of(path, Lazy))
//   particles two emitters (Particles, Emitter) after STEPS steps
//   orbits the Orbits example (shapes made in code on a scene graph, a
//          directional Light) at TIME seconds
class Scenes {
	public static final NAMES = ["gltf", "orbits", "shadows", "physics", "instances", "skin", "overlay", "textured", "packed", "spot", "sky", "lazy", "particles", "normals", "blend", "walker", "packedskin", "packednormals", "cascades", "environment", "morph", "chains", "packedmorph"];
	// whether the last scene has what it draws (a lazy one: once its files loaded)
	public static var ready:Void->Bool = () -> true;
	// the last scene's renderer (its statistics: RenderTest)
	public static var renderer:Null<Renderer>;
	// the last scene's own checks beyond its frame (RenderTest; null: none)
	public static var probe:Null<Void->String>;
	public static inline var TIME = 2.0;
	public static inline var STEPS = 150;

	public static function make(name:String, device:Device):Encoder->Void {
		ready = () -> true;
		probe = null;
		return switch name {
			case "overlay":
				// the sample scene under the debug overlay (@hxmc/ui), its frame times made up
				var under = make("gltf", device);
				var r = renderer;
				var overlay = new hxmc.scene.debug.Overlay(device);
				var stats = new hxmc.scene.debug.FrameStats(100);
				for (k in 0...100)
					stats.add(k % 17 == 0 ? 0.04 : k % 5 == 0 ? 0.025 : 0.008 + (k % 7) * 0.001);
				enc -> {
					under(enc);
					stats.from(r);
					overlay.draw(enc, stats);
				};
			case "gltf" | "shadows" | "sky":
				var renderer = new Renderer(device);
				Scenes.renderer = renderer;
				if (name != "gltf") renderer.use(new Shadows(device, 512));
				// (the sky at the BeforeOpaque injection point)
				// (a night sky: the tests want a dark corner, compare.mjs and GfxTest alike)
				if (name == "sky") {
					var sky = new Sky(device);
					sky.zenith = new Vec3(0.004, 0.008, 0.03);
					sky.horizon = new Vec3(0.02, 0.025, 0.05);
					sky.ground = new Vec3(0.01, 0.01, 0.01);
					renderer.use(sky);
				}
				var world = new World();
				var model = Model.of("sample.glb");
				model.instantiate(world, device);
				// (typed from the file when compiling)
				if (world.root.find(model.nodes.camera).isNone) throw "Scenes: no camera node";
				var camera = Camera.first(world);
				enc -> renderer.draw(enc, world, camera);
			case "orbits":
				var orbits = new Orbits(device);
				orbits.at(TIME);
				enc -> orbits.draw(enc);
			case "physics":
				var falling = new Falling(device);
				for (_ in 0...STEPS)
					falling.physics.step(1 / 60);
				enc -> falling.draw(enc);
			case "chains":
				var chains = new Chains(device);
				for (_ in 0...72)
					chains.physics.step(1 / 60);
				enc -> chains.draw(enc);
			case "walker":
				var walker = new Walker(device);
				for (k in 0...STEPS)
					walker.step(1 / 60, k < 20 || k >= 100 ? new Vec3(0, 0, 0) : new Vec3(0.8, 0, -1), k == 60);
				enc -> walker.draw(enc);
			case "instances":
				// a field of 13x13 cubes and spheres on two meshes: instanced draws
				var r = new Renderer(device);
				renderer = r;
				var world = new World();
				var cube = Shapes.box(device, new Material("cube", new hxmc.gfx.shader.Vec4(0.9, 0.45, 0.2, 1), 0, 0.45), 0.5, 0.5, 0.5);
				var ball = Shapes.sphere(device, new Material("ball", new hxmc.gfx.shader.Vec4(0.25, 0.5, 0.95, 1), 0, 0.3), 0.3, 16, 8);
				for (x in 0...13)
					for (z in 0...13) {
						var n = world.node();
						n.position = new Vec3((x - 6) * 0.8, 0, (z - 6) * 0.8);
						n.rotation = hxmc.scene.math.Quat.axisAngle(new Vec3(0, 1, 0), (x * 13 + z) * 0.3);
						MeshRenderer.attach(n, (x + z) % 2 == 0 ? cube : ball);
					}
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
				eye.position = new Vec3(0, 6, 8);
				eye.lookAt(new Vec3(0, 0, 0));
				// (picking: straight down onto the cube at the centre, its top at 0.25;
				// through the camera's centre; beside the field, nothing)
				probe = () -> {
					var down = Pick.ray(world, new Vec3(0, 5, 0), new Vec3(0, -1, 0));
					var r = camera.ray(0, 0, 4 / 3);
					var centre = Pick.ray(world, r.origin, r.dir);
					var miss = Pick.ray(world, new Vec3(20, 5, 0), new Vec3(0, -1, 0));
					down != null && down.node.position.x == 0 && down.node.position.z == 0 && Math.abs(down.distance - 4.75) < 1e-6 && centre != null
						&& centre.node.position.x == 0 && miss == null ? null : 'picking: ${down?.distance} ${centre?.node.position.x} ${miss != null}';
				};
				enc -> r.draw(enc, world, camera);
			case "skin":
				// the skinned sample bent by its animation at 1 s (the elbow at 1.2 radians)
				var r = new Renderer(device).use(new Skinning(device)).use(new Shadows(device, 512));
				renderer = r;
				var world = new World();
				var model = Model.of("skinned.glb");
				var made = [];
				model.instantiate(world, device, null, made);
				var animator = new hxmc.scene.anim.Animator(made);
				animator.play(model.clip(model.animations.bend));
				animator.update(1.0);
				var floor = world.node("floor");
				MeshRenderer.attach(floor, Shapes.plane(device, new Material("floor", new hxmc.gfx.shader.Vec4(0.5, 0.5, 0.55, 1), 0, 0.9), 6));
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
				eye.position = new Vec3(0.4, 1.4, 4.2);
				eye.lookAt(new Vec3(-0.3, 1.1, 0));
				enc -> r.draw(enc, world, camera);
			case "textured":
				// the textured sample, its PNG decoded by @hxmc/ui's decoder, mip-mapped
				Images.decode = (mime, bytes) -> hxmc.ui.PngDecoder.decode(bytes);
				var r = new Renderer(device);
				renderer = r;
				var world = new World();
				var model = Model.of("textured.glb");
				var crate = model.instantiate(world, device).find(model.nodes.crate);
				crate.rotation = hxmc.scene.math.Quat.fromEuler(0.5, 0.7, 0);
				var floor = world.node("floor");
				floor.position = new Vec3(0, -1.1, 0);
				MeshRenderer.attach(floor, Shapes.plane(device, new Material("floor", new hxmc.gfx.shader.Vec4(0.45, 0.47, 0.5, 1), 0, 0.9), 8));
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
				eye.position = new Vec3(0, 0.8, 3.2);
				eye.lookAt(new Vec3(0, -0.1, 0));
				enc -> r.draw(enc, world, camera);
			case "normals":
				// the normal-mapped sample (NormalMaps; tangents computed when loaded)
				Images.decode = (mime, bytes) -> hxmc.ui.PngDecoder.decode(bytes);
				var r = new Renderer(device).use(new NormalMaps(device));
				renderer = r;
				var world = new World();
				var model = Model.of("normals.glb");
				var tiles = model.instantiate(world, device).find(model.nodes.tiles);
				tiles.rotation = hxmc.scene.math.Quat.fromEuler(0.5, 0.7, 0);
				var floor = world.node("floor");
				floor.position = new Vec3(0, -1.1, 0);
				MeshRenderer.attach(floor, Shapes.plane(device, new Material("floor", new hxmc.gfx.shader.Vec4(0.45, 0.47, 0.5, 1), 0, 0.9), 8));
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
				eye.position = new Vec3(0, 0.8, 3.2);
				eye.lookAt(new Vec3(0, -0.1, 0));
				enc -> r.draw(enc, world, camera);
			case "blend":
				// three see-through panes (one double-sided) crossing in front of
				// an opaque ball: drawn after it, farthest first
				var r = new Renderer(device);
				renderer = r;
				var world = new World();
				var floor = world.node("floor");
				MeshRenderer.attach(floor, Shapes.plane(device, new Material("floor", new hxmc.gfx.shader.Vec4(0.5, 0.5, 0.52, 1), 0, 0.9), 8));
				var ball = world.node("ball");
				ball.position = new Vec3(0, 0.6, -1.2);
				MeshRenderer.attach(ball, Shapes.sphere(device, new Material("ball", new hxmc.gfx.shader.Vec4(0.9, 0.75, 0.2, 1), 1, 0.3), 0.6, 24, 12));
				var colors = [new hxmc.gfx.shader.Vec4(0.2, 0.5, 1, 0.45), new hxmc.gfx.shader.Vec4(1, 0.3, 0.2, 0.45), new hxmc.gfx.shader.Vec4(0.3, 1, 0.4, 0.35)];
				for (k in 0...3) {
					var glass = new Material("glass" + k, colors[k], 0, 0.1, null, k == 2);
					glass.blend = true;
					var pane = world.node("pane" + k);
					pane.position = new Vec3(-0.7 + 0.7 * k, 0.8, 0.4 - 0.5 * k);
					pane.rotation = hxmc.scene.math.Quat.fromEuler(0, -0.5 + 0.5 * k, 0);
					MeshRenderer.attach(pane, Shapes.box(device, glass, 1, 1.2, 0.05));
				}
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
				eye.position = new Vec3(0.3, 1.6, 4);
				eye.lookAt(new Vec3(0, 0.6, -0.3));
				enc -> r.draw(enc, world, camera);
			case "packedskin":
				// the skinned sample packed (make 3d-programs writes bin/3d/skinned.hxm3d):
				// its skin and clip from the packed file, skin.png's frame
				var r = new Renderer(device).use(new Skinning(device)).use(new Shadows(device, 512));
				renderer = r;
				var world = new World();
				var model = PackedModel.read(Asset.embed("bin/3d/skinned.hxm3d"), device);
				var made = [];
				model.instantiate(world, null, made);
				var animator = new hxmc.scene.anim.Animator(made);
				animator.play(model.clip("bend"));
				animator.update(1.0);
				var floor = world.node("floor");
				MeshRenderer.attach(floor, Shapes.plane(device, new Material("floor", new hxmc.gfx.shader.Vec4(0.5, 0.5, 0.55, 1), 0, 0.9), 6));
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
				eye.position = new Vec3(0.4, 1.4, 4.2);
				eye.lookAt(new Vec3(-0.3, 1.1, 0));
				enc -> r.draw(enc, world, camera);
			case "packednormals":
				// the normal-mapped sample packed (its PNG, its tangents): normals.png's frame
				Images.decode = (mime, bytes) -> hxmc.ui.PngDecoder.decode(bytes);
				var r = new Renderer(device).use(new NormalMaps(device));
				renderer = r;
				var world = new World();
				var tiles = PackedModel.read(Asset.embed("bin/3d/normals.hxm3d"), device).instantiate(world).find("tiles");
				tiles.rotation = hxmc.scene.math.Quat.fromEuler(0.5, 0.7, 0);
				var floor = world.node("floor");
				floor.position = new Vec3(0, -1.1, 0);
				MeshRenderer.attach(floor, Shapes.plane(device, new Material("floor", new hxmc.gfx.shader.Vec4(0.45, 0.47, 0.5, 1), 0, 0.9), 8));
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
				eye.position = new Vec3(0, 0.8, 3.2);
				eye.lookAt(new Vec3(0, -0.1, 0));
				enc -> r.draw(enc, world, camera);
			case "cascades":
				// (HXMC_CASCADES=1: the same with one, to compare)
				var one = Sys.getEnv("HXMC_CASCADES") == "1";
				var shadows = one ? new Shadows(device, 512) : Shadows.cascaded(device, 512, 7);
				var r = new Renderer(device).use(shadows);
				renderer = r;
				var world = new World();
				var floor = world.node("floor");
				floor.position = new Vec3(0, 0, -18);
				MeshRenderer.attach(floor, Shapes.plane(device, new Material("floor", new hxmc.gfx.shader.Vec4(0.6, 0.6, 0.62, 1), 0, 0.9), 44));
				var pillar = Shapes.box(device, new Material("pillar", new hxmc.gfx.shader.Vec4(0.8, 0.55, 0.35, 1), 0, 0.6), 0.4, 2.4, 0.4);
				var ball = Shapes.sphere(device, new Material("ball", new hxmc.gfx.shader.Vec4(0.3, 0.55, 0.9, 1), 0, 0.3), 0.35, 16, 8);
				for (k in 0...10) {
					for (x in [-2.2, 2.2]) {
						var n = world.node();
						n.position = new Vec3(x, 1.2, 2 - k * 4);
						MeshRenderer.attach(n, pillar);
					}
					var b = world.node();
					b.position = new Vec3((k % 2) * 1.2 - 0.6, 0.35, 0.5 - k * 4);
					MeshRenderer.attach(b, ball);
				}
				var sun = world.node("sun");
				Light.attach(sun, Light.directional(new Vec3(1, 0.95, 0.88), 2.6));
				sun.rotation = hxmc.scene.math.Quat.fromEuler(-0.7, 0.9, 0);
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.9, 0.1, 60));
				eye.position = new Vec3(0.6, 1.5, 4.5);
				eye.lookAt(new Vec3(0, 0.6, -6));
				enc -> r.draw(enc, world, camera);
			case "environment":
				Images.decode = (mime, bytes) -> hxmc.ui.PngDecoder.decode(bytes);
				var env = Environment.fromImage(device, "image/png", Asset.embed("panorama.png"));
				var r = new Renderer(device).use(env);
				renderer = r;
				var world = new World();
				for (k in 0...5) {
					var rough = 0.05 + k * 0.235;
					var metal = world.node("metal" + k), plastic = world.node("plastic" + k);
					metal.position = new Vec3(-2.4 + k * 1.2, 0.65, 0);
					plastic.position = new Vec3(-2.4 + k * 1.2, -0.65, 0);
					MeshRenderer.attach(metal, Shapes.sphere(device, new Material("metal", new hxmc.gfx.shader.Vec4(0.95, 0.93, 0.88, 1), 1, rough), 0.5, 32, 16));
					MeshRenderer.attach(plastic, Shapes.sphere(device, new Material("plastic", new hxmc.gfx.shader.Vec4(0.8, 0.2, 0.15, 1), 0, rough), 0.5, 32, 16));
				}
				var sun = world.node("sun");
				Light.attach(sun, Light.directional(new Vec3(1, 0.95, 0.85), 2));
				sun.lookAt(new Vec3(0.35, -0.45, 0.82));
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
				eye.position = new Vec3(0, 0.3, 5.5);
				eye.lookAt(new Vec3(0, 0, 0));
				// (a bright background: a black mark in the corner, where the
				// tests' check that something was drawn looks for the clear colour)
				var ui = new hxmc.ui.draw.Renderer(device);
				var markPass:PassDesc = {colors: [{load: Load}]};
				r.inject(AfterPass, (enc, frame) -> {
					ui.begin(device.width, device.height);
					ui.rect(0, 0, 4, 4, 0, 0xFF000000, 0, 0);
					enc.beginPass(markPass);
					ui.end(enc);
					enc.endPass();
				});
				enc -> r.draw(enc, world, camera);
			case "morph" | "packedmorph":
				var r = new Renderer(device).use(new Shadows(device, 512));
				renderer = r;
				var world = new World();
				var made = [];
				var left:Node, right:Node;
				if (name == "morph") {
					var model = Model.of("morph.glb");
					left = model.instantiate(world, device, null, made);
					var animator = new hxmc.scene.anim.Animator(made);
					animator.play(model.clip(model.animations.breathe));
					animator.update(1.5);
					// (a second instance at its mesh's default weights, its own vertices)
					right = model.instantiate(world, device);
				} else {
					// (packed at build time: bin/3d/morph.hxm3d, morph.png's frame)
					var model = PackedModel.read(Asset.embed("bin/3d/morph.hxm3d"), device);
					left = model.instantiate(world, null, made);
					var animator = new hxmc.scene.anim.Animator(made);
					animator.play(model.clip("breathe"));
					animator.update(1.5);
					right = model.instantiate(world);
				}
				left.position = new Vec3(-1.15, 0, 0);
				right.position = new Vec3(1.15, 0, 0);
				var floor = world.node("floor");
				floor.position = new Vec3(0, -0.4, 0);
				MeshRenderer.attach(floor, Shapes.plane(device, new Material("floor", new hxmc.gfx.shader.Vec4(0.5, 0.5, 0.52, 1), 0, 0.9), 8));
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
				eye.position = new Vec3(0, 1.1, 3.3);
				eye.lookAt(new Vec3(0, 0.05, 0));
				enc -> r.draw(enc, world, camera);
			case "packed":
				// the sample scene packed at build time (Pack: make 3d-check writes
				// bin/3d/sample.hxm3d first), read without JSON: gltf.png's frame
				var r = new Renderer(device);
				renderer = r;
				var world = new World();
				PackedModel.read(Asset.embed("bin/3d/sample.hxm3d"), device).instantiate(world);
				var camera = Camera.first(world);
				enc -> r.draw(enc, world, camera);
			case "spot":
				// two spot lights and a point light over a floor and spheres, no sun
				var r = new Renderer(device);
				renderer = r;
				r.sky = new Vec3(0.03, 0.035, 0.05);
				r.ground = new Vec3(0.02, 0.02, 0.02);
				var world = new World();
				var floor = world.node("floor");
				MeshRenderer.attach(floor, Shapes.plane(device, new Material("floor", new hxmc.gfx.shader.Vec4(0.7, 0.7, 0.72, 1), 0, 0.7), 10));
				var ball = Shapes.sphere(device, new Material("ball", new hxmc.gfx.shader.Vec4(0.9, 0.9, 0.9, 1), 0, 0.4), 0.5, 24, 12);
				for (x in [-1.6, 0.0, 1.6]) {
					var n = world.node();
					n.position = new Vec3(x, 0.5, 0);
					MeshRenderer.attach(n, ball);
				}
				var warm = world.node("warm");
				warm.position = new Vec3(-1.5, 3, 1);
				warm.lookAt(new Vec3(-1.2, 0, 0));
				Light.attach(warm, Light.spot(new Vec3(1, 0.6, 0.3), 14, 12, 0.25, 0.45));
				var cool = world.node("cool");
				cool.position = new Vec3(1.5, 3, 1);
				cool.lookAt(new Vec3(1.2, 0, 0));
				Light.attach(cool, Light.spot(new Vec3(0.3, 0.6, 1), 14, 12, 0.2, 0.35));
				var fill = world.node("fill");
				fill.position = new Vec3(0, 1.5, 2.5);
				Light.attach(fill, Light.pointLight(new Vec3(1, 1, 1), 1.5, 8));
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
				eye.position = new Vec3(0, 3, 5.5);
				eye.lookAt(new Vec3(0, 0.3, 0));
				enc -> r.draw(enc, world, camera);
			case "lazy":
				// the skinned sample loaded in the background (Model.of(path, Lazy)),
				// drawn bent once it is here: skin.png's frame (until then the clear colour)
				var r = new Renderer(device).use(new Skinning(device)).use(new Shadows(device, 512));
				renderer = r;
				var world = new World();
				var floor = world.node("floor");
				MeshRenderer.attach(floor, Shapes.plane(device, new Material("floor", new hxmc.gfx.shader.Vec4(0.5, 0.5, 0.55, 1), 0, 0.9), 6));
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
				eye.position = new Vec3(0.4, 1.4, 4.2);
				eye.lookAt(new Vec3(-0.3, 1.1, 0));
				var asset = Model.of("skinned.glb", Lazy);
				asset.then(model -> {
					var made = [];
					model.instantiate(world, device, null, made);
					var animator = new hxmc.scene.anim.Animator(made);
					animator.play(model.clip(model.animations.bend));
					animator.update(1.0);
				});
				ready = () -> {
					Assets.poll();
					asset.ready;
				};
				enc -> {
					Assets.poll();
					r.draw(enc, world, camera);
				};
			case "particles":
				// two emitters (a fountain of sparks, a plume) over a floor, at STEPS fixed steps
				var r = new Renderer(device).use(new Particles(device));
				renderer = r;
				var world = new World();
				var floor = world.node("floor");
				MeshRenderer.attach(floor, Shapes.plane(device, new Material("floor", new hxmc.gfx.shader.Vec4(0.3, 0.3, 0.33, 1), 0, 0.8), 8));
				var sparks = world.node("sparks");
				sparks.position = new Vec3(0, 0.1, 0);
				var e = Emitter.attach(sparks, new Emitter(7));
				e.velocity = new Vec3(0, 3, 0);
				e.rate = 20;
				e.size = 0.12;
				e.spread = 0.8;
				e.gravity = new Vec3(0, -4, 0);
				var plume = world.node("plume");
				plume.position = new Vec3(1.4, 0.1, 0);
				var f = Emitter.attach(plume, new Emitter(11));
				f.velocity = new Vec3(0, 0.8, 0);
				f.spread = 0.25;
				f.gravity = new Vec3(0.1, 0.2, 0);
				f.color = new hxmc.gfx.shader.Vec4(0.08, 0.16, 0.45, 1);
				f.size = 0.12;
				f.endSize = 0.3;
				f.life = 2.5;
				f.rate = 12;
				for (_ in 0...STEPS)
					Particles.update(world, 1 / 60);
				var eye = world.node("eye");
				var camera = Camera.attach(eye, Camera.perspective(0.8, 0.1, 100));
				eye.position = new Vec3(0, 1.6, 4.5);
				eye.lookAt(new Vec3(0, 0.9, 0));
				enc -> r.draw(enc, world, camera);
			case n: throw 'Scenes: no scene $n';
		}
	}
}
