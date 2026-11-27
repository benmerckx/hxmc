package hxmc;

// The regular expression engine behind EReg, in Haxe (no PCRE in the
// runtime). A backtracking matcher over UTF-16 code units with the PCRE
// subset Haxe code commonly uses: classes and escapes (\d \w \s \b ... and
// POSIX classes, Unicode-aware as PCRE2_UCP, which Eval and HashLink use;
// tables in hxmc.RegexUnicode), groups ((...), (?:...), (?<name>...),
// lookahead (?= (?!), alternation, greedy and lazy quantifiers (* + ? {n,m}),
// backreferences, anchors and the flags i, m, s (g is EReg's own).
enum RNode {
	RChar(c:Int);
	RAny; // . (any but newline unless dotall)
	RSet(ranges:Array<Int>, neg:Bool); // inclusive (lo, hi) pairs
	RStart;
	REnd;
	RWordB(neg:Bool);
	RGroup(idx:Int, alts:Array<Array<RNode>>); // idx -1: non-capturing
	RLook(neg:Bool, alts:Array<Array<RNode>>);
	RRepeat(body:Array<RNode>, min:Int, max:Int, greedy:Bool); // max -1: unbounded
	RBackRef(n:Int);
}

class Regex {
	var prog:Array<RNode>;
	var icase:Bool;
	var multiline:Bool;
	var dotall:Bool;
	// (PCRE2 without UCP, as Neko's: \d \w \s \b and the POSIX classes ASCII;
	// asciiCase: without UTF either, caseless matching ASCII alone)
	var ascii = false;
	var asciiCase = false;

	public var ngroups(default, null):Int; // including group 0
	public var caps:Array<Int>; // start, end per group (-1: unset)

	var s:String;
	var limit:Int;

	// parser state
	var src:String;
	var p:Int;

	// the code units a match can start with (inclusive pairs; null: any, or
	// the match may be empty); anchored: only at position 0
	var first:Null<Array<Int>>;
	var anchored:Bool;

	// parsed patterns by options and source, shared by the instances (read
	// lock-free: a new map is published whole, never changed afterwards)
	static var cache:Map<String, Regex> = new Map();

	public function new(pattern:String, opt:String, ucp = true, unicodeCase = true) {
		ascii = !ucp;
		asciiCase = !unicodeCase;
		var key = (ascii ? "A" : "") + (asciiCase ? "C" : "") + opt + "/" + pattern;
		var c = cache.get(key);
		if (c == null) {
			parse(pattern, opt);
			var next = new Map<String, Regex>();
			for (k => v in cache)
				next.set(k, v);
			next.set(key, this);
			cache = next;
		} else {
			prog = c.prog;
			icase = c.icase;
			multiline = c.multiline;
			dotall = c.dotall;
			ngroups = c.ngroups;
			first = c.first;
			anchored = c.anchored;
			caps = [for (_ in 0...ngroups * 2) -1];
		}
	}

	function parse(pattern:String, opt:String) {
		for (i in 0...opt.length)
			switch StringTools.fastCodeAt(opt, i) {
				case "i".code: icase = true;
				case "m".code: multiline = true;
				case "s".code: dotall = true;
				case "u".code | "g".code:
				case c: throw "Invalid regular expression option: " + String.fromCharCode(c);
			}
		src = pattern;
		p = 0;
		ngroups = 1;
		var alts = parseAlts();
		if (p < src.length) throw "Invalid regular expression: unmatched ) in " + pattern;
		prog = [RGroup(0, alts)];
		caps = [for (_ in 0...ngroups * 2) -1];
		src = null;
		anchored = !multiline && startsAnchored(alts);
		first = icase ? null : firstOfAlts(alts);
	}

	static function startsAnchored(alts:Array<Array<RNode>>):Bool {
		for (a in alts)
			if (a.length == 0 || !a[0].match(RStart)) return false;
		return true;
	}

	// what a match of the alternatives starts with (see `first`)
	static function firstOfAlts(alts:Array<Array<RNode>>):Null<Array<Int>> {
		var r = [];
		for (a in alts) {
			var f = firstOfSeq(a);
			if (f == null) return null;
			r = r.concat(f);
		}
		return normalize(r);
	}

	static function firstOfSeq(nodes:Array<RNode>):Null<Array<Int>> {
		if (nodes.length == 0) return null;
		return switch nodes[0] {
			case RChar(c): [c, c];
			case RSet(r, false): r;
			case RGroup(_, alts): firstOfAlts(alts);
			case RRepeat(body, min, _, _) if (min > 0): firstOfSeq(body);
			case _: null;
		}
	}

