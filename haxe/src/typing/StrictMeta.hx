package typing;

import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.Globals.Platform;
import context.Common.CommonContext;
import context.Common.*;
import context.Typecore.Typer as TyperContext;
import core.Ast;
import core.Ast.*;
import core.TType;
import core.TType.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.Globals;
import core.Meta;
import core.WithType;
import context.Typecore.*;
import context.Typecore;
import context.TyperPass;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

class StrictMeta {
	static function efield(e:Expr, name:String):ExprDef return EField(e, name, EFNormal);

	public static function getNativeRepr(md:ModuleType, pos:Pos):Expr {
		var info = switch md {
			case TClassDecl(c): {path: c.clPath, meta: c.clMeta};
			case TEnumDecl(e): {path: e.ePath, meta: e.eMeta};
			case TTypeDecl(t): {path: t.tPath, meta: t.tMeta};
			case TAbstractDecl(a): {path: a.aPath, meta: a.aMeta};
		};
		var path = info.path;
		for (m in info.meta) switch m {
			case {meta: MetaTag.Native, exprs: [{expr: EConst(String(name, _))}]}:
				path = Ast.parsePath(name);
			case _:
		}
		if (path.pack.length == 0) return {expr: EConst(Ident(path.name)), pos: pos};
		var expr:Expr = {expr: EConst(Ident(path.pack[0])), pos: pos};
		for (part in path.pack.slice(1)) expr = {expr: efield(expr, part), pos: pos};
		return {expr: efield(expr, path.name), pos: pos};
	}

	public static function processMetaArgument(ctx:TyperContext, expr:TExpr, toplevel:Bool = true):Expr {
		var p = expr.epos;
		return switch expr.eexpr {
			case TField(e, f): {expr: efield(processMetaArgument(ctx, e, false), fieldName(f)), pos: p};
			case TConst(TInt(i)): {expr: EConst(Int(Std.string(i), null)), pos: p};
			case TConst(TFloat(f)): {expr: EConst(Float(f, null)), pos: p};
			case TConst(TString(s)): {expr: EConst(String(s, SDoubleQuotes)), pos: p};
			case TConst(TNull): {expr: EConst(Ident("null")), pos: p};
			case TConst(TBool(b)): {expr: EConst(Ident(Std.string(b))), pos: p};
			case TCast(e, _) | TMeta(_, e) | TParenthesis(e): processMetaArgument(ctx, e, toplevel);
			case TTypeExpr(md) if (toplevel): {expr: efield(getNativeRepr(md, p), "class"), pos: p};
			case TTypeExpr(md): getNativeRepr(md, p);
			case TArrayDecl(el): {expr: EArrayDecl(el.map(e -> processMetaArgument(ctx, e))), pos: p};
			case _:
				displayError(ctx.com, "This expression is too complex to be a strict metadata argument", p);
				{expr: EConst(Ident("null")), pos: p};
		};
	}

	public static function kindOfTypeAgainst(ctx:TyperContext, tWant:T, eHave:Expr):TExpr {
		return switch follow(tWant) {
			case TInst({clPath: {pack: ["java", "lang"], name: "Class"}}, [t1]):
				var e = typeExpr(ctx, eHave, WithTypeTools.withType(tWant));
				switch follow(e.etype) {
					case TAbstract({aPath: {pack: [], name: "Class"}}, [t2]): unify(ctx, t2, t1, e.epos);
					case TAnon(an): switch an.aStatus {
							case ClassStatics(c): unify(ctx, TInst(c, extractParamTypes(c.clParams)), t1, e.epos);
							case AbstractStatics(a): unify(ctx, TAbstract(a, extractParamTypes(a.aParams)), t1, e.epos);
							case _: unify(ctx, e.etype, tWant, e.epos);
						}
					case _: unify(ctx, e.etype, tWant, e.epos);
				}
				e;
			case TInst({clPath: {pack: ["jvm"], name: "NativeArray"}}, [t1]): switch eHave.expr {
					case EArrayDecl(el): mk(TArrayDecl(el.map(e -> kindOfTypeAgainst(ctx, t1, e))), t1, eHave.pos);
					case _:
						var e = typeExpr(ctx, eHave, WithTypeTools.withType(tWant));
						unify(ctx, e.etype, tWant, e.epos);
						e;
				}
			case t1:
				var e = typeExpr(ctx, eHave, WithTypeTools.withType(t1));
				unify(ctx, e.etype, t1, e.epos);
				e;
		};
	}

	public static function handleFields(ctx:TyperContext, fields:Array<ObjectField>,
			withTypeExpr:Expr):Array<Expr> return fields.map(function(f):Expr {
			var expr = f.expr, pos = expr.pos;
			var field:core.Ast.Expr = {expr: efield(withTypeExpr, f.key.name), pos: pos};
			var fieldexpr:core.Ast.Expr = {expr: EConst(Ident(f.key.name)), pos: pos};
			var left = typeExpr(ctx, {expr: ECall(field, vector()), pos: pos}, NoValue);
			var right = kindOfTypeAgainst(ctx, left.etype, expr);
			return {expr: EBinop(OpAssign, fieldexpr, processMetaArgument(ctx, right)), pos: pos};
		});

