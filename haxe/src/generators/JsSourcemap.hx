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

package generators;

import core.Globals;
import core.TType;

@:structInit class SourcemapPos {
	public final file:Int;
	public final line:Int;
	public final col:Int;
}

@:structInit class Sourcemap {
	public final sources:Array<String>;
	// port: (string, int) Hashtbl.t upstream; only looked up, so a StringMap keeps the behavior.
	public final sourcesHash:haxe.ds.StringMap<Int>;
	public final mappings:StringBuf;
	public var sourceLastPos:SourcemapPos;
	public var printComma:Bool;
	public var outputLastCol:Int;
	public var outputCurrentCol:Int;
	public var currentExpr:Null<SourcemapPos>;
	/* the file of the last mapping, its index in [sources] and its lines */
	public var lastFile:Null<{name:String, file:Int, lexerFile:syntax.Lexer.LexerFile}>;
}

/* The mappings of a fragment, encoded from an empty state with its own sources. */
@:structInit class EncodedFragment {
	public final efMappings:String;
	public final efSources:Array<String>;
	/* the final state */
	public final efLastPos:Null<SourcemapPos>;
	public final efOutputLastCol:Int;
	public final efOutputCurrentCol:Int;
	public final efPrintComma:Bool;
	public final efHasNewline:Bool;
	/* the mappings after the first one, encoded for the global indexes of the
		sources when they are not only shifted (computed in parallel before the
		fragments are spliced in order) */
	public var efSpliced:Null<{globals:Array<Int>, tail:String}>;
}

class JsSourcemap {
	static final base64Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

	/* Adds [number] to [b] as a base64 VLQ. */
	static function addVlqDigits(b:StringBuf, vlq:Int):Void {
		var digit = vlq & 31, next = vlq >> 5;
		b.addChar(StringTools.fastCodeAt(base64Chars, if (next > 0) digit | 32 else digit));
		if (next > 0) addVlqDigits(b, next);
	}

	static function addBase64Vlq(b:StringBuf, number:Int):Void {
		addVlqDigits(b, if (number < 0) ((-number) << 1) + 1 else number << 1);
	}

	public static function encodeMapping(smap:Sourcemap, pos:SourcemapPos):Void {
		if (smap.printComma) smap.mappings.addChar(",".code) else smap.printComma = true;
		var b = smap.mappings, last = smap.sourceLastPos;
		addBase64Vlq(b, smap.outputCurrentCol - smap.outputLastCol);
		addBase64Vlq(b, pos.file - last.file);
		addBase64Vlq(b, pos.line - last.line);
		addBase64Vlq(b, pos.col - last.col);
		smap.sourceLastPos = pos;
		smap.outputLastCol = smap.outputCurrentCol;
	}

	public static function noop():Void {}

	/* The index of [file_name] in the sources (in their order of first use), and its lines. */
	static function sourceFile(smap:Sourcemap, fileName:String):{name:String, file:Int, lexerFile:syntax.Lexer.LexerFile} {
		var last = smap.lastFile;
		if (last != null && last.name == fileName) return last;
		var file = smap.sourcesHash.get(fileName);
		if (file == null) {
			var length = smap.sources.length;
			smap.sourcesHash.set(fileName, length);
			smap.sources.push(fileName);
			file = length;
		}
		return smap.lastFile = {name: fileName, file: file, lexerFile: syntax.Lexer.findFile(fileName)};
	}

	/* What [add_mapping] gives when the mapping did not change: nothing to put
		back. */
	public static final unchanged:SourcemapPos = {file: -2, line: 0, col: 0};

	/* Maps the output that follows to [pos]: gives the mapping to put back with
		[clear_mapping] once the expression is output (no closure, no option is
		allocated for it). */
	static function addSourceMapping(smap:Sourcemap, pos:SourcemapPos):Null<SourcemapPos> {
		var last = smap.sourceLastPos;
		if (last.file != pos.file || last.line != pos.line || last.col != pos.col) {
			var oldCurrentExpr = smap.currentExpr;
			smap.currentExpr = pos;
			encodeMapping(smap, pos);
			return oldCurrentExpr;
		} else return unchanged;
	}

	static function addMappingPos(smap:Sourcemap, pos:Pos):Null<SourcemapPos> {
		if (pos.pmin < 0) return unchanged;
		var sf = sourceFile(smap, pos.pfile);
		var lc = syntax.Lexer.findLine(pos.pmin, sf.lexerFile);
		return addSourceMapping(smap, {file: sf.file, line: lc.line - 1, col: lc.column});
	}

