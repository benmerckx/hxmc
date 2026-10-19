import hxmc.gfx.*;
import hxmc.gfx.shader.Vec3;
import hxmc.os.*;

// packages/3d's cost per feature (sizes.sh, make 3d-sizes): one program, a
// window clearing its frame, with each level adding a feature on top of
// the one before (-D size_level=<n>):
//   0  gfx alone (a window, a device, a cleared frame)
//   1  + the math (Quat, MathTools: a turning matrix)
//   2  + the world (World, Node, Camera, FixedStep)
//   3  + the glTF reader (Gltf.parse of the sample scene, GltfNodes)
//   4  + the renderer (GltfScene, Renderer, PbrShader: the scene drawn)
//   5  + shadows (Shadows: a shadow map pass)
//   6  + input actions (Actions)
//   7  + keyframe animation (AnimationClip, Animator)
//   8  + skinning (Skinning: the skinned shader)
//   9  + normal maps (NormalMaps: the normal-mapped shader)
// and, with -D size_packed at level 4, the renderer drawing the sample
// packed at build time (PackedModel: no glTF reader, no JSON)
class Size {
	static function main() {
		var window = new Window("Size", 320, 240);
		var device = Device.create(window.surface);
		var pass:PassDesc = {colors: [{load: Clear, clear: new Color(0.1, 0.1, 0.12)}]};
		#if (size_level >= 1)
		var q = hxmc.scene.math.Quat.axisAngle(new Vec3(0, 1, 0), 0.3);
		var m = hxmc.scene.math.MathTools.inverse(q.toMat4());
		pass.colors[0].clear = new Color(m.c0.x * 0.1, 0.1, 0.12);
		#end
		#if (size_level >= 2)
		var world = new hxmc.scene.World();
		var eye = world.node("eye");
		var camera = hxmc.scene.Camera.attach(eye, hxmc.scene.Camera.perspective(1, 0.1, 100));
		eye.position = new Vec3(0, 1, 5);
		eye.lookAt(new Vec3(0, 0, 0));
		var clock = new hxmc.scene.FixedStep();
		#end
		#if (size_level >= 3 && !size_packed)
		var doc = hxmc.scene.gltf.Gltf.parse(hxmc.scene.gltf.Asset.embed("sample.glb"));
		#end
		#if (size_level == 3)
		hxmc.scene.gltf.GltfNodes.build(doc, world);
		#end
		#if size_packed
		var renderer = new hxmc.scene.render.Renderer(device);
		hxmc.scene.render.PackedModel.read(hxmc.scene.gltf.Asset.embed("bin/3d/sample.hxm3d"), device).instantiate(world);
		#elseif (size_level >= 4)
		var renderer = new hxmc.scene.render.Renderer(device);
		#if (size_level >= 5)
		renderer.use(new hxmc.scene.render.Shadows(device));
		#end
		#if (size_level >= 8)
		renderer.use(new hxmc.scene.render.Skinning(device));
		#end
		#if (size_level >= 9)
		renderer.use(new hxmc.scene.render.NormalMaps(device));
		#end
		new hxmc.scene.gltf.GltfScene(doc, device).instantiate(world);
		#end
		#if (size_level >= 6)
		var actions = new hxmc.scene.input.Actions().bind("turn", KeyAxis(0xFF51, 0xFF53));
		#end
		#if (size_level >= 7)
		var made = [];
		hxmc.scene.gltf.GltfNodes.build(doc, world, null, null, null, null, made);
		var animator = new hxmc.scene.anim.Animator(made);
		animator.play(hxmc.scene.anim.AnimationClip.fromGltf(doc, 0));
		#end
		App.run(() -> {
			#if (size_level >= 2)
			clock.advance(1 / 60, dt -> {
				eye.position = eye.position + new Vec3(0, 0, dt * 0.01);
				#if (size_level >= 6)
				actions.step();
				eye.position = eye.position + new Vec3(actions.axis("turn") * dt, 0, 0);
				#end
				#if (size_level >= 7)
				animator.update(dt);
				#end
			});
			#end
			var enc = device.beginFrame();
			if (enc == null) return;
			#if (size_level >= 4)
			renderer.draw(enc, world, camera);
			#else
			enc.beginPass(pass);
			enc.endPass();
			#end
			device.endFrame();
		}, e -> {
			#if (size_level >= 6)
			actions.event(e);
			#end
			if (e.kind == Close) window.close();
		});
	}
}
