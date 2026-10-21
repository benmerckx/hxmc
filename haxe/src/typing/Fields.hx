package typing;

import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.display.DisplayPosition;
import core.Ast;
import core.Ast.*;
import core.TType;
import core.TType.*;
import core.TFunctions.*;
import core.TFunctions;
import core.TOther.*;
import core.TOther;
import core.TPrinting.*;
import core.Globals;
import core.Globals.*;
import context.display.ImportHandling;
import core.Meta;
import core.WithType;
import core.Error.*;
import core.Error;
import context.Typecore.*;
import context.Typecore;
import context.Common;
import core.Define;
import core.Abstract;
import core.TUnification;
import core.TUnification.*;
import core.ds.NotFound;
import core.ds.Exit;
import core.StringError;
import core.Message;
import context.Common.*;
import context.Typecore.FieldHost as AccessHost;
import context.Typecore.FieldAccess as AccessData;
import core.display.Javadoc;
import typing.TyperBase;
import typing.TyperBase.*;
import typing.FieldAccess;
import typing.FieldAccess.*;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

class TypeFieldConfig {
	public var allowResolve:Bool = true;
	public var allowDynamic:Bool = true;
	public var allowOpenMono:Bool = true;
	public var doResume:Bool = false;

	public function new() {}

	public static final defaultConfig = new TypeFieldConfig();

	public static function create(resume:Bool):TypeFieldConfig {
		var cfg = new TypeFieldConfig();
		cfg.doResume = resume;
		return cfg;
	}

	public static function withResume(cfg:TypeFieldConfig):TypeFieldConfig {
		var result = new TypeFieldConfig();
		result.allowResolve = cfg.allowResolve;
		result.allowDynamic = cfg.allowDynamic;
		result.allowOpenMono = cfg.allowOpenMono;
		result.doResume = true;
		return result;
	}
}

class Fields {
	static function some<V>(v:Null<V>):V {
		if (v == null) throw NotFound.raise();
		return v;
	}

	static function byList<V>(f:V->AccessKind, list:Array<V>):AccessKind {
		for (x in list) try return f(x)
		catch (_:NotFound) {}
		throw NotFound.raise();
	}

	// port: by_list on a list kept as a Vector
	static function byVector<V>(f:V->AccessKind, list:haxe.ds.Vector<V>):AccessKind {
		for (x in list) try return f(x)
		catch (_:NotFound) {}
		throw NotFound.raise();
	}

	/*
		temporally remove the constant flag from structures to allow larger unification
	*/
	public static function removeConstantFlag<A>(t:T, callback:Bool->A):A {
		var temporary:Array<TAnon> = [];
		function loop(t:T):Void switch follow(t) {
			case TAnon(a):
				if (a.aStatus == Const) {
					a.aStatus = Closed;
					temporary.unshift(a);
				}
				for (f in a.aFields) loop(f.cfType);
			case _:
		}
		inline function restore():Void {
			for (a in temporary) a.aStatus = Const;
		}
		try {
			loop(t);
			var ret = callback(temporary.length != 0);
			restore();
			return ret;
		} catch (e:haxe.Exception) {
			restore();
			throw e;
		}
	}

	public static function enumFieldType(ctx:Typer, en:TEnum, ef:TEnumField, p:Pos):T {
		var enTypes = Monomorph.spawnConstrainedMonos(t -> t, en.eParams),
			map = t -> applyParams(en.eParams, enTypes, t),
			efTypes = Monomorph.spawnConstrainedMonos(map, ef.efParams);
		return map(applyParams(ef.efParams, efTypes, ef.efType));
	}

	public static function fieldType(ctx:Typer, c:TClass, pl:TParams, f:TClassField, p:Pos):T {
		if (f.cfParams.length == 0) return f.cfType;
		var map:T->T = pl.length == 0 ? (t->t) : (t->applyParams(c.clParams, pl, t));
		var monos = Monomorph.spawnConstrainedMonos(map, f.cfParams);
		return applyParams(f.cfParams, monos, f.cfType);
	}

	public static function noAbstractConstructor(c:TClass, p:Pos):Void {
		if (hasClassFlag(c, CAbstract)) raiseTypingErrorExt(makeError(AbstractClass(TClassDecl(c)), p));
	}

