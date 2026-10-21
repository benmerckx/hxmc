/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

package generators.jvm;

import generators.jvm.JvmGlobals;
import generators.jvm.JvmData;
import generators.jvm.JvmSignature;

/* Opcode builder with stack management */
class EmptyStack extends haxe.Exception {
	public function new() super("EmptyStack");
}

class JvmCode {
	public static function terminates(op:JOpcode):Bool return switch op {
		case OpDreturn | OpFreturn | OpIreturn | OpLreturn | OpAreturn | OpGoto(_) | OpGoto_w(_) | OpJsr(_) | OpJsr_w(_) | OpAthrow | OpReturn:
			true;
		case _:
			false;
	}
}

// port: `jsignature list * int`; the arrays are never mutated, so saved states can share them.
typedef JvmStackState = {stack:Array<JSignature>, size:Int};

class JvmStack {
	// port: OCaml list `stack` with the head (top of stack) first.
	var stack:Array<JSignature> = [];
	var stackSize = 0;
	var maxStackSize = 0;

	public function new() {}

	public function push(js:JSignature):Void {
		stack = [js].concat(stack);
		stackSize = stackSize + JvmSignature.signatureSize(js);
		if (stackSize > maxStackSize) maxStackSize = stackSize;
	}

	public function pop():JSignature {
		if (stack.length == 0) throw new EmptyStack();
		var js = stack[0];
		stack = stack.slice(1);
		stackSize = stackSize - JvmSignature.signatureSize(js);
		return js;
	}

	public function toString():String return "[" + stack.map(JvmSignature.generateSignature.bind(false)).join(", ") + "]";

	public function save():JvmStackState return {stack: stack, size: stackSize};

	public function top():JSignature {
		if (stack.length == 0) throw new EmptyStack();
		return stack[0];
	}

	public function restore(s:JvmStackState):Void {
		stack = s.stack;
		stackSize = s.size;
	}

	public function getMaxStackSize():Int return maxStackSize;

	public function setMaxStackSize(value:Int):Void maxStackSize = value;

	public function getStack():Array<JSignature> return stack;

	public function getStackItems(i:Int):Array<JSignature> {
		if (i > stack.length) throw new EmptyStack();
		return stack.slice(0, i);
	}

	public function replace(jsig:JSignature):Void {
		pop();
		push(jsig);
	}
}

class JvmCodeBuilder {
	final pool:JvmConstantPool;
	final stack = new JvmStack();
	final lines:Array<{pc:Int, line:Int}> = [];
	var lastLine = -1;
	var currentLine = -1;

	/* ops */
	final ops:Array<JOpcode> = [];
	var fp = 0;
	var terminated = false;

	public function new(pool:JvmConstantPool) {
		this.pool = pool;
	}

	public function isTerminated():Bool return terminated;

	public function setTerminated(b:Bool):Void terminated = b;

	public function op(opcode:JOpcode, length:Int, expect:Array<JSignature>, ret:Array<JSignature>):Void {
		if (lastLine != currentLine) {
			lastLine = currentLine;
			lines.push({pc: fp, line: currentLine});
		}
		ops.push(opcode);
		fp = fp + length;
		for (_ in expect) stack.pop();
		var i = ret.length;
		while (i-- > 0) stack.push(ret[i]);
		if (JvmCode.terminates(opcode)) terminated = true;
	}

	public function opMaybeWide(op:JOpcode, opw:OpWide, i:Int, tl:Array<JSignature>, tr:Array<JSignature>):Void {
		switch JvmGlobals.getNumericRangeUnsigned(i) {
			case Int8Range: this.op(op, 2, tl, tr);
			case Int16Range: this.op(OpWide(opw), 4, tl, tr);
			case Int32Range: core.Globals.die("", "generators/jvm/jvmCode.ml");
		}
	}

	/* variables */
	public function iload(i:Int, ?jsig:JSignature):Void {
		if (jsig == null) jsig = JInt;
		switch i {
			case 0: op(OpIload_0, 1, [], [jsig]);
			case 1: op(OpIload_1, 1, [], [jsig]);
			case 2: op(OpIload_2, 1, [], [jsig]);
			case 3: op(OpIload_3, 1, [], [jsig]);
			case i: opMaybeWide(OpIload(i), OpWIload(i), i, [], [jsig]);
		}
	}

