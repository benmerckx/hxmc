package hxmc.scene.gltf;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import hxmc.scene.math.MathTools;
import hxmc.scene.render.VertexData;

// The asset step (docs/plans/3d.md, step 2): a glTF file read at build time
// (Gltf.parse, the runtime's reader) and written compact for
// PackedModel: each primitive's vertices and indices already in the
// renderer's layout (VertexData; joints and weights for skins, tangents
// computed here where a normal map is drawn), node transforms decomposed,
// materials (factors, maps, sampler), images as the file has them (PNG,
// JPEG: decoded when loaded), cameras, lights, skins, morph targets and
// animations; no
// JSON, so a program loading only packed models links no JSON reader.
//
//   bin/hxmc/hxmc -cp packages/os/src -cp packages/gfx/src -cp packages/3d/src \
//     --run hxmc.scene.gltf.Pack <in.glb> <out.hxm3d>
//
// The format (little-endian): "HXM3", version 3, then counts and records:
//   images      mime, byte count, bytes
//   materials   name, base colour 4 floats, metallic, roughness, emissive 3
//               floats, flags (1: double-sided, 2: blended), normal scale,
//               the maps' images (base colour, metallic-roughness, normal,
//               emissive, occlusion; -1: none), the sampler (magFilter,
//               minFilter, wrapS, wrapT; glTF's)
//   vertex data flags (2: wide indices, 4: skinned, 8: tangents), index
//               count, vertex bytes, index bytes, tangent bytes (flag 8),
//               bounds 6 floats: once per set of accessors
//   meshes      name, primitives: material, vertex data, morph targets
//               (each: flags (1 positions, 2 normals), their displacements),
//               the targets' default weights
//   cameras     perspective byte, yfov or height, near, far
//   lights      kind (0 directional, 1 point, 2 spot), colour 3 floats,
//               intensity, range, inner and outer cone
//   skins       joints (nodes), their inverse bind matrices (16 floats each)
//   nodes       parents first: name, parent, mesh, camera, light, skin, TRS
//               10 floats, morph weights (none: the mesh's)
//   animations  name, tracks: node, path (0 translation, 1 rotation, 2
//               scale, 3 weights), interpolation (0 step, 1 linear, 2 cubic spline),
//               times, values
//   the roots' scene name
// (nodes are referred to by their place in the nodes' list)
class Pack {
	public static inline var MAGIC = 0x334D5848; // "HXM3"
	public static inline var VERSION = 3;

	static function main() {
		var args = Sys.args();
		if (args.length != 2) {
			Sys.println("usage: Pack <in.gltf|in.glb> <out.hxm3d>");
			Sys.exit(2);
		}
		var input = sys.io.File.getBytes(args[0]);
		var dir = haxe.io.Path.directory(args[0]);
		var out = pack(Gltf.parse(input, uri -> {
			var f = haxe.io.Path.join([dir, uri]);
			sys.FileSystem.exists(f) ? sys.io.File.getBytes(f) : null;
		}));
		sys.io.File.saveBytes(args[1], out);
		Sys.println('Pack: ${args[0]} (${input.length} bytes) to ${args[1]} (${out.length} bytes)');
	}

