package core;

import core.TType;
import core.ds.PMap;
import core.ds.List;
import core.ds.NotFound;
import Type as StdType;
import core.TFunctions;
import core.TFunctions.*;
import core.TPrinting.*;
import core.TUnification.TUnification.*;
import core.MetaList.StrictMeta;
import core.Meta as MetadataTools;

// port: from haxe/src/core/tUnification.ml.
// port: OCaml record updates copy the context but share all recursion-stack cells.
enum UnifyError {
	CannotUnify(a:T, b:T);
	CannotUnifyImplementation(a:T, b:T);
	InvalidFieldType(name:String);
	HasNoField(t:T, name:String);
	HasNoRuntimeField(t:T, name:String);
	HasExtraField(t:T, name:String);
	InvalidKind(name:String, a:FieldKind, b:FieldKind);
	InvalidVisibility(name:String);
	// optional acc_actual, optional acc_expected, field name
	NotMatchingOptional(actual:Bool, expected:Bool, name:String);
	InvariantParameter(index:Int);
	ConstraintFailure(name:String);
	MissingOverload(field:TClassField, t:T);
	FinalInvariance(actual:Bool, expected:Bool); // nice band name
	InvalidFunctionArgument(index:Int, total:Int); // index, total
	InvalidReturnType;
	UnifyCustom(message:String);
}

class Unify_error {
	public var errors:Array<UnifyError>;

	public function new(errors) this.errors = errors;
}

enum EqKind {
	EqStrict;
	EqCoreType;
	EqRightDynamic;
	EqBothDynamic;
	EqStricter;
}

@:structInit class TypeParamUnificationContext {
	public var knownTypeParams:Array<TypedTypeParam>;
	public var typeParamPairs:Array<{a:TypedTypeParam, b:TypedTypeParam}>;

	public inline function new(knownTypeParams:Array<TypedTypeParam>, typeParamPairs:Array<{a:TypedTypeParam, b:TypedTypeParam}>) {
		this.knownTypeParams = knownTypeParams;
		this.typeParamPairs = typeParamPairs;
	}

	public inline function clone():TypeParamUnificationContext return new TypeParamUnificationContext(knownTypeParams, typeParamPairs);
}

enum TypeParamMode {
	TpDefault;
	TpDefinition(context:TypeParamUnificationContext);
}

// port: upstream wraps a mutable list in a record; the array itself is the stack here,
// its top (the list's head) at the end: `v :: l` is a push, `List.tl` a pop.
typedef RecStack<A> = Array<A>;

enum NullFollowMode {
	NeverFollow;
	AlwaysFollow;
	FollowIfNullable;
}

@:structInit class TypePair {
	public var a:T;
	public var b:T;

	public inline function new(a:T, b:T) {
		this.a = a;
		this.b = b;
	}

	public inline function clone():TypePair return new TypePair(a, b);
}

@:structInit class UnificationContext {
	public var allowTransitiveCast:Bool;
	public var allowAbstractCast:Bool; // allows a non-transitive abstract cast (from,to,@:from,@:to)
	public var allowDynamicToCast:Bool; // allows a cast from dynamic to non-dynamic
	public var allowArgNameMismatch:Bool;
	public var allowOptionalMismatch:Bool; // allows optional vs. non-optional fields
	public var allowFinalInvariance:Bool;
	public var equalityKind:EqKind;
	public var equalityUnderlying:Bool;
	public var strictFieldKind:Bool;
	public var opaqueFieldParams:Bool; // treat cf_params as opaque: don't substitute them with fresh monomorphs during unification
	public var typeParamMode:TypeParamMode;
	public var nullFollowMode:NullFollowMode;
	// port: the stacks are allocated on first access: most unifications never reach
	// them, and a default context is built for each one. Any access (including
	// clone) allocates, so contexts copied from this one share its stacks.
	public var unifyStack(get, set):RecStack<TypePair>;

	var _unifyStack:Null<RecStack<TypePair>>;

	inline function get_unifyStack():RecStack<TypePair> {
		var v = _unifyStack;
		if (v == null) v = _unifyStack = [];
		return v;
	}

	inline function set_unifyStack(v:RecStack<TypePair>):RecStack<TypePair> return _unifyStack = v;

	public var eqStack(get, set):RecStack<TypePair>;

	var _eqStack:Null<RecStack<TypePair>>;

	inline function get_eqStack():RecStack<TypePair> {
		var v = _eqStack;
		if (v == null) v = _eqStack = [];
		return v;
	}

	inline function set_eqStack(v:RecStack<TypePair>):RecStack<TypePair> return _eqStack = v;

	public var varianceStack(get, set):RecStack<TypePair>;

	var _varianceStack:Null<RecStack<TypePair>>;

	inline function get_varianceStack():RecStack<TypePair> {
		var v = _varianceStack;
		if (v == null) v = _varianceStack = [];
		return v;
	}

	inline function set_varianceStack(v:RecStack<TypePair>):RecStack<TypePair> return _varianceStack = v;

	public var abstractCastStack(get, set):RecStack<TypePair>;

	var _abstractCastStack:Null<RecStack<TypePair>>;

	inline function get_abstractCastStack():RecStack<TypePair> {
		var v = _abstractCastStack;
		if (v == null) v = _abstractCastStack = [];
		return v;
	}

	inline function set_abstractCastStack(v:RecStack<TypePair>):RecStack<TypePair> return _abstractCastStack = v;

	public var unifyNewMonos(get, set):RecStack<T>;

	var _unifyNewMonos:Null<RecStack<T>>;

	inline function get_unifyNewMonos():RecStack<T> {
		var v = _unifyNewMonos;
		if (v == null) v = _unifyNewMonos = [];
		return v;
	}

	inline function set_unifyNewMonos(v:RecStack<T>):RecStack<T> return _unifyNewMonos = v;

	public var applyParamsStack(get, set):ApplyParamsStack;

	var _applyParamsStack:Null<ApplyParamsStack>;

	inline function get_applyParamsStack():ApplyParamsStack {
		var v = _applyParamsStack;
		if (v == null) v = _applyParamsStack = {value: []};
		return v;
	}

	inline function set_applyParamsStack(v:ApplyParamsStack):ApplyParamsStack return _applyParamsStack = v;

	public inline function new(allowTransitiveCast:Bool, allowAbstractCast:Bool, allowDynamicToCast:Bool, allowArgNameMismatch:Bool,
			allowOptionalMismatch:Bool, allowFinalInvariance:Bool, equalityKind:EqKind, equalityUnderlying:Bool, strictFieldKind:Bool,
			opaqueFieldParams:Bool, typeParamMode:TypeParamMode, nullFollowMode:NullFollowMode, unifyStack:Null<RecStack<TypePair>>,
			eqStack:Null<RecStack<TypePair>>, varianceStack:Null<RecStack<TypePair>>, abstractCastStack:Null<RecStack<TypePair>>,
			unifyNewMonos:Null<RecStack<T>>, applyParamsStack:Null<ApplyParamsStack>) {
		this.allowTransitiveCast = allowTransitiveCast;
		this.allowAbstractCast = allowAbstractCast;
		this.allowDynamicToCast = allowDynamicToCast;
		this.allowArgNameMismatch = allowArgNameMismatch;
		this.allowOptionalMismatch = allowOptionalMismatch;
		this.allowFinalInvariance = allowFinalInvariance;
		this.equalityKind = equalityKind;
		this.equalityUnderlying = equalityUnderlying;
		this.strictFieldKind = strictFieldKind;
		this.opaqueFieldParams = opaqueFieldParams;
		this.typeParamMode = typeParamMode;
		this.nullFollowMode = nullFollowMode;
		this._unifyStack = unifyStack;
		this._eqStack = eqStack;
		this._varianceStack = varianceStack;
		this._abstractCastStack = abstractCastStack;
		this._unifyNewMonos = unifyNewMonos;
		this._applyParamsStack = applyParamsStack;
	}

	public inline function clone():UnificationContext return new UnificationContext(allowTransitiveCast, allowAbstractCast,
		allowDynamicToCast, allowArgNameMismatch, allowOptionalMismatch, allowFinalInvariance, equalityKind, equalityUnderlying,
		strictFieldKind, opaqueFieldParams, typeParamMode, nullFollowMode, unifyStack, eqStack, varianceStack, abstractCastStack,
		unifyNewMonos, applyParamsStack);
}

enum UnifyMinResult {
	UnifyMinOk(t:T);
	UnifyMinError(errors:Array<UnifyError>, index:Int);
}


class Monomorph {
	public static function create():TMono return {
		tmType: null,
		tmDownConstraints: [],
		tmUpConstraints: [],
		tmModifiers: []
	};

	public static function addModifier(m:TMono, mod:TMonoModifier):Void m.tmModifiers.unshift(mod);

	public static function hasModifier(m:TMono, f:TMonoModifier->Bool):Bool return core.ds.ArrayTools.exists(m.tmModifiers, f);

