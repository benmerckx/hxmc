package filters.exception;

import core.TType;
import core.TFunctions as TypeOps;
import core.Globals;
import core.Meta;
import context.SafeCom;
import context.PlatformConfig;
import core.ds.AtomicLazy;
import core.Error;
import core.Abstract;
import typing.TyperBase;
import filters.exception.ExceptionFunctions;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

@:structInit class ExceptionContext {
	public var scom:SafeContext;
	public var basic:BasicTypes;
	public var config:ExceptionsConfig;
	public var wildcardCatchType:T;
	public var baseThrowType:T;
	public var throwsAnything:Bool;
	public var catchesAnything:Bool;
	public var haxeException:AtomicLazy<{type:T, cls:TClass}>;
	public var haxeNativeStackTrace:AtomicLazy<TClass>;
	public var valueException:AtomicLazy<{type:T, cls:TClass}>;
	public var isOfType:{cls:TClass, field:TClassField, returnType:T};

	public inline function new(scom:SafeContext, basic:BasicTypes, config:ExceptionsConfig, wildcardCatchType:T, baseThrowType:T,
			throwsAnything:Bool, catchesAnything:Bool, haxeException:AtomicLazy<{
			type:T,
			cls:TClass
		}>,
			haxeNativeStackTrace:AtomicLazy<TClass>, valueException:AtomicLazy<{type:T, cls:TClass}>,
			isOfType:{cls:TClass, field:TClassField, returnType:T}) {
		this.scom = scom;
		this.basic = basic;
		this.config = config;
		this.wildcardCatchType = wildcardCatchType;
		this.baseThrowType = baseThrowType;
		this.throwsAnything = throwsAnything;
		this.catchesAnything = catchesAnything;
		this.haxeException = haxeException;
		this.haxeNativeStackTrace = haxeNativeStackTrace;
		this.valueException = valueException;
		this.isOfType = isOfType;
	}

	public inline function clone():ExceptionContext return new ExceptionContext(scom, basic, config, wildcardCatchType, baseThrowType,
		throwsAnything, catchesAnything, haxeException, haxeNativeStackTrace, valueException, isOfType);
}

typedef CatchClause = {var variable:TVar; var expr:TExpr;}

class Exceptions {
	public static function haxeExceptionClass(ctx:ExceptionContext):TClass {
		var cls = ctx.haxeException.force().cls;
		if (ctx.scom.curclass == TypeOps.nullClass) throw "assert: current class";
		TypeOps.addDependency(ctx.scom.curclass.clModule, cls.clModule, MDepFromTyping);
		return cls;
	}

	public static function haxeExceptionType(ctx:ExceptionContext):T {
		var value = ctx.haxeException.force();
		if (ctx.scom.curclass == TypeOps.nullClass) throw "assert: current class";
		TypeOps.addDependency(ctx.scom.curclass.clModule, value.cls.clModule, MDepFromTyping);
		return value.type;
	}

	public static function valueExceptionClass(ctx:ExceptionContext):TClass {
		var cls = ctx.valueException.force().cls;
		if (ctx.scom.curclass == TypeOps.nullClass) throw "assert: current class";
		TypeOps.addDependency(ctx.scom.curclass.clModule, cls.clModule, MDepFromTyping);
		return cls;
	}

	public static function valueExceptionType(ctx:ExceptionContext):T {
		var value = ctx.valueException.force();
		if (ctx.scom.curclass == TypeOps.nullClass) throw "assert: current class";
		TypeOps.addDependency(ctx.scom.curclass.clModule, value.cls.clModule, MDepFromTyping);
		return value.type;
	}

	/**
		Generate `haxe.Exception.method_name(args)`
	**/
	public static function haxeExceptionStaticCall(ctx:ExceptionContext, name:String, args:haxe.ds.Vector<TExpr>, p:Pos):TExpr {
		var fields = haxeExceptionClass(ctx).clStatics;
		if (!fields.exists(name)) Error.raiseTypingError("haxe.Exception has no field " + name, p);
		var field = fields.get(name);
		var rt = switch TypeOps.follow(field.cfType) {
			case TFun(sig): sig.ret;
			case _: Error.raiseTypingError("haxe.Exception." + name + " is not a function and cannot be called", p);
		};
		return ExceptionFunctions.makeStaticCall(ctx.scom, haxeExceptionClass(ctx), field, args, rt, p);
	}

