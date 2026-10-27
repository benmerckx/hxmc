// Operations that must not allocate, or only within a bound, measured with
// the native collector's counters (hxmc.rt.Gc: the nursery's pointer and the
// bytes it handed out before the last minor collections). Each line is
// "<operation>: ok" when the bytes per operation are within the bound; the
// count otherwise. WebAssembly, WasmGC and the interpreters have another
// allocator: there every line is "ok" without a measurement. (Objects
// larger than a part of the nursery go to the old space, not counted: with
// the corpus's 64 KB nursery, a large array's storage.)
#if !(hxmc.target == "wasm32-wasi" || hxmc.wasm_gc || hxmc.interp || hxmc.run)
@:access(hxmc.rt.Gc)
#end
class AllocBounds {
	static inline function bytes():Float {
		#if (hxmc.target == "wasm32-wasi" || hxmc.wasm_gc || hxmc.interp || hxmc.run)
		return 0.0;
		#else
		var p = hxmc.rt.Gc.yptr;
		var young:Float = cast hxmc.rt.Gc.youngBytes;
		return young + (p.isNull() ? 0.0 : (cast p.diff(hxmc.rt.Gc.youngStart) : Float));
		#end
	}

	static function check(name:String, b0:Float, b1:Float, ops:Int, bound:Float) {
		var per = (b1 - b0) / ops;
		Sys.println(name + ": " + (per <= bound ? "ok" : per + " B/op, bound " + bound));
	}

	// (through the interface: its declarations stay, and an implementation
	// shares their signature, the key a type parameter's)
	static function viaInterface<K, V>(m:haxe.Constraints.IMap<K, V>, k:K, v:V):Bool {
		m.set(k, v);
		var r = m.get(k) != null && m.exists(k);
		return m.remove(k) && r;
	}

	static function main() {
		#if !(hxmc.target == "wasm32-wasi" || hxmc.wasm_gc || hxmc.interp || hxmc.run)
		hxmc.rt.Gc.stats = true;
		#end
		maps();
		arrays();
		structLoops();
		sorts();
		#if !(hxmc.target == "wasm32-wasi" || hxmc.wasm_gc || hxmc.interp || hxmc.run)
		hxmc.rt.Gc.stats = false; // (no report at the exit)
		#end
	}

	// map lookups of a present or missing key (helder: IntMap.get boxed its
	// key, 12 to 16 B per call; keys from 4096: the boxes of small Ints are
	// static)
	static function maps() {
		var im = new haxe.ds.IntMap<AllocBounds>();
		var sm = new haxe.ds.StringMap<AllocBounds>();
		var om = new haxe.ds.ObjectMap<AllocBounds, AllocBounds>();
		var keys = [for (i in 0...64) new AllocBounds()];
		var names = [for (i in 0...64) "k" + i];
		for (i in 0...32) {
			im.set(4096 + i * 4, keys[i]);
			sm.set(names[i], keys[i]);
			om.set(keys[i], keys[i]);
		}
		var hits = 0;
		hits += viaInterface(im, 100000, keys[0]) ? 1 : 0;
		hits += viaInterface(sm, "x", keys[0]) ? 1 : 0;
		hits += viaInterface(om, keys[63], keys[0]) ? 1 : 0;
		var b0 = bytes();
		for (k in 0...100000) if ((k * 28) % 20000 != 7) hits++;
		check("loop", b0, bytes(), 100000, 0);
		b0 = bytes();
		for (k in 0...100000) if (im.exists(4096 + (k & 255))) hits++;
		check("IntMap.exists", b0, bytes(), 100000, 0);
		b0 = bytes();
		for (k in 0...100000) if (im.get(4096 + (k & 255)) != null) hits++;
		check("IntMap.get", b0, bytes(), 100000, 0);
		b0 = bytes();
		for (k in 0...100000) if (im.get((k * 28) % 20000) != null) hits++;
		check("IntMap.get (missing)", b0, bytes(), 100000, 0);
		b0 = bytes();
		for (k in 0...100000) im.set(4096 + (k & 31) * 4, keys[k & 31]);
		check("IntMap.set (present)", b0, bytes(), 100000, 0);
		b0 = bytes();
		for (k in 0...100000) if (im.remove(4097 + (k & 255) * 4)) hits++;
		check("IntMap.remove (missing)", b0, bytes(), 100000, 0);
		b0 = bytes();
		for (k in 0...100000) if (sm.get(names[k & 63]) != null) hits++;
		check("StringMap.get", b0, bytes(), 100000, 0);
		b0 = bytes();
		for (k in 0...100000) if (sm.exists(names[k & 63])) hits++;
		check("StringMap.exists", b0, bytes(), 100000, 0);
		b0 = bytes();
		for (k in 0...100000) if (om.get(keys[k & 63]) != null) hits++;
		check("ObjectMap.get", b0, bytes(), 100000, 0);
		b0 = bytes();
		for (k in 0...100000) if (om.exists(keys[k & 63])) hits++;
		check("ObjectMap.exists", b0, bytes(), 100000, 0);
		Sys.println("hits " + hits);
	}

