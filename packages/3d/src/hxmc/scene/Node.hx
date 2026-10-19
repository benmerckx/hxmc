package hxmc.scene;

import hxmc.gfx.shader.Mat4;
import hxmc.gfx.shader.Vec3;
import hxmc.scene.math.Quat;

// A node of a World's scene graph: a handle, an Int (the world, a
// generation and a slot: World), so nodes cost no object each and a
// renderer reads the world's flat arrays. The accessors are inline calls
// into the world's storage:
//
//   var arm = world.node("arm");          // under the world's root
//   arm.position = new Vec3(2, 0, 0);     // (Vec3 and Quat are immutable values)
//   arm.rotation = Quat.axisAngle(new Vec3(0, 0, 1), Math.PI / 2);
//   var hand = arm.add(world.node("hand"));
//   hand.worldMatrix();                    // cached until a transform above changes
//
// A disposed node's handle is stale: valid is false and every other access
// throws (its slot's generation moved on).
abstract Node(Int) {
	public static inline var NONE:Node = cast 0;

	@:allow(hxmc.scene.World) inline function new(id:Int)
		this = id;

	public inline function id():Int
		return this;

	public var world(get, never):World;

	inline function get_world():World
		return World.all[this >>> World.WORLD_SHIFT];

	@:allow(hxmc.scene) var slot(get, never):Int;

	inline function get_slot():Int
		return world.slotOf(cast this);

	public var isNone(get, never):Bool;

	inline function get_isNone():Bool
		return this == 0;

	public var valid(get, never):Bool;

	inline function get_valid():Bool
		return this != 0 && world.isValid(cast this);

	public var name(get, set):String;

	inline function get_name():String
		return world.names[slot];

	inline function set_name(v:String):String
		return world.names[slot] = v;

	public var position(get, set):Vec3;

	inline function get_position():Vec3
		return world.getPosition(slot);

	inline function set_position(v:Vec3):Vec3 {
		world.setPosition(slot, v);
		return v;
	}

	public var rotation(get, set):Quat;

	inline function get_rotation():Quat
		return world.getRotation(slot);

	inline function set_rotation(v:Quat):Quat {
		world.setRotation(slot, v);
		return v;
	}

	public var scale(get, set):Vec3;

	inline function get_scale():Vec3
		return world.getScale(slot);

	inline function set_scale(v:Vec3):Vec3 {
		world.setScale(slot, v);
		return v;
	}

	// hidden: neither it nor what is below it is drawn
	public var visible(get, set):Bool;

	inline function get_visible():Bool
		return world.visible[slot];

	inline function set_visible(v:Bool):Bool
		return world.visible[slot] = v;

	// NONE for the root (and a node taken out of the tree)
	public var parent(get, never):Node;

	inline function get_parent():Node
		return world.parentOf(slot);

	public inline function add(child:Node):Node
		return world.attach(cast this, child);

	// out of its parent (it and what is below it are no longer drawn or reached from the root)
	public inline function detach():Void
		world.detach(slot);

	public inline function children():NodeIterator
		return new NodeIterator(world, world.firstChildOf(slot));

	public inline function localMatrix():Mat4
		return world.localMatrix(slot);

	public inline function worldMatrix():Mat4
		return world.worldMatrix(slot);

	public inline function worldPosition():Vec3 {
		var c = world.worldMatrix(slot).c3;
		return new Vec3(c.x, c.y, c.z);
	}

	public inline function setMatrix(m:Mat4):Void
		world.setMatrix(slot, m);

	// turns it so that its -z looks at target (a point in its parent's space)
	public inline function lookAt(target:Vec3, ?up:Vec3):Void
		world.lookAt(slot, target, up);

	// the first node named name, this one or below it (depth first)
	public inline function find(name:String):Node
		return world.find(slot, name);

	// f on this node and each one below it, parents first
	public inline function walk(f:Node->Void):Void
		world.walk(slot, f);

	// whether it and all its ancestors are visible
	public inline function shown():Bool
		return world.shown(slot);

	// it and what is below it removed from the world (their components too)
	public inline function dispose():Void
		world.disposeNode(cast this);

	@:op(A == B) static inline function eq(a:Node, b:Node):Bool
		return a.id() == b.id();

	@:op(A != B) static inline function ne(a:Node, b:Node):Bool
		return a.id() != b.id();
}

class NodeIterator {
	final world:World;
	var at:Node;

	public inline function new(world:World, first:Node) {
		this.world = world;
		at = first;
	}

	public inline function hasNext():Bool
		return !at.isNone;

	public inline function next():Node {
		var n = at;
		at = world.nextSiblingOf(world.slotOf(n));
		return n;
	}
}
