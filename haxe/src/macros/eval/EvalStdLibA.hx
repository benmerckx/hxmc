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
import core.ds.Failure;
import core.ds.InvalidArgument;
import haxe.Int64;
import haxe.io.Bytes;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalHash;
import macros.eval.EvalEncode;
import macros.eval.EvalDecode;
import macros.eval.EvalExceptions;
import macros.eval.EvalPrinting;
import macros.eval.EvalMisc;
import macros.eval.EvalField;
import macros.eval.EvalString;

using macros.eval.EvalValue.EvalValueTools;
// port: the host natives of hxmc (hxmc/std)
#if (target.name == "hxmc")
import hxmc.NativeGc;
import hxmc.NativeNet;
#end

// port: haxe/src/macro/eval/evalStdLib.ml, lines 45-1484 (StdEvalVector to StdLock,
// `outside_bounds` and `lineEnd`). The shared helpers of lines 1-44 are in
// `EvalStdLib`, the rest of the file is in `EvalStdLibB` and `EvalStdLib`.
//
// Deliberate deviations (the OCaml libraries are replaced by host APIs):
// - "Byte offsets" are native string indices. Bytes <-> string
//   conversions decode/encode UTF-8 on the host; invalid UTF-8 cannot be held
//   in a native string.
// - EReg uses the host `EReg` instead of PCRE2 (see `StdEReg`). HashLink's
//   regexp also uses PCRE2 with UTF|UCP, plus ALT_BSUX, ALLOW_EMPTY_CLASS and
//   MATCH_UNSET_BACKREF; compile errors have the host's message. Matches are
//   snapshotted (`VregexMatch`) so `r_groups` keeps upstream's semantics.
// - An empty regex match in `map`/`split`/`replace` steps over one code point
//   instead of one byte (upstream would resume inside a UTF-8 sequence).
// - zlib is libs.extc.Extc; CRC32 is `haxe.crypto.Crc32`.
// - Dates use the host `Date` (local time via the host's localtime/mktime).
//   `FileSystem.stat` times have the host's precision.
// - Sys_error messages are approximated as "<path>: <reason>", with
//   "No such file or directory" when the path does not exist.
// - OCaml's Gc statistics/control and Dynlink plugins are not
//   available: those natives fail with "... is not supported by haxe-in-haxe".
//   Gc collection requests run the host collector when there is one.
// - `StdLock` waits on the condition's own mutex (host `sys.thread.Condition`
//   owns its mutex), so `Vlock.lmutex` is unused.
// - `StdHost.int32Addr` returns the dotted address string (no `inet_addr`).
class EvalStdLibA {
	public static function outsideBounds():Dynamic {
		var haxe_io_Error = EvalContext.getStaticPrototype(EvalContext.getCtx(), EvalHash.key_haxe_io_Error, Globals.nullPos);
		return EvalContext.exc(EvalField.protoFieldDirect(haxe_io_Error, EvalHash.key_OutsideBounds));
	}

	public static final lineEnd:String = switch Sys.systemName() {
			case "Windows": "\r\n";
			case _: "\n";
		}

	// port: Sys_error message: "<path>: <reason>".
	public static function sysErrorMessage(path:String, e:Dynamic):String {
		var exists = try sys.FileSystem.exists(path) catch (_:Dynamic) false;
		return if (!exists) path + ": No such file or directory" else path + ": " + Std.string(e);
	}

	public static function notSupported(what:String):Dynamic return EvalContext.excString(what + " is not supported by haxe-in-haxe");
}

// port: evalBytes.ml `read_*`/`write_*` (Bytes.get/set raise Invalid_argument out of bounds).
private class BytesIo {
	public static inline function check(b:Bytes, i:Int):Void {
		if (i < 0 || i >= b.length) throw new InvalidArgument("index out of bounds");
	}

	public static function readByte(b:Bytes, i:Int):Int {
		check(b, i);
		return b.get(i);
	}

	public static function readUi16(b:Bytes, i:Int):Int {
		var ch1 = readByte(b, i);
		var ch2 = readByte(b, i + 1);
		return ch1 | (ch2 << 8);
	}

	public static function readI32(b:Bytes, i:Int):Int {
		var ch1 = readByte(b, i);
		var ch2 = readByte(b, i + 1);
		var ch3 = readByte(b, i + 2);
		var base = ch1 | (ch2 << 8) | (ch3 << 16);
		var big = readByte(b, i + 3) << 24;
		return base | big;
	}

	public static function readI64(b:Bytes, i:Int):Int64 {
		var small = readI32(b, i);
		var big = readI32(b, i + 4);
		return Int64.make(big, small);
	}

	public static function writeByte(b:Bytes, i:Int, v:Int):Void {
		check(b, i);
		b.set(i, v & 0xFF);
	}

	public static function writeUi16(b:Bytes, i:Int, v:Int):Void {
		writeByte(b, i, v);
		writeByte(b, i + 1, v >>> 8);
	}

	public static function writeI32(b:Bytes, i:Int, v:Int):Void {
		var base = v;
		var big = v >>> 24;
		writeByte(b, i, base);
		writeByte(b, i + 1, base >>> 8);
		writeByte(b, i + 2, base >>> 16);
		writeByte(b, i + 3, big);
	}

	public static function writeI64(b:Bytes, i:Int, v:Int64):Void {
		writeI32(b, i, v.low);
		writeI32(b, i + 4, v.high);
	}
}

class StdEvalVector {
	// port: upstream `this` (a Haxe keyword)
	static function thisValue(v:Value):Vvector {
		return switch v {
			case VVector(vv): vv;
			case v: EvalExceptions.unexpectedValue(v, "vector");
		}
	}

	// port: OCaml Array.blit (overlap-safe, Invalid_argument on bad ranges).
	static function arrayBlit(src:Array<Value>, srcPos:Int, dst:Array<Value>, dstPos:Int, len:Int):Void {
		if (len < 0 || srcPos < 0 || srcPos > src.length - len || dstPos < 0 || dstPos > dst.length - len)
			throw new InvalidArgument("Array.blit");
		if (src == dst && srcPos < dstPos) {
			var i = len - 1;
			while (i >= 0) {
				dst[dstPos + i] = src[srcPos + i];
				i--;
			}
		} else
			for (i in 0...len)
				dst[dstPos + i] = src[srcPos + i];
	}

	public static final blit = EvalEncode.vifun4((vthis, srcPos, dest, destPos, len) -> {
		arrayBlit(thisValue(vthis), EvalDecode.decodeInt(srcPos), EvalDecode.decodeVector(dest), EvalDecode.decodeInt(destPos),
			EvalDecode.decodeInt(len));
		return VNull;
	});

	public static final toArray = EvalEncode.vifun0(vthis -> {
		var copy = thisValue(vthis).copy();
		return EvalEncode.encodeArrayInstance(EvalArray.create(copy));
	});

	public static final fromArrayCopy = EvalEncode.vfun1(arr -> {
		var a = EvalDecode.decodeVarray(arr);
		return EvalEncode.encodeVectorInstance(a.avalues.slice(0, a.alength));
	});

	public static final copy = EvalEncode.vifun0(vthis -> {
		return EvalEncode.encodeVectorInstance(thisValue(vthis).copy());
	});

	public static final join = EvalEncode.vifun1((vthis, sep) -> {
		var self = thisValue(vthis);
		var sep = EvalDecode.decodeVstring(sep);
		return EvalString.vstring(EvalArray.arrayJoin(self, v -> EvalPrinting.sValue(0, v), sep));
	});

	public static final map = EvalEncode.vifun1((vthis, f) -> {
		var self = thisValue(vthis);
		var a = switch f {
				case VFunction(f, _):
					self.map(v -> f([v]));
				case VFieldClosure(v1, f):
					self.map(v -> f([v1, v]));
				case _: EvalContext.excString("Cannot call " + EvalPrinting.valueString(f));
			}
		return EvalEncode.encodeVectorInstance(a);
	});
}

class StdArray {
	static function thisValue(v:Value):Varray {
		return switch v {
			case VArray(va): va;
			case v: EvalExceptions.unexpectedValue(v, "array");
		}
	}

	public static final concat = EvalEncode.vifun1((vthis, a2) -> {
		var a2 = EvalDecode.decodeVarray(a2);
		return EvalEncode.encodeArrayInstance(EvalArray.concat(thisValue(vthis), a2));
	});

	public static final copy = EvalEncode.vifun0(vthis -> {
		return EvalEncode.encodeArrayInstance(EvalArray.copy(thisValue(vthis)));
	});

	public static final filter = EvalEncode.vifun1((vthis, f) -> {
		var self = thisValue(vthis);
		var a = EvalArray.filter(self, v -> EvalMisc.isTrue(EvalPrinting.callValueOn(vthis, f, [v])));
		return EvalEncode.encodeArrayInstance(a);
	});

	public static final indexOf = EvalEncode.vifun2((vthis, x, fromIndex) -> {
		var self = thisValue(vthis);
		var fromIndex = EvalDecode.defaultInt(fromIndex, 0);
		var fromIndex = if (fromIndex < 0) self.alength + fromIndex else fromIndex;
		var fromIndex = if (fromIndex < 0) 0 else fromIndex;
		return VInt32(EvalArray.indexOf(self, EvalValueTools.equals, x, fromIndex));
	});

	public static final insert = EvalEncode.vifun2((vthis, pos, x) -> {
		var self = thisValue(vthis);
		var pos = EvalDecode.decodeInt(pos);
		if (pos >= self.alength) {
			EvalArray.push(self, x);
		} else {
			var pos = if (pos < 0) self.alength + pos else pos;
			var pos = if (pos < 0) 0 else pos;
			EvalArray.insert(self, pos, x);
		}
		return VNull;
	});

