import hxmc.NativeGc;

// Header constructors (docs/hxmc.md, "Compressed references"): a
// constructor of a @:hxmc.compact enum with one argument of 4 bytes (an
// Int, a Bool or a compressed reference) is the 8-byte header alone, the
// argument where an object's identity hash is otherwise, natively on Linux
// and Windows on x86-64; elsewhere a slot, as any packed constructor. Values
// built and matched through minor and major collections (the corpus' small
// nurseries, RT_VERIFY; chains of them, the last object of a space),
// alongside other constructors, reflection (Type.enumParameters, enumEq,
// createEnum, Std.string, haxe.Serializer, EnumValueMap's keys, ObjectMap's
// keys, Reflect.copy), the identity hash, a value the escape analysis
// replaces, and threads building and collecting at once.
@:hxmc.compact
enum Expr {
	EConst(c:Const);
	Local(v:Var);
	Block(el:Array<Expr>);
	Paren(e:Expr);
	Return(e:Null<Expr>);
	Call(e:Expr, args:Array<Expr>);
	Fn(f:Int->Int);
	EAny(d:Dynamic);
	Pt(p:{x:Int, y:Int});
	Nothing;
}

@:hxmc.compact
enum Const {
	CInt(i:Int);
	CBool(b:Bool);
	CString(s:String);
	CFloat(f:Float); // (8 bytes: a slot)
	CNull(n:Null<Int>); // (a tagged word: a slot)
}

@:hxmc.compact
enum Box<T> {
	Full(v:T); // (a type parameter's value: a slot)
	Pair(a:T, b:Int);
}

@:hxmc.compact
class Var {
	public var name:String;
	public var id:Int;

	public function new(name, id) {
		this.name = name;
		this.id = id;
	}
}

class HeaderEnums {
	// an object's slots (its header: hxmc.rt.Types)
	@:hxmc.unsafe static function slots(o:Dynamic):Int
		return hxmc.unsafe.Mem.getU16(hxmc.unsafe.Mem.addr(o), -6);

	static function build(depth:Int, salt:Int):Expr {
		if (depth == 0)
			return switch salt % 5 {
				case 0: EConst(CInt(salt));
				case 1: EConst(CString("s" + salt));
				case 2: Local(new Var("v" + salt, salt));
				case 3: EConst(CBool(salt & 8 == 0));
				case _: Return(null);
			}
		return switch depth % 4 {
			case 0: Paren(build(depth - 1, salt * 3 + 1));
			case 1: Block([build(depth - 1, salt * 3 + 1), build(depth - 1, salt * 3 + 2)]);
			case 2: Return(build(depth - 1, salt * 3 + 2));
			case _: Call(build(depth - 1, salt * 3), [build(depth - 1, salt * 3 + 1), EConst(CInt(salt))]);
		}
	}

	static function sum(e:Expr):Int
		return switch e {
			case EConst(CInt(i)): i;
			case EConst(CBool(b)): b ? 1 : 2;
			case EConst(CString(s)): s.length;
			case EConst(CFloat(f)): Std.int(f);
			case EConst(CNull(n)): n == null ? 3 : n;
			case Local(v): v.id + v.name.length;
			case Block(el):
				var s = 0;
				for (x in el)
					s += sum(x);
				s;
			case Paren(x) | Return(x) if (x != null): 1 + sum(x);
			case Return(_): 5;
			case Call(f, args):
				var s = sum(f);
				for (a in args)
					s += sum(a);
				s;
			case Fn(f): f(1);
			case EAny(d): d;
			case Pt(p): p.x + p.y;
			case Paren(_) | Nothing: 0;
		}

	// a chain of header values, each the last one's only reference
	static function chain(n:Int):Expr {
		var e = EConst(CInt(0));
		for (k in 0...n)
			e = k % 2 == 0 ? Paren(e) : Return(e);
		return e;
	}

	static function depth(e:Expr):Int {
		var d = 0;
		while (true)
			switch e {
				case Paren(x) | Return(x) if (x != null):
					d++;
					e = x;
				case _:
					return d;
			}
	}