	public function lload(i:Int):Void {
		switch i {
			case 0: op(OpLload_0, 1, [], [JLong]);
			case 1: op(OpLload_1, 1, [], [JLong]);
			case 2: op(OpLload_2, 1, [], [JLong]);
			case 3: op(OpLload_3, 1, [], [JLong]);
			case i: opMaybeWide(OpLload(i), OpWLload(i), i, [], [JLong]);
		}
	}

	public function fload(i:Int):Void {
		switch i {
			case 0: op(OpFload_0, 1, [], [JFloat]);
			case 1: op(OpFload_1, 1, [], [JFloat]);
			case 2: op(OpFload_2, 1, [], [JFloat]);
			case 3: op(OpFload_3, 1, [], [JFloat]);
			case i: opMaybeWide(OpFload(i), OpWFload(i), i, [], [JFloat]);
		}
	}

	public function dload(i:Int):Void {
		switch i {
			case 0: op(OpDload_0, 1, [], [JDouble]);
			case 1: op(OpDload_1, 1, [], [JDouble]);
			case 2: op(OpDload_2, 1, [], [JDouble]);
			case 3: op(OpDload_3, 1, [], [JDouble]);
			case i: opMaybeWide(OpDload(i), OpWDload(i), i, [], [JDouble]);
		}
	}

	public function aload(vtt:JSignature, i:Int):Void {
		switch i {
			case 0: op(OpAload_0, 1, [], [vtt]);
			case 1: op(OpAload_1, 1, [], [vtt]);
			case 2: op(OpAload_2, 1, [], [vtt]);
			case 3: op(OpAload_3, 1, [], [vtt]);
			case i: opMaybeWide(OpAload(i), OpWAload(i), i, [], [vtt]);
		}
	}

	public function istore(i:Int):Void {
		switch i {
			case 0: op(OpIstore_0, 1, [JInt], []);
			case 1: op(OpIstore_1, 1, [JInt], []);
			case 2: op(OpIstore_2, 1, [JInt], []);
			case 3: op(OpIstore_3, 1, [JInt], []);
			case i: opMaybeWide(OpIstore(i), OpWIstore(i), i, [JInt], []);
		}
	}

	public function lstore(i:Int):Void {
		switch i {
			case 0: op(OpLstore_0, 1, [JLong], []);
			case 1: op(OpLstore_1, 1, [JLong], []);
			case 2: op(OpLstore_2, 1, [JLong], []);
			case 3: op(OpLstore_3, 1, [JLong], []);
			case i: opMaybeWide(OpLstore(i), OpWLstore(i), i, [JLong], []);
		}
	}

	public function fstore(i:Int):Void {
		switch i {
			case 0: op(OpFstore_0, 1, [JFloat], []);
			case 1: op(OpFstore_1, 1, [JFloat], []);
			case 2: op(OpFstore_2, 1, [JFloat], []);
			case 3: op(OpFstore_3, 1, [JFloat], []);
			case i: opMaybeWide(OpFstore(i), OpWFstore(i), i, [JFloat], []);
		}
	}

	public function dstore(i:Int):Void {
		switch i {
			case 0: op(OpDstore_0, 1, [JDouble], []);
			case 1: op(OpDstore_1, 1, [JDouble], []);
			case 2: op(OpDstore_2, 1, [JDouble], []);
			case 3: op(OpDstore_3, 1, [JDouble], []);
			case i: opMaybeWide(OpDstore(i), OpWDstore(i), i, [JDouble], []);
		}
	}

	public function astore(vtt:JSignature, i:Int):Void {
		switch i {
			case 0: op(OpAstore_0, 1, [vtt], []);
			case 1: op(OpAstore_1, 1, [vtt], []);
			case 2: op(OpAstore_2, 1, [vtt], []);
			case 3: op(OpAstore_3, 1, [vtt], []);
			case i: opMaybeWide(OpAstore(i), OpWAstore(i), i, [vtt], []);
		}
	}

	public function iinc(index:Int, i:Int):Void {
		switch [JvmGlobals.getNumericRangeUnsigned(index), JvmGlobals.getNumericRange(i)] {
			case [Int8Range, Int8Range]:
				op(OpIinc(index, i), 3, [], []);
			case [(Int8Range | Int16Range), (Int8Range | Int16Range)]:
				op(OpWide(OpWIinc(index, i)), 6, [], []);
			case _:
				core.Globals.die("", "generators/jvm/jvmCode.ml");
		}
	}

	/* conversions */
	public function d2f():Void op(OpD2f, 1, [JDouble], [JFloat]);

