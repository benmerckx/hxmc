package typing;

import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.Abstract as AbstractTools;
import core.Ast;
import core.Ast.*;
import core.TType;
import core.TType.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.TPrinting.*;
import core.Globals;
import core.Meta;
import core.WithType;
import core.Error.*;
import core.Error;
import context.Typecore.*;
import context.Typecore;
import context.Common;
import context.Common.*;
import core.Globals.*;
import core.TUnification.TUnification.*;
import core.Texpr.Builder;
import typing.FieldCallCandidate.FieldCallCandidateData;
import codegen.Overloads.Resolution;
import compiler.MessageReporting;
import context.Typecore.Typer as TyperContext;
import core.TUnification;
import core.Texpr;
import core.ds.AtomicLazy;
import core.Message;
import context.Typecore.TyperManager;
import typing.FieldAccess;
import typing.FieldAccess.*;
import typing.FieldCallCandidate.*;
import typing.CallUnification.*;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

typedef CallAttemptData = {var call:Void->TExpr; var display:Null<core.DisplayTypes.DisplayExceptionKind>;}
typedef CallAttemptFailure = {var field:TClassField; var error:CompilerError; var display:Null<core.DisplayTypes.DisplayExceptionKind>;}
typedef CallAttempts = {var candidates:Array<FieldCallCandidateData<CallAttemptData>>; var failures:Array<CallAttemptFailure>;}
typedef CallParameter = {var name:String; var optional:Bool; var type:T;}

enum OverloadKind {
	OverloadProper; // @:overload or overload
	OverloadMeta; // @:overload(function() {})
	OverloadNone;
}

