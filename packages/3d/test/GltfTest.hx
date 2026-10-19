import haxe.io.Bytes;
import hxmc.gfx.shader.Vec3;
import hxmc.scene.*;
import hxmc.scene.anim.*;
import hxmc.scene.gltf.*;
import hxmc.scene.math.*;

using hxmc.scene.math.MathTools;

// packages/3d's step 2 (make 3d-check: on Eval and natively): the glTF
// reader on the sample scene (SampleModel.hx; examples/sample.glb checked
// in, the same bytes as the generator's on Eval), both forms (.glb and
// .gltf with a data: URI) read alike, its accessors against the generated
// values, the hierarchy as scene nodes, and files it must reject.
class GltfTest {
	static var checks = 0;
	static var failed = 0;

	static function check(what:String, ok:Bool) {
		checks++;
		if (!ok) {
			failed++;
			Sys.println('GltfTest: FAIL: $what');
		}
	}

	static function near(a:Float, b:Float, eps = 1e-6):Bool
		return Math.abs(a - b) <= eps;

	static function nearV(a:Vec3, b:Vec3, eps = 1e-6):Bool
		return near(a.x, b.x, eps) && near(a.y, b.y, eps) && near(a.z, b.z, eps);

	static function main() {
		var file = Sys.args()[0] != null ? Sys.args()[0] : "packages/3d/examples/sample.glb";
		var glb = sys.io.File.getBytes(file);
		var made = SampleModel.glb();
		#if eval
		// (the generator's floats come from libm: the bytes are compared where the file was made)
		check("sample.glb is the generator's (bless: run SampleModel)", made.compare(glb) == 0);
		#end
		check("isGlb", Gltf.isGlb(glb) && !Gltf.isGlb(SampleModel.gltf()));
		var doc = Gltf.parse(glb), text = Gltf.parse(SampleModel.gltf());
		for (d in [doc, text])
			sample(d);
		check("both forms: the same buffer", doc.buffers[0].compare(text.buffers[0]) == 0);
		nodes(doc);
		animations(doc);
		skins();
		textured();
		normals();
		morphs();
		rejects(glb);
		Sys.println('GltfTest: $checks checks, ' + (failed == 0 ? "ok" : '$failed FAILED'));
		if (failed > 0) Sys.exit(1);
	}

	static function sample(doc:GltfDoc) {
		check("generator", doc.generator == "hxmc packages/3d/test/SampleModel.hx");
		check("counts", doc.meshes.length == 5 && doc.materials.length == 4 && doc.nodes.length == 7 && doc.scenes.length == 1 && doc.cameras.length == 1
			&& doc.animations.length == 3);
		check("names", [for (n in doc.nodes) n.name].join(",") == "ground,pedestal,ball,orbit,moon,satellite,camera");
		check("roots", doc.roots().join(",") == "0,1,3,5,6");
		check("children", doc.nodes[1].children.join(",") == "2" && doc.nodes[3].children.join(",") == "4");
		var ground = doc.meshes[0].primitives[0], cube = doc.meshes[1].primitives[0], sphere = doc.meshes[2].primitives[0];
		check("8-bit indices", doc.indices(ground.indices).join(",") == "0,1,2,0,2,3");
		check("ground positions", same(doc.floats(ground.position), SampleModel.groundPositions));
		check("interleaved positions (byteStride)", same(doc.floats(cube.position), SampleModel.cubePositions));
		var n = doc.floats(cube.normal);
		check("interleaved normals", n.length == 72 && n[0] == 0 && n[1] == 0 && n[2] == 1 && n[69] == 0 && n[70] == -1);
		check("16-bit indices", doc.indices(cube.indices).length == 36 && doc.indices(cube.indices)[35] == 23);
		check("32-bit indices", doc.indices(sphere.indices).join(",") == SampleModel.sphereIndices.join(","));
		check("sphere positions", same(doc.floats(sphere.position), SampleModel.spherePositions));
		var uv = doc.floats(sphere.texcoord);
		check("normalized 16-bit UVs", near(uv[0], 0) && near(uv[2], 1 / 24, 1e-4) && near(uv[uv.length - 1], 1) && near(uv[uv.length - 2], 1));
		var a = doc.accessors[cube.position];
		check("min and max", a.min != null && a.min.join(",") == "-0.5,-0.5,-0.5" && a.max.join(",") == "0.5,0.5,0.5");
		var gold = doc.materials[2];
		check("material", gold.name == "gold" && near(gold.baseColor.y, 0.77) && gold.metallic == 1 && near(gold.roughness, 0.3)
			&& gold.alphaMode == "OPAQUE" && !gold.doubleSided && gold.baseColorTexture == -1);
		check("primitive's material", doc.meshes[3].primitives[0].material == 3 && sphere.material == 2);
		check("absent attributes", cube.texcoord == -1 && cube.tangent == -1 && ground.color == -1);
		var cam = doc.cameras[0];
		check("camera", cam.perspective && near(cam.yfov, 0.7) && near(cam.znear, 0.1) && cam.zfar == 100);
		check("matrix node", doc.nodes[3].matrix != null && doc.nodes[3].matrix.length == 16);
	}

