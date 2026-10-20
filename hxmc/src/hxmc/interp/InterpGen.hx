package hxmc.interp;

import hxmc.Mir;
import hxmc.Obj;
import hxmc.ir.Ir;

// The operations of the interpreter's code: hxmc/std/hxmc/rt/Interp.hx runs
// them (IOp there: the same list, the operands described there).
enum abstract IOp(Int) from Int to Int {
	var TLSLD = 0;
	var TLSST;
	var TLSST_HCUR;
	var SADDR;
	var MOV;
	var ADD;
	var SUB;
	var MUL;
	var AND;
	var OR;
	var XOR;
	var NEG;
	var NOT;
	var SHL32;
	var SHL64;
	var SAR32;
	var SAR64;
	var SHR32;
	var SHR64;
	var DIV32;
	var DIV64;
	var REM32;
	var REM64;
	var ROTR32;
	var ROTR64;
	var FADD;
	var FSUB;
	var FMUL;
	var FDIV;
	var FNEG;
	var FSQRT;
	var FABS;
	var EQ32;
	var NE32;
	var LT32;
	var LE32;
	var GT32;
	var GE32;
	var ULT32;
	var ULE32;
	var UGT32;
	var UGE32;
	var EQ64;
	var NE64;
	var LT64;
	var LE64;
	var GT64;
	var GE64;
	var ULT64;
	var ULE64;
	var UGT64;
	var UGE64;
	var FEQ;
	var FNE;
	var FLT;
	var FLE;
	var FGT;
	var FGE;
	var SEXT;
	var ZEXT;
	var TRUNC;
	var I2F32;
	var I2F64;
	var F2I32;
	var F2I64;
	var SELECT;
	var LD1S;
	var LD1U;
	var LD2S;
	var LD2U;
	var LD4S;
	var LD4U;
	var LD8;
	var LDF4;
	var LDX1S;
	var LDX1U;
	var LDX2S;
	var LDX2U;
	var LDX4S;
	var LDX4U;
	var LDX8;
	var LDXF4;
	var ST1;
	var ST2;
	var ST4;
	var ST8;
	var STF4;
	var STX1;
	var STX2;
	var STX4;
	var STX8;
	var STXF4;
	var CALLN;
	var CALLNI;
	var CALLI;
	var SETJMP;
	var JMP;
	var MOVJ1;
	var MOVJ2;
	var MOVJN;
	var BR;
	var BEQ32;
	var BNE32;
	var BLT32;
	var BLE32;
	var BGT32;
	var BGE32;
	var BULT32;
	var BULE32;
	var BUGT32;
	var BUGE32;
	var BEQ64;
	var BNE64;
	var BLT64;
	var BLE64;
	var BGT64;
	var BGE64;
	var BULT64;
	var BULE64;
	var BUGT64;
	var BUGE64;
	var BFEQ;
	var BFNE;
	var BFLT;
	var BFLE;
	var BFGT;
	var BFGE;
	var SWITCH;
	var SWITCHT;
	var RET;
	var RETV;
	var UNREACH;
	var TLSXLD;
	var TLSXST;
}

// The functions -D hxmc.interp interprets: those of the program's modules
// (not the runtime's, hxmc.rt and hxmc.unsafe), or of the modules named (prefixes,
// comma-separated), except the ones C enters with structs by value.
class InterpSet {
	final prefixes:Null<Array<String>>;
	// the symbols of the functions interpreted (a call of one: CALLI)
	public final syms = new Map<String, Bool>();

	// (exclude: functions whose native code is used, interp.MirRun)
	final exclude:Null<Map<FuncInfo, Bool>>;

	public function new(spec:String, prep:Prep, ?exclude:Map<FuncInfo, Bool>) {
		this.exclude = exclude;
		prefixes = spec == "" || spec == "1" ? null : [for (p in spec.split(",")) if (StringTools.trim(p) != "") StringTools.trim(p)];
		for (f in prep.p.funcs)
			if (wants(f)) syms.set(prep.funcSym(f), true);
	}

	public function wants(f:FuncInfo):Bool {
		if (f.module == null || StringTools.startsWith(f.module, "hxmc.rt.") || StringTools.startsWith(f.module, "hxmc.unsafe.") || f.cAbi != null) return false;
		if (exclude != null && exclude.exists(f)) return false;
		if (prefixes == null) return true;
		for (p in prefixes)
			if (StringTools.startsWith(f.module, p)) return true;
		return false;
	}

	// an empty table: a program with the interpreter, none of its functions
	// interpreted (a compiler that loads interpreted code: -D hxmc.jit)
	public static function emptyTable(obj:Obj) {
		var sec = obj.section(".data", SecKind.Data, 16);
		sec.buf.align(16);
		var start = sec.buf.len;
		sec.buf.u64(0, 0);
		obj.define(InterpGen.TABLE, sec, start, 8, true);
	}

