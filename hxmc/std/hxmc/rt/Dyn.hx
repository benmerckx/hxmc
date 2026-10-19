package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.rt.Types.*;
import hxmc.unsafe.Atomic;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The runtime's dynamic operations (formerly rt_dyn.c): structural and
// Dynamic access, the inline caches' lookups, Dynamic equality, comparison
// and arithmetic, type tests, Std.string of any value, and the reflection
// intrinsics behind Type and Reflect (hxmc.Native). The table of field
// names is Names; fid() puts a lock-free cache in front of it.
@:keep @:allow(hxmc.rt)
class Dyn {
	// ---- field names

	// fid of a name (interned): a direct-mapped cache of (hash, fid + 1)
	// entries outside the heap (Names.fidCache), each checked against
	// the name it claims (a racing writer leaves an old or a new entry, both
	// checked), in front of the C table
	@:hxmc.host("hx_fid") @:hxmc.noGc static function fid(name:String):Int {
		var h = Str.hash(name);
		var e = Names.fidCache.add(8 * (h & 4095));
		var v = Atomic.load64(e);
		if ((v >>> 32).toInt() == h) {
			var f = v.toInt() - 1;
			if (f >= 0 && nameIs(Names.fidName(f), name)) return f;
		}
		var f = Names.fidSlow(name);
		Atomic.store64(e, ((h : I64) << 32) | ((f + 1 : I64) & (((1 : I64) << 32) - 1)));
		return f;
	}

	// the fid of a name if it has one (not interned): -1 otherwise
	@:hxmc.noGc static function fidFind(name:String):Int
		return Names.fidFind(name);

	// whether the C string at p (UTF-8) is the string s (ASCII names only:
	// any other unit answers false, and the caller asks the C table)
	@:hxmc.noGc static function nameIs(p:Ptr, s:String):Bool {
		var n = Str.len(s);
		var c = Str.unitsAddr(s);
		for (i in 0...n) {
			var u = Mem.getU16At(c, 0, i);
			if (u >= 0x80 || Mem.getU8At(p, 0, i) != u) return false;
		}
		return Mem.getU8At(p, 0, n) == 0;
	}

	// ---- lookups (binary searches: the tables are sorted by fid)

	@:hxmc.noGc static function findField(ty:Ptr, fid:Int):Ptr {
		var lo = 0, hi = nfields(ty) - 1;
		while (lo <= hi) {
			var mid = (lo + hi) >> 1;
			var f = field(ty, mid);
			var x = fFid(f);
			if (x == fid) return f;
			if (x < fid) lo = mid + 1 else hi = mid - 1;
		}
		return Ptr.nil();
	}

	@:hxmc.noGc static function findMethod(ty:Ptr, fid:Int):Ptr {
		var lo = 0, hi = nmethods(ty) - 1;
		while (lo <= hi) {
			var mid = (lo + hi) >> 1;
			var m = method(ty, mid);
			var x = mFid(m);
			if (x == fid) return m;
			if (x < fid) lo = mid + 1 else hi = mid - 1;
		}
		return Ptr.nil();
	}

	// rt_icache (Names.hx): uint32 t, int32 slot (> 0: field slot + 1; 0: a
	// method; -1: none), char kind, void *fn, int32 sig. The C side
	// (rt_icache_miss) publishes it.
	@:hxmc.host("rt_icache_fill") @:hxmc.noGc static function icacheFill(o:Dynamic, fid:Int, c:Ptr):Void {
		var ty = ty(tindex(o));
		Mem.setPtr(c, 16, Ptr.nil());
		Mem.setI32(c, 24, -1);
		var f = findField(ty, fid);
		if (!f.isNull()) {
			Mem.setI32(c, 4, fSlot(f) + 1);
			Mem.setI8(c, 8, fKind(f));
			return;
		}
		var m = findMethod(ty, fid);
		if (!m.isNull()) {
			Mem.setI32(c, 4, 0);
			Mem.setPtr(c, 16, mFn(m));
			Mem.setI32(c, 24, mSig(m));
			Mem.setI8(c, 8, "m".code);
		} else {
			Mem.setI32(c, 4, -1);
			Mem.setI8(c, 8, 0);
		}
	}

	// ---- slots by kind ('i' Int, 'b' Bool, 'f' Float, 'l' Int64, else a
	// reference); Int/Bool slots are 4-byte indices

	static function boxSlot(o:Dynamic, slot:Int, k:Int):Dynamic {
		var p = Mem.addr(o);
		return switch k {
			case "i".code: (Mem.getI32(p, 4 * slot) : Dynamic);
			case "b".code: (Mem.getI32(p, 4 * slot) != 0 : Dynamic);
			case "f".code: (Mem.getF64(p, 8 * slot) : Dynamic);
			case "l".code: (Mem.getI64(p, 8 * slot) : Dynamic);
			case _: Mem.getRef(p, 8 * slot);
		}
	}

	static function storeSlot(o:Dynamic, slot:Int, k:Int, v:Dynamic):Void {
		switch k {
			case "i".code:
				var x:Int = v;
				Mem.setI32(Mem.addr(o), 4 * slot, x);
			case "b".code:
				var x:Bool = v;
				Mem.setI32(Mem.addr(o), 4 * slot, x ? 1 : 0);
			case "f".code:
				var x:Float = v;
				Mem.setF64(Mem.addr(o), 8 * slot, x);
			case "l".code:
				var x:I64 = v;
				Mem.setI64(Mem.addr(o), 8 * slot, x);
			case _:
				Mem.setRefBarrier(o, 8 * slot, v);
		}
	}

	// a closure over `o` calling method m (TK_BOUND: code, this, fn)
	static function boundMethod(o:Dynamic, m:Ptr):Dynamic {
		var sig = mSig(m), fn = mFn(m);
		var c = Mem.alloc(3, Mem.getI32At(Mem.sym("rt_bound_types"), 0, sig), K_OBJ);
		var p = Mem.addr(c);
		Mem.setPtr(p, 0, Mem.getPtr(Mem.sym("rt_bound_tramps"), 8 * sig));
		Mem.setRef(p, 8, o);
		Mem.setPtr(p, 16, fn);
		return c;
	}

