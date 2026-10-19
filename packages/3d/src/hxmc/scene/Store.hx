package hxmc.scene;

// The components of one kind in a world: at most one per node, by slot
class Store<T> extends StoreBase {
	final world:World;
	final values:Array<Null<T>> = [];
	final nodes:Array<Node> = [];
	// (the slots holding a value, in the order they were set)
	final slots:Array<Int> = [];

	@:allow(hxmc.scene) function new(world:World) {
		this.world = world;
	}

	public function get(n:Node):Null<T> {
		var s = world.slotOf(n);
		return s < values.length ? values[s] : null;
	}

	public function set(n:Node, v:T):T {
		var s = world.slotOf(n);
		while (values.length <= s) {
			values.push(null);
			nodes.push(Node.NONE);
		}
		if (values[s] == null) slots.push(s);
		values[s] = v;
		nodes[s] = n;
		return v;
	}

	public function remove(n:Node)
		removeSlot(world.slotOf(n));

	override function removeSlot(s:Int) {
		if (s >= values.length || values[s] == null) return;
		values[s] = null;
		nodes[s] = Node.NONE;
		slots.remove(s);
	}

	public var length(get, never):Int;

	inline function get_length():Int
		return slots.length;

	// the k-th node holding a value (0 <= k < length) and its value
	public inline function nodeAt(k:Int):Node
		return nodes[slots[k]];

	public inline function valueAt(k:Int):T
		return values[slots[k]];
}
