package ml2hx.std;

import Array as HArray;
import String;
import StdTypes;
import ml2hx.rt.*;
import ml2hx.rt.MlList;

// The Str library (str.ml and strstubs.c): its regular expression syntax,
// a backtracking matcher with Str's priorities (alternatives left to right,
// greedy repetition), the last match as global state, and the splitting and
// substitution functions over it.
enum StrSplitResult {
	Text(v0:String);
	Delim(v0:String);
}

private enum Node {
	Char(c:Int);
	Any; // any char but newline
	Set(bits:HArray<Bool>);
	Bol;
	Eol;
	WordBoundary;
	Group(n:Int, body:Node);
	Backref(n:Int);
	Seq(items:HArray<Node>);
	Alt(a:Node, b:Node);
	Star(body:Node);
	Plus(body:Node);
	Opt(body:Node);
}

class StrRegexp {
	public final source:String;
	final node:Node;
	public final fold:Bool;
	public final groups:Int;
	public function new(source:String, fold:Bool) {
		this.source = source;
		this.fold = fold;
		var p = new StrParser(source, fold);
		node = p.parse();
		groups = p.groupCount;
	}
	@:allow(ml2hx.std.Str)
	inline function root():Node return node;
}

@:allow(ml2hx.std.StrRegexp)
private class StrParser {
	final s:String;
	final fold:Bool;
	var i = 0;
	public var groupCount = 0;
	public function new(s:String, fold:Bool) {
		this.s = s;
		this.fold = fold;
	}
	inline function peek():Int return i < s.length ? StringTools.fastCodeAt(s, i) : -1;
	inline function peek2():Int return i + 1 < s.length ? StringTools.fastCodeAt(s, i + 1) : -1;
	function lit(c:Int):Node {
		if (!fold) return Char(c);
		var bits = [for (_ in 0...256) false];
		bits[c] = true;
		bits[lower(c)] = true;
		bits[upper(c)] = true;
		return Set(bits);
	}
	public static inline function lower(c:Int):Int return c >= "A".code && c <= "Z".code ? c + 32 : c;
	public static inline function upper(c:Int):Int return c >= "a".code && c <= "z".code ? c - 32 : c;
	public function parse():Node {
		var n = alt();
		if (i < s.length) throw new InvalidArgument("Str.regexp: unmatched \\)");
		return n;
	}
	function alt():Node {
		var a = seq();
		while (peek() == "\\".code && peek2() == "|".code) {
			i += 2;
			a = Alt(a, seq());
		}
		return a;
	}
	function seq():Node {
		var items = [];
		while (i < s.length) {
			var c = peek();
			if (c == "\\".code && (peek2() == "|".code || peek2() == ")".code)) break;
			if ((c == "*".code || c == "+".code || c == "?".code) && items.length > 0) {
				i++;
				var last = items.pop();
				items.push(c == "*".code ? Star(last) : c == "+".code ? Plus(last) : Opt(last));
				continue;
			}
			items.push(atom());
		}
		return items.length == 1 ? items[0] : Seq(items);
	}
	function atom():Node {
		var c = peek();
		i++;
		switch c {
			case ".".code: return Any;
			case "^".code: return Bol;
			case "$".code: return Eol;
			case "[".code: return set();
			case "\\".code:
				var d = peek();
				if (d < 0) throw new InvalidArgument("Str.regexp: trailing backslash");
				i++;
				switch d {
					case "(".code:
						var n = ++groupCount;
						var body = alt();
						if (!(peek() == "\\".code && peek2() == ")".code)) throw new InvalidArgument("Str.regexp: unmatched \\(");
						i += 2;
						return Group(n, body);
					case "b".code: return WordBoundary;
					case _ if (d >= "1".code && d <= "9".code): return Backref(d - "0".code);
					case _: return lit(d);
				}
			case _: return lit(c);
		}
	}
	function set():Node {
		var bits = [for (_ in 0...256) false];
		var neg = false;
		if (peek() == "^".code) { neg = true; i++; }
		var first = true;
		while (true) {
			if (i >= s.length) throw new InvalidArgument("Str.regexp: [ class not closed by ]");
			var c = peek();
			if (c == "]".code && !first) { i++; break; }
			first = false;
			i++;
			if (peek() == "-".code && peek2() != "]".code && peek2() >= 0) {
				i++;
				var d = peek();
				i++;
				for (k in c...d + 1) bits[k] = true;
			} else bits[c] = true;
		}
		if (fold) for (k in 0...256) if (bits[k]) { bits[lower(k)] = true; bits[upper(k)] = true; }
		if (neg) for (k in 0...256) bits[k] = !bits[k];
		return Set(bits);
	}
}