	public static final iterator = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		var it = EvalArray.iterator(self);
		return EvalEncode.encodeObj([
			{name: EvalHash.key_hasNext, value: EvalEncode.vifun0(_ -> it.hasNext().vbool())},
			{name: EvalHash.key_next, value: EvalEncode.vifun0(_ -> it.next())}
		]);
	});

	public static final join = EvalEncode.vifun1((vthis, sep) -> {
		var sep = EvalDecode.decodeVstring(sep);
		var s = EvalArray.join(thisValue(vthis), v -> EvalPrinting.sValue(0, v), sep);
		return EvalString.vstring(s);
	});

	public static final keyValueIterator = EvalEncode.vifun0(vthis -> {
		var ctx = EvalContext.getCtx();
		var path = EvalHash.key_haxe_iterators_array_key_value_iterator;
		var vit = EvalEncode.encodeInstance(path);
		var fnew = EvalContext.getInstanceConstructor(ctx, path, Globals.nullPos);
		EvalPrinting.callValueOn(vit, fnew.force(), [vthis]);
		return vit;
	});

	public static final lastIndexOf = EvalEncode.vifun2((vthis, x, fromIndex) -> {
		var self = thisValue(vthis);
		var last = self.alength - 1;
		var fromIndex = EvalDecode.defaultInt(fromIndex, last);
		var fromIndex = if (fromIndex < 0) self.alength + fromIndex else fromIndex;
		var fromIndex = if (fromIndex < 0) 0 else if (fromIndex > last) last else fromIndex;
		return VInt32(EvalArray.lastIndexOf(self, EvalValueTools.equals, x, fromIndex));
	});

	public static final map = EvalEncode.vifun1((vthis, f) -> {
		var self = thisValue(vthis);
		var a = switch f {
				case VFunction(f, _):
					EvalArray.map(self, v -> f([v]));
				case VFieldClosure(v1, f):
					EvalArray.map(self, v -> f([v1, v]));
				case _: EvalContext.excString("Cannot call " + EvalPrinting.valueString(f));
			}
		return EvalEncode.encodeArrayInstance(a);
	});

	public static final pop = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		return EvalArray.pop(self);
	});

	public static final push = EvalEncode.vifun1((vthis, v) -> {
		var self = thisValue(vthis);
		return VInt32(EvalArray.push(self, v));
	});

	public static final remove = EvalEncode.vifun1((vthis, x) -> {
		var self = thisValue(vthis);
		return EvalArray.remove(self, EvalValueTools.equals, x).vbool();
	});

	public static final contains = EvalEncode.vifun1((vthis, x) -> {
		var self = thisValue(vthis);
		return EvalArray.contains(self, EvalValueTools.equals, x).vbool();
	});

	public static final reverse = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		EvalArray.reverse(self);
		return VNull;
	});

	public static final shift = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		return EvalArray.shift(self);
	});

	public static final slice = EvalEncode.vifun2((vthis, pos, end) -> {
		var self = thisValue(vthis);
		var pos = EvalDecode.decodeInt(pos);
		var length = self.alength;
		var end = EvalDecode.defaultInt(end, length);
		var end = if (end > length) length else end;
		var pos = if (pos < 0) length + pos else pos;
		var end = if (end < 0) length + end else end;
		var pos = if (pos < 0) 0 else pos;
		var end = if (end < 0) 0 else end;
		return EvalEncode.encodeArrayInstance(EvalArray.slice(self, pos, end));
	});

	public static final sort = EvalEncode.vifun1((vthis, f) -> {
		var self = thisValue(vthis);
		EvalArray.sort(self, (a, b) -> EvalDecode.decodeInt(EvalPrinting.callValueOn(vthis, f, [a, b])));
		return VNull;
	});

	public static final splice = EvalEncode.vifun2((vthis, pos, len) -> {
		var self = thisValue(vthis);
		var pos = EvalDecode.decodeInt(pos);
		var len = EvalDecode.decodeInt(len);
		var length = self.alength;
		if (len < 0 || pos > length)
			return EvalEncode.encodeArray([]);
		else {
			var pos = if (pos < 0) length + pos else pos;
			var pos = if (pos < 0) 0 else pos;
			var delta = length - pos;
			var len = if (len > delta) delta else len;
			var end = pos + len;
			return EvalEncode.encodeArrayInstance(EvalArray.splice(self, pos, len, end));
		}
	});

	public static final toString = EvalEncode.vifun0(vthis -> {
		return EvalString.vstring(EvalPrinting.sArray(0, 0, thisValue(vthis)));
	});

	public static final unshift = EvalEncode.vifun1((vthis, v) -> {
		var self = thisValue(vthis);
		EvalArray.unshift(self, v);
		return VNull;
	});

	public static final resize = EvalEncode.vifun1((vthis, len) -> {
		var self = thisValue(vthis);
		var len = EvalDecode.decodeInt(len);
		EvalArray.resize(self, len);
		return VNull;
	});
}

class StdBytes {
	static function thisValue(vthis:Value):Bytes {
		return switch vthis {
			case VInstance({ikind: IBytes(o)}): o;
			case v: EvalExceptions.unexpectedValue(v, "bytes");
		}
	}

	// port: Bytes.sub (Invalid_argument on a bad range).
	static function bytesSub(b:Bytes, pos:Int, len:Int):Bytes {
		if (pos < 0 || len < 0 || pos > b.length - len) throw new InvalidArgument("String.sub / Bytes.sub");
		return b.sub(pos, len);
	}

	public static final alloc = EvalEncode.vfun1(length -> {
		var length = EvalDecode.decodeInt(length);
		var b = Bytes.alloc(length);
		b.fill(0, length, 0);
		return EvalEncode.encodeBytes(b);
	});

	public static function encodeNative(v:Value):Bool {
		return switch v {
			case VEnumValue({eindex: 1}): true; // haxe.io.Encoding.RawNative
			case _: false;
		}
	}

	public static final blit = EvalEncode.vifun4((vthis, pos, src, srcpos, len) -> {
		var s = thisValue(vthis);
		var pos = EvalDecode.decodeInt(pos);
		var src = EvalDecode.decodeBytes(src);
		var srcpos = EvalDecode.decodeInt(srcpos);
		var len = EvalDecode.decodeInt(len);
		if (len < 0 || srcpos < 0 || srcpos > src.length - len || pos < 0 || pos > s.length - len) outsideBounds();
		try s.blit(pos, src, srcpos, len)
		catch (_:Dynamic) outsideBounds();
		return VNull;
	});

	static inline function outsideBounds():Dynamic return EvalStdLibA.outsideBounds();

	// port: OCaml's polymorphic compare on bytes: -1, 0 or 1.
	static function compareBytes(a:Bytes, b:Bytes):Int {
		var la = a.length, lb = b.length;
		var n = la < lb ? la : lb;
		for (i in 0...n) {
			var ca = a.get(i), cb = b.get(i);
			if (ca != cb) return ca < cb ? -1 : 1;
		}
		return la == lb ? 0 : (la < lb ? -1 : 1);
	}

	public static final compare = EvalEncode.vifun1((vthis, other) -> {
		var self = thisValue(vthis);
		var other = EvalDecode.decodeBytes(other);
		return VInt32(compareBytes(self, other));
	});

	public static final fastGet = EvalEncode.vfun2((b, pos) -> {
		var b = EvalDecode.decodeBytes(b);
		var pos = EvalDecode.decodeInt(pos);
		return if (pos < 0 || pos >= b.length) VNull else VInt32(b.get(pos));
	});

	public static final fill = EvalEncode.vifun3((vthis, pos, len, value) -> {
		var self = thisValue(vthis);
		var pos = EvalDecode.decodeInt(pos);
		var len = EvalDecode.decodeInt(len);
		var value = EvalDecode.decodeInt(value);
		if (pos < 0 || len < 0 || pos > self.length - len) outsideBounds();
		self.fill(pos, len, value & 0xFF);
		return VNull;
	});

	public static final get = EvalEncode.vifun1((vthis, pos) -> {
		var self = thisValue(vthis);
		var pos = EvalDecode.decodeInt(pos);
		return try VInt32(BytesIo.readByte(self, pos)) catch (_:InvalidArgument) VNull;
	});

	public static final getData = EvalEncode.vifun0(vthis -> vthis);

	public static final getDouble = EvalEncode.vifun1((vthis, pos) -> {
		return try {
			var i64 = BytesIo.readI64(thisValue(vthis), EvalDecode.decodeInt(pos));
			VFloat(haxe.io.FPHelper.i64ToDouble(i64.low, i64.high));
		} catch (_:InvalidArgument) outsideBounds();
	});

	public static final getFloat = EvalEncode.vifun1((vthis, pos) -> {
		return try VFloat(haxe.io.FPHelper.i32ToFloat(BytesIo.readI32(thisValue(vthis),
			EvalDecode.decodeInt(pos)))) catch (_:InvalidArgument) outsideBounds();
	});

	public static final getInt32 = EvalEncode.vifun1((vthis, pos) -> {
		return try VInt32(BytesIo.readI32(thisValue(vthis), EvalDecode.decodeInt(pos))) catch (_:InvalidArgument) outsideBounds();
	});

	public static final getInt64 = EvalEncode.vifun1((vthis, pos) -> {
		var self = thisValue(vthis);
		var pos = EvalDecode.decodeInt(pos);
		return try {
			var low = BytesIo.readI32(self, pos);
			var high = BytesIo.readI32(self, pos + 4);
			VInt64(EvalIntegers.makeInt64(high, low));
		} catch (_:InvalidArgument) {
			outsideBounds();
		}
	});

	public static final getString = EvalEncode.vifun3((vthis, pos, len, encoding) -> {
		var self = thisValue(vthis);
		var pos = EvalDecode.decodeInt(pos);
		var len = EvalDecode.decodeInt(len);
		var s = try bytesSub(self, pos, len) catch (_:InvalidArgument) outsideBounds();
		return EvalString.createUnknown(core.StringHelper.ofBytes(s));
	});

	public static final getUInt16 = EvalEncode.vifun1((vthis, pos) -> {
		return try VInt32(BytesIo.readUi16(thisValue(vthis), EvalDecode.decodeInt(pos))) catch (_:InvalidArgument) outsideBounds();
	});

	public static final ofData = EvalEncode.vfun1(v -> v);

	public static final ofString = EvalEncode.vfun2((v, encoding) -> {
		var s = EvalDecode.decodeVstring(v);
		return EvalEncode.encodeBytes(Bytes.ofString(s.sstring));
	});