class CallUnification {
	public static function unifyCallArgs(ctx:TyperContext, el:Vector<Expr>, args:Vector<CallParameter>, r:T, callp:Pos, isInline:Bool,
			forceInline:Bool, inOverload:Bool, ?callFieldP:Pos):Vector<TExpr> {
		if (callFieldP == null) callFieldP = callp;
		inline function callError(err:core.Error.CallError, p:Pos):Dynamic return raiseErrorMsg(CallError(err), p);
		inline function argError(e:CompilerError, name:String, opt:Bool):Dynamic {
			var msg = "For " + (opt ? "optional " : "") + "function argument '" + name + "'",
				copy = core.ds.Record.copy(e);
			switch e.errMessage {
				case Unify(l):
					copy.errMessage = Unify(l.concat([UnifyCustom(msg)]));
				case _:
					copy.errSub = [makeError(Custom(complMsg(msg)), e.errPos)].concat(e.errSub);
			}
			copy.errMessage = CallError(CouldNotUnify(copy.errMessage));
			return raiseError(copy);
		}
		inline function posInfos(t:T):TExpr return mkInfosT(ctx, callp, [], t);
		inline function defaultValue(name:String, t:T):TExpr return isPosInfos(t) ? posInfos(t) : nullExpr(ctx.t.tnull(t), callp);
		var skipped:Array<{name:String, error:CompilerError}> = [],
			invalidSkips:Array<String> = [];
		inline function skip(name:String, ul:CompilerError, t:T):TExpr {
			if (!ctx.com.config.pfCanSkipNonNullableArgument && !isNullable(t)) invalidSkips.unshift(name);
			skipped.unshift({name: name, error: ul});
			return defaultValue(name, t);
		}
		function handleErrors(fn:Void->TExpr):TExpr {
			try return fn()
			catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some(e)):
						switch e.errMessage {
							case CallError(_) | ModuleNotFound(_): throw exc;
							case _: throw new context.Typecore.WithTypeError(e);
						}
					case _:
						throw exc;
				}
			}
		}
		// let force_inline, is_extern = match cf with Some(TInst(c,_),f) -> is_forced_inline (Some c) f, (has_class_flag c CExtern) | _ -> false, false in
		function typeAgainst(name:String, t:T, e:Expr):TExpr return handleErrors(function() {
			var e = typeExpr(ctx, e, WithTypeTools.withArgument(t, name));
			return castOrUnifyRaiseRef(ctx, t, e, e.epos);
		});
		function restError(fn:Void->Array<TExpr>, name:String):Array<TExpr> {
			try return fn()
			catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.withType(_) => Some(e)):
						return argError(e, name, false);
					case _:
						throw exc;
				}
			}
		}
		// port: `loop` walks `el` from `ei` and `args` from `ai` on (upstream: their tails) and returns the typed
		// arguments in reverse order (upstream: `x :: loop ...`), made a Vector once at the end.
		inline function reversed(l:Array<TExpr>):Array<TExpr> {
			l.reverse();
			return l;
		}
		function loop(ei:Int, ai:Int):Array<TExpr> {
			if (ei == el.length && ai == args.length) {
				if (invalidSkips.length > 0) callError(CannotSkipNonNullable(invalidSkips[invalidSkips.length - 1]), callp);
				return [];
			}
			if (args.length - ai == 1 && !args[ai].optional) {
				var name = args[ai].name, t = args[ai].type;
				switch t {
					case TAbstract({aPath: {pack: ["cpp"], name: "Rest"}}, [element]):
						return reversed(restError(() -> [for (i in ei...el.length) typeAgainst(name, element, el[i])], name));
					case _:
				}
				if (ExtType.isRest(follow(t))) return reversed(switch follow(t) {
					case TAbstract({aPath: {pack: ["haxe"], name: "Rest"}}, [argT]):
						inline function unexpectedSpread(p:Pos):Dynamic
							return argError(makeError(Custom("Cannot spread arguments with additional rest arguments"), p), name, false);
						var spread:Null<{expr:Expr, pos:Pos}> = el.length - ei == 1 ? switch el[ei].expr {
							case EUnop(Spread, Prefix, e): {expr: e, pos: el[ei].pos};
							case _: null;
						} : null;
						// these platforms deal with rest args on their own
						if (ctx.com.config.pfSupportsRestArgs) {
							inline function typeRest(getType:Void->T):Array<TExpr> return [
								for (i in ei...el.length) switch el[i].expr {
									case EUnop(Spread, Prefix, _): unexpectedSpread(el[i].pos);
									case _: typeAgainst(name, getType(), el[i]);
								}
							];
							if (spread != null) restError(() -> [mk(TUnop(Spread, Prefix, typeAgainst(name, t, spread.expr)), t,
								spread.pos)], name);
							else if (ExtType.isMono(follow(argT))) restError(function() {
								var typed = typeRest(mkMono);
								Typecore.unify(ctx, unifyMin(ctx, VectorTools.ofArray(typed)), argT, Texpr.punionEl(callp, typed));
								return typed;
							}, name);
							else restError(() -> typeRest(() -> argT), name);
						} else {
							// for other platforms make sure rest arguments are wrapped in an array
							if (spread != null) restError(() -> [typeAgainst(name, t, spread.expr)], name);
							else if (ei == el.length) restError(() -> [typeAgainst(name, t, {expr: EArrayDecl(vector()), pos: callp})], name);
							else {
								var p = el[ei].pos;
								for (i in ei...el.length) switch el[i].expr {
									case EUnop(Spread, Prefix, _): unexpectedSpread(el[i].pos);
									case _: p = Ast.punion(p, el[i].pos);
								}
								restError(function() {
									var e:Expr = {expr: EArrayDecl(ei == 0 ? el : el.slice(ei)), pos: p};
									// typer requires dynamic arrays to be explicitly declared as Array<Dynamic>
									if (follow(argT) == tDynamic) {
										var dynamicType = makePtpTh(mkTypePath([], "Dynamic"), p);
										var ct = makePtpCt(mkTypePath([], "Array", vector(TPType(dynamicType))), p);
										e = {expr: ECheckType(e, {type: ct, pos: p}), pos: p}; // ([arg1, arg2...]:Array<Dynamic>)
									}
									return [typeAgainst(name, t, e)];
								}, name);
							}
						}
					case _: throw "Invalid rest type";
				});
			}
			if (ei == el.length) {
				var arg = args[ai];
				if (!arg.optional) {
					var tailP = core.ds.Record.copy(callp);
					tailP.pmin = callFieldP.pmin;
					return callError(NotEnoughArguments(ai == 0 ? args : args.slice(ai)), tailP);
				}
				var rest = loop(ei, ai + 1);
				if (!ctx.allowTransform) return [];
				if (rest.length == 0
					&& !(isInline && (ctx.com.doinline || forceInline))
					&& !ctx.com.config.pfPadNulls) return isPosInfos(arg.type) ? [posInfos(arg.type)] : [];
				rest.push(defaultValue(arg.name, arg.type));
				return rest;
			}
			if (ai == args.length) {
				if (skipped.length == 0) {
					if (ctx.m.isDisplayFile && !context.display.Diagnostics.errorInDiagnosticsRun(ctx.com, el[ei].pos)) {
						typeExpr(ctx, el[ei], WithTypeTools.value);
						loop(ei + 1, args.length);
					}
					return callError(TooManyArguments, el[ei].pos);
				}
				var first = skipped[skipped.length - 1];
				return argError(first.error, first.name, true);
			}
			var e = el[ei], arg = args[ai], tailLength = args.length - ai - 1, name = arg.name, opt = arg.optional,
				t = arg.type;
			var bodyCapture = resetCallArgBodyCapture(ctx),
				restoreMonos:Void->Void = opt ? monomorphTransaction(ctx) : function() {},
				committed = false;
			inline function commit():Void {
				if (!committed) {
					committed = true;
					Common.commitCapturedMessages(ctx.com, bodyCapture.value);
				}
			}
			inline function drop():Void {
				committed = true;
			}
			var mightSkip = opt && el.length - ei - 1 < tailLength,
				optFollowedByRest = opt && tailLength == 1 && ExtType.isRest(follow(args[ai + 1].type));
			inline function maybeRaiseCapturedError():Void {
				if (mightSkip || optFollowedByRest) for (cm in bodyCapture.value) if (Message.severity(cm) == MessageSeverity.Error)
					throw new context.Typecore.WithTypeError(makeError(Custom(cm.cmMessage), cm.cmPos));
			}
			// port: HashLink 2.0 JIT: an early exit through two nested try blocks restores only the innermost trap, leaving a dangling handler; the result is returned after both.
			var result:Array<TExpr> = null;
			try {
				try {
					var typed = typeAgainst(name, t, e);
					maybeRaiseCapturedError();
					commit();
					result = loop(ei + 1, ai + 1);
					result.push(typed);
				} catch (exc:Dynamic) {
					switch exc {
						case(core.ds.ExceptionTools.withType(_) => Some(ul)):
							if (mightSkip || optFollowedByRest) {
								drop();
								restoreMonos();
								var def = skip(name, ul, t);
								var rest = loop(ei, ai + 1);
								rest.push(def);
								return rest;
							}
							var isFunction = switch follow(t) {
								case TFun(_): true;
								case _: false;
							};
							if (bodyCapture.value.length != 0 && !isFunction) {
								commit();
								restoreMonos();
								var def = defaultValue(name, t);
								var rest = loop(ei + 1, ai + 1);
								rest.push(def);
								return rest;
							}
							commit();
							if (skipped.length == 0) return argError(ul, name, opt);
							var first = skipped[skipped.length - 1];
							return argError(first.error, first.name, true);
						case _:
							throw exc;
					}
				}
			} catch (exc:haxe.Exception) {
				commit();
				throw exc;
			}
			return result;
		}
		var restore = enterCallArgs(ctx, inOverload);
		try {
			var result = VectorTools.ofArrayReversed(loop(0, 0));
			restore();
			return result;
		} catch (exc:haxe.Exception) {
			restore();
			throw exc;
		}
	}

	/**
		Unifies `el_typed` against the types from `args` list starting at the beginning
		of `args` list.

		Returns a tuple of a part of `args` covered by `el_typed`, and a part of `args`
		not used for `el_typed` unification.
	*/
	public static function unifyTypedArgs(tmap:T->T, args:Vector<CallParameter>, typed:Vector<TExpr>,
			callPos:Pos):{typed:Vector<CallParameter>, remaining:Vector<CallParameter>} {
		for (i in 0...typed.length) {
			if (i >= args.length) raiseErrorMsg(CallError(TooManyArguments), callPos);
			var e = typed[i], arg = args[i];
			try unifyRaise(tmap(e.etype), arg.type, e.epos)
			catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some(err)):
						switch err.errMessage {
							case Unify(_):
								var copy = core.ds.Record.copy(err);
								copy.errMessage = CallError(CouldNotUnify(err.errMessage));
								raiseError(copy);
							case _: throw exc;
						}
					case _:
						throw exc;
				}
			}
			tmap = t -> t;
		}
		// port: the covered part is the first typed.length args (none: no copies)
		return typed.length == 0 ? {typed: vector(), remaining: args} : {
			typed: args.slice(0, typed.length),
			remaining: args.slice(typed.length)
		};
	}

	public static function ensureCoroAvailability(com:CommonContext):Void {
		// In cases where we never actually built a coro state machine, the SuspensionResult structure might
		// not have been initialized yet. This would normally be handled via the pass flushing in `load_module`,
		// but because all coro data is loaded from a `build-module` pass, this doesn't trigger in time.
		com.basic.tcoro.suspensionResultClass.force().clBuild();
	}

	// Wrap a coroutine call expression from a non-coroutine context with a `.resolveTo(cont)` call.
	// This ensures that if the coroutine completes synchronously, its result or error is propagated
	// to the continuation immediately. If the continuation expression `econt` is not pure (e.g. a
	// constructor call), a temp var is introduced to avoid evaluating it twice.
	public static function wrapWithResolveTo(com:CommonContext, ecall:TExpr, econt:TExpr, p:Pos):TExpr {
		var basic = com.basic,
			b = new coro.CoroElsewhere.TexprBuilder(basic, p),
			c = basic.tcoro.suspensionResultClass.force();
		var param = switch follow(ecall.etype) {
			case TInst(_, [t]): t;
			case _: throw "Expected SuspensionResult with one type parameter for coroutine call result";
		};
		var cf = c.clFields.get("resolveTo");
		if (cf == null) throw core.ds.NotFound.raise();
		var type = applyParams(c.clParams, vector(param), cf.cfType);
		inline function resolve(call:TExpr,
				cont:TExpr):TExpr return b.call(b.instanceField(call, c, vector(param), cf, type), vector(cont), basic.tvoid);
		switch econt.eexpr {
			case TLocal(_) | TConst(_):
				return resolve(ecall, econt);
			case _:
		}
		// Introduce a temp var for the continuation so it is evaluated exactly once, and replace
		// its occurrence in ecall's argument list with a reference to the local var.
		var v = allocVar(VGenerated, "_hx_cont", econt.etype, econt.epos),
			local = b.local(v, v.vPos);
		var call = switch ecall.eexpr {
			case TCall(ef, args) if (args.length > 0): mk(TCall(ef, args.withFirst(local)), ecall.etype, ecall.epos);
			case _: throw "Expected TCall with at least one argument (continuation)";
		};
		return b.voidBlock(vector(b.varInit(v, econt), resolve(call, local)));
	}

	public static function unifyFieldCall(ctx:TyperContext, fa:context.Typecore.FieldAccess, elTyped:Vector<TExpr>, el:Vector<Expr>, p:Pos,
			isInline:Bool):FieldCallCandidateData<Void->TExpr> {
		inline function expand(cf:TClassField):Array<TClassField> return [cf].concat(cf.cfOverloads);
		var candidates:Array<TClassField>, co:Null<TClass>, isStatic:Bool, map:T->T, tmap:T->T;
		switch fa.faHost {
			case FHStatic(c):
				candidates = expand(fa.faField);
				co = c;
				isStatic = true;
				map = t -> t;
				tmap = t -> t;
			case FHAnon:
				candidates = expand(fa.faField);
				co = null;
				isStatic = false;
				map = t -> t;
				tmap = t -> t;
			case FHInstance(c, tl):
				var cf = fa.faField;
				candidates = cf.cfName == "new"
					|| !hasClassFieldFlag(cf, CfOverload) ? expand(cf) : getOverloads(ctx.com, c, cf.cfName).map(pair -> pair.field);
				co = c;
				isStatic = false;
				map = TClassTools.getMapFunction(c, tl);
				tmap = t -> t;
			case FHAbstract(a, tl, c):
				map = t -> applyParams(a.aParams, tl, t);
				tmap = hasClassFieldFlag(fa.faField, CfAbstractConstructor) ? (t->t) : (t->map(a.aThis));
				candidates = expand(fa.faField);
				co = c;
				isStatic = true;
		}
		var forced = isForcedInline(co, fa.faField),
			kind = hasClassFieldFlag(fa.faField,
				CfOverload) ? OverloadProper : fa.faField.cfOverloads.length != 0 ? OverloadMeta : OverloadNone;
		/* Delayed display handling works like this: If in_overload_call_args is set (via attempt_calls calling unify_call_args' below),
		   the code which normally raises eager Display exceptions (in typerDisplay.ml handle_display) instead stores them in ctx.g.delayed_display.
		   The overload handling here extracts them and associates the exception with the field call candidates. Afterwards, normal overload resolution
		   can take place and only then the display callback is actually committed.
		*/
		inline function extractDisplay():Null<core.DisplayTypes.DisplayExceptionKind> {
			var f = ctx.g.delayedDisplay;
			ctx.g.delayedDisplay = null;
			return f;
		}
		function raiseAugmentedDisplay<R>(cf:TClassField, de:core.DisplayTypes.DisplayExceptionKind):R {
			inline function defaultRaise():R throw new context.display.DisplayException(de);
			var text = genDocTextOpt(cf.cfDoc);
			if (text == null) return defaultRaise();
			var javadoc = new core.display.Javadoc(text);
			switch de {
				case DisplayHover(hover):
					switch hover.hexpected {
						case WithType(t, si) if (si != null):
							var si:core.WithType.WithTypeSource = switch si {
								case FunctionArgument(info) if (info.siDoc == null): FunctionArgument(new core.WithType.WithTypeSourceInformation(info.siName,
										javadoc.getParamInfo(info.siName)));
								case StructureField(info) if (info.siDoc == null): StructureField(new core.WithType.WithTypeSourceInformation(info.siName,
										javadoc.getParamInfo(info.siName)));
								case _: si;
							};
							var expected = WithType(t, si);
							return context.display.DisplayException.raiseHover(hover.hitem, expected, hover.hpos);
						case _:
							return defaultRaise();
					}
				case _:
					return defaultRaise();
			}
		}
		inline function commitDisplay(fcc:FieldCallCandidateData<CallAttemptData>):FieldCallCandidateData<Void->TExpr> {
			if (fcc.fcData.display != null) raiseAugmentedDisplay(fcc.fcField, fcc.fcData.display);
			return makeFieldCallCandidate(fcc.fcArgs, fcc.fcRet, fcc.fcMonos, fcc.fcType, fcc.fcField, fcc.fcData.call);
		}
		inline function attempt(cf:TClassField, inOverload:Bool):FieldCallCandidateData<CallAttemptData> {
			var monos = Monomorph.spawnConstrainedMonos(map, cf.cfParams),
				t = map(applyParams(cf.cfParams, monos, cf.cfType));
			inline function make(args:Vector<CallParameter>, ret:T, coro:Bool):FieldCallCandidateData<CallAttemptData> {
				var split = unifyTypedArgs(tmap, args, elTyped, p),
					typed:Vector<TExpr>;
				typed = try unifyCallArgs(ctx, el, split.remaining, ret, p, isInline, forced, inOverload,
					fa.faFieldPos) catch (de:context.display.DisplayException) raiseAugmentedDisplay(cf, de.kind);
				// here
				if (elTyped.length > 0) typed = elTyped.concat(typed);
				// port: args_typed @ args is args again
				var tf = coro ? ctx.t.tcoro.tcoro.force()({args: args, ret: ret}) : TFun({args: args, ret: ret});
				function makeCall():TExpr {
					var ef = mk(TField(fa.faOn, FieldAccess.applyFa(cf, fa.faHost)), t, fa.faPos);
					return makeCallRef(ctx, ef, typed, ret, p, isInline);
				}
				return makeFieldCallCandidate(typed, ret, monos, tf, cf, {call: makeCall, display: extractDisplay()});
			}
			return switch followWithCoro(t) {
				case Coro({args: args, ret: ret}) if (!TyperManager.isCoroutineContext(ctx)):
					var expanded = expandCoroType(ctx.com.basic, args, ret);
					ensureCoroAvailability(ctx.com);
					var fcc = make(expanded.args, expanded.ret, false);
					if (fcc.fcArgs.length == 0) raiseTypingError("Unexpected overload candidate without arguments for coroutine call", p);
					var cont = fcc.fcArgs[0],
						original = fcc.fcData.call,
						copy = core.ds.Record.copy(fcc);
					copy.fcData = {call: function() return wrapWithResolveTo(ctx.com, original(), cont, p), display: fcc.fcData.display};
					copy;
				case Coro({args: args, ret: ret}): make(args, ret, true);
				case NotCoro(TFun({args: args, ret: ret})): make(args, ret, false);
				case NotCoro(t): raiseTypingError(sType(printContext(), t) + " cannot be called", p);
			};
		}
		var unknownIdentError:Null<CompilerError> = null;
		function checkUnknown(err:CompilerError):Void switch err.errMessage {
			case CallError(CouldNotUnify(UnknownIdent(_))) | UnknownIdent(_):
				if (unknownIdentError == null) unknownIdentError = err;
			case _:
				for (sub in err.errSub) checkUnknown(sub);
		}
		function attempts(list:Array<TClassField>):CallAttempts {
			if (list.length == 0) return {candidates: [], failures: []};
			var cf = list[0], current = ctx.e.monomorphs, known = [];
			for (i in 0...context.Typecore.MonomorphList.size(current)) {
				var mono = current.mono(i);
				known.push({mono: mono, type: mono.tmType, constraints: mono.tmDownConstraints});
			}
			try {
				var candidate = attempt(cf, true);
				ctx.e.monomorphs = current;
				if (kind == OverloadProper) {
					var rest = attempts(list.slice(1));
					return {candidates: [candidate].concat(rest.candidates), failures: rest.failures};
				}
				return {candidates: [candidate], failures: []};
			} catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some(err)):
						switch err.errMessage {
							case CallError(_):
								for (m in known) {
									if (m.type != m.mono.tmType) m.mono.tmType = m.type;
									if (m.constraints != m.mono.tmDownConstraints) m.mono.tmDownConstraints = m.constraints;
								}
								ctx.e.monomorphs = current;
								checkUnknown(err);
								var rest = attempts(list.slice(1));
								return {
									candidates: rest.candidates,
									failures: [
										{
											field: cf,
											error: err,
											display: extractDisplay()
										}
									].concat(rest.failures)
								};
							case _: throw exc;
						}
					case _:
						throw exc;
				}
			}
		}
		function checkAccess(cf:TClassField):Void {
			// type_field doesn't check access for overloads, so let's check it here
			if (co != null) checkFieldAccess(ctx, co, cf, isStatic, p);
		}
		// There's always a chance that we never even came across the EDisplay in an argument, so let's look for it (issue #11422).
		function checkDisplayArgs():Void {
			if (ctx.m.isDisplayFile) for (e in el) if (Ast.exists(function(def) return switch def {
				case EDisplay(_): true;
				case _: false;
			}, e)) {
				typeExpr(ctx, e, WithTypeTools.value);
				break;
			}
		}
		if (candidates.length == 1) {
			var cf = candidates[0];
			if (kind == OverloadProper) checkAccess(cf);
			try return commitDisplay(attempt(cf, false))
			catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some(_)) if (Common.ignoreError(ctx.com)):
						checkDisplayArgs();
						var tf = TFun({args: el.map(_ -> {name: "", optional: false, type: tDynamic}), ret: tDynamic});
						function call():TExpr {
							var ef = mk(TField(fa.faOn, FieldAccess.applyFa(fa.faField, fa.faHost)), tf, fa.faPos);
							return mk(TCall(ef, vector()), tDynamic, p);
						}
						return makeFieldCallCandidate(vector(), tDynamic, vector(), tf, fa.faField, call);
					case _:
						throw exc;
				}
			}
		}
		var all = attempts(candidates),
			success = all.candidates,
			failures = all.failures;
		function fail():FieldCallCandidateData<Void->TExpr> {
			var errors:Array<{field:TClassField, error:CompilerError}> = [];
			for (f in failures) {
				// If any resolution attempt had a delayed display result, we might as well raise it now.
				if (f.display != null) raiseAugmentedDisplay(f.field, f.display);
				errors.push({field: f.field, error: f.error});
			}
			checkDisplayArgs();
			errors = removeDuplicates((a:{field:TClassField, error:CompilerError},
					b:{field:TClassField, error:CompilerError}) ->
					MessageReporting.printError(a.error) != MessageReporting.printError(b.error),
				errors);
			if (errors.length == 1) return raiseTypingErrorExt(errors[0].error);
			if (unknownIdentError != null) return raiseTypingErrorExt(unknownIdentError);
			var sub = [];
			for (f in errors) sub.unshift(makeError(Custom("Overload resolution failed for " + sType(printContext(), f.field.cfType)), p,
				[f.error]));
			sub.unshift(makeError(Custom("End of overload failure reasons"), p));
			return raiseTypingErrorExt(makeError(Custom("Could not find a suitable overload, reasons follow"), p, sub));
		}
		if (kind == OverloadProper) {
			var compatible = Resolution.reduceCompatible(success);
			if (compatible.length == 0) return fail();
			var fcc = compatible[0];
			if (compatible.length == 1) checkAccess(fcc.fcField);
			else {
				var pc = printContext(),
					sub = compatible.map(fcc -> makeError(Custom(complMsg(sType(pc, fcc.fcType))), fcc.fcField.cfNamePos));
				sub.reverse();
				displayErrorExt(ctx.com, makeError(Custom("Ambiguous overload, candidates follow"), p, sub));
			}
			return commitDisplay(fcc);
		}
		return success.length == 0 ? fail() : commitDisplay(success[success.length - 1]);
	}

	public static function makeStaticCallBetter(ctx:TyperContext, c:TClass, cf:TClassField, tl:TParams, el:Vector<TExpr>, t:T, p:Pos):TExpr {
		var fh = switch c.clKind {
			case KAbstractImpl(a) if (hasClassFieldFlag(cf, CfImpl)): FHAbstract(a, tl, c);
			case _: FHStatic(c);
		};
		var fa = FieldAccess.create(Builder.makeStaticThis(c, p), cf, fh, false, p);
		var fcc = unifyFieldCall(ctx, fa, el, vector(), p, false);
		return fcc.fcData();
	}
}

