package hxmc.ir;

import core.Ast.Binop;
import core.Ast.Unop;
import core.TType;
import core.TFunctions;
import hxmc.ir.Lower.LowerError;

// -D hxmc.wasm-gc: struct of arrays (docs/plans/lowlevel.md, "Two
// representations, one core"). A NativeArray of a scoped class whose fields
// are all scalars (the storage of a Grow, a Slice, a Fixed of them) is an
// object of a class made for it, P_Soa: its length and one NativeArray per
// field, no object per element. The typed code's uses of such a NativeArray
// are rewritten before the lowering: an element's field read or written is
// that field's array's element; an element read whole is made from them (a
// value: a copy, as anywhere on WasmGC), one written whole is spread over
// them; an element copied from one to another goes field by field. Its type
// is the companion class's (Lower.lowerTy); code seeing it through an erased
// type parameter only passes it on (the scoped abstractions' generic
// classes). Anything else done to one is an error.
class Soa {
	static var companions = new Map<TClass, TClass>();
	static var eligibles = new Map<TClass, Bool>();

	public static function reset() {
		companions = new Map();
		eligibles = new Map();
	}

	// a scoped class whose fields are all scalars (WasmGC), at least one
	public static function eligible(c:TClass):Bool {
		if (!Lower.wasmGc || !CInterop.isWasmValue(c) || c.clParams.length > 0 || c.clSuper != null) return false;
		var known = eligibles.get(c);
		if (known != null) return known;
		var ok = false;
		for (cf in c.clOrderedFields) {
			if (!cf.cfKind.match(Var(_))) continue;
			if (!scalar(cf.cfType)) {
				ok = false;
				break;
			}
			ok = true;
		}
		eligibles.set(c, ok);
		return ok;
	}

	static function scalar(t:T):Bool
		return switch CInterop.ctype(t) {
			case CBool | CI8 | CU8 | CI16 | CU16 | CI32 | CI64 | CF32 | CF64: !CInterop.isStructValue(t) && !isFixedType(t);
			case _: false;
		}

	static function isFixedType(t:T):Bool
		return switch TFunctions.follow(t) {
			case TAbstract(a, _): CInterop.isFixed(a);
			case _: false;
		}

	// the element class of a NativeArray of struct of arrays, else null
	public static function elemOf(t:T):Null<TClass> {
		if (!Lower.wasmGc) return null;
		return switch TFunctions.follow(t) {
			case TInst(na, [et]) if (Lower.isNativeArray(na)):
				switch TFunctions.followWithoutNull(et) {
					case TInst(c, _) if (eligible(c)): c;
					case _: null;
				}
			case _: null;
		}
	}

	static function fieldsOf(c:TClass):Array<TClassField>
		return [for (cf in c.clOrderedFields) if (cf.cfKind.match(Var(_))) cf];

	static var naClass:Null<TClass> = null;

	public static function setNativeArray(c:TClass)
		naClass = c;

	// the class of P's struct of arrays: `length` and a NativeArray per field
	public static function companion(c:TClass):TClass {
		var s = companions.get(c);
		if (s != null) return s;
		if (naClass == null) throw new LowerError("struct of arrays: no hxmc.NativeArray", CInterop.posOf(c.clPos));
		s = TFunctions.mkClass(c.clModule, {pack: c.clPath.pack, name: c.clPath.name + "_Soa"}, c.clPos, c.clPos);
		function add(name:String, t:T) {
			var cf = TFunctions.mkField(name, t, c.clPos, c.clPos);
			s.clFields.set(name, cf);
			s.clOrderedFields.push(cf);
		}
		add("length", Lower.basic.tint);
		for (cf in fieldsOf(c))
			add("f_" + cf.cfName, TInst(naClass, haxe.ds.Vector.fromArrayCopy([cf.cfType])));
		companions.set(c, s);
		return s;
	}

	// ---- typed expressions

	static inline function mk(e:TExprDef, t:T, p:core.Globals.Pos):TExpr
		return TFunctions.mk(e, t, p);

	static function soaType(c:TClass):T
		return TInst(companion(c), haxe.ds.Vector.fromArrayCopy([]));

	static function arrayOf(c:TClass, cf:TClassField):T
		return TInst(naClass, haxe.ds.Vector.fromArrayCopy([cf.cfType]));

