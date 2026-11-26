package hxmc.es;

import core.TType;
import core.TFunctions.*;

// Where a value of one Haxe type goes where Haxe accepted it but TypeScript would not (`untyped` code, a cast, a
// GADT's type parameter, an extern's signature): the lowering marks it (JAs), TypeScript's output casts it
// (`(e as any)`). Types as TypeScript has them (Dts.type): what it has as `any` takes anything; numbers, strings,
// booleans, classes, enums and type parameters are TypeScript's to compare, structures and functions are assumed
// to agree, as Haxe's do.
class Casts {
	// whether a value of type `from` needs a cast to go where `to` is expected
	public static function need(from:T, to:T, depth = 0):Bool {
		// (recursive types: as far as it matters)
		if (depth > 8) return false;
		var a = kind(from), b = kind(to);
		return switch [a, b] {
			// (a class or enum as a value: `any` to TypeScript, as Dts types it)
			case [KAny | KType, _] | [_, KAny | KType]: false;
			// (an abstract: another's only by a cast; its underlying type where it is `to` it, a `from` type's value where it is
			// `from` it, as the brand has them)
			case [KAbstract(x), KAbstract(y)]: x != y;
			case [KAbstract(x), _]: !toThis(x) || need(underlying(from), to, depth + 1);
			case [_, KAbstract(y)]: !Lambda.exists(froms(to), f -> !need(from, f, depth + 1));
			// (a structure with a field the other has not: TypeScript checks an object literal's, Haxe let it)
			case [KOther, KOther]: extraFields(from, to) || ((mentionsBranded(from, 0) || mentionsBranded(to, 0)) && fieldsNeed(from, to, depth));
			// (a structure or function as a class's value: Haxe's classes are nominal, a cast made it one)
			case [KOther, KClass(_)]: true;
			// (a structure as a primitive, or the other way around: only a cast does that)
			case [KOther, KNumber | KString | KBool | KArray | KEnum(_)] | [KNumber | KString | KBool, KOther]: true;
			// (an array as a structure: TypeScript's arrays have not Haxe's fields; an instance as a structure of a type
			// parameter, which Haxe bound and TypeScript does not)
			case [KArray, KOther]: !to.match(TType({tPath: {pack: [], name: "Iterable"}}, _));
			case [KClass(_), KOther]: mentionsParam(to, 0) || mentionsBranded(to, 0);
			case [KOther, _] | [_, KOther]: false;
			case [KParam(x), KParam(y)]: x != y;
			case [_, KParam(_)] | [KParam(_), _]: true;
			case [KNumber, KNumber] | [KString, KString] | [KBool, KBool]: false;
			// (and their type arguments: Haxe's are the same but where a cast made them otherwise)
			case [KArray, KArray]: args(from, to, depth);
			case [KClass(c), KClass(d)]: !extendsClass(c, d) || (c == d && args(from, to, depth));
			case [KEnum(e), KEnum(f)]: e != f || args(from, to, depth);
			case [KEnum(_) | KEnumValue, KEnumValue]: false;
			case _: true;
		}
	}

	// An abstract is a type of its own to TypeScript (a brand, Ts.abstractDecl), but for the std's core types and the
	// abstracts TypeScript could not tell apart (an extern's, a multi-type's: Map, whose values are its specializations'):
	// as Haxe has it, a value of its underlying type goes where it is `from` it, and it where it is `to` it.
	public static function branded(a:TAbstract):Bool {
		var m = a.aMeta;
		return !core.Meta.has(core.Meta.CoreType, m) && !core.Meta.has(core.Meta.MultiType, m) && !core.Meta.has(core.Meta.Extern, m)
			&& !(a.aPath.pack.length == 0 && a.aPath.name == "EnumValue")
			// (one over Dynamic, Any: nothing to tell apart; the std's constraints, haxe.Constructible, haxe.Function)
			&& !isDynamic(a.aThis) && !follow(a.aThis).match(TAbstract({aPath: {pack: [], name: "Any"}}, _))
			// (a rest argument's: JavaScript's rest parameter, an array)
			&& !(a.aPath.pack.length == 1 && a.aPath.pack[0] == "haxe" && a.aPath.name == "Rest");
	}

