/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
*/

package typing;

import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.Globals.*;
import core.Message;
import core.TUnification;
import core.TUnification.TUnification.*;
import core.TUnification.Monomorph;
import core.TUnification.UnificationMatrix;
import core.Texpr;
import core.Texpr.Builder;
import core.Naming;
import core.StringError;
import core.Abstract as AbstractTools;
import core.DisplayTypes;
import core.WithType.WithTypeSource;
import context.Common.*;
import context.Typecore.Typer as TyperContext;
import context.Typecore.FieldAccess as FieldAccessData;
import context.Resolution;
import context.display.ImportHandling;
import context.display.DeprecationCheck;
import typing.FieldAccess as FieldAccessTools;
import typing.FieldCallCandidate.FieldCallCandidateData;
import typing.CallUnification.CallDispatcher;
import typing.ForLoop.ForLoopUnroll;
import core.ds.Hashtbl;
import syntax.Lexer;
import syntax.ParserConfig;
import context.FormatString;
import optimization.OptimizerTexpr;
import core.Texpr.DeadEnd;
import filters.LocalUsage;
import filters.LocalUsage.Usage;
import coro.Coro as CoroTools;
import coro.CoroTypes;
import core.display.DisplayPosition;
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
import context.TyperPass;
import context.Typecore.TyperManager;
import context.Common;
import core.Define;
import context.AbstractCast;
import context.Resolution.*;
import typing.TyperBase;
import typing.TyperBase.*;
import typing.Fields.*;
import typing.Calls.*;
import typing.CallUnification.*;
import typing.Typeload.*;
import typing.FieldAccess.*;
import typing.Operators.*;

class Typer {
	static function ensureBlock(e:Expr):Expr return switch e.expr {
		case EBlock(_): e;
		case _: {expr: EBlock([e]), pos: e.pos};
	};

	static function efield(e:Expr, name:String):ExprDef return EField(e, name, EFNormal);

	static function checkDisplayMetadata(ctx:TyperContext,
			metas:Metadata):Void context.display.DisplayEmitter.checkDisplayMetadata(ctx, metas);

	static function checkDisplayType(ctx:TyperContext, t:T,
			ptp:PlacedTypePath):Void context.display.DisplayEmitter.checkDisplayType(ctx, t, ptp);

	// ----------------------------------------------------------------------
	// TOOLS
	public static function terminatorType(ctx:TyperContext, withType:WithTypeValue, p:Pos):T return switch withType {
		case NoValue: tDynamic;
		case WithType(t, _): t;
		case Value(_): spawnMonomorph(ctx, p);
	};

	public static function getIteratorParam(t:T):T return switch follow(t) {
		case TAnon(a):
			if (a.aStatus != Closed) throw core.ds.NotFound.raise();
			var hasNext = a.aFields.get("hasNext"),
				next = a.aFields.get("next");
			if (hasNext == null || next == null) throw core.ds.NotFound.raise();
			switch [follow(hasNext.cfType), follow(next.cfType)] {
				case [TFun({args: [], ret: tb}), TFun({args: [], ret: t})]: switch follow(tb) {
						case TAbstract({aPath: {pack: [], name: "Bool"}}, []):
							if (Lambda.count(a.aFields) != 2) throw core.ds.NotFound.raise();
							t;
						case _: throw core.ds.NotFound.raise();
					}
				case _: throw core.ds.NotFound.raise();
			}
		case _: throw core.ds.NotFound.raise();
	};

	public static function getIterableParam(t:T):T return switch follow(t) {
		case TAnon(a):
			if (a.aStatus != Closed) throw core.ds.NotFound.raise();
			var field = a.aFields.get("iterator");
			if (field == null) throw core.ds.NotFound.raise();
			switch follow(field.cfType) {
				case TFun({args: [], ret: it}):
					var t = getIteratorParam(it);
					if (Lambda.count(a.aFields) != 1) throw core.ds.NotFound.raise();
					t;
				case _: throw core.ds.NotFound.raise();
			}
		case _: throw core.ds.NotFound.raise();
	};

	public static function getOwnResolution(ctx:TyperContext):ResolutionList {
		if (ctx.m.ownResolution != null) return ctx.m.ownResolution;
		var rl = new ResolutionList(["own", Globals.sTypePath(ctx.m.curmod.mPath)]);
		if (ctx.m.curmod.mStatics != null) rl.add(classStaticsResolution(ctx.m.curmod.mStatics, Globals.nullPos));
		for (mt in ctx.m.curmod.mTypes) rl.add(moduleTypeResolution(mt, null, Globals.nullPos));
		ctx.m.ownResolution = rl;
		return rl;
	}

	public static function maybeTypeAgainstEnum(ctx:TyperContext, f:Void->AccessKind, withType:WithTypeValue, isCall:Bool,
			p:Pos):AccessKind {
		try return switch withType {
			case WithType(t, _):
				function loop(stack:Array<T>, t:T):{
					isEnum:Bool,
					path:GlobalTypePath,
					fields:Array<String>,
					type:ModuleType
				}
					return switch follow(t) {
						case TEnum(en, _): {
								isEnum: true,
								path: en.ePath,
								fields: en.eNames,
								type: TEnumDecl(en)
							};
						case TAbstract(a, _) if (a.aImpl != null && a.aEnum): {
								isEnum: false,
								path: a.aPath,
								fields: a.aImpl.clOrderedStatics.filter(cf -> hasClassFieldFlag(cf, CfEnum)).map(cf -> cf.cfName),
								type: TAbstractDecl(a)
							};
						case TAbstract(a, pl) if (!Meta.has(MetaTag.CoreType, a.aMeta)):
							var froms = TyperBase.getAbstractFroms(ctx, a, pl);
							if (froms.length != 1 || core.ds.ArrayTools.exists(stack, t2 -> shallowEq(t, t2))) throw core.ds.Exit.raise();
							loop([t].concat(stack), froms[0].type);
						case _: throw core.ds.Exit.raise();
					};
				var expected = loop([], t), old = ctx.m.enumWithType;
				ctx.m.enumWithType = expected.type;
				var access:AccessKind;
				try access = f()
				catch (exc:Dynamic) {
					ctx.m.enumWithType = old;
					switch exc {
						case(core.ds.ExceptionTools.typing(_) => Some({errMessage: UnknownIdent(n)})):
							raiseOrDisplayMessage(ctx,
								StringError.stringError(n, expected.fields,
									"Identifier '" + n + "' is not part of " + Globals.sTypePath(expected.path)),
								p);
							access = AKExpr(mk(TConst(TNull), mkMono(), p));
						case _: throw exc;
					}
				}
				ctx.m.enumWithType = old;
				switch access {
					case AKExpr(e): switch follow(e.etype) {
							case TFun({args: _, ret: ret}) if (expected.isEnum):
								// TODO: this is a dodge for #7603
								try core.TUnification.unify(ret, t) catch (exc:Dynamic) {
									switch exc {
										case(core.ds.ExceptionTools.unification(_) => Some(_)):
										case _: throw exc;
									}
								}
							case _:
						}
					case _: // ???
				}
				access;
			case _: throw core.ds.Exit.raise();
		} catch (_:core.ds.Exit) {
			return f();
		}
	}

	// ----------------------------------------------------------------------
	// PASS 3 : type expression & check structure
	public static function unifyMinRaise(ctx:TyperContext, el:Array<TExpr>):T {
		try return UnifyMin.unifyMinRaise(ctx.t, el)
		catch (_:typing.UnifyMin.NoValue) {
			return spawnMonomorph(ctx, Globals.nullPos);
		}
	}

	public static function unifyMin(ctx:TyperContext, el:Array<TExpr>):T {
		try return unifyMinRaise(ctx, el)
		catch (exc:Dynamic) {
			switch exc {
				case(core.ds.ExceptionTools.typing(_) => Some(err)):
					switch err.errMessage {
						case Unify(_):
							if (!ctx.f.isUntyped) displayErrorExt(ctx.com, err);
							return el[0].etype;
						case _: throw exc;
					}
				case _:
					throw exc;
			}
		}
	}

	public static function unifyMinForTypeSource(ctx:TyperContext, el:Array<TExpr>, src:Null<WithTypeSource>):T {
		if (src == ImplicitReturn && core.ds.ArrayTools.exists(el, e -> ExtType.isVoid(follow(e.etype)))) return ctx.com.basic.tvoid;
		return unifyMin(ctx, el);
	}

	public static function enumFieldAccess(ctx:TyperContext, en:TEnum, ef:TEnumField, mode:AccessMode, p:Pos, pt:Pos):AccessKind {
		var et = TyperBase.typeModuleType(ctx, TEnumDecl(en), p),
			acc = AKExpr(mk(TField(et, FEnum(en, ef)), enumFieldType(ctx, en, ef, p), p));
		// Should this really be here?
		return switch mode {
			case MSet(_): AKNo(acc, p);
			case _: acc;
		};
	}

	public static function resolveAgainstExpectedEnum(ctx:TyperContext, i:String):ResolvedImport {
		function loop(mt:ModuleType):ResolvedImport return switch mt {
			case TAbstractDecl(a) if (a.aImpl != null && a.aEnum):
				var cf = a.aImpl.clStatics.get(i);
				if (cf == null || !hasClassFieldFlag(cf, CfEnum)) throw core.ds.NotFound.raise();
				staticAbstractFieldResolution(a, a.aImpl, cf, null, Globals.nullPos);
			case TClassDecl(_) | TAbstractDecl(_): throw core.ds.NotFound.raise();
			case TTypeDecl(t): switch follow(t.tType) {
					case TEnum(e, _): loop(TEnumDecl(e));
					case TAbstract(a, _) if (a.aEnum): loop(TAbstractDecl(a));
					case _: throw core.ds.NotFound.raise();
				}
			case TEnumDecl(en):
				var ef = en.eConstrs.get(i);
				if (ef == null) throw core.ds.NotFound.raise();
				enumConstructorResolution(en, ef, null, Globals.nullPos);
		};
		if (ctx.m.enumWithType == null) throw core.ds.NotFound.raise();
		return loop(ctx.m.enumWithType);
	}

