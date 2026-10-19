package hxmc.scene.gltf;

import haxe.io.Bytes;
import hxmc.gfx.shader.Mat4;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.math.Quat;

// A glTF 2.0 document as typed data (Gltf.parse): what the JSON says, its
// indices checked, -1 for "none", the buffers' bytes loaded. Accessors are
// read through floats and indices, which handle every component type,
// normalized integers and strides.
class GltfDoc {
	public var buffers:Array<Bytes> = [];
	public var bufferViews:Array<GltfBufferView> = [];
	public var accessors:Array<GltfAccessor> = [];
	public var meshes:Array<GltfMesh> = [];
	public var materials:Array<GltfMaterial> = [];
	public var textures:Array<GltfTexture> = [];
	public var images:Array<GltfImage> = [];
	public var samplers:Array<GltfSampler> = [];
	public var cameras:Array<GltfCamera> = [];
	public var nodes:Array<GltfNode> = [];
	public var scenes:Array<GltfSceneDef> = [];
	// KHR_lights_punctual's lights
	public var lights:Array<GltfLight> = [];
	public var animations:Array<GltfAnimation> = [];
	public var skins:Array<GltfSkin> = [];
	// the default scene (-1: none named; the first, if any)
	public var scene = -1;
	public var generator = "";

	public function new() {}

	// an accessor's elements as floats, components in order (count *
	// components values): normalized integers mapped to 0..1 or -1..1,
	// others as they are
	public function floats(accessor:Int):Array<Float> {
		var a = accessors[accessor];
		var out = [];
		var n = a.count * a.components;
		out.resize(n);
		if (a.bufferView < 0) {
			for (i in 0...n)
				out[i] = 0.0;
			return out;
		}
		var v = bufferViews[a.bufferView], b = buffers[v.buffer];
		var size = componentSize(a.componentType), stride = v.byteStride > 0 ? v.byteStride : size * a.components;
		var base = v.byteOffset + a.byteOffset;
		for (e in 0...a.count)
			for (c in 0...a.components) {
				var p = base + e * stride + c * size;
				out[e * a.components + c] = switch a.componentType {
					case 5126: b.getFloat(p); // FLOAT
					case 5121: a.normalized ? b.get(p) / 255 : b.get(p);
					case 5120:
						var x = b.get(p);
						if (x > 127) x -= 256;
						a.normalized ? Math.max(x / 127, -1.0) : x;
					case 5123: a.normalized ? b.getUInt16(p) / 65535 : b.getUInt16(p);
					case 5122:
						var x = b.getUInt16(p);
						if (x > 32767) x -= 65536;
						a.normalized ? Math.max(x / 32767, -1.0) : x;
					case 5125: (b.getInt32(p) : Float) + (b.getInt32(p) < 0 ? 4294967296.0 : 0);
					case t: throw 'glTF: accessor $accessor: component type $t';
				}
			}
		return out;
	}

	// an accessor of integers (indices): its elements
	public function indices(accessor:Int):Array<Int> {
		var a = accessors[accessor];
		if (a.components != 1) throw 'glTF: accessor $accessor: indices of ${a.components} components';
		var out = [];
		out.resize(a.count);
		if (a.bufferView < 0) {
			for (i in 0...a.count)
				out[i] = 0;
			return out;
		}
		var v = bufferViews[a.bufferView], b = buffers[v.buffer];
		var size = componentSize(a.componentType), stride = v.byteStride > 0 ? v.byteStride : size;
		var base = v.byteOffset + a.byteOffset;
		for (e in 0...a.count) {
			var p = base + e * stride;
			out[e] = switch a.componentType {
				case 5121: b.get(p);
				case 5123: b.getUInt16(p);
				case 5125: b.getInt32(p);
				case t: throw 'glTF: accessor $accessor: indices of component type $t';
			}
		}
		return out;
	}

	// an image's bytes: from its buffer view, or its URI (resolved when parsed)
	public function imageBytes(image:Int):Null<Bytes> {
		var im = images[image];
		if (im.bufferView >= 0) {
			var v = bufferViews[im.bufferView];
			return buffers[v.buffer].sub(v.byteOffset, v.byteLength);
		}
		return im.data;
	}

	// the nodes of a scene (the default one by default) that have no parent
	public function roots(scene = -1):Array<Int> {
		var s = scene >= 0 ? scene : this.scene >= 0 ? this.scene : 0;
		if (s < scenes.length) return scenes[s].nodes;
		// (no scenes: every node that is nobody's child)
		var child = [for (n in nodes) for (c in n.children) c => true];
		return [for (i in 0...nodes.length) if (!child.exists(i)) i];
	}

