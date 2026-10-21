package hxmc.wasmgc;

import hxmc.Buf;
import hxmc.ir.Ir;
import hxmc.wasm.Enc;

// Small functions the generated code calls (written here in wasm, once per
// module, when first asked for): Haxe's array accesses (reads out of range
// give the default, writes past the end grow the array), Dynamic's unboxing,
// fmod, interface tests and the kind of a Dynamic value (hxmc.rt.gc.W.kind).
class Helpers {
	static function valByte(k:String):Int
		return switch k {
			case "i" | "b": Enc.I32;
			case "f": Enc.F64;
			case "l": Enc.I64;
			case _: 0x6D;
		}

	static function get(b:Buf, i:Int) {
		b.u8(0x20);
		Enc.uleb(b, i);
	}

	static function set(b:Buf, i:Int) {
		b.u8(0x21);
		Enc.uleb(b, i);
	}

	static function i32(b:Buf, v:Int) {
		b.u8(0x41);
		Enc.sleb(b, v);
	}

	// the array's length (local 0)
	static function len(m:GcModule, b:Buf) {
		get(b, 0);
		m.castTo(b, m.arrBaseType);
		m.gc(b, 0x02, m.arrBaseType, 0);
	}

	// the array's storage (local 0)
	static function data(m:GcModule, b:Buf, k:String) {
		get(b, 0);
		m.castTo(b, m.arrType(k));
		m.gc(b, 0x02, m.arrType(k), 1);
	}

	// (an array of another kind than the code expects, as map's: through the
	// boxed path, unboxed or boxed for this kind)
	static function otherKind(m:GcModule, b:Buf, k:String) {
		get(b, 0);
		b.u8(0xFB);
		b.u8(0x14);
		Enc.sleb(b, m.arrType(k));
		b.u8(0x45);
		b.u8(0x04);
		b.u8(0x40);
		// (null, with -D hxmc.null-checks: rt_null_access throws "Null Access", FuncGen.derefAs)
		if (hxmc.ir.Lower.nullChecks) {
			get(b, 0);
			b.u8(0xD1); // ref.is_null
			b.u8(0x04);
			b.u8(0x40);
			b.u8(0x10);
			Enc.uleb(b, m.exportOf("rt_null_access"));
			b.u8(0x00);
			b.u8(0x0B);
		}
	}

	public static function arrGet(m:GcModule, k:String):Int {
		var name = "arr_get_" + k;
		var h = m.hasHelper(name);
		if (h != null) return h;
		var b = new Buf();
		var idx = m.addHelper(name, "pi_" + (k == "b" ? "i" : k), b, []);
		otherKind(m, b, k);
		get(b, 0);
		get(b, 1);
		b.u8(0x10);
		Enc.uleb(b, arrGetDyn(m));
		if (k != "p") {
			b.u8(0x10);
			Enc.uleb(b, unbox(m, k));
		}
		b.u8(0x0F);
		b.u8(0x0B);
		get(b, 1);
		len(m, b);
		b.u8(0x49); // i32.lt_u: also false for negative indices
		b.u8(0x04);
		b.u8(valByte(k));
		data(m, b, k);
		get(b, 1);
		m.gc(b, 0x0B, m.dataType(k));
		b.u8(0x05);
		m.constZero(b, k == "b" ? "i" : k);
		b.u8(0x0B);
		return idx;
	}

	// room for n elements (local 0 the array): the storage doubled (at least 4) when short
	static function ensure(m:GcModule, k:String):Int {
		var name = "arr_ensure_" + k;
		var h = m.hasHelper(name);
		if (h != null) return h;
		var b = new Buf();
		// if capacity < n
		data(m, b, k);
		m.gc(b, 0x0F);
		get(b, 1);
		b.u8(0x49);
		b.u8(0x04);
		b.u8(0x40);
		// cap = max(n, capacity * 2, 4) in local 2
		data(m, b, k);
		m.gc(b, 0x0F);
		i32(b, 1);
		b.u8(0x74);
		set(b, 2);
		get(b, 2);
		get(b, 1);
		b.u8(0x49);
		b.u8(0x04);
		b.u8(0x40);
		get(b, 1);
		set(b, 2);
		b.u8(0x0B);
		get(b, 2);
		i32(b, 4);
		b.u8(0x49);
		b.u8(0x04);
		b.u8(0x40);
		i32(b, 4);
		set(b, 2);
		b.u8(0x0B);
		// new storage in local 3, the elements copied
		get(b, 2);
		m.gc(b, 0x07, m.dataType(k));
		set(b, 3);
		get(b, 3);
		m.castTo(b, m.dataType(k));
		i32(b, 0);
		data(m, b, k);
		i32(b, 0);
		len(m, b);
		m.gc(b, 0x11, m.dataType(k), m.dataType(k));
		get(b, 0);
		m.castTo(b, m.arrType(k));
		get(b, 3);
		b.u8(0xFB);
		b.u8(0x16); // ref.cast to the non-null storage
		Enc.sleb(b, m.dataType(k));
		m.gc(b, 0x05, m.arrType(k), 1);
		b.u8(0x0B);
		return m.addHelper(name, "pi_v", b, [Enc.I32, 0x6D]);
	}

