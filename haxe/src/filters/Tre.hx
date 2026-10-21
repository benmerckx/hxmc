package filters;

import core.Ast;
import core.TType;
import core.TFunctions as TypeOps;
import core.Globals;
import core.Meta;
import core.TOther.ExtType;
import core.Define;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

class Tre {
	public static function collectNewArgsValues(ctx:context.SafeCom.SafeContext, args:Vector<TExpr>, declarations:Array<TExpr>,
			values:Array<TExpr>, n:Int):{
		declarations:Array<TExpr>,
		values:Array<TExpr>
	} {
		for (arg in args) {
			var v = TypeOps.allocVar(VGenerated, "tmp", arg.etype, arg.epos);
			declarations.unshift(TypeOps.mk(TVar(v, arg), ctx.basic.tvoid, v.vPos));
			values.unshift(TypeOps.mk(TLocal(v), arg.etype, arg.epos));
			++n;
		}
		return {declarations: declarations, values: values};
	}

	// port: the list walk as a loop: the i-th expression, else the argument's default value
	public static function assignArgs(vars:Vector<{variable:TVar, defaultValue:Null<TExpr>}>, exprs:Array<TExpr>):Array<TExpr> {
		if (exprs.length > vars.length) throw "tre: argument arity";
		return [
			for (i in 0...vars.length) {
				var arg = vars[i];
				var e = i < exprs.length ? exprs[i] : arg.defaultValue;
				if (e == null) throw "tre: missing argument";
				var lhs = TypeOps.mk(TLocal(arg.variable), e.etype, e.epos);
				TypeOps.mk(TBinop(OpAssign, lhs, e), e.etype, e.epos);
			}
		];
	}

	public static function replacementForTReturn(ctx:context.SafeCom.SafeContext, fn:TFunc, args:Vector<TExpr>, p:Pos):TExpr {
		var collected = collectNewArgsValues(ctx, args, [], [], 0);
		collected.declarations.reverse();
		collected.values.reverse();
		var next = TypeOps.mk(TContinue, ctx.basic.tvoid, Globals.nullPos);
		var block = TypeOps.mk(TBlock(Vector.fromArrayCopy(collected.declarations.concat(assignArgs(fn.tfArgs, collected.values)).concat([next]))),
			ctx.basic.tvoid, p);
		return TypeOps.mk(TMeta({meta: core.MetaList.StrictMeta.TailRecursion, exprs: vector(), pos: Globals.nullPos}, block), ctx.basic.tvoid,
			p);
	}

	public static function collectCapturedArgs(args:Array<TVar>, e:TExpr):Array<TVar> {
		var result = [];
		function loop(inClosure:Bool, e:TExpr):Void switch e.eexpr {
			case TLocal(v = {vKind: VUser(TVOArgument)}) if (inClosure && !result.contains(v) && args.contains(v)):
				result.unshift(v);
			case TFunction(fn):
				loop(true, fn.tfExpr);
			case _:
				core.Texpr.iterWith(loop, inClosure, e);
		}
		loop(false, e);
		return result;
	}

	public static function redeclareVars(ctx:context.SafeCom.SafeContext, vars:Array<TVar>, declarations:Array<TExpr>,
			replaceList:Array<{old:TVar, replacement:TVar}>):{declarations:Array<TExpr>, replaceList:Array<{old:TVar, replacement:TVar}>} {
		for (v in vars) {
			var newV = TypeOps.allocVar(VGenerated, core.Globals.genLocalPrefix + v.vName, v.vType, v.vPos);
			declarations.unshift(TypeOps.mk(TVar(newV, TypeOps.mk(TLocal(v), v.vType, v.vPos)), ctx.basic.tvoid, v.vPos));
			replaceList.unshift({old: v, replacement: newV});
		}
		return {declarations: declarations, replaceList: replaceList};
	}

	public static function replaceVars(replaceList:Array<{old:TVar, replacement:TVar}>, inTailRecursion:Bool, e:TExpr):TExpr {
		return switch e.eexpr {
			case TBinop(OpAssign, arg = {eexpr: TLocal({vKind: VUser(TVOArgument)})}, value) if (inTailRecursion):
				TypeOps.mk(TBinop(OpAssign, arg, replaceVars(replaceList, inTailRecursion, value)), e.etype, e.epos);
			case TLocal(v):
				var replaced = v;
				for (entry in replaceList) if (entry.old == v) {
					replaced = entry.replacement;
					break;
				}
				replaced == v ? e : TypeOps.mk(TLocal(replaced), e.etype, e.epos);
			case TMeta({meta: core.MetaList.StrictMeta.TailRecursion}, _): core.Texpr.mapExpr(e -> replaceVars(replaceList, true, e), e);
			case _: core.Texpr.mapExpr(e -> replaceVars(replaceList, inTailRecursion, e), e);
		};
	}