	public static function isDynamic(m:TMono):Bool return hasModifier(m, function(mod) return switch mod {
		case MDynamic: true;
		case _: false;
	});

	// constraining

	public static function addUpConstraint(m:TMono, c:{type:T, name:Null<String>}):Void {
		m.tmUpConstraints.unshift(c);
		switch c.type {
			case TMono(m2):
				m2.tmDownConstraints.unshift(MMono(m, c.name));
			case _:
		}
	}

	public static function addDownConstraint(m:TMono, c:TMonoConstraint):Void {
		m.tmDownConstraints.unshift(c);
		switch c {
			case MMono(m2, s):
				m2.tmUpConstraints.unshift({type: TMono(m), name: s});
			case _:
		}
	}

	public static function constraintOfType(name:Null<String>, t:T):Array<TMonoConstraint> return switch follow(t) {
		case TMono(m): [MMono(m, name)];
		case TAnon(an) if (!PMap.isEmpty(an.aFields)): PMap.fold(function(cf, l:Array<TMonoConstraint>) {
				l.unshift(MField(cf));
				return l;
			}, an.aFields, []);
		case TAnon(_): [MEmptyStructure];
		case _: [MType(t, name)];
	}

	public static function constrainToType(m:TMono, name:Null<String>,
			t:T):Void for (c in constraintOfType(name, t)) addDownConstraint(m, c);

	// Note: This function is called by printing and others and should thus not modify state.

	public static function classifyDownConstraints(m:TMono):TMonoConstraintKind {
		var types:Array<{type:T, name:Null<String>}> = [], fields = PMap.empty(), isOpen = false, visited = [m];
		function check(c:TMonoConstraint):Void switch c {
			case MMono(m2, name):
				if (visited.indexOf(m2) < 0) {
					visited.unshift(m2);
					// Recursively inherit constraints.
					if (m2.tmType == null) for (c in m2.tmDownConstraints) check(c);
					else for (c in constraintOfType(name, m2.tmType)) check(c);
				}
			case MField(cf):
				fields = PMap.add(cf.cfName, cf, fields);
			case MType(t, name):
				types.push({type: t, name: name});
			case MEmptyStructure:
				isOpen = true;
		}
		for (c in m.tmDownConstraints) check(c);
		for (mod in m.tmModifiers) switch mod {
			case MOpenStructure:
				isOpen = true;
			case MNullable(_), MDynamic:
		}
		var kind = types.length > 0 ? CTypes(types) : CUnknown;
		if (!PMap.isEmpty(fields) || isOpen) {
			var structure = CStructural(fields, isOpen);
			return switch kind {
				case CTypes(_): CMixed([kind, structure]);
				case _: structure;
			};
		}
		return kind;
	}

	public static function checkDownConstraints(c:TMonoConstraintKind, t:T):Void switch c {
		case CUnknown:
		case CTypes(tl):
			for (v in tl) {
				var f = function() unifyRef(defaultUnificationContext(), t, v.type);
				if (v.name != null) checkConstraint(v.name, f);
				else f();
			}
		case CStructural(fields, _):
			unifyRef(defaultUnificationContext(), t, mkAnon(Closed, fields));
		case CMixed(l):
			for (c in l) checkDownConstraints(c, t);
	}

	public static function collectUpConstraints(m:TMono):Array<{type:T, name:Null<String>}> {
		var visited = [m];
		function collect(m:TMono, acc:Array<{type:T, name:Null<String>}>):Array<{type:T, name:Null<String>}> {
			for (v in m.tmUpConstraints) switch v.type {
				case TMono(m2):
					if (m2.tmType != null) switch follow(m2.tmType) {
						case TMono(_):
						case _: acc.unshift({type: m2.tmType, name: v.name});
					}
					else if (visited.indexOf(m2) < 0) {
						visited.unshift(m2);
						acc = collect(m2, acc);
					}
				case _:
					acc.unshift(v);
			}
			return acc;
		}
		return collect(m, []);
	}

	public static function checkUpConstraints(m:TMono, t:T):Void for (v in collectUpConstraints(m)) {
		var check = function() unifyRef(defaultUnificationContext(), v.type, t);
		if (v.name != null) checkConstraint(v.name, check);
		else check();
	}

	// binding

	public static function doBind(m:TMono, t:T):Void {
		// assert(m.tm_type = None); // TODO: should be here, but matcher.ml does some weird bind handling at the moment.
		for (mod in m.tmModifiers) switch mod {
			case MNullable(f):
				t = f(t);
			case MOpenStructure, MDynamic:
		}
		m.tmType = t;
		m.tmDownConstraints = [];
		m.tmUpConstraints = [];
	}

	public static function bind(m:TMono, t:T):Void switch t {
		case TAnon(_) if (m.tmModifiers.indexOf(MOpenStructure) >= 0):
			// If we assign an open structure monomorph to another structure, the semantics want us to merge the
			// fields. This is kinda weird, but that's how it has always worked.
			constrainToType(m, null, t);
			close(m);
		case TMono(m2):
			if (m != m2) {
				if (m2.tmType == null) {
					for (c in m.tmDownConstraints) addDownConstraint(m2, c);
					for (c in m.tmUpConstraints) addUpConstraint(m2, c);
					for (mod in m.tmModifiers) addModifier(m2, mod);
					doBind(m, t);
				} else bind(m, m2.tmType);
			}
		case _:
			checkUpConstraints(m, t);
			// Due to recursive constraints like in #9603, we tentatively bind the monomorph to the type we're checking
			// against before checking the constraints.
			m.tmType = t;
			var kind = classifyDownConstraints(m);
			try {
				checkDownConstraints(kind, t);
			} catch (e:haxe.Exception) {
				m.tmType = null;
				throw e;
			}
			m.tmType = null;
			doBind(m, t);
	}

	public static function close(m:TMono):Void {
		if (m.tmType != null) return;
		inline function getRecursion(t:T):Null<T> {
			function loop(t:T):Void switch t {
				case TMono(m2) if (m == m2):
					throw new core.TType.TypeException(t);
				case _:
					TFunctions.iter(loop, t);
			}
			try {
				loop(t);
				return null;
			} catch (e:core.TType.TypeException) {
				return e.type;
			}
		}
		switch classifyDownConstraints(m) {
			case CUnknown:
				if (isDynamic(m)) doBind(m, tDynamic);
			case CTypes([{type: t, name: _}]):
				// TODO: silently not binding doesn't seem correct, but it's likely better than infinite recursion
				if (getRecursion(t) == null) doBind(m, t);
			case CTypes(_), CMixed(_):
			case CStructural(fields, _):
				// We found a bunch of fields but no type, create a merged structure type and bind to that
				PMap.iter(function(_, cf:TClassField) {
					var t = getRecursion(cf.cfType);
					if (t != null) {
						// port: OCaml evaluates the sprintf arguments right to left
						var pctx = printContext(); var sf = sType(pctx,
							cf.cfType);
						var s = sType(pctx, t) + " appears in { " + cf.cfName + ": " + sf + " }";
						throw new Unify_error([UnifyCustom("Recursive type"), UnifyCustom(s)]);
					}
				}, fields);
				doBind(m, mkAnon(Closed, fields));
		}
	}

	public static function unbind(m:TMono):Void m.tmType = null;

	public static function spawnConstrainedMonos(map:T->T, params:TypeParams):Array<T> {
		var checks:Array<{mono:TMono, constraints:Array<T>, path:String}> = [];
		var monos = params.map(function(ttp) {
			var m = create(), c = getConstraints(ttp);
			if (c.length > 0) checks.push({mono: m, constraints: c, path: Globals.sTypePath(ttp.ttpClass.clPath)});
			return TMono(m);
		});
		var transform = function(t) return map(applyParams(params, monos, t));
		for (v in checks) for (t in v.constraints) constrainToType(v.mono, v.path, transform(t));
		return monos;
	}
}

class TUnification {
	// port: hxmc's persistent module cache (hxmc/src/hxmc/ModuleCache.hx) learns here which class fields a
	// ... structural unification marks as maybe used (with the field of the structure; null for a class's
	// ... statics), to attribute the marks to the module being typed; always null in the compiler itself.
	public static var maybeUsedHook:Null<(cl:Null<TClass>, f1:TClassField, f2:Null<TClassField>) -> Void> = null;

	public static function error(l:Array<UnifyError>):Dynamic throw new Unify_error(l);

	public static function checkConstraint(name:String, f:Void->Void):Void try {
		f();
	} catch (e:Unify_error) {
		error([ConstraintFailure(name)].concat(e.errors));
	}

	// port: upstream's trailing `unify_ref := ...` assignments are these initializers.
	public static var unifyRef:UnificationContext->T->T->Void = unifyCustom;
	public static var unifyMinRef:UnificationContext->T->Array<T>->UnifyMinResult = UnifyMinT.unifyMin;

	public static inline function newRecStack<A>():RecStack<A> return [];

