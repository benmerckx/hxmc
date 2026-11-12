package hxmc.ir;

import core.TType;
import core.Ast;
import core.Ast.Expr;
import core.Message.WarningCode;
import context.Typecore.AccessMode;
import context.Typecore.FieldHost;
import core.Globals.Pos;
import haxe.ds.Vector;
import typing.TyperBase.AccessKind;

// hxmc.Platform.supports(view.setPreferredFrameRateRange), the macro
// function the typer expands without the macro context
// (MacroContext.typeMacroHook): Platform.atLeast with what the declaration's
// uses need (Available.field: its own and its class's) of each of hxmc's
// Apple platforms (Available.PLATFORMS' first three; 0: any), whatever the
// target, so that the typed program is the same for all: AvailCheck reads
// the target's as the guard, FnLower folds or tests it (docs/interop.md,
// "Availability"). The declaration, a method, a property, a class, a static
// or an enum constant, is typed as an access, not a value: no closure of an
// extern method. Without @:hxmc.available it is true, with a warning.
class AvailGuard {
	public static function expand(ctx:context.Typecore.Typer, cpath:core.Globals.GlobalTypePath, f:String, el:Vector<Expr>, p:Pos):Null<Expr> {
		if (cpath.name != "Platform" || cpath.pack.length != 1 || cpath.pack[0] != "hxmc") return null;
		return f == "supports" ? supports(ctx, el, p) : null;
	}

	static function supports(ctx:context.Typecore.Typer, el:Vector<Expr>, p:Pos):Expr {
		var what = "Platform.supports: a declaration (view.method, a class, a static, an enum constant)";
		if (el.length != 1) core.Error.raiseTypingError(what, p);
		var x = el[0];
		if (x.expr.match(ECall(_, _))) core.Error.raiseTypingError(what + ", not a call", x.pos);
		var acc = typing.Typer.typeAccess(ctx, x.expr, x.pos, MGet, core.WithType.value);
		var v = [for (i in 0...3) need(acc, Available.PLATFORMS[i])];
		if (v[0] < 0) core.Error.raiseTypingError(what, x.pos);
		if (v[0] == 0 && v[1] == 0 && v[2] == 0) {
			context.Typecore.warning(ctx, WUser, "Platform.supports: no @:hxmc.available, every version has it (the test is true)", x.pos);
			return {expr: EConst(Ident("true")), pos: p};
		}
		return atLeast(v[0], v[1], v[2], p);
	}

	// what the access needs of platform (-1: no declaration)
	static function need(acc:AccessKind, platform:String):Int
		return switch acc {
			case AKField(fa) | AKAccessor(fa): field(fa, platform);
			case AKUsingField(sea) | AKUsingAccessor(sea): field(sea.seAccess, platform);
			case AKExpr(e): typed(e, platform);
			case _: -1;
		}

	static function field(fa:context.Typecore.FieldAccess, platform:String):Int
		return switch fa.faHost {
			case FHStatic(c) | FHInstance(c, _) | FHAbstract(_, _, c): Available.field(c, fa.faField, platform);
			case FHAnon: -1;
		}

	static function typed(e:TExpr, platform:String):Int
		return switch e.eexpr {
			case TParenthesis(x) | TCast(x, null): typed(x, platform);
			// (an inlined constant: its own version, TargetFlags.keepUnsafe)
			case TMeta(m, x) if (Available.isMeta(m)):
				var a = Available.of(m.exprs, platform), b = typed(x, platform);
				a > b ? a : b;
			case TMeta(_, x): typed(x, platform);
			case TConst(_): 0;
			case TField(_, FStatic(c, cf) | FInstance(c, _, cf)): Available.field(c, cf, platform);
			case TField(_, FClosure(o, cf)) if (o != null): Available.field(o.cls, cf, platform);
			case TField(_, FEnum(en, ef)):
				var a = Available.required(ef.efMeta, platform), b = Available.required(en.eMeta, platform);
				a > b ? a : b;
			case TTypeExpr(TClassDecl(c)): Available.required(c.clMeta, platform);
			case TTypeExpr(TEnumDecl(en)): Available.required(en.eMeta, platform);
			case TTypeExpr(TAbstractDecl(a)): Available.required(a.aMeta, platform);
			case _: -1;
		}

	// (Platform.atLeast is private: the expansion's alone)
	static function atLeast(mac:Int, ios:Int, cat:Int, p:Pos):Expr {
		inline function int(v:Int):Expr
			return {expr: EConst(Int(Std.string(v), null)), pos: p};
		var path:Expr = {expr: EField({expr: EConst(Ident("hxmc")), pos: p}, "Platform", EFNormal), pos: p};
		var call:Expr = {expr: ECall({expr: EField(path, "atLeast", EFNormal), pos: p}, haxe.ds.Vector.fromArrayCopy([int(mac), int(ios), int(cat)])), pos: p};
		return {expr: EMeta({meta: core.MetaList.StrictMeta.PrivateAccess, exprs: new Vector(0), pos: p}, call), pos: p};
	}
}
