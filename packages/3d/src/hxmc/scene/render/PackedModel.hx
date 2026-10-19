package hxmc.scene.render;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import hxmc.gfx.Device;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.Camera;
import hxmc.scene.Node;
import hxmc.scene.World;
import hxmc.scene.anim.AnimationClip;
import hxmc.scene.math.Aabb;
import hxmc.scene.math.Quat;

// A model packed at build time (hxmc.scene.gltf.Pack): read without JSON,
// its vertex data handed to the GPU as it is, its images decoded by
// Images.decode, instantiated into worlds as GltfScene's are (cameras,
// lights, skins; made: the nodes in the file's order, for an Animator of
// its clips):
//
//   var level = PackedModel.read(Asset.embed("level.hxm3d"), device);
//   var made = [];
//   level.instantiate(world, null, made);
//   new Animator(made).play(level.clip("walk"));
class PackedModel {
	public final meshes:Array<Mesh> = [];
	public final materials:Array<Material> = [];
	// the images' textures (null: not decoded)
	public final textures:Array<Null<hxmc.gfx.Texture>> = [];
	// the animations' names (clip makes one; a program playing none links
	// no keyframe code)
	public final animations:Array<String> = [];
	final tracks:Array<Array<{node:Int, path:Int, interpolation:Int, times:Array<Float>, values:Array<Float>}>> = [];
	final device:Device;
	final cameras:Array<{perspective:Bool, size:Float, near:Float, far:Float}> = [];
	final lights:Array<{kind:Int, f:Array<Float>}> = [];
	final skins:Array<{joints:Array<Int>, inverseBind:Array<Float>}> = [];
	final nodes:Array<{name:String, parent:Int, mesh:Int, camera:Int, light:Int, skin:Int, trs:Array<Float>, weights:Array<Float>}> = [];
	// per mesh with morph targets: its primitives' sources and its default weights (Morph.bend)
	final morphs:Array<Null<{sources:Array<Morph.MorphSource>, weights:Array<Float>}>> = [];
	var sceneName = "";

	function new(device:Device)
		this.device = device;

	public static function read(bytes:Bytes, device:Device):PackedModel {
		var m = new PackedModel(device);
		var i = new BytesInput(bytes);
		i.bigEndian = false;
		function str():String
			return i.readString(i.readUInt16());
		function floats():Array<Float>
			return [for (_ in 0...i.readInt32()) i.readFloat()];
		if (i.readInt32() != 0x334D5848) throw "PackedModel: not a packed model";
		if (i.readInt32() != 3) throw "PackedModel: another version (pack it again)";
		for (_ in 0...i.readInt32()) {
			var mime = str(), n = i.readInt32();
			var b = n > 0 ? i.read(n) : null;
			m.textures.push(Images.texture(device, mime, b));
		}
		var samplers = new Map<String, hxmc.gfx.Sampler>();
		for (_ in 0...i.readInt32()) {
			var name = str();
			var f = [for (_ in 0...9) i.readFloat()];
			var flags = i.readByte();
			var mat = new Material(name, new Vec4(f[0], f[1], f[2], f[3]), f[4], f[5], new Vec3(f[6], f[7], f[8]), flags & 1 != 0);
			mat.blend = flags & 2 != 0;
			mat.normalScale = i.readFloat();
			var maps = [for (_ in 0...5) i.readInt32()];
			function tex(k:Int):Null<hxmc.gfx.Texture>
				return maps[k] >= 0 ? m.textures[maps[k]] : null;
			mat.baseColorTexture = tex(0);
			mat.metallicRoughnessTexture = tex(1);
			mat.normalTexture = tex(2);
			mat.emissiveTexture = tex(3);
			mat.occlusionTexture = tex(4);
			var s = [for (_ in 0...4) i.readInt32()];
			var desc = hxmc.scene.gltf.GltfSamplers.desc(s[0], s[1], s[2], s[3]);
			if (desc != null) {
				var key = s.join(",");
				if (!samplers.exists(key)) samplers.set(key, device.createSampler(desc));
				mat.sampler = samplers.get(key);
			}
			m.materials.push(mat);
		}
		var datas:Array<VertexData> = [];
		for (_ in 0...i.readInt32()) {
			var flags = i.readByte(), count = i.readInt32();
			var vertices = i.read(i.readInt32()), indices = i.read(i.readInt32());
			var tangents = flags & 8 != 0 ? i.read(i.readInt32()) : null;
			var b = [for (_ in 0...6) i.readFloat()];
			// (tangents uploaded only with NormalMaps made)
			datas.push(new VertexData(vertices, indices, flags & 2 != 0, count, flags & 4 != 0, new Aabb(new Vec3(b[0], b[1], b[2]), new Vec3(b[3], b[4], b[5])),
				VertexData.tangentsFrom != null ? tangents : null));
		}
		var fallback:Null<Material> = null;
		for (_ in 0...i.readInt32()) {
			str();
			var mesh = new Mesh(), sources:Array<Morph.MorphSource> = [];
			for (_ in 0...i.readInt32()) {
				var material = i.readInt32(), data = i.readInt32();
				var mat = if (material >= 0) m.materials[material] else {
					if (fallback == null) fallback = new Material("default");
					fallback;
				}
				var prim = mesh.addData(device, datas[data], mat);
				var targets = i.readInt32();
				if (targets > 0) {
					var positions:Array<Null<Array<Float>>> = [], normals:Array<Null<Array<Float>>> = [];
					for (_ in 0...targets) {
						var flags = i.readByte();
						positions.push(flags & 1 != 0 ? floats() : null);
						normals.push(flags & 2 != 0 ? floats() : null);
					}
					sources.push({prim: prim, vertices: datas[data].vertices, stride: datas[data].skinned ? 64 : 32, positions: positions, normals: normals});
				}
			}
			var weights = floats();
			m.morphs.push(sources.length > 0 ? {sources: sources, weights: weights} : null);
			m.meshes.push(mesh);
		}
		for (_ in 0...i.readInt32()) {
			var perspective = i.readByte() == 1;
			m.cameras.push({perspective: perspective, size: i.readFloat(), near: i.readFloat(), far: i.readFloat()});
		}
		for (_ in 0...i.readInt32()) {
			var kind = i.readByte();
			m.lights.push({kind: kind, f: [for (_ in 0...7) i.readFloat()]});
		}
		for (_ in 0...i.readInt32()) {
			var joints = [for (_ in 0...i.readInt32()) i.readInt32()];
			m.skins.push({joints: joints, inverseBind: floats()});
		}
		for (_ in 0...i.readInt32()) {
			var name = str(), parent = i.readInt32(), mesh = i.readInt32(), camera = i.readInt32(), light = i.readInt32(), skin = i.readInt32();
			m.nodes.push({
				name: name,
				parent: parent,
				mesh: mesh,
				camera: camera,
				light: light,
				skin: skin,
				trs: [for (_ in 0...10) i.readFloat()],
				weights: floats()
			});
		}
		for (_ in 0...i.readInt32()) {
			m.animations.push(str());
			var list = [];
			for (_ in 0...i.readInt32()) {
				var node = i.readInt32(), path = i.readByte(), interpolation = i.readByte();
				list.push({node: node, path: path, interpolation: interpolation, times: floats(), values: floats()});
			}
			m.tracks.push(list);
		}
		m.sceneName = str();
		return m;
	}