	// whether a value of t is an abstract's TypeScript has as no value of its underlying type (it is not `to` it): what
	// JavaScript does with the value (index it, call it, compute with it, iterate it), only cast
	public static function opaque(t:T):Bool return switch kind(t) {
		case KAbstract(a): !toThis(a);
		case _: false;
	}

	// (an enum abstract) its values, as TypeScript's literals (`0`, `"a"`), or null: one not a constant, or not an enum abstract
	// (as typing left them, before DCE removes the fields it inlined: recordEnums)
	public static function enumValues(a:TAbstract):Null<Array<String>> return enums.get(a);

	static final enums = new haxe.ds.ObjectMap<TAbstract, Array<String>>();
	static var named:Array<{name:String, c:TConstant}> = [];

	// (after typing) the enum abstracts' values
	public static function recordEnums(types:Array<ModuleType>) {
		enums.clear();
		literals.clear();
		fields.clear();
		for (t in types) switch t {
			case TAbstractDecl(a) if (a.aEnum && a.aImpl != null):
				named = [];
				var v = valuesOf(a.aImpl);
				if (v != null) {
					enums.set(a, v);
					fields.set(a, named);
				}
			case _:
		}
	}

	// (an enum abstract) its values' names and constants, in order, as recordEnums had them
	public static function enumFields(a:TAbstract):Array<{name:String, c:TConstant}> return fields.get(a) ?? [];

	static final fields = new haxe.ds.ObjectMap<TAbstract, Array<{name:String, c:TConstant}>>();

	static function valuesOf(impl:TClass):Null<Array<String>> {
		var out = [];
		for (f in impl.clStatics) if (core.Meta.has(core.Meta.Enum, f.cfMeta) && f.cfKind.match(Var(_))) {
			var c = constOf(f.cfExpr);
			var l = c == null ? null : literalOf(c);
			if (l == null) return null;
			out.push(l);
			literals.set(f, c);
			named.push({name: f.cfName, c: c});
		}
		return out.length == 0 ? null : out;
	}

	// (an enum abstract's value) its constant, as recordEnums had it
	public static function enumConst(f:TClassField):Null<TConstant> return literals.get(f);

	static final literals = new haxe.ds.ObjectMap<TClassField, TConstant>();

	static function constOf(e:Null<TExpr>):Null<TConstant> {
		while (e != null && e.eexpr.match(TCast(_, _) | TParenthesis(_) | TMeta(_, _))) e = switch e.eexpr {
			case TCast(x, _) | TParenthesis(x) | TMeta(_, x): x;
			case _: e;
		}
		return switch e == null ? null : e.eexpr {
			case TConst(c): c;
			case _: null;
		}
	}

	// a constant as TypeScript's literal type (`0`, `"a"`)
	public static function literalOf(c:TConstant):Null<String> return switch c {
		case TInt(i): Std.string(i);
		case TFloat(s): s;
		case TString(s): Printer.quote(s);
		case TBool(b): b ? "true" : "false";
		case TNull: "null";
		case _: null;
	}

	// whether an abstract is `to` its underlying type, `from` it (directly: not through a function, @:to, @:from)
	public static function toThis(a:TAbstract):Bool return Lambda.exists(a.aTo, t -> isThis(a, t));

	public static function fromThis(a:TAbstract):Bool return Lambda.exists(a.aFrom, t -> isThis(a, t));

	public static function isThis(a:TAbstract, t:T):Bool return core.TUnification.fastEq(follow(t), follow(a.aThis));

	// an abstract's type's underlying type, of its arguments
	public static function underlying(t:T):T return switch follow(t) {
		case TAbstract({aPath: {pack: [], name: "Null"}}, [p]): underlying(p);
		case TAbstract(a, ps): applyParams(a.aParams, ps, a.aThis);
		case t: t;
	}