	public static function checkConstructorAccess(ctx:Typer, c:TClass, f:TClassField, p:Pos):Void {
		if (Meta.has(MetaTag.CompilerGenerated, f.cfMeta)) displayError(ctx.com, errorMsg(NoConstructor(TClassDecl(c))), p);
		if (!(canAccess(ctx, c, f, true) || extendsClass(ctx.c.curclass, c))
			&& !ctx.f.isUntyped) displayError(ctx.com, "Cannot access private constructor of " + sClassPath(c), p);
	}

	public static function checkNoClosureMeta(ctx:Typer, cf:TClassField, fa:AccessHost, mode:AccessMode, p:Pos):Void switch mode {
		case MGet | MSet(_) if (!DisplayPosition.displayPosition.enclosedIn(p)):
			switch cf.cfKind {
				case Method(_):
					var meta = switch fa {
						case FHStatic(c) | FHInstance(c, _) | FHAbstract(_, _, c): c.clMeta;
						case _: [];
					};
					if (Meta.has(MetaTag.NoClosure,
						meta) || Meta.has(MetaTag.NoClosure,
							cf.cfMeta)) raiseTypingError("Method " + cf.cfName + " cannot be used as a value", p);
				case _:
			}
		case _:
	}

	public static function fieldAccess(ctx:Typer, mode:AccessMode, f:TClassField, fh:AccessHost, e:TExpr, pfield:Pos):AccessKind {
		var pfull = Ast.punion(e.epos, pfield), isSet = switch mode {
			case MSet(_): true;
			case _: false;
		};
		checkNoClosureMeta(ctx, f, fh, mode, pfield);
		inline function bypass():Bool {
			if (ctx.e.bypassAccessor > 0) {
				ctx.e.bypassAccessor--;
				return true;
			}
			return false;
		}
		inline function makeAccess(inlineValue:Bool):AccessData return FieldAccess.create(e, f, fh, inlineValue && ctx.allowInline, pfull,
			pfield);
		return switch f.cfKind {
			case Method(m):
				inline function normal():AccessKind return AKField(makeAccess(false));
				if (isSet && m != MethDynamic && !ctx.f.isUntyped)
					raiseTypingError("Cannot rebind this method : please use 'dynamic' before method declaration", pfield);
				// For overloads we have to resolve the actual field before we can check accessibility.
				inline function visibility(c:TClass, isStatic:Bool):Void switch mode {
					case MCall(_) if (hasClassFieldFlag(f, CfOverload)):
					case _:
						checkFieldAccess(ctx, c, f, isStatic, pfield);
				}
				inline function defaultAccess():AccessKind return switch [m, mode] {
					case [MethInline, _] if (ctx.com.doinline && ctx.allowInline): AKField(makeAccess(true));
					case [MethMacro, MGet]:
						displayError(ctx.com, "Macro functions must be called immediately", pfield);
						normal();
					case [_, MGet]:
						if (hasClassFieldFlag(f, CfGeneric)) displayError(ctx.com, "Cannot create closure on generic function", pfield);
						normal();
					case _: normal();
				};
				switch fh {
					case FHInstance(c, tl):
						if (e.eexpr.match(TConst(TSuper))) switch mode {
							case MSet(_) | MGet: displayError(ctx.com, "Cannot create closure on super method", pfield);
							case MCall(_):
						}
						// We need the actual class type (i.e. a potential child class) for visibility checks.
						switch follow(e.etype) {
							case TInst(c, _): visibility(c, false);
							case _:
						}
						defaultAccess();
					case FHStatic(c):
						visibility(c, true);
						defaultAccess();
					case FHAnon: defaultAccess();
					case FHAbstract(a, tl, c):
						visibility(c, true);
						AKUsingField(makeAbstractStaticExtensionAccess(a, tl, c, f, e, false, pfull));
				}
			case Var(v):
				inline function prop(access:VarAccess):Bool return switch access {
					case AccCall | AccPrivateCall: ctx.e.bypassAccessor == 0;
					case _: false;
				};
				inline function checkMode(c:TClass, isStatic:Bool):Void switch mode {
					case MGet if (prop(v.vRead)):
						if (!canAccess(ctx, c, f, isStatic, true,
							false)) raiseTypingError("This property cannot be accessed for reading", pfield);
					case MSet(_) if (prop(v.vWrite)):
						if (!canAccess(ctx, c, f, isStatic, true,
							true)) raiseTypingError("This property cannot be accessed for writing", pfield);
					case _:
						checkFieldAccess(ctx, c, f, isStatic, pfield);
				}
				switch fh {
					case FHStatic(c) | FHAbstract(_, _, c): checkMode(c, true);
					case FHInstance(_):
						switch follow(e.etype) {
							case TInst(c, _): checkMode(c, false);
							case _:
						}
						if (e.eexpr.match(TConst(TSuper))) switch mode {
							case MGet | MCall(_) if (v.vRead == AccCall || v.vRead == AccPrivateCall):
							case MSet(_) if (v.vWrite == AccCall || v.vWrite == AccPrivateCall):
							case _: displayError(ctx.com, "Normal variables cannot be accessed with 'super', use 'this' instead", pfield);
						}
					case FHAnon:
						inline function privateAccess(a:VarAccess):Bool return a == AccPrivateCall
							&& !Meta.has(MetaTag.PrivateAccess, ctx.f.meta)
							&& ctx.e.bypassAccessor == 0;
						switch mode {
							case MGet if (privateAccess(v.vRead)): raiseTypingError("This property cannot be accessed for reading", pfield);
							case MSet(_) if (privateAccess(v.vWrite)): raiseTypingError("This property cannot be accessed for writing",
									pfield);
							case _:
						}
				}
				inline function normal(inlineValue:Bool):AccessKind return AKField(makeAccess(inlineValue));
				inline function failure():AccessKind return AKNo(normal(false), pfield);
				var access = isSet ? v.vWrite : v.vRead;
				switch access {
					case AccNo if (!Meta.has(MetaTag.PrivateAccess, ctx.f.meta)):
						var privateField:TClassField = core.ds.Record.copy(f);
						removeClassFieldFlag(privateField, CfPublic);
						switch follow(e.etype) {
							case TInst(c, _) if (extendsClass(ctx.c.curclass, c) || canAccess(ctx, c, privateField, false)): normal(false);
							case TAnon(a): switch a.aStatus {
									case ClassStatics(c) if (ctx.c.curclass == c || canAccess(ctx, c, privateField, true)): normal(false);
									case _: ctx.f.isUntyped ? normal(false) : failure();
								}
							case _: ctx.f.isUntyped ? normal(false) : failure();
						}
					case AccNormal | AccNo: normal(false);
					case AccCall | AccPrivateCall
						if (!ctx.allowTransform || (ctx.f.inDisplay && DisplayPosition.displayPosition.enclosedIn(pfull))): normal(false);
					case AccCall | AccPrivateCall:
						var name = (isSet ? "set_" : "get_") + f.cfName;
						var ownReceiver = switch e.eexpr {
							case TConst(TThis): true;
							case TLocal(v): ctx.f.vthis != null && v == ctx.f.vthis;
							case TTypeExpr(TClassDecl(c)) if (c == ctx.c.curclass): true;
							case _: false;
						};
						var shouldBypass = (name == ctx.f.curfield.cfName && ownReceiver) || bypass();
						if (shouldBypass) {
							switch e.eexpr {
								case TLocal(_) if (Common.defined(ctx.com,
									Define.Haxe3Compat)): warning(ctx, WTemp,
										"Field set has changed here in Haxe 4: call setter explicitly to keep Haxe 3.x behaviour", pfield);
								case _:
							}
							if (!isPhysicalField(f)) displayErrorExt(ctx.com,
								makeError(Custom("This field cannot be accessed because it is not a real variable"), pfield,
									[makeError(Custom("Add @:isVar here to enable it"), f.cfPos)]));
							normal(false);
						} else switch fh {
							case FHAbstract(a, tl, c): AKUsingAccessor(makeAbstractStaticExtensionAccess(a, tl, c, f, e, false, pfull));
							case _: AKAccessor(makeAccess(false));
						}
					case AccNever: ctx.f.isUntyped ? normal(false) : failure();
					case AccInline: normal(true);
					case AccCtor: switch [ctx.e.curfun, fh] {
							case [FunConstructor, FHInstance(c, _)]
								if (c == ctx.c.curclass || (hasClassFlag(c, CAbstract) && extendsClass(ctx.c.curclass, c))): normal(false);
							case _: failure();
						}
					case AccRequire(r, msg): msg == null ? errorRequire(r, pfield) : raiseTypingError(msg, pfield);
				}
		};
	}

