package ml2hx.std;

import Array as HArray;
import String;
import StdTypes;
import ml2hx.rt.*;
import ml2hx.std.Ipaddr;

// An IPv6 address: its eight 16-bit components.
typedef IpaddrV6T = HArray<Int>;

@:allow(ml2hx.std.Ipaddr)
class Ipaddr_V6 {
	static function ofStringRaw(s:String, i:Ref<Int>):IpaddrV6T {
		var compressed = false;
		var len = s.length;
		if (len < i.value + 1) throw Ipaddr.needMore(s);
		var useBracket = StringTools.fastCodeAt(s, i.value) == "[".code;
		if (useBracket) i.value++;
		if (len < i.value + 2) throw Ipaddr.needMore(s);
		var l:HArray<Int> = [];
		if (StringTools.fastCodeAt(s, i.value) == ":".code) {
			i.value++;
			if (StringTools.fastCodeAt(s, i.value) == ":".code) {
				compressed = true;
				i.value++;
				l = [-1];
			} else throw Ipaddr.badChar(i.value, s);
		}
		// acc is in reverse order (head first), as the OCaml list
		var acc = l.copy();
		var nb = l.length;
		while (true) {
			if (nb >= 8 || i.value >= len) break;
			var pos = i.value;
			var x = try Ipaddr.parseInt(16, s, i) catch (e:IpaddrParseError) -1;
			if (x < 0) break;
			if (nb == 7) { acc.unshift(x); break; }
			if (i.value < len && StringTools.fastCodeAt(s, i.value) == ":".code) {
				i.value++;
				if (i.value < len) {
					if (StringTools.fastCodeAt(s, i.value) == ":".code) {
						if (compressed) { i.value--; acc.unshift(x); break; }
						compressed = true;
						i.value++;
						acc.unshift(x);
						acc.unshift(-1);
						nb += 2;
						continue;
					} else if (Ipaddr.digit(StringTools.fastCodeAt(s, i.value)) >= 0) {
						acc.unshift(x);
						nb++;
						continue;
					} else throw Ipaddr.badChar(i.value, s);
				} else throw Ipaddr.needMore(s);
			} else if (i.value < len && StringTools.fastCodeAt(s, i.value) == ".".code) {
				i.value = pos;
				var v4 = Ipaddr_V4.ofStringRaw(s, i);
				acc.unshift((v4 >>> 16) & 0xffff);
				acc.unshift(v4 & 0xffff);
				break;
			} else { acc.unshift(x); break; }
		}
		var resLen = acc.length;
		if (resLen > 8) throw new IpaddrParseError("too many components", s);
		if (resLen == 0) throw Ipaddr.needMore(s);
		var a = [for (_ in 0...8) 0];
		var missing = if (compressed) 8 - (resLen - 1) else if (resLen != 8) { if (i.value < len) throw Ipaddr.badChar(i.value, s); else throw Ipaddr.needMore(s); } else 0;
		var k = 7;
		for (x in acc) {
			if (x == -1) k -= missing; else {
				if (x & 0xffff != x) throw new IpaddrParseError('component $k out of bounds', s);
				a[k] = x;
				k--;
			}
		}
		if (useBracket) Ipaddr.expectChar(s, i, "]".code);
		return a;
	}
	public static function ofStringExn(s:String):IpaddrV6T {
		var o = new Ref(0);
		var x = ofStringRaw(s, o);
		Ipaddr.expectEnd(s, o);
		return x;
	}
	// RFC 5952, as ipaddr's to_buffer
	public static function toString(c:IpaddrV6T):String {
		var v4 = c[0] == 0 && c[1] == 0 && c[2] == 0 && c[3] == 0 && c[4] == 0 && c[5] == 0xffff;
		// runs of zeros: longest of length >= 2 is elided (the first if tied)
		var bestStart = -1, bestLen = 1, i = 0;
		while (i < 8) {
			if (c[i] == 0) {
				var j = i;
				while (j < 8 && c[j] == 0) j++;
				if (j - i > bestLen) { bestStart = i; bestLen = j - i; }
				i = j;
			} else i++;
		}
		var b = new StringBuf();
		var parts = [for (k in 0...8) k];
		var k = 0;
		var limit = v4 ? 6 : 8;
		while (k < limit) {
			if (k == bestStart) {
				b.add("::");
				k += bestLen;
				continue;
			}
			b.add(StringTools.hex(c[k]).toLowerCase());
			k++;
			if (k < limit && k != bestStart) b.add(":");
		}
		if (v4) {
			if (bestStart + bestLen < 6 || bestStart == -1) b.add(":");
			b.add(Ipaddr_V4.toString((c[6] << 16) | c[7]));
		}
		return b.toString();
	}
}
