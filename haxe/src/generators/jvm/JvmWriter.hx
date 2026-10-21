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

/* Low-level writing corresponding to jvmData. */
class JvmWriter {
	public static function writeJvmAttribute(ch:OutputBytes, jvma:JvmAttributeData):Void {
		ch.writeUi16(jvma.attrIndex);
		JvmGlobals.writeUi32(ch, jvma.attrData.length);
		ch.nwrite(jvma.attrData);
	}

	public static function writeJvmAttributes(ch:OutputBytes, jvmal:haxe.ds.Vector<JvmAttributeData>):Void {
		JvmGlobals.writeArray16(ch, writeJvmAttribute, jvmal);
	}

	public static function writeJvmField(ch:OutputBytes, jvmf:JvmField):Void {
		ch.writeUi16(jvmf.fieldAccessFlags);
		ch.writeUi16(jvmf.fieldNameIndex);
		ch.writeUi16(jvmf.fieldDescriptorIndex);
		writeJvmAttributes(ch, jvmf.fieldAttributes);
	}

	public static function writeJvmClass(ch:OutputBytes, jvmc:JvmClassData):Void {
		ch.writeByte(0xCA);
		ch.writeByte(0xFE);
		ch.writeByte(0xBA);
		ch.writeByte(0xBE);
		ch.writeUi16(jvmc.classMinorVersion);
		ch.writeUi16(jvmc.classMajorVersion);
		ch.nwrite(jvmc.classConstantPool);
		ch.writeUi16(jvmc.classAccessFlags);
		ch.writeUi16(jvmc.classThisClass);
		ch.writeUi16(jvmc.classSuperClass);
		ch.writeUi16(jvmc.classInterfaces.length);
		for (i in jvmc.classInterfaces) ch.writeUi16(i);
		ch.writeUi16(jvmc.classFields.length);
		for (f in jvmc.classFields) writeJvmField(ch, f);
		ch.writeUi16(jvmc.classMethods.length);
		for (f in jvmc.classMethods) writeJvmField(ch, f);
		writeJvmAttributes(ch, jvmc.classAttributes);
	}

	/* Level 2: Targeting JVM structures */
	public static function writeException(ch:OutputBytes, jvme:JvmException):Void {
		ch.writeUi16(jvme.excStartPc);
		ch.writeUi16(jvme.excEndPc);
		ch.writeUi16(jvme.excHandlerPc);
		switch jvme.excCatchType {
			case null: ch.writeUi16(0);
			case t: ch.writeUi16(t);
		}
	}