	public static function defaultUnificationContext():UnificationContext return {
		allowTransitiveCast: true,
		allowAbstractCast: true,
		allowDynamicToCast: true,
		allowArgNameMismatch: true,
		allowOptionalMismatch: true,
		equalityKind: EqStrict,
		equalityUnderlying: false,
		strictFieldKind: false,
		opaqueFieldParams: false,
		allowFinalInvariance: false,
		typeParamMode: TpDefault,
		nullFollowMode: AlwaysFollow,
		unifyStack: null,
		eqStack: null,
		varianceStack: null,
		abstractCastStack: null,
		unifyNewMonos: null,
		applyParamsStack: null
	};

	// Unify like targets (e.g. Java) probably would.
	public static var nativeUnificationContext:UnificationContext = makeNativeContext();

	static function makeNativeContext():UnificationContext {
		var c = defaultUnificationContext();
		c.allowTransitiveCast = false;
		c.allowAbstractCast = false;
		c.allowDynamicToCast = false;
		c.allowFinalInvariance = true;
		c.nullFollowMode = FollowIfNullable;
		return c;
	}

	static function pair(a:T, b:T):TypePair return {a: a, b: b};

	static function pathIs(p:core.Globals.GlobalTypePath, pack:String, name:String):Bool return p.pack.join(".") == pack && p.name == name;

	static function pathEq(a:core.Globals.GlobalTypePath,
			b:core.Globals.GlobalTypePath):Bool return a.name == b.name && a.pack.join(".") == b.pack.join(".");

	public static function followAndClose(t:T):T return switch follow(t) {
		case TMono(r):
			Monomorph.close(r);
			r.tmType != null ? followAndClose(t) : TMono(r);
		case t: t;
	}

	public static function link(uctx:UnificationContext, e:TMono, a:T, b:T):Bool {
		// tell if setting a == b will create a type-loop
		function loop(t:T):Bool {
			if (t == a) return true;
			return switch t {
				case TMono(m): m.tmType != null && loop(m.tmType);
				case TEnum(_, tl): core.ds.ArrayTools.exists(tl, loop);
				case TInst({clKind: KTypeParameter(ttp)}, tl): switch uctx.typeParamMode {
						case TpDefault: core.ds.ArrayTools.exists(tl, loop);
						case TpDefinition(c): c.knownTypeParams.indexOf(ttp) < 0;
					}
				case TInst(_, tl), TType(_, tl), TAbstract(_, tl): core.ds.ArrayTools.exists(tl, loop);
				case TFun(s): core.ds.ArrayTools.exists(s.args, function(a) return loop(a.type)) || loop(s.ret);
				case TDynamic(null): false;
				case TDynamic(t): loop(t);
				case TLazy(f): loop(lazyType(f));
				case TAnon(an): try {
						PMap.iter(function(_, f:TClassField) {
							if (loop(f.cfType)) throw new TypeExit();
						}, an.aFields);
						false;
					} catch (_:TypeExit) {
						true;
					}
			}
		}
		// tell is already a ~= b
		if (loop(b)) return follow(b) == a;
		if (b == tDynamic) {
			if (!Monomorph.isDynamic(e)) Monomorph.addModifier(e, MDynamic);
			return true;
		}
		Monomorph.bind(e, b);
		return true;
	}

	public static function linkDynamic(a:T, b:T):Void switch [follow(a), follow(b)] {
		case [TMono(r), TDynamic(_)]:
			Monomorph.bind(r, b);
		case [TDynamic(_), TMono(r)]:
			Monomorph.bind(r, a);
		case _:
	}

	public static function fastEqCheck(check:T->T->Bool, a:T, b:T):Bool {
		if (a == b) return true;
		return switch [a, b] {
			case [TFun(s1), TFun(s2)] if (s1.args.length == s2.args.length): List.forAll2(function(a, b) return check(a.type, b.type),
					s1.args, s2.args) && check(s1.ret, s2.ret);
			case [TType(t1, l1), TType(t2, l2)]: t1 == t2 && List.forAll2(check, l1, l2);
			case [TEnum(t1, l1), TEnum(t2, l2)]: t1 == t2 && List.forAll2(check, l1, l2);
			case [TInst(t1, l1), TInst(t2, l2)]: t1 == t2 && List.forAll2(check, l1, l2);
			case [TAbstract(t1, l1), TAbstract(t2, l2)]: t1 == t2 && List.forAll2(check, l1, l2);
			case [TAnon(an1), TAnon(an2)]: switch [an1.aStatus, an2.aStatus] {
					case [ClassStatics(c1), ClassStatics(c2)]: c1 == c2;
					case [EnumStatics(e1), EnumStatics(e2)]: e1 == e2;
					case [AbstractStatics(a1), AbstractStatics(a2)]: a1 == a2;
					case _: false;
				}
			case _: false;
		}
	}

	public static function fastEq(a:T, b:T):Bool return fastEqCheck(fastEq, a, b);

	public static function fastEqPair(a:TypePair, b:TypePair):Bool return fastEq(a.a, b.a) && fastEq(a.b, b.b);

	public static function fastEqUnboundMono(a:T, b:T):Bool return switch [a, b] {
		case [TMono({tmType: null}), TMono({tmType: null})]: true;
		case _: fastEqCheck(fastEqUnboundMono, a, b);
	}

	public static function fastEqMono(ml:Array<T>, a:T, b:T):Bool {
		if (fastEqCheck(function(a, b) return fastEqMono(ml, a, b), a, b)) return true;
		return switch a {
			case TMono(_): ml.indexOf(a) >= 0;
			case _: false;
		};
	}

	public static function shallowEq(a:T, b:T):Bool {
		if (a == b) return true;
		a = follow(a);
		b = follow(b);
		if (fastEqCheck(shallowEq, a, b)) return true;
		return switch [a, b] {
			case [t, TMono({tmType: null})] if (t == tDynamic): true;
			case [TMono({tmType: null}), t] if (t == tDynamic): true;
			case [TMono({tmType: null}), TMono({tmType: null})]: true;
			case [TAnon(a1), TAnon(a2)]:
				function fieldsEq():Bool {
					var f1 = PMap.fold(function(f, l:Array<TClassField>) {
						l.unshift(f);
						return l;
					}, a1.aFields, []), f2 = PMap.fold(function(f, l:Array<TClassField>) {
						l.unshift(f);
						return l;
					}, a2.aFields, []);
					var cmp = function(a:TClassField, b:TClassField) return Reflect.compare(a.cfName, b.cfName);
					f1.sort(cmp);
					f2.sort(cmp);
					if (f1.length != f2.length) return false;
					for (i in 0...f1.length) {
						if (f1[i].cfName != f2[i].cfName) return false;
						try {
							if (!shallowEq(f1[i].cfType, f2[i].cfType)) return false;
						} catch (_:NotFound) {
							return false;
						}
					}
					return true;
				}
				switch [a2.aStatus, a1.aStatus] {
					case [Extend(tl1), Extend(tl2)]: fieldsEq() && List.forAll2(shallowEq, tl1, tl2);
					case [Closed, Closed], [Const, Const]: fieldsEq();
					case _: false;
				}
			case _: false;
		}
	}

	// perform unification with subtyping.
	// the first type is always the most down in the class hierarchy
	// it's also the one that is pointed by the position.
	// It's actually a typecheck of  A :> B where some mutations can happen

	public static function cannotUnify(a:T, b:T):UnifyError return CannotUnify(a, b);

	public static function invalidField(n:String):UnifyError return InvalidFieldType(n);

	public static function invalidKind(n:String, a:FieldKind, b:FieldKind):UnifyError return InvalidKind(n, a, b);

	public static function invalidVisibility(n:String):UnifyError return InvalidVisibility(n);

	public static function hasNoField(t:T, n:String):UnifyError return HasNoField(t, n);

	public static function hasExtraField(t:T, n:String):UnifyError return HasExtraField(t, n);

	public static function directAccess(a:VarAccess):Bool return switch a {
		case AccNo, AccNever, AccNormal, AccInline, AccRequire(_, _), AccCtor: true;
		case AccCall, AccPrivateCall: false;
	};

	// we can restrict access as soon as both are runtime-compatible
	public static function unifyVarAccess(c:UnificationContext, a:VarAccess, b:VarAccess):Bool {
		if (StdType.enumEq(a, b)) return true;
		return switch [a, b] {
			case [_, AccNo], [_, AccNever], [AccInline, AccNormal], [AccCall, AccPrivateCall]: true;
			case _ if (c.allowFinalInvariance): directAccess(a) && directAccess(b);
			case _: false;
		};
	}

