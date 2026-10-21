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

import core.Globals;
import core.ds.AtomicLazy;
import core.ds.GlobalsIntMap;
import macros.MacroApi.EnumType;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalHash;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using macros.eval.EvalValue.EvalValueTools;

// port: `ctx.get_object_prototype` returns only the prototype here; the
// sorted field list it also returns upstream is computed by `sortObjectFields`
// (the same stable sort on the hashed names).
class EvalEncode {
	// Functions
	public static function vifun0(f:Value->Value):Value return VFunction(vl -> switch vl {
		case []: f(VNull);
		case [v0]: f(v0);
		case _: EvalExceptions.invalidCallArgNumber(1, vl.length);
	}, false);

	public static function vifun1(f:Value->Value->Value):Value return VFunction(vl -> switch vl {
		case []: f(VNull, VNull);
		case [v0]: f(v0, VNull);
		case [v0, v1]: f(v0, v1);
		case _: EvalExceptions.invalidCallArgNumber(2, vl.length);
	}, false);

	public static function vifun2(f:Value->Value->Value->Value):Value return VFunction(vl -> switch vl {
		case []: f(VNull, VNull, VNull);
		case [v0]: f(v0, VNull, VNull);
		case [v0, v1]: f(v0, v1, VNull);
		case [v0, v1, v2]: f(v0, v1, v2);
		case _: EvalExceptions.invalidCallArgNumber(3, vl.length);
	}, false);

	public static function vifun3(f:Value->Value->Value->Value->Value):Value return VFunction(vl -> switch vl {
		case []: f(VNull, VNull, VNull, VNull);
		case [v0]: f(v0, VNull, VNull, VNull);
		case [v0, v1]: f(v0, v1, VNull, VNull);
		case [v0, v1, v2]: f(v0, v1, v2, VNull);
		case [v0, v1, v2, v3]: f(v0, v1, v2, v3);
		case _: EvalExceptions.invalidCallArgNumber(4, vl.length);
	}, false);

	public static function vifun4(f:Value->Value->Value->Value->Value->Value):Value return VFunction(vl -> switch vl {
		case []: f(VNull, VNull, VNull, VNull, VNull);
		case [v0]: f(v0, VNull, VNull, VNull, VNull);
		case [v0, v1]: f(v0, v1, VNull, VNull, VNull);
		case [v0, v1, v2]: f(v0, v1, v2, VNull, VNull);
		case [v0, v1, v2, v3]: f(v0, v1, v2, v3, VNull);
		case [v0, v1, v2, v3, v4]: f(v0, v1, v2, v3, v4);
		case _: EvalExceptions.invalidCallArgNumber(4, vl.length); // port: sic (upstream)
	}, false);

	public static function vfun0(f:Void->Value):Value return VFunction(vl -> switch vl {
		case []: f();
		case _: EvalExceptions.invalidCallArgNumber(1, vl.length); // port: sic (upstream)
	}, true);

	public static function vfun1(f:Value->Value):Value return VFunction(vl -> switch vl {
		case []: f(VNull);
		case [v0]: f(v0);
		case _: EvalExceptions.invalidCallArgNumber(1, vl.length);
	}, true);

	public static function vfun2(f:Value->Value->Value):Value return VFunction(vl -> switch vl {
		case []: f(VNull, VNull);
		case [v0]: f(v0, VNull);
		case [v0, v1]: f(v0, v1);
		case _: EvalExceptions.invalidCallArgNumber(2, vl.length);
	}, true);

	public static function vfun3(f:Value->Value->Value->Value):Value return VFunction(vl -> switch vl {
		case []: f(VNull, VNull, VNull);
		case [v0]: f(v0, VNull, VNull);
		case [v0, v1]: f(v0, v1, VNull);
		case [v0, v1, v2]: f(v0, v1, v2);
		case _: EvalExceptions.invalidCallArgNumber(3, vl.length);
	}, true);

	public static function vfun4(f:Value->Value->Value->Value->Value):Value return VFunction(vl -> switch vl {
		case []: f(VNull, VNull, VNull, VNull);
		case [v0]: f(v0, VNull, VNull, VNull);
		case [v0, v1]: f(v0, v1, VNull, VNull);
		case [v0, v1, v2]: f(v0, v1, v2, VNull);
		case [v0, v1, v2, v3]: f(v0, v1, v2, v3);
		case _: EvalExceptions.invalidCallArgNumber(4, vl.length);
	}, true);