	public static function wrapLoop(ctx:context.SafeCom.SafeContext, args:Array<TVar>, body:TExpr):TExpr {
		function wrap(e:TExpr):TExpr return TypeOps.mk(TWhile(TypeOps.mk(TConst(TBool(true)), ctx.basic.tbool, Globals.nullPos), e,
			NormalWhile), e.etype, e.epos);
		var captured = collectCapturedArgs(args, body);
		if (captured.length == 0) return wrap(body);
		var redeclared = redeclareVars(ctx, captured, [], []);
		return wrap(TypeOps.mk(TBlock(Vector.fromArrayCopy(redeclared.declarations.concat([replaceVars(redeclared.replaceList, false, body)]))), body.etype,
			body.epos));
	}

	public static function fnArgsVars(fn:TFunc):Array<TVar> return fn.tfArgs.mapToArray(a -> a.variable);

	public static function isRecursiveNamedLocalCall(fnVar:TVar, callee:TExpr, args:Vector<TExpr>):Bool return switch callee.eexpr {
		// named local function
		case TLocal(v): v == fnVar;
		case _: false;
	};

	public static function isRecursiveMethodCall(cls:TClass, field:TClassField, callee:TExpr, args:Vector<TExpr>):Bool {
		return switch callee.eexpr {
			case TField(_, FStatic(_, cf)):
				// member abstract function
				if (args.length > 0) switch args[0].eexpr {
					case TLocal(v) if (TypeOps.hasClassFieldFlag(cf, CfImpl)): return cf == field && Meta.has(This, v.vMeta);
					case _:
				}
				// static method
				cf == field;
			case _: false;
		};
	}

	public static function transformFunction(ctx:context.SafeCom.SafeContext, isRecursiveCall:TExpr->Vector<TExpr>->Bool, fn:TFunc):TFunc {
		var addLoop = false;
		function transformExpr(cancelTre:Bool, functionEnd:Bool, e:TExpr):TExpr {
			return switch e.eexpr {
				// cancel tre inside of loops bodies
				case TWhile(_, _, _): core.Texpr.mapExpr(e -> transformExpr(true, false, e), e);
				// cancel tre inside of try blocks
				case TTry(eTry, catches):
					var eTry = transformExpr(true, functionEnd, eTry);
					var catches = catches.map(c -> {variable: c.variable, expr: transformExpr(cancelTre, functionEnd, c.expr)});
					TypeOps.mk(TTry(eTry, catches), e.etype, e.epos);
				// named local function
				case TBinop(OpAssign, eVar = {eexpr: TLocal(v = {vKind: VUser(TVOLocalFunction)})}, eFn = {eexpr: TFunction(localFn)}):
					var transformed = transformFunction(ctx, (callee, args) -> isRecursiveNamedLocalCall(v, callee, args), localFn);
					TypeOps.mk(TBinop(OpAssign, eVar, TypeOps.mk(TFunction(transformed), eFn.etype, eFn.epos)), e.etype, e.epos);
				// anonymous function
				case TFunction(_): e;
				// return a recursive call to current function
				case TReturn({eexpr: TCall(callee, args)}) if (!cancelTre && isRecursiveCall(callee, args)):
					addLoop = true;
					replacementForTReturn(ctx, fn, args, e.epos);
				case TReturn(eReturn) if (eReturn != null): TypeOps.mk(TReturn(transformExpr(cancelTre, functionEnd, eReturn)), e.etype,
						e.epos);
				case TBlock(exprs):
					// port: `loop` walks `exprs` from `i` on (upstream: its tail)
					function loop(i:Int):Vector<TExpr> {
						if (exprs.length - i == 0) return vector();
						var head = exprs[i];
						switch head.eexpr {
							case TCall(callee, args) if (!cancelTre && isRecursiveCall(callee, args)):
								if (exprs.length - i == 1 && functionEnd) {
									addLoop = true;
									return vector(replacementForTReturn(ctx, fn, args, head.epos));
								}
								if (exprs.length - i == 2) switch exprs[i + 1].eexpr {
									case TReturn(null):
										addLoop = true;
										return vector(replacementForTReturn(ctx, fn, args, e.epos));
									case _:
								}
							case _:
						}
						var x = transformExpr(cancelTre, functionEnd && exprs.length - i == 1, head);
						return VectorTools.cons(x, loop(i + 1));
					}
					TypeOps.mk(TBlock(loop(0)), e.etype, e.epos);
				case _: core.Texpr.mapExpr(e -> transformExpr(cancelTre, functionEnd, e), e);
			};
		}
		var body = transformExpr(false, true, fn.tfExpr);
		if (addLoop) {
			if (ExtType.isVoid(TypeOps.follow(fn.tfType))) body = TypeOps.mk(TBlock(vector(body, TypeOps.mk(TReturn(null), ctx.basic.tvoid,
				Globals.nullPos))), ctx.basic.tvoid, Globals.nullPos);
			body = wrapLoop(ctx, fnArgsVars(fn), body);
		}
		return {tfArgs: fn.tfArgs, tfType: fn.tfType, tfExpr: body};
	}

