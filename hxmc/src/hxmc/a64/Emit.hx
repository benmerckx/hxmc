package hxmc.a64;

import hxmc.Lir;
import hxmc.Mir.SrcPos;
import hxmc.Obj;
import hxmc.a64.Asm;
import hxmc.a64.Isel.AOp;
import haxe.ds.Vector;

// Allocated LIR -> AArch64 machine code: frame (x29/x30 pair, then the
// callee-saved registers, the slots and the outgoing arguments below; on
// Windows the slots above the callee-saved registers),
// prologue and epilogues, jump tables, out-of-range immediates and offsets
// through the scratch registers x16/x17. The prologue and epilogues record
// what they do to the frame (Unwind: the unwind tables; Windows' unwind
// codes reach saved registers up to 504 bytes above sp, which the layout
// keeps), and with -debug the instructions' source lines are recorded
// (FuncRec).
class Emit implements hxmc.Target.Emitter {
	static inline var X16 = 16;
	static inline var X17 = 17;
	static inline var ZR = 31;
	static inline var SP = 31;

	var obj:Obj;
	var text:Section;
	var a:Asm;
	var tlsLocalExec:Bool;

	// Windows commits the stack one guard page at a time: frames of a page or
	// more touch each page as they grow
	var probe:Bool;
	var pac:Bool; // Abi.pac
	var signs = false; // the function being written signs its return address

	public function new(obj:Obj, probe = false, pac = false) {
		this.obj = obj;
		this.probe = probe;
		this.pac = pac;
		text = obj.section(".text", Text, 16);
		a = new Asm(text);
	}

	var slotOff:Vector<Int>;
	var frameSize = 0;
	var saved:Vector<Int>;
	var saveOff:Vector<Int>;
	// Windows, where the outgoing arguments would put the saved registers
	// beyond the unwind codes' reach: their area (allocated last, freed first)
	var split = 0;
	// this function's frame operations (Unwind; offsets in the section until
	// the function is done) and (-debug) its rows of lines
	var ops:Array<Int> = []; // (the function's frame operations, while it is written)
	var lines:Null<Array<Int>>;
	var lastPos = 0;
	var fileIndex = new Map<String, Int>();
	var start = 0;

	// a frame operation (Unwind) whose instruction ends here
	inline function op(kind:Int, x = 0, y = 0) {
		ops.push(kind);
		ops.push(text.buf.len - start);
		ops.push(x);
		ops.push(y);
	}

	public function allocStub(name:String, lo:Int, tySym:Null<String>, tyVal:Int, bytes:Int):Bool
		return false;

	// the runtime's stubs (MirBuild.STUB_*), in the C convention
	public function stub(name:String) {
		text.buf.align(4, 0);
		start = text.buf.len;
		ops.resize(0);
		switch name {
			case hxmc.MirBuild.STUB_CALL_ON_STACK:
				// fn() (x1) with the stack pointer at top (x0); unwinders follow
				// the frame pointer back to the old stack
				a.pair(false, Asm.FP, Asm.LR, SP, -16, 1);
				op(Unwind.SAVEFPLR, 16);
				a.movSp(Asm.FP, SP);
				op(Unwind.SETFP);
				op(Unwind.ENDPROLOGUE);
				a.movSp(SP, 0);
				a.blr(1);
				op(Unwind.EPILOGUE);
				a.movSp(SP, Asm.FP);
				op(Unwind.SPFP);
				a.pair(true, Asm.FP, Asm.LR, SP, 16, 2);
				op(Unwind.RESTOREFPLR, 16);
				a.ret();
				op(Unwind.RET);
			case hxmc.MirBuild.STUB_ZERO:
				// memset(p, 0, bytes)
				a.movR(true, 2, 1);
				a.movz(false, 1, 0, 0);
				a.bSym(obj.sym("memset"));
			case hxmc.MirBuild.STUB_FRAME:
				// the caller's x29 (this stub keeps no record of its own)
				a.movR(true, 0, Asm.FP);
				a.ret();
			case hxmc.MirBuild.STUB_STRIP:
				// x0 without its signature: xpaclri strips x30 only (the return
				// address is in x16 for these three instructions)
				a.movR(true, X16, Asm.LR);
				a.movR(true, Asm.LR, 0);
				a.xpaclri();
				a.movR(true, 0, Asm.LR);
				a.br(X16);
			case hxmc.MirBuild.STUB_LANDING:
				// hxmc_objc_caught(x0) as though the call returning to x1 had
				// called it (where an unwinder resumes a frame)
				op(Unwind.PASS);
				a.movR(true, Asm.LR, 1);
				a.bSym(obj.sym(hxmc.MirBuild.OBJC_CAUGHT));
			case _:
				throw "hxmc: unknown runtime stub " + name;
		}
		obj.funcs.push(new FuncRec(obj.define(name, text, start, text.buf.len - start, true), Vector.fromArrayCopy(ops)));
	}