	/**
		Generate `haxe_exception.method_name(args)`
	**/
	public static function haxeExceptionInstanceCall(ctx:ExceptionContext, hx:TExpr, name:String, args:haxe.ds.Vector<TExpr>, p:Pos):TExpr {
		var access = TypeOps.quickField(hx.etype, name);
		return switch access {
			case FInstance(_, _, cf):
				var efield = TypeOps.mk(TField(hx, access), cf.cfType, p);
				var rt = switch TypeOps.follow(cf.cfType) {
					case TFun(sig): sig.ret;
					case _: Error.raiseTypingError(core.TPrinting.sType(core.TPrinting.printContext(), hx.etype)
							+ "."
							+ name
							+ " is not a function and cannot be called",
							p);
				};
				ExceptionFunctions.makeCall(ctx.scom, efield, args, rt, p);
			case _: Error.raiseTypingError(core.TPrinting.sType(core.TPrinting.printContext(), hx.etype)
					+ "."
					+ name
					+ " is expected to be an instance method", p);
		};
	}

	public static function addMetaExceptionTypeCheck(e:TExpr):TExpr {
		return TypeOps.mk(TMeta({meta: core.MetaList.StrictMeta.ExceptionTypeCheck, exprs: vector(), pos: e.epos}, e), e.etype, e.epos);
	}

	/**
		Generate `Std.isOfType(e, t)`
	**/
	public static function stdIs(ctx:ExceptionContext, e:TExpr, t:T, p:Pos):TExpr {
		var typeExpr = TyperBase.typeModuleTypeSimple(TypeOps.moduleTypeOfType(TypeOps.follow(t)), p);
		var std = ctx.isOfType;
		return addMetaExceptionTypeCheck(ExceptionFunctions.makeStaticCall(ctx.scom, std.cls, std.field, vector(e, typeExpr), std.returnType, p));
	}

	/**
		Check if type path of `t` exists in `lst`
	**/
	public static function isInList(t:T, lst:Array<GlobalTypePath>):Bool {
		inline function contains(path:GlobalTypePath):Bool return core.ds.ArrayTools.exists(lst,
			p -> p.name == path.name && p.pack.join(".") == path.pack.join("."));
		function check(cls:TClass):Bool return contains(cls.clPath)
			|| core.ds.ArrayTools.exists(cls.clImplements, c -> check(c.cls))
			|| cls.clSuper != null
			&& check(cls.clSuper.cls);
		return switch Abstract.followWithAbstracts(t) {
			case TInst(_, _): switch TypeOps.follow(t) {
					case TInst(cls, _): check(cls);
					case _: false;
				}
			case TAbstract({aPath: path}, _) | TEnum({ePath: path}, _): contains(path);
			case _: false;
		};
	}

	/**
		Check if `t` can be thrown without wrapping.
	**/
	public static function isNativeThrow(ctx:ExceptionContext,
			t:T):Bool return ctx.throwsAnything || isInList(t, ctx.config.ecNativeThrows);

	/**
		Check if `t` can be caught without wrapping.
	**/
	public static function isNativeCatch(ctx:ExceptionContext,
			t:T):Bool return ctx.catchesAnything || isInList(t, ctx.config.ecNativeCatches);

	/**
		Check if `t` can be used for a Haxe-specific wildcard catch.
		E.g `catch(e:Dynamic)` or `catch(e:haxe.Exception)`
	**/
	public static function isHaxeWildcardCatch(ctx:ExceptionContext, t:T):Bool {
		var t = Abstract.followWithAbstracts(t);
		return t == TypeOps.tDynamic || core.TUnification.fastEq(haxeExceptionType(ctx), t);
	}

	/**
		Check if `v` variable is used in `e` expression
	**/
	public static function isVarUsed(v:TVar, e:TExpr):Bool return switch e.eexpr {
		case TLocal(v2): v == v2;
		case _: core.Texpr.checkExpr(e -> isVarUsed(v, e), e);
	};

