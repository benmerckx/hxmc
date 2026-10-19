package hxmc.x64;

import hxmc.Buf;
import hxmc.Obj;

// x86-64 instruction encoder. Registers: 0-15 the general registers (rax,
// rcx, rdx, rbx, rsp, rbp, rsi, rdi, r8-r15), 16-31 xmm0-15. Sizes are in
// bytes (1, 2, 4, 8). Branches go to labels (rel32 at first; `finish`
// shortens what fits in rel8); symbols are relocations of an Obj section.
class Mem {
	public var base:Int; // -1: none (RIP-relative when sym != null, else absolute disp32)
	public var index:Int; // -1: none
	public var scale:Int; // 1, 2, 4, 8
	public var disp:Int;
	public var sym:Null<Symbol>; // RIP-relative symbol (disp is the addend)
	public var tls:Bool = false; // fs:[sym@tpoff + disp] (local-exec TLS)
	public var gs:Bool = false; // gs:[disp32] (Windows: the thread environment block)
	public var dispSym:Null<Symbol>; // [base + disp32] with the displacement relocated (dispKind)
	public var dispKind:RelKind = RSecRel32;

	public function new(base:Int, disp:Int = 0, index:Int = -1, scale:Int = 1) {
		this.base = base;
		this.disp = disp;
		this.index = index;
		this.scale = scale;
	}

	public static function rip(sym:Symbol, addend = 0):Mem {
		var m = new Mem(-1, addend);
		m.sym = sym;
		return m;
	}

	public static function tlsVar(sym:Symbol, addend = 0):Mem {
		var m = new Mem(-1, addend);
		m.sym = sym;
		m.tls = true;
		return m;
	}

	public function toString():String {
		var parts = [];
		if (tls) return 'fs:[${sym.name}@tpoff+$disp]';
		if (sym != null) return '[rip+${sym.name}+$disp]';
		if (base >= 0) parts.push(Asm.regName(base, 8));
		if (index >= 0) parts.push(Asm.regName(index, 8) + "*" + scale);
		var s = parts.join("+");
		if (disp != 0 || s == "") s += (disp < 0 ? "-" : (s == "" ? "" : "+")) + Std.string(disp < 0 ? -disp : disp);
		return '[$s]';
	}
}

enum abstract CC(Int) to Int from Int {
	var O = 0;
	var NO = 1;
	var B = 2;
	var AE = 3;
	var E = 4;
	var NE = 5;
	var BE = 6;
	var A = 7;
	var S = 8;
	var NS = 9;
	var P = 10;
	var NP = 11;
	var L = 12;
	var GE = 13;
	var LE = 14;
	var G = 15;
}

class Asm {
	public static inline var RAX = 0;
	public static inline var RCX = 1;
	public static inline var RDX = 2;
	public static inline var RBX = 3;
	public static inline var RSP = 4;
	public static inline var RBP = 5;
	public static inline var RSI = 6;
	public static inline var RDI = 7;
	public static inline var R8 = 8;
	public static inline var R9 = 9;
	public static inline var R10 = 10;
	public static inline var R11 = 11;
	public static inline var R12 = 12;
	public static inline var R13 = 13;
	public static inline var R14 = 14;
	public static inline var R15 = 15;
	public static inline var XMM0 = 16;

	// ALU operations (the /digit of 0x81/0x83 and the opcode row of 0x01..0x3b)
	public static inline var ADD = 0;
	public static inline var OR = 1;
	public static inline var AND = 4;
	public static inline var SUB = 5;
	public static inline var XOR = 6;
	public static inline var CMP = 7;
	// shifts (/digit of 0xc1/0xd3)
	public static inline var ROR = 1;
	public static inline var SHL = 4;
	public static inline var SHR = 5;
	public static inline var SAR = 7;

	public var b:Buf;
	public var sec:Null<Section>;
	// the next 32-bit immediate is this symbol's value + the immediate (an absolute relocation)
	public var isym:Null<Symbol>;
	var ripPlaceholder = false;
	var labels:Array<Int> = []; // label -> position (-1: not bound)
	var fixups:Array<Fixup> = [];

	public function new(?sec:Section) {
		this.sec = sec;
		b = sec != null ? sec.buf : new Buf(4096);
	}

