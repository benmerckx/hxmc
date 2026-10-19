package hxmc.x64;

import hxmc.Lir;
import hxmc.Mir.SrcPos;
import hxmc.Obj;
import hxmc.x64.Asm;
import hxmc.x64.Isel.XOp;

// Allocated LIR -> x86-64 machine code in a text section: frame layout,
// prologue and epilogues, jump tables, the constant pool. With frame pointers
// (Abi.framePointers) every function starts with push rbp; mov rbp, rsp
// (rbp is then not allocated: Isel), so [rbp] links to the caller's record
// and [rbp + 8] is the return address, leaf functions included. The prologue
// and epilogues record what they do to the frame (Unwind: the unwind
// tables), and with -debug the instructions' source lines are recorded
// (FuncRec).
class Emit implements hxmc.Target.Emitter {
	var obj:Obj;
	var text:Section;
	var rodata:Section;
	var a:Asm;
	var pool = new Map<String, Symbol>();
	var npool = 0;

	var win:Bool;
	var fp:Bool;
	// this function's frame operations (Unwind; offsets in the section until
	// the function is done) and (-debug) its rows of lines
	var ops:Array<Int>;
	var lines:Null<Array<Int>>;
	var lastPos = 0;
	var fileIndex = new Map<String, Int>();

	public function new(obj:Obj, win = false, fp = false) {
		this.obj = obj;
		this.win = win;
		this.fp = fp;
		text = obj.section(".text", Text, FALIGN);
		rodata = obj.section(".rodata", RoData, 16);
		a = new Asm(text);
	}

	// a 16-byte constant (low, high 64 bits as hex strings of their halves)
	function constant(lo0:Int, lo1:Int, hi0:Int, hi1:Int):Symbol {
		var key = '$lo0,$lo1,$hi0,$hi1';
		var s = pool.get(key);
		if (s != null) return s;
		rodata.buf.align(16);
		var off = rodata.buf.len;
		rodata.buf.u32(lo0);
		rodata.buf.u32(lo1);
		rodata.buf.u32(hi0);
		rodata.buf.u32(hi1);
		s = obj.define(".Lk" + npool++, rodata, off, 16, false);
		pool.set(key, s);
		return s;
	}

	function floatConst(v:Float):Symbol {
		var bits = haxe.io.Bytes.alloc(8);
		bits.setDouble(0, v);
		return constant(bits.getInt32(0), bits.getInt32(4), 0, 0);
	}

	var slotOff:Array<Int>;
	var frameSize = 0;

	// HXMC_SIZE_STATS=1: bytes of code by instruction kind, hot and cold
	// blocks, frame slots and other memory, prologue and epilogues (all functions, all threads)
	public static var sizeStats = Sys.getEnv("HXMC_SIZE_STATS") == "1";
	static var statLock = new sys.thread.Mutex();
	public static var statBytes = new Map<String, Int>();

	static function stat(k:String, n:Int) {
		statLock.acquire();
		statBytes.set(k, (statBytes.exists(k) ? statBytes.get(k) : 0) + n);
		statLock.release();
	}
	var saved:Array<Int>;
	var savedX:Array<Int>; // Win64: xmm6-15 used, saved in the frame (all 128 bits)
	var savedXOff:Array<Int>;

	// (measurement: how much run time depends on code layout alone, the
	// noise of A/B comparisons: HXMC_FALIGN aligns functions, HXMC_FSHIFT
	// pads before each one)
	static var FALIGN = Sys.getEnv("HXMC_FALIGN") != null ? Std.parseInt(Sys.getEnv("HXMC_FALIGN")) : 16;
	static var FSHIFT = Sys.getEnv("HXMC_FSHIFT") != null ? Std.parseInt(Sys.getEnv("HXMC_FSHIFT")) : 0;

	public function useSection(name:Null<String>) {
		text = obj.section(name != null ? name : ".text", Text, FALIGN);
		a.sec = text;
		a.b = text.buf;
	}

