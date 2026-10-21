/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package generators;

import haxe.ds.IntMap;
import haxe.ds.StringMap;
import haxe.ds.Vector;
import generators.Hlcode;
import generators.Hlcode.*;

// port: `Set.Make(struct let compare a b = b - a type t = int end)`: an immutable
// set of ints, kept sorted in that order (decreasing ints).
abstract ISet(Array<Int>) {
	inline function new(a:Array<Int>) this = a;

	public static final empty:ISet = new ISet([]);

	public function mem(r:Int):Bool return this.indexOf(r) >= 0;

	public function add(r:Int):ISet {
		var i = 0;
		while (i < this.length && this[i] > r) i++;
		if (i < this.length && this[i] == r) return cast this;
		var a = this.copy();
		a.insert(i, r);
		return new ISet(a);
	}

	public function union(s:ISet):ISet {
		var b:Array<Int> = cast s;
		var out = [];
		var i = 0, j = 0;
		while (i < this.length || j < b.length) {
			if (j == b.length || (i < this.length && this[i] > b[j])) out.push(this[i++]) else if (i == this.length || b[j] > this[i])
				out.push(b[j++]) else {
				out.push(this[i]);
				i++;
				j++;
			}
		}
		return new ISet(out);
	}

	public function filter(f:Int->Bool):ISet return new ISet([for (r in this) if (f(r)) r]);

	public function elements():Array<Int> return this.copy();
}

enum CurValue {
	VUndef;
	VReg(r:Int);
}

class RegState {
	public var rindex:Int;
	public var ralias:RegState;
	public var rbind:Array<RegState>; // port: list, head first
	public var rnullcheck:Bool;

	public function new(rindex:Int) {
		this.rindex = rindex;
		this.ralias = this;
		this.rbind = [];
		this.rnullcheck = false;
	}
}

class Block {
	public final bstart:Int;
	public var bend:Int = 0;
	public var bnext:Array<Block> = []; // port: lists, head first
	public var bprev:Array<Block> = [];
	public var bloop:Bool = false;
	public var bstate:Null<Vector<RegState>> = null;
	public var bneed:ISet = ISet.empty;
	public var bneedAll:Null<ISet> = null;
	public var bwrite:IntMap<Int> = new IntMap(); // port: (int, int) PMap.t
	public var btrap:Array<Int>; // port: int list, head first

	public function new(bstart:Int, btrap:Array<Int>) {
		this.bstart = bstart;
		this.btrap = btrap;
	}
}

enum Control {
	CNo;
	CJCond(d:Int);
	CJAlways(d:Int);
	CTry(d:Int);
	CCatch;
	CSwitch(cases:Vector<Int>);
	CRet;
	CThrow;
	CLabel;
}

typedef Rctx = {
	var rRoot:Block;
	var rUsedRegs:Int;
	var rNopCount:Int;
	var rBlocksPos:IntMap<Block>;
	var rRegMoved:IntMap<{reg:Int, lastW:Int}>; // port: Hashtbl.add/find: the most recent binding
	var rLiveBits:Vector<Int>;
	var rRegMap:Vector<Int>;
}

typedef CacheElt = {
	var cCode:Vector<Opcode>;
	var cRctx:Rctx;
	var cRemapIndexes:Vector<Int>;
	var cLastUsed:Int;
}

class Hlopt {
	public static function control(op:Opcode):Control {
		return switch op {
			case OJTrue(_, d) | OJFalse(_, d) | OJNull(_, d) | OJNotNull(_, d) | OJSLt(_, _, d) | OJSGte(_, _, d) | OJSGt(_, _, d) | OJSLte(_, _, d) |
				OJULt(_, _, d) | OJUGte(_, _, d) | OJEq(_, _, d) | OJNotEq(_, _, d) | OJNotLt(_, _, d) | OJNotGte(_, _, d):
				CJCond(d);
			case OJAlways(d):
				CJAlways(d);
			case OLabel(_):
				CLabel;
			case ORet(_):
				CRet;
			case OThrow(_) | ORethrow(_) | OAssert(_):
				CThrow;
			case OSwitch(_, cases, _):
				CSwitch(cases);
			case OTrap(_, d):
				CTry(d);
			case OEndTrap(_):
				CCatch;
			case _:
				CNo;
		}
	}