	// the table of the functions interpreted (hxmc.rt.Interp.lookup: an
	// indirect call of an entry stub runs its function directly): their
	// number, then each entry stub's address and its descriptor's
	public function table(obj:Obj) {
		var names = [for (n in syms.keys()) n];
		names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		var sec = obj.section(".data", SecKind.Data, 16);
		var b = sec.buf;
		b.align(16);
		var start = b.len;
		b.u64(names.length, 0);
		for (n in names) {
			sec.relocs.push(new Reloc(b.len, RelKind.RAbs64, obj.sym(n), 0));
			b.u64(0, 0);
			sec.relocs.push(new Reloc(b.len, RelKind.RAbs64, obj.sym(InterpGen.DESC + n), 0));
			b.u64(0, 0);
		}
		obj.define(InterpGen.TABLE, sec, start, b.len - start, true);
	}
}

// One function's Mir (after the optimizations) for the interpreter
// (hxmc.rt.Interp): its descriptor in the module's .data (DESC + its
// symbol), its entry stub (a native function of its symbol, so that
// whatever calls it, code, dispatch rows, closures, C, finds it as before)
// and the call-out stubs its calls of native code go through (local
// functions of the module's object, one per callee and signature).
//
// The descriptor: a header (MAGIC, registers, frame bytes, code words, the
// symbol table's offset, constants, their offset, parameters), the code (words:
// an operation and its operands, branch targets as byte offsets in the
// code, relative to their instruction's start), the constants (8 bytes each, relocated: copied into the first
// registers when a frame starts, so a constant is never an operation) and
// the symbol table (8 bytes each, relocated: call-out stubs, other
// descriptors; zeroed: inline caches).
//
// Registers: the constants (deduplicated), the parameters (a caller writes
// its arguments there), then the other values, then
// scratch ones for the phi moves of an edge that form a cycle. A compare
// whose only use is a branch is that branch (BLT32...). Phis are the moves
// of the edges into their block: a jump carries them (MOVJ1...), a branch's
// edge with moves goes through a trampoline after the code.
@:access(hxmc.MirBuild)
class InterpGen {
	public static inline var DESC = "hxmc_i$";
	public static inline var TABLE = "hxmc_interp_fns";
	static inline var STUB = "hxmc_ic$";
	static inline var MAGIC = 0x31495848;
	static inline var HEADER = 32;
	// the runtime's thread-local variables the interpreter reads itself (Interp.T_*)
	static var TLS = [
		"rt_sp" => 0, "rt_sp_hw" => 1, "rt_hcur" => 2, "rt_exn" => 3, "rt_young_ptr" => 4, "rt_young_limit" => 5, "rt_young_rlimit" => 6,
		"rt_mut" => 7
	];

	final prep:Prep;
	final abi:Abi;
	final obj:Obj;
	final mf:MFunc;
	final set:InterpSet;
	// compiles a stub into the module's object (global or not)
	final compile:(MFunc, Bool) -> Void;
	final code:Array<Int> = [];
	final syms:Array<{name:Null<String>, addend:Int}> = [];
	final symIndex = new Map<String, Int>();
	final consts:Array<{lo:Int, hi:Int, sym:Null<String>}> = [];
	final constIndex = new Map<String, Int>();
	// value -> register (-1: none)
	var reg:haxe.ds.Vector<Int>;
	var nregs = 0;
	var scratch = 0;
	// compares that are their branch's condition
	final fused = new Map<Int, Bool>();
	// targets to fill in: blocks' (their code's offset), trampolines' (an edge's moves)
	final fixups:Array<{at:Int, from:Int, to:MBlock}> = [];
	final tramps:Array<{at:Int, from:Int, moves:Array<{d:Int, s:Int}>, to:MBlock}> = [];
	// where the instruction being written starts (its targets are relative to it)
	var insStart = 0;

	public function new(prep, abi, obj, mf, set, compile) {
		this.prep = prep;
		this.abi = abi;
		this.obj = obj;
		this.mf = mf;
		this.set = set;
		this.compile = compile;
	}

