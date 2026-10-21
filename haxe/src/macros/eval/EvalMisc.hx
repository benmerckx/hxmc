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

package macros.eval;

import core.Ast;
import core.Globals;
import core.Globals.Pos;
import haxe.Int64;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalHash;
import macros.eval.EvalExceptions.EvalExceptions.unexpectedValue;

using macros.eval.EvalValue.EvalValueTools;

class EvalMisc {
	public static function throwString(s:String, p:Pos):Dynamic {
		return EvalContext.throwValue(EvalString.createUnknown(s), p);
	}

	public static function invalidBinop(op:Binop, v1:Value, v2:Value, p:Pos):Dynamic {
		return throwString('Invalid operation: ${EvalPrinting.valueString(v1)} ${core.Ast.Ast.sBinop(op)} ${EvalPrinting.valueString(v2)}',
			p);
	}

	public static function updateObjectPrototype(o:Vobject, fields:Array<{name:Int, value:Value}>):Void {
		var ctx = EvalContext.getCtx();
		var r = EvalEncode.getObjectPrototype(EvalContext.getCtx(), fields);
		var fields = new haxe.ds.Vector<Value>(r.sorted.length);
		for (i in 0...r.sorted.length)
			fields[i] = r.sorted[i].value;
		o.ofields = fields;
		o.oproto = OProto(r.proto);
	}

	// Calls

	public static function callValue(v:Value, vl:Array<Value>):Value {
		return switch v {
			case VFunction(f, _): EvalContext.callFunction(f, vl);
			case VFieldClosure(v1, f): EvalContext.callFunction(f, [v1].concat(vl));
			case VInstance({ikind: ILazyType(_, get)}): get();
			case _: EvalContext.excString("Cannot call " + EvalPrinting.valueString(v));
		}
	}

	// Field setters

	public static function setProtoField(proto:Vprototype, name:Int, v2:Value):Void {
		proto.pfields[EvalContext.getProtoFieldIndexRaise(proto, name)] = v2;
	}

	public static function setInstanceField(vi:Vinstance, name:Int, v2:Value):Void {
		vi.ifields[EvalContext.getInstanceFieldIndexRaise(vi.iproto, name)] = v2;
	}

	public static function setObjectField(o:Vobject, name:Int, v2:Value):Void {
		switch o.oproto {
			case OProto(proto):
				try {
					o.ofields[EvalContext.getInstanceFieldIndexRaise(proto, name)] = v2;
				} catch (_:core.ds.NotFound) {
					var fields = proto.pinstanceNames.fold((name, i, acc:Array<{name:Int, value:Value}>) -> {
						acc.unshift({name: name, value: o.ofields[i]});
						acc;
					}, []);
					fields.unshift({name: name, value: v2});
					updateObjectPrototype(o, fields);
				}
			case ODictionary(d):
				o.oproto = ODictionary(d.add(name, v2));
		}
	}

	/** Turns prototypes into dictionaries if the field doesn't exist. **/
	public static function setObjectFieldRuntime(o:Vobject, name:Int, v2:Value):Void {
		inline function updateDictionary(d:core.ds.GlobalsIntMap<Value>) return d.add(name, v2);
		inline function makeDictionary(proto:Vprototype) return proto.pinstanceNames.map(i -> o.ofields[i]);
		switch o.oproto {
			case OProto(proto):
				try {
					o.ofields[EvalContext.getInstanceFieldIndexRaise(proto, name)] = v2;
				} catch (_:core.ds.NotFound) {
					var d = makeDictionary(proto);
					var d = updateDictionary(d);
					o.oproto = ODictionary(d);
				}
			case ODictionary(d):
				var d = updateDictionary(d);
				o.oproto = ODictionary(d);
		}
	}