class CallDispatcher {
	final ctx:TyperContext;
	final mode:AccessMode;
	final withType:WithTypeValue;
	final p:Pos;
	final isSet:Bool;

	public function new(ctx:TyperContext, mode:AccessMode, withType:WithTypeValue, p:Pos) {
		this.ctx = ctx;
		this.mode = mode;
		this.withType = withType;
		this.p = p;
		isSet = switch mode {
			case MSet(_): true;
			case _: false;
		};
	}

	function checkAssign():Void {
		if (isSet && !Common.ignoreError(ctx.com)) invalidAssign(p);
	}

	function makeFieldCall(fa:context.Typecore.FieldAccess, typed:Vector<TExpr>, el:Vector<Expr>):TExpr {
		var fcc = CallUnification.unifyFieldCall(ctx, fa, typed, el, p, fa.faInline);
		if (hasClassFieldFlag(fcc.fcField, CfGeneric)) return typeGenericFunctionRef(ctx, fa, fcc, withType, p);
		if (hasClassFieldFlag(fcc.fcField, CfAbstract)) switch fa.faOn.eexpr {
			case TConst(TSuper):
				displayError(ctx.com, "abstract method " + fcc.fcField.cfName + " cannot be accessed directly", p);
			case _:
		}
		return fcc.fcData();
	}