	// searches s[pos, pos + len) for the leftmost match
	public function exec(str:String, pos:Int, len:Int):Bool {
		s = str;
		limit = pos + len;
		var start = pos;
		// `^` only matches at 0
		var last = anchored ? (pos == 0 ? 0 : -1) : limit;
		var f = first;
		while (start <= last) {
			if (f != null) {
				// skip the positions a match cannot start at
				while (start < limit && !inRanges(f, code(start)))
					start++;
				if (start >= limit) break;
			}
			for (i in 0...caps.length)
				caps[i] = -1;
			if (seq(prog, 0, start, done)) return true;
			start++;
		}
		for (i in 0...caps.length)
			caps[i] = -1;
		return false;
	}

	static function done(pos:Int):Bool
		return true;

	// ---- parser

	inline function peek():Int
		return p < src.length ? StringTools.fastCodeAt(src, p) : -1;

	function parseAlts():Array<Array<RNode>> {
		var alts = [parseSeq()];
		while (peek() == "|".code) {
			p++;
			alts.push(parseSeq());
		}
		return alts;
	}

	function parseSeq():Array<RNode> {
		var out = [];
		while (p < src.length) {
			var c = peek();
			if (c == "|".code || c == ")".code) break;
			var atom = parseAtom();
			if (atom == null) continue;
			out.push(parseQuant(atom));
		}
		return out;
	}

	function parseQuant(atom:RNode):RNode {
		var min = -1, max = -1;
		switch peek() {
			case "*".code:
				p++;
				min = 0;
			case "+".code:
				p++;
				min = 1;
			case "?".code:
				p++;
				min = 0;
				max = 1;
			case "{".code:
				var save = p;
				p++;
				var a = number();
				if (a < 0) {
					p = save;
					return atom;
				}
				var b = a;
				if (peek() == ",".code) {
					p++;
					b = peek() == "}".code ? -1 : number();
				}
				if (peek() != "}".code) {
					p = save;
					return atom;
				}
				p++;
				min = a;
				max = b;
			case _:
				return atom;
		}
		var greedy = true;
		if (peek() == "?".code) {
			p++;
			greedy = false;
		} else if (peek() == "+".code) {
			p++; // possessive: treated as greedy
		}
		return RRepeat([atom], min, max, greedy);
	}

	function number():Int {
		var n = -1;
		while (true) {
			var c = peek();
			if (c < "0".code || c > "9".code) break;
			n = (n < 0 ? 0 : n * 10) + c - "0".code;
			p++;
		}
		return n;
	}

	function parseAtom():Null<RNode> {
		var c = peek();
		p++;
		return switch c {
			case ".".code: RAny;
			case "^".code: RStart;
			case "$".code: REnd;
			case "[".code: parseClass();
			case "(".code:
				var idx = -1, look = 0;
				if (peek() == "?".code) {
					p++;
					switch peek() {
						case ":".code: p++;
						case "=".code:
							p++;
							look = 1;
						case "!".code:
							p++;
							look = 2;
						case "<".code | "P".code | "'".code:
							if (peek() == "P".code) p++;
							var close = peek() == "'".code ? "'".code : ">".code;
							while (p < src.length && peek() != close)
								p++;
							p++;
							idx = ngroups++;
						case _:
							// inline flags (?i) (?s) (?m)
							var on = true;
							while (p < src.length && peek() != ")".code && peek() != ":".code) {
								switch peek() {
									case "-".code: on = false;
									case "i".code: icase = on;
									case "m".code: multiline = on;
									case "s".code: dotall = on;
									case _: throw "Invalid regular expression group";
								}
								p++;
							}
							if (peek() == ")".code) {
								p++;
								return null;
							}
							p++;
					}
				} else
					idx = ngroups++;
				var alts = parseAlts();
				if (peek() != ")".code) throw "Invalid regular expression: missing )";
				p++;
				look == 0 ? RGroup(idx, alts) : RLook(look == 2, alts);
			case "\\".code: parseEscape(false);
			case _: RChar(c);
		}
	}