	public function d2i():Void op(OpD2i, 1, [JDouble], [JInt]);

	public function d2l():Void op(OpD2l, 1, [JDouble], [JLong]);

	public function f2d():Void op(OpF2d, 1, [JFloat], [JDouble]);

	public function f2i():Void op(OpF2i, 1, [JFloat], [JInt]);

	public function f2l():Void op(OpF2l, 1, [JFloat], [JLong]);

	public function i2b(jsig:JSignature):Void op(OpI2b, 1, [JInt], [jsig]);

	public function i2c():Void op(OpI2c, 1, [JInt], [JChar]);

	public function i2d():Void op(OpI2d, 1, [JInt], [JDouble]);

	public function i2f():Void op(OpI2f, 1, [JInt], [JFloat]);

	public function i2l():Void op(OpI2l, 1, [JInt], [JLong]);

	public function i2s():Void op(OpI2s, 1, [JInt], [JShort]);

	public function l2d():Void op(OpL2d, 1, [JLong], [JDouble]);

	public function l2f():Void op(OpL2f, 1, [JLong], [JFloat]);

	public function l2i():Void op(OpL2i, 1, [JLong], [JInt]);

	/* arrays */
	public function newarray(ta:JSignature, t:Int):Void op(OpNewarray(t), 2, [JInt], [ta]);

	public function anewarray(ta:JSignature, offset:Int):Void op(OpAnewarray(offset), 3, [JInt], [ta]);

	public function arraylength(ta:JSignature):Void op(OpArraylength, 1, [ta], [JInt]);

	public function aastore(ta:JSignature, te:JSignature):Void op(OpAastore, 1, [te, JInt, ta], []);

	public function aaload(ta:JSignature, te:JSignature):Void op(OpAaload, 1, [JInt, ta], [te]);

	public function castore(ta:JSignature):Void op(OpCastore, 1, [JChar, JInt, ta], []);

	public function caload(ta:JSignature):Void op(OpCaload, 1, [JInt, ta], [JChar]);

	public function fastore(ta:JSignature):Void op(OpFastore, 1, [JFloat, JInt, ta], []);

	public function faload(ta:JSignature):Void op(OpFaload, 1, [JInt, ta], [JFloat]);

	public function lastore(ta:JSignature):Void op(OpLastore, 1, [JLong, JInt, ta], []);

	public function laload(ta:JSignature):Void op(OpLaload, 1, [JInt, ta], [JLong]);

	public function sastore(ta:JSignature):Void op(OpSastore, 1, [JShort, JInt, ta], []);

	public function saload(ta:JSignature):Void op(OpSaload, 1, [JInt, ta], [JShort]);

	public function iastore(ta:JSignature):Void op(OpIastore, 1, [JInt, JInt, ta], []);

	public function iaload(ta:JSignature):Void op(OpIaload, 1, [JInt, ta], [JInt]);

	public function dastore(ta:JSignature):Void op(OpDastore, 1, [JDouble, JInt, ta], []);

	public function daload(ta:JSignature):Void op(OpDaload, 1, [JInt, ta], [JDouble]);

	public function bastore(jsig:JSignature, ta:JSignature):Void op(OpBastore, 1, [jsig, JInt, ta], []);

	public function baload(jsig:JSignature, ta:JSignature):Void op(OpBaload, 1, [JInt, ta], [jsig]);

	/* fields */
	public function getstatic(offset:Int, t:JSignature):Void op(OpGetstatic(offset), 3, [], [t]);

	public function putstatic(offset:Int, t:JSignature):Void op(OpPutstatic(offset), 3, [t], []);

	public function getfield(offset:Int, tobj:JSignature, t:JSignature):Void op(OpGetfield(offset), 3, [tobj], [t]);

	public function putfield(offset:Int, tobj:JSignature, t:JSignature):Void op(OpPutfield(offset), 3, [t, tobj], []);

	/* calls */
	static function rev<A>(l:Array<A>):Array<A> {
		var l = l.copy();
		l.reverse();
		return l;
	}

	public function invokestatic(offset:Int, tl:Array<JSignature>, tr:Array<JSignature>):Void op(OpInvokestatic(offset), 3, rev(tl), tr);

	public function invokevirtual(offset:Int, t1:JSignature, tl:Array<JSignature>, tr:Array<JSignature>):Void op(OpInvokevirtual(offset), 3,
		rev([t1].concat(tl)), tr);

