package context;

import core.Globals;
import core.Globals.Pos;
import core.Ast;
import core.TType;
import core.Meta;
import core.TFunctions;
import core.TUnification;
import core.TUnification.EqKind;
import core.MetaList.StrictMeta;
import core.Meta as MetadataTools;
import context.Typecore;
import core.Abstract;
import core.TUnification.Monomorph;
import core.Error.Error;
import core.Error.ErrorMsg;
import typing.CallUnification;
import core.ds.NotFound;
import context.SafeCom.SafeContext;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// port: find_array_read_access / find_array_write_access results (OCaml tuples)
typedef ArrayReadAccess = {field:TClassField, type:T, ret:T, index:TExpr};
typedef ArrayWriteAccess = {field:TClassField, type:T, ret:T, index:TExpr, value:TExpr};
// port: prepare_array_access_field result: (map, check_constraints, get_ta)
typedef PreparedArrayAccess = {map:T->T, checkConstraints:Void->Void, getTa:Void->T};
// port: find_to_field result: (t, cf, monos)
typedef ToField = {type:T, field:TClassField, monos:TParams};
// port: find_multitype_specialization' result: (cf, field_monos, m, tl)
typedef MultitypeSpecializationFull = {field:TClassField, fieldMonos:TParams, type:T, params:TParams};
// port: find_multitype_specialization result: (cf, m)
typedef MultitypeSpecialization = {field:TClassField, type:T};
// port: handle_abstract_casts find_abstract result: (a, pl, e)
typedef MultitypeAbstractExpr = {abs:TAbstract, params:TParams, expr:TExpr};

class AbstractCast {
	static final castStack:Array<TClassField> = [];

	public static function makeStaticCall(ctx:context.Typecore.Typer, c:TClass, cf:TClassField, a:TAbstract, pl:TParams,
			args:haxe.ds.Vector<TExpr>, t:T, p:Pos):TExpr {
		switch cf.cfKind {
			case Method(MethMacro):
				if (args.length != 1) throw "abstractCast: invalid macro cast argument count";
				var pushed = Typecore.pushThis(ctx, args[0]);
				ctx.e.withTypeStack.unshift(core.WithType.withType(t));
				var e = switch ctx.g.doMacro(ctx, MExpr, c.clPath, cf.cfName, vector(pushed.expr), p) {
					case MSuccess(expr): Typecore.typeExpr(ctx, expr, core.WithType.withType(t));
					case _: Typecore.typeExpr(ctx, {expr: EConst(Ident("null")), pos: p}, core.WithType.value);
				};
				ctx.e.withTypeStack.shift();
				try e = castOrUnifyRaise(ctx, t, e, p)
				catch (err:core.Error.TypingError) {
					switch err.error.errMessage {
						case Unify(_): throw NotFound.raise();
						case _: throw err;
					}
				}
				pushed.restore();
				return e;
			case _:
				return CallUnification.makeStaticCallBetter(ctx, c, cf, pl, args, t, p);
		}
	}

