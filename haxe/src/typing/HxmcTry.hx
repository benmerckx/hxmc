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

// hxmc: `@:try e` (docs/plans/lowlevel.md, "Less to write"), Zig's try for
// scoped error values: e a value of a scoped enum with a constructor Ok (of
// one argument or none), the others its errors. Ok(v) gives v (nothing for
// Ok); an error is returned from the function at once, as the constructor
// of the same name and arguments of the enum the function returns (the same
// enum, or another one with those errors: a result of another value).
class HxmcTry {
	static inline var VALUE = "_hx_try";

	static function path(en:TEnum, p:Pos):Expr {
		var names = en.eModule.mPath.pack.copy();
		if (en.eModule.mPath.name != en.ePath.name) names.push(en.eModule.mPath.name);
		names.push(en.ePath.name);
		var e:Expr = {expr: EConst(Ident(names[0])), pos: p};
		for (i in 1...names.length)
			e = {expr: EField(e, names[i], EFNormal), pos: p};
		return e;
	}

	static function arity(ef:TEnumField):Int
		return switch follow(ef.efType) {
			case TFun(s): s.args.length;
			case _: 0;
		}

	static function ctor(en:TEnum, name:String, args:Array<Expr>, p:Pos):Expr {
		var f:Expr = {expr: EField(path(en, p), name, EFNormal), pos: p};
		return args.length == 0 ? f : {expr: ECall(f, Vector.fromArrayCopy(args)), pos: p};
	}

	// (e not a scoped enum's value: e, the metadata ignored, as Haxe ignores what it does not know)
	public static function type(ctx:Typer, e1:Expr, withType:WithTypeValue, p:Pos):TExpr {
		var te = typing.Typer.typeExpr(ctx, e1, WithTypeTools.value);
		var en = switch follow(te.etype) {
			case TEnum(en, _) if (core.HxmcScoped.isEnum(en)): en;
			case _: return te;
		};
		var ok = en.eConstrs.get("Ok");
		if (ok == null || arity(ok) > 1)
			Error.raiseTypingError('@:try: ${en.ePath.name} has no constructor Ok of one argument or none (the value; the others are its errors)', p);
		var fn = switch follow(ctx.e.ret) {
			case TEnum(fn, _): fn;
			case t: null;
		};
		var cases = [];
		for (name in en.eNames) {
			var ef = en.eConstrs.get(name), n = arity(ef);
			var args = [for (i in 0...n) ({expr: EConst(Ident(VALUE + i)), pos: p} : Expr)];
			var body:Expr = if (name == "Ok") {
				n == 1 ? {expr: EConst(Ident(VALUE + 0)), pos: p} : {expr: EBlock(new Vector(0)), pos: p};
			} else {
				var to = fn == null ? null : fn.eConstrs.get(name);
				if (to == null || arity(to) != n)
					Error.raiseTypingError('@:try: an error ${en.ePath.name}.$name returned from a function whose result ${fn == null ? "is no enum" : "(" + fn.ePath.name + ") has no " + name + " of " + n + " argument" + (n == 1 ? "" : "s")}',
						p);
				{expr: EReturn(ctor(fn, name, args, p)), pos: p};
			}
			cases.push(new SwitchCase(Vector.fromArrayCopy([ctor(en, name, args, p)]), null, body, p));
		}
		var stored = Typecore.storeTypedExpr(ctx.com, te, p);
		var r = try typing.Typer.typeExpr(ctx, {expr: ESwitch(stored.expr, Vector.fromArrayCopy(cases), null), pos: p}, withType) catch (x:Dynamic) {
			ctx.com.partScope.storedTypedExprs.remove(stored.id);
			throw x;
		}
		ctx.com.partScope.storedTypedExprs.remove(stored.id);
		return r;
	}
}