	public static function addMapping(smap:Null<Sourcemap>, e:TExpr):Null<SourcemapPos> {
		return smap == null ? unchanged : addMappingPos(smap, e.epos);
	}

	public static function clearMapping(smap:Null<Sourcemap>, old:Null<SourcemapPos>):Void {
		if (old != unchanged && smap != null) smap.currentExpr = old;
	}

	// port: OCaml strings are UTF-8 bytes, so String.length counts bytes; the host strings are UTF-16
	// (a character past U+FFFF a surrogate pair, a byte that is not UTF-8 a lone U+DC80 to
	// U+DCFF), or code points on a code point host (core.StringHelper.codePointHost: such a
	// character is one, of 4 bytes).
	public static function utf8Length(s:String, from:Int, to:Int):Int {
		var n = 0, i = from;
		while (i < to) {
			var c = StringTools.fastCodeAt(s, i++);
			if (c < 0x80) n++;
			else if (c < 0x800) n += 2;
			else if (c >= 0xD800 && c < 0xDC00 && i < to) {
				var d = StringTools.fastCodeAt(s, i);
				if (d >= 0xDC00 && d < 0xE000) {
					i++;
					n += 4;
				} else n += 3;
			} else if (!core.StringHelper.codePointHost && c >= 0xDC80 && c < 0xDD00) n++;
			else n += core.StringHelper.codePointHost && c >= 0x10000 ? 4 : 3;
		}
		return n;
	}

	/* The text [str] from [from] to [upto] is output. */
	public static function handleNewlinesSub(smap:Sourcemap, str:String, from:Int, upto:Int):Void {
		function loop(from:Int):Void {
			var i = str.indexOf("\n", from);
			if (i >= 0 && i < upto) {
				smap.mappings.addChar(";".code);
				smap.outputLastCol = 0;
				smap.outputCurrentCol = 0;
				smap.printComma = false;
				if (smap.currentExpr != null) encodeMapping(smap, smap.currentExpr);
				loop(i + 1);
			} else smap.outputCurrentCol = smap.outputCurrentCol + utf8Length(str, from, upto);
		}
		loop(from);
	}

	public static function handleNewlines(smap:Null<Sourcemap>, str:String):Void {
		if (smap != null) handleNewlinesSub(smap, str, 0, str.length);
	}

	public static function create():Sourcemap return {
		sourceLastPos: {file: 0, line: 0, col: 0},
		printComma: false,
		outputLastCol: 0,
		outputCurrentCol: 0,
		sources: [],
		sourcesHash: new haxe.ds.StringMap(),
		mappings: new StringBuf(),
		currentExpr: null,
		lastFile: null,
	};

	public static function encodedFragment(smap:Sourcemap):EncodedFragment {
		var mappings = smap.mappings.toString();
		return {
			efMappings: mappings,
			efSources: smap.sources.copy(),
			efLastPos: if (smap.sources.length == 0) null else smap.sourceLastPos,
			efOutputLastCol: smap.outputLastCol,
			efOutputCurrentCol: smap.outputCurrentCol,
			efPrintComma: smap.printComma,
			efHasNewline: mappings.length > 0 && mappings.indexOf(";") >= 0,
			efSpliced: null,
		};
	}

	// port: String.index base64_chars c, which raises Not_found for another character (unsafe_get
	// ... past the end reads the terminating NUL).
	static function base64Digit(s:String, i:Int):Int {
		var c = if (i < s.length) StringTools.fastCodeAt(s, i) else 0;
		return if (c >= "A".code && c <= "Z".code) c - "A".code else if (c >= "a".code && c <= "z".code) c - "a".code + 26 else if (c >= "0".code
			&& c <= "9".code) c - "0".code + 52 else if (c == "+".code) 62 else if (c == "/".code) 63 else throw core.ds.NotFound.raise();
	}

	static function decodeVlq(s:String, i:Int):{next:Int, value:Int} {
		function loop(i:Int, shift:Int, acc0:Int):{next:Int, value:Int} {
			var digit = base64Digit(s, i);
			var acc = acc0 | ((digit & 31) << shift);
			return if (digit & 32 != 0) loop(i + 1, shift + 5, acc) else {next: i + 1, value: if (acc & 1 == 1) -(acc >>> 1) else acc >>> 1};
		}
		return loop(i, 0, 0);
	}