	public static function arrSet(m:GcModule, k:String):Int {
		var name = "arr_set_" + k;
		var h = m.hasHelper(name);
		if (h != null) return h;
		var e = ensure(m, k);
		var b = new Buf();
		var idx = m.addHelper(name, "pi" + (k == "b" ? "i" : k) + "_v", b, []);
		otherKind(m, b, k);
		get(b, 0);
		get(b, 1);
		get(b, 2);
		box(m, b, k);
		b.u8(0x10);
		Enc.uleb(b, arrSetDyn(m));
		b.u8(0x0F);
		b.u8(0x0B);
		// past the end: grown, the length the index + 1
		get(b, 1);
		len(m, b);
		b.u8(0x4F); // i32.ge_u
		b.u8(0x04);
		b.u8(0x40);
		get(b, 0);
		get(b, 1);
		i32(b, 1);
		b.u8(0x6A);
		b.u8(0x10);
		Enc.uleb(b, e);
		get(b, 0);
		m.castTo(b, m.arrBaseType);
		get(b, 1);
		i32(b, 1);
		b.u8(0x6A);
		m.gc(b, 0x05, m.arrBaseType, 0);
		b.u8(0x0B);
		data(m, b, k);
		get(b, 1);
		get(b, 2);
		m.gc(b, 0x0E, m.dataType(k));
		return idx;
	}

	public static function arrPush(m:GcModule, k:String):Int {
		var name = "arr_push_" + k;
		var h = m.hasHelper(name);
		if (h != null) return h;
		var e = ensure(m, k);
		var b = new Buf();
		var idx = m.addHelper(name, "p" + (k == "b" ? "i" : k) + "_v", b, []);
		otherKind(m, b, k);
		get(b, 0);
		len(m, b);
		get(b, 1);
		box(m, b, k);
		b.u8(0x10);
		Enc.uleb(b, arrSetDyn(m));
		b.u8(0x0F);
		b.u8(0x0B);
		get(b, 0);
		len(m, b);
		i32(b, 1);
		b.u8(0x6A);
		b.u8(0x10);
		Enc.uleb(b, e);
		data(m, b, k);
		len(m, b);
		get(b, 1);
		m.gc(b, 0x0E, m.dataType(k));
		get(b, 0);
		m.castTo(b, m.arrBaseType);
		len(m, b);
		i32(b, 1);
		b.u8(0x6A);
		m.gc(b, 0x05, m.arrBaseType, 0);
		return idx;
	}

	// Dynamic to a scalar: null gives 0; an Int read as a Float converts, and back
	public static function unbox(m:GcModule, k:String):Int {
		var name = "unbox_" + k;
		var h = m.hasHelper(name);
		if (h != null) return h;
		var r = k == "b" ? "i" : k;
		var b = new Buf();
		var tries = switch k {
			case "i": [TI32, TF64, TBool];
			case "f": [TF64, TI32];
			case "b": [TBool, TI32];
			case _: [TI64, TI32];
		};
		for (t in tries) {
			get(b, 0);
			b.u8(0xFB);
			b.u8(0x14);
			Enc.sleb(b, m.dynType(t));
			b.u8(0x04);
			b.u8(0x40);
			get(b, 0);
			m.castTo(b, m.dynType(t));
			m.gc(b, 0x02, m.dynType(t), 0);
			// convert to the representation asked for
			switch [k, t] {
				case ["i", TF64]:
					b.u8(0x10);
					Enc.uleb(b, f2iSlow(m));
				case ["f", TI32]: b.u8(0xB7);
				case ["l", TI32]: b.u8(0xAC);
				case _:
			}
			b.u8(0x0F);
			b.u8(0x0B);
		}
		m.constZero(b, r);
		return m.addHelper(name, "p_" + r, b, []);
	}

	// x - y * trunc(x / y)
	// hx_f2i_slow's: a Float to an Int, NaN 0, out of range modulo 2^32
	public static function f2iSlow(m:GcModule):Int {
		var h = m.hasHelper("f2i_slow");
		if (h != null) return h;
		var b = new Buf();
		function f64(v:Float) {
			b.u8(0x44);
			var bs = haxe.io.Bytes.alloc(8);
			bs.setDouble(0, v);
			b.bytes(bs);
		}
		get(b, 0);
		f64(-2147483649.0);
		b.u8(0x64);
		get(b, 0);
		f64(2147483648.0);
		b.u8(0x63);
		b.u8(0x71);
		b.u8(0x04);
		b.u8(Enc.I32);
		get(b, 0);
		b.u8(0xFC);
		b.u8(2);
		b.u8(0x05);
		get(b, 0);
		f64(4294967296.0);
		b.u8(0x10);
		Enc.uleb(b, fmod(m));
		b.u8(0xFC);
		b.u8(6);
		b.u8(0xA7);
		b.u8(0x0B);
		return m.addHelper("f2i_slow", "f_i", b, []);
	}