	public static function typeIdentRaise(ctx:TyperContext, i:String, p:Pos, mode:AccessMode, withType:WithTypeValue):AccessKind {
		inline function resolve(res:ResolvedImport):AccessKind {
			ImportHandling.markImportPosition(ctx, res.rPos);
			return switch res.rKind {
				case RTypeImport(_, mt): AKExpr(TyperBase.typeModuleType(ctx, mt, p));
				case RClassFieldImport(_, c,
					cf): fieldAccess(ctx, mode, cf, FHStatic(c), TyperBase.typeModuleType(ctx, TClassDecl(c), p), p);
				case RAbstractFieldImport(_, a, c, cf):
					var et = TyperBase.typeModuleType(ctx, TClassDecl(c), p),
						inlined = switch cf.cfKind {
							case Var({vRead: AccInline}): true;
							case _: false;
						};
					AKField(FieldAccessTools.create(et, cf, FHAbstract(a, extractParamTypes(a.aParams), c), inlined, p));
				case REnumConstructorImport(_, en, ef): enumFieldAccess(ctx, en, ef, mode, p, res.rPos);
				case _: throw "Invalid identifier resolution";
			};
		}
		switch i {
			case "true" | "false":
				var acc = AKExpr(mk(TConst(TBool(i == "true")), ctx.t.tbool, p));
				return mode == MGet ? acc : AKNo(acc, p);
			case "this":
				var acc = AKExpr(TyperBase.getThis(ctx, p));
				return switch mode {
					case MSet(_):
						addClassFieldFlag(ctx.f.curfield, CfModifiesThis);
						switch ctx.c.curclass.clKind {
							case KAbstractImpl(_):
								if (!TyperBase.assignToThisIsAllowed(ctx))
									raiseTypingError("Abstract 'this' value can only be modified inside an inline function", p);
								acc;
							case _: AKNo(acc, p);
						}
					case MCall(_): switch ctx.c.curclass.clKind {
							case KAbstractImpl(_): acc;
							case _: AKNo(acc, p);
						}
					case MGet: acc;
				};
			case "abstract":
				return switch [mode, ctx.c.curclass.clKind] {
					case [MSet(_), KAbstractImpl(_)]: raiseTypingError("Property 'abstract' is read-only", p);
					case [MGet, KAbstractImpl(a)] | [MCall(_), KAbstractImpl(a)]:
						var e = TyperBase.getThis(ctx, p);
						AKExpr(mk(e.eexpr, TAbstract(a, extractParamTypes(a.aParams)), e.epos));
					case _: raiseTypingError("Property 'abstract' is reserved and only available in abstracts", p);
				};
			case "super":
				var sup = ctx.c.curclass.clSuper;
				if (sup == null) raiseTypingError("Current class does not have a superclass", p);
				switch ctx.e.curfun {
					case FunMember | FunConstructor:
					case FunMemberAbstract: raiseTypingError("Cannot access super inside an abstract function", p);
					case FunStatic: raiseTypingError("Cannot access super inside a static function", p);
					case FunMemberClassLocal | FunMemberAbstractLocal: raiseTypingError("Cannot access super inside a local function", p);
				}
				return AKExpr(mk(TConst(TSuper), TInst(sup.cls, sup.params), p));
			case "null":
				var t = switch withType {
					case WithType(t, _):
						switch follow(t) {
							case TMono(r) if (!isNullable(t)): Monomorph.addModifier(r, MNullable(ctx.t.tnull));
							case _:
								// Otherwise there's no need to create a monomorph, we can just type the null literal
								// the way we expect it.
						}
						t;
					case _: ctx.t.tnull(spawnMonomorph(ctx, p));
				};
				var acc = AKExpr(nullExpr(t, p));
				return mode == MGet ? acc : AKNo(acc, p);
			case _:
		}
		if (ctx.f.locals.mem(i)) {
			var v = ctx.f.locals.find(i);
			addVarFlag(v, VUsedByTyper);
			if (v.vExtra == null) return AKExpr(mk(TLocal(v), v.vType, p));
			var params = v.vExtra.vParams,
				e = v.vExtra.vExpr,
				t = applyParams(params, Monomorph.spawnConstrainedMonos(t -> t, params), v.vType);
			return switch e {
				case {eexpr: TFunction(_)} if (ctx.com.display.dmsInline): switch mode {
						case MSet(_): raiseTypingError("Cannot set inline closure", p);
						case MGet: raiseTypingError("Cannot create closure on inline closure", p);
						case MCall(_):
							// create a fake class with a fake field to emulate inlining
							var c = mkClass(ctx.m.curmod, {pack: ["local"], name: v.vName}, e.epos, Globals.nullPos),
								cf = mkField(v.vName, v.vType, e.epos, Globals.nullPos);
							cf.cfParams = params;
							cf.cfExpr = e;
							cf.cfKind = Method(MethInline);
							addClassFlag(c, CExtern);
							c.clFields.set(cf.cfName, cf);
							var on = mk(TConst(TNull), TInst(c, []), p);
							AKField(FieldAccessTools.create(on, cf, FHInstance(c, []), true, p));
					}
				case _: AKExpr(mk(TLocal(v), t, p));
			};
		}
		try {
			// member variable lookup
			if (ctx.e.curfun == FunStatic) throw core.ds.NotFound.raise();
			var raw = classField(ctx, ctx.c.curclass, extractParamTypes(ctx.c.curclass.clParams), i, p);
			return fieldAccess(ctx, mode, raw.field, raw.owner == null ? FHAnon : FHInstance(raw.owner.cls, raw.owner.params),
				TyperBase.getThis(ctx, p), p);
		} catch (_:core.ds.NotFound) {}
		// static variable lookup
		if (ctx.c.curclass.clStatics.exists(i)) {
			var f = ctx.c.curclass.clStatics.get(i),
				impl = hasClassFieldFlag(f, CfImpl),
				isEnum = hasClassFieldFlag(f, CfEnum);
			if (impl
				&& !hasClassFieldFlag(ctx.f.curfield, CfImpl)
				&& !isEnum) raiseTypingError("Cannot access non-static field " + f.cfName + " from static method", p);
			var on:TExpr, host:FieldHost;
			switch ctx.c.curclass.clKind {
				case KAbstractImpl(a) if (impl && !isEnum):
					var tl = extractParamTypes(a.aParams),
						e = TyperBase.getThis(ctx, p);
					on = mk(e.eexpr, TAbstract(a, tl), e.epos);
					host = FHAbstract(a, tl, ctx.c.curclass);
				case _:
					on = TyperBase.typeModuleType(ctx, TClassDecl(ctx.c.curclass), p);
					host = FHStatic(ctx.c.curclass);
			}
			return fieldAccess(ctx, mode, f, host, on, p);
		}
		try return resolve(resolveAgainstExpectedEnum(ctx, i))
		catch (_:core.ds.NotFound) {}
		try return resolve(getOwnResolution(ctx).resolve(i))
		catch (_:core.ds.NotFound) {}
		return resolve(ctx.m.importResolution.resolve(i));
	}

