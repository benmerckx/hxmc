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

	function new() {}
}