	public static function fmod(m:GcModule):Int {
		var h = m.hasHelper("fmod");
		if (h != null) return h;
		var b = new Buf();
		get(b, 0);
		get(b, 0);
		get(b, 1);
		b.u8(0xA3);
		b.u8(0x9D);
		get(b, 1);
		b.u8(0xA2);
		b.u8(0xA1);
		return m.addHelper("fmod", "ff_f", b, []);
	}

	// whether an object's class implements the interface
	public static function implementsOf(m:GcModule, iface:ClassInfo):Int {
		var name = "implements_" + iface.ident;
		var h = m.hasHelper(name);
		if (h != null) return h;
		var b = new Buf();
		get(b, 0);
		b.u8(0xFB);
		b.u8(0x14);
		Enc.sleb(b, m.objType);
		b.u8(0x04);
		b.u8(0x40);
		get(b, 0);
		m.castTo(b, m.objType);
		m.indexOf(b);
		set(b, 1);
		for (c in m.classList())
			if (c.ifaces.indexOf(iface) >= 0) {
				get(b, 1);
				i32(b, m.clsOf(c));
				b.u8(0x46);
				b.u8(0x04);
				b.u8(0x40);
				i32(b, 1);
				b.u8(0x0F);
				b.u8(0x0B);
			}
		b.u8(0x0B);
		i32(b, 0);
		return m.addHelper(name, "p_i", b, [Enc.I32]);
	}

	// obj.name(args) on a class instance (ECallAnon): its class's method of that
	// name, called directly; else the field through the runtime (a closure)
	public static function anonCall(m:GcModule, name:String, s:SigInfo):Int {
		var key = "anon_call_" + name + "_" + s.key;
		var h = m.hasHelper(key);
		if (h != null) return h;
		var params = "p" + [for (a in s.args) GcModule.repr(a)].join("");
		var b = new Buf();
		var idx = m.addHelper(key, params + "_" + GcModule.repr(s.ret), b, [Enc.I32]);
		get(b, 0);
		m.castTo(b, m.objType);
		m.indexOf(b);
		set(b, s.args.length + 1);
		for (c in m.classList()) {
			var f = c.findMethod(name);
			if (f == null || !m.reached(f) || f.args.length != s.args.length + 1) continue;
			// (a representation of the method's other than the call's: Dynamic, boxed
			// or unboxed, as Iterator<Int>'s next on a class whose next returns Dynamic)
			var conv = true;
			for (i in 0...s.args.length)
				conv = conv && convertible(GcModule.repr(s.args[i]), GcModule.repr(f.args[i + 1].ty));
			var fr = GcModule.repr(f.ret), sr = GcModule.repr(s.ret);
			if (!conv || !(convertible(fr, sr) || sr == "v")) continue;
			get(b, s.args.length + 1);
			i32(b, m.clsOf(c));
			b.u8(0x46);
			b.u8(0x04);
			b.u8(0x40);
			get(b, 0);
			for (i in 0...s.args.length) {
				get(b, i + 1);
				convert(m, b, s.args[i], f.args[i + 1].ty);
			}
			b.u8(0x10);
			Enc.uleb(b, m.tableFunc(f));
			if (sr == "v") {
				if (fr != "v") b.u8(0x1A);
			} else convert(m, b, f.ret, s.ret);
			b.u8(0x0F);
			b.u8(0x0B);
		}
		// (no such method: the runtime's, an Array's, a String's, a closure field)
		get(b, 0);
		b.u8(0x23);
		Enc.uleb(b, m.strLit(name));
		b.u8(0x41);
		Enc.sleb(b, s.args.length);
		for (i in 0...s.args.length) {
			get(b, i + 1);
			m.box(b, s.args[i]);
		}
		m.gc(b, 0x08, m.dataType("p"), s.args.length);
		m.gc(b, 0x00, m.arrType("p"));
		b.u8(0x10);
		Enc.uleb(b, m.exportOf("gc_anon_call"));
		var r = GcModule.repr(s.ret);
		if (r == "v") b.u8(0x1A) else if (r != "p") {
			b.u8(0x10);
			Enc.uleb(b, unbox(m, s.ret == TBool ? "b" : r));
		}
		return idx;
	}