	public static function opcodeFx(frw:Int->Bool->Void, op:Opcode):Void {
		inline function read(r:Int) frw(r, true);
		inline function write(r:Int) frw(r, false);
		switch op {
			case OMov(d, a) | ONeg(d, a) | ONot(d, a):
				read(a);
				write(d);
			case OInt(d, _) | OFloat(d, _) | OBool(d, _) | OBytes(d, _) | OString(d, _) | ONull(d):
				write(d);
			case OAdd(d, a, b) | OSub(d, a, b) | OMul(d, a, b) | OSDiv(d, a, b) | OUDiv(d, a, b) | OSMod(d, a, b) | OUMod(d, a, b) | OShl(d, a, b) |
				OSShr(d, a, b) | OUShr(d, a, b) | OAnd(d, a, b) | OOr(d, a, b) | OXor(d, a, b):
				read(a);
				read(b);
				write(d);
			case OIncr(a) | ODecr(a):
				read(a);
				write(a);
			case OCall0(d, _):
				write(d);
			case OCall1(d, _, a):
				read(a);
				write(d);
			case OCall2(d, _, a, b):
				read(a);
				read(b);
				write(d);
			case OCall3(d, _, a, b, c):
				read(a);
				read(b);
				read(c);
				write(d);
			case OCall4(d, _, a, b, c, k):
				read(a);
				read(b);
				read(c);
				read(k);
				write(d);
			case OCallN(d, _, rl) | OCallMethod(d, _, rl) | OCallThis(d, _, rl):
				for (r in rl) read(r);
				write(d);
			case OCallClosure(d, f, rl):
				read(f);
				for (r in rl) read(r);
				write(d);
			case OStaticClosure(d, _):
				write(d);
			case OInstanceClosure(d, _, a) | OVirtualClosure(d, a, _):
				read(a);
				write(d);
			case OGetGlobal(d, _):
				write(d);
			case OSetGlobal(_, a):
				read(a);
			case OField(d, a, _) | ODynGet(d, a, _):
				read(a);
				write(d);
			case OSetField(a, _, b) | ODynSet(a, _, b):
				read(a);
				read(b);
			case OGetThis(d, _):
				write(d);
			case OSetThis(_, a):
				read(a);
			case OJTrue(r, _) | OJFalse(r, _) | OJNull(r, _) | OJNotNull(r, _):
				read(r);
			case OJSLt(a, b, _) | OJSGte(a, b, _) | OJSGt(a, b, _) | OJSLte(a, b, _) | OJULt(a, b, _) | OJUGte(a, b, _) | OJNotLt(a, b, _) |
				OJNotGte(a, b, _) | OJEq(a, b, _) | OJNotEq(a, b, _):
				read(a);
				read(b);
			case OJAlways(_) | OLabel(_):
			case OToDyn(d, a) | OToSFloat(d, a) | OToUFloat(d, a) | OToInt(d, a) | OSafeCast(d, a) | OUnsafeCast(d, a) | OToVirtual(d, a):
				read(a);
				write(d);
			case ORet(r) | OThrow(r) | ORethrow(r) | OSwitch(r, _, _) | ONullCheck(r):
				read(r);
			case OTrap(r, _):
				write(r);
			case OEndTrap(_):
				/* ??? */
			case OGetUI8(d, a, b) | OGetUI16(d, a, b) | OGetMem(d, a, b) | OGetArray(d, a, b):
				read(a);
				read(b);
				write(d);
			case OSetUI8(a, b, c) | OSetUI16(a, b, c) | OSetMem(a, b, c) | OSetArray(a, b, c):
				read(a);
				read(b);
				read(c);
			case ONew(d):
				write(d);
			case OArraySize(d, a) | OGetType(d, a) | OGetTID(d, a) | OUnref(d, a) | OSetref(d, a) | OEnumIndex(d, a) | OEnumField(d, a, _, _):
				read(a);
				write(d);
			case ORef(d, a):
				read(a);
				write(a); /* prevent issue with 'a' being reused later - this is not exact as it can be set everytime we pass it to a function */
				write(d);
			case OType(d, _) | OEnumAlloc(d, _):
				write(d);
			case OMakeEnum(d, _, rl):
				for (r in rl) read(r);
				write(d);
			case OSetEnumField(a, _, b):
				read(a);
				read(b);
			case OAssert(_):
			case ORefData(r, d):
				read(d);
				write(r);
			case ORefOffset(r, r2, off):
				read(r2);
				read(off);
				write(r);
			case ONop(_):
			case OPrefetch(r, _, _):
				read(r);
			case OAsm(_, _, r):
				if (r > 0) {
					/* assume both */
					read(r - 1);
					write(r - 1);
				}
			case OCatch(_):
		}
	}

	// port: OCaml `a = b` on opcodes (dump only); `OType` compares its type physically.
	public static function opcodeEq(a:Opcode, b:Opcode):Bool {
		return switch [a, b] {
			case [OType(r1, t1), OType(r2, t2)]:
				r1 == r2 && t1 == t2;
			case _:
				Type.enumIndex(a) == Type.enumIndex(b) && ostr(Std.string, a) == ostr(Std.string, b) && switch [a, b] {
					case [OCallMethod(r1, f1, _), OCallMethod(r2, f2, _)]: r1 == r2 && f1 == f2;
					case _: true;
				}
		}
	}