	public static function classField(ctx:Typer, c:TClass, tl:TParams, name:String,
			p:Pos):RawClassField return rawClassField(f -> fieldType(ctx, c, tl, f, p), c, tl, name);

	// Resolves field [i] on typed expression [e] using the given [mode].
	// Note: if mode = MCall, with_type (if known) refers to the return type
	public static function typeField(cfg:TypeFieldConfig, ctx:Typer, e:TExpr, i:String, p:Pos, mode:AccessMode,
			withType:WithTypeValue):AccessKind {
		var pfield = e.epos == p ? p : patchStringPos(p, i),
			isSet = switch mode {
				case MSet(_): true;
				case _: false;
			};
		inline function access(e:TExpr, f:TClassField, host:AccessHost):AccessKind return fieldAccess(ctx, mode, f, host, e, pfield);
		inline function classAccess(e:TExpr, c:TClass, tl:TParams):{field:TClassField, access:AccessKind} {
			var raw = classField(ctx, c, tl, i, p),
				host = raw.owner == null ? FHAnon : FHInstance(raw.owner.cls, raw.owner.params);
			return {field: raw.field, access: access(e, raw.field, host)};
		}
		inline function byET(f:TExpr->T->AccessKind, e:TExpr, t:T):AccessKind return f(mk(TCast(e, null), t, e.epos), followWithoutType(t));
		inline function byE(f:TExpr->T->AccessKind, e:TExpr):AccessKind return f(e, followWithoutType(e.etype));
		inline function byForward(f:Void->AccessKind, meta:MetaTag, a:TAbstract):AccessKind {
			var m = Meta.get(meta, a.aMeta), el = m.exprs;
			if (el.length != 0) {
				var found = false;
				for (e in el) {
					var name = switch e.expr {
						case EConst(Ident(s) | String(s, _)): s;
						case _: raiseTypingError("Identifier or string expected as argument to @:forward", e.pos);
					};
					if (name == i) {
						found = true;
						break;
					}
				}
				if (!found) throw NotFound.raise();
			}
			return f();
		}
		inline function forwardStatic(f:Void->AccessKind, a:TAbstract):AccessKind return byForward(f, MetaTag.ForwardStatics, a);
		inline function forwardMember(f:TExpr->T->AccessKind, e:TExpr, a:TAbstract,
				tl:TParams):AccessKind return byForward(() -> byET(f, e, Abstract.getUnderlyingType(a, tl, true)), MetaTag.Forward, a);
		inline function byTypedef(f:TExpr->T->AccessKind, e:TExpr, td:TDef,
				tl:TParams):AccessKind return f(e, followWithoutType(applyTypedef(td, tl)));
		inline function byInterfaces(e:TExpr, c:TClass):AccessKind {
			// For extern lib types we didn't go through check_interfaces and check_abstract_class, which handles some field
			// generation. We instead do this lazily here by browsing the implemented interfaces (issue #9768).
			if (!(hasClassFlag(c, CExtern) && Meta.has(MetaTag.LibType, c.clMeta))) throw NotFound.raise();
			return byList(function(pair) {
				var result = classAccess(e, pair.cls, pair.params);
				// It should be fine to just add the field to our class to make future lookups a bit faster.
				TClassTools.addField(c, result.field);
				return result.access;
			}, c.clImplements);
		}
		inline function noNoLookup(cf:TClassField):Void {
			if (hasClassFieldFlag(cf, CfNoLookup)) displayError(ctx.com, "This field cannot be accessed explicitly", pfield);
		}
		function byType(e:TExpr, t:T):AccessKind return switch t {
			case TType(td, tl): byTypedef(byType, e, td, tl);
			case TInst(c, tl):
				try classAccess(e, c, tl).access catch (err:Dynamic) {
					if (!Std.isOfType(err, NotFound)) throw err;
					try switch c.clKind {
						case KTypeParameter(ttp): byVector(function(t) return switch follow(t) {
								case TAbstract(_): byE(byType, mkCast(e, t, p));
								case _: throw NotFound.raise();
							}, getConstraints(ttp));
						case _: throw NotFound.raise();
					} catch (err:Dynamic) {
						if (!Std.isOfType(err, NotFound)) throw err;
						byInterfaces(e, c);
					}
				}
			case TAnon(a): switch a.aStatus {
					case ClassStatics(c):
						try {
							var cf = some(c.clStatics.get(i));
							if (hasClassFieldFlag(cf,
								CfImpl) && !hasClassFieldFlag(cf,
									CfEnum)) displayError(ctx.com, "Cannot access non-static abstract field statically", pfield);
							noNoLookup(cf);
							access(e, cf, FHStatic(c));
						} catch (err:Dynamic) {
							if (!Std.isOfType(err, NotFound)) throw err;
							switch c.clKind {
								case KAbstractImpl(a): forwardStatic(function() {
										var mt:ModuleType;
										try mt = moduleTypeOfType(a.aThis)
										catch (err:Dynamic) {
											if (!Std.isOfType(err, Exit)) throw err;
											throw NotFound.raise();
										}
										return byE(byType, TyperBase.typeModuleType(ctx, mt, p));
									}, a);
								case _: throw NotFound.raise();
							}
						}
					case EnumStatics(en):
						var c = some(en.eConstrs.get(i));
						AKExpr(mk(TField(e, FEnum(en, c)), enumFieldType(ctx, en, c, p), p));
					case _: access(e, some(a.aFields.get(i)), FHAnon);
				}
			case TMono(r):
				inline function makeField():TClassField {
					var f = mkField(i, spawnMonomorph(ctx, p), p, Globals.nullPos);
					f.cfKind = Var({vRead: AccNormal, vWrite: isSet ? AccNormal : AccNo});
					return f;
				}
				function checkConstraint(constr:TMonoConstraintKind):AccessKind return switch constr {
					case CStructural(fields, isOpen):
						try {
							var f = some(fields.get(i));
							switch f.cfKind {
								// We previously inferred to read-only, but now we want to write. This can happen in cases like #8079.
								case Var(acc) if (acc.vWrite == AccNo && isOpen && isSet):
									var copy = core.ds.Record.copy(acc);
									copy.vWrite = AccNormal;
									f.cfKind = Var(copy);
								case _:
							}
							access(e, f, FHAnon);
						} catch (err:Dynamic) {
							if (!Std.isOfType(err, NotFound) || !isOpen || !cfg.allowOpenMono) throw err;
							var f = makeField();
							Monomorph.addDownConstraint(r, MField(f));
							access(e, f, FHAnon);
						}
					case CTypes(tl): byList(pair -> byET(byType, e, pair.type), tl);
					case CUnknown if (!cfg.allowOpenMono): throw NotFound.raise();
					case CUnknown:
						if (!context.Typecore.MonomorphList.exists(ctx.e.monomorphs, r)
							&& !(ctx.f.isUntyped && ctx.com.platform == Neko)) ctx.e.monomorphs = context.Typecore.MonomorphList.cons(r, p,
								ctx.e.monomorphs);
						var f = makeField();
						Monomorph.addDownConstraint(r, MField(f));
						Monomorph.addModifier(r, MOpenStructure);
						access(e, f, FHAnon);
					case CMixed(l): byList(checkConstraint, l);
				};
				checkConstraint(Monomorph.classifyDownConstraints(r));
			case TAbstract(a, tl):
				try {
					var c = some(a.aImpl), f = some(c.clStatics.get(i));
					if (!hasClassFieldFlag(f, CfImpl)) throw NotFound.raise();
					noNoLookup(f);
					access(e, f, FHAbstract(a, tl, c));
				} catch (err:Dynamic) {
					if (!Std.isOfType(err, NotFound)) throw err;
					forwardMember(byType, e, a, tl);
				}
			case _: throw NotFound.raise();
		};
		inline function byExtension(f:(Array<{cls:TClass, pos:Pos}>->AccessKind)->AccessKind, t:T, e:TExpr):AccessKind {
			var constantStruct = false;
			switch t {
				case TInst(_) if (e.eexpr.match(TConst(TSuper))):
					e = mk(TCast(mk(TConst(TThis), mkMono(), e.epos), null), e.etype, e.epos);
				case _:
			}
			function lookup(list:Array<{cls:TClass, pos:Pos}>):AccessKind return byList(function(pair) {
				var c = pair.cls, pc = pair.pos, cf0 = some(c.clStatics.get(i));
				function check(fields:Array<TClassField>):AccessKind {
					if (fields.length == 0) throw NotFound.raise();
					var cf = fields[0], rest = fields.slice(1);
					if (Meta.has(MetaTag.NoUsing, cf.cfMeta)
						|| !canAccess(ctx, c, cf, true)
						|| hasClassFieldFlag(cf, CfImpl)) return check(rest);
					// We always want to reset monomorphs here because they will be handled again when making the actual call.
					var current = ctx.e.monomorphs;
					function next():AccessKind {
						ctx.e.monomorphs = current;
						return check(rest);
					}
					try {
						var monos = Monomorph.spawnConstrainedMonos(t -> t, cf.cfParams),
							cft = follow(applyParams(cf.cfParams, monos, cf.cfType));
						var args:haxe.ds.Vector<{name:String, optional:Bool, type:T}> = switch followWithCoro(cft) {
							case NotCoro(TFun({args: args, ret: _})) | Coro({args: args}): args;
							case _: vector();
						};
						if (args.length == 0) return next();
						var t0 = switch args[0].type {
							case TType({tPath: {pack: ["haxe", "macro"], name: "ExprOf"}}, [t]): t;
							case t: t;
						};
						if (t == tDynamic && follow(t0) != t) return next();
						var casted = TyperBase.unifyStaticExtension(ctx, e, t0, p);
						ImportHandling.markImportPosition(ctx, pc);
						ctx.e.monomorphs = current;
						return AKUsingField(makeStaticExtensionAccess(c, cf, casted, false, p));
					} catch (err:Unify_error) {
						constantStruct = constantStruct || core.ds.ArrayTools.exists(err.errors, function(err) return switch err {
							case HasExtraField(_): true;
							case _: false;
						});
						return next();
					} catch (err:TypingError) {
						switch err.error.errMessage {
							case Unify(el):
								constantStruct = constantStruct || core.ds.ArrayTools.exists(el, function(err) return switch err {
									case HasExtraField(_): true;
									case _: false;
								});
								return next();
							case _:
								throw err;
						}
					}
				}
				return check([cf0].concat(cf0.cfOverloads));
			}, list);
			try return f(lookup)
			catch (err:Dynamic) {
				if (!Std.isOfType(err, NotFound) || !constantStruct) throw err;
				return removeConstantFlag(t, function(changed) {
					if (changed) return f(lookup);
					throw NotFound.raise();
				});
			}
		}
		function byTypeExtension(e:TExpr, t:T):AccessKind {
			if (isSet) throw NotFound.raise();
			inline function extension():AccessKind return byExtension(function(lookup) {
				var mt:ModuleType;
				try mt = moduleTypeOfType(t)
				catch (err:Dynamic) {
					if (!Std.isOfType(err, Exit)) throw err;
					throw NotFound.raise();
				}
				return lookup(tInfos(mt).mtUsing);
			}, t, e);
			return switch t {
				case TType(td, tl): try extension() catch (err:Dynamic) {
						if (!Std.isOfType(err, NotFound)) throw err;
						byTypedef(byTypeExtension, e, td, tl);
					}
				case TMono(_): throw NotFound.raise();
				case TAbstract(a, tl): try extension() catch (err:Dynamic) {
						if (!Std.isOfType(err, NotFound)) throw err;
						forwardMember(byTypeExtension, e, a, tl);
					}
				case _: extension();
			};
		}
		function byModuleExtension(e:TExpr, t:T):AccessKind {
			if (isSet) throw NotFound.raise();
			inline function extension():AccessKind return byExtension(function(lookup) {
				try return lookup(ctx.m.moduleUsing)
				catch (err:Dynamic) {
					if (!Std.isOfType(err, NotFound)) throw err;
					var acc = lookup(ctx.g.globalUsing);
					return switch acc {
						case AKUsingField({seAccess: {faHost: FHStatic(c)}}):
							addDependency(ctx.m.curmod, c.clModule, MDepFromTyping);
							acc;
						case _: throw "Invalid global using access";
					};
				}
			}, t, e);
			return switch t {
				case TType(td, tl): byTypedef(byModuleExtension, e, td, tl);
				case TMono(r): switch Monomorph.classifyDownConstraints(r) {
						case CStructural(_, false): extension();
						case _: throw NotFound.raise();
					}
				case TAbstract(a, tl): try extension() catch (err:Dynamic) {
						if (!Std.isOfType(err, NotFound)) throw err;
						forwardMember(byModuleExtension, e, a, tl);
					}
				case _: extension();
			};
		}
		function byFallback(e:TExpr, t:T):AccessKind return switch t {
			case TType(td, tl): byTypedef(byFallback, e, td, tl);
			case TInst(c, tl):
				function loop(c:TClass, tl:TParams):AccessKind {
					if (c.clDynamic != null) return AKExpr(mk(TField(e, FDynamic(i)), applyParams(c.clParams, tl, c.clDynamic), p));
					if (c.clSuper != null) return loop(c.clSuper.cls, c.clSuper.params);
					throw NotFound.raise();
				}
				try loop(c, tl) catch (err:Dynamic) {
					if (!Std.isOfType(err, NotFound) || !c.clStatics.exists(i)) throw err;
					raiseTypingError("Cannot access static field " + i + " from a class instance", pfield);
				}
			case TDynamic(t) if (cfg.allowDynamic): AKExpr(mk(TField(e, FDynamic(i)), t == null ? tDynamic : t, p));
			case TAbstract(a, tl):
				try {
					if (!cfg.allowResolve) throw NotFound.raise();
					var c = some(a.aImpl),
						f = some(isSet ? a.aWrite : a.aRead);
					AKResolve(makeAbstractStaticExtensionAccess(a, tl, c, f, e, false, p), i);
				} catch (err:Dynamic) {
					if (!Std.isOfType(err, NotFound)) throw err;
					try forwardMember(byFallback, e, a, tl)
					catch (err:Dynamic) {
						if (!Std.isOfType(err, NotFound)) throw err;
						var f = some(some(a.aImpl).clStatics.get(i));
						if (!hasClassFieldFlag(f,
							CfImpl)) raiseTypingError("Invalid call to static function " + i + " through abstract instance", pfield);
						else throw err;
					}
				}
			case _: throw NotFound.raise();
		};
		function byModule(e:TExpr, t:T):AccessKind return switch e.eexpr {
			case TTypeExpr(mt):
				var infos = tInfos(mt);
				if (infos.mtPath.name != infos.mtModule.mPath.name) throw NotFound.raise();
				// TODO: This duplicates some code from typerDotPath.ml
				var c = infos.mtModule.mStatics;
				if (c != null && c.clStatics.exists(i)) {
					var cf = c.clStatics.get(i);
					// We cannot use e here because in the case of module statics the type could be different (issue #11385).
					access(TyperBase.typeModuleType(ctx, TClassDecl(c), e.epos), cf, FHStatic(c));
				} else TyperBase.mkModuleTypeAccess(ctx, Typeload.findTypeInModule(infos.mtModule, i), p);
			case _: throw NotFound.raise();
		};
		var t = followWithoutType(e.etype);
		for (strategy in [byType, byTypeExtension, byModuleExtension, byFallback, byModule]) try return strategy(e, t)
		catch (err:Dynamic) {
			if (!Std.isOfType(err, NotFound)) throw err;
		}
		if (cfg.doResume) throw NotFound.raise();
		if (!ctx.f.isUntyped) {
			inline function special(a:TAbstract):Bool return core.ds.ArrayTools.exists(a.aOps, pair -> pair.field.cfName == i)
				|| core.ds.ArrayTools.exists(a.aUnops, pair -> pair.field.cfName == i)
				|| core.ds.ArrayTools.exists(a.aArray, cf -> cf.cfName == i);
			switch follow(t) {
				case TAnon({aStatus: ClassStatics({clKind: KAbstractImpl(a)})}) | TInst({clKind: KAbstractImpl(a)}, _) | TAbstract(a, _)
					if (special(a)):
					// the abstract field is not part of the field list, which is only true when it has no expression (issue #2344)
					displayError(ctx.com, "Field " + i + " cannot be called directly because it has no expression", pfield);
				case TAnon({aStatus: ClassStatics(c)}) if (c.clFields.exists(i)):
					displayError(ctx.com, "Static access to instance field " + i + " is not allowed", pfield);
				case _:
					var tthis = e.etype;
					try {
						if (!context.display.Diagnostics.errorInDiagnosticsRun(ctx.com, pfield)) throw core.ds.Exit.raise();
						context.display.DisplayFields.handleMissingFieldRaise(ctx, tthis, i, mode, withType, pfield);
					} catch (_:core.ds.Exit) {
						displayError(ctx.com,
							StringError.stringError(i, stringSource(tthis), sType(printContext(), tthis) + " has no field " + i), pfield);
					}
			}
		}
		return AKExpr(mk(TField(e, FDynamic(i)), spawnMonomorph(ctx, p), p));
	}