	// whether a value of representation a passes as one of b (the same, or Dynamic boxed or unboxed)
	static function convertible(a:String, b:String):Bool
		return a == b || (a == "p") != (b == "p") && a != "v" && b != "v";

	// the value on the stack of type a as one of type b (convertible)
	static function convert(m:GcModule, b:Buf, from:Ty, to:Ty) {
		var fr = GcModule.repr(from), tr = GcModule.repr(to);
		if (fr == tr) return;
		if (tr == "p") m.box(b, from) else {
			b.u8(0x10);
			Enc.uleb(b, unbox(m, to == TBool ? "b" : tr));
		}
	}

	// two references of enum arguments equal: the same, else both enums
	// (enumEq), else as Dynamic (dynEq)
	public static function refEq3(m:GcModule, enumEq:Int, dynEq:Int):Int {
		var h = m.hasHelper("ref_eq3");
		if (h != null) return h;
		var b = new Buf();
		get(b, 0);
		get(b, 1);
		b.u8(0xD3);
		b.u8(0x04);
		b.u8(0x40);
		i32(b, 1);
		b.u8(0x0F);
		b.u8(0x0B);
		get(b, 0);
		b.u8(0xFB);
		b.u8(0x14);
		Enc.sleb(b, m.enumType);
		get(b, 1);
		b.u8(0xFB);
		b.u8(0x14);
		Enc.sleb(b, m.enumType);
		b.u8(0x71);
		b.u8(0x04);
		b.u8(0x40);
		get(b, 0);
		get(b, 1);
		b.u8(0x10);
		Enc.uleb(b, enumEq);
		b.u8(0x0F);
		b.u8(0x0B);
		get(b, 0);
		get(b, 1);
		b.u8(0x10);
		Enc.uleb(b, dynEq);
		return m.addHelper("ref_eq3", "pp_i", b, []);
	}

	// the kind of a Dynamic value (hxmc.rt.gc.W.kind): 0 null, 1 Int, 2 Float,
	// 3 Bool, 4 String, 5 class instance, 6 enum, 7 array, 8 function, 9 Int64,
	// 10 anonymous structure, 11 other, 12 a type value (Class, Enum)
	public static function kind(m:GcModule):Int {
		var h = m.hasHelper("kind");
		if (h != null) return h;
		var b = new Buf();
		get(b, 0);
		b.u8(0xD1);
		b.u8(0x04);
		b.u8(0x40);
		i32(b, 0);
		b.u8(0x0F);
		b.u8(0x0B);
		var tests = [
			{t: m.dynType(TI32), k: 1},
			{t: m.dynType(TF64), k: 2},
			{t: m.dynType(TBool), k: 3},
			{t: m.stringType, k: 4},
			{t: m.objType, k: 5},
			{t: m.enumType, k: 6},
			{t: m.arrBaseType, k: 7},
			{t: m.funBaseType, k: 8},
			{t: m.dynType(TI64), k: 9},
			{t: m.anonBaseType, k: 10},
			{t: m.typeType(), k: 12}
		];
		for (x in tests) {
			if (x.t < 0) continue;
			get(b, 0);
			b.u8(0xFB);
			b.u8(0x14);
			Enc.sleb(b, x.t);
			b.u8(0x04);
			b.u8(0x40);
			i32(b, x.k);
			b.u8(0x0F);
			b.u8(0x0B);
		}
		i32(b, 11);
		return m.addHelper("kind", "p_i", b, []);
	}

	static final KINDS:haxe.ds.Vector<String> = core.ds.VectorTools.vector("i", "f", "l", "p", "b");

	// the box of a value of kind k on the stack (p: itself)
	static function box(m:GcModule, b:Buf, k:String)
		switch k {
			case "i": m.box(b, TI32);
			case "f": m.box(b, TF64);
			case "l": m.box(b, TI64);
			case "b": m.box(b, TBool);
			case _:
		}

