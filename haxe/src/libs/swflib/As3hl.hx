/*
 *  This file is part of SwfLib
 *  Copyright (c)2004-2008 Nicolas Cannasse
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
import libs.swflib.As3;

// port: haxe/libs/swflib/as3hl.mli. hl_method and hl_class are compared by
// identity (List.memq, ==) and mutated, so they are classes; `MultiArray.t`
// is an Array, an OCaml array a Vector.
typedef HlIdent = String;
typedef HlInt = Int;
typedef HlUint = Int;
typedef HlFloat = Float;
typedef HlSlot = Int;
typedef HlJump = As3Jump;
typedef HlOp = As3Op;

enum HlOpcode {
	HBreakPoint;
	HNop;
	HThrow;
	HGetSuper(n:HlName);
	HSetSuper(n:HlName);
	HDxNs(i:HlIdent);
	HDxNsLate;
	HRegKill(r:Reg);
	HLabel;
	HJump(j:HlJump, n:Int);
	HSwitch(n:Int, l:Array<Int>);
	HPushWith;
	HPopScope;
	HForIn;
	HHasNext;
	HNull;
	HUndefined;
	HForEach;
	HSmallInt(n:Int);
	HInt(n:Int);
	HTrue;
	HFalse;
	HNaN;
	HPop;
	HDup;
	HSwap;
	HString(s:HlIdent);
	HIntRef(i:HlInt);
	HUIntRef(i:HlUint);
	HFloat(f:HlFloat);
	HScope;
	HNamespace(ns:HlNamespace);
	HNext(r1:Reg, r2:Reg);
	HFunction(m:HlMethod);
	HCallStack(n:Nargs);
	HConstruct(n:Nargs);
	HCallMethod(s:HlSlot, n:Nargs);
	HCallStatic(m:HlMethod, n:Nargs);
	HCallSuper(p:HlName, n:Nargs);
	HCallProperty(p:HlName, n:Nargs);
	HRetVoid;
	HRet;
	HConstructSuper(n:Nargs);
	HConstructProperty(p:HlName, n:Nargs);
	HCallPropLex(p:HlName, n:Nargs);
	HCallSuperVoid(p:HlName, n:Nargs);
	HCallPropVoid(p:HlName, n:Nargs);
	HApplyType(n:Nargs);
	HObject(n:Nargs);
	HArray(n:Nargs);
	HNewBlock;
	HClassDef(c:HlClass);
	HGetDescendants(p:HlName);
	HCatch(n:Int);
	HFindPropStrict(p:HlName);
	HFindProp(p:HlName);
	HFindDefinition(p:HlName);
	HGetLex(p:HlName);
	HSetProp(p:HlName);
	HReg(r:Reg);
	HSetReg(r:Reg);
	HGetGlobalScope;
	HGetScope(n:Int);
	HGetProp(p:HlName);
	HInitProp(p:HlName);
	HDeleteProp(p:HlName);
	HGetSlot(s:HlSlot);
	HSetSlot(s:HlSlot);
	HToString;
	HToXml;
	HToXmlAttr;
	HToInt;
	HToUInt;
	HToNumber;
	HToBool;
	HToObject;
	HCheckIsXml;
	HCast(p:HlName);
	HAsAny;
	HAsString;
	HAsType(p:HlName);
	HAsObject;
	HIncrReg(r:Reg);
	HDecrReg(r:Reg);
	HTypeof;
	HInstanceOf;
	HIsType(p:HlName);
	HIncrIReg(r:Reg);
	HDecrIReg(r:Reg);
	HThis;
	HSetThis;
	HDebugReg(name:HlIdent, r:Reg, line:Int);
	HDebugLine(n:Int);
	HDebugFile(f:HlIdent);
	HBreakPointLine(n:Int);
	HTimestamp;
	HOp(op:HlOp);
	HUnk(c:Int);
}

enum HlNamespace {
	HNPrivate(i:Null<HlIdent>);
	HNPublic(i:Null<HlIdent>);
	HNInternal(i:Null<HlIdent>);
	HNProtected(i:HlIdent);
	HNNamespace(i:HlIdent);
	HNExplicit(i:HlIdent);
	HNStaticProtected(i:Null<HlIdent>);
}

typedef HlNsSet = Array<HlNamespace>;

enum HlName {
	HMPath(pack:Array<HlIdent>, name:HlIdent);
	HMName(i:HlIdent, ns:HlNamespace);
	HMMultiName(i:Null<HlIdent>, ns:HlNsSet);
	HMRuntimeName(i:HlIdent);
	HMRuntimeNameLate;
	HMMultiNameLate(ns:HlNsSet);
	HMAttrib(n:HlName);
	HMParams(n:HlName, pl:Array<HlName>);
	HMNSAny(i:HlIdent);
	HMAny;
}

enum HlValue {
	HVNone;
	HVNull;
	HVBool(b:Bool);
	HVString(s:HlIdent);
	HVInt(i:HlInt);
	HVUInt(i:HlUint);
	HVFloat(f:HlFloat);
	HVNamespace(kind:Int, ns:HlNamespace);
}

class HlMethod {
	public var hlmt_index:Int; /* used to sort methods (preserve order) */
	public var hlmt_ret:Null<HlName>;
	public var hlmt_args:Array<Null<HlName>>;
	public var hlmt_native:Bool;
	public var hlmt_var_args:Bool;
	public var hlmt_arguments_defined:Bool;
	public var hlmt_uses_dxns:Bool;
	public var hlmt_new_block:Bool;
	public var hlmt_unused_flag:Bool;
	public var hlmt_debug_name:Null<HlIdent>;
	public var hlmt_dparams:Null<Array<HlValue>>;
	public var hlmt_pnames:Null<Array<Null<HlIdent>>>;
	public var hlmt_function:Null<HlFunction>; /* None for interfaces constructors only */

	public function new() {}

	// port: `{ m with ... }` record copies.
	public function copy():HlMethod {
		var m = new HlMethod();
		m.hlmt_index = hlmt_index;
		m.hlmt_ret = hlmt_ret;
		m.hlmt_args = hlmt_args;
		m.hlmt_native = hlmt_native;
		m.hlmt_var_args = hlmt_var_args;
		m.hlmt_arguments_defined = hlmt_arguments_defined;
		m.hlmt_uses_dxns = hlmt_uses_dxns;
		m.hlmt_new_block = hlmt_new_block;
		m.hlmt_unused_flag = hlmt_unused_flag;
		m.hlmt_debug_name = hlmt_debug_name;
		m.hlmt_dparams = hlmt_dparams;
		m.hlmt_pnames = hlmt_pnames;
		m.hlmt_function = hlmt_function;
		return m;
	}
}