	public function func(f:LFunc, usedRegs:Array<Bool>, global:Bool):Symbol {
		text.buf.align(FALIGN, 0xcc);
		for (_ in 0...FSHIFT)
			text.buf.u8(0xcc);
		var start = text.buf.len;
		a.reset();
		// frame: outgoing arguments, then the slots
		var off = f.outArgs;
		slotOff = [];
		for (s in f.slots) {
			var al = s.align < 8 ? 8 : s.align;
			off = (off + al - 1) & ~(al - 1);
			slotOff.push(off);
			off += s.size;
		}
		saved = [for (r in (win ? Isel.WIN_CALLEE_SAVED : Isel.CALLEE_SAVED)) if (r < 16 && usedRegs[r]) r];
		savedX = [for (r in (win ? Isel.WIN_CALLEE_SAVED : [])) if (r >= 16 && usedRegs[r]) r];
		savedXOff = [];
		for (_ in savedX) {
			off = (off + 15) & ~15;
			savedXOff.push(off);
			off += 16;
		}
		var x = off;
		while ((8 + 8 * pushed() + x) % 16 != 0)
			x += 8;
		// leaf functions without slots keep rsp as it is
		if (!f.hasCalls && f.slots.length == 0 && f.outArgs == 0 && savedX.length == 0) x = 0;
		frameSize = x;
		ops = [];
		lines = f.display != null ? [] : null;
		lastPos = 0;
		if (fp) {
			a.push(Asm.RBP);
			op(Unwind.PUSH, Asm.RBP);
			a.movRR(8, Asm.RBP, Asm.RSP);
			op(Unwind.SETFP);
		}
		for (r in saved) {
			a.push(r);
			op(Unwind.PUSH, r);
		}
		if (win && frameSize >= 4096) {
			// Windows commits the stack one guard page at a time: touch each page
			// (described as one allocation at the end)
			var left = frameSize;
			while (left >= 4096) {
				a.aluRI(Asm.SUB, 8, Asm.RSP, 4096);
				a.aluMI(Asm.OR, 8, new Mem(Asm.RSP, 0), 0);
				left -= 4096;
			}
			if (left > 0) a.aluRI(Asm.SUB, 8, Asm.RSP, left);
			op(Unwind.ALLOC, frameSize);
		} else if (frameSize > 0) {
			a.aluRI(Asm.SUB, 8, Asm.RSP, frameSize);
			op(Unwind.ALLOC, frameSize);
		}
		for (k in 0...savedX.length) {
			a.movupsMR(new Mem(Asm.RSP, savedXOff[k]), savedX[k]);
			op(Unwind.SAVE, savedX[k], savedXOff[k]);
		}
		op(Unwind.ENDPROLOGUE);
		if (sizeStats) stat("prologue", text.buf.len - start);
		epiLabel = -1;
		// (a move of a register to itself: a zero or sign extension is not)
		f.threadJumps(i -> (i.op : XOp) == JMP,
			i -> (i.op : XOp) == MOV && i.d == i.s1 && (isX(i.d) || !i.flag && !(i.size == 4 && i.imm2 == 1)));
		for (b in f.blocks)
			b.label = a.newLabel();
		var tables:Array<{label:Int, entries:Array<LBlock>}> = [];
		for (bi in 0...f.blocks.length) {
			var b = f.blocks[bi];
			a.bind(b.label);
			var next = bi + 1 < f.blocks.length ? f.blocks[bi + 1] : null;
			LFunc.fallThrough(b, next, i -> (i.op : XOp) == JMP, i -> (i.op : XOp) == JCC, i -> i.cond ^= 1);
			// a zero constant may be xor where no flags are live (none are
			// live at block ends: branches consume them in their block)
			var live = false;
			var k = b.ins.length;
			while (k-- > 0) {
				var i = b.ins[k];
				switch i.op {
					case JCC | SETCC | CMOV: live = true;
					case CMP | CMPI | TEST | UCOMI | ALU | ALUI | NEG | CALL: live = false;
					case MOVI if (i.flag && !live && i.isym == null): i.flag = false;
					case _:
				}
			}
			if (sizeStats) {
				for (i in b.ins) {
					var at = text.buf.len;
					var ep = epilogueBytes;
					ins(i, next, tables);
					var nb = text.buf.len - at;
					var kind = Std.string(i.op);
					if ((i.op : XOp) == LOAD || (i.op : XOp) == STORE || (i.op : XOp) == STOREI)
						kind += (i.base == LIns.FRAME ? "-frame" : i.base < 0 ? "-sym" : "-mem") + i.mem;
					if ((i.op : XOp) == STOREI) kind += i.imm == 0 && i.isym == null ? "z" : "c";
					stat((b.cold ? "cold " : "hot ") + kind, nb - (epilogueBytes - ep));
					stat(b.cold ? "cold" : "hot", nb);
				}
			} else
				for (i in b.ins)
					ins(i, next, tables);
		}
		var tf = text.buf.len;
		var map = a.finish(start);
		if (sizeStats) {
			stat("epilogue", epilogueBytes);
			stat("finish (branch relaxation)", text.buf.len - tf);
			epilogueBytes = 0;
		}
		// jump tables: 32-bit offsets from the table
		for (t in tables) {
			text.buf.align(4, 0);
			a.bind(t.label);
			var at = text.buf.len;
			for (e in t.entries)
				text.buf.u32(a.labelPos(e.label) - at);
		}
		a.patchLabelRefs();
		var sym = obj.define(f.name, text, start, text.buf.len - start, global);
		var k = 1;
		while (k < ops.length) {
			ops[k] = map(ops[k]) - start;
			k += 4;
		}
		var r = new FuncRec(sym, ops);
		if (lines != null) {
			r.name = f.display;
			var rows = [];
			var k = 0;
			while (k < lines.length) {
				var p = SrcPos.get(lines[k + 1]);
				var fi = fileIndex.get(p.file);
				if (fi == null) {
					fi = obj.files.length;
					obj.files.push(p.file);
					fileIndex.set(p.file, fi);
				}
				rows.push(map(lines[k]) - start);
				rows.push(fi);
				rows.push(p.line);
				k += 2;
			}
			r.lines = rows;
		}
		obj.funcs.push(r);
		return sym;
	}