	// an object's identity hash (GcModule.indexOf), made the first time from a
	// linear congruential sequence (as hxmc.rt.Dyn.objHash's); 0 for other values
	public static function objHash(m:GcModule):Int {
		var h = m.hasHelper("obj_hash");
		if (h != null) return h;
		var tb = new Buf();
		tb.u8(Enc.I32);
		var ib = new Buf();
		i32(ib, 0x9E37);
		ib.u8(0x0B);
		var seed = m.newGlobal(tb, ib, true);
		var b = new Buf();
		// (local 1: the first i32, local 2: the hash)
		for (anon in [false, true]) {
			var t = anon ? m.anonBaseType : m.objType, f = anon ? 1 : 0;
			get(b, 0);
			b.u8(0xFB);
			b.u8(0x14);
			Enc.sleb(b, t);
			b.u8(0x04);
			b.u8(0x40);
			get(b, 0);
			m.castTo(b, t);
			m.gc(b, 0x02, t, f);
			b.u8(0x22);
			b.u8(1);
			i32(b, 16);
			b.u8(0x76);
			b.u8(0x22);
			b.u8(2);
			b.u8(0x45);
			b.u8(0x04);
			b.u8(0x40);
			// seed = seed * 1103515245 + 12345; hash = seed >>> 16 & 0xFFFF, not 0
			b.u8(0x23);
			Enc.uleb(b, seed);
			i32(b, 1103515245);
			b.u8(0x6C);
			i32(b, 12345);
			b.u8(0x6A);
			b.u8(0x24);
			Enc.uleb(b, seed);
			b.u8(0x23);
			Enc.uleb(b, seed);
			i32(b, 16);
			b.u8(0x76);
			b.u8(0x22);
			b.u8(2);
			b.u8(0x45);
			b.u8(0x04);
			b.u8(0x40);
			i32(b, 1);
			set(b, 2);
			b.u8(0x0B);
			get(b, 0);
			m.castTo(b, t);
			get(b, 1);
			get(b, 2);
			i32(b, 16);
			b.u8(0x74);
			b.u8(0x72);
			m.gc(b, 0x05, t, f);
			b.u8(0x0B);
			get(b, 2);
			b.u8(0x0F);
			b.u8(0x0B);
		}
		i32(b, 0);
		return m.addHelper("obj_hash", "p_i", b, [Enc.I32, Enc.I32]);
	}

	// an Int boxed: those of SMALL_MIN...SMALL_MAX made once each (in a table
	// filled as they are asked for, as hxmc.rt.Boxes has them), the others new
	static inline var SMALL_MIN = -128;
	static inline var SMALL_MAX = 1023;

	public static function boxInt(m:GcModule):Int {
		var h = m.hasHelper("box_int");
		if (h != null) return h;
		var pt = m.dataType("p"), dt = m.dynType(TI32);
		var tb = new Buf();
		tb.u8(0x63);
		Enc.sleb(tb, pt);
		var ib = new Buf();
		i32(ib, SMALL_MAX - SMALL_MIN + 1);
		m.gc(ib, 0x07, pt);
		ib.u8(0x0B);
		var table = m.newGlobal(tb, ib, false);
		var b = new Buf();
		// (local 1: the index; local 2: the box)
		get(b, 0);
		i32(b, SMALL_MIN);
		b.u8(0x6B);
		b.u8(0x22);
		b.u8(1);
		i32(b, SMALL_MAX - SMALL_MIN + 1);
		b.u8(0x49);
		b.u8(0x04);
		b.u8(0x40);
		b.u8(0x23);
		Enc.uleb(b, table);
		get(b, 1);
		m.gc(b, 0x0B, pt);
		b.u8(0x22);
		b.u8(2);
		b.u8(0xD1);
		b.u8(0x04);
		b.u8(0x40);
		b.u8(0x23);
		Enc.uleb(b, table);
		get(b, 1);
		get(b, 0);
		m.gc(b, 0x00, dt);
		b.u8(0x22);
		b.u8(2);
		m.gc(b, 0x0E, pt);
		b.u8(0x0B);
		get(b, 2);
		b.u8(0x0F);
		b.u8(0x0B);
		get(b, 0);
		m.gc(b, 0x00, dt);
		return m.addHelper("box_int", "i_p", b, [Enc.I32, 0x6D]);
	}

	// if local 0 is an array of kind k (then ... end)
	static function ifKind(m:GcModule, b:Buf, k:String, result = 0x40) {
		get(b, 0);
		b.u8(0xFB);
		b.u8(0x14);
		Enc.sleb(b, m.arrType(k));
		b.u8(0x04);
		b.u8(result);
	}

	// an array's kind: 0 Int, 1 Float, 2 Int64, 3 references, 4 Bool; -1 not an array
	public static function arrKind(m:GcModule):Int {
		var h = m.hasHelper("arr_kind");
		if (h != null) return h;
		var b = new Buf();
		for (i in 0...KINDS.length) {
			ifKind(m, b, KINDS[i]);
			i32(b, i);
			b.u8(0x0F);
			b.u8(0x0B);
		}
		i32(b, -1);
		return m.addHelper("arr_kind", "p_i", b, []);
	}

	// a[i] boxed (null out of range or not an array)
	public static function arrGetDyn(m:GcModule):Int {
		var h = m.hasHelper("arr_get_dyn");
		if (h != null) return h;
		var b = new Buf();
		var idx = m.addHelper("arr_get_dyn", "pi_p", b, []);
		for (k in KINDS) {
			var g = arrGet(m, k);
			ifKind(m, b, k);
			get(b, 0);
			get(b, 1);
			b.u8(0x10);
			Enc.uleb(b, g);
			box(m, b, k);
			b.u8(0x0F);
			b.u8(0x0B);
		}
		m.constZero(b, "p");
		return idx;
	}