class Str {
	// the last match: group starts and ends (index 0: the whole match), -1 if unset
	static var lastStarts:HArray<Int> = [];
	static var lastEnds:HArray<Int> = [];

	public static function regexp(s:String):StrRegexp return new StrRegexp(s, false);
	public static function regexpCaseFold(s:String):StrRegexp return new StrRegexp(s, true);
	public static function quote(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if ("$^\\.*+?[]".indexOf(std.String.fromCharCode(c)) >= 0) b.addChar("\\".code);
			b.addChar(c);
		}
		return b.toString();
	}
	public static function regexpString(s:String):StrRegexp return regexp(quote(s));
	public static function regexpStringCaseFold(s:String):StrRegexp return regexpCaseFold(quote(s));

	// ---------------------------------------------------------------- matcher
	static function isWord(c:Int):Bool
		return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "_".code || (c >= 192 && c <= 255 && c != 215 && c != 247);
	// Match node at i in s, then continue with k; starts/ends hold groups.
	static function m(n:Node, s:String, i:Int, starts:HArray<Int>, ends:HArray<Int>, k:Int->Bool):Bool {
		switch n {
			case Char(c): return i < s.length && StringTools.fastCodeAt(s, i) == c && k(i + 1);
			case Any: return i < s.length && StringTools.fastCodeAt(s, i) != "\n".code && k(i + 1);
			case Set(bits): return i < s.length && bits[StringTools.fastCodeAt(s, i)] && k(i + 1);
			case Bol: return (i == 0 || StringTools.fastCodeAt(s, i - 1) == "\n".code) && k(i);
			case Eol: return (i == s.length || StringTools.fastCodeAt(s, i) == "\n".code) && k(i);
			case WordBoundary:
				var a = i > 0 && isWord(StringTools.fastCodeAt(s, i - 1)), b = i < s.length && isWord(StringTools.fastCodeAt(s, i));
				return a != b && k(i);
			case Group(g, body):
				var os = starts[g], oe = ends[g];
				if (m(body, s, i, starts, ends, j -> {
					var ps = starts[g], pe = ends[g];
					starts[g] = i;
					ends[g] = j;
					if (k(j)) return true;
					starts[g] = ps;
					ends[g] = pe;
					return false;
				})) return true;
				starts[g] = os;
				ends[g] = oe;
				return false;
			case Backref(g):
				if (starts[g] < 0) return false;
				var len = ends[g] - starts[g];
				if (i + len > s.length || s.substr(i, len) != s.substr(starts[g], len)) return false;
				return k(i + len);
			case Seq(items):
				function go(idx:Int, j:Int):Bool return idx == items.length ? k(j) : m(items[idx], s, j, starts, ends, j2 -> go(idx + 1, j2));
				return go(0, i);
			case Alt(a, b): return m(a, s, i, starts, ends, k) || m(b, s, i, starts, ends, k);
			case Star(body):
				// greedy; an iteration that matches empty ends the repetition
				function star(j:Int):Bool return m(body, s, j, starts, ends, j2 -> j2 != j && star(j2)) || k(j);
				return star(i);
			case Plus(body):
				function plus(j:Int):Bool return m(body, s, j, starts, ends, j2 -> (j2 != j && plus(j2)) || k(j2));
				return plus(i);
			case Opt(body): return m(body, s, i, starts, ends, k) || k(i);
		}
	}
	static function tryAt(r:StrRegexp, s:String, pos:Int):Bool {
		var starts = [for (_ in 0...r.groups + 1) -1], ends = [for (_ in 0...r.groups + 1) -1];
		var endPos = -1;
		if (m(r.root(), s, pos, starts, ends, j -> { endPos = j; true; })) {
			starts[0] = pos;
			ends[0] = endPos;
			lastStarts = starts;
			lastEnds = ends;
			return true;
		}
		return false;
	}
	static function invalidPos(name:String):Dynamic throw new InvalidArgument("Str." + name);
	public static function stringMatch(r:StrRegexp, s:String, pos:Int63):Bool {
		var p = pos.toInt();
		if (p < 0 || p > s.length) invalidPos("string_match");
		return tryAt(r, s, p);
	}
	public static function stringPartialMatch(r:StrRegexp, s:String, pos:Int63):Bool throw new InvalidArgument("Str.string_partial_match: unsupported");
	static function search(r:StrRegexp, s:String, p:Int):Int {
		var i = p;
		while (i <= s.length) {
			if (tryAt(r, s, i)) return i;
			i++;
		}
		return -1;
	}
	public static function searchForward(r:StrRegexp, s:String, pos:Int63):Int63 {
		var p = pos.toInt();
		if (p < 0 || p > s.length) invalidPos("search_forward");
		var i = search(r, s, p);
		if (i < 0) throw NotFound.instance;
		return Int63.ofInt(i);
	}
	public static function searchBackward(r:StrRegexp, s:String, pos:Int63):Int63 {
		var p = pos.toInt();
		if (p < 0 || p > s.length) invalidPos("search_backward");
		var i = p;
		while (i >= 0) {
			if (tryAt(r, s, i)) return Int63.ofInt(i);
			i--;
		}
		throw NotFound.instance;
	}
	public static function matchedGroup(n:Int63, s:String):String {
		var g = n.toInt();
		if (g < 0 || g >= lastStarts.length) throw new InvalidArgument("Str.matched_group");
		if (lastStarts[g] < 0) throw NotFound.instance;
		return s.substring(lastStarts[g], lastEnds[g]);
	}
	public static function matchedString(s:String):String return matchedGroup(Int63.zero, s);
	public static function groupBeginning(n:Int63):Int63 {
		var g = n.toInt();
		if (g < 0 || g >= lastStarts.length) throw new InvalidArgument("Str.group_beginning");
		if (lastStarts[g] < 0) throw NotFound.instance;
		return Int63.ofInt(lastStarts[g]);
	}
	public static function groupEnd(n:Int63):Int63 {
		var g = n.toInt();
		if (g < 0 || g >= lastEnds.length) throw new InvalidArgument("Str.group_end");
		if (lastEnds[g] < 0) throw NotFound.instance;
		return Int63.ofInt(lastEnds[g]);
	}
	public static function matchBeginning(_:Unit):Int63 return groupBeginning(Int63.zero);
	public static function matchEnd(_:Unit):Int63 return groupEnd(Int63.zero);

	// ---------------------------------------------------------------- substitution
	static function replaceMatched(templ:String, s:String):String {
		var b = new StringBuf(), i = 0;
		while (i < templ.length) {
			var c = StringTools.fastCodeAt(templ, i);
			if (c == "\\".code && i + 1 < templ.length) {
				var d = StringTools.fastCodeAt(templ, i + 1);
				if (d >= "0".code && d <= "9".code) {
					var g = d - "0".code;
					if (g >= lastStarts.length) throw new Failure("Str.replace: reference to unmatched group");
					if (lastStarts[g] >= 0) b.add(s.substring(lastStarts[g], lastEnds[g]));
					i += 2;
					continue;
				}
				if (d == "\\".code) { b.addChar("\\".code); i += 2; continue; }
			}
			b.addChar(c);
			i++;
		}
		return b.toString();
	}
	public static function replaceMatched_(templ:String, s:String):String return replaceMatched(templ, s);
	public static function globalSubstitute(r:StrRegexp, f:String->String, text:String):String {
		var b = new StringBuf();
		var start = 0, lastEmpty = false;
		while (true) {
			var startpos = lastEmpty ? start + 1 : start;
			if (startpos > text.length) { b.add(text.substr(start)); break; }
			var pos = search(r, text, startpos);
			if (pos < 0) { b.add(text.substr(start)); break; }
			var endPos = lastEnds[0];
			b.add(text.substring(start, pos));
			b.add(f(text));
			lastEmpty = endPos == pos;
			start = endPos;
		}
		return b.toString();
	}
	public static function globalReplace(r:StrRegexp, templ:String, text:String):String return globalSubstitute(r, s -> replaceMatched(templ, s), text);
	public static function substituteFirst(r:StrRegexp, f:String->String, text:String):String {
		var pos = search(r, text, 0);
		if (pos < 0) return text;
		var e = lastEnds[0];
		return text.substr(0, pos) + f(text) + text.substr(e);
	}
	public static function replaceFirst(r:StrRegexp, templ:String, text:String):String return substituteFirst(r, s -> replaceMatched(templ, s), text);

	// ---------------------------------------------------------------- splitting
	static function list<T>(a:HArray<T>):MlList<T> {
		var l:MlList<T> = Nil, i = a.length;
		while (i > 0) l = Cons(a[--i], l);
		return l;
	}
	public static function boundedSplit(r:StrRegexp, text:String, num:Int63):MlList<String> {
		var out = [], n = num.toInt();
		var start = tryAt(r, text, 0) ? lastEnds[0] : 0;
		while (true) {
			if (start >= text.length) break;
			if (n == 1) { out.push(text.substr(start)); break; }
			var pos = search(r, text, start);
			if (pos < 0) { out.push(text.substr(start)); break; }
			out.push(text.substring(start, pos));
			start = lastEnds[0];
			n--;
		}
		return list(out);
	}
	public static function split(r:StrRegexp, text:String):MlList<String> return boundedSplit(r, text, Int63.zero);
	public static function boundedSplitDelim(r:StrRegexp, text:String, num:Int63):MlList<String> {
		if (text == "") return Nil;
		var out = [], n = num.toInt(), start = 0;
		while (true) {
			if (start > text.length) break;
			if (n == 1) { out.push(text.substr(start)); break; }
			var pos = search(r, text, start);
			if (pos < 0) { out.push(text.substr(start)); break; }
			out.push(text.substring(start, pos));
			start = lastEnds[0];
			n--;
		}
		return list(out);
	}
	public static function splitDelim(r:StrRegexp, text:String):MlList<String> return boundedSplitDelim(r, text, Int63.zero);
	public static function boundedFullSplit(r:StrRegexp, text:String, num:Int63):MlList<StrSplitResult> {
		var out = [], n = num.toInt(), start = 0;
		while (true) {
			if (start >= text.length) break;
			if (n == 1) { out.push(Text(text.substr(start))); break; }
			var pos = search(r, text, start);
			if (pos < 0) { out.push(Text(text.substr(start))); break; }
			var d = text.substring(lastStarts[0], lastEnds[0]);
			if (pos > start) out.push(Text(text.substring(start, pos)));
			out.push(Delim(d));
			start = lastEnds[0];
			n--;
		}
		return list(out);
	}
	public static function fullSplit(r:StrRegexp, text:String):MlList<StrSplitResult> return boundedFullSplit(r, text, Int63.zero);

	public static function stringBefore(s:String, n:Int63):String return s.substr(0, n.toInt());
	public static function stringAfter(s:String, n:Int63):String return s.substr(n.toInt());
	public static function firstChars(s:String, n:Int63):String return s.substr(0, n.toInt());
	public static function lastChars(s:String, n:Int63):String return s.substr(s.length - n.toInt());
}