	public function run() {
		if (abi.wasm) throw new MirBuild.Unsupported("-D hxmc.interp: not on WebAssembly");
		// the frame slots' offsets
		var slotOff = [];
		var frame = 0;
		for (s in mf.slots) {
			if (s.align > 16) throw new MirBuild.Unsupported("-D hxmc.interp: a frame slot aligned to more than 16 bytes");
			frame = (frame + s.align - 1) & ~(s.align - 1);
			slotOff.push(frame);
			frame += s.size;
		}
		frame = (frame + 15) & ~15;
		var blocks = hxmc.Driver.Layout.order(mf);
		// uses, the compares that are their branch's condition
		var uses = MFunc.ints(mf.vals.length, 0);
		for (b in blocks)
			for (i in b.ins) {
				if (i.dead) continue;
				if (i.a >= 0) uses[i.a]++;
				if (i.b >= 0) uses[i.b]++;
				if (i.c >= 0) uses[i.c]++;
				if (i.args != null)
					for (v in i.args)
						uses[v]++;
			}
		for (b in blocks) {
			var t = b.term();
			if (t != null && t.op == Br && mf.vals[t.a].op == Cmp && uses[t.a] == 1) fused.set(t.a, true);
		}
		// registers: the constants, then the other values
		reg = MFunc.ints(mf.vals.length, -1);
		for (b in blocks)
			for (i in b.ins)
				if (!i.dead) switch i.op {
					case Const if (i.sym != null):
						reg[i.id] = constant(0, 0, i.sym, i.imm);
					case Const if (i.ty == I32):
						reg[i.id] = constant(i.imm, i.imm < 0 ? -1 : 0, null, 0);
					case Const:
						reg[i.id] = constant(i.imm, i.imm2, null, 0);
					case ConstF:
						reg[i.id] = constant(haxe.io.FPHelper.doubleLow(i.f), haxe.io.FPHelper.doubleHigh(i.f), null, 0);
					case SymAddr:
						reg[i.id] = constant(0, 0, i.sym, i.imm);
					case _:
				}
		var nc = consts.length;
		if (coalesce) nregs = allocate(blocks, nc, uses) else {
			nregs = nc + mf.params.length;
			for (b in blocks)
				for (i in b.ins)
					if (i.op == Param && !i.dead) reg[i.id] = nc + i.imm;
			for (b in blocks)
				for (i in b.ins)
					if (!i.dead && reg[i.id] < 0 && i.ty != Void && !fused.exists(i.id)) reg[i.id] = nregs++;
		}
		var pcOf = new Map<Int, Int>();
		for (b in blocks) {
			pcOf.set(b.id, code.length);
			for (i in b.ins)
				if (!i.dead) {
					insStart = code.length;
					ins(i, b, slotOff);
				}
		}
		// the trampolines: an edge's moves, then its block
		for (t in tramps) {
			code[t.at] = (code.length - t.from) * 4;
			insStart = code.length;
			moveJump(t.moves, t.to);
		}
		for (f in fixups)
			code[f.at] = (pcOf.get(f.to.id) - f.from) * 4;
		// the descriptor
		var sec = obj.section(".data", SecKind.Data, 16);
		var b = sec.buf;
		b.align(16);
		var start = b.len;
		var constOff = (HEADER + 4 * code.length + 7) & ~7;
		var symOff = constOff + 8 * consts.length;
		b.u32(MAGIC);
		b.u32(nregs + scratch);
		b.u32(frame);
		b.u32(code.length);
		b.u32(symOff);
		b.u32(consts.length);
		b.u32(constOff);
		b.u32(mf.params.length);
		for (w in code)
			b.u32(w);
		b.align(8);
		for (c in consts) {
			if (c.sym != null) sec.relocs.push(new Reloc(b.len, RelKind.RAbs64, obj.sym(c.sym), c.lo));
			b.u64(c.sym != null ? 0 : c.lo, c.sym != null ? 0 : c.hi);
		}
		for (s in syms) {
			if (s.name != null) sec.relocs.push(new Reloc(b.len, RelKind.RAbs64, obj.sym(s.name), s.addend));
			b.u64(0, 0);
		}
		obj.define(DESC + mf.name, sec, start, b.len - start, true);
		entryStub();
	}

	// the program's thread-local variables (@:hxmc.threadLocal statics) when
	// code is loaded at run time (MirRun: no TLS block of its own): indices
	// of a block of the interpreter's per thread (TLSXLD, TLSXST)
	public static var emulatedTls:Null<Map<String, Int>> = null;
	// (those the running compiler has: its own, through a stub)
	public static var nativeTls:String->Bool = _ -> false;

	function tlsIndex(sym:String):Int {
		var k = emulatedTls.get(sym);
		if (k == null) {
			k = Lambda.count(emulatedTls);
			if (k >= 4096) throw new MirBuild.Unsupported("-D hxmc.mir-run: more than 4096 thread-local variables");
			emulatedTls.set(sym, k);
		}
		return k;
	}

	// (HXMC_INTERP_COALESCE=0: a register per value)
	static var coalesce = Sys.getEnv("HXMC_INTERP_COALESCE") != "0";

