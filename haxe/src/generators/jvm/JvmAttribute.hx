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

import haxe.ds.Vector;
import generators.jvm.JvmGlobals;
import generators.jvm.JvmData;
import generators.jvm.JvmVerificationTypeInfo;
import generators.jvm.JvmWriter;

@:structInit class JAnnotation {
	public var annType:Int;
	public var annElements:Vector<{index:JvmConstantPoolIndex, value:JAnnotationElementValue}>;
}

// port: `char * j_annotation_value`
@:structInit class JAnnotationElementValue {
	public var c:String;
	public var v:JAnnotationValue;
}

enum JAnnotationValue {
	ValConst(i:Int); /* B, C, D, E, F, I, J, S, Z, s */
	ValEnum(i1:Int, i2:Int); /* e */
	ValClass(i:Int); /* c */ /* V -> Void */
	ValAnnotation(a:JAnnotation); /* @ */
	ValArray(a:Vector<JAnnotationElementValue>); /* [ */
}

/* https://docs.oracle.com/javase/specs/jvms/se7/html/jvms-4.html#jvms-4.7.4 */
enum JStackMapFrame {
	StackSame(i:Int);
	Stack1StackItem(i:Int, t:VerificationTypeInfo);
	Stack1StackItemExtended(i:Int, t:VerificationTypeInfo);
	StackChop1(i:Int);
	StackChop2(i:Int);
	StackChop3(i:Int);
	StackSameExtended(i:Int);
	StackAppend1(i:Int, t1:VerificationTypeInfo);
	StackAppend2(i:Int, t1:VerificationTypeInfo, t2:VerificationTypeInfo);
	StackAppend3(i:Int, t1:VerificationTypeInfo, t2:VerificationTypeInfo, t3:VerificationTypeInfo);
	StackFull(i:Int, tl1:Vector<VerificationTypeInfo>, tl2:Vector<VerificationTypeInfo>);
}

/* https://docs.oracle.com/javase/specs/jvms/se7/html/jvms-4.html#jvms-4.7.13 */
@:structInit class JvmLocalDebug {
	public var ldStartPc:Int;
	public var ldLength:Int;
	public var ldNameIndex:JvmConstantPoolIndex;
	public var ldDescriptorIndex:JvmConstantPoolIndex;
	public var ldIndex:Int;
}

@:structInit class JvmInnerClass {
	public var icInnerClassInfoIndex:Int;
	public var icOuterClassInfoIndex:Int;
	public var icInnerNameIndex:Int;
	public var icInnerClassAccessFlags:Int;
}

@:structInit class JBootstrapMethod {
	public var bmMethodRef:JvmConstantPoolIndex;
	public var bmArguments:Vector<JvmConstantPoolIndex>;
}

/* https://docs.oracle.com/javase/specs/jvms/se7/html/jvms-4.html#jvms-4.7 */
enum JAttribute {
	AttributeConstantValue(i:JvmConstantPoolIndex);
	AttributeCode(code:JvmCodeData);
	AttributeStackMapTable(frames:Vector<JStackMapFrame>);
	AttributeExceptions(a:Vector<JvmConstantPoolIndex>);
	AttributeSourceFile(i:JvmConstantPoolIndex);
	AttributeLineNumberTable(a:Vector<{pc:Int, line:Int}>);
	AttributeSignature(i:JvmConstantPoolIndex);
	AttributeLocalVariableTable(a:Vector<JvmLocalDebug>);
	AttributeLocalVariableTypeTable(a:Vector<JvmLocalDebug>);
	AttributeInnerClasses(a:Vector<JvmInnerClass>);
	AttributeEnclosingMethod(i1:JvmConstantPoolIndex, i2:JvmConstantPoolIndex);
	AttributeRuntimeVisibleAnnotations(a:Vector<JAnnotation>);
	AttributeRuntimeInvisibleAnnotations(a:Vector<JAnnotation>);
	AttributeRuntimeVisibleParameterAnnotations(a:Vector<Vector<JAnnotation>>);
	AttributeRuntimeInvisibleParameterAnnotations(a:Vector<Vector<JAnnotation>>);
	AttributeBootstrapMethods(a:Vector<JBootstrapMethod>);
}