	// ---- dynamic fields of anonymous objects: slot 0 holds (fid box, value) pairs

	static function overflowFind(o:Dynamic, fid:Int):Int {
		if (tk(ty(tindex(o))) != TK_ANON) return -1;
		var ov = Mem.getRef(Mem.addr(o), 0);
		if (Str.isNull(ov)) return -1;
		var n = nslots(ov);
		var i = 0;
		while (i + 1 < n) {
			var k = Mem.getRefAt(Mem.addr(ov), 0, i);
			if (!Str.isNull(k)) {
				var kf:Int = k;
				if (kf == fid) return i;
			}
			i += 2;
		}
		return -1;
	}

	static function overflowSet(o:Dynamic, fid:Int, v:Dynamic):Void {
		if (tk(ty(tindex(o))) != TK_ANON) Rt.rt_throw("Cannot add a field to this object");
		var i = overflowFind(o, fid);
		if (i >= 0) {
			Mem.setRefBarrier(Mem.getRef(Mem.addr(o), 0), 8 * (i + 1), v);
			return;
		}
		var ov = Mem.getRef(Mem.addr(o), 0);
		var n = Str.isNull(ov) ? 0 : nslots(ov);
		var key:Dynamic = fid;
		var nv = Mem.alloc(n + 2, T_OVERFLOW, K_PARR);
		ov = Mem.getRef(Mem.addr(o), 0);
		for (k in 0...n)
			Mem.setRefBarrier(nv, 8 * k, Mem.getRefAt(Mem.addr(ov), 0, k));
		Mem.setRefBarrier(nv, 8 * n, key);
		Mem.setRefBarrier(nv, 8 * (n + 1), v);
		Mem.setRefBarrier(o, 0, nv);
	}

	// ---- statics reached through a class value

	static function findStatic(o:Dynamic, fid:Int):Ptr {
		if (tindex(o) != T_TYPEOBJ) return Ptr.nil();
		var t = ty(described(o));
		var lo = 0, hi = nstatics(t);
		while (lo < hi) {
			var mid = (lo + hi) >> 1;
			var s = stat(t, mid);
			var f = Mem.getI32(s, 0);
			if (f == fid) return s;
			if (f < fid) lo = mid + 1 else hi = mid;
		}
		return Ptr.nil();
	}

	static function staticGet(s:Ptr):Dynamic {
		var ptr = Mem.getPtr(s, 16);
		return switch Mem.getU8(s, 4) {
			case "c".code:
				var c = Mem.alloc(1, Mem.getI32(s, 8), K_OBJ);
				Mem.setPtr(Mem.addr(c), 0, ptr);
				c;
			case "p".code: Mem.getRef(globalSlot(Mem.getI32(s, 8)), 0);
			case "i".code: (Mem.getI32(ptr, 0) : Dynamic);
			case "b".code: (Mem.getI32(ptr, 0) != 0 : Dynamic);
			case "f".code: (Mem.getF64(ptr, 0) : Dynamic);
			case "l".code: (Mem.getI64(ptr, 0) : Dynamic);
			case _: null;
		}
	}

	static function staticSet(s:Ptr, v:Dynamic):Void {
		var ptr = Mem.getPtr(s, 16);
		switch Mem.getU8(s, 4) {
			case "c".code:
				Rt.rt_throw("Cannot rebind this method");
			case "p".code:
				Mem.setRef(globalSlot(Mem.getI32(s, 8)), 0, v);
			case "i".code:
				var x:Int = v;
				Mem.setI32(ptr, 0, x);
			case "b".code:
				var x:Bool = v;
				Mem.setI32(ptr, 0, x ? 1 : 0);
			case "f".code:
				var x:Float = v;
				Mem.setF64(ptr, 0, x);
			case "l".code:
				var x:I64 = v;
				Mem.setI64(ptr, 0, x);
			case _:
		}
	}

	// ---- structural access, the inline caches' slow paths

	static var fidLength = 0; // fid of "length" + 1 (0: not looked up yet)

	@:hxmc.noGc static function isLength(fid:Int):Bool {
		if (fidLength == 0) fidLength = fidFind("length") + 1;
		return fid == fidLength - 1;
	}

	@:hxmc.export("hx_anon_get_slow") static function anonGetSlow(o:Dynamic, fid:Int):Dynamic {
		if (Str.isNull(o)) Rt.rt_throw("Null access");
		var st = findStatic(o, fid);
		if (!st.isNull()) return staticGet(st);
		var t = tindex(o);
		if (t == T_STRING && isLength(fid)) return (Str.len(o) : Dynamic);
		if (t == T_ARRAY && isLength(fid)) return ((o : Array<Dynamic>).length : Dynamic);
		if (t == T_NATIVE_ARRAY && isLength(fid)) return (Mem.getI32(Mem.addr(o), 0) : Dynamic);
		if (t == T_NATIVE_ARRAY) return null;
		var ty = ty(t);
		var f = findField(ty, fid);
		if (!f.isNull()) return boxSlot(o, fSlot(f), fKind(f));
		var m = findMethod(ty, fid);
		if (!m.isNull()) return boundMethod(o, m);
		var i = overflowFind(o, fid);
		return i >= 0 ? Mem.getRefAt(Mem.addr(Mem.getRef(Mem.addr(o), 0)), 0, i + 1) : null;
	}

	@:hxmc.export("hx_anon_set_slow") static function anonSetSlow(o:Dynamic, fid:Int, v:Dynamic):Void {
		if (Str.isNull(o)) Rt.rt_throw("Null access");
		if (tindex(o) == T_ARRAY && isLength(fid)) {
			// Array length assignment resizes the array.
			var n:Int = v;
			(o : Array<Dynamic>).resize(n);
			return;
		}
		if (tindex(o) == T_NATIVE_ARRAY) Rt.rt_throw("NativeArray fields are read-only");
		var st = findStatic(o, fid);
		if (!st.isNull()) {
			staticSet(st, v);
			return;
		}
		var f = findField(ty(tindex(o)), fid);
		if (!f.isNull()) storeSlot(o, fSlot(f), fKind(f), v) else overflowSet(o, fid, v);
	}

