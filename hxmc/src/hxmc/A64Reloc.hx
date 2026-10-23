package hxmc;

import hxmc.Obj;

// The AArch64 instruction fields the linkers patch (LinkCore.applyRelocs):
// `v` is the value the relocation computes (S + A, a GOT slot's address, or a
// TLS offset), `p` the address of the instruction.
class A64Reloc {
	public static function imm12(buf:Buf, at:Int, v:Int)
		buf.set32(at, (buf.get32(at) & ~(0xfff << 10)) | ((v & 0xfff) << 10));

	public static function adrp(buf:Buf, at:Int, target:Int, p:Int) {
		var imm = ((target & ~0xfff) - (p & ~0xfff)) >> 12;
		var w = buf.get32(at) & ~((3 << 29) | (0x7ffff << 5));
		buf.set32(at, w | ((imm & 3) << 29) | (((imm >> 2) & 0x7ffff) << 5));
	}

	// the access size (log2) of a load or store with an unsigned offset
	public static function ldstScale(insn:Int):Int {
		var size = insn >>> 30;
		if ((insn & 0x04800000) == 0x04800000) size += 4; // 128-bit SIMD
		return size;
	}

	// patches the field of a relocation of an arm64 kind; false: not one
	public static function apply(buf:Buf, at:Int, kind:RelKind, v:Int, p:Int, name:String):Bool {
		switch kind {
			case RA64AdrPage21 | RA64GotPage21:
				adrp(buf, at, v, p);
			case RA64GotLo12:
				imm12(buf, at, (v & 0xfff) >> 3);
			case RA64AddLo12 | RA64Ldst8Lo12:
				imm12(buf, at, v & 0xfff);
			case RA64Ldst16Lo12:
				imm12(buf, at, (v & 0xfff) >> 1);
			case RA64Ldst32Lo12:
				imm12(buf, at, (v & 0xfff) >> 2);
			case RA64Ldst64Lo12:
				imm12(buf, at, (v & 0xfff) >> 3);
			case RA64Ldst128Lo12:
				imm12(buf, at, (v & 0xfff) >> 4);
			case RA64Call26 | RA64Jump26:
				var d = v - p;
				if (d >= (1 << 27) || d < -(1 << 27)) throw "hxmc: link: branch out of range to " + name;
				buf.set32(at, (buf.get32(at) & 0xfc000000) | ((d >> 2) & 0x3ffffff));
			case RA64Cond19:
				var d = v - p;
				if (d >= (1 << 20) || d < -(1 << 20)) throw "hxmc: link: conditional branch out of range to " + name;
				buf.set32(at, (buf.get32(at) & ~(0x7ffff << 5)) | (((d >> 2) & 0x7ffff) << 5));
			case RA64Tst14:
				var d = v - p;
				if (d >= (1 << 15) || d < -(1 << 15)) throw "hxmc: link: test branch out of range to " + name;
				buf.set32(at, (buf.get32(at) & ~(0x3fff << 5)) | (((d >> 2) & 0x3fff) << 5));
			case RA64TlsLeHi12:
				imm12(buf, at, (v >> 12) & 0xfff);
			case RA64TlsLeLo12Nc:
				imm12(buf, at, v & 0xfff);
			case RA64SecRelHi12:
				if (v < 0 || v >= 1 << 24) throw "hxmc: link: thread-local offset out of range for " + name;
				imm12(buf, at, (v >> 12) & 0xfff);
			case RA64SecRelLo12A:
				imm12(buf, at, v & 0xfff);
			case RA64SecRelLo12L:
				var sc = ldstScale(buf.get32(at));
				imm12(buf, at, (v & 0xfff) >> sc);
			case RA64MovwG0Nc:
				buf.set32(at, (buf.get32(at) & ~(0xffff << 5)) | ((v & 0xffff) << 5));
			case RA64MovwG1Nc:
				buf.set32(at, (buf.get32(at) & ~(0xffff << 5)) | (((v >>> 16) & 0xffff) << 5));
			case _:
				return false;
		}
		return true;
	}
}