	public static function doCheckCast(ctx:context.Typecore.Typer, uctx:UnificationContext, tleft:T, eright:TExpr, p:Pos):TExpr {
		inline function recurse(cf:TClassField, f:Void->TExpr):TExpr {
			/*
				Without this special check for macro @:from methods we will always get "Recursive implicit cast" error
				unlike non-macro @:from methods, which generate unification errors if no other @:from methods are involved.
			*/
			switch cf.cfKind {
				case Method(MethMacro):
					if (castStack.length > 0 && castStack[0] == cf)
						try core.TUnification.unifyCustom(uctx, eright.etype, tleft)
						catch (err:core.TUnification.Unify_error) Error.raiseErrorMsg(Unify(err.errors), eright.epos);
				case _:
			}
			if (cf == ctx.f.curfield || castStack.indexOf(cf) != -1) Error.raiseTypingError("Recursive implicit cast", p);
			castStack.unshift(cf);
			var result:TExpr;
			try result = f()
			catch (err:haxe.Exception) {
				castStack.shift();
				throw err;
			}
			castStack.shift();
			return result;
		}
		inline function make(found:AbstractCastField):TExpr {
			var a:TAbstract = found.abs;
			var tl:TParams = found.params;
			var cf:TClassField = found.field.field;
			if (MetadataTools.has(StrictMeta.MultiType, cf.cfMeta)) return core.TFunctions.mkCast(eright, tleft, p);
			if (a.aImpl == null) throw "abstractCast: missing implementation";
			return recurse(cf, function() {
				var ret = makeStaticCall(ctx, a.aImpl, cf, a, tl, vector(eright), tleft, p);
				return {eexpr: TMeta({meta: StrictMeta.ImplicitCast, exprs: vector(), pos: ret.epos}, ret), etype: ret.etype, epos: ret.epos};
			});
		}
		if (core.TUnification.typeIseqCustom(uctx, tleft, eright.etype)) return eright;
		function loop(stack:Array<{left:T, right:T}>, left:T, right:T):TExpr {
			for (pair in stack) if (core.TUnification.fastEq(left, pair.left)
				&& core.TUnification.fastEq(right, pair.right)) throw NotFound.raise();
			var next = [{left: left, right: right}].concat(stack);
			return switch [core.TFunctions.follow(left), core.TFunctions.follow(right)] {
				case [TAbstract(a1, tl1), TAbstract(a2, tl2)]: make(Abstract.findToFrom(uctx, eright.etype, left, a2, tl2, a1, tl1));
				case [TAbstract(a, tl), _]:
					try make({abs: a, params: tl, field: Abstract.findFrom(uctx, eright.etype, a, tl)}) catch (_:NotFound) {
						var found:Null<TExpr> = null;
						for (tc in a.aFrom) if (!core.TUnification.typeIseqCustom(uctx, tc, left)) {
							found = loop(next, core.TFunctions.applyParams(a.aParams, tl, tc), right);
							break;
						}
						if (found == null) throw NotFound.raise();
						found;
					}
				case [_, TAbstract(a, tl)]:
					try make({abs: a, params: tl, field: Abstract.findTo(uctx, left, a, tl)}) catch (_:NotFound) {
						var found:Null<TExpr> = null;
						for (tc in a.aTo) if (!core.TUnification.typeIseqCustom(uctx, tc, right)) {
							found = loop(next, left, core.TFunctions.applyParams(a.aParams, tl, tc));
							break;
						}
						if (found == null) throw NotFound.raise();
						found;
					}
				case [TInst(c, tl), TFun(_)] if (core.TFunctions.hasClassFlag(c, CFunctionalInterface)):
					var cf = core.TOther.TClassTools.getSingularInterfaceField(c.clOrderedFields);
					if (cf == null) throw NotFound.raise();
					function map(t:T):T return core.TFunctions.applyParams(c.clParams, tl, t);
					var monos = Monomorph.spawnConstrainedMonos(map, cf.cfParams);
					Typecore.unifyRaiseCustom(core.TUnification.nativeUnificationContext, eright.etype,
						map(core.TFunctions.applyParams(cf.cfParams, monos, cf.cfType)), p);
					if (core.TFunctions.hasMono(right))
						Error.raiseTypingError("Cannot use this function as a functional interface because it has unknown types: "
							+ core.TPrinting.sType(core.TPrinting.printContext(), right),
							p);
					// Wrap the function expression in a TCast to the SAM type so
					// the SAM TInst lives in the typed AST. Without this the
					// genjvm AST scan can't see SAM conversions in argument
					// position (TNew has no callee subexpression; the
					// constructor's parameter types are unreachable), and the
					// emitted closure would not implement the SAM interface.
					core.TFunctions.mkCast(eright, left, p);
				case _: throw NotFound.raise();
			};
		}
		return loop([], tleft, eright.etype);
	}

	public static function castOrUnifyRaise(ctx:context.Typecore.Typer, tleft:T, eright:TExpr, p:Pos,
			?uctx:core.TUnification.UnificationContext):TExpr {
		if (uctx == null) uctx = core.TUnification.defaultUnificationContext();
		try return doCheckCast(ctx, uctx, tleft, eright, p)
		catch (_:NotFound) {
			Typecore.unifyRaiseCustom(uctx, eright.etype, tleft, p);
			return eright;
		}
	}

