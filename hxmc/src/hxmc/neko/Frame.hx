package hxmc.neko;

import haxe.ds.Vector;
import hxmc.neko.Module.Op;
import hxmc.neko.Value;

// The code the interpreter runs (VM.interp): Neko's, translated once per
// module. Neko's stack depth at each instruction is fixed (neko_check_stack
// verifies it), so a stack access is a slot of the frame (its base: the
// first argument), a push a store to the slot at the depth, a pop nothing;
// an instruction taking its operands from the stack has the depth. The
// frame's slots are reserved when the function is entered (frameMax), the
// VM's sp kept above them (a call sets it to the arguments' top). Common
// sequences are one instruction (no instruction but the first a jump's
// target): a value pushed, an operation with a constant, a comparison that
// jumps, a static's method called.
class F {
	public static inline var ANULL = 0;
	public static inline var ATRUE = 1;
	public static inline var AFALSE = 2;
	public static inline var ATHIS = 3;
	public static inline var ACONST = 4; // k: consts' index
	public static inline var ASLOT = 5; // s
	public static inline var AGLOBAL = 6; // g
	public static inline var AENV = 7; // i
	public static inline var AFIELD = 8; // id
	public static inline var AARRAY = 9; // d
	public static inline var AINDEX = 10; // i
	public static inline var SSLOT = 11; // s
	public static inline var SGLOBAL = 12; // g
	public static inline var SENV = 13; // i
	public static inline var SFIELD = 14; // id, d
	public static inline var SARRAY = 15; // d
	public static inline var SINDEX = 16; // i, d
	public static inline var STHIS = 17;
	public static inline var PUSH = 18; // d
	public static inline var CALL = 19; // n, d
	public static inline var OBJCALL = 20; // n, d
	public static inline var JUMP = 21; // t
	public static inline var JIF = 22; // t
	public static inline var JIFNOT = 23; // t
	public static inline var TRAP = 24; // handler, d
	public static inline var ENDTRAP = 25; // d
	public static inline var RET = 26;
	public static inline var MAKEENV = 27; // n, d
	public static inline var MAKEARRAY = 28; // n, d
	public static inline var MAKEARRAY2 = 29; // n, d
	public static inline var BOOL = 30;
	public static inline var ISNULL = 31;
	public static inline var ISNOTNULL = 32;
	public static inline var NOT = 33;
	public static inline var TYPEOF = 34;
	public static inline var HASH = 35;
	public static inline var NEW = 36;
	public static inline var ADD = 37; // d
	public static inline var SUB = 38; // d
	public static inline var MULT = 39; // d
	public static inline var DIV = 40; // d
	public static inline var MOD = 41; // d
	public static inline var BITOP = 42; // op, d
	public static inline var CMP = 43; // op, d
	public static inline var COMPARE = 44; // d
	public static inline var PHYSCMP = 45; // d
	public static inline var JUMPTABLE = 46; // n, default, n targets
	public static inline var APPLY = 47; // n, d
	public static inline var TAILCALL = 48; // n, d
	public static inline var LAST = 49;
	public static inline var COPYPUSH = 50; // s, d
	public static inline var CONSTPUSH = 51; // k, d
	public static inline var GLOBALPUSH = 52; // g, d
	public static inline var OPIMM = 53; // op, k, kidx
	public static inline var CMPJUMP = 54; // op, flag (1: JumpIf), t, d
	public static inline var OPIMMJUMP = 55; // op, flag, k, kidx, t
	public static inline var CALLGF = 56; // g, id, n, d
	// (Frame.peephole: in the slots of the instructions they replace, the
	// last operand the length to skip)
	public static inline var SLOTOPIMM = 57; // s, op, k, kidx, len
	public static inline var SLOTOPIMMJUMP = 58; // s, op, flag, k, kidx, t, (len)
	public static inline var OPIMMPUSH = 59; // op, k, kidx, d, len
	public static inline var SLOTOPIMMPUSH = 60; // s, op, k, kidx, d, len
	public static inline var SLOTRET = 61; // s
	public static inline var CALLGFPUSH = 62; // g, id, n, d, d2, len
	public static inline var CALLPUSH = 63; // n, d, d2, len