	public static final ofHex = EvalEncode.vfun1(v -> {
		var s = EvalDecode.decodeString(v);
		var len = s.length;
		if ((len & 1) != 0) EvalContext.excString("Not a hex string (odd number of digits)");
		var ret = Bytes.alloc(len >>> 1);
		ret.fill(0, ret.length, 0);
		for (i in 0...ret.length) {
			var high = StringTools.fastCodeAt(s, i * 2);
			var low = StringTools.fastCodeAt(s, i * 2 + 1);
			var high = (high & 0xF) + ((high & 0x40) >>> 6) * 9;
			var low = (low & 0xF) + ((low & 0x40) >>> 6) * 9;
			ret.set(i, ((high << 4) | low) & 0xFF);
		}
		return EvalEncode.encodeBytes(ret);
	});

	public static final set = EvalEncode.vifun2((vthis, pos, v) -> {
		var self = thisValue(vthis);
		var pos = EvalDecode.decodeInt(pos);
		var v = EvalDecode.decodeInt(v);
		try BytesIo.writeByte(self, pos, v)
		catch (_:InvalidArgument) {}
		return VNull;
	});

	public static final setDouble = EvalEncode.vifun2((vthis, pos, v) -> {
		try BytesIo.writeI64(thisValue(vthis), EvalDecode.decodeInt(pos), haxe.io.FPHelper.doubleToI64(EvalDecode.num(v)))
		catch (_:InvalidArgument) outsideBounds();
		return VNull;
	});

	public static final setFloat = EvalEncode.vifun2((vthis, pos, v) -> {
		var self = thisValue(vthis);
		var pos = EvalDecode.decodeInt(pos);
		var v = EvalDecode.num(v);
		// port: not caught upstream: Invalid_argument escapes
		BytesIo.writeI32(self, pos, haxe.io.FPHelper.floatToI32(v));
		return VNull;
	});

	public static final setInt32 = EvalEncode.vifun2((vthis, pos, v) -> {
		try BytesIo.writeI32(thisValue(vthis), EvalDecode.decodeInt(pos), EvalDecode.decodeI32(v))
		catch (_:InvalidArgument) outsideBounds();
		return VNull;
	});

	public static final setInt64 = EvalEncode.vifun2((vthis, pos, v) -> {
		var v = EvalDecode.decodeInstance(v);
		var pos = EvalDecode.decodeInt(pos);
		var high = EvalDecode.decodeI32(EvalField.instanceField(v, EvalHash.key_high));
		var low = EvalDecode.decodeI32(EvalField.instanceField(v, EvalHash.key_low));
		var self = thisValue(vthis);
		return try {
			BytesIo.writeI32(self, pos, low);
			BytesIo.writeI32(self, pos + 4, high);
			VNull;
		} catch (_:InvalidArgument) {
			outsideBounds();
		}
	});

	public static final setUInt16 = EvalEncode.vifun2((vthis, pos, v) -> {
		try BytesIo.writeUi16(thisValue(vthis), EvalDecode.decodeInt(pos), EvalDecode.decodeInt(v) & 0xFFFF)
		catch (_:InvalidArgument) outsideBounds();
		return VNull;
	});

	public static final sub = EvalEncode.vifun2((vthis, pos, len) -> {
		var self = thisValue(vthis);
		var pos = EvalDecode.decodeInt(pos);
		var len = EvalDecode.decodeInt(len);
		var s = try bytesSub(self, pos, len) catch (_:InvalidArgument) outsideBounds();
		return EvalEncode.encodeBytes(s);
	});

	public static final toHex = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		var chars = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
		var l = self.length;
		var buf = new StringBuf();
		for (i in 0...l) {
			var c = self.get(i);
			buf.add(chars[c >>> 4]);
			buf.add(chars[c & 15]);
		}
		return EvalEncode.encodeString(buf.toString());
	});

	// port: extlib UTF8.validate: true when well-formed (up to 6-byte sequences, no overlongs).
	public static function utf8Valid(b:Bytes):Bool {
		var len = b.length;
		function trail(c:Int, i:Int, a:Int):Int {
			while (c > 0) {
				if (i >= len) return -1;
				var n = b.get(i);
				if (n < 0x80 || n >= 0xc0) return -1;
				a = (a << 6) | (n - 0x80);
				c--;
				i++;
			}
			return a;
		}
		var i = 0;
		while (i < len) {
			var n = b.get(i);
			if (n < 0x80) i++;
			else if (n < 0xc2) return false;
			else if (n <= 0xdf) {
				var t = trail(1, i + 1, n - 0xc0);
				if (t < 0x80) return false;
				i += 2;
			} else if (n <= 0xef) {
				var t = trail(2, i + 1, n - 0xe0);
				if (t < 0x800) return false;
				i += 3;
			} else if (n <= 0xf7) {
				var t = trail(3, i + 1, n - 0xf0);
				if (t < 0x10000) return false;
				i += 4;
			} else if (n <= 0xfb) {
				var t = trail(4, i + 1, n - 0xf8);
				if (t < 0x200000) return false;
				i += 5;
			} else if (n <= 0xfd) {
				var t = trail(5, i + 1, n - 0xfc);
				if (t < 0 || (t >>> 16) < 0x400) return false;
				i += 6;
			} else return false;
		}
		return true;
	}

	public static final toString = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		return if (utf8Valid(self)) EvalString.createUnknown(self.toString()) else EvalContext.excString("Invalid string");
	});
}

class StdBytesBuffer {
	static function thisValue(vthis:Value):haxe.io.BytesBuffer {
		return switch vthis {
			case VInstance({ikind: IOutput(o)}): o;
			case v: EvalExceptions.unexpectedValue(v, "output");
		}
	}

	public static final getLength = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		return VInt32(self.length);
	});

	public static function addChar(self:haxe.io.BytesBuffer, i:Int):Void {
		self.addByte(i & 0xFF);
	}

	public static function addI32(self:haxe.io.BytesBuffer, v:Int):Void {
		var base = v;
		var big = v >>> 24;
		addChar(self, base);
		addChar(self, base >>> 8);
		addChar(self, base >>> 16);
		addChar(self, big);
	}

	public static final addByte = EvalEncode.vifun1((vthis, byte) -> {
		var self = thisValue(vthis);
		var byte = EvalDecode.decodeInt(byte);
		addChar(self, byte);
		return VNull;
	});

	public static final add = EvalEncode.vifun1((vthis, src) -> {
		var self = thisValue(vthis);
		var src = EvalDecode.decodeBytes(src);
		self.add(src);
		return VNull;
	});

	public static final addString = EvalEncode.vifun2((vthis, src, encoding) -> {
		var self = thisValue(vthis);
		var src = EvalDecode.decodeVstring(src);
		self.add(Bytes.ofString(src.sstring));
		return VNull;
	});

	public static final addInt32 = EvalEncode.vifun1((vthis, v) -> {
		var self = thisValue(vthis);
		var v = EvalDecode.decodeI32(v);
		addI32(self, v);
		return VNull;
	});

	public static final addInt64 = EvalEncode.vifun1((vthis, v) -> {
		var self = thisValue(vthis);
		var i64 = EvalIntegers.decodeI64(v);
		var high = i64.high;
		var low = i64.low;
		addI32(self, low);
		addI32(self, high);
		return VNull;
	});

	public static final addFloat = EvalEncode.vifun1((vthis, v) -> {
		var self = thisValue(vthis);
		var v = EvalDecode.num(v);
		addI32(self, haxe.io.FPHelper.floatToI32(v));
		return VNull;
	});

	public static final addDouble = EvalEncode.vifun1((vthis, v) -> {
		var self = thisValue(vthis);
		var v = EvalDecode.num(v);
		var v = haxe.io.FPHelper.doubleToI64(v);
		addI32(self, v.low);
		addI32(self, v.high);
		return VNull;
	});

	public static final addBytes = EvalEncode.vifun3((vthis, src, pos, len) -> {
		var self = thisValue(vthis);
		var src = EvalDecode.decodeBytes(src);
		var pos = EvalDecode.decodeInt(pos);
		var len = EvalDecode.decodeInt(len);
		if (pos < 0 || len < 0 || pos + len > src.length) EvalStdLibA.outsideBounds();
		self.addBytes(src, pos, len);
		return VNull;
	});

	// port: `Buffer.contents` copies and leaves the buffer usable; the host
	// `BytesBuffer.getBytes` invalidates it, so the instance gets a new buffer
	// holding a copy of the contents.
	public static final getBytes = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		var b = self.getBytes();
		var nb = new haxe.io.BytesBuffer();
		nb.add(b);
		switch vthis {
			case VInstance(vi): vi.ikind = IOutput(nb);
			case _:
		}
		return EvalEncode.encodeBytes(b);
	});
}

typedef Zresult = libs.extc.Extc.ZResult;

// port: `zfun`: zstream -> src -> spos -> slen -> dst -> dpos -> dlen -> zflush -> zresult.
typedef Zfun = (z:Dynamic, src:Bytes, spos:Int, slen:Int, dst:Bytes, dpos:Int, dlen:Int, flush:Int) -> Zresult;

class StdCompress {
	// port: Extc.zflush, numbered as zlib's flush constants
	public static inline final Z_NO_FLUSH = 0;
	public static inline final Z_PARTIAL_FLUSH = 1;
	public static inline final Z_SYNC_FLUSH = 2;
	public static inline final Z_FULL_FLUSH = 3;
	public static inline final Z_FINISH = 4;

	public static function zlibDeflate(z:Dynamic, src:Bytes, spos:Int, slen:Int, dst:Bytes, dpos:Int, dlen:Int, flush:Int):Zresult {
		return libs.extc.Extc.zlibDeflate(z, src, spos, slen, dst, dpos, dlen, flush);
	}

	static function thisValue(vthis:Value):Vzlib {
		return switch vthis {
			case VInstance({ikind: IZip(zip)}): zip;
			case _: EvalExceptions.unexpectedValue(vthis, "Compress");
		}
	}