	public static function unifyKind(c:UnificationContext, a:FieldKind, b:FieldKind):Bool {
		if (StdType.enumEq(a, b)) return true;
		return switch [a, b] {
			case [Var(a), Var(b)]: unifyVarAccess(c, a.vRead, b.vRead) && unifyVarAccess(c, a.vWrite, b.vWrite);
			case [Method(a), Method(b)]: switch [a, b] {
					case [MethInline, MethNormal], [MethDynamic, MethNormal]: true;
					case _: false;
				}
			case [Var(v), Method(m)] if (!c.strictFieldKind): switch [v.vRead, v.vWrite, m] {
					case [AccNormal, _, MethNormal], [AccNormal, AccNormal, MethDynamic]: true;
					case _: false;
				}
			case [Method(m), Var(v)] if (!c.strictFieldKind): switch m {
					case MethDynamic: directAccess(v.vRead) && directAccess(v.vWrite);
					case MethMacro: false;
					case MethNormal, MethInline: switch [v.vRead, v.vWrite] {
							case [AccNormal, AccNo], [AccNormal, AccNever]: true;
							case _: false;
						}
				}
			case _: false;
		}
	}

	public static function recStackExists<A>(f:A->Bool, s:RecStack<A>):Bool {
		var i = s.length;
		while (i > 0) if (f(s[--i])) return true;
		return false;
	}

	public static function recStackMemq<A>(v:A, s:RecStack<A>):Bool return s.indexOf(v) >= 0;

	public static function recStackLoop<A, B, R>(s:RecStack<A>, v:A, f:B->R, arg:B):R {
		s.push(v);
		try {
			var r = f(arg);
			s.pop();
			return r;
		} catch (e:haxe.Exception) {
			s.pop();
			throw e;
		}
	}

	public static function recStack<A>(s:RecStack<A>, v:A, check:A->Bool, run:Void->Void, onError:Array<UnifyError>->Void):Void {
		if (!recStackExists(check, s)) {
			s.push(v);
			try {
				run();
			} catch (e:Unify_error) {
				s.pop();
				onError(e.errors);
				return;
			} catch (e:haxe.Exception) {
				s.pop();
				throw e;
			}
			s.pop();
		}
	}

	public static function recStackDefault<A, R>(s:RecStack<A>, v:A, check:A->Bool, run:Void->R,
			def:R):R return !recStackExists(check, s) ? recStackLoop(s, v, function(_) return run(), null) : def;

	public static function typeEqCustom(c:UnificationContext, a:T, b:T):Void {
		var param = c.equalityKind;
		inline function canFollow(t:T):Bool return param != EqStricter && param != EqCoreType;
		inline function canFollowNull(t:T):Bool return switch c.nullFollowMode {
			case AlwaysFollow: true;
			case NeverFollow: false;
			case FollowIfNullable: isNullable(t);
		};
		function canFollowAbstract(ab:TAbstract):Bool return c.equalityUnderlying && switch ab.aThis {
			case TAbstract(other, _): other != ab;
			case _: true;
		};
		if (a == b) return;
		switch [a, b] {
			case [TLazy(f), _]:
				typeEqCustom(c, lazyType(f), b);
			case [_, TLazy(f)]:
				typeEqCustom(c, a, lazyType(f));
			case [TMono(m), _]:
				if (m.tmType == null) {
					if (param == EqCoreType || param == EqStricter || !link(c, m, a, b)) error([cannotUnify(a, b)]);
				} else typeEqCustom(c, m.tmType, b);
			case [_, TMono(m)]:
				if (m.tmType == null) {
					if (param == EqCoreType || param == EqStricter || !link(c, m, b, a)) error([cannotUnify(a, b)]);
				} else typeEqCustom(c, a, m.tmType);
			case [TDynamic(null), TDynamic(null)]:
			case [TDynamic(a), TDynamic(b)] if (a != null && b != null):
				typeEqCustom(c, a, b);
			case _ if (a == tDynamic && param == EqBothDynamic):
			case _ if (b == tDynamic && (param == EqRightDynamic || param == EqBothDynamic)):
			case [TAbstract(ab1, [t1]), TAbstract(ab2, [t2])] if (pathIs(ab1.aPath, "", "Null") && pathIs(ab2.aPath, "", "Null")):
				typeEqCustom(c, t1, t2);
			case [TAbstract(ab, [t]), t2] if (pathIs(ab.aPath, "", "Null") && canFollowNull(t2)):
				typeEqCustom(c, t, b);
			case [t1, TAbstract(ab, [t])] if (pathIs(ab.aPath, "", "Null") && canFollowNull(t1)):
				typeEqCustom(c, a, t);
			case [TType(t1, tl1), TType(t2, tl2)]
				if ((t1 == t2 || (param == EqCoreType && pathEq(t1.tPath, t2.tPath))) && tl1.length == tl2.length):
				typeEqParams(c, a, b, tl1, tl2);
			case [TType(t, tl), _] if (canFollow(a)):
				recStack(c.eqStack, pair(a, b), function(p) return fastEqPair(pair(a, b), p), function() {
					tryApplyParamsRec(c.applyParamsStack, t.tParams, tl, t.tType, function(a) typeEqCustom(c, a, b));
				}, function(l) error([cannotUnify(a, b)].concat(l)));
			case [_, TType(t, tl)] if (canFollow(b)):
				recStack(c.eqStack, pair(a, b), function(p) return fastEqPair(pair(a, b), p), function() {
					tryApplyParamsRec(c.applyParamsStack, t.tParams, tl, t.tType, function(b) typeEqCustom(c, a, b));
				}, function(l) error([cannotUnify(a, b)].concat(l)));
			case [TEnum(e1, tl1), TEnum(e2, tl2)]:
				if (e1 != e2 && !(param == EqCoreType && pathEq(e1.ePath, e2.ePath))) error([cannotUnify(a, b)]);
				typeEqParams(c, a, b, tl1, tl2);
			case [
				TInst({clKind: KTypeParameter(p1)}, tl1),
				TInst({clKind: KTypeParameter(p2)}, tl2)
			] if (param != EqCoreType):
				assignTypeParams(c, p1, p2);
				typeEqParams(c, a, b, tl1, tl2);
			case [TInst(c1, tl1), TInst(c2, tl2)]:
				var differentKind = switch [c1.clKind, c2.clKind] {
					case [KExpr(_), KExpr(_)]: false;
					case _: true;
				};
				if (c1 != c2 && !(param == EqCoreType && pathEq(c1.clPath, c2.clPath)) && differentKind) error([cannotUnify(a, b)]);
				typeEqParams(c, a, b, tl1, tl2);
			case [TFun(s1), TFun(s2)] if (s1.args.length == s2.args.length):
				var i = 0;
				try {
					typeEqCustom(c, s1.ret, s2.ret);
					List.iter2(function(v1, v2) {
						i++;
						if (!c.allowArgNameMismatch && v1.name != v2.name) error([UnifyCustom("Arg name mismatch: "
							+ v2.name
							+ " should be "
							+ v1.name)]);
						if (v1.optional != v2.optional) error([NotMatchingOptional(v1.optional, v2.optional, v1.name)]);
						typeEqCustom(c, v1.type, v2.type);
					}, s1.args, s2.args);
				} catch (e:Unify_error) {
					var msg = i == 0 ? InvalidReturnType : InvalidFunctionArgument(i, s1.args.length);
					error([cannotUnify(a, b), msg].concat(e.errors));
				}
			case [TAbstract(a1, tl1), TAbstract(a2, tl2)] if (a1 == a2 || (param == EqCoreType && pathEq(a1.aPath, a2.aPath))):
				typeEqParams(c, a, b, tl1, tl2);
			case [TAbstract(ab, tl), _] if (canFollowAbstract(ab)):
				typeEqCustom(c, applyParams(ab.aParams, tl, ab.aThis), b);
			case [_, TAbstract(ab, tl)] if (canFollowAbstract(ab)):
				typeEqCustom(c, a, applyParams(ab.aParams, tl, ab.aThis));
			case [TAnon(a1), TAnon(a2)]:
				try {
					switch a2.aStatus {
						case ClassStatics(c): switch a1.aStatus {
								case ClassStatics(c2) if (c == c2):
								case _: error([]);
							}
						case EnumStatics(e): switch a1.aStatus {
								case EnumStatics(e2) if (e == e2):
								case _: error([]);
							}
						case AbstractStatics(ab): switch a1.aStatus {
								case AbstractStatics(ab2) if (ab == ab2):
								case _: error([]);
							}
						case _:
					}
					var fields = switch a1.aStatus {
						case ClassStatics(c): c.clStatics;
						case _: a1.aFields;
					};
					PMap.iter(function(n, f1) {
						try {
							var f2 = PMap.find(n, a2.aFields),
								kindShouldMatch = param == EqStrict || param == EqCoreType || param == EqStricter;
							if (!fieldKindEq(f1.cfKind, f2.cfKind)
								&& (kindShouldMatch || !unifyKind(c, f1.cfKind, f2.cfKind))) error([invalidKind(n, f1.cfKind, f2.cfKind)]);
							try {
								typeEqCustom(c, f1.cfType, f2.cfType);
							} catch (e:Unify_error) {
								error([invalidField(n)].concat(e.errors));
							}
							if (hasClassFieldFlag(f1, CfPublic) != hasClassFieldFlag(f2, CfPublic)) error([invalidVisibility(n)]);
						} catch (_:NotFound) {
							error([hasNoField(b, n)]);
						}
					}, fields);
					PMap.iter(function(n, _) {
						if (!PMap.mem(n, fields)) error([hasNoField(a, n)]);
					}, a2.aFields);
				} catch (e:Unify_error) {
					error([cannotUnify(a, b)].concat(e.errors));
				}
			case _:
				error([cannotUnify(a, b)]);
		}
	}