	static function sfield(s:TExpr, c:TClass, name:String, p:core.Globals.Pos):TExpr {
		var sc = companion(c), cf = sc.clFields.get(name);
		return mk(TField(s, FInstance(sc, haxe.ds.Vector.fromArrayCopy([]), cf)), cf.cfType, p);
	}

	static function naCall(a:TExpr, et:T, name:String, args:Array<TExpr>, t:T, p:core.Globals.Pos):TExpr {
		var cf = naClass.clFields.get(name);
		return mk(TCall(mk(TField(a, FInstance(naClass, haxe.ds.Vector.fromArrayCopy([et]), cf)), cf.cfType, p), haxe.ds.Vector.fromArrayCopy(args)), t, p);
	}

	static function local(name:String, init:TExpr, p:core.Globals.Pos):{decl:TExpr, use:TExpr} {
		var v = TFunctions.allocVar(VGenerated, name, init.etype, p);
		return {decl: mk(TVar(v, init), Lower.basic.tvoid, p), use: mk(TLocal(v), init.etype, p)};
	}

	static function block(es:Array<TExpr>, t:T, p:core.Globals.Pos):TExpr
		return mk(TBlock(haxe.ds.Vector.fromArrayCopy(es)), t, p);

	// (an expression with no effect, read twice: kept as it is)
	static function simple(e:TExpr):Bool
		return switch e.eexpr {
			case TLocal(_) | TConst(_): true;
			case _: false;
		}

	static function bind(name:String, e:TExpr, pre:Array<TExpr>, p:core.Globals.Pos):TExpr {
		if (simple(e)) return e;
		var l = local(name, e, p);
		pre.push(l.decl);
		return l.use;
	}

	// a new struct of arrays of n elements of class c
	public static function make(c:TClass, n:TExpr, p:core.Globals.Pos):TExpr {
		var pre = [];
		var ln = bind("_hx_n", n, pre, p);
		var sc = companion(c);
		var s = local("_hx_soa", mk(TNew(sc, haxe.ds.Vector.fromArrayCopy([]), haxe.ds.Vector.fromArrayCopy([])), soaType(c), p), p);
		pre.push(s.decl);
		pre.push(mk(TBinop(OpAssign, sfield(s.use, c, "length", p), ln), Lower.basic.tint, p));
		for (cf in fieldsOf(c)) {
			var at = arrayOf(c, cf);
			var arr = switch at {
				case TInst(na, ps): mk(TNew(na, ps, haxe.ds.Vector.fromArrayCopy([ln])), at, p);
				case _: null;
			};
			pre.push(mk(TBinop(OpAssign, sfield(s.use, c, "f_" + cf.cfName, p), arr), at, p));
		}
		pre.push(s.use);
		return block(pre, soaType(c), p);
	}

	// a copy of the struct of arrays x (of class c's): its arrays copied
	public static function copy(c:TClass, x:TExpr, p:core.Globals.Pos):TExpr {
		var pre = [];
		var src = bind("_hx_src", x, pre, p);
		var n = local("_hx_n", sfield(src, c, "length", p), p);
		pre.push(n.decl);
		var dst = local("_hx_dst", make(c, n.use, p), p);
		pre.push(dst.decl);
		for (cf in fieldsOf(c)) {
			var at = arrayOf(c, cf);
			var name = "f_" + cf.cfName;
			pre = pre.concat(CInterop.forIndex(n.use, i -> naCall(sfield(dst.use, c, name, p), cf.cfType, "unsafeSet", [i, naCall(sfield(src, c, name, p), cf.cfType, "unsafeGet", [i], cf.cfType, p)], Lower.basic.tvoid, p), p));
		}
		pre.push(dst.use);
		return block(pre, soaType(c), p);
	}

	// element i of a, made whole: P's own constructor of its fields when it
	// has one (Escape may then keep it in values), else a zero object filled
	static function element(c:TClass, a:TExpr, i:TExpr, p:core.Globals.Pos):TExpr {
		var pre = [];
		var la = bind("_hx_a", a, pre, p), li = bind("_hx_i", i, pre, p);
		var t = TInst(c, haxe.ds.Vector.fromArrayCopy([]));
		var fs = fieldsOf(c);
		var values = [for (cf in fs) naCall(sfield(la, c, "f_" + cf.cfName, p), cf.cfType, "unsafeGet", [li], cf.cfType, p)];
		if (structInit(c, fs)) {
			pre.push(mk(TNew(c, haxe.ds.Vector.fromArrayCopy([]), haxe.ds.Vector.fromArrayCopy(values)), t, p));
			return block(pre, t, p);
		}
		var o = local("_hx_e", CInterop.zeroValue(t, p), p);
		pre.push(o.decl);
		for (k in 0...fs.length)
			pre.push(CInterop.setField(o.use, c, fs[k], values[k], p));
		pre.push(o.use);
		return block(pre, t, p);
	}