	public static function castOrUnify(ctx:context.Typecore.Typer, tleft:T, eright:TExpr, p:Pos):TExpr {
		try return castOrUnifyRaise(ctx, tleft, eright, p)
		catch (err:core.Error.TypingError) {
			switch err.error.errMessage {
				case Unify(_):
					Typecore.raiseOrDisplayError(ctx, err.error);
					return eright;
				case _:
					throw err;
			}
		}
	}

	public static function prepareArrayAccessField(ctx:context.Typecore.Typer, a:TAbstract, pl:TParams, cf:TClassField,
			p:Pos):PreparedArrayAccess {
		var monos = cf.cfParams.map(_ -> Typecore.spawnMonomorph(ctx, p));
		function map(t:T):T return core.TFunctions.applyParams(a.aParams, pl, core.TFunctions.applyParams(cf.cfParams, monos, t));
		function checkConstraints():Void {
			for (i in 0...monos.length) {
				var m = monos[i];
				for (tc in core.TFunctions.getConstraints(cf.cfParams[i])) switch core.TFunctions.follow(m) {
					case TMono(_):
						throw new core.TUnification.Unify_error([]);
					case _:
						core.TUnification.unify(m, map(tc));
				}
			}
		}
		function getTa():T {
			var ta = core.TFunctions.applyParams(a.aParams, pl, a.aThis);
			return core.TFunctions.hasClassFieldFlag(cf, CfImpl) ? ta : TAbstract(a, pl);
		}
		return {map: map, checkConstraints: checkConstraints, getTa: getTa};
	}

	public static function findArrayReadAccessRaise(ctx:context.Typecore.Typer, a:TAbstract, pl:TParams, e1:TExpr, p:Pos):ArrayReadAccess {
		for (cf in a.aArray) {
			var prepared = prepareArrayAccessField(ctx, a, pl, cf, p);
			var tf = core.TFunctions.follow(prepared.map(cf.cfType));
			switch tf {
				case TFun(sig) if (sig.args.length >= 2 && Typecore.isEmptyOrPosInfos(sig.args, 2)):
					try {
						core.TUnification.unify(sig.args[0].type, prepared.getTa());
						var e1 = castOrUnifyRaise(ctx, sig.args[1].type, e1, p);
						prepared.checkConstraints();
						return {
							field: cf,
							type: tf,
							ret: sig.ret,
							index: e1
						};
					} catch (_:core.TUnification.Unify_error) {} catch (err:core.Error.TypingError) {
						switch err.error.errMessage {
							case Unify(_):
							case _: throw err;
						}
					}
				case _:
			}
		}
		throw NotFound.raise();
	}

	public static function findArrayWriteAccessRaise(ctx:context.Typecore.Typer, a:TAbstract, pl:TParams, e1:TExpr, e2:TExpr,
			p:Pos):ArrayWriteAccess {
		for (cf in a.aArray) {
			var prepared = prepareArrayAccessField(ctx, a, pl, cf, p);
			var tf = core.TFunctions.follow(prepared.map(cf.cfType));
			switch tf {
				case TFun(sig) if (sig.args.length >= 3 && Typecore.isEmptyOrPosInfos(sig.args, 3)):
					try {
						core.TUnification.unify(sig.args[0].type, prepared.getTa());
						var e1 = castOrUnifyRaise(ctx, sig.args[1].type, e1, p);
						var e2 = castOrUnifyRaise(ctx, sig.args[2].type, e2, p);
						prepared.checkConstraints();
						return {
							field: cf,
							type: tf,
							ret: sig.ret,
							index: e1,
							value: e2
						};
					} catch (_:core.TUnification.Unify_error) {} catch (err:core.Error.TypingError) {
						switch err.error.errMessage {
							case Unify(_):
							case _: throw err;
						}
					}
				case _:
			}
		}
		throw NotFound.raise();
	}