	public function useSection(name:Null<String>) {
		text = obj.section(name != null ? name : ".text", Text, 16);
		a.sec = text;
		a.b = text.buf;
	}

	public function func(f:LFunc, usedRegs:Vector<Bool>, global:Bool):Symbol {
		text.buf.align(16, 0);
		start = text.buf.len;
		a.reset();
		ops.resize(0);
		if (f.foreignPasses) op(Unwind.PASS);
		lines = f.display != null ? [] : null;
		lastPos = 0;
		var off = f.outArgs;
		var cs = hxmc.CallConv.Aapcs64.CALLEE_SAVED;
		// callee-saved registers by pairs (x19/x20 ... d14/d15, both when
		// either is used) packed below the frame record, as Mach-O's compact
		// unwind encoding describes them (Unwind.compact); on Windows the
		// used ones above the outgoing arguments, in its unwind codes' reach
		var n = 0;
		for (k in 0...cs.length)
			if (usedRegs[cs[k]] || !probe && usedRegs[cs[k ^ 1]]) n++;
		saved = new Vector(n);
		n = 0;
		for (k in 0...cs.length)
			if (usedRegs[cs[k]] || !probe && usedRegs[cs[k ^ 1]]) saved[n++] = cs[k];
		split = 0;
		if (probe && off + 8 * saved.length > 504) {
			off = (off + 15) & ~15;
			split = off;
		}
		saveOff = new Vector(saved.length);
		if (probe)
			for (k in 0...saved.length) {
				saveOff[k] = off - split;
				off += 8;
			}
		slotOff = new Vector(f.slots.length);
		for (k in 0...f.slots.length) {
			var s = f.slots[k];
			var al = s.align < 8 ? 8 : s.align;
			off = (off + al - 1) & ~(al - 1);
			slotOff[k] = off;
			off += s.size;
		}
		frameSize = (off + 15) & ~15;
		if (!probe) {
			frameSize += 8 * saved.length;
			for (k in 0...saved.length)
				saveOff[k] = frameSize - 8 - 8 * k;
		}
		// prologue
		// (Windows, probe: key IB, which its unwind codes name)
		signs = pac && f.exposed;
		if (signs) {
			a.pacsp(probe);
			op(Unwind.PAC);
		}
		a.pair(false, Asm.FP, Asm.LR, SP, -16, 1);
		op(Unwind.SAVEFPLR, 16);
		a.movSp(Asm.FP, SP);
		op(Unwind.SETFP);
		subSp(frameSize - split);
		var k = 0;
		while (k < saved.length)
			if (!probe) {
				// (from the frame pointer: always within stp's reach)
				a.pair(false, saved[k + 1], saved[k], Asm.FP, -8 - 8 * (k + 1), 0);
				op(Unwind.SAVE, saved[k], saveOff[k]);
				op(Unwind.SAVE, saved[k + 1], saveOff[k + 1]);
				k += 2;
			} else if (paired(k)) {
				a.pair(false, saved[k], saved[k + 1], SP, saveOff[k], 0);
				op(Unwind.SAVE, saved[k], saveOff[k]);
				op(Unwind.SAVE, saved[k + 1], saveOff[k + 1]);
				k += 2;
			} else {
				ldst(false, 8, false, saved[k], SP, saveOff[k]);
				op(Unwind.SAVE, saved[k], saveOff[k]);
				k++;
			}
		subSp(split);
		op(Unwind.ENDPROLOGUE);
		// (a move of a register to itself: a 32-bit one zero-extends)
		f.threadJumps(i -> (i.op : AOp) == B, i -> (i.op : AOp) == MOV && i.d == i.s1 && (i.d >= 32 || i.size != 4));
		// (every return writes its epilogue: a copied return block is a jump less)
		f.duplicateReturns(i -> (i.op : AOp) == B, i -> (i.op : AOp) == RET, 3);
		// (an AArch64 condition ^ 1 is its exact inverse, unordered included)
		f.duplicateTests(i -> (i.op : AOp) == B, i -> (i.op : AOp) == BCOND, i -> switch (i.op : AOp) {
			case CMP | CMPI | FCMP: true;
			case _: false;
		}, i -> i.cond ^= 1, 2);
		for (b in f.blocks)
			b.label = a.newLabel();
		var tables:Array<{label:Int, entries:haxe.ds.Vector<LBlock>}> = [];
		for (bi in 0...f.blocks.length) {
			var b = f.blocks[bi];
			a.bind(b.label);
			var next = bi + 1 < f.blocks.length ? f.blocks[bi + 1] : null;
			LFunc.fallThrough(b, next, i -> (i.op : AOp) == B, i -> (i.op : AOp) == BCOND || (i.op : AOp) == CBZ, i -> if ((i.op : AOp) == CBZ) i.flag = !i.flag else i.cond ^= 1);
			for (i in b.ins)
				ins(i, next, tables);
		}
		for (t in tables) {
			a.bind(t.label);
			var at = text.buf.len;
			for (e in t.entries)
				text.buf.u32(a.labelPos(e.label) - at);
		}
		a.finish();
		var sym = obj.define(f.name, text, start, text.buf.len - start, global);
		var r = new FuncRec(sym, Vector.fromArrayCopy(ops));
		if (lines != null) {
			r.name = f.display;
			var rows = new Vector<Int>(3 * ((lines.length + 1) >> 1));
			var k = 0, j = 0;
			while (k < lines.length) {
				var p = SrcPos.get(lines[k + 1]);
				var fi = fileIndex.get(p.file);
				if (fi == null) {
					fi = obj.files.length;
					obj.files.push(p.file);
					fileIndex.set(p.file, fi);
				}
				rows[j++] = lines[k];
				rows[j++] = fi;
				rows[j++] = p.line;
				k += 2;
			}
			r.lines = rows;
		}
		obj.funcs.push(r);
		return sym;
	}