	// c's constructor takes its fields, in order, and only stores them
	static function structInit(c:TClass, fs:Array<TClassField>):Bool {
		var ctor = c.clConstructor;
		if (ctor == null || !core.Meta.has(CompilerGenerated, ctor.cfMeta)) return false;
		return switch TFunctions.follow(ctor.cfType) {
			case TFun(s):
				if (s.args.length != fs.length) return false;
				for (k in 0...fs.length)
					if (s.args[k].name != fs[k].cfName || s.args[k].optional) return false;
				true;
			case _: false;
		}
	}

	// element i of a set to v, field by field
	static function store(c:TClass, a:TExpr, i:TExpr, v:TExpr, p:core.Globals.Pos):TExpr {
		var pre = [];
		var la = bind("_hx_a", a, pre, p), li = bind("_hx_i", i, pre, p);
		// (from an element of another such array: field by field, no object)
		var from = getOf(v);
		if (from != null && from.c == c) {
			pre = pre.concat(from.pre);
			var lb = bind("_hx_b", from.a, pre, p), lj = bind("_hx_j", from.i, pre, p);
			for (cf in fieldsOf(c)) {
				var name = "f_" + cf.cfName;
				pre.push(naCall(sfield(la, c, name, p), cf.cfType, "unsafeSet", [li, naCall(sfield(lb, c, name, p), cf.cfType, "unsafeGet", [lj], cf.cfType, p)], Lower.basic.tvoid, p));
			}
			return block(pre, Lower.basic.tvoid, p);
		}
		var lv = bind("_hx_v", v, pre, p);
		for (cf in fieldsOf(c))
			pre.push(naCall(sfield(la, c, "f_" + cf.cfName, p), cf.cfType, "unsafeSet", [li, CInterop.getField(lv, c, cf, p)], Lower.basic.tvoid, p));
		return block(pre, Lower.basic.tvoid, p);
	}

	// e an element read of such an array (under parentheses, casts, a block's
	// last expression): the array, the index, the statements before
	static function getOf(e:TExpr):Null<{c:TClass, a:TExpr, i:TExpr, pre:Array<TExpr>}> {
		return switch e.eexpr {
			case TParenthesis(x) | TMeta(_, x): getOf(x);
			case TCast(x, null): getOf(x);
			case TBlock(es) if (es.length > 0):
				var r = getOf(es[es.length - 1]);
				if (r == null) return null;
				{c: r.c, a: r.a, i: r.i, pre: [for (k in 0...es.length - 1) es[k]].concat(r.pre)};
			case TCall({eexpr: TField(a, FInstance(na, _, {cfName: "unsafeGet"}))}, args) if (Lower.isNativeArray(na) && args.length == 1):
				var c = elemOf(a.etype);
				c == null ? null : {c: c, a: a, i: args[0], pre: []};
			case _: null;
		}
	}

	// e a field of an element of such an array
	static function fieldOf(e:TExpr):Null<{c:TClass, a:TExpr, i:TExpr, pre:Array<TExpr>, cf:TClassField}> {
		return switch e.eexpr {
			case TParenthesis(x) | TMeta(_, x): fieldOf(x);
			case TField(x, FInstance(c, _, cf)) if (cf.cfKind.match(Var(_))):
				var g = getOf(x);
				g == null || g.c != c ? null : {c: g.c, a: g.a, i: g.i, pre: g.pre, cf: cf};
			case _: null;
		}
	}