	public static function findArrayReadAccess(ctx:context.Typecore.Typer, a:TAbstract, tl:TParams, e1:TExpr, p:Pos):ArrayReadAccess {
		try return findArrayReadAccessRaise(ctx, a, tl, e1, p)
		catch (_:NotFound) {
			return Error.raiseTypingError("No @:arrayAccess function for "
				+ core.TPrinting.sType(core.TPrinting.printContext(), TAbstract(a, tl))
				+ " accepts argument of "
				+ core.TPrinting.sType(core.TPrinting.printContext(), e1.etype),
				p);
		}
	}

	public static function findArrayWriteAccess(ctx:context.Typecore.Typer, a:TAbstract, tl:TParams, e1:TExpr, e2:TExpr,
			p:Pos):ArrayWriteAccess {
		try return findArrayWriteAccessRaise(ctx, a, tl, e1, e2, p)
		catch (_:NotFound) {
			return Error.raiseTypingError("No @:arrayAccess function for "
				+ core.TPrinting.sType(core.TPrinting.printContext(), TAbstract(a, tl))
				+ " accepts arguments of "
				+ core.TPrinting.sType(core.TPrinting.printContext(), e1.etype)
				+ " and "
				+ core.TPrinting.sType(core.TPrinting.printContext(), e2.etype),
				p);
		}
	}

	// TODO: This duplicates pretty much all the code from unifies_to_field. The only reason for that is
	// that we want the monos so we can apply them to the type. Surely we can design our data better here...
	public static function findToField(uctx:core.TUnification.UnificationContext, b:T, ab:TAbstract, tl:TParams):ToField {
		var a = TAbstract(ab, tl);
		inline function check(t:T, cf:TClassField):ToField return switch core.TFunctions.follow(cf.cfType) {
			case TFun(sig) if (sig.args.length > 0):
				var ta = sig.args[0].type;
				function outerMap(t:T):T return core.TFunctions.applyParams(ab.aParams, tl, t);
				var monos = Monomorph.spawnConstrainedMonos(outerMap, cf.cfParams);
				function map(t:T):T return outerMap(core.TFunctions.applyParams(cf.cfParams, monos, t));
				var uctx = core.TUnification.getAbstractContext(uctx, a, b, ab);
				var unifyFunc = core.TUnification.getAbstractUnifyFunc(uctx, EqStrict);
				var athis = map(ab.aThis);
				// we cannot allow implicit casts when the this type is not completely known yet
				if (MetadataTools.has(StrictMeta.MultiType, ab.aMeta)
					&& core.TFunctions.hasMono(athis)) throw new core.TUnification.Unify_error([]);
				var equalityContext = core.ds.Record.copy(uctx);
				equalityContext.equalityKind = EqStrict;
				core.TUnification.withVariance(uctx, function(t1, t2) return core.TUnification.typeEqCustom(equalityContext, t1, t2),
					athis, map(ta));
				unifyFunc(map(t), b);
				{type: t, field: cf, monos: monos};
			case _: throw "abstractCast: invalid to-field type";
		};
		for (entry in ab.aToField) try return check(entry.type, entry.field)
		catch (_:core.TUnification.Unify_error) {}
		throw NotFound.raise();
	}

	public static function findMultitypeSpecializationFull(platform:core.Globals.Platform, a:TAbstract, pl:TParams,
			p:Pos):MultitypeSpecializationFull {
		var uctx = core.TUnification.defaultUnificationContext();
		var m = core.TFunctions.mkMono();
		var params = Abstract.findMultitypeParams(a, pl);
		var tl:TParams = params.types;
		var found:Null<ToField> = null;
		try {
			found = findToField(uctx, m, a, tl);
			for (t in params.definitiveTypes) if (core.TFunctions.hasMono(t)) {
				var at = core.TFunctions.applyParams(a.aParams, pl, a.aThis);
				Error.raiseTypingError("Type parameters of multi type abstracts must be known (for "
					+ core.TPrinting.sType(core.TPrinting.printContext(), at)
					+ ")",
					p);
			}
		} catch (_:NotFound) {
			var at = core.TFunctions.applyParams(a.aParams, pl, a.aThis);
			var st = core.TPrinting.sType(core.TPrinting.printContext(), at);
			if (core.TFunctions.hasMono(at)) Error.raiseTypingError("Type parameters of multi type abstracts must be known (for "
				+ st
				+ ")", p);
			else Error.raiseTypingError("Abstract " + Globals.sTypePath(a.aPath) + " has no @:to function that accepts " + st, p);
		}
		return {
			field: found.field,
			fieldMonos: found.monos,
			type: core.TFunctions.follow(m),
			params: tl
		};
	}

