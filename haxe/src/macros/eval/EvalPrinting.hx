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

package macros.eval;

import core.Globals;
import core.ds.NotFound;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalString;

using core.ds.VectorTools;

// port: floats are printed with `Numeric.floatRepres` (numeric.ml `float_repres`,
// i.e. C's %.12g/%.15g/%.18g).
class EvalPrinting {
	public static final rbropen = EvalString.createAscii("{");
	public static final rbrclose = EvalString.createAscii("}");
	public static final rbkopen = EvalString.createAscii("[");
	public static final rbkclose = EvalString.createAscii("]");
	public static final rpopen = EvalString.createAscii("(");
	public static final rpclose = EvalString.createAscii(")");
	public static final rcolon = EvalString.createAscii(":");
	public static final rgt = EvalString.createAscii(">");
	public static final rstop = EvalString.createAscii("<...>");
	public static final rnull = EvalString.createAscii("null");
	public static final rcomma = EvalString.createAscii(",");
	public static final rtrue = EvalString.createAscii("true");
	public static final rfalse = EvalString.createAscii("false");
	public static final rfun = EvalString.createAscii("#fun");
	public static final rclosure = EvalString.createAscii("#closure");
	public static final rhandle = EvalString.createAscii("#handle");

	static function pad(i:Int, n:Int):String {
		var neg = i < 0;
		var s = Std.string(neg ? -i : i);
		while (s.length < n) s = "0" + s;
		return neg ? "-" + s : s;
	}

	// port: `Unix.localtime` of seconds since the epoch, printed as %.4d-%.2d-%.2d %.2d:%.2d:%.2d.
	public static function sDate(d:Float):Vstring {
		var t = Date.fromTime(d * 1000.);
		return EvalString.createAscii(pad(t.getFullYear(), 4) + "-" + pad(t.getMonth() + 1, 2) + "-" + pad(t.getDate(), 2) + " "
			+ pad(t.getHours(), 2) + ":" + pad(t.getMinutes(), 2) + ":" + pad(t.getSeconds(), 2));
	}

	public static function sHash(key:Int):Vstring return EvalString.createAscii(EvalHash.revHash(key));

	public static function indent(buf:StringBuf, s:String, n:Int):Void {
		while (n != 0) {
			buf.add(s);
			n--;
		}
	}

	public static function sObject(depth:Int, indentLevel:Int, o:Vobject):Vstring {
		var fields = EvalContext.objectFields(o);
		var buf = new StringBuf();
		var innerIndentLevel = indentLevel + 1;

		buf.add("{");
		switch EvalContext.getCtx().printIndentation {
			case null:
			case s:
				buf.add("\n");
				indent(buf, s, innerIndentLevel);
		}

		for (i in 0...fields.length) {
			var kv = fields[i];
			if (i > 0) {
				switch EvalContext.getCtx().printIndentation {
					case null:
						buf.add(", ");
					case s:
						buf.add(",\n");
						indent(buf, s, innerIndentLevel);
				}
			}

			buf.add(EvalHash.revHash(kv.name));
			buf.add(": ");
			buf.add(sValue(depth, kv.value, innerIndentLevel).sstring);
		}

		switch EvalContext.getCtx().printIndentation {
			case null:
			case s:
				buf.add("\n");
				indent(buf, s, indentLevel);
		}

		buf.add("}");
		var s = buf.toString();
		return EvalString.createUnknownVstring(s);
	}

	public static function sArray(depth:Int, indentLevel:Int, va:Varray):Vstring {
		return EvalString.join(EvalString.emptyString, [
			rbkopen,
			EvalArray.join(va, v -> sValue(depth, v, indentLevel), rcomma),
			rbkclose
		]);
	}

	public static function sVector(depth:Int, indentLevel:Int, vv:Vvector):Vstring {
		return EvalString.join(EvalString.emptyString, [
			rbkopen,
			EvalArray.join(EvalArray.create(vv), v -> sValue(depth, v, indentLevel), rcomma),
			rbkclose
		]);
	}

