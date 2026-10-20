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
}

class JsSourcemap {
	static final chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

	public static function encodeMapping(smap:Sourcemap, pos:SourcemapPos):Void {
		if (smap.printComma) smap.mappings.addChar(",".code) else smap.printComma = true;

		function base64Vlq(number:Int):Void {
			inline function encodeDigit(digit:Int):Int return StringTools.fastCodeAt(chars, digit);
			inline function toVlq(number:Int):Int return if (number < 0) ((-number) << 1) + 1 else number << 1;
			function loop(vlq:Int):Void {
				var shift = 5;
				var base = 1 << shift;
				var mask = base - 1;
				var continuationBit = base;
				var digit = vlq & mask;
				var next = vlq >> shift;
				smap.mappings.addChar(encodeDigit(if (next > 0) digit | continuationBit else digit));
				if (next > 0) loop(next);
			}
			loop(toVlq(number));
		}

		base64Vlq(smap.outputCurrentCol - smap.outputLastCol);
		base64Vlq(pos.file - smap.sourceLastPos.file);
		base64Vlq(pos.line - smap.sourceLastPos.line);
		base64Vlq(pos.col - smap.sourceLastPos.col);

		smap.sourceLastPos = pos;
		smap.outputLastCol = smap.outputCurrentCol;
	}

	public static function noop():Void {}

	static function addMappingPos(smap:Sourcemap, pos:Pos):Void->Void {
		if (pos.pmin < 0) return noop;

		var file = smap.sourcesHash.get(pos.pfile);
		if (file == null) {
			var length = smap.sources.length;
			smap.sourcesHash.set(pos.pfile, length);
			smap.sources.push(pos.pfile);
			file = length;
		}

		var pos:SourcemapPos = {
			var lc = syntax.Lexer.findPos(pos);
			var line = lc.line - 1;
			{file: file, line: line, col: lc.column};
		}

		var last = smap.sourceLastPos;
		if (last.file != pos.file || last.line != pos.line || last.col != pos.col) {
			var oldCurrentExpr = smap.currentExpr;
			smap.currentExpr = pos;
			encodeMapping(smap, pos);
			return function() smap.currentExpr = oldCurrentExpr;
		} else return noop;
	}

	public static function addMapping(smap:Null<Sourcemap>, e:TExpr):Void->Void {
		return smap == null ? noop : addMappingPos(smap, e.epos);
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

	public static function handleNewlines(smap:Null<Sourcemap>, str:String):Void {
		if (smap != null) {
			function loop(from:Int):Void {
				var idx = str.indexOf("\n", from);
				if (idx >= 0) {
					var next = idx + 1;
					smap.mappings.addChar(";".code);
					smap.outputLastCol = 0;
					smap.outputCurrentCol = 0;
					smap.printComma = false;
					if (smap.currentExpr != null) encodeMapping(smap, smap.currentExpr);
					loop(next);
				} else smap.outputCurrentCol = smap.outputCurrentCol + utf8Length(str, from, str.length);
			}
			loop(0);
		}
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
