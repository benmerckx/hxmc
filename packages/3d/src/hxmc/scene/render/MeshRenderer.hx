package hxmc.scene.render;

import hxmc.scene.Node;
import hxmc.scene.World;

// The mesh a node draws: a component (a store keyed by node), several
// nodes may share one Mesh.
class MeshRenderer {
	public static final KIND = new StoreKind<Mesh>("mesh");

	public static inline function attach(node:Node, mesh:Mesh):Mesh
		return node.world.store(KIND).set(node, mesh);

	public static inline function of(node:Node):Null<Mesh>
		return node.world.store(KIND).get(node);

	public static inline function detach(node:Node)
		node.world.store(KIND).remove(node);
}