	// the registers of the values (after the constants): SSA coloring in
	// dominator-tree preorder, a value taking a register no value live at its
	// definition holds (an operand dying at an operation frees its register
	// for that operation's result: the interpreter reads operands first); a
	// value feeding a phi prefers the phi's register and a phi its
	// arguments', so that the edge's move goes. A value live into a try's
	// handler block keeps a register of its own: a throw resumes the frame
	// with its registers as they are. Returns the number of registers.
	function allocate(blocks:Array<MBlock>, nc:Int, uses:haxe.ds.Vector<Int>):Int {
		var vals = mf.vals;
		var wid = MFunc.ints(vals.length, -1), ids = [];
		for (b in blocks)
			for (i in b.ins)
				if (!i.dead && i.ty != Void && reg[i.id] < 0 && !fused.exists(i.id)) {
					wid[i.id] = ids.length;
					ids.push(i.id);
				}
		var n = ids.length;
		var nb = 0;
		for (b in mf.blocks)
			if (b.id >= nb) nb = b.id + 1;
		var reach = [for (_ in 0...nb) false];
		for (b in blocks)
			reach[b.id] = true;
		// the uses of an operation (a fused compare's at its branch)
		function eachUse(i:MIns, f:Int->Void) {
			if (i.op == Phi || fused.exists(i.id)) return;
			if (i.op == Br && fused.exists(i.a)) {
				var c = vals[i.a];
				if (wid[c.a] >= 0) f(c.a);
				if (wid[c.b] >= 0) f(c.b);
				return;
			}
			if (i.a >= 0 && wid[i.a] >= 0) f(i.a);
			if (i.b >= 0 && wid[i.b] >= 0) f(i.b);
			if (i.c >= 0 && wid[i.c] >= 0) f(i.c);
			if (i.args != null)
				for (v in i.args)
					if (wid[v] >= 0) f(v);
		}
		// liveness (a phi's argument: live out of its predecessor)
		var gen = [for (_ in 0...nb) new hxmc.Lir.Bits(n)];
		var kill = [for (_ in 0...nb) new hxmc.Lir.Bits(n)];
		var phiUse = [for (_ in 0...nb) new hxmc.Lir.Bits(n)];
		var liveIn = [for (_ in 0...nb) new hxmc.Lir.Bits(n)];
		var liveOut = [for (_ in 0...nb) new hxmc.Lir.Bits(n)];
		for (b in blocks) {
			var g = gen[b.id], k = kill[b.id];
			for (i in b.ins) {
				if (i.dead) continue;
				if (i.op == Phi) {
					if (wid[i.id] >= 0) k.set(wid[i.id]);
					for (pi in 0...b.preds.length) {
						var p = b.preds[pi], v = i.args[pi];
						if (reach[p.id] && wid[v] >= 0) phiUse[p.id].set(wid[v]);
					}
					continue;
				}
				eachUse(i, u -> if (!k.get(wid[u])) g.set(wid[u]));
				if (wid[i.id] >= 0) k.set(wid[i.id]);
			}
		}
		var post = blocks.copy();
		post.reverse();
		var changed = true;
		while (changed) {
			changed = false;
			for (b in post) {
				// (in place: no set made per block and pass)
				var out = liveOut[b.id], ow = out.w, pw = phiUse[b.id].w;
				for (w in 0...ow.length)
					ow[w] = pw[w];
				for (s in b.succs)
					if (reach[s.id]) out.union(liveIn[s.id]);
				var inn = liveIn[b.id], g = gen[b.id], k = kill[b.id];
				for (w in 0...inn.w.length) {
					var v = g.w[w] | (out.w[w] & ~k.w[w]);
					if (v != inn.w[w]) {
						inn.w[w] = v;
						changed = true;
					}
				}
			}
		}
		// dominators (Cooper, Harvey, Kennedy) over a reverse postorder
		var rpo = [], seen = [for (_ in 0...nb) false];
		var stack = [mf.entry], idx = [0];
		seen[mf.entry.id] = true;
		while (stack.length > 0) {
			var t = stack.length - 1, b = stack[t];
			if (idx[t] < b.succs.length) {
				var s = b.succs[idx[t]++];
				if (reach[s.id] && !seen[s.id]) {
					seen[s.id] = true;
					stack.push(s);
					idx.push(0);
				}
			} else {
				rpo.push(b);
				stack.pop();
				idx.pop();
			}
		}
		rpo.reverse();
		var num = [for (_ in 0...nb) -1];
		for (k in 0...rpo.length)
			num[rpo[k].id] = k;
		var idom:Array<Null<MBlock>> = [for (_ in 0...nb) null];
		idom[mf.entry.id] = mf.entry;
		changed = true;
		while (changed) {
			changed = false;
			for (k in 1...rpo.length) {
				var b = rpo[k];
				var d:Null<MBlock> = null;
				for (p in b.preds) {
					if (num[p.id] < 0 || idom[p.id] == null) continue;
					if (d == null) d = p else {
						var x = p, y = d;
						while (x != y) {
							while (num[x.id] > num[y.id])
								x = idom[x.id];
							while (num[y.id] > num[x.id])
								y = idom[y.id];
						}
						d = x;
					}
				}
				if (d != idom[b.id]) {
					idom[b.id] = d;
					changed = true;
				}
			}
		}
		var kids = [for (_ in 0...nb) []];
		for (k in 1...rpo.length)
			kids[idom[rpo[k].id].id].push(rpo[k]);
		// the values a try's handler reads: their own registers
		var pinned = new hxmc.Lir.Bits(n);
		for (b in blocks)
			if (b.handler) pinned.union(liveIn[b.id]);
		// a value feeding a phi: the phi
		var hint = MFunc.ints(vals.length, -1);
		for (b in blocks)
			for (i in b.ins)
				if (i.op == Phi && !i.dead)
					for (v in i.args)
						if (hint[v] < 0) hint[v] = i.id;
		var maxReg = nc + mf.params.length;
		var occ:Array<Int> = [for (_ in 0...maxReg) 0];
		var reserved:Array<Bool> = [for (_ in 0...maxReg) false];
		var reservedRegs:Array<Int> = [];
		var stamp = 0;
		var last = MFunc.ints(n, -1);
		function free():Int {
			var r = nc;
			while (r < maxReg && (occ[r] == stamp || reserved[r]))
				r++;
			if (r == maxReg) {
				maxReg++;
				occ.push(0);
				reserved.push(false);
			}
			return r;
		}
		function take(v:Int, r:Int) {
			reg[v] = r;
			occ[r] = stamp;
			if (pinned.get(wid[v]) && !reserved[r]) {
				reserved[r] = true;
				reservedRegs.push(r);
			}
		}
		function pick(v:Int, prefer:Int):Int {
			if (pinned.get(wid[v])) {
				// (a register no other value ever takes)
				maxReg++;
				occ.push(0);
				reserved.push(false);
				return maxReg - 1;
			}
			return prefer >= nc && occ[prefer] != stamp && !reserved[prefer] ? prefer : free();
		}
		var order = [mf.entry];
		while (order.length > 0) {
			var b = order.pop();
			for (c in kids[b.id])
				order.push(c);
			stamp++;
			var li = liveIn[b.id], lo = liveOut[b.id];
			// (the values live in: the set bits only)
			var lw = li.w;
			for (x in 0...lw.length) {
				var bits = lw[x];
				while (bits != 0) {
					var low = bits & -bits;
					occ[reg[ids[(x << 5) + trailingZeros(low)]]] = stamp;
					bits ^= low;
				}
			}
			for (r in reservedRegs)
				occ[r] = stamp;
			// (the parameters: written by the caller before the entry block runs)
			if (b == mf.entry)
				for (i in b.ins)
					if (i.op == Param && !i.dead && wid[i.id] >= 0) occ[nc + i.imm] = stamp;
			// the last use of each value in the block
			for (k in 0...b.ins.length) {
				var i = b.ins[k];
				if (!i.dead) eachUse(i, u -> last[wid[u]] = k);
			}
			for (k in 0...b.ins.length) {
				var i = b.ins[k];
				if (i.dead) continue;
				if (i.op == Phi) {
					if (wid[i.id] < 0) continue;
					var prefer = -1;
					for (v in i.args)
						if (reg[v] >= nc && occ[reg[v]] != stamp) prefer = reg[v];
					take(i.id, pick(i.id, prefer));
					continue;
				}
				eachUse(i, u -> {
					var w = wid[u];
					if (last[w] == k && !lo.get(w) && !pinned.get(w)) occ[reg[u]] = 0;
				});
				if (wid[i.id] < 0) continue;
				if (i.op == Param) {
					take(i.id, nc + i.imm);
				} else {
					var h = hint[i.id];
					take(i.id, pick(i.id, h >= 0 && reg[h] >= 0 ? reg[h] : -1));
				}
				// (never read: free again)
				if (uses[i.id] == 0 && !pinned.get(wid[i.id])) occ[reg[i.id]] = 0;
			}
		}
		return maxReg;
	}