	// a value that never leaves the function (the escape analysis)
	static function local(a:Int):Int {
		var p = Paren(EConst(CInt(a)));
		return switch p {
			case Paren(EConst(CInt(x))): x * 10;
			case _: -1;
		}
	}

	static function main() {
		// (header constructors: no slot where there are compressed references,
		// Linux and Windows on x86-64; else a slot, as a packed constructor)
		var compressed = hxmc.unsafe.Mem.os() == 0 || hxmc.unsafe.Mem.os() == 2 && !hxmc.unsafe.Mem.arm() || hxmc.unsafe.Mem.os() == 1 && hxmc.unsafe.Mem.platform() == 0;
		var sizes = [
			slots(EConst(null)), slots(Local(null)), slots(Block(null)), slots(Return(null)), slots(Fn(null)), slots(EAny(null)), slots(Pt(null)),
			slots(CInt(1)), slots(CBool(true)), slots(CString("")), slots(CFloat(1.5)), slots(CNull(null)), slots(Full(1)), slots(Pair(1, 2))
		];
		trace(sizes.join(",") == (compressed ? "0,0,0,0,0,0,0,0,0,0,1,1,1,2" : "1,1,1,1,1,1,1,1,1,1,1,1,1,2") ? "sizes ok" : "sizes " + sizes);
		trace(local(3));

		var t = build(10, 1);
		var expect = sum(t);
		var junk = 0;
		for (k in 0...100000)
			junk += sum(build(2, k)) & 1;
		trace(sum(t) == expect, junk > 0);
		NativeGc.collect(false);
		trace(sum(t) == expect);
		NativeGc.collect(true);
		trace(sum(t) == expect, expect);

		// many small values in arrays: some end a nursery or an old space
		var a = [], ids = [];
		for (k in 0...30000) {
			a.push(k % 3 == 0 ? EConst(CInt(k)) : k % 3 == 1 ? Paren(EConst(CInt(k))) : Local(new Var("x", k)));
			if (k % 7 == 0) ids.push({k: k});
		}
		var bad = 0;
		for (k in 0...a.length)
			switch a[k] {
				case EConst(CInt(i)) | Paren(EConst(CInt(i))) if (i == k):
				case Local(v) if (v.id == k):
				case _: bad++;
			}
		NativeGc.collect(true);
		for (k in 0...a.length)
			if (sum(a[k]) != (k % 3 == 2 ? k + 1 : k % 3 == 1 ? k + 1 : k)) bad++;
		trace(bad, ids.length);
		var c = chain(100000);
		NativeGc.collect(false);
		trace(depth(c));
		NativeGc.collect(true);
		trace(depth(c), sum(chain(1001)));

		// every argument kind, read back after collections
		var fs = [Fn(x -> x + 41), EAny(7), EAny("d"), Pt({x: 3, y: 4}), EConst(CFloat(2.5)), EConst(CNull(9)), EConst(CNull(null)), Block([]), Nothing];
		NativeGc.collect(true);
		trace([for (f in fs) switch f {
			case EAny(d) if (Std.isOfType(d, String)): (d : String).length;
			case _: sum(f);
		}]);
		var bx:Array<Box<String>> = [Full("a"), Pair("b", 2), Full(null)];
		var bi:Array<Box<Int>> = [Full(3), Pair(4, 5)];
		NativeGc.collect(false);
		trace(bx, bi);

		// reflection
		var e = Call(Local(new Var("f", 1)), [EConst(CString("s")), EConst(CBool(false)), Return(null), Paren(EConst(CInt(-2)))]);
		trace(Type.enumParameters(EConst(CInt(5))), Type.enumParameters(CBool(true)), Type.enumParameters(Return(null)), Type.enumParameters(CString("q")));
		trace(Type.enumIndex(Return(null)), Type.enumConstructor(CString("x")), Type.enumIndex(CBool(false)));
		trace(Std.string(e), "" + Paren(Return(EConst(CString("z")))));
		trace(Type.enumEq(EConst(CInt(1)), EConst(CInt(1))), Type.enumEq(EConst(CInt(1)), EConst(CInt(2))), Type.enumEq(CString("a"), CString("a" + "")),
			Type.enumEq(Paren(EConst(CBool(true))), Paren(EConst(CBool(true)))), Type.enumEq(CBool(true), CBool(false)), Type.enumEq(Return(null), Return(null)));
		var m1 = Type.createEnum(Expr, "Paren", [EConst(CInt(6))]);
		var m2 = Type.createEnumIndex(Const, 0, [8]);
		var m3 = Type.createEnum(Const, "CBool", [true]);
		var m4 = Type.createEnum(Const, "CString", ["made" + 1]);
		NativeGc.collect(false);
		trace(sum(m1), m2, m3, m4, slots(m1) == slots(Paren(null)), slots(m4) == slots(CString(null)));
		var s = haxe.Serializer.run([e, build(4, 2)]);
		var u:Array<Expr> = haxe.Unserializer.run(s);
		trace(s, Std.string(u[0]) == Std.string(e), sum(u[1]) == sum(build(4, 2)));
		var map = new Map<Expr, Int>();
		for (k in 0...50)
			map.set(Paren(EConst(CInt(k))), k);
		NativeGc.collect(true);
		var found = 0;
		for (k in 0...50)
			if (map.get(Paren(EConst(CInt(k)))) == k) found++;
		trace(found, map.get(Paren(EConst(CInt(50)))), map.get(EConst(CInt(1))));
		var om = new haxe.ds.ObjectMap<{}, Int>();
		var keys:Array<{}> = [for (k in 0...200) (cast EConst(CInt(k)) : {})];
		for (k in 0...200)
			om.set(keys[k], k);
		NativeGc.collect(false);
		var hits = 0;
		for (k in 0...200)
			if (om.get(keys[k]) == k) hits++;
		NativeGc.collect(true);
		for (k in 0...200)
			if (om.get(keys[k]) == k) hits++;
		trace(hits, om.get((cast EConst(CInt(1)) : {})));
		var cp = Reflect.copy(EConst(CString("copied")));
		trace(cp, cp == null ? false : Type.enumEq(cp, EConst(CString("copied"))));
		var dyn:Dynamic = Return(null);
		trace(Reflect.isEnumValue(dyn), Type.getEnum(dyn) == Expr);
		// (the identity hash (a header constructor's: of its type and argument), the same after collections)
		var hv:Array<Expr> = [EConst(CInt(3)), Paren(EConst(CString("h"))), Local(new Var("w", 2)), Return(null), c];
		var h0 = [for (v in hv) hxmc.Native.objHash(v)];
		NativeGc.collect(false);
		var h1 = [for (v in hv) hxmc.Native.objHash(v)];
		NativeGc.collect(true);
		var h2 = [for (v in hv) hxmc.Native.objHash(v)];
		trace(h0.join(",") == h1.join(","), h1.join(",") == h2.join(","));

		// threads building, collecting and checking at once (one after another on wasm32-wasi)
		var results = [for (_ in 0...4) false];
		function work(k:Int) {
			var t = build(9, 10 + k);
			var e = sum(t);
			var c = chain(20000 + k);
			for (j in 0...50000)
				sum(build(2, j));
			NativeGc.collect(k % 2 == 0);
			results[k] = sum(t) == e && depth(c) == 20000 + k && Std.string(build(5, k)) == Std.string(build(5, k));
		}
		#if (hxmc.target != "wasm32-wasi")
		var lock = new sys.thread.Lock();
		for (k in 0...4)
			sys.thread.Thread.create(() -> {
				work(k);
				lock.release();
			});
		for (_ in 0...4)
			lock.wait();
		#else
		for (k in 0...4)
			work(k);
		#end
		trace(results);
		trace(sum(t) == expect, depth(c));
	}
}