	public static function setBytesLengthField(v1:Value, v2:Value):Void {
		switch v1 {
			case VInstance(vi = {ikind: IBytes(b)}):
				var i = EvalDecode.decodeInt(v2);
				var b2 = haxe.io.Bytes.alloc(i);
				b2.blit(0, b, 0, if (i > b.length) b.length else i);
				vi.ikind = IBytes(b2);
			case _:
				unexpectedValue(v1, "bytes");
		}
	}

	public static function setField(v1:Value, name:Int, v2:Value):Void {
		switch v1.vresolve() {
			case VObject(o):
				setObjectField(o, name, v2);
			case VPrototype(proto):
				setProtoField(proto, name, v2);
			case VArray(va):
				// Vector.new does this
				if (name == EvalHash.key_length) {
					EvalArray.setLength(va, EvalDecode.decodeInt(v2));
				} else
					unexpectedValue(v1, "object");
			case VInstance({ikind: IBytes(_)}):
				setBytesLengthField(v1, v2);
			case VInstance(vi):
				setInstanceField(vi, name, v2);
			case _:
				unexpectedValue(v1, "object");
		}
	}

	public static function setFieldRuntime(v1:Value, name:Int, v2:Value):Void {
		switch v1.vresolve() {
			case VObject(o):
				setObjectFieldRuntime(o, name, v2);
			case _:
				setField(v1, name, v2);
		}
	}

	// Equality/compare

	public static function fcmp(a:Float, b:Float):Cmp return if (a == b) CEq else if (a < b) CInf else if (a > b) CSup else CUndef;

	public static function icmp(a:Int, b:Int):Cmp return if (a == b) CEq else if (a < b) CInf else CSup;

	public static function i64cmp(a:Int64, b:Int64):Cmp {
		var l = Int64.compare(a, b);
		return if (l == 0) CEq else if (l < 0) CInf else CSup;
	}

	public static function compare(a:Value, b:Value):Cmp {
		return switch [a, b] {
			case [VNull, VNull]: CEq;
			case [VInt32(a), VInt32(b)]: icmp(a, b);
			case [VInt64(a), VInt64(b)]: i64cmp(a, b);
			case [VFloat(a), VFloat(b)]: fcmp(a, b);
			case [VFloat(a), VInt32(b)]: fcmp(a, b);
			case [VInt32(a), VFloat(b)]: fcmp(a, b);
			case [VTrue, VTrue] | [VFalse, VFalse]: CEq;
			case [VFalse, VTrue]: CInf;
			case [VTrue, VFalse]: CSup;
			case [VString(s1), VString(s2)]:
				var s1_ = s1.sstring;
				var s2_ = s2.sstring;
				// port: String.compare on the UTF-8 bytes
				var r = EvalString.compareCodePoints(s1_, s2_);
				if (r == 0) CEq else if (r < 0) CInf else CSup;
			case [VFunction(a, _), VFunction(b, _)]: if (Reflect.compareMethods(a, b)) CEq else CUndef;
			case [VArray(va1), VArray(va2)]: if (va1 == va2) CEq else CUndef;
			case [VVector(vv1), VVector(vv2)]: if (vv1 == vv2) CEq else CUndef;
			case [VObject(a), VObject(b)]: if (a == b) CEq else CUndef;
			case [VInstance(a), VInstance(b)]: if (a == b) CEq else CUndef;
			case [VPrototype(a), VPrototype(b)]: if (a == b) CEq else CUndef;
			case [VEnumValue(a), VEnumValue(b)]:
				if (a == b) CEq else if (a.eindex < b.eindex) CInf else if (a.eindex > b.eindex) CSup else if (a.epath != b.epath)
					CUndef else if (a.eargs.length == 0
					&& b.eargs.length == 0) CEq else CUndef;
			case [VFieldClosure(v1, f1), VFieldClosure(v2, f2)]:
				if (!Reflect.compareMethods(f1, f2)) CUndef else compare(v1, v2);
			case [VLazy(f1), _]:
				compare(f1.force(), b);
			case [_, VLazy(f2)]:
				compare(a, f2.force());
			case _: CUndef;
		}
	}

