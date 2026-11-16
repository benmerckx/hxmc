package hxmc.neko;

import haxe.io.Bytes;
import hxmc.neko.Prims.Register;
import hxmc.neko.Value;

using hxmc.neko.Builtins.Check;

class NRegexp {
	public final re:hxmc.Regex;
	// the 'u' option: pattern and subject UTF-8 (PCRE2_UTF), positions still bytes
	public final utf8:Bool;
	// the subject of the last match, null when it failed
	public var str:Null<NStr>;
	public var subj:Null<Subject>;

	public function new(re, utf8) {
		this.re = re;
		this.utf8 = utf8;
	}

	// a capture's byte offset in the subject (an end inside a surrogate pair:
	// the character's end, PCRE matching whole characters)
	public inline function cap(k:Int):Int {
		var u = re.caps[k];
		var tb = subj.toByte;
		return if (u < 0 || tb == null) u else if (k & 1 == 1 && u > 0 && tb[u] == tb[u - 1]) tb[u + 1] else tb[u];
	}
}

// a subject as the engine sees it: one code unit per byte, or (utf8) its
// characters decoded, with the byte offset of each unit and the unit of each
// byte offset (a byte inside a character: the character after it)
class Subject {
	public final b:Bytes;
	public final s:String;
	public final toByte:Null<haxe.ds.Vector<Int>>;
	public final toUnit:Null<haxe.ds.Vector<Int>>;
	// (utf8: the bytes are well-formed UTF-8, as PCRE2_UTF requires of a subject)
	public var valid = true;

	public function new(b, s, toByte, toUnit) {
		this.b = b;
		this.s = s;
		this.toByte = toByte;
		this.toUnit = toUnit;
	}

	// PCRE2_UTF's checks of a match: the subject well-formed, the start
	// offset at a character
	public function check(p:Int) {
		if (toByte != null && (!valid || (p < b.length && toByte[toUnit[p]] != p)))
			throw VM.error("An error occurred while running pcre2_match");
	}

	public inline function unit(p:Int):Int
		return toUnit == null ? p : toUnit[p];

	public static function utf8(b:Bytes):Subject {
		var sb = new StringBuf();
		var toByte:Array<Int> = [];
		var toUnit = new haxe.ds.Vector<Int>(b.length + 1);
		var i = 0, n = b.length, valid = true;
		inline function cont(k:Int)
			return b.get(k) & 0xC0 == 0x80;
		while (i < n) {
			var c = b.get(i), len = 1;
			if (c >= 0x80 && !(c >= 0xC2 && c < 0xE0 && i + 1 < n && cont(i + 1))
				&& !(c >= 0xE0 && c < 0xF0 && i + 2 < n && cont(i + 1) && cont(i + 2))
				&& !(c >= 0xF0 && c < 0xF5 && i + 3 < n && cont(i + 1) && cont(i + 2) && cont(i + 3)))
				valid = false;
			if (c >= 0xF0 && i + 3 < n) {
				c = ((c & 7) << 18) | ((b.get(i + 1) & 0x3F) << 12) | ((b.get(i + 2) & 0x3F) << 6) | (b.get(i + 3) & 0x3F);
				len = 4;
			} else if (c >= 0xE0 && i + 2 < n) {
				c = ((c & 0xF) << 12) | ((b.get(i + 1) & 0x3F) << 6) | (b.get(i + 2) & 0x3F);
				len = 3;
			} else if (c >= 0xC0 && i + 1 < n) {
				c = ((c & 0x1F) << 6) | (b.get(i + 1) & 0x3F);
				len = 2;
			}
			var u0 = toByte.length;
			sb.addChar(c);
			// (one unit per char, two for a surrogate pair)
			var units = c >= 0x10000 ? 2 : 1;
			for (_ in 0...units)
				toByte.push(i);
			for (k in 0...len)
				toUnit[i + k] = k == 0 ? u0 : u0 + units;
			i += len;
		}
		toByte.push(n);
		toUnit[n] = toByte.length - 1;
		var sj = new Subject(b, sb.toString(), haxe.ds.Vector.fromArrayCopy(toByte), toUnit);
		sj.valid = valid;
		return sj;
	}
}

// libs/regexp over hxmc's engine (hxmc.Regex): Neko's strings are bytes, PCRE
// without its UTF option matches them byte by byte, so the subject and the
// pattern are given to the engine as one code unit per byte
class RegexpPrims {
	// (the last subject's text, by identity)
	static final last = new sys.thread.Tls<{b:Bytes, s:String}>();
	static final lastUtf8 = new sys.thread.Tls<Subject>();

