package hxmc.ir;

import core.Ast.Binop;
import core.TType;
import core.TFunctions;
import hxmc.ir.CInterop.CTy;
import hxmc.ir.Lower.LowerError;

// hxmc.scoped.Image's parts for each T (docs/plans/lowlevel.md,
// "Serialization: relative references"): its calls of Image.size, check,
// zero, decode and encode replaced, before the root checker, by what T's
// layout makes of them. An image's layout is linear memory's (CInterop.layout,
// fixedStruct) on every target: scalars at their natural alignment, a scoped
// class's fields in order, a Fixed's elements (8-byte aligned, its size a
// multiple of 8), a Rel 4 bytes.
class Images {
	public static var image:Null<TClass> = null; // hxmc.scoped.ImageParts
	public static var io:Null<TClass> = null; // hxmc.scoped.ImageIO

	public static function reset() {
		image = null;
		io = null;
	}

	public static function rewrite(e:TExpr):TExpr {
		if (image == null || io == null) return e;
		function map(e:TExpr):TExpr {
			var e = core.Texpr.mapExpr(map, e);
			return switch e.eexpr {
				case TCall({eexpr: TField(_, FStatic(c, cf))}, args) if (c == image):
					var p = e.epos;
					switch cf.cfName {
						case "size": int(layoutOf(elemOf(args[0].etype, p), p).size, p);
						case "check": check(args[0], args[1], elemOf(args[2].etype, p), p);
						case "zero": zero(elemOf(args[0].etype, p), p);
						case "decode": decode(args[0], args[1], elemOf(args[2].etype, p), p);
						case "encode": encode(args[0], args[1], args[2], p);
						case _: e;
					}
				case _: e;
			}
		}
		return map(e);
	}

	// ---- T's layout

	static function fail(msg:String, p:core.Globals.Pos):Dynamic
		throw new LowerError(msg, CInterop.posOf(p));

	static function elemOf(t:T, p:core.Globals.Pos):T
		return switch TFunctions.follow(t) {
			case TAbstract(_, [et]): et;
			case _: fail("Image: not a Grow", p);
		}

	static function show(t:T):String
		return core.TPrinting.sType(core.TPrinting.printContext(), t);

	// what t is in an image: "rel", "struct", "fixed", or a scalar's C type
	static function kindOf(t:T, p:core.Globals.Pos):{kind:String, ct:Null<CTy>} {
		switch TFunctions.follow(t) {
			case TAbstract({aPath: {pack: ["hxmc", "scoped"], name: "Rel"}}, _):
				return {kind: "rel", ct: null};
			case TAbstract(a, params) if (CInterop.isFixed(a)):
				return {kind: "fixed", ct: null};
			case TInst(c, _) if (CInterop.isScopedValue(c)):
				if (c.clParams.length > 0) fail('Image: ${show(t)} has type parameters', p);
				return {kind: "struct", ct: null};
			case _:
		}
		var ct = CInterop.ctype(t);
		return switch ct {
			case CBool | CI8 | CU8 | CI16 | CU16 | CI32 | CI64 | CF32 | CF64: {kind: "scalar", ct: ct};
			case _: fail('Image: ${show(t)} is not in an image (scalars, Rels, scoped classes and Fixed of them: no references)', p);
		}
	}

	static function scalarSize(ct:CTy):Int
		return switch ct {
			case CBool | CI8 | CU8: 1;
			case CI16 | CU16: 2;
			case CI32 | CF32: 4;
			case _: 8;
		}

	static function layoutOf(t:T, p:core.Globals.Pos):{size:Int, align:Int} {
		var k = kindOf(t, p);
		switch k.kind {
			case "rel":
				return {size: 4, align: 4};
			case "scalar":
				var s = scalarSize(k.ct);
				return {size: s, align: s};
			case "fixed":
				var f = fixedOf(t, p);
				var el = layoutOf(f.elem, p);
				return {size: (f.n * el.size + 7) & ~7, align: el.align > 8 ? el.align : 8};
			case _:
				var c = classOf(t);
				var off = 0, align = 1;
				for (f in fieldsOf(c, p)) {
					off = f.off + f.size;
					if (f.align > align) align = f.align;
				}
				var size = (off + align - 1) & ~(align - 1);
				if (size == 0) fail('Image: ${show(t)} has no fields', p);
				// (linear memory's layout, which an image is)
				if (!Lower.wasmGc && CInterop.layout(c).size != size) fail('Image: ${show(t)}: the layout differs from the struct\'s', p);
				return {size: size, align: align};
		}
	}

