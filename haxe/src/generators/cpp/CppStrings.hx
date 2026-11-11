package generators.cpp;

import core.Globals;
import core.Define;
import haxe.io.Bytes;
import generators.Gctx;

// port: OCaml strings are UTF-8 bytes; the helpers below that index, measure or
// hash strings work on the UTF-8 encoding of the port's strings.
class CppStrings {
	// port: 32-bit wrapping multiplication.
	public static inline function mul32(a:Int, b:Int):Int return ((a & 0xFFFF) * b + ((((a >>> 16) * b) & 0xFFFF) << 16)) | 0;

	public static function genHash32(seed:Int, str:String):Int {
		var h = seed;
		var cycle = 223;
		var b = Bytes.ofString(str);
		for (i in 0...b.length) h = (mul32(h, cycle) + b.get(i)) | 0;
		return h;
	}

	// port: `Printf.sprintf "%0Nlx"`.
	public static function hex(i:Int, width:Int):String {
		var s = StringTools.hex(i).toLowerCase();
		return StringTools.lpad(s, "0", width);
	}

	public static function hash64(s:String):String return haxe.crypto.Md5.make(Bytes.ofString(s)).toHex().substr(0, 16);

	public static function genHash(seed:Int, str:String):String return "0x" + hex(genHash32(seed, str), 8);

	public static function genHashSmall(seed:Int, str:String):String return hex(genHash32(seed, str), 8);

	public static function genQstringHash(str:String):String {
		var h = genHash32(0, str);
		return hex((h << 24) >>> 24, 2) + "," + hex((h << 16) >>> 24, 2) + "," + hex((h << 8) >>> 24, 2) + "," + hex(h >>> 24, 2);
	}

	public static function genWqstringHash(str:String):String {
		var h = genHash32(0, str);
		return hex((h << 16) >>> 16, 4) + "," + hex(h >>> 16, 4);
	}

	// port: special_to_hex over the bytes of `s`.
	static function specialToHexBytes(b:Bytes):String {
		var buf = new StringBuf();
		for (i in 0...b.length) {
			var c = b.get(i);
			if (c > 127 || c < 32) buf.add("\\x" + hex(c, 2) + "\"\"") else buf.addChar(c);
		}
		return buf.toString();
	}

	public static function specialToHex(s:String):String return specialToHexBytes(Bytes.ofString(s));

	// port: `StringHelper.s_escape ~hex:false` over bytes (non-ASCII bytes are kept as they are).
	static function sEscapeBytes(b:Bytes):Bytes {
		var out = new haxe.io.BytesBuffer();
		for (i in 0...b.length) {
			var c = b.get(i);
			switch c {
				case 10:
					out.addByte(92);
					out.addByte("n".code);
				case 9:
					out.addByte(92);
					out.addByte("t".code);
				case 13:
					out.addByte(92);
					out.addByte("r".code);
				case 34:
					out.addByte(92);
					out.addByte(34);
				case 92:
					out.addByte(92);
					out.addByte(92);
				case _:
					out.addByte(c);
			}
		}
		return out.getBytes();
	}

	public static function strq(ctx:Gctx, s:String):String {
		function hasUtf8Chars(s:String):Bool {
			var b = Bytes.ofString(s);
			var result = false;
			for (i in 0...b.length) result = result || b.get(i) > 127;
			return result;
		}

		function genStr(macro_:String, gen:String->String, s:String):String {
			function split(s:Bytes, plus:String):String {
				var escaped = sEscapeBytes(s);
				var hexed = specialToHexBytes(escaped);
				if (hexed.length <= 16000) return plus + " HX_CSTRING(\"" + hexed + "\")" else {
					var len = s.length;
					var half = len >>> 1;
					return split(s.sub(0, half), plus) + split(s.sub(half, len - half), "+");
				}
			}
			var bytes = Bytes.ofString(s);
			var escaped = sEscapeBytes(bytes);
			var hexed = specialToHexBytes(escaped);
			return if (hexed.length <= 16000) macro_ + "(\"" + hexed + "\"," + gen(s) + ")" else "(" + split(bytes, "") + ")";
		}

		return if (Gctx.defined(ctx, Define.HxcppSmartStrings) && hasUtf8Chars(s)) {
			var b = new StringBuf();
			function add(ichar:Int):Void {
				switch ichar {
					case 92 /* \ */:
						b.add("\\\\");
					case 39 /* ' */:
						b.add("\\\'");
					case 34:
						b.add("\\\"");
					case 13 /* \r */:
						b.add("\\r");
					case 10 /* \n */:
						b.add("\\n");
					case 9 /* \t */:
						b.add("\\t");
					case c if (c < 32 || (c >= 127 && c <= 0xFFFF)):
						b.add("\\u" + hex(c, 4));
					case c if (c > 0xFFFF):
						b.add("\\U" + hex(c, 8));
					case c:
						b.addChar(c);
				}
			}
			for (c in new haxe.iterators.StringIteratorUnicode(s)) add(c);
			"HX_W(u\"" + b.toString() + "\"," + genWqstringHash(s) + ")";
		} else genStr("HX_", genQstringHash, s);
	}

	public static function escapeCommand(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var ch = s.charAt(i);
			if (ch == "\"" || ch == "\\") b.add("\\");
			b.add(ch);
		}
		return b.toString();
	}

	public static function constCharStar(s:String):String {
		var escaped = sEscapeBytes(Bytes.ofString(s));
		return "\"" + specialToHexBytes(escaped) + "\"";
	}

	public static function makePathAbsolute(path:String, pos:Pos):String {
		// port: `String.sub path 0 2` raises Invalid_argument for shorter strings.
		if (Bytes.ofString(path).length < 2) return path;
		if (path.substr(0, 2) == "./") {
			var base = if (core.OcamlFilename.isRelative(pos.pfile)) core.OcamlFilename.concat(core.OcamlFilename.sysGetcwd(), pos.pfile) else pos.pfile;
			return core.Path.normalizePath(core.OcamlFilename.concat(core.OcamlFilename.dirname(base), path.substr(2)));
		} else return path;
	}

	public static function pathOfString(path:String):GlobalTypePath return {pack: ["@verbatim"], name: path};

	public static function getAllMetaStringPath(metaList:core.Ast.Metadata, key:core.MetaList.StrictMeta):Array<String> {
		function extractPath(pos:Pos, expr:core.Ast.Expr):String {
			return switch expr.expr {
				case EConst(String(name, _)): makePathAbsolute(name, pos);
				case _: "";
			}
		}
		var result = [];
		for (meta in metaList) if (core.Meta.metaEq(key, meta.meta)) {
			// port: List.hd raises Failure "hd" on an empty argument list.
			if (meta.exprs.length == 0) throw new core.ds.Failure("hd");
			result.push(extractPath(meta.pos, meta.exprs[0]));
		}
		return result;
	}
}