	public static function assignTypeParams(c:UnificationContext, p1:TypedTypeParam, p2:TypedTypeParam):Void {
		if (p1 != p2) switch c.typeParamMode {
			case TpDefault:
				error([]);
			case TpDefinition(tc):
				for (p in tc.typeParamPairs) if (p.a == p2) {
					if (p1 != p.b) error([]);
					return;
				}
				tc.typeParamPairs.unshift({a: p2, b: p1});
		}
	}

	public static function typeEqParams(c:UnificationContext, a:T, b:T, tl1:Array<T>, tl2:Array<T>):Void {
		var i = 0;
		List.iter2(function(t1, t2) {
			i++;
			try {
				typeEqCustom(c, t1, t2);
			} catch (e:Unify_error) {
				error([cannotUnify(a, b), InvariantParameter(i)].concat(e.errors));
			}
		}, tl1, tl2);
	}

	public static function typeIseqCustom(c:UnificationContext, a:T, b:T):Bool {
		try {
			typeEqCustom(c, a, b);
			return true;
		} catch (_:Unify_error) {
			return false;
		}
	}

	public static function typeIseqStrict(a:T,
			b:T):Bool return typeIseqCustom(core.ds.Record.withFields(defaultUnificationContext(), {equalityKind: EqStricter}), a, b);

	public static function printStacks(c:UnificationContext):Void {
		var ctx = printContext(), st = function(t) return sType(ctx, t);
		Sys.println("unify_stack");
		for (p in c.unifyStack) Sys.println("\t" + st(p.a) + " , " + st(p.b));
		Sys.println("variance_stack");
		for (p in c.varianceStack) Sys.println("\t" + st(p.a) + " , " + st(p.b));
		Sys.println("monos");
		for (m in c.unifyNewMonos) Sys.println("\t" + st(m));
		Sys.println("abstract_cast_stack");
		for (p in c.abstractCastStack) Sys.println("\t" + st(p.a) + " , " + st(p.b));
	}

	public static function fieldTypeForUnification(c:UnificationContext,
			f:TClassField):T return c.opaqueFieldParams ? f.cfType : fieldType(f);