class JvmAttribute {
	public static function writeVerificationType(ch:OutputBytes, v:VerificationTypeInfo):Void {
		switch v {
			case VTop: ch.writeByte(0);
			case VInteger: ch.writeByte(1);
			case VFloat: ch.writeByte(2);
			case VDouble: ch.writeByte(3);
			case VLong: ch.writeByte(4);
			case VNull: ch.writeByte(5);
			case VUninitializedThis: ch.writeByte(6);
			case VObject(i):
				ch.writeByte(7);
				ch.writeUi16(i);
			case VUninitialized(i):
				ch.writeByte(8);
				ch.writeUi16(i);
		}
	}

	public static function writeStackMapFrame(ch:OutputBytes, f:JStackMapFrame):Void {
		switch f {
			case StackSame(i):
				if (!(i < 64)) throw new core.ds.Failure("assert");
				ch.writeByte(i);
			case Stack1StackItem(i, t):
				if (!(i < 64)) throw new core.ds.Failure("assert");
				ch.writeByte(i + 64);
				writeVerificationType(ch, t);
			case Stack1StackItemExtended(i, t):
				ch.writeByte(247);
				ch.writeUi16(i);
				writeVerificationType(ch, t);
			case StackChop1(i1):
				ch.writeByte(250);
				ch.writeUi16(i1);
			case StackChop2(i1):
				ch.writeByte(249);
				ch.writeUi16(i1);
			case StackChop3(i1):
				ch.writeByte(248);
				ch.writeUi16(i1);
			case StackSameExtended(i):
				ch.writeByte(251);
				ch.writeUi16(i);
			case StackAppend1(i1, t1):
				ch.writeByte(252);
				ch.writeUi16(i1);
				writeVerificationType(ch, t1);
			case StackAppend2(i1, t1, t2):
				ch.writeByte(253);
				ch.writeUi16(i1);
				writeVerificationType(ch, t1);
				writeVerificationType(ch, t2);
			case StackAppend3(i1, t1, t2, t3):
				ch.writeByte(254);
				ch.writeUi16(i1);
				writeVerificationType(ch, t1);
				writeVerificationType(ch, t2);
				writeVerificationType(ch, t3);
			case StackFull(i1, tl1, tl2):
				ch.writeByte(255);
				ch.writeUi16(i1);
				JvmGlobals.writeArray16(ch, writeVerificationType, tl1);
				JvmGlobals.writeArray16(ch, writeVerificationType, tl2);
		}
	}

	public static function writeConstant(pool:JvmConstantPool, ch:OutputBytes, const:JvmConstant):Void {
		var offset = pool.add(const);
		ch.writeUi16(offset);
	}

	public static function writeAnnotation(ch:OutputBytes, ann:JAnnotation):Void {
		ch.writeUi16(ann.annType);
		JvmGlobals.writeArray16(ch, function(_, e:{index:JvmConstantPoolIndex, value:JAnnotationElementValue}) {
			ch.writeUi16(e.index);
			function loop(_:OutputBytes, ev:JAnnotationElementValue):Void {
				ch.writeByte(ev.c.charCodeAt(0));
				switch ev.v {
					case ValConst(i):
						ch.writeUi16(i);
					case ValEnum(i1, i2):
						ch.writeUi16(i1);
						ch.writeUi16(i2);
					case ValClass(i):
						ch.writeUi16(i);
					case ValAnnotation(a):
						writeAnnotation(ch, a);
					case ValArray(annl):
						JvmGlobals.writeArray16(ch, loop, annl);
				}
			}
			loop(ch, e.value);
		}, ann.annElements);
	}