	// the types whose values go where an abstract's type is (its `from` types, of its arguments)
	static function froms(t:T):Array<T> return switch follow(t) {
		case TAbstract({aPath: {pack: [], name: "Null"}}, [p]): froms(p);
		case TAbstract(a, ps): [for (f in a.aFrom) applyParams(a.aParams, ps, f)];
		case _: [];
	}

	// (structures, functions: of their fields', results', arguments' types, one needing a cast)
	static function fieldsNeed(from:T, to:T, depth:Int):Bool return switch [follow(from), follow(to)] {
		case [TAnon(a), TAnon(b)]:
			var found = false;
			b.aFields.iter((n, g) -> if (!found && a.aFields.exists(n) && need(a.aFields.get(n).cfType, g.cfType, depth + 1)) found = true);
			found;
		case [TFun(s), TFun(t)]:
			if (need(s.ret, t.ret, depth + 1)) return true;
			for (i in 0...s.args.length) if (i < t.args.length && need(t.args[i].type, s.args[i].type, depth + 1)) return true;
			false;
		case _: false;
	}

	// (a structure that has a branded abstract: a class's value, which Haxe let be one, TypeScript checks against it)
	static function mentionsBranded(t:T, depth:Int):Bool {
		if (depth > 6) return false;
		return switch follow(t) {
			case TAbstract(a, _) if (branded(a)): true;
			case TAnon(a): Lambda.exists(a.aFields, f -> mentionsBranded(f.cfType, depth + 1));
			case TFun(s):
				if (mentionsBranded(s.ret, depth + 1)) return true;
				for (a in s.args) if (mentionsBranded(a.type, depth + 1)) return true;
				false;
			case _: false;
		}
	}

	// whether a literal (a number, a string, an object, an array) of type t needs a cast: t a branded abstract's, but one
	// `from` its underlying type
	public static function literalCast(t:T):Bool return switch kind(t) {
		case KAbstract(a): !fromThis(a);
		case _: false;
	}

	static function mentionsParam(t:T, depth:Int):Bool {
		if (depth > 6) return false;
		return switch follow(t) {
			case TInst({clKind: KTypeParameter(_)}, _): true;
			case TAnon(a): Lambda.exists(a.aFields, f -> mentionsParam(f.cfType, depth + 1));
			case TFun(s):
				if (mentionsParam(s.ret, depth + 1)) return true;
				for (a in s.args) if (mentionsParam(a.type, depth + 1)) return true;
				false;
			case _: false;
		}
	}

	static function extraFields(from:T, to:T, depth = 0):Bool {
		if (depth > 4) return false;
		return switch [follow(from), follow(to)] {
			case [TAnon(a), TAnon(b)] if (!b.aFields.isEmpty()):
				// (and in the structures of its fields: object literals in it)
				var extra = false;
				a.aFields.iter((n, f) -> if (!b.aFields.exists(n)) extra = true else if (extraFields(f.cfType, b.aFields.get(n).cfType, depth + 1)) extra = true);
				// (or without one the other requires, or has as optional: a cast's)
				inline function optional(f:TClassField) return core.Meta.has(core.Meta.Optional, f.cfMeta);
				b.aFields.iter((n, g) -> if (!optional(g) && (!a.aFields.exists(n) || optional(a.aFields.get(n)))) extra = true);
				extra;
			case _: false;
		}
	}

	// whether a type argument of from needs a cast to to's (the same class or enum)
	static function args(from:T, to:T, depth:Int):Bool {
		function params(t:T, depth = 0):Array<T> return depth > 20 ? [] : switch follow(t) {
			case TInst(_, p) | TEnum(_, p): p.toArray();
			case TAbstract({aPath: {pack: [], name: "Null"}}, [p]): params(p, depth + 1);
			// (as kind has it: what it stands for)
			case TAbstract(a, []) if (!core.Meta.has(core.Meta.CoreType, a.aMeta)): params(a.aThis, depth + 1);
			case _: [];
		}
		var a = params(from), b = params(to);
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (need(a[i], b[i], depth + 1)) return true;
		return false;
	}