	// growing arrays one element at a time: amortised, as push (helder:
	// resize to the length + 1 copied the storage every time, 2 KB per
	// element up to 1000)
	static function arrays() {
		var a:Array<Int> = [];
		var b0 = bytes();
		for (k in 1...4097) a.resize(k);
		check("resize Int (+1)", b0, bytes(), 4096, 16);
		var o:Array<AllocBounds> = [];
		b0 = bytes();
		for (k in 1...4097) o.resize(k);
		check("resize object (+1)", b0, bytes(), 4096, 32);
		var p:Array<Int> = [];
		b0 = bytes();
		for (k in 0...4096) p.push(k);
		check("push Int", b0, bytes(), 4096, 16);
		// (within the capacity: nothing)
		a.resize(10);
		b0 = bytes();
		for (k in 0...4096) a.resize(10 + (k & 1023));
		check("resize within capacity", b0, bytes(), 4096, 0);
		// (a resize from empty: the exact length, once)
		var e:Array<Int> = [];
		b0 = bytes();
		e.resize(1000);
		check("resize from empty", b0, bytes(), 1000, 4.1);
		Sys.println(a.length + " " + o.length + " " + p.length + " " + e.length + " " + a[1000] + " " + o[4095] + " " + e[999]);
	}

	// a for over an array literal of struct values: unrolled by the typer
	// without a continue or a break, else a loop over the literal (helder: it
	// allocated the array and boxed each element, 112 B per run)
	static var fsink = 0.0;

	static function structLoops() {
		var b0 = bytes();
		for (k in 0...1000)
			for (v in [new V3(k, 0, 0), new V3(0, k, 0)]) {
				if (v.y > 500) continue;
				fsink += v.y;
			}
		check("for struct literal, continue", b0, bytes(), 1000, 0);
		b0 = bytes();
		for (k in 0...1000)
			for (v in [new V3(k, 1, 0), new V3(0, k, 1), new V3(1, 0, k)]) {
				if (v.z > 700) break;
				fsink += v.x + v.y * 2 + v.z * 3;
			}
		check("for struct literal, break", b0, bytes(), 1000, 0);
		b0 = bytes();
		for (k in 0...1000)
			for (v in [new V3(k, 0, 0), new V3(0, k, 0)])
				fsink += v.y;
		check("for struct literal", b0, bytes(), 1000, 0);
		// (one element; a nested loop over another literal)
		for (v in [new V3(1, 2, 3)]) {
			if (v.x < 0) continue;
			for (w in [v, new V3(v.z, v.y, v.x)]) {
				if (w.x == 2) continue;
				fsink += w.x * 10;
			}
		}
		Sys.println(fsink);
	}

	// sorting small arrays (helder: 1.7 KB per sort of 100 Ints with a
	// comparator, a merge sort's buffers of boxed copies); large ones keep
	// the order, stable
	var key:Int;

	static function sorts() {
		var ints = [for (i in 0...100) 100000 + (i * 7919) % 101];
		var objs = [for (i in 0...100) {var o = new AllocBounds(); o.key = (i * 37) % 10; o;}];
		var work = ints.copy(), owork = objs.copy();
		var total = 0.0;
		for (k in 0...100) {
			for (i in 0...100) work[i] = ints[i];
			var b0 = bytes();
			work.sort((x, y) -> x - y);
			total += bytes() - b0;
		}
		check("sort 100 Ints", 0, total, 100, 64);
		total = 0.0;
		for (k in 0...100) {
			for (i in 0...100) owork[i] = objs[i];
			var b0 = bytes();
			owork.sort((a, b) -> a.key - b.key);
			total += bytes() - b0;
		}
		check("sort 100 objects", 0, total, 100, 64);
		var floats = [for (i in 0...100) ((i * 7919) % 101) / 3], fwork = floats.copy();
		total = 0.0;
		for (k in 0...100) {
			for (i in 0...100) fwork[i] = floats[i];
			var b0 = bytes();
			fwork.sort((x, y) -> x < y ? -1 : x > y ? 1 : 0);
			total += bytes() - b0;
		}
		check("sort 100 Floats", 0, total, 100, 64);
		Sys.println(work.slice(0, 5) + " " + work.slice(95) + " " + [for (o in owork.slice(0, 12)) o.key + ":" + objs.indexOf(o)].join(","));
		// (stable, at every size around the thresholds)
		var ok = true;
		for (n in [0, 1, 2, 7, 8, 9, 31, 32, 33, 63, 64, 65, 100, 127, 128, 129, 255, 256, 257, 1000, 5000]) {
			var a = [for (i in 0...n) {var o = new AllocBounds(); o.key = (i * 7919 + 13) % (n > 10 ? 10 : 3); o;}];
			var idx = new haxe.ds.ObjectMap<AllocBounds, Int>();
			for (i in 0...n) idx.set(a[i], i);
			a.sort((x, y) -> x.key - y.key);
			for (i in 1...n)
				if (a[i - 1].key > a[i].key || a[i - 1].key == a[i].key && idx.get(a[i - 1]) > idx.get(a[i])) ok = false;
			var b = [for (i in 0...n) (i * 7919 + 13) % 1009];
			b.sort((x, y) -> y - x);
			for (i in 1...n)
				if (b[i - 1] < b[i]) ok = false;
			var c = [for (i in 0...n) ((i * 7919 + 13) % 1009) / 7];
			c.sort((x, y) -> x < y ? -1 : x > y ? 1 : 0);
			for (i in 1...n)
				if (c[i - 1] > c[i]) ok = false;
			// (a comparator of Dynamic arguments: the generic sort)
			var d = [for (i in 0...n) (i * 7919 + 13) % 1009];
			var cmp:Dynamic->Dynamic->Int = (x, y) -> (x : Int) - (y : Int);
			d.sort(cmp);
			for (i in 1...n)
				if (d[i - 1] > d[i]) ok = false;
		}
		Sys.println("sorted and stable: " + ok);
	}

	function new() {}
}

@:hxmc.struct final class V3 {
	public final x:Float;
	public final y:Float;
	public final z:Float;

	public inline function new(x:Float, y:Float, z:Float) {
		this.x = x;
		this.y = y;
		this.z = z;
	}
}