	public static function regName(r:Int, size:Int):String {
		if (r >= 16) return "xmm" + (r - 16);
		var n64 = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi"];
		var n32 = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"];
		var n16 = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di"];
		var n8 = ["al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil"];
		if (r < 8) return switch size {
			case 8: n64[r];
			case 4: n32[r];
			case 2: n16[r];
			case _: n8[r];
		}
		return "r" + r + (switch size {
			case 8: "";
			case 4: "d";
			case 2: "w";
			case _: "b";
		});
	}

	// ---- labels

	// a new function: its own labels
	public function reset() {
		labels = [];
		fixups = [];
	}

	public function newLabel():Int {
		labels.push(-1);
		return labels.length - 1;
	}

	public function bind(l:Int) {
		labels[l] = b.len;
	}

	public inline function pos():Int
		return b.len;

	public function labelPos(l:Int):Int
		return labels[l];

	// ---- encoding core

	// prefix (0x66/0xf2/0xf3 or 0), REX.W, opcode bytes (1-3, in an Int
	// written high byte first: 0x0faf = 0f af), reg field (register or
	// /digit), r/m operand (a register when m == null)
	function op(prefix:Int, w:Bool, opcode:Int, nbytes:Int, reg:Int, rm:Int, m:Null<Mem>, byteRegs = 0, immBytes = 0) {
		if (m != null && m.tls) b.u8(0x64); // fs:
		if (m != null && m.gs) b.u8(0x65); // gs:
		if (prefix != 0) b.u8(prefix);
		var rex = (w ? 8 : 0) | ((reg & 8) != 0 ? 4 : 0);
		if (m == null) {
			if ((rm & 8) != 0) rex |= 1;
		} else {
			if (m.index >= 0 && (m.index & 8) != 0) rex |= 2;
			if (m.base >= 0 && (m.base & 8) != 0) rex |= 1;
		}
		// spl, bpl, sil, dil need a REX prefix
		var force = (byteRegs & 1) != 0 && (reg & 15) >= 4 && (reg & 15) < 8 || (byteRegs & 2) != 0 && m == null && (rm & 15) >= 4 && (rm & 15) < 8;
		if (rex != 0 || force) b.u8(0x40 | rex);
		if (nbytes == 3) b.u8((opcode >> 16) & 0xff);
		if (nbytes >= 2) b.u8((opcode >> 8) & 0xff);
		b.u8(opcode & 0xff);
		var r = reg & 7;
		if (m == null) {
			b.u8(0xc0 | (r << 3) | (rm & 7));
			return;
		}
		if (m.tls) {
			// fs:[disp32] absolute: modrm 00 r 100, SIB 00 100 101
			b.u8((r << 3) | 4);
			b.u8(0x25);
			reloc(RTpOff32, m.sym, m.disp);
			b.u32(0);
			return;
		}
		if (m.sym != null || m.base == -1 && m.index == -1 && m.disp == 0 && m.tls == false && m.sym == null && ripPlaceholder) {
			b.u8((r << 3) | 5);
			if (m.sym == null) {
				b.u32(0);
				return;
			}
			// the displacement is relative to the end of the instruction
			reloc(RPc32, m.sym, m.disp - 4 - immBytes);
			b.u32(0);
			return;
		}
		if (m.gs) {
			b.u8((r << 3) | 4);
			b.u8(0x25);
			b.u32(m.disp);
			return;
		}
		if (m.dispSym != null) {
			// [base (+ index) + disp32] with a relocated displacement
			var base = m.base & 7;
			if (m.index >= 0 || base == 4) {
				b.u8((2 << 6) | (r << 3) | 4);
				b.u8((scaleBits(m.scale) << 6) | ((m.index >= 0 ? m.index : 4) & 7) << 3 | base);
			} else b.u8((2 << 6) | (r << 3) | base);
			reloc(m.dispKind, m.dispSym, m.disp);
			b.u32(0);
			return;
		}
		if (m.base < 0) {
			// [index*scale + disp32] or [disp32]
			b.u8((r << 3) | 4);
			b.u8((scaleBits(m.scale) << 6) | ((m.index >= 0 ? m.index : 4) & 7) << 3 | 5);
			b.u32(m.disp);
			return;
		}
		var base = m.base & 7;
		var mod = m.disp == 0 && base != 5 ? 0 : (m.disp >= -128 && m.disp <= 127 ? 1 : 2);
		if (m.index >= 0 || base == 4) {
			b.u8((mod << 6) | (r << 3) | 4);
			b.u8((scaleBits(m.scale) << 6) | ((m.index >= 0 ? m.index : 4) & 7) << 3 | base);
		} else b.u8((mod << 6) | (r << 3) | base);
		if (mod == 1) b.u8(m.disp & 0xff) else if (mod == 2) b.u32(m.disp);
	}