	function parseEscape(inClass:Bool):RNode {
		var c = peek();
		p++;
		return switch c {
			case "d".code: RSet(ascii ? ASCII_DIGIT : RegexUnicode.DIGIT, false);
			case "D".code: RSet(ascii ? ASCII_DIGIT : RegexUnicode.DIGIT, true);
			case "w".code: RSet(ascii ? ASCII_WORD : RegexUnicode.WORD, false);
			case "W".code: RSet(ascii ? ASCII_WORD : RegexUnicode.WORD, true);
			case "s".code: RSet(ascii ? ASCII_SPACE : RegexUnicode.SPACE, false);
			case "S".code: RSet(ascii ? ASCII_SPACE : RegexUnicode.SPACE, true);
			case "b".code if (!inClass): RWordB(false);
			case "B".code if (!inClass): RWordB(true);
			case "b".code: RChar(8);
			case "A".code if (!inClass): RStart;
			case "z".code | "Z".code if (!inClass): REnd;
			case "n".code: RChar(10);
			case "r".code: RChar(13);
			case "t".code: RChar(9);
			case "f".code: RChar(12);
			case "v".code: RChar(11);
			case "e".code: RChar(27);
			case "0".code: RChar(0);
			case "x".code:
				if (peek() == "{".code) {
					p++;
					var v = hex(8);
					p++;
					RChar(v);
				} else RChar(hex(2));
			case "u".code: RChar(hex(4));
			case c if (c >= "1".code && c <= "9".code && !inClass):
				var n = c - "0".code;
				while (peek() >= "0".code && peek() <= "9".code && n * 10 + peek() - "0".code < ngroups) {
					n = n * 10 + peek() - "0".code;
					p++;
				}
				RBackRef(n);
			case -1: throw "Invalid regular expression: trailing \\";
			case _: RChar(c);
		}
	}

	function hex(max:Int):Int {
		var v = 0, n = 0;
		while (n < max) {
			var c = peek();
			var d = c >= "0".code && c <= "9".code ? c - "0".code : c >= "a".code && c <= "f".code ? c - "a".code + 10 : c >= "A".code
				&& c <= "F".code ? c - "A".code + 10 : -1;
			if (d < 0) break;
			v = v * 16 + d;
			p++;
			n++;
		}
		return v;
	}

	function parseClass():RNode {
		var neg = false;
		if (peek() == "^".code) {
			p++;
			neg = true;
		}
		var ranges = [];
		var first = true;
		while (p < src.length && (peek() != "]".code || first)) {
			first = false;
			var lo = classAtom(ranges);
			if (lo < 0) continue;
			var hi = lo;
			if (peek() == "-".code && p + 1 < src.length && StringTools.fastCodeAt(src, p + 1) != "]".code) {
				p++;
				hi = classAtom(ranges);
				if (hi < 0) {
					ranges.push("-".code);
					ranges.push("-".code);
					hi = lo;
				}
			}
			ranges.push(lo);
			ranges.push(hi);
		}
		if (peek() != "]".code) throw "Invalid regular expression: missing ]";
		p++;
		return RSet(normalize(ranges), neg);
	}

	// sorted, merged ranges (inSet searches them)
	static function normalize(ranges:Array<Int>):Array<Int> {
		var pairs = [for (i in 0...ranges.length >> 1) i];
		pairs.sort((a, b) -> ranges[2 * a] - ranges[2 * b]);
		var out = [];
		for (i in pairs) {
			var lo = ranges[2 * i], hi = ranges[2 * i + 1];
			if (hi < lo) continue;
			if (out.length > 0 && lo <= out[out.length - 1] + 1) {
				if (hi > out[out.length - 1]) out[out.length - 1] = hi;
			} else {
				out.push(lo);
				out.push(hi);
			}
		}
		return out;
	}