	/* Where the mappings after the first one start, and the source of the
		first one. */
	static function firstMapping(m:String):{next:Int, file:Int} {
		var len = m.length;
		var i = 0;
		while (i < len && StringTools.fastCodeAt(m, i) == ";".code) i++;
		var d1 = decodeVlq(m, i);
		var d2 = decodeVlq(m, d1.next);
		var d3 = decodeVlq(m, d2.next);
		var d4 = decodeVlq(m, d3.next);
		return {next: d4.next, file: d2.value};
	}

	/* Whether the sources of a fragment keep their order once global: the
		deltas of the mappings are then the same. */
	public static function shifted(globals:Array<Int>):Bool {
		for (i in 0...globals.length) if (globals[i] - globals[0] != i) return false;
		return true;
	}

	static function sameGlobals(a:Array<Int>, b:Array<Int>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (a[i] != b[i]) return false;
		return true;
	}

	/* The mappings after the first one of fragment [ef], its sources having
		the global indices [globals]: the same deltas, but the one of their
		source. Kept with the fragment for these indices. */
	public static function splicedTail(ef:EncodedFragment, globals:Array<Int>):String {
		switch ef.efSpliced {
			case {globals: g, tail: tail} if (sameGlobals(g, globals)):
				return tail;
			case _:
		}
		var m = ef.efMappings;
		var len = m.length;
		var first = firstMapping(m);
		var b = new StringBuf();
		function addVlq(number:Int):Void {
			var vlq = if (number < 0) ((-number) << 1) + 1 else number << 1;
			addVlqDigits(b, vlq);
		}
		var local = first.file;
		function loop(i:Int):Void {
			if (i < len) switch StringTools.fastCodeAt(m, i) {
				case c = ";".code | ",".code:
					b.addChar(c);
					loop(i + 1);
				case _:
					/* a segment: column, source, line, column in the source */
					var d1 = decodeVlq(m, i);
					var d2 = decodeVlq(m, d1.next);
					var d3 = decodeVlq(m, d2.next);
					var d4 = decodeVlq(m, d3.next);
					var previous = globals[local];
					local = local + d2.value;
					addVlq(d1.value);
					addVlq(globals[local] - previous);
					addVlq(d3.value);
					addVlq(d4.value);
					loop(d4.next);
			}
		}
		loop(first.next);
		var tail = b.toString();
		ef.efSpliced = {globals: globals, tail: tail};
		return tail;
	}

	/* The global indices that the sources of the fragments [efs] get when they
		are spliced in this order into [smap] (without changing it): their
		mappings are transcoded for them in parallel, before being spliced in
		order. A fragment that cannot be spliced (generated again) may use its
		sources in another order: the tails computed for the fragments after it
		are then not used. */
	public static function predictGlobals(smap:Sourcemap, efs:Array<Null<EncodedFragment>>):Array<Null<Array<Int>>> {
		var known = smap.sourcesHash.copy();
		var n = smap.sources.length;
		return [
			for (ef in efs)
				if (ef != null && ef.efLastPos != null) [
					for (name in ef.efSources)
						switch known.get(name) {
							case null:
								var i = n;
								known.set(name, i);
								n++;
								i;
							case i: i;
						}
				] else null
		];
	}