	static inline function scaleBits(s:Int):Int
		return s == 8 ? 3 : s == 4 ? 2 : s == 2 ? 1 : 0;

	public function reloc(kind:RelKind, s:Symbol, addend:Int) {
		if (sec == null) throw "hxmc: relocation without a section";
		sec.relocs.push(new Reloc(b.len, kind, s, addend));
	}

	inline function imm(size:Int, v:Int) {
		if (size == 1) b.u8(v) else if (size == 2) b.u16(v) else imm32(v);
	}

	function imm32(v:Int) {
		if (isym != null) {
			reloc(RAbs32S, isym, v);
			isym = null;
			b.u32(0);
		} else b.u32(v);
	}

	// ---- integer instructions

	// op r/m, r (size 1, 4, 8)
	public function aluRR(o:Int, size:Int, dst:Int, src:Int)
		op(0, size == 8, size == 1 ? o * 8 : o * 8 + 1, 1, src, dst, null, size == 1 ? 3 : 0);

	public function aluMR(o:Int, size:Int, m:Mem, src:Int)
		op(size == 2 ? 0x66 : 0, size == 8, size == 1 ? o * 8 : o * 8 + 1, 1, src, 0, m, size == 1 ? 3 : 0);

	public function aluRM(o:Int, size:Int, dst:Int, m:Mem)
		op(size == 2 ? 0x66 : 0, size == 8, size == 1 ? o * 8 + 2 : o * 8 + 3, 1, dst, 0, m, size == 1 ? 3 : 0);

	public function aluRI(o:Int, size:Int, dst:Int, v:Int) {
		var short = isym == null && v >= -128 && v <= 127;
		if (dst == RAX && (size == 1 || !short)) {
			// the accumulator forms (04, 05, 0c, 0d, ...): one byte shorter
			if (size == 8) b.u8(0x48);
			b.u8(o * 8 + (size == 1 ? 4 : 5));
			if (size == 1) b.u8(v) else imm32(v);
			return;
		}
		if (size == 1) {
			op(0, false, 0x80, 1, o, dst, null, 3);
			b.u8(v);
		} else if (short) {
			op(0, size == 8, 0x83, 1, o, dst, null);
			b.u8(v);
		} else {
			op(0, size == 8, 0x81, 1, o, dst, null);
			imm32(v);
		}
	}

	public function aluMI(o:Int, size:Int, m:Mem, v:Int) {
		if (size == 1) {
			op(0, false, 0x80, 1, o, 0, m, 0, 1);
			b.u8(v);
		} else if (isym == null && v >= -128 && v <= 127) {
			op(size == 2 ? 0x66 : 0, size == 8, 0x83, 1, o, 0, m, 0, 1);
			b.u8(v);
		} else {
			op(size == 2 ? 0x66 : 0, size == 8, 0x81, 1, o, 0, m, 0, size == 2 ? 2 : 4);
			imm(size == 2 ? 2 : 4, v);
		}
	}

	public function testRR(size:Int, a:Int, c:Int)
		op(0, size == 8, size == 1 ? 0x84 : 0x85, 1, c, a, null, size == 1 ? 3 : 0);

	public function testRI(size:Int, r:Int, v:Int) {
		if (r == RAX) {
			if (size == 8) b.u8(0x48);
			b.u8(size == 1 ? 0xa8 : 0xa9);
			if (size == 1) b.u8(v) else b.u32(v);
			return;
		}
		if (size == 1) {
			op(0, false, 0xf6, 1, 0, r, null, 3);
			b.u8(v);
		} else {
			op(0, size == 8, 0xf7, 1, 0, r, null);
			b.u32(v);
		}
	}

