package typing.matcher;

import core.TType;
import core.ds.Hashtbl;
import core.Globals;
import core.Globals.Pos;
import core.TFunctions.*;
import core.TPrinting.*;

enum ConstructorKind {
	ConConst(value:TConstant);
	ConEnum(en:TEnum, field:TEnumField);
	ConStatic(cls:TClass, field:TClassField);
	ConTypeExpr(type:ModuleType);
	ConFields(fields:Array<String>);
	ConArray(length:Int);
}

@:structInit class ConstructorData {
	public var kind:ConstructorKind;
	public var pos:Pos;

	public inline function new(kind:ConstructorKind, pos:Pos) {
		this.kind = kind;
		this.pos = pos;
	}

	public inline function clone():ConstructorData return new ConstructorData(kind, pos);
}

class Constructor {
	public static function toString(con:ConstructorData):String return switch con.kind {
		case ConConst(ct): sConst(ct);
		case ConEnum(en, ef): ef.efName;
		case ConStatic(c, cf): Globals.sTypePath(switch c.clKind {
				case KAbstractImpl(a): a.aPath;
				case _: c.clPath;
			}) + "." + cf.cfName;
		case ConTypeExpr(mt): Globals.sTypePath(tPath(mt));
		case ConFields(fields): "{ " + fields.join(", ") + " }";
		case ConArray(i): "<array " + i + ">";
	};

	public static function equal(con1:ConstructorData, con2:ConstructorData):Bool return switch [con1.kind, con2.kind] {
		case [ConConst(ct1), ConConst(ct2)]: Type.enumEq(ct1, ct2);
		case [ConEnum(en1, ef1), ConEnum(en2, ef2)]: en1 == en2 && ef1 == ef2;
		case [ConStatic(c1, cf1), ConStatic(c2, cf2)]: c1 == c2 && cf1 == cf2;
		case [ConTypeExpr(mt1), ConTypeExpr(mt2)]: mt1 == mt2;
		case [ConFields(_), ConFields(_)]: true;
		case [ConArray(i1), ConArray(i2)]: i1 == i2;
		case _: false;
	};

	public static function arity(con:ConstructorData):Int return switch con.kind {
		case ConEnum(_, {efType: TFun(s)}): s.args.length;
		case ConFields(fields): fields.length;
		case ConArray(i): i;
		case _: 0;
	};

	public static function compare(con1:ConstructorData, con2:ConstructorData):Int return switch [con1.kind, con2.kind] {
		case [ConConst(ct1), ConConst(ct2)]:
			// port: OCaml's `compare` orders constant constructors before payload constructors.
			inline function rank(c:TConstant):Int return switch c {
				case TNull: 0;
				case TThis: 1;
				case TSuper: 2;
				case TInt(_): 3;
				case TFloat(_): 4;
				case TString(_): 5;
				case TBool(_): 6;
			};
			var r = rank(ct1) - rank(ct2);
			if (r != 0) r else switch [ct1, ct2] {
				case [TInt(a), TInt(b)]: Reflect.compare(a, b);
				case [TFloat(a), TFloat(b)] | [TString(a), TString(b)]: core.ds.Key.compareStrings(a, b);
				case [TBool(a), TBool(b)]: a == b ? 0 : (a ? 1 : -1);
				case _: 0;
			}
		case [ConEnum(_, ef1), ConEnum(_, ef2)]: Reflect.compare(ef1.efIndex, ef2.efIndex);
		case [ConStatic(_, cf1), ConStatic(_, cf2)]: core.ds.Key.compareStrings(cf1.cfName, cf2.cfName);
		case [ConTypeExpr(mt1), ConTypeExpr(mt2)]:
			var p1 = tPath(mt1), p2 = tPath(mt2);
			var r = 0;
			for (i in 0...Std.int(Math.min(p1.pack.length, p2.pack.length))) {
				r = core.ds.Key.compareStrings(p1.pack[i], p2.pack[i]);
				if (r != 0) break;
			}
			if (r != 0) r else if (p1.pack.length != p2.pack.length) p1.pack.length - p2.pack.length else core.ds.Key.compareStrings(p1.name, p2.name);
		case [ConFields(_), ConFields(_)]: 0;
		case [ConArray(i1), ConArray(i2)]: i1 - i2;
		case _: -1; // Could assert...
	};

	public static function hash(con:ConstructorData):Int return Hashtbl.hash(con.kind);
}