	// the signature of a closure, or -1
	static function closureSig(c:Dynamic):Int {
		if (Str.isNull(c) || tindex(c) < T_FIRST) return -1;
		var t = ty(tindex(c));
		var k = tk(t);
		return k == TK_CLOSURE || k == TK_BOUND ? sup(t) : -1;
	}

	// c when it is a closure of the signature key (as rt_sig_keys has it), else
	// null: a Dynamic converted to a function type keeps such a closure and
	// wraps any other value in an adapter that calls it dynamically
	// (FnLower.coerce)
	@:hxmc.host("hx_clos_of_sig") static function closOfSig(c:Dynamic, key:String):Dynamic {
		var s = closureSig(c);
		if (s < 0) return null;
		var k = Mem.getPtr(Mem.sym("rt_sig_keys"), 8 * s);
		var n = key.length;
		for (i in 0...n)
			if (Mem.getU8At(k, 0, i) != StringTools.fastCodeAt(key, i)) return null;
		return Mem.getU8At(k, 0, n) == 0 ? c : null;
	}

	// the argument count of signature s: the characters of its key before '_'
	static function sigArgs(s:Int):Int {
		var k = Mem.getPtr(Mem.sym("rt_sig_keys"), 8 * s);
		var n = 0;
		while (Mem.getU8At(k, 0, n) != "_".code)
			n++;
		return n;
	}

	static inline function sigRet(s:Int):Int {
		var k = Mem.getPtr(Mem.sym("rt_sig_keys"), 8 * s);
		return Mem.getU8At(k, 0, sigArgs(s) + 1);
	}

	// calls a closure with boxed arguments (args[0...n], missing ones null)
	static function callBoxed(f:Dynamic, args:Array<Dynamic>, n:Int):Dynamic {
		var s = closureSig(f);
		if (s < 0) Rt.rt_throw("Cannot call a non-function");
		var want = sigArgs(s);
		if (want > 16) want = 16;
		// the arguments boxed (reading an Int or Float array boxes) into a
		// reference array first, then copied without a GC point into the
		// frame area the generated dyncall reads (it unboxes them before
		// anything can collect)
		var refs:Array<Dynamic> = [];
		refs.resize(want);
		for (i in 0...(n < want ? n : want))
			refs[i] = args[i];
		var buf = Mem.stack(128);
		if (want > 0) {
			var d = Mem.getPtr(Mem.addr(refs), 8);
			for (i in 0...want)
				Mem.setPtr(buf, 8 * i, Mem.getPtr(d, 8 * i));
		}
		return Mem.callRef2(Mem.getPtr(Mem.sym("rt_dyncalls"), 8 * s), f, buf);
	}

	static function fromBoxed(v:Dynamic, k:Int):I64 {
		return switch k {
			case "i".code:
				var x:Int = v;
				(x : I64) & (((1 : I64) << 32) - 1);
			case "b".code:
				var x:Bool = v;
				x ? 1 : 0;
			case "f".code:
				var x:Float = v;
				var p = Mem.stack(8);
				Mem.setF64(p, 0, x);
				Mem.getI64(p, 0);
			case "l".code:
				var x:I64 = v;
				x;
			case "v".code: 0;
			case _: Mem.addr(v).toI64();
		}
	}

	@:hxmc.export("hx_arrayiter_hasNext") @:hxmc.noGc static function arrayIterHasNext(it:Dynamic):Bool {
		var p = Mem.addr(it);
		return Mem.getI32(p, 8) < Mem.getI32(Mem.getPtr(p, 0), 0);
	}

	@:hxmc.export("hx_arrayiter_next") static function arrayIterNext(it:Dynamic):Dynamic {
		var p = Mem.addr(it);
		var i = Mem.getI32(p, 8);
		Mem.setI32(p, 8, i + 1);
		return (Mem.getRef(p, 0) : Array<Dynamic>)[i];
	}

	@:hxmc.export("hx_array_iterator") static function arrayIterator(a:Dynamic):Dynamic {
		var it = Mem.alloc(2, T_ARRAYITER, K_OBJ);
		Mem.setRef(Mem.addr(it), 0, a); // it is young
		return it;
	}

	// obj.name(args) through a structural type, slow path: the arguments
	// packed in 8-byte words (MirBuild.callAnon), the result likewise
	@:hxmc.export("hx_anon_call_slow") static function anonCallSlow(o:Dynamic, fid:Int, sig:Int, args:Ptr):I64 {
		var n = sigArgs(sig);
		var k = Mem.getPtr(Mem.sym("rt_sig_keys"), 8 * sig);
		var rk = Mem.getU8At(k, 0, n + 1);
		// the arguments boxed into an array: the references first (no GC
		// point while they are read from the caller's words), then the
		// scalars (boxing allocates)
		var boxed:Array<Dynamic> = [];
		boxed.resize(n);
		for (i in 0...n) {
			var c = Mem.getU8At(k, 0, i);
			if (c != "i".code && c != "b".code && c != "f".code && c != "l".code) boxed[i] = Mem.obj(Mem.getPtr(args, 8 * i));
		}
		for (i in 0...n) {
			var w = Mem.getI64At(args, 0, i);
			switch Mem.getU8At(k, 0, i) {
				case "i".code:
					boxed[i] = w.toInt();
				case "b".code:
					boxed[i] = w.toInt() != 0;
				case "f".code:
					var p = Mem.stack(8);
					Mem.setI64(p, 0, w);
					boxed[i] = Mem.getF64(p, 0);
				case "l".code:
					boxed[i] = w;
				case _:
			}
		}
		var r:Dynamic = Str.isNull(o) ? NOT_BUILTIN : callBuiltin(o, Names.fidStr(fid), boxed, n);
		if (isNotBuiltin(r)) r = callBoxed(anonGetSlow(o, fid), boxed, n);
		return fromBoxed(r, rk);
	}

	// ---- Dynamic access

