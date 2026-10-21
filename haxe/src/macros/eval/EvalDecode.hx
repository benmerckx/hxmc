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
import macros.eval.EvalValue;
import macros.eval.EvalExceptions.EvalExceptions.unexpectedValue;

using macros.eval.EvalValue.EvalValueTools;

// port: options are `Null<T>` (as elsewhere in the port); enum
// decoders return `{index, args}`; `decode_int` of a float truncates to a
// 32-bit Int (upstream: OCaml `int_of_float`, 63 bits).
class EvalDecode {
	public static function decodeObject(v:Value):Vobject {
		return switch v.vresolve() {
			case VObject(o): o;
			case _: unexpectedValue(v, "object");
		}
	}

	public static function decodeEnum(v:Value):{index:Int, args:Array<Value>} {
		return switch v {
			case VEnumValue(ev): {index: ev.eindex, args: ev.eargs.toArray()};
			case _: unexpectedValue(v, "enum");
		}
	}

	public static function decodeEnumWithPos(v:Value):{index:Int, args:Array<Value>, pos:Pos} {
		return switch v {
			case VEnumValue(ev): {index: ev.eindex, args: ev.eargs.toArray(), pos: ev.enpos == null ? Globals.nullPos : ev.enpos};
			case _: unexpectedValue(v, "enum");
		}
	}

	public static function decodeInstance(v:Value):Vinstance {
		return switch v {
			case VInstance(vi): vi;
			case _: unexpectedValue(v, "instance");
		}
	}

	public static function decodeArray(v:Value):Array<Value> {
		return switch v {
			case VArray(va): EvalArray.toList(va);
			case _: unexpectedValue(v, "array");
		}
	}

	public static function decodeVector(v:Value):Vvector {
		return switch v {
			case VVector(vv): vv;
			case _: unexpectedValue(v, "vector");
		}
	}

	public static function decodeVarray(v:Value):Varray {
		return switch v {
			case VArray(va): va;
			case _: unexpectedValue(v, "array");
		}
	}

	public static function decodeString(v:Value):String {
		return switch v {
			case VString(s): s.sstring;
			case _: unexpectedValue(v, "string");
		}
	}

	public static function decodeVstring(v:Value):Vstring {
		return switch v {
			case VString(s): s;
			case _: unexpectedValue(v, "string");
		}
	}

	public static function decodeNativeString(v:Value):haxe.io.Bytes {
		return switch v {
			case VNativeString(s): s;
			case _: unexpectedValue(v, "native string");
		}
	}

	public static function decodeHandle(v:Value):Vhandle {
		return switch v {
			case VHandle(h): h;
			case _: unexpectedValue(v, "handle");
		}
	}

	public static function decodeBytes(v:Value):haxe.io.Bytes {
		return switch v {
			case VInstance({ikind: IBytes(s)}): s;
			case _: unexpectedValue(v, "string");
		}
	}

	// port: OCaml `Int32.of_float` / `int_of_float`: truncation toward zero.
	static function truncFloat(f:Float):Int {
		if (Math.isNaN(f) || f >= 2147483648.0 || f <= -2147483649.0) {
			// port: out of range: wrap like the low 32 bits of a 64-bit conversion
			if (!Math.isFinite(f)) return 0;
			var t = f < 0 ? Math.ceil(f) : Math.floor(f);
			var m = t % 4294967296.0;
			if (m < 0) m += 4294967296.0;
			return m >= 2147483648.0 ? Std.int(m - 4294967296.0) : Std.int(m);
		}
		return Std.int(f);
	}

	public static function decodeI32(v:Value):Int {
		return switch v {
			case VInt32(i): i;
			case VFloat(f): truncFloat(f);
			case _: unexpectedValue(v, "int");
		}
	}

	public static function decodeInt(v:Value):Int {
		return switch v {
			case VInt32(i): i;
			case VFloat(f): truncFloat(f);
			case _: unexpectedValue(v, "int");
		}
	}

	public static function decodeBool(v:Value):Bool {
		return switch v {
			case VTrue: true;
			case VFalse: false;
			case _: unexpectedValue(v, "bool");
		}
	}

	public static function defaultInt(v:Value, vd:Int):Int {
		return switch v {
			case VNull: vd;
			case VInt32(i): i;
			case VFloat(f): truncFloat(f);
			case _: unexpectedValue(v, "int");
		}
	}

	public static function decodeUnsafe(v:Value):Dynamic {
		return switch v {
			case VInstance({ikind: IRef(o)}): o;
			case _: unexpectedValue(v, "unsafe");
		}
	}

	public static function decodeLazytype(v:Value):core.TType.TLazy {
		return switch v {
			case VInstance({ikind: ILazyType(t, _)}): t;
			case _: unexpectedValue(v, "lazy type");
		}
	}

	public static function decodeTdecl(v:Value):core.TType.ModuleType {
		return switch v {
			case VInstance({ikind: ITypeDecl(t)}): t;
			case _: unexpectedValue(v, "type declaration");
		}
	}

	public static function decodePos(v:Value):Pos {
		return switch v {
			case VInstance({ikind: IPos(p)}): p;
			case _: throw macros.MacroApi.InvalidExpr.raise(); // maybe_decode_pos relies on this being raised
		}
	}

	public static function decodeRef<T>(v:Value):T {
		return switch v {
			case VInstance({ikind: IRef(r)}): r;
			case _: unexpectedValue(v, "unsafe");
		}
	}

	public static function num(v:Value):Float {
		return switch v {
			case VInt32(i): i;
			case VFloat(f): f;
			case v: unexpectedValue(v, "number");
		}
	}

	public static function decodeOption<T>(decodeValue:Value->T, v:Value):Null<T> {
		var e = decodeEnum(v);
		return switch [e.index, e.args] {
			case [0, [v]]: decodeValue(v);
			case [1, []]: null;
			case _: unexpectedValue(v, "haxe.ds.Option");
		}
	}

	public static function decodeOptional<T>(decodeValue:Value->T, v:Value):Null<T> {
		if (v.match(VNull)) return null;
		return decodeValue(v);
	}
}
