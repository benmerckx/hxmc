package hxmc.scene.render;

import haxe.io.Bytes;
import hxmc.gfx.*;
import hxmc.gfx.shader.Mat4;
import hxmc.scene.Node;
import hxmc.scene.World;
import hxmc.scene.math.MathTools;

// A skin, a component of the node whose mesh it deforms: its joints (nodes,
// animated like any: Animator) and their inverse bind matrices. Each frame
// the renderer computes the joint matrices (the mesh node's world matrix
// inverted, times the joint's world matrix, times its inverse bind matrix:
// glTF's) into an R32F texture of 16 columns, a row per joint, which the
// skinned shader reads (four joints a vertex, weighted).
class Skin {
	public static final KIND = new StoreKind<Skin>("skin");

	public final joints:Array<Node>;
	// 16 floats a joint, column by column
	public final inverseBind:Array<Float>;
	public final texture:Texture;

	final bytes:Bytes;
	final device:Device;

	public function new(device:Device, joints:Array<Node>, inverseBind:Array<Float>) {
		this.device = device;
		this.joints = joints;
		this.inverseBind = inverseBind;
		bytes = Bytes.alloc(16 * 4 * joints.length);
		texture = device.createTexture({width: 16, height: joints.length, format: R32F, data: bytes});
	}

	public static inline function attach(node:Node, skin:Skin):Skin
		return node.world.store(KIND).set(node, skin);

	public static inline function of(node:Node):Null<Skin>
		return node.world.store(KIND).get(node);

	// the joint matrices for the mesh on node, written to the texture
	public function update(node:Node) {
		var toMesh = MathTools.inverse(node.worldMatrix());
		for (j in 0...joints.length) {
			var b = 16 * j, ib = inverseBind;
			var bind = new Mat4(new hxmc.gfx.shader.Vec4(ib[b], ib[b + 1], ib[b + 2], ib[b + 3]),
				new hxmc.gfx.shader.Vec4(ib[b + 4], ib[b + 5], ib[b + 6], ib[b + 7]),
				new hxmc.gfx.shader.Vec4(ib[b + 8], ib[b + 9], ib[b + 10], ib[b + 11]),
				new hxmc.gfx.shader.Vec4(ib[b + 12], ib[b + 13], ib[b + 14], ib[b + 15]));
			var m = joints[j].valid ? toMesh * joints[j].worldMatrix() * bind : Mat4.identity();
			for (c in 0...4) {
				var col = MathTools.col(m, c);
				bytes.setFloat(4 * (b + 4 * c), col.x);
				bytes.setFloat(4 * (b + 4 * c + 1), col.y);
				bytes.setFloat(4 * (b + 4 * c + 2), col.z);
				bytes.setFloat(4 * (b + 4 * c + 3), col.w);
			}
		}
		device.writeTexture(texture, bytes);
	}

	public function dispose()
		device.destroyTexture(texture);
}