	public function testMI(size:Int, m:Mem, v:Int) {
		if (size == 1) {
			op(0, false, 0xf6, 1, 0, 0, m, 0, 1);
			b.u8(v);
		} else {
			op(0, size == 8, 0xf7, 1, 0, 0, m, 0, 4);
			b.u32(v);
		}
	}

	public function movRR(size:Int, dst:Int, src:Int) {
		if (dst == src && size == 8) return;
		op(0, size == 8, 0x89, 1, src, dst, null);
	}

	// loads: sizes 4, 8 (movzx/movsx for 1 and 2)
	public function load(size:Int, dst:Int, m:Mem)
		op(0, size == 8, 0x8b, 1, dst, 0, m);

	public function store(size:Int, m:Mem, src:Int) {
		switch size {
			case 1: op(0, false, 0x88, 1, src, 0, m, 3);
			case 2: op(0x66, false, 0x89, 1, src, 0, m);
			case _: op(0, size == 8, 0x89, 1, src, 0, m);
		}
	}

	public function storeI(size:Int, m:Mem, v:Int) {
		switch size {
			case 1:
				op(0, false, 0xc6, 1, 0, 0, m, 0, 1);
				b.u8(v);
			case 2:
				op(0x66, false, 0xc7, 1, 0, 0, m, 0, 2);
				b.u16(v);
			case _:
				op(0, size == 8, 0xc7, 1, 0, 0, m, 0, 4);
				imm32(v);
		}
	}

	public function movzx8(dst:Int, m:Mem)
		op(0, false, 0x0fb6, 2, dst, 0, m);

	public function movzx16(dst:Int, m:Mem)
		op(0, false, 0x0fb7, 2, dst, 0, m);

	public function movzx8R(dst:Int, src:Int)
		op(0, false, 0x0fb6, 2, dst, src, null, 2);

	public function movzx16R(dst:Int, src:Int)
		op(0, false, 0x0fb7, 2, dst, src, null);

	public function movsx8(size:Int, dst:Int, m:Mem)
		op(0, size == 8, 0x0fbe, 2, dst, 0, m);

	public function movsx16(size:Int, dst:Int, m:Mem)
		op(0, size == 8, 0x0fbf, 2, dst, 0, m);

	// movsxd r64, r/m32
	public function movsxdR(dst:Int, src:Int)
		op(0, true, 0x63, 1, dst, src, null);

	public function movsxd(dst:Int, m:Mem)
		op(0, true, 0x63, 1, dst, 0, m);

	// r = imm: 32-bit (zero-extended), sign-extended 32 into 64, or full 64
	// mov r32, imm32 (zero-extended; never xor, so the flags survive)
	public function movImm32(dst:Int, v:Int) {
		if ((dst & 8) != 0) b.u8(0x41);
		b.u8(0xb8 + (dst & 7));
		imm32(v);
	}

	public function movRI(size:Int, dst:Int, v:Int) {
		if (v == 0) {
			aluRR(XOR, 4, dst, dst);
			return;
		}
		if (size == 4 || v > 0) {
			if ((dst & 8) != 0) b.u8(0x41);
			b.u8(0xb8 + (dst & 7));
			b.u32(v);
		} else {
			op(0, true, 0xc7, 1, 0, dst, null);
			b.u32(v);
		}
	}

	public function movRI64(dst:Int, lo:Int, hi:Int) {
		if (hi == 0 && lo >= 0 || hi == 0 && lo < 0) {
			// zero-extended 32 bits
			if (lo == 0) {
				aluRR(XOR, 4, dst, dst);
				return;
			}
			if ((dst & 8) != 0) b.u8(0x41);
			b.u8(0xb8 + (dst & 7));
			b.u32(lo);
			return;
		}
		if (hi == -1 && lo < 0) {
			op(0, true, 0xc7, 1, 0, dst, null);
			b.u32(lo);
			return;
		}
		b.u8(0x48 | ((dst & 8) != 0 ? 1 : 0));
		b.u8(0xb8 + (dst & 7));
		b.u32(lo);
		b.u32(hi);
	}