	// one class member: its code, or -1 after adding a whole class escape to ranges
	function classAtom(ranges:Array<Int>):Int {
		var c = peek();
		p++;
		if (c == "[".code && peek() == ":".code) {
			// POSIX classes [:alpha:] etc.
			var end = src.indexOf(":]", p);
			if (end > 0) {
				var name = src.substring(p + 1, end);
				p = end + 2;
				var r = switch name {
					case "alpha": ascii ? [65, 90, 97, 122] : RegexUnicode.ALPHA;
					case "digit": ascii ? ASCII_DIGIT : RegexUnicode.DIGIT;
					case "alnum": ascii ? [48, 57, 65, 90, 97, 122] : RegexUnicode.ALNUM;
					case "space": ascii ? ASCII_SPACE : RegexUnicode.SPACE;
					case "upper": ascii ? [65, 90] : RegexUnicode.UPPER;
					case "lower": ascii ? [97, 122] : RegexUnicode.LOWER;
					case "xdigit": [48, 57, 65, 70, 97, 102];
					case "word": ascii ? ASCII_WORD : RegexUnicode.WORD;
					case "punct": [33, 47, 58, 64, 91, 96, 123, 126];
					case _: throw "Invalid regular expression class " + name;
				};
				for (x in r)
					ranges.push(x);
				return -1;
			}
		}
		if (c != "\\".code) return c;
		switch parseEscape(true) {
			case RChar(v):
				return v;
			case RSet(r, false):
				for (x in r)
					ranges.push(x);
				return -1;
			case RSet(r, true):
				// complement of r over the code unit range
				var lo = 0;
				var i = 0;
				while (i < r.length) {
					if (r[i] > lo) {
						ranges.push(lo);
						ranges.push(r[i] - 1);
					}
					lo = r[i + 1] + 1;
					i += 2;
				}
				ranges.push(lo);
				ranges.push(0x10FFFF);
				return -1;
			case _:
				throw "Invalid regular expression escape in class";
		}
	}

	// ---- matcher

	inline function code(pos:Int):Int
		return StringTools.fastCodeAt(s, pos);

	static final ASCII_DIGIT = [48, 57];
	static final ASCII_WORD = [48, 57, 65, 90, 95, 95, 97, 122];
	static final ASCII_SPACE = [9, 13, 32, 32];

	// lower, or (asciiCase) ASCII letters alone
	inline function fold(c:Int):Int
		return asciiCase && c >= 128 ? c : lower(c);

	// the representative of c's caseless set (ASCII letters: the upper case one)
	static function lower(c:Int):Int {
		if (c < 128) return c >= "a".code && c <= "z".code ? c - 32 : c;
		var src = RegexUnicode.FOLD_SRC;
		var lo = 0, hi = src.length - 1;
		while (lo <= hi) {
			var mid = (lo + hi) >> 1;
			var v = src[mid];
			if (v == c) return RegexUnicode.FOLD_REP[mid];
			if (v < c) lo = mid + 1 else hi = mid - 1;
		}
		return c;
	}

	// representative -> the members of its caseless set
	static var caseSets:Null<Map<Int, Array<Int>>>;

	static function caseSet(c:Int):Null<Array<Int>> {
		// built aside and published whole: another thread may look at it meanwhile
		var sets = caseSets;
		if (sets == null) {
			sets = new Map();
			var src = RegexUnicode.FOLD_SRC, rep = RegexUnicode.FOLD_REP;
			for (i in 0...src.length) {
				var a = sets.get(rep[i]);
				if (a == null) sets.set(rep[i], a = []);
				a.push(src[i]);
			}
			caseSets = sets;
		}
		return sets.get(lower(c));
	}

	inline function wordAt(c:Int):Bool
		return ascii ? c < 128 && isWord(c) : isWord(c);

	static function isWord(c:Int):Bool
		return c < 128 ? c >= "0".code && c <= "9".code || c >= "A".code && c <= "Z".code || c >= "a".code && c <= "z".code
			|| c == "_".code : inRanges(RegexUnicode.WORD, c);

	// ranges sorted (normalize, the tables, or a complement of them)
	static function inRanges(ranges:Array<Int>, c:Int):Bool {
		if (ranges.length <= 16) {
			var i = 0;
			while (i < ranges.length) {
				if (c >= ranges[i] && c <= ranges[i + 1]) return true;
				i += 2;
			}
			return false;
		}
		var lo = 0, hi = (ranges.length >> 1) - 1;
		while (lo <= hi) {
			var mid = (lo + hi) >> 1;
			if (c < ranges[2 * mid]) hi = mid - 1 else if (c > ranges[2 * mid + 1]) lo = mid + 1 else return true;
		}
		return false;
	}

	function inSet(ranges:Array<Int>, c:Int):Bool {
		if (inRanges(ranges, c)) return true;
		if (icase && !(asciiCase && c >= 128)) {
			var set = caseSet(c);
			if (set != null)
				for (o in set)
					if (o != c && inRanges(ranges, o)) return true;
		}
		return false;
	}

	// does the single-unit node n match at pos (pos < limit)?
	function single(n:RNode, pos:Int):Bool {
		return switch n {
			case RChar(c): var x = code(pos); x == c || icase && fold(x) == fold(c);
			case RAny: dotall || code(pos) != 10;
			case RSet(r, neg): inSet(r, code(pos)) != neg;
			case _: false;
		}
	}