	public static function writeAttribute(pool:JvmConstantPool, jvma:JAttribute):JvmAttributeData {
		var ch = new OutputBytes();
		function writeLocalTable(table:Vector<JvmLocalDebug>):Void {
			JvmGlobals.writeArray16(ch, function(_, d:JvmLocalDebug) {
				ch.writeUi16(d.ldStartPc);
				ch.writeUi16(d.ldLength);
				ch.writeUi16(d.ldNameIndex);
				ch.writeUi16(d.ldDescriptorIndex);
				ch.writeUi16(d.ldIndex);
			}, table);
		}
		var name = switch jvma {
			case AttributeConstantValue(const):
				ch.writeUi16(const);
				"ConstantValue";
			case AttributeCode(code):
				ch.writeUi16(code.codeMaxStack);
				ch.writeUi16(code.codeMaxLocals);
				JvmGlobals.writeUi32(ch, code.codeCode.length);
				ch.nwrite(code.codeCode);
				JvmGlobals.writeArray16(ch, JvmWriter.writeException, code.codeExceptions);
				JvmWriter.writeJvmAttributes(ch, code.codeAttributes);
				"Code";
			case AttributeStackMapTable(stackMap):
				JvmGlobals.writeArray16(ch, writeStackMapFrame, stackMap);
				"StackMapTable";
			case AttributeExceptions(a):
				JvmGlobals.writeArray16(ch, function(_, offset) ch.writeUi16(offset), a);
				"Exceptions";
			case AttributeInnerClasses(icl):
				JvmGlobals.writeArray16(ch, function(ch, ic:JvmInnerClass) {
					ch.writeUi16(ic.icInnerClassInfoIndex);
					ch.writeUi16(ic.icOuterClassInfoIndex);
					ch.writeUi16(ic.icInnerNameIndex);
					ch.writeUi16(ic.icInnerClassAccessFlags);
				}, icl);
				"InnerClasses";
			case AttributeEnclosingMethod(i1, i2):
				ch.writeUi16(i1);
				ch.writeUi16(i2);
				"EnclosingMethod";
			case AttributeSourceFile(offset):
				ch.writeUi16(offset);
				"SourceFile";
			case AttributeLineNumberTable(a):
				JvmGlobals.writeArray16(ch, function(_, e:{pc:Int, line:Int}) {
					ch.writeUi16(e.pc);
					ch.writeUi16(e.line);
				}, a);
				"LineNumberTable";
			case AttributeSignature(offset):
				ch.writeUi16(offset);
				"Signature";
			case AttributeLocalVariableTable(table):
				writeLocalTable(table);
				"LocalVariableTable";
			case AttributeLocalVariableTypeTable(table):
				writeLocalTable(table);
				"LocalVariableTypeTable";
			case AttributeRuntimeVisibleAnnotations(al):
				JvmGlobals.writeArray16(ch, writeAnnotation, al);
				"RuntimeVisibleAnnotations";
			case AttributeRuntimeInvisibleAnnotations(al):
				JvmGlobals.writeArray16(ch, writeAnnotation, al);
				"RuntimeInvisibleAnnotations";
			case AttributeRuntimeVisibleParameterAnnotations(al):
				ch.writeByte(al.length);
				for (a in al) JvmGlobals.writeArray16(ch, writeAnnotation, a);
				"RuntimeVisibleParameterAnnotations";
			case AttributeRuntimeInvisibleParameterAnnotations(al):
				ch.writeByte(al.length);
				for (a in al) JvmGlobals.writeArray16(ch, writeAnnotation, a);
				"RuntimeInvisibleParameterAnnotations";
			case AttributeBootstrapMethods(a):
				JvmGlobals.writeArray16(ch, function(_, bm:JBootstrapMethod) {
					ch.writeUi16(bm.bmMethodRef);
					JvmGlobals.writeArray16(ch, function(_, i) ch.writeUi16(i), bm.bmArguments);
				}, a);
				"BootstrapMethods";
		}
		// port: the record fields are evaluated right to left: attr_data first, then attr_index.
		var attrData = ch.closeOut();
		var attrIndex = pool.add(ConstUtf8(name));
		return {attrIndex: attrIndex, attrData: attrData};
	}
}