	@:hxmc.export("hx_dyn_get") static function dynGet(o:Dynamic, name:String):Dynamic {
		if (Str.isNull(o)) Rt.rt_throw("Null access");
		var t = tindex(o);
		if (Str.len(name) == 6 && name == "length") {
			if (t == T_STRING) return (Str.len(o) : Dynamic);
			if (t == T_ARRAY) return ((o : Array<Dynamic>).length : Dynamic);
			if (t == T_NATIVE_ARRAY) return (Mem.getI32(Mem.addr(o), 0) : Dynamic);
		}
		return anonGetSlow(o, fid(name));
	}

	@:hxmc.export("hx_dyn_set") static function dynSet(o:Dynamic, name:String, v:Dynamic):Void
		anonSetSlow(o, fid(name), v);

	@:hxmc.host("hx_dyn_call") static function dynCall(f:Dynamic, args:Array<Dynamic>):Dynamic {
		if (Str.isNull(args)) return callBoxed(f, [], 0);
		// a copy: the callee may change the array
		var a = args.copy();
		return callBoxed(f, a, a.length);
	}

	// callBuiltin's answer when the name is not a built-in method (a static
	// string: its identity is unique)
	static inline var NOT_BUILTIN = "\x00not a built-in method";

	static inline function isNotBuiltin(r:Dynamic):Bool
		return Mem.addr(r) == Mem.addr(NOT_BUILTIN);

	// a method of the runtime's built-in values (Array, String) called
	// through Dynamic: its result, or NOT_BUILTIN
	static function callBuiltin(o:Dynamic, nm:String, args:Array<Dynamic>, n:Int):Dynamic {
		var t = tindex(o);
		if (t != T_ARRAY && t != T_STRING) return NOT_BUILTIN;
		var a0:Dynamic = n > 0 ? args[0] : null, a1:Dynamic = n > 1 ? args[1] : null;
		var r:Dynamic = null;
		if (t == T_STRING) {
			var s:String = o;
			switch nm {
				case "charAt": r = Str.charAt(s, a0);
				case "charCodeAt": r = Str.charCodeAt(s, a0);
				case "indexOf": r = Str.indexOf(s, a0, a1);
				case "lastIndexOf": r = Str.lastIndexOf(s, a0, a1);
				case "substr": r = Str.substr(s, a0, a1);
				case "substring": r = Str.substring(s, a0, a1);
				case "toLowerCase": r = Str.toLowerCase(s);
				case "toUpperCase": r = Str.toUpperCase(s);
				case "toString": r = s;
				case "split": r = Str.split(s, a0);
				case _: return NOT_BUILTIN;
			}
			return r;
		}
		var a:Array<Dynamic> = o;
		switch nm {
			case "join": r = a.join(a0);
			case "push": r = a.push(a0);
			case "pop": r = a.pop();
			case "shift": r = a.shift();
			case "copy": r = a.copy();
			case "concat": r = a.concat(a0);
			case "indexOf": r = a.indexOf(a0, a1);
			case "lastIndexOf": r = a.lastIndexOf(a0, a1);
			case "contains": r = a.contains(a0);
			case "remove": r = a.remove(a0);
			case "insert": a.insert(a0, a1);
			case "unshift": a.unshift(a0);
			case "reverse": a.reverse();
			case "slice": r = a.slice(a0, a1);
			case "splice": r = a.splice(a0, a1);
			case "toString": r = a.toString();
			case "sort": a.sort(a0);
			case "filter": r = a.filter(a0);
			case "map": r = a.map(a0);
			case "iterator": r = arrayIterator(a);
			case _: return NOT_BUILTIN;
		}
		return r;
	}

	@:hxmc.export("hx_dyn_call_field") static function dynCallField(o:Dynamic, name:String, args:Array<Dynamic>):Dynamic {
		var t = Str.isNull(o) ? 0 : tindex(o);
		if ((t == T_ARRAY || t == T_STRING) && Str.len(name) < 30) {
			var a = Str.isNull(args) ? [] : args.copy();
			var r = callBuiltin(o, name, a, a.length);
			if (!isNotBuiltin(r)) return r;
		}
		var f = dynGet(o, name);
		return dynCall(f, args);
	}

	// by field id (a literal name: no interning at run time)
	@:hxmc.host("hx_dyn_get_fid") static function dynGetFid(o:Dynamic, fid:Int):Dynamic
		return anonGetSlow(o, fid);

	@:hxmc.host("hx_dyn_set_fid") static function dynSetFid(o:Dynamic, fid:Int, v:Dynamic):Void
		anonSetSlow(o, fid, v);

	@:hxmc.host("hx_dyn_call_field_fid") static function dynCallFieldFid(o:Dynamic, fid:Int, args:Array<Dynamic>):Dynamic {
		var t = Str.isNull(o) ? 0 : tindex(o);
		if (t == T_ARRAY || t == T_STRING) {
			var a = Str.isNull(args) ? [] : args.copy();
			var r = callBuiltin(o, Names.fidStr(fid), a, a.length);
			if (!isNotBuiltin(r)) return r;
		}
		var f = anonGetSlow(o, fid);
		return dynCall(f, args);
	}

	// a NativeArray's index out of bounds by Dynamic access: as -D
	// hxmc.native-array-outofbounds says for typed access (FnLower.nativeRead;
	// silent: the default of the storage's kind), an error when it is not defined
	@:hxmc.host("hx_dyn_aget") static function dynAget(a:Dynamic, i:Int):Dynamic {
		if (!Str.isNull(a) && tindex(a) == T_NATIVE_ARRAY) {
			var n = Mem.getI32(Mem.addr(a), 0);
			if (!Mem.ult(i, n)) {
				#if (hxmc.native_array_outofbounds == "silent")
				return NArray.defaultOf(a);
				#elseif (hxmc.native_array_outofbounds == "throws")
				throw NArray.outOfBounds(i, n, null, 0, null, null);
				#else
				Rt.rt_throw("Invalid NativeArray index");
				#end
			}
			return NArray.get(a, i);
		}
		if (Str.isNull(a) || tindex(a) != T_ARRAY) return null;
		return (a : Array<Dynamic>)[i];
	}