	// mov r64, imm64 with an absolute symbol address
	public function movRSym(dst:Int, s:Symbol, addend = 0) {
		b.u8(0x48 | ((dst & 8) != 0 ? 1 : 0));
		b.u8(0xb8 + (dst & 7));
		reloc(RAbs64, s, addend);
		b.u64(0, 0);
	}

	public function lea(size:Int, dst:Int, m:Mem)
		op(0, size == 8, 0x8d, 1, dst, 0, m);

	public function imulRR(size:Int, dst:Int, src:Int)
		op(0, size == 8, 0x0faf, 2, dst, src, null);

	public function imulRM(size:Int, dst:Int, m:Mem)
		op(0, size == 8, 0x0faf, 2, dst, 0, m);

	public function imulRRI(size:Int, dst:Int, src:Int, v:Int) {
		if (v >= -128 && v <= 127) {
			op(0, size == 8, 0x6b, 1, dst, src, null);
			b.u8(v);
		} else {
			op(0, size == 8, 0x69, 1, dst, src, null);
			b.u32(v);
		}
	}

	// F7 group: 2 not, 3 neg, 4 mul, 5 imul, 6 div, 7 idiv
	public function unary(digit:Int, size:Int, r:Int)
		op(0, size == 8, 0xf7, 1, digit, r, null);

	public function neg(size:Int, r:Int)
		unary(3, size, r);

	public function not(size:Int, r:Int)
		unary(2, size, r);

	public function idiv(size:Int, r:Int)
		unary(7, size, r);

	// cdq / cqo
	public function signExtendAx(size:Int) {
		if (size == 8) b.u8(0x48);
		b.u8(0x99);
	}

	public function shiftCl(o:Int, size:Int, r:Int)
		op(0, size == 8, 0xd3, 1, o, r, null);

	public function shiftI(o:Int, size:Int, r:Int, n:Int) {
		if (n == 1) {
			op(0, size == 8, 0xd1, 1, o, r, null);
		} else {
			op(0, size == 8, 0xc1, 1, o, r, null);
			b.u8(n);
		}
	}

	public function setcc(c:CC, r:Int)
		op(0, false, 0x0f90 + (c : Int), 2, 0, r, null, 2);

	public function cmovRR(c:CC, size:Int, dst:Int, src:Int)
		op(0, size == 8, 0x0f40 + (c : Int), 2, dst, src, null);

	public function push(r:Int) {
		if ((r & 8) != 0) b.u8(0x41);
		b.u8(0x50 + (r & 7));
	}

	public function pop(r:Int) {
		if ((r & 8) != 0) b.u8(0x41);
		b.u8(0x58 + (r & 7));
	}

	public function ret()
		b.u8(0xc3);

	public function ud2() {
		b.u8(0x0f);
		b.u8(0x0b);
	}

	public function int3()
		b.u8(0xcc);

	public function callSym(s:Symbol) {
		b.u8(0xe8);
		reloc(RCall32, s, -4);
		b.u32(0);
	}

	public function jmpSym(s:Symbol) {
		b.u8(0xe9);
		reloc(RCall32, s, -4);
		b.u32(0);
	}

	public function callR(r:Int)
		op(0, false, 0xff, 1, 2, r, null);

	public function callM(m:Mem)
		op(0, false, 0xff, 1, 2, 0, m);

	public function jmpR(r:Int)
		op(0, false, 0xff, 1, 4, r, null);

	public function jmpM(m:Mem)
		op(0, false, 0xff, 1, 4, 0, m);

	// lea r, [rip + label]: the displacement is patched by patchLabelRefs (after finish)
	public var labelRefs:Array<{at:Int, label:Int}> = [];

	public function leaLabel(dst:Int, l:Int) {
		ripPlaceholder = true;
		op(0, true, 0x8d, 1, dst, 0, new Mem(-1, 0));
		ripPlaceholder = false;
		b.len -= 4;
		labelRefs.push({at: b.len, label: l});
		b.u32(0);
	}

	public function patchLabelRefs() {
		for (r in labelRefs)
			b.set32(r.at, labels[r.label] - (r.at + 4));
		labelRefs = [];
	}

	public function jmp(l:Int) {
		b.u8(0xe9);
		fixups.push(new Fixup(b.len, l, -1));
		b.u32(0);
	}

