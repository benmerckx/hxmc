package hxmc.scene.render;

import haxe.io.Bytes;
import hxmc.gfx.Buffer;
import hxmc.gfx.Device;
import hxmc.gfx.IndexFormat;
import hxmc.scene.math.Aabb;

// What a node draws (node.mesh): primitives, each a vertex buffer in the
// renderer's layout (PbrVertex: position, normal, uv; 32 bytes a vertex),
// triangles' indices and a material, and the bounds of them all.
class Mesh {
	public var primitives(default, null):Array<Primitive> = [];
	public var bounds(default, null):Aabb = Aabb.empty();

	public function new() {}

	// a primitive from positions, normals and uvs (x, y, z / u, v per
	// vertex; normals null: computed from the triangles, smooth where
	// vertices are shared) and triangles' indices (null: 0, 1, 2, ...)
	public function add(device:Device, positions:Array<Float>, normals:Null<Array<Float>>, uvs:Null<Array<Float>>, indices:Null<Array<Int>>,
			material:Material, ?joints:Array<Float>, ?weights:Array<Float>, ?tangents:Array<Float>):Primitive {
		return addData(device, VertexData.make(positions, normals, uvs, indices, joints, weights, tangents), material);
	}

	// a primitive from data in the renderer's layout (VertexData: made here, or packed at build time)
	public function addData(device:Device, d:VertexData, material:Material):Primitive {
		var prim = new Primitive(device.createBuffer({size: d.vertices.length, usage: Vertex, data: d.vertices}),
			device.createBuffer({size: d.indices.length, usage: Index, data: d.indices}), d.wide ? UInt32 : UInt16, d.count, material, d.bounds, d.skinned);
		if (d.tangents != null) prim.tangents = device.createBuffer({size: d.tangents.length, usage: Vertex, data: d.tangents});
		primitives.push(prim);
		bounds = bounds.union(prim.bounds);
		return prim;
	}

	// a primitive made elsewhere (a morph's copy, sharing the original's indices)
	public function addPrimitive(p:Primitive):Primitive {
		primitives.push(p);
		bounds = bounds.union(p.bounds);
		return p;
	}

	public function dispose(device:Device) {
		for (p in primitives) {
			device.destroyBuffer(p.vertices);
			device.destroyBuffer(p.indices);
			if (p.tangents != null) device.destroyBuffer(p.tangents);
		}
		primitives = [];
	}

	public static inline function smoothNormals(positions:Array<Float>, indices:Array<Int>):Array<Float>
		return VertexData.smoothNormals(positions, indices);
}

class Primitive {
	static var made = 0;

	// (draws of one primitive are batched by it)
	public final id:Int = made++;

	public final vertices:Buffer;
	public final indices:Buffer;
	public final indexFormat:IndexFormat;
	public final count:Int;
	public var material:Material;
	public final bounds:Aabb;
	// its vertices carry joints and weights (drawn with a Skin)
	public final skinned:Bool;
	// its vertices' tangents (VertexData.tangents), for normal maps; null: none
	public var tangents:Null<Buffer>;

	public function new(vertices:Buffer, indices:Buffer, indexFormat:IndexFormat, count:Int, material:Material, bounds:Aabb, skinned = false) {
		this.skinned = skinned;
		this.vertices = vertices;
		this.indices = indices;
		this.indexFormat = indexFormat;
		this.count = count;
		this.material = material;
		this.bounds = bounds;
	}
}
