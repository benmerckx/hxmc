// Large objects (over 128 KB) through major collections: on wasm32 each has
// a region of its own, which a major collection keeps where it is when the
// object is reached (promoted in place, issue #129); natively they are
// copied as any object. Their contents stay intact; the references they hold
// follow the small objects they point to, which majors move; slots stored
// into a large old object (the write barrier) are seen by minor
// collections; a large array reachable only from another one survives; the
// dead ones are freed, and new ones take their place. GcStats.liveBytes
// counts what a major collection left live, and drops once they are dropped.
import haxe.io.Bytes;
import haxe.ds.Vector;
import hxmc.GcStats;

class Item {
	public var id:Int;
	public var name:String;

	public function new(id:Int) {
		this.id = id;
		name = "item" + id;
	}
}

class GcLargeObjects {
	static var bytes:Array<Bytes> = [];
	static var seeds:Array<Int> = [];
	static var refs:Vector<Item>;
	static var outer:Vector<Vector<Item>>;
	static var junk:Array<Item> = [];

	static function fill(b:Bytes, seed:Int)
		for (i in 0...b.length)
			b.set(i, (i * 31 + seed) & 255);

	static function intact(b:Bytes, seed:Int):Bool {
		for (i in 0...b.length)
			if (b.get(i) != (i * 31 + seed) & 255) return false;
		return true;
	}

	// garbage, some of it promoted before it dies
	static function churn(n:Int)
		for (i in 0...n) {
			junk.push(new Item(i));
			if (junk.length > 500) junk = [];
		}

	static function itemsOk(v:Vector<Item>, base:Int):Bool {
		for (i in 0...v.length)
			if (v[i] == null || v[i].name != "item" + v[i].id || (i % 40 != 0 && v[i].id != base + i)) return false;
		return true;
	}

	static function main() {
		for (k in 0...6) {
			var b = Bytes.alloc((1 << 18) + k * 70001);
			fill(b, k);
			bytes.push(b);
			seeds.push(k);
		}
		// 40000 references: 320 KB, to small objects that move
		refs = new Vector(40000);
		for (i in 0...refs.length)
			refs[i] = new Item(i);
		// a large array held only by another large array
		outer = new Vector(20000);
		var inner = new Vector<Item>(30000);
		for (i in 0...inner.length)
			inner[i] = new Item(500000 + i);
		outer[19999] = inner;
		inner = null;
		for (r in 0...5) {
			churn(30000);
			hxmc.NativeGc.collect(true);
			// stores into the large old array, seen by a minor collection
			for (i in 0...1000)
				refs[i * 40] = new Item(100000 + r * 1000 + i);
			churn(30000);
			hxmc.NativeGc.collect(false);
			// one large Bytes dropped, another allocated
			var k = r % bytes.length;
			bytes[k] = Bytes.alloc(300000 + r * 4096);
			seeds[k] = 100 + r;
			fill(bytes[k], seeds[k]);
		}
		hxmc.NativeGc.collect(true);
		var ok = true;
		for (k in 0...bytes.length)
			if (!intact(bytes[k], seeds[k])) ok = false;
		Sys.println("bytes intact: " + ok);
		Sys.println("references: " + itemsOk(refs, 0) + " " + refs[40].id + " " + refs[41].name);
		Sys.println("held by a large array: " + itemsOk(outer[19999], 500000) + " " + outer[19999][29999].name);
		// what is live: at least the large objects, not much more
		var large = 0.0;
		for (b in bytes)
			large += b.length;
		large += 8.0 * (refs.length + outer.length + outer[19999].length);
		var live = GcStats.liveBytes();
		Sys.println("live bytes: " + (live >= large) + " " + (live < large + 8e6));
		bytes = [];
		refs = null;
		outer = null;
		hxmc.NativeGc.collect(true);
		Sys.println("dropped: " + (GcStats.liveBytes() < live - large + 1e6));
	}
}