	public static function unifyCustom(c:UnificationContext, a:T, b:T):Void {
		if (a == b) return;
		switch [a, b] {
			case [TLazy(f), _]:
				unifyCustom(c, lazyType(f), b);
			case [_, TLazy(f)]:
				unifyCustom(c, a, lazyType(f));
			case [TMono(m), _]:
				if (m.tmType == null) {
					if (c.equalityKind == EqStricter || !link(c, m, a, b)) error([cannotUnify(a, b)]);
				} else unifyCustom(c, m.tmType, b);
			case [_, TMono(m)]:
				if (m.tmType == null) {
					if (c.equalityKind == EqStricter || !link(c, m, b, a)) error([cannotUnify(a, b)]);
				} else unifyCustom(c, a, m.tmType);
			case [TType(t, tl), _]:
				recStack(c.unifyStack, pair(a, b), function(p) return fastEqUnboundMono(a, p.a) && fastEq(b, p.b), function() {
					tryApplyParamsRec(c.applyParamsStack, t.tParams, tl, t.tType, function(a) unifyCustom(c, a, b));
				}, function(l) error([cannotUnify(a, b)].concat(l)));
			case [_, TType(t, tl)]:
				recStack(c.unifyStack, pair(a, b), function(p) return fastEq(a, p.a) && fastEqUnboundMono(b, p.b), function() {
					tryApplyParamsRec(c.applyParamsStack, t.tParams, tl, t.tType, function(b) unifyCustom(c, a, b));
				}, function(l) error([cannotUnify(a, b)].concat(l)));
			case [TEnum(ea, tl1), TEnum(eb, tl2)]:
				if (ea != eb) error([cannotUnify(a, b)]);
				unifyTypeParams(c, a, b, tl1, tl2);
			case [TAbstract(ab1, [t1]), TAbstract(ab2, [t2])] if (pathIs(ab1.aPath, "", "Null") && pathIs(ab2.aPath, "", "Null")):
				// Unify the wrapped types directly so a monomorph on either side binds to the
				// unwrapped type instead of capturing the whole Null<...> - see #11077
				try {
					unifyCustom(c, t1, t2);
				} catch (e:Unify_error) {
					error([cannotUnify(a, b)].concat(e.errors));
				}
			case [TAbstract(ab, [t]), _] if (pathIs(ab.aPath, "", "Null")):
				try {
					unifyCustom(c, t, b);
				} catch (e:Unify_error) {
					error([cannotUnify(a, b)].concat(e.errors));
				}
			case [_, TAbstract(ab, [t])] if (pathIs(ab.aPath, "", "Null")):
				try {
					unifyCustom(c, a, t);
				} catch (e:Unify_error) {
					error([cannotUnify(a, b)].concat(e.errors));
				}
			case [TAbstract(a1, tl1), TAbstract(a2, tl2)] if (a1 == a2):
				try {
					unifyTypeParams(c, a, b, tl1, tl2);
				} catch (first:Unify_error) {
					// the type could still have a from/to relation to itself (issue #3494)
					try {
						unifyAbstracts(c, a, b, a1, tl1, a2, tl2);
					} catch (_:Unify_error) {
						throw first;
					}
				}
			case [TAbstract(ab, _), _] if (pathIs(ab.aPath, "", "Void")):
				error([cannotUnify(a, b)]);
			case [_, TAbstract(ab, _)] if (pathIs(ab.aPath, "", "Void")):
				error([cannotUnify(a, b)]);
			case [TAbstract(ab, []), _] if (pathIs(ab.aPath, "haxe", "NotVoid")):
			case [_, TAbstract(ab, [])] if (pathIs(ab.aPath, "haxe", "NotVoid")):
			case [TAbstract(ab, tl), TAbstract(target, _)]
				if (target.aPath.pack.join(".") == "haxe" && ["FlatEnum", "Function", "Constructible"].indexOf(target.aPath.name) >= 0):
				unifyTo(core.ds.Record.withFields(c, {allowTransitiveCast: false}), a, b, ab, tl);
			case [TAbstract(a1, tl1), TAbstract(a2, tl2)]:
				unifyAbstracts(c, a, b, a1, tl1, a2, tl2);
			case [
				TInst({clKind: KTypeParameter(p1)}, tl1),
				TInst({clKind: KTypeParameter(p2)}, tl2)
			] if (c.typeParamMode != TpDefault):
				assignTypeParams(c, p1, p2);
				unifyTypeParams(c, a, b, tl1, tl2);
			case [TInst(c1, tl1), TInst(c2, tl2)]:
				function loop(cl:TClass, tl:Array<T>):Bool {
					if (cl == c2) {
						unifyTypeParams(c, a, b, tl, tl2);
						return true;
					}
					if (cl.clSuper != null) {
						var s = cl.clSuper;
						if (loop(s.cls, s.params.map(function(t) return applyParams(cl.clParams, tl, t)))) return true;
					}
					if (core.ds.ArrayTools.exists(cl.clImplements,
						function(s) return loop(s.cls, s.params.map(function(t) return applyParams(cl.clParams, tl, t))))) return true;
					return switch cl.clKind {
						case KTypeParameter(p): core.ds.ArrayTools.exists(getConstraints(p), function(t) return switch follow(t) {
								case TInst(cs, tls): loop(cs, tls.map(function(t) return applyParams(cl.clParams, tl, t)));
								case TAbstract(aa, tl): unifiesTo(c, a, b, aa, tl);
								case _: false;
							});
						case _: false;
					}
				}
				if (!loop(c1, tl1)) error([cannotUnify(a, b)]);
			case [TFun(s1), TFun(s2)] if (s1.args.length == s2.args.length):
				var nested = getNestedContext(c), i = 0;
				try {
					switch follow(s2.ret) {
						case TAbstract(ab, _) if (pathIs(ab.aPath, "", "Void")): i++;
						case _:
							unifyCustom(nested, s1.ret, s2.ret);
							i++;
					}
					List.iter2(function(v1, v2) {
						if (v1.optional && !v2.optional) error([
							CannotUnify(v1.type, v2.type),
							NotMatchingOptional(v1.optional, v2.optional, v1.name)
						]);
						unifyCustom(nested, v1.type, v2.type);
						i++;
					}, s2.args, s1.args); // contravariance
				} catch (e:Unify_error) {
					error([
						cannotUnify(a, b),
						i == 0 ? InvalidReturnType : InvalidFunctionArgument(i, s1.args.length)
					].concat(e.errors));
				}
			case [TInst(cl, tl), TAnon(an)]:
				if (PMap.isEmpty(an.aFields)) switch cl.clKind {
					// one of the constraints must unify with { }
					case KTypeParameter(p): if (!core.ds.ArrayTools.exists(getConstraints(p), function(t) return switch follow(t) {
							case TInst(_, _), TAnon(_): true;
							case _: false;
						})) error([cannotUnify(a, b)]);
					case _:
				}
				cl.clBuild();
				try {
					PMap.iter(function(n, f2) {
						// introducing monomorphs while unifying might create infinite loops - see #2315
						// let's store these monomorphs and make sure we reach a fixed point
						var monos:Array<T> = [];
						function makeType(f:TClassField):T {
							if (c.opaqueFieldParams || f.cfParams.length == 0) return f.cfType;
							var ml = f.cfParams.map(function(_) return mkMono());
							monos = ml;
							return applyParams(f.cfParams, ml, f.cfType);
						}
						var found = try {
							rawClassField(makeType, cl, tl, n);
						} catch (_:NotFound) {
							error([hasNoField(a, n)]);
						};
						var f1 = found.field,
							ft = applyParams(cl.clParams, tl, found.type);
						if (!unifyKind(c, f1.cfKind, f2.cfKind)) error([invalidKind(n, f1.cfKind, f2.cfKind)]);
						if (hasClassFieldFlag(f2, CfPublic) && !hasClassFieldFlag(f1, CfPublic)) error([invalidVisibility(n)]);
						switch f2.cfKind {
							case Var({vRead: AccNo}), Var({vRead: AccNever}):
								// we will do a recursive unification, so let's check for possible recursion
								var old = c.unifyNewMonos;
								c.unifyNewMonos = monos.concat(old);
								recStack(c.unifyStack, pair(ft, f2.cfType),
									function(p) return fastEq(p.b, f2.cfType) && fastEqMono(c.unifyNewMonos, ft, p.a), function() {
										try {
											unifyWithAccess(c, f1, ft, f2);
										} catch (e:haxe.Exception) {
											c.unifyNewMonos = old;
											throw e;
										}
								}, function(l) error([invalidField(n)].concat(l)));
								c.unifyNewMonos = old;
							case Method(MethNormal), Method(MethInline), Var({vWrite: AccNo}), Var({vWrite: AccNever}):
								// same as before, but unification is reversed (read-only var)
								var old = c.unifyNewMonos;
								c.unifyNewMonos = monos.concat(old);
								recStack(c.unifyStack, pair(f2.cfType, ft),
									function(p) return fastEqMono(c.unifyNewMonos, p.b, ft) && fastEq(f2.cfType, p.a), function() {
										try {
											unifyWithAccess(c, f1, ft, f2);
										} catch (e:haxe.Exception) {
											c.unifyNewMonos = old;
											throw e;
										}
								}, function(l) error([invalidField(n)].concat(l)));
								c.unifyNewMonos = old;
							case _:
								// will use fast_eq, which have its own stack
								try {
									unifyWithAccess(c, f1, ft, f2);
								} catch (e:Unify_error) {
									error([invalidField(n)].concat(e.errors));
								}
						}
						for (f2o in f2.cfOverloads) if (!core.ds.ArrayTools.exists([f1].concat(f1.cfOverloads),
							function(f1o) return typeIseqCustom(c, f1o.cfType, f2o.cfType))) error([MissingOverload(f1, f2o.cfType)]);
						// we mark the field as :?used because it might be used through the structure
						if (maybeUsedHook != null) maybeUsedHook(cl, f1, f2);
						if (!hasClassFieldFlag(f1, CfMaybeUsed)) {
							addClassFieldFlag(f1, CfMaybeUsed);
							switch f2.cfKind {
								case Var(v):
									inline function check(name:String):Void try {
										addClassFieldFlag(rawClassField(makeType, cl, tl, name).field, CfMaybeUsed);
									} catch (_:NotFound) {}
									switch v.vRead {
										case AccCall, AccPrivateCall: check("get_" + f1.cfName);
										case _:
									}
									switch v.vWrite {
										case AccCall, AccPrivateCall: check("set_" + f1.cfName);
										case _:
									}
								case _:
							}
						}
						switch f1.cfKind {
							case Method(MethInline):
								if ((hasClassFlag(cl, CExtern) || hasClassFieldFlag(f1, CfExtern))
									&& !MetadataTools.has(Runtime, f1.cfMeta)) error([HasNoRuntimeField(a, n)]);
							case _:
						}
					}, an.aFields);
					switch an.aStatus {
						case ClassStatics(_), EnumStatics(_), AbstractStatics(_): error([]);
						case Closed, Extend(_), Const:
					}
				} catch (e:Unify_error) {
					error([cannotUnify(a, b)].concat(e.errors));
				}
			case [TAnon(a1), TAnon(a2)]:
				unifyAnons(c, a, b, a1, a2);
			case [TAnon(an), TAbstract(ab, [pt])] if (pathIs(ab.aPath, "", "Class")):
				switch an.aStatus {
					case ClassStatics(cl): unifyCustom(c, TInst(cl, cl.clParams.map(function(_) return mkMono())), pt);
					case _: error([cannotUnify(a, b)]);
				}
			case [TAnon(an), TAbstract(ab, [pt])] if (pathIs(ab.aPath, "", "Enum")):
				switch an.aStatus {
					case EnumStatics(en): unifyCustom(c, TEnum(en, en.eParams.map(function(_) return mkMono())), pt);
					case _: error([cannotUnify(a, b)]);
				}
			case [TEnum(_, _), TAbstract(ab, [])] if (pathIs(ab.aPath, "", "EnumValue")):
			case [TEnum(en, _), TAbstract(ab, [])] if (pathIs(ab.aPath, "haxe", "FlatEnum") && MetadataTools.has(FlatEnum, en.eMeta)):
			case [TFun(_), TAbstract(ab, [])] if (pathIs(ab.aPath, "haxe", "Function")):
			case [TInst(cl, tl), TAbstract(ab, [t1])] if (pathIs(ab.aPath, "haxe", "Constructible")):
				try {
					switch cl.clKind {
						// type parameters require an equal Constructible constraint
						case KTypeParameter(p): if (!core.ds.ArrayTools.exists(getConstraints(p), function(t) return switch follow(t) {
								case TAbstract(ab, [t2]) if (pathIs(ab.aPath, "haxe", "Constructible")): typeIseqCustom(c, t1, t2);
								case _: false;
							})) error([cannotUnify(a, b)]);
						case _:
							var found = classField(cl, tl, "new");
							if (!hasClassFieldFlag(found.field, CfPublic)) error([invalidVisibility("new")]);
							try {
								unifyCustom(c, found.type, t1);
							} catch (e:Unify_error) {
								error([cannotUnify(a, b)].concat(e.errors));
							}
					}
				} catch (_:NotFound) {
					error([hasNoField(a, "new")]);
				}
			case [TDynamic(null), _]:
				if (!c.allowDynamicToCast) switch b {
					case TDynamic(null):
					case _: error([cannotUnify(a, b)]);
				}
			case [TDynamic(t1), _] if (t1 != null):
				switch b {
					case TDynamic(null):
					case TDynamic(t2): if (t2 != t1) try {
							typeEqCustom(core.ds.Record.withFields(c, {equalityKind: EqRightDynamic}), t1, t2);
						} catch (e:Unify_error) {
							error([cannotUnify(a, b)].concat(e.errors));
						}
					case TAbstract(bb, tl): unifyFrom(c, a, b, bb, tl);
					case _: error([cannotUnify(a, b)]);
				}
			case [_, TDynamic(null)]:
				if (c.equalityKind == EqStricter) error([cannotUnify(a, b)]);
			case [_, TDynamic(t1)] if (t1 != null):
				switch a {
					case TAnon(an): try {
							switch an.aStatus {
								case ClassStatics(_), EnumStatics(_): error([]);
								case _:
							}
							PMap.iter(function(_, f) {
								try {
									typeEqCustom(c, fieldTypeForUnification(c, f), t1);
								} catch (e:Unify_error) {
									error([invalidField(f.cfName)].concat(e.errors));
								}
							}, an.aFields);
						} catch (e:Unify_error) {
							error([cannotUnify(a, b)].concat(e.errors));
						}
					case TAbstract(aa, tl): unifyTo(c, a, b, aa, tl);
					case _: error([cannotUnify(a, b)]);
				}
			case [TAbstract(aa, tl), _]:
				unifyTo(c, a, b, aa, tl);
			case [TInst(cl, pl), TAbstract(bb, tl)] if (switch cl.clKind {
					case KTypeParameter(_): true;
					case _: false;
				}):
				var p = switch cl.clKind {
					case KTypeParameter(p): p;
					case _: Globals.die("", "tUnification.ml");
				};
				// one of the constraints must satisfy the abstract
				if (!core.ds.ArrayTools.exists(getConstraints(p), function(t) {
					var t = applyParams(cl.clParams, pl, t);
					try {
						unifyCustom(c, t, b);
						return true;
					} catch (_:Unify_error) {
						return false;
					}
				})) unifyFrom(c, a, b, bb, tl);
			case [_, TAbstract(bb, tl)]:
				unifyFrom(c, a, b, bb, tl);
			case _:
				error([cannotUnify(a, b)]);
		}
	}