	static function isSingle(n:RNode):Bool
		return switch n {
			case RChar(_) | RAny | RSet(_, _): true;
			case _: false;
		}

	function seq(nodes:Array<RNode>, i:Int, pos:Int, k:Int->Bool):Bool {
		while (i < nodes.length) {
			var n = nodes[i];
			switch n {
				case RChar(_) | RAny | RSet(_, _):
					if (pos >= limit || !single(n, pos)) return false;
					pos++;
				case RStart:
					if (!(pos == 0 || multiline && code(pos - 1) == 10)) return false;
				case REnd:
					if (!(pos == limit || (multiline || pos == limit - 1) && code(pos) == 10)) return false; // PCRE: also before a final newline
				case RWordB(neg):
					var a = pos > 0 && wordAt(code(pos - 1)), b = pos < limit && wordAt(code(pos));
					if ((a != b) == neg) return false;
				case RBackRef(g):
					var st = caps[2 * g], en = caps[2 * g + 1];
					if (st >= 0) {
						var l = en - st;
						if (pos + l > limit) return false;
						for (j in 0...l) {
							var x = code(st + j), y = code(pos + j);
							if (x != y && !(icase && fold(x) == fold(y))) return false;
						}
						pos += l;
					}
				case RGroup(idx, alts):
					return group(idx, alts, nodes, i + 1, pos, k);
				case RLook(neg, alts):
					var saved = caps.copy();
					var found = false;
					for (a in alts)
						if (seq(a, 0, pos, done)) {
							found = true;
							break;
						}
					if (neg || !found) caps = saved;
					if (found == neg) return false;
				case RRepeat(body, min, max, greedy):
					if (body.length == 1 && isSingle(body[0])) return simpleRepeat(body[0], min, max, greedy, nodes, i + 1, pos, k);
					return repeat(body, min, max, greedy, 0, pos, -1, p2 -> seq(nodes, i + 1, p2, k));
			}
			i++;
		}
		return k(pos);
	}

	function group(idx:Int, alts:Array<Array<RNode>>, nodes:Array<RNode>, next:Int, pos:Int, k:Int->Bool):Bool {
		for (a in alts) {
			if (idx < 0) {
				if (seq(a, 0, pos, p2 -> seq(nodes, next, p2, k))) return true;
			} else {
				var os = caps[2 * idx], oe = caps[2 * idx + 1];
				if (seq(a, 0, pos, p2 -> {
					var ps = caps[2 * idx], pe = caps[2 * idx + 1];
					caps[2 * idx] = pos;
					caps[2 * idx + 1] = p2;
					if (seq(nodes, next, p2, k)) return true;
					caps[2 * idx] = ps;
					caps[2 * idx + 1] = pe;
					return false;
				})) return true;
				caps[2 * idx] = os;
				caps[2 * idx + 1] = oe;
			}
		}
		return false;
	}

	function simpleRepeat(n:RNode, min:Int, max:Int, greedy:Bool, nodes:Array<RNode>, next:Int, pos:Int, k:Int->Bool):Bool {
		var count = 0;
		if (greedy) {
			while ((max < 0 || count < max) && pos + count < limit && single(n, pos + count))
				count++;
			while (count >= min) {
				if (seq(nodes, next, pos + count, k)) return true;
				count--;
			}
			return false;
		}
		while (count < min) {
			if (pos + count >= limit || !single(n, pos + count)) return false;
			count++;
		}
		while (true) {
			if (seq(nodes, next, pos + count, k)) return true;
			if (max >= 0 && count >= max || pos + count >= limit || !single(n, pos + count)) return false;
			count++;
		}
	}

	function repeat(body:Array<RNode>, min:Int, max:Int, greedy:Bool, count:Int, pos:Int, last:Int, k:Int->Bool):Bool {
		var more = (max < 0 || count < max) && (pos != last || count < min); // an empty iteration ends the loop
		if (greedy) {
			if (more && seq(body, 0, pos, p2 -> repeat(body, min, max, greedy, count + 1, p2, pos, k))) return true;
			return count >= min && k(pos);
		}
		if (count >= min && k(pos)) return true;
		return more && seq(body, 0, pos, p2 -> repeat(body, min, max, greedy, count + 1, p2, pos, k));
	}
}
