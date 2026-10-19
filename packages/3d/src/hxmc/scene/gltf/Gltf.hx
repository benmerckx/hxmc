package hxmc.scene.gltf;

import haxe.io.Bytes;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.gltf.GltfDoc;
import hxmc.scene.math.Quat;

// glTF 2.0 files read into a GltfDoc: the JSON form (.gltf: buffers as
// data: URIs, or files that resolve returns) and the binary form (.glb: a
// JSON chunk and a BIN chunk, the first buffer's bytes). The JSON is read
// once into typed data and checked (every index in range, every buffer
// view inside its buffer, every accessor inside its view), so nothing
// after parse sees Dynamic or reads out of bounds. Errors throw a String
// starting with "glTF: ".
class Gltf {
	// whether bytes are a .glb file
	public static inline function isGlb(b:Bytes):Bool
		return GltfFile.isGlb(b);

	// a .gltf or .glb file; resolve(uri) gives the bytes of a file it names
	// (a buffer, an image: relative to the file), null when there is none
	public static function parse(bytes:Bytes, ?resolve:String->Null<Bytes>):GltfDoc {
		var parts = GltfFile.split(bytes);
		return read(haxe.Json.parse(parts.json), parts.bin, resolve);
	}

	static function read(root:Dynamic, bin:Null<Bytes>, resolve:Null<String->Null<Bytes>>):GltfDoc {
		var doc = new GltfDoc();
		var asset = obj(root, "asset");
		if (asset == null) throw "glTF: no asset";
		var version = str(asset, "version", "");
		if (version.charAt(0) != "2") throw 'glTF: version $version';
		doc.generator = str(asset, "generator", "");
		function uriBytes(uri:String, what:String):Null<Bytes> {
			if (StringTools.startsWith(uri, "data:")) {
				var comma = uri.indexOf(",");
				if (comma < 0 || uri.lastIndexOf(";base64", comma) < 0) throw 'glTF: $what: a data URI not in base64';
				return haxe.crypto.Base64.decode(uri.substr(comma + 1));
			}
			return resolve != null ? resolve(StringTools.urlDecode(uri)) : null;
		}
		var i = 0;
		for (b in list(root, "buffers")) {
			var length = int(b, "byteLength", -1);
			if (length < 0) throw 'glTF: buffer $i: no byteLength';
			var uri = str(b, "uri", null);
			var data = if (uri == null) {
				if (i != 0 || bin == null) throw 'glTF: buffer $i: no uri and no BIN chunk';
				bin;
			} else uriBytes(uri, 'buffer $i');
			if (data == null) throw 'glTF: buffer $i: $uri not found';
			if (data.length < length) throw 'glTF: buffer $i: ${data.length} bytes, not $length';
			doc.buffers.push(data);
			i++;
		}
		i = 0;
		for (v in list(root, "bufferViews")) {
			var view:GltfBufferView = {
				buffer: index(v, "buffer", doc.buffers.length, 'bufferView $i', false),
				byteOffset: int(v, "byteOffset", 0),
				byteLength: int(v, "byteLength", -1),
				byteStride: int(v, "byteStride", 0)
			};
			if (view.byteLength < 0 || view.byteOffset < 0 || view.byteOffset + view.byteLength > doc.buffers[view.buffer].length)
				throw 'glTF: bufferView $i: out of its buffer';
			if (view.byteStride != 0 && (view.byteStride < 4 || view.byteStride > 252)) throw 'glTF: bufferView $i: byteStride ${view.byteStride}';
			doc.bufferViews.push(view);
			i++;
		}
		i = 0;
		for (a in list(root, "accessors")) {
			var type = str(a, "type", "");
			var components = switch type {
				case "SCALAR": 1;
				case "VEC2": 2;
				case "VEC3": 3;
				case "VEC4": 4;
				case "MAT2": 4;
				case "MAT3": 9;
				case "MAT4": 16;
				case t: throw 'glTF: accessor $i: type $t';
			}
			var acc:GltfAccessor = {
				bufferView: index(a, "bufferView", doc.bufferViews.length, 'accessor $i', true),
				byteOffset: int(a, "byteOffset", 0),
				componentType: int(a, "componentType", 0),
				normalized: Reflect.field(a, "normalized") == true,
				count: int(a, "count", -1),
				components: components,
				min: floats(a, "min"),
				max: floats(a, "max")
			};
			if (acc.count < 1) throw 'glTF: accessor $i: count ${acc.count}';
			if (obj(a, "sparse") != null) throw 'glTF: accessor $i: sparse accessors are not read yet';
			var size = GltfDoc.componentSize(acc.componentType);
			if (acc.bufferView >= 0) {
				var v = doc.bufferViews[acc.bufferView];
				var stride = v.byteStride > 0 ? v.byteStride : size * components;
				if (acc.byteOffset < 0 || acc.byteOffset % size != 0 || acc.byteOffset + (acc.count - 1) * stride + size * components > v.byteLength)
					throw 'glTF: accessor $i: out of its bufferView';
			}
			doc.accessors.push(acc);
			i++;
		}
		i = 0;
		for (im in list(root, "images")) {
			var uri = str(im, "uri", null);
			var view = index(im, "bufferView", doc.bufferViews.length, 'image $i', true);
			if (uri == null && view < 0) throw 'glTF: image $i: no uri and no bufferView';
			doc.images.push({
				name: str(im, "name", ""),
				mimeType: str(im, "mimeType", ""),
				bufferView: view,
				uri: uri != null ? uri : "",
				data: uri != null ? uriBytes(uri, 'image $i') : null
			});
			i++;
		}
		i = 0;
		for (s in list(root, "samplers"))
			doc.samplers.push({
				magFilter: int(s, "magFilter", 0),
				minFilter: int(s, "minFilter", 0),
				wrapS: int(s, "wrapS", 10497),
				wrapT: int(s, "wrapT", 10497)
			});
		i = 0;
		for (t in list(root, "textures")) {
			doc.textures.push({
				sampler: index(t, "sampler", doc.samplers.length, 'texture $i', true),
				source: index(t, "source", doc.images.length, 'texture $i', true)
			});
			i++;
		}
		i = 0;
		for (m in list(root, "materials")) {
			var pbr = obj(m, "pbrMetallicRoughness");
			var what = 'material $i';
			function tex(o:Dynamic, f:String):Int {
				var t = o != null ? obj(o, f) : null;
				return t == null ? -1 : index(t, "index", doc.textures.length, what, false);
			}
			var bc = floats(pbr, "baseColorFactor"), em = floats(m, "emissiveFactor");
			doc.materials.push({
				name: str(m, "name", ""),
				baseColor: bc != null && bc.length == 4 ? new Vec4(bc[0], bc[1], bc[2], bc[3]) : new Vec4(1, 1, 1, 1),
				metallic: num(pbr, "metallicFactor", 1),
				roughness: num(pbr, "roughnessFactor", 1),
				emissive: em != null && em.length == 3 ? new Vec3(em[0], em[1], em[2]) : new Vec3(0, 0, 0),
				baseColorTexture: tex(pbr, "baseColorTexture"),
				metallicRoughnessTexture: tex(pbr, "metallicRoughnessTexture"),
				normalTexture: tex(m, "normalTexture"),
				normalScale: num(obj(m, "normalTexture"), "scale", 1),
				occlusionTexture: tex(m, "occlusionTexture"),
				emissiveTexture: tex(m, "emissiveTexture"),
				alphaMode: str(m, "alphaMode", "OPAQUE"),
				alphaCutoff: num(m, "alphaCutoff", 0.5),
				doubleSided: Reflect.field(m, "doubleSided") == true
			});
			i++;
		}
		i = 0;
		for (m in list(root, "meshes")) {
			var prims = [];
			var what = 'mesh $i';
			for (p in list(m, "primitives")) {
				var at = obj(p, "attributes");
				if (at == null) throw 'glTF: $what: a primitive without attributes';
				var n = doc.accessors.length;
				var prim:GltfPrimitive = {
					position: index(at, "POSITION", n, what, true),
					normal: index(at, "NORMAL", n, what, true),
					texcoord: index(at, "TEXCOORD_0", n, what, true),
					tangent: index(at, "TANGENT", n, what, true),
					color: index(at, "COLOR_0", n, what, true),
					joints: index(at, "JOINTS_0", n, what, true),
					weights: index(at, "WEIGHTS_0", n, what, true),
					indices: index(p, "indices", n, what, true),
					material: index(p, "material", doc.materials.length, what, true),
					mode: int(p, "mode", 4),
					targets: [
						for (t in list(p, "targets"))
							{position: index(t, "POSITION", n, what, true), normal: index(t, "NORMAL", n, what, true)}
					]
				};
				for (t in prim.targets)
					for (k in [t.position, t.normal])
						if (k >= 0 && (prim.position < 0 || doc.accessors[k].count != doc.accessors[prim.position].count || doc.accessors[k].components != 3))
							throw 'glTF: $what: a morph target not of VEC3s, one per vertex';
				if (prim.position >= 0 && doc.accessors[prim.position].components != 3) throw 'glTF: $what: POSITION not VEC3';
				if (prim.normal >= 0 && doc.accessors[prim.normal].count != doc.accessors[prim.position].count) throw 'glTF: $what: NORMAL count';
				if ((prim.joints >= 0) != (prim.weights >= 0)) throw 'glTF: $what: JOINTS_0 without WEIGHTS_0, or the reverse';
				if (prim.joints >= 0 && (doc.accessors[prim.joints].components != 4 || doc.accessors[prim.weights].components != 4
					|| doc.accessors[prim.joints].count != doc.accessors[prim.position].count || doc.accessors[prim.weights].count != doc.accessors[prim.position].count))
					throw 'glTF: $what: JOINTS_0 and WEIGHTS_0 must be VEC4s, one per vertex';
				if (prim.indices >= 0) {
					var count = prim.position >= 0 ? doc.accessors[prim.position].count : 0;
					for (k in doc.indices(prim.indices))
						if (k < 0 || k >= count) throw 'glTF: $what: index $k out of its vertices';
				}
				prims.push(prim);
			}
			var targets = prims.length > 0 ? prims[0].targets.length : 0;
			for (p in prims)
				if (p.targets.length != targets) throw 'glTF: $what: primitives with different numbers of morph targets';
			var w = floats(m, "weights");
			doc.meshes.push({name: str(m, "name", ""), primitives: prims, weights: w != null && w.length == targets ? w : [for (_ in 0...targets) 0.0]});
			i++;
		}
		i = 0;
		for (c in list(root, "cameras")) {
			var type = str(c, "type", "");
			var p = obj(c, "perspective"), o = obj(c, "orthographic");
			if (type == "perspective" && p == null || type == "orthographic" && o == null || type != "perspective" && type != "orthographic")
				throw 'glTF: camera $i: type $type';
			doc.cameras.push({
				name: str(c, "name", ""),
				perspective: type == "perspective",
				yfov: num(p, "yfov", 0.8),
				aspect: num(p, "aspectRatio", 0),
				znear: num(p != null ? p : o, "znear", 0.1),
				zfar: num(p != null ? p : o, "zfar", 0),
				xmag: num(o, "xmag", 1),
				ymag: num(o, "ymag", 1)
			});
			i++;
		}
		// (KHR_lights_punctual: lights at the root, a node's light by index)
		var punctual = obj(obj(root, "extensions"), "KHR_lights_punctual");
		i = 0;
		for (l in list(punctual, "lights")) {
			var type = str(l, "type", "");
			if (type != "directional" && type != "point" && type != "spot") throw 'glTF: light $i: type $type';
			var c = floats(l, "color");
			doc.lights.push({
				name: str(l, "name", ""),
				type: type,
				color: c != null && c.length == 3 ? new Vec3(c[0], c[1], c[2]) : new Vec3(1, 1, 1),
				intensity: num(l, "intensity", 1),
				range: num(l, "range", 0),
				innerCone: num(obj(l, "spot"), "innerConeAngle", 0),
				outerCone: num(obj(l, "spot"), "outerConeAngle", Math.PI / 4)
			});
			i++;
		}
		var nodes = list(root, "nodes");
		i = 0;
		for (n in nodes) {
			var what = 'node $i';
			var t = floats(n, "translation"), r = floats(n, "rotation"), s = floats(n, "scale"), m = floats(n, "matrix");
			if (m != null && m.length != 16) throw 'glTF: $what: a matrix of ${m.length} values';
			var children = [for (c in list(n, "children")) checked(c, nodes.length, what)];
			doc.nodes.push({
				name: str(n, "name", ""),
				children: children,
				mesh: index(n, "mesh", doc.meshes.length, what, true),
				camera: index(n, "camera", doc.cameras.length, what, true),
				light: index(obj(obj(n, "extensions"), "KHR_lights_punctual"), "light", doc.lights.length, what, true),
				skin: -1,
				translation: t != null && t.length == 3 ? new Vec3(t[0], t[1], t[2]) : new Vec3(0, 0, 0),
				rotation: r != null && r.length == 4 ? new Quat(r[0], r[1], r[2], r[3]) : Quat.identity(),
				scale: s != null && s.length == 3 ? new Vec3(s[0], s[1], s[2]) : new Vec3(1, 1, 1),
				matrix: m,
				weights: floats(n, "weights")
			});
			i++;
		}
		i = 0;
		for (sk in list(root, "skins")) {
			var what = 'skin $i';
			var joints = [for (j in list(sk, "joints")) checked(j, doc.nodes.length, what)];
			if (joints.length == 0) throw 'glTF: $what: no joints';
			var ibm = index(sk, "inverseBindMatrices", doc.accessors.length, what, true);
			if (ibm >= 0 && (doc.accessors[ibm].components != 16 || doc.accessors[ibm].count < joints.length)) throw 'glTF: $what: inverseBindMatrices';
			doc.skins.push({name: str(sk, "name", ""), joints: joints, inverseBindMatrices: ibm});
			i++;
		}
		for (k in 0...nodes.length) {
			doc.nodes[k].skin = index(nodes[k], "skin", doc.skins.length, 'node $k', true);
			if (doc.nodes[k].skin >= 0 && doc.nodes[k].mesh < 0) throw 'glTF: node $k: a skin without a mesh';
		}
		// (a node has one parent at most, and no node is its own ancestor)
		var parent = [for (_ in 0...doc.nodes.length) -1];
		for (k in 0...doc.nodes.length)
			for (c in doc.nodes[k].children) {
				if (parent[c] >= 0) throw 'glTF: node $c: two parents';
				parent[c] = k;
			}
		for (k in 0...doc.nodes.length) {
			var p = parent[k], steps = 0;
			while (p >= 0) {
				if (p == k || ++steps > doc.nodes.length) throw 'glTF: node $k: a cycle';
				p = parent[p];
			}
		}
		i = 0;
		for (an in list(root, "animations")) {
			var what = 'animation $i';
			var samplers = list(an, "samplers");
			var channels:Array<GltfChannel> = [];
			for (c in list(an, "channels")) {
				var sm = samplers[index(c, "sampler", samplers.length, what, false)];
				var target = obj(c, "target");
				var path = str(target, "path", "");
				if (path != "translation" && path != "rotation" && path != "scale" && path != "weights") throw 'glTF: $what: path $path';
				var node = index(target, "node", doc.nodes.length, what, true);
				var input = index(sm, "input", doc.accessors.length, what, false), output = index(sm, "output", doc.accessors.length, what, false);
				var interpolation = str(sm, "interpolation", "LINEAR");
				if (interpolation != "LINEAR" && interpolation != "STEP" && interpolation != "CUBICSPLINE") throw 'glTF: $what: interpolation $interpolation';
				// (the values: one per time, three for a cubic spline: in-tangent, value, out-tangent)
				var per = path == "rotation" ? 4 : path == "weights" ? 0 : 3;
				var n = doc.accessors[input].count * (interpolation == "CUBICSPLINE" ? 3 : 1);
				if (per > 0 && (doc.accessors[output].count != n || doc.accessors[output].components != per)) throw 'glTF: $what: output of $path does not match its input';
				if (node >= 0) channels.push({node: node, path: path, input: input, output: output, interpolation: interpolation});
			}
			doc.animations.push({name: str(an, "name", ""), channels: channels});
			i++;
		}
		i = 0;
		for (s in list(root, "scenes")) {
			var ns = [for (n in list(s, "nodes")) checked(n, doc.nodes.length, 'scene $i')];
			for (n in ns)
				if (parent[n] >= 0) throw 'glTF: scene $i: node $n is not a root';
			doc.scenes.push({name: str(s, "name", ""), nodes: ns});
			i++;
		}
		doc.scene = index(root, "scene", doc.scenes.length, "the document", true);
		return doc;
	}

