package hxmc.scene;

import hxmc.gfx.shader.Mat4;
import hxmc.gfx.shader.Vec3;
import hxmc.gfx.shader.Vec4;
import hxmc.scene.math.MathTools;
import hxmc.scene.math.Quat;

// A scene: a scene graph of Nodes (handles) over flat arrays, one slot per
// node: its local translation, rotation and scale (10 floats), its local
// and world matrices (16 each), its parent and siblings, its name and
// visibility. What nodes carry (a camera, a mesh, a light) is in typed
// stores keyed by node (Store, created by the kinds a program uses, so a
// kind nobody uses is not linked).
//
// World matrices are computed when asked and cached: a slot keeps the
// version of its parent's world matrix it was computed from, so a change
// high in the tree makes everything below it stale without visiting it,
// and still parts of a scene cost nothing per frame.
//
// A node's id: the world (4 bits: up to 16 worlds alive), the slot's
// generation (7 bits, never 0 for a live node, so no node is 0, NONE) and
// the slot (20 bits).
class World {
	@:allow(hxmc.scene) static var all:Array<World> = [];
	@:allow(hxmc.scene) static inline var WORLD_SHIFT = 27;
	static inline var GEN_SHIFT = 20;
	static inline var SLOT_MASK = (1 << 20) - 1;

	public final root:Node;

	final index:Int;
	final gens:Array<Int> = [];
	final free:Array<Int> = [];
	@:allow(hxmc.scene) final names:Array<String> = [];
	@:allow(hxmc.scene) final visible:Array<Bool> = [];
	// (tx ty tz, qx qy qz qw, sx sy sz)
	final trs:Array<Float> = [];
	final locals:Array<Float> = [];
	final worlds:Array<Float> = [];
	final localDirty:Array<Bool> = [];
	final worldValid:Array<Bool> = [];
	final versions:Array<Int> = [];
	final parentVersions:Array<Int> = [];
	final parents:Array<Int> = [];
	final firstChild:Array<Int> = [];
	final lastChild:Array<Int> = [];
	final nextSibling:Array<Int> = [];
	final prevSibling:Array<Int> = [];
	final stores:Array<StoreBase> = [];
	var live = 0;

	public function new(name = "world") {
		var k = all.indexOf(null);
		if (k < 0) {
			k = all.length;
			if (k >= 16) throw "hxmc.scene.World: more than 16 worlds alive";
			all.push(this);
		} else
			all[k] = this;
		index = k;
		root = make(name);
	}

	// the world's slot freed for another (its nodes' handles stale)
	public function dispose() {
		all[index] = null;
	}

	// the number of live nodes, the root included
	public var count(get, never):Int;

	inline function get_count():Int
		return live;

	// a new node, under parent (by default the root)
	public function node(name = "", ?parent:Node):Node {
		var n = make(name);
		attach(parent != null && !parent.isNone ? parent : root, n);
		return n;
	}

	function make(name:String):Node {
		var s:Int;
		if (free.length > 0) s = free.pop() else {
			s = gens.length;
			if (s > SLOT_MASK) throw "hxmc.scene.World: too many nodes";
			gens.push(0);
			names.push("");
			visible.push(true);
			for (_ in 0...10)
				trs.push(0);
			for (_ in 0...16) {
				locals.push(0);
				worlds.push(0);
			}
			localDirty.push(true);
			worldValid.push(false);
			versions.push(0);
			parentVersions.push(-1);
			parents.push(-1);
			firstChild.push(-1);
			lastChild.push(-1);
			nextSibling.push(-1);
			prevSibling.push(-1);
		}
		// (generations 1..127)
		var g = gens[s] % 127 + 1;
		gens[s] = g;
		names[s] = name;
		visible[s] = true;
		var b = 10 * s;
		for (k in 0...10)
			trs[b + k] = k == 6 || k >= 7 ? 1 : 0;
		localDirty[s] = true;
		worldValid[s] = false;
		parentVersions[s] = -1;
		parents[s] = firstChild[s] = lastChild[s] = nextSibling[s] = prevSibling[s] = -1;
		live++;
		return new Node(index << WORLD_SHIFT | g << GEN_SHIFT | s);
	}

