package hxmc.wasm;

import hxmc.Buf;

// WebAssembly's encodings: LEB128 numbers, value types, the opcodes the
// code generator writes (WebAssembly 3.0: bulk memory, non-trapping
// conversions, exception handling with try_table; or, with
// -D hxmc.wasm-eh=legacy, the legacy try/catch_all/rethrow instructions).
class Enc {
	public static inline var I32 = 0x7F;
	public static inline var I64 = 0x7E;
	public static inline var F32 = 0x7D;
	public static inline var F64 = 0x7C;
	public static inline var V128 = 0x7B;
	public static inline var VOID = 0x40; // the empty block type
	public static inline var EXNREF = 0x69; // exnref: a caught exception (value type and heap type)

	public static function uleb(b:Buf, v:Int) {
		do {
			var x = v & 0x7f;
			v >>>= 7;
			if (v != 0) x |= 0x80;
			b.u8(x);
		} while (v != 0);
	}

	public static function sleb(b:Buf, v:Int) {
		while (true) {
			var x = v & 0x7f;
			v >>= 7;
			if ((v == 0 && (x & 0x40) == 0) || (v == -1 && (x & 0x40) != 0)) {
				b.u8(x);
				return;
			}
			b.u8(x | 0x80);
		}
	}

	// a signed 64-bit number from its halves
	public static function sleb64(b:Buf, lo:Int, hi:Int) {
		if ((hi == 0 && lo >= 0) || (hi == -1 && lo < 0)) {
			sleb(b, lo);
			return;
		}
		// 7 bits at a time over the 64-bit value (lo: bits 0-31, hi: 32-63)
		while (true) {
			var x = lo & 0x7f;
			// shift right arithmetically by 7 across the halves
			lo = (lo >>> 7) | (hi << 25);
			hi = hi >> 7;
			var done = (hi == 0 && lo == 0 && (x & 0x40) == 0) || (hi == -1 && lo == -1 && (x & 0x40) != 0);
			if (done) {
				b.u8(x);
				return;
			}
			b.u8(x | 0x80);
		}
	}

	// a padded LEB of 5 bytes (relocated later)
	public static function uleb5(b:Buf, v:Int) {
		for (k in 0...4)
			b.u8(((v >>> (7 * k)) & 0x7f) | 0x80);
		b.u8((v >>> 28) & 0x7f);
	}

	public static function name(b:Buf, s:String) {
		var bs = haxe.io.Bytes.ofString(s);
		uleb(b, bs.length);
		b.bytes(bs);
	}

	// the size of a section or body in front of it
	public static function sized(out:Buf, body:Buf) {
		uleb(out, body.len);
		out.buf(body);
	}
}