	function subSp(n:Int) {
		if (n == 0) return;
		if (probe && n >= 4096) {
			// sub sp, sp, #4096; str xzr, [sp] per page, then the rest
			var left = n;
			while (left >= 4096) {
				a.addSubI(2, true, SP, SP, 1, true);
				op(Unwind.ALLOC, 4096);
				a.ldst(false, 8, false, true, ZR, SP, 0);
				op(Unwind.NOP);
				left -= 4096;
			}
			if (left > 0) subSp0(left);
			return;
		}
		subSp0(n);
	}

	function subSp0(n:Int) {
		if (n >= 4096) {
			a.addSubI(2, true, SP, SP, n >> 12, true);
			op(Unwind.ALLOC, n & ~0xfff);
		}
		if (n & 0xfff != 0) {
			a.addSubI(2, true, SP, SP, n & 0xfff);
			op(Unwind.ALLOC, n & 0xfff);
		}
	}

	// saved registers k and k + 1 by one stp/ldp: of a kind, in adjacent
	// slots within its reach (not on Windows: its unwind codes are one per
	// instruction, save_reg's)
	function paired(k:Int):Bool
		return !probe && k + 1 < saved.length && (saved[k] >= 32) == (saved[k + 1] >= 32) && saveOff[k + 1] == saveOff[k] + 8
			&& saveOff[k] <= 496;