	@:allow(hxmc.scene) inline function isValid(n:Node):Bool {
		var s = n.id() & SLOT_MASK;
		return n.id() >>> WORLD_SHIFT == index && s < gens.length && gens[s] == (n.id() >>> GEN_SHIFT) & 127;
	}

	@:allow(hxmc.scene) function slotOf(n:Node):Int {
		if (!isValid(n)) throw n.isNone ? "hxmc.scene: Node.NONE used" : "hxmc.scene: a disposed node used";
		return n.id() & SLOT_MASK;
	}

	inline function handle(s:Int):Node
		return s < 0 ? Node.NONE : new Node(index << WORLD_SHIFT | gens[s] << GEN_SHIFT | s);

	@:allow(hxmc.scene) inline function parentOf(s:Int):Node
		return handle(parents[s]);

	@:allow(hxmc.scene) inline function firstChildOf(s:Int):Node
		return handle(firstChild[s]);

	@:allow(hxmc.scene) inline function nextSiblingOf(s:Int):Node
		return handle(nextSibling[s]);

	// (transforms)

	@:allow(hxmc.scene) inline function getPosition(s:Int):Vec3
		return new Vec3(trs[10 * s], trs[10 * s + 1], trs[10 * s + 2]);

	@:allow(hxmc.scene) inline function getRotation(s:Int):Quat
		return new Quat(trs[10 * s + 3], trs[10 * s + 4], trs[10 * s + 5], trs[10 * s + 6]);

	@:allow(hxmc.scene) inline function getScale(s:Int):Vec3
		return new Vec3(trs[10 * s + 7], trs[10 * s + 8], trs[10 * s + 9]);

	@:allow(hxmc.scene) function setPosition(s:Int, v:Vec3) {
		var b = 10 * s;
		trs[b] = v.x;
		trs[b + 1] = v.y;
		trs[b + 2] = v.z;
		localDirty[s] = true;
	}

	@:allow(hxmc.scene) function setRotation(s:Int, q:Quat) {
		var b = 10 * s + 3;
		trs[b] = q.x;
		trs[b + 1] = q.y;
		trs[b + 2] = q.z;
		trs[b + 3] = q.w;
		localDirty[s] = true;
	}

	@:allow(hxmc.scene) function setScale(s:Int, v:Vec3) {
		var b = 10 * s + 7;
		trs[b] = v.x;
		trs[b + 1] = v.y;
		trs[b + 2] = v.z;
		localDirty[s] = true;
	}

	@:allow(hxmc.scene) function setMatrix(s:Int, m:Mat4) {
		var d = MathTools.decompose(m);
		setPosition(s, d.t);
		setRotation(s, d.r);
		setScale(s, d.s);
	}

	@:allow(hxmc.scene) function lookAt(s:Int, target:Vec3, ?up:Vec3)
		setRotation(s, MathTools.lookRotation(target - getPosition(s), up != null ? up : new Vec3(0, 1, 0)));

	static inline function read(a:Array<Float>, b:Int):Mat4
		return new Mat4(new Vec4(a[b], a[b + 1], a[b + 2], a[b + 3]), new Vec4(a[b + 4], a[b + 5], a[b + 6], a[b + 7]),
			new Vec4(a[b + 8], a[b + 9], a[b + 10], a[b + 11]), new Vec4(a[b + 12], a[b + 13], a[b + 14], a[b + 15]));

	static function write(a:Array<Float>, b:Int, m:Mat4) {
		for (k in 0...4) {
			var c = MathTools.col(m, k);
			a[b + 4 * k] = c.x;
			a[b + 4 * k + 1] = c.y;
			a[b + 4 * k + 2] = c.z;
			a[b + 4 * k + 3] = c.w;
		}
	}

	@:allow(hxmc.scene) function localMatrix(s:Int):Mat4 {
		if (localDirty[s]) {
			write(locals, 16 * s, MathTools.compose(getPosition(s), getRotation(s), getScale(s)));
			localDirty[s] = false;
			worldValid[s] = false;
		}
		return read(locals, 16 * s);
	}