	// (the JSON's values, read with their defaults)

	static function obj(o:Dynamic, f:String):Dynamic {
		if (o == null) return null;
		var v:Dynamic = Reflect.field(o, f);
		return Reflect.isObject(v) && !Std.isOfType(v, String) && !Std.isOfType(v, Array) ? v : null;
	}

	static function list(o:Dynamic, f:String):Array<Dynamic> {
		var v:Dynamic = o == null ? null : Reflect.field(o, f);
		return Std.isOfType(v, Array) ? (v : Array<Dynamic>) : [];
	}

	static function str(o:Dynamic, f:String, def:String):String {
		var v:Dynamic = o == null ? null : Reflect.field(o, f);
		return Std.isOfType(v, String) ? (v : String) : def;
	}

	static function num(o:Dynamic, f:String, def:Float):Float {
		var v:Dynamic = o == null ? null : Reflect.field(o, f);
		return Std.isOfType(v, Float) || Std.isOfType(v, Int) ? (v : Float) : def;
	}

	static function int(o:Dynamic, f:String, def:Int):Int {
		var v:Dynamic = o == null ? null : Reflect.field(o, f);
		if (Std.isOfType(v, Int)) return (v : Int);
		if (Std.isOfType(v, Float)) {
			var x:Float = v;
			if (x == Math.ffloor(x) && Math.abs(x) < 2147483648.0) return Std.int(x);
		}
		return def;
	}

	static function floats(o:Dynamic, f:String):Null<Array<Float>> {
		var v:Dynamic = o == null ? null : Reflect.field(o, f);
		if (!Std.isOfType(v, Array)) return null;
		return [for (x in (v : Array<Dynamic>)) Std.isOfType(x, Float) || Std.isOfType(x, Int) ? (x : Float) : throw 'glTF: $f: not a number'];
	}

	// an index into a list of n, -1 when absent and optional
	static function index(o:Dynamic, f:String, n:Int, what:String, optional:Bool):Int {
		var v:Dynamic = o == null ? null : Reflect.field(o, f);
		if (v == null) {
			if (optional) return -1;
			throw 'glTF: $what: no $f';
		}
		var k = int(o, f, -1);
		if (k < 0 || k >= n) throw 'glTF: $what: $f $k out of range';
		return k;
	}

	static function checked(v:Dynamic, n:Int, what:String):Int {
		var k = Std.isOfType(v, Int) ? (v : Int) : -1;
		if (k < 0 || k >= n) throw 'glTF: $what: node $v out of range';
		return k;
	}
}