	public static function writeOpcode(ch:OutputBytes, code:JOpcode):Void {
		inline function w(i:Int) ch.writeByte(i);
		inline function wr(i32:Int) ch.writeByte(i32);
		/* TODO: probably don't need these */
		function bp(i:Int) {
			w((i >>> 8) & 0xFF);
			w(i & 0xFF);
		}
		function b4(i:Int) {
			w((i >>> 24) & 0xFF);
			w((i >>> 16) & 0xFF);
			w((i >>> 8) & 0xFF);
			w(i & 0xFF);
		}
		function b4r(i32:Int) {
			wr((i32 >>> 24) & 0xFF);
			wr((i32 >>> 16) & 0xFF);
			wr((i32 >>> 8) & 0xFF);
			wr(i32 & 0xFF);
		}
		switch code {
			/* double */
			case OpD2f:
				w(0x90);
			case OpD2i:
				w(0x8e);
			case OpD2l:
				w(0x8f);
			case OpDadd:
				w(0x63);
			case OpDaload:
				w(0x31);
			case OpDastore:
				w(0x52);
			case OpDcmpg:
				w(0x98);
			case OpDcmpl:
				w(0x97);
			case OpDdiv:
				w(0x6f);
			case OpDconst_0:
				w(0xe);
			case OpDconst_1:
				w(0xf);
			case OpDload_0:
				w(0x26);
			case OpDload_1:
				w(0x27);
			case OpDload_2:
				w(0x28);
			case OpDload_3:
				w(0x29);
			case OpDload(i):
				w(0x18); w(i);
			case OpDmul:
				w(0x6b);
			case OpDneg:
				w(0x77);
			case OpDrem:
				w(0x73);
			case OpDreturn:
				w(0xaf);
			case OpDstore_0:
				w(0x47);
			case OpDstore_1:
				w(0x48);
			case OpDstore_2:
				w(0x49);
			case OpDstore_3:
				w(0x4a);
			case OpDstore(i):
				w(0x39); w(i);
			case OpDsub:
				w(0x67);
			/* float */
			case OpF2d:
				w(0x8d);
			case OpF2i:
				w(0x8b);
			case OpF2l:
				w(0x8c);
			case OpFadd:
				w(0x62);
			case OpFaload:
				w(0x30);
			case OpFastore:
				w(0x51);
			case OpFcmpg:
				w(0x96);
			case OpFcmpl:
				w(0x95);
			case OpFdiv:
				w(0x6e);
			case OpFconst_0:
				w(0xb);
			case OpFconst_1:
				w(0xc);
			case OpFconst_2:
				w(0xd);
			case OpFload_0:
				w(0x22);
			case OpFload_1:
				w(0x23);
			case OpFload_2:
				w(0x24);
			case OpFload_3:
				w(0x25);
			case OpFload(i):
				w(0x17); w(i);
			case OpFmul:
				w(0x6a);
			case OpFneg:
				w(0x76);
			case OpFrem:
				w(0x72);
			case OpFreturn:
				w(0xae);
			case OpFstore_0:
				w(0x43);
			case OpFstore_1:
				w(0x44);
			case OpFstore_2:
				w(0x45);
			case OpFstore_3:
				w(0x46);
			case OpFstore(i):
				w(0x38); w(i);
			case OpFsub:
				w(0x66);
			/* int */
			case OpI2b:
				w(0x91);
			case OpI2c:
				w(0x92);
			case OpI2d:
				w(0x87);
			case OpI2f:
				w(0x86);
			case OpI2l:
				w(0x85);
			case OpI2s:
				w(0x93);
			case OpIadd:
				w(0x60);
			case OpIaload:
				w(0x2e);
			case OpIand:
				w(0x7e);
			case OpIastore:
				w(0x4f);
			case OpIconst_m1:
				w(0x2);
			case OpIconst_0:
				w(0x3);
			case OpIconst_1:
				w(0x4);
			case OpIconst_2:
				w(0x5);
			case OpIconst_3:
				w(0x6);
			case OpIconst_4:
				w(0x7);
			case OpIconst_5:
				w(0x8);
			case OpIdiv:
				w(0x6c);
			case OpIload_0:
				w(0x1a);
			case OpIload_1:
				w(0x1b);
			case OpIload_2:
				w(0x1c);
			case OpIload_3:
				w(0x1d);
			case OpIload(i):
				w(0x15); w(i);
			case OpImul:
				w(0x68);
			case OpIneg:
				w(0x74);
			case OpIor:
				w(0x80);
			case OpIrem:
				w(0x70);
			case OpIreturn:
				w(0xac);
			case OpIshl:
				w(0x78);
			case OpIshr:
				w(0x7a);
			case OpIstore_0:
				w(0x3b);
			case OpIstore_1:
				w(0x3c);
			case OpIstore_2:
				w(0x3d);
			case OpIstore_3:
				w(0x3e);
			case OpIstore(i):
				w(0x36); w(i);
			case OpIsub:
				w(0x64);
			case OpIushr:
				w(0x7c);
			case OpIxor:
				w(0x82);
			/* long */
			case OpL2d:
				w(0x8a);
			case OpL2f:
				w(0x89);
			case OpL2i:
				w(0x88);
			case OpLadd:
				w(0x61);
			case OpLaload:
				w(0x2f);
			case OpLand:
				w(0x7f);
			case OpLastore:
				w(0x50);
			case OpLconst_0:
				w(0x9);
			case OpLconst_1:
				w(0xa);
			case OpLcmp:
				w(0x94);
			case OpLdiv:
				w(0x6d);
			case OpLload_0:
				w(0x1e);
			case OpLload_1:
				w(0x1f);
			case OpLload_2:
				w(0x20);
			case OpLload_3:
				w(0x21);
			case OpLload(i):
				w(0x16); w(i);
			case OpLmul:
				w(0x69);
			case OpLneg:
				w(0x75);
			case OpLor:
				w(0x81);
			case OpLrem:
				w(0x71);
			case OpLreturn:
				w(0xad);
			case OpLshl:
				w(0x79);
			case OpLshr:
				w(0x7b);
			case OpLstore_0:
				w(0x3f);
			case OpLstore_1:
				w(0x40);
			case OpLstore_2:
				w(0x41);
			case OpLstore_3:
				w(0x42);
			case OpLstore(i):
				w(0x37); w(i);
			case OpLsub:
				w(0x65);
			case OpLushr:
				w(0x7d);
			case OpLxor:
				w(0x83);
			/* short */
			case OpSaload:
				w(0x35);
			case OpSastore:
				w(0x56);
			case OpSipush(i):
				w(0x11); bp(i);
			/* array */
			case OpAaload:
				w(0x32);
			case OpAastore:
				w(0x53);
			case OpAnewarray(offset):
				w(0xbd); bp(offset);
			case OpArraylength:
				w(0xbe);
			case OpBaload:
				w(0x33);
			case OpBastore:
				w(0x54);
			case OpBipush(i):
				w(0x10); w(i);
			case OpCaload:
				w(0x34);
			case OpCastore:
				w(0x55);
			case OpMultianewarray(offset,d):
				w(0xc5); bp(offset); w(d);
			case OpNewarray(t):
				w(0xbc); w(t);
			/* reference */
			case OpAload_0:
				w(0x2a);
			case OpAload_1:
				w(0x2b);
			case OpAload_2:
				w(0x2c);
			case OpAload_3:
				w(0x2d);
			case OpAload(i):
				w(0x19); w(i);
			case OpAreturn:
				w(0xb0);
			case OpAstore_0:
				w(0x4b);
			case OpAstore_1:
				w(0x4c);
			case OpAstore_2:
				w(0x4d);
			case OpAstore_3:
				w(0x4e);
			case OpAstore(i):
				w(0x3a); w(i);
			/* object */
			case OpNew(offset):
				w(0xbb); bp(offset);
			case OpInstanceof(offset):
				w(0xc1); bp(offset);
			case OpCheckcast(offset):
				w(0xc0); bp(offset);
			case OpInvokedynamic(offset):
				w(0xba); bp(offset); w(0); w(0); /* ??? */
			case OpInvokeinterface(offset,c):
				w(0xb9); bp(offset); w(c); w(0);
			case OpInvokespecial(offset):
				w(0xb7); bp(offset);
			case OpInvokestatic(offset):
				w(0xb8); bp(offset);
			case OpInvokevirtual(offset):
				w(0xb6); bp(offset);
			case OpGetfield(offset):
				w(0xb4); bp(offset);
			case OpGetstatic(offset):
				w(0xb2); bp(offset);
			case OpPutfield(offset):
				w(0xb5); bp(offset);
			case OpPutstatic(offset):
				w(0xb3); bp(offset);
			/* branching */
			case OpIf_acmpeq(i):
				w(0xa5); bp(i.v);
			case OpIf_acmpne(i):
				w(0xa6); bp(i.v);
			case OpIf_icmp(cmp, i):
				switch cmp {
					case CmpEq: w(0x9f);
					case CmpNe: w(0xa0);
					case CmpLt: w(0xa1);
					case CmpGe: w(0xa2);
					case CmpGt: w(0xa3);
					case CmpLe: w(0xa4);
				}
				bp(i.v);
			case OpIf(cmp, i):
				switch cmp {
					case CmpEq: w(0x99);
					case CmpNe: w(0x9a);
					case CmpLt: w(0x9b);
					case CmpGe: w(0x9c);
					case CmpGt: w(0x9d);
					case CmpLe: w(0x9e);
				}
				bp(i.v);
			case OpIfnonnull(i):
				w(0xc7); bp(i.v);
			case OpIfnull(i):
				w(0xc6); bp(i.v);
			case OpGoto(i):
				w(0xa7); bp(i.v);
			case OpGoto_w(i):
				w(0xc8); b4(i.v);
			case OpJsr(i):
				w(0xa8); bp(i.v);
			case OpJsr_w(i):
				w(0xc9); b4(i.v);
			/* stack */
			case OpAconst_null:
				w(0x1);
			case OpDup:
				w(0x59);
			case OpDup_x1:
				w(0x5a);
			case OpDup_x2:
				w(0x5b);
			case OpDup2:
				w(0x5c);
			case OpDup2_x1:
				w(0x5d);
			case OpDup2_x2:
				w(0x5e);
			case OpLdc(i):
				w(0x12); w(i);
			case OpLdc_w(i):
				w(0x13); bp(i);
			case OpLdc2_w(i):
				w(0x14); bp(i);
			case OpNop:
				w(0x0);
			case OpPop:
				w(0x57);
			case OpPop2:
				w(0x58);
			case OpSwap:
				w(0x5f);
			/* other */
			case OpAthrow:
				w(0xbf);
			case OpIinc(i,c):
				w(0x84); w(i); w(c); /* TODO: signed? */
			case OpLookupswitch(pad, def, pairs):
				w(0xab);
				if (pad > 0) for (_ in 0...pad) w(0);
				b4(def.v);
				b4(pairs.length);
				for (p in pairs) {
					b4r(p.key);
					b4(p.offset.v);
				}
			case OpTableswitch(pad, def, low, high, offsets):
				w(0xaa);
				if (pad > 0) for (_ in 0...pad) w(0);
				b4(def.v);
				b4r(low);
				b4r(high);
				for (offset in offsets) b4(offset.v);
			case OpMonitorenter:
				w(0xc2);
			case OpMonitorexit:
				w(0xc3);
			case OpRet(i):
				w(0xa9); w(i);
			case OpReturn:
				w(0xb1);
			case OpWide(op):
				w(0xc4);
				switch op {
					case OpWIinc(i1, i2):
						w(0x84); bp(i1); bp(i2);
					case OpWIload(i): w(0x15); bp(i);
					case OpWFload(i): w(0x17); bp(i);
					case OpWAload(i): w(0x19); bp(i);
					case OpWLload(i): w(0x16); bp(i);
					case OpWDload(i): w(0x18); bp(i);
					case OpWIstore(i): w(0x36); bp(i);
					case OpWFstore(i): w(0x38); bp(i);
					case OpWAstore(i): w(0x3a); bp(i);
					case OpWLstore(i): w(0x37); bp(i);
					case OpWDstore(i): w(0x39); bp(i);
				}
		}
	}
}