	/**
		Check if `e` contains any throws or try..catches.
	**/
	public static function containsThrowOrTry(e:TExpr):Bool return switch e.eexpr {
		case TThrow(_) | TTry(_, _): true;
		case _: core.Texpr.checkExpr(containsThrowOrTry, e);
	};

	/**
		Check if expression represents an exception wrapped with `haxe.Exception.thrown`
	**/
	public static function isWrappedException(e:TExpr):Bool return switch e.eexpr {
		case TMeta({meta: core.MetaList.StrictMeta.WrappedException}, _): true;
		case _: false;
	};

	/**
		Returns `true` if `e` has to be wrapped with `haxe.Exception.thrown(e)`
		to be thrown.
	**/
	public static function requiresWrappedThrow(ctx:ExceptionContext, e:TExpr):Bool {
		if (ctx.throwsAnything || isWrappedException(e) || ctx.config.ecSpecialThrow(e)) return false;
		/*
			Check if `e` is of `haxe.Exception` type directly (not a descendant),
			but not a `new haxe.Exception(...)` expression.
			In this case we delegate the decision to `haxe.Exception.thrown(e)`.
			Because it could happen to be a wrapper for a wildcard catch.
		*/
		var stored = ExceptionFunctions.isHaxeException(e.etype, false) && switch e.eexpr {
			case TNew(_, _, _): false;
			case _: true;
		};
		return stored || !isNativeThrow(ctx, e.etype) && !ExceptionFunctions.isHaxeException(e.etype);
	}

	/**
		Generate a throw of a native exception.
	**/
	public static function throwNative(ctx:ExceptionContext, eThrown:TExpr, t:T, p:Pos):TExpr {
		if (!requiresWrappedThrow(ctx, eThrown)) return eThrown;
		var thrown = haxeExceptionStaticCall(ctx, "thrown", vector(eThrown), p);
		var wrapped = ExceptionFunctions.isDynamic(ctx.baseThrowType) ? thrown : TypeOps.mkCast(thrown, ctx.baseThrowType, p);
		return TypeOps.mk(TMeta({meta: core.MetaList.StrictMeta.WrappedException, exprs: vector(), pos: p}, wrapped), wrapped.etype, p);
	}

	public static function setNeedsExceptionStack(v:TVar):Void {
		if (!Meta.has(NeedsExceptionStack, v.vMeta)) v.vMeta = ([
			{meta: core.MetaList.StrictMeta.NeedsExceptionStack, exprs: vector(), pos: Globals.nullPos}
		] : Array<core.Ast.MetadataEntry>).concat(v.vMeta);
	}