	public static function exec(f:Zfun, vthis:Value, src:Value, srcPos:Value, dst:Value, dstPos:Value):Value {
		var self = thisValue(vthis);
		var src = EvalDecode.decodeBytes(src);
		var srcPos = EvalDecode.decodeInt(srcPos);
		var dst = EvalDecode.decodeBytes(dst);
		var dstPos = EvalDecode.decodeInt(dstPos);
		var r = try f(self.z, src, srcPos, src.length - srcPos, dst, dstPos, dst.length - dstPos,
			self.zFlush) catch (_:Dynamic) EvalContext.excString("oops");
		return EvalEncode.encodeObj([
			{name: EvalHash.key_done, value: r.z_finish.vbool()},
			{name: EvalHash.key_read, value: VInt32(r.z_read)},
			{name: EvalHash.key_write, value: VInt32(r.z_wrote)}
		]);
	}

	public static final close = EvalEncode.vifun0(vthis -> {
		libs.extc.Extc.zlibDeflateEnd(thisValue(vthis).z);
		return VNull;
	});

	public static final execute = EvalEncode.vifun4((vthis, src, srcPos, dst, dstPos) -> {
		return exec(zlibDeflate, vthis, src, srcPos, dst, dstPos);
	});

	public static final run = EvalEncode.vfun2((s, level) -> {
		var s = EvalDecode.decodeBytes(s);
		var level = EvalDecode.decodeInt(level);
		var zip = libs.extc.Extc.zlibDeflateInit(level);
		var d = Bytes.alloc(libs.extc.Extc.zlibDeflateBound(zip, s.length));
		d.fill(0, d.length, 0);
		var r = libs.extc.Extc.zlibDeflate(zip, s, 0, s.length, d, 0, d.length, Z_FINISH);
		libs.extc.Extc.zlibDeflateEnd(zip);
		if (!r.z_finish || r.z_read != s.length) EvalContext.excString("Compression failed");
		return EvalEncode.encodeBytes(d.sub(0, r.z_wrote));
	});

	public static final setFlushMode = EvalEncode.vifun1((vthis, f) -> {
		var mode = switch EvalDecode.decodeEnum(f).index {
				case 0: Z_NO_FLUSH;
				case 1: Z_SYNC_FLUSH;
				case 2: Z_FULL_FLUSH;
				case 3: Z_FINISH;
				case 4: Z_PARTIAL_FLUSH;
				case _: Globals.die("", "StdCompress.setFlushMode");
			}
		thisValue(vthis).zFlush = mode;
		return VNull;
	});
}

class StdContext {
	public static final addBreakpoint = EvalEncode.vfun2((file, line) -> {
		var file = EvalDecode.decodeString(file);
		var line = EvalDecode.decodeInt(line);
		try {
			EvalDebugMisc.addBreakpoint(EvalContext.getCtx(), file, line, BPAny, null);
		} catch (_:core.ds.NotFound) {
			EvalContext.excString("Could not find file " + file);
		}
		return VNull;
	});

	public static final breakHere = EvalEncode.vfun0(() -> {
		if (!EvalContext.getCtx().debug.supportDebugger) return VNull;
		else throw new EvalDebugMisc.BreakHere();
	});

	public static final callMacroApi = EvalEncode.vfun1(f -> {
		var f = EvalDecode.decodeString(f);
		var v = GlobalState.macroLib.get(f);
		if (v == null) return EvalContext.excString("Could not find macro function \"" + f + "\"");
		return v;
	});

	public static var plugins:Map<String, Value> = new Map();

	public static var pluginData:Null<Array<{name:String, value:Value}>> = null;

	public static function register(data:Array<{name:String, value:Value}>):Void pluginData = data;

	public static final loadPlugin = EvalEncode.vfun1(filePath -> {
		var filePath = EvalDecode.decodeString(filePath);
		if (plugins.exists(filePath))
			return plugins.get(filePath);
		else {
			// port: Dynlink.loadfile: native plugins cannot be loaded
			return EvalStdLibA.notSupported("Loading native plugins (" + filePath + ")");
		}
	});
}

class StdCrc32 {
	public static final make = EvalEncode.vfun1(data -> {
		var data = EvalDecode.decodeBytes(data);
		var crc32 = haxe.crypto.Crc32.make(data);
		return VInt32(crc32);
	});
}

class StdDate {
	public static function encodeDate(d:Float):Value return EvalEncode.encodeInstance(EvalHash.key_Date, IDate(d));

	static function thisValue(vthis:Value):Float {
		return switch vthis {
			case VInstance({ikind: IDate(d)}): d;
			case v: EvalExceptions.unexpectedValue(v, "date");
		}
	}

	// port: Unix.localtime/gmtime take a time_t (truncated); the host Date gives both views.
	static function tm(d:Float):Date {
		var t = d < 0 ? Math.fceil(d) : Math.ffloor(d);
		return Date.fromTime(t * 1000.);
	}

	// port: Unix.mktime (tm_isdst/tm_wday/tm_yday ignored): seconds of a local time.
	static function mktime(year:Int, mon:Int, mday:Int, hour:Int, min:Int, sec:Int):Float {
		return new Date(year, mon, mday, hour, min, sec).getTime() / 1000.;
	}

	public static final fromTime = EvalEncode.vfun1(f -> encodeDate(EvalDecode.num(f) / 1000.));

	static final reDateTime = ~/^([0-9][0-9][0-9][0-9])-([0-9][0-9])-([0-9][0-9]) ([0-9][0-9]):([0-9][0-9]):([0-9][0-9])$/;
	static final reDate = ~/^([0-9][0-9][0-9][0-9])-([0-9][0-9])-([0-9][0-9])$/;
	static final reTime = ~/^([0-9][0-9]):([0-9][0-9]):([0-9][0-9])$/;

	public static final fromString = EvalEncode.vfun1(s -> {
		var s = EvalDecode.decodeString(s);
		switch s.length {
			case 19:
				var r = reDateTime;
				if (!r.match(s)) EvalContext.excString("Invalid date format : " + s);
				var year = Std.parseInt(r.matched(1));
				var mon = Std.parseInt(r.matched(2)) - 1;
				var mday = Std.parseInt(r.matched(3));
				var hour = Std.parseInt(r.matched(4));
				var min = Std.parseInt(r.matched(5));
				var sec = Std.parseInt(r.matched(6));
				return encodeDate(EvalStdLib.catchUnixError(_ -> mktime(year, mon, mday, hour, min, sec), null));
			case 10:
				var r = reDate;
				if (!r.match(s)) EvalContext.excString("Invalid date format : " + s);
				var year = Std.parseInt(r.matched(1));
				var mon = Std.parseInt(r.matched(2)) - 1;
				var mday = Std.parseInt(r.matched(3));
				return encodeDate(EvalStdLib.catchUnixError(_ -> mktime(year, mon, mday, 0, 0, 0), null));
			case 8:
				var r = reTime;
				if (!r.match(s)) EvalContext.excString("Invalid date format : " + s);
				var h = Std.parseInt(r.matched(1));
				var m = Std.parseInt(r.matched(2));
				var s = Std.parseInt(r.matched(3));
				var t = h * 60 * 60 + m * 60 + s;
				return encodeDate(t);
			case _:
				return EvalContext.excString("Invalid date format : " + s);
		}
	});

	public static final getDate = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getDate()));
	public static final getDay = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getDay()));
	public static final getFullYear = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getFullYear()));
	public static final getHours = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getHours()));
	public static final getMinutes = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getMinutes()));
	public static final getMonth = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getMonth()));
	public static final getSeconds = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getSeconds()));
	public static final getUTCDate = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getUTCDate()));
	public static final getUTCDay = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getUTCDay()));
	public static final getUTCFullYear = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getUTCFullYear()));
	public static final getUTCHours = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getUTCHours()));
	public static final getUTCMinutes = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getUTCMinutes()));
	public static final getUTCMonth = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getUTCMonth()));
	public static final getUTCSeconds = EvalEncode.vifun0(vthis -> VInt32(tm(thisValue(vthis)).getUTCSeconds()));
	public static final getTime = EvalEncode.vifun0(vthis -> VFloat(thisValue(vthis) * 1000.));

	public static final getTimezoneOffset = EvalEncode.vifun0(vthis -> {
		var t = tm(thisValue(vthis));
		// port: mktime of the local and of the UTC broken-down times
		var tsLocal = mktime(t.getFullYear(), t.getMonth(), t.getDate(), t.getHours(), t.getMinutes(), t.getSeconds());
		var tsUTC = mktime(t.getUTCFullYear(), t.getUTCMonth(), t.getUTCDate(), t.getUTCHours(), t.getUTCMinutes(), t.getUTCSeconds());
		return VInt32(Std.int((tsUTC - tsLocal) / 60.));
	});

	// port: Unix.time (whole seconds)
	public static final now = EvalEncode.vfun0(() -> encodeDate(Math.ffloor(Sys.time())));

	public static final toString = EvalEncode.vifun0(vthis -> EvalString.vstring(EvalPrinting.sDate(thisValue(vthis))));
}

class StdDeque {
	static function thisValue(vthis:Value):Vdeque {
		return switch vthis {
			case VInstance({ikind: IDeque(d)}): d;
			case _: EvalExceptions.unexpectedValue(vthis, "Deque");
		}
	}

	public static final add = EvalEncode.vifun1((vthis, i) -> {
		var self = thisValue(vthis);
		EvalThread.Deque.add(self, i);
		return VNull;
	});

	public static final pop = EvalEncode.vifun1((vthis, blocking) -> {
		var self = thisValue(vthis);
		var blocking = EvalDecode.decodeBool(blocking);
		var v = EvalThread.Deque.pop(self, blocking);
		return if (v == null) VNull else v;
	});

	public static final push = EvalEncode.vifun1((vthis, i) -> {
		var self = thisValue(vthis);
		EvalThread.Deque.push(self, i);
		return VNull;
	});
}