	public function jcc(c:CC, l:Int) {
		b.u8(0x0f);
		b.u8(0x80 + (c : Int));
		fixups.push(new Fixup(b.len, l, c));
		b.u32(0);
	}

	// ---- SSE2 (doubles); xmm registers are 16-31

	function sse(prefix:Int, w:Bool, opcode:Int, reg:Int, rm:Int, m:Null<Mem>)
		op(prefix, w, opcode, 2, reg & 15, rm & 15, m);

	// movups m128, xmm / xmm, m128 (saving callee-saved xmm registers whole)
	public function movupsMR(m:Mem, src:Int)
		sse(0, false, 0x0f11, src, 0, m);

	public function movupsRM(dst:Int, m:Mem)
		sse(0, false, 0x0f10, dst, 0, m);

	public function movsdRR(dst:Int, src:Int) {
		if (dst != src) sse(0x66, false, 0x0f28, dst, src, null); // movapd
	}

	public function movsdRM(dst:Int, m:Mem)
		sse(0xf2, false, 0x0f10, dst, 0, m);

	public function movsdMR(m:Mem, src:Int)
		sse(0xf2, false, 0x0f11, src, 0, m);

	// 0x58 add, 0x59 mul, 0x5c sub, 0x5e div, 0x51 sqrt, 0x5d min, 0x5f max
	public function sdRR(o:Int, dst:Int, src:Int)
		sse(0xf2, false, 0x0f00 | o, dst, src, null);

	public function sdRM(o:Int, dst:Int, m:Mem)
		sse(0xf2, false, 0x0f00 | o, dst, 0, m);

	public function ucomisdRR(a:Int, c:Int)
		sse(0x66, false, 0x0f2e, a, c, null);

	public function ucomisdRM(a:Int, m:Mem)
		sse(0x66, false, 0x0f2e, a, 0, m);

	// 66-prefixed packed-double operation with a memory operand (0x57 xorpd, 0x54 andpd)
	public function pdRM(o:Int, dst:Int, m:Mem)
		sse(0x66, false, 0x0f00 | o, dst, 0, m);

	public function xorpd(dst:Int, src:Int)
		sse(0x66, false, 0x0f57, dst, src, null);

	public function andpd(dst:Int, src:Int)
		sse(0x66, false, 0x0f54, dst, src, null);

	// cvtsi2sd xmm, r32/r64
	public function cvtsi2sd(size:Int, dst:Int, src:Int)
		op(0xf2, size == 8, 0x0f2a, 2, dst & 15, src, null);

	// cvttsd2si r32/r64, xmm
	public function cvttsd2si(size:Int, dst:Int, src:Int)
		op(0xf2, size == 8, 0x0f2c, 2, dst, src & 15, null);

	// movq xmm, r64 / movq r64, xmm
	public function movqXR(dst:Int, src:Int)
		op(0x66, true, 0x0f6e, 2, dst & 15, src, null);

	public function movqRX(dst:Int, src:Int)
		op(0x66, true, 0x0f7e, 2, src & 15, dst, null);

	// movd xmm, r32 / movd r32, xmm (float32 bits)
	public function movdXR(dst:Int, src:Int)
		op(0x66, false, 0x0f6e, 2, dst & 15, src, null);

	public function movdRX(dst:Int, src:Int)
		op(0x66, false, 0x0f7e, 2, src & 15, dst, null);

	// cvtss2sd xmm, xmm / cvtsd2ss xmm, xmm
	public function cvtss2sd(dst:Int, src:Int)
		sse(0xf3, false, 0x0f5a, dst, src, null);

	public function cvtsd2ss(dst:Int, src:Int)
		sse(0xf2, false, 0x0f5a, dst, src, null);

	// ---- atomics (hxmc.unsafe.Atomic): xchg m, r (locked by itself);
	// lock xadd m, r; lock cmpxchg m, r (rax: expected, then the old value); mfence
	public function xchgMR(size:Int, m:Mem, r:Int)
		op(0, size == 8, 0x87, 1, r, 0, m);

	public function lockXaddMR(size:Int, m:Mem, r:Int)
		op(0xf0, size == 8, 0x0fc1, 2, r, 0, m);