	// an instruction's slots
	public static function size(code:Array<Int>, pc:Int):Int {
		return switch code[pc] {
			case ANULL | ATRUE | AFALSE | ATHIS | STHIS | RET | LAST | BOOL | ISNULL | ISNOTNULL | NOT | TYPEOF | HASH | NEW: 1;
			case ACONST | ASLOT | AGLOBAL | AENV | AFIELD | AARRAY | AINDEX | SSLOT | SGLOBAL | SENV | SARRAY | PUSH | JUMP | JIF | JIFNOT | ENDTRAP | ADD | SUB |
				MULT | DIV | MOD | COMPARE | PHYSCMP: 2;
			case SFIELD | SINDEX | CALL | OBJCALL | TRAP | MAKEENV | MAKEARRAY | MAKEARRAY2 | BITOP | CMP | APPLY | TAILCALL | COPYPUSH | CONSTPUSH | GLOBALPUSH: 3;
			case OPIMM: 4;
			case CMPJUMP | CALLGF: 5;
			case OPIMMJUMP: 6;
			case JUMPTABLE: 3 + code[pc + 1];
			case op: throw "Frame.size: " + op;
		}
	}
}

class Frame {
	static inline function isCmp(op:Int):Bool
		return op == Op.Lt || op == Op.Lte || op == Op.Gt || op == Op.Gte || op == Op.Eq || op == Op.Neq;

	static inline function isImmOp(op:Int):Bool
		return op == Op.Add || op == Op.Sub || op == Op.Mult || isCmp(op);

	// the change of the depth (neko's stack_table; P: the parameter)
	// sequences of the translated code as one instruction, where no
	// instruction but the first is a jump's target
	static function peephole(code:Array<Int>, entries:Array<Int>) {
		var target = new Map<Int, Bool>();
		for (e in entries)
			target.set(e, true);
		var pc = 0;
		while (pc < code.length) {
			switch code[pc] {
				case F.JUMP | F.JIF | F.JIFNOT | F.TRAP:
					target.set(code[pc + 1], true);
				case F.CMPJUMP:
					target.set(code[pc + 3], true);
				case F.OPIMMJUMP:
					target.set(code[pc + 5], true);
				case F.JUMPTABLE:
					for (k in 0...code[pc + 1] + 1)
						target.set(code[pc + 2 + k], true);
				case _:
			}
			pc += F.size(code, pc);
		}
		inline function at(k:Int, op:Int):Bool
			return k < code.length && code[k] == op && !target.exists(k);
		pc = 0;
		while (pc < code.length) {
			var n = F.size(code, pc);
			switch code[pc] {
				case F.ASLOT:
					var s = code[pc + 1], q = pc + 2;
					if (at(q, F.OPIMMJUMP)) {
						// s, op, flag, k, kidx, t (8 slots)
						var op = code[q + 1], flag = code[q + 2], k = code[q + 3], kidx = code[q + 4], t = code[q + 5];
						code[pc] = F.SLOTOPIMMJUMP;
						code[pc + 1] = s;
						code[pc + 2] = op;
						code[pc + 3] = flag;
						code[pc + 4] = k;
						code[pc + 5] = kidx;
						code[pc + 6] = t;
						n = 8;
					} else if (at(q, F.OPIMM)) {
						var op = code[q + 1], k = code[q + 2], kidx = code[q + 3];
						if (at(q + 4, F.PUSH)) {
							var d = code[q + 5];
							code[pc] = F.SLOTOPIMMPUSH;
							code[pc + 1] = s;
							code[pc + 2] = op;
							code[pc + 3] = k;
							code[pc + 4] = kidx;
							code[pc + 5] = d;
							code[pc + 6] = 8;
							n = 8;
						} else {
							code[pc] = F.SLOTOPIMM;
							code[pc + 1] = s;
							code[pc + 2] = op;
							code[pc + 3] = k;
							code[pc + 4] = kidx;
							code[pc + 5] = 6;
							n = 6;
						}
					} else if (at(q, F.RET)) {
						code[pc] = F.SLOTRET;
						n = 3;
					}
				case F.OPIMM if (at(pc + 4, F.PUSH)):
					var d = code[pc + 5];
					code[pc] = F.OPIMMPUSH;
					code[pc + 4] = d;
					code[pc + 5] = 6;
					n = 6;
				case F.CALLGF if (at(pc + 5, F.PUSH)):
					var d2 = code[pc + 6];
					code[pc] = F.CALLGFPUSH;
					code[pc + 5] = d2;
					code[pc + 6] = 7;
					n = 7;
				case F.CALL if (at(pc + 3, F.PUSH)):
					var d2 = code[pc + 4];
					code[pc] = F.CALLPUSH;
					code[pc + 3] = d2;
					code[pc + 4] = 5;
					n = 5;
				case _:
			}
			pc += n;
		}
	}