	public static inline var BYTE = 5120;
	public static inline var UNSIGNED_BYTE = 5121;
	public static inline var SHORT = 5122;
	public static inline var UNSIGNED_SHORT = 5123;
	public static inline var UNSIGNED_INT = 5125;
	public static inline var FLOAT = 5126;

	public static function componentSize(t:Int):Int
		return switch t {
			case 5120 | 5121: 1;
			case 5122 | 5123: 2;
			case 5125 | 5126: 4;
			case _: throw 'glTF: component type $t';
		}
}

@:structInit class GltfBufferView {
	public var buffer:Int;
	public var byteOffset:Int;
	public var byteLength:Int;
	public var byteStride:Int; // 0: tightly packed
}

@:structInit class GltfAccessor {
	public var bufferView:Int; // -1: all zeros
	public var byteOffset:Int;
	public var componentType:Int;
	public var normalized:Bool;
	public var count:Int;
	public var components:Int; // SCALAR 1, VEC2 2, VEC3 3, VEC4 4, MAT4 16
	public var min:Null<Array<Float>>;
	public var max:Null<Array<Float>>;
}

@:structInit class GltfMesh {
	public var name:String;
	public var primitives:Array<GltfPrimitive>;
	// the morph targets' default weights (none: no targets)
	public var weights:Array<Float>;
}

@:structInit class GltfPrimitive {
	// the attributes' accessors (-1: absent)
	public var position:Int;
	public var normal:Int;
	public var texcoord:Int;
	public var tangent:Int;
	public var color:Int;
	public var joints:Int; // JOINTS_0, WEIGHTS_0: skinning (-1: none)
	public var weights:Int;
	public var indices:Int; // -1: not indexed
	public var material:Int; // -1: the default material
	public var mode:Int; // 4: triangles
	// morph targets: each one's position and normal displacements' accessors (-1: none)
	public var targets:Array<GltfTarget>;
}

@:structInit class GltfTarget {
	public var position:Int;
	public var normal:Int;
}

@:structInit class GltfMaterial {
	public var name:String;
	public var baseColor:Vec4;
	public var metallic:Float;
	public var roughness:Float;
	public var emissive:Vec3;
	public var baseColorTexture:Int; // textures' indices, -1: none
	public var metallicRoughnessTexture:Int;
	public var normalTexture:Int;
	public var normalScale:Float; // the normal map's x and y scale
	public var occlusionTexture:Int;
	public var emissiveTexture:Int;
	public var alphaMode:String; // OPAQUE, MASK, BLEND
	public var alphaCutoff:Float;
	public var doubleSided:Bool;
}

@:structInit class GltfTexture {
	public var sampler:Int;
	public var source:Int;
}

@:structInit class GltfImage {
	public var name:String;
	public var mimeType:String;
	public var bufferView:Int;
	public var uri:String;
	// (the bytes of a URI, resolved when parsed; null when not resolved)
	public var data:Null<Bytes>;
}

@:structInit class GltfSampler {
	public var magFilter:Int;
	public var minFilter:Int;
	public var wrapS:Int;
	public var wrapT:Int;
}

@:structInit class GltfCamera {
	public var name:String;
	public var perspective:Bool;
	public var yfov:Float;
	public var aspect:Float; // 0: the view's
	public var znear:Float;
	public var zfar:Float; // perspective: infinite when 0
	public var xmag:Float;
	public var ymag:Float;
}

@:structInit class GltfNode {
	public var name:String;
	public var children:Array<Int>;
	public var mesh:Int;
	public var camera:Int;
	public var light:Int; // KHR_lights_punctual, -1: none
	public var skin:Int; // -1: none
	public var translation:Vec3;
	public var rotation:Quat;
	public var scale:Vec3;
	public var matrix:Null<Array<Float>>; // 16 values, column by column: instead of translation, rotation and scale
	public var weights:Null<Array<Float>>; // its mesh's morph weights, instead of the mesh's
}

@:structInit class GltfLight {
	public var name:String;
	public var type:String; // directional, point, spot
	public var color:Vec3;
	public var intensity:Float;
	public var range:Float; // 0: infinite
	public var innerCone:Float; // spot: radians
	public var outerCone:Float;
}

@:structInit class GltfSkin {
	public var name:String;
	public var joints:Array<Int>; // nodes
	public var inverseBindMatrices:Int; // an accessor of MAT4s, -1: identities
}

@:structInit class GltfAnimation {
	public var name:String;
	public var channels:Array<GltfChannel>;
}

@:structInit class GltfChannel {
	public var node:Int;
	public var path:String; // translation, rotation, scale, weights
	public var input:Int; // the times' accessor (seconds)
	public var output:Int; // the values' accessor
	public var interpolation:String; // LINEAR, STEP, CUBICSPLINE
}

@:structInit class GltfSceneDef {
	public var name:String;
	public var nodes:Array<Int>;
}
