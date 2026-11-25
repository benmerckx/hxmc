package hxmc.es;

import core.Globals.Pos;

// The source maps (v3) of the printed files (-D js-source-map, --debug): the printer marks where an expression or a
// statement starts, and a name it prints renamed (minified), with a marker in its text (`mark`), which `finish`
// takes out of a file's final text, mapping the place it held: the next character that is not a space. A renamed
// name's mapping names the original (the map's `names`), per place: names minified alike map apart.
class SourceMap {
	static inline final START = 0xE000;
	static inline final END = 0xE001;

	final marks:Array<{pos:Pos, name:Null<String>}> = [];
	// (the files and lines of the positions: syntax.Lexer.findPos, once each)
	final lines = new Map<String, {line:Int, col:Int}>();

	public function new() {}

	// a marker for pos (and the name printed after it, renamed), or nothing
	public function mark(pos:Null<Pos>, ?name:String):String {
		if (pos == null || pos.pmin < 0) return "";
		marks.push({pos: pos, name: name});
		return String.fromCharCode(START) + (marks.length - 1) + String.fromCharCode(END);
	}

	// (the printer's checks of its own text) its first and last characters, its width, past the markers
	public static function first(s:String):String {
		var i = 0;
		while (i < s.length && StringTools.fastCodeAt(s, i) == START) i = s.indexOf(String.fromCharCode(END), i) + 1;
		return i < s.length ? s.charAt(i) : "";
	}

	public static function last(s:String):String {
		var i = s.length - 1;
		while (i >= 0 && StringTools.fastCodeAt(s, i) == END) i = s.lastIndexOf(String.fromCharCode(START), i) - 1;
		return i >= 0 ? s.charAt(i) : "";
	}

	public static function width(s:String):Int {
		var n = s.length, i = s.indexOf(String.fromCharCode(START));
		while (i >= 0) {
			var j = s.indexOf(String.fromCharCode(END), i);
			n -= j - i + 1;
			i = s.indexOf(String.fromCharCode(START), j);
		}
		return n;
	}

	// a file's text without its markers, and its map (`json(<the file's name>)`; withContent: -D source-map-content)
	public function finish(text:String, withContent = false):{code:String, json:String->String} {
		var out = new StringBuf();
		var sources:Array<String> = [], sourceIds = new Map<String, Int>();
		var names:Array<String> = [], nameIds = new Map<String, Int>();
		var mappings = new StringBuf();
		var line = 0, col = 0, pending = -1;
		// (VLQ: each field relative to the previous segment's, the column to the line's)
		var lastCol = 0, lastSrc = 0, lastLine = 0, lastSrcCol = 0, lastName = 0, lineSegments = 0;
		function segment(m:{pos:Pos, name:Null<String>}) {
			var src = sourceIds.get(m.pos.pfile);
			if (src == null) {
				src = sources.length;
				sources.push(m.pos.pfile);
				sourceIds.set(m.pos.pfile, src);
			}
			var at = where(m.pos);
			if (lineSegments++ > 0) mappings.addChar(",".code);
			vlq(mappings, col - lastCol);
			vlq(mappings, src - lastSrc);
			vlq(mappings, at.line - lastLine);
			vlq(mappings, at.col - lastSrcCol);
			lastCol = col;
			lastSrc = src;
			lastLine = at.line;
			lastSrcCol = at.col;
			if (m.name != null) {
				var n = nameIds.get(m.name);
				if (n == null) {
					n = names.length;
					names.push(m.name);
					nameIds.set(m.name, n);
				}
				vlq(mappings, n - lastName);
				lastName = n;
			}
		}
		var i = 0, n = text.length;
		while (i < n) {
			var c = StringTools.fastCodeAt(text, i);
			if (c == START) {
				var j = text.indexOf(String.fromCharCode(END), i);
				// (of the marks before a character, the last: the innermost, or a name's)
				pending = Std.parseInt(text.substring(i + 1, j));
				i = j + 1;
				continue;
			}
			if (c == "\n".code) {
				mappings.addChar(";".code);
				line++;
				col = 0;
				lastCol = 0;
				lineSegments = 0;
			} else if (c == " ".code || c == "\t".code) {
				col++;
			} else {
				if (pending >= 0) {
					segment(marks[pending]);
					pending = -1;
				}
				// (columns in UTF-16 units: a character past U+FFFF two, on a host of code points)
				col += core.StringHelper.codePointHost && c >= 0x10000 ? 2 : 1;
			}
			out.addChar(c);
			i++;
		}
		var code = out.toString();
		return {
			code: code,
			json: (file:String) -> {
				var b = new StringBuf();
				b.add("{\"version\":3,\"file\":" + Printer.quote(file) + ",\"sourceRoot\":\"\",\"sources\":[");
				b.add([for (s in sources) Printer.quote(url(s))].join(","));
				b.add("],");
				if (withContent) b.add(content(sources));
				b.add("\"names\":[" + [for (s in names) Printer.quote(s)].join(",") + "],");
				b.add("\"mappings\":\"" + mappings.toString() + "\"}");
				b.toString();
			}
		};
	}

	// the map's own sources' texts (-D source-map-content)
	public static function content(sources:Array<String>):String
		return "\"sourcesContent\":[" + [
			for (s in sources) try Printer.quote(sys.io.File.getBytes(s).toString()) catch (_:Dynamic) "null"
		].join(",") + "],";

	// (a file's URL: its full path)
	static function url(file:String):String {
		var p = core.Path.getFullPath(file).split("\\").join("/");
		return StringTools.startsWith(p, "/") ? "file://" + p : "file:///" + p;
	}

	function where(p:Pos):{line:Int, col:Int} {
		var k = p.pfile + ":" + p.pmin;
		var r = lines.get(k);
		if (r == null) {
			var lc = syntax.Lexer.findPos(p);
			r = {line: lc.line - 1, col: lc.column};
			lines.set(k, r);
		}
		return r;
	}

	static final DIGITS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

	static function vlq(b:StringBuf, n:Int) {
		var v = n < 0 ? ((-n) << 1) | 1 : n << 1;
		do {
			var d = v & 31;
			v >>>= 5;
			if (v > 0) d |= 32;
			b.addChar(StringTools.fastCodeAt(DIGITS, d));
		} while (v > 0);
	}
}