	static function classOf(t:T):TClass
		return switch TFunctions.follow(t) {
			case TInst(c, _): c;
			case _: null;
		}

	static function fixedOf(t:T, p:core.Globals.Pos):{elem:T, n:Int, nat:T, nc:TClass} {
		return switch TFunctions.follow(t) {
			case TAbstract(a, params):
				var info = CInterop.fixedOf(t);
				if (info == null) fail('Image: ${show(t)}: a Fixed of an unknown length', p);
				var nat = core.Abstract.getUnderlyingType(a, params);
				var nc = switch TFunctions.follow(nat) {
					case TInst(nc, _): nc;
					case _: fail("Image: a Fixed's array", p);
				};
				{elem: info.elem, n: info.n, nat: nat, nc: nc};
			case _: fail("Image: not a Fixed", p);
		}
	}

	static function fieldsOf(c:TClass, p:core.Globals.Pos):Array<{cf:TClassField, off:Int, size:Int, align:Int}> {
		var off = 0, r = [];
		for (cf in c.clOrderedFields) {
			if (!cf.cfKind.match(Var(_))) continue;
			var l = layoutOf(cf.cfType, p);
			off = (off + l.align - 1) & ~(l.align - 1);
			r.push({cf: cf, off: off, size: l.size, align: l.align});
			off += l.size;
		}
		return r;
	}

	// ---- typed expressions

	static inline function mk(e:TExprDef, t:T, p:core.Globals.Pos):TExpr
		return TFunctions.mk(e, t, p);

	static function int(i:Int, p:core.Globals.Pos):TExpr
		return mk(TConst(TInt(i)), Lower.basic.tint, p);

	static function add(at:TExpr, k:Int, p:core.Globals.Pos):TExpr
		return k == 0 ? at : mk(TBinop(OpAdd, at, int(k, p)), Lower.basic.tint, p);

	static function addMul(at:TExpr, j:TExpr, k:Int, p:core.Globals.Pos):TExpr
		return mk(TBinop(OpAdd, at, k == 1 ? j : mk(TBinop(OpMult, j, int(k, p)), Lower.basic.tint, p)), Lower.basic.tint, p);

	static function block(es:Array<TExpr>, t:T, p:core.Globals.Pos):TExpr
		return mk(TBlock(haxe.ds.Vector.fromArrayCopy(es)), t, p);

	static function ioCall(name:String, args:Array<TExpr>, p:core.Globals.Pos):TExpr {
		var cf = io.clStatics.get(name);
		if (cf == null) fail('Image: ImageIO.$name', p);
		var ret = switch TFunctions.follow(cf.cfType) {
			case TFun(s): s.ret;
			case _: Lower.basic.tvoid;
		};
		var f = mk(TField(mk(TTypeExpr(TClassDecl(io)), TDynamic(null), p), FStatic(io, cf)), cf.cfType, p);
		return mk(TCall(f, haxe.ds.Vector.fromArrayCopy(args)), ret, p);
	}

	static function local(name:String, init:TExpr, p:core.Globals.Pos):{decl:TExpr, use:TExpr} {
		var v = TFunctions.allocVar(VGenerated, name, init.etype, p);
		return {decl: mk(TVar(v, init), Lower.basic.tvoid, p), use: mk(TLocal(v), init.etype, p)};
	}

	static function arrayCall(na:TExpr, f:{nc:TClass, elem:T}, name:String, args:Array<TExpr>, t:T, p:core.Globals.Pos):TExpr {
		var cf = f.nc.clFields.get(name);
		var params = switch TFunctions.follow(na.etype) {
			case TInst(_, ps): ps;
			case _: haxe.ds.Vector.fromArrayCopy([f.elem]);
		};
		return mk(TCall(mk(TField(na, FInstance(f.nc, params, cf)), cf.cfType, p), haxe.ds.Vector.fromArrayCopy(args)), t, p);
	}