// opcodes
enum abstract Op(Int) to Int {
	var Unreachable = 0x00;
	var Nop = 0x01;
	var Block = 0x02;
	var Loop = 0x03;
	var If = 0x04;
	var Else = 0x05;
	var Try = 0x06; // legacy exception handling
	var Throw = 0x08;
	var Rethrow = 0x09; // legacy
	var ThrowRef = 0x0A;
	var End = 0x0B;
	var Br = 0x0C;
	var BrIf = 0x0D;
	var BrTable = 0x0E;
	var Return = 0x0F;
	var Call = 0x10;
	var CallIndirect = 0x11;
	var CatchAll = 0x19; // legacy
	var Drop = 0x1A;
	var Select = 0x1B;
	var TryTable = 0x1F;
	var LocalGet = 0x20;
	var LocalSet = 0x21;
	var LocalTee = 0x22;
	var GlobalGet = 0x23;
	var GlobalSet = 0x24;
	var I32Load = 0x28;
	var I64Load = 0x29;
	var F32Load = 0x2A;
	var F64Load = 0x2B;
	var I32Load8S = 0x2C;
	var I32Load8U = 0x2D;
	var I32Load16S = 0x2E;
	var I32Load16U = 0x2F;
	var I64Load8S = 0x30;
	var I64Load8U = 0x31;
	var I64Load16S = 0x32;
	var I64Load16U = 0x33;
	var I64Load32S = 0x34;
	var I64Load32U = 0x35;
	var I32Store = 0x36;
	var I64Store = 0x37;
	var F32Store = 0x38;
	var F64Store = 0x39;
	var I32Store8 = 0x3A;
	var I32Store16 = 0x3B;
	var I64Store8 = 0x3C;
	var I64Store16 = 0x3D;
	var I64Store32 = 0x3E;
	var MemorySize = 0x3F;
	var MemoryGrow = 0x40;
	var I32Const = 0x41;
	var I64Const = 0x42;
	var F32Const = 0x43;
	var F64Const = 0x44;
	var I32Eqz = 0x45;
	var RefNull = 0xD0;
	var RefIsNull = 0xD1;
	var I32Eq = 0x46;
	var I32Ne = 0x47;
	var I32LtS = 0x48;
	var I32LtU = 0x49;
	var I32GtS = 0x4A;
	var I32GtU = 0x4B;
	var I32LeS = 0x4C;
	var I32LeU = 0x4D;
	var I32GeS = 0x4E;
	var I32GeU = 0x4F;
	var I64Eqz = 0x50;
	var I64Eq = 0x51;
	var I64Ne = 0x52;
	var I64LtS = 0x53;
	var I64LtU = 0x54;
	var I64GtS = 0x55;
	var I64GtU = 0x56;
	var I64LeS = 0x57;
	var I64LeU = 0x58;
	var I64GeS = 0x59;
	var I64GeU = 0x5A;
	var F64Eq = 0x61;
	var F64Ne = 0x62;
	var F64Lt = 0x63;
	var F64Gt = 0x64;
	var F64Le = 0x65;
	var F64Ge = 0x66;
	var I32Clz = 0x67;
	var I32Ctz = 0x68;
	var I32Add = 0x6A;
	var I32Sub = 0x6B;
	var I32Mul = 0x6C;
	var I32DivS = 0x6D;
	var I32DivU = 0x6E;
	var I32RemS = 0x6F;
	var I32RemU = 0x70;
	var I32And = 0x71;
	var I32Or = 0x72;
	var I32Xor = 0x73;
	var I32Shl = 0x74;
	var I32ShrS = 0x75;
	var I32ShrU = 0x76;
	var I32Rotl = 0x77;
	var I32Rotr = 0x78;
	var I64Clz = 0x79;
	var I64Ctz = 0x7A;
	var I64Add = 0x7C;
	var I64Sub = 0x7D;
	var I64Mul = 0x7E;
	var I64DivS = 0x7F;
	var I64DivU = 0x80;
	var I64RemS = 0x81;
	var I64RemU = 0x82;
	var I64And = 0x83;
	var I64Or = 0x84;
	var I64Xor = 0x85;
	var I64Shl = 0x86;
	var I64ShrS = 0x87;
	var I64ShrU = 0x88;
	var I64Rotl = 0x89;
	var I64Rotr = 0x8A;
	var F64Abs = 0x99;
	var F64Neg = 0x9A;
	var F64Ceil = 0x9B;
	var F64Floor = 0x9C;
	var F64Trunc = 0x9D;
	var F64Nearest = 0x9E;
	var F64Sqrt = 0x9F;
	var F64Add = 0xA0;
	var F64Sub = 0xA1;
	var F64Mul = 0xA2;
	var F64Div = 0xA3;
	var F64Min = 0xA4;
	var F64Max = 0xA5;
	var F64Copysign = 0xA6;
	var I32WrapI64 = 0xA7;
	var I64ExtendI32S = 0xAC;
	var I64ExtendI32U = 0xAD;
	var F32DemoteF64 = 0xB6;
	var F64ConvertI32S = 0xB7;
	var F64ConvertI32U = 0xB8;
	var F64ConvertI64S = 0xB9;
	var F64ConvertI64U = 0xBA;
	var F64PromoteF32 = 0xBB;
	var I32ReinterpretF32 = 0xBC;
	var I64ReinterpretF64 = 0xBD;
	var F32ReinterpretI32 = 0xBE;
	var F64ReinterpretI64 = 0xBF;
	var Prefix = 0xFC; // then: 2 i32.trunc_sat_f64_s, 6 i64.trunc_sat_f64_s, 10 memory.copy, 11 memory.fill
}