// port: upstream compiles with PCRE2 (`UTF|UCP` plus the i/s/m options) and keeps
// the subject and the `substrings` of the last match. Here the host `EReg`
// (compiled with the same options, `g` handled by this module) performs each
// single match through `matchSub(s, pos, len)`, which like `Pcre2.exec ~pos`
// searches `s[0 .. pos+len)` from `pos`. The match is snapshotted as a
// `VregexMatch`; group substrings come from the host's `matched(n)` for the
// host's `matchedNum()` groups (capture count + 1, as `num_of_subs`).
// `replace` reimplements `Pcre2.replace`/`replace_first` and its template
// syntax (`$n`, `${n}`-less digits, `$$`, `$&`, `` $` ``, `$'`, `$+`, `$!`);
// its "nonexistent subpattern" check needs the capture count, which the host
// only reports after a successful match, so a template naming a missing
// group fails only when the pattern matches.
class StdEReg {
	public static function create(r:String, opt:String):VinstanceKind {
		var global = false;
		var hostOpt = new StringBuf();
		for (i in 0...opt.length) {
			var c = opt.charAt(i);
			switch c {
				case "i" | "s" | "m":
					hostOpt.add(c);
				case "u":
				case "g":
					global = true;
				case _:
					throw new Failure("Unsupported regexp option '" + c + "'");
			}
		}
		// port: `UTF :: `UCP :: flags: the host always compiles with UTF and UCP
		var rex = try new EReg(hostPattern(r), hostOpt.toString()) catch (e:Dynamic) throw new Failure(Std.string(e));
		var pcre = new Vregex(rex, EvalString.createAscii('~/$r/$opt'), global);
		return IRegex(pcre);
	}

	// port: PCRE2 takes the pattern with its length; the HashLink host passes a
	// NUL-terminated string, so NUL characters become the `\x00` escape.
	static function hostPattern(r:String):String {
		#if hl
		if (r.indexOf("\x00") < 0) return r;
		var buf = new StringBuf(), backslashes = 0;
		for (i in 0...r.length) {
			var c = r.charCodeAt(i);
			if (c == 0) buf.add(backslashes % 2 == 1 ? "x00" : "\\x00");
			else buf.addChar(c);
			backslashes = c == "\\".code ? backslashes + 1 : 0;
		}
		return buf.toString();
		#else
		return r;
		#end
	}

	static function hostMatchedNum(r:EReg):Int {
		return try r.matchedNum() catch (_:Dynamic) 0;
	}

	// port: `Pcre2.exec ~pos` on `s[0 .. pos+len)`; null for Not_found.
	public static function exec(rex:Vregex, s:String, pos:Int, len:Int = -1):Null<VregexMatch> {
		var r = rex.r;
		if (!r.matchSub(s, pos, len)) return null;
		var p = r.matchedPos();
		var n = hostMatchedNum(r);
		var groups:Array<Null<String>> = [];
		for (i in 0...n) groups.push(try r.matched(i) catch (_:Dynamic) null);
		if (groups.length == 0) groups.push(s.substr(p.pos, p.len));
		return new VregexMatch(p.pos, p.pos + p.len, groups);
	}

	// port: native width of the code point at `i` (where upstream steps one byte after an empty match).
	static function charWidth(s:String, i:Int):Int {
		var c = StringTools.fastCodeAt(s, i);
		if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
			var d = StringTools.fastCodeAt(s, i + 1);
			if (d >= 0xDC00 && d <= 0xDFFF) return 2;
		}
		return 1;
	}

	static function maybeRun(rex:Vregex, n:Int, f:(first:Int, last:Int, sub:String) -> Value):Value {
		var substrings = if (rex.rGroups.length == 0) EvalContext.excString("Invalid regex operation because no match was made") else
			rex.rGroups[0];
		if (n < 0 || n >= substrings.groups.length) return EvalContext.excString("Invalid group");
		var sub = substrings.groups[n];
		if (sub == null) return VNull;
		// port: group offsets are only needed for group 0
		return if (n == 0) f(substrings.first, substrings.last, sub) else f(-1, -1, sub);
	}

	static function thisValue(v:Value):Vregex {
		return switch v {
			case VInstance({ikind: IRegex(rex)}): rex;
			case v: EvalExceptions.unexpectedValue(v, "EReg");
		}
	}

	// port: OCaml Str.quote.
	static function strQuote(s:String):String {
		var buf = new StringBuf();
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			switch c {
				case '['.code | ']'.code | '*'.code | '.'.code | '\\'.code | '?'.code | '+'.code | '^'.code | '$'.code:
					buf.addChar('\\'.code);
					buf.addChar(c);
				case _:
					buf.addChar(c);
			}
		}
		return buf.toString();
	}

	public static final escape = EvalEncode.vfun1(s -> {
		var s = EvalDecode.decodeString(s);
		return EvalString.createUnknown(strQuote(s));
	});

	public static final map = EvalEncode.vifun2((vthis, s, f) -> {
		var self = thisValue(vthis);
		var s = EvalDecode.decodeString(s);
		var l = s.length;
		var buf = new StringBuf();
		function loop(pos:Int):Void {
			while (true) {
				if (pos >= l) return;
				var a = exec(self, s, pos);
				if (a == null) {
					buf.addSub(s, pos, l - pos);
					return;
				}
				self.rGroups = [a];
				var first = a.first, last = a.last;
				buf.addSub(s, pos, first - pos);
				buf.add(EvalDecode.decodeString(EvalPrinting.callValueOn(vthis, f, [vthis])));
				if (last == first) {
					if (last >= l)
						return;
					else {
						if (self.rGlobal) {
							var w = charWidth(s, first);
							buf.addSub(s, first, w);
							pos = first + w;
						} else {
							buf.addSub(s, first, l - first);
							return;
						}
					}
				} else if (self.rGlobal)
					pos = last;
				else {
					buf.addSub(s, last, l - last);
					return;
				}
			}
		}
		self.rString = s;
		loop(0);
		self.rString = "";
		self.rGroups = [];
		return EvalString.createUnknown(buf.toString());
	});

	// port: upstream `match'`
	public static final match = EvalEncode.vifun1((vthis, s) -> {
		var self = thisValue(vthis);
		var s = EvalDecode.decodeString(s);
		self.rString = s;
		var a = try exec(self, s, 0) catch (_:Dynamic) EvalContext.excString("PCRE Error (invalid unicode string?)");
		if (a != null) {
			self.rGroups = [a];
			return VTrue;
		} else {
			self.rGroups = [];
			return VFalse;
		}
	});

	// port: alias of `match` (the name used by the `init_*` tables)
	public static final matchValue = match;

	public static final matched = EvalEncode.vifun1((vthis, n) -> {
		var self = thisValue(vthis);
		var n = EvalDecode.decodeInt(n);
		return maybeRun(self, n, (first, last, sub) -> EvalString.createUnknown(sub));
	});

	public static final matchedLeft = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		return maybeRun(self, 0, (first, _, _) -> EvalString.createUnknown(self.rString.substring(0, first)));
	});

	public static final matchedPos = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		// port: upstream converts byte offsets to character offsets; here native offsets to code points
		function charOffset(s:String, i:Int):Int return core.StringHelper.codePointHost ? i : EvalString.codePointLength(s.substring(0, i));
		return maybeRun(self, 0, (first, last, _) -> {
			var first = charOffset(self.rString, first);
			var last = charOffset(self.rString, last);
			EvalEncode.encodeObj([
				{name: EvalHash.key_pos, value: VInt32(first)},
				{name: EvalHash.key_len, value: VInt32(last - first)}
			]);
		});
	});

	public static final matchedRight = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		return maybeRun(self, 0, (_, last, _) -> EvalString.createUnknown(self.rString.substring(last)));
	});

	public static final matchSub = EvalEncode.vifun3((vthis, s, pos, len) -> {
		var self = thisValue(vthis);
		var s = EvalDecode.decodeString(s);
		var pos = EvalDecode.decodeInt(pos);
		var lenDefault = s.length - pos;
		var len = EvalDecode.defaultInt(len, lenDefault);
		var len = if (len < 0) lenDefault else len;
		if (pos + len > s.length) return VFalse;
		// port: String.sub s 0 (pos + len), then Pcre2.exec_all ~pos: their checks
		if (pos + len < 0) throw new InvalidArgument("String.sub / Bytes.sub");
		if (pos < 0 || len < 0) throw new InvalidArgument("Pcre2.pcre2_match_stub: illegal position");
		var a = exec(self, s, pos, len);
		if (a == null) return VFalse;
		self.rString = s;
		self.rGroups = [a];
		return VTrue;
	});

	public static final matchedNum = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		if (self.rGroups.length == 0)
			return VInt32(0);
		else {
			var substrings = self.rGroups[0];
			return VInt32(substrings.groups.length);
		}
	});

	// port: Pcre2.subst elements
	static inline final SUBST_STRING = 0; // port: (ix, len) in the template
	static inline final BACKREF = 1;
	static inline final MATCH = 2;
	static inline final PRE_MATCH = 3;
	static inline final POST_MATCH = 4;
	static inline final LAST_PAREN_MATCH = 5;

	// port: Pcre2.subst: the elements (in order), the highest backreference and whether `$+` is used.
	static function subst(str:String):{elements:Array<{kind:Int, a:Int, b:Int}>, maxBr:Int, withLp:Bool} {
		var maxBr = 0;
		var withLp = false;
		var lix = str.length - 1;
		var acc:Array<{kind:Int, a:Int, b:Int}> = [];
		var n = 0;
		while (true) {
			if (lix < n) break;
			var i = n;
			while (i <= lix && StringTools.fastCodeAt(str, i) != '$'.code)
				i++;
			if (i > lix) {
				acc.push({kind: SUBST_STRING, a: n, b: lix - n + 1});
				break;
			}
			if (i == lix) {
				acc.push({kind: SUBST_STRING, a: n, b: lix - n + 1});
				break;
			}
			var i1 = i + 1;
			if (n != i) acc.push({kind: SUBST_STRING, a: n, b: i - n});
			var c = StringTools.fastCodeAt(str, i1);
			if (c >= '0'.code && c <= '9'.code) {
				var subpatNr = c - '0'.code;
				var j = i1 + 1;
				while (j <= lix) {
					var c = StringTools.fastCodeAt(str, j);
					if (c >= '0'.code && c <= '9'.code) {
						subpatNr = 10 * subpatNr + c - '0'.code;
						j++;
					} else
						break;
				}
				if (subpatNr > maxBr) maxBr = subpatNr;
				acc.push({kind: BACKREF, a: subpatNr, b: 0});
				if (j > lix) break;
				n = j;
			} else
				switch c {
					case '!'.code:
						n = i1 + 1;
					case '$'.code:
						acc.push({kind: SUBST_STRING, a: i1, b: 1});
						n = i1 + 1;
					case '&'.code:
						acc.push({kind: MATCH, a: 0, b: 0});
						n = i1 + 1;
					case '`'.code:
						acc.push({kind: PRE_MATCH, a: 0, b: 0});
						n = i1 + 1;
					case "'".code:
						acc.push({kind: POST_MATCH, a: 0, b: 0});
						n = i1 + 1;
					case '+'.code:
						withLp = true;
						acc.push({kind: LAST_PAREN_MATCH, a: 0, b: 0});
						n = i1 + 1;
					case _:
						n = i1;
				}
		}
		return {elements: acc, maxBr: maxBr, withLp: withLp};
	}

	// port: Pcre2.calc_trans_lst: the replacement text of one match.
	static function calcTrans(m:VregexMatch, subj:String, templ:String, elements:Array<{kind:Int, a:Int, b:Int}>):String {
		var buf = new StringBuf();
		for (e in elements) {
			switch e.kind {
				case SUBST_STRING:
					buf.addSub(templ, e.a, e.b);
				case BACKREF:
					if (e.a == 0) buf.add(Sys.programPath()); // port: Sys.argv.(0) upstream
					else {
						var g = m.groups[e.a];
						if (g != null) buf.add(g);
					}
				case MATCH:
					buf.addSub(subj, m.first, m.last - m.first);
				case PRE_MATCH:
					buf.addSub(subj, 0, m.first);
				case POST_MATCH:
					buf.addSub(subj, m.last, subj.length - m.last);
				case _: // port: LAST_PAREN_MATCH
					var i = m.groups.length - 1;
					while (m.groups[i] == null)
						i--;
					buf.add(m.groups[i]);
			}
		}
		return buf.toString();
	}

	static function pcreReplace(rex:Vregex, global:Bool, templ:String, subj:String):String {
		var name = global ? "Pcre2.replace" : "Pcre2.replace_first";
		var s = subst(templ);
		inline function check(m:VregexMatch):Void {
			var nsubs = m.groups.length - 1;
			if (s.maxBr > nsubs) throw new Failure(name + ": backreference denotes nonexistent subpattern");
			if (s.withLp && nsubs == 0) throw new Failure(name + ": no backreferences");
		}
		var subjLen = subj.length;
		if (!global) {
			var m = exec(rex, subj, 0);
			if (m == null) return subj;
			check(m);
			return subj.substring(0, m.first) + calcTrans(m, subj, templ, s.elements) + subj.substring(m.last);
		}
		var buf = new StringBuf();
		var curPos = 0;
		while (true) {
			var m = if (curPos > subjLen) null else exec(rex, subj, curPos);
			if (m == null) {
				if (curPos < subjLen) buf.addSub(subj, curPos, subjLen - curPos);
				return buf.toString();
			}
			check(m);
			var first = m.first;
			var len = first - curPos;
			if (len > 0) buf.addSub(subj, curPos, len);
			buf.add(calcTrans(m, subj, templ, s.elements));
			var next = first + 1;
			var last = m.last;
			if (last < next) {
				if (first < subjLen) {
					var w = charWidth(subj, first);
					buf.addSub(subj, curPos + len, w);
					curPos = first + w;
				} else
					curPos = next;
			} else
				curPos = last;
		}
	}

	public static final replace = EvalEncode.vifun2((vthis, s, by) -> {
		var self = thisValue(vthis);
		var s = EvalDecode.decodeString(s);
		var by = EvalDecode.decodeString(by);
		var s = pcreReplace(self, self.rGlobal, by, s);
		return EvalString.createUnknown(s);
	});

	public static final split = EvalEncode.vifun1((vthis, s) -> {
		var self = thisValue(vthis);
		var s = EvalDecode.decodeString(s);
		var slength = s.length;
		if (slength == 0)
			return EvalEncode.encodeArray([EvalString.vEmptyString]);
		else {
			var copyOffset = 0;
			var acc:Array<Value> = [];
			function add(first:Int, last:Int):Void {
				var sub = s.substr(first, last - first);
				acc.push(EvalString.createUnknown(sub));
			}
			function step(pos:Int):Null<Int> {
				var substrings = exec(self, s, pos);
				if (substrings == null) {
					add(copyOffset, slength);
					return null;
				}
				var first = substrings.first, last = substrings.last;
				add(copyOffset, first);
				copyOffset = last;
				var nextStart = if (pos == last) last + (last < slength ? charWidth(s, last) : 1) else last;
				if (nextStart >= slength) {
					acc.push(EvalString.createUnknown(""));
					return null;
				} else
					return nextStart;
			}
			var pos = 0;
			while (true) {
				var next = step(pos);
				if (next == null) break;
				if (self.rGlobal)
					pos = next;
				else {
					add(copyOffset, slength);
					break;
				}
			}
			return EvalEncode.encodeArray(acc);
		}
	});
}