	// ---- check: every Bool 0 or 1, every Rel none or one of the n elements

	static function hasChecks(t:T, p:core.Globals.Pos):Bool {
		var k = kindOf(t, p);
		return switch k.kind {
			case "rel": true;
			case "scalar": k.ct == CBool;
			case "fixed": hasChecks(fixedOf(t, p).elem, p);
			case _:
				for (f in fieldsOf(classOf(t), p))
					if (hasChecks(f.cf.cfType, p)) return true;
				false;
		}
	}

	static function check(b:TExpr, n:TExpr, t:T, p:core.Globals.Pos):TExpr {
		var tbool = Lower.basic.tbool;
		if (!hasChecks(t, p)) return mk(TConst(TBool(true)), tbool, p);
		var size = layoutOf(t, p).size;
		var lb = local("_hx_b", b, p), ln = local("_hx_n", n, p), ok = local("_hx_ok", mk(TConst(TBool(true)), tbool, p), p);
		function bad(test:TExpr):TExpr
			return mk(TIf(test, mk(TBinop(OpAssign, ok.use, mk(TConst(TBool(false)), tbool, p)), tbool, p), null), Lower.basic.tvoid, p);
		function checks(t:T, at:TExpr):Array<TExpr> {
			var k = kindOf(t, p);
			return switch k.kind {
				case "rel": [bad(ioCall("badRel", [lb.use, at, ln.use], p))];
				case "scalar": k.ct == CBool ? [bad(ioCall("badBool", [lb.use, at], p))] : [];
				case "fixed":
					var f = fixedOf(t, p);
					if (!hasChecks(f.elem, p)) return [];
					var es = layoutOf(f.elem, p).size;
					CInterop.forIndex(int(f.n, p), j -> block(checks(f.elem, addMul(at, j, es, p)), Lower.basic.tvoid, p), p);
				case _:
					var r = [];
					for (f in fieldsOf(classOf(t), p))
						r = r.concat(checks(f.cf.cfType, add(at, f.off, p)));
					r;
			}
		}
		var es = [lb.decl, ln.decl, ok.decl];
		es = es.concat(CInterop.forIndex(ln.use, i -> block(checks(t, mk(TBinop(OpMult, i, int(size, p)), Lower.basic.tint, p)), Lower.basic.tvoid, p), p));
		es.push(ok.use);
		return block(es, tbool, p);
	}

	// ---- zero: a zero T (linear memory: a local without a value is zero)

	static function zero(t:T, p:core.Globals.Pos):TExpr {
		var k = kindOf(t, p);
		if (Lower.wasmGc && (k.kind == "struct" || k.kind == "fixed")) return CInterop.zeroValue(t, p);
		var v = TFunctions.allocVar(VGenerated, "_hx_zero", t, p);
		return block([mk(TVar(v, null), Lower.basic.tvoid, p), mk(TLocal(v), t, p)], t, p);
	}

	// ---- decode (WasmGC): a T from b at at, field by field

	static function read(t:T, b:TExpr, at:TExpr, p:core.Globals.Pos):TExpr {
		var k = kindOf(t, p);
		var x = switch k.kind {
			case "rel": ioCall("i32", [b, at], p);
			case _:
				switch k.ct {
					case CBool: ioCall("bool", [b, at], p);
					case CI8: ioCall("i8", [b, at], p);
					case CU8: ioCall("u8", [b, at], p);
					case CI16: ioCall("i16", [b, at], p);
					case CU16: ioCall("u16", [b, at], p);
					case CI32: ioCall("i32", [b, at], p);
					case CI64: ioCall("i64", [b, at], p);
					case CF32: ioCall("f32", [b, at], p);
					case _: ioCall("f64", [b, at], p);
				}
		};
		return mk(TCast(x, null), t, p);
	}

