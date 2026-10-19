package hxmc.scene.gltf;

import hxmc.gfx.shader.Mat4;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.Camera;
import hxmc.scene.Node;
import hxmc.scene.World;

// A glTF document's node hierarchy as nodes of a world: a Node per glTF
// node (its TRS, or its matrix decomposed), named as in the file, under
// one new node (under parent, by default the world's root); cameras made
// from the document's; what a node's mesh becomes is the caller's
// (mesh(node, index): attach the renderer's own mesh, made once per glTF
// mesh; light(node, index) the same for KHR_lights_punctual's lights), so
// the hierarchy needs no renderer. made, when given, gets each glTF
// node's Node at its index (for animations). Each call instantiates the
// document again (a prefab).
class GltfNodes {
	public static function build(doc:GltfDoc, world:World, ?parent:Node, ?scene:Int, ?mesh:(Node, Int) -> Void, ?light:(Node, Int) -> Void, ?made:Array<Node>):Node {
		var s = scene != null ? scene : doc.scene;
		var top = world.node(s >= 0 && s < doc.scenes.length ? doc.scenes[s].name : "gltf", parent);
		function make(k:Int, under:Node) {
			var g = doc.nodes[k];
			var n = world.node(g.name, under);
			if (made != null) made[k] = n;
			if (g.matrix != null) {
				var m = g.matrix;
				n.setMatrix(new Mat4(new Vec4(m[0], m[1], m[2], m[3]), new Vec4(m[4], m[5], m[6], m[7]), new Vec4(m[8], m[9], m[10], m[11]),
					new Vec4(m[12], m[13], m[14], m[15])));
			} else {
				n.position = g.translation;
				n.rotation = g.rotation;
				n.scale = g.scale;
			}
			if (g.mesh >= 0 && mesh != null) mesh(n, g.mesh);
			if (g.light >= 0 && light != null) light(n, g.light);
			if (g.camera >= 0) {
				var c = doc.cameras[g.camera];
				Camera.attach(n, c.perspective ? Camera.perspective(c.yfov, c.znear, c.zfar > 0 ? c.zfar : 1000) : Camera.orthographic(2 * c.ymag,
					c.znear, c.zfar));
			}
			for (c in g.children)
				make(c, n);
		}
		for (k in doc.roots(scene != null ? scene : -1))
			make(k, top);
		return top;
	}
}