	// an animation by name (null: none of that name); its tracks address
	// the nodes instantiate made, in their order
	public function clip(name:String):Null<AnimationClip> {
		var k = animations.indexOf(name);
		if (k < 0) return null;
		return new AnimationClip(name, [
			for (t in tracks[k])
				new hxmc.scene.anim.AnimationClip.Track(t.node, t.path == 0 ? Translation : t.path == 1 ? Rotation : t.path == 3 ? Weights : Scale, t.times, t.values,
					t.interpolation == 0 ? Step : t.interpolation == 2 ? CubicSpline : Linear)
		]);
	}

	// the model's nodes in world, under one new node (under parent); made:
	// the nodes, in the file's order (an Animator's)
	public function instantiate(world:World, ?parent:Node, ?made:Array<Node>):Node {
		var top = world.node(sceneName, parent);
		if (made == null) made = [];
		var first = made.length;
		for (k in 0...nodes.length) {
			var g = nodes[k], t = g.trs;
			var n = world.node(g.name, g.parent >= 0 ? made[first + g.parent] : top);
			n.position = new Vec3(t[0], t[1], t[2]);
			n.rotation = new Quat(t[3], t[4], t[5], t[6]);
			n.scale = new Vec3(t[7], t[8], t[9]);
			if (g.mesh >= 0) MeshRenderer.attach(n, meshes[g.mesh]);
			if (g.camera >= 0) {
				var c = cameras[g.camera];
				Camera.attach(n, c.perspective ? Camera.perspective(c.size, c.near, c.far) : Camera.orthographic(c.size, c.near, c.far));
			}
			if (g.light >= 0) {
				var l = lights[g.light], f = l.f, color = new Vec3(f[0], f[1], f[2]);
				Light.attach(n, switch l.kind {
					case 0: Light.directional(color, f[3]);
					case 2: Light.spot(color, f[3], f[4], f[5], f[6]);
					case _: Light.pointLight(color, f[3], f[4]);
				});
			}
			made.push(n);
		}
		// (morph targets: each node its own copy of the vertices)
		for (k in 0...nodes.length) {
			var g = nodes[k];
			if (g.mesh < 0 || morphs[g.mesh] == null) continue;
			var mo = morphs[g.mesh];
			Morph.bend(device, made[first + k], mo.sources, g.weights.length > 0 ? g.weights : mo.weights);
		}
		// (skins: their joints are this instance's nodes)
		for (k in 0...nodes.length)
			if (nodes[k].skin >= 0) {
				var s = skins[nodes[k].skin];
				Skin.attach(made[first + k], new Skin(device, [for (j in s.joints) made[first + j]], s.inverseBind));
			}
		return top;
	}
}
