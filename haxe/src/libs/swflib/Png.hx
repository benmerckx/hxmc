/*
 *  PNG File Format Library
 *  Copyright (c)2005 Nicolas Cannasse
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
 */

package libs.swflib;

import haxe.io.Bytes;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;
import libs.extlib.IO;
import libs.extlib.IO.Input;

// port: haxe/libs/swflib/png.ml, the reading half genswf uses (parse, header,
// data, filter). The writers (output_crc, write_chunk, write_header, write,
// make) and the chunk-name predicates have no caller in the compiler and are
// not translated. Chunk data (OCaml strings) is Bytes.
enum GreyBits {
	GBits1;
	GBits2;
	GBits4;
	GBits8;
	GBits16;
}

enum GreyAlphaBits {
	GABits8;
	GABits16;
}

enum TrueBits {
	TBits8;
	TBits16;
}

enum IndexBits {
	IBits1;
	IBits2;
	IBits4;
	IBits8;
}

enum Alpha {
	NoAlpha;
	HaveAlpha;
}

enum PngColor {
	ClGreyScale(g:GreyBits);
	ClGreyAlpha(g:GreyAlphaBits);
	ClTrueColor(t:TrueBits, a:Alpha);
	ClIndexed(i:IndexBits);
}

typedef PngHeader = {
	var png_width:Int;
	var png_height:Int;
	var png_color:PngColor;
	var png_interlace:Bool;
}

typedef ChunkId = String;

enum Chunk {
	CEnd;
	CHeader(h:PngHeader);
	CData(s:Bytes);
	CPalette(s:Bytes);
	CUnknown(id:ChunkId, data:Bytes);
}

typedef PngData = Array<Chunk>;

enum ErrorMsg {
	Invalid_header;
	Invalid_file;
	Truncated_file;
	Invalid_CRC;
	Invalid_colors;
	Unsupported_colors;
	Invalid_datasize;
	Invalid_filter(f:Int);
	Invalid_array;
}

class PngError extends haxe.Exception {
	public final msg:ErrorMsg;

	// port: the message is Printexc.to_string of the uncaught `Png.Error msg`
	// (constant constructors print their index, the others `_`).
	public function new(msg:ErrorMsg) {
		super("Png.Error(" + (switch msg {
			case Invalid_filter(_): "_";
			case Invalid_array: "7";
			case m: Std.string(m.getIndex());
		}) + ")");
		this.msg = msg;
	}
}

class Png {
	public static function error_msg(e:ErrorMsg):String return switch e {
		case Invalid_header: "Invalid header";
		case Invalid_file: "Invalid file";
		case Truncated_file: "Truncated file";
		case Invalid_CRC: "Invalid CRC";
		case Invalid_colors: "Invalid color model";
		case Unsupported_colors: "Unsupported color model";
		case Invalid_datasize: "Invalid data size";
		case Invalid_filter(f): "Invalid filter " + f;
		case Invalid_array: "Invalid array";
	}

	static function error(msg:ErrorMsg):Dynamic throw new PngError(msg);