	public static function opcodeMap(read:Int->Int, write:Int->Int, op:Opcode):Opcode {
		return switch op {
			case OMov(d, a):
				var a = read(a);
				OMov(write(d), a);
			case ONeg(d, a):
				var a = read(a);
				ONeg(write(d), a);
			case ONot(d, a):
				var a = read(a);
				ONot(write(d), a);
			case OInt(d, idx):
				OInt(write(d), idx);
			case OFloat(d, idx):
				OFloat(write(d), idx);
			case OBool(d, idx):
				OBool(write(d), idx);
			case OBytes(d, idx):
				OBytes(write(d), idx);
			case OString(d, idx):
				OString(write(d), idx);
			case ONull(d):
				ONull(write(d));
			case OAdd(d, a, b):
				var a = read(a), b = read(b);
				OAdd(write(d), a, b);
			case OSub(d, a, b):
				var a = read(a), b = read(b);
				OSub(write(d), a, b);
			case OMul(d, a, b):
				var a = read(a), b = read(b);
				OMul(write(d), a, b);
			case OSDiv(d, a, b):
				var a = read(a), b = read(b);
				OSDiv(write(d), a, b);
			case OUDiv(d, a, b):
				var a = read(a), b = read(b);
				OUDiv(write(d), a, b);
			case OSMod(d, a, b):
				var a = read(a), b = read(b);
				OSMod(write(d), a, b);
			case OUMod(d, a, b):
				var a = read(a), b = read(b);
				OUMod(write(d), a, b);
			case OShl(d, a, b):
				var a = read(a), b = read(b);
				OShl(write(d), a, b);
			case OSShr(d, a, b):
				var a = read(a), b = read(b);
				OSShr(write(d), a, b);
			case OUShr(d, a, b):
				var a = read(a), b = read(b);
				OUShr(write(d), a, b);
			case OAnd(d, a, b):
				var a = read(a), b = read(b);
				OAnd(write(d), a, b);
			case OOr(d, a, b):
				var a = read(a), b = read(b);
				OOr(write(d), a, b);
			case OXor(d, a, b):
				var a = read(a), b = read(b);
				OXor(write(d), a, b);
			case OIncr(a):
				OIncr(write(a));
			case ODecr(a):
				ODecr(write(a));
			case OCall0(d, f):
				OCall0(write(d), f);
			case OCall1(d, f, a):
				var a = read(a);
				OCall1(write(d), f, a);
			case OCall2(d, f, a, b):
				var a = read(a);
				var b = read(b);
				OCall2(write(d), f, a, b);
			case OCall3(d, f, a, b, c):
				var a = read(a);
				var b = read(b);
				var c = read(c);
				OCall3(write(d), f, a, b, c);
			case OCall4(w, f, a, b, c, d):
				var a = read(a);
				var b = read(b);
				var c = read(c);
				var d = read(d);
				OCall4(write(w), f, a, b, c, d);
			case OCallN(d, f, rl):
				var rl = [for (r in rl) read(r)];
				OCallN(write(d), f, rl);
			case OCallMethod(d, f, rl):
				var rl = [for (r in rl) read(r)];
				OCallMethod(write(d), f, rl);
			case OCallThis(d, f, rl):
				var rl = [for (r in rl) read(r)];
				OCallThis(write(d), f, rl);
			case OCallClosure(d, f, rl):
				var f = read(f);
				var rl = [for (r in rl) read(r)];
				OCallClosure(write(d), f, rl);
			case OStaticClosure(d, f):
				OStaticClosure(write(d), f);
			case OInstanceClosure(d, f, a):
				var a = read(a);
				OInstanceClosure(write(d), f, a);
			case OVirtualClosure(d, a, f):
				var a = read(a);
				OVirtualClosure(write(d), a, f);
			case OGetGlobal(d, g):
				OGetGlobal(write(d), g);
			case OSetGlobal(g, r):
				OSetGlobal(g, read(r));
			case OField(d, a, f):
				var a = read(a);
				OField(write(d), a, f);
			case ODynGet(d, a, f):
				var a = read(a);
				ODynGet(write(d), a, f);
			case OSetField(a, f, b):
				var b2 = read(b);
				OSetField(read(a), f, b2);
			case ODynSet(a, f, b):
				var b2 = read(b);
				ODynSet(read(a), f, b2);
			case OGetThis(d, f):
				OGetThis(write(d), f);
			case OSetThis(f, a):
				OSetThis(f, read(a));
			case OJTrue(r, d):
				OJTrue(read(r), d);
			case OJFalse(r, d):
				OJFalse(read(r), d);
			case OJNull(r, d):
				OJNull(read(r), d);
			case OJNotNull(r, d):
				OJNotNull(read(r), d);
			case OJSLt(a, b, d):
				var b2 = read(b);
				OJSLt(read(a), b2, d);
			case OJSGte(a, b, d):
				var b2 = read(b);
				OJSGte(read(a), b2, d);
			case OJSGt(a, b, d):
				var b2 = read(b);
				OJSGt(read(a), b2, d);
			case OJSLte(a, b, d):
				var b2 = read(b);
				OJSLte(read(a), b2, d);
			case OJULt(a, b, d):
				var b2 = read(b);
				OJULt(read(a), b2, d);
			case OJUGte(a, b, d):
				var b2 = read(b);
				OJUGte(read(a), b2, d);
			case OJNotLt(a, b, d):
				var b2 = read(b);
				OJNotLt(read(a), b2, d);
			case OJNotGte(a, b, d):
				var b2 = read(b);
				OJNotGte(read(a), b2, d);
			case OJEq(a, b, d):
				var b2 = read(b);
				OJEq(read(a), b2, d);
			case OJNotEq(a, b, d):
				var b2 = read(b);
				OJNotEq(read(a), b2, d);
			case OJAlways(_) | OLabel(_):
				op;
			case OToDyn(d, a):
				var a = read(a);
				OToDyn(write(d), a);
			case OToSFloat(d, a):
				var a = read(a);
				OToSFloat(write(d), a);
			case OToUFloat(d, a):
				var a = read(a);
				OToUFloat(write(d), a);
			case OToInt(d, a):
				var a = read(a);
				OToInt(write(d), a);
			case OSafeCast(d, a):
				var a = read(a);
				OSafeCast(write(d), a);
			case OUnsafeCast(d, a):
				var a = read(a);
				OUnsafeCast(write(d), a);
			case OToVirtual(d, a):
				var a = read(a);
				OToVirtual(write(d), a);
			case ORet(r):
				ORet(read(r));
			case OThrow(r):
				OThrow(read(r));
			case ORethrow(r):
				ORethrow(read(r));
			case OSwitch(r, cases, def):
				OSwitch(read(r), cases, def);
			case ONullCheck(r):
				ONullCheck(read(r));
			case OTrap(r, d):
				OTrap(write(r), d);
			case OEndTrap(_):
				op; /* ??? */
			case OGetUI8(d, a, b):
				var a = read(a), b = read(b);
				OGetUI8(write(d), a, b);
			case OGetUI16(d, a, b):
				var a = read(a), b = read(b);
				OGetUI16(write(d), a, b);
			case OGetMem(d, a, b):
				var a = read(a), b = read(b);
				OGetMem(write(d), a, b);
			case OGetArray(d, a, b):
				var a = read(a), b = read(b);
				OGetArray(write(d), a, b);
			case OSetUI8(a, b, c):
				var a = read(a), b = read(b), c = read(c);
				OSetUI8(a, b, c);
			case OSetUI16(a, b, c):
				var a = read(a), b = read(b), c = read(c);
				OSetUI16(a, b, c);
			case OSetMem(a, b, c):
				var a = read(a), b = read(b), c = read(c);
				OSetMem(a, b, c);
			case OSetArray(a, b, c):
				var a = read(a), b = read(b), c = read(c);
				OSetArray(a, b, c);
			case ONew(d):
				ONew(write(d));
			case OArraySize(d, a):
				var a = read(a);
				OArraySize(write(d), a);
			case OGetType(d, a):
				var a = read(a);
				OGetType(write(d), a);
			case OGetTID(d, a):
				var a = read(a);
				OGetTID(write(d), a);
			case ORef(d, a):
				var a = read(a);
				ORef(write(d), a);
			case OUnref(d, a):
				var a = read(a);
				OUnref(write(d), a);
			case OSetref(d, a):
				var a = read(a);
				OSetref(write(d), a);
			case OEnumIndex(d, a):
				var a = read(a);
				OEnumIndex(write(d), a);
			case OEnumField(d, a, cs, idx):
				var a = read(a);
				OEnumField(write(d), a, cs, idx);
			case OType(d, t):
				OType(write(d), t);
			case OEnumAlloc(d, e):
				OEnumAlloc(write(d), e);
			case OMakeEnum(d, e, rl):
				var rl = [for (r in rl) read(r)];
				OMakeEnum(write(d), e, rl);
			case OSetEnumField(a, f, b):
				var b2 = read(b);
				OSetEnumField(read(a), f, b2);
			case OAssert(_):
				op;
			case ORefData(r, d):
				var d = read(d);
				ORefData(write(r), d);
			case ORefOffset(r, r2, off):
				var r2 = read(r2);
				var off = read(off);
				ORefOffset(write(r), r2, off);
			case ONop(_):
				op;
			case OPrefetch(r, fid, mode):
				var r2 = read(r);
				OPrefetch(r2, fid, mode);
			case OAsm(_, _, 0):
				op;
			case OAsm(mode, value, r):
				var r2 = read(r - 1);
				OAsm(mode, value, (write(r2)) + 1);
			case OCatch(_):
				op;
		}
	}