	function macroCall(ethis:TExpr, cf:TClassField, el:Vector<Expr>):TExpr {
		if (ctx.e.macroDepth > 300) raiseTypingError("Stack overflow", p);
		ctx.e.macroDepth = ctx.e.macroDepth + 1;
		ctx.e.withTypeStack.unshift(withType);
		var ethisF:Void->Void = function() {};
		inline function macroInMacro():Void->TExpr return function() {
			var e:Expr = {expr: EThrow({expr: EConst(String("macro-in-macro", SDoubleQuotes)), pos: p}), pos: p};
			return typeExpr(ctx, e, withType, mode);
		};
		var f:Void->TExpr = switch ethis.eexpr {
			case TTypeExpr(TClassDecl(c)):
				context.display.DeprecationCheck.checkCf(createDeprecationContext(ctx), cf, p);
				switch ctx.g.doMacro(ctx, MExpr, c.clPath, cf.cfName, el, p) {
					case MError: function() return typeExpr(ctx, {expr: EConst(Ident("null")), pos: p}, WithTypeTools.value, mode);
					case MSuccess({expr: EMeta({meta: MetaTag.MergeBlock}, {expr: EBlock(el)})}): function() {
							var e:TExpr = typeBlockRef(ctx, el, withType, p);
							return mk(TMeta({meta: MetaTag.MergeBlock, exprs: vector(), pos: p}, e), e.etype, e.epos);
						};
					case MSuccess(e): function() return typeExpr(ctx, e, withType, mode);
					case MMacroInMacro: macroInMacro();
				}
			case _:
				// member-macro call : since we will make a static call, let's find the actual class and not its subclass
				switch follow(ethis.etype) {
					case TInst(c, _):
						function loop(c:TClass):Void->TExpr {
							if (c.clFields.exists(cf.cfName)) {
								var pushed = pushThis(ctx, ethis);
								ethisF = pushed.restore;
								return switch ctx.g.doMacro(ctx, MExpr, c.clPath, cf.cfName, VectorTools.cons(pushed.expr, el), p) {
									case MError: function() return typeExpr(ctx, {expr: EConst(Ident("null")), pos: p},
											WithTypeTools.value, mode);
									case MSuccess(e): function() return typeExpr(ctx, e, withType, mode);
									case MMacroInMacro: macroInMacro();
								};
							}
							return c.clSuper == null ? Globals.die("", "typing/CallUnification.hx") : loop(c.clSuper.cls);
						}
						loop(c);
					case _: Globals.die("", "typing/CallUnification.hx");
				}
		};
		ctx.e.macroDepth = ctx.e.macroDepth - 1;
		ctx.e.withTypeStack.shift();
		var old = ctx.com.errorExt;
		ctx.com.errorExt = function(err:CompilerError) {
			var err:CompilerError = err;
			var ep = err.errPos;
			// display additional info in the case the error is not part of our original call
			if (ep.pfile != p.pfile || ep.pmax < p.pmin || ep.pmin > p.pmax) {
				if (ep.pfile == Globals.nullPos.pfile && ep.pmin == Globals.nullPos.pmin && ep.pmax == Globals.nullPos.pmax)
					old(makeError(err.errMessage, p, err.errSub));
				else old(makeError(err.errMessage, err.errPos,
					[makeError(Custom(complMsg("Called from macro here")), p)].concat(err.errSub)));
			} else old(err);
		};
		var e = try f() catch (exc:Dynamic) {
			ctx.com.errorExt = old;
			ethisF();
			throw exc;
		};
		ctx.com.errorExt = old;
		ethisF();
		return e;
	}

