package typing;

import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.MetaList.StrictMeta as MetaTag;
import core.TType;
import core.Ast;
import context.Typecore.Typer as TyperContext;
import context.Common.CommonContext;
import core.Globals.Platform;
import core.Ast.Expr;
import core.Ast.FuncArg;
import core.Ast.TypeHint;
import core.Globals;
import core.Globals.Pos;
import core.display.DisplayPosition;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.TOther.ExtType;
import core.TPrinting.*;
import core.Error.*;
import core.Error;
import core.Meta;
import core.Naming;
import core.WithType;
import context.Typecore.*;
import context.Typecore;
import context.TyperPass;
import context.AbstractCast;
import context.SafeCom;
import optimization.Optimizer;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

@:structInit class ArgumentWithDefault {
	public var name:String;
	public var expr:Null<Expr>;
	public var type:T;

	public inline function new(name:String, expr:Null<Expr>, type:T) {
		this.name = name;
		this.expr = expr;
		this.type = type;
	}

	public inline function clone():ArgumentWithDefault return new ArgumentWithDefault(name, expr, type);
}

class FunctionArguments {
	public static function isFlashNativeBasic(t:T):Bool return switch follow(t) {
		case TAbstract(a, _): (a.aPath.pack.length == 0
				&& ["Int", "Float", "Bool"].contains(a.aPath.name)) || (a.aPath.pack.join(".") == "haxe"
				&& ["Int32", "UInt32"].contains(a.aPath.name));
		case TInst(c, _): (c.clPath.pack.length == 0
				&& ["Int", "Float"].contains(c.clPath.name)) || (c.clPath.pack.join(".") == "haxe" && c.clPath.name == "Int32");
		case TEnum(e, _): e.ePath.pack.length == 0 && e.ePath.name == "Bool";
		case _: false;
	};

	public static function typeFunctionArg(com:CommonContext, t:T, e:Null<Expr>, opt:Bool, p:Pos):{type:T, expr:Null<Expr>} {
		// TODO https://github.com/HaxeFoundation/haxe/issues/8461
		// delay ctx PTypeField (fun() ->
		// 	if ExtType.is_void (follow t) then
		// 		error "Arguments of type Void are not allowed" p
		// );
		if (opt) return {type: com.basic.tnull(t), expr: e == null ? {expr: EConst(Ident("null")), pos: Globals.nullPos} : e};
		// port: null_pos in this OCaml pattern is a binding, not a position comparison.
		if (e != null) switch e.expr {
			case EConst(Ident("null")):
				t = com.basic.tnull(t);
			case _:
		}
		return {type: t, expr: e};
	}

	public static function typeFunctionArgValue(ctx:TyperContext, t:T, c:Null<Expr>, doDisplay:Bool):Null<TExpr> {
		if (c == null) return null;
		var p = c.pos;
		var input = doDisplay ? context.display.Display.preprocessExpr(ctx.com, c) : c;
		var e = typeExpr(ctx, input, WithTypeTools.withType(t));
		e = AbstractCast.castOrUnify(ctx, t, e, p);
		e = Optimizer.reduceExpression(SafeCom.ofTyper(ctx), e);
		inline function runAnalyzer(e:TExpr):TExpr return analyzerRunOnExprRef(ctx.com,
			Globals.sTypePath(ctx.c.curclass.clPath) + "." + ctx.f.curfield.cfName, e);
		if (ctx.e.curfun == FunConstructor) {
			function checkThis(e:TExpr):Void {
				switch e.eexpr {
					case TConst(TThis):
						raiseTypingError("Cannot access this in a constructor's default argument value", e.epos);
					case TLocal(v) if (ctx.f.vthis != null && v == ctx.f.vthis):
						raiseTypingError("Cannot access this in a constructor's default argument value", e.epos);
					case _:
						core.Texpr.iter(checkThis, e);
				}
			}
			checkThis(e);
		}
		inline function referencesArg(e:TExpr):Bool {
			var found = false;
			function loop(e:TExpr):Void {
				if (found) return;
				switch e.eexpr {
					case TLocal(v) if (ctx.f.locals.findOpt(v.vName) == v):
						found = true;
					case _:
						core.Texpr.iter(loop, e);
				}
			}
			loop(e);
			return found;
		}
		function loop(analyzed:Bool, e:TExpr):TExpr return switch e.eexpr {
			case TConst(_) | TLocal(_): e;
			case TField({eexpr: TTypeExpr(_)}, FEnum(_, _)): e;
			case TField({eexpr: TTypeExpr(_)}, FStatic({clKind: KAbstractImpl(a)}, cf)) if (a.aEnum && hasClassFieldFlag(cf, CfEnum)): e;
			case TCast(e, null): loop(analyzed, e);
			case _ if (!analyzed && !referencesArg(e)): loop(true, runAnalyzer(e));
			case _ if (ctx.com.platform == Flash && isFlashNativeBasic(t)):
				raiseTypingError("Non-constant default argument values are not supported on the flash target for basic type "
					+ sType(printContext(), t),
					p);
			case _: e;
		};
		return loop(false, e);
	}

