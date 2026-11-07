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

import macros.eval.EvalValue;

// port: upstream strings are UTF-8 with character (code point) indices and cached
// byte offsets. Here a string is native; "byte offsets" are native string
// indices, and character indices are code points; the cache of offsets
// (`soffsets`) is upstream's, over native indices. Strings without surrogate
// pairs (`sbmp`) need no walk: a character index is the native index. On a code point host
// (core.StringHelper.codePointHost: Eval's own semantics, the host caching the
// offsets) every string is such a string: native lengths are code points.
// How to store a new offset pair, relative to the cached pairs that were read.
enum OffsetUpdate {
	Single;
	Before(pair:VstringOffset);
	After(pair:VstringOffset);
}

class EvalString {
	public static inline function vstring(s:Vstring):Value return VString(s);

	public static function createAscii(s:String):Vstring return new Vstring(s, s.length, true);

	public static function createWithLength(s:String, length:Int):Vstring return new Vstring(s, length, length == s.length);

	public static final emptyString:Vstring = createAscii("");

	public static final vEmptyString:Value = VString(emptyString);

	public static function codePointLength(s:String):Int {
		if (core.StringHelper.codePointHost) return s.length;
		var n = s.length;
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if (c >= 0xDC00 && c <= 0xDFFF && i > 0) {
				var p = StringTools.fastCodeAt(s, i - 1);
				if (p >= 0xD800 && p <= 0xDBFF) n--;
			}
		}
		return n;
	}

	// port: bytes that are not UTF-8 (lone U+DC80 to U+DCFF on a UTF-16 host:
	// core.StringHelper.codePointHost) are one character each, where upstream
	// counts by their first bytes (UTF8.length) or, failing, takes the byte
	// length; such a string's bytes are kept, its indexing is the port's.
	public static function createUnknownVstring(s:String):Vstring return createWithLength(s, codePointLength(s));

	public static function createUnknown(s:String):Value return VString(createUnknownVstring(s));

	public static function concat(s1:Vstring,
			s2:Vstring):Vstring return new Vstring(s1.sstring + s2.sstring, s1.slength +
			s2.slength, s1.sbmp && s2.sbmp && !joinsSurrogates(s1.sstring, s2.sstring));

	static function joinsSurrogates(a:String, b:String):Bool {
		if (a.length == 0 || b.length == 0) return false;
		var x = StringTools.fastCodeAt(a, a.length - 1),
			y = StringTools.fastCodeAt(b, 0);
		return x >= 0xD800 && x <= 0xDBFF && y >= 0xDC00 && y <= 0xDFFF;
	}

	public static function join(sep:Vstring, sl:Array<Vstring>):Vstring {
		var buf = new StringBuf();
		var first = true;
		for (s in sl) {
			if (!first) buf.add(sep.sstring);
			buf.add(s.sstring);
			first = false;
		}
		return createUnknownVstring(buf.toString());
	}

	// port: get_offset', which returns the native index of the character
	// (code point) at `cIndex` with how its caller stores the new pair.
	static function getOffset_(s:Vstring, cIndex:Int):{bOffset:Int, update:OffsetUpdate} {
		var offsets = s.soffsets;
		switch offsets == null ? 0 : offsets.length {
			case 0:
				return {bOffset: getBOffset(s, cIndex, 0), update: Single};
			case 1:
				var r1 = offsets[0];
				var cIndex1 = r1.cIndex;
				var bOffset1 = r1.bOffset;
				var diff = cIndex - cIndex1;
				var bOffset = switch diff {
					case 0: bOffset1;
					case 1: next(s, bOffset1);
					case -1: prev(s, bOffset1);
					case _:
						if (diff > 0) getBOffset(s, diff, bOffset1) else if (cIndex + diff < 0)
							/* big step backwards, better to start over */
							getBOffset(s, cIndex, 0) else rgetBOffset(s, diff, bOffset1);
				}
				/* If our jump is larger than the scientifically determined value 20, upgrade
					to two offset pointers. */
				var update = if (diff > 20 || diff < -20) Before(r1) else Single;
				return {bOffset: bOffset, update: update};
			case 2:
				var r1 = offsets[0], r2 = offsets[1];
				var cIndex1 = r1.cIndex, bOffset1 = r1.bOffset;
				var cIndex2 = r2.cIndex, bOffset2 = r2.bOffset;
				var diff1 = cIndex - cIndex1;
				var diff2 = cIndex - cIndex2;
				// Updating the first pair keeps the second one and vice versa.
				var update1 = Before(r2);
				var update2 = After(r1);
				if (diff1 == 0) return {bOffset: bOffset1, update: update1};
				if (diff2 == 0) return {bOffset: bOffset2, update: update2};
				if (diff1 == 1) return {bOffset: next(s, bOffset1), update: update1};
				if (diff2 == 1) return {bOffset: next(s, bOffset2), update: update2};
				if (diff1 == -1) return {bOffset: prev(s, bOffset1), update: update1};
				if (diff2 == -1) return {bOffset: prev(s, bOffset2), update: update2};
				var far = (diff1 < 0 ? -diff1 : diff1) > (diff2 < 0 ? -diff2 : diff2);
				var update = far ? update2 : update1;
				var diff = far ? diff2 : diff1;
				var bOffset_ = far ? bOffset2 : bOffset1;
				var bOffset = if (diff > 0) getBOffset(s, diff, bOffset_) else if (cIndex + diff < 0)
					/* big step backwards, better to start over */
					getBOffset(s, cIndex, 0) else rgetBOffset(s, diff, bOffset_);
				return {bOffset: bOffset, update: update};
			case _:
				// The cache never has more than two pairs, but start over if it does.
				return {bOffset: getBOffset(s, cIndex, 0), update: Single};
		}
	}

	// Other threads may read or replace the cache at any time, so this builds a new list
	// instead of modifying the one that was read. A concurrent update may be lost, which
	// only means that the offset is computed again later.
	static function setOffsets(s:Vstring, update:OffsetUpdate, pair:VstringOffset):Void {
		s.soffsets = switch update {
			case Single: [pair];
			case Before(pair_): [pair, pair_];
			case After(pair_): [pair_, pair];
		}
	}

	// port: get_b_offset; with a negative count it walks on until UTF8.next
	// reads past the end.
	static function getBOffset(s:Vstring, cLen:Int, bOffset:Int):Int {
		if (cLen < 0) return outOfBounds();
		return move(s, bOffset, cLen);
	}

	static function rgetBOffset(s:Vstring, cLen:Int, bOffset:Int):Int {
		while (cLen != 0) {
			bOffset = prev(s, bOffset);
			cLen++;
		}
		return bOffset;
	}

	// port: native index of the character (code point) at `cIndex`.
	public static function getOffset(s:Vstring, cIndex:Int):Int {
		var r = getOffset_(s, cIndex);
		setOffsets(s, r.update, new VstringOffset(cIndex, r.bOffset));
		return r.bOffset;
	}

	// port: UTF8.next and UTF8.prev on native indices: a surrogate pair is one
	// character. Both read the string where OCaml's s.[i] checks the index.
	static function next(s:Vstring, b:Int):Int {
		if (b < 0 || b >= s.sstring.length) outOfBounds();
		return s.sbmp ? b + 1 : b + (isHighSurrogateAt(s.sstring, b) ? 2 : 1);
	}

	static function prev(s:Vstring, b:Int):Int {
		var i = b - 1;
		if (i < 0) return -1;
		if (i >= s.sstring.length) outOfBounds();
		if (s.sbmp || i == 0) return i;
		var y = StringTools.fastCodeAt(s.sstring, i);
		return y >= 0xDC00 && y <= 0xDFFF && isHighSurrogateAt(s.sstring, i - 1) ? i - 1 : i;
	}

	// port: OCaml's s.[i] past either end of the string.
	static function outOfBounds():Dynamic throw new core.ds.InvalidArgument("index out of bounds");

	static inline function isHighSurrogateAt(s:String, i:Int):Bool {
		var x = StringTools.fastCodeAt(s, i);
		return x >= 0xD800 && x <= 0xDBFF && i + 1 < s.length && {
			var y = StringTools.fastCodeAt(s, i + 1);
			y >= 0xDC00 && y <= 0xDFFF;
		};
	}

	// port: native index `b` moved by `cLength` characters (UTF8.move).
	public static function move(s:Vstring, b:Int, cLength:Int):Int {
		if (cLength >= 0) {
			if (s.sbmp) {
				// port: next's reads of b .. b + cLength - 1 at once
				if (cLength > 0 && (b < 0 || b + cLength > s.sstring.length)) outOfBounds();
				return b + cLength;
			}
			while (cLength > 0) {
				b = next(s, b);
				cLength--;
			}
			return b;
		}
		while (cLength < 0) {
			b = prev(s, b);
			cLength++;
		}
		return b;
	}

	// port: the code point at character index `cIndex`; the entry moves past it.
	public static function charAt(s:Vstring, cIndex:Int):Int {
		var r = getOffset_(s, cIndex);
		var b = r.bOffset;
		var str = s.sstring;
		if (b < 0 || b >= str.length) outOfBounds();
		var x = StringTools.fastCodeAt(str, b);
		var diff = 1;
		if (!s.sbmp && isHighSurrogateAt(str, b)) {
			x = ((x - 0xD800) << 10) + (StringTools.fastCodeAt(str, b + 1) - 0xDC00) + 0x10000;
			diff = 2;
		}
		setOffsets(s, r.update, new VstringOffset(cIndex + 1, b + diff));
		return x;
	}

	// port: a lone surrogate is one character, as upstream's; on a UTF-16 host
	// (core.StringHelper.codePointHost) one from U+DC80 to U+DCFF is written
	// out as the byte it stands for there (0x80 to 0xFF), where upstream's
	// string holds its three bytes.
	public static function stringOfCharCode(i:Int):String {
		if (i < 0x10000) return String.fromCharCode(i);
		var u = new StringBuf();
		u.addChar(i);
		return u.toString();
	}

	public static function fromCharCode(i:Int):Vstring return new Vstring(stringOfCharCode(i), 1, core.StringHelper.codePointHost || i < 0x10000);

	// port: the returned search function yields the character index and the start
	// and end native indices instead of upstream's tuple.
	public static function findSubstring(self:Vstring, sub:Vstring, reverse:Bool):(cIndex:Int, bIndex:Int) -> {c: Int, b: Int, e: Int} {
		var clThis = self.slength;
		var clSub = sub.slength;
		var sThis = self.sstring;
		var sSub = sub.sstring;
		var blThis = sThis.length;
		var blSub = sSub.length;
		function hit(b:Int):Bool {
			if (b < 0 || b + blSub > blThis) return false;
			for (k in 0...blSub) if (StringTools.fastCodeAt(sThis, b + k) != StringTools.fastCodeAt(sSub, k)) return false;
			return true;
		}
		// port: a code point host (core.StringHelper.codePointHost) searches its
		// strings itself (native indices are character indices there): the
		// first hit from bIndex on, the last from bIndex down
		if (core.StringHelper.codePointHost && blSub > 0) {
			return function(cIndex, bIndex) {
				if (cIndex > clThis - clSub || (reverse && bIndex < 0)) throw core.ds.NotFound.raise();
				var b = reverse ? sThis.lastIndexOf(sSub, bIndex) : sThis.indexOf(sSub, bIndex < 0 ? 0 : bIndex);
				if (b < 0) throw core.ds.NotFound.raise();
				return {c: cIndex + (b - bIndex), b: b, e: b + blSub};
			}
		}
		if (!reverse) {
			return function(cIndex, bIndex) {
				while (true) {
					if (cIndex > clThis - clSub || bIndex >= blThis) {
						// port: an empty needle matches at the end
						if (blSub == 0 && cIndex <= clThis && bIndex <= blThis) return {c: cIndex, b: bIndex, e: bIndex};
						throw core.ds.NotFound.raise();
					}
					if (hit(bIndex)) return {c: cIndex, b: bIndex, e: bIndex + blSub};
					bIndex += !self.sbmp && isHighSurrogateAt(sThis, bIndex) ? 2 : 1;
					cIndex++;
				}
			}
		} else {
			return function(cIndex, bIndex) {
				while (true) {
					if (cIndex > clThis - clSub || bIndex < 0) throw core.ds.NotFound.raise();
					if (hit(bIndex)) return {c: cIndex, b: bIndex, e: bIndex + blSub};
					cIndex--;
					bIndex -= (!self.sbmp && bIndex >= 2 && isHighSurrogateAt(sThis, bIndex - 2)) ? 2 : 1;
				}
			}
		}
	}

	public static function caseMap(self:Vstring, upper:Bool):Vstring {
		var buf = new StringBuf();
		var a = upper ? EvalBytesUnicase._UPPER : EvalBytesUnicase._LOWER;
		var m = upper ? 1022 : 1021;
		var s = self.sstring;
		var i = 0;
		while (i < s.length) {
			var c = StringTools.fastCodeAt(s, i++);
			if (c >= 0xD800 && c <= 0xDBFF && i < s.length) {
				var d = StringTools.fastCodeAt(s, i);
				if (d >= 0xDC00 && d <= 0xDFFF) {
					c = ((c - 0xD800) << 10) + (d - 0xDC00) + 0x10000;
					i++;
				}
			}
			var up = c >>> 6;
			if (up < m) {
				var c2 = a[up][c & ((1 << 6) - 1)];
				if (c2 != 0) c = c2;
			}
			buf.addChar(c);
		}
		return createWithLength(buf.toString(), self.slength);
	}

	public static function substr(self:Vstring, cIndex:Int, cLength:Int):Vstring {
		if (cLength < 0) return createWithLength("", 0);
		var b1 = getOffset(self, cIndex);
		var b2 = move(self, b1, cLength);
		return new Vstring(self.sstring.substring(b1, b2), cLength, self.sbmp);
	}

	// port: OCaml's String.compare on the UTF-8 encodings: code point order (the
	// order of a code point host's strings).
	public static function compareCodePoints(a:String, b:String):Int return core.ds.Key.compareStrings(a, b);

	// port: module VStringBuffer

	public static function bufferCreate():VstringBuffer return new VstringBuffer();

	public static function bufferAddString(self:VstringBuffer, s:Vstring):Void {
		self.bbuffer.add(s.sstring);
		self.blength += s.slength;
	}

	public static function bufferAddSubstring(self:VstringBuffer, s:Vstring, bPos:Int, bLen:Int, cLen:Int):Void {
		self.bbuffer.add(s.sstring.substr(bPos, bLen));
		self.blength += cLen;
	}

	// port: Buffer.clear: a fresh host buffer
	public static function bufferClear(self:VstringBuffer):Void {
		self.bbuffer = new StringBuf();
		self.blength = 0;
	}

	public static function bufferContents(self:VstringBuffer):Vstring return createUnknownVstring(self.bbuffer.toString());
}