typedef HlTryCatch = {
	var hltc_start:Int;
	var hltc_end:Int;
	var hltc_handle:Int;
	var hltc_type:Null<HlName>;
	var hltc_name:Null<HlName>;
}

typedef HlLocal = {
	var name:HlName;
	var type:Null<HlName>;
	var slot:HlSlot;
	var const:Bool; /* bool = const - mostly false */
}

typedef HlFunction = {
	var hlf_stack_size:Int;
	var hlf_nregs:Int;
	var hlf_init_scope:Int;
	var hlf_max_scope:Int;
	var hlf_code:Array<HlOpcode>;
	var hlf_trys:Vector<HlTryCatch>;
	var hlf_locals:Vector<HlLocal>;
}

typedef HlMethodKind = As3MethodKind;

typedef HlMethodField = {
	var hlm_type:HlMethod;
	var hlm_final:Bool;
	var hlm_override:Bool;
	var hlm_kind:HlMethodKind;
}

typedef HlVarField = {
	var hlv_type:Null<HlName>;
	var hlv_value:HlValue;
	var hlv_const:Bool;
}

typedef HlMetadata = {
	var hlmeta_name:HlIdent;
	var hlmeta_data:Vector<{k:Null<HlIdent>, v:HlIdent}>;
}

enum HlFieldKind {
	HFMethod(m:HlMethodField);
	HFVar(v:HlVarField);
	HFFunction(m:HlMethod);
	HFClass(c:HlClass); /* only for hl_static fields */
}

typedef HlField = {
	var hlf_name:HlName;
	var hlf_slot:HlSlot;
	var hlf_kind:HlFieldKind;
	var hlf_metas:Null<Vector<HlMetadata>>;
}

class HlClass {
	public var hlc_index:Int;
	public var hlc_name:HlName;
	public var hlc_super:Null<HlName>;
	public var hlc_sealed:Bool;
	public var hlc_final:Bool;
	public var hlc_interface:Bool;
	public var hlc_namespace:Null<HlNamespace>;
	public var hlc_implements:Vector<HlName>;
	public var hlc_construct:HlMethod;
	public var hlc_fields:Vector<HlField>;
	public var hlc_static_construct:HlMethod;
	public var hlc_static_fields:Vector<HlField>;

	public function new() {}
}

typedef HlStatic = {
	var hls_method:HlMethod;
	var hls_fields:Vector<HlField>;
}

typedef HlTag = Array<HlStatic>;