	final com:CommonContext;
	final isExtern:Bool;
	final doDisplay:Bool;
	final abstractThis:Null<T>;
	final syntax:haxe.ds.Vector<FuncArg>;
	final withDefault:Array<ArgumentWithDefault>;
	var typeRepr:Null<haxe.ds.Vector<{name:String, optional:Bool, type:T}>> = null;
	var exprRepr:Null<haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}>> = null;

	public function new(com:CommonContext, typeArg:Int->Bool->Null<TypeHint>->Pos->T, isExtern:Bool, doDisplay:Bool, abstractThis:Null<T>,
			syntax:haxe.ds.Vector<FuncArg>) {
		this.com = com;
		this.isExtern = isExtern;
		this.doDisplay = doDisplay;
		this.abstractThis = abstractThis;
		this.syntax = syntax;
		withDefault = [];
		for (i in 0...syntax.length) {
			var arg = syntax[i];
			var t = typeArg(i, arg.optional, arg.type, arg.name.pos);
			var typed = typeFunctionArg(com, t, arg.expr, arg.optional, arg.name.pos);
			withDefault.push({name: arg.name.name, expr: typed.expr, type: typed.type});
		}
		if (abstractThis != null) withDefault.unshift({name: "this", expr: null, type: abstractThis});
	}

	static function checkCoroutineScope(v:TVar):Void {
		try {
			var mt = tInfos(moduleTypeOfType(v.vType));
			var config = coro.CoroScopeConfig.ofMetaList(mt.mtMeta);
			if (config != null) {
				addVarFlag(v, VCoroScope);
				if (config.restrictedSuspension) addVarFlag(v, VCoroRestrictedSuspension);
			}
		} catch (_:core.ds.Exit) {}
	}

	// Returns the `(string * bool * Type.t) list` requires by `TFun` .
	public function forType():haxe.ds.Vector<{name:String, optional:Bool, type:T}> {
		if (typeRepr == null) typeRepr = withDefault.mapToVector(function(arg) return {name: arg.name, optional: arg.expr != null, type: arg.type});
		return typeRepr;
	}

	function checkRest(isLast:Bool, eo:Null<Expr>, opt:Bool, t:T, pn:Pos):Void {
		if (!ExtType.isRest(follow(t))) return;
		if (opt) raiseTypingError("Rest argument cannot be optional", pn);
		if (eo != null) raiseTypingError("Rest argument cannot have default value", eo.pos);
		if (!isLast) raiseTypingError("Rest should only be used for the last function argument", pn);
	}

	// Returns the `(tvar * texpr option) list` for `tf_args`. Also checks the validity of argument names and whether or not
	// an argument should be displayed.
	public function forExpr(ctx:TyperContext):haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}> {
		if (exprRepr != null) return exprRepr;
		inline function makeLocal(name:String, kind:TVarKind, t:T, meta:Metadata, pn:Pos):TVar {
			var v = allocVar(kind, name, t, pn);
			v.vMeta = StrictMeta.checkStrictMeta(ctx, meta).concat(meta);
			return v;
		}
		// port: the arguments in order (upstream: accumulated reversed, then List.rev), one per withDefault entry
		var acc = new haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}>(withDefault.length);
		var offset = abstractThis == null ? 0 : 1;
		for (i in 0...withDefault.length) {
			var typed = withDefault[i];
			if (i == 0 && offset == 1) {
				var v = makeLocal(typed.name, VAbstractThis, typed.type, [], Globals.nullPos);
				v.vMeta.unshift({meta: MetaTag.This, exprs: vector(), pos: Globals.nullPos});
				acc[i] = {variable: v, defaultValue: null};
				continue;
			}
			if (i - offset >= syntax.length) throw "Invalid function argument lists";
			var arg = syntax[i - offset], pn = arg.name.pos;
			var last = i == withDefault.length - 1;
			delay(ctx.g, PTypeField, function() checkRest(last, typed.expr, arg.optional, typed.type, pn));
			if (!isExtern) {
				Naming.checkLocalVariableName(ctx.com, typed.name, TVOArgument, pn);
				if (typed.name != "_"
					&& core.ds.VectorTools.exists(acc,
						function(arg) return arg != null && arg.variable.vName == typed.name)) raiseTypingError('Duplicate argument name "'
						+ typed.name
						+ '"', pn);
			}
			var eo = typeFunctionArgValue(ctx, typed.type, typed.expr, doDisplay);
			var v = makeLocal(typed.name, VUser(TVOArgument), typed.type, arg.meta, pn);
			if (doDisplay && DisplayPosition.displayPosition.enclosedIn(pn)) context.display.DisplayEmitter.displayVariable(ctx, v, pn);
			if (i == 0 && TyperManager.isCoroutineContext(ctx)) checkCoroutineScope(v);
			if (typed.name != "_") ctx.f.locals = ctx.f.locals.add(v.vName, v);
			acc[i] = {variable: v, defaultValue: eo};
		}
		if (syntax.length + offset != withDefault.length) throw "Invalid function argument lists";
		exprRepr = acc;
		return acc;
	}

	// Verifies the validity of any argument typed as `haxe.extern.Rest` and checks default values.
	public function verifyExtern(ctx:TyperContext):Void {
		var offset = abstractThis == null ? 0 : 1;
		if (syntax.length + offset != withDefault.length) throw "Invalid function argument lists";
		for (i in offset...withDefault.length) {
			var typed = withDefault[i],
				arg = syntax[i - offset],
				last = i == withDefault.length - 1;
			delay(ctx.g, PTypeField, function() checkRest(last, typed.expr, arg.optional, typed.type, arg.name.pos));
			typeFunctionArgValue(ctx, typed.type, typed.expr, doDisplay);
		}
	}

	// Brings arguments into context by adding them to `ctx.f.locals`.
	public function bringIntoContext(ctx:TyperContext):Void {
		for (arg in forExpr(ctx)) ctx.f.locals = ctx.f.locals.add(arg.variable.vName, arg.variable);
	}
}
