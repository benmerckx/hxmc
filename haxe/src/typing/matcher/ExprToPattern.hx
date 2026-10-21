package typing.matcher;

import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.TType;
import core.Ast;
import core.Ast.*;
import core.Error;
import core.Texpr;
import core.TUnification;
import core.ds.NotFound;
import core.ds.Exit;
import context.Common;
import core.Ast.Expr;
import core.Globals.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.WithType;
import core.Message;
import core.StringError;
import context.display.DeprecationCheck;
import core.DisplayTypes;
import core.TUnification.shallowEq;
import context.Typecore.*;
import context.Typecore;
import typing.matcher.Pattern;
import typing.matcher.Constructor;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

typedef PatternContext = {
	var ctx:Typer;
	var orLocals:Null<haxe.ds.StringMap<{v:TVar, p:Pos}>>;
	var ctxLocals:core.ds.PersistentMap<String, TVar>;
	var currentLocals:haxe.ds.StringMap<{v:TVar, p:Pos}>;
	var inReification:Bool;
	var isPostfixMatch:Bool;
	// Reverses the per-case type substitution; used for extractor expressions
	// so that they see the original type parameters rather than fresh monos.
	var unsubst:T->T;
}

class BadPattern extends haxe.Exception {
	public function new(s:String) super(s);
}

class ExprToPattern {
	static function fieldAssoc(name:String, fields:haxe.ds.Vector<ObjectField>):Expr {
		for (field in fields) if (field.key.name == name) return field.expr;
		throw NotFound.raise();
	}

	static function displayDeferred(ctx:Typer, e:Expr, kind:DisplayKind, mode:AccessMode,
			withType:WithTypeValue):Void typing.TyperDisplay.handleEdisplay(ctx, e, kind, mode, withType);

	static function displayExprDeferred(ctx:Typer, e:Expr, typed:TExpr, kind:DisplayKind, mode:AccessMode, withType:WithTypeValue,
			p:Pos):Void typing.TyperDisplay.displayExpr(ctx, e, typed, kind, mode, withType, p);

	public static var fakeTupleType:T = TInst(mkClass(nullModule, {pack: [], name: "-Tuple"}, nullPos, nullPos), vector());

	public static function tupleType(tl:core.TType.TParams):T return tfun(tl, fakeTupleType);

	public static function typeFieldAccess(ctx:Typer, e:TExpr, name:String,
			resume:Bool = false):TExpr return Calls.accGet(ctx,
			Fields.typeField(Fields.TypeFieldConfig.create(resume), ctx, e, name, e.epos, MGet, WithTypeTools.value));

	public static function getGeneralModuleType(ctx:Typer, mt:ModuleType, p:Pos):T {
		function loop(mt:ModuleType):String return switch mt {
			case TClassDecl(_): "Class";
			case TEnumDecl(_): "Enum";
			case TAbstractDecl(a) if (core.Meta.has(MetaTag.RuntimeValue, a.aMeta)): "Class";
			case TTypeDecl(t): switch follow(monomorphs(t.tParams, t.tType)) {
					case TInst(c, _): loop(TClassDecl(c));
					case TEnum(en, _): loop(TEnumDecl(en));
					case TAbstract(a, _): loop(TAbstractDecl(a));
					case _: core.Error.raiseTypingError("Cannot use this type as a value", p);
				}
			case _: core.Error.raiseTypingError("Cannot use this type as a value", p);
		};
		return Typeload.loadInstance(ctx, makePtp({
			tname: loop(mt),
			tpackage: [],
			tsub: null,
			tparams: vector()
		}, p), ParamSpawnMonos, LoadNormal);
	}

	public static function unifyTypePattern(ctx:Typer, mt:ModuleType, t:T, p:Pos):Void switch getGeneralModuleType(ctx, mt, p) {
		case TAbstract(a, _):
			unify(ctx, TAbstract(a, vector(spawnMonomorph(ctx, p))), t, p);
		case _:
			throw "assert";
	};

