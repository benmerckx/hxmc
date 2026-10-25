package hxmc.rt;

import hxmc.scoped.Slice;

// The maps' index (docs/hxmc.md, "Maps"), written once as scoped code
// (docs/plans/lowlevel.md, "One core, two faces"): the GC face is
// haxe.ds.IntMap, StringMap and ObjectMap, which view their GC array right
// before calling (the core has no GC point, and the raw-address check keeps
// the view from living across one); the scoped face is hxmc.scoped.IntTable,
// whose slots are on a data stack. Open addressing with linear probing: slot
// i is two Ints, a tag (IntMap's key, the others' hash) and the entry + 1 (0:
// empty); removals shift the probe chain back (no tombstones). The caller
// keeps the index at most half full and says where a tag's probe chain starts
// (home, before the mask) and which entry with a tag is the key (same).
@:hxmc.scoped class MapIndex {
	// the slot of the entry with tag t that `same` accepts (its entry
	// number), probing from home h; -1: none (the slot numbers run on from
	// h, the view masks them)
	public static inline function slot(idx:IndexView, h:Int, t:Int, same:Int->Bool):Int {
		var i = h;
		var r = -1;
		while (true) {
			var e = idx.entry(i);
			if (e == 0) break;
			if (idx.tag(i) == t && same(e - 1)) {
				r = i & idx.mask;
				break;
			}
			i++;
		}
		return r;
	}

	// the entry with tag t that `same` accepts, or -1
	public static inline function find(idx:IndexView, h:Int, t:Int, same:Int->Bool):Int {
		var i = h;
		var r = -1;
		while (true) {
			var e = idx.entry(i);
			if (e == 0) break;
			if (idx.tag(i) == t && same(e - 1)) {
				r = e - 1;
				break;
			}
			i++;
		}
		return r;
	}

	// entry e (tag t, home h) indexed: in the first empty slot of its chain
	public static inline function insert(idx:IndexView, h:Int, t:Int, e:Int) {
		var i = h;
		while (idx.entry(i) != 0)
			i++;
		idx.setTag(i, t);
		idx.setEntry(i, e + 1);
	}

	// slot i emptied, the slots after it whose probe chain passes through it
	// moved back (backward-shift deletion); home: a tag's home slot
	public static inline function unindex(idx:IndexView, i:Int, home:Int->Int) {
		var mask = idx.mask;
		var j = i;
		while (true) {
			j = (j + 1) & mask;
			var e = idx.entry(j);
			if (e == 0) break;
			var h = home(idx.tag(j)) & mask;
			// (j stays where it is when its home is cyclically in (i, j])
			if (i <= j ? (i < h && h <= j) : (i < h || h <= j)) continue;
			idx.setTag(i, idx.tag(j));
			idx.setEntry(i, e);
			i = j;
		}
		idx.setEntry(i, 0);
	}
}

// The slots of an index (mask + 1 of them, two Ints each): a Slice of Ints
// (on each target its representation: hxmc.scoped.Slice), whose length was
// checked against the mask when the view was made (or is the maps' trusted
// shell's invariant), so that a slot number, masked, is always in range: the
// accesses need no other test. A struct value natively (in registers); an
// object of final fields on WasmGC, which Haxe's inline constructors turn
// into locals.
@:forward(mask)
abstract IndexView(IndexViewData) {
	public inline function new(slots:Slice<Int>, mask:Int) {
		if (slots.length < 2 * (mask + 1)) Abort.outOfRange();
		this = new IndexViewData(slots, mask);
	}

	// the same, unchecked: for the maps (MapSlots.index), which keep their
	// array's size so, as the trusted shell around the core (a test here
	// would read the array's header, another cache line, on every lookup)
	public static inline function trusted(slots:Slice<Int>, mask:Int):IndexView
		return cast new IndexViewData(slots, mask);

	public inline function tag(i:Int):Int
		return this.slots.unsafeGet(2 * (i & this.mask));

	public inline function entry(i:Int):Int
		return this.slots.unsafeGet(2 * (i & this.mask) + 1);

	public inline function setTag(i:Int, v:Int)
		this.slots.unsafeSet(2 * (i & this.mask), v);

	public inline function setEntry(i:Int, v:Int)
		this.slots.unsafeSet(2 * (i & this.mask) + 1, v);
}

@:hxmc.struct @:hxmc.repr @:noCompletion class IndexViewData {
	public final slots:Slice<Int>;
	public final mask:Int;

	public inline function new(slots:Slice<Int>, mask:Int) {
		this.slots = slots;
		this.mask = mask;
	}
}