	/* build code graph */

	public static function codeGraph(f:Fundecl):{blocksPos:IntMap<Block>, root:Block} {
		function op(index:Int) return f.code[index];
		var blocksPos = new IntMap<Block>();
		var allBlocks = new IntMap<Bool>();
		for (i in 0...f.code.length) {
			switch control(op(i)) {
				case CJAlways(d) | CJCond(d): allBlocks.set(i + 1 + d, true);
				case _:
			}
		}
		function makeBlock(trapl:Array<Int>, pos:Int):Block {
			var b = blocksPos.get(pos);
			if (b != null) return b;
			var b = new Block(pos, trapl);
			blocksPos.set(pos, b);
			var i = pos;
			while (true) {
				function goto(d:Int, ?tl:Array<Int>):Block {
					var b2 = makeBlock(tl == null ? b.btrap : tl, i + 1 + d);
					b2.bprev.unshift(b);
					return b2;
				}
				if (i > pos && allBlocks.exists(i)) {
					b.bend = i - 1;
					b.bnext = [goto(-1)];
					break;
				} else switch control(op(i)) {
					case CNo:
						i++;
						continue;
					case CRet:
						if (b.btrap.length != 0) throw new haxe.Exception("Assert_failure");
						b.bend = i;
					case CJAlways(d):
						b.bend = i;
						b.bnext = [goto(d)];
					case CSwitch(pl):
						b.bend = i;
						var l = [for (p in pl) goto(p)];
						b.bnext = [goto(0)].concat(l);
					case CJCond(d):
						b.bend = i;
						var b1 = goto(d);
						b.bnext = [goto(0), b1];
					case CTry(d):
						b.bend = i;
						var b1 = goto(d);
						b.bnext = [goto(0, [i + 1 + d].concat(b.btrap)), b1];
					case CThrow:
						b.bend = i;
						switch b.btrap {
							case []:
							case [p]: b.bnext = [goto(p - 1 - i, [])];
							case _: b.bnext = [goto(b.btrap[0] - 1 - i, b.btrap.slice(1))];
						}
					case CCatch:
						var p, pl;
						switch b.btrap {
							case []:
								throw new haxe.Exception("Assert_failure");
							case [p0]:
								p = p0;
								pl = [];
							case _:
								p = b.btrap[0];
								pl = b.btrap.slice(1);
						}
						b.bend = i;
						var b1 = goto(p - 1 - i, pl);
						b.bnext = [goto(0, pl), b1];
					case CLabel:
						b.bloop = true;
						i++;
						continue;
				}
				break;
			}
			return b;
		}
		return {blocksPos: blocksPos, root: makeBlock([], 0)};
	}