	// a frame operation (Unwind) whose instruction ends here
	inline function op(kind:Int, x = 0, y = 0) {
		ops.push(kind);
		ops.push(text.buf.len);
		ops.push(x);
		ops.push(y);
	}

	// a function written directly (stubs) and its frame operations
	function define(name:String, start:Int, global = true) {
		var sym = obj.define(name, text, start, text.buf.len - start, global);
		var k = 1;
		while (k < ops.length) {
			ops[k] -= start;
			k += 4;
		}
		obj.funcs.push(new FuncRec(sym, ops));
	}

	// the arguments of hxmc_alloc_slow, then a jump to it (no frame: 20 bytes)
	public function allocStub(name:String, lo:Int, tySym:Null<String>, tyVal:Int, bytes:Int):Bool {
		var start = text.buf.len;
		ops = [];
		a.movImm32(win ? 1 : 7, lo); // rcx / rdi
		if (tySym != null) a.isym = obj.sym(tySym);
		a.movImm32(win ? 2 : 6, tySym != null ? 0 : tyVal); // rdx / rsi
		a.movImm32(win ? 8 : 2, bytes); // r8 / rdx
		a.jmpSym(obj.sym("hxmc_alloc_slow"));
		define(name, start);
		return true;
	}

	// the runtime's stubs (MirBuild.STUB_*), in the C convention
	public function stub(name:String) {
		var start = text.buf.len;
		ops = [];
		var arg0 = win ? Asm.RCX : Asm.RDI, arg1 = win ? Asm.RDX : Asm.RSI;
		switch name {
			case hxmc.MirBuild.STUB_CALL_ON_STACK:
				// fn() with the stack pointer at top (Windows: its home area
				// below); unwinders follow the frame pointer back to the old stack
				a.push(Asm.RBP);
				op(Unwind.PUSH, Asm.RBP);
				a.movRR(8, Asm.RBP, Asm.RSP);
				op(Unwind.SETFP);
				op(Unwind.ENDPROLOGUE);
				a.movRR(8, Asm.RSP, arg0);
				if (win) a.aluRI(Asm.SUB, 8, Asm.RSP, 32);
				a.callR(arg1);
				op(Unwind.EPILOGUE);
				a.movRR(8, Asm.RSP, Asm.RBP);
				op(Unwind.SPFP);
				a.pop(Asm.RBP);
				op(Unwind.POP, Asm.RBP);
				a.ret();
				op(Unwind.RET);
			case hxmc.MirBuild.STUB_ZERO:
				// rep stosb: rdi = p, rcx = bytes, al = 0 (rdi is callee-saved on Windows)
				if (win) {
					a.push(Asm.RDI);
					op(Unwind.PUSH, Asm.RDI);
					op(Unwind.ENDPROLOGUE);
					a.movRR(8, Asm.RDI, Asm.RCX);
				}
				a.movRR(8, Asm.RCX, arg1);
				a.movImm32(Asm.RAX, 0);
				text.buf.u8(0xF3);
				text.buf.u8(0xAA);
				if (win) {
					op(Unwind.EPILOGUE);
					a.pop(Asm.RDI);
					op(Unwind.POP, Asm.RDI);
				}
				a.ret();
				if (win) op(Unwind.RET);
			case hxmc.MirBuild.STUB_FRAME:
				// the caller's rbp (this stub keeps no record of its own)
				a.movRR(8, Asm.RAX, Asm.RBP);
				a.ret();
			case _:
				throw "hxmc: unknown runtime stub " + name;
		}
		define(name, start);
	}

