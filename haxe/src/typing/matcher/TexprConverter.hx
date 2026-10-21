package typing.matcher;

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
import core.Globals.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.WithType;
import context.Typecore.*;
import context.Typecore;
import typing.matcher.DecisionTree;
import typing.matcher.Constructor;
import typing.matcher.Case;
import typing.matcher.Bind;
import typing.matcher.MatcherGlobals.*;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

enum MatchKind {
	SKValue;
	SKEnum;
	SKLength;
}

enum DtRecursion {
	Toplevel;
	AfterSwitch;
	Deep;
}

class TexprConverter {
	public static function constructorToTexpr(ctx:Typer, con:ConstructorData):TExpr {
		var p = con.pos;
		return switch con.kind {
			case ConEnum(_, ef): mk(TConst(TInt(ef.efIndex)), ctx.t.tint, p);
			case ConConst(ct): Texpr.Builder.makeConstTexpr(ctx.com.basic, ct, p);
			case ConArray(i): Texpr.Builder.makeInt(ctx.com.basic, i, p);
			case ConTypeExpr(mt): TyperBase.typeModuleType(ctx, mt, p);
			case ConStatic(c, cf): Texpr.Builder.makeStaticField(c, cf, p);
			case ConFields(_): Error.raiseTypingError("Unexpected matching on ConFields, please report this", p);
		};
	}

	static function sSubject(lookup:Map<Int, TExpr>, s:String, e:TExpr):String {
		function loop(top:Bool, s:String, e:TExpr):String return switch e.eexpr {
			case TField(_, FEnum(_, _)): s;
			case TField(e1, fa): loop(false, top ? s : '{ ${fieldName(fa)}: $s }', e1);
			case TEnumParameter(e1, ef, i):
				var arity = switch follow(ef.efType) {
					case TFun(sig): sig.args.length;
					case _: throw "assert";
				};
				loop(false, ef.efName + "(" + makeOffsetList(i, arity - i - 1, s, "_").join(", ") + ")", e1);
			case TLocal(v): lookup.exists(v.vId) ? loop(top, s, lookup.get(v.vId)) : s;
			case _: s;
		};
		return loop(true, s, e);
	}

	public static function sMatchKind(k:MatchKind):String return switch k {
		case SKValue: "value";
		case SKEnum: "enum";
		case SKLength: "length";
	};

	static function unifyConstructor(ctx:Typer, params:core.TType.TParams, t:T,
			con:ConstructorData):Null<{con:ConstructorData, params:core.TType.TParams}> return switch con.kind {
			case ConEnum(en, ef):
				var tef = switch follow(ef.efType) {
					case TFun(s): s.ret;
					case _: ef.efType;
				};
				tef = applyParams(ctx.typeParams, params, monomorphs(en.eParams, monomorphs(ef.efParams, tef)));
				var monos = params.map(function(t) return switch follow(t) {
					case TInst({clKind: KTypeParameter(_)}, _) | TMono(_): mkMono();
					case _: t;
				});
				function duplicate(t:T):T return switch follow(t) {
					case TMono(_): mkMono();
					case _: map(duplicate, t);
				};
				var te = applyParams(ctx.typeParams, monos, duplicate(t));
				try {
					core.TUnification.unify(tef, te);
					{con: con, params: monos};
				} catch (e:Unify_error) {
					null;
				}
			case _: {con: con, params: params};
		};

	static function extractCtor(e:TExpr):Null<ConstructorKind> return switch e.eexpr {
		case TConst(ct): ConConst(ct);
		case TField(_, FEnum(en, ef)): ConEnum(en, ef);
		case TCast(e1, null): extractCtor(e1);
		case _: null;
	};