	// the index of a word's only set bit
	static inline function trailingZeros(x:Int):Int {
		var t = 0;
		if (x & 0xFFFF == 0) {
			t += 16;
			x >>>= 16;
		}
		if (x & 0xFF == 0) {
			t += 8;
			x >>>= 8;
		}
		if (x & 0xF == 0) {
			t += 4;
			x >>>= 4;
		}
		if (x & 3 == 0) {
			t += 2;
			x >>>= 2;
		}
		return x & 1 == 0 ? t + 1 : t;
	}

	// a constant's register: a value (lo, hi), or a symbol's (S + A)
	function constant(lo:Int, hi:Int, sym:Null<String>, addend:Int):Int {
		var k = sym != null ? sym + "+" + addend : lo + ":" + hi;
		var i = constIndex.get(k);
		if (i == null) {
			i = consts.length;
			consts.push(sym != null ? {lo: addend, hi: 0, sym: sym} : {lo: lo, hi: hi, sym: null});
			constIndex.set(k, i);
		}
		return i;
	}

	function sym(name:String, addend:Int):Int {
		var k = name + "+" + addend;
		var i = symIndex.get(k);
		if (i == null) {
			i = syms.length;
			syms.push({name: name, addend: addend});
			symIndex.set(k, i);
		}
		return i;
	}