	static function decode(b:TExpr, at:TExpr, t:T, p:core.Globals.Pos):TExpr {
		var lb = local("_hx_b", b, p), lat = local("_hx_at", at, p);
		// (the fields of the object o, made zero, read in place)
		function fill(o:TExpr, t:T, at:TExpr):Array<TExpr> {
			var k = kindOf(t, p);
			switch k.kind {
				case "fixed":
					var f = fixedOf(t, p);
					var na = mk(TCast(o, null), f.nat, p);
					var es = layoutOf(f.elem, p).size;
					var ek = kindOf(f.elem, p).kind;
					return CInterop.forIndex(int(f.n, p), j -> {
						var eat = addMul(at, j, es, p);
						ek == "struct" ? block(fill(arrayCall(na, f, "unsafeGet", [j], f.elem, p), f.elem, eat), Lower.basic.tvoid,
							p) : arrayCall(na, f, "unsafeSet", [j, read(f.elem, lb.use, eat, p)], Lower.basic.tvoid, p);
					}, p);
				case _:
					var c = classOf(t), r = [];
					for (f in fieldsOf(c, p)) {
						var fat = add(at, f.off, p), fk = kindOf(f.cf.cfType, p).kind;
						if (fk == "struct" || fk == "fixed")
							r = r.concat(fill(CInterop.getField(o, c, f.cf, p), f.cf.cfType, fat));
						else
							r.push(CInterop.setField(o, c, f.cf, read(f.cf.cfType, lb.use, fat, p), p));
					}
					return r;
			}
		}
		var k = kindOf(t, p).kind;
		if (k != "struct" && k != "fixed") return block([lb.decl, lat.decl, read(t, lb.use, lat.use, p)], t, p);
		var v = local("_hx_v", zero(t, p), p);
		return block([lb.decl, lat.decl, v.decl].concat(fill(v.use, t, lat.use)).concat([v.use]), t, p);
	}

	// ---- encode (WasmGC): v's fields into out at at

	static function write(t:T, out:TExpr, at:TExpr, x:TExpr, p:core.Globals.Pos):TExpr {
		var k = kindOf(t, p);
		var basic = Lower.basic;
		return switch k.kind {
			case "rel": ioCall("put32", [out, at, mk(TCast(x, null), basic.tint, p)], p);
			case _:
				switch k.ct {
					case CBool: ioCall("putBool", [out, at, mk(TCast(x, null), basic.tbool, p)], p);
					case CI8 | CU8: ioCall("put8", [out, at, mk(TCast(x, null), basic.tint, p)], p);
					case CI16 | CU16: ioCall("put16", [out, at, mk(TCast(x, null), basic.tint, p)], p);
					case CI32: ioCall("put32", [out, at, mk(TCast(x, null), basic.tint, p)], p);
					case CI64: ioCall("put64", [out, at, x], p);
					case CF32: ioCall("putF32", [out, at, mk(TCast(x, null), basic.tfloat, p)], p);
					case _: ioCall("putF64", [out, at, mk(TCast(x, null), basic.tfloat, p)], p);
				}
		}
	}

	static function encode(v:TExpr, out:TExpr, at:TExpr, p:core.Globals.Pos):TExpr {
		var lv = local("_hx_v", v, p), lo = local("_hx_out", out, p), lat = local("_hx_at", at, p);
		function emit(t:T, x:TExpr, at:TExpr):Array<TExpr> {
			var k = kindOf(t, p);
			switch k.kind {
				case "fixed":
					var f = fixedOf(t, p);
					var na = mk(TCast(x, null), f.nat, p);
					var es = layoutOf(f.elem, p).size;
					return CInterop.forIndex(int(f.n, p), j -> block(emit(f.elem, arrayCall(na, f, "unsafeGet", [j], f.elem, p), addMul(at, j, es, p)),
						Lower.basic.tvoid, p), p);
				case "struct":
					var c = classOf(t), r = [];
					for (f in fieldsOf(c, p))
						r = r.concat(emit(f.cf.cfType, CInterop.getField(x, c, f.cf, p), add(at, f.off, p)));
					return r;
				case _:
					return [write(t, lo.use, at, x, p)];
			}
		}
		return block([lv.decl, lo.decl, lat.decl].concat(emit(v.etype, lv.use, lat.use)), Lower.basic.tvoid, p);
	}
}