	// Calls `e` with arguments `el`. Does not inspect the callee expression, so it should only be
	// used with actual expression calls and not with something like field calls.
	public function exprCall(e:TExpr, typed:Vector<TExpr>, el:Vector<Expr>):TExpr {
		checkAssign();
		inline function defaultCall(t:T):TExpr {
			var all = typed.concat(el.map(e -> typeExpr(ctx, e, WithTypeTools.value))), ret:T;
			if (t == tDynamic) ret = tDynamic;
			else if (ctx.f.isUntyped) ret = mkMono();
			else {
				var pos = switch e.eexpr {
					case TField(_, FAnon(cf) | FInstance(_, _, cf) | FStatic(_, cf) | FClosure(_, cf)): patchStringPos(e.epos, cf.cfName);
					case _: e.epos;
				};
				ret = raiseTypingError(sType(printContext(), e.etype) + " cannot be called", pos);
			}
			return mk(TCall(e, all), ret, p);
		}
		inline function make(args:Vector<CallParameter>, ret:T):TExpr {
			var split = CallUnification.unifyTypedArgs(t -> t, args, typed, p);
			var all = CallUnification.unifyCallArgs(ctx, el, split.remaining, ret, p, false, false, false);
			return mk(TCall(e, typed.concat(all)), ret, p);
		}
		function loop(t:T):TExpr return switch followWithCoro(t) {
			case Coro({args: args, ret: ret}) if (!TyperManager.isCoroutineContext(ctx)):
				var expanded = expandCoroType(ctx.com.basic, args, ret);
				CallUnification.ensureCoroAvailability(ctx.com);
				var call = make(expanded.args, expanded.ret);
				var cont = switch call.eexpr {
					case TCall(_, args) if (args.length > 0): args[0];
					case _: throw "Expected TCall with at least one argument (continuation)";
				};
				CallUnification.wrapWithResolveTo(ctx.com, call, cont, p);
			case Coro({args: args, ret: ret}): make(args, ret);
			case NotCoro(TFun({args: args, ret: ret})): make(args, ret);
			case NotCoro(abstractType = TAbstract(a, tl)):
				if (a.aCall != null && a.aImpl != null) {
					var on = Builder.makeStaticThis(a.aImpl, e.epos),
						fa = FieldAccess.create(on, a.aCall, FHAbstract(a, tl, a.aImpl), false, e.epos);
					fieldCall(fa, VectorTools.cons(e, typed), el);
				} else if (Meta.has(MetaTag.Callable,
					a.aMeta)) loop(AbstractTools.getUnderlyingType(a, tl)); else defaultCall(abstractType);
			case NotCoro(TMono(_)):
				var ret = mkMono(),
					all = typed.concat(el.map(e -> typeExpr(ctx, e, WithTypeTools.value)));
				Typecore.unify(ctx, tfun(all.map(e -> e.etype), ret), e.etype, e.epos);
				mk(TCall(e, all), ret, p);
			case NotCoro(t): defaultCall(t);
		};
		return loop(e.etype);
	}