	public function invokeinterface(offset:Int, t1:JSignature, tl:Array<JSignature>, tr:Array<JSignature>):Void {
		var count = 1;
		for (jsig in tl) count = count + JvmSignature.signatureSize(jsig);
		op(OpInvokeinterface(offset, count), 5, rev([t1].concat(tl)), tr);
	}

	public function invokespecial(offset:Int, t1:JSignature, tl:Array<JSignature>, tr:Array<JSignature>):Void op(OpInvokespecial(offset), 3,
		rev([t1].concat(tl)), tr);

	public function invokedynamic(offset:Int, tl:Array<JSignature>, tr:Array<JSignature>):Void op(OpInvokedynamic(offset), 5, rev(tl), tr);

	public function new_(offset:Int):Void op(OpNew(offset), 3, [], [JUninitialized(fp)]);

	/* return */
	public function returnVoid():Void op(OpReturn, 1, [], []);

	public function returnValue(t:JSignature):Void {
		var o = switch t {
			case JInt | JBool | JByte | JChar | JShort: OpIreturn;
			case JLong: OpLreturn;
			case JFloat: OpFreturn;
			case JDouble: OpDreturn;
			case _: OpAreturn;
		}
		op(o, 1, [t], []);
	}

	public function athrow():Void op(OpAthrow, 1, [stack.top()], []);

	/* control flow */
	public function if_(cmp:JCmp, r:JBranchOffsetRef):Void op(OpIf(cmp, r), 3, [JBool], []);

	public function ifIcmp(cmp:JCmp, r:JBranchOffsetRef):Void op(OpIf_icmp(cmp, r), 3, [JInt, JInt], []);

	public function ifAcmpEq(t1:JSignature, t2:JSignature, r:JBranchOffsetRef):Void op(OpIf_acmpeq(r), 3, [t1, t2], []);

	public function ifAcmpNe(t1:JSignature, t2:JSignature, r:JBranchOffsetRef):Void op(OpIf_acmpne(r), 3, [t1, t2], []);

	public function ifNull(t:JSignature, r:JBranchOffsetRef):Void op(OpIfnull(r), 3, [t], []);

	public function ifNonnull(t:JSignature, r:JBranchOffsetRef):Void op(OpIfnonnull(r), 3, [t], []);

	public function goto(r:JBranchOffsetRef):Void op(OpGoto(r), 3, [], []);

	public function lookupswitch(offsetDef:JBranchOffsetRef, offsets:haxe.ds.Vector<{key:Int, offset:JBranchOffsetRef}>):Void {
		var pad = (fp + 1) % 4;
		var pad = if (pad == 0) pad else 4 - pad;
		op(OpLookupswitch(pad, offsetDef, offsets), 9 + pad + (offsets.length * 8), [JInt], []);
	}

	public function tableswitch(offsetDef:JBranchOffsetRef, low:Int, high:Int, offsets:haxe.ds.Vector<JBranchOffsetRef>):Void {
		var pad = (fp + 1) % 4;
		var pad = if (pad == 0) pad else 4 - pad;
		op(OpTableswitch(pad, offsetDef, low, high, offsets), 13 + pad + (offsets.length * 4), [JInt], []);
	}

	/* compare */
	public function dcmpg():Void op(OpDcmpg, 1, [JDouble, JDouble], [JInt]);

	public function dcmpl():Void op(OpDcmpl, 1, [JDouble, JDouble], [JInt]);

	public function fcmpg():Void op(OpFcmpg, 1, [JFloat, JFloat], [JInt]);

	public function fcmpl():Void op(OpFcmpl, 1, [JFloat, JFloat], [JInt]);

	public function lcmpl():Void op(OpLcmp, 1, [JLong, JLong], [JInt]);

	/* ops */
	public function iadd():Void op(OpIadd, 1, [JInt, JInt], [JInt]);

	public function isub():Void op(OpIsub, 1, [JInt, JInt], [JInt]);

	public function imul():Void op(OpImul, 1, [JInt, JInt], [JInt]);

	public function iand():Void op(OpIand, 1, [JInt, JInt], [JInt]);

	public function ior():Void op(OpIor, 1, [JInt, JInt], [JInt]);

	public function ixor():Void op(OpIxor, 1, [JInt, JInt], [JInt]);

	public function ishl():Void op(OpIshl, 1, [JInt, JInt], [JInt]);

	public function ishr():Void op(OpIshr, 1, [JInt, JInt], [JInt]);