	public static function pack(doc:GltfDoc, ?scene:Int):Bytes {
		var o = new BytesOutput();
		o.bigEndian = false;
		function str(s:String) {
			var b = Bytes.ofString(s);
			o.writeUInt16(b.length);
			o.write(b);
		}
		function floats(a:Array<Float>) {
			o.writeInt32(a.length);
			for (x in a)
				o.writeFloat(x);
		}
		o.writeInt32(MAGIC);
		o.writeInt32(VERSION);
		o.writeInt32(doc.images.length);
		for (k in 0...doc.images.length) {
			var b = doc.imageBytes(k);
			str(doc.images[k].mimeType);
			if (b == null) o.writeInt32(0) else {
				o.writeInt32(b.length);
				o.write(b);
			}
		}
		function image(texture:Int):Int
			return texture >= 0 ? doc.textures[texture].source : -1;
		o.writeInt32(doc.materials.length);
		for (m in doc.materials) {
			str(m.name);
			for (x in [m.baseColor.x, m.baseColor.y, m.baseColor.z, m.baseColor.w, m.metallic, m.roughness, m.emissive.x, m.emissive.y, m.emissive.z])
				o.writeFloat(x);
			o.writeByte((m.doubleSided ? 1 : 0) | (m.alphaMode == "BLEND" ? 2 : 0));
			o.writeFloat(m.normalScale);
			var maps = [m.baseColorTexture, m.metallicRoughnessTexture, m.normalTexture, m.emissiveTexture, m.occlusionTexture];
			for (t in maps)
				o.writeInt32(image(t));
			// (one sampler a material: its base colour's, else its first map's: GltfScene's)
			var sampler = -1;
			for (t in maps)
				if (t >= 0) {
					sampler = doc.textures[t].sampler;
					break;
				}
			var s = sampler >= 0 ? doc.samplers[sampler] : null;
			var fields = s != null ? [s.magFilter, s.minFilter, s.wrapS, s.wrapT] : [0, 0, 10497, 10497];
			for (x in fields)
				o.writeInt32(x);
		}
		// (the vertex data once per set of accessors: primitives sharing them share it)
		var keys = new Map<String, Int>(), datas:Array<VertexData> = [];
		function dataOf(p:GltfDoc.GltfPrimitive):Int {
			var mapped = p.material >= 0 && doc.materials[p.material].normalTexture >= 0 && p.texcoord >= 0 && p.joints < 0;
			var key = p.position + "," + p.normal + "," + p.texcoord + "," + p.indices + "," + p.joints + "," + p.weights + "," + (mapped ? p.tangent : -2);
			if (!keys.exists(key)) {
				var positions = doc.floats(p.position), normals = p.normal >= 0 ? doc.floats(p.normal) : null;
				var uvs = p.texcoord >= 0 ? doc.floats(p.texcoord) : null, indices = p.indices >= 0 ? doc.indices(p.indices) : null;
				var tangents:Null<Array<Float>> = null;
				if (mapped) {
					if (p.tangent >= 0) tangents = doc.floats(p.tangent) else {
						if (indices == null) indices = [for (i in 0...Std.int(positions.length / 3)) i];
						if (normals == null) normals = VertexData.smoothNormals(positions, indices);
						tangents = VertexData.computeTangents(positions, normals, uvs, indices);
					}
				}
				datas.push(VertexData.make(positions, normals, uvs, indices, p.joints >= 0 ? doc.floats(p.joints) : null,
					p.weights >= 0 ? doc.floats(p.weights) : null, tangents));
				keys.set(key, datas.length - 1);
			}
			return keys.get(key);
		}
		var meshPrims = [for (mesh in doc.meshes) [for (p in mesh.primitives) if (p.mode == 4 && p.position >= 0) {material: p.material, data: dataOf(p), prim: p}]];
		o.writeInt32(datas.length);
		for (d in datas) {
			o.writeByte((d.wide ? 2 : 0) | (d.skinned ? 4 : 0) | (d.tangents != null ? 8 : 0));
			o.writeInt32(d.count);
			o.writeInt32(d.vertices.length);
			o.write(d.vertices);
			o.writeInt32(d.indices.length);
			o.write(d.indices);
			if (d.tangents != null) {
				o.writeInt32(d.tangents.length);
				o.write(d.tangents);
			}
			for (x in [d.bounds.min.x, d.bounds.min.y, d.bounds.min.z, d.bounds.max.x, d.bounds.max.y, d.bounds.max.z])
				o.writeFloat(x);
		}
		o.writeInt32(doc.meshes.length);
		for (k in 0...doc.meshes.length) {
			str(doc.meshes[k].name);
			o.writeInt32(meshPrims[k].length);
			for (p in meshPrims[k]) {
				o.writeInt32(p.material);
				o.writeInt32(p.data);
				o.writeInt32(p.prim.targets.length);
				for (t in p.prim.targets) {
					o.writeByte((t.position >= 0 ? 1 : 0) | (t.normal >= 0 ? 2 : 0));
					if (t.position >= 0) floats(doc.floats(t.position));
					if (t.normal >= 0) floats(doc.floats(t.normal));
				}
			}
			floats(doc.meshes[k].weights);
		}
		o.writeInt32(doc.cameras.length);
		for (c in doc.cameras) {
			o.writeByte(c.perspective ? 1 : 0);
			o.writeFloat(c.perspective ? c.yfov : 2 * c.ymag);
			o.writeFloat(c.znear);
			o.writeFloat(c.zfar > 0 ? c.zfar : 1000);
		}
		o.writeInt32(doc.lights.length);
		for (l in doc.lights) {
			o.writeByte(switch l.type {
				case "directional": 0;
				case "spot": 2;
				case _: 1;
			});
			for (x in [l.color.x, l.color.y, l.color.z, l.intensity, l.range > 0 ? l.range : 1000, l.innerCone, l.outerCone])
				o.writeFloat(x);
		}
		// (the scene's nodes, parents first, each with its parent's index in this list)
		var order:Array<Int> = [], parentOf:Array<Int> = [];
		var placeOf = [for (_ in doc.nodes) -1];
		function visit(k:Int, parent:Int) {
			order.push(k);
			parentOf.push(parent);
			var me = order.length - 1;
			placeOf[k] = me;
			for (c in doc.nodes[k].children)
				visit(c, me);
		}
		for (r in doc.roots(scene != null ? scene : -1))
			visit(r, -1);
		o.writeInt32(doc.skins.length);
		for (skin in doc.skins) {
			o.writeInt32(skin.joints.length);
			for (j in skin.joints)
				o.writeInt32(placeOf[j]);
			floats(skin.inverseBindMatrices >= 0 ? doc.floats(skin.inverseBindMatrices).slice(0, 16 * skin.joints.length) : [
				for (_ in skin.joints) for (i in 0...16) i % 5 == 0 ? 1.0 : 0.0
			]);
		}
		o.writeInt32(order.length);
		for (i in 0...order.length) {
			var g = doc.nodes[order[i]];
			str(g.name);
			o.writeInt32(parentOf[i]);
			o.writeInt32(g.mesh);
			o.writeInt32(g.camera);
			o.writeInt32(g.light);
			o.writeInt32(g.skin);
			var t = g.translation, r = g.rotation, s = g.scale;
			if (g.matrix != null) {
				var m = g.matrix;
				var d = MathTools.decompose(new hxmc.gfx.shader.Mat4(new hxmc.gfx.shader.Vec4(m[0], m[1], m[2], m[3]),
					new hxmc.gfx.shader.Vec4(m[4], m[5], m[6], m[7]), new hxmc.gfx.shader.Vec4(m[8], m[9], m[10], m[11]),
					new hxmc.gfx.shader.Vec4(m[12], m[13], m[14], m[15])));
				t = d.t;
				r = d.r;
				s = d.s;
			}
			for (x in [t.x, t.y, t.z, r.x, r.y, r.z, r.w, s.x, s.y, s.z])
				o.writeFloat(x);
			floats(g.weights != null ? g.weights : []);
		}
		o.writeInt32(doc.animations.length);
		for (a in doc.animations) {
			str(a.name);
			var channels = [for (c in a.channels) if (placeOf[c.node] >= 0) c];
			o.writeInt32(channels.length);
			for (c in channels) {
				o.writeInt32(placeOf[c.node]);
				o.writeByte(switch c.path {
					case "translation": 0;
					case "rotation": 1;
					case "weights": 3;
					case _: 2;
				});
				o.writeByte(switch c.interpolation {
					case "STEP": 0;
					case "CUBICSPLINE": 2;
					case _: 1;
				});
				floats(doc.floats(c.input));
				floats(doc.floats(c.output));
			}
		}
		var s = scene != null ? scene : doc.scene;
		str(s >= 0 && s < doc.scenes.length ? doc.scenes[s].name : "gltf");
		return o.getBytes();
	}
}