	public static function sEnumCtorName(ve:VenumValue):String {
		try {
			return switch EvalContext.getStaticPrototypeRaise(EvalContext.getCtx(), ve.epath).pkind {
				case PEnum(names):
					if (ve.eindex < 0 || ve.eindex >= names.length) "#unknown" else names[ve.eindex].name;
				case _: throw NotFound.raise();
			}
		} catch (_:NotFound) {
			return "#unknown";
		}
	}

	public static function sEnumValue(depth:Int, indentLevel:Int, ve:VenumValue):Vstring {
		var name = sEnumCtorName(ve);
		return switch ve.eargs {
			case []: EvalString.createAscii(name);
			case vl:
				EvalString.join(EvalString.emptyString, [
					EvalString.createAscii(name),
					rpopen,
					EvalString.join(rcomma, vl.mapToArray(v -> sValue(depth + 1, v, indentLevel))),
					rpclose
				]);
		}
	}

	public static function sProtoKind(proto:Vprototype):Vstring {
		return switch proto.pkind {
			case PClass(_): EvalString.join(EvalString.emptyString, [EvalString.createAscii("Class<"), sHash(proto.ppath), rgt]);
			case PEnum(_): EvalString.join(EvalString.emptyString, [EvalString.createAscii("Enum<"), sHash(proto.ppath), rgt]);
			case PInstance | PObject: Globals.die("", "EvalPrinting.sProtoKind");
		}
	}

	// port: `s_value ?(indent_level=0) depth v`
	public static function sValue(depth:Int, v:Value, indentLevel:Int = 0):Vstring {
		inline function callToString():Vstring {
			var vf = EvalField.fieldRaise(v, EvalHash.key_toString);
			return sValue(depth + 1, callValueOn(v, vf, []), indentLevel);
		}
		if (depth > EvalContext.getCtx().maxPrintDepth) return rstop;
		return switch v {
			case VNull: rnull;
			case VInt32(i32): EvalString.createAscii(Std.string(i32));
			case VInt64(i): EvalString.createAscii(haxe.Int64.toStr(i));
			case VUInt64(u): EvalString.createAscii(EvalIntegers.uint64ToString(u));
			case VTrue: rtrue;
			case VFalse: rfalse;
			case VFloat(f):
				var s = core.Numeric.floatRepres(f);
				var len = s.length;
				EvalString.createAscii(StringTools.fastCodeAt(s, len - 1) == ".".code ? s.substr(0, len - 1) : s);
			case VFunction(f, _): rfun;
			case VFieldClosure(_): rclosure;
			case VHandle(_): rhandle;
			case VEnumValue(ve): sEnumValue(depth, indentLevel, ve);
			case VString(s): s;
			case VNativeString(s): EvalString.createUnknownVstring(s.toString());
			case VArray(va): sArray(depth + 1, indentLevel, va);
			case VVector(vv): sVector(depth + 1, indentLevel, vv);
			case VInstance({ikind: IDate(d)}): sDate(d);
			case VInstance({ikind: IPos(p)}):
				EvalString.createAscii("#pos(" + syntax.Lexer.getErrorPos((file, line) -> '$file:$line:', p) + ")"); // STODO: not ascii?
			case VInstance({ikind: IRegex(r)}): r.rRexString;
			case VInstance(i):
				try callToString() catch (_:NotFound) sHash(i.iproto.ppath);
			case VObject(o):
				try callToString() catch (_:NotFound) sObject(depth + 1, indentLevel, o);
			case VLazy(f): sValue(depth, f.force(), indentLevel);
			case VPrototype(proto):
				try callToString() catch (_:NotFound) sProtoKind(proto);
		}
	}

	public static function callValueOn(vthis:Value, v:Value, vl:Array<Value>):Value {
		return switch v {
			case VFunction(f, b):
				var vl = if (!b) [vthis].concat(vl) else vl;
				EvalContext.callFunction(f, vl);
			case VFieldClosure(v1, f): EvalContext.callFunction(f, [v1].concat(vl));
			case _: EvalContext.excString("Cannot call " + valueString(v));
		}
	}

	public static function valueString(v:Value):String return sValue(0, v).sstring;
}