	public function iushr():Void op(OpIushr, 1, [JInt, JInt], [JInt]);

	public function irem():Void op(OpIrem, 1, [JInt, JInt], [JInt]);

	public function ineg():Void op(OpIneg, 1, [JInt], [JInt]);

	public function ladd():Void op(OpLadd, 1, [JLong, JLong], [JLong]);

	public function lsub():Void op(OpLsub, 1, [JLong, JLong], [JLong]);

	public function lmul():Void op(OpLmul, 1, [JLong, JLong], [JLong]);

	public function ldiv():Void op(OpLdiv, 1, [JLong, JLong], [JLong]);

	public function land_():Void op(OpLand, 1, [JLong, JLong], [JLong]);

	public function lor_():Void op(OpLor, 1, [JLong, JLong], [JLong]);

	public function lxor_():Void op(OpLxor, 1, [JLong, JLong], [JLong]);

	public function lshl():Void op(OpLshl, 1, [JInt, JLong], [JLong]);

	public function lshr():Void op(OpLshr, 1, [JInt, JLong], [JLong]);

	public function lushr():Void op(OpLushr, 1, [JInt, JLong], [JLong]);

	public function lrem():Void op(OpLrem, 1, [JLong, JLong], [JLong]);

	public function lneg():Void op(OpLneg, 1, [JLong], [JLong]);

	public function fadd():Void op(OpFadd, 1, [JFloat, JFloat], [JFloat]);

	public function fsub():Void op(OpFsub, 1, [JFloat, JFloat], [JFloat]);

	public function fmul():Void op(OpFmul, 1, [JFloat, JFloat], [JFloat]);

	public function fdiv():Void op(OpFdiv, 1, [JFloat, JFloat], [JFloat]);

	public function frem():Void op(OpFrem, 1, [JFloat, JFloat], [JFloat]);

	public function fneg():Void op(OpFneg, 1, [JFloat], [JFloat]);

	public function dadd():Void op(OpDadd, 1, [JDouble, JDouble], [JDouble]);

	public function dsub():Void op(OpDsub, 1, [JDouble, JDouble], [JDouble]);

	public function dmul():Void op(OpDmul, 1, [JDouble, JDouble], [JDouble]);

	public function ddiv():Void op(OpDdiv, 1, [JDouble, JDouble], [JDouble]);

	public function drem():Void op(OpDrem, 1, [JDouble, JDouble], [JDouble]);

	public function dneg():Void op(OpDneg, 1, [JDouble], [JDouble]);

	/* stack */
	public function pop():Void {
		var top = stack.top();
		op(if (JvmSignature.signatureSize(top) == 1) OpPop else OpPop2, 1, [top], []);
	}

	public function dup():Void {
		switch stack.top() {
			case JLong | JDouble: op(OpDup2, 1, [], [stack.top()]);
			case _: op(OpDup, 1, [], [stack.top()]);
		}
	}

	public function dupX1():Void {
		var tl = stack.getStackItems(2);
		var tl2 = [tl[0]].concat(rev(tl));
		switch tl[0] {
			case JLong | JDouble: op(OpDup2_x1, 1, tl, tl2);
			case _: op(OpDup_x1, 1, tl, tl2);
		}
	}

	public function dupX2():Void {
		var tl = stack.getStackItems(3);
		var sizes = tl.map(JvmSignature.signatureSize);
		var vt1 = tl[0], vt2 = tl[1], vt3 = tl[2];
		if (sizes[0] == 2 && sizes[1] == 2) op(OpDup2_x2, 1, [vt1, vt2], [vt1, vt2, vt1]);
		else if (sizes[0] == 1 && sizes[1] == 2) op(OpDup_x2, 1, [vt1, vt2], [vt1, vt2, vt1]);
		else if (sizes[0] == 1 && sizes[1] == 1 && sizes[2] == 1) op(OpDup_x2, 1, tl, [vt1, vt2, vt3, vt1]);
		else if (sizes[0] == 2 && sizes[1] == 1 && sizes[2] == 1) op(OpDup2_x2, 1, tl, [vt1, vt2, vt3, vt1]);
		else JvmGlobals.jerror("???");
	}

	public function swap():Void {
		var tl = stack.getStackItems(2);
		op(OpSwap, 1, tl, rev(tl));
	}

	public function checkcastSig(jsig:JSignature):Void {
		var offset = pool.addType(JvmSignature.generateSignature(false, jsig));
		op(OpCheckcast(offset), 3, [stack.top()], [jsig]);
	}