// port: file open flags of `create_out` (Open_creat is always added).
enum OutFlags {
	OAppend; // port: [Open_append]
	OUpdate; // port: [Open_rdonly; Open_wronly]
	OWrite; // port: [Open_wronly; Open_trunc]
}

class StdFile {
	public static function createOut(path:Value, binary:Value, flags:OutFlags):Value {
		var path = EvalDecode.decodeString(path);
		var binary = switch binary {
			case VTrue | VNull: true;
			case _: false;
		}
		var ch:haxe.io.Output = try {
			switch flags {
				case OAppend: sys.io.File.append(path, binary);
				case OUpdate:
					// port: Open_creat
					if (!sys.FileSystem.exists(path)) sys.io.File.saveBytes(path, Bytes.alloc(0));
					sys.io.File.update(path, binary);
				case OWrite: sys.io.File.write(path, binary);
			}
		} catch (e:Dynamic) EvalContext.excString(EvalStdLibA.sysErrorMessage(path, e));
		return EvalEncode.encodeInstance(EvalHash.key_sys_io_FileOutput, IOutChannel(ch));
	}

	public static function writeOut(path:String, content:Bytes):Value {
		try {
			sys.io.File.saveBytes(path, content);
			return VNull;
		} catch (e:Dynamic) {
			return EvalContext.excString(EvalStdLibA.sysErrorMessage(path, e));
		}
	}

	public static final append = EvalEncode.vfun2((path, binary) -> {
		return createOut(path, binary, OAppend);
	});

	public static final update = EvalEncode.vfun2((path, binary) -> {
		return createOut(path, binary, OUpdate);
	});

	public static final getBytes = EvalEncode.vfun1(path -> {
		var path = EvalDecode.decodeString(path);
		var b = try sys.io.File.getBytes(path) catch (_:Dynamic) EvalContext.excString("Could not read file " + path);
		return EvalEncode.encodeBytes(b);
	});

	public static final getContent = EvalEncode.vfun1(path -> {
		var path = EvalDecode.decodeString(path);
		var b = try sys.io.File.getBytes(path) catch (_:Dynamic) EvalContext.excString("Could not read file " + path);
		return EvalString.createUnknown(core.StringHelper.ofBytes(b));
	});

	public static final read = EvalEncode.vfun2((path, binary) -> {
		var path = EvalDecode.decodeString(path);
		var binary = switch binary {
				case VTrue | VNull: true;
				case _: false;
			}
		var ch = try sys.io.File.read(path, binary) catch (e:Dynamic) EvalContext.excString(EvalStdLibA.sysErrorMessage(path, e));
		return EvalEncode.encodeInstance(EvalHash.key_sys_io_FileInput, IInChannel(ch, {v: false}));
	});

	public static final saveBytes = EvalEncode.vfun2((path, bytes) -> {
		var path = EvalDecode.decodeString(path);
		var bytes = EvalDecode.decodeBytes(bytes);
		return writeOut(path, bytes);
	});

	public static final saveContent = EvalEncode.vfun2((path, content) -> {
		var path = EvalDecode.decodeString(path);
		var content = EvalDecode.decodeString(content);
		return writeOut(path, Bytes.ofString(content));
	});

	public static final write = EvalEncode.vfun2((path, binary) -> {
		return createOut(path, binary, OWrite);
	});
}

class StdFileInput {
	public static function raiseEof():Dynamic {
		var v = EvalEncode.encodeInstance(EvalHash.key_haxe_io_Eof);
		return EvalContext.exc(v);
	}

	static function thisValue(vthis:Value):{ch:haxe.io.Input, eof:{v:Bool}} {
		return switch vthis {
			case VInstance({ikind: IInChannel(c, e)}): {ch: c, eof: e};
			case _: EvalExceptions.unexpectedValue(vthis, "FileInput");
		}
	}

