// hxmc: haxe/upstream/std/hl/_std/EReg.hx over hxmc.Regex (a Haxe engine in place of the
// regexp_* natives)

@:coreApi final class EReg {
	var r:hxmc.Regex;
	var last:String;
	var global:Bool;

	public function new(r:String, opt:String):Void {
		var a = opt.split("g");
		global = a.length > 1;
		if (global)
			opt = a.join("");
		this.r = new hxmc.Regex(r, opt);
	}

	public function match(s:String):Bool {
		var p = r.exec(s, 0, s.length);
		if (p)
			last = s;
		else
			last = null;
		return p;
	}

	function matchedPos_(n:Int):Int {
		// (Eval's: upstream's TestEReg)
		if (last == null) throw "Invalid regex operation because no match was made";
		if (n < 0 || n >= r.ngroups) throw "Invalid group";
		return r.caps[2 * n];
	}

	function matchedLen_(n:Int):Int
		return r.caps[2 * n + 1] - r.caps[2 * n];

	public function matched(n:Int):String {
		var m = matchedPos_(n);
		return m < 0 ? null : last.substr(m, matchedLen_(n));
	}

	public function matchedLeft():String {
		var p = matchedPos_(0);
		return last.substr(0, p);
	}

	public function matchedRight():String {
		var p = matchedPos_(0);
		return last.substr(p + matchedLen_(0));
	}

	public function matchedPos():{pos:Int, len:Int} {
		var p = matchedPos_(0);
		if (p < 0)
			return null;
		return {pos: p, len: matchedLen_(0)};
	}

	public function matchedNum():Int {
		if (last == null) return 0;
		return r.ngroups;
	}

	public function matchSub(s:String, pos:Int, len:Int = -1):Bool {
		var p = r.exec(s, pos, len < 0 ? s.length - pos : len);
		if (p)
			last = s;
		else
			last = null;
		return p;
	}

	public function split(s:String):Array<String> {
		var pos = 0;
		var len = s.length;
		var a = new Array();
		var first = true;
		do {
			if (!r.exec(s, pos, len))
				break;
			var p = r.caps[0];
			var plen = r.caps[1] - p;
			if (plen == 0 && !first) {
				if (p == s.length)
					break;
				p++;
			}
			a.push(s.substr(pos, p - pos));
			var tot = p + plen - pos;
			pos += tot;
			len -= tot;
			first = false;
		} while (global);
		a.push(s.substr(pos, len));
		return a;
	}

	public function replace(s:String, by:String):String {
		var b = new StringBuf();
		var pos = 0;
		var len = s.length;
		var a = by.split("$");
		var first = true;
		do {
			if (!r.exec(s, pos, len))
				break;
			var p = r.caps[0];
			var plen = r.caps[1] - p;
			if (plen == 0 && !first) {
				if (p == s.length)
					break;
				p++;
			}
			b.addSub(s, pos, p - pos);
			if (a.length > 0)
				b.add(a[0]);
			var i = 1;
			while (i < a.length) {
				var k = a[i];
				var c = StringTools.fastCodeAt(k, 0);
				// 1...9
				if (c >= 49 && c <= 57) {
					var g = c - 48;
					var gp = g < r.ngroups ? r.caps[2 * g] : -1;
					if (gp < 0) {
						b.add("$");
						b.add(k);
					} else {
						b.addSub(s, gp, r.caps[2 * g + 1] - gp);
						b.addSub(k, 1, k.length - 1);
					}
				} else if (c == 0) {
					b.add("$");
					i++;
					var k2 = a[i];
					if (k2 != null && k2.length > 0)
						b.add(k2);
				} else
					b.add("$" + k);
				i++;
			}
			var tot = p + plen - pos;
			pos += tot;
			len -= tot;
			first = false;
		} while (global);
		b.addSub(s, pos, len);
		return b.toString();
	}

	public function map(s:String, f:EReg->String):String {
		var offset = 0;
		var buf = new StringBuf();
		do {
			if (offset >= s.length)
				break;
			else if (!matchSub(s, offset)) {
				buf.add(s.substr(offset));
				break;
			}
			var p = r.caps[0];
			var plen = r.caps[1] - p;
			buf.add(s.substr(offset, p - offset));
			buf.add(f(this));
			if (plen == 0) {
				buf.add(s.substr(p, 1));
				offset = p + 1;
			} else
				offset = p + plen;
		} while (global);
		if (!global && offset > 0 && offset < s.length)
			buf.add(s.substr(offset));
		return buf.toString();
	}

	public static function escape(s:String):String {
		// hxmc: a fresh EReg per call (an EReg keeps its last match, and threads may
		// escape at the same time)
		return new EReg("[\\[\\]{}()*+?.\\\\\\^$|]", "g").map(s, function(r) return "\\" + r.matched(0));
	}
}