	function epilogue() {
		op(Unwind.EPILOGUE);
		if (split >= 4096) {
			a.addSubI(0, true, SP, SP, split >> 12, true);
			op(Unwind.FREE, split & ~0xfff);
		}
		if (split & 0xfff != 0) {
			a.addSubI(0, true, SP, SP, split & 0xfff);
			op(Unwind.FREE, split & 0xfff);
		}
		var k = 0;
		while (k < saved.length)
			if (!probe) {
				a.pair(true, saved[k + 1], saved[k], Asm.FP, -8 - 8 * (k + 1), 0);
				op(Unwind.RESTORE, saved[k], saveOff[k]);
				op(Unwind.RESTORE, saved[k + 1], saveOff[k + 1]);
				k += 2;
			} else if (paired(k)) {
				a.pair(true, saved[k], saved[k + 1], SP, saveOff[k], 0);
				op(Unwind.RESTORE, saved[k], saveOff[k]);
				op(Unwind.RESTORE, saved[k + 1], saveOff[k + 1]);
				k += 2;
			} else {
				ldst(true, 8, false, saved[k], SP, saveOff[k]);
				op(Unwind.RESTORE, saved[k], saveOff[k]);
				k++;
			}
		a.movSp(SP, Asm.FP);
		op(Unwind.SPFP);
		a.pair(true, Asm.FP, Asm.LR, SP, 16, 2);
		op(Unwind.RESTOREFPLR, 16);
		if (signs) {
			a.autsp(probe);
			op(Unwind.AUT);
		}
		a.ret();
		op(Unwind.RET);
	}

	// a load or store of [n + off], through x17 when the offset does not encode
	function ldst(load:Bool, size:Int, signed:Bool, t:Int, n:Int, off:Int, x = true) {
		if (a.ldst(load, size, signed, x, t, n, off)) return;
		a.movI(true, X17, off, off < 0 ? -1 : 0);
		a.ldstR(load, size, signed, x, t, n, X17, false);
	}

	// d = n + imm (d and n may be sp)
	function addImm(x:Bool, d:Int, n:Int, imm:Int) {
		if (imm >= 0 && imm < 4096) a.addSubI(0, x, d, n, imm) else if (imm < 0 && imm > -4096) a.addSubI(2, x, d, n, -imm) else {
			a.movI(true, X17, imm, imm < 0 ? -1 : 0);
			// add (extended register) would allow sp; with sp in n use x16 first
			if (n == SP || d == SP) {
				a.movSp(X16, n);
				a.addSubR(0, true, X16, X16, X17);
				a.movSp(d, X16);
			} else a.addSubR(0, x, d, n, X17);
		}
	}

	// the memory operand of a LOAD/STORE: base register and offset, or a symbol
	function mem(i:LIns, load:Bool, t:Int) {
		var x = i.size == 8 || t >= 32;
		var signedLoad = load && i.flag;
		var regx = i.size == 8 || (signedLoad && i.size < 4) ? x : false;
		if (i.sym != null) {
			var s = obj.sym(i.sym);
			a.adrp(X16, s, i.disp);
			a.ldstSymLo(load, i.size, signedLoad, i.size == 8, t, X16, s, i.disp);
			return;
		}
		if (i.base == LIns.FRAME) {
			ldst(load, i.size, signedLoad, t, SP, slotOff[i.slot] + i.disp, i.size == 8);
			return;
		}
		if (i.base == -3) {
			ldst(load, i.size, signedLoad, t, Asm.FP, 16 + i.disp, i.size == 8);
			return;
		}
		if (i.base == -4) {
			ldst(load, i.size, signedLoad, t, SP, i.disp, i.size == 8);
			return;
		}
		if (i.index >= 0) {
			a.ldstR(load, i.size, signedLoad, i.size == 8, t, i.base, i.index, i.scale != 1);
			return;
		}
		ldst(load, i.size, signedLoad, t, i.base, i.disp, i.size == 8);
	}

