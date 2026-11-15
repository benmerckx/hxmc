package core.ds;

import haxe.ds.Vector;

// port: a persistent map with string keys that keeps a sequence too: upstream's pairs
// of a PMap and the list of the same bindings in another order (a class's `cl_fields`
// and `cl_ordered_fields`, its `cl_statics` and `cl_ordered_statics`), which upstream
// keeps in step by hand at every write. Iteration follows the sequence; `byName` is the
// PMap, in key order, for lookups by name and wherever upstream iterates the PMap (and
// to share, as a class's statics are its `cl_type`'s fields). The operations are the
// ones upstream applies to such a pair: `cons` (`f :: l` and `PMap.add`), `filter`
// (`List.filter` removing what it drops from the PMap), `rev`, and making one of a
// list (`List.fold_left PMap.add`). An update copies the sequence once and returns a
// new map; the old one is unchanged.
final class SeqMap<V> {
	static final emptyMap:SeqMap<Dynamic> = new SeqMap(PMap.empty(), new Vector(0), new Vector(0));

	public final byName:PMap<V>;

	final keys:Vector<String>;
	final values:Vector<V>;

	public var length(get, never):Int;

	inline function get_length():Int return values.length;

	function new(byName:PMap<V>, keys:Vector<String>, values:Vector<V>) {
		this.byName = byName;
		this.keys = keys;
		this.values = values;
	}

	public static inline function empty<V>():SeqMap<V> return cast emptyMap;

	// port: `List.fold_left (fun pmap f -> PMap.add (name f) f pmap) PMap.empty l` beside l
	// itself: the sequence is the list; the last of a name is the one byName finds.
	public static function ofArray<V>(names:Array<String>, values:Array<V>):SeqMap<V> {
		if (values.length == 0) return empty();
		return new SeqMap(PMap.ofArrays(names, values), Vector.fromArrayCopy(names), Vector.fromArrayCopy(values));
	}

	public inline function isEmpty():Bool return values.length == 0;

	public inline function exists(name:String):Bool return byName.exists(name);

	public inline function get(name:String):Null<V> return byName.get(name);

	// port: PMap.find, raising Not_found.
	public inline function find(name:String):V return byName.find(name);

	// port: the i-th of the sequence (0 <= i < length).
	public inline function at(i:Int):V return values[i];

	// port: `f :: l` and `PMap.add name f m`.
	public function cons(name:String, value:V):SeqMap<V> {
		var n = values.length, nk = new Vector<String>(n + 1), nv = new Vector<V>(n + 1);
		nk[0] = name;
		nv[0] = value;
		Vector.blit(keys, 0, nk, 1, n);
		Vector.blit(values, 0, nv, 1, n);
		return new SeqMap(byName.add(name, value), nk, nv);
	}

	// port: `List.filter keep l`, with `PMap.remove` of each dropped one's name; keep runs
	// in sequence order. Upstream removes from the PMap inside keep's callback, as it goes,
	// and assigns the list once the filter is done: `dropped`, after each drop, gets that
	// state (this sequence, the PMap without the ones dropped so far), for callers whose
	// keep reads the class's fields meanwhile.
	public function filter(keep:V->Bool, ?dropped:SeqMap<V>->Void):SeqMap<V> {
		var n = values.length, kept = new Vector<Bool>(n), m = 0, map = byName;
		for (i in 0...n) {
			if (kept[i] = keep(values[i])) m++;
			else {
				map = map.remove(keys[i]);
				if (dropped != null) dropped(new SeqMap(map, keys, values));
			}
		}
		if (m == n) return this;
		var nk = new Vector<String>(m), nv = new Vector<V>(m), j = 0;
		for (i in 0...n) if (kept[i]) {
			nk[j] = keys[i];
			nv[j++] = values[i];
		}
		return new SeqMap(map, nk, nv);
	}

	// port: `List.rev l`, the PMap as it is.
	public function rev():SeqMap<V> {
		var n = values.length;
		if (n < 2) return this;
		var nk = new Vector<String>(n), nv = new Vector<V>(n);
		for (i in 0...n) {
			nk[i] = keys[n - 1 - i];
			nv[i] = values[n - 1 - i];
		}
		return new SeqMap(byName, nk, nv);
	}

	// port: whether f holds for one of the sequence (`List.exists`).
	public function any(f:V->Bool):Bool {
		for (v in values) if (f(v)) return true;
		return false;
	}

	// port: the sequence as a new Array.
	public function toArray():Array<V> {
		var out:Array<V> = [];
		out.resize(values.length);
		for (i in 0...values.length) out[i] = values[i];
		return out;
	}

	// port: f of the sequence, in its order, as a new Array (`List.map`).
	public function mapToArray<W>(f:V->W):Array<W> {
		var out:Array<W> = [];
		out.resize(values.length);
		for (i in 0...values.length) out[i] = f(values[i]);
		return out;
	}

	// port: the sequence, in its order.
	public inline function iterator():SeqMapIterator<V> return new SeqMapIterator(values);
}

class SeqMapIterator<V> {
	final values:Vector<V>;
	var i = 0;

	public inline function new(values:Vector<V>) this.values = values;

	public inline function hasNext():Bool return i < values.length;

	public inline function next():V return values[i++];
}