	static function remapFun(ctx:Rctx, f:Fundecl, dump:Bool, getStr:Int->String, oldCode:Vector<Opcode>):{f:Fundecl, dump:String} {
		function op(index:Int) return f.code[index];
		var nregs = f.regs.length;
		var regRemap = ctx.rUsedRegs != nregs;
		var assigns = f.assigns;
		var dumpBuffer = new StringBuf();
		function write(str:String) if (dump) dumpBuffer.add(str + "\n");
		var nargs = switch f.ftype {
			case HFun(args, _): args.length;
			case _: core.Globals.die("", "hlopt.ml");
		}

		var liveBits = ctx.rLiveBits;
		var regMap = ctx.rRegMap;

		var bitRegs = 30;
		var stride = Std.int((nregs + bitRegs - 1) / bitRegs);
		function isLive(r:Int, i:Int):Bool {
			var offset = Std.int(r / bitRegs);
			var mask = 1 << (r - offset * bitRegs);
			return liveBits[i * stride + offset] & mask != 0;
		}

		/* remap assigns */
		if (ctx.rNopCount > 0) {
			function resolveBlock(p:Int):Block {
				while (true) {
					var b = ctx.rBlocksPos.get(p);
					if (b != null) return b;
					p--;
				}
			}

			function writesReg(p:Int, reg:Int):Bool {
				var found = false;
				opcodeFx((r, read) -> if (r == reg && !read) found = true, oldCode[p]);
				return found;
			}

			var newAssigns:Array<Assign> = []; // port: list, head first
			for (a in assigns) {
				var i = a.name, scopeEnd = a.scopeEnd;
				var gmap = new IntMap<Bool>();
				/*
					For a given assign at position p, that's been optimized out,
					let's try to find where the last assign that maps to the same value
					is, and remap the variable name to it
				 */
				function loop(p:Int):Array<Assign> {
					if (p < 0 || !op(p).match(ONop(_))) return [{name: i, pos: p, scopeEnd: scopeEnd}];
					var moved = ctx.rRegMoved.get(p);
					var reg = moved == null ? -1 : moved.reg, lastW = moved == null ? -1 : moved.lastW;
					if (reg < 0) return []; /* ? */
					if (reg < nargs) return [{name: i, pos: -reg - 2, scopeEnd: -1}];
					var b = resolveBlock(p);
					if (lastW >= b.bstart && lastW < b.bend && lastW < p && writesReg(lastW, reg)) return loop(lastW);
					var wp = b.bwrite.exists(reg) ? b.bwrite.get(reg) : -1;
					function gather(b:Block):Array<Assign> {
						if (gmap.exists(b.bstart)) return [] else {
							gmap.set(b.bstart, true);
							/* lookup in all parent blocks, recursively, to fetch all last writes */
							var acc:Array<Assign> = [];
							for (bp in b.bprev) {
								if (bp.bstart > b.bstart) continue;
								if (bp.bwrite.exists(reg)) {
									var wp = bp.bwrite.get(reg);
									if (wp > p) core.Globals.die("", "hlopt.ml");
									acc = loop(wp).concat(acc);
								} else
									acc = gather(bp).concat(acc);
							}
							return acc;
						}
					}
					return if (wp < 0) gather(b) else if (wp < p) loop(wp) else {
						/* lookup in writes between p-1 and block bstart */
						function findW(p:Int):Array<Assign> {
							return if (p < b.bstart) gather(b) else if (writesReg(p, reg)) loop(p) else findW(p - 1);
						}
						findW(p - 1);
					}
				}
				newAssigns = loop(a.pos).concat(newAssigns);
			}
			newAssigns.reverse();
			var newAssigns = listSort((a1:Assign, a2:Assign) -> a1.pos - a2.pos, newAssigns);
			var seen = new StringMap<Bool>();
			var newAssigns = [
				for (a in newAssigns) {
					var k = a.name + ":" + a.pos + ":" + a.scopeEnd;
					if (seen.exists(k)) continue;
					seen.set(k, true);
					a;
				}
			];
			assigns = Vector.fromArrayCopy(newAssigns);
		}

		/* done */
		if (dump) {
			var oldAssigns = new IntMap<Int>();
			var newAssigns = new IntMap<Array<Int>>();
			for (a in f.assigns) if (a.pos >= 0) oldAssigns.set(a.pos, a.name);
			for (a in assigns) {
				if (a.pos >= 0) {
					var l = newAssigns.get(a.pos);
					if (l == null) {
						l = [];
						newAssigns.set(a.pos, l);
					}
					l.unshift(a.name);
				}
			}
			function pad(s:String, n:Int):String {
				while (s.length < n) s += " ";
				return s;
			}
			function loop():Void {
				for (i in 0...f.code.length) {
					var b = ctx.rBlocksPos.get(i);
					if (b != null) {
						write("\t----- [" + [for (b in b.bnext) hex(b.bstart)].join(",") + "] (" + hex(b.bend) + ")");
						var need = [for (r in b.bneed.elements()) Std.string(r)].join(",");
						var keys = [for (k in b.bwrite.keys()) k];
						haxe.ds.ArraySort.sort(keys, (a, b) -> a - b);
						var wr = [for (r in keys) r + "@" + hex(b.bwrite.get(r))].join(" ");
						write("\t" + (if (b.bloop) "LOOP " else "") + "NEED=" + need + "\tWRITE=" + wr);
					}
					var old = oldCode[i];
					var op = op(i);
					var live = "LIVE=" + [for (r in 0...nregs) if (isLive(r, i)) Std.string(r)].join(",");
					var varSet = if (oldAssigns.exists(i)) "set " + getStr(oldAssigns.get(i)) else "";
					var nvarSet = if (newAssigns.exists(i)) "set " + [for (v in newAssigns.get(i)) getStr(v)].join(",") else "";
					write("\t@" + pad(hex(i), 3) + " " + pad(ostr(Std.string, old), 20) + " "
						+ pad(if (opcodeEq(old, op)) "" else ostr(Std.string, op), 20) + " " + pad(varSet, 20) + " " + pad(nvarSet, 20) + " " + live);
				}
			}
			write(fundeclName(f) + "@" + f.findex);
			var args = [];
			for (a in f.assigns) {
				if (a.pos >= 0) break;
				args.push(getStr(a.name) + ":" + a.pos);
			}
			write("ARGS = " + args.join(", ") + "\n");
			if (regRemap) {
				for (i in 0...nregs) {
					var m = if (ctx.rRegMap[i] < 0) " unused" else if (ctx.rRegMap[i] == i) "" else " r" + pad(Std.string(ctx.rRegMap[i]), 2);
					write("\tr" + pad(Std.string(i), 2) + " " + pad(tstr(f.regs[i]), 10) + m);
				}
			}
			loop();
			write("");
			write("");
		}

		var code = f.code;
		var regs = f.regs;
		var debug = f.debug;

		if (ctx.rNopCount > 0 || regRemap) {
			// port: one extra slot so that a jump to the end of the code reads the end position
			// (upstream reads past the array with unsafe_get)
			var newPos = new Vector(f.code.length + 1, 0);
			var jumps:Array<Int> = [];
			var outPos = 0;
			var outCode = new Vector(f.code.length - ctx.rNopCount, ONop(""));
			var newDebug = new Vector<DebugInfo>(f.code.length - ctx.rNopCount);
			for (i in 0...f.code.length) {
				var op = f.code[i];
				newPos[i] = outPos;
				switch op {
					case ONop(_):
					case _:
						switch op {
							case OJTrue(_) | OJFalse(_) | OJNull(_) | OJNotNull(_) | OJSLt(_) | OJSGte(_) | OJSGt(_) | OJSLte(_) | OJNotLt(_) | OJNotGte(_) |
								OJULt(_) | OJUGte(_) | OJEq(_) | OJNotEq(_) | OJAlways(_) | OSwitch(_) | OTrap(_):
								jumps.unshift(i);
							case _:
						}
						var op = if (regRemap) opcodeMap(r -> regMap[r], r -> regMap[r], op) else op;
						outCode[outPos] = op;
						newDebug[outPos] = f.debug[i];
						outPos++;
				}
			}
			newPos[f.code.length] = outPos;
			for (j in jumps) {
				function pos(d:Int):Int return newPos[j + 1 + d] - newPos[j + 1];
				var p = newPos[j];
				outCode[p] = switch outCode[p] {
					case OJTrue(r, d): OJTrue(r, pos(d));
					case OJFalse(r, d): OJFalse(r, pos(d));
					case OJNull(r, d): OJNull(r, pos(d));
					case OJNotNull(r, d): OJNotNull(r, pos(d));
					case OJSLt(a, b, d): OJSLt(a, b, pos(d));
					case OJSGte(a, b, d): OJSGte(a, b, pos(d));
					case OJSLte(a, b, d): OJSLte(a, b, pos(d));
					case OJSGt(a, b, d): OJSGt(a, b, pos(d));
					case OJULt(a, b, d): OJULt(a, b, pos(d));
					case OJUGte(a, b, d): OJUGte(a, b, pos(d));
					case OJNotLt(a, b, d): OJNotLt(a, b, pos(d));
					case OJNotGte(a, b, d): OJNotGte(a, b, pos(d));
					case OJEq(a, b, d): OJEq(a, b, pos(d));
					case OJNotEq(a, b, d): OJNotEq(a, b, pos(d));
					case OJAlways(d): OJAlways(pos(d));
					case OSwitch(r, cases, send): OSwitch(r, cases.map(pos), pos(send));
					case OTrap(r, d): OTrap(r, pos(d));
					case _: core.Globals.die("", "hlopt.ml");
				}
			}

			function remapScopeEnd(p:Int):Int return if (p < 0) -1 else if (p >= f.code.length) outCode.length else newPos[p];
			for (idx in 0...assigns.length) {
				var a = assigns[idx];
				if (a.pos >= 0) assigns[idx] = {name: a.name, pos: newPos[a.pos], scopeEnd: remapScopeEnd(a.scopeEnd)};
			}

			code = outCode;
			debug = newDebug;
			if (regRemap) {
				var newRegs = new Vector(ctx.rUsedRegs, HVoid);
				for (i in 0...nregs) {
					var p = regMap[i];
					if (p >= 0) newRegs[p] = f.regs[i];
				}
				regs = newRegs;
			}
		}
		var dumpStr = dumpBuffer.toString();
		return {f: f.with(code, regs, debug, assigns), dump: dumpStr};
	}