	@:hxmc.host("hx_dyn_aset") static function dynAset(a:Dynamic, i:Int, v:Dynamic):Void {
		if (!Str.isNull(a) && tindex(a) == T_NATIVE_ARRAY) {
			var n = Mem.getI32(Mem.addr(a), 0);
			if (!Mem.ult(i, n)) {
				#if (hxmc.native_array_outofbounds == "silent")
				return;
				#elseif (hxmc.native_array_outofbounds == "throws")
				throw NArray.outOfBounds(i, n, null, 0, null, null);
				#else
				Rt.rt_throw("Invalid NativeArray index");
				#end
			}
			NArray.set(a, i, v);
			return;
		}
		if (Str.isNull(a) || tindex(a) != T_ARRAY) Rt.rt_throw("Invalid array access");
		var arr:Array<Dynamic> = a;
		arr[i] = v;
	}

	// ---- equality, comparison, arithmetic

	static inline function isNum(v:Dynamic):Bool {
		if (Str.isNull(v)) return false;
		var t = tindex(v);
		return t == T_BOXINT || t == T_BOXFLOAT;
	}

	static inline function isI64(v:Dynamic):Bool {
		if (Str.isNull(v)) return false;
		var t = tindex(v);
		return t == T_BOXI64 || t == T_BOXINT;
	}

	@:hxmc.noGc public static function isInt64(v:Dynamic):Bool
		return !Str.isNull(v) && tindex(v) == T_BOXI64;

	@:hxmc.host("hx_dyn_eq") @:hxmc.noGc static function dynEq(a:Dynamic, b:Dynamic):Bool {
		if (Mem.addr(a) == Mem.addr(b)) return true;
		if (Str.isNull(a) || Str.isNull(b)) return false;
		var ta = tindex(a), tb = tindex(b);
		if ((ta == T_BOXI64 || tb == T_BOXI64) && isI64(a) && isI64(b)) return unboxI64(a) == unboxI64(b);
		if (isNum(a) && isNum(b)) return unboxFloat(a) == unboxFloat(b);
		if (ta == T_BOXBOOL && tb == T_BOXBOOL) return Mem.getI32(Mem.addr(a), 0) == Mem.getI32(Mem.addr(b), 0);
		if (ta == T_STRING && tb == T_STRING) return Str.len(a) == Str.len(b) && Str.eqSlow(a, b);
		if (ta == T_TYPEOBJ && tb == T_TYPEOBJ) return described(a) == described(b);
		return false;
	}

	// the unboxings (no GC point)
	@:hxmc.noGc static function unboxI64(v:Dynamic):I64 {
		var p = Mem.addr(v);
		return switch tindex(v) {
			case T_BOXINT | T_BOXBOOL: (Mem.getI32(p, 0) : I64);
			case T_BOXFLOAT: f2l(Mem.getF64(p, 0));
			case T_BOXI64: Mem.getI64(p, 0);
			case _: 0;
		}
	}

	@:hxmc.noGc static inline function f2l(f:Float):I64 {
		// (the conversion of the language: NaN 0, saturating)
		var x:I64 = cast f;
		return x;
	}

	@:hxmc.noGc static function unboxFloat(v:Dynamic):Float {
		var p = Mem.addr(v);
		return switch tindex(v) {
			case T_BOXINT | T_BOXBOOL: Mem.getI32(p, 0);
			case T_BOXFLOAT: Mem.getF64(p, 0);
			case T_BOXI64:
				var x:Float = cast Mem.getI64(p, 0);
				x;
			case _: 0;
		}
	}

	@:hxmc.host("hx_dyn_cmp") @:hxmc.noGc static function dynCmp(a:Dynamic, b:Dynamic):Int {
		if (!Str.isNull(a) && !Str.isNull(b) && (tindex(a) == T_BOXI64 || tindex(b) == T_BOXI64) && isI64(a) && isI64(b)) {
			var x = unboxI64(a), y = unboxI64(b);
			return x < y ? -1 : x > y ? 1 : 0;
		}
		if (isNum(a) && isNum(b)) {
			var x = unboxFloat(a), y = unboxFloat(b);
			return x < y ? -1 : x > y ? 1 : 0;
		}
		if (!Str.isNull(a) && !Str.isNull(b) && tindex(a) == T_STRING && tindex(b) == T_STRING) return Str.cmp(a, b);
		if (Mem.addr(a) == Mem.addr(b)) return 0;
		return Str.isNull(a) ? -1 : 1;
	}

	@:hxmc.noGc public static function compare(a:Dynamic, b:Dynamic):Int
		return dynCmp(a, b);

	// a op b on Dynamic values (FnLower.opCode: 0 + 1 - 2 * 3 / 4 % 5 & 6 | 7 ^ 8 << 9 >> 10 >>>)
	@:hxmc.host("hx_dyn_op") static function dynOp(op:Int, a:Dynamic, b:Dynamic):Dynamic {
		if (op == 0 && ((!Str.isNull(a) && tindex(a) == T_STRING) || (!Str.isNull(b) && tindex(b) == T_STRING)))
			return Str.concat(stdString(a), stdString(b));
		var ints = !Str.isNull(a) && !Str.isNull(b) && tindex(a) != T_BOXFLOAT && tindex(b) != T_BOXFLOAT;
		if (op >= 5 || (ints && op != 3)) {
			var x:Int = a, y:Int = b;
			var r = switch op {
				case 0: x + y;
				case 1: x - y;
				case 2: x * y;
				case 4: x % y;
				case 5: x & y;
				case 6: x | y;
				case 7: x ^ y;
				case 8: x << y;
				case 9: x >> y;
				case 10: x >>> y;
				case _: 0;
			}
			return (r : Dynamic);
		}
		var x:Float = a, y:Float = b;
		var r = switch op {
			case 0: x + y;
			case 1: x - y;
			case 2: x * y;
			case 3: x / y;
			case 4: x % y;
			case _: 0.0;
		}
		return (r : Dynamic);
	}

	// ---- type tests

	@:hxmc.noGc static function classExtends(t:Int, c:Int):Bool {
		while (t >= 0) {
			if (t == c) return true;
			t = sup(ty(t));
		}
		return false;
	}

	@:hxmc.noGc static function implementsIface(t:Int, i:Int):Bool {
		var ty = ty(t);
		for (k in 0...nifaces(ty))
			if (iface(ty, k) == i) return true;
		return false;
	}