	public static function vfun5(f:Value->Value->Value->Value->Value->Value):Value return VFunction(vl -> switch vl {
		case []: f(VNull, VNull, VNull, VNull, VNull);
		case [v0]: f(v0, VNull, VNull, VNull, VNull);
		case [v0, v1]: f(v0, v1, VNull, VNull, VNull);
		case [v0, v1, v2]: f(v0, v1, v2, VNull, VNull);
		case [v0, v1, v2, v3]: f(v0, v1, v2, v3, VNull);
		case [v0, v1, v2, v3, v4]: f(v0, v1, v2, v3, v4);
		case _: EvalExceptions.invalidCallArgNumber(5, vl.length);
	}, true);

	public static function vfun6(f:Value->Value->Value->Value->Value->Value->Value):Value return VFunction(vl -> switch vl {
		case []: f(VNull, VNull, VNull, VNull, VNull, VNull);
		case [v0]: f(v0, VNull, VNull, VNull, VNull, VNull);
		case [v0, v1]: f(v0, v1, VNull, VNull, VNull, VNull);
		case [v0, v1, v2]: f(v0, v1, v2, VNull, VNull, VNull);
		case [v0, v1, v2, v3]: f(v0, v1, v2, v3, VNull, VNull);
		case [v0, v1, v2, v3, v4]: f(v0, v1, v2, v3, v4, VNull);
		case [v0, v1, v2, v3, v4, v5]: f(v0, v1, v2, v3, v4, v5);
		case _: EvalExceptions.invalidCallArgNumber(6, vl.length);
	}, true);

	public static function vfun7(f:Value->Value->Value->Value->Value->Value->Value->Value):Value return VFunction(vl -> switch vl {
		case []: f(VNull, VNull, VNull, VNull, VNull, VNull, VNull);
		case [v0]: f(v0, VNull, VNull, VNull, VNull, VNull, VNull);
		case [v0, v1]: f(v0, v1, VNull, VNull, VNull, VNull, VNull);
		case [v0, v1, v2]: f(v0, v1, v2, VNull, VNull, VNull, VNull);
		case [v0, v1, v2, v3]: f(v0, v1, v2, v3, VNull, VNull, VNull);
		case [v0, v1, v2, v3, v4]: f(v0, v1, v2, v3, v4, VNull, VNull);
		case [v0, v1, v2, v3, v4, v5]: f(v0, v1, v2, v3, v4, v5, VNull);
		case [v0, v1, v2, v3, v4, v5, v6]: f(v0, v1, v2, v3, v4, v5, v6);
		case _: EvalExceptions.invalidCallArgNumber(7, vl.length);
	}, true);

	// Objects

	// port: the field list sorted as evalPrototype.ml `get_object_prototype` sorts it (List.sort is stable).
	public static function sortObjectFields(l:Array<{name:Int, value:Value}>):Array<{name:Int, value:Value}> {
		return EvalPrototype.sortObjectFields(l);
	}

	// port: `ctx.get_object_prototype ctx l`: the prototype and the sorted fields.
	public static function getObjectPrototype(ctx:Context,
			l:Array<{name:Int, value:Value}>):{proto:Vprototype, sorted:Array<{name:Int, value:Value}>} {
		var sorted = sortObjectFields(l);
		var proto = ctx.getObjectPrototype(ctx, [for (f in sorted) f.name]);
		return {proto: proto, sorted: sorted};
	}

	public static function encodeObj(l:Array<{name:Int, value:Value}>):Value {
		var ctx = EvalContext.getCtx();
		var r = getObjectPrototype(ctx, l);
		var fields = new Vector<Value>(r.sorted.length);
		for (i in 0...r.sorted.length)
			fields[i] = r.sorted[i].value;
		return VObject(new Vobject(fields, OProto(r.proto)));
	}

	public static function encodeObjS(l:Array<{name:String, value:Value}>):Value {
		return encodeObj([for (f in l) {name: EvalHash.hash(f.name), value: f.value}]);
	}

	// Enum values

	public static function encodeEnumValueV(path:Int, i:Int, vl:Vector<Value>, pos:Null<Pos>):Value {
		return VEnumValue(new VenumValue(i, vl, path, pos));
	}

	public static function encodeEnumValue(path:Int, i:Int, vl:Vector<Value>, pos:Null<Pos>):Value
		return encodeEnumValueV(path, i, vl, pos);