	/**
		Transforms the set of catch-blocks into `if(Std.is(e, ExceptionType)`-fest.

		`t` - the type of `try...catch` expression under transformation.
	**/
	public static function catchesToIfs(ctx:ExceptionContext, catches:Array<CatchClause>, t:T, p:Pos):Array<CatchClause> {
		if (catches.length == 0) return [];
		var catchVar = TypeOps.allocVar(VGenerated, core.Globals.genLocalPrefix, ctx.wildcardCatchType, catches[0].variable.vPos);
		TypeOps.addVarFlag(catchVar, VCaught);
		var catchLocal = TypeOps.mk(TLocal(catchVar), catchVar.vType, catchVar.vPos);
		var caught = new ExceptionCatch(ctx, catchLocal, p);
		function transform(rest:Array<CatchClause>):TExpr {
			if (rest.length == 0) return TypeOps.mk(TThrow(catchLocal), t, p);
			var current = rest[0];
			var v = current.variable;
			var body = current.expr;
			var currentT = Abstract.followWithAbstracts(v.vType);
			var varUsed = isVarUsed(v, body);
			var condition:TExpr;
			// catch(e:ExtendsHaxeError)
			if (ExceptionFunctions.isHaxeException(currentT)) {
				// catch(e:haxe.Exception) is a wildcard catch
				condition = core.TUnification.fastEq(haxeExceptionType(ctx),
					currentT) ? addMetaExceptionTypeCheck(TypeOps.mk(TConst(TBool(true)), ctx.basic.tbool,
						v.vPos)) : stdIs(ctx, caught.getHaxeException(v.vPos), v.vType, v.vPos);
				if (varUsed) body = TypeOps.mk(TBlock(vector(
					// var v:ExceptionType = cast haxe_exception_local;
					TypeOps.mk(TVar(v, TypeOps.mkCast(caught.getHaxeException(v.vPos), v.vType, v.vPos)), ctx.basic.tvoid, v.vPos),
					body
				)), body.etype, body.epos);
			} else if (currentT == TypeOps.tDynamic) { // catch(e:Dynamic)
				setNeedsExceptionStack(catchVar);
				// this is a wildcard catch
				condition = TypeOps.mk(TConst(TBool(true)), ctx.basic.tbool, v.vPos);
				// `var v:Dynamic = catch_local;` or `var v:Dynamic = haxe_exception_local.unwrap();`
				var decl = varUsed ? TypeOps.mk(TVar(v, ctx.catchesAnything ? catchLocal : caught.unwrap(v.vPos)), ctx.basic.tvoid,
					v.vPos) : TypeOps.mk(TBlock(vector()), ctx.basic.tvoid, v.vPos);
				body = TypeOps.mk(TBlock(vector(decl, body)), body.etype, body.epos);
			} else if (core.TUnification.fastEq(ctx.wildcardCatchType, currentT)) { // catch(e:NativeWildcardException)
				setNeedsExceptionStack(catchVar);
				// this is a wildcard catch
				condition = TypeOps.mk(TConst(TBool(true)), ctx.basic.tbool, v.vPos);
				// var v:NativeWildcardException = catch_var;
				var decl = varUsed ? TypeOps.mk(TVar(v, catchLocal), ctx.basic.tvoid,
					v.vPos) : TypeOps.mk(TBlock(vector()), ctx.basic.tvoid, v.vPos);
				body = TypeOps.mk(TBlock(vector(decl, body)), body.etype, body.epos);
			} else { // catch(e:AnythingElse)
				setNeedsExceptionStack(catchVar);
				// Std.isOfType(haxe_exception_local.unwrap(), ExceptionType)
				condition = stdIs(ctx, caught.unwrap(v.vPos), v.vType, v.vPos);
				// var v:ExceptionType = cast haxe_exception_local.unwrap()
				var decl = varUsed ? TypeOps.mk(TVar(v, TypeOps.mkCast(caught.unwrap(v.vPos), v.vType, v.vPos)), ctx.basic.tvoid,
					v.vPos) : TypeOps.mk(TBlock(vector()), ctx.basic.tvoid, v.vPos);
				body = TypeOps.mk(TBlock(vector(decl, body)), body.etype, body.epos);
			}
			var remaining = rest.slice(1);
			var elseBody = remaining.length == 0 ? TypeOps.mk(TThrow(catchLocal), TypeOps.mkMono(), p) : transform(remaining);
			return TypeOps.mk(TIf(condition, body, elseBody), t, p);
		}
		var transformed = transform(catches);
		// port: upstream builds `[declare_haxe_exception; declare_unwrap; transformed]`
		// and relies on OCaml right-to-left evaluation: declare_unwrap runs
		// first, so the haxe.Exception temporary allocated through
		// get_haxe_exception while building the unwrap declaration is already
		// known when declare_haxe_exception emits its declaration. Haxe
		// evaluates array literals left-to-right, so sequence explicitly to
		// keep document order `[declHx, declUnwrap, ifs]` with all generated
		// variables declared before use.
		// haxe.Exception.caught(catch_var)
		// var unwrapped_local = haxe_exception_local.unwrap();
		var declUnwrap = caught.declareUnwrap(catchVar.vPos);
		// var haxe_exception_local = haxe.Exception.caught(catch_var);
		var declHx = caught.declareHaxeException(catchVar.vPos);
		var exprs = vector(declHx, declUnwrap, transformed);
		return [{variable: catchVar, expr: TypeOps.mk(TBlock(exprs), t, p)}];
	}

