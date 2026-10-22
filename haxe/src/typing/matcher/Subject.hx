package typing.matcher;

import core.MetaList.StrictMeta as MetaTag;
import core.TType;
import core.Globals.Pos;
import core.Globals.*;
import core.Texpr.Builder;
import core.TFunctions.*;
import core.TOther.*;
import context.Typecore;
import typing.ArrayAccess.ArrayAccessData;
import typing.matcher.Bind;
import typing.matcher.Constructor;
import typing.matcher.DecisionTree;
import typing.matcher.MatcherGlobals.*;

// A value the matcher still has to match: its expression, a constant or a local, and the binding of that local if the
// matcher introduced it. A switch on it keeps a DecisionTree.scrutinee, see [make_scrutinee].
class Subject {
	final e:TExpr;
	final bind:Null<Bind>;
	var arrayAccess:Null<ArrayAccessData> = null;

	public function new(e:TExpr, bind:Null<Bind>) {
		this.e = e;
		this.bind = bind;
	}

	public function getExpr():TExpr {
		if (bind != null) bind.bStatus = BindUsed;
		return e;
	}

	public function getScopedExpr():{expr:TExpr, reset:Void->Void} {
		if (bind != null && bind.bStatus == BindDeferred) {
			// For deferred bindings, we generate `subject = expr` and mark the binding as used so that
			// subsequent calls to this function do not generate the assignment again. The returned function
			// can be used to reset the status back to BindDeferred, for cases where we need to initalize
			// again in an unrelated scope.
			var assigned = Builder.binop(OpAssign, e, bind.bExpr, e.etype, e.epos);
			bind.bStatus = BindUsed;
			return {
				expr: assigned,
				reset: function() {
					bind.bStatus = BindDeferred;
				}
			};
		}
		if (bind != null && bind.bStatus == BindUnused) bind.bStatus = BindUsed;
		return {expr: e, reset: function() {}};
	}

	public function getAssignedExpr():TExpr {
		var scoped = getScopedExpr();
		scoped.reset();
		return scoped.expr;
	}

	public function getPos():Pos return e.epos;

	public function isNullable():Bool return isExplicitNullOrAbstractOverThat(e.etype);

	// How array patterns read this subject, looked up when they first do. They are only typed against values which
	// can be accessed by index (see ExprToPattern), but an element of an abstract has the type of its @:arrayAccess
	// getter here, which can differ from the `from` type the element's own patterns were typed against.
	public function getArrayAccess(ctx:Typer):ArrayAccessData {
		if (arrayAccess == null) {
			var aa = ExprToPattern.getArrayAccess(ctx, e.etype, e.epos);
			arrayAccess = aa != null ? aa : ExprToPattern.noArrayAccess(e.etype, e.epos);
		}
		return arrayAccess;
	}

	public function toString():String return MatcherGlobals.sExprPretty(e);

	// The scrutinee of a switch on [subject] with the constructors [cons], in the order of its cases. The switch uses
	// the subject's expression as [e_switch], which assigns the subject's deferred binding if the switch comes first.
	public static function makeScrutinee(ctx:Typer, subject:Subject, eSwitch:TExpr, cons:Array<ConstructorData>):Scrutinee {
		var t = eSwitch.etype;
		switch follow(t) {
			case TDynamic(_) | TMono(_):
				if (cons.length > 0) t = switch cons[0].kind {
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
					case ConTypeExpr(mt): ExprToPattern.getGeneralModuleType(ctx, mt, eSwitch.epos);
					case ConFields(_) | ConStatic(_, _):
						// error "Could not determine switch kind, make sure the type is known" e.epos;
						tDynamic;
				};
			case _:
		}
		// port: the constructors are kept distinct as they are added (the ConTable of TexprConverter.unmatched_ctors).
		var constructors:Array<ConstructorData> = [];
		function add(kind:ConstructorKind):Void {
			var con = ({kind: kind, pos: nullPos} : ConstructorData);
			for (i in 0...constructors.length) if (Constructor.equal(constructors[i], con)) {
				constructors[i] = con;
				return;
			}
			constructors.push(con);
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
							var ctor = cf.cfExpr == null ? null : Constructor.extractCtor(cf.cfExpr);
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
				case t = TInst({clPath: {pack: [], name: "Array"}}, _): {kind: SKLength(typing.ArrayAccess.getArrayAccess(ctx, t, eSwitch.epos)), finiteness: Infinite};
				// port: `constructors` is still empty here and the constructors are distinct, so they are pushed without add's linear search.
				case TEnum(en, _):
					if (!deep) {
						var names = [for (n in en.eConstrs.keys()) n];
						names.sort(core.ds.Key.compareStrings);
						for (n in names) constructors.push(({kind: ConEnum(en, en.eConstrs.get(n)), pos: nullPos} : ConstructorData));
					}
					{kind: SKEnum, finiteness: RunTimeFinite};
				case _: {kind: SKValue, finiteness: Infinite};
			};
		var classified = loop(false, t);
		// Array patterns test the subject's length (#8012). A switch without cases doesn't test its subject at all.
		if (cons.length > 0 && cons[0].kind.match(ConArray(_))) {
			constructors = [];
			classified = {kind: SKLength(subject.getArrayAccess(ctx)), finiteness: Infinite};
		} else if (cons.length == 0 && classified.kind.match(SKLength(_))) {
			classified = {kind: SKValue, finiteness: classified.finiteness};
		}
		return {
			scrExpr: eSwitch,
			scrKind: classified.kind,
			scrFiniteness: classified.finiteness,
			scrConstructors: constructors,
			scrNullable: subject.isNullable()
		};
	}
}