	// whether TypeScript has a value of t as `any` (Dynamic, unknown)
	public static function isDynamic(t:T):Bool return switch t {
		case TMono(m): m.tmType == null || follow(m.tmType).match(TAnon(_)) || isDynamic(m.tmType);
		case TLazy(l): isDynamic(lazyType(l));
		case TType(_, _): isDynamic(follow(t));
		case TDynamic(_): true;
		case TAbstract({aPath: {pack: [], name: "Null"}}, [p]): isDynamic(p);
		case _: false;
	}

	// whether TypeScript has a value of t as `any` (as Dts types it)
	public static function tsAny(t:T):Bool return kind(t).match(KAny);

	// an enum, or an enum abstract (its values constants TypeScript narrows)
	public static function enumLike(t:T):Bool return switch follow(t) {
		case TEnum(_, _): true;
		case TAbstract({aPath: {pack: [], name: "Null"}}, [p]): enumLike(p);
		case TAbstract(a, _): core.Meta.has(core.Meta.Enum, a.aMeta);
		case _: false;
	}

	// whether TypeScript would call `a == b` unintentional, its types of no overlap (a string and a class, a number and a
	// string)
	public static function disjoint(a:T, b:T):Bool {
		var ka = kind(a), kb = kind(b);
		return switch [ka, kb] {
			case [KAny, _] | [_, KAny] | [KParam(_), _] | [_, KParam(_)] | [KOther, _] | [_, KOther]: false;
			case [KClass(_), KClass(_)] | [KEnum(_), KEnum(_)] | [KEnum(_), KEnumValue] | [KEnumValue, KEnum(_)]: false;
			case _: ka.getIndex() != kb.getIndex();
		}
	}

	// whether TypeScript has a value of t as a number (or `any`), for arithmetic
	public static function numeric(t:T):Bool return kind(t).match(KNumber | KAny);

	static function kind(t:T, depth = 0):Kind {
		if (depth > 20) return KAny;
		inline function sub(t:T) return kind(t, depth + 1);
		return switch t {
			case TMono(m): m.tmType == null ? KAny : switch follow(m.tmType) {
					case TAnon(_): KAny;
					case t: sub(t);
				}
			case TLazy(l): sub(lazyType(l));
			case TDynamic(_): KAny;
			case TType(_, _): sub(follow(t));
			case TAbstract({aPath: {pack: [], name: "Int" | "Float" | "UInt"}}, _): KNumber;
			case TAbstract({aPath: {pack: [], name: "Bool"}}, _): KBool;
			case TAbstract({aPath: {pack: [], name: "Null"}}, [p]): sub(p);
			case TAbstract({aPath: {pack: [], name: "EnumValue"}}, _): KEnumValue;
			case TAbstract({aPath: {pack: [], name: "Class" | "Enum"}}, _): KType;
			// (a brand of its own, TypeScript's: Ts.abstractDecl)
			case TAbstract(a, _) if (branded(a)): KAbstract(a);
			case TAbstract(a, params): a.aParams.length == 0 && !core.Meta.has(core.Meta.CoreType, a.aMeta) ? sub(a.aThis) : KAny;
			case TInst({clKind: KTypeParameter(p)}, _): KParam(p.ttpName);
			case TInst({clPath: {pack: [], name: "String"}}, _): KString;
			case TInst({clPath: {pack: [], name: "Array"}}, _): KArray;
			case TInst(c, _) if (c.clKind.match(KModuleFields(_) | KAbstractImpl(_))): KAny;
			case TInst(c, _): KClass(c);
			case TEnum(e, _): KEnum(e);
			case TAnon({aStatus: ClassStatics(_) | EnumStatics(_) | AbstractStatics(_)}): KType;
			case TAnon(a) if (a.aFields.isEmpty()): KAny;
			case TAnon(_) | TFun(_): KOther;
		}
	}
}

private enum Kind {
	KAny;
	KNumber;
	KString;
	KBool;
	KArray;
	KParam(name:String);
	KClass(c:TClass);
	KEnum(e:TEnum);
	// the runtime's class of every enum's values
	KEnumValue;
	// a class or an enum as a value
	KType;
	// an abstract, branded (Casts.branded)
	KAbstract(a:TAbstract);
	// structures and functions
	KOther;
}
