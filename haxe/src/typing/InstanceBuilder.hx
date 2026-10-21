package typing;

import core.MetaList.StrictMeta as MetaTag;
import core.TType;
import core.Ast;
import core.Ast.Expr;
import core.Globals;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.TPrinting.*;
import core.Error.*;
import core.Error;
import core.Meta;
import core.Abstract;
import context.Typecore;
import context.Typecore.*;
import context.TyperPass;
import core.TUnification.*;
import core.ds.NotFound;
import context.display.DeprecationCheck;

@:structInit class MacroCallPath {
	public var path:GlobalTypePath;
	public var field:String;
	public var args:haxe.ds.Vector<Expr>;

	public inline function new(path:GlobalTypePath, field:String, args:haxe.ds.Vector<Expr>) {
		this.path = path;
		this.field = field;
		this.args = args;
	}

	public inline function clone():MacroCallPath return new MacroCallPath(path, field, args);
}

class InstanceBuilder {
	public static function getMacroPath(ctx:Typer, e:Expr, args:haxe.ds.Vector<Expr>, p:Pos):MacroCallPath {
		function loop(e:Expr):Array<String> return switch e.expr {
			case EField(e, f, _): [f].concat(loop(e));
			case EConst(Ident(i)): [i];
			case _: raiseTypingError("Invalid macro call", p);
		};
		var path = switch e.expr {
			case EConst(Ident(i)):
				var resolved:GlobalTypePath;
				if (ctx.c.curclass.clStatics.exists(i)) resolved = ctx.c.curclass.clPath;
				else {
					var imported = ctx.m.importResolution.extractFieldImports().findOpt(i);
					if (imported == null) raiseTypingError("Invalid macro call", p);
					resolved = tPath(imported.type);
				}
				[i, resolved.name].concat(resolved.pack);
			case _: loop(e);
		};
		if (path.length < 2) return raiseTypingError("Invalid macro call", p);
		var pack = path.slice(2);
		pack.reverse();
		return {path: {pack: pack, name: path[1]}, field: path[0], args: args};
	}

	public static function buildMacroType(ctx:Typer, pl:TParams, p:Pos):T {
		var call = switch pl {
			case [TInst({clKind: KExpr({expr: ECall(e, args)})}, _)]: getMacroPath(ctx, e, args, p);
			case [TInst({clKind: KExpr({expr: EArrayDecl([{expr: ECall(e, args)}])})}, _)]: getMacroPath(ctx, e, args, p);
			case _: raiseTypingError("MacroType requires a single expression call parameter", p);
		};
		var old = ctx.e.ret;
		// port: typed local, gencpp can't switch on a call through a function-typed field.
		var macroResult:context.Typecore.MacroResult = ctx.g.doMacro(ctx, MMacroType, call.path, call.field, call.args, p);
		var t = switch macroResult {
			case MError | MMacroInMacro: spawnMonomorph(ctx, p);
			case MSuccess(_): ctx.e.ret;
		};
		ctx.e.ret = old;
		return t;
	}

	public static function buildMacroBuild(ctx:Typer, c:TClass, pl:TParams, cfl:haxe.ds.Vector<ClassField>, p:Pos):T {
		var buildExpr = try Meta.get(MetaTag.GenericBuild, c.clMeta) catch (_:NotFound) {
			raiseTypingError(Globals.sTypePath(c.clPath) + " is missing @:genericBuild meta. Was it removed by a macro?", p);
		};
		var call = switch buildExpr.exprs {
			case [{expr: ECall(e, args)}]: getMacroPath(ctx, e, args, p);
			case _: raiseTypingError("genericBuild requires a single expression call parameter", p);
		};
		var oldRet = ctx.e.ret, oldBuild = ctx.c.getBuildInfos;
		ctx.c.getBuildInfos = function() return {type: TClassDecl(c), params: pl, fields: cfl.toArray()};
		var macroResult:context.Typecore.MacroResult = ctx.g.doMacro(ctx, MMacroType, call.path, call.field, call.args, p);
		var t = switch macroResult {
			case MError | MMacroInMacro: spawnMonomorph(ctx, p);
			case MSuccess(_): ctx.e.ret;
		};
		ctx.e.ret = oldRet;
		ctx.c.getBuildInfos = oldBuild;
		return t;
	}

	// --------------------------------------------------------------------------
	// API EVENTS

	public static function getBuildInfo(ctx:Typer, mtype:ModuleType, p:Pos):BuildInfo {
		return switch mtype {
			case TClassDecl(c):
				if (Type.enumIndex(ctx.pass) > Type.enumIndex(PBuildClass)) c.clBuild();
				inline function build(f:TParams->T, label:String, tl:TParams):T {
					var t = spawnMonomorph(ctx, p);
					var r = makeLazy(ctx.g, t, function() {
						var tf = f(tl);
						unifyRaise(tf, t, p);
						linkDynamic(t, tf);
						switch tf {
							case TInst(c, _):
								c.clBuild();
							case TAbstract(a, _):
								Abstract.buildAbstract(a);
							case _:
						}
						return t;
					}, label);
					return TLazy(r);
				}
				var kind:BuildKind;
				var apply = switch c.clKind {
					case KGeneric:
						kind = BuildGeneric(c);
						function(tl) return build(function(tl) return typing.Generic.buildGenericClass(ctx, c, p, tl), "build_generic", tl);
					case KGenericBuild(cfl):
						kind = BuildGenericBuild;
						function(tl) return build(function(tl) return buildMacroBuild(ctx, c, tl, cfl, p), "build_generic_build", tl);
					case KMacroType:
						kind = BuildMacroType;
						function(tl) return build(function(tl) return buildMacroType(ctx, tl, p), "build_macro_type", tl);
					case _:
						kind = BuildNormal;
						function(tl) return TInst(c, tl);
				};
				makeBuildInfo(kind, c.clPath, c.clParams, hasClassFlag(c, CExtern), apply);
			case TEnumDecl(e): makeBuildInfo(BuildNormal, e.ePath, e.eParams, hasEnumFlag(e, EnExtern), function(tl) return TEnum(e, tl));
			case TTypeDecl(td):
				try {
					var deprecated = Meta.get(MetaTag.Deprecated, td.tMeta);
					var msg = switch deprecated.exprs {
						case [{expr: EConst(String(s, _))}]: s;
						case _: "This typedef is deprecated in favor of " + sType(printContext(), td.tType);
					};
					DeprecationCheck.warnDeprecation(createDeprecationContext(ctx), msg, p);
				} catch (_:NotFound) {}
				makeBuildInfo(BuildNormal, td.tPath, td.tParams, false, function(tl) return TType(td, tl));
			case TAbstractDecl(a): makeBuildInfo(BuildNormal, a.aPath, a.aParams, false, function(tl) return TAbstract(a, tl));
		};
	}
}