	// a[i] = v (unboxed for the array's kind)
	public static function arrSetDyn(m:GcModule):Int {
		var h = m.hasHelper("arr_set_dyn");
		if (h != null) return h;
		var b = new Buf();
		var idx = m.addHelper("arr_set_dyn", "pip_v", b, []);
		for (k in KINDS) {
			var st = arrSet(m, k);
			ifKind(m, b, k);
			get(b, 0);
			get(b, 1);
			get(b, 2);
			if (k != "p") {
				b.u8(0x10);
				Enc.uleb(b, unbox(m, k));
			}
			b.u8(0x10);
			Enc.uleb(b, st);
			b.u8(0x0F);
			b.u8(0x0B);
		}
		return idx;
	}

	// a new array of the kind (arrKind's numbers) and length, its elements zero
	public static function arrNew(m:GcModule):Int {
		var h = m.hasHelper("arr_new");
		if (h != null) return h;
		var b = new Buf();
		for (i in 0...KINDS.length) {
			var k = KINDS[i];
			get(b, 0);
			i32(b, i);
			b.u8(0x46);
			b.u8(0x04);
			b.u8(0x40);
			get(b, 1);
			get(b, 1);
			m.gc(b, 0x07, m.dataType(k));
			m.gc(b, 0x00, m.arrType(k));
			b.u8(0x0F);
			b.u8(0x0B);
		}
		b.u8(0x00);
		return m.addHelper("arr_new", "ii_p", b, []);
	}

	// the array's length set to n: grown with zeros, or cut (what is cut cleared)
	public static function arrSetLen(m:GcModule):Int {
		var h = m.hasHelper("arr_set_len");
		if (h != null) return h;
		var b = new Buf();
		for (k in KINDS) {
			var e = ensure(m, k);
			ifKind(m, b, k);
			get(b, 0);
			get(b, 1);
			b.u8(0x10);
			Enc.uleb(b, e);
			// (cut: [n, length) cleared)
			get(b, 1);
			len(m, b);
			b.u8(0x48);
			b.u8(0x04);
			b.u8(0x40);
			data(m, b, k);
			get(b, 1);
			m.constZero(b, k == "b" ? "i" : k);
			len(m, b);
			get(b, 1);
			b.u8(0x6B);
			m.gc(b, 0x10, m.dataType(k));
			b.u8(0x0B);
			get(b, 0);
			m.castTo(b, m.arrBaseType);
			get(b, 1);
			m.gc(b, 0x05, m.arrBaseType, 0);
			b.u8(0x0F);
			b.u8(0x0B);
		}
		return m.addHelper("arr_set_len", "pi_v", b, []);
	}

	// dst[di...di+n] = src[si...si+n] (arrays of one kind, dst long enough)
	public static function arrBlit(m:GcModule):Int {
		var h = m.hasHelper("arr_blit");
		if (h != null) return h;
		var b = new Buf();
		for (k in KINDS) {
			ifKind(m, b, k);
			data(m, b, k);
			get(b, 1);
			get(b, 2);
			m.castTo(b, m.arrType(k));
			m.gc(b, 0x02, m.arrType(k), 1);
			get(b, 3);
			get(b, 4);
			m.gc(b, 0x11, m.dataType(k), m.dataType(k));
			b.u8(0x0F);
			b.u8(0x0B);
		}
		return m.addHelper("arr_blit", "pipii_v", b, []);
	}

	// ---- hxmc.NativeArray (rt/gc/GcNArray, W.na*): storage is an array of its
	// kind (GcModule.naType; the kinds by number GcModule.NA_KINDS), a wrapper
	// ($NWrap) holds storage

	// if local l is storage of kind k (then ... end)
	static function ifData(m:GcModule, b:Buf, l:Int, k:String, result = 0x40) {
		get(b, l);
		b.u8(0xFB);
		b.u8(0x14);
		Enc.sleb(b, m.naType(k));
		b.u8(0x04);
		b.u8(result);
	}

	// a NativeArray's kind: its storage's number (GcModule.NA_KINDS), 5 a wrapper
	// no typed view took yet, 6 one a view took; -1 not a NativeArray
	public static function naKind(m:GcModule):Int {
		var h = m.hasHelper("na_kind");
		if (h != null) return h;
		var b = new Buf();
		for (i in 0...GcModule.NA_KINDS.length) {
			ifData(m, b, 0, GcModule.NA_KINDS[i]);
			i32(b, i);
			b.u8(0x0F);
			b.u8(0x0B);
		}
		get(b, 0);
		b.u8(0xFB);
		b.u8(0x14);
		Enc.sleb(b, m.nwrapType);
		b.u8(0x04);
		b.u8(0x40);
		i32(b, 5);
		get(b, 0);
		m.castTo(b, m.nwrapType);
		m.gc(b, 0x02, m.nwrapType, 1);
		b.u8(0x6A);
		b.u8(0x0F);
		b.u8(0x0B);
		i32(b, -1);
		return m.addHelper("na_kind", "p_i", b, []);
	}