	public static function rewrite(e:TExpr):TExpr {
		if (!Lower.wasmGc || naClass == null) return e;
		function rw(e:TExpr):TExpr {
			var p = e.epos;
			// (a field of an element read or written in place)
			switch e.eexpr {
				case TBinop(OpAssign, lhs, rhs):
					var f = fieldOf(lhs);
					if (f != null) {
						var pre = [for (x in f.pre) rw(x)];
						var la = bind("_hx_a", rw(f.a), pre, p), li = bind("_hx_i", rw(f.i), pre, p);
						var v = local("_hx_v", rw(rhs), p);
						pre.push(v.decl);
						pre.push(naCall(sfield(la, f.c, "f_" + f.cf.cfName, p), f.cf.cfType, "unsafeSet", [li, v.use], Lower.basic.tvoid, p));
						pre.push(v.use);
						return block(pre, e.etype, p);
					}
				case TBinop(OpAssignOp(op), lhs, rhs):
					var f = fieldOf(lhs);
					if (f != null) {
						var pre = [for (x in f.pre) rw(x)];
						var la = bind("_hx_a", rw(f.a), pre, p), li = bind("_hx_i", rw(f.i), pre, p);
						var arr = sfield(la, f.c, "f_" + f.cf.cfName, p);
						var old = naCall(arr, f.cf.cfType, "unsafeGet", [li], f.cf.cfType, p);
						var v = local("_hx_v", mk(TBinop(op, old, rw(rhs)), e.etype, p), p);
						pre.push(v.decl);
						pre.push(naCall(arr, f.cf.cfType, "unsafeSet", [li, v.use], Lower.basic.tvoid, p));
						pre.push(v.use);
						return block(pre, e.etype, p);
					}
				case TUnop(op = Increment | Decrement, flag, x):
					var f = fieldOf(x);
					if (f != null) {
						var pre = [for (y in f.pre) rw(y)];
						var la = bind("_hx_a", rw(f.a), pre, p), li = bind("_hx_i", rw(f.i), pre, p);
						var arr = sfield(la, f.c, "f_" + f.cf.cfName, p);
						var old = local("_hx_old", naCall(arr, f.cf.cfType, "unsafeGet", [li], f.cf.cfType, p), p);
						pre.push(old.decl);
						var one = mk(TConst(TInt(1)), f.cf.cfType, p);
						var nv = local("_hx_new", mk(TBinop(op == Increment ? OpAdd : OpSub, old.use, one), f.cf.cfType, p), p);
						pre.push(nv.decl);
						pre.push(naCall(arr, f.cf.cfType, "unsafeSet", [li, nv.use], Lower.basic.tvoid, p));
						pre.push(flag == Postfix ? old.use : nv.use);
						return block(pre, e.etype, p);
					}
				case TField(x, FInstance(_, _, cf)) if (cf.cfKind.match(Var(_))):
					var f = fieldOf(e);
					if (f != null) {
						var pre = [for (y in f.pre) rw(y)];
						pre.push(naCall(sfield(rw(f.a), f.c, "f_" + f.cf.cfName, p), f.cf.cfType, "unsafeGet", [rw(f.i)], f.cf.cfType, p));
						return block(pre, e.etype, p);
					}
				case _:
			}
			// (the operations of the NativeArray itself)
			switch e.eexpr {
				case TNew(na, _, args) if (Lower.isNativeArray(na) && args.length == 1):
					var c = elemOf(e.etype);
					if (c != null) return make(c, rw(args[0]), p);
				case TCall({eexpr: TField(a, FInstance(na, _, cf))}, args) if (Lower.isNativeArray(na) && elemOf(a.etype) != null):
					var c = elemOf(a.etype);
					switch cf.cfName {
						case "unsafeGet": return element(c, rw(a), rw(args[0]), p);
						case "unsafeSet": return store(c, rw(a), rw(args[0]), rw(args[1]), p);
						case n: throw new LowerError('struct of arrays: NativeArray.$n of ${c.clPath.name} (unsafeGet, unsafeSet, length and new only)', CInterop.posOf(p));
					}
				case TField(a, FInstance(na, _, cf)) if (Lower.isNativeArray(na) && elemOf(a.etype) != null):
					if (cf.cfName == "length") return sfield(rw(a), elemOf(a.etype), "length", p);
					throw new LowerError('struct of arrays: NativeArray.${cf.cfName} of ${elemOf(a.etype).clPath.name}', CInterop.posOf(p));
				case TArray(a, _) if (elemOf(a.etype) != null):
					throw new LowerError('struct of arrays: an element of a NativeArray of ${elemOf(a.etype).clPath.name} by [] (unsafeGet and unsafeSet only)', CInterop.posOf(p));
				case _:
			}
			return core.Texpr.mapExpr(rw, e);
		}
		return rw(e);
	}
}