	@:allow(hxmc.scene) function worldMatrix(s:Int):Mat4 {
		var l = localMatrix(s);
		var p = parents[s];
		if (p < 0) {
			if (!worldValid[s]) {
				write(worlds, 16 * s, l);
				worldValid[s] = true;
				versions[s]++;
			}
			return read(worlds, 16 * s);
		}
		var pw = worldMatrix(p);
		if (!worldValid[s] || parentVersions[s] != versions[p]) {
			write(worlds, 16 * s, pw * l);
			parentVersions[s] = versions[p];
			worldValid[s] = true;
			versions[s]++;
		}
		return read(worlds, 16 * s);
	}

	// (a slot's world matrix version: tests)
	@:allow(hxmc.scene) inline function versionOf(s:Int):Int
		return versions[s];

	// (the tree)

	@:allow(hxmc.scene) function attach(parent:Node, child:Node):Node {
		var p = slotOf(parent), c = slotOf(child);
		var a = p;
		while (a >= 0) {
			if (a == c) throw "hxmc.scene: a node cannot be added under itself";
			a = parents[a];
		}
		detach(c);
		parents[c] = p;
		prevSibling[c] = lastChild[p];
		nextSibling[c] = -1;
		if (lastChild[p] >= 0) nextSibling[lastChild[p]] = c else firstChild[p] = c;
		lastChild[p] = c;
		worldValid[c] = false;
		return child;
	}

	@:allow(hxmc.scene) function detach(c:Int) {
		var p = parents[c];
		if (p < 0) return;
		if (prevSibling[c] >= 0) nextSibling[prevSibling[c]] = nextSibling[c] else firstChild[p] = nextSibling[c];
		if (nextSibling[c] >= 0) prevSibling[nextSibling[c]] = prevSibling[c] else lastChild[p] = prevSibling[c];
		parents[c] = prevSibling[c] = nextSibling[c] = -1;
		worldValid[c] = false;
	}

	@:allow(hxmc.scene) function find(s:Int, name:String):Node {
		if (names[s] == name) return handle(s);
		var c = firstChild[s];
		while (c >= 0) {
			var n = find(c, name);
			if (!n.isNone) return n;
			c = nextSibling[c];
		}
		return Node.NONE;
	}

	@:allow(hxmc.scene) function walk(s:Int, f:Node->Void) {
		f(handle(s));
		var c = firstChild[s];
		while (c >= 0) {
			var next = nextSibling[c];
			walk(c, f);
			c = next;
		}
	}

	@:allow(hxmc.scene) function shown(s:Int):Bool {
		while (s >= 0) {
			if (!visible[s]) return false;
			s = parents[s];
		}
		return true;
	}

	// whether a node is in the tree under the root (not detached)
	public function inTree(n:Node):Bool {
		var s = slotOf(n), r = slotOf(root);
		while (s >= 0) {
			if (s == r) return true;
			s = parents[s];
		}
		return false;
	}

	@:allow(hxmc.scene) function disposeNode(n:Node) {
		if (n == root) throw "hxmc.scene: the root is disposed with its world";
		var s = slotOf(n);
		detach(s);
		release(s);
	}

	function release(s:Int) {
		var c = firstChild[s];
		while (c >= 0) {
			var next = nextSibling[c];
			release(c);
			c = next;
		}
		for (st in stores)
			if (st != null) st.removeSlot(s);
		// (the generation moves on: the handles are stale)
		gens[s] = gens[s] % 127 + 1;
		parents[s] = firstChild[s] = lastChild[s] = nextSibling[s] = prevSibling[s] = -1;
		free.push(s);
		live--;
	}

	// (component stores)

	// the world's store of a kind (made on first use)
	public function store<T>(kind:StoreKind<T>):Store<T> {
		while (stores.length <= kind.id)
			stores.push(null);
		var s = stores[kind.id];
		if (s == null) {
			s = new Store<T>(this);
			stores[kind.id] = s;
		}
		return cast s;
	}
}