	static function is_id_char(c:Int):Bool return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);

	public static function header(l:PngData):PngHeader {
		for (c in l) switch c {
			case CHeader(h): return h;
			case _:
		}
		return error(Invalid_file);
	}

	public static function data(f:PngData):Bytes {
		var acc = new haxe.io.BytesBuffer();
		var found = false;
		for (c in f) switch c {
			case CData(s):
				found = true;
				acc.add(s);
			case _:
		}
		if (!found) error(Invalid_file);
		return acc.getBytes();
	}

	static final crc_table:Vector<Int> = {
		var t = new Vector<Int>(256);
		for (n in 0...256) {
			var c = n;
			for (k in 0...8) {
				if (c & 1 != 0)
					c = 0xEDB88320 ^ (c >>> 1)
				else
					c = (c >>> 1);
			}
			t[n] = c;
		}
		t;
	};

	static function input_crc(ch:Input):{ch:Input, crc:Void->Int} {
		var crc = 0xFFFFFFFF;
		function update(c:Int) {
			var k = crc_table[(crc ^ c) & 0xFF];
			crc = k ^ (crc >>> 8);
		}
		var ch2 = IO.createIn(() -> {
			var c = IO.read(ch);
			update(c);
			c;
		}, (s, p, l) -> {
			var l = IO.input(ch, s, p, l);
			for (i in 0...l) update(s.get(p + i));
			l;
		}, () -> IO.closeIn(ch));
		return {ch: ch2, crc: () -> crc ^ 0xFFFFFFFF};
	}

	static function parse_header(ch:Input):PngHeader {
		var width = IO.beReadI32(ch);
		var height = IO.beReadI32(ch);
		if (width < 0 || height < 0) error(Invalid_header);
		var bits = IO.readByte(ch);
		var color = IO.readByte(ch);
		var color = (switch color {
			case 0: ClGreyScale(switch bits {
					case 1: GBits1;
					case 2: GBits2;
					case 4: GBits4;
					case 8: GBits8;
					case 16: GBits16;
					case _: error(Invalid_colors);
				});
			case 2: ClTrueColor((switch bits {
					case 8: TBits8;
					case 16: TBits16;
					case _: error(Invalid_colors);
				}), NoAlpha);
			case 3: ClIndexed(switch bits {
					case 1: IBits1;
					case 2: IBits2;
					case 4: IBits4;
					case 8: IBits8;
					case _: error(Invalid_colors);
				});
			case 4: ClGreyAlpha(switch bits {
					case 8: GABits8;
					case 16: GABits16;
					case _: error(Invalid_colors);
				});
			case 6: ClTrueColor((switch bits {
					case 8: TBits8;
					case 16: TBits16;
					case _: error(Invalid_colors);
				}), HaveAlpha);
			case _: error(Invalid_colors);
		});
		var compress = IO.readByte(ch);
		var filter = IO.readByte(ch);
		if (compress != 0 || filter != 0) error(Invalid_header);
		var interlace = IO.readByte(ch);
		var interlace = (switch interlace {
			case 0: false;
			case 1: true;
			case _: error(Invalid_header);
		});
		return {
			png_width: width,
			png_height: height,
			png_color: color,
			png_interlace: interlace,
		};
	}

	static function parse_chunk(ch:Input):Chunk {
		var len = IO.beReadI32(ch);
		var c = input_crc(ch);
		var ch2 = c.ch, crc = c.crc;
		var idb = IO.nread(ch2, 4);
		// port: `id.[i]` raises Invalid_argument past the end of a short read.
		if (idb.length < 4) throw new core.ds.InvalidArgument("index out of bounds");
		if (len < 0 || !is_id_char(idb.get(0)) || !is_id_char(idb.get(1)) || !is_id_char(idb.get(2)) || !is_id_char(idb.get(3))) error(Invalid_file);
		var id = idb.toString();
		var data = IO.nread(ch2, len);
		var crc_val = IO.beReadRealI32(ch);
		if (crc_val != crc()) error(Invalid_CRC);
		return switch id {
			case "IEND": CEnd;
			case "IHDR": CHeader(parse_header(IO.inputString(data)));
			case "IDAT": CData(data);
			case "PLTE": CPalette(data);
			case _: CUnknown(id, data);
		}
	}

	static final png_sign = Bytes.ofHex("89504e470d0a1a0a");

	public static function parse(ch:Input):PngData {
		var sign = (try IO.nread(ch, png_sign.length) catch (_:libs.extlib.IO.NoMoreInput) error(Invalid_header));
		if (sign.compare(png_sign) != 0) error(Invalid_header);
		var acc = [];
		try {
			while (true) {
				switch parse_chunk(ch) {
					case CEnd:
						return acc;
					case c:
						acc.push(c);
				}
			}
		} catch (_:libs.extlib.IO.NoMoreInput) {
			return error(Truncated_file);
		} catch (_:libs.extlib.IO.Overflow) {
			return error(Invalid_file);
		}
	}

	public static function filter(png:PngData, data:Bytes):Bytes {
		var head = header(png);
		var w = head.png_width;
		var h = head.png_height;
		switch head.png_color {
			case ClGreyScale(_) | ClGreyAlpha(_) | ClIndexed(_) | ClTrueColor(TBits16, _):
				return error(Unsupported_colors);
			case ClTrueColor(TBits8, alpha):
				var alpha = (switch alpha {
					case NoAlpha: false;
					case HaveAlpha: true;
				});
				var buf = Bytes.alloc(w * h * 4);
				var nbytes = if (alpha) 4 else 3;
				var stride = nbytes * w + 1;
				if (data.length < h * stride) error(Invalid_datasize);
				var bp = 0;
				// port: String.unsafe_get past the end reads the string's padding (0).
				function get(p:Int):Int return p < data.length ? data.get(p) : 0;
				function bget(p:Int):Int return buf.get(p);
				// port: Char.unsafe_chr keeps the low byte.
				function set(v:Int) {
					buf.set(bp, v & 0xFF);
					bp++;
				}
				var filters:Vector<Int->Int->Int->Int> = vector(
					(x, y, v) -> v,
					(x, y, v) -> {
						var v2 = if (x == 0) 0 else bget(bp - 4);
						v + v2;
					},
					(x, y, v) -> {
						var v2 = if (y == 0) 0 else bget(bp - 4 * w);
						v + v2;
					},
					(x, y, v) -> {
						var v2 = if (x == 0) 0 else bget(bp - 4);
						var v3 = if (y == 0) 0 else bget(bp - 4 * w);
						v + Std.int((v2 + v3) / 2);
					},
					(x, y, v) -> {
						var a = if (x == 0) 0 else bget(bp - 4);
						var b = if (y == 0) 0 else bget(bp - 4 * w);
						var c = if (x == 0 || y == 0) 0 else bget(bp - 4 - 4 * w);
						var p = a + b - c;
						var pa = Std.int(Math.abs(p - a));
						var pb = Std.int(Math.abs(p - b));
						var pc = Std.int(Math.abs(p - c));
						var d = (if (pa <= pb && pa <= pc) a else if (pb <= pc) b else c);
						v + d;
					}
				);
				for (y in 0...h) {
					var f = get(y * stride);
					var f = (if (f < 5) filters[f] else error(Invalid_filter(f)));
					for (x in 0...w) {
						var p = x * nbytes + y * stride;
						if (!alpha) {
							set(255);
							for (c in 1...4) {
								var v = get(p + c);
								set(f(x, y, v));
							}
						} else {
							var v = get(p + 4);
							var a = f(x, y, v);
							set(a);
							for (c in 1...4) {
								var v = get(p + c);
								set(f(x, y, v));
							}
						}
					}
				}
				return buf;
		}
	}
}