	static function subject(d:NRegexp, b:Bytes):Subject {
		if (!d.utf8) return new Subject(b, text(b), null, null);
		var l = lastUtf8.value;
		if (l != null && l.b == b && l.toUnit.length == b.length + 1) return l;
		var s = Subject.utf8(b);
		lastUtf8.value = s;
		return s;
	}

	public static function text(b:Bytes):String {
		var l = last.value;
		if (l != null && l.b == b && l.s.length == b.length) return l.s;
		var sb = new StringBuf();
		for (i in 0...b.length)
			sb.addChar(b.get(i));
		var s = sb.toString();
		last.value = {b: b, s: s};
		return s;
	}

	static function re(v:Dynamic):NRegexp
		return v.abs("regexp");

	static function make(pattern:NStr, opts:String):NAbs {
		var o = new StringBuf();
		var utf8 = false;
		for (c in opts.split(""))
			switch c {
				case "i" | "s" | "m":
					o.add(c);
				case "u":
					utf8 = true;
				case "g":
				case _:
					throw VM.error("Unknown regexp option '" + c + "'");
			}
		var src = utf8 ? Subject.utf8(pattern.b).s : text(pattern.b);
		var r = try new hxmc.Regex(src, o.toString(), false, utf8) catch (e:Dynamic) throw VM.error("Regexp compilation error : " + Std.string(e) + " in "
			+ pattern.toString());
		return new NAbs("regexp", new NRegexp(r, utf8));
	}

	public static function register(add:Register) {
		var r = (n:String, k:Int, f:Prim) -> add("regexp@" + n, k, f);
		r("regexp_new", 1, (vm, a) -> make(a[0].str(), ""));
		r("regexp_new_options", 2, (vm, a) -> make(a[0].str(), a[1].str().toString()));
		r("regexp_match", 4, (vm, a) -> {
			var d = re(a[0]), s = a[1].str(), p = a[2].int(), l = a[3].int();
			if (p < 0 || l < 0 || p > s.b.length || p + l > s.b.length) throw Builtins.failure;
			var sj = subject(d, s.b);
			sj.check(p);
			var u = sj.unit(p);
			if (d.re.exec(sj.s, u, sj.unit(p + l) - u)) {
				d.str = s;
				d.subj = sj;
				return true;
			}
			d.str = null;
			return false;
		});
		r("regexp_matched", 2, (vm, a) -> {
			var d = re(a[0]), m = a[1].int();
			if (m < 0 || m >= d.re.ngroups || d.str == null) throw Builtins.failure;
			var start = d.cap(m * 2), end = d.cap(m * 2 + 1);
			if (start < 0) return (null : Dynamic);
			return new NStr(d.str.b.sub(start, end - start));
		});
		r("regexp_matched_pos", 2, (vm, a) -> {
			var d = re(a[0]), m = a[1].int();
			if (m < 0 || m >= d.re.ngroups || d.str == null) throw Builtins.failure;
			var start = d.cap(m * 2), end = d.cap(m * 2 + 1);
			var o = new NObj();
			o.set(Fields.id("pos"), start);
			o.set(Fields.id("len"), end - start);
			return o;
		});
		r("regexp_matched_num", 1, (vm, a) -> {
			var d = re(a[0]);
			return d.str == null ? -1 : d.re.ngroups;
		});
		function replace(vm:VM, a:haxe.ds.Vector<Dynamic>, all:Bool, f:Null<NFun>):Dynamic {
			var d = re(a[0]), s = a[1].str();
			var by = f == null ? a[2].str().b : null;
			var sj = subject(d, s.b);
			d.subj = sj;
			var b = new StdPrims.NBuf();
			var pos = 0, len = s.b.length;
			if (f != null) d.str = s;
			while (pos <= len && d.re.exec(sj.s, sj.unit(pos), sj.unit(len) - sj.unit(pos))) {
				var ms = d.cap(0), me = d.cap(1);
				b.addBytes(s.b, pos, ms - pos);
				if (f != null) {
					d.str = s;
					b.add(vm.toBytes(vm.callN(f, [a[0]])));
				} else
					b.add(by);
				if (me == ms) {
					// (PCRE retries an empty match one byte later)
					// (a character, in UTF-8)
					var next = sj.toByte == null || ms >= len ? ms + 1 : sj.toByte[sj.unit(ms) + 1];
					if (ms < len) b.addBytes(s.b, ms, next - ms);
					pos = next;
				} else
					pos = me;
				if (!all) break;
			}
			d.str = null;
			if (pos < len) b.addBytes(s.b, pos, len - pos);
			return new NStr(b.bytes());
		}
		r("regexp_replace", 3, (vm, a) -> replace(vm, a, false, null));
		r("regexp_replace_all", 3, (vm, a) -> replace(vm, a, true, null));
		r("regexp_replace_fun", 3, (vm, a) -> replace(vm, a, true, a[2].fun()));
	}
}
