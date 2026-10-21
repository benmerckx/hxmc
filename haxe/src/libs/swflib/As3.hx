/*
 *  This file is part of SwfLib
 *  Copyright (c)2004-2006 Nicolas Cannasse
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
 */

package libs.swflib;

import haxe.ds.Vector;

// port: haxe/libs/swflib/as3.mli. `'a index` and `'a index_nz` are plain Ints
// (the phantom type is not kept); `MultiArray.t` is an Array, an OCaml array a Vector.
typedef Index = Int;
typedef IndexNz = Int;
typedef As3Ident = String;
typedef As3Int = Int;
typedef As3Uint = Int;
typedef As3Float = Float;
typedef As3Slot = Int;
typedef Reg = Int;
typedef Nargs = Int;

enum As3Jump {
	J3NotLt;
	J3NotLte;
	J3NotGt;
	J3NotGte;
	J3Always;
	J3True;
	J3False;
	J3Eq;
	J3Neq;
	J3Lt;
	J3Lte;
	J3Gt;
	J3Gte;
	J3PhysEq;
	J3PhysNeq;
}

enum As3Op {
	A3OAs;
	A3ONeg;
	A3OIncr;
	A3ODecr;
	A3ONot;
	A3OBitNot;
	A3OAdd;
	A3OSub;
	A3OMul;
	A3ODiv;
	A3OMod;
	A3OShl;
	A3OShr;
	A3OUShr;
	A3OAnd;
	A3OOr;
	A3OXor;
	A3OEq;
	A3OPhysEq;
	A3OLt;
	A3OLte;
	A3OGt;
	A3OGte;
	A3OIs;
	A3OIn;
	A3OIIncr;
	A3OIDecr;
	A3OINeg;
	A3OIAdd;
	A3OISub;
	A3OIMul;
	A3OMemSet8;
	A3OMemSet16;
	A3OMemSet32;
	A3OMemSetFloat;
	A3OMemSetDouble;
	A3OMemGet8;
	A3OMemGet16;
	A3OMemGet32;
	A3OMemGetFloat;
	A3OMemGetDouble;
	A3OSign1;
	A3OSign8;
	A3OSign16;
}

typedef As3Name = Index;

enum As3Opcode {
	A3BreakPoint;
	A3Nop;
	A3Throw;
	A3GetSuper(n:As3Name);
	A3SetSuper(n:As3Name);
	A3DxNs(i:Index);
	A3DxNsLate;
	A3RegKill(r:Reg);
	A3Label;
	A3Jump(j:As3Jump, n:Int);
	A3Switch(n:Int, l:Array<Int>);
	A3PushWith;
	A3PopScope;
	A3ForIn;
	A3HasNext;
	A3Null;
	A3Undefined;
	A3ForEach;
	A3SmallInt(n:Int);
	A3Int(n:Int);
	A3True;
	A3False;
	A3NaN;
	A3Pop;
	A3Dup;
	A3Swap;
	A3String(i:Index);
	A3IntRef(i:Index);
	A3UIntRef(i:Index);
	A3Float(i:Index);
	A3Scope;
	A3Namespace(i:Index);
	A3Next(r1:Reg, r2:Reg);
	A3Function(i:IndexNz);
	A3CallStack(n:Nargs);
	A3Construct(n:Nargs);
	A3CallMethod(s:As3Slot, n:Nargs);
	A3CallStatic(i:Index, n:Nargs);
	A3CallSuper(p:As3Name, n:Nargs);
	A3CallProperty(p:As3Name, n:Nargs);
	A3RetVoid;
	A3Ret;
	A3ConstructSuper(n:Nargs);
	A3ConstructProperty(p:As3Name, n:Nargs);
	A3CallPropLex(p:As3Name, n:Nargs);
	A3CallSuperVoid(p:As3Name, n:Nargs);
	A3CallPropVoid(p:As3Name, n:Nargs);
	A3ApplyType(n:Nargs);
	A3Object(n:Nargs);
	A3Array(n:Nargs);
	A3NewBlock;
	A3ClassDef(i:IndexNz);
	A3GetDescendants(p:As3Name);
	A3Catch(n:Int);
	A3FindPropStrict(p:As3Name);
	A3FindProp(p:As3Name);
	A3FindDefinition(p:As3Name);
	A3GetLex(p:As3Name);
	A3SetProp(p:As3Name);
	A3Reg(r:Reg);
	A3SetReg(r:Reg);
	A3GetGlobalScope;
	A3GetScope(n:Int);
	A3GetProp(p:As3Name);
	A3InitProp(p:As3Name);
	A3DeleteProp(p:As3Name);
	A3GetSlot(s:As3Slot);
	A3SetSlot(s:As3Slot);
	A3ToString;
	A3ToXml;
	A3ToXmlAttr;
	A3ToInt;
	A3ToUInt;
	A3ToNumber;
	A3ToBool;
	A3ToObject;
	A3CheckIsXml;
	A3Cast(p:As3Name);
	A3AsAny;
	A3AsString;
	A3AsType(p:As3Name);
	A3AsObject;
	A3IncrReg(r:Reg);
	A3DecrReg(r:Reg);
	A3Typeof;
	A3InstanceOf;
	A3IsType(p:As3Name);
	A3IncrIReg(r:Reg);
	A3DecrIReg(r:Reg);
	A3This;
	A3SetThis;
	A3DebugReg(i:Index, r:Reg, line:Int);
	A3DebugLine(n:Int);
	A3DebugFile(i:Index);
	A3BreakPointLine(n:Int);
	A3Timestamp;
	A3Op(op:As3Op);
	A3Unk(c:Int);
}