	// a NativeArray's storage: itself, unless a wrapper
	public static function naStorage(m:GcModule):Int {
		var h = m.hasHelper("na_storage");
		if (h != null) return h;
		var b = new Buf();
		get(b, 0);
		b.u8(0xFB);
		b.u8(0x14);
		Enc.sleb(b, m.nwrapType);
		b.u8(0x04);
		b.u8(0x6D);
		get(b, 0);
		m.castTo(b, m.nwrapType);
		m.gc(b, 0x02, m.nwrapType, 0);
		b.u8(0x05);
		get(b, 0);
		b.u8(0x0B);
		return m.addHelper("na_storage", "p_p", b, []);
	}

	// a NativeArray's length (its storage's: any array's)
	public static function naLen(m:GcModule):Int {
		var h = m.hasHelper("na_len");
		if (h != null) return h;
		var b = new Buf();
		get(b, 0);
		b.u8(0x10);
		Enc.uleb(b, naStorage(m));
		m.castTo(b, ARRAY);
		m.gc(b, 0x0F);
		return m.addHelper("na_len", "p_i", b, []);
	}

	// (the abstract heap type of every array)
	static inline var ARRAY = -0x16;

	// new storage of the kind (its number) and length, zeroed (the length tested by the caller)
	public static function naNew(m:GcModule):Int {
		var h = m.hasHelper("na_new");
		if (h != null) return h;
		var b = new Buf();
		for (i in 0...GcModule.NA_KINDS.length) {
			get(b, 0);
			i32(b, i);
			b.u8(0x46);
			b.u8(0x04);
			b.u8(0x40);
			get(b, 1);
			m.gc(b, 0x07, m.naType(GcModule.NA_KINDS[i]));
			b.u8(0x0F);
			b.u8(0x0B);
		}
		b.u8(0x00);
		return m.addHelper("na_new", "ii_p", b, []);
	}

	// element i of a NativeArray (or its wrapper's storage), boxed
	public static function naGet(m:GcModule):Int {
		var h = m.hasHelper("na_get");
		if (h != null) return h;
		var b = new Buf();
		// (local 2: the storage)
		get(b, 0);
		b.u8(0x10);
		Enc.uleb(b, naStorage(m));
		set(b, 2);
		for (k in GcModule.NA_KINDS) {
			ifData(m, b, 2, k);
			get(b, 2);
			m.castTo(b, m.naType(k));
			get(b, 1);
			m.gc(b, k == "b" ? 0x0D : 0x0B, m.naType(k));
			box(m, b, k);
			b.u8(0x0F);
			b.u8(0x0B);
		}
		b.u8(0x00);
		return m.addHelper("na_get", "pi_p", b, [0x6D]);
	}

	// element i of a NativeArray (or its wrapper's storage) set, unboxed for its kind (unchecked)
	public static function naSet(m:GcModule):Int {
		var h = m.hasHelper("na_set");
		if (h != null) return h;
		var b = new Buf();
		// (local 3: the storage)
		get(b, 0);
		b.u8(0x10);
		Enc.uleb(b, naStorage(m));
		set(b, 3);
		for (k in GcModule.NA_KINDS) {
			ifData(m, b, 3, k);
			get(b, 3);
			m.castTo(b, m.naType(k));
			get(b, 1);
			get(b, 2);
			if (k != "p") {
				b.u8(0x10);
				Enc.uleb(b, unbox(m, k));
			}
			m.gc(b, 0x0E, m.naType(k));
			b.u8(0x0F);
			b.u8(0x0B);
		}
		b.u8(0x00);
		return m.addHelper("na_set", "pip_v", b, [0x6D]);
	}

	// dst[di...di+n] = src[si...si+n] when both (or their wrappers' storage) are of one kind
	// (array.copy: overlapping ranges too; in bounds), and true; else false
	public static function naCopy(m:GcModule):Int {
		var h = m.hasHelper("na_copy");
		if (h != null) return h;
		var b = new Buf();
		// (locals 5 and 6: the storage of dst and src)
		get(b, 0);
		b.u8(0x10);
		Enc.uleb(b, naStorage(m));
		set(b, 5);
		get(b, 2);
		b.u8(0x10);
		Enc.uleb(b, naStorage(m));
		set(b, 6);
		for (k in GcModule.NA_KINDS) {
			var t = m.naType(k);
			for (l in [5, 6]) {
				get(b, l);
				b.u8(0xFB);
				b.u8(0x14);
				Enc.sleb(b, t);
			}
			b.u8(0x71);
			b.u8(0x04);
			b.u8(0x40);
			get(b, 5);
			m.castTo(b, t);
			get(b, 1);
			get(b, 6);
			m.castTo(b, t);
			get(b, 3);
			get(b, 4);
			m.gc(b, 0x11, t, t);
			i32(b, 1);
			b.u8(0x0F);
			b.u8(0x0B);
		}
		i32(b, 0);
		return m.addHelper("na_copy", "pipii_i", b, [0x6D, 0x6D]);
	}