	static function same(a:Array<Float>, b:Array<Float>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length)
			if (!near(a[i], b[i])) return false;
		return true;
	}

	static function nodes(doc:GltfDoc) {
		var meshes = [];
		var world = new World();
		var top = GltfNodes.build(doc, world, null, 0, (n, k) -> meshes.push(n.name + ":" + k));
		check("root", top.name == "sample" && top.parent == world.root && [for (c in top.children()) c].length == 5);
		var ball = top.find("ball"), pedestal = top.find("pedestal");
		check("hierarchy", ball.parent == pedestal && top.find("moon").parent == top.find("orbit"));
		check("meshes", meshes.join(",") == "ground:0,pedestal:1,ball:2,moon:3,satellite:4");
		check("ball's world", nearV(ball.worldPosition(), new Vec3(0, 1.6, 0), 1e-6));
		var w = ball.worldMatrix();
		check("ball's scale", near(w.c0.x * w.c0.x + w.c0.z * w.c0.z, 0.36, 1e-5));
		// (the orbit's matrix: a turn of 0.9 about y and a lift of 0.2)
		var moon = top.find("moon").worldPosition();
		check("matrix node: decomposed", nearV(moon, new Vec3(2.3 * Math.cos(0.9), 0.65, -2.3 * Math.sin(0.9)), 1e-5));
		var cam = Camera.of(top.find("camera"));
		check("camera node", cam != null && near(cam.fovY, 0.7) && Camera.first(world) == cam);
		// (the camera looks at the pedestal's middle, as made)
		var c = cam.viewProjection(4 / 3).transformPoint(new Vec3(0, 0.7, 0));
		check("camera looks at the scene", near(c.x, 0, 1e-5) && near(c.y, 0, 1e-5));
		var again = GltfNodes.build(doc, world);
		check("instantiated twice", again != top && again.find("ball") != ball && world.count == 1 + 2 * 8);
		world.dispose();
	}

	static function animations(doc:GltfDoc) {
		check("animations", [for (a in doc.animations) a.name].join(",") == "spin,bounce,pulse" && doc.animations[1].channels[0].interpolation == "STEP");
		var world = new World(), made = [];
		GltfNodes.build(doc, world, null, null, null, null, made);
		check("made: by glTF index", made.length == 7 && made[2].name == "ball" && made[4].name == "moon");
		var spin = AnimationClip.fromGltf(doc, 0), bounce = AnimationClip.fromGltf(doc, 1), pulse = AnimationClip.fromGltf(doc, 2);
		check("durations", spin.duration == 4 && bounce.duration == 4 && pulse.duration == 4);
		spin.apply(made, 0.5);
		check("linear rotation: slerped", nearQ(made[1].rotation, Quat.axisAngle(new Vec3(0, 1, 0), 0.5 + Math.PI / 4), 1e-5));
		bounce.apply(made, 0.5);
		check("step translation", nearV(made[2].position, new Vec3(0, 1.1, 0)));
		bounce.apply(made, 1.0);
		check("step translation at a key", nearV(made[2].position, new Vec3(0, 1.6, 0)));
		pulse.apply(made, 0.5);
		check("cubic spline scale (Hermite, flat tangents)", nearV(made[4].scale, new Vec3(0.525, 0.525, 0.525), 1e-6));
		pulse.apply(made, 9);
		check("clamped after the end", nearV(made[4].scale, new Vec3(0.45, 0.45, 0.45), 1e-6));
		var animator = new Animator(made);
		animator.play(bounce);
		animator.update(1.25);
		check("animator: time", near(animator.time, 1.25) && nearV(made[2].position, new Vec3(0, 1.6, 0)));
		animator.update(3.0);
		check("animator: loops", near(animator.time, 0.25));
		// (bounce leaves the pedestal alone: during the fade it blends from where it is)
		made[1].rotation = Quat.identity();
		animator.play(spin, {fade: 1.0, loop: false});
		animator.update(0.5);
		var half = made[1].rotation;
		animator.update(0.6);
		check("cross-fade, then the new clip alone", nearQ(half, Quat.slerp(Quat.identity(), Quat.axisAngle(new Vec3(0, 1, 0), 0.5 + Math.PI / 4), 0.5), 1e-5)
			&& nearQ(made[1].rotation, Quat.axisAngle(new Vec3(0, 1, 0), 0.5 + 1.1 * Math.PI / 2), 1e-5));
		animator.update(10);
		check("not looping: held at the end", near(animator.time, 4));
		world.dispose();
	}

	static function nearQ(a:Quat, b:Quat, eps = 1e-9):Bool
		return Math.abs(Math.abs(a.dot(b)) - 1) <= eps;

	static function skins() {
		var file = sys.io.File.getBytes("packages/3d/examples/skinned.glb");
		#if eval
		check("skinned.glb is the generator's", SampleModel.skinnedGlb().compare(file) == 0);
		#end
		var doc = Gltf.parse(file);
		var p = doc.meshes[0].primitives[0];
		check("a skin", doc.skins.length == 1 && doc.skins[0].joints.join(",") == "1,2" && doc.nodes[0].skin == 0 && doc.skins[0].inverseBindMatrices >= 0);
		var j = doc.floats(p.joints), w = doc.floats(p.weights);
		check("JOINTS_0 and WEIGHTS_0", j.length == w.length && j[1] == 1 && w[0] == 1 && w[1] == 0 && w[w.length - 3] == 1);
		var ibm = doc.floats(doc.skins[0].inverseBindMatrices);
		check("inverse bind matrices", ibm.length == 32 && ibm[16 + 13] == -1);
		var parts = GltfFile.split(file);
		var bad = SampleModel.pack({json: StringTools.replace(parts.json, '"skin":0', '"skin":4'), bin: parts.bin});
		var threw = try {
			Gltf.parse(bad);
			false;
		} catch (e:String) StringTools.startsWith(e, "glTF: node 0: skin");
		check("rejects a skin out of range", threw);
	}

	static function textured() {
		var file = sys.io.File.getBytes("packages/3d/examples/textured.glb");
		#if eval
		check("textured.glb is the generator's", SampleModel.texturedGlb().compare(file) == 0);
		#end
		var doc = Gltf.parse(file);
		var png = doc.imageBytes(0);
		check("an image in a buffer view", doc.images.length == 1 && doc.images[0].mimeType == "image/png" && png != null && png.get(1) == 0x50
			&& png.get(2) == 0x4E && png.get(3) == 0x47);
		check("texture, sampler, material", doc.textures.length == 1 && doc.textures[0].source == 0 && doc.samplers[0].minFilter == 9729
			&& doc.materials[0].baseColorTexture == 0 && doc.materials[0].metallicRoughnessTexture == 0 && doc.materials[0].emissiveTexture == 0
			&& doc.materials[0].occlusionTexture == 0);
		var image = Png.decode(png);
		check("the image decodes", image.width == 64 && image.height == 64);
		// (glTF's samplers as gfx's: null where the renderer's own)
		check("the sample's sampler is the renderer's", hxmc.scene.gltf.GltfSamplers.desc(9729, 9987, 10497, 10497) == null
			&& hxmc.scene.gltf.GltfSamplers.desc(0, 0, 10497, 10497) == null);
		var pixelated = hxmc.scene.gltf.GltfSamplers.desc(9728, 9728, 33071, 33071);
		check("a nearest, clamped sampler without mip levels", pixelated != null && pixelated.filter == Nearest && pixelated.mipFilter == null
			&& pixelated.wrap == Clamp);
		var mirrored = hxmc.scene.gltf.GltfSamplers.desc(9729, 9985, 33648, 10497);
		check("a mirrored one, nearest between mip levels", mirrored != null && mirrored.mipFilter == Nearest && mirrored.wrap == Mirror);
	}

	static function normals() {
		var file = sys.io.File.getBytes("packages/3d/examples/normals.glb");
		#if eval
		check("normals.glb is the generator's", SampleModel.normalsGlb().compare(file) == 0);
		check("panorama.png is the generator's", SampleModel.environmentPng().compare(sys.io.File.getBytes("packages/3d/examples/panorama.png")) == 0);
		#end
		var doc = Gltf.parse(file);
		var m = doc.materials[0];
		check("a normal map and its scale", m.normalTexture == 0 && m.normalScale == 1.5 && m.baseColorTexture == -1);
		var p = doc.meshes[0].primitives[0];
		check("no tangents in the file", p.tangent == -1);
		// computed: each face's tangent along its uvs' u (the face's right),
		// the bitangent n x t (times w) up the image (the face's up, uvs' v down)
		var pos = doc.floats(p.position), nor = doc.floats(p.normal), uv = doc.floats(p.texcoord), idx = doc.indices(p.indices);
		var t = hxmc.scene.render.VertexData.computeTangents(pos, nor, uv, idx);
		var ok = t.length == 4 * 24;
		var rights = [[1, 0, 0], [-1, 0, 0], [0, 0, -1], [0, 0, 1], [1, 0, 0], [1, 0, 0]];
		var ups = [[0, 1, 0], [0, 1, 0], [0, 1, 0], [0, 1, 0], [0, 0, -1], [0, 0, 1]];
		for (v in 0...24) {
			var f = Std.int(v / 4), r = rights[f], u = ups[f];
			var n = [nor[3 * v], nor[3 * v + 1], nor[3 * v + 2]], w = t[4 * v + 3];
			var b = [(n[1] * t[4 * v + 2] - n[2] * t[4 * v + 1]) * w, (n[2] * t[4 * v] - n[0] * t[4 * v + 2]) * w, (n[0] * t[4 * v + 1] - n[1] * t[4 * v]) * w];
			for (k in 0...3)
				if (Math.abs(t[4 * v + k] - r[k]) > 1e-6 || Math.abs(b[k] - u[k]) > 1e-6) ok = false;
		}
		check("tangents from the uvs: right and up on every face", ok);
		// a mirrored face (its u reversed): the sign flips
		var flipped = hxmc.scene.render.VertexData.computeTangents([0, 0, 0, 1, 0, 0, 0, 1, 0], [0, 0, 1, 0, 0, 1, 0, 0, 1], [1, 1, 0, 1, 1, 0], [0, 1, 2]);
		check("a mirrored face's tangent and sign", Math.abs(flipped[0] + 1) < 1e-6 && flipped[3] == -1);
	}

	static function morphs() {
		var file = sys.io.File.getBytes("packages/3d/examples/morph.glb");
		#if eval
		check("morph.glb is the generator's", SampleModel.morphGlb().compare(file) == 0);
		#end
		var doc = Gltf.parse(file);
		var p = doc.meshes[0].primitives[0];
		check("two morph targets, positions and normals", p.targets.length == 2 && p.targets[1].position == 4 && p.targets[1].normal == 5);
		check("the mesh's default weights", doc.meshes[0].weights.join(",") == "1,0" && doc.nodes[0].weights == null);
		var clip = hxmc.scene.anim.AnimationClip.fromGltf(doc, 0);
		var w = [0.0, 0.0];
		clip.tracks[0].weightsAt(1.5, w);
		check('weights played (${w.join(",")})', clip.tracks[0].path == Weights && Math.abs(w[0] - 0.5) < 1e-9 && Math.abs(w[1] - 0.5) < 1e-9);
	}

	static function rejects(glb:Bytes) {
		function fails(what:String, f:Void->Void) {
			var msg = try {
				f();
				null;
			} catch (e:String) e;
			check('rejects $what' + (msg != null ? "" : " (accepted)"), msg != null && StringTools.startsWith(msg, "glTF: "));
		}
		fails("a truncated .glb", () -> Gltf.parse(glb.sub(0, 100)));
		var json = SampleModel.gltf().toString();
		function edited(from:String, to:String):Bytes {
			if (json.indexOf(from) < 0) throw 'GltfTest: no $from';
			return Bytes.ofString(StringTools.replace(json, from, to));
		}
		fails("version 1", () -> Gltf.parse(edited('"version":"2.0"', '"version":"1.0"')));
		fails("a node out of range", () -> Gltf.parse(edited('"children":[2]', '"children":[9]')));
		fails("a cycle", () -> Gltf.parse(edited('"children":[4]', '"children":[3]')));
		fails("two parents", () -> Gltf.parse(edited('"children":[4]', '"children":[4,2]')));
		fails("an accessor out of its view", () -> Gltf.parse(edited('"count":36', '"count":3600')));
		fails("a material out of range", () -> Gltf.parse(edited('"material":3}', '"material":30}')));
		fails("a missing buffer file", () -> Gltf.parse(edited('"uri":"data:', '"uri":"x.bin","x":"')));
		var lit = Gltf.parse(Bytes.ofString(edited('"scene":0,', '"scene":0,"extensions":{"KHR_lights_punctual":{"lights":[{"type":"point","color":[1,0.5,0],"intensity":20,"range":9},{"type":"directional"}]}},').toString()
			.split('{"name":"ball","mesh":2').join('{"name":"ball","extensions":{"KHR_lights_punctual":{"light":0}},"mesh":2')));
		var lights = [];
		GltfNodes.build(lit, new World(), null, null, null, (n, k) -> lights.push(n.name + ":" + k));
		check("KHR_lights_punctual", lit.lights.length == 2 && lit.lights[0].type == "point" && lit.lights[0].intensity == 20 && lit.lights[0].range == 9
			&& near(lit.lights[0].color.y, 0.5) && lit.lights[1].intensity == 1 && lit.nodes[2].light == 0 && lights.join(",") == "ball:0");
		fails("a light out of range", () -> Gltf.parse(Bytes.ofString(StringTools.replace(json, '{"name":"ball","mesh":2', '{"name":"ball","extensions":{"KHR_lights_punctual":{"light":3}},"mesh":2'))));
		var resolved = false;
		var doc = Gltf.parse(edited('"uri":"data:application/octet-stream;base64,', '"uri":"sample.bin","x":"'), uri -> {
			resolved = uri == "sample.bin";
			return Gltf.parse(glb).buffers[0];
		});
		check("a buffer from resolve", resolved && doc.meshes.length == 5);
	}
}
