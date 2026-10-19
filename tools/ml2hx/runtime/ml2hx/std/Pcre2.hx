package ml2hx.std;

import ml2hx.rt.*;

// pcre2 (the OCaml binding of PCRE2, used by eval's EReg) over hxmc's regular
// expression engine, hxmc.Regex (the one today's port uses). With `UTF the
// subject and the pattern are UTF-8 byte strings: the engine runs on their
// decoding and offsets are given back in bytes.
enum Pcre2Error {
	Partial;
	BadPattern(v0:String, v1:Int63);
	BadUTF;
	BadUTFOffset;
	MatchLimit;
	DepthLimit;
	WorkspaceSize;
	InternalError(v0:String);
}

class Pcre2ErrorExn extends MlException {
	public final v0:Pcre2Error;
	public function new(v0:Pcre2Error) {
		super();
		this.v0 = v0;
	}
	override public function exnArity():Int return 1;
	override public function exnArg(i:Int):Dynamic return i == 0 ? v0 : super.exnArg(i);
	override public function exnName():String return "Pcre2.Error";
}

class Pcre2Icflag {
	function new() {}
}

class Pcre2Irflag {
	function new() {}
}

class Pcre2Chtables {
	function new() {}
}

class Pcre2CalloutData {
	function new() {}
}

class Pcre2Substitution {
	function new() {}
}

class Pcre2Regexp {
	public final regex:hxmc.Regex;
	public final utf:Bool;
	public function new(regex, utf) {
		this.regex = regex;
		this.utf = utf;
	}
}

class Pcre2Substrings {
	public final subject:String;
	// start, end per group, in bytes (-1: unset)
	public final ofs:Array<Int>;
	public function new(subject, ofs) {
		this.subject = subject;
		this.ofs = ofs;
	}
}

class Pcre2 {
	static function labels(flags:Null<MlList<PolyVariant>>):Array<String> {
		var out = [];
		var l = flags;
		while (l != null) switch l {
			case Nil: break;
			case Cons(f, t):
				out.push(f.label);
				l = t;
		}
		return out;
	}

	public static function regexp(pattern:String, ?limit:Int63, ?depthLimit:Int63, ?iflags:Pcre2Icflag, ?flags:MlList<PolyVariant>, ?chtables:Pcre2Chtables):Pcre2Regexp {
		var ls = labels(flags);
		var utf = ls.contains("UTF");
		var opt = (ls.contains("CASELESS") ? "i" : "") + (ls.contains("MULTILINE") ? "m" : "") + (ls.contains("DOTALL") ? "s" : "");
		var p = utf ? ByteString.toNative(pattern) : pattern;
		try {
			return new Pcre2Regexp(new hxmc.Regex(p, opt), utf);
		} catch (e:haxe.Exception) {
			throw new Pcre2ErrorExn(BadPattern(e.message, Int63.zero));
		}
	}

	// the byte offset of each code unit index of the decoded subject (and
	// of its end)
	static function unitToByte(subject:String, decoded:String):Array<Int> {
		var map = [];
		var b = 0;
		var i = 0;
		while (i < decoded.length) {
			var c = StringTools.fastCodeAt(decoded, i);
			map.push(b);
			var cp = c;
			if (c >= 0xD800 && c < 0xDC00 && i + 1 < decoded.length) {
				map.push(b);
				i++;
				cp = 0x10000;
			}
			b += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
			i++;
		}
		map.push(b);
		return map;
	}

	static function search(rex:Pcre2Regexp, subject:String, pos:Int):Null<Pcre2Substrings> {
		var r = rex.regex;
		if (!rex.utf) {
			if (!r.exec(subject, pos, subject.length - pos)) return null;
			return new Pcre2Substrings(subject, r.caps.copy());
		}
		var decoded = ByteString.toNative(subject);
		var map = unitToByte(subject, decoded);
		var start = map.indexOf(pos);
		if (start < 0) throw new Pcre2ErrorExn(BadUTFOffset);
		if (!r.exec(decoded, start, decoded.length - start)) return null;
		return new Pcre2Substrings(subject, [for (c in r.caps) c < 0 ? -1 : map[c]]);
	}

	public static function exec(subject:String, ?iflags:Pcre2Irflag, ?flags:MlList<PolyVariant>, ?rex:Pcre2Regexp, ?pat:String, ?pos:Int63,
			?callout:Pcre2CalloutData->Unit):Pcre2Substrings {
		var r = rex ?? regexp(pat ?? "");
		var s = search(r, subject, pos == null ? 0 : pos.toInt());
		if (s == null) throw NotFound.instance;
		return s;
	}