	public static function unifyAnons(c:UnificationContext, a:T, b:T, a1:TAnon, a2:TAnon):Void {
		inline function unifyField(fields:TypeMap<TClassField>, f2:TClassField):TClassField {
			var n = f2.cfName, f1 = PMap.find(n, fields);
			if (!unifyKind(c, f1.cfKind, f2.cfKind)) error([invalidKind(n, f1.cfKind, f2.cfKind)]);
			if (hasClassFieldFlag(f2, CfPublic) && !hasClassFieldFlag(f1, CfPublic)) error([invalidVisibility(n)]);
			try {
				var t = fastEq(f1.cfType, f2.cfType) ? f1.cfType : fieldTypeForUnification(c, f1);
				unifyWithAccess(c, f1, t, f2);
				return f1;
			} catch (e:Unify_error) {
				return error([invalidField(n)].concat(e.errors));
			}
		}
		inline function unifyFields(fields:TypeMap<TClassField>, good:TClassField->Void, bad:TClassField->Bool):Void {
			try {
				PMap.iter(function(_, f2) {
					try {
						good(unifyField(fields, f2));
					} catch (_:NotFound) {
						if (!bad(f2)) error([hasNoField(a, f2.cfName)]);
					}
				}, a2.aFields);
			} catch (e:Unify_error) {
				error([cannotUnify(a, b)].concat(e.errors));
			}
		}
		switch [a1.aStatus, a2.aStatus] {
			case [ClassStatics(c1), ClassStatics(c2)] if (c1 == c2):
			case [EnumStatics(e1), EnumStatics(e2)] if (e1 == e2):
			case [AbstractStatics(ab1), AbstractStatics(ab2)] if (ab1 == ab2):
			case [Const, _]:
				unifyFields(a1.aFields, function(_) {}, function(f2) {
					if (MetadataTools.has(Optional, f2.cfMeta)) {
						a1.aFields = PMap.add(f2.cfName, f2, a1.aFields);
						return true;
					}
					return false;
				});
			case [ClassStatics(c1), _]:
				unifyFields(c1.clStatics, function(f1) {
					if (maybeUsedHook != null) maybeUsedHook(null, f1, null);
					addClassFieldFlag(f1, CfMaybeUsed);
				}, function(_) return false);
			case _:
				unifyFields(a1.aFields, function(_) {}, function(_) return false);
		}
	}

	public static function doesFuncUnify(f:Void->Void):Bool {
		try {
			f();
			return true;
		} catch (_:Unify_error) {
			return false;
		}
	}

	public static function doesFuncUnifyArg<A>(f:A->Void, arg:A):Bool {
		try {
			f(arg);
			return true;
		} catch (_:Unify_error) {
			return false;
		}
	}

	public static function getAbstractContext(c:UnificationContext, a:T, b:T, ab:TAbstract):UnificationContext {
		if (MetadataTools.has(CoreType, ab.aMeta) || MetadataTools.has(Transitive, ab.aMeta)) return c;
		if (c.allowAbstractCast) return core.ds.Record.withFields(c, {allowAbstractCast: false});
		return error([cannotUnify(a, b)]);
	}

	public static function getNestedContext(c:UnificationContext):UnificationContext return core.ds.Record.withFields(c,
		{allowAbstractCast: true});

	public static function unifiesWithAbstract(c:UnificationContext, a:T, b:T,
			f:UnificationContext->Bool):Bool return recStackDefault(c.abstractCastStack, pair(a, b),
			function(p) return fastEqPair(pair(a, b), p), function() return (c.allowTransitiveCast && f(core.ds.Record.withFields(c, {
				allowTransitiveCast: false
			}))) || f(c), false);

	public static function getAbstractUnifyFunc(c:UnificationContext,
			kind:EqKind):T->T->Void return c.allowTransitiveCast ? function(a,
				b) unifyCustom(c, a, b) : function(a, b) typeEqCustom(core.ds.Record.withFields(c, {
				equalityKind: kind
			}), a, b);

	public static function unifyAbstracts(c:UnificationContext, a:T, b:T, a1:TAbstract, tl1:Array<T>, a2:TAbstract, tl2:Array<T>):Void {
		if (!unifiesAbstracts(c, a, b, a1, tl1, a2, tl2)) error([cannotUnify(a, b)]);
	}

	public static function unifyFrom(c:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>):Void {
		if (!unifiesFrom(c, a, b, ab, tl)) error([cannotUnify(a, b)]);
	}

	public static function unifyTo(c:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>):Void {
		if (!unifiesTo(c, a, b, ab, tl)) error([cannotUnify(a, b)]);
	}

	public static function unifiesAbstracts(c:UnificationContext, a:T, b:T, a1:TAbstract, tl1:Array<T>, a2:TAbstract,
			tl2:Array<T>):Bool return unifiesWithAbstract(c, a, b,
			function(c) return core.ds.ArrayTools.exists(a1.aTo, function(t) return unifiesToDirect(c, a, b, a1, tl1, t))
				|| core.ds.ArrayTools.exists(a2.aFrom, function(t) return unifiesFromDirect(c, a, b, a2, tl2, t)));

	public static function unifiesFrom(c:UnificationContext, a:T, b:T, ab:TAbstract,
			tl:Array<T>):Bool return unifiesWithAbstract(c, a, b,
			function(c) return core.ds.ArrayTools.exists(ab.aFrom, function(t) return unifiesFromDirect(c, a, b, ab, tl, t)));

	public static function unifiesTo(c:UnificationContext, a:T, b:T, ab:TAbstract,
			tl:Array<T>):Bool return unifiesWithAbstract(c, a, b,
			function(c) return core.ds.ArrayTools.exists(ab.aTo, function(t) return unifiesToDirect(c, a, b, ab, tl, t)));

	public static function unifiesFromDirect(c:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>,
			t:T):Bool return doesFuncUnify(function() {
			var t = applyParams(ab.aParams, tl, t),
				c = getAbstractContext(c, a, b, ab),
				f = getAbstractUnifyFunc(c, EqRightDynamic);
			f(a, t);
		});

	public static function unifiesToDirect(c:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>,
			t:T):Bool return doesFuncUnify(function() {
			var t = applyParams(ab.aParams, tl, t),
				c = getAbstractContext(c, a, b, ab),
				f = getAbstractUnifyFunc(c, EqStrict);
			f(t, b);
		});

	public static function unifiesFromField(c:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>,
			entry:{type:T, field:TClassField}):Bool return doesFuncUnify(function() {
			var cf = entry.field;
			switch follow(cf.cfType) {
				case TFun(s):
					var baseMap = function(t) return applyParams(ab.aParams, tl, t), map = baseMap;
					if (!c.opaqueFieldParams) {
						var monos = Monomorph.spawnConstrainedMonos(baseMap, cf.cfParams);
						map = function(t) return baseMap(applyParams(cf.cfParams, monos, t));
					}
					var c = getAbstractContext(c, a, b, ab),
						f = getAbstractUnifyFunc(c, EqStrict);
					f(a, map(entry.type));
					f(map(s.ret), b);
				case _:
					Globals.die("", "tUnification.ml");
			}
		});

	public static function unifiesToField(c:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>,
			entry:{type:T, field:TClassField}):Bool return doesFuncUnify(function() {
			var cf = entry.field;
			switch follow(cf.cfType) {
				case TFun(s) if (s.args.length > 0):
					var ta = s.args[0].type, baseMap = function(t) return applyParams(ab.aParams, tl, t), map = baseMap;
					if (!c.opaqueFieldParams) {
						var monos = Monomorph.spawnConstrainedMonos(baseMap, cf.cfParams);
						map = function(t) return baseMap(applyParams(cf.cfParams, monos, t));
					}
					var c = getAbstractContext(c, a, b, ab),
						f = getAbstractUnifyFunc(c, EqStrict),
						athis = map(ab.aThis);
					// we cannot allow implicit casts when the this type is not completely known yet
					if (MetadataTools.has(MultiType, ab.aMeta) && hasMono(athis)) throw new Unify_error([]);
					withVariance(c, function(a, b) typeEqCustom(core.ds.Record.withFields(c, {equalityKind: EqStrict}), a, b), athis,
						map(ta));
					f(map(entry.type), b);
				case _:
					Globals.die("", "tUnification.ml");
			}
		});