	static function effect(c:Int, p:Int):Int {
		return switch c {
			case Op.AccArray | Op.SetField | Op.SetIndex | Op.Compare | Op.PhysCompare: -1;
			case Op.SetArray: -2;
			case Op.Push: 1;
			case Op.Pop | Op.Call | Op.MakeEnv | Op.MakeArray | Op.MakeArray2 | Op.Apply: -p;
			case Op.ObjCall: -p - 1;
			case Op.Trap: 6;
			case Op.EndTrap: -6;
			case _ if (c >= Op.Add && c <= Op.Lte): -1;
			case _: 0;
		}
	}

	static inline function invalid():Dynamic
		throw new Module.ReadError();

	public static function translate(m:Module, code:Vector<Int>, codesize:Int, funcs:Array<NFun>) {
		inline function len(i:Int):Int
			return Op.hasParam[code[i]] ? 2 : 1;
		// ---- the depths, from the entries (each function's frame size)
		var depth = new Vector<Int>(codesize + 1, -1);
		var entries = [0].concat([for (f in funcs) f.addr]);
		var entryArgs = [0].concat([for (f in funcs) f.nargs]);
		var frameOf = new Map<Int, Int>();
		for (e in 0...entries.length) {
			var max = entryArgs[e];
			var work = [entries[e], entryArgs[e]];
			while (work.length > 0) {
				var d = work.pop(), i = work.pop();
				while (true) {
					if (i > codesize) invalid();
					if (depth[i] >= 0) {
						if (depth[i] != d) invalid();
						break;
					}
					depth[i] = d;
					if (d > max) max = d;
					var c = code[i], p = code[i + 1];
					if (c == Op.Last || c == Op.Ret || c == Op.TailCall) break;
					if (c == Op.Jump) {
						work.push(p);
						work.push(d);
						break;
					}
					if (c == Op.JumpIf || c == Op.JumpIfNot) {
						work.push(p);
						work.push(d);
					}
					if (c == Op.Trap) {
						work.push(p);
						work.push(d);
					}
					if (c == Op.JumpTable) {
						for (k in 0...p) {
							work.push(i + 2 + 2 * k);
							work.push(d);
						}
						i = i + 2 + 2 * p;
						continue;
					}
					d += effect(c, p);
					if (d < 0) invalid();
					if (d > max) max = d;
					i += len(i);
				}
			}
			frameOf.set(entries[e], max + 1);
		}
		// ---- jump targets: a sequence is fused only where its later instructions are none
		var target = new Vector<Bool>(codesize + 1, false);
		for (e in entries)
			target[e] = true;
		var i = 0;
		while (i < codesize) {
			var c = code[i];
			switch c {
				case Op.Jump | Op.JumpIf | Op.JumpIfNot | Op.Trap:
					target[code[i + 1]] = true;
				case Op.JumpTable:
					for (k in 0...code[i + 1] + 1)
						if (i + 2 + 2 * k <= codesize) target[i + 2 + 2 * k] = true;
				case _:
			}
			i += len(i);
		}
		// ---- the translation
		var out:Array<Int> = [];
		var oldOf:Array<Int> = [];
		var map = new Vector<Int>(codesize + 1, -1);
		var fix:Array<Int> = []; // (operand position, old target)
		inline function op(k:Int):Int
			return k < codesize ? code[k] : Op.Last;
		inline function free(k:Int):Bool
			return k < codesize && !target[k] && depth[k] >= 0;
		function emit(i:Int, xs:Array<Int>) {
			oldOf.push(i);
			for (k in 1...xs.length)
				oldOf.push(i);
			for (x in xs)
				out.push(x);
		}
		function jumpTo(old:Int) {
			fix.push(out.length);
			fix.push(old);
			out.push(-1);
			oldOf.push(oldOf[oldOf.length - 1]);
		}
		i = 0;
		while (i < codesize) {
			var c = code[i], p = code[i + 1], d = depth[i];
			var n = len(i);
			map[i] = out.length;
			if (d < 0) {
				// (unreachable)
				i += n;
				continue;
			}
			inline function slotOf(nn:Int):Int
				return d - 1 - nn;
			// a Push followed by a constant and an operation (and a jump)
			var immAfter = (k:Int) -> free(k) && op(k) == Op.Push && free(k + 1) && op(k + 1) == Op.AccInt && free(k + 3) && isImmOp(op(k + 3))
				&& Tag.isInt(m.consts[code[k + 2]]);
			switch c {
				case Op.AccNull:
					emit(i, [F.ANULL]);
				case Op.AccTrue:
					emit(i, [F.ATRUE]);
				case Op.AccFalse:
					emit(i, [F.AFALSE]);
				case Op.AccThis:
					emit(i, [F.ATHIS]);
				case Op.AccInt | Op.AccBuiltin:
					if (free(i + 2) && op(i + 2) == Op.Push && !immAfter(i + 2)) {
						emit(i, [F.CONSTPUSH, p, d]);
						n = 3;
					} else
						emit(i, [F.ACONST, p]);
				case Op.AccStack | Op.AccStack0 | Op.AccStack1:
					var s = c == Op.AccStack0 ? slotOf(0) : c == Op.AccStack1 ? slotOf(1) : slotOf(p);
					if (s < 0) invalid();
					if (free(i + n) && op(i + n) == Op.Push && !immAfter(i + n)) {
						emit(i, [F.COPYPUSH, s, d]);
						n += 1;
					} else
						emit(i, [F.ASLOT, s]);
				case Op.AccGlobal:
					// (a static's method called: AccGlobal g, Push, AccField f, ObjCall n)
					if (free(i + 2) && op(i + 2) == Op.Push && free(i + 3) && op(i + 3) == Op.AccField && free(i + 5) && op(i + 5) == Op.ObjCall) {
						emit(i, [F.CALLGF, p, code[i + 4], code[i + 6], d]);
						n = 7;
					} else if (free(i + 2) && op(i + 2) == Op.Push && !immAfter(i + 2)) {
						emit(i, [F.GLOBALPUSH, p, d]);
						n = 3;
					} else
						emit(i, [F.AGLOBAL, p]);
				case Op.AccEnv:
					emit(i, [F.AENV, p]);
				case Op.AccField:
					emit(i, [F.AFIELD, p]);
				case Op.AccArray:
					emit(i, [F.AARRAY, d]);
				case Op.AccIndex:
					emit(i, [F.AINDEX, p]);
				case Op.AccIndex0:
					emit(i, [F.AINDEX, 0]);
				case Op.AccIndex1:
					emit(i, [F.AINDEX, 1]);
				case Op.SetStack:
					if (slotOf(p) < 0) invalid();
					emit(i, [F.SSLOT, slotOf(p)]);
				case Op.SetGlobal:
					emit(i, [F.SGLOBAL, p]);
				case Op.SetEnv:
					emit(i, [F.SENV, p]);
				case Op.SetField:
					emit(i, [F.SFIELD, p, d]);
				case Op.SetArray:
					emit(i, [F.SARRAY, d]);
				case Op.SetIndex:
					emit(i, [F.SINDEX, p, d]);
				case Op.SetThis:
					emit(i, [F.STHIS]);
				case Op.Push:
					if (immAfter(i)) {
						var k:Int = m.consts[code[i + 2]];
						var cmp = op(i + 3);
						if (isCmp(cmp) && free(i + 4) && (op(i + 4) == Op.JumpIf || op(i + 4) == Op.JumpIfNot)) {
							emit(i, [F.OPIMMJUMP, cmp, op(i + 4) == Op.JumpIf ? 1 : 0, k, code[i + 2]]);
							jumpTo(code[i + 5]);
							n = 6;
						} else {
							emit(i, [F.OPIMM, cmp, k, code[i + 2]]);
							n = 4;
						}
					} else
						emit(i, [F.PUSH, d]);
				case Op.Pop | Op.Loop:
				case Op.Call:
					emit(i, [F.CALL, p, d]);
				case Op.ObjCall:
					emit(i, [F.OBJCALL, p, d]);
				case Op.Jump:
					emit(i, [F.JUMP]);
					jumpTo(p);
				case Op.JumpIf:
					emit(i, [F.JIF]);
					jumpTo(p);
				case Op.JumpIfNot:
					emit(i, [F.JIFNOT]);
					jumpTo(p);
				case Op.Trap:
					emit(i, [F.TRAP]);
					jumpTo(p);
					out.push(d);
					oldOf.push(i);
				case Op.EndTrap:
					emit(i, [F.ENDTRAP, d]);
				case Op.Ret:
					emit(i, [F.RET]);
				case Op.MakeEnv:
					emit(i, [F.MAKEENV, p, d]);
				case Op.MakeArray:
					emit(i, [F.MAKEARRAY, p, d]);
				case Op.MakeArray2:
					emit(i, [F.MAKEARRAY2, p, d]);
				case Op.Bool:
					emit(i, [F.BOOL]);
				case Op.IsNull:
					emit(i, [F.ISNULL]);
				case Op.IsNotNull:
					emit(i, [F.ISNOTNULL]);
				case Op.Not:
					emit(i, [F.NOT]);
				case Op.TypeOf:
					emit(i, [F.TYPEOF]);
				case Op.Hash:
					emit(i, [F.HASH]);
				case Op.New:
					emit(i, [F.NEW]);
				case Op.Add:
					emit(i, [F.ADD, d]);
				case Op.Sub:
					emit(i, [F.SUB, d]);
				case Op.Mult:
					emit(i, [F.MULT, d]);
				case Op.Div:
					emit(i, [F.DIV, d]);
				case Op.Mod:
					emit(i, [F.MOD, d]);
				case Op.Shl | Op.Shr | Op.UShr | Op.Or | Op.And | Op.Xor:
					emit(i, [F.BITOP, c, d]);
				case Op.Eq | Op.Neq | Op.Lt | Op.Lte | Op.Gt | Op.Gte:
					if (free(i + 1) && (op(i + 1) == Op.JumpIf || op(i + 1) == Op.JumpIfNot)) {
						emit(i, [F.CMPJUMP, c, op(i + 1) == Op.JumpIf ? 1 : 0]);
						jumpTo(code[i + 2]);
						out.push(d);
						oldOf.push(i);
						n = 3;
					} else
						emit(i, [F.CMP, c, d]);
				case Op.Compare:
					emit(i, [F.COMPARE, d]);
				case Op.PhysCompare:
					emit(i, [F.PHYSCMP, d]);
				case Op.JumpTable:
					emit(i, [F.JUMPTABLE, p]);
					jumpTo(i + 2 + 2 * p);
					for (k in 0...p)
						jumpTo(i + 2 + 2 * k);
				case Op.Apply:
					emit(i, [F.APPLY, p, d]);
				case Op.TailCall:
					emit(i, [F.TAILCALL, p & 7, d]);
				case Op.Last:
					emit(i, [F.LAST]);
				case _:
					invalid();
			}
			i += n;
		}
		map[codesize] = out.length;
		emit(codesize, [F.LAST]);
		var k = 0;
		while (k < fix.length) {
			var t = map[fix[k + 1]];
			if (t < 0) invalid();
			out[fix[k]] = t;
			k += 2;
		}
		peephole(out, [for (e in entries) map[e]]);
		var frameMax = new Vector<Int>(out.length + 1, 0);
		for (e => size in frameOf)
			frameMax[map[e]] = size;
		for (f in funcs)
			f.addr = map[f.addr];
		m.vcode = Vector.fromArrayCopy(out);
		m.oldOf = Vector.fromArrayCopy(oldOf);
		m.frameMax = frameMax;
		m.icObj = new Vector(out.length + 1);
		m.icIdx = new Vector(out.length + 1, 0);
	}
}