	// two zeroed entries of the symbol table: an inline cache
	function cacheSlot():Int {
		syms.push({name: null, addend: 0});
		syms.push({name: null, addend: 0});
		return syms.length - 2;
	}

	function r(v:Int):Int {
		var x = reg[v];
		if (x < 0) throw new MirBuild.Unsupported('-D hxmc.interp: ${mf.name}: v$v has no register');
		return x;
	}

	inline function emit(xs:Array<Int>)
		for (x in xs)
			code.push(x);

	function ty(v:Int):MTy
		return mf.vals[v].ty;

	// the moves of the edge from -> to (its block's phis), in an order that
	// reads every source before it is written (a cycle through a scratch register)
	function moves(from:MBlock, to:MBlock):Array<{d:Int, s:Int}> {
		var idx = to.preds.indexOf(from);
		var todo = [];
		for (p in to.ins)
			if (p.op == Phi && !p.dead) {
				var d = r(p.id), s = r(p.args[idx]);
				if (d != s) todo.push({d: d, s: s});
			}
		var out = [];
		var tmp = 0;
		while (todo.length > 0) {
			var k = 0;
			while (k < todo.length) {
				var m = todo[k];
				if (!Lambda.exists(todo, x -> x != m && x.s == m.d)) {
					out.push(m);
					todo.splice(k, 1);
					k = 0;
				} else
					k++;
			}
			if (todo.length > 0) {
				// a cycle: the value of one destination saved first
				var m = todo[0];
				var t = nregs + tmp++;
				if (tmp > scratch) scratch = tmp;
				out.push({d: t, s: m.d});
				for (x in todo)
					if (x.s == m.d) x.s = t;
			}
		}
		return out;
	}

	function moveJump(ms:Array<{d:Int, s:Int}>, to:MBlock) {
		switch ms.length {
			case 0:
				code.push(JMP);
			case 1:
				emit([MOVJ1, ms[0].d, ms[0].s]);
			case 2:
				emit([MOVJ2, ms[0].d, ms[0].s, ms[1].d, ms[1].s]);
			case n:
				emit([MOVJN, n]);
				for (m in ms)
					emit([m.d, m.s]);
		}
		target(to);
	}

	function target(to:MBlock) {
		fixups.push({at: code.length, from: insStart, to: to});
		code.push(-1);
	}

	// a branch's edge: its block, or a trampoline with its moves
	function edge(from:MBlock, to:MBlock) {
		code.push(-1);
		edgeAt(from, to, code.length - 1);
	}

	// (the word at `at` its target)
	function edgeAt(from:MBlock, to:MBlock, at:Int) {
		var ms = moves(from, to);
		if (ms.length == 0) fixups.push({at: at, from: insStart, to: to}) else tramps.push({at: at, from: insStart, moves: ms, to: to});
	}