	static function allCtors(ctx:Typer, e:TExpr, cases:Array<DecisionSwitchCase>):{
		e:TExpr,
		unmatched:Array<ConstructorData>,
		kind:MatchKind,
		finiteness:TypeFiniteness
	} {
		var t = e.etype;
		switch follow(t) {
			case TDynamic(_) | TMono(_):
				if (cases.length > 0) t = switch cases[0].scCon.kind {
					case ConEnum(en, _): TEnum(en, extractParamTypes(en.eParams));
					case ConArray(_): ctx.t.tarray(tDynamic);
					case ConConst(ct): switch ct {
							case TString(_): ctx.t.tstring;
							case TInt(_): ctx.t.tint;
							case TFloat(_): ctx.t.tfloat;
							case TBool(_): ctx.t.tbool;
							case _: tDynamic;
						}
					case ConStatic({clKind: KAbstractImpl(a)}, _): TAbstract(a, extractParamTypes(a.aParams));
					case ConTypeExpr(mt): ExprToPattern.getGeneralModuleType(ctx, mt, e.epos);
					case ConFields(_) | ConStatic(_, _):
						// error "Could not determine switch kind, make sure the type is known" e.epos;
						tDynamic;
				};
			case _:
		}
		var all:Array<ConstructorData> = [];
		function add(kind:ConstructorKind):Void {
			var con = ({kind: kind, pos: nullPos} : typing.matcher.Constructor.ConstructorData);
			for (i in 0...all.length) if (Constructor.equal(all[i], con)) {
				all[i] = con;
				return;
			}
			all.push(con);
		}
		function loop(deep:Bool, t:T):{kind:MatchKind, finiteness:TypeFiniteness}
			return switch follow(t) {
				case TAbstract({aPath: {pack: [], name: "Bool"}}, _):
					if (!deep) {
						add(ConConst(TBool(true)));
						add(ConConst(TBool(false)));
					}
					{kind: SKValue, finiteness: RunTimeFinite};
				case TAbstract(a = {aImpl: c}, pl) if (c != null && a.aEnum):
					if (!deep) for (cf in c.clOrderedStatics) {
						follow(cf.cfType);
						if (hasClassFieldFlag(cf, CfImpl) && hasClassFieldFlag(cf, CfEnum)) {
							var ctor = cf.cfExpr == null ? null : extractCtor(cf.cfExpr);
							switch ctor {
								case ConConst(TNull):
								case null: add(ConStatic(c, cf));
								case ctor: add(ctor);
							}
						}
					}
					var real = loop(true, core.Abstract.getUnderlyingType(a, pl));
					{kind: real.kind, finiteness: CompileTimeFinite};
				case TAbstract(a, pl) if (!core.Meta.has(MetaTag.CoreType, a.aMeta)): loop(deep, core.Abstract.getUnderlyingType(a, pl));
				case TInst({clPath: {pack: [], name: "String"}},
					_) | TInst({clKind: KTypeParameter(_)}, _): {kind: SKValue, finiteness: Infinite};
				case TInst({clPath: {pack: [], name: "Array"}}, _): {kind: SKLength, finiteness: Infinite};
				// port: `all` is still empty here and the constructors are distinct, so they are pushed without add's linear search.
				case TEnum(en, _):
					if (!deep) {
						var names = [for (n in en.eConstrs.keys()) n];
						names.sort(core.ds.Key.compareStrings);
						for (n in names) all.push(({
							kind: ConEnum(en, en.eConstrs.get(n)),
							pos: nullPos
						} : typing.matcher.Constructor.ConstructorData));
					}
					{kind: SKEnum, finiteness: RunTimeFinite};
				case _: {kind: SKValue, finiteness: Infinite};
			};
		var classified = loop(false, t);
		// Array patterns on values which can be accessed by index (#8012).
		if (cases.length > 0 && cases[0].scCon.kind.match(ConArray(_)) && ExprToPattern.getArrayAccess(ctx, t, e.epos) != null) {
			all = [];
			classified = {kind: SKLength, finiteness: Infinite};
		}
		// port: unguarded enum constructors are removed in one pass at the end (by field identity) rather than one filter per case.
		var removedEnum:Null<haxe.ds.ObjectMap<core.TType.TEnumField, Bool>> = null;
		for (sc in cases) {
			var compatible = switch sc.scCon.kind {
				case ConEnum(_, _): classified.kind == SKEnum;
				case ConArray(_): classified.kind == SKLength;
				case _: classified.kind == SKValue;
			};
			if (!compatible) Error.raiseTypingError("Incompatible pattern", sc.scDt.dtPos);
			if (sc.scUnguarded) switch sc.scCon.kind {
				case ConEnum(_, ef):
					if (removedEnum == null) removedEnum = new haxe.ds.ObjectMap();
					removedEnum.set(ef, true);
				case _:
					all = all.filter(function(c) return !Constructor.equal(c, sc.scCon));
			}
		}
		if (removedEnum != null) {
			var removed = removedEnum;
			all = all.filter(function(c) return switch c.kind {
				case ConEnum(_, ef): !removed.exists(ef);
				case _: true;
			});
		}
		return {
			e: e,
			unmatched: all,
			kind: classified.kind,
			finiteness: classified.finiteness
		};
	}

