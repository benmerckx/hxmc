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

typedef JvmConstantPoolIndex = Int;

/* Constants */
typedef JvmBootstrapMethodIndex = Int;

enum JvmConstant {
	ConstUtf8(s:String);
	ConstInt(i:Int);
	ConstFloat(f:Float);
	ConstLong(i:haxe.Int64);
	ConstDouble(f:Float);
	ConstClass(i:JvmConstantPoolIndex);
	ConstString(i:JvmConstantPoolIndex);
	ConstFieldref(i1:JvmConstantPoolIndex, i2:JvmConstantPoolIndex);
	ConstMethodref(i1:JvmConstantPoolIndex, i2:JvmConstantPoolIndex);
	ConstInterfaceMethodref(i1:JvmConstantPoolIndex, i2:JvmConstantPoolIndex);
	ConstNameAndType(i1:JvmConstantPoolIndex, i2:JvmConstantPoolIndex);
	ConstMethodHandle(i:Int, i2:JvmConstantPoolIndex);
	ConstMethodType(i:JvmConstantPoolIndex);
	ConstInvokeDynamic(i1:JvmBootstrapMethodIndex, i2:JvmConstantPoolIndex);
}

enum FieldKind {
	FKField;
	FKMethod;
	FKInterfaceMethod;
}

enum NumericRange {
	Int8Range;
	Int16Range;
	Int32Range;
}

// port: `Overflow` of extlib's IO (raised by write_ui16 on out-of-range values).
class Overflow extends haxe.Exception {}

// port: IO.output_bytes with the IO.BigEndian writers used by the JVM generator.
class OutputBytes {
	final buf = new haxe.io.BytesBuffer();

	public function new() {}

	public inline function writeByte(i:Int):Void buf.addByte(i & 0xFF);

	public function writeUi16(i:Int):Void {
		if (i < 0 || i > 0xFFFF) throw new Overflow("write_ui16");
		writeByte(i >> 8);
		writeByte(i);
	}

	public function writeRealI32(i:Int):Void {
		writeByte(i >>> 24);
		writeByte(i >>> 16);
		writeByte(i >>> 8);
		writeByte(i);
	}

	public function writeDouble(f:Float):Void {
		var i64 = haxe.io.FPHelper.doubleToI64(f);
		writeRealI32(i64.high);
		writeRealI32(i64.low);
	}

	public inline function nwrite(b:Bytes):Void buf.add(b);

	public inline function nwriteString(s:String):Void buf.add(Bytes.ofString(s));

	public inline function closeOut():Bytes return buf.getBytes();
}

class ClassAccessFlags {
	public static function toInt(f:ClassAccessFlag):Int return switch f {
		case CPublic: 0x1;
		case CFinal: 0x10;
		case CSuper: 0x20;
		case CInterface: 0x200;
		case CAbstract: 0x400;
		case CSynthetic: 0x1000;
		case CAnnotation: 0x2000;
		case CEnum: 0x4000;
	}

	public static function hasFlag(b:Int, flag:ClassAccessFlag):Bool return b & toInt(flag) != 0;
}

// port: ClassAccessFlags.t
enum ClassAccessFlag {
	CPublic;
	CFinal;
	CSuper;
	CInterface;
	CAbstract;
	CSynthetic;
	CAnnotation;
	CEnum;
}

// port: MethodAccessFlags.t
enum MethodAccessFlags {
	MPublic;
	MPrivate;
	MProtected;
	MStatic;
	MFinal;
	MSynchronized;
	MBridge;
	MVarargs;
	MNative;
	MAbstract;
	MStrict;
	MSynthetic;
}

class MethodAccessFlagsTools {
	public static function toInt(f:MethodAccessFlags):Int return switch f {
		case MPublic: 0x1;
		case MPrivate: 0x2;
		case MProtected: 0x4;
		case MStatic: 0x8;
		case MFinal: 0x10;
		case MSynchronized: 0x20;
		case MBridge: 0x40;
		case MVarargs: 0x80;
		case MNative: 0x100;
		case MAbstract: 0x400;
		case MStrict: 0x800;
		case MSynthetic: 0x1000;
	}

	public static function hasFlag(b:Int, flag:MethodAccessFlags):Bool return b & toInt(flag) != 0;
}

// port: FieldAccessFlags.t
enum FieldAccessFlags {
	FdPublic;
	FdPrivate;
	FdProtected;
	FdStatic;
	FdFinal;
	FdVolatile;
	FdTransient;
	FdSynthetic;
	FdEnum;
}

class FieldAccessFlagsTools {
	public static function toInt(f:FieldAccessFlags):Int return switch f {
		case FdPublic: 0x1;
		case FdPrivate: 0x2;
		case FdProtected: 0x4;
		case FdStatic: 0x8;
		case FdFinal: 0x10;
		case FdVolatile: 0x40;
		case FdTransient: 0x80;
		case FdSynthetic: 0x1000;
		case FdEnum: 0x4000;
	}

	public static function hasFlag(b:Int, flag:FieldAccessFlags):Bool return b & toInt(flag) != 0;
}

class JvmGlobals {
	public static function getNumericRange(i:Int):NumericRange {
		return if (i >= -128 && i <= 127) Int8Range else if (i >= -32768 && i <= 32767) Int16Range else Int32Range;
	}

	public static function getNumericRangeUnsigned(i:Int):NumericRange {
		return if (i <= 0xFF) Int8Range else if (i <= 0xFFFF) Int16Range else Int32Range;
	}

	public static function inRange(unsigned:Bool, range:NumericRange, i:Int):Bool {
		return switch [(if (unsigned) getNumericRangeUnsigned else getNumericRange)(i), range] {
			case [Int8Range, (Int8Range | Int16Range | Int32Range)]: true;
			case [Int16Range, (Int16Range | Int32Range)]: true;
			case [Int32Range, Int32Range]: true;
			case _: false;
		}
	}

	public static function jerror(s:String):Dynamic {
		throw new core.ds.Failure(s);
	}

	public static inline function writeByte(ch:OutputBytes, i:Int):Void ch.writeByte(i);

	public static inline function writeBytes(ch:OutputBytes, b:Bytes):Void ch.nwrite(b);

	public static inline function writeUi16(ch:OutputBytes, i:Int):Void ch.writeUi16(i);

	public static inline function writeUi32(ch:OutputBytes, i:Int):Void ch.writeRealI32(i);

	public static inline function writeString(ch:OutputBytes, s:String):Void ch.nwriteString(s);

	// port: inline: hxmc erases type parameters, and a Vector read in generic code has no
	// known element type (dynamic accesses)
	public static inline function writeArray16<A>(ch:OutputBytes, f:OutputBytes->A->Void, a:haxe.ds.Vector<A>):Void {
		writeUi16(ch, a.length);
		for (x in a) f(ch, x);
	}

	public static function patchName(name:String):String return switch name {
		case "<init>": "new";
		case "<clinit>": "__init__";
		case name: name;
	}
}
