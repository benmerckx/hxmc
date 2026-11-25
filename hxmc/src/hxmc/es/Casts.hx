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
			// (a structure with a field the other has not: TypeScript checks an object literal's, Haxe let it)
			case [KOther, KOther]: extraFields(from, to);
			// (a structure or function as a class's value: Haxe's classes are nominal, a cast made it one)
			case [KOther, KClass(_)]: true;
			// (a structure as a primitive, or the other way around: only a cast does that)
			case [KOther, KNumber | KString | KBool | KArray | KEnum(_)] | [KNumber | KString | KBool, KOther]: true;
			// (an array as a structure: TypeScript's arrays have not Haxe's fields; an instance as a structure of a type
			// parameter, which Haxe bound and TypeScript does not)
			case [KArray, KOther]: !to.match(TType({tPath: {pack: [], name: "Iterable"}}, _));
			case [KClass(_), KOther]: mentionsParam(to, 0);
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
	// structures and functions
	KOther;
}
