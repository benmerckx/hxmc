package hxmc;

import hxmc.Obj;

// Unwind information from what the emitters write (x64.Emit, a64.Emit:
// their prologues and epilogues record each change of the frame as an
// operation, FuncRec.ops), in each format: DWARF call frame information
// (.eh_frame and .eh_frame_hdr on ELF, __eh_frame on Mach-O: debuggers,
// perf --call-graph dwarf, C++-style unwinders), Windows x64 UNWIND_INFO
// and arm64 .xdata (.pdata: debuggers, crash dumps, RtlVirtualUnwind and
// SEH through generated frames).
//
// Operations (four numbers: kind, the offset where the frame is as the
// operation leaves it, two operands; registers in the emitter's numbering:
// x86-64 0-15 general, 16+ xmm; arm64 0-31 general, 32+ v):
//   PUSH r          x86-64 push r
//   SETFP           the frame pointer (rbp, x29) = sp
//   ALLOC n         sp -= n
//   SAVE r, off     r stored at [sp + off]
//   SAVEFPLR n      arm64 stp x29, x30, [sp, #-n]!
//   NOP             arm64: a prologue instruction that changes no state (a stack probe)
//   ENDPROLOGUE     the body starts
//   ENTRY           an entry point (_start): no caller to unwind to
//   EPILOGUE        an epilogue starts (its first instruction)
//   FREE n          sp += n
//   POP r           x86-64 pop r
//   RESTORE r, off  arm64 ldr r, [sp + off]
//   SPFP            sp = the frame pointer
//   RESTOREFPLR n   arm64 ldp x29, x30, [sp], #n
//   RET             the epilogue's return (the code after it has the body's frame)
// Within a function the frame is the same at every instruction of the body
// (outgoing arguments are part of the frame: no pushes around calls); the
// stack switch of hxmc_call_on_stack runs on the frame pointer.
class Unwind {
	public static inline var PUSH = 0;
	public static inline var SETFP = 1;
	public static inline var ALLOC = 2;
	public static inline var SAVE = 3;
	public static inline var SAVEFPLR = 4;
	public static inline var NOP = 5;
	public static inline var ENDPROLOGUE = 6;
	public static inline var ENTRY = 7;
	public static inline var EPILOGUE = 8;
	public static inline var FREE = 9;
	public static inline var POP = 10;
	public static inline var RESTORE = 11;
	public static inline var SPFP = 12;
	public static inline var RESTOREFPLR = 13;
	public static inline var RET = 14;

	// ---- DWARF call frame information

	// the DWARF numbers of x86-64 registers 0-7 by the emitter's number (rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi)
	static final X64_DWARF:haxe.ds.Vector<Int> = core.ds.VectorTools.vector(0, 2, 1, 3, 7, 6, 4, 5);

	// the DWARF number of an emitter's register
	static function dwarfReg(r:Int, arm:Bool):Int {
		if (arm) return r < 32 ? r : 64 + (r - 32);
		if (r >= 16) return 17 + (r - 16);
		return X64_DWARF[r & 7] + (r & 8);
	}

	// the CIE every FDE shares: x86-64 CFA = rsp + 8, the return address at
	// CFA - 8; arm64 CFA = sp, the return address in x30. FDEs give their
	// addresses pc-relative in 4 bytes (augmentation "zR", DW_EH_PE_pcrel | sdata4).
	static function cie(b:Buf, arm:Bool) {
		var at = b.len;
		b.u32(0);
		b.u32(0); // CIE id
		b.u8(1); // version
		b.str("zR");
		b.u8(0);
		b.uleb(arm ? 4 : 1); // code alignment
		b.sleb(-8); // data alignment
		b.u8(arm ? 30 : 16); // return address register
		b.uleb(1);
		b.u8(0x1b);
		if (arm) {
			b.u8(0x0c); // DW_CFA_def_cfa sp, 0
			b.uleb(31);
			b.uleb(0);
		} else {
			b.u8(0x0c); // DW_CFA_def_cfa rsp, 8
			b.uleb(7);
			b.uleb(8);
			b.u8(0x80 | 16); // DW_CFA_offset rip, CFA - 8
			b.uleb(1);
		}
		b.align(4, 0);
		b.set32(at, b.len - at - 4);
	}