	static function _optimize(f:Fundecl):Rctx {
		var nregs = f.regs.length;
		function op(index:Int) return f.code[index];
		function setOp(index:Int, op:Opcode) f.code[index] = op;
		var nopCount = 0;
		function setNop(index:Int, r:String) {
			f.code[index] = ONop(r);
			nopCount++;
		}

		/* an allocating opcode never returns null and ONull is always null */
		function foldNullChecks():Void {
			var len = f.code.length;
			var isTarget = new Vector(len + 1, false);
			function mark(i:Int, d:Int):Void {
				var t = i + 1 + d;
				if (t >= 0 && t <= len) isTarget[t] = true;
			}
			for (i in 0...f.code.length) {
				switch control(f.code[i]) {
					case CJAlways(d) | CJCond(d) | CTry(d): mark(i, d);
					case CSwitch(pl): for (d in pl) mark(i, d);
					case _:
				}
			}
			function defOf(r:Int, i:Int):Null<Opcode> {
				/* nearest write to r, only following straight line code and movs */
				var i = i - 1;
				while (true) {
					if (i < 0 || isTarget[i + 1]) return null;
					var op = f.code[i];
					var writes = false;
					opcodeFx((r2, read) -> if (!read && r2 == r) writes = true, op);
					if (writes) return switch op {
						case OMov(_, s): defOf(s, i);
						case _: op;
					} else switch control(op) {
						case CNo: i--;
						case _: return null;
					}
				}
			}
			for (i in 0...f.code.length) {
				switch f.code[i] {
					case OJNotNull(r, d) | OJNull(r, d):
						var isNull:Null<Bool> = switch defOf(r, i) {
							case ONew(_) | OStaticClosure(_, _) | OInstanceClosure(_, _, _): false;
							case ONull(_): true;
							case _: null;
						}
						if (isNull != null) {
							var taken = switch f.code[i] {
								case OJNull(_, _): isNull;
								case _: !isNull;
							}
							if (taken) f.code[i] = OJAlways(d) else setNop(i, "nullcheck");
						}
					case _:
				}
			}
		}
		foldNullChecks();

		var g = codeGraph(f);
		var blocksPos = g.blocksPos, root = g.root;

		var readCounts = new Vector(nregs, 0);
		var writeCounts = new Vector(nregs, 0);
		var lastWrite = new Vector(nregs, -1);

		var bitRegs = 30;
		var stride = Std.int((nregs + bitRegs - 1) / bitRegs);
		var liveBits = new Vector(f.code.length * stride, 0);

		var regMoved = new IntMap<{reg:Int, lastW:Int}>();
		function addRegMoved(p:Int, w:Int, r:Int):Void regMoved.set(p, {reg: r, lastW: lastWrite[r]});

		function setLive(r:Int, min:Int, max:Int):Void {
			var offset = Std.int(r / bitRegs);
			var mask = 1 << (r - offset * bitRegs);
			if (min < 0 || max >= f.code.length) core.Globals.die("", "hlopt.ml");
			for (i in min...max + 1) {
				var p = i * stride + offset;
				liveBits[p] = liveBits[p] | mask;
			}
		}
		function isLive(r:Int, i:Int):Bool {
			var offset = Std.int(r / bitRegs);
			var mask = 1 << (r - offset * bitRegs);
			var idx = i * stride + offset;
			if (idx < 0 || idx >= liveBits.length) throw new core.ds.InvalidArgument("index out of bounds");
			return liveBits[idx] & mask != 0;
		}

		function readCount(r:Int) readCounts[r] = readCounts[r] + 1;
		function writeCount(r:Int) writeCounts[r] = writeCounts[r] + 1;

		function emptyState():Vector<RegState> {
			var s = new Vector<RegState>(nregs);
			for (i in 0...nregs) s[i] = new RegState(i);
			return s;
		}

		function isPackedField(o:Int, fid:Int):Bool {
			return switch f.regs[o] {
				case HStruct(p) | HObj(p):
					var ft = try resolveField(p, fid).t catch (_:core.ds.NotFound) throw new haxe.Exception("Assert_failure");
					ft.match(HPacked(_));
				case _:
					false;
			}
		}

		/*
			let print_state i s =
				let state_str s =
					if s.ralias == s && s.rbind == [] then "" else
					Printf.sprintf "%d%s[%s]" s.rindex (if s.ralias == s then "" else "=" ^ string_of_int s.ralias.rindex) (String.concat "," (List.map (fun s -> string_of_int s.rindex) s.rbind))
				in
				write (Printf.sprintf "@%X %s" i (String.concat " " (Array.to_list (Array.map state_str s))))
			in
		 */

		var getState:Block->Vector<RegState> = null;
		function propagate(b:Block):Void {
			var state = if (b.bloop) emptyState() else if (b.bprev.length == 0) emptyState() else {
				var b2 = b.bprev[0];
				var l = b.bprev.slice(1);
				var s = getState(b2);
				var s = switch b2.bnext.length {
					case 0: core.Globals.die("", "hlopt.ml");
					case 1: s; /* reuse */
					case _:
						var s2 = emptyState();
						for (i in 0...nregs) {
							var sold = s[i], snew = s2[i];
							snew.ralias = s2[sold.ralias.rindex];
							snew.rbind = [for (b in sold.rbind) s2[b.rindex]];
							snew.rnullcheck = sold.rnullcheck;
						}
						s2;
				}
				for (b2 in l) {
					var s2 = getState(b2);
					for (i in 0...nregs) {
						var s1 = s[i], s2 = s2[i];
						if (s1.ralias.rindex != s2.ralias.rindex) s1.ralias = s1;
					}
					for (i in 0...nregs) {
						var s1 = s[i], s2 = s2[i];
						s1.rbind = [for (x in s1.rbind) if (x.ralias == s1) x];
						s1.rnullcheck = s1.rnullcheck && s2.rnullcheck;
						if (s2.rbind.length != 0) {
							var orig = s1.rbind;
							var acc = s1.rbind;
							for (sb2 in s2.rbind) {
								var s = s[sb2.rindex];
								if (s.ralias == s1 && orig.indexOf(s) < 0) acc = [s].concat(acc);
							}
							s1.rbind = acc;
						}
					}
				}
				s;
			}
			function unalias(r:RegState):Void {
				r.ralias.rbind = [for (r2 in r.ralias.rbind) if (r2 != r) r2];
				r.ralias = r;
			}
			var i = b.bstart;
			while (i <= b.bend) {
				function doRead(r:Int):Void {
					var w = lastWrite[r];
					if (w < b.bstart || w > i) {
						lastWrite[r] = i;
						setLive(r, b.bstart, i);
						b.bneed = b.bneed.add(r);
					} else
						setLive(r, w + 1, i);
					readCount(r);
				}
				function doWrite(r:Int):Void {
					var s = state[r];
					for (s2 in s.rbind) s2.ralias = s2;
					s.rbind = [];
					s.rnullcheck = false;
					lastWrite[r] = i;
					b.bwrite.set(r, i);
					writeCount(r);
					unalias(s);
				}
				var op = op(i);
				/* print_state i state; (* debug *) */
				switch op {
					case OIncr(r) | ODecr(r) | ORef(_, r): unalias(state[r]);
					case OCallClosure(_, r, _) if (tEq(f.regs[r], HDyn) && (switch f.regs[state[r].ralias.rindex] {
							case HFun(_, rt): !isDynamic(rt);
							case HDyn: false;
							case _: true;
						})): unalias(state[r]); /* Issue3218.hx */
					case _:
				}
				var op = opcodeMap(r -> {
					var s = state[r];
					s.ralias.rindex;
				}, w -> w, op);
				setOp(i, op);
				switch op {
					case OMov(d, v) | OToInt(d, v) | OToSFloat(d, v) if (d == v):
						addRegMoved(i, d, v);
						setNop(i, "mov");
					case OMov(d, v):
						var sv = state[v];
						var sd = state[d];
						doRead(v);
						doWrite(d);
						sd.ralias = sv;
						sd.rnullcheck = sv.rnullcheck;
						if (sv.rbind.indexOf(sd) < 0) sv.rbind.unshift(sd);
					case OIncr(r) | ODecr(r):
						doRead(r);
						doWrite(r);
					case ONullCheck(r):
						var s = state[r];
						if (s.rnullcheck) setNop(i, "nullcheck") else {
							doRead(r);
							s.rnullcheck = true;
						}
					case ONew(r):
						var s = state[r];
						doWrite(r);
						s.rnullcheck = true;
					case OToVirtual(v, o):
						doRead(o);
						doWrite(v);
						state[v].rnullcheck = state[o].rnullcheck;
					case OField(r, o, fid) if (f.regs[r].match(HStruct(_))):
						doRead(o);
						doWrite(r);
						if (isPackedField(o, fid)) state[r].rnullcheck = true;
					case OGetThis(r, fid) if (f.regs[r].match(HStruct(_))):
						doWrite(r);
						if (isPackedField(0, fid)) state[r].rnullcheck = true;
					case OGetArray(r, arr, idx):
						doRead(arr);
						doRead(idx);
						doWrite(r);
						switch f.regs[arr] {
							case HAbstract(_): state[r].rnullcheck = true;
							case _:
						}
					case _:
						opcodeFx((r, read) -> if (read) doRead(r) else doWrite(r), op);
				}
				i++;
			}
			b.bstate = state;
			for (b2 in b.bnext) getState(b2);
		}

		getState = function(b:Block):Vector<RegState> {
			switch b.bstate {
				case null:
					/* recurse before calculating */
					for (b2 in b.bprev) if (b2.bstart < b.bstart) getState(b2);
					switch b.bstate {
						case null:
							propagate(b);
							return getState(b);
						case b:
							return b;
					}
				case state:
					return state;
			}
		}
		propagate(root);

		/* unreachable code */

		var i = 0;
		while (i != f.code.length) {
			var b = blocksPos.get(i);
			if (b != null) i = b.bend + 1 else {
				switch op(i) {
					case OEndTrap(true):
					case _: setNop(i, "unreach");
				}
				i++;
			}
		}

		/* liveness */

		function live(b:Block):ISet {
			switch b.bneedAll {
				case null:
				case a: return a;
			}
			function needSub0(bl:Array<Block>):ISet {
				var acc = ISet.empty;
				for (b2 in bl) {
					/* loop : first pass does not recurse, second pass uses cache */
					acc = if (b2.bloop && b2.bstart < b.bstart) (b2.bneedAll == null ? acc : acc.union(b2.bneedAll)) else acc.union(live(b2));
				}
				return acc;
			}
			function needSub(bl:Array<Block>):ISet {
				return needSub0(bl).filter(r -> {
					if (b.bwrite.exists(r)) {
						var w = b.bwrite.get(r);
						setLive(r, w + 1, b.bend);
						false;
					} else {
						setLive(r, b.bstart, b.bend);
						true;
					}
				});
			}
			var need = b.bneed.union(needSub(b.bnext));
			b.bneedAll = need;
			if (b.bloop) {
				/*
					if we are a loop, we need a second pass to perform fixed point
					first clear the cache within the loop from backward
					then rebuild the cache to make sure liveness ranges are correctly set
				 */
				function clear(b2:Block):Void {
					if (b2.bneedAll != null && b2.bstart > b.bstart) {
						b2.bneedAll = null;
						for (x in b2.bprev) clear(x);
					}
				}
				for (b2 in b.bprev) if (b2.bstart > b.bstart) clear(b2);
				for (b in b.bnext) live(b);
				/* do-while loop : recompute self after recompute all next */
				var need = b.bneed.union(needSub(b.bnext));
				b.bneedAll = need;
			}
			if (b.bneedAll == null) throw new core.ds.InvalidArgument("option is None");
			return b.bneedAll;
		}
		live(root);

		/* nop */

		var i = f.code.length - 1;
		while (i >= 0) {
			switch op(i) {
				case OMov(d, r) if (!isLive(d, i + 1) || readCounts[d] == 0):
					var n = readCounts[r] - 1;
					readCounts[r] = n;
					writeCounts[d] = writeCounts[d] - 1;
					addRegMoved(i, d, r);
					setNop(i, "unused");
				case ONull(d) if (!isLive(d, i + 1) || readCounts[d] == 0):
					writeCounts[d] = writeCounts[d] - 1;
					setNop(i, "unused");
				case OJAlways(d) if (d >= 0):
					var k = 0;
					while (true) {
						if (k == d) {
							setNop(i, "nojmp");
							break;
						}
						switch f.code[i + k + 1] {
							case ONop(_): k++;
							case _: break;
						}
					}
				case _:
			}
			i--;
		}

		/* reg map */

		var usedRegs = 0;
		var regMap = readCounts;
		var nargs = switch f.ftype {
			case HFun(args, _): args.length;
			case _: core.Globals.die("", "hlopt.ml");
		}
		for (i in 0...nregs) {
			if (readCounts[i] > 0 || writeCounts[i] > 0 || i < nargs) {
				regMap[i] = usedRegs;
				usedRegs++;
			} else
				regMap[i] = -1;
		}
		return {
			rRoot: root,
			rBlocksPos: blocksPos,
			rNopCount: nopCount,
			rUsedRegs: usedRegs,
			rLiveBits: liveBits,
			rRegMap: regMap,
			rRegMoved: regMoved
		};
	}