	public function lockCmpxchgMR(size:Int, m:Mem, r:Int)
		op(0xf0, size == 8, 0x0fb1, 2, r, 0, m);

	public function mfence() {
		b.u8(0x0f);
		b.u8(0xae);
		b.u8(0xf0);
	}

	// roundsd xmm, xmm, mode (SSE4.1): 1 floor, 2 ceil, 3 truncate
	public function roundsd(dst:Int, src:Int, mode:Int) {
		op(0x66, false, 0x0f3a0b, 3, dst & 15, src & 15, null);
		b.u8(mode);
	}

	// ---- finishing

	// Resolves the branches; shortens rel32 jumps to rel8 where possible
	// (iterating until no more fit), then patches. `code` positions of other
	// recorded offsets (relocations of the section, label positions) are
	// moved accordingly. Returns the map old offset -> new offset (a function).
	public function finish(start:Int):Int->Int {
		if (fixups.length == 0) return x -> x;
		// (this function's: the map keeps them)
		var fixups = this.fixups;
		fixups.sort((x, y) -> x.at - y.at);
		// shrink: a fixup is short when its displacement fits; removing bytes only shortens distances
		var short = new haxe.ds.Vector<Bool>(fixups.length);
		var changed = true;
		var removedPrefix = new haxe.ds.Vector<Int>(fixups.length);
		function computePrefix() {
			var n = 0;
			for (i in 0...fixups.length) {
				removedPrefix[i] = n;
				if (short[i]) n += fixups[i].cond < 0 ? 3 : 4;
			}
		}
		// removed bytes strictly before position p (fixups are sorted by position)
		function removed(p:Int):Int {
			var lo = 0, hi = fixups.length;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (fixups[mid].at < p) lo = mid + 1 else hi = mid;
			}
			if (lo == 0) return 0;
			var i = lo - 1;
			return removedPrefix[i] + (short[i] ? (fixups[i].cond < 0 ? 3 : 4) : 0);
		}
		while (changed) {
			changed = false;
			computePrefix();
			for (i in 0...fixups.length) {
				if (short[i]) continue;
				var f = fixups[i];
				var target = labels[f.label];
				if (target < 0) throw "hxmc: unbound label";
				var end = f.at + 4;
				var newEnd = end - removed(end) - (f.cond < 0 ? 3 : 4);
				var newTarget = target - removed(target);
				var d = newTarget - newEnd;
				if (d >= -128 && d <= 127) {
					short[i] = true;
					changed = true;
				}
			}
		}
		computePrefix();
		// rebuild the code from `start`
		var old = b.b.sub(start, b.len - start);
		var oldLen = b.len;
		b.len = start;
		var src = start;
		for (i in 0...fixups.length) {
			var f = fixups[i];
			var opStart = f.at - (f.cond < 0 ? 1 : 2);
			b.bytes(old, src - start, opStart - src);
			var target = labels[f.label];
			var newTarget = target - removed(target);
			if (short[i]) {
				var newEnd = b.len + 2;
				b.u8(f.cond < 0 ? 0xeb : 0x70 + f.cond);
				b.u8((newTarget - newEnd) & 0xff);
			} else {
				var newEnd = b.len + (f.cond < 0 ? 5 : 6);
				if (f.cond < 0) b.u8(0xe9) else {
					b.u8(0x0f);
					b.u8(0x80 + f.cond);
				}
				b.u32(newTarget - newEnd);
			}
			src = f.at + 4;
		}
		b.bytes(old, src - start, oldLen - src);
		var map = (p:Int) -> p < start ? p : p - removed(p);
		for (i in 0...labels.length)
			if (labels[i] >= 0) labels[i] = map(labels[i]);
		if (sec != null) {
			// the relocations of this function are the last ones
			var k = sec.relocs.length;
			while (k-- > 0 && sec.relocs[k].offset >= start)
				sec.relocs[k].offset = map(sec.relocs[k].offset);
		}
		for (r in labelRefs)
			r.at = map(r.at);
		this.fixups = [];
		return map;
	}
}

class Fixup {
	public var at:Int; // position of the rel32
	public var label:Int;
	public var cond:Int; // -1: jmp

	public function new(at, label, cond) {
		this.at = at;
		this.label = label;
		this.cond = cond;
	}
}