	function mem(i:LIns):Mem {
		if (i.secrel != null) {
			var m = new Mem(i.base, i.disp);
			m.dispSym = obj.sym(i.secrel);
			m.dispKind = RSecRel32;
			return m;
		}
		if (i.dsym != null) {
			var m = new Mem(i.base, i.disp, i.index, i.scale);
			m.dispSym = obj.sym(i.dsym);
			m.dispKind = RAbs32S;
			return m;
		}
		if (i.sym != null) return Mem.rip(obj.sym(i.sym), i.disp);
		if (i.base == LIns.FRAME) return new Mem(Asm.RSP, slotOff[i.slot] + i.disp);
		if (i.base == -3) return new Mem(Asm.RSP, frameSize + 8 * pushed() + 8 + i.disp);
		if (i.base == -4) return new Mem(Asm.RSP, i.disp);
		return new Mem(i.base, i.disp, i.index, i.scale);
	}

	function tlsSym(name:String):Symbol {
		var s = obj.sym(name);
		s.tls = true;
		return s;
	}

	static inline function isX(r:Int):Bool
		return r >= 16;

	var epilogueBytes = 0;
	var epiLabel = -1; // the shared epilogue (this function's first)

	// the registers the prologue pushes (rbp first with frame pointers)
	inline function pushed():Int
		return saved.length + (fp ? 1 : 0);

	function epilogue() {
		var at = text.buf.len;
		op(Unwind.EPILOGUE);
		for (k in 0...savedX.length)
			a.movupsRM(savedX[k], new Mem(Asm.RSP, savedXOff[k]));
		if (frameSize > 0) {
			a.aluRI(Asm.ADD, 8, Asm.RSP, frameSize);
			op(Unwind.FREE, frameSize);
		}
		var k = saved.length;
		while (k-- > 0) {
			a.pop(saved[k]);
			op(Unwind.POP, saved[k]);
		}
		if (fp) {
			a.pop(Asm.RBP);
			op(Unwind.POP, Asm.RBP);
		}
		a.ret();
		op(Unwind.RET);
		epilogueBytes += text.buf.len - at;
	}