	public static function encodeEnum(i:EnumType, pos:Null<Pos>, index:Int, pl:Vector<Value>):Value {
		var key = switch i {
			case IExpr: EvalHash.key_haxe_macro_ExprDef;
			case IEFieldKind: EvalHash.key_haxe_macro_EFieldKind;
			case IBinop: EvalHash.key_haxe_macro_Binop;
			case IUnop: EvalHash.key_haxe_macro_Unop;
			case IConst: EvalHash.key_haxe_macro_Constant;
			case ITParam: EvalHash.key_haxe_macro_TypeParam;
			case ICType: EvalHash.key_haxe_macro_ComplexType;
			case IField: EvalHash.key_haxe_macro_FieldType;
			case IType: EvalHash.key_haxe_macro_Type;
			case IFieldKind: EvalHash.key_haxe_macro_FieldKind;
			case IMethodKind: EvalHash.key_haxe_macro_MethodKind;
			case IVarAccess: EvalHash.key_haxe_macro_VarAccess;
			case IAccess: EvalHash.key_haxe_macro_Access;
			case IClassKind: EvalHash.key_haxe_macro_ClassKind;
			case ITypedExpr: EvalHash.key_haxe_macro_TypedExprDef;
			case ITConstant: EvalHash.key_haxe_macro_TConstant;
			case IModuleType: EvalHash.key_haxe_macro_ModuleType;
			case IFieldAccess: EvalHash.key_haxe_macro_FieldAccess;
			case IAnonStatus: EvalHash.key_haxe_macro_AnonStatus;
			case IImportMode: EvalHash.key_haxe_macro_ImportMode;
			case IQuoteStatus: EvalHash.key_haxe_macro_QuoteStatus;
			case IDisplayKind: EvalHash.key_haxe_macro_DisplayKind;
			case IDisplayMode: EvalHash.key_haxe_macro_DisplayMode;
			case ICapturePolicy: EvalHash.key_haxe_macro_CapturePolicy;
			case IVarScope: EvalHash.key_haxe_macro_VarScope;
			case IVarScopingFlags: EvalHash.key_haxe_macro_VarScopingFlags;
			case IPlatform: EvalHash.key_haxe_macro_Platform;
			case IPackageRule: EvalHash.key_haxe_macro_PackageRule;
			case IMessage: EvalHash.key_haxe_macro_Message;
			case IFunctionKind: EvalHash.key_haxe_macro_FunctionKind;
			case IStringLiteralKind: EvalHash.key_haxe_macro_StringLiteralKind;
		}
		return encodeEnumValueV(key, index, pl, pos);
	}

	// Instances

	public static function createInstanceDirect(proto:Vprototype, kind:VinstanceKind):Value {
		return VInstance(new Vinstance(proto.pinstanceFields.length == 0 ? proto.pinstanceFields : proto.pinstanceFields.copy(), proto,
			kind));
	}

	public static function createInstance(path:Int, ?kind:VinstanceKind):Vinstance {
		if (kind == null) kind = INormal;
		var proto = EvalContext.getInstancePrototype(EvalContext.getCtx(), path, Globals.nullPos);
		return new Vinstance(proto.pinstanceFields.length == 0 ? proto.pinstanceFields : proto.pinstanceFields.copy(), proto, kind);
	}

	public static function encodeInstance(path:Int, ?kind:VinstanceKind):Value {
		return VInstance(createInstance(path, kind));
	}

	public static function encodeArrayInstance(a:Varray):Value return VArray(a);

	public static function encodeVectorInstance(v:Vvector):Value return VVector(v);

	public static function encodeArray(l:Array<Value>):Value return encodeArrayInstance(EvalArray.ofList(l));

	// port: encode_array of a fresh value array (a Vector made by the caller), with no copy
	public static function encodeArrayV(v:Vector<Value>):Value return encodeArrayInstance(EvalArray.create(v));

	// port: upstream's takes a value array; the Haxe arrays given here are copied
	public static function encodeArrayA(a:Array<Value>):Value return encodeArrayInstance(EvalArray.ofList(a));

	public static function encodeString(s:String):Value return EvalString.createUnknown(s);

	/** Should only be used for std types that aren't expected to change while the compilation server is running **/
	public static function createCachedInstance<T>(path:Int, fkind:T->VinstanceKind):T->Value {
		var proto = AtomicLazy.fromFun(() -> EvalContext.getInstancePrototype(EvalContext.getCtx(), path, Globals.nullPos));
		return v -> createInstanceDirect(proto.force(), fkind(v));
	}