	public static function arraysEqual(cmp:Value->Value->Bool, a1:haxe.ds.Vector<Value>, a2:haxe.ds.Vector<Value>):Bool {
		if (a1.length != a2.length) return false;
		for (i in 0...a1.length) if (!cmp(a1[i], a2[i])) return false;
		return true;
	}

	// port: OCaml physical equality `==` on values (immediates compare by value).
	static function physicalEquals(a:Value, b:Value):Bool {
		return switch [a, b] {
			case [VNull, VNull] | [VTrue, VTrue] | [VFalse, VFalse]: true;
			case [VInt32(a), VInt32(b)]: a == b;
			case [VInstance(a), VInstance(b)]: a == b;
			case [VFunction(a, s1), VFunction(b, s2)]: s1 == s2 && Reflect.compareMethods(a, b);
			case [VFieldClosure(v1, f1), VFieldClosure(v2, f2)]: physicalEquals(v1, v2) && Reflect.compareMethods(f1, f2);
			case [VNativeString(a), VNativeString(b)]: a == b;
			case [VHandle(a), VHandle(b)]: a == b;
			case [VLazy(a), VLazy(b)]: a == b;
			case _: false;
		}
	}

	public static function equalsStructurally(a:Value, b:Value):Bool {
		return switch [a, b] {
			case [VInt32(a), VInt32(b)]: a == b;
			case [VInt64(a), VInt64(b)]: Int64.compare(a, b) == 0;
			case [VFloat(a), VFloat(b)]: a == b;
			case [VFloat(a), VInt32(b)]: a == (b : Float);
			case [VInt32(a), VFloat(b)]: (a : Float) == b;
			case [VString(s1), VString(s2)]: s1.sstring == s2.sstring; // STODO
			case [VArray(a), VArray(b)]: a == b || arraysEqual(equalsStructurally, a.avalues, b.avalues);
			case [VVector(a), VVector(b)]: a == b || arraysEqual(equalsStructurally, a, b);
			case [VObject(a), VObject(b)]: a == b || arraysEqual(equalsStructurally, a.ofields, b.ofields);
			case [VEnumValue(a), VEnumValue(b)]: a == b || a.eindex == b.eindex && arraysEqual(equalsStructurally, a.eargs,
					b.eargs) && a.epath == b.epath;
			case [VPrototype(proto1), VPrototype(proto2)]: proto1.ppath == proto2.ppath;
			case [VLazy(f1), _]: equalsStructurally(f1.force(), b);
			case [_, VLazy(f2)]: equalsStructurally(a, f2.force());
			case _: physicalEquals(a, b);
		}
	}

	public static function isTrue(v:Value):Bool {
		return switch v {
			case VTrue: true;
			case _: false;
		}
	}