	// little-endian loads and stores in a Bytes (an array of i8): n bytes at local 1
	public static function bytesGet(m:GcModule, wide:Bool):Int {
		var name = wide ? "bytes_get_i64" : "bytes_get_i32";
		var h = m.hasHelper(name);
		if (h != null) return h;
		var b = new Buf();
		var n = wide ? 8 : 4;
		for (i in 0...n) {
			get(b, 0);
			m.castTo(b, m.bytesType);
			get(b, 1);
			if (i > 0) {
				i32(b, i);
				b.u8(0x6A);
			}
			m.gc(b, 0x0D, m.bytesType);
			if (wide) b.u8(0xAD); // i64.extend_i32_u
			if (i > 0) {
				if (wide) {
					b.u8(0x42);
					Enc.sleb(b, 8 * i);
					b.u8(0x86);
					b.u8(0x84);
				} else {
					i32(b, 8 * i);
					b.u8(0x74);
					b.u8(0x72);
				}
			}
		}
		return m.addHelper(name, wide ? "pi_l" : "pi_i", b, []);
	}

	public static function bytesSet(m:GcModule, wide:Bool):Int {
		var name = wide ? "bytes_set_i64" : "bytes_set_i32";
		var h = m.hasHelper(name);
		if (h != null) return h;
		var b = new Buf();
		var n = wide ? 8 : 4;
		for (i in 0...n) {
			get(b, 0);
			m.castTo(b, m.bytesType);
			get(b, 1);
			if (i > 0) {
				i32(b, i);
				b.u8(0x6A);
			}
			get(b, 2);
			if (i > 0) {
				if (wide) {
					b.u8(0x42);
					Enc.sleb(b, 8 * i);
					b.u8(0x88);
				} else {
					i32(b, 8 * i);
					b.u8(0x76);
				}
			}
			if (wide) b.u8(0xA7);
			m.gc(b, 0x0E, m.bytesType);
		}
		return m.addHelper(name, wide ? "pil_v" : "pii_v", b, []);
	}

	// n bytes of the linear memory at p (local 2) into Bytes b (local 0) at pos (local 1)
	public static function memToBytes(m:GcModule):Int {
		var h = m.hasHelper("mem_to_bytes");
		if (h != null) return h;
		var b = new Buf();
		copyLoop(m, b, false);
		return m.addHelper("mem_to_bytes", "pili_v", b, [Enc.I32]);
	}

	// n bytes of Bytes b (local 1) at pos (local 2) into the linear memory at p (local 0)
	public static function bytesToMem(m:GcModule):Int {
		var h = m.hasHelper("bytes_to_mem");
		if (h != null) return h;
		var b = new Buf();
		copyLoop(m, b, true);
		return m.addHelper("bytes_to_mem", "lpii_v", b, [Enc.I32]);
	}

	// (a byte a step: local 4 the index)
	static function copyLoop(m:GcModule, b:Buf, toMem:Bool) {
		var bytes = toMem ? 1 : 0, pos = toMem ? 2 : 1, ptr = toMem ? 0 : 2;
		b.u8(0x02);
		b.u8(0x40);
		b.u8(0x03);
		b.u8(0x40);
		get(b, 4);
		get(b, 3);
		b.u8(0x4E); // i32.ge_s: done
		b.u8(0x0D);
		b.u8(1);
		if (toMem) {
			get(b, ptr);
			b.u8(0xA7);
			get(b, 4);
			b.u8(0x6A);
			get(b, bytes);
			m.castTo(b, m.bytesType);
			get(b, pos);
			get(b, 4);
			b.u8(0x6A);
			m.gc(b, 0x0D, m.bytesType);
			b.u8(0x3A);
			b.u8(0);
			b.u8(0);
		} else {
			get(b, bytes);
			m.castTo(b, m.bytesType);
			get(b, pos);
			get(b, 4);
			b.u8(0x6A);
			get(b, ptr);
			b.u8(0xA7);
			get(b, 4);
			b.u8(0x6A);
			b.u8(0x2D);
			b.u8(0);
			b.u8(0);
			m.gc(b, 0x0E, m.bytesType);
		}
		get(b, 4);
		i32(b, 1);
		b.u8(0x6A);
		set(b, 4);
		b.u8(0x0C);
		b.u8(0);
		b.u8(0x0B);
		b.u8(0x0B);
	}
}