	// Calls the resolve method represented by `sea` with an additional string-expression argument `name`.
	public function resolveCall(sea:StaticExtensionAccess,
			name:String):TExpr return fieldCall(sea.seAccess, vector(sea.seThis, Texpr.Builder.makeString(ctx.t, name, Globals.nullPos)), vector());

	// Resolves the accessor function for `fa` and calls it with the provided arguments.
	// If no accessor function is found (AccessorAnon case), a generic field access is generated instead.
	public function accessorCall(fa:context.Typecore.FieldAccess, typed:Vector<TExpr>,
			el:Vector<Expr>):TExpr return switch FieldAccess.resolveAccessor(fa, mode) {
			case AccessorFound(accessor):
				var dispatch = new CallDispatcher(ctx, MCall(el), withType, p),
					e = dispatch.fieldCall(accessor, typed, el),
					t = FieldAccess.getMapFunction(fa)(fa.faField.cfType);
				!typeIseqStrict(t, e.etype) ? mk(TCast(e, null), t, e.epos) : e;
			case AccessorAnon:
				var e = fa.faOn, t = FieldAccess.getMapFunction(fa)(fa.faField.cfType),
					all = typed.concat(el.map(e -> typeExpr(ctx, e, WithTypeTools.value))), tf = tfun(all.map(e -> e.etype), t),
					name = (isSet ? "set" : "get") + "_" + fa.faField.cfName;
				Calls.makeCall(ctx, mk(TField(e, quickFieldDynamic(e.etype, name)), tf, p), all, t, p);
			case _: raiseTypingError("Could not resolve accessor", p);
		};