	@:hxmc.host("hx_is") @:hxmc.noGc static function is(v:Dynamic, type:Dynamic):Bool {
		if (Str.isNull(v) || Str.isNull(type)) return false;
		var c = described(type);
		var t = tindex(v);
		switch c {
			case T_NONE:
				return true; // Dynamic
			case T_BOXINT:
				if (t == T_BOXINT) return true;
				if (t != T_BOXFLOAT) return false;
				var f = Mem.getF64(Mem.addr(v), 0);
				return f == Math.ffloor(f) && Math.abs(f) < 2147483648.0;
			case T_BOXFLOAT:
				return t == T_BOXINT || t == T_BOXFLOAT;
			case T_BOXBOOL | T_STRING | T_ARRAY | T_BYTES | T_NATIVE_ARRAY:
				return t == c;
			case _:
		}
		if (c >= T_FIRST) {
			var ct = tk(ty(c));
			if (ct == TK_CLASS) return t >= T_FIRST && tk(ty(t)) == TK_CLASS && classExtends(t, c);
			if (ct == TK_INTERFACE) return t >= T_FIRST && tk(ty(t)) == TK_CLASS && implementsIface(t, c);
			if (ct == TK_ENUM) return t >= T_FIRST && tk(ty(t)) == TK_CTOR && sup(ty(t)) == c;
		}
		return false;
	}

	@:hxmc.host("hx_cast") static function cast_(v:Dynamic, type:Dynamic):Dynamic {
		if (Str.isNull(v) || is(v, type)) return v;
		Rt.rt_throw("Class cast error");
		return null;
	}

	@:hxmc.host("Std_isOfType") @:hxmc.noGc static function isOfType(v:Dynamic, t:Dynamic):Bool
		return is(v, t);

	// Std.isOfType(v, Class) (kind 0: a type object, not an enum's), (v, Enum) (1)
	@:hxmc.host("hx_is_typeobj") @:hxmc.noGc static function isTypeObject(v:Dynamic, kind:Int):Bool {
		if (Str.isNull(v) || tindex(v) != T_TYPEOBJ) return false;
		var enum_ = described(v) >= T_FIRST && tk(ty(described(v))) == TK_ENUM;
		return kind == 1 ? enum_ : !enum_;
	}

	@:hxmc.host("Std_downcast") @:hxmc.noGc static function downcast(v:Dynamic, t:Dynamic):Dynamic
		return is(v, t) ? v : null;

	// ---- Std.string

	@:hxmc.host("Std_string") static function std(v:Dynamic):String
		return stdString(v);

	static var fidToString = 0; // fid of "toString" + 1 (0: not looked up yet; -1 + 1: not a field name)

	@:hxmc.host("hx_std_string") static function stdString(v:Dynamic):String {
		if (Str.isNull(v)) return "null";
		var t = tindex(v);
		var p = Mem.addr(v);
		switch t {
			case T_STRING:
				return v;
			case T_BOXINT:
				return Str.ofInt(Mem.getI32(p, 0));
			case T_BOXFLOAT:
				return Str.ofFloat(Mem.getF64(p, 0));
			case T_BOXI64:
				return Str.ofI64(Mem.getI64(p, 0));
			case T_BOXBOOL:
				return Mem.getI32(p, 0) != 0 ? "true" : "false";
			case T_TYPEOBJ:
				return Str.ofAscii(name(ty(described(v))));
			case T_ARRAY:
				var a:Array<Dynamic> = v;
				var b = new StringBuf();
				b.addChar("[".code);
				var i = 0;
				while (i < a.length) {
					if (i > 0) b.addChar(",".code);
					b.add(stdString(a[i]));
					i++;
				}
				b.addChar("]".code);
				return b.toString();
			case _:
		}
		var ty = ty(t);
		if (t < T_FIRST) return Str.ofAscii(name(ty));
		switch tk(ty) {
			case TK_CTOR:
				// Name(p1,p2)
				var b = new StringBuf();
				b.add(Str.ofAscii(name(ty)));
				var np = slotCount(ty);
				if (np > 0) {
					b.addChar("(".code);
					for (i in 0...np) {
						if (i > 0) b.addChar(",".code);
						var k = "p".code;
						for (f in 0...nfields(ty)) {
							var fk = fKind(field(ty, f));
							if (fSlot(field(ty, f)) == (fk == "i".code || fk == "b".code ? 2 * i : i)) k = fk;
						}
						var x:Dynamic = switch k {
							case "i".code: (Mem.getI32(Mem.addr(v), 8 * i) : Dynamic);
							case "b".code: (Mem.getI32(Mem.addr(v), 8 * i) != 0 : Dynamic);
							case "f".code: (Mem.getF64(Mem.addr(v), 8 * i) : Dynamic);
							case _: Mem.getRef(Mem.addr(v), 8 * i);
						}
						b.add(stdString(x));
					}
					b.addChar(")".code);
				}
				return b.toString();
			case TK_CLASS:
				if (fidToString == 0) fidToString = fidFind("toString") + 1;
				var f = fidToString - 1;
				if (f >= 0) {
					var m = findMethod(ty, f);
					if (!m.isNull()) return Mem.callRef1(mFn(m), v);
				}
				return Str.ofAscii(name(ty));
			case TK_ANON:
				return anonToString(v);
			case TK_CLOSURE | TK_BOUND:
				return "<function>";
			case _:
				return Str.ofAscii(name(ty));
		}
	}

	// { a : 1, b : 2 }
	static function anonToString(o:Dynamic):String {
		var ty = ty(tindex(o));
		var b = new StringBuf();
		b.addChar("{".code);
		var n = nfields(ty);
		for (i in 0...n) {
			b.add(i == 0 ? " " : ", ");
			var f = field(ty, i);
			b.add(Names.fidStr(fFid(f)));
			b.add(" : ");
			f = field(ty, i);
			b.add(stdString(boxSlot(o, fSlot(f), fKind(f))));
		}
		b.add(n > 0 ? " }" : "}");
		return b.toString();
	}

	// ---- hxmc.Native: reflection