	public static function execAll(subject:String, ?iflags:Pcre2Irflag, ?flags:MlList<PolyVariant>, ?rex:Pcre2Regexp, ?pat:String, ?pos:Int63,
			?callout:Pcre2CalloutData->Unit):Array<Pcre2Substrings> {
		var r = rex ?? regexp(pat ?? "");
		var out = [];
		var p = pos == null ? 0 : pos.toInt();
		while (p <= subject.length) {
			var s = search(r, subject, p);
			if (s == null) break;
			out.push(s);
			// after an empty match, on from the next character
			p = s.ofs[1] > s.ofs[0] ? s.ofs[1] : s.ofs[1] + (r.utf ? utf8Length(subject, s.ofs[1]) : 1);
		}
		if (out.length == 0) throw NotFound.instance;
		return out;
	}

	static function utf8Length(s:String, i:Int):Int {
		if (i >= s.length) return 1;
		var c = StringTools.fastCodeAt(s, i);
		return c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
	}

	public static function numOfSubs(s:Pcre2Substrings):Int63 return Int63.ofInt(s.ofs.length >> 1);

	public static function getSubstringOfs(s:Pcre2Substrings, n:Int63):Tuple2<Int63, Int63> {
		var k = n.toInt();
		if (Int63.lt(n, Int63.zero) || k >= s.ofs.length >> 1) throw new InvalidArgument("Pcre2.get_substring_ofs: illegal offset");
		if (s.ofs[2 * k] < 0) throw NotFound.instance;
		return new Tuple2(Int63.ofInt(s.ofs[2 * k]), Int63.ofInt(s.ofs[2 * k + 1]));
	}

	// a template: $n and ${n} for groups, $$ for $
	static function expand(templ:String, s:Pcre2Substrings):String {
		var b = new StringBuf();
		var i = 0;
		while (i < templ.length) {
			var c = templ.charAt(i);
			if (c == "$" && i + 1 < templ.length) {
				var d = templ.charAt(i + 1);
				if (d == "$") {
					b.add("$");
					i += 2;
					continue;
				}
				var j = i + 1, braces = d == "{";
				if (braces) j++;
				var k = j;
				while (k < templ.length && templ.charCodeAt(k) >= 48 && templ.charCodeAt(k) <= 57) k++;
				if (k > j && (!braces || (k < templ.length && templ.charAt(k) == "}"))) {
					var g = Std.parseInt(templ.substring(j, k));
					if (2 * g < s.ofs.length && s.ofs[2 * g] >= 0) b.add(s.subject.substring(s.ofs[2 * g], s.ofs[2 * g + 1]));
					i = braces ? k + 1 : k;
					continue;
				}
			}
			b.add(c);
			i++;
		}
		return b.toString();
	}

	static function substitute(subject:String, r:Pcre2Regexp, pos:Int, templ:String, all:Bool):String {
		var b = new StringBuf();
		var last = 0, p = pos;
		while (p <= subject.length) {
			var s = search(r, subject, p);
			if (s == null) break;
			b.add(subject.substring(last, s.ofs[0]));
			b.add(expand(templ, s));
			last = s.ofs[1];
			if (!all) break;
			p = s.ofs[1] > s.ofs[0] ? s.ofs[1] : s.ofs[1] + 1;
			if (s.ofs[1] == s.ofs[0] && s.ofs[0] < subject.length) {
				b.add(subject.substring(s.ofs[0], p));
				last = p;
			}
		}
		b.add(subject.substring(last));
		return b.toString();
	}

	public static function replace(subject:String, ?iflags:Pcre2Irflag, ?flags:MlList<PolyVariant>, ?rex:Pcre2Regexp, ?pat:String, ?pos:Int63,
			?itempl:Pcre2Substitution, ?templ:String, ?callout:Pcre2CalloutData->Unit):String
		return substitute(subject, rex ?? regexp(pat ?? ""), pos == null ? 0 : pos.toInt(), templ ?? "", true);

	public static function replaceFirst(subject:String, ?iflags:Pcre2Irflag, ?flags:MlList<PolyVariant>, ?rex:Pcre2Regexp, ?pat:String, ?pos:Int63,
			?itempl:Pcre2Substitution, ?templ:String, ?callout:Pcre2CalloutData->Unit):String
		return substitute(subject, rex ?? regexp(pat ?? ""), pos == null ? 0 : pos.toInt(), templ ?? "", false);
}