	public static function opAdd(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt32(i1), VInt32(i2)]: EvalValueTools.vint32(i1 + i2);
			case [VInt64(i1), VInt64(i2)]: VInt64(Int64.add(i1, i2));
			// These two cases should technically not exist, but the analyzer emits code like this because
			// our TConst only knows Int32 at the moment.
			case [VInt64(i1), VInt32(i2)]: VInt64(Int64.add(i1, Int64.ofInt(i2)));
			case [VInt32(i1), VInt64(i2)]: VInt64(Int64.add(Int64.ofInt(i1), i2));
			case [VFloat(f1), VFloat(f2)]: VFloat(f1 + f2);
			case [VInt32(i), VFloat(f)] | [VFloat(f), VInt32(i)]: VFloat((i : Float) + f);
			case [VNativeString(s1), VNativeString(s2)]:
				var b = haxe.io.Bytes.alloc(s1.length + s2.length);
				b.blit(0, s1, 0, s1.length);
				b.blit(s1.length, s2, 0, s2.length);
				VNativeString(b);
			case [VString(s1), VString(s2)]: VString(EvalString.concat(s1, s2));
			case [VString(s1), v2]: VString(EvalString.concat(s1, EvalPrinting.sValue(0, v2)));
			case [v1, VString(s2)]: VString(EvalString.concat(EvalPrinting.sValue(0, v1), s2));
			case [v1, v2]: invalidBinop(OpAdd, v1, v2, p);
		}
	}

	public static function opMult(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt32(i1), VInt32(i2)]: EvalValueTools.vint32(i1 * i2);
			case [VInt64(i1), VInt64(i2)]: VInt64(Int64.mul(i1, i2));
			case [VFloat(f1), VFloat(f2)]: VFloat(f1 * f2);
			case [VInt32(i), VFloat(f)] | [VFloat(f), VInt32(i)]: VFloat((i : Float) * f);
			case _: invalidBinop(OpMult, v1, v2, p);
		}
	}

	public static function opDiv(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt32(i1), VInt32(i2)]: VFloat((i1 : Float) / (i2 : Float));
			case [VFloat(f1), VFloat(f2)]: VFloat(f1 / f2);
			case [VInt32(i1), VFloat(f2)]: VFloat((i1 : Float) / f2);
			case [VFloat(f1), VInt32(i2)]: VFloat(f1 / (i2 : Float));
			case _: invalidBinop(OpDiv, v1, v2, p);
		}
	}

	public static function opSub(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt32(i1), VInt32(i2)]: EvalValueTools.vint32(i1 - i2);
			case [VInt64(i1), VInt64(i2)]: VInt64(Int64.sub(i1, i2));
			// See op_add remark.
			case [VInt64(i1), VInt32(i2)]: VInt64(Int64.sub(i1, Int64.ofInt(i2)));
			case [VInt32(i1), VInt64(i2)]: VInt64(Int64.sub(Int64.ofInt(i1), i2));
			case [VFloat(f1), VFloat(f2)]: VFloat(f1 - f2);
			case [VInt32(i1), VFloat(f2)]: VFloat((i1 : Float) - f2);
			case [VFloat(f1), VInt32(i2)]: VFloat(f1 - (i2 : Float));
			case _: invalidBinop(OpSub, v1, v2, p);
		}
	}

	public static function opEq(v1:Value, v2:Value):Value return v1.equals(v2) ? VTrue : VFalse;

	public static function opNotEq(v1:Value, v2:Value):Value return !v1.equals(v2) ? VTrue : VFalse;

	public static function opGt(v1:Value, v2:Value):Value return compare(v1, v2) == CSup ? VTrue : VFalse;

	public static function opGte(v1:Value, v2:Value):Value return switch compare(v1, v2) {
		case CSup | CEq: VTrue;
		case _: VFalse;
	}

	public static function opLt(v1:Value, v2:Value):Value return compare(v1, v2) == CInf ? VTrue : VFalse;

	public static function opLte(v1:Value, v2:Value):Value return switch compare(v1, v2) {
		case CInf | CEq: VTrue;
		case _: VFalse;
	}

	public static function opAnd(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt32(i1), VInt32(i2)]: EvalValueTools.vint32(i1 & i2);
			case _: invalidBinop(OpAnd, v1, v2, p);
		}
	}

	public static function opOr(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt32(i1), VInt32(i2)]: EvalValueTools.vint32(i1 | i2);
			case _: invalidBinop(OpOr, v1, v2, p);
		}
	}

	public static function opXor(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt32(i1), VInt32(i2)]: EvalValueTools.vint32(i1 ^ i2);
			case _: invalidBinop(OpXor, v1, v2, p);
		}
	}

	public static function opShl(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt32(i1), VInt32(i2)]:
				var i2 = i2 & 31;
				EvalValueTools.vint32(i1 << i2);
			case _: invalidBinop(OpShl, v1, v2, p);
		}
	}

	public static function opShr(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt32(i1), VInt32(i2)]:
				var i2 = i2 & 31;
				EvalValueTools.vint32(i1 >> i2);
			case _: invalidBinop(OpShr, v1, v2, p);
		}
	}

	public static function opUshr(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			case [VInt32(i1), VInt32(i2)]:
				var i2 = i2 & 31;
				EvalValueTools.vint32(i1 >>> i2);
			case _: invalidBinop(OpUShr, v1, v2, p);
		}
	}

	public static function opMod(p:Pos, v1:Value, v2:Value):Value {
		return switch [v1, v2] {
			// port: Int32.rem: Division_by_zero gives nan; min_int rem -1 is 0 (avoids the host's overflow trap)
			case [VInt32(i1), VInt32(i2)]: if (i2 == 0) VFloat(Math.NaN) else if (i2 == -1) EvalValueTools.vint32(0) else
					EvalValueTools.vint32(i1 % i2);
			case [VFloat(f1), VFloat(f2)]: VFloat(f1 % f2);
			case [VInt32(i1), VFloat(f2)]: VFloat((i1 : Float) % f2);
			case [VFloat(f1), VInt32(i2)]: VFloat(f1 % (i2 : Float));
			case _: invalidBinop(OpMod, v1, v2, p);
		}
	}

	public static function getBinopFun(op:Binop, p:Pos):Value->Value->Value {
		return switch op {
			case OpAdd: opAdd.bind(p);
			case OpMult: opMult.bind(p);
			case OpDiv: opDiv.bind(p);
			case OpSub: opSub.bind(p);
			case OpEq: opEq;
			case OpNotEq: opNotEq;
			case OpGt: opGt;
			case OpGte: opGte;
			case OpLt: opLt;
			case OpLte: opLte;
			case OpAnd: opAnd.bind(p);
			case OpOr: opOr.bind(p);
			case OpXor: opXor.bind(p);
			case OpShl: opShl.bind(p);
			case OpShr: opShr.bind(p);
			case OpUShr: opUshr.bind(p);
			case OpMod: opMod.bind(p);
			case OpAssign | OpBoolAnd | OpBoolOr | OpAssignOp(_) | OpInterval | OpArrow | OpIn | OpNullCoal: Globals.die("",
					"EvalMisc.getBinopFun", p);
		}
	}

	public static function prepareCallback(v:Value, n:Int):Array<Value>->Value {
		return switch v {
			case VFunction(_) | VFieldClosure(_):
				var ctx = EvalContext.getCtx();
				args -> switch EvalExceptions.catchExceptions(ctx, () -> callValue(v, args), Globals.nullPos) {
					case Some(v): v;
					case None: VNull;
				}
			case _:
				throw macros.MacroApi.InvalidExpr.raise();
		}
	}

	public static function createHaxeException(msg:String, ?stack:Array<{pos:Pos, kind:EnvKind}>):Value {
		var vi = EvalEncode.encodeInstance(EvalHash.key_haxe_Exception);
		return switch vi {
			case VInstance(i):
				var vMsg = EvalString.createUnknown(msg);
				setInstanceField(i, EvalHash.key_exception_message, vMsg);
				setInstanceField(i, EvalHash.key_native_exception, vMsg);
				switch stack {
					case null:
						var ctx = EvalContext.getCtx();
						var eval = EvalContext.getEval(ctx);
						switch eval.env {
							case null:
							case _:
								var stack = EvalStackTrace.makeStackValue(EvalContext.callStack(eval));
								setInstanceField(i, EvalHash.key_native_stack, stack);
						}
					case stack:
						var stack = EvalStackTrace.makeStack(stack);
						setInstanceField(i, EvalHash.key_native_stack, stack);
				}
				vi;
			case _:
				Globals.die("", "EvalMisc.createHaxeException");
		}
	}
}