	public static function typeIdent(ctx:TyperContext, i:String, p:Pos, mode:AccessMode, withType:WithTypeValue):AccessKind {
		try return typeIdentRaise(ctx, i, p, mode, withType)
		catch (_:core.ds.NotFound) {}
		try {
			// lookup type
			if (TyperBase.isLowerIdent(i, p)) throw core.ds.NotFound.raise();
			var e:TExpr;
			try e = TyperBase.typeModuleType(ctx, Typeload.loadTypeDefPrime(ctx, [], i, i, p), p)
			catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some({errMessage: ModuleNotFound({pack: [], name: name})})) if (name == i):
						throw core.ds.NotFound.raise();
					case _:
						throw exc;
				}
			}
			return AKExpr(e);
		} catch (_:core.ds.NotFound) {}
		var resolved = false;
		for (tp in ctx.typeParams) if (tp.ttpName == i) {
			resolved = true;
			var c = switch follow(extractParamType(tp)) {
				case TInst(c, _): c;
				case _: throw "Invalid type parameter";
			};
			if (TypeloadCheck.isGenericParameter(ctx, c) && Meta.has(MetaTag.Const, c.clMeta)) {
				var e = TyperBase.typeModuleType(ctx, TClassDecl(c), p);
				return AKExpr(mk(e.eexpr, extractParamType(tp), e.epos));
			}
			break;
		}
		if (ctx.f.isUntyped) return i == "__this__" ? AKExpr(mk(TConst(TThis), ctx.c.tthis, p)) : AKExpr(mk(TIdent(i), mkMono(), p));
		if (ctx.e.curfun == FunStatic && ctx.c.curclass.clFields.exists(i)) raiseTypingError("Cannot access " + i + " in static function",
			p);
		if (resolved) {
			displayError(ctx.com, "Only @:const type parameters on @:generic classes can be used as value", p);
			return AKExpr(mk(TConst(TNull), tDynamic, p));
		}
		var err = UnknownIdent(i);
		if (ctx.f.inDisplay) raiseErrorMsg(err, p);
		if (ctx.f.inCallArgs) throw new context.Typecore.WithTypeError(makeError(err, p));
		if (context.display.Diagnostics.errorInDiagnosticsRun(ctx.com, p)) {
			context.display.DisplayToplevel.handleUnresolvedIdentifier(ctx, i, p, false);
			context.display.DisplayFields.handleMissingIdent(ctx, i, mode, withType, p);
			return AKExpr(mk(TIdent(i), mkMono(), p));
		}
		if (ctx.com.display.dmsKind == DMNone) return raiseErrorMsg(err, p);
		displayError(ctx.com, errorMsg(err), p);
		return AKExpr(mk(TIdent(i), mkMono(), p));
	}

	public static function handleEfield(ctx:TyperContext, e:ExprDef, p0:Pos, mode:AccessMode, withType:WithTypeValue):AccessKind {
		function dotPath(first:DotPathPart, next:Array<DotPathPart>):AccessKind {
			var name = first.name, p = first.pos, path = [first].concat(next);
			// first, try to resolve the first ident in the chain and access its fields.
			// this doesn't support untyped identifiers yet, because we want to check fully-qualified
			// paths first (even in an untyped block)
			try return fieldChain(ctx, next, typeIdentRaise(ctx, name, p, MGet, WithTypeTools.value), mode, withType)
			catch (_:core.ds.NotFound) {}
			// first ident couldn't be resolved, it's probably a fully qualified path - resolve it
			try return TyperDotPath.resolveDotPath(ctx, path, mode, withType)
			catch (_:core.ds.NotFound) {}
			// dot-path resolution failed, it could be an untyped field access that happens to look like a dot-path, e.g. `untyped __global__.String`
			// TODO: we don't really want to do full type_ident again, just the second part of it
			try return fieldChain(ctx, next, typeIdent(ctx, name, p, MGet, WithTypeTools.value), mode, withType)
			catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some(err)):
						switch err.errMessage {
							case UnknownIdent(_) if (err.errPos == p):
								// try raising a more sensible error if there was an uppercase-first (module name) part
								// TODO: we should pass the actual resolution error from resolve_dot_path instead of Not_found
								try {
									var pack = [], upper:Null<DotPathPart> = null, sub:Null<String> = null, position:Null<Pos> = null;
									for (part in path) {
										if (part.caseKind == PLowercase) {
											if (upper == null) pack.push(part.name);
											else {
												position = upper.pos;
												break;
											}
										} else if (upper == null) {
											upper = part;
											position = part.pos;
										} else {
											sub = part.name;
											position = part.pos;
											break;
										}
									}
									if (upper == null) throw core.ds.NotFound.raise();
									var mpath:core.Globals.GlobalTypePath = {pack: pack, name: upper.name};
									if (ctx.com.moduleLut.mem(mpath)) return raiseErrorMsg(TypeNotFound(mpath,
										sub == null ? upper.name : sub, NotDefined), position);
									return raiseErrorMsg(ModuleNotFound(mpath), position);
								} catch (_:core.ds.NotFound) {
									// if there was no module name part, last guess is that we're trying to get package completion
									if (ctx.f.inDisplay) {
										var sl = path.map(part -> part.name);
										context.display.DisplayToplevel.collectAndRaise(ctx, TKType, WithTypeTools.noValue,
											CRToplevel(null), sl.join("."), p0, p0);
									}
									return raiseError(err);
								}
							case _: throw exc;
						}
					case _:
						throw exc;
				}
			}
		}
		// loop through the given EField expression to figure out whether it's a dot-path that we have to resolve,
		// or a field access chain
		function loop(parts:Array<DotPathPart>, expr:Expr):AccessKind return switch expr.expr {
			// field access - accumulate and check further
			case EField(e, s, EFNormal): loop([TyperDotPath.mkDotPathPart(s, expr.pos)].concat(parts), e);
			// it's a dot-path, so it might be either fully-qualified access (pack.Class.field)
			// or normal field access of a local/global/field identifier, proceed figuring this out
			case EConst(Ident(i)): dotPath(TyperDotPath.mkDotPathPart(i, expr.pos), parts);
			case EField(obj, s, EFSafe):
				// safe navigation field access - definitely NOT a fully-qualified access,
				// create safe navigation chain from the object expression
				var on = accGet(ctx, typeAccess(ctx, obj.expr, obj.pos, MGet, WithTypeTools.value)),
					base = TyperBase.getSafeNavBase(ctx, on);
				var access = fieldChain(ctx, [TyperDotPath.mkDotPathPart(s, expr.pos)].concat(parts), AKExpr(base.base), mode, withType);
				AKSafeNav({
					snPos: expr.pos,
					snBase: base.base,
					snTempVar: base.tempVar,
					snAccess: access
				});
			// non-ident expr occured: definitely NOT a fully-qualified access,
			// resolve the field chain against this expression
			case _: switch typeAccess(ctx, expr.expr, expr.pos, MGet, WithTypeTools.value) {
					// further field access continues the safe navigation chain (after a non-field access inside the chain)
					case AKSafeNav(sn): AKSafeNav({
							snPos: sn.snPos,
							snBase: sn.snBase,
							snTempVar: sn.snTempVar,
							snAccess: fieldChain(ctx, parts, sn.snAccess, mode, withType)
						});
					case acc: fieldChain(ctx, parts, acc, mode, withType);
				}
		};
		return loop([], {expr: e, pos: p0});
	}

	public static function typeAccess(ctx:TyperContext, e:ExprDef, p:Pos, mode:AccessMode,
			withType:WithTypeValue):AccessKind return switch e {
			case EConst(Ident(s)): typeIdent(ctx, s, p, mode, withType);
			case EField(e1, "new", kind):
				if (kind == EFSafe) raiseTypingError("?.new is not supported", p);
				var on = typeExpr(ctx, e1, WithTypeTools.value);
				switch on.eexpr {
					case TTypeExpr(TClassDecl(c)):
						switch mode {
							case MSet(_): raiseTypingError("Cannot set constructor", p);
							case MCall(_): raiseTypingError("Cannot call constructor like this, use 'new " + Globals.sTypePath(c.clPath)
									+ "()' instead", p);
							case MGet:
						}
						var monos = Monomorph.spawnConstrainedMonos(t -> t, switch c.clKind {
							case KAbstractImpl(a): a.aParams;
							case _: c.clParams;
						});
						var fa = FieldAccessTools.getConstructorAccess(c, monos, p),
							cf = fa.faField;
						noAbstractConstructor(c, p);
						checkConstructorAccess(ctx, c, cf, p);
						var args = switch follow(FieldAccessTools.getMapFunction(fa)(cf.cfType)) {
							case TFun({args: args, ret: _}): args;
							case _: throw "Invalid constructor type";
						};
						var vars = args.map(arg -> allocVar(VGenerated, arg.name, arg.type, c.clPos)),
							el = vars.map(v -> mk(TLocal(v), v.vType, p)), call:TExpr, t:T;
						switch [c.clKind, fa.faHost] {
							case [KAbstractImpl(a), FHAbstract(_)]:
								t = TAbstract(a, monos);
								call = new CallDispatcher(ctx, MCall([]), WithTypeTools.value, p).fieldCall(fa, el, []);
							case [KAbstractImpl(a), FHInstance(c, pl)]:
								var enew = mk(TNew(c, monos, el), TInst(c, pl), p);
								t = TAbstract(a, monos);
								call = mkCast(enew, t, p);
							case _:
								t = TInst(c, monos);
								call = mk(TNew(c, monos, el), t, p);
						}
						AKExpr(mk(TFunction({
							tfArgs: vars.map(v -> {variable: v, defaultValue: null}),
							tfType: t,
							tfExpr: mk(TReturn(call), t, p)
						}),
							TFun({args: vars.map(v -> {name: v.vName, optional: false, type: v.vType}), ret: t}), p));
					case _: raiseTypingError("Binding new is only allowed on class types", p);
				}
			case EField(_): handleEfield(ctx, e, p, mode, withType);
			case EArray(e1, e2): typeArrayAccess(ctx, e1, e2, p, mode);
			case ECall(e, el): typeCallAccess(ctx, e, el, mode, withType, null, p);
			case EDisplay(e, dk): AKExpr(TyperDisplay.handleEdisplay(ctx, e, dk, mode, withType));
			case _: AKExpr(typeExpr(ctx, {expr: e, pos: p}, withType, mode));
		};

	public static function typeArrayAccess(ctx:TyperContext, e1:Expr, e2:Expr, p:Pos, mode:AccessMode):AccessKind {
		var a1 = typeAccess(ctx, e1.expr, e1.pos, MGet, WithTypeTools.value),
			index = typeExpr(ctx, e2, WithTypeTools.value);
		return switch a1 {
			// pack the array access inside the safe navigation chain
			case AKSafeNav(sn): AKSafeNav({
					snPos: sn.snPos,
					snBase: sn.snBase,
					snTempVar: sn.snTempVar,
					snAccess: Calls.arrayAccess(ctx, accGet(ctx, sn.snAccess), index, mode, p)
				});
			case _: Calls.arrayAccess(ctx, accGet(ctx, a1), index, mode, p);
		};
	}

	public static function typeVars(ctx:TyperContext, vl:Array<EVar>, p:Pos):TExpr {
		var vars:Array<{variable:TVar, expr:Null<TExpr>}> = [];
		for (ev in vl) {
			var name = ev.evName.name, pv = ev.evName.pos;
			DeprecationCheck.checkIs(ctx.com, ctx.m.curmod, ctx.c.curclass.clMeta, ctx.f.curfield.cfMeta, name, ev.evMeta, pv);
			try {
				var t = Typeload.loadTypeHint(ctx, p, LoadNormal, ev.evType),
					e:Null<TExpr> = null;
				if (ev.evExpr != null) {
					var old = ctx.e.inLoop;
					if (ev.evStatic) ctx.e.inLoop = false;
					try {
						e = typeExpr(ctx, ev.evExpr, WithTypeTools.withLocalVariable(t, name));
						ctx.e.inLoop = old;
					} catch (exc:haxe.Exception) {
						ctx.e.inLoop = old;
						throw exc;
					}
					e = AbstractCast.castOrUnify(ctx, t, e, p);
				}
				var v = Meta.has(MetaTag.This,
					ev.evMeta) ? addLocal(ctx, VAbstractThis, name, t, pv) : addLocalWithOrigin(ctx, TVOLocalVariable, name, t, pv);
				v.vMeta = ev.evMeta;
				checkDisplayMetadata(ctx, v.vMeta);
				if (ev.evFinal) addVarFlag(v, VFinal);
				if (ev.evStatic) addVarFlag(v, VStatic);
				if (ctx.f.inDisplay
					&& DisplayPosition.displayPosition.enclosedIn(pv)) context.display.DisplayEmitter.displayVariable(ctx, v, pv);
				vars.push({variable: v, expr: e});
			} catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some(err)):
						checkError(ctx, err);
						vars.push({variable: addLocal(ctx, VGenerated, name, tDynamic, pv), expr: null});
					case _:
						throw exc;
				}
			}
		}
		for (pair in vars) delayIfMono(ctx.g, PTypeField, pair.variable.vType, function() {
			if (ExtType.isVoid(follow(pair.variable.vType))) raiseTypingError("Variables of type Void are not allowed", pair.variable.vPos);
		});
		if (vars.length == 1) return mk(TVar(vars[0].variable, vars[0].expr), ctx.t.tvoid, p);
		var block = mk(TBlock(vars.map(pair -> mk(TVar(pair.variable, pair.expr), ctx.t.tvoid, p))), ctx.t.tvoid, p);
		return mk(TMeta({meta: MetaTag.MergeBlock, exprs: [], pos: p}, block), block.etype, block.epos);
	}

	public static function formatString(ctx:TyperContext, s:String,
			p:Pos):Expr return FormatString.formatString(ParserConfig.fileParserConfig(ctx.com, p.pfile), s, p,
			function(next:ExprDef,
					p:Pos) return ctx.f.inDisplay
					&& DisplayPosition.displayPosition.enclosedIn(p) ? context.display.Display.preprocessExpr(ctx.com, {
						expr: next,
						pos: p
					}) : {expr: next, pos: p});

	public static function typeBlock(ctx:TyperContext, el:Array<Expr>, withType:WithTypeValue, p:Pos):TExpr {
		var result = [];
		for (i in 0...el.length) {
			var expected = i == el.length - 1 ? withType : WithTypeTools.noValue;
			try {
				var e = typeExpr(ctx, el[i], expected);
				switch e.eexpr {
					case TMeta({meta: MetaTag.MergeBlock}, {eexpr: TBlock(list)}):
						result = result.concat(list);
					case _:
						result.push(e);
				}
			} catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some(err)):
						checkError(ctx, err);
						if (expected != NoValue) result.push(mk(TConst(TNull), mkMono(), el[i].pos));
					case _:
						throw exc;
				}
			}
		}
		return mk(TBlock(result), result.length == 0 ? ctx.t.tvoid : result[result.length - 1].etype, p);
	}

	public static function typeObjectDecl(ctx:TyperContext, fl:Array<ObjectField>, withType:WithTypeValue, p:Pos):TExpr {
		var dynamicParameter:Null<T> = null;
		var kind:ObjectDeclKind = switch withType {
			case WithType(t, _):
				function loop(hadCast:Bool, seen:Array<T>, t:T):ObjectDeclKind return switch follow(t) {
					case TAnon(a): ODKWithStructure(a);
					case followed = TAbstract(a, pl)
						if (!Meta.has(MetaTag.CoreType, a.aMeta) && !core.ds.ArrayTools.exists(seen, t -> shallowEq(followed, t))):
						var matches = [];
						for (from in TyperBase.getAbstractFroms(ctx, a, pl)) {
							var result = loop(from.kind == FromField, [followed].concat(seen), from.type);
							if (result != ODKPlain) matches.unshift(result);
						}
						// If the abstract has no casts in the first place, we can assume plain typing (issue #10730)
						matches.length == 0 ? ODKPlain : matches.length == 1 ? matches[0] : ODKFailed;
					case TDynamic(t) if (t != null):
						dynamicParameter = t;
						ODKWithStructure({aStatus: Closed, aFields: new haxe.ds.StringMap()});
					case TInst(c, tl) if (!hadCast && Meta.has(MetaTag.StructInit, c.clMeta)): ODKWithClass(c, tl);
					case _: ODKPlain;
				}
				loop(false, [], t);
			case _: ODKPlain;
		};
		inline function typeFields(fieldMap:haxe.ds.StringMap<TClassField>):{type:T, fields:Array<{key:{name:String, pos:Pos, quote:QuoteStatus}, expr:TExpr}>} {
			var fields = new haxe.ds.StringMap<TClassField>(), extra = [];
			var result = fl.map(function(field) {
				var n = field.key.name, pn = field.key.pos, valid = Lexer.isValidIdentifier(n);
				if (fields.exists(n)) raiseTypingError("Duplicate field in object declaration : " + n, pn);
				var e:TExpr, original:Null<TClassField> = null;
				try {
					var t:T;
					if (dynamicParameter != null) t = dynamicParameter;
					else {
						original = fieldMap.get(n);
						if (original == null) throw core.ds.NotFound.raise();
						if (ctx.f.inDisplay
							&& DisplayPosition.displayPosition.enclosedIn(pn)) context.display.DisplayEmitter.displayField(ctx, Unknown,
								CFSMember, original, pn);
						t = original.cfType;
					}
					e = typeExpr(ctx, field.expr, WithTypeTools.withStructureField(t, n));
					e = AbstractCast.castOrUnify(ctx, t, e, e.epos);
					if (isNull(t) && !isNull(e.etype)) e = mk(TCast(e, null), ctx.t.tnull(e.etype), e.epos);
					try typeEq(EqStrict, e.etype, t)
					catch (exc:Dynamic) {
						switch exc {
							case(core.ds.ExceptionTools.unification(_) => Some(_)):
								e = mk(TCast(e, null), t, e.epos);
							case _:
								throw exc;
						}
					}
				} catch (_:core.ds.NotFound) {
					if (valid) extra.unshift({name: n, pos: pn});
					e = typeExpr(ctx, field.expr, WithTypeTools.value);
					original = null;
				}
				if (valid) {
					if (StringTools.startsWith(n, "$")) raiseTypingError("Field names starting with a dollar are not allowed", p);
					var cf = mkField(n, e.etype, Ast.punion(pn, e.epos), pn);
					if (original != null) {
						// If we're assigning to an existing field, copy some of its characteristics
						if (hasClassFieldFlag(original, CfFinal)) addClassFieldFlag(cf, CfFinal);
						cf.cfKind = original.cfKind;
					}
					fields.set(n, cf);
				}
				return {key: field.key, expr: e};
			});
			var t = mkAnon(Const, fields);
			if (!ctx.f.isUntyped) {
				var missing = [];
				var names = [for (name in fieldMap.keys()) name];
				names.sort(core.ds.Key.compareStrings);
				for (name in names) {
					var cf = fieldMap.get(name);
					if (!Meta.has(MetaTag.Optional, cf.cfMeta) && !fields.exists(name)) missing.unshift(name);
				}
				if (missing.length == 1) raiseOrDisplay(ctx, [UnifyCustom("Object requires field " + missing[0])], p);
				else if (missing.length > 1) raiseOrDisplay(ctx, [UnifyCustom("Object requires fields: " + missing.join(", "))], p);
				for (field in extra) raiseOrDisplay(ctx, [hasExtraField(t, field.name)], field.pos);
			}
			return {type: t, fields: result};
		}
		inline function plain():TExpr {
			var fields = [], types = new haxe.ds.StringMap<TClassField>();
			for (field in fl) {
				var name = field.key.name,
					pf = field.key.pos,
					valid = Lexer.isValidIdentifier(name);
				if (types.exists(name)) raiseTypingError("Duplicate field in object declaration : " + name, pf);
				var e = typeExpr(ctx, field.expr, WithTypeTools.namedStructureField(name));
				switch follow(e.etype) {
					case TAbstract({aPath: {pack: [], name: "Void"}}, _):
						raiseTypingError("Fields of type Void are not allowed in structures", e.epos);
					case _:
				}
				var cf = mkField(name, e.etype, Ast.punion(pf, e.epos), pf);
				if (ctx.f.inDisplay
					&& DisplayPosition.displayPosition.enclosedIn(pf)) context.display.DisplayEmitter.displayField(ctx, Unknown,
						CFSMember, cf, pf);
				fields.push({key: field.key, expr: e});
				if (valid) {
					if (StringTools.startsWith(name, "$")) raiseTypingError("Field names starting with a dollar are not allowed", p);
					types.set(name, cf);
				}
			}
			var anon:TAnon = {aStatus: Const, aFields: types};
			ctx.e.opened.unshift(anon);
			return mk(TObjectDecl(fields), TAnon(anon), p);
		}
		return switch kind {
			case ODKPlain | ODKFailed: plain();
			case ODKWithStructure(a) if (!a.aFields.keys().hasNext() && dynamicParameter == null): plain();
			case ODKWithStructure(a):
				var typed = typeFields(a.aFields);
				mk(TObjectDecl(typed.fields), typed.type, p);
			case ODKWithClass(c, tl):
				noAbstractConstructor(c, p);
				var fa = FieldAccessTools.getConstructorAccess(c, tl, p),
					ctor = fa.faField;
				var args:Array<{name:String, optional:Bool, type:T}> = switch follow(FieldAccessTools.getMapFunction(fa)(ctor.cfType)) {
					case TFun({args: args, ret: _}): args;
					case _: throw "Invalid structure constructor";
				};
				var argsWithPos = [];
				for (i in 0...args.length) {
					var pos = ctor.cfNamePos;
					switch ctor.cfExpr {
						case {eexpr: TFunction(tf)}: if (i < tf.tfArgs.length) pos = tf.tfArgs[i].variable.vPos;
						case _:
					}
					argsWithPos.push({arg: args[i], pos: pos});
				}
				var fields = new haxe.ds.StringMap<TClassField>();
				for (pair in argsWithPos) {
					var arg = pair.arg,
						f = mkField(arg.name, arg.type, pair.pos, pair.pos);
					if (arg.optional) f.cfMeta = [{meta: MetaTag.Optional, exprs: [], pos: Globals.nullPos}];
					if (c.clFields.exists(arg.name)) f.cfDoc = c.clFields.get(arg.name).cfDoc;
					fields.set(arg.name, f);
				}
				var typed = typeFields(fields), input = typed.fields.copy();
				input.reverse();
				var declarations = [], locals = [], hadSideEffect = false;
				for (field in input) {
					var e = field.expr;
					switch e.eexpr {
						case TConst(_) | TTypeExpr(_) | TFunction(_): locals.unshift(field);
						case _:
							if (hadSideEffect) {
								var v = genLocal(ctx, e.etype, e.epos);
								declarations.unshift(mk(TVar(v, e), e.etype, e.epos));
								locals.unshift({key: field.key, expr: mk(TLocal(v), v.vType, e.epos)});
							} else {
								locals.unshift(field);
								hadSideEffect = OptimizerTexpr.hasSideEffect(e);
							}
					}
				}
				var el = argsWithPos.map(function(pair) {
					var arg = pair.arg;
					for (field in locals) if (field.key.name == arg.name) return field.expr;
					switch ctor.cfExpr {
						case {eexpr: TFunction(fn)}:
							for (pair in fn.tfArgs) if (pair.variable.vName == arg.name && pair.defaultValue != null) return
								pair.defaultValue;
						case _:
					}
					var t = arg.type;
					if (typeHasMeta(AbstractTools.followWithAbstractsWithoutNull(t), MetaTag.NotNull)) t = ctx.t.tnull(t);
					return mk(TConst(TNull), t, p);
				});
				var e = mk(TNew(c, tl, el), TInst(c, tl), p);
				mk(TBlock(declarations.concat([e])), e.etype, e.epos);
		};
	}

	public static function typeNew(ctx:TyperContext, ptp:PlacedTypePath, el:Array<Expr>, withType:WithTypeValue, forceInline:Bool,
			p:Pos):TExpr {
		/*
			Since macros don't have placed_type_path structure on Haxe side any ENew will have null_pos in `path`.
			Try to calculate a better pos.
		*/
		if (ptp.posFull == Globals.nullPos) {
			var pp = p;
			if (el.length > 0 && el[0].pos.pfile == p.pfile && p.pmin < el[0].pos.pmin) {
				pp = core.ds.Record.copy(p);
				var min = p.pmin + 4, max = el[0].pos.pmin - 2; // Additional "1" for an opening bracket
				pp.pmin = min < max ? min : p.pmin;
				pp.pmax = max;
			}
			ptp = makePtp(ptp.path, pp);
		}
		function unifyConstructor(c:TClass, fa:FieldAccessData):FieldCallCandidateData<Void->TExpr> {
			try {
				var fcc = unifyFieldCall(ctx, fa, [], el, p, fa.faInline);
				checkConstructorAccess(ctx, c, fcc.fcField, p);
				return fcc;
			} catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some(err)):
						return raiseTypingErrorExt(err);
					case _:
						throw exc;
				}
			}
		}
		function getParams(info:BuildInfo, tl:Null<TParams>):TParams {
			function tlOrMonos(params:TypeParams):TParams return tl == null ? Monomorph.spawnConstrainedMonos(t -> t, params) : tl;
			function defaultParams(c:TClass):TParams {
				var tl = tlOrMonos(c.clParams);
				unifyConstructor(c, FieldAccessTools.getConstructorAccess(c, tl, p));
				return tl;
			}
			return switch info.buildKind {
				case BuildGeneric(c): switch withType {
						// If we have a matching expected type, use its type parameters.
						case WithType(t, _): switch follow(t) {
								case TInst(c, tl) if (core.ds.Key.compare(c.clPath, info.buildPath) == 0): tl;
								case TInst({clKind: KGenericInstance(c, tl)},
									_) if (core.ds.Key.compare(c.clPath, info.buildPath) == 0): tl;
								case TAbstract(a, tl) if (core.ds.Key.compare(a.aPath, info.buildPath) == 0): tl;
								case _: defaultParams(c);
							}
						case _: defaultParams(c);
					}
				case _: tlOrMonos(info.buildParams);
			};
		}
		ctx.e.callArgumentStack.unshift(el);
		ctx.e.withTypeStack.unshift(withType);
		function restore():Void {
			ctx.e.withTypeStack.shift();
			ctx.e.callArgumentStack.shift();
		}
		var t:T;
		try t = Typeload.loadInstance(ctx, ptp, ParamCustom(getParams), LoadNormal)
		catch (exc:haxe.Exception) {
			restore();
			// If we fail for some reason, process the arguments in case we want to display them (#7650).
			if (core.ds.ArrayTools.exists(el,
				e -> DisplayPosition.displayPosition.enclosedIn(e.pos))) for (e in el) typeExpr(ctx, e, WithTypeTools.value);
			throw exc;
		}
		checkDisplayType(ctx, t, ptp);
		t = follow(t);
		function buildConstructor(ao:Null<TAbstract>, c:TClass, tl:TParams):FieldCallCandidateData<Void->TExpr> {
			var fa = FieldAccessTools.getConstructorAccess(c, tl, p);
			if (forceInline) {
				fa = core.ds.Record.copy(fa);
				fa.faInline = true;
			}
			var cf = fa.faField;
			noAbstractConstructor(c, p);
			switch cf.cfKind {
				case Var({vRead: AccRequire(r, msg)}):
					if (msg != null) raiseTypingError(msg, p);
					else errorRequire(r, p);
				case _:
			}
			return unifyConstructor(c, fa);
		}
		// port: upstream only invokes restore on the failing instance-load path above.
		try return switch AbstractTools.followWithForwardCtor(t) {
			case TInst(c = {clKind: KTypeParameter(ttp)}, params):
				if (!TypeloadCheck.isGenericParameter(ctx, c)) raiseTypingError("Only generic type parameters can be constructed", p);
				var constraint = TyperBase.getConstructibleConstraint(ctx, getConstraints(ttp), p);
				if (constraint == null) raiseTypingErrorExt(makeError(NoConstructor(TClassDecl(c)), p));
				mk(TNew(c, params, unifyCallArgs(ctx, el, constraint.args, constraint.ret, p, false, false, false)), t, p);
			case TAbstract(a, tl) if (a.aImpl != null && !Meta.has(MetaTag.MultiType, a.aMeta)):
				var fcc = buildConstructor(a, a.aImpl, tl), e = fcc.fcData();
				mk(e.eexpr, t, e.epos);
			case TInst(c, params):
				var fcc = buildConstructor(null, c, params);
				mk(TNew(c, params, fcc.fcArgs), t, p);
			case TAbstract(a, params) if (a.aImpl != null):
				var fcc = buildConstructor(null, a.aImpl, params);
				mk(TNew(a.aImpl, params, fcc.fcArgs), t, p);
			case _: raiseTypingError(sType(printContext(), t) + " cannot be constructed", p);
		} catch (exc:Dynamic) {
			switch exc {
				case(core.ds.ExceptionTools.typing(_) => Some(err)):
					switch err.errMessage {
						case NoConstructor(_):
							if (context.display.Diagnostics.errorInDiagnosticsRun(ctx.com,
								p)) context.display.DisplayFields.handleMissingFieldRaise(ctx, t, "new", MCall(el), withType, p);
							displayErrorExt(ctx.com, err);
							return mk(TConst(TNull), t, p);
						case _: throw exc;
					}
				case _:
					throw exc;
			}
		}
	}

	public static function typeTry(ctx:TyperContext, e1:Expr, catches:Array<Catch>, withType:WithTypeValue, p:Pos):TExpr {
		var body = typeExpr(ctx, ensureBlock(e1), withType),
			typed:Array<{variable:TVar, expr:TExpr}> = [],
			expressions = [body];
		function checkUnreachable(cases:Array<{variable:TVar, expr:TExpr}>, t:T, p:Pos):Void {
			if (cases.length == 0) return;
			var first = cases[0], v = first.variable, e = first.expr;
			function unreachable():Void {
				displayError(ctx.com, "This block is unreachable", p);
				var pc = printContext();
				displayError(ctx.com, sType(pc, t) + " can be caught to " + sType(pc, v.vType) + ", which is handled here", e.epos);
			}
			try switch [follow(t), follow(v.vType)] {
				case [_, TDynamic(_)] | [_, TInst({clPath: {pack: ["haxe"], name: "Error"}}, _)]:
					unreachable();
				case [_, TInst({clPath: path}, _)] if (path == ctx.com.config.pfExceptions.ecWildcardCatch):
					unreachable();
				case [TDynamic(_), _]:
				case _:
					core.TUnification.unify(t, v.vType);
					unreachable();
			} catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.unification(_) => Some(_)):
						checkUnreachable(cases.slice(1), t, p);
					case _:
						throw exc;
				}
			}
		}
		inline function checkParams(params:TParams, p:Pos):Void {
			for (pt in params) if (AbstractTools.followWithAbstracts(pt) != tDynamic)
				raiseTypingError("Catch class parameter must be Dynamic", p);
		}
		for (catchSyntax in catches) {
			var th = catchSyntax.type == null ? makePtpTh({
				tpackage: ["haxe"],
				tname: "Exception",
				tsub: null,
				tparams: []
			}, Globals.nullPos) : catchSyntax.type;
			var t = Typeload.loadComplexType(ctx, true, LoadNormal, th);
			function loop(t:T):T return switch follow(t) {
				case TInst(c = {clKind: KTypeParameter(_)},
					_) if (!TypeloadCheck.isGenericParameter(ctx, c)): raiseTypingError("Cannot catch non-generic type parameter", p);
				case TInst(_, params) | TEnum(_, params):
					checkParams(params, th.pos);
					t;
				case TAbstract(a, params) if (Meta.has(MetaTag.RuntimeValue, a.aMeta)):
					checkParams(params, th.pos);
					t;
				case TAbstract(a, tl) if (!Meta.has(MetaTag.CoreType, a.aMeta)): loop(AbstractTools.getUnderlyingType(a, tl));
				case TDynamic(_): t;
				case _: raiseTypingError("Catch type must be a class, an enum or Dynamic", catchSyntax.expr.pos);
			};
			var t2 = loop(t);
			checkUnreachable(typed, t2, catchSyntax.expr.pos);
			var locals = saveLocals(ctx),
				v = addLocalWithOrigin(ctx, TVOCatchVariable, catchSyntax.name.name, t, catchSyntax.name.pos);
			if (ctx.m.isDisplayFile
				&& DisplayPosition.displayPosition.enclosedIn(catchSyntax.name.pos)) context.display.DisplayEmitter.displayVariable(ctx,
					v, catchSyntax.name.pos);
			var e = typeExpr(ctx, catchSyntax.expr, withType);
			// If the catch position is the display position it means we get completion on the catch keyword or some
			// punctuation. Otherwise we wouldn't reach this point.
			if (ctx.m.isDisplayFile
				&& DisplayPosition.displayPosition.enclosedIn(catchSyntax.pos)) TyperDisplay.displayExpr(ctx, catchSyntax.expr, e,
					DKMarked, MGet, withType, catchSyntax.pos);
			v.vType = t2;
			locals();
			typed.unshift({variable: v, expr: e});
			expressions.unshift(e);
		}
		var t:T = switch withType {
			case NoValue: ctx.t.tvoid;
			case Value(_): unifyMin(ctx, expressions);
			case WithType(t, src) if (ExtType.isMono(follow(t)) || ExtType.isVoid(follow(t))): unifyMinForTypeSource(ctx, expressions, src);
			case WithType(t, _):
				body = AbstractCast.castOrUnify(ctx, t, body, body.epos);
				typed = typed.map(pair -> {variable: pair.variable, expr: AbstractCast.castOrUnify(ctx, t, pair.expr, pair.expr.epos)});
				t;
		};
		typed.reverse();
		return mk(TTry(body, typed), t, p);
	}

	public static function typeMapDeclaration(ctx:TyperContext, e1:Expr, el:Array<Expr>, withType:WithTypeValue, p:Pos):TExpr {
		var expected:Null<{key:T, value:T}> = switch withType {
			case WithType(t, _): switch follow(t) {
					case TAbstract({aPath: {pack: ["haxe", "ds"], name: "Map"}}, [tk, tv]): {key: tk, value: tv};
					case TInst({clPath: {pack: ["haxe", "ds"], name: "IntMap"}}, [tv]): {key: ctx.t.tint, value: tv};
					case TInst({clPath: {pack: ["haxe", "ds"], name: "StringMap"}}, [tv]): {key: ctx.t.tstring, value: tv};
					case TInst({clPath: {pack: ["haxe", "ds"], name: "ObjectMap" | "EnumValueMap"}}, [tk, tv]): {key: tk, value: tv};
					case _: null;
				}
			case _: null;
		};
		var keys = new core.ds.Hashtbl<TExprDef, Pos>();
		inline function checkKey(e:TExpr):Void {
			if (keys.mem(e.eexpr)) raiseTypingErrorExt(makeError(Custom("Duplicate key"), e.epos,
				[makeError(Custom(complMsg("Previously defined here")), keys.find(e.eexpr))]));
			switch e.eexpr {
				case TConst(_):
					keys.add(e.eexpr, e.epos);
				case _:
			}
		}
		var pairs = [e1].concat(el).map(e -> switch e.expr {
			case EBinop(OpArrow, a, b): {key: a, value: b};
			case EDisplay(_):
				typeExpr(ctx, e, expected == null ? WithTypeTools.value : WithTypeTools.withType(expected.key));
				raiseTypingError("Expected a => b", e.pos);
			case _: raiseTypingError("Expected a => b", e.pos);
		});
		var keyExprs = [], valueExprs = [];
		for (pair in pairs) {
			var key = typeExpr(ctx, pair.key, expected == null ? WithTypeTools.value : WithTypeTools.withType(expected.key));
			checkKey(key);
			if (expected != null) key = AbstractCast.castOrUnify(ctx, expected.key, key, key.epos);
			var value = typeExpr(ctx, pair.value, expected == null ? WithTypeTools.value : WithTypeTools.withType(expected.value));
			if (expected != null) value = AbstractCast.castOrUnify(ctx, expected.value, value, value.epos);
			keyExprs.unshift(key);
			valueExprs.unshift(value);
		}
		var tk = expected == null ? unifyMinRaise(ctx, keyExprs) : expected.key,
			tv = expected == null ? unifyMinRaise(ctx, valueExprs) : expected.value;
		var m = Typeload.loadModule(ctx, {pack: ["haxe", "ds"], name: "Map"}, Globals.nullPos), a:Null<TAbstract>, c:Null<TClass>;
		if (m.mTypes.length > 0) switch m.mTypes[0] {
			case TAbstractDecl(abstractType) if (abstractType.aImpl != null):
				a = abstractType;
				c = abstractType.aImpl;
			case _:
				a = null;
				c = null;
		}
		else {
			a = null;
			c = null;
		}
		if (a == null) raiseTypingError("Module haxe.ds.Map is expected to contain an abstract type with an implementation, but found ["
			+ m.mTypes.map(sModuleTypeKind).join(", ")
			+ "]",
			p);
		var tmap = TAbstract(a, [tk, tv]), cf = c.clStatics.get("set");
		if (cf == null) throw core.ds.NotFound.raise();
		var v = genLocal(ctx, tmap, p),
			ev = mk(TLocal(v), tmap, p),
			ec = TyperBase.typeModuleType(ctx, TClassDecl(c), p),
			ef = mk(TField(ec, FStatic(c, cf)), tfun([tk, tv], ctx.t.tvoid), p);
		var result = [ev];
		for (i in 0...keyExprs.length) result.push(makeCall(ctx, ef, [ev, keyExprs[i], valueExprs[i]], ctx.com.basic.tvoid, p));
		result.reverse();
		result.unshift(mk(TVar(v, mk(TNew(c, [tk, tv], []), tmap, p)), tDynamic, p));
		return mk(TBlock(result), tmap, p);
	}

	public static function typeLocalFunction(ctxFrom:TyperContext, kind:FunctionKind, f:Func, withType:WithTypeValue, wantCoroutine:Bool,
			p:Pos):TExpr {
		var name:Null<PlacedName> = null, inlined = false;
		switch kind {
			case FKNamed(n, inlineValue):
				name = n;
				inlined = inlineValue;
			case _:
		}
		var params = TypeloadFunction.typeFunctionParams(ctxFrom, f, TPHLocal, name == null ? "localfun" : name.name);
		var curfun = switch ctxFrom.e.curfun {
			case FunStatic: FunStatic;
			case FunMemberAbstract | FunMemberAbstractLocal: FunMemberAbstractLocal;
			case _: FunMemberClassLocal;
		};
		var isCoroutine = wantCoroutine;
		if (name == null) switch withType {
			case WithType(t, _) if (!ExtType.isMono(follow(t))):
				isCoroutine = switch followWithCoro(t) {
					case Coro(_): true;
					case _: false;
				};
			case _:
		}
		var ctx = TyperManager.cloneForExpr(ctxFrom, curfun, isCoroutine ? FunCoroutine : FunFunction),
			vname:Null<{name:String, kind:TVarKind}> = null, pname = p;
		if (name == null) {
			if (params.length > 0 || isCoroutine) vname = {name: genLocalPrefix, kind: VGenerated};
		} else {
			Naming.checkLocalVariableName(ctx.com, name.name, TVOLocalFunction, p);
			vname = {name: name.name, kind: VUser(TVOLocalFunction)};
			pname = name.pos;
		}
		ctx.typeParams = params.concat(ctx.typeParams);
		if (!inlined) ctx.e.inLoop = false;
		var rt = Typeload.loadTypeHint(ctx, p, LoadReturn, f.fType);
		function typeArg(_:Int, opt:Bool, t:Null<TypeHint>, p:Pos):T return Typeload.loadTypeHint(ctx, p, LoadNormal, t, opt);
		var args = new FunctionArguments(ctx.com, typeArg, false, ctx.f.inDisplay, null, f.fArgs),
			targs = args.forType();
		inline function maybeUnifyArg(t1:T, t2:T):Void switch follow(t1) {
			case TMono(_):
				Typecore.unify(ctx, t2, t1, p);
			case _:
		}
		inline function maybeUnifyRet(tr:T):Void switch [follow(tr), follow(rt)] {
			case [TAbstract({aPath: {pack: [], name: "Void"}}, _), _] if (kind != FKArrow):
			case [_, TMono(_)]:
				Typecore.unify(ctx, rt, tr, p);
			case _:
		}
		// The idea here is: If we have multiple `from Function`, we can
		// 1. ignore any that have a different argument arity, and
		// 2. still top-down infer any argument or return type that is equal across all candidates.
		function matrix(list:Array<T>):Void {
			var arity = targs.length, m = new UnificationMatrix(arity + 1);
			for (t in list) switch followWithCoro(t) {
				case NotCoro(TFun({args: args, ret: ret})) | Coro({args: args, ret: ret}) if (args.length == arity):
					// We don't want to bind monomorphs because we want the widest type
					for (i in 0...args.length) m.join(dynamifyMonos(args[i].type), i + 1);
					m.join(dynamifyMonos(ret), 0);
				case _:
			}
			for (i in 0...targs.length) {
				var t = m.getType(i + 1);
				if (t != null) maybeUnifyArg(targs[i].type, t);
			}
			var ret = m.getType(0);
			if (ret != null) maybeUnifyRet(ret);
		}
		switch withType {
			case WithType(t, _):
				function loop(stack:Array<T>, t:T):Void switch followWithCoro(t) {
					case NotCoro(TFun({args: args2, ret: tr})) | Coro({args: args2, ret: tr}) if (args2.length == targs.length):
						for (i in 0...targs.length) maybeUnifyArg(targs[i].type, args2[i].type);
						// unify for top-down inference unless we are expecting Void
						maybeUnifyRet(tr);
					case NotCoro(TAbstract(a, tl)):
						var froms = TyperBase.getAbstractFroms(ctx, a, tl);
						if (froms.length == 1) {
							if (!core.ds.ArrayTools.exists(stack, t2 -> shallowEq(t, t2))) loop([t].concat(stack), froms[0].type);
						} else {
							// For cases like nested EitherType, we want a flat list of all possible candidates.
							// This might be controversial because those could be considered transitive casts,
							// but it's unclear if that's a bad thing for this kind of inference (issue #10982).
							var pending = froms.copy(), seen = [], flat = [];
							while (pending.length > 0) {
								var next = pending.shift().type;
								switch follow(next) {
									case t = TAbstract(a, tl) if (!core.ds.ArrayTools.exists(seen, t2 -> shallowEq(t, t2))):
										seen.unshift(t);
										pending = pending.concat(TyperBase.getAbstractFroms(ctx, a, tl));
									case _: flat.push(next);
								}
							}
							matrix(flat);
						}
					case _:
				}
				loop([], t);
			case NoValue:
				if (name == null) displayError(ctx.com, "Unnamed lvalue functions are not supported", p);
			case _:
		}
		var ft = isCoroutine ? ctx.t.tcoro.tcoro.force()({args: targs, ret: rt}) : TFun({args: targs, ret: rt});
		// We want to apply params as if we accessed the function by name (see type_ident_raise).
		if (withType != NoValue) ft = applyParams(params, Monomorph.spawnConstrainedMonos(t -> t, params), ft);
		var v:Null<TVar> = null;
		if (vname != null) {
			v = addLocal(ctx, vname.kind, vname.name, ft, pname);
			if (params.length > 0) v.vExtra = varExtra(params, null);
		}
		var oldInArgs = ctx.f.inCallArgs,
			resets = oldInArgs && !inOverloadCallArgs(ctx);
		if (resets) ctx.f.inCallArgs = false;
		var capture = resets ? callArgBodyCapture(ctx) : null,
			deactivate:Void->Void = capture == null ? function() {} : activateMessageCapture(ctx.com, capture), body:TExpr;
		try {
			try body = TypeloadFunction.typeFunction(ctx, args, rt, f.fExpr, ctx.f.inDisplay, p)
			catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some(err)) if (resets):
						checkError(ctx, err);
						body = mk(TBlock([]), ctx.t.tvoid, p);
					case _:
						throw exc;
				}
			}
			deactivate();
			ctx.f.inCallArgs = oldInArgs;
		} catch (exc:haxe.Exception) {
			deactivate();
			ctx.f.inCallArgs = oldInArgs;
			throw exc;
		}
		var tf = ({tfArgs: args.forExpr(ctx), tfType: rt, tfExpr: body} : core.TType.TFunc),
			e = mk(TFunction(tf), ft, p),
			config = TypeloadFields.getCoroConfig(ctx, ctx.f.meta);
		if (config != null) {
			if (v == null) throw "No_value";
			e = CoroTools.funToCoro(CoroTools.createCoroContext(ctx, config, coro.CoroTypes.CoroFor.LocalFunc(tf, v)));
		}
		if (v == null) return e;
		Typeload.generateArgsMeta(ctx.com, null, m -> v.vMeta.unshift(m), f.fArgs);
		if (params.length > 0 || inlined) v.vExtra = varExtra(params, inlined ? e : null);
		if (ctx.f.inDisplay
			&& DisplayPosition.displayPosition.enclosedIn(v.vPos)) context.display.DisplayEmitter.displayVariable(ctx, v, v.vPos);
		function usage(event:Usage):Void switch event {
			case Usage.Block(f) | Usage.Loop(f) | Usage.Function(f):
				f(usage);
			case Usage.Use(v2) | Usage.Assign(v2) if (v == v2):
				throw core.ds.Exit.raise();
			case Usage.Use(_) | Usage.Assign(_) | Usage.Declare(_):
		}
		var recursive = false;
		try LocalUsage.localUsage(usage, e)
		catch (_:core.ds.Exit) {
			recursive = true;
		}
		var exprs = withType != NoValue && !inlined ? [mk(TLocal(v), v.vType, p)] : [];
		if (recursive || (params.length > 0 && withType != NoValue)) {
			if (inlined) displayError(ctx.com, "Inline function cannot be recursive", e.epos);
			exprs = [
				mk(TVar(v, mk(TConst(TNull), ft, p)), ctx.t.tvoid, p),
				mk(TBinop(OpAssign, mk(TLocal(v), ft, p), e), ft, p)
			].concat(exprs);
		} else if (inlined && !ctx.m.isDisplayFile) exprs.unshift(mk(TBlock([]), ctx.t.tvoid, p)); // do not add variable since it will be inlined
		else exprs.unshift(mk(TVar(v, e), ctx.t.tvoid, p));
		if (exprs.length == 1) return exprs[0];
		var block = mk(TBlock(exprs), v.vType, p);
		return mk(TMeta({meta: MetaTag.MergeBlock, exprs: [], pos: Globals.nullPos}, block), v.vType, p);
	}

	public static function typeArrayDecl(ctx:TyperContext, el:Array<Expr>, withType:WithTypeValue, p:Pos):TExpr {
		var allowDynamic = false;
		function loop(seen:Array<T>, t:T):Null<T> return switch follow(t) {
			case TInst({clPath: {pack: [], name: "Array"}}, [tp]): switch follow(tp) {
					case TMono(_): null;
					case t:
						if (t == tDynamic) allowDynamic = true;
						tp;
				}
			case TAnon(_): try getIterableParam(t) catch (_:core.ds.NotFound) {
					null;
				}
			case t = TAbstract(a, pl) if (!core.ds.ArrayTools.exists(seen, t2 -> shallowEq(t, t2))):
				var types = [];
				for (from in TyperBase.getAbstractFroms(ctx, a, pl)) {
					var next = loop([t].concat(seen), from.type);
					if (next != null) types.unshift(next);
				}
				types.length == 1 ? types[0] : null;
			case t: if (t == tDynamic) {
					allowDynamic = true;
					t;
				} else null;
		};
		var tp = switch withType {
			case WithType(t, _): loop([], t);
			case _: null;
		};
		if (tp == null) {
			var typed = el.map(e -> typeExpr(ctx, e, WithTypeTools.value)), t:T;
			try t = unifyMinRaise(ctx, typed)
			catch (exc:Dynamic) {
				switch exc {
					case(core.ds.ExceptionTools.typing(_) => Some(err)):
						switch err.errMessage {
							case Unify(_): if (allowDynamic || ctx.f.isUntyped || ignoreError(ctx.com)) t = tDynamic; else
									t = raiseTypingErrorExt(makeError(Custom("Arrays of mixed types are only allowed if the type is forced to Array<Dynamic>"),
										err.errPos,
									[err]));
							case _: throw exc;
						}
					case _:
						throw exc;
				}
			}
			return mk(TArrayDecl(typed), ctx.t.tarray(t), p);
		}
		var typed = el.map(function(e) {
			var value = typeExpr(ctx, e, WithTypeTools.withType(tp));
			return AbstractCast.castOrUnify(ctx, tp, value, value.epos);
		});
		return mk(TArrayDecl(typed), ctx.t.tarray(tp), p);
	}

	public static function typeArrayComprehension(ctx:TyperContext, e:Expr, withType:WithTypeValue, p:Pos):TExpr {
		var v = genLocal(ctx, spawnMonomorph(ctx, p), p),
			ev = mk(TLocal(v), v.vType, p),
			reference = storeTypedExpr(ctx.com, ev, p).expr,
			initializer:Expr = {
				expr: EConst(Ident("null")),
				pos: p
			};
		function map(expr:Expr):Expr {
			var ep = expr.pos;
			var def = switch expr.expr {
				case EFor(it, e): EFor(it, map(e));
				case EWhile(cond, e, flag): EWhile(cond, map(e), flag);
				case EIf(cond, e1, e2): EIf(cond, map(e1), e2 == null ? null : map(e2));
				case EBlock([e]): EBlock([map(e)]);
				case EBlock([]): return map({expr: EObjectDecl([]), pos: ep});
				case EBlock(el):
					var next = el.copy();
					next[next.length - 1] = map(next[next.length - 1]);
					EBlock(next);
				case EParenthesis(e): EParenthesis(map(e));
				case EMeta(m, e): EMeta(m, map(e));
				case EBinop(OpArrow, a, b):
					initializer = {
						expr: ENew(makePtp({
							tpackage: ["haxe", "ds"],
							tname: "Map",
							tparams: [],
							tsub: null
						}, Globals.nullPos), []),
						pos: p
					};
					ECall({expr: efield(reference, "set"), pos: ep}, [a, b]);
				case _:
					initializer = {expr: EArrayDecl([]), pos: p};
					ECall({expr: efield(reference, "push"), pos: ep}, [expr]);
			};
			return {expr: def, pos: ep};
		}
		var mapped = map(e), ea = typeExpr(ctx, initializer, withType);
		Typecore.unify(ctx, v.vType, ea.etype, p);
		var loop = typeExpr(ctx, mapped, NoValue);
		return mk(TBlock([mk(TVar(v, ea), ctx.t.tvoid, p), loop, ev]), v.vType, p);
	}

	public static function typeReturn(ctx:TyperContext, e:Null<Expr>, withType:WithTypeValue, p:Pos, implicit:Bool = false):TExpr {
		var abstractCtor = ctx.e.curfun == FunMemberAbstract && hasClassFieldFlag(ctx.f.curfield, CfAbstractConstructor);
		if (e == null && abstractCtor) return mk(TReturn(mk(TCast(TyperBase.getThis(ctx, p), null), ctx.e.ret, p)),
			terminatorType(ctx, withType, p), p);
		if (e == null) {
			var v = ctx.t.tvoid;
			Typecore.unify(ctx, v, ctx.e.ret, p);
			var expectVoid = switch withType {
				case WithType(t, _): ExtType.isVoid(follow(t));
				case Value(ImplicitReturn): true;
				case _: false;
			};
			return mk(TReturn(null), expectVoid ? v : terminatorType(ctx, withType, p), p);
		}
		if (abstractCtor) switch e.expr {
			case ECast({expr: EConst(Ident("this"))}, null):
			case _:
				displayError(ctx.com, "Cannot return a value from constructor", p);
		}
		try {
			var expected = ExtType.isVoid(follow(ctx.e.ret)) ? WithTypeTools.noValue : implicit ? WithTypeTools.ofImplicitReturn(ctx.e.ret) : WithTypeTools.withType(ctx.e.ret);
			var e = typeExpr(ctx, e, expected);
			if (ExtType.isVoid(follow(ctx.e.ret)) && implicit) return e;
			e = AbstractCast.castOrUnify(ctx, ctx.e.ret, e, p);
			if (ExtType.isVoid(follow(e.etype))) {
				switch Texpr.skip(e).eexpr {
					case TConst(TNull):
						raiseTypingError("Cannot return `null` from Void-function", p);
					case _:
				}
				// if we get a Void expression (e.g. from inlining) we don't want to return it (issue #4323)
				var t = terminatorType(ctx, withType, p);
				return mk(TBlock([e, mk(TReturn(null), t, p)]), t, e.epos);
			}
			return mk(TReturn(e), terminatorType(ctx, withType, p), p);
		} catch (exc:Dynamic) {
			switch exc {
				case(core.ds.ExceptionTools.typing(_) => Some(err)):
					var p = err.errPos;
					checkError(ctx, err);
					// If we have a bad return, let's generate a return null expression at least. This surpresses various
					// follow-up errors that come from the fact that the function no longer has a return expression (issue #6445).
					return mk(TReturn(mk(TConst(TNull), mkMono(), p)), terminatorType(ctx, withType, p), p);
				case _:
					throw exc;
			}
		}
	}

	public static function typeCast(ctx:TyperContext, e:Expr, hint:TypeHint, p:Pos):TExpr {
		var tpos = hint.pos,
			t = Typeload.loadComplexType(ctx, true, LoadNormal, hint);
		inline function check(pt:T):Void switch follow(pt) {
			case TMono(_): // This probably means that Dynamic wasn't bound (issue #4675).
			case t if (t == tDynamic):
			case _:
				raiseTypingError("Cast type parameters must be Dynamic", tpos);
		}
		function loop(t:T):ModuleType return switch follow(t) {
			case TInst(c, params):
				for (pt in params) check(pt);
				switch c.clKind {
					case KTypeParameter(_): raiseTypingError("Can't cast to a type parameter", tpos);
					case _:
				}
				TClassDecl(c);
			case TEnum(en, params):
				for (pt in params) check(pt);
				TEnumDecl(en);
			case TAbstract(a, params) if (Meta.has(MetaTag.RuntimeValue, a.aMeta)):
				for (pt in params) check(pt);
				TAbstractDecl(a);
			case TAbstract(a, params): loop(AbstractTools.getUnderlyingType(a, params));
			case _: raiseTypingError("Cast type must be a class or an enum", tpos);
		};
		var module = loop(t);
		return mk(TCast(typeExpr(ctx, e, WithTypeTools.value), module), t, p);
	}

	public static function getIfThenElseOperands(ctx:TyperContext, e1:TExpr, e2:TExpr, withType:WithTypeValue):{type:T, coerce:TExpr->TExpr}
		return switch withType {
			case NoValue: {type: ctx.t.tvoid, coerce: function(e:TExpr) return e};
			case Value(_): {type: unifyMin(ctx, [e1, e2]), coerce: function(e:TExpr) return e};
			case WithType(t, src) if (ExtType.isMono(follow(t)) || ExtType.isVoid(follow(t))): {
					type: unifyMinForTypeSource(ctx, [e1, e2], src),
					coerce: function(e:TExpr) return e
				};
			case WithType(t, _): {type: t, coerce: function(e:TExpr) return AbstractCast.castOrUnify(ctx, t, e, e.epos)};
		};

	public static function makeIfThenElse(ctx:TyperContext, e0:TExpr, e1:TExpr, e2:TExpr, withType:WithTypeValue, p:Pos):TExpr {
		var operands = getIfThenElseOperands(ctx, e1, e2, withType),
			a = operands.coerce(e1),
			b = operands.coerce(e2);
		return mk(TIf(e0, a, b), operands.type, p);
	}

	public static function typeIf(ctx:TyperContext, e:Expr, e1:Expr, e2:Null<Expr>, withType:WithTypeValue, ternary:Bool, p:Pos):TExpr {
		var condition = typeExpr(ctx, e, WithTypeTools.value);
		if (ternary && condition.eexpr.match(TConst(TNull))) raiseTypingError("Cannot use null as ternary condition", condition.epos);
		condition = AbstractCast.castOrUnify(ctx, ctx.t.tbool, condition, condition.epos);
		var thenExpr = typeExpr(ctx, ensureBlock(e1), withType);
		if (e2 == null) return mk(TIf(condition, thenExpr, null), ctx.t.tvoid, p);
		var elseExpr = typeExpr(ctx, ensureBlock(e2), withType);
		return makeIfThenElse(ctx, condition, thenExpr, elseExpr, withType, p);
	}

	public static function typeMeta(ctx:TyperContext, m:MetadataEntry, e1:Expr, withType:WithTypeValue, p:Pos, ?mode:AccessMode):TExpr {
		if (mode == null) mode = MGet;
		if (ctx.m.isDisplayFile) checkDisplayMetadata(ctx, [m]);
		var old = ctx.f.meta;
		ctx.f.meta = [m].concat(ctx.f.meta);
		function expression():TExpr return typeExpr(ctx, e1, withType, mode);
		inline function preserve():TExpr {
			var e = expression();
			return mk(TMeta(m, e), e.etype, e.epos);
		}
		var e:TExpr = switch m.meta {
			case MetaTag.ToString:
				var e = expression();
				switch follow(e.etype) {
					case TAbstract(a, _) if (a.aImpl != null && a.aImpl.clStatics.exists("toString")): callToString(ctx, e);
					case _: e;
				}
			case MetaTag.Markup: raiseTypingError("Markup literals must be processed by a macro", p);
			case MetaTag.Analyzer: preserve();
			case MetaTag.MergeBlock: switch e1.expr {
					case EBlock(el):
						var e = typeBlock(ctx, el, withType, p);
						mk(TMeta(m, e), e.etype, e.epos);
					case _: expression();
				}
			case MetaTag.StoredTypedExpr: TyperBase.typeStoredExpr(ctx, e1);
			case MetaTag.NoPrivateAccess:
				ctx.f.meta = ctx.f.meta.filter(m -> m.meta != MetaTag.PrivateAccess);
				expression();
			case MetaTag.Fixed if (ctx.com.platform == Cpp): preserve();
			case MetaTag.NullSafety: preserve();
			case MetaTag.BypassAccessor:
				var counter = ctx.e.bypassAccessor;
				ctx.e.bypassAccessor = counter + 1;
				var e = expression();
				if (ctx.e.bypassAccessor > counter) displayError(ctx.com,
					"Field access expression expected after @:bypassAccessor metadata", m.pos);
				e;
			case MetaTag.Inline: switch e1.expr {
					case ECall(e, el): accGet(ctx, typeCallAccess(ctx, e, el, MGet, WithTypeTools.value, m.pos, p));
					case ENew(t, el):
						var e = typeNew(ctx, t, el, withType, true, p);
						mk(TMeta({meta: MetaTag.Inline, exprs: [], pos: Globals.nullPos}, e), e.etype, e.epos);
					case EFor(it, e2): ForLoop.typeForLoop(ctx, TyperDisplay.handleDisplay, it, e2, ForcedUnroll, p);
					case _:
						displayError(ctx.com, "Call or function expected after inline keyword", p);
						expression();
				}
			case MetaTag.ImplicitReturn: switch e1.expr {
					case EReturn(e): typeReturn(ctx, e, withType, e1.pos, true);
					case _: expression();
				}
			case MetaTag.Coroutine:
				var current = ctx.f.meta;
				function loop(e:Expr):TExpr return switch e.expr {
					case EMeta(m, e):
						ctx.f.meta = [m].concat(ctx.f.meta);
						loop(e);
					case EFunction(kind, f): typeLocalFunction(ctx, kind, f, withType, true, p);
					case _: expression();
				};
				var e = loop(e1);
				ctx.f.meta = current;
				e;
			// Allow `${...}` reification because it's a noop and happens easily with macros
			case MetaTag.Dollar(""): expression();
			case MetaTag.Dollar(s):
				displayError(ctx.com, "Reification $" + s + " is not allowed outside of `macro` expression", m.pos);
				expression();
			case MetaTag.Custom(":debug.import"):
				inline function print(list:Array<ResolvedImport>):Void Sys.println(list.map(res -> sResolutionKind(res.rKind)).join("\n"));
				Sys.println("OWN:");
				print(getOwnResolution(ctx).getList());
				Sys.println("IMPORT:");
				print(ctx.m.importResolution.getList());
				expression();
			case _: ctx.g.retainMeta ? preserve() : expression();
		};
		ctx.f.meta = old;
		return e;
	}

	public static function typeCallTarget(ctx:TyperContext, e:Expr, el:Array<Expr>, withType:WithTypeValue, pInline:Null<Pos>):AccessKind {
		var acc = maybeTypeAgainstEnum(ctx, () -> typeAccess(ctx, e.expr, e.pos, MCall(el), WithTypeTools.value), withType, true, e.pos);
		if (pInline == null) return acc;
		inline function check(cf:TClassField):Void {
			if (hasClassFieldFlag(cf, CfAbstract)) displayError(ctx.com, "Cannot force inline on abstract method", pInline);
		}
		function loop(e:AccessKind):AccessKind return switch e {
			case AKSafeNav(sn): AKSafeNav({
					snPos: sn.snPos,
					snBase: sn.snBase,
					snTempVar: sn.snTempVar,
					snAccess: loop(sn.snAccess)
				});
			case AKField(fa):
				check(fa.faField);
				var copy = core.ds.Record.copy(fa);
				copy.faInline = true;
				AKField(copy);
			case AKUsingField(sea):
				check(sea.seAccess.faField);
				var copy = core.ds.Record.copy(sea),
					access = core.ds.Record.copy(sea.seAccess);
				access.faInline = true;
				copy.seAccess = access;
				AKUsingField(copy);
			case AKExpr({eexpr: TLocal(_)}):
				displayError(ctx.com, "Cannot force inline on local functions", pInline);
				e;
			case _: e;
		};
		return loop(acc);
	}

	public static function typeCallAccess(ctx:TyperContext, e:Expr, el:Array<Expr>, mode:AccessMode, withType:WithTypeValue,
			pInline:Null<Pos>, p:Pos):AccessKind {
		try return AKExpr(typeCallBuiltin(ctx, e, el, mode, withType, p))
		catch (_:core.ds.Exit) {
			return buildCallAccess(ctx, typeCallTarget(ctx, e, el, withType, pInline), el, mode, withType, p);
		}
	}

	public static function typeCallBuiltin(ctx:TyperContext, e:Expr, el:Array<Expr>, mode:AccessMode, withType:WithTypeValue,
			p:Pos):TExpr return switch e.expr {
			case EConst(Ident("trace")) if (el.length > 0):
				var p = e.pos;
				if (Common.defined(ctx.com, Define.NoTraces)) nullExpr(ctx.t.tvoid, p); else {
					var first = el[0], rest = el.slice(1);
					function toStringMeta(e:Expr):Expr return {
						expr: EMeta({meta: MetaTag.ToString, exprs: [], pos: Globals.nullPos}, e),
						pos: e.pos
					};
					var params:Array<core.Ast.ObjectField> = rest.length == 0 ? [] : [
						{
							key: {name: "customParams", pos: Globals.nullPos, quote: NoQuotes},
							expr: {expr: EArrayDecl(rest.map(toStringMeta)), pos: p}
						}
					],
						infos = mkInfos(ctx, p, params);
					if ((platform(ctx.com, Js) || platform(ctx.com, Python)) && rest.length == 0 && hasDce(ctx.com)) {
						var value = typeExpr(ctx, first, WithTypeTools.value);
						if (ExtType.isVoid(follow(value.etype))) raiseTypingError("Cannot use Void as value", value.epos);
						var information = typeExpr(ctx, infos, WithTypeTools.value);
						switch follow(value.etype) {
							case TAbstract(a,
								_) if (a.aImpl != null && a.aImpl.clStatics.exists("toString")): value = callToString(ctx, value);
							case _:
						}
						mk(TCall(mk(TIdent("`trace"), tDynamic, p), [value, information]), ctx.t.tvoid, p);
					} else {
						var root:core.Ast.Expr = {expr: EConst(Ident("haxe")), pos: p},
							log:core.Ast.Expr = {expr: efield(root, "Log"), pos: p},
							trace:core.Ast.Expr = {expr: efield(log, "trace"), pos: p};
						typeExpr(ctx, {expr: ECall(trace, [toStringMeta(first), infos]), pos: p}, NoValue);
					}
				}
			case EField({expr: EConst(Ident("super"))}, _, _):
				// no builtins can be applied to super as it can't be a value
				throw core.ds.Exit.raise();
			case EField(on, "bind", kind):
				var typed = typeExpr(ctx, on, WithTypeTools.value);
				switch follow(typed.etype) {
					case TFun({args: args, ret: ret}): typeBind(ctx, typed, {args: args, ret: ret}, el, kind == EFSafe, e.pos);
					case _: throw core.ds.Exit.raise();
				}
			case EConst(Ident("$type")) if (el.length > 0):
				var expected = el.length == 2 && (switch el[1].expr {
					case EConst(Ident("_")): true;
					case _: false;
				}) ? WithTypeTools.toString(withType) : null;
				var value = typeExpr(ctx, el[0], withType),
					s = sType(printContext(), value.etype);
				if (expected != null) s += " (expected: " + expected + ")";
				warning(ctx, WInfo, s, value.epos);
				value;
			case EField(on, "match", kind) if (el.length == 1):
				if (kind == EFSafe) raiseTypingError("?.match is not supported", e.pos);
				var typed = typeExpr(ctx, on, WithTypeTools.value);
				function hasEnumMatch(t:T):Bool return switch follow(t) {
					case TEnum(_): true;
					case TAbstract(a,
						tl) if (Meta.has(MetaTag.Forward,
							a.aMeta) && !Meta.has(MetaTag.CoreType,
								a.aMeta)): if (a.aImpl != null
							&& a.aImpl.clStatics.exists("match")
							&& hasClassFieldFlag(a.aImpl.clStatics.get("match"),
								CfImpl)) false; else hasEnumMatch(AbstractTools.getUnderlyingType(a, tl, true));
					case _: false;
				};
				if (!hasEnumMatch(typed.etype)) throw core.ds.Exit.raise();
				Matcher.matchExpr(ctx, on, [
					{
						patterns: [el[0]],
						guard: null,
						expr: {expr: EConst(Ident("true")), pos: e.pos},
						pos: e.pos
					}
				],
					{expr: {expr: EConst(Ident("false")), pos: e.pos}, pos: e.pos}, WithTypeTools.withType(ctx.t.tbool), true, e.pos);
			case EConst(Ident("__unprotect__")) if (el.length == 1 && switch el[0].expr {
					case EConst(String(_)): true;
					case _: false;
				}):
				var value = typeExpr(ctx, el[0], WithTypeTools.value);
				if (Common.platform(ctx.com, Flash)) {
					var t = tfun([value.etype], value.etype);
					mk(TCall(mk(TIdent("__unprotect__"), t, p), [value]), value.etype, value.epos);
				} else value;
			case EDisplay(subject = {expr: EConst(Ident("super"))},
				dk): TyperDisplay.handleDisplay(ctx, {expr: ECall(subject, el), pos: p}, dk, mode, withType);
			case EConst(Ident("super")):
				if (ctx.e.curfun != FunConstructor) raiseTypingError("Cannot call super constructor outside class constructor", p);
				var sup = ctx.c.curclass.clSuper;
				if (sup == null) raiseTypingError("Current class does not have a super", p);
				var c = sup.cls, params = sup.params, fa = FieldAccessTools.getConstructorAccess(c, params, p), cf = fa.faField,
					t = TInst(c, params), on = mk(TConst(TSuper), t, e.pos);
				if (Meta.has(MetaTag.CompilerGenerated, cf.cfMeta)) displayError(ctx.com, errorMsg(NoConstructor(TClassDecl(c))), p);
				fa = FieldAccessTools.create(on, cf, FHInstance(c, params), false, p);
				var fcc = unifyFieldCall(ctx, fa, [], el, p, false);
				mk(TCall(mk(TConst(TSuper), t, e.pos), fcc.fcArgs), ctx.t.tvoid, p);
			case _: throw core.ds.Exit.raise();
		};

	public static function typeExpr(ctx:TyperContext, syntax:Expr, withType:WithTypeValue, ?mode:AccessMode):TExpr {
		core.ds.GcPolicy.tick();
		if (mode == null) mode = MGet;
		var e = syntax.expr, p = syntax.pos;
		return switch e {
			case EField({expr: EConst(String(s, _)), pos: ps}, "code", EFNormal):
				if ([for (code in new haxe.iterators.StringIteratorUnicode(s)) code].length != 1)
					raiseTypingError("String must be a single UTF8 char", ps);
				mk(TConst(TInt(new haxe.iterators.StringIteratorUnicode(s).next())), ctx.t.tint, p);
			case EField(_, name,
				_) if (StringTools.startsWith(name, "$")): raiseTypingError("Field names starting with $ are not allowed", p);
			case EConst(Ident(s)):
				if (s == "super" && withType != NoValue && !ctx.f.inDisplay) raiseTypingError("Cannot use super as value", p);
				accGet(ctx, maybeTypeAgainstEnum(ctx, () -> typeIdent(ctx, s, p, mode, withType), withType, false, p));
			case EField(_) | EArray(_) | ECall(_): accGet(ctx, typeAccess(ctx, e, p, mode, withType));
			case EConst(Regexp(r, opt)):
				var str = mk(TConst(TString(r)), ctx.t.tstring, p),
					options = mk(TConst(TString(opt)), ctx.t.tstring, p),
					t = Typeload.loadInstance(ctx, makePtp(mkTypePath(["std"], "EReg"), Globals.nullPos), ParamNormal, LoadNormal);
				var c = switch t {
					case TInst(c, []): c;
					case _: throw "Invalid EReg class";
				};
				mk(TNew(c, [], [str, options]), t, p);
			case EConst(String(s, SSingleQuotes)) if (s != ""): typeExpr(ctx, formatString(ctx, s, p), withType);
			case EConst(Int(s, suffix)) if (suffix != null): switch suffix {
					case "i32": try mk(TConst(TInt(core.ds.OcamlInt32.ofString(s))), ctx.com.basic.tint,
							p) catch (_:Dynamic) raiseTypingError("Cannot represent " + s + " with a 32 bit integer", p);
					case "i64":
						if (s.length > 18 && s.substr(0, 2) == "0x") raiseTypingError("Invalid hexadecimal integer", p);
						var value = core.ds.OcamlInt64.ofString(s),
							high = value.high,
							low = value.low;
						var root:core.Ast.Expr = {expr: EConst(Ident("haxe")), pos: p},
							int64:core.Ast.Expr = {expr: efield(root, "Int64"), pos: p},
							field:core.Ast.Expr = {expr: efield(int64, "make"), pos: p};
						typeExpr(ctx, {
							expr: ECall(field, [
								{expr: EConst(Int(Std.string(high), null)), pos: p},
								{expr: EConst(Int(Std.string(low), null)), pos: p}
							]),
							pos: p
						}, withType);
					case "u32": typeExpr(ctx,
							{expr: ECheckType({expr: EConst(Int(s, null)), pos: p}, makePtpTh(mkTypePath(["haxe"], "UInt32"), p)), pos: p},
							withType);
					case other: raiseTypingError(other + " is not a valid integer suffix", p);
				}
			case EConst(c = Float(_,
				suffix)) if (suffix != null): suffix == "f64" ? Texpr.typeConstant(ctx.com.basic, c,
					p) : raiseTypingError(suffix + " is not a valid float suffix", p);
			case EConst(c): Texpr.typeConstant(ctx.com.basic, c, p);
			case EBinop(OpNullCoal, a, b):
				var reference = new ValueReference(ctx),
					e1 = typeExpr(ctx, ensureBlock(a), WithTypeTools.value),
					e2 = typeExpr(ctx, ensureBlock(b), WithTypeTools.withType(e1.etype)),
					operands = getIfThenElseOperands(ctx, e1, e2, withType);
				e2 = operands.coerce(e2);
				var iftype = DeadEnd.hasDeadEnd(e2) ? followWithoutType(e1.etype) : switch e2.etype {
					case TAbstract({aPath: {pack: [], name: "Null"}}, [_]): operands.type;
					case _: followWithoutType(operands.type);
				};
				var nullable = ctx.t.tnull(e1.etype),
					name = WithTypeTools.getExpectedName(withType);
				if (name == null || name == "") name = "tmp"; // TODO: why does this happen?
				e1 = reference.asVar(name, mk(e1.eexpr, nullable, e1.epos));
				var enull = Builder.makeNull(nullable, e1.epos),
					condition = mk(TBinop(OpNotEq, e1, enull), ctx.t.tbool, e1.epos),
					eif = mk(TIf(condition, operands.coerce(e1), e2), iftype, p);
				reference.toTexpr(eif);
			case EBinop(OpAssignOp(OpNullCoal), a, b): typeOpNullCoalAssign(ctx, a, b, withType, p);
			case EBinop(op, a, b): typeBinop(ctx, op, a, b, false, withType, p);
			case EBlock([]) if (switch withType {
					case NoValue: false;
					/*
						If expected type is unknown then treat `(...) -> {}` as an empty function
						(just like `function(...) {}`) instead of returning an object.
					*/
					case WithType(t, ImplicitReturn): !ExtType.isMono(follow(t));
					case _: true;
				}): typeExpr(ctx, {expr: EObjectDecl([]), pos: p}, withType);
			case EBlock(list):
				var locals = saveLocals(ctx),
					e = typeBlock(ctx, list, withType, p);
				locals();
				e;
			case EParenthesis(inner):
				var e = typeExpr(ctx, inner, withType);
				mk(TParenthesis(e), e.etype, p);
			case EObjectDecl(fields): typeObjectDecl(ctx, fields, withType, p);
			case EArrayDecl([e = {expr: EFor(_, _) | EWhile(_, _, _)}]): typeArrayComprehension(ctx, e, withType, p);
			case EArrayDecl([
				e = {
					expr: EMeta({meta: MetaTag.Inline, exprs: []}, {expr: EFor(_, _)})
				}
			]): typeArrayComprehension(ctx, e, withType, p); // awkward...
			case EArrayDecl(list) if (list.length > 0 && switch list[0].expr {
					case EBinop(OpArrow, _, _): true;
					case _: false;
				}): typeMapDeclaration(ctx, list[0], list.slice(1), withType, p);
			case EArrayDecl(list):
				switch withType {
					case WithType(t, _): switch follow(t) {
							case TAbstract({aPath: {pack: ["haxe", "ds"], name: "Map"}}, [tk, _]):
								if (list.length == 0) typeExpr(ctx, {
									expr: ENew(makePtp({
										tpackage: ["haxe", "ds"],
										tname: "Map",
										tparams: [],
										tsub: null
									}, Globals.nullPos), []),
									pos: p
								}, withType); else if (list.length == 1 && switch list[0].expr {
									case EDisplay(_): true;
									case _: false;
								})
									// This must mean we're just typing the first key of a map declaration (issue #9133).
									typeExpr(ctx, list[0], WithTypeTools.withType(tk)); else typeArrayDecl(ctx, list, withType, p);
							case _: typeArrayDecl(ctx, list, withType, p);
						}
					case _: typeArrayDecl(ctx, list, withType, p);
				}
			case EVars(vl): typeVars(ctx, vl, p);
			case EFor(it, e2): ForLoop.typeForLoop(ctx, TyperDisplay.handleDisplay, it, e2, NoForcedUnroll, p);
			case ETernary(e1, e2, e3): typeIf(ctx, e1, e2, e3, withType, true, p);
			case EIf(e, e1, e2): typeIf(ctx, e, e1, e2, withType, false, p);
			case EWhile(cond, body, NormalWhile):
				var old = ctx.e.inLoop,
					condition = typeExpr(ctx, cond, WithTypeTools.value);
				condition = AbstractCast.castOrUnify(ctx, ctx.t.tbool, condition, p);
				ctx.e.inLoop = true;
				var e = typeExpr(ctx, ensureBlock(body), NoValue);
				ctx.e.inLoop = old;
				mk(TWhile(condition, e, NormalWhile), ctx.t.tvoid, p);
			case EWhile(cond, body, DoWhile):
				var old = ctx.e.inLoop;
				ctx.e.inLoop = true;
				var e = typeExpr(ctx, ensureBlock(body), NoValue);
				ctx.e.inLoop = old;
				var condition = typeExpr(ctx, cond, WithTypeTools.value);
				condition = AbstractCast.castOrUnify(ctx, ctx.t.tbool, condition, condition.epos);
				mk(TWhile(condition, e, DoWhile), ctx.t.tvoid, p);
			case ESwitch(e1, cases, def):
				var result = Matcher.matchExpr(ctx, e1, cases.map(c -> ({
					patterns: c.values,
					guard: c.guard,
					expr: c.expr,
					pos: c.pos
				} : typing.Matcher.MatchCase)), def, withType, false, p);
				mk(TMeta({meta: MetaTag.Ast, exprs: [syntax], pos: p}, result), result.etype, result.epos);
			case EReturn(e):
				if (!TyperManager.isFunctionContext(ctx)) {
					displayError(ctx.com, "Return outside function", p);
					e == null ? Texpr.Builder.makeNull(terminatorType(ctx, withType, p), p) :
						// type the return expression to see if there are more errors
						// as well as use its type as if there was no `return`, since
						// that is most likely what was meant
						typeExpr(ctx, e, WithTypeTools.value);
				} else typeReturn(ctx, e, withType, p);
			case EBreak:
				if (!ctx.e.inLoop) displayError(ctx.com, "Break outside loop", p);
				mk(TBreak, terminatorType(ctx, withType, p), p);
			case EContinue:
				if (!ctx.e.inLoop) displayError(ctx.com, "Continue outside loop", p);
				mk(TContinue, terminatorType(ctx, withType, p), p);
			case ETry(e1, []): typeExpr(ctx, e1, withType);
			case ETry(e1, catches): typeTry(ctx, e1, catches, withType, p);
			case EThrow(e):
				var value:TExpr;
				try value = typeExpr(ctx, e, WithTypeTools.value)
				catch (exc:Dynamic) {
					switch exc {
						case(core.ds.ExceptionTools.typing(_) => Some(err)):
							checkError(ctx, err);
							value = Texpr.Builder.makeNull(tDynamic, p);
						case _: throw exc;
					}
				}
				mk(TThrow(value), terminatorType(ctx, withType, p), p);
			case ENew(t, el): typeNew(ctx, t, el, withType, false, p);
			case EUnop(op, flag, e): typeUnop(ctx, op, flag, e, withType, p);
			case EFunction(kind, f): typeLocalFunction(ctx, kind, f, withType, false, p);
			case EUntyped(inner):
				var old = ctx.f.isUntyped;
				ctx.f.isUntyped = true;
				if (!Meta.has(MetaTag.HasUntyped,
					ctx.f.curfield.cfMeta)) ctx.f.curfield.cfMeta.unshift({meta: MetaTag.HasUntyped, exprs: [], pos: mkZeroRangePos(p)});
				var value = typeExpr(ctx, inner, withType);
				ctx.f.isUntyped = old;
				mk(value.eexpr, mkMono(), value.epos);
			case ECast(inner, null):
				var value = typeExpr(ctx, inner, WithTypeTools.value);
				mk(TCast(value, null), spawnMonomorph(ctx, p), p);
			case ECast(inner, t): typeCast(ctx, inner, t, p);
			case EDisplay(inner, dk): TyperDisplay.handleEdisplay(ctx, inner, dk, mode, withType);
			case ECheckType(inner, hint):
				var t = Typeload.loadComplexType(ctx, true, LoadAny, hint),
					value = typeExpr(ctx, inner, WithTypeTools.withType(t));
				value = AbstractCast.castOrUnify(ctx, t, value, p);
				value.etype == t ? value : mk(TCast(value, null), t, p);
			case EMeta(m, inner): typeMeta(ctx, m, inner, withType, p, mode);
			case EIs(inner, hint): switch hint.type {
					case CTPath(tp):
						if (tp.path.tparams.length > 0) displayError(ctx.com, "Type parameters are not supported for the `is` operator",
							hint.pos);
						var value = typeExpr(ctx, inner, WithTypeTools.value),
							mt = Typeload.loadTypeDef(ctx, hint.pos, tp.path);
						if (ctx.f.inDisplay
							&& DisplayPosition.displayPosition.enclosedIn(hint.pos)) context.display.DisplayEmitter.displayModuleType(ctx,
								mt, hint.pos);
						var typeValue = TyperBase.typeModuleType(ctx, mt, hint.pos);
						Texpr.Builder.resolveAndMakeStaticCall(ctx.com.std, "isOfType", [value, typeValue], p);
					case _:
						displayError(ctx.com, "Unsupported type for `is` operator", hint.pos);
						Texpr.Builder.makeBool(ctx.com.basic, false, p);
				}
		};
	}

	public static function initialize():Void {
		unifyMinRef = unifyMin;
		unifyMinForTypeSourceRef = unifyMinForTypeSource;
		makeCallRef = Calls.makeCall;
		TyperBase.typeCallTargetRef = typeCallTarget;
		TyperBase.typeAccessRef = typeAccess;
		typeBlockRef = typeBlock;
		typeExprRef = typeExpr;
	}

	static function __init__():Void initialize();
}