	public static final close = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).ch.close();
		return VNull;
	});

	public static final eof = EvalEncode.vifun0(vthis -> {
		return thisValue(vthis).eof.v.vbool();
	});

	public static final seek = EvalEncode.vifun2((vthis, pos, mode) -> {
		var t = thisValue(vthis);
		var ch:sys.io.FileInput = cast t.ch;
		t.eof.v = false;
		var pos = EvalDecode.decodeInt(pos);
		var mode = EvalDecode.decodeEnum(mode).index;
		switch mode {
			case 0: ch.seek(pos, SeekBegin);
			case 1: ch.seek(pos, SeekCur);
			case 2: ch.seek(pos, SeekEnd);
			case _: Globals.die("", "StdFileInput.seek");
		}
		return VNull;
	});

	public static final tell = EvalEncode.vifun0(vthis -> {
		var ch:sys.io.FileInput = cast thisValue(vthis).ch;
		return VInt32(ch.tell());
	});

	public static final readByte = EvalEncode.vifun0(vthis -> {
		var t = thisValue(vthis);
		var i = try {
			EvalLock.blocking(() -> t.ch.readByte());
		} catch (_:Dynamic) {
			t.eof.v = true;
			raiseEof();
		}
		return VInt32(i);
	});

	public static final readBytes = EvalEncode.vifun3((vthis, bytes, pos, len) -> {
		var t = thisValue(vthis);
		var bytes = EvalDecode.decodeBytes(bytes);
		var pos = EvalDecode.decodeInt(pos);
		var len = EvalDecode.decodeInt(len);
		if (pos < 0 || len < 0 || pos > bytes.length - len) throw new InvalidArgument("input");
		// port: `input` returns 0 at end of file; the host raises Eof
		var i = if (len == 0) 0 else try EvalLock.blocking(() -> t.ch.readBytes(bytes, pos, len)) catch (_:haxe.io.Eof) 0;
		if (i == 0) {
			t.eof.v = true;
			raiseEof();
		}
		return VInt32(i);
	});
}

class StdFileOutput {
	static function thisValue(vthis:Value):haxe.io.Output {
		return switch vthis {
			case VInstance({ikind: IOutChannel(ch)}): ch;
			case _: EvalExceptions.unexpectedValue(vthis, "FileOutput");
		}
	}

	public static final close = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).close();
		return VNull;
	});

	public static final flush = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).flush();
		return VNull;
	});

	public static final seek = EvalEncode.vifun2((vthis, pos, mode) -> {
		var self:sys.io.FileOutput = cast thisValue(vthis);
		var pos = EvalDecode.decodeInt(pos);
		var mode = EvalDecode.decodeEnum(mode).index;
		switch mode {
			case 0: self.seek(pos, SeekBegin);
			case 1: self.seek(pos, SeekCur);
			case 2: self.seek(pos, SeekEnd);
			case _: Globals.die("", "StdFileOutput.seek");
		}
		return VNull;
	});

	public static final tell = EvalEncode.vifun0(vthis -> {
		var self:sys.io.FileOutput = cast thisValue(vthis);
		return VInt32(self.tell());
	});

	public static final writeByte = EvalEncode.vifun1((vthis, c) -> {
		var self = thisValue(vthis);
		var c = EvalDecode.decodeInt(c);
		if (c < 0 || c > 255) throw new InvalidArgument("char_of_int");
		self.writeByte(c);
		return VNull;
	});

	public static final writeBytes = EvalEncode.vifun3((vthis, bytes, pos, len) -> {
		var self = thisValue(vthis);
		var bytes = EvalDecode.decodeBytes(bytes);
		var pos = EvalDecode.decodeInt(pos);
		var len = EvalDecode.decodeInt(len);
		if (pos < 0 || len < 0 || pos > bytes.length - len) throw new InvalidArgument("output");
		self.writeFullBytes(bytes, pos, len);
		return VInt32(len);
	});
}

class StdFPHelper {
	public static final doubleToI64 = EvalEncode.vfun1(v -> {
		var f = EvalDecode.num(v);
		var i64 = haxe.io.FPHelper.doubleToI64(f);
		return VInt64(i64);
	});

	public static final floatToI32 = EvalEncode.vfun1(f -> {
		var f = EvalDecode.num(f);
		var i32 = haxe.io.FPHelper.floatToI32(f);
		return VInt32(i32);
	});

	public static final i32ToFloat = EvalEncode.vfun1(i -> {
		var i32 = EvalDecode.decodeI32(i);
		var f = haxe.io.FPHelper.i32ToFloat(i32);
		return VFloat(f);
	});

	public static final i64ToDouble = EvalEncode.vfun2((low, high) -> {
		var low = EvalDecode.decodeI32(low);
		var high = EvalDecode.decodeI32(high);
		var b = Bytes.alloc(8);
		b.fill(0, 8, '0'.code);
		BytesIo.writeI32(b, 0, low);
		BytesIo.writeI32(b, 4, high);
		var i64 = BytesIo.readI64(b, 0);
		return VFloat(haxe.io.FPHelper.i64ToDouble(i64.low, i64.high));
	});
}

class StdFileSystem {
	public static function removeTrailingSlash(p:String):String {
		var l = p.length;
		if (l == 0)
			return ""; // don't be retarded
		else
			return switch p.charAt(l - 1) {
				case "\\" | "/": removeTrailingSlash(p.substr(0, l - 1));
				case _: p;
			}
	}

	public static function patchPath(s:String):String {
		return if (s.length > 1 && s.length <= 3 && s.charAt(1) == ":") core.Path.addTrailingSlash(s) else if (s == "/") "/" else
			removeTrailingSlash(s);
	}

	public static final createDirectory = EvalEncode.vfun1(path -> {
		EvalStdLib.catchUnixError(p -> {
			core.Path.mkdirFromPathUnixErr(p);
			return true;
		}, core.Path.addTrailingSlash(EvalDecode.decodeString(path)));
		return VNull;
	});

	public static final deleteDirectory = EvalEncode.vfun1(path -> {
		EvalStdLib.catchUnixError(p -> {
			sys.FileSystem.deleteDirectory(p);
			return true;
		}, EvalDecode.decodeString(path));
		return VNull;
	});

	public static final deleteFile = EvalEncode.vfun1(path -> {
		var path = EvalDecode.decodeString(path);
		try sys.FileSystem.deleteFile(path)
		catch (e:Dynamic) EvalContext.excString(EvalStdLibA.sysErrorMessage(path, e));
		return VNull;
	});

	public static final exists = EvalEncode.vfun1(path -> {
		var b = try sys.FileSystem.exists(patchPath(EvalDecode.decodeString(path))) catch (_:Dynamic) false;
		return b.vbool();
	});

	public static final fullPath = EvalEncode.vfun1(relPath -> {
		var relPath = EvalDecode.decodeString(relPath);
		var p = try sys.FileSystem.fullPath(relPath) catch (_:Dynamic) null;
		// port: Extc.get_full_path fails with Failure "get_full_path"
		if (p == null) return EvalContext.excString('Failure("get_full_path")');
		return EvalString.createUnknown(p);
	});

	public static final isDirectory = EvalEncode.vfun1(dir -> {
		var b = try sys.FileSystem.isDirectory(patchPath(EvalDecode.decodeString(dir))) catch (_:Dynamic) false;
		return b.vbool();
	});

	public static final readDirectory = EvalEncode.vfun1(dir -> {
		var dir = EvalDecode.decodeString(dir);
		var patched = patchPath(dir);
		if (!sys.FileSystem.exists(patched)) EvalContext.excString(dir + ": No such file or directory");
		var isDir = try sys.FileSystem.isDirectory(patched) catch (e:Dynamic) EvalContext.excString(EvalStdLibA.sysErrorMessage(dir, e));
		if (!isDir) EvalContext.excString("No such directory");
		var d = try sys.FileSystem.readDirectory(dir) catch (e:Dynamic) EvalContext.excString(EvalStdLibA.sysErrorMessage(dir, e));
		return EvalEncode.encodeArray(d.map(s -> EvalString.createUnknown(s)));
	});

	public static final rename = EvalEncode.vfun2((path, newPath) -> {
		var path = EvalDecode.decodeString(path);
		var newPath = EvalDecode.decodeString(newPath);
		try sys.FileSystem.rename(path, newPath)
		catch (e:Dynamic) EvalContext.excString(EvalStdLibA.sysErrorMessage(path, e));
		return VNull;
	});

	public static final stat = EvalEncode.vfun1(path -> {
		var s:sys.FileStat = EvalStdLib.catchUnixError(p -> sys.FileSystem.stat(p), patchPath(EvalDecode.decodeString(path)));
		return EvalEncode.encodeObj([
			{name: EvalHash.key_gid, value: VInt32(s.gid)},
			{name: EvalHash.key_uid, value: VInt32(s.uid)},
			{name: EvalHash.key_atime, value: StdDate.encodeDate(s.atime.getTime() / 1000.)},
			{name: EvalHash.key_mtime, value: StdDate.encodeDate(s.mtime.getTime() / 1000.)},
			{name: EvalHash.key_ctime, value: StdDate.encodeDate(s.ctime.getTime() / 1000.)},
			{name: EvalHash.key_dev, value: VInt32(s.dev)},
			{name: EvalHash.key_ino, value: VInt32(s.ino)},
			{name: EvalHash.key_nlink, value: VInt32(s.nlink)},
			{name: EvalHash.key_rdev, value: VInt32(s.rdev)},
			{name: EvalHash.key_size, value: VInt32(s.size)},
			// port: st_perm
			{name: EvalHash.key_mode, value: VInt32(s.mode & 0xFFF)},
		]);
	});
}

// port: OCaml's Gc is not available: statistics and control fail, collections use the host collector.
class StdGc {
	public static final key_minor_heap_size = EvalHash.hash("minor_heap_size");
	public static final key_major_heap_increment = EvalHash.hash("major_heap_increment");
	public static final key_space_overhead = EvalHash.hash("space_overhead");
	public static final key_verbose = EvalHash.hash("verbose");
	public static final key_max_overhead = EvalHash.hash("max_overhead");
	public static final key_stack_limit = EvalHash.hash("stack_limit");
	public static final key_allocation_policy = EvalHash.hash("allocation_policy");
	public static final key_minor_words = EvalHash.hash("minor_words");
	public static final key_promoted_words = EvalHash.hash("promoted_words");
	public static final key_major_words = EvalHash.hash("major_words");
	public static final key_minor_collections = EvalHash.hash("minor_collections");
	public static final key_major_collections = EvalHash.hash("major_collections");
	public static final key_heap_words = EvalHash.hash("heap_words");
	public static final key_heap_chunks = EvalHash.hash("heap_chunks");
	public static final key_live_words = EvalHash.hash("live_words");
	public static final key_live_blocks = EvalHash.hash("live_blocks");
	public static final key_free_words = EvalHash.hash("free_words");
	public static final key_free_blocks = EvalHash.hash("free_blocks");
	public static final key_largest_free = EvalHash.hash("largest_free");
	public static final key_fragments = EvalHash.hash("fragments");
	public static final key_compactions = EvalHash.hash("compactions");
	public static final key_top_heap_words = EvalHash.hash("top_heap_words");
	public static final key_stack_size = EvalHash.hash("stack_size");