	/* Puts the mappings of a fragment, whose text was just output, in [smap]
		(the state before the text is [col0], [last_col0], [comma0]): the
		encoded mappings are transcoded, the indices of their sources becoming
		those of [smap], and the first one encoded relatively to the previous
		mapping. Only when the state is the one of the fragment's start (no
		current expression, the first mapping not the same position as the
		previous one, which would not have been output): false otherwise, and
		nothing done. */
	public static function spliceFragment(smap:Sourcemap, ef:EncodedFragment, col0:Int, lastCol0:Int, comma0:Bool):Bool {
		if (smap.currentExpr != null) return false;
		if (ef.efLastPos == null) {
			/* no mapping: only newlines and columns */
			if (ef.efHasNewline) {
				smap.mappings.add(ef.efMappings);
				smap.outputLastCol = ef.efOutputLastCol;
				smap.outputCurrentCol = ef.efOutputCurrentCol;
				smap.printComma = ef.efPrintComma;
			} else smap.outputCurrentCol = col0 + ef.efOutputCurrentCol;
			return true;
		}
		var m = ef.efMappings;
		var len = m.length;
		/* the leading newlines, then the first mapping */
		var i = 0;
		while (i < len && StringTools.fastCodeAt(m, i) == ";".code) i++;
		var newlines = i;
		var d1 = decodeVlq(m, i);
		var d2 = decodeVlq(m, d1.next);
		var d3 = decodeVlq(m, d2.next);
		var d4 = decodeVlq(m, d3.next);
		var dcol = d1.value, dfile = d2.value, dline = d3.value, dscol = d4.value, i4 = d4.next;
		function index(name:String):Null<Int> return smap.sourcesHash.get(name);
		var firstFile = switch index(ef.efSources[dfile]) {
			case null: smap.sources.length;
			case i: i;
		}
		var last = smap.sourceLastPos;
		if (last.file == firstFile && last.line == dline && last.col == dscol) return false;
		/* the sources, in their order of first use */
		var globals = [
			for (name in ef.efSources)
				switch index(name) {
					case null:
						var i = smap.sources.length;
						smap.sourcesHash.set(name, i);
						smap.sources.push(name);
						i;
					case i: i;
				}
		];
		smap.lastFile = null;
		/* the state where the first mapping is encoded */
		for (_ in 0...newlines) smap.mappings.addChar(";".code);
		var col = if (newlines == 0) col0 + dcol else dcol;
		smap.outputLastCol = if (newlines == 0) lastCol0 else 0;
		smap.printComma = if (newlines == 0) comma0 else false;
		smap.outputCurrentCol = col;
		encodeMapping(smap, {file: globals[dfile], line: dline, col: dscol});
		/* the others: the same deltas, but the one of their source */
		if (shifted(globals)) smap.mappings.addSub(m, i4, len - i4) else smap.mappings.add(splicedTail(ef, globals));
		/* the final state */
		var fl = ef.efLastPos;
		smap.sourceLastPos = {file: globals[fl.file], line: fl.line, col: fl.col};
		if (ef.efHasNewline) {
			smap.outputLastCol = ef.efOutputLastCol;
			smap.outputCurrentCol = ef.efOutputCurrentCol;
			smap.printComma = ef.efPrintComma;
		} else {
			smap.outputLastCol = col0 + ef.efOutputLastCol;
			smap.outputCurrentCol = col0 + ef.efOutputCurrentCol;
			smap.printComma = true;
		}
		return true;
	}

	/* The source map as JSON text. */
	public static function mappingsJson(com:Gctx, smap:Sourcemap, sourcePathPrefix:String):String {
		var basefile = core.OcamlFilename.basename(com.file);
		var b = new StringBuf();
		var sources = smap.sources;
		function toUrl(file:String):String return core.Path.getFullPath(file).split("\\").join("/");
		b.add("{\n");
		b.add("\"version\":3,\n");
		b.add("\"file\":\"" + (basefile.split("\\").join("\\\\")) + "\",\n");
		b.add("\"sourceRoot\":\"\",\n");
		b.add("\"sources\":[" + ([for (s in sources) "\"" + sourcePathPrefix + toUrl(s) + "\""].join(",")) + "],\n");
		if (Gctx.defined(com, core.Define.SourceMapContent)) {
			b.add("\"sourcesContent\":["
				+ ([
					for (s in sources)
						try "\"" + core.StringHelper.sEscape(sys.io.File.getBytes(s).toString()) + "\"" catch (_:Dynamic) "null"
				].join(","))
				+ "],\n");
		}
		b.add("\"names\":[],\n");
		b.add("\"mappings\":\"");
		b.add(smap.mappings.toString());
		b.add("\"\n");
		b.add("}");
		return b.toString();
	}

	/* The source map, written next to the output as [<output>.map]. */
	public static function writeMappings(com:Gctx, smap:Sourcemap, sourcePathPrefix:String):Void {
		var channel = sys.io.File.write(com.file + ".map", true);
		channel.writeString(mappingsJson(com, smap, sourcePathPrefix));
		channel.close();
	}

	/* The source map as a data: URL, for a [sourceMappingURL] comment: base64, padded. */
	public static function mappingsDataUrl(com:Gctx, smap:Sourcemap, sourcePathPrefix:String):String {
		var json = mappingsJson(com, smap, sourcePathPrefix);
		// port: ExtLib's Base64.str_encode with the standard table, which writes no '=' padding, over the
		// ... JSON's UTF-8 bytes.
		var encoded = haxe.crypto.Base64.encode(haxe.io.Bytes.ofString(json), false);
		var padding = (4 - encoded.length % 4) % 4;
		return "data:application/json;charset=utf-8;base64," + encoded + StringTools.lpad("", "=", padding);
	}
}