	function ins(i:LIns, next:Null<LBlock>, tables:Array<{label:Int, entries:Array<LBlock>}>) {
		if (lines != null && i.pos != 0 && i.pos != lastPos) {
			lastPos = i.pos;
			lines.push(text.buf.len);
			lines.push(i.pos);
		}
		if (i.isym != null) a.isym = obj.sym(i.isym);
		switch (i.op : XOp) {
			case MOV:
				if (isX(i.d) && isX(i.s1)) a.movsdRR(i.d, i.s1) else if (isX(i.d)) a.movqXR(i.d, i.s1) else if (isX(i.s1)) a.movqRX(i.d, i.s1) else if (i.flag)
					a.movsxdR(i.d, i.s1)
				else if (i.d != i.s1 || i.size == 4 && i.imm2 == 1) a.movRR(i.size == 4 ? 4 : 8, i.d, i.s1);
			case MOVI:
				if (i.isym != null) a.movImm32(i.d, i.imm) else if (i.flag && i.imm == 0 && (i.size == 4 || i.imm2 == 0)) a.movImm32(i.d, 0) else if (i.size == 4) a.movRI(4, i.d, i.imm) else a.movRI64(i.d, i.imm, i.imm2);
			case MOVF:
				if (i.f == 0 && 1 / i.f > 0) a.xorpd(i.d, i.d) else a.movsdRM(i.d, Mem.rip(floatConst(i.f)));
			case LEA:
				a.lea(8, i.d, mem(i));
			case LOAD:
				var m = mem(i);
				if (isX(i.d)) a.movsdRM(i.d, m) else switch i.size {
					case 1: if (i.flag) a.movsx8(4, i.d, m) else a.movzx8(i.d, m);
					case 2: if (i.flag) a.movsx16(4, i.d, m) else a.movzx16(i.d, m);
					case 4: a.load(4, i.d, m);
					case _: a.load(8, i.d, m);
				}
			case STORE:
				var m = mem(i);
				if (isX(i.s1)) a.movsdMR(m, i.s1) else a.store(i.size, m, i.s1);
			case STOREI:
				a.storeI(i.size, mem(i), i.imm);
			case ALU:
				a.aluRR(i.cond, i.size, i.d, i.s1);
			case ALUI:
				a.aluRI(i.cond, i.size, i.d, i.imm);
			case IMUL:
				a.imulRR(i.size, i.d, i.s1);
			case IMULI:
				a.imulRRI(i.size, i.d, i.s1, i.imm);
			case SHIFT:
				a.shiftCl(i.cond, i.size, i.d);
			case SHIFTI:
				if (i.imm != 0) a.shiftI(i.cond, i.size, i.d, i.imm);
			case NEG:
				a.neg(i.size, i.d);
			case NOT:
				a.not(i.size, i.d);
			case CQO:
				a.signExtendAx(i.size);
			case IDIV:
				a.idiv(i.size, i.s1);
			case CMP:
				a.aluRR(Asm.CMP, i.size, i.s1, i.s2);
			case CMPI:
				a.aluRI(Asm.CMP, i.size, i.s1, i.imm);
			case CMPM:
				a.aluRM(Asm.CMP, i.size, i.s1, mem(i));
			case CMPMI:
				a.aluMI(Asm.CMP, i.size, mem(i), i.imm);
			case ALUM:
				a.aluRM(i.cond, i.size, i.d, mem(i));
			case TEST:
				a.testRR(i.size, i.s1, i.s2);
			case UCOMI:
				a.ucomisdRR(i.s1, i.s2);
			case SETCC:
				a.setcc(i.cond, i.d);
				a.movzx8R(i.d, i.d);
			case CMOV:
				a.cmovRR(i.cond, i.size < 4 ? 4 : i.size, i.d, i.s1);
			case FOP:
				a.sdRR(i.cond, i.d, i.s1);
			case FOPK:
				a.sdRM(i.cond, i.d, Mem.rip(floatConst(i.f)));
			case FSQRT:
				a.sdRR(0x51, i.d, i.s1);
			case FMASK:
				var k = i.imm == 0 ? constant(0, 0x80000000, 0, 0) : constant(-1, 0x7fffffff, 0, 0);
				a.pdRM(i.cond, i.d, Mem.rip(k));
			case CVTI2F:
				a.xorpd(i.d, i.d);
				a.cvtsi2sd(i.size, i.d, i.s1);
			case CVTF2I:
				a.cvttsd2si(i.size, i.d, i.s1);
			case MOVQXR:
				a.movqXR(i.d, i.s1);
			case MOVQRX:
				a.movqRX(i.d, i.s1);
			case CALL:
				if (i.sym != null) a.callSym(obj.sym(i.sym)) else a.callR(i.s1);
			case RET:
				// the first return's epilogue is shared: later ones jump to it
				// when it is longer than the jump
				if (epiLabel >= 0) a.jmp(epiLabel) else {
					var at = text.buf.len;
					var l = a.newLabel();
					a.bind(l);
					epilogue();
					if (text.buf.len - at > 5) epiLabel = l;
				}
			case JMP:
				if (i.target != next) a.jmp(i.target.label);
			case JCC:
				a.jcc(i.cond, i.target.label);
			case LEATABLE:
				var l = a.newLabel();
				tables.push({label: l, entries: i.table});
				a.leaLabel(i.d, l);
			case JTABLE:
				a.movsxd(i.s2, new Mem(i.d, 0, i.s1, 4));
				a.aluRR(Asm.ADD, 8, i.d, i.s2);
				a.jmpR(i.d);
			case GSLOAD:
				var m = new Mem(-1, i.imm);
				m.gs = true;
				a.load(8, i.d, m);
			case TLSLOAD:
				a.load(8, i.d, Mem.tlsVar(tlsSym(i.sym)));
			case TLSSTORE:
				a.store(8, Mem.tlsVar(tlsSym(i.sym)), i.s1);
			case UD2:
				a.ud2();
			case XCHG:
				a.xchgMR(i.size, mem(i), i.d);
			case XADD:
				a.lockXaddMR(i.size, mem(i), i.d);
			case CMPXCHG:
				a.lockCmpxchgMR(i.size, mem(i), i.s1);
			case MFENCE:
				a.mfence();
			case CVTSS2SD:
				a.cvtss2sd(i.d, i.s1);
			case CVTSD2SS:
				a.cvtsd2ss(i.d, i.s1);
			case MOVDXR:
				a.movdXR(i.d, i.s1);
			case MOVDRX:
				a.movdRX(i.d, i.s1);
		}
	}
}
