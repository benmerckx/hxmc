package typing;

import context.Typecore;
import core.Ast;
import core.Error;
import core.Globals.Pos;
import core.TFunctions.*;
import core.TType;
import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import haxe.ds.Vector;

// hxmc: literals that build scoped values where one is expected
// (docs/plans/lowlevel.md, "Less to write"). An array literal expected as a
// Slice<T> is Scope.slice(n) filled, as a Grow<T> a new Grow pushed to, as
// a Fixed<T, N> (N elements) a new Fixed filled; a string with
// interpolations expected as a Str is Str.join of its parts (Str values,
// Int and Float through Str.ofInt and ofFloat, Bool as "true" or "false").
// What it builds is the enclosing scope's memory, as a call's would be.
class HxmcLiterals {
	static inline var LOCAL = "_hx_lit";

	// the hxmc.scoped type t is (Slice, Grow, Fixed, Str), or null
	static function scoped(withType:WithTypeValue):Null<{name:String, t:T, params:TParams}>
		return switch withType {
			case WithType(t, _):
				switch follow(t) {
					case TAbstract(a, params) if (a.aPath.pack.length == 2 && a.aPath.pack[0] == "hxmc" && a.aPath.pack[1] == "scoped"):
						{name: a.aPath.name, t: t, params: params};
					case _: null;
				}
			case _: null;
		}

	static function path(names:Array<String>, p:Pos):Expr {
		var e:Expr = {expr: EConst(Ident(names[0])), pos: p};
		for (i in 1...names.length)
			e = {expr: EField(e, names[i], EFNormal), pos: p};
		return e;
	}

	static function call(names:Array<String>, args:Array<Expr>, p:Pos):Expr
		return {expr: ECall(path(names, p), Vector.fromArrayCopy(args)), pos: p};

	static function int(i:Int, p:Pos):Expr
		return {expr: EConst(Int(Std.string(i), null)), pos: p};

	public static function arrayDecl(ctx:Typer, el:Vector<Expr>, withType:WithTypeValue, p:Pos):Null<TExpr> {
		var s = scoped(withType);
		if (s == null) return null;
		var create = switch s.name {
			case "Slice": call(["hxmc", "scoped", "Scope", "slice"], [int(el.length, p)], p);
			case "Grow": ({expr: ENew(Ast.makePtp(Ast.mkTypePath(["hxmc", "scoped"], "Grow"), p), new Vector(0)), pos: p} : Expr);
			case "Fixed":
				var n = switch s.params.length == 2 ? follow(s.params[1]) : null {
					case TInst({clKind: KExpr({expr: EConst(Int(v, _))})}, _): Std.parseInt(v);
					case _: null;
				};
				if (n != null && n != el.length) Error.raiseTypingError('a literal of ${el.length} elements for a Fixed of $n', p);
				call(["hxmc", "scoped", "Fixed", "make"], [], p);
			case _: return null;
		};
		// (the elements in locals first, typed as elements: in value position,
		// what they allocate is the enclosing scope's, as the collection is; a
		// store's inlined body would be a scope of its own)
		var ids = [];
		function store(te:TExpr, pos:Pos):Expr {
			var st = Typecore.storeTypedExpr(ctx.com, te, pos);
			ids.push(st.id);
			return st.expr;
		}
		function done()
			for (id in ids)
				ctx.com.partScope.storedTypedExprs.remove(id);
		inline function decl(name:String, e:Expr, pos:Pos):Expr
			return {expr: EVars(Vector.fromArrayCopy([new EVar({name: name, pos: pos}, false, false, null, e, [])])), pos: pos};
		var local = path([LOCAL], p), et = s.params[0];
		var e = try {
			var exprs = [decl(LOCAL, store(typing.Typer.typeExpr(ctx, create, WithTypeTools.withType(s.t)), p), p)];
			for (i in 0...el.length) {
				var x = typing.Typer.typeExpr(ctx, el[i], WithTypeTools.withType(et));
				exprs.push(decl(LOCAL + i, store(context.AbstractCast.castOrUnify(ctx, et, x, x.epos), el[i].pos), el[i].pos));
			}
			for (i in 0...el.length) {
				var v = path([LOCAL + i], el[i].pos);
				exprs.push(s.name == "Grow" ? {expr: ECall({expr: EField(local, "push", EFNormal), pos: p}, Vector.fromArrayCopy([v])), pos: el[i].pos} : {
					expr: EBinop(OpAssign, {expr: EArray(local, int(i, p)), pos: el[i].pos}, v),
					pos: el[i].pos
				});
			}
			exprs.push(local);
			typing.Typer.typeExpr(ctx, {expr: EBlock(Vector.fromArrayCopy(exprs)), pos: p}, withType);
		} catch (x:Dynamic) {
			done();
			throw x;
		}
		done();
		return e;
	}

	// s with interpolations ('...'), expected as a Str: Str.join of its parts
	public static function formatStr(ctx:Typer, s:String, withType:WithTypeValue, p:Pos):Null<TExpr> {
		var st = scoped(withType);
		if (st == null || st.name != "Str") return null;
		// (formatString's parts: a string first, then each added on the right)
		var parts = [], e = typing.Typer.formatString(ctx, s, p);
		while (true)
			switch e.expr {
				case EBinop(OpAdd, l, r):
					parts.unshift(r);
					e = l;
				case _:
					parts.unshift(e);
					break;
			}
		var items:Array<Expr> = [], ids = [];
		function done()
			for (id in ids)
				ctx.com.partScope.storedTypedExprs.remove(id);
		for (part in parts)
			switch part.expr {
				case EConst(String(v, _)):
					if (v != "") items.push(part);
				case _:
					var te = typing.Typer.typeExpr(ctx, part, WithTypeTools.value);
					var stored = Typecore.storeTypedExpr(ctx.com, te, part.pos);
					ids.push(stored.id);
					var x = stored.expr;
					items.push(switch follow(te.etype) {
						case TAbstract({aPath: {pack: ["hxmc", "scoped"], name: "Str"}}, _): x;
						case TAbstract({aPath: {pack: [], name: "Int"}}, _): call(["hxmc", "scoped", "Str", "ofInt"], [x], part.pos);
						case TAbstract({aPath: {pack: [], name: "Float"}}, _): call(["hxmc", "scoped", "Str", "ofFloat"], [x], part.pos);
						case TAbstract({aPath: {pack: [], name: "Bool"}}, _):
							{expr: ETernary(x, {expr: EConst(String("true", SDoubleQuotes)), pos: part.pos}, {expr: EConst(String("false", SDoubleQuotes)), pos: part.pos}), pos: part.pos};
						case _:
							done();
							Error.raiseTypingError('a Str interpolates Str, Int, Float and Bool values, not ${core.TPrinting.sType(core.TPrinting.printContext(), te.etype)}', part.pos);
					});
			}
		if (ids.length == 0) {
			done();
			return null;
		}
		var joined = items.length == 1 ? items[0] : call(["hxmc", "scoped", "Str", "join"], [{expr: EArrayDecl(Vector.fromArrayCopy(items)), pos: p}], p);
		var r = try typing.Typer.typeExpr(ctx, joined, withType) catch (x:Dynamic) {
			done();
			throw x;
		}
		done();
		return r;
	}
}