	public static function typeFieldDefaultCfg(ctx:Typer, e:TExpr, i:String, p:Pos, mode:AccessMode,
			withType:WithTypeValue):AccessKind return typeField(TypeFieldConfig.defaultConfig, ctx, e, i, p, mode, withType);

	/**
		Generates a list of fields for `@:structInit` class `c` with type params `tl`
		as it's needed for anonymous object syntax.
	*/
	public static function getStructInitAnonFields(c:TClass, tl:TParams):haxe.ds.StringMap<TClassField> {
		var args:Null<Array<{
			name:String,
			optional:Bool,
			type:T,
			pos:Pos,
			doc:Null<String>
		}>> = null, cf = c.clConstructor;
		if (cf != null) {
			var doc = genDocTextOpt(cf.cfDoc),
				javadoc:Null<Javadoc> = doc == null ? null : new Javadoc(doc);
			inline function paramInfo(name:String):Null<String> return javadoc == null ? null : javadoc.getParamInfo(name);
			switch follow(cf.cfType) {
				case TFun({args: list, ret: _}):
					args = list.mapToArray(function(arg) {
						var name = arg.name,
							t = applyParams(c.clParams, tl, arg.type),
							p = cf.cfNamePos,
							doc = paramInfo(name);
						switch cf.cfExpr {
							case {eexpr: TFunction(fn)}:
								for (pair in fn.tfArgs) if (pair.variable.vName == name) {
									p = pair.variable.vPos;
									break;
								}
							case _:
								if (c.clFields.exists(name)) {
									var field = c.clFields.get(name);
									p = field.cfNamePos;
									doc = genDocTextOpt(field.cfDoc);
								}
						}
						return {
							name: name,
							optional: arg.optional,
							type: t,
							pos: p,
							doc: doc
						};
					});
				case _:
			}
		}
		var fields = new haxe.ds.StringMap<TClassField>();
		if (args != null) for (arg in args) {
			var cf = mkField(arg.name, arg.type, arg.pos, arg.pos);
			if (arg.optional) cf.cfMeta = [{meta: MetaTag.Optional, exprs: vector(), pos: Globals.nullPos}];
			cf.cfDoc = docFromStringOpt(arg.doc);
			fields.set(cf.cfName, cf);
		}
		else for (cf in c.clFields) switch cf.cfKind {
			case Var(_):
				var copy:TClassField = core.ds.Record.copy(cf);
				copy.cfType = applyParams(c.clParams, tl, cf.cfType);
				fields.set(copy.cfName, copy);
			case _:
		}
		return fields;
	}
}