	// identity hash in the header's top 16 bits, set once (a CAS: another
	// thread may set it at the same time; the collector only runs with every
	// thread stopped). The seed is thread-local.
	@:hxmc.threadLocal static var hashSeed:Int;

	// the running thread's id (hxmc.NativeThread.current, without typing the threads' API)
	@:hxmc.noGc static inline function threadId():Int
		return #if (hxmc.target == "wasm32-wasi") hxmc.rt.wasm.Threads.current() #else Threads.current() #end;

	@:hxmc.noGc public static function objHash(o:Dynamic):Int {
		if (Str.isNull(o)) return 0;
		var hp = Mem.addr(o).add(-8);
		var h = Mem.getU16(hp, 6);
		if (h == 0) {
			var seed = hashSeed;
			if (seed == 0) seed = 0x9E37 + 0x10000 * (threadId() - 1); // the main thread's sequence is the single-threaded one
			seed = seed * 1103515245 + 12345;
			hashSeed = seed;
			h = (seed >>> 16) & 0xFFFF;
			if (h == 0) h = 1;
			var old = Atomic.load64(hp);
			while ((old >>> 48).toInt() == 0) {
				var seen = Atomic.cas64(hp, old, old | ((h : I64) << 48));
				if (seen == old) break;
				old = seen;
			}
			var got = (old >>> 48).toInt();
			if (got != 0) h = got;
		}
		return h * (0x9E3779B1 : Int);
	}

	@:hxmc.noGc public static function refEq(a:Dynamic, b:Dynamic):Bool
		return Mem.addr(a) == Mem.addr(b);

	// 0 null, 1 Int, 2 Float, 3 Bool, 4 anonymous object, 5 function, 6 class
	// instance, 7 enum value, 8 String, 9 Array, 10 a type object, 11 other
	@:hxmc.noGc public static function typeKind(v:Dynamic):Int {
		if (Str.isNull(v)) return 0;
		var t = tindex(v);
		switch t {
			case T_BOXINT:
				return 1;
			case T_BOXFLOAT:
				return 2;
			case T_BOXBOOL:
				return 3;
			case T_STRING:
				return 8;
			case T_ARRAY:
				return 9;
			case T_TYPEOBJ:
				return 10;
			case _:
		}
		if (t < T_FIRST) return 11;
		return switch tk(ty(t)) {
			case TK_ANON: 4;
			case TK_CLOSURE | TK_BOUND: 5;
			case TK_CLASS: 6;
			case TK_CTOR: 7;
			case _: 11;
		}
	}

	@:hxmc.noGc public static function getClass(v:Dynamic):Dynamic {
		if (Str.isNull(v)) return null;
		var t = tindex(v);
		if (t == T_STRING || t == T_ARRAY) return typeObj(t);
		if (t >= T_FIRST && tk(ty(t)) == TK_CLASS) return typeObj(t);
		return null;
	}

	@:hxmc.noGc public static function getEnum(v:Dynamic):Dynamic {
		if (Str.isNull(v)) return null;
		var t = tindex(v);
		if (t >= T_FIRST && tk(ty(t)) == TK_CTOR) return typeObj(sup(ty(t)));
		return null;
	}

	@:hxmc.noGc public static function superClass(c:Dynamic):Dynamic {
		var t = ty(described(c));
		var s = sup(t);
		return s >= 0 && tk(t) == TK_CLASS ? typeObj(s) : null;
	}

	public static function typeName(t:Dynamic):String
		return Str.ofAscii(name(ty(described(t))));

	public static function resolveType(n:String):Dynamic {
		var c = Str.toUtf8(n);
		var r:Dynamic = null;
		var nt = Mem.getI32(Mem.sym("rt_ntypes"), 0);
		for (t in T_FIRST...nt) {
			var k = tk(ty(t));
			if ((k == TK_CLASS || k == TK_ENUM) && LibC.strcmp(name(ty(t)), c) == 0) {
				r = typeObj(t);
				break;
			}
		}
		LibC.free(c);
		if (Str.isNull(r) && n == "String") r = typeObj(T_STRING);
		return r;
	}

	public static function createEmpty(c:Dynamic):Dynamic {
		var t = described(c);
		var n = slotCount(ty(t));
		return Mem.alloc(n > 0 ? n : 1, t, K_OBJ);
	}

	public static function enumCtorNames(e:Dynamic):Array<String> {
		var t = described(e);
		var ty = ty(t);
		if (tk(ty) != TK_ENUM) return null;
		var a:Array<String> = [];
		for (i in 0...tag(ty))
			a.push(Str.ofAscii(name(Types.ty(ctor(Types.ty(t), i)))));
		return a;
	}

	// the position of an enum constructor's argument (its slot: no packing)
	static inline function ctorArg(f:Ptr):Int {
		var k = fKind(f);
		return k == "i".code || k == "b".code ? fSlot(f) >> 1 : fSlot(f);
	}

	public static function enumCreate(e:Dynamic, index:Int, params:Array<Dynamic>):Dynamic {
		var t = described(e);
		if (tk(ty(t)) != TK_ENUM || index < 0 || index >= tag(ty(t))) Rt.rt_throw("Invalid enum constructor");
		var ct = ctor(ty(t), index);
		// (its own value: `==` to the constructor)
		var g = single(ty(ct));
		if (g >= 0) return Mem.getRef(globalSlot(g), 0);
		var n = slotCount(ty(ct));
		var o = Mem.alloc(n > 0 ? n : 1, ct, K_OBJ);
		for (i in 0...nfields(ty(ct))) {
			var f = field(ty(ct), i);
			var v:Dynamic = Str.isNull(params) ? null : params[ctorArg(f)];
			f = field(ty(ct), i);
			storeSlot(o, fSlot(f), fKind(f), v);
		}
		return o;
	}

	@:hxmc.noGc public static function enumIndex(v:Dynamic):Int
		return tag(ty(tindex(v)));

	public static function enumCtorName(v:Dynamic):String
		return Str.ofAscii(name(ty(tindex(v))));

	public static function enumParams(v:Dynamic):Array<Dynamic> {
		var t = tindex(v);
		var a:Array<Dynamic> = [];
		a.resize(slotCount(ty(t)));
		for (i in 0...nfields(ty(t))) {
			var f = field(ty(t), i);
			var b = boxSlot(v, fSlot(f), fKind(f));
			a[ctorArg(field(ty(t), i))] = b;
		}
		return a;
	}