	public static function findMultitypeSpecialization(platform:core.Globals.Platform, a:TAbstract, pl:TParams,
			p:Pos):MultitypeSpecialization {
		var found = findMultitypeSpecializationFull(platform, a, pl, p);
		return {field: found.field, type: found.type};
	}

	public static function handleAbstractCasts(scom:SafeContext, e:TExpr):TExpr {
		function loop(e:TExpr):TExpr return switch e.eexpr {
			case TNew(c, pl, el) if (switch c.clKind {
					case KAbstractImpl(_): true;
					case _: false;
				}):
				var a = switch c.clKind {
					case KAbstractImpl(a): a;
					case _: throw "abstractCast: invalid implementation";
				};
				if (!MetadataTools.has(StrictMeta.MultiType, a.aMeta)) {
					// This must have been a @:generic expansion with a { new } constraint (issue #4364). In this case
					// let's construct the underlying type.
					switch Abstract.getUnderlyingType(a, pl) {
						case TInst(c, tl): {eexpr: TNew(c, tl, el), etype: TInst(c, tl), epos: e.epos};
						case _: Error.raiseTypingError("Cannot construct "
								+ core.TPrinting.sType(core.TPrinting.printContext(), TAbstract(a, pl)), e.epos);
					}
				} else {
					// a TNew of an abstract implementation is only generated if it is a multi type abstract
					var found = findMultitypeSpecializationFull(scom.platform, a, pl, e.epos);
					var cf:TClassField = found.field;
					var m:T = found.type;
					var eThis = core.Texpr.Builder.makeStaticThis(c, e.epos);
					var ef = core.TFunctions.mk(TField(eThis, FStatic(c, cf)),
						core.TFunctions.applyParams(cf.cfParams, found.fieldMonos, cf.cfType), e.epos);
					var call = filters.exception.ExceptionFunctions.makeCall(scom, ef,
						core.ds.VectorTools.cons(core.TFunctions.mk(TConst(TNull), TAbstract(a, found.params), e.epos), el), m, e.epos);
					{eexpr: call.eexpr, etype: m, epos: call.epos};
				}
			case TCall({eexpr: TField(_, FStatic(c, cf))}, [e1])
				if (c.clPath.pack.length == 0
					&& c.clPath.name == "Std"
					&& cf.cfName == "string"
					&& (switch core.TFunctions.follow(e1.etype) {
						case TAbstract(a, _) if (a.aImpl != null): true;
						case _: false;
					})):
					switch core.TFunctions.follow(e1.etype) {
						case TAbstract(a, tl) if (a.aImpl != null):
							var c = a.aImpl;
							var cf = c.clStatics.get("toString");
							if (cf == null) e; else {
								function call():TExpr return filters.exception.ExceptionFunctions.makeStaticCall(scom, c, cf, vector(e1),
									scom.basic.tstring, e.epos);
								if (!core.TFunctions.isNullable(e1.etype)) call();
								else {
									var p = e.epos;
									var chkNull = core.TFunctions.mk(TBinop(OpEq, e1, core.TFunctions.mk(TConst(TNull), e1.etype, p)),
										scom.basic.tbool, p);
									core.TFunctions.mk(TIf(chkNull, core.TFunctions.mk(TConst(TString("null")), scom.basic.tstring, p),
										call()),
										scom.basic.tstring, p);
								}
							}
						case _: throw "abstractCast: invalid abstract string call";
					}
			case TCall(e1, el):
				try {
					function findAbstract(e:TExpr, t:T):MultitypeAbstractExpr {
						switch core.TFunctions.follow(t) {
							case TAbstract(a, pl) if (MetadataTools.has(StrictMeta.MultiType, a.aMeta)):
								return {abs: a, params: pl, expr: e};
							case _:
						}
						return switch e.eexpr {
							case TCast(e1, null): findAbstract(e1, e1.etype);
							case TLocal(v) if (v.vExtra != null && v.vExtra.vExpr != null):
								var original = v.vExtra.vExpr;
								switch core.TFunctions.follow(original.etype) {
									case TAbstract(a, pl) if (MetadataTools.has(StrictMeta.MultiType, a.aMeta)): {
											abs: a,
											params: pl,
											expr: core.TFunctions.mk(TCast(e, null), original.etype, e.epos)
										};
									case _: throw NotFound.raise();
								}
							case _: throw NotFound.raise();
						};
					}
					function findField(e1:TExpr):TExpr return switch e1.eexpr {
						case TCast(e2, null): {eexpr: TCast(findField(e2), null), etype: e1.etype, epos: e1.epos};
						case TField(e2, fa):
							var found = findAbstract(e2, e2.etype);
							var a:TAbstract = found.abs;
							var pl:TParams = found.params;
							var e2 = loop(found.expr);
							var m = Abstract.getUnderlyingType(a, pl);
							var fname = core.TFunctions.fieldName(fa);
							var el = el.map(loop);
							try {
								var fa = core.TFunctions.quickField(m, fname);
								inline function getFunType(t:T):{type:T, signature:TSignature}
									return switch core.TFunctions.follow(t) {
										case TFun(sig): {type: TFun(sig), signature: sig};
										case _: throw NotFound.raise();
									};
								var funType = switch fa {
									case FStatic(_, cf): getFunType(cf.cfType);
									case FInstance(c, tl, cf): getFunType(core.TFunctions.applyParams(c.clParams, tl, cf.cfType));
									case FAnon(cf): getFunType(cf.cfType);
									case _: throw NotFound.raise();
								};
								inline function maybeCast(e:TExpr, t:T,
										p:Pos):TExpr return core.TUnification.typeIseq(e.etype,
										t) ? e : core.TFunctions.mk(TCast(e, null), t, p);
								var ef = core.TFunctions.mk(TField({eexpr: e2.eexpr, etype: m, epos: e2.epos}, fa), funType.type, e2.epos);
								if (core.TFunctions.hasMeta(StrictMeta.MultiType, a.aMeta)) switch core.TFunctions.follow(e1.etype) {
									case TFun(original):
										var args = funType.signature.args;
										var casted = new haxe.ds.Vector<TExpr>(el.length);
										for (i in 0...el.length) {
											if (i >= args.length) {
												casted[i] = el[i];
												continue;
											}
											var t = args[i].type;
											if (i < original.args.length) switch core.TFunctions.follow(t) {
												case TMono(_): switch core.TFunctions.follow(original.args[i].type) {
														case TDynamic(_): t = original.args[i].type;
														case _:
													}
												case _:
											}
											casted[i] = maybeCast(el[i], t, el[i].epos);
										}
										el = casted;
									case _:
								}
								var ecall = filters.exception.ExceptionFunctions.makeCall(scom, ef, el, funType.signature.ret, e.epos);
								maybeCast(ecall, e.etype, e.epos);
							} catch (_:NotFound) {
								// quick_field raises Not_found if m is an abstract, we have to replicate the 'using' call here
								switch core.TFunctions.follow(m) {
									case TAbstract(a, pl) if (a.aImpl != null):
										var c = a.aImpl;
										var cf = c.clStatics.get(fname);
										if (cf == null) throw NotFound.raise();
										filters.exception.ExceptionFunctions.makeStaticCall(scom, c, cf, core.ds.VectorTools.cons(e2, el), e.etype, e.epos);
									case _: throw NotFound.raise();
								}
							}
						case _: throw NotFound.raise();
					};
					findField(e1);
				} catch (_:NotFound) core.Texpr.mapExpr(loop, e);
			case _: core.Texpr.mapExpr(loop, e);
		};
		return loop(e);
	}

	static final installCastOrUnifyRaise = install();

	public static function install():Bool {
		Typecore.castOrUnifyRaiseRef = castOrUnifyRaise;
		return true;
	}
}