	// the CFA instructions of a function of `size` bytes from its operations
	public static function cfi(ops:haxe.ds.Vector<Int>, size:Int, arm:Bool, b:Buf) {
		var codeAlign = arm ? 4 : 1;
		var sp = arm ? 31 : 7, fp = arm ? 29 : 6;
		var loc = 0;
		function advance(to:Int) {
			var d = Std.int((to - loc) / codeAlign);
			if (d <= 0) return;
			if (d < 64) b.u8(0x40 | d) else if (d < 256) {
				b.u8(0x02);
				b.u8(d);
			} else if (d < 65536) {
				b.u8(0x03);
				b.u16(d);
			} else {
				b.u8(0x04);
				b.u32(d);
			}
			loc = to;
		}
		function offset(r:Int, cfaOff:Int) {
			if (r < 64) b.u8(0x80 | r) else {
				b.u8(0x05);
				b.uleb(r);
			}
			b.uleb(cfaOff >> 3);
		}
		function restore(r:Int) {
			if (r < 64) b.u8(0xc0 | r) else {
				b.u8(0x06);
				b.uleb(r);
			}
		}
		function defCfa(r:Int, off:Int) {
			b.u8(0x0c);
			b.uleb(r);
			b.uleb(off);
		}
		function defCfaOffset(off:Int) {
			b.u8(0x0e);
			b.uleb(off);
		}
		// the frame: CFA - sp, and CFA - fp once it is set; the CFA's register
		var spOff = arm ? 0 : 8, fpOff = 0, cfaFp = false;
		// saved registers (DWARF number, CFA - where) whose rules are written
		// once one of them may change: at the frame pointer's setting or at
		// the end of the prologue (until then they hold their values)
		var pending:Array<Int> = [];
		function flush() {
			var k = 0;
			while (k < pending.length) {
				offset(pending[k], pending[k + 1]);
				k += 2;
			}
			pending = [];
		}
		var body = {spOff: 0, fpOff: 0, cfaFp: false};
		var k = 0;
		while (k < ops.length) {
			var kind = ops[k], at = ops[k + 1], a = ops[k + 2], o = ops[k + 3];
			k += 4;
			switch kind {
				case PUSH:
					spOff += 8;
					pending.push(dwarfReg(a, arm));
					pending.push(spOff);
					if (!cfaFp) {
						advance(at);
						defCfaOffset(spOff);
					}
				case SETFP:
					fpOff = spOff;
					advance(at);
					b.u8(0x0d); // DW_CFA_def_cfa_register
					b.uleb(fp);
					cfaFp = true;
					flush();
				case ALLOC:
					spOff += a;
					if (!cfaFp) {
						advance(at);
						defCfaOffset(spOff);
					}
				case SAVE:
					pending.push(dwarfReg(a, arm));
					pending.push(spOff - o);
				case SAVEFPLR:
					spOff += a;
					pending.push(29);
					pending.push(spOff);
					pending.push(30);
					pending.push(spOff - 8);
					if (!cfaFp) {
						advance(at);
						defCfaOffset(spOff);
					}
				case NOP:
				case ENDPROLOGUE:
					if (pending.length > 0) {
						advance(at);
						flush();
					}
					body = {spOff: spOff, fpOff: fpOff, cfaFp: cfaFp};
				case ENTRY:
					// DW_CFA_undefined of the return address: the outermost frame
					b.u8(0x07);
					b.uleb(arm ? 30 : 16);
				case EPILOGUE:
					// (the body's frame is remembered when code follows the epilogue)
					var j = k;
					while (j < ops.length && ops[j] != RET)
						j += 4;
					if (j < ops.length && ops[j + 1] < size) {
						advance(at);
						b.u8(0x0a); // DW_CFA_remember_state
					}
				case FREE:
					spOff -= a;
					if (!cfaFp) {
						advance(at);
						defCfaOffset(spOff);
					}
				case POP:
					spOff -= 8;
					if (cfaFp && a == 5) {
						// pop rbp: the CFA is on the stack pointer again
						advance(at);
						defCfa(sp, spOff);
						cfaFp = false;
					} else if (!cfaFp) {
						advance(at);
						defCfaOffset(spOff);
					}
				case RESTORE:
				case SPFP:
					spOff = fpOff;
				case RESTOREFPLR:
					spOff -= a;
					advance(at);
					if (cfaFp) defCfa(sp, spOff) else defCfaOffset(spOff);
					cfaFp = false;
					restore(29);
					restore(30);
				case RET:
					// (the rest of the function has the body's frame)
					if (at < size) {
						advance(at);
						b.u8(0x0b); // DW_CFA_restore_state
					}
					spOff = body.spOff;
					fpOff = body.fpOff;
					cfaFp = body.cfaFp;
				case _:
					throw "hxmc: unwind operation " + kind;
			}
		}
	}

