package hxmc.scene.anim;

import hxmc.scene.Node;
import hxmc.scene.StoreKind;

// A node's morph target weights (one per target of its mesh): set by a
// program or played by an Animator's weights tracks; the renderer's Morph
// bends the node's vertices by them.
class MorphWeights {
	public static final KIND = new StoreKind<MorphWeights>("morphWeights");

	public final weights:Array<Float>;

	public function new(weights:Array<Float>)
		this.weights = weights.copy();

	public static inline function attach(node:Node, w:MorphWeights):MorphWeights
		return node.world.store(KIND).set(node, w);

	public static inline function of(node:Node):Null<MorphWeights>
		return node.world.store(KIND).get(node);
}