	public function checkcast(path:JPath):Void {
		var offset = pool.addPath(path);
		var jsig = switch [path.pack, path.name] {
			case [[], "Int"]: JInt;
			case [["haxe" | "java"], "Int64"]: JLong;
			case _: JObject(path, []);
		}
		op(OpCheckcast(offset), 3, [stack.top()], [jsig]);
	}

	public function instanceof(path:JPath):Void {
		var offset = pool.addPath(path);
		op(OpInstanceof(offset), 3, [stack.top()], [JInt]);
	}

	/* monitor */
	public function monitorenter():Void op(OpMonitorenter, 1, [stack.top()], []);

	public function monitorexit():Void op(OpMonitorexit, 1, [stack.top()], []);

	/* constants */
	public function aconstNull(t:JSignature):Void op(OpAconst_null, 1, [], [t]);

	public function ldc(offset:Int, vt:JSignature):Void {
		if (offset < 0xFF) op(OpLdc(offset), 2, [], [vt]) else op(OpLdc_w(offset), 3, [], [vt]);
	}

	public function bconst(b:Bool):Void op(if (b) OpIconst_1 else OpIconst_0, 1, [], [JBool]);

	public function iconst(i32:Int):Void {
		var instr, count;
		switch i32 {
			case -1:
				instr = OpIconst_m1;
				count = 1;
			case 0:
				instr = OpIconst_0;
				count = 1;
			case 1:
				instr = OpIconst_1;
				count = 1;
			case 2:
				instr = OpIconst_2;
				count = 1;
			case 3:
				instr = OpIconst_3;
				count = 1;
			case 4:
				instr = OpIconst_4;
				count = 1;
			case 5:
				instr = OpIconst_5;
				count = 1;
			case i:
				switch JvmGlobals.getNumericRange(i) {
					case Int8Range:
						instr = OpBipush(i);
						count = 2;
					case Int16Range:
						instr = OpSipush(i);
						count = 3;
					case Int32Range:
						var offset = pool.add(ConstInt(i32));
						if (offset < 0xFF) {
							instr = OpLdc(offset);
							count = 2;
						} else {
							instr = OpLdc_w(offset);
							count = 3;
						}
				}
		}
		op(instr, count, [], [JInt]);
	}

	public function dconst(f:Float):Void {
		var instr, count;
		// port: OCaml float patterns compare with `=`, so -0.0 matches 0.0
		if (f == 0.0) {
			instr = OpDconst_0;
			count = 1;
		} else if (f == 1.0) {
			instr = OpDconst_1;
			count = 1;
		} else {
			var offset = pool.add(ConstDouble(f));
			instr = OpLdc2_w(offset);
			count = 3;
		}
		op(instr, count, [], [JDouble]);
	}

	public function lconst(d:haxe.Int64):Void {
		var instr, count;
		if (d == haxe.Int64.ofInt(0)) {
			instr = OpLconst_0;
			count = 1;
		} else if (d == haxe.Int64.ofInt(1)) {
			instr = OpLconst_1;
			count = 1;
		} else {
			var offset = pool.add(ConstLong(d));
			instr = OpLdc2_w(offset);
			count = 3;
		}
		op(instr, count, [], [JLong]);
	}

	public function fconst(f:Float):Void {
		var instr, count;
		if (f == 0.0) {
			instr = OpFconst_0;
			count = 1;
		} else if (f == 1.0) {
			instr = OpFconst_1;
			count = 1;
		} else if (f == 2.0) {
			instr = OpFconst_2;
			count = 1;
		} else {
			var offset = pool.add(ConstFloat(f));
			instr = OpLdc_w(offset);
			count = 3;
		}
		op(instr, count, [], [JFloat]);
	}

	public function sconst(t:JSignature, offset:Int):Void ldc(offset, t);

	public function getPool():JvmConstantPool return pool;

	public function getFp():Int return fp;

	public function getOps():Array<JOpcode> return ops;

	public function getStack():JvmStack return stack;

	public function getMaxStackSize():Int return stack.getMaxStackSize();

	public function getLines():Array<{pc:Int, line:Int}> return lines;

	public function setLine(line:Int):Void currentLine = line;

	public function exportCode():haxe.io.Bytes {
		var ch = new OutputBytes();
		for (o in ops) JvmWriter.writeOpcode(ch, o);
		return ch.closeOut();
	}
}
