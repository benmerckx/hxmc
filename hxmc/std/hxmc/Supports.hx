package hxmc;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

// hxmc.Platform.supports(x): x typed, only to find its declaration (the
// typed expression is dropped, so no closure of an extern method reaches
// the program), and the versions its @:hxmc.available and its class's (or
// abstract's; a property's for its accessor) give macOS, iOS and Mac
// Catalyst, as hxmc.ir.Available reads them for the check: the expansion is
// `Platform.atLeast(macos, ios, maccatalyst)` (0: any version), whatever the
// target, which hxmc.ir.AvailCheck takes for the guard and FnLower folds or
// tests (docs/interop.md, "Availability").
class Supports {
	static final PLATFORMS = ["macos", "ios", "maccatalyst"];
	static final WHAT = "Platform.supports: a declaration (view.method, a class, a static, an enum constant)";

	public static function expand(e:Expr):Expr {
		if (e.expr.match(ECall(_, _))) Context.error(WHAT + ", not a call", e.pos);
		var metas = declaration(Context.typeExpr(e));
		if (metas == null) Context.error(WHAT, e.pos);
		var v = [for (p in PLATFORMS) need(metas, p)];
		if (v[0] == 0 && v[1] == 0 && v[2] == 0) {
			Context.warning("Platform.supports: no @:hxmc.available, every version has it (the test is true)", e.pos);
			return macro @:pos(e.pos) true;
		}
		return macro @:pos(e.pos) @:privateAccess hxmc.Platform.atLeast($v{v[0]}, $v{v[1]}, $v{v[2]});
	}

	// the metadata that give the declaration's versions (null: no declaration)
	static function declaration(t:TypedExpr):Null<Array<Metadata>>
		return switch t.expr {
			case TParenthesis(x) | TCast(x, null): declaration(x);
			// (an inlined constant keeps its @:hxmc.available)
			case TMeta(m, x): m.name == ":hxmc.available" ? [[m]] : declaration(x);
			case TConst(_): [];
			// (a property read: its accessor)
			case TCall(x, _): declaration(x);
			// (an abstract's method as a value: the function calling it)
			case TFunction(f): declaration(f.expr);
			case TReturn(x) if (x != null): declaration(x);
			case TBlock([x]): declaration(x);
			case TField(_, FStatic(c, cf) | FInstance(c, _, cf)): field(c.get(), cf.get());
			case TField(_, FClosure(o, cf)) if (o != null): field(o.c.get(), cf.get());
			case TField(_, FEnum(en, ef)): [ef.meta.get(), en.get().meta.get()];
			case TTypeExpr(TClassDecl(c)): [c.get().meta.get()];
			case TTypeExpr(TEnumDecl(en)): [en.get().meta.get()];
			case TTypeExpr(TAbstract(a)): [a.get().meta.get()];
			case _: null;
		}

	static function field(c:ClassType, cf:ClassField):Array<Metadata> {
		var ms = [cf.meta.get(), c.meta.get()];
		switch c.kind {
			case KAbstractImpl(a): ms.push(a.get().meta.get());
			case _:
		}
		var n = cf.name;
		if (n.length > 4 && (n.substr(0, 4) == "get_" || n.substr(0, 4) == "set_"))
			for (p in c.fields.get().concat(c.statics.get()))
				if (p.name == n.substr(4)) ms.push(p.meta.get());
		return ms;
	}

	// the later version of platform the metadata ask for (0: any)
	static function need(metas:Array<Metadata>, platform:String):Int {
		var v = 0;
		for (ml in metas)
			for (m in ml)
				if (m.name == ":hxmc.available")
					for (x in m.params) {
						var n = entry(x, platform);
						if (n > v) v = n;
					}
		return v;
	}

	// `macos >= 14.0` (`||` of them, version("10.15.4")): its version if it
	// is platform's (the literal's text: 10.15 is newer than 10.9), else 0
	static function entry(e:Expr, platform:String):Int
		return switch e.expr {
			case EParenthesis(x): entry(x, platform);
			case EBinop(OpBoolOr, a, b):
				var x = entry(a, platform), y = entry(b, platform);
				x > y ? x : y;
			case EBinop(OpGte, {expr: EConst(CIdent(p))}, v) if (p == platform): number(v);
			case _: 0;
		}

	static function number(e:Expr):Int {
		var s = switch e.expr {
			case EConst(CInt(s, null) | CFloat(s, null)): s;
			case ECall({expr: EConst(CIdent("version"))}, [{expr: EConst(CString(s, _))}]): s;
			case EParenthesis(x): return number(x);
			case _: return 0;
		}
		// (by hand: hxmc's EReg and Std, not Eval's, are the macro context's)
		var parts = s.split("."), v = 0;
		if (parts.length > 3) return 0;
		for (i in 0...3) {
			var n = 0, p = i < parts.length ? parts[i] : "0";
			if (p.length == 0) return 0;
			for (j in 0...p.length) {
				var c = p.charCodeAt(j);
				if (c < "0".code || c > "9".code) return 0;
				n = n * 10 + c - "0".code;
			}
			v = (v << 8) | n;
		}
		return v;
	}
}
#end