enum As3Namespace {
	A3NPrivate(i:Null<Index>);
	A3NPublic(i:Null<Index>);
	A3NInternal(i:Null<Index>);
	A3NProtected(i:Index);
	A3NNamespace(i:Index);
	A3NExplicit(i:Index);
	A3NStaticProtected(i:Null<Index>);
}

typedef As3NsSet = Array<Index>;

enum As3MultiName {
	A3MName(id:Index, ns:Index);
	A3MMultiName(id:Null<Index>, ns:Index);
	A3MRuntimeName(id:Index);
	A3MRuntimeNameLate;
	A3MMultiNameLate(ns:Index);
	A3MAttrib(n:As3MultiName);
	A3MParams(id:Index, pl:Array<Index>);
	A3MNSAny(id:Index);
	A3MAny;
}

enum As3Value {
	A3VNone;
	A3VNull;
	A3VBool(b:Bool);
	A3VString(i:Index);
	A3VInt(i:Index);
	A3VUInt(i:Index);
	A3VFloat(i:Index);
	A3VNamespace(kind:Int, i:Index); /* int : kind of namespace */
}

typedef As3MethodType = {
	var mt3_ret:Null<As3Name>;
	var mt3_args:Array<Null<As3Name>>;
	var mt3_native:Bool;
	var mt3_var_args:Bool;
	var mt3_arguments_defined:Bool;
	var mt3_uses_dxns:Bool;
	var mt3_new_block:Bool;
	var mt3_unused_flag:Bool;
	var mt3_debug_name:Null<Index>;
	var mt3_dparams:Null<Array<As3Value>>;
	var mt3_pnames:Null<Array<Null<Index>>>;
}

enum As3MethodKind {
	MK3Normal;
	MK3Getter;
	MK3Setter;
}

typedef As3Method = {
	var m3_type:IndexNz;
	var m3_final:Bool;
	var m3_override:Bool;
	var m3_kind:As3MethodKind;
}

typedef As3Var = {
	var v3_type:Null<As3Name>;
	var v3_value:As3Value;
	var v3_const:Bool;
}

typedef As3Metadata = {
	var meta3_name:Index;
	var meta3_data:Vector<{k:Null<Index>, v:Index}>;
}

enum As3FieldKind {
	A3FMethod(m:As3Method);
	A3FVar(v:As3Var);
	A3FClass(c:IndexNz);
	A3FFunction(f:IndexNz);
}

typedef As3Field = {
	var f3_name:As3Name;
	var f3_slot:As3Slot;
	var f3_kind:As3FieldKind;
	var f3_metas:Null<Vector<IndexNz>>;
}

typedef As3Class = {
	var cl3_name:As3Name;
	var cl3_super:Null<As3Name>;
	var cl3_sealed:Bool;
	var cl3_final:Bool;
	var cl3_interface:Bool;
	var cl3_namespace:Null<Index>;
	var cl3_implements:Vector<As3Name>;
	var cl3_construct:IndexNz;
	var cl3_fields:Vector<As3Field>;
}

typedef As3Static = {
	var st3_method:IndexNz;
	var st3_fields:Vector<As3Field>;
}

typedef As3TryCatch = {
	var tc3_start:Int;
	var tc3_end:Int;
	var tc3_handle:Int;
	var tc3_type:Null<As3Name>;
	var tc3_name:Null<As3Name>;
}

typedef As3Function = {
	var fun3_id:IndexNz;
	var fun3_stack_size:Int;
	var fun3_nregs:Int;
	var fun3_init_scope:Int;
	var fun3_max_scope:Int;
	var fun3_code:Array<As3Opcode>;
	var fun3_trys:Vector<As3TryCatch>;
	var fun3_locals:Vector<As3Field>;
}

typedef As3Tag = {
	var as3_ints:Vector<As3Int>;
	var as3_uints:Vector<As3Uint>;
	var as3_floats:Vector<As3Float>;
	var as3_idents:Vector<As3Ident>;
	var as3_namespaces:Vector<As3Namespace>;
	var as3_nsets:Vector<As3NsSet>;
	var as3_names:Vector<As3MultiName>;
	var as3_method_types:Vector<As3MethodType>;
	var as3_metadatas:Vector<As3Metadata>;
	var as3_classes:Vector<As3Class>;
	var as3_statics:Vector<As3Static>;
	var as3_inits:Vector<As3Static>;
	var as3_functions:Vector<As3Function>;
	var as3_unknown:String; /* only for partial parsing */
}