	public static final encodeBytes:haxe.io.Bytes->Value = createCachedInstance(EvalHash.key_haxe_io_Bytes, s -> IBytes(s));

	public static final encodeIntMapDirect:RuntimeIntHashtbl<Value>->Value = createCachedInstance(EvalHash.key_haxe_ds_IntMap,
		s -> IIntMap(s));

	public static final encodeInt64MapDirect:RuntimeInt64Hashtbl<Value>->Value = createCachedInstance(EvalHash.key_haxe_ds_Int64Map,
		s -> IInt64Map(s));

	public static final encodeStringMapDirect:RuntimeStringHashtbl<Value>->Value = createCachedInstance(EvalHash.key_haxe_ds_StringMap,
		s -> IStringMap(s));

	public static final encodeObjectMapDirect:core.ds.OcamlHashtbl<Value, Value>->
		Value = createCachedInstance(EvalHash.key_haxe_ds_ObjectMap, s -> IObjectMap(s));

	// port: `m` is upstream's string PMap; the resulting map is ordered by key either way.
	public static function encodeStringMap<T>(convert:T->Value, m:Map<String, T>):Value {
		var h = new RuntimeStringHashtbl<Value>();
		var keys = [for (k in m.keys()) k];
		keys.sort(EvalString.compareCodePoints);
		for (key in keys) h.add(EvalString.createAscii(key), convert(m.get(key)));
		return encodeStringMapDirect(h);
	}

	public static function fakeProto(cache:Map<Int, Vprototype>, path:Int):Vprototype {
		var proto = cache.get(path);
		if (proto != null) return proto;
		var proto = new Vprototype(path, new Vector(0), GlobalsIntMap.empty(), new Vector(0), GlobalsIntMap.empty(), null, PInstance, VNull);
		proto.pvalue = VPrototype(proto);
		cache.set(path, proto);
		return proto;
	}

	public static function encodeUnsafe(o:Dynamic):Value {
		return VInstance(new Vinstance(new Vector(0), fakeProto(EvalContext.getCtx().fakeProtoCache, EvalHash.key_haxe_macro_Unsafe), IRef(o)));
	}

	public static function encodePos(p:Pos):Value {
		return VInstance(new Vinstance(new Vector(0), fakeProto(EvalContext.getCtx().fakeProtoCache, EvalHash.key_haxe_macro_Position), IPos(p)));
	}

	public static function encodeLazytype(t:core.TType.TLazy, f:Void->Value):Value {
		return VInstance(new Vinstance(new Vector(0), fakeProto(EvalContext.getCtx().fakeProtoCache, EvalHash.key_haxe_macro_LazyType),
			ILazyType(t, f)));
	}

	public static function encodeTdecl(t:core.TType.ModuleType):Value {
		return VInstance(new Vinstance(new Vector(0), fakeProto(EvalContext.getCtx().fakeProtoCache, EvalHash.key_haxe_macro_TypeDecl), ITypeDecl(t)));
	}

	public static final refProto:Vprototype = {
		var proto = new Vprototype(EvalHash.key_haxe_macro_Ref, new Vector(0), GlobalsIntMap.empty(), new Vector(2, VNull),
			GlobalsIntMap.empty().add(EvalHash.key_toString, 1).add(EvalHash.key_get, 0), null, PInstance, VNull);
		proto.pvalue = VPrototype(proto);
		proto;
	}

	public static function encodeRef<T>(v:T, convert:T->Value, tostr:Void->String):Value {
		var fields = new Vector<Value>(2);
		fields[0] = vifun0(_ -> convert(v));
		fields[1] = vifun0(_ -> encodeString(tostr()));
		return VInstance(new Vinstance(fields, refProto, IRef(v)));
	}

	public static function encodeLazy(r:AtomicLazy<Value>):Value return VLazy(r);

	public static function encodeOption<T>(encodeValue:T->Value, o:Null<T>):Value {
		return switch o {
			case null: encodeEnumValue(EvalHash.key_haxe_ds_Option, 1, vector(), null);
			case v: encodeEnumValue(EvalHash.key_haxe_ds_Option, 0, vector(encodeValue(v)), null);
		}
	}

	public static function encodeNullable<T>(encodeValue:T->Value, o:Null<T>):Value {
		return switch o {
			case null: VNull;
			case v: encodeValue(v);
		}
	}
}