	public static function makeMeta(ctx:TyperContext, texpr:TExpr, extra:Array<Expr>):Expr return switch texpr.eexpr {
		case TNew(c, _, el): {
				expr: ECall(getNativeRepr(TClassDecl(c), texpr.epos), el.map(e -> processMetaArgument(ctx, e)).appendArray(extra)),
				pos: texpr.epos
			};
		case TTypeExpr(md): {expr: ECall(getNativeRepr(md, texpr.epos), VectorTools.ofArray(extra)), pos: texpr.epos};
		case _:
			displayError(ctx.com, "Unexpected expression", texpr.epos);
			throw "Unexpected strict metadata expression";
	};

	public static function fieldToTypePath(com:CommonContext, e:Expr):core.Ast.TypePath {
		function loop(e:Expr, pack:Array<String>, name:Array<String>):core.Ast.TypePath return switch e.expr {
			case EField(inner, f, _) if (f.charAt(0).toLowerCase() != f.charAt(0)):
				if (name.length > 1) {
					// too many name paths
					displayError(com, "Unexpected " + f, e.pos);
					throw core.ds.Exit.raise();
				}
				loop(inner, pack, [f].concat(name));
			case EField(inner, f, _): loop(inner, [f].concat(pack), name);
			case EConst(Ident(f)):
				var n:String, sub:Null<String> = null;
				switch name {
					case []:
						if (f.charAt(0).toUpperCase() != f.charAt(0)) {
							displayError(com, "A class name must start with an uppercase letter", e.pos);
							throw core.ds.Exit.raise();
						}
						n = f;
					case [nm]:
						pack = [f].concat(pack);
						n = nm;
					case [nm, s]:
						pack = [f].concat(pack);
						n = nm;
						sub = s;
					case _: throw "Invalid strict metadata path";
				}
				mkTypePath(pack, n, vector(), sub);
			case _:
				displayError(com, "Unexpected expression when building strict meta", e.pos);
				throw core.ds.Exit.raise();
		};
		return loop(e, [], []);
	}

	public static function getStrictMeta(ctx:TyperContext, meta:MetaTag, params:Vector<Expr>, pos:Pos):MetadataEntry {
		var changedExpr:Expr, fields:Array<ObjectField>, ctype:ComplexType;
		switch params {
			case [{expr: ECall(ef, el), pos: p}]:
				var path = fieldToTypePath(ctx.com, ef);
				fields = switch el {
					case [{expr: EObjectDecl(f)}]: f.toArray();
					case []: [];
					case _:
						displayError(ctx.com, "Object declaration expected", el[0].pos);
						[];
				};
				changedExpr = ef;
				ctype = CTPath(makePtp(path, ef.pos));
			case [e = {expr: EConst(Ident(i)), pos: p}]:
				changedExpr = e;
				fields = [];
				ctype = CTPath(makePtp(mkTypePath([], i), p));
			case [field = {expr: EField(_), pos: p}]:
				changedExpr = field;
				fields = [];
				ctype = CTPath(makePtp(fieldToTypePath(ctx.com, field), p));
			case _:
				displayError(ctx.com,
					"A @:strict metadata must contain exactly one parameter. Please check the documentation for more information", pos);
				throw core.ds.Exit.raise();
		}
		var t = Typeload.loadComplexType(ctx, false, LoadNormal, {type: ctype, pos: pos});
		flushPass(ctx.g, PBuildClass, "get_strict_meta");
		var texpr = typeExpr(ctx, changedExpr, NoValue);
		var withTypeExpr:core.Ast.Expr = {
			expr: ECheckType({expr: EConst(Ident("null")), pos: pos}, {type: ctype, pos: Globals.nullPos}),
			pos: pos
		};
		var args = [makeMeta(ctx, texpr, handleFields(ctx, fields, withTypeExpr))];
		switch t {
			case TInst(c, _):
				var v = getMetaString(c.clMeta, MetaTag.Annotation);
				// We explicitly set this to the default retention policy CLASS. This allows us to treat
				// @:strict as default CLASS and @:meta as default RUNTIME.
				args.push({expr: EConst(String(v == null ? "CLASS" : v, SDoubleQuotes)), pos: pos});
			case _:
		}
		return {meta: meta, exprs: Vector.fromArrayCopy(args), pos: pos};
	}

	public static function checkStrictMeta(ctx:TyperContext, metas:Metadata):Metadata {
		if (ctx.com.platform != Jvm) return [];
		var ret = [];
		for (m in metas) if (m.meta == MetaTag.Strict) try {
			ret.unshift(getStrictMeta(ctx, MetaTag.Meta, m.exprs, m.pos));
		} catch (_:core.ds.Exit) {}
		return ret;
	}
}