	// Array patterns apply to arrays, Dynamic and abstracts with a single `from` type leading to one of those. Other values
	// can be matched by array patterns if they can be accessed by index like in `for` loops, and their length and elements
	// are then read the same way (#8012). This returns how to access them, or None for values of the former types and for
	// values which can't be accessed by index.
	//
	// TODO: this is looked up for each array pattern here, then again for the same subject when compile.ml reads its
	// elements and twice in texprConverter.ml. The decision tree stores a switch subject as a plain texpr, so what the
	// subject is and how it is accessed is lost after pattern typing (which can't keep it: patterns are typed against
	// per-case types). A subject that carries this would avoid the repeated lookups; see the discussion in #13070.
	public static function getArrayAccess(ctx:Typer, t:T, p:Pos):Null<typing.TyperBase.ArrayAccessData> {
		function isArray(seen:Array<T>, t:T):Bool return switch follow(t) {
			case TInst({clPath: {pack: [], name: "Array"}}, [_]) | TDynamic(_):
				true;
			case ty = TAbstract(a, tl) if (!core.ds.ArrayTools.exists(seen, function(t) return shallowEq(ty, t))):
				var froms = TyperBase.getAbstractFroms(ctx, a, tl);
				if (froms.length == 1) isArray([ty].concat(seen), froms[0].type); else false;
			case _:
				false;
		};
		if (isArray([], t)) return null;
		return try TyperBase.getArrayAccess(ctx, t, p) catch (ex:NotFound) null;
	}