	// .eh_frame of these functions (one CIE, an FDE each, a terminator),
	// whose FDEs give the functions' addresses through RPc32 relocations;
	// fdes: the offset of each FDE (for .eh_frame_hdr)
	public static function ehFrame(recs:Array<FuncRec>, arm:Bool, name:String):{sec:Section, fdes:haxe.ds.Vector<Int>} {
		var s = new Section(name, RoData, 8);
		var b = s.buf;
		cie(b, arm);
		var fdes = new haxe.ds.Vector<Int>(recs.length);
		var insns = new Buf(256);
		for (k in 0...recs.length) {
			var r = recs[k];
			var at = b.len;
			fdes[k] = at;
			b.u32(0);
			b.u32(at + 4); // the distance back to the CIE (at 0)
			s.relocs.push(new Reloc(b.len, RPc32, r.sym, 0));
			b.u32(0);
			b.u32(r.sym.size);
			b.uleb(0); // augmentation data
			insns.len = 0;
			cfi(r.ops, r.sym.size, arm, insns);
			b.buf(insns);
			b.align(4, 0);
			b.set32(at, b.len - at - 4);
		}
		b.u32(0);
		return {sec: s, fdes: fdes};
	}

	// .eh_frame_hdr (the binary search table the C library's unwinder looks
	// functions up in: PT_GNU_EH_FRAME) at hdrAddr for .eh_frame at
	// frameAddr: fdes are (function address, FDE address) pairs
	public static function ehFrameHdr(hdrAddr:Int, frameAddr:Int, fdes:Array<{pc:Int, fde:Int}>, b:Buf) {
		fdes.sort((x, y) -> x.pc - y.pc);
		b.u8(1); // version
		b.u8(0x1b); // eh_frame_ptr: pcrel sdata4
		b.u8(0x03); // fde_count: udata4
		b.u8(0x3b); // table: datarel sdata4
		b.u32(frameAddr - (hdrAddr + 4));
		b.u32(fdes.length);
		for (f in fdes) {
			b.u32(f.pc - hdrAddr);
			b.u32(f.fde - hdrAddr);
		}
	}

	public static inline function ehFrameHdrSize(n:Int):Int
		return 12 + 8 * n;

	// ---- Windows

	// the UNWIND_INFO of an x86-64 function (null: a leaf function that
	// leaves the stack pointer alone, which needs none). Epilogues are not
	// described: the unwinder recognizes them (add rsp; pops; ret).
	public static function winX64(ops:haxe.ds.Vector<Int>):Null<Buf> {
		var codes:Array<Array<Int>> = []; // slots of each code, in prologue order
		var fpreg = 0, prolog = 0;
		var k = 0;
		while (k < ops.length) {
			var kind = ops[k], at = ops[k + 1], a = ops[k + 2], o = ops[k + 3];
			k += 4;
			// (a prologue longer than the format's 255 bytes: a huge frame
			// probed page by page; its offsets are clamped)
			if (at > 255) at = 255;
			switch kind {
				case PUSH:
					codes.push([at | (0 << 8) | (a << 12)]);
				case SETFP:
					fpreg = 5;
					codes.push([at | (3 << 8)]);
				case ALLOC:
					if (a <= 128) codes.push([at | (2 << 8) | (((a >> 3) - 1) << 12)]) else if (a < 0x80000) codes.push([at | (1 << 8), a >> 3]) else
						codes.push([at | (1 << 8) | (1 << 12), a & 0xffff, a >>> 16]);
				case SAVE:
					if (a < 16) throw "hxmc: unwind: a general register saved by a store";
					if (o < 0x100000) codes.push([at | (8 << 8) | ((a - 16) << 12), o >> 4]) else
						codes.push([at | (9 << 8) | ((a - 16) << 12), o & 0xffff, o >>> 16]);
				case ENDPROLOGUE:
					prolog = at;
				case _:
			}
		}
		if (codes.length == 0) return null;
		var b = new Buf(16);
		var n = 0;
		for (c in codes)
			n += c.length;
		b.u8(1); // version 1, no handler
		b.u8(prolog);
		b.u8(n);
		b.u8(fpreg); // frame register, offset 0
		var i = codes.length;
		while (i-- > 0)
			for (w in codes[i])
				b.u16(w);
		if (n & 1 != 0) b.u16(0);
		return b;
	}

