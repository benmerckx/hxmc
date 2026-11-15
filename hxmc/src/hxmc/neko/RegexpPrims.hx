package hxmc.neko;

import haxe.io.Bytes;
import hxmc.neko.Prims.Register;
import hxmc.neko.Value;

using hxmc.neko.Builtins.Check;

class NRegexp {
	public final re:hxmc.Regex;
	// the subject of the last match, null when it failed
	public var str:Null<NStr>;

	public function new(re)
		this.re = re;
}

// libs/regexp over hxmc's engine (hxmc.Regex): Neko's strings are bytes, PCRE
// without its UTF option matches them byte by byte, so the subject and the
// pattern are given to the engine as one code unit per byte
class RegexpPrims {
	// (the last subject's text, by identity)
	static final last = new sys.thread.Tls<{b:Bytes, s:String}>();

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
		for (c in opts.split(""))
			switch c {
				case "i" | "s" | "m":
					o.add(c);
				case "u" | "g":
				case _:
					throw VM.error("Unknown regexp option '" + c + "'");
			}
		var r = try new hxmc.Regex(text(pattern.b), o.toString()) catch (e:Dynamic) throw VM.error("Regexp compilation error : " + Std.string(e) + " in "
			+ pattern.toString());
		return new NAbs("regexp", new NRegexp(r));
	}

	public static function register(add:Register) {
		var r = (n, k, f) -> add("regexp@" + n, k, f);
		r("regexp_new", 1, (vm, a) -> make(a[0].str(), ""));
		r("regexp_new_options", 2, (vm, a) -> make(a[0].str(), a[1].str().toString()));
		r("regexp_match", 4, (vm, a) -> {
			var d = re(a[0]), s = a[1].str(), p = a[2].int(), l = a[3].int();
			if (p < 0 || l < 0 || p > s.b.length || p + l > s.b.length) throw Builtins.failure;
			if (d.re.exec(text(s.b), p, l)) {
				d.str = s;
				return true;
			}
			d.str = null;
			return false;
		});
		r("regexp_matched", 2, (vm, a) -> {
			var d = re(a[0]), m = a[1].int();
			if (m < 0 || m >= d.re.ngroups || d.str == null) throw Builtins.failure;
			var start = d.re.caps[m * 2], end = d.re.caps[m * 2 + 1];
			if (start < 0) return (null : Dynamic);
			return new NStr(d.str.b.sub(start, end - start));
		});
		r("regexp_matched_pos", 2, (vm, a) -> {
			var d = re(a[0]), m = a[1].int();
			if (m < 0 || m >= d.re.ngroups || d.str == null) throw Builtins.failure;
			var start = d.re.caps[m * 2], end = d.re.caps[m * 2 + 1];
			var o = new NObj();
			o.set(Fields.id("pos"), start);
			o.set(Fields.id("len"), end - start);
			return o;
		});
		r("regexp_matched_num", 1, (vm, a) -> {
			var d = re(a[0]);
			return d.str == null ? -1 : d.re.ngroups;
		});
		function replace(vm:VM, a:Array<Dynamic>, all:Bool, f:Null<NFun>):Dynamic {
			var d = re(a[0]), s = a[1].str();
			var by = f == null ? a[2].str().b : null;
			var t = text(s.b);
			var b = new StdPrims.NBuf();
			var pos = 0, len = s.b.length;
			if (f != null) d.str = s;
			while (pos <= len && d.re.exec(t, pos, len - pos)) {
				var ms = d.re.caps[0], me = d.re.caps[1];
				b.addBytes(s.b, pos, ms - pos);
				if (f != null) {
					d.str = s;
					b.add(vm.toBytes(vm.callN(f, [a[0]])));
				} else
					b.add(by);
				if (me == ms) {
					// (PCRE retries an empty match one byte later)
					if (ms < len) b.addByte(s.b.get(ms));
					pos = ms + 1;
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