	function ins(i:LIns, next:Null<LBlock>, tables:Array<{label:Int, entries:haxe.ds.Vector<LBlock>}>) {
		if (lines != null && i.pos != 0 && i.pos != lastPos) {
			lastPos = i.pos;
			lines.push(text.buf.len - start);
			lines.push(i.pos);
		}
		var x = i.size == 8;
		switch (i.op : AOp) {
			case MOV:
				if (i.d >= 32 && i.s1 >= 32 && i.size == 16) a.movV(i.d, i.s1) else if (i.d >= 32 && i.s1 >= 32) a.fmovR(i.d, i.s1) else if (i.d >= 32) a.fmovFromGpr(i.d, i.s1) else if (i.s1 >= 32) a.fmovToGpr(i.d, i.s1)
				else if (i.d != i.s1 || i.size == 4) a.movR(i.size == 4 ? false : true, i.d, i.s1);
			case MOVI:
				if (i.isym != null) a.movSym(x, i.d, obj.sym(i.isym), i.imm) else a.movI(x, i.d, i.imm, x ? i.imm2 : 0);
			case MOVF:
				var bytes = haxe.io.Bytes.alloc(8);
				bytes.setDouble(0, i.f);
				var lo = bytes.getInt32(0), hi = bytes.getInt32(4);
				if (lo == 0 && hi == 0) a.fmovFromGpr(i.d, ZR) else {
					a.movI(true, X16, lo, hi);
					a.fmovFromGpr(i.d, X16);
				}
			case LEA:
				if (i.sym != null) a.adrSym(i.d, obj.sym(i.sym), i.disp) else if (i.base == LIns.FRAME) addImm(true, i.d, SP, slotOff[i.slot] + i.disp)
				else addImm(true, i.d, i.base, i.disp);
			case LOAD:
				mem(i, true, i.d);
			case STORE:
				mem(i, false, i.s1);
			case ALU:
				switch i.cond {
					case 0 | 1: a.addSubR(i.cond == 0 ? 0 : 2, x, i.d, i.s1, i.s2);
					case 2: a.logicR(0, x, i.d, i.s1, i.s2);
					case 3: a.logicR(1, x, i.d, i.s1, i.s2);
					case _: a.logicR(2, x, i.d, i.s1, i.s2);
				}
			case ALUI:
				var v = i.imm;
				switch i.cond {
					case 0 | 1:
						var add = (i.cond == 0) == (v >= 0);
						var mag = v >= 0 ? v : -v;
						a.addSubI(add ? 0 : 2, x, i.d, i.s1, mag);
					case op:
						if (!a.logicI(op == 2 ? 0 : op == 3 ? 1 : 2, x, i.d, i.s1, v, v < 0 ? -1 : 0)) throw "hxmc: logical immediate";
				}
			case ADDSH:
				a.addSubR(0, true, i.d, i.s1, i.s2, 0, i.imm);
			case MUL:
				a.mul(x, i.d, i.s1, i.s2);
			case SDIV:
				a.dp2(i.flag ? 0 : 1, x, i.d, i.s1, i.s2);
			case MSUB:
				a.msub(x, i.d, i.s1, i.s2, i.s3);
			case SHIFT:
				a.dp2(i.cond, x, i.d, i.s1, i.s2);
			case SHIFTI:
				if (i.imm == 0) a.movR(x, i.d, i.s1) else switch i.cond {
					case 2: a.lslI(x, i.d, i.s1, i.imm);
					case 3: a.lsrI(x, i.d, i.s1, i.imm);
					case 5: a.rorI(x, i.d, i.s1, i.imm);
					case _: a.asrI(x, i.d, i.s1, i.imm);
				}
			case NEG:
				a.neg(x, i.d, i.s1);
			case MVN:
				a.mvn(x, i.d, i.s1);
			case SXTW:
				a.sxtw(i.d, i.s1);
			case CMP:
				a.cmpR(x, i.s1, i.s2);
			case CMPI:
				var v = i.imm;
				if (v >= 0 && v < 4096) a.cmpI(x, i.s1, v) else if (v < 0 && v > -4096) a.cmnI(x, i.s1, -v) else {
					a.movI(x, X16, v, v < 0 ? -1 : 0);
					a.cmpR(x, i.s1, X16);
				}
			case FCMP:
				a.fcmp(i.s1, i.s2);
			case CSET:
				a.cset(false, i.d, i.cond);
			case CSEL:
				a.csel(x, i.d, i.s1, i.s2, i.cond);
			case FOP2:
				a.fop2(i.cond, i.d, i.s1, i.s2);
			case FOP1:
				a.fop1(i.cond, i.d, i.s1);
			case SCVTF:
				a.scvtf(x, i.d, i.s1);
			case FCVTZS:
				a.fcvtzs(x, i.d, i.s1);
			case FMOVTOG:
				a.fmovToGpr(i.d, i.s1);
			case FMOVFROMG:
				a.fmovFromGpr(i.d, i.s1);
			case CALL:
				if (i.sym != null) a.blSym(obj.sym(i.sym)) else a.blr(i.s1);
			case RET:
				epilogue();
			case B:
				if (i.target != next) a.bLabel(i.target.label);
			case BCOND:
				a.bcond(i.cond, i.target.label);
			case CBZ:
				a.cbz(x, i.s1, i.target.label, i.flag);
			case JTABLE:
				var l = a.newLabel();
				tables.push({label: l, entries: i.table});
				a.adrLabel(X16, l);
				a.ldstR(true, 4, true, true, X17, X16, i.s1, true);
				a.addSubR(0, true, X16, X16, X17);
				a.br(X16);
			case TLSLOAD if (i.s2 >= 0):
				// [base + offset]: add x16, base, #hi12, lsl 12; ldr d, [x16, #lo12]
				var s = tlsSym(i.sym);
				a.reloc(RA64SecRelHi12, s, 0);
				a.addSubI(0, true, X16, i.s2, 0, true);
				a.reloc(RA64SecRelLo12L, s, 0);
				a.ldst(true, 8, false, true, i.d, X16, 0);
			case TLSSTORE if (i.s2 >= 0):
				var s = tlsSym(i.sym);
				a.reloc(RA64SecRelHi12, s, 0);
				a.addSubI(0, true, X16, i.s2, 0, true);
				a.reloc(RA64SecRelLo12L, s, 0);
				a.ldst(false, 8, false, true, i.s1, X16, 0);
			case TLSLOAD:
				a.tlsAddr(X16, tlsSym(i.sym));
				a.ldst(true, 8, false, true, i.d, X16, 0);
			case TLSSTORE:
				a.tlsAddr(X16, tlsSym(i.sym));
				a.ldst(false, 8, false, true, i.s1, X16, 0);
			case TEBLOAD:
				a.ldst(true, 8, false, true, i.d, 18, i.imm);
			case TLSBASE:
				// Apple's TLV access inline (dyld's _tlv_get_addr): the image's
				// descriptor (hxmc_tls_start: offset 0) holds the pthread key whose
				// slot in the thread's TSD array (tpidrro_el0) is its block; an empty
				// slot (the thread's first access) calls the thunk, which keeps every
				// register but x0, x16, x17 and lr (the TLV convention): x0 and lr
				// are kept here, so the function stays a leaf
				var desc = obj.sym("hxmc_tls_start"), done = a.newLabel();
				a.adrSym(X16, desc, 0);
				a.ldst(true, 8, false, true, X17, X16, 8);
				a.mrsTpRo(X16);
				a.logicI(0, true, X16, X16, -8, -1);
				a.ldstR(true, 8, false, true, X16, X16, X17, true);
				a.cbz(true, X16, done, true);
				a.pair(false, 0, 30, 31, -16, 1);
				a.adrSym(0, desc, 0);
				a.ldst(true, 8, false, true, X16, 0, 0);
				a.blr(X16);
				a.movR(true, X16, 0);
				a.pair(true, 0, 30, 31, 16, 2);
				a.bind(done);
				a.movR(true, i.d, X16);
			case BRK:
				a.brk();
			case LDAR:
				a.ldar(x, i.d, i.s1);
			case STLR:
				a.stlr(x, i.s2, i.s1);
			case ATOMIC:
				var again = a.newLabel();
				a.bind(again);
				a.ldaxr(x, i.d, i.s1);
				switch i.cond {
					case 0:
						a.addSubR(0, x, X16, i.d, i.s2);
						a.stlxr(x, X17, X16, i.s1);
						a.cbz(false, X17, again, true);
					case 1:
						a.stlxr(x, X17, i.s2, i.s1);
						a.cbz(false, X17, again, true);
					case _:
						var differ = a.newLabel(), done = a.newLabel();
						a.cmpR(x, i.d, i.s3);
						a.bcond(Asm.NE, differ);
						a.stlxr(x, X17, i.s2, i.s1);
						a.cbz(false, X17, again, true);
						a.bLabel(done);
						a.bind(differ);
						a.clrex();
						a.bind(done);
				}
			case KEEP:
			case DMB:
				if (i.cond == 1) a.dmbIshst() else a.dmbIsh();
			case FMOVSW:
				a.fmovSFromW(i.d, i.s1);
			case FMOVWS:
				a.fmovWFromS(i.d, i.s1);
			case FCVTSD:
				a.fcvtSToD(i.d, i.s1);
			case FCVTDS:
				a.fcvtDToS(i.d, i.s1);
			case NV:
				a.neon(i.imm, i.d, i.s1, i.s2);
			case VCONST:
				var u = i.uses;
				if (u[0] == 0 && u[1] == 0 && u[2] == 0 && u[3] == 0) a.neon(0x6F00E400, i.d, -1, -1) // movi v.2d, #0
				else if (u[0] == -1 && u[1] == -1 && u[2] == -1 && u[3] == -1) a.neon(0x6F07E7E0, i.d, -1, -1) // movi v.2d, #-1
				else if (u[0] == u[1] && u[1] == u[2] && u[2] == u[3]) {
					// a word in every lane (a splat): through w16, dup v.4s
					a.movI(false, X16, u[0], 0);
					a.neon(0x4E040C00, i.d, X16, -1);
				} else if (u[0] == u[2] && u[1] == u[3]) {
					a.movI(true, X16, u[0], u[1]);
					a.neon(0x4E080C00, i.d, X16, -1); // dup v.2d, x16
				} else {
					// the low half through x16 (fmov d, x16: the high half zero), the high one if any
					a.movI(true, X16, u[0], u[1]);
					a.fmovFromGpr(i.d, X16);
					if (u[2] != 0 || u[3] != 0) {
						a.movI(true, X16, u[2], u[3]);
						a.neon(0x4E181C00, i.d, X16, -1); // ins v.d[1], x16
					}
				}
		}
	}

	function tlsSym(name:String):Symbol {
		var s = obj.sym(name);
		s.tls = true;
		return s;
	}
}