	static var optCache = new StringMap<CacheElt>();
	static var usedMark = 0;

	public static function optimize(dump:Bool, getStr:Int->String, f:Fundecl, hxf:String):{f:Fundecl, dump:String} {
		var oldCode:Vector<Opcode> = if (dump) f.code.copy() else f.code;
		var c = optCache.get(hxf);
		if (c != null) {
			c.cLastUsed = usedMark;
			if (f.code.length != c.cCode.length) core.Globals.die("", "hlopt.ml");
			var code = c.cCode;
			for (i in c.cRemapIndexes) {
				var op = switch [code[i], f.code[i]] {
					case [OInt(r, _), OInt(_, idx)]: OInt(r, idx);
					case [OFloat(r, _), OFloat(_, idx)]: OFloat(r, idx);
					case [OBytes(r, _), OBytes(_, idx)]: OBytes(r, idx);
					case [OString(r, _), OString(_, idx)]: OString(r, idx);
					case [OCall0(r, _), OCall0(_, idx)]: OCall0(r, idx);
					case [OCall1(r, _, a), OCall1(_, idx, _)]: OCall1(r, idx, a);
					case [OCall2(r, _, a, b), OCall2(_, idx, _, _)]: OCall2(r, idx, a, b);
					case [OCall3(r, _, a, b, c), OCall3(_, idx, _, _, _)]: OCall3(r, idx, a, b, c);
					case [OCall4(r, _, a, b, c, d), OCall4(_, idx, _, _, _, _)]: OCall4(r, idx, a, b, c, d);
					case [OCallN(r, _, pl), OCallN(_, idx, _)]: OCallN(r, idx, pl);
					case [OStaticClosure(r, _), OStaticClosure(_, idx)]: OStaticClosure(r, idx);
					case [OInstanceClosure(r, _, v), OInstanceClosure(_, idx, _)]: OInstanceClosure(r, idx, v);
					case [OGetGlobal(r, _), OGetGlobal(_, g)]: OGetGlobal(r, g);
					case [OSetGlobal(_, v), OSetGlobal(g, _)]: OSetGlobal(g, v);
					case [ODynGet(r, o, _), ODynGet(_, _, idx)]: ODynGet(r, o, idx);
					case [ODynSet(o, _, v), ODynSet(_, idx, _)]: ODynSet(o, idx, v);
					case [OType(r, _), OType(_, t)]: OType(r, t);
					case _: core.Globals.die("", "hlopt.ml");
				}
				code[i] = op;
			}
			return remapFun(c.cRctx, f.with(code, f.regs, f.debug, f.assigns), dump, getStr, oldCode);
		}
		var rctx = _optimize(f);
		var oldOps = f.code;
		var fopt = remapFun(rctx, f, dump, getStr, oldCode);
		for (b in rctx.rBlocksPos) {
			b.bstate = null;
			if (!dump) {
				b.bneed = ISet.empty;
				b.bneedAll = null;
			}
		}
		var idxs = [];
		for (i in 0...oldOps.length) {
			switch oldOps[i] {
				case OInt(_) | OFloat(_) | OBytes(_) | OString(_) | OCall0(_) | OCall1(_) | OCall2(_) | OCall3(_) | OCall4(_) | OCallN(_) | OStaticClosure(_) |
					OInstanceClosure(_) | OGetGlobal(_) | OSetGlobal(_) | ODynGet(_) | ODynSet(_) | OType(_):
					idxs.push(i);
				case _:
			}
		}
		/*opt_cache := PMap.add hxf {
			c_code = old_ops;
			c_rctx = rctx;
			c_last_used = !used_mark;
			c_remap_indexes = DynArray.to_array idxs;
		} (!opt_cache); */
		return fopt;
	}

	public static function cleanCache():Void {
		for (k in [for (k in optCache.keys()) k]) {
			var c = optCache.get(k);
			if (usedMark - c.cLastUsed > 3) optCache.remove(k);
		}
		usedMark++;
	}
}
