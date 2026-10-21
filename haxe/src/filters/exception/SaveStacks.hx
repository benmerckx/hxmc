package filters.exception;

import core.TType;
import core.TFunctions as TypeOps;
import core.Meta;
import core.Error;
import filters.exception.Exceptions;
import filters.exception.ExceptionFunctions;
import core.ds.VectorTools.vector;

class SaveStacks {
	/**
		Inserts `haxe.NativeStackTrace.saveStack(e)` in non-haxe.Exception catches.
	**/
	public static function insertSaveStacks(ectx:ExceptionContext, scom:context.SafeCom.SafeContext):TExpr->TExpr {
		function containsInsertionPoints(e:TExpr):Bool return switch e.eexpr {
			case TTry(body, catches): core.ds.ArrayTools.exists(catches,
					c -> Meta.has(NeedsExceptionStack,
						c.variable.vMeta)) || containsInsertionPoints(body) || core.ds.ArrayTools.exists(catches,
					c -> containsInsertionPoints(c.expr));
			case _: core.Texpr.checkExpr(containsInsertionPoints, e);
		};
		inline function saveExceptionStack(catchVar:TVar):TExpr {
			var cls = ectx.haxeNativeStackTrace.force();
			if (!cls.clStatics.exists("saveStack")) Error.raiseTypingError("haxe.NativeStackTrace has no field saveStack", catchVar.vPos);
			var field = cls.clStatics.get("saveStack");
			var returnType = switch TypeOps.follow(field.cfType) {
				case TFun(sig): sig.ret;
				case _: Error.raiseTypingError("haxe.NativeStackTrace." + field.cfName + " is not a function and cannot be called",
						catchVar.vPos);
			};
			var local = TypeOps.mk(TLocal(catchVar), catchVar.vType, catchVar.vPos);
			return ExceptionFunctions.makeStaticCall(scom, cls, field, vector(local), returnType, catchVar.vPos);
		}
		function run(e:TExpr):TExpr return switch e.eexpr {
			case TTry(e1, catches):
				var e1 = core.Texpr.mapExpr(run, e1);
				var catches = catches.map(function(c) {
					if (!Meta.has(NeedsExceptionStack, c.variable.vMeta)) return c;
					var exprs = switch c.expr.eexpr {
						case TBlock(exprs): core.ds.VectorTools.cons(saveExceptionStack(c.variable), exprs);
						case _: vector(saveExceptionStack(c.variable), c.expr);
					};
					return {variable: c.variable, expr: TypeOps.mk(TBlock(exprs), c.expr.etype, c.expr.epos)};
				});
				TypeOps.mk(TTry(e1, catches), e.etype, e.epos);
			case _: core.Texpr.mapExpr(run, e);
		};
		return e -> containsInsertionPoints(e) ? run(e) : e;
	}

	/**
		Adds `this.__shiftStack()` calls to constructors of classes which extend `haxe.Exception`
	**/
	static function patchConstructorsContext(ectx:ExceptionContext):ModuleType->Void {
		var exception = ectx.haxeException.force();
		switch exception.type {
			/*
				Add only if `__shiftStack` method exists and has a constructor.

				If it doesn't have a constructor, that means it wasn't called and was removed during DCE.
				In this case, there is no need to patch it because the exception is never instantiated.
			*/
			case TInst(cls, _) if (cls.clFields.exists("__shiftStack") && cls.clConstructor != null):
			case _:
				return function(_) {};
		}
		return function(mt) {
			switch mt {
				case TClassDecl(cls)
					if (!TypeOps.hasClassFlag(cls, CExtern)
						&& !ExceptionFunctions.isHaxeExceptionClass(cls, false)
						&& ExceptionFunctions.isHaxeExceptionClass(cls)):
					function shiftStack(p:core.Globals.Pos):TExpr {
						var t = TypeOps.typeOfModuleType(mt);
						var ethis = TypeOps.mk(TConst(TThis), t, p);
						var faccess:TFieldAccess;
						try faccess = TypeOps.quickField(t, "__shiftStack")
						catch (_:Dynamic) {
							return Error.raiseTypingError("haxe.Exception has no field __shiftStack", p);
						}
						return switch faccess {
							case FInstance(_, _, cf):
								var efield = TypeOps.mk(TField(ethis, faccess), cf.cfType, p);
								var rt = switch TypeOps.follow(cf.cfType) {
									case TFun(sig): sig.ret;
									case _: Error.raiseTypingError("haxe.Exception.__shiftStack is not a function and cannot be called",
											cf.cfNamePos);
								};
								ExceptionFunctions.makeCall(ectx.scom, efield, vector(), rt, p);
							case _: Error.raiseTypingError("haxe.Exception.__shiftStack is expected to be an instance method", p);
						};
					}
					if (cls.clConstructor != null) TypeOps.follow(cls.clConstructor.cfType);
					var ctor = cls.clConstructor;
					if (ctor != null && ctor.cfExpr != null) {
						function add(e:TExpr):TExpr return switch e.eexpr {
							case TFunction(_): e;
							case TReturn(_): TypeOps.mk(TBlock(vector(shiftStack(e.epos), e)), e.etype, e.epos);
							case _: core.Texpr.mapExpr(add, e);
						};
						var eCtor = ctor.cfExpr;
						ctor.cfExpr = switch eCtor.eexpr {
							case TFunction(fn):
								var body = TypeOps.mk(TBlock(vector(add(fn.tfExpr), shiftStack(fn.tfExpr.epos))), ectx.scom.basic.tvoid,
									fn.tfExpr.epos);
								TypeOps.mk(TFunction({tfArgs: fn.tfArgs, tfType: fn.tfType, tfExpr: body}), eCtor.etype, eCtor.epos);
							case _: throw "saveStacks: constructor is not a function";
						};
					}
				case _:
			}
		};
	}

	public static function patchConstructors(ectx:Null<ExceptionContext>, scom:context.SafeCom.SafeContext):ModuleType->Void {
		if (ectx == null) return function(_) {};
		var ctx:ExceptionContext = core.ds.Record.copy(ectx);
		ctx.scom = scom;
		return patchConstructorsContext(ctx);
	}
}