	function ins(i:MIns, b:MBlock, slotOff:Array<Int>) {
		switch i.op {
			case Param | Const | ConstF | SymAddr | Phi:
			case Cmp if (fused.exists(i.id)):
			case TlsLoad:
				var t = TLS.get(i.sym);
				if (t != null) emit([TLSLD, r(i.id), t]) else if (emulatedTls != null && !nativeTls(i.sym)) emit([TLSXLD, r(i.id), tlsIndex(i.sym)]) else callOut(tlsStub(i.sym, false), r(i.id), []);
			case TlsStore:
				if (i.sym == "rt_hcur") emit([TLSST_HCUR, r(i.a), abi.handlerPrev]) else {
					var t = TLS.get(i.sym);
					if (t != null) emit([TLSST, r(i.a), t]) else if (emulatedTls != null && !nativeTls(i.sym)) emit([TLSXST, r(i.a), tlsIndex(i.sym)]) else callOut(tlsStub(i.sym, true), -1, [i.a]);
				}
			case StackAddr:
				emit([SADDR, r(i.id), slotOff[i.imm]]);
			case Copy | BitsToF | FToBits:
				emit([MOV, r(i.id), r(i.a)]);
			case Add:
				op2(ADD, i);
			case Sub:
				op2(SUB, i);
			case Mul:
				op2(MUL, i);
			case And:
				op2(AND, i);
			case Or:
				op2(OR, i);
			case Xor:
				op2(XOR, i);
			case Shl:
				op2(i.ty == I32 ? SHL32 : SHL64, i);
			case Sar:
				op2(i.ty == I32 ? SAR32 : SAR64, i);
			case Shr:
				op2(i.ty == I32 ? SHR32 : SHR64, i);
			case Div:
				op2(i.ty == I32 ? DIV32 : DIV64, i);
			case Rem:
				op2(i.ty == I32 ? REM32 : REM64, i);
			case Rotr:
				op2(i.ty == I32 ? ROTR32 : ROTR64, i);
			case FAdd:
				op2(FADD, i);
			case FSub:
				op2(FSUB, i);
			case FMul:
				op2(FMUL, i);
			case FDiv:
				op2(FDIV, i);
			case Neg:
				op1(NEG, i);
			case Not:
				op1(NOT, i);
			case FNeg:
				op1(FNEG, i);
			case FSqrt:
				op1(FSQRT, i);
			case FAbs:
				op1(FABS, i);
			case Cmp:
				op2(cmpOp(i, EQ32, EQ64, FEQ), i);
			case SExt:
				op1(SEXT, i);
			case ZExt:
				op1(ZEXT, i);
			case Trunc:
				op1(TRUNC, i);
			case I2F:
				op1(ty(i.a) == I32 ? I2F32 : I2F64, i);
			case F2I:
				op1(i.ty == I32 ? F2I32 : F2I64, i);
			case Select:
				emit([SELECT, r(i.id), r(i.a), r(i.b), r(i.c)]);
			case Load:
				var k = if (i.ty == F64) i.size == 4 ? 7 : 6 else switch i.size {
					case 1: i.signed ? 0 : 1;
					case 2: i.signed ? 2 : 3;
					case 4: i.ty == I64 && !i.signed ? 5 : 4;
					case _: 6;
				}
				if (i.b < 0) emit([(LD1S : Int) + k, r(i.id), r(i.a), i.imm]) else emit([(LDX1S : Int) + k, r(i.id), r(i.a), r(i.b), i.imm2, i.imm]);
			case Store:
				var k = if (ty(i.c) == F64 && i.size == 4) 4 else switch i.size {
					case 1: 0;
					case 2: 1;
					case 4: 2;
					case _: 3;
				}
				if (i.b < 0) emit([(ST1 : Int) + k, r(i.a), i.imm, r(i.c)]) else emit([(STX1 : Int) + k, r(i.a), r(i.b), i.imm2, i.imm, r(i.c)]);
			case Call:
				var res = i.ty == Void ? -1 : r(i.id);
				if (i.returnsTwice) emit([SETJMP, r(i.id), r(i.args[0])]) else if (i.sym != null && set.syms.exists(i.sym)) {
					emit([CALLI, sym(DESC + i.sym, 0), res, i.args.length]);
					for (a in i.args)
						code.push(r(a));
				} else if (i.sym != null) callOut(callStub(i), res, i.args) else {
					emit([CALLNI, sym(callStub(i), 0), r(i.a), res, i.args.length, cacheSlot()]);
					for (a in i.args)
						code.push(r(a));
				}
			case Jmp:
				moveJump(moves(b, i.targets[0]), i.targets[0]);
			case Br:
				var c = mf.vals[i.a];
				if (fused.exists(c.id)) emit([cmpOp(c, BEQ32, BEQ64, BFEQ), r(c.a), r(c.b)]) else emit([BR, r(i.a)]);
				edge(b, i.targets[0]);
				edge(b, i.targets[1]);
			case Switch:
				var n = i.cases.length;
				var lo = n > 0 ? i.cases[0] : 0, hi = lo;
				for (c in i.cases) {
					if (c < lo) lo = c;
					if (c > hi) hi = c;
				}
				var span = hi - lo + 1;
				if (n >= 4 && span > 0 && span <= 3 * n + 8) {
					// a table on value - lo (the values it lacks: the default)
					emit([SWITCHT, r(i.a), lo, span]);
					var at = code.length;
					for (_ in 0...span + 1)
						code.push(-1);
					for (v in 0...span) {
						var t = i.targets[n];
						for (c in 0...n)
							if (i.cases[c] == lo + v) t = i.targets[c];
						edgeAt(b, t, at + v);
					}
					edgeAt(b, i.targets[n], at + span);
				} else {
					emit([SWITCH, r(i.a), n]);
					for (k in 0...n) {
						code.push(i.cases[k]);
						edge(b, i.targets[k]);
					}
					edge(b, i.targets[n]);
				}
			case Ret:
				if (i.a >= 0) emit([RET, r(i.a)]) else code.push(RETV);
			case Unreachable:
				code.push(UNREACH);
		}
	}

