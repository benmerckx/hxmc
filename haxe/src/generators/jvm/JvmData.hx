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

import haxe.io.Bytes;
import haxe.ds.Vector;
import generators.jvm.JvmGlobals;

/* Low-level data that is written out. */
@:structInit class JvmAttributeData {
	public var attrIndex:JvmConstantPoolIndex;
	public var attrData:Bytes;
}

@:structInit class JvmField {
	public var fieldAccessFlags:Int;
	public var fieldNameIndex:Int;
	public var fieldDescriptorIndex:Int;
	public var fieldAttributes:Vector<JvmAttributeData>;
}

@:structInit class JvmClassData {
	public var classMinorVersion:Int;
	public var classMajorVersion:Int;
	public var classConstantPool:Bytes;
	public var classAccessFlags:Int;
	public var classThisClass:Int;
	public var classSuperClass:Int;
	public var classInterfaces:Vector<Int>;
	public var classFields:Vector<JvmField>;
	public var classMethods:Vector<JvmField>;
	public var classAttributes:Vector<JvmAttributeData>;
}

@:structInit class JvmException {
	public var excStartPc:Int;
	public var excEndPc:Int;
	public var excHandlerPc:Int;
	public var excCatchType:Null<JvmConstantPoolIndex>;
}

@:structInit class JvmCodeData {
	public var codeMaxStack:Int;
	public var codeMaxLocals:Int;
	public var codeCode:Bytes;
	public var codeExceptions:Vector<JvmException>;
	public var codeAttributes:Vector<JvmAttributeData>;
}

/* Opcodes */
typedef JByte = Int;
typedef JShort = Int;
typedef JBranchOffset = Int;

// port: `jbranchoffset ref`
class JBranchOffsetRef {
	public var v:JBranchOffset;

	public inline function new(v:JBranchOffset) this.v = v;
}

enum JCmp {
	CmpEq;
	CmpNe;
	CmpLt;
	CmpGe;
	CmpGt;
	CmpLe;
}

enum OpWide {
	OpWIinc(i1:JShort, i2:JShort);
	OpWIload(i:JShort);
	OpWFload(i:JShort);
	OpWAload(i:JShort);
	OpWLload(i:JShort);
	OpWDload(i:JShort);
	OpWIstore(i:JShort);
	OpWFstore(i:JShort);
	OpWAstore(i:JShort);
	OpWLstore(i:JShort);
	OpWDstore(i:JShort);
}