	public static function hasTailRecursion(isRecursiveCall:TExpr->Vector<TExpr>->Bool, cancelTre:Bool, functionEnd:Bool, e:TExpr):Bool {
		return switch e.eexpr {
			// cancel tre inside of loops bodies
			case TWhile(_, _, _): core.Texpr.checkExpr(e -> hasTailRecursion(isRecursiveCall, true, false, e), e);
			// cancel tre inside of try blocks
			case TTry(body, catches): hasTailRecursion(isRecursiveCall, true, functionEnd,
					body) || core.ds.ArrayTools.exists(catches, c -> hasTailRecursion(isRecursiveCall, cancelTre, functionEnd, c.expr));
			// named local function
			case TBinop(OpAssign, {eexpr: TLocal(v = {vKind: VUser(TVOLocalFunction)})}, {eexpr: TFunction(fn)}):
				hasTailRecursion((callee, args) -> isRecursiveNamedLocalCall(v, callee, args), false, true, fn.tfExpr);
			// anonymous function
			case TFunction(_): false;
			case TReturn({eexpr: TCall(callee, args)}): !cancelTre && isRecursiveCall(callee, args);
			case TBlock(exprs):
				// port: `loop` walks `exprs` from `i` on (upstream: its tail)
				function loop(i:Int):Bool {
					if (exprs.length - i == 0) return false;
					switch exprs[i].eexpr {
						case TCall(callee, args) if (!cancelTre):
							if (exprs.length - i == 1 && functionEnd) return isRecursiveCall(callee, args);
							if (exprs.length - i == 2) switch exprs[i + 1].eexpr {
								case TReturn(null): return isRecursiveCall(callee, args);
								case _:
							}
						case _:
					}
					return hasTailRecursion(isRecursiveCall, cancelTre, functionEnd && exprs.length - i == 1, exprs[i])
						|| loop(i + 1);
				}
				loop(0);
			case _: core.Texpr.checkExpr(e -> hasTailRecursion(isRecursiveCall, cancelTre, functionEnd, e), e);
		};
	}

	public static function run(ctx:context.SafeCom.SafeContext):TExpr->TExpr {
		if (Define.defined(ctx.defines, Define.NoTre)) return e->e;
		return function(e) {
			return switch e.eexpr {
				case TFunction(fn):
					var eligible = switch ctx.curfield.cfKind {
						case Method(MethDynamic): false;
						case Method(MethInline): true;
						case Method(MethNormal): ctx.curclass.clStatics.exists(ctx.curfield.cfName);
						case _: TypeOps.hasClassFieldFlag(ctx.curfield, CfFinal);
					};
					var recursive = (callee, args) -> eligible && isRecursiveMethodCall(ctx.curclass, ctx.curfield, callee, args);
					// print_endline ("TRE: " ^ ctx.f.curfield.cf_pos.pfile ^ ": " ^ ctx.f.curfield.cf_name);
					hasTailRecursion(recursive, false, true,
						fn.tfExpr) ? TypeOps.mk(TFunction(transformFunction(ctx, recursive, fn)), e.etype, e.epos) : e;
				case _: e;
			};
		};
	}
}