	/**
		Transforms set of catches into
		```
		catch(e:ValueException) {
			if(Std.isOfType(e.value, Exception1)) {
				<...>
			} else if(Std.isOfType(e.value, Exception2)) {
				<...>
			} else <...>
		}
		```
	**/
	public static function catchesAsValueException(ctx:ExceptionContext, nonValue:Array<CatchClause>, valueCatch:Null<CatchClause>, t:T,
			p:Pos):CatchClause {
		if (nonValue.length == 0) {
			if (valueCatch == null) throw "Nothing to transform into ValueException catch";
			return valueCatch;
		}
		var catchVar:TVar;
		if (valueCatch != null) catchVar = valueCatch.variable;
		else {
			catchVar = TypeOps.allocVar(VGenerated, core.Globals.genLocalPrefix, valueExceptionType(ctx), nonValue[0].variable.vPos);
			TypeOps.addVarFlag(catchVar, VCaught);
		}
		var catchLocal = TypeOps.mk(TLocal(catchVar), catchVar.vType, catchVar.vPos);
		// catch_local.value
		var fields = valueExceptionClass(ctx).clFields;
		if (!fields.exists("value")) throw 'haxe.ValueException is missing field "value"';
		var cf = fields.get("value");
		var catchLocalValue = TypeOps.mk(TField(catchLocal, FInstance(valueExceptionClass(ctx), vector(), cf)), cf.cfType, catchLocal.epos);
		function traverse(catches:Array<CatchClause>, finalElse:TExpr):TExpr {
			if (catches.length == 0) return finalElse;
			var c = catches[0];
			var v = c.variable;
			var body = c.expr;
			setNeedsExceptionStack(catchVar);
			// Std.isOfType(catch_local.value, ExceptionType)
			var condition = stdIs(ctx, catchLocalValue, v.vType, v.vPos);
			// var v:ExceptionType = cast catch_local.value
			var decl = isVarUsed(v,
				body) ? TypeOps.mk(TVar(v, TypeOps.mkCast(catchLocalValue, v.vType, v.vPos)), ctx.basic.tvoid,
					v.vPos) : TypeOps.mk(TBlock(vector()), ctx.basic.tvoid, v.vPos);
			body = TypeOps.mk(TBlock(vector(decl, body)), body.etype, body.epos);
			return TypeOps.mk(TIf(condition, body, traverse(catches.slice(1), finalElse)), t, p);
		}
		var finalElse = valueCatch == null ? TypeOps.mk(TThrow(catchLocal), TypeOps.tDynamic, p) : valueCatch.expr;
		return {variable: catchVar, expr: traverse(nonValue, finalElse)};
	}

	/**
		Transform user-written `catches` to a set of catches, which would not require
		special handling in the target generator.

		For example:
		```
		} catch(e:SomeNativeError) {
			doStuff();
		} catch(e:String) {
			trace(e);
		}
		```
		is transformed into
		```
		} catch(e:SomeNativeError) {
			doStuff();
		} catch(etmp:WildCardNativeException) {
			var ehx:haxe.Exception = haxe.Exception.caught(etmp);
			if(Std.isOfType(ehx.unwrap(), String)) {
				var e:String = ehx.unwrap();
				trace(e);
			} else {
				throw etmp;
			}
		}
		```
	**/
	public static function catchNative(ctx:ExceptionContext, catches:Array<CatchClause>, t:T, p:Pos):Array<CatchClause> {
		function transform(handleAsValue:Array<CatchClause>, valueCatch:Null<CatchClause>, catches:Array<CatchClause>):Array<CatchClause> {
			if (catches.length == 0) {
				if (handleAsValue.length == 0) return valueCatch == null ? [] : catchesToIfs(ctx, [valueCatch], t, p);
				return [catchesAsValueException(ctx, handleAsValue, null, t,
					p)].concat(valueCatch == null ? [] : catchesToIfs(ctx, [valueCatch], t, p));
			}
			var current = catches[0];
			var v = current.variable;
			var rest = catches.slice(1);
			// Haxe-specific wildcard catches should go to if-fest because they need additional handling
			if (isHaxeWildcardCatch(ctx, v.vType)) {
				if (handleAsValue.length == 0) return catchesToIfs(ctx, valueCatch == null ? catches : [valueCatch].concat(catches), t, p);
				return [catchesAsValueException(ctx, handleAsValue, null, t, p)].concat(catchesToIfs(ctx, catches, t, p));
			}
			if (ctx.catchesAnything && core.TUnification.fastEq(valueExceptionType(ctx), Abstract.followWithAbstracts(v.vType)))
				return [catchesAsValueException(ctx, handleAsValue, current, t,
					p)].concat(transform([], valueCatch == null ? current : valueCatch, rest));
			// Keep catches for native exceptions intact
			if (isNativeCatch(ctx, v.vType)) {
				/*
					If current target can catch any type natively, then we also need
					to check if `new haxe.ValueException(value)` with the same type of
					`value` was thrown. That is, we should be able to catch `throw 'error'`
					and `throw new ValueException('error')` with a single `catch(e:String)`
					expression in user's code to be consistent with targets which can't
					catch arbitrary types.
				*/
				if (ctx.catchesAnything && !ExceptionFunctions.isHaxeException(v.vType)) handleAsValue = [current].concat(handleAsValue);
				return [current].concat(transform(handleAsValue, valueCatch, rest));
			}
			// everything else goes to if-fest
			return catchesToIfs(ctx, handleAsValue.concat(catches), t, p);
		}
		return transform([], null, catches);
	}

