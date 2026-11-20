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