	/* Calls the field represented by `fa` with the typed arguments `el_typed` and the syntactic arguments `el`.

		This function inspects the nature of the field being called and dispatches the call accordingly:

		* If the field is a non-macro method, call it via `make_field_call`.
		* If the field is a property, resolve the accessor (depending on `mode`) and recurse onto it.
		* Otherwise, call the field as a normal expression via `expr_call`.
	*/
	public function fieldCall(fa:context.Typecore.FieldAccess, typed:Vector<TExpr>, el:Vector<Expr>):TExpr return switch fa.faField.cfKind {
		case Method(MethNormal | MethInline | MethDynamic):
			checkAssign();
			makeFieldCall(fa, typed, el);
		case Method(MethMacro):
			if (typed.length == 0) macroCall(fa.faOn, fa.faField, el); else {
				var pushed = typed.map(e -> pushThis(ctx, e)),
					e = macroCall(fa.faOn, fa.faField, pushed.map(pair -> pair.expr).concat(el));
				for (pair in pushed) pair.restore();
				e;
			}
		case Var(v): switch (isSet ? v.vWrite : v.vRead) {
				case AccCall | AccPrivateCall: accessorCall(fa, typed, el);
				case _: exprCall(FieldAccess.getFieldExpr(fa, FCall), typed, el);
			}
	};
}