	static function hostCollect(full:Bool = true):Void {
		#if hl
		hl.Gc.major();
		#elseif cpp
		cpp.vm.Gc.run(true);
		#elseif (target.name == "hxmc")
		// port: a collection, then the finalisers it found due (rt.c)
		NativeGc.collect(full);
		NativeGc.runFinalisers();
		#end
	}

	static function unsupported(name:String):Dynamic return EvalStdLibA.notSupported("Gc." + name);

	// port: the host has no OCaml GC statistics. The statistics are zero except the heap
	// size, which the hxmc host measures (as `heap_words`, 8-byte words).
	static function hostStats():Value {
		var heapWords = #if (target.name == "hxmc") Std.int(NativeGc.heapBytes() / 8) #else 0 #end;
		return EvalEncode.encodeObj([
			{name: key_minor_words, value: VFloat(0.)},
			{name: key_promoted_words, value: VFloat(0.)},
			{name: key_major_words, value: VFloat(0.)},
			{name: key_minor_collections, value: VInt32(0)},
			{name: key_major_collections, value: VInt32(0)},
			{name: key_heap_words, value: VInt32(heapWords)},
			{name: key_heap_chunks, value: VInt32(0)},
			{name: key_live_words, value: VInt32(0)},
			{name: key_live_blocks, value: VInt32(0)},
			{name: key_free_words, value: VInt32(0)},
			{name: key_free_blocks, value: VInt32(0)},
			{name: key_largest_free, value: VInt32(0)},
			{name: key_fragments, value: VInt32(0)},
			{name: key_compactions, value: VInt32(0)},
			{name: key_top_heap_words, value: VInt32(heapWords)},
			{name: key_stack_size, value: VInt32(0)}
		]);
	}

	// port: Gc.control is kept for get/set (OCaml 5.2's defaults) and has no effect on the host GC.
	static var control = {
		minorHeapSize: 262144,
		majorHeapIncrement: 15,
		spaceOverhead: 120,
		verbose: 0,
		maxOverhead: 500,
		stackLimit: 134217728,
		allocationPolicy: 2
	};

	public static final allocatedBytes = EvalEncode.vfun0(() -> VFloat(0.));

	public static final compact = EvalEncode.vfun0(() -> {
		hostCollect();
		return VNull;
	});

	public static final counters = EvalEncode.vfun0(() -> {
		EvalEncode.encodeObj([
			{name: key_minor_words, value: VFloat(0.)},
			{name: key_promoted_words, value: VFloat(0.)},
			{name: key_major_words, value: VFloat(0.)}
		]);
	});

	#if (target.name == "hxmc")
	// port: the hxmc host GC has OCaml's finalisers (hxmc/std/hxmc/rt/Gc.hx)
	public static final finalise = EvalEncode.vfun2((f, v) -> {
		NativeGc.finalise((v:Value) -> {
			EvalMisc.callValue(f, [v]);
		}, v);
		VNull;
	});

	// port: finalisers run one after the other already
	public static final finaliseRelease = EvalEncode.vfun0(() -> VNull);
	#else
	public static final finalise = EvalEncode.vfun2((f, v) -> unsupported("finalise"));

	// port: no finalisers are ever registered
	public static final finaliseRelease = EvalEncode.vfun0(() -> VNull);
	#end

	public static final fullMajor = EvalEncode.vfun0(() -> {
		hostCollect();
		return VNull;
	});

	public static final get = EvalEncode.vfun0(() -> {
		EvalEncode.encodeObj([
			{name: key_minor_heap_size, value: VInt32(control.minorHeapSize)},
			{name: key_major_heap_increment, value: VInt32(control.majorHeapIncrement)},
			{name: key_space_overhead, value: VInt32(control.spaceOverhead)},
			{name: key_verbose, value: VInt32(control.verbose)},
			{name: key_max_overhead, value: VInt32(control.maxOverhead)},
			{name: key_stack_limit, value: VInt32(control.stackLimit)},
			{name: key_allocation_policy, value: VInt32(control.allocationPolicy)}
		]);
	});

	public static final major = EvalEncode.vfun0(() -> {
		hostCollect();
		return VNull;
	});

	// port: OCaml 5's Gc.major_slice returns 0
	public static final majorSlice = EvalEncode.vfun1(n -> {
		EvalDecode.decodeInt(n);
		hostCollect(false);
		VInt32(0);
	});

	public static final minor = EvalEncode.vfun0(() -> {
		hostCollect(false);
		return VNull;
	});

	public static final printStat = EvalEncode.vfun1(outChannel -> {
		switch outChannel {
			case VInstance({ikind: IOutChannel(_)}):
			case _: EvalExceptions.unexpectedValue(outChannel, "Output");
		}
		return unsupported("print_stat");
	});

	public static final quickStat = EvalEncode.vfun0(() -> hostStats());

	public static final set = EvalEncode.vfun1(r -> {
		var r = EvalDecode.decodeObject(r);
		function field(key) return EvalDecode.decodeInt(EvalField.objectField(r, key));
		control = {
			minorHeapSize: field(key_minor_heap_size),
			majorHeapIncrement: field(key_major_heap_increment),
			spaceOverhead: field(key_space_overhead),
			verbose: field(key_verbose),
			maxOverhead: field(key_max_overhead),
			stackLimit: field(key_stack_limit),
			allocationPolicy: control.allocationPolicy
		};
		/* Awkward hack to avoid warning. */
		control.allocationPolicy = field(key_allocation_policy);
		return VNull;
	});

	public static final stat = EvalEncode.vfun0(() -> hostStats());
}

class StdHost {
	// port: dotted address of a host-order int32 (upstream returns `Unix.inet_addr`).
	public static function int32Addr(h:Int):String {
		var base = h & 0xFFFFFF;
		return '${h >>> 24}.${base >>> 16}.${(base >>> 8) & 0xFF}.${base & 0xFF}';
	}

	public static final localhost = EvalEncode.vfun0(() -> {
		#if (target.name == "hxmc")
		// port: catch_unix_error Unix.gethostname
		var name = NativeNet.gethostname();
		if (name == null) macros.eval.EvalStdLibB.StdSocket.unixError("gethostname");
		return EvalString.createUnknown(name);
		#else
		return EvalString.createUnknown(EvalStdLib.catchUnixError(_ -> sys.net.Host.localhost(), null));
		#end
	});

	public static final hostReverse = EvalEncode.vfun1(ip -> {
		var ip = EvalDecode.decodeI32(ip);
		#if (target.name == "hxmc")
		// port: Unix.gethostbyaddr raises Not_found
		var name = NativeNet.reverse(ip);
		if (name == null) EvalContext.excString("Could not reverse host");
		#else
		var name = try new sys.net.Host(int32Addr(ip)).reverse() catch (_:Dynamic) EvalContext.excString("Could not reverse host");
		#end
		return EvalString.createUnknown(name);
	});

	public static final hostToString = EvalEncode.vfun1(ip -> {
		var ip = EvalDecode.decodeI32(ip);
		return EvalString.createUnknown(int32Addr(ip));
	});

	public static final resolve = EvalEncode.vfun1(name -> {
		var name = EvalDecode.decodeString(name);
		#if (target.name == "hxmc")
		// port: Unix.gethostbyname raises Not_found; the address is h_addr_list.(0)
		var a = NativeNet.resolve(name);
		if (a == null) EvalContext.excString('Could not resolve host $name');
		return VInt32(a[0]);
		#else
		var h = try new sys.net.Host(name) catch (_:Dynamic) EvalContext.excString('Could not resolve host $name');
		var addr = h.toString();
		var parts = addr.split(".").map(Std.parseInt);
		var a = parts[0], b = parts[1], c = parts[2], d = parts[3];
		return VInt32((a << 24) | (d | (c << 8) | (b << 16)));
		#end
	});
}

// Yield between spin-loop iterations when waiting on a lock or semaphore
// with a timeout. Unix.sleepf 0.0 calls caml_enter_blocking_section /
// caml_leave_blocking_section, which releases the OCaml domain lock for the
// duration of the nanosleep. This is required for Thread and LuvThread modes,
// where all threads share one domain lock: without it, the spinning thread
// holds the domain lock and prevents other threads from running OCaml code
// (including the code that would release the lock), causing a deadlock.
// For Domain mode this is also safe — each domain has its own lock — and the
// brief syscall is a reasonable price for correct cross-mode behaviour.
// port: the port yields with `EvalLock.yieldNow`, which gives up the Eval lock.
class StdLock {
	static function thisValue(vthis:Value):Vlock {
		return switch vthis {
			case VInstance({ikind: ILock(lock)}): lock;
			case v: EvalExceptions.unexpectedValue(v, "Lock");
		}
	}

	public static final release = EvalEncode.vifun0(vthis -> {
		var lock = thisValue(vthis);
		lock.lcond.acquire();
		lock.lcount = lock.lcount + 1;
		lock.lcond.signal();
		lock.lcond.release();
		return VNull;
	});

	public static final wait = EvalEncode.vifun1((vthis, timeout) -> {
		var lock = thisValue(vthis);
		switch timeout {
			case VNull:
				EvalLock.blocking(() -> {
					lock.lcond.acquire();
					while (lock.lcount == 0)
						lock.lcond.wait();
					lock.lcount = lock.lcount - 1;
					lock.lcond.release();
					true;
				});
				return VTrue;
			case _:
				var timeout = EvalDecode.num(timeout);
				var deadline = Sys.time() + timeout;
				function loop():Value {
					while (true) {
						lock.lcond.acquire();
						if (lock.lcount > 0) {
							lock.lcount = lock.lcount - 1;
							lock.lcond.release();
							return VTrue;
						} else {
							lock.lcond.release();
							if (Sys.time() >= deadline) return VFalse;
							else EvalLock.yieldNow();
						}
					}
				}
				return loop();
		}
	});
}