	// the .xdata of an arm64 function (null: a leaf function without a
	// frame): the prologue's unwind codes in reverse, then the epilogue's
	// (the same for every epilogue of a function) in order
	public static function winA64(ops:haxe.ds.Vector<Int>, size:Int):Null<Buf> {
		var pro = new Buf(32), epi = new Buf(32);
		var proCodes:Array<Buf> = [];
		var epilogues:Array<Int> = [];
		var inEpi = false, epiDone = false;
		function code(kind:Int, a:Int, o:Int):Buf {
			var c = new Buf(4);
			switch kind {
				case SAVEFPLR | RESTOREFPLR:
					c.u8(0x80 | ((a >> 3) - 1)); // save_fplr_x
				case SETFP | SPFP:
					c.u8(0xe1); // set_fp
				case ALLOC | FREE:
					if (a < 512) c.u8(a >> 4) else if (a < 32768) {
						c.u8(0xc0 | (a >> 12));
						c.u8((a >> 4) & 0xff);
					} else {
						c.u8(0xe0);
						c.u8((a >> 20) & 0xff);
						c.u8((a >> 12) & 0xff);
						c.u8((a >> 4) & 0xff);
					}
				case SAVE | RESTORE:
					if (o > 504 || o & 7 != 0) throw "hxmc: unwind: a register saved out of save_reg's reach";
					if (a >= 32) {
						var x = a - 32 - 8;
						c.u8(0xdc | (x >> 2)); // save_freg
						c.u8(((x & 3) << 6) | (o >> 3));
					} else {
						var x = a - 19;
						c.u8(0xd0 | (x >> 2)); // save_reg
						c.u8(((x & 3) << 6) | (o >> 3));
					}
				case NOP:
					c.u8(0xe3);
				case _:
			}
			return c;
		}
		var k = 0;
		while (k < ops.length) {
			var kind = ops[k], at = ops[k + 1], a = ops[k + 2], o = ops[k + 3];
			k += 4;
			switch kind {
				case EPILOGUE:
					epilogues.push(at);
					inEpi = true;
				case RET:
					if (inEpi && !epiDone) epi.u8(0xe4);
					inEpi = false;
					epiDone = true;
				case ENDPROLOGUE | ENTRY | PUSH | POP:
				case _:
					if (inEpi) {
						if (!epiDone) epi.buf(code(kind, a, o));
					} else proCodes.push(code(kind, a, o));
			}
		}
		if (proCodes.length == 0) return null;
		var i = proCodes.length;
		while (i-- > 0)
			pro.buf(proCodes[i]);
		pro.u8(0xe4); // end
		var epiStart = pro.len;
		pro.buf(epi);
		pro.align(4, 0xe4);
		var words = pro.len >> 2;
		var b = new Buf(16 + 4 * epilogues.length + pro.len);
		if (size >= 1 << 20) throw "hxmc: unwind: an arm64 function of 1 MB or more";
		if (epilogues.length < 32 && words < 32) b.u32((size >> 2) | (epilogues.length << 22) | (words << 27)) else {
			b.u32(size >> 2);
			b.u32(epilogues.length | (words << 16));
		}
		for (e in epilogues)
			b.u32((e >> 2) | (epiStart << 22));
		b.buf(pro);
		return b;
	}
}