	/**
		Transform `throw` and `try..catch` expressions.
		`rename_locals` is required to deal with the names of temp vars.
	**/
	public static function filter(ectx:Null<ExceptionContext>, scom:context.SafeCom.SafeContext):TExpr->TExpr {
		if (ectx == null) return e->e;
		var ctx:ExceptionContext = core.ds.Record.copy(ectx);
		ctx.scom = scom;
		function run(e:TExpr):TExpr return switch e.eexpr {
			case TThrow(e1): TypeOps.mk(TThrow(throwNative(ctx, run(e1), e.etype, e.epos)), e.etype, e.epos);
			case TTry(e1, catches):
				var catches = catchNative(ctx,
					catches.mapToArray(c -> ({variable: c.variable, expr: run(c.expr)} : filters.exception.Exceptions.CatchClause)), e.etype,
					e.epos);
				TypeOps.mk(TTry(run(e1), haxe.ds.Vector.fromArrayCopy(catches)), e.etype, e.epos);
			case _: core.Texpr.mapExpr(run, e);
		};
		return e -> containsThrowOrTry(e) ? run(e) : e;
	}
}

class ExceptionCatch {
	var ctx:ExceptionContext;
	var catchLocal:TExpr;
	var catchPos:Pos;
	var hxExceptionVar:Null<TVar> = null;
	var unwrappedVar:Null<TVar> = null;

	public function new(ctx:ExceptionContext, catchLocal:TExpr, catchPos:Pos) {
		this.ctx = ctx;
		this.catchLocal = catchLocal;
		this.catchPos = catchPos;
	}

	public function getHaxeException(p:Pos):TExpr {
		if (hxExceptionVar == null) hxExceptionVar = TypeOps.allocVar(VGenerated, core.Globals.genLocalPrefix,
			Exceptions.haxeExceptionType(ctx), p);
		return TypeOps.mk(TLocal(hxExceptionVar), hxExceptionVar.vType, p);
	}

	public function unwrap(p:Pos):TExpr {
		if (unwrappedVar == null) unwrappedVar = TypeOps.allocVar(VGenerated, core.Globals.genLocalPrefix, TypeOps.tDynamic, p); // unwrapped_local <- Some e;
		return TypeOps.mk(TLocal(unwrappedVar), unwrappedVar.vType, p);
	}

	public function declareHaxeException(p:Pos):TExpr {
		return hxExceptionVar == null ? TypeOps.mk(TBlock(vector()), ctx.basic.tvoid,
			p) : TypeOps.mk(TVar(hxExceptionVar, Exceptions.haxeExceptionStaticCall(ctx, "caught", vector(catchLocal), p)), ctx.basic.tvoid, p);
	}

	public function declareUnwrap(p:Pos):TExpr {
		return unwrappedVar == null ? TypeOps.mk(TBlock(vector()), ctx.basic.tvoid,
			p) : TypeOps.mk(TVar(unwrappedVar, Exceptions.haxeExceptionInstanceCall(ctx, getHaxeException(p), "unwrap", vector(), p)),
			ctx.basic.tvoid, p);
	}
}