	public static function make(pctx:PatternContext, toplevel:Bool, t:T, e:Expr):PatternData {
		var ctx = pctx.ctx;
		var p = e.pos;
		inline function fail():Dynamic return core.Error.raiseTypingError("Unrecognized pattern: " + core.AstPrinter.sExpr(e), p);
		function expected(tp:T):Void unify(ctx, tp, t, p);
		inline function variableError(name:String,
				p:Pos):Dynamic return core.Error.raiseTypingError('Variable $name must appear exactly once in each sub-pattern', p);
		inline function addLocal(finalFlag:Bool, name:String, p:Pos):TVar {
			var wildcard = name == "_";
			if (!wildcard && pctx.isPostfixMatch) core.Error.raiseTypingError("Pattern variables are not allowed in .match patterns", p);
			if (!wildcard && pctx.currentLocals.exists(name)) core.Error.raiseTypingError('Variable $name is bound multiple times', p);
			if (pctx.orLocals != null && !wildcard) {
				var entry = pctx.orLocals.get(name);
				if (entry == null) return variableError(name, p);
				var v:TVar = entry.v;
				unify(ctx, t, v.vType, entry.p);
				if (finalFlag) addVarFlag(v, VFinal);
				pctx.currentLocals.set(name, {v: v, p: entry.p});
				return v;
			}
			var v = allocVar(VUser(TVOPatternVariable), name, t, p);
			if (finalFlag) addVarFlag(v, VFinal);
			pctx.currentLocals.set(name, {v: v, p: p});
			ctx.f.locals = ctx.f.locals.add(name, v);
			return v;
		}
		inline function conEnum(en:TEnum, ef:TEnumField, p:Pos):ConstructorData {
			var d = createDeprecationContext(ctx);
			DeprecationCheck.checkEnum(d, en, p);
			DeprecationCheck.checkEf(d, ef, p);
			return {kind: ConEnum(en, ef), pos: p};
		}
		inline function enumerable():Array<String> return switch follow(t) {
			case TEnum(en, _): en.eNames;
			case TAbstract(a = {aImpl: c}, _) if (c != null && a.aEnum): [
					for (cf in c.clOrderedStatics) if (hasClassFieldFlag(cf, CfImpl) && hasClassFieldFlag(cf, CfEnum)) cf.cfName
				];
			case _: [];
		};
		function checkExpr(e:TExpr):PatternKind return switch e.eexpr {
			case TField(_, FEnum(en, ef)):
				// Let the unification afterwards fail so we don't recover.
				// (match follow ef.ef_type with TFun _ -> raise Exit | _ -> ());
				PatConstructor(conEnum(en, ef, e.epos), []);
			case TField(_, FStatic(c, cf = {cfKind: Var({vWrite: AccNever})})): PatConstructor({kind: ConStatic(c, cf), pos: e.epos}, []);
			case TConst(ct): PatConstructor({kind: ConConst(ct), pos: e.epos}, []);
			case TCast(e1, null): checkExpr(e1);
			case TField(_, f):
				var similar = StringError.getSimilar(fieldName(f), enumerable());
				if (similar.length > 0) {
					var path = switch follow(t) {
						case TEnum(en, _): sTypePath(en.ePath) + ".";
						case TAbstract(a, _): sTypePath(a.aPath) + ".";
						case _: "";
					};
					warning(ctx, WTyper,
						"Potential typo detected (expected similar values are " + similar.map(function(s) return path + s).join(", ") + ")",
						p);
				}
				throw new BadPattern("Only inline or read-only (default, never) fields can be used as a pattern");
			case TTypeExpr(mt): PatConstructor({kind: ConTypeExpr(mt), pos: e.epos}, []);
			case TMeta(meta = {meta: MetaTag.Deprecated}, e1):
				DeprecationCheck.checkMeta(createDeprecationContext(ctx), [meta], "field", e1.epos);
				checkExpr(e1);
			case _: throw Exit.raise();
		};
		inline function displayMode():DisplayKind return pctx.isPostfixMatch ? DKMarked : DKPattern(toplevel);
		inline function catchErrors(p:Pos):Void->Void {
			var old = ctx.com.errorExt;
			var restore = Common.disableReportMode(ctx.com);
			ctx.com.errorExt = function(err) {
				var ep = err.errPos;
				// The error might not actually come from here, let's check the position (issue #12098).
				if (ep.pfile != p.pfile || ep.pmax < p.pmin || ep.pmin > p.pmax) old(err);
				else throw Exit.raise();
			};
			return function() {
				restore();
				ctx.com.errorExt = old;
			};
		}
		inline function tryTyping(e:Expr):PatternKind {
			var old = ctx.f.isUntyped;
			ctx.f.isUntyped = true;
			var restore = catchErrors(e.pos);
			var typed:TExpr;
			try {
				typed = typeExpr(ctx, e, WithTypeTools.withType(t));
			} catch (ex:haxe.Exception) {
				restore();
				ctx.f.isUntyped = old;
				throw ex;
			}
			restore();
			ctx.f.isUntyped = old;
			var pat = checkExpr(typed);
			switch pat {
				case PatConstructor({kind: ConTypeExpr(mt)}, _):
					unifyTypePattern(ctx, mt, t, typed.epos);
				case _:
					unify(ctx, typed.etype, t, p);
			}
			return pat;
		}
		function handleIdent(s:String, p:Pos):PatternKind {
			try {
				return tryTyping({expr: EConst(Ident(s)), pos: p});
			} catch (ex:Dynamic) {
				if (!Std.isOfType(ex, Exit) && !Std.isOfType(ex, BadPattern)) throw ex;
			}
			var restore = catchErrors(p);
			try {
				var mt = moduleTypeOfType(t);
				var emt = TyperBase.typeModuleType(ctx, mt, p);
				var typed = typeFieldAccess(ctx, emt, s, true);
				restore();
				return checkExpr(typed);
			} catch (ex:Dynamic) {
				restore();
			}
			if (!isLowerIdent(s) && s.charAt(0) != "`" && s.charAt(0) != "_") Common.displayError(ctx.com,
				"Unknown identifier : " + s + ", pattern variables must be lower-case or with `var ` prefix", p);
			var similar = StringError.getSimilar(s, enumerable());
			// if toplevel then
			//	warning pctx.ctx (Printf.sprintf "`case %s` has been deprecated, use `case var %s` instead" s s) p
			if (similar.length > 0) warning(ctx, WTyper,
				"Potential typo detected (expected similar values are "
				+ similar.join(", ")
				+ "). Consider using `var "
				+ s
				+ "` instead",
				p);
			return PatBind(addLocal(false, s, p), {kind: PatAny, pos: nullPos});
		}
		function loop(e:Expr):PatternKind return switch e.expr {
			case EParenthesis(e1) | ECast(e1, null): loop(e1);
			case ECheckType(e1, {type: CTPath({path: {tpackage: ["haxe", "macro"], tname: "Expr"}})}):
				var old = pctx.inReification;
				pctx.inReification = true;
				var pat = loop(e1);
				pctx.inReification = old;
				pat;
			case EConst(ct = (Ident("false" | "true") | Int(_, _) | String(_, _) | Float(_, _))):
				switch ct {
					case String(value, SSingleQuotes):
						var formatted = ctx.g.doFormatString(ctx, value, p);
						switch formatted.expr {
							case EBinop(_, _,
								_): core.Error.raiseTypingError("String interpolation is not allowed in case patterns", formatted.pos);
							case _:
						}
					case _:
				}
				var typed = Texpr.typeConstant(ctx.com.basic, ct, e.pos);
				expected(typed.etype);
				var constant = switch typed.eexpr {
					case TConst(ct): ct;
					case _: throw "assert";
				};
				PatConstructor({kind: ConConst(constant), pos: e.pos}, []);
			case EConst(Ident(i)): switch follow(t) {
					case TFun(s) if (s.ret == fakeTupleType): if (i == "_") PatTuple(s.args.mapToArray(function(_) return ({
							kind: PatAny,
							pos: e.pos
						} : typing.matcher.Pattern.PatternData))); else
							core.Error.raiseTypingError("Cannot bind matched tuple to variable, use _ instead", p);
					case _: i == "_" ? PatAny : handleIdent(i, e.pos);
				}
			case EVars([
				{
					evName: {name: s, pos: p},
					evFinal: finalFlag,
					evType: null,
					evExpr: null
				}
			]): PatBind(addLocal(finalFlag, s, p), {kind: PatAny, pos: nullPos});
			case ECall(e1, el):
				var e1 = typeExpr(ctx, e1, WithTypeTools.withType(t));
				switch [e1.eexpr, follow(e1.etype)] {
					case [TField(_, FEnum(en, ef)), TFun(sig)]:
						var tl = switch follow(sig.ret) {
							case TEnum(_, tl): tl;
							case _: fail();
						};
						function mapEn(t:T):T return applyParams(en.eParams, tl, t);
						var monos = Monomorph.spawnConstrainedMonos(mapEn, ef.efParams);
						inline function mapper(t:T):T return mapEn(applyParams(ef.efParams, monos, t));
						unify(ctx, mapper(ef.efType), e1.etype, e1.epos);
						var args = switch follow(e1.etype) {
							case TFun(s):
								expected(s.ret);
								s.args;
							case _: throw "assert";
						};
						// port: in `make pctx false t e :: loop el tl` OCaml evaluates the tail first, so arguments are typed last to first.
						function loopArgs(ei:Int, ai:Int):Array<typing.matcher.Pattern.PatternData> {
							if (ei == el.length - 1 && ai < args.length && (switch el[ei].expr {
								case EConst(Ident("_")): true;
								case _: false;
							})) {
								// Allow using final _ to match "multiple" arguments
								var rest = ai + 1 == args.length ? [] : loopArgs(ei, ai + 1);
								rest.unshift({kind: PatAny, pos: el[ei].pos});
								return rest;
							}
							if (ei < el.length && ai < args.length) {
								var rest = loopArgs(ei + 1, ai + 1);
								rest.unshift(make(pctx, false, args[ai].type, el[ei]));
								return rest;
							}
							if (ei >= el.length && ai < args.length && args[ai].optional) {
								var pat:typing.matcher.Pattern.PatternData = {kind: PatAny, pos: e.pos};
								var rest = loopArgs(ei, ai + 1);
								rest.unshift(pat);
								return rest;
							}
							if (ei >= el.length && ai >= args.length) return [];
							if (ei >= el.length) return core.Error.raiseTypingError("Not enough arguments", p);
							return core.Error.raiseTypingError("Too many arguments", p);
						}
						var ps = loopArgs(0, 0);
						// Rebind any unrefined constructor type-param monos back to their
						// parameter types. This ensures the case body sees a constrained
						// type variable rather than a free monomorphism, preserving GADT
						// constructor type constraints (see #1310).
						for (i in 0...ef.efParams.length) switch monos[i] {
							case TMono(m) if (m.tmType == null): Monomorph.doBind(m, ef.efParams[i].ttpType);
							case _:
						}
						PatConstructor(conEnum(en, ef, e1.epos), ps);
					case _: fail();
				}
			case EField(_, _, _): try tryTyping(e) catch (ex:Exit) fail() catch (ex:BadPattern) core.Error.raiseTypingError(ex.message, p);
			case EArrayDecl(el):
				function arrayPattern(t2:T):PatternKind {
					var ps = el.mapToArray(function(e) return make(pctx, false, t2, e));
					return PatConstructor({kind: ConArray(ps.length), pos: e.pos}, ps);
				}
				function arrayAccessPattern():PatternKind {
					var aa = getArrayAccess(ctx, t, p);
					return aa != null ? arrayPattern(aa.aaType) : fail();
				}
				function pattern(seen:Array<T>, t:T):PatternKind return switch follow(t) {
					case TFun(s) if (s.ret == fakeTupleType):
						if (el.length < s.args.length) core.Error.raiseTypingError("Not enough arguments", p);
						if (el.length > s.args.length) core.Error.raiseTypingError("Too many arguments", el[s.args.length].pos);
						PatTuple([for (i in 0...el.length) make(pctx, false, s.args[i].type, el[i])]);
					case TInst({clPath: {pack: [], name: "Array"}}, [t2]):
						arrayPattern(t2);
					case t2 = TDynamic(_):
						arrayPattern(t2);
					case ty = TAbstract(a, tl) if (!core.ds.ArrayTools.exists(seen, function(t) return shallowEq(ty, t))):
						var froms = TyperBase.getAbstractFroms(ctx, a, tl);
						if (froms.length == 1) pattern([ty].concat(seen), froms[0].type); else arrayAccessPattern();
					case _: arrayAccessPattern();
				};
				pattern([], t);
			case EObjectDecl(fl):
				var known:Array<{cf:TClassField, t:T}> = [];
				inline function collectField(cf:TClassField, t:T, filter:Null<Array<String>>):Void {
					if (filter != null && filter.indexOf(cf.cfName) < 0) return;
					known = known.filter(function(k) return k.cf.cfName != cf.cfName);
					known.unshift({cf: cf, t: t});
				}
				function collectFields(t:T, filter:Null<Array<String>>):Void switch follow(t) {
					case TAnon(an):
						var names = [for (n in an.aFields.keys()) n];
						names.sort(core.ds.Key.compareStrings);
						for (n in names) {
							var cf = an.aFields.get(n);
							collectField(cf, cf.cfType, filter);
						}
					case TInst(c, tl):
						function loopClass(c:TClass, tl:core.TType.TParams):Void {
							if (c.clSuper != null) loopClass(c.clSuper.cls,
								c.clSuper.params.map(function(t) return applyParams(c.clParams, tl, t)));
							for (cf in c.clOrderedFields) if (canAccess(ctx, c, cf,
								false)) collectField(cf, applyParams(c.clParams, tl, cf.cfType), filter);
						}
						loopClass(c, tl);
					case TAbstract(a = {aImpl: c}, tl) if (c != null):
						if (core.Meta.has(MetaTag.Forward, a.aMeta)) {
							var entry = core.Meta.get(MetaTag.Forward, a.aMeta);
							var sl = [];
							for (e in entry.exprs) switch e.expr {
								case EConst(Ident(s)): sl.push(s);
								case _:
							}
							var filtered = sl.length == 0 ? filter : filter == null ? sl : sl.filter(function(s) return
								filter.indexOf(s) >= 0);
							collectFields(core.Abstract.getUnderlyingType(a, tl), filtered);
						}
						for (cf in c.clOrderedStatics) if (hasClassFieldFlag(cf,
							CfImpl)) collectField(cf, applyParams(a.aParams, tl, cf.cfType), filter);
					case _:
						core.Error.raiseTypingError("Cannot field-match against "
							+ core.TPrinting.sType(core.TPrinting.printContext(), t), e.pos);
				};
				collectFields(t, null);
				var ps = [], fields = [];
				for (item in known) {
					var cf = item.cf;
					var e1:Null<Expr> = null;
					// TODO: This needs a better check, but it's not obvious how to approach this. See #11433
					if (!(pctx.inReification && (cf.cfName == "pos" || cf.cfName == "posPath" || cf.cfName == "namePos"))) try {
						e1 = fieldAssoc(cf.cfName, fl);
					} catch (ex:NotFound) {}
					if (e1 != null) {
						ps.unshift(make(pctx, false, item.t, e1));
						fields.unshift(cf.cfName);
					} else switch cf.cfKind {
						case Method(_):
						case _:
							ps.unshift({kind: PatAny, pos: cf.cfPos});
							fields.unshift(cf.cfName);
					}
				}
				for (f in fl) if (fields.indexOf(f.key.name) < 0)
					core.Error.raiseTypingError(core.TPrinting.sType(core.TPrinting.printContext(), t) + " has no field " + f.key.name,
						f.expr.pos);
				PatConstructor({kind: ConFields(fields), pos: e.pos}, ps);
			case EBinop(OpOr, e1, e2):
				var left:PatternContext = core.ds.Record.withFields(pctx, {currentLocals: new haxe.ds.StringMap()});
				var pat1 = make(left, toplevel, t, e1);
				var right:PatternContext = core.ds.Record.withFields(pctx,
					{currentLocals: new haxe.ds.StringMap(), orLocals: left.currentLocals});
				var pat2 = make(right, toplevel, t, e2);
				var names = [for (n in (left.currentLocals.keys() : Iterator<String>)) n];
				names.sort(core.ds.Key.compareStrings);
				for (n in names) {
					var entry = left.currentLocals.get(n);
					if (!right.currentLocals.exists(n) && n != "_") variableError(n, entry.p);
					pctx.currentLocals.set(n, entry);
				}
				PatOr(pat1, pat2);
			case EBinop(OpAssign, e1, e2):
				function assignment(dk:Null<DisplayKind>, e:Expr):PatternKind return switch e.expr {
					case EConst(Ident(s)):
						var v = addLocal(false, s, e.pos);
						if (dk != null) displayExprDeferred(ctx, e, mk(TLocal(v), v.vType, e.pos), dk, MSet(null),
							WithTypeTools.withType(t), e.pos);
						PatBind(v, make(pctx, false, t, e2));
					case EParenthesis(e1): assignment(dk, e1);
					case EDisplay(e1, dk): assignment(dk, e1);
					case _: fail();
				};
				assignment(null, e1);
			case EBinop(OpArrow, e1, e2):
				var restore = saveLocals(ctx);
				ctx.f.locals = pctx.ctxLocals;
				var v = addLocal(false, "_", nullPos);
				// Extractor expressions are typed in the original (non-refined) context
				// so that type parameters remain visible with their declared identity (#5952).
				v.vType = pctx.unsubst(v.vType);
				var typed = typeExpr(ctx, e1, WithTypeTools.value);
				v.vName = "tmp";
				restore();
				PatExtractor({exVar: v, exExpr: typed, exPattern: make(pctx, toplevel, typed.etype, e2)});
			case EBinop(OpEq | OpNotEq | OpLt | OpLte | OpGt | OpGte | OpBoolAnd | OpBoolOr, _,
				_): loop({expr: EBinop(OpArrow, e, {expr: EConst(Ident("true")), pos: nullPos}), pos: e.pos});
			// Special case for completion on a pattern local: We don't want to add the local to the context
			// while displaying (#7319)
			case EDisplay(e1 = {expr: EConst(Ident(_))}, _) if (ctx.com.display.dmsKind == DMDefault):
				var locals = ctx.f.locals;
				var pat = loop(e1);
				var changed = ctx.f.locals;
				ctx.f.locals = locals;
				displayDeferred(ctx, e1, displayMode(), MGet, WithTypeTools.withType(t));
				ctx.f.locals = changed;
				pat;
			// For signature completion, we don't want to recurse into the inner pattern because there's probably
			// a EDisplay(_,DMMarked) in there. We can handle display immediately because inner patterns should not
			// matter (#7326)
			case EDisplay(e1, DKCall):
				displayDeferred(ctx, e, displayMode(), MGet, WithTypeTools.withType(t));
				loop(e1);
			case EDisplay(e1, _):
				var pat = loop(e1);
				displayDeferred(ctx, e1, displayMode(), MGet, WithTypeTools.withType(t));
				pat;
			case EMeta({meta: MetaTag.StoredTypedExpr}, e1): loop(TExprToExpr.convertExpr(TyperBase.typeStoredExpr(ctx, e1)));
			case _: fail();
		};
		return {kind: loop(e), pos: p};
	}
}