enum JOpcode {
	/* double */
	OpD2f;
	OpD2i;
	OpD2l;
	OpDadd;
	OpDaload;
	OpDastore;
	OpDcmpg;
	OpDcmpl;
	OpDdiv;
	OpDconst_0;
	OpDconst_1;
	OpDload_0;
	OpDload_1;
	OpDload_2;
	OpDload_3;
	OpDload(i:JByte);
	OpDmul;
	OpDneg;
	OpDrem;
	OpDreturn;
	OpDstore_0;
	OpDstore_1;
	OpDstore_2;
	OpDstore_3;
	OpDstore(i:JByte);
	OpDsub;
	/* float */
	OpF2d;
	OpF2i;
	OpF2l;
	OpFadd;
	OpFaload;
	OpFastore;
	OpFcmpg;
	OpFcmpl;
	OpFdiv;
	OpFconst_0;
	OpFconst_1;
	OpFconst_2;
	OpFload_0;
	OpFload_1;
	OpFload_2;
	OpFload_3;
	OpFload(i:JByte);
	OpFmul;
	OpFneg;
	OpFrem;
	OpFreturn;
	OpFstore_0;
	OpFstore_1;
	OpFstore_2;
	OpFstore_3;
	OpFstore(i:JByte);
	OpFsub;
	/* int */
	OpI2b;
	OpI2c;
	OpI2d;
	OpI2f;
	OpI2l;
	OpI2s;
	OpIadd;
	OpIaload;
	OpIand;
	OpIastore;
	OpIconst_m1;
	OpIconst_0;
	OpIconst_1;
	OpIconst_2;
	OpIconst_3;
	OpIconst_4;
	OpIconst_5;
	OpIdiv;
	OpIload_0;
	OpIload_1;
	OpIload_2;
	OpIload_3;
	OpIload(i:JByte);
	OpImul;
	OpIneg;
	OpIor;
	OpIrem;
	OpIreturn;
	OpIshl;
	OpIshr;
	OpIstore_0;
	OpIstore_1;
	OpIstore_2;
	OpIstore_3;
	OpIstore(i:JByte);
	OpIsub;
	OpIushr;
	OpIxor;
	/* long */
	OpL2d;
	OpL2f;
	OpL2i;
	OpLadd;
	OpLaload;
	OpLand;
	OpLastore;
	OpLconst_0;
	OpLconst_1;
	OpLcmp;
	OpLdiv;
	OpLload_0;
	OpLload_1;
	OpLload_2;
	OpLload_3;
	OpLload(i:JByte);
	OpLmul;
	OpLneg;
	OpLor;
	OpLrem;
	OpLreturn;
	OpLshl;
	OpLshr;
	OpLstore_0;
	OpLstore_1;
	OpLstore_2;
	OpLstore_3;
	OpLstore(i:JByte);
	OpLsub;
	OpLushr;
	OpLxor;
	/* short */
	OpSaload;
	OpSastore;
	OpSipush(i:JShort);
	/* array */
	OpAaload;
	OpAastore;
	OpAnewarray(i:JvmConstantPoolIndex);
	OpArraylength;
	OpBaload;
	OpBastore;
	OpBipush(i:JByte);
	OpCaload;
	OpCastore;
	OpMultianewarray(i:JvmConstantPoolIndex, d:JByte);
	OpNewarray(i:JByte);
	/* reference */
	OpAload_0;
	OpAload_1;
	OpAload_2;
	OpAload_3;
	OpAload(i:JByte);
	OpAreturn;
	OpAstore_0;
	OpAstore_1;
	OpAstore_2;
	OpAstore_3;
	OpAstore(i:JByte);
	/* object */
	OpNew(i:JvmConstantPoolIndex);
	OpInstanceof(i:JvmConstantPoolIndex);
	OpCheckcast(i:JvmConstantPoolIndex);
	OpInvokedynamic(i:JvmConstantPoolIndex);
	OpInvokeinterface(i:JvmConstantPoolIndex, c:JByte);
	OpInvokespecial(i:JvmConstantPoolIndex);
	OpInvokestatic(i:JvmConstantPoolIndex);
	OpInvokevirtual(i:JvmConstantPoolIndex);
	OpGetfield(i:JvmConstantPoolIndex);
	OpGetstatic(i:JvmConstantPoolIndex);
	OpPutfield(i:JvmConstantPoolIndex);
	OpPutstatic(i:JvmConstantPoolIndex);
	/* branching */
	OpIf_acmpeq(r:JBranchOffsetRef);
	OpIf_acmpne(r:JBranchOffsetRef);
	OpIf_icmp(cmp:JCmp, r:JBranchOffsetRef);
	OpIf(cmp:JCmp, r:JBranchOffsetRef);
	OpIfnonnull(r:JBranchOffsetRef);
	OpIfnull(r:JBranchOffsetRef);
	OpGoto(r:JBranchOffsetRef);
	OpGoto_w(r:JBranchOffsetRef);
	OpJsr(r:JBranchOffsetRef);
	OpJsr_w(r:JBranchOffsetRef);
	/* stack */
	OpAconst_null;
	OpDup;
	OpDup_x1;
	OpDup_x2;
	OpDup2;
	OpDup2_x1;
	OpDup2_x2;
	OpLdc(i:JByte);
	OpLdc_w(i:JvmConstantPoolIndex);
	OpLdc2_w(i:JvmConstantPoolIndex);
	OpNop;
	OpPop;
	OpPop2;
	OpSwap;
	/* other */
	OpAthrow;
	OpIinc(i:JByte, c:JByte);
	OpLookupswitch(pad:Int /* num pad bytes */, def:JBranchOffsetRef /* default */, pairs:Vector<{key:Int, offset:JBranchOffsetRef}>);
	OpTableswitch(pad:Int /* num pad bytes */, def:JBranchOffsetRef /* default */, low:Int /* low */, high:Int /* high */,
		offsets:Vector<JBranchOffsetRef>);
	OpMonitorenter;
	OpMonitorexit;
	OpRet(i:JByte);
	OpReturn;
	OpWide(op:OpWide);
}