	static function reportNotExhaustive(lookup:Map<Int, TExpr>, e:TExpr, unmatched:Array<{con:ConstructorData, params:core.TType.TParams}>):Dynamic {
		var sl:Array<String> = switch follow(e.etype) {
			case TAbstract(a = {aImpl: c}, _) if (c != null && a.aEnum): unmatched.map(function(u) {
					var con:ConstructorData = u.con;
					return switch con.kind {
						case ConConst(_) | ConEnum(_, _):
							var found = null;
							for (cf in c.clOrderedStatics) if (cf.cfExpr != null) {
								var ctor = extractCtor(cf.cfExpr);
								if (ctor != null && Constructor.equal({kind: ctor, pos: nullPos}, con)) {
									found = cf;
									break;
								}
							}
							if (found == null) throw NotFound.raise();
							found.cfName;
						case _: Constructor.toString(con);
					};
				});
			case _: unmatched.map(function(u) return Constructor.toString(u.con));
		};
		sl.sort(core.ds.Key.compareStrings);
		var s = unmatched.length == 0 ? "_" : sl.join(" | ");
		return Error.raiseTypingError("Unmatched patterns: " + sSubject(lookup, s, e), e.epos);
	}

	public static function toTexpr(ctx:Typer, tSwitch:T, withType:WithTypeValue, root:DecisionTreeData):TExpr {
		var lookup:Map<Int, TExpr> = [];
		var com = ctx.com;
		var p = root.dtPos;
		function loop(rec:DtRecursion, params:core.TType.TParams, dt:DecisionTreeData):Null<TExpr> {
			if (dt.dtTexpr != null) return dt.dtTexpr;
			var e:Null<TExpr> = switch dt.dtT {
				case Leaf(c): c.caseExpr == null ? mk(TBlock(vector()), ctx.t.tvoid, c.casePos) : c.caseExpr;
				case Switch(subject, [sc = {scCon: {kind: ConFields(_)}}], _): // TODO: Can we improve this by making it more general?
					var e = loop(rec, params, sc.scDt);
					e == null ? null : core.TFunctions.concat(subject, e);
				case Switch(subject, cases, def):
					var nextRec = rec == Toplevel ? AfterSwitch : Deep;
					var top = rec == Toplevel;
					var ctors = allCtors(ctx, subject, cases);
					subject = ctors.e;
					var unmatched = [];
					for (con in ctors.unmatched) {
						var u = unifyConstructor(ctx, params, subject.etype, con);
						if (u != null) unmatched.push(u);
					}
					inline function descend(params:core.TType.TParams, dt:DecisionTreeData):Null<TExpr> {
						var e = loop(nextRec, params, dt);
						if (e != null) return e;
						if (withType == NoValue && ctors.finiteness == Infinite && top) return null;
						if (ctors.finiteness == CompileTimeFinite && unmatched.length == 0) return null;
						if (Common.ignoreError(com)) return null;
						return reportNotExhaustive(lookup, subject, unmatched);
					}
					var groups:Array<{cons:Array<ConstructorData>, dt:DecisionTreeData, params:core.TType.TParams}> = [];
					for (sc in cases) {
						var u = unifyConstructor(ctx, params, subject.etype, sc.scCon);
						if (u == null) continue;
						var group = null;
						for (g in groups) if (DecisionTree.equal(g.dt.dtT, sc.scDt.dtT)) {
							group = g;
							break;
						}
						if (group == null) groups.push({cons: [sc.scCon], dt: sc.scDt, params: u.params});
						else {
							group.cons.unshift(sc.scCon);
							group.dt = sc.scDt;
							group.params = u.params;
						}
					}
					groups.sort(function(a,
							b) return a.cons.length > 0 && b.cons.length > 0 ? Constructor.compare(a.cons[0], b.cons[0]) : -1);
					var edef = unmatched.length == 0 && ctors.finiteness == RunTimeFinite ? null : descend(params, def);
					var ecases = [];
					for (g in groups) {
						var e = descend(g.params, g.dt);
						if (e != null) {
							g.cons.sort(Constructor.compare);
							ecases.push(({
								casePatterns: g.cons.mapToVector(function(c) return constructorToTexpr(ctx, c)),
								caseExpr: e
							} : core.TType.TSwitchCase));
						}
					}
					var nullable = isExplicitNullOrAbstractOverThat(subject.etype);
					subject = switch ctors.kind {
						case SKValue: subject;
						case SKEnum: mk(TEnumIndex(subject), com.basic.tint, subject.epos);
						case SKLength:
							var aa = ExprToPattern.getArrayAccess(ctx, subject.etype, subject.epos);
							aa != null ? aa.aaLength(subject, subject.epos) : ExprToPattern.typeFieldAccess(ctx, subject, "length");
					};
					if (ecases.length == 1 && edef == null && ctors.finiteness == RunTimeFinite && !nullable)
						core.ds.Record.withFields(ecases[0].caseExpr,
						{
							etype: tSwitch
						}); else if (ecases.length == 1 && ecases[0].casePatterns.length == 1 && (edef != null || withType == NoValue)) {
							var rhs = ecases[0].casePatterns[0];
							var body = ecases[0].caseExpr;
							var op = mk(TBinop(OpEq, subject, rhs), ctx.t.tbool, subject.epos);
							switch body.eexpr {
								case TIf(op2, e3, def2) if (edef != null && def2 != null && edef == def2):
									var and = Texpr.Builder.binop(OpBoolAnd, op, op2, ctx.t.tbool, punion(op.epos, op2.epos));
									mk(TIf(and, e3, edef), tSwitch, dt.dtPos);
								case _: mk(TIf(op, body, edef), tSwitch, dt.dtPos);
							}
						} else if (ecases.length == 2 && edef == null && (switch [ecases[0].casePatterns, ecases[1].casePatterns] {
							case [[{eexpr: TConst(TBool(true))}], [{eexpr: TConst(TBool(false))}]] |
								[[{eexpr: TConst(TBool(false))}], [{eexpr: TConst(TBool(true))}]]: true;
							case _: false;
					})) mk(TIf(subject, ecases[1].caseExpr, ecases[0].caseExpr), tSwitch,
							dt.dtPos); else mk(TSwitch(Texpr.mkSwitch(subject, Vector.fromArrayCopy(ecases),
						edef, edef != null || ctors.finiteness == RunTimeFinite || ctors.finiteness == CompileTimeFinite)),
						tSwitch, dt.dtPos);
				case Guard(cond, a, b):
					// Normal guards are considered toplevel if we're in the toplevel switch.
					var top = rec != Deep;
					var thenE = loop(rec, params, a);
					if (thenE == null) null; else {
						var elseE = loop(rec, params, b);
						if (elseE != null) mk(TIf(cond, thenE, elseE), tSwitch, punion(thenE.epos, elseE.epos));
						else if (withType == NoValue && top) mk(TIf(cond, thenE, null), ctx.t.tvoid, punion(cond.epos, thenE.epos));
						else null;
					}
				case GuardNull(subject, a, b):
					var top = rec == Toplevel;
					var enull = Texpr.Builder.makeNull(subject.etype, subject.epos);
					function op(e:TExpr):TExpr return mk(TBinop(OpEq, e, enull), ctx.t.tbool, e.epos);
					var conds = [];
					var inner = a;
					while (true) {
						var proceed = true;
						switch inner.dtT {
							case GuardNull(e, a, z) if (DecisionTree.equalDt(b, z)):
								conds.push(op(e));
								inner = a;
							case Guard(e, a, z) if (DecisionTree.equalDt(b, z)):
								conds.push(e);
								inner = a;
							case _: proceed = false;
						}
						if (!proceed) break;
					}
					var cond = op(subject);
					for (c in conds) cond = Texpr.Builder.binop(OpBoolAnd, cond, c, ctx.t.tbool, punion(cond.epos, c.epos));
					var thenE = loop(rec, params, inner);
					if (thenE == null) {
						if (top) {
							var elseE = loop(rec, params, b);
							elseE == null ? null :
								// In some cases like extractors, the original e expression might be significant for the
								// output, so let's make sure it appears there (issue #11738).
								mk(TBlock(vector(subject, elseE)), elseE.etype, elseE.epos);
						} else if (Common.ignoreError(com)) mk(TConst(TNull), mkMono(), b.dtPos);
						else reportNotExhaustive(lookup, subject, [{con: {kind: ConConst(TNull), pos: dt.dtPos}, params: vector()}]);
					} else {
						var elseE = loop(rec, params, b);
						if (elseE == null) {
							if (top && withType == NoValue) mk(TIf(cond, thenE, null), tSwitch, thenE.epos);
							else reportNotExhaustive(lookup, subject, []);
						} else mk(TIf(cond, thenE, elseE), tSwitch, punion(thenE.epos, elseE.epos));
					}
				case Bind(bl, inner):
					var el = [];
					for (b in bl) switch b.bStatus {
						case BindUsed:
							lookup.set(b.bVar.vId, b.bExpr);
							el.push(mk(TVar(b.bVar, b.bExpr), com.basic.tvoid, b.bPos));
						case BindDeferred: el.push(mk(TVar(b.bVar, null), com.basic.tvoid, b.bPos));
						case BindUnused:
					}
					var e = loop(rec, params, inner);
					e == null ? null : {
						el.push(e);
						mk(TBlock(Vector.fromArrayCopy(el)), e.etype, inner.dtPos);
					}
				case Fail: null;
			};
			dt.dtTexpr = e;
			return e;
		}
		var e = loop(Toplevel, extractParamTypes(ctx.typeParams), root);
		if (e == null) return Error.raiseTypingError("Unmatched patterns: _", p);
		return Texpr.duplicateTvars(function(e) return e, e);
	}
}