	public static function enumEq(a:Dynamic, b:Dynamic):Bool {
		if (Mem.addr(a) == Mem.addr(b)) return true;
		if (Str.isNull(a) || Str.isNull(b) || tindex(a) != tindex(b)) return false;
		var ty = ty(tindex(a));
		if (tk(ty) != TK_CTOR) return false;
		for (i in 0...nfields(ty)) {
			var f = field(ty, i);
			var s = fSlot(f);
			var pa = Mem.addr(a), pb = Mem.addr(b);
			switch fKind(f) {
				case "i".code | "b".code:
					if (Mem.getI32(pa, 4 * s) != Mem.getI32(pb, 4 * s)) return false;
				case "f".code:
					if (Mem.getF64(pa, 8 * s) != Mem.getF64(pb, 8 * s)) return false;
				case "l".code:
					if (Mem.getI64(pa, 8 * s) != Mem.getI64(pb, 8 * s)) return false;
				case _:
					var x = Mem.getRef(pa, 8 * s), y = Mem.getRef(pb, 8 * s);
					if (Mem.addr(x) == Mem.addr(y)) continue;
					if (!Str.isNull(x) && !Str.isNull(y) && tindex(x) >= T_FIRST && tk(Types.ty(tindex(x))) == TK_CTOR) {
						if (!enumEq(x, y)) return false;
					} else if (!dynEq(x, y)) return false;
			}
		}
		return true;
	}

	static function namesArray(t:Int, withMethods:Bool):Array<String> {
		var a:Array<String> = [];
		for (i in 0...nfields(ty(t)))
			a.push(Names.fidStr(fFid(field(ty(t), i))));
		if (withMethods)
			for (i in 0...nmethods(ty(t)))
				a.push(Names.fidStr(mFid(method(ty(t), i))));
		return a;
	}

	public static function instanceFields(c:Dynamic):Array<String>
		return namesArray(described(c), true);

	public static function fields(o:Dynamic):Array<String> {
		if (Str.isNull(o) || tindex(o) < T_FIRST) return [];
		var t = tindex(o);
		var a = namesArray(t, false);
		if (tk(ty(t)) == TK_ANON && !Str.isNull(Mem.getRef(Mem.addr(o), 0))) {
			var i = 0;
			while (i + 1 < nslots(Mem.getRef(Mem.addr(o), 0))) {
				var ov = Mem.getRef(Mem.addr(o), 0);
				var k:Int = Mem.getRefAt(Mem.addr(ov), 0, i);
				a.push(Names.fidStr(k));
				i += 2;
			}
		}
		return a;
	}

	public static function hasField(o:Dynamic, name:String):Bool {
		if (Str.isNull(o) || tindex(o) < T_FIRST) return false;
		var f = fid(name);
		if (!findField(ty(tindex(o)), f).isNull()) return true;
		return overflowFind(o, f) >= 0;
	}

	public static function getField(o:Dynamic, name:String):Dynamic {
		if (Str.isNull(o)) return null;
		var t = tindex(o);
		if (t < T_FIRST && t != T_STRING && t != T_ARRAY) return null;
		return dynGet(o, name);
	}

	public static function setField(o:Dynamic, name:String, v:Dynamic):Void
		dynSet(o, name, v);

	public static function deleteField(o:Dynamic, name:String):Bool {
		if (Str.isNull(o) || tk(ty(tindex(o))) != TK_ANON || Str.isNull(Mem.getRef(Mem.addr(o), 0))) return false;
		var i = overflowFind(o, fid(name));
		if (i < 0) return false;
		var ov = Mem.addr(Mem.getRef(Mem.addr(o), 0));
		Mem.setRef(ov, 8 * i, null);
		Mem.setRef(ov, 8 * (i + 1), null);
		return true;
	}

	public static function callMethod(f:Dynamic, args:Array<Dynamic>):Dynamic
		return dynCall(f, args);

	@:hxmc.noGc public static function compareMethods(a:Dynamic, b:Dynamic):Bool {
		if (Mem.addr(a) == Mem.addr(b)) return true;
		if (Str.isNull(a) || Str.isNull(b) || tindex(a) != tindex(b)) return false;
		if (tk(ty(tindex(a))) == TK_BOUND) {
			var pa = Mem.addr(a), pb = Mem.addr(b);
			return Mem.getPtr(pa, 8) == Mem.getPtr(pb, 8) && Mem.getPtr(pa, 16) == Mem.getPtr(pb, 16);
		}
		return false;
	}

	public static function copyObject(o:Dynamic):Dynamic {
		if (Str.isNull(o) || tindex(o) < T_FIRST) return o;
		var n = nslots(o);
		var c = Mem.alloc(n, tindex(o), kind(o));
		LibC.memcpy(Mem.addr(c), Mem.addr(o), (8 * n : I64));
		// an anonymous object's dynamic fields (slot 0) are its own
		if (tk(ty(tindex(o))) == TK_ANON && !Str.isNull(Mem.getRef(Mem.addr(o), 0))) {
			var m = nslots(Mem.getRef(Mem.addr(o), 0));
			var nv = Mem.alloc(m, T_OVERFLOW, K_PARR);
			LibC.memcpy(Mem.addr(nv), Mem.addr(Mem.getRef(Mem.addr(o), 0)), (8 * m : I64));
			Leaf.rt_barrier_range(nv, Mem.addr(nv), m);
			Mem.setRef(Mem.addr(c), 0, nv);
		}
		if (kind(c) == K_PARR) Leaf.rt_barrier_range(c, Mem.addr(c), n) else if (kind(c) == K_OBJ) {
			var pm = ptrmap(ty(tindex(c))); // only the reference slots
			if (!pm.isNull())
				for (i in 0...n)
					if ((Mem.getI64At(pm, 0, i >> 6) >>> (i & 63)).toInt() & 1 != 0) Leaf.rt_barrier_range(c, Mem.addr(c).add(8 * i), 1);
		}
		return c;
	}
}