	inline function op1(op:IOp, i:MIns)
		emit([op, r(i.id), r(i.a)]);

	inline function op2(op:IOp, i:MIns)
		emit([op, r(i.id), r(i.a), r(i.b)]);

	// a compare's operation (or branch): the first of its kind plus the condition
	function cmpOp(c:MIns, i32:IOp, i64:IOp, f64:IOp):Int {
		var t = ty(c.a);
		if (t == F64) {
			if (c.imm < 10) throw new MirBuild.Unsupported("-D hxmc.interp: an integer condition on doubles");
			return (f64 : Int) + c.imm - 10;
		}
		if (c.imm >= 10) throw new MirBuild.Unsupported("-D hxmc.interp: a double condition on integers");
		return (t == I64 ? (i64 : Int) : (i32 : Int)) + c.imm;
	}

	function callOut(stub:String, res:Int, args:Array<Int>) {
		emit([CALLN, sym(stub, 0), res, args.length]);
		for (a in args)
			code.push(r(a));
	}

	// ---- stubs

	function defined(name:String):Bool
		return obj.exists(name) && obj.sym(name).section != null;

	static function tyKey(t:MTy):String
		return switch t {
			case I32: "i";
			case I64: "l";
			case F64: "f";
			case Void: "v";
		}

	// the call-out stub of a call: (unused, buf) -> 0: the function at buf[0]
	// (an indirect call) called with the arguments at buf[8...], as the call
	// does it, its result written at buf[0]
	function callStub(c:MIns):String {
		var k = new StringBuf();
		k.add(c.sym != null ? c.sym : "*");
		k.add("|" + tyKey(c.ty) + "|" + [for (a in c.args) tyKey(ty(a))].join(""));
		k.add("|" + (c.argTys == null ? "" : [for (t in c.argTys) tyKey(t)].join("")));
		k.add("|" + c.cSizes + "|" + c.cGroups + "|" + (c.cRet == null ? "" : [for (p in c.cRet) p.off + ":" + p.size + ":" + p.float].join(",")));
		k.add("|" + c.variadic + "|" + c.noReturn);
		var name = STUB + haxe.crypto.Md5.encode(k.toString()).substr(0, 16);
		if (defined(name)) return name;
		var argTys = [for (a in c.args) ty(a)];
		compile(MirBuild.synthetic(prep, abi, name, [I64, I64], I64, (b, ps) -> {
			var buf = ps[1];
			var xs = [for (n in 0...argTys.length) b.load(argTys[n], argTys[n] == I32 ? 4 : 8, buf, 8 + 8 * n)];
			var x = b.mk(Call, c.ty);
			if (c.sym != null) x.sym = c.sym else x.a = b.load(I64, 8, buf, 0);
			x.args = xs;
			x.argTys = c.argTys != null ? c.argTys.copy() : [for (t in argTys) t];
			x.cSizes = c.cSizes;
			x.cGroups = c.cGroups;
			x.cRet = c.cRet;
			x.variadic = c.variadic;
			x.noReturn = c.noReturn;
			var r = b.add(x);
			if (c.noReturn) {
				b.add(b.mk(Unreachable, Void));
				return;
			}
			if (c.ty != Void) b.store(c.ty == I32 ? 4 : 8, buf, 0, r);
			b.ret(b.lconst(0, 0));
		}), false);
		return name;
	}

	// a thread-local variable of the program's (@:hxmc.threadLocal) read or set
	function tlsStub(tls:String, set:Bool):String {
		var name = STUB + (set ? "tset$" : "tget$") + tls;
		if (defined(name)) return name;
		compile(MirBuild.synthetic(prep, abi, name, [I64, I64], I64, (b, ps) -> {
			if (set) b.tlsStore(tls, b.load(I64, 8, ps[1], 8)) else b.store(8, ps[1], 0, b.tlsLoad(tls));
			b.ret(b.lconst(0, 0));
		}), false);
		return name;
	}

	// the function's own symbol: its arguments into a buffer of 8-byte
	// words, the interpreter, its result from the buffer
	function entryStub() {
		var params = mf.params, ret = mf.ret;
		var desc = DESC + mf.name;
		compile(MirBuild.synthetic(prep, abi, mf.name, params, ret, (b, ps) -> {
			var buf = b.stackAddr(b.f.slot(8 * (params.length > 0 ? params.length : 1), 16));
			for (n in 0...params.length)
				b.store(params[n] == I32 ? 4 : 8, buf, 8 * n, ps[n]);
			b.call("hxmc_interp_enter", [b.symAddr(desc), buf], Void);
			b.ret(ret == Void ? -1 : b.load(ret, ret == I32 ? 4 : 8, buf, 0));
		}), true);
	}
}