	public static function unifyWithVariance(c:UnificationContext, f:T->T->Void, t1:T, t2:T):Void {
		t1 = followWithoutType(t1);
		t2 = followWithoutType(t2);
		inline function fail():Void error([cannotUnify(t1, t2)]);
		inline function unifyRec(f:Void->Void):Void recStack(c.varianceStack, pair(t1, t2),
			function(p) return fastEqPair(pair(t1, t2), p), f, function(_) fail());
		function unifyNested(t1:T, t2:T):Void withVariance(getNestedContext(c), f, t1, t2);
		inline function unifyTls(tl1:Array<T>, tl2:Array<T>):Void List.iter2(unifyNested, tl1, tl2);
		inline function thisType(ab:TAbstract, tl:Array<T>):T return followWithoutType(applyParams(ab.aParams, tl, ab.aThis));
		inline function definedType(td:TDef, tl:Array<T>):T return followWithoutType(applyTypedef(td, tl));
		inline function compareUnderlying():Void typeEqCustom(core.ds.Record.withFields(c,
			{equalityUnderlying: true, equalityKind: EqBothDynamic}), t1, t2);
		inline function unifiesAbstract(c:UnificationContext, a:T, b:T, ab:TAbstract, tl:Array<T>, ats:Array<T>):Bool {
			try {
				var c = getAbstractContext(c, a, b, ab);
				return recStackDefault(c.abstractCastStack, pair(a, b), function(p) return fastEqPair(pair(a, b), p),
					function() return core.ds.ArrayTools.exists(ats, function(at) return doesFuncUnifyArg(function(at) {
						var at = applyParams(ab.aParams, tl, at);
						if (ats == ab.aTo) withVariance(c, f, at, b);
						else withVariance(c, f, a, at);
					}, at)), false);
			} catch (_:Unify_error) {
				return false;
			}
		}
		switch [t1, t2] {
			case [TInst(c1, tl1), TInst(c2, tl2)] if (c1 == c2):
				unifyTls(tl1, tl2);
			case [TEnum(e1, tl1), TEnum(e2, tl2)] if (e1 == e2):
				unifyTls(tl1, tl2);
			case [TAbstract(a1, tl1), TAbstract(a2, tl2)] if (a1 == a2):
				unifyTls(tl1, tl2);
			case [TType(td1, tl1), TType(td2, tl2)] if (td1 == td2):
				unifyTls(tl1, tl2);
			case [TType(td, tl), _]:
				unifyRec(function() unifyWithVariance(c, f, definedType(td, tl), t2));
			case [_, TType(td, tl)]:
				unifyRec(function() unifyWithVariance(c, f, t1, definedType(td, tl)));
			case [TAbstract(ab, tl), _] if (MetadataTools.has(ForwardVariance, ab.aMeta)):
				withVariance(c, f, thisType(ab, tl), t2);
			case [_, TAbstract(ab, tl)] if (MetadataTools.has(ForwardVariance, ab.aMeta)):
				withVariance(c, f, t1, thisType(ab, tl));
			case [TAbstract(a1, tl1), TAbstract(a2, tl2)]:
				if (!unifiesAbstract(c, t1, t2, a1, tl1, a1.aTo) && !unifiesAbstract(c, t1, t2, a2, tl2, a2.aFrom)) fail();
				compareUnderlying();
			case [TAbstract(ab, tl), _]:
				if (!unifiesAbstract(c, t1, t2, ab, tl, ab.aTo)) fail();
				compareUnderlying();
			case [_, TAbstract(ab, tl)]:
				if (!unifiesAbstract(c, t1, t2, ab, tl, ab.aFrom)) fail();
				compareUnderlying();
			case [TAnon(a1), TAnon(a2)]:
				unifyAnons(c, t1, t2, a1, a2);
			case [TFun(s1), TFun(s2)] if (s1.args.length == s2.args.length):
				List.iter2(function(a, b) unifyNested(a.type, b.type), s1.args, s2.args);
				unifyNested(s1.ret, s2.ret);
			case _:
				fail();
		}
	}

	public static function unifyTypeParams(c:UnificationContext, a:T, b:T, tl1:Array<T>, tl2:Array<T>):Void {
		var c = getNestedContext(c), i = 0;
		List.iter2(function(t1, t2) {
			i++;
			try {
				withVariance(c, function(a, b) typeEqCustom(core.ds.Record.withFields(c, {equalityKind: EqRightDynamic}), a, b), t1, t2);
			} catch (e:Unify_error) {
				error([cannotUnify(a, b), InvariantParameter(i)].concat(e.errors));
			}
		}, tl1, tl2);
	}

	public static function withVariance(c:UnificationContext, f:T->T->Void, t1:T, t2:T):Void {
		try {
			f(t1, t2);
		} catch (first:Unify_error) {
			try {
				unifyWithVariance(c, f, t1, t2);
			} catch (_:Unify_error) {
				throw first;
			}
		}
	}

	public static function unifyWithAccess(c:UnificationContext, f1:TClassField, t1:T, f2:TClassField):Void {
		var c = getNestedContext(c);
		switch f2.cfKind {
			// write only
			case Var({vRead: AccNo}), Var({vRead: AccNever}):
				unifyCustom(c, f2.cfType, t1);
			// read only
			case Method(MethNormal), Method(MethInline), Var({vWrite: AccNo}), Var({vWrite: AccNever}):
				var final1 = hasClassFieldFlag(f1, CfFinal),
					final2 = hasClassFieldFlag(f2, CfFinal);
				if (final1 != final2 && !c.allowFinalInvariance) throw new Unify_error([CannotUnify(f2.cfType,
					f1.cfType), FinalInvariance(final2, final1)]);
				unifyCustom(c, t1, f2.cfType);
			// read/write
			case _:
				withVariance(c, function(a, b) typeEqCustom(core.ds.Record.withFields(c, {equalityKind: EqBothDynamic}), a, b), t1,
					f2.cfType);
		}
	}

	public static function doesUnify(a:T, b:T):Bool return doesFuncUnify(function() unifyCustom(defaultUnificationContext(), a, b));

	public static function unify(a:T, b:T):Void unifyCustom(defaultUnificationContext(), a, b);

	public static function typeEq(kind:EqKind, a:T,
			b:T):Void typeEqCustom(core.ds.Record.withFields(defaultUnificationContext(), {equalityKind: kind}), a, b);

	public static function typeIseq(a:T, b:T):Bool return typeIseqCustom(defaultUnificationContext(), a, b);

	public static function initHooks():Void TFunctions.monomorphClassifyConstraintsRef = Monomorph.classifyDownConstraints;

	static function __init__():Void initHooks();
}

class UnifyMinT {
	public static function collectBaseTypes(t:T):Array<T> {
		var tl:Array<T> = [];
		function loop(t:T):Void switch t {
			case TInst(cl, params):
				switch cl.clKind {
					case KTypeParameter(p): for (t in getConstraints(p)) loop(t);
					case _:
				}
				for (s in cl.clImplements) loop(applyParams(cl.clParams, params, TInst(s.cls, s.params)));
				if (cl.clSuper != null) {
					var s = cl.clSuper;
					loop(applyParams(cl.clParams, params, TInst(s.cls, s.params)));
				}
				tl.unshift(t);
			case TType(td, pl):
				loop(applyTypedef(td, pl));
				// prioritize the most generic definition
				tl.unshift(t);
			case TLazy(f):
				loop(lazyType(f));
			case TMono(m):
				if (m.tmType != null) loop(m.tmType);
			case _:
				tl.unshift(t);
		}
		loop(t);
		return tl;
	}

	public static function unifyMinPrime(c:UnificationContext, commonTypes:Array<T>, tl:Array<T>):UnifyMinResult {
		var first:Null<{errors:Array<UnifyError>, index:Int}> = null, index = 0;
		for (t in tl) {
			commonTypes = commonTypes.filter(function(candidate) {
				try {
					unifyCustom(c, t, candidate);
					return true;
				} catch (e:Unify_error) {
					if (first == null) first = {errors: e.errors, index: index};
					return false;
				}
			});
			index++;
		}
		if (commonTypes.length > 0) return UnifyMinOk(commonTypes[0]);
		return first == null ? UnifyMinError([UnifyCustom("Could not determine common type, please add a type-hint")],
			0) : UnifyMinError(first.errors, first.index);
	}

	public static function unifyMin(c:UnificationContext, t0:T,
			tl:Array<T>):UnifyMinResult return tl.length == 0 ? UnifyMinOk(t0) : unifyMinPrime(c, collectBaseTypes(t0), tl);
}

enum UnificationMatrixState {
	STop;
	SType(t:T);
	SBottom;
}

class UnificationMatrix {
	var values:Array<UnificationMatrixState>;

	public function new(arity:Int) values = [for (_ in 0...arity) STop];

	public function join(t:T, at:Int):Void switch values[at] {
		case STop:
			values[at] = SType(t);
		case SBottom:
		case SType(other):
			if (!typeIseq(t, other)) values[at] = SBottom;
	}

	public function getType(at:Int):Null<T> return switch values[at] {
		case SType(t): t;
		case _: null;
	};

	public function dump():String {
		var ctx = printContext();
		return values.map(function(v) return switch v {
			case STop: "STop";
			case SType(t): "SType " + sType(ctx, t);
			case SBottom: "SBottom";
		}).join(" ; ");
	}
}
