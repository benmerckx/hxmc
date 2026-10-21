package generators.cpp;

import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.Meta;
import generators.cpp.CppAst;
import generators.cpp.CppTypeUtils.*;
import generators.cpp.CppMarshalling.*;
import generators.cpp.CppError;
import generators.cpp.CppError.CppErrorKind;
import core.ds.VectorTools.vector;

class CppAstTools {
	public static function follow(t:T):T return core.Abstract.followWithAbstracts(t);

	// port: OCaml's String.compare.
	public static function stringCompare(a:String, b:String):Int return core.ds.Key.compareStrings(a, b);

	// port: List.sort is a stable merge sort; Array.sort is not guaranteed to be stable.
	public static function listSort<A>(cmp:A->A->Int, l:Array<A>):Array<A> {
		var a = l.copy();
		if (a.length < 2) return a;
		var tmp = a.copy();
		function merge(lo:Int, mid:Int, hi:Int):Void {
			var i = lo, j = mid, k = lo;
			while (i < mid && j < hi) {
				if (cmp(a[i], a[j]) <= 0) tmp[k++] = a[i++] else tmp[k++] = a[j++];
			}
			while (i < mid) tmp[k++] = a[i++];
			while (j < hi) tmp[k++] = a[j++];
			for (x in lo...hi) a[x] = tmp[x];
		}
		var width = 1;
		while (width < a.length) {
			var lo = 0;
			while (lo < a.length) {
				var mid = lo + width;
				var hi = lo + 2 * width;
				if (mid > a.length) mid = a.length;
				if (hi > a.length) hi = a.length;
				if (mid < hi) merge(lo, mid, hi);
				lo += 2 * width;
			}
			width *= 2;
		}
		return a;
	}

	// port: OCaml print_endline: writes the line and flushes stdout.
	public static function printEndline(s:String):Void {
		var out = Sys.stdout();
		out.writeString(s + "\n");
		out.flush();
	}

	// port: String.length (bytes of the UTF-8 encoding).
	public static function byteLength(s:String):Int return haxe.io.Bytes.ofString(s).length;

	/*
		A class_path is made from a package (array of strings) and a class name.
		Join these together, inclding a separator.  eg, "/" for includes : pack1/pack2/Name or "::"
		for namespace "pack1::pack2::Name"
	 */
	public static function joinClassPath(path:GlobalTypePath, separator:String):String {
		var result = switch path.pack {
			case []: path.name;
			case el: el.join(separator) + separator + path.name;
		}
		return if (result.indexOf("+") >= 0) {
			var idx = result.indexOf("+");
			result.substr(0, idx) + result.substr(idx + 1);
		} else result;
	}

	public static function classText(path:GlobalTypePath):String return "::" + joinClassPath(path, "::");

	public static function isInternalMember(member:String):Bool {
		return member == "toString" || member.length > 1 && member.substr(0, 2) == "__" && switch member {
			case "__ArgCount" | "__ArrayImplRef" | "__CStr" | "__Compare" | "__Create" | "__CreateEmpty" | "__FieldRef" | "__FindArgCount" |
				"__GetFieldMap" | "__GetHandle" | "__GetItem" | "__GetScriptCallable" | "__GetScriptVTable" | "__Param" | "__Remove" |
				"__SGetClass" | "__Set" | "__SetItem" | "__TArrayImplRef" | "__ToDouble" | "__ToInt" | "__ToInterface" | "__ToObject" |
				"__Visit" | "__WCStr" | "__a" | "__blit" | "__boot" | "__boot_all" | "__compare" | "__concat" | "__construct" | "__copy" |
				"__filter" | "__get_args" | "__hx_dump_stack" | "__hx_field_iter" | "__hxt_gc_new" | "__indexOf" | "__insert" |
				"__instanceof" | "__int" | "__iterator" | "__join" | "__lastIndexOf" | "__loadprim" | "__mClass" | "__mDynamicFields" |
				"__map" | "__memcmp" | "__new" | "__pop" | "__prime" | "__push" | "__qsort" | "__unshift" | "__unsafeStringReference" |
				"__time_stamp" | "__superString" | "__splice" | "__shift" | "__slice" | "__sort" | "__s_id" | "__run" | "__root" |
				"__register" | "__remove" | "__removeAt" | "__reverse" | "__zero" | "__Field" | "__IField" | "__Run" | "__Is" |
				"__GetClass" | "__GetType" | "__ToString" | "__s" | "__GetPtr" | "__SetField" | "__length" | "__IsArray" | "__SetThis" |
				"__Internal" | "__EnumParams" | "__Index" | "__Tag" | "__GetFields" | "__HasField" | "__get" | "__set" | "__unsafe_get" |
				"__unsafe_set" | "__global__" | "__SetSize" | "__trace" | "__GetRealObject" | "__SetSizeExact" | "__cpp__" |
				"__URLEncode" | "__URLDecode" | "__IsEnum":
				true;
			case _:
				member.length > 4 && member.substr(0, 4) == "__hx";
		}
	}

	public static function isKnownMember(member:String):Bool {
		return switch member {
			case "__meta__" | "__rtti" | "_Compare": true;
			case _: false;
		}
	}

	/* Convert function names that can't be written in c++ ... */
	public static function keywordRemap(name:String):String {
		return if (isInternalMember(name) || isKnownMember(name)) name else if (name.length > 1 && name.substr(0, 2) == "__") "_hx_" + name else
			switch name {
				case "int" | "Int" | "Bool" | "super" | "auto" | "char" | "const" | "delete" | "double" | "Float" | "enum" | "extern" | "float" |
					"friend" | "goto" | "long" | "operator" | "protected" | "register" | "short" | "signed" | "sizeof" | "template" | "typedef" |
					"union" | "unsigned" | "void" | "volatile" | "or" | "and" | "xor" | "or_eq" | "not" | "and_eq" | "xor_eq" | "typeof" |
					"stdin" | "stdout" | "stderr" | "system" | "BIG_ENDIAN" | "LITTLE_ENDIAN" | "assert" | "NULL" | "wchar_t" | "EOF" | "bool" |
					"const_cast" | "dynamic_cast" | "explicit" | "export" | "mutable" | "namespace" | "reinterpret_cast" | "static_cast" |
					"typeid" | "typename" | "virtual" | "_Complex" | "INFINITY" | "NAN" | "INT_MIN" | "INT_MAX" | "INT8_MIN" | "INT8_MAX" |
					"UINT8_MAX" | "INT16_MIN" | "INT16_MAX" | "UINT16_MAX" | "INT32_MIN" | "INT32_MAX" | "UINT32_MAX" | "asm" | "near" | "far" |
					"_w64" | "HX_" | "HXLINE" | "HXDLIN" | "NO" | "YES" | "abstract" | "decltype" | "finally" | "nullptr" | "static_assert" |
					"struct" | "_Atomic" | "constexpr" | "consteval" | "constinit" | "co_await" | "co_return" | "co_yield" | "alignas" |
					"alignof" | "_Alignas" | "_Alignof" | "requires":
					"_hx_" + name;
				case x:
					x;
			}
	}

	public static function cppVarNameOf(v:TVar):String {
		return switch Ast.getMetaString(v.vMeta, Meta.Native) {
			case null: keywordRemap(v.vName);
			case n: n;
		}
	}

	public static function cppVarDebugNameOf(v:TVar):String {
		return switch Ast.getMetaString(v.vMeta, Meta.RealPath) {
			case null: v.vName;
			case n: n;
		}
	}

	public static function remapClassPath(classPath:GlobalTypePath):GlobalTypePath {
		function pathRemap(withKeywords:Bool, name:String):String {
			var len = name.length;
			return if (len > 3 && name.substr(0, 3) == " ::") name.substr(3) else if (len > 2 && name.substr(0, 2) == "::") name.substr(2) else
				if (withKeywords) keywordRemap(name) else name;
		}
		return {pack: classPath.pack.map(function(n) return pathRemap(true, n)), name: pathRemap(false, classPath.name)};
	}

	public static function joinClassPathRemap(path:GlobalTypePath, separator:String):String {
		return switch joinClassPath(remapClassPath(path), separator) {
			case "Class": "hx::Class";
			case x: x;
		}
	}

	public static function sTcpp(e:TcppExprExpr):String {
		return switch e {
			case CppInt(_): "CppInt";
			case CppFloat(_): "CppFloat";
			case CppString(_): "CppString";
			case CppBool(_): "CppBool";
			case CppNull: "CppNull";
			case CppNil: "CppNil";
			case CppThis(_): "CppThis";
			case CppSuper(_): "CppSuper";
			case CppCode(_): "CppCode";
			case CppCallable(_): "CppCallable";
			case CppVar(VarLocal(_)): "CppVarLocal";
			case CppVar(VarClosure(_)): "CppVarClosure";
			case CppVar(VarThis(_)): "CppVarThis";
			case CppVar(VarInstance(expr, field, clazz, op)): "CppVarInstance(" + clazz + "::" + op + field.cfName + ")";
			case CppVar(VarInterface(_)): "CppVarInterface";
			case CppVar(VarStatic(_, true, _)): "CppObjcVarStatic";
			case CppVar(VarStatic(_)): "CppVarStatic";
			case CppVar(VarInternal(_)): "CppVarInternal";
			case CppDynamicField(_): "CppDynamicField";
			case CppExtern(_): "CppExtern";
			case CppFunction(_): "CppFunction";
			case CppEnumIndex(_): "CppEnumIndex";
			case CppEnumField(_): "CppEnumField";
			case CppNullAccess: "CppNullAccess";
			case CppCall(FuncThis(_), _): "CppCallThis";
			case CppCall(FuncInstance(obj, inst, field, _), _):
				(switch inst {
					case InstObjC: "CppCallObjCInstance(";
					case InstPtr(_): "CppCallInstance(";
					case _: "CppCallStruct(";
				}) + tcppToString(obj.cpptype) + "," + field.cfName + ")";
			case CppCall(FuncInterface(_), _): "CppCallInterface";
			case CppCall(FuncStatic(_, objC, _, _), _): objC ? "CppCallStaticObjC" : "CppCallStatic";
			case CppCall(FuncTemplate(_), _): "CppCallTemplate";
			case CppCall(FuncEnumConstruct(_), _): "CppCallEnumConstruct";
			case CppCall(FuncSuperConstruct(_), _): "CppCallSuperConstruct";
			case CppCall(FuncSuper(_), _): "CppCallSuper";
			case CppCall(FuncNew(_), _): "CppCallNew";
			case CppCall(FuncExpression(_), _): "CppCallExpression";
			case CppCall(FuncInternal(_), _): "CppCallInternal";
			case CppCall(FuncExtern(_), _): "CppCallExtern";
			case CppCall(FuncFromStaticFunction, _): "CppCallFromStaticFunction";
			case CppNewNative(_): "CppNewNative";
			case CppAddressOf(_): "CppAddressOf";
			case CppDereference(_): "CppDereference";
			case CppFunctionAddress(_): "CppFunctionAddress";
			case CppArray(_): "CppArray";
			case CppCrement(_): "CppCrement";
			case CppSet(_): "CppSet";
			case CppModify(_): "CppModify";
			case CppBinop(_): "CppBinop";
			case CppCompare(_): "CppCompare";
			case CppNullCompare(_): "CppNullCompare";
			case CppObjectDecl(_): "CppObjectDecl";
			case CppPosition(_): "CppPosition";
			case CppArrayDecl(_): "CppArrayDecl";
			case CppUnop(_): "CppUnop";
			case CppVarDecl(_): "CppVarDecl";
			case CppBlock(_): "CppBlock";
			case CppFor(_): "CppFor";
			case CppIf(_): "CppIf";
			case CppWhile(_): "CppWhile";
			case CppIntSwitch(_): "CppIntSwitch";
			case CppSwitch(_): "CppSwitch";
			case CppTry(_): "CppTry";
			case CppBreak: "CppBreak";
			case CppContinue: "CppContinue";
			case CppClassOf(_): "CppClassOf";
			case CppGoto(_): "CppGoto";
			case CppReturn(_): "CppReturn";
			case CppThrow(_): "CppThrow";
			case CppEnumParameter(_): "CppEnumParameter";
			case CppTCast(_): "CppTCast";
			case CppCast(_): "CppCast";
			case CppCastStatic(_): "CppCastStatic";
			case CppCastScalar(_): "CppCastScalar";
			case CppCastVariant(_): "CppCastVariant";
			case CppCastObjC(_): "CppCastObjC";
			case CppCastObjCBlock(_): "CppCastObjCBlock";
			case CppCastProtocol(_): "CppCastProtocol";
			case CppCastNative(_): "CppCastNative";
		}
	}

	static function nativeSuffix(valueType:NativeType):String return switch valueType {
		case Pointer(_): "*";
		case _: "";
	}

	public static function tcppToStringSuffix(suffix:String, tcpp:Tcpp):String {
		return switch tcpp {
			case TCppDynamic: " ::Dynamic";
			case TCppUnchanged: " ::Dynamic/*Unchanged*/";
			case TCppObject: " ::Dynamic";
			case TCppObjectPtr: " ::hx::Object *";
			case TCppStruct(t): "cpp::Struct< " + tcppToString(t) + " >";
			case TCppReference(TCppMarshalNativeType(valueType, _)): getNativeMarshalledType(valueType) + "&";
			case TCppReference(t): tcppToString(t) + " &";
			case TCppStar(TCppMarshalNativeType(valueType, _), isConst):
				var suffix = nativeSuffix(valueType);
				(isConst ? "const " : "") + getNativeMarshalledType(valueType) + "*" + suffix;
			case TCppStar(t, isConst):
				(isConst ? "const " : "") + tcppToString(t) + " *";
			case TCppVoid: "void";
			case TCppVoidStar: "void *";
			case TCppRest(_): "vaarg_list";
			case TCppVarArg: "vararg";
			case TCppAutoCast: "::cpp::AutoCast";
			case TCppVariant(null): "::cpp::Variant";
			case TCppVariant(t): '::cpp::Variant( ${tcppToString(t)} )';
			case TCppEnum(enumDef): " ::" + joinClassPathRemap(enumDef.ePath, "::") + suffix;
			case TCppScalar(scalar): scalar;
			case TCppString: "::String";
			case TCppFastIterator(it): "::cpp::FastIterator" + suffix + "< " + tcppToString(it) + " >";
			case TCppPointer(ptrType, TCppMarshalNativeType(valueType, _)):
				var suffix = nativeSuffix(valueType);
				'::cpp::$ptrType< ${getNativeMarshalledType(valueType)}$suffix >';
			case TCppPointer(ptrType, valueType):
				"::cpp::" + ptrType + "< " + tcppToString(valueType) + " >";
			case TCppRawPointer(constName, TCppMarshalNativeType(valueType, _)):
				var suffix = nativeSuffix(valueType);
				constName + getNativeMarshalledType(valueType) + "*" + suffix;
			case TCppRawPointer(constName, valueType):
				constName + tcppToString(valueType) + "*";
			case TCppFunction(argTypes, retType, abi):
				var args = argTypes.map(tcppToString).join(",");
				"::cpp::Function< " + tcppToString(retType) + " " + abi + " (" + args + ") >";
			case TCppObjCBlock(argTypes, retType):
				tcppObjcBlockStruct(argTypes, retType) + "::t";
			case TCppDynamicArray: "::cpp::VirtualArray" + suffix;
			case TCppObjectArray(_): "::Array" + suffix + "< ::Dynamic>";
			case TCppScalarArray(value): "::Array" + suffix + "< " + tcppToString(value) + " >";
			case TCppObjC(klass):
				var path = joinClassPathRemap(klass.clPath, "::");
				if (hasClassFlag(klass, CInterface)) "id < " + path + ">" else path + " *";
			case TCppProtocol(iface):
				var path = switch Ast.getMetaString(iface.clMeta, Meta.ObjcProtocol) {
					case null: joinClassPathRemap(iface.clPath, "::");
					case p: p;
				}
				"id < " + path + ">";
			case TCppNativePointer(klass):
				var name = joinClassPathRemap(klass.clPath, "::");
				if (suffix == "_obj") name else "::hx::Native< " + name + "* >";
			case TCppInst(klass, p):
				cppClassPathOf(klass, p) + (isNativeClass(klass) ? "" : suffix);
			case TCppInterface(klass) if (suffix == "_obj"):
				cppClassPathOf(klass, []) + suffix;
			case TCppInterface(_): "::Dynamic";
			case TCppClass: "::hx::Class" + suffix;
			case TCppGlobal: "::Dynamic";
			case TCppNull: " ::Dynamic";
			case TCppCode(_): "Code";
			case TCppMarshalManagedType(cls, params):
				var r = buildType(cls.clPath, cls.clPos, params, cls.clMeta, Meta.CppManagedType, tcppToString);
				var typeStr = r.type, flags = r.flags;
				var standardNaming = flags.indexOf("StandardNaming") >= 0;
				var wrapped = if (suffix == "_obj") {
					if (standardNaming) typeStr + suffix else typeStr;
				} else {
					if (standardNaming) typeStr else '::hx::ObjectPtr< $typeStr >';
				}
				wrapped;
			case TCppMarshalNativeType(valueType = Pointer(_), Promoted):
				'::cpp::marshal::Boxed< ${getNativeMarshalledType(valueType)}* >';
			case TCppMarshalNativeType(valueType = Pointer(_), Reference):
				'::cpp::marshal::PointerReference< ${getNativeMarshalledType(valueType)} >';
			case TCppMarshalNativeType(valueType = Pointer(_), Stack):
				'::cpp::marshal::PointerType< ${getNativeMarshalledType(valueType)} >';
			case TCppMarshalNativeType(valueType = (ValueClass(_) | ValueEnum(_)), Promoted):
				'::cpp::marshal::Boxed< ${getNativeMarshalledType(valueType)} >';
			case TCppMarshalNativeType(valueType = (ValueClass(_) | ValueEnum(_)), Reference):
				'::cpp::marshal::ValueReference< ${getNativeMarshalledType(valueType)} >';
			case TCppMarshalNativeType(valueType = (ValueClass(_) | ValueEnum(_)), Stack):
				'::cpp::marshal::ValueType< ${getNativeMarshalledType(valueType)} >';
			case TCppCallable(arguments, ret):
				var returnStr = tcppToString(ret);
				var argumentsStr = arguments.map(tcppToString).join(",");
				'::hx::Callable< $returnStr ($argumentsStr) >';
		}
	}

	public static function buildType<A>(path:GlobalTypePath, pos:Pos, params:Array<A>, meta:Metadata, target:core.MetaList.StrictMeta,
			parameterHandler:A->String):{type:String, flags:Array<String>} {
		function getMetaField(field:String):Null<ObjectField> {
			var m = Meta.get(target, meta);
			return switch m.exprs {
				case [{expr: EObjectDecl(decls)}]:
					var found = null;
					for (d in decls) if (d.key.name == field) {
						found = d;
						break;
					}
					found;
				case _:
					null;
			}
		}
		var typeParams = switch params {
			case []: "";
			case _: "< " + params.map(parameterHandler).join(",") + " >";
		}
		function namespaceError(pos:Pos):Dynamic return CppError.cppAbort(InvalidNamespaceField, pos);
		function flagError(pos:Pos):Dynamic return CppError.cppAbort(InvalidFlagsField, pos);
		var namespace = switch getMetaField("namespace") {
			case {expr: {expr: EArrayDecl([])}}: "";
			case {expr: {expr: EArrayDecl(els)}}:
				var parts = [];
				for (e in els) switch e.expr {
					case EConst(String(s, _)): parts.push(s);
					case _: namespaceError(e.pos);
				}
				"::" + parts.join("::");
			case null:
				"";
			case f:
				namespaceError(f.key.pos);
		}
		var t = switch getMetaField("type") {
			case {expr: {expr: EConst(String(s, _))}}: s + typeParams;
			case null: path.name + typeParams;
			case f: CppError.cppAbort(InvalidTypeField, f.key.pos);
		}
		var flags:Array<String> = switch getMetaField("flags") {
			case {expr: {expr: EArrayDecl(decls)}}:
				var r = [];
				for (d in decls) switch d.expr {
					case EConst(Ident(c)): r.push(c);
					case _: flagError(d.pos);
				}
				r;
			case null:
				[];
			case f:
				flagError(f.key.pos);
		}
		return {type: '$namespace::$t', flags: flags};
	}

	public static function getExternValueTypeBoxed(valueType:NativeType):{ptr:String, obj:String} {
		var p = getNativeMarshalledType(valueType);
		var suffix = nativeSuffix(valueType);
		return {ptr: '::cpp::marshal::Boxed< $p$suffix >', obj: '::cpp::marshal::Boxed_obj< $p$suffix >'};
	}

	public static function marshalTypeParameterToString(pos:Pos, tcpp:Tcpp):String {
		return switch tcpp {
			case TCppMarshalNativeType(valueType = Pointer(_), _): getNativeMarshalledType(valueType) + "*";
			case TCppMarshalNativeType(valueType, _): getNativeMarshalledType(valueType);
			case TCppScalar(_) | TCppPointer(_) | TCppRawPointer(_) | TCppStar(_) | TCppVoidStar | TCppStruct(_):
				tcppToStringSuffix("", tcpp);
			case _:
				CppError.cppAbort(InvalidMarshallingTypeParameter, pos);
		}
	}

	public static function getNativeMarshalledType(valueType:NativeType):String {
		return switch valueType {
			case ValueClass(cls, params):
				buildType(cls.clPath, cls.clPos, params, cls.clMeta, Meta.CppValueType, function(t) return marshalTypeParameterToString(cls.clPos, t)).type;
			case ValueEnum(abs):
				buildType(abs.aPath, abs.aPos, ([] : Array<Tcpp>), abs.aMeta, Meta.CppValueType,
					function(t) return marshalTypeParameterToString(abs.aPos, t)).type;
			case Pointer(cls, params):
				buildType(cls.clPath, cls.clPos, params, cls.clMeta, Meta.CppPointerType, function(t) return marshalTypeParameterToString(cls.clPos, t)).type;
		}
	}

	public static function tcppObjcBlockStruct(argTypes:Array<Tcpp>, retType:Tcpp):String {
		var args = argTypes.map(tcppToString).join(",");
		var ret = tcppToString(retType);
		var suffix = Std.string(argTypes.length);
		return if (ret == "void") {
			if (argTypes.length == 0) "::hx::TObjcBlockVoidVoid" else "::hx::TObjcBlockVoidArgs" + suffix + "< " + args + " >";
		} else if (argTypes.length == 0) "::hx::TObjcBlockRetVoid< " + ret + " >" else
			"::hx::TObjcBlockRetArgs" + suffix + "< " + ret + "," + args + " >";
	}

	public static function tcppToString(tcpp:Tcpp):String return tcppToStringSuffix("", tcpp);

	public static function cppClassPathOf(klass:TClass, params:Array<Tcpp>):String {
		return if (isMarshallingNativeValueClass(klass)) getNativeMarshalledType(ValueClass(klass, params)) else
			switch Ast.getMetaString(klass.clMeta, Meta.Native) {
				case null:
					" ::" + joinClassPathRemap(klass.clPath, "::");
				case s:
					var typeParams = switch params {
						case []: "";
						case _: "< " + params.map(tcppToString).join(",") + " >";
					}
					" " + joinClassPathRemap(klass.clPath, "::") + typeParams;
			}
	}

	/*  Get a string to represent a type.
		The "suffix" will be nothing or "_obj", depending if we want the name of the
		pointer class or the pointee (_obj class */
	public static function classString(klass:TClass, suffix:String, params:TParams, remap:Bool):String {
		var typeString = function(t) return typeStringRemap(remap, t);
		var joinClassPathRemap = remap ? CppAstTools.joinClassPathRemap : CppAstTools.joinClassPath;
		return switch [klass.clPath.pack, klass.clPath.name] {
			/* Array class */
			case [[], "Array"] if (isDynamicArrayParam(hd(params))):
				"cpp::ArrayBase" + suffix;
			/*"cpp::VirtualArray" ^ suffix*/
			case [[], "Array"]:
				klass.clPath.name + suffix + "< " + params.map(arrayElementType).join(",") + " >";
			/* FastIterator class */
			case [["cpp"], "FastIterator"]:
				"::cpp::FastIterator" + suffix + "< " + params.map(typeString).join(",") + " >";
			case [["cpp"], "Pointer"] | [["cpp"], "ConstPointer"]:
				"::cpp::Pointer< " + params.map(typeString).join(",") + " >";
			case [["cpp"], "RawPointer"]:
				" " + params.map(typeString).join(",") + " * ";
			case [["cpp"], "RawConstPointer"]:
				" const " + params.map(typeString).join(",") + " * ";
			case [["cpp"], "Function"]:
				"::cpp::Function< " + cppFunctionSignatureParams(params) + " >";
			case _ if (isDynamicTypeParam(klass.clKind)): "Dynamic";
			case [[], "#Int"]: "/* # */int";
			case [["cpp"], "UInt8"]: "unsigned char";
			case [[], "Class"]: "::hx::Class";
			case [[], "EnumValue"]: "Dynamic";
			case [[], "Null"]:
				switch params {
					case [t]:
						switch follow(t) {
							case TAbstract({aPath: {pack: [], name: "Int"}}, _) | TAbstract({aPath: {pack: [], name: "Float"}}, _) |
								TAbstract({aPath: {pack: [], name: "Bool"}}, _): "Dynamic";
							case TAbstract({aPath: {pack: ["cpp"], name: "UInt8"}}, _): "Dynamic";
							case t if (typeHasMetaKey(Meta.NotNull, t)): "Dynamic";
							case _: "/*NULL*/" + typeString(t);
						}
					case _: die("", "cppAstTools.ml");
				}
			/* Objective-C class */
			case _ if (isObjcType(TInst(klass, vector()))):
				var str = joinClassPathRemap(klass.clPath, "::");
				if (suffix == "_obj") str else if (hasClassFlag(klass, CInterface)) "id < " + str + ">" else str + " *";
			/* Native interface - use pointer */
			case _ if (hasClassFlag(klass, CInterface) && isNativeGenClass(klass)):
				joinClassPathRemap(klass.clPath, "::") + " *";
			/* Normal class */
			case _ if (isNativeClass(klass)):
				var classParams = switch params {
					case []: "";
					case _: "< " + params.map(typeString).join(",") + " >";
				}
				joinClassPathRemap(klass.clPath, "::") + classParams;
			case _:
				var globalNamespace = switch Ast.getMetaString(klass.clMeta, Meta.Native) {
					case null: "::";
					case s: s;
				}
				globalNamespace + joinClassPathRemap(klass.clPath, "::") + suffix;
		}
	}

	// port: List.hd.
	static function hd<A>(l:haxe.ds.Vector<A>):A {
		if (l.length == 0) throw new core.ds.Failure("hd");
		return l[0];
	}

	public static function typeHasMetaKey(key:core.MetaList.StrictMeta, haxeType:T):Bool {
		return switch follow(haxeType) {
			case TInst(klass, _): Meta.has(key, klass.clMeta);
			case TType(typeDef, _): Meta.has(key, typeDef.tMeta);
			case TEnum(enumDef, _): Meta.has(key, enumDef.eMeta);
			case _: false;
		}
	}

	public static function typeStringSuff(suffix:String, haxeType:T, remap:Bool):String {
		var typeString = function(t) return typeStringRemap(remap, t);
		var joinClassPathRemap = remap ? CppAstTools.joinClassPathRemap : CppAstTools.joinClassPath;
		return switch haxeType {
			case TMono(r):
				r.tmType == null ? "Dynamic" + suffix : typeStringSuff(suffix, r.tmType, remap);
			case TAbstract({aPath: {pack: [], name: "Void"}}, []): "Void";
			case TAbstract({aPath: {pack: [], name: "Bool"}}, []): "bool";
			case TAbstract({aPath: {pack: [], name: "Float"}}, []): "Float";
			case TAbstract({aPath: {pack: [], name: "Int"}}, []): "int";
			case TAbstract({aPath: {pack: ["cpp"], name: "UInt8"}}, []): "unsigned char";
			case TAbstract({aPath: {pack: [], name: "EnumValue"}}, _): "Dynamic";
			case TAbstract({aPath: {pack: [], name: "Null"}}, [t]):
				switch follow(t) {
					case TAbstract({aPath: {pack: [], name: "Int"}}, _) | TAbstract({aPath: {pack: [], name: "Float"}}, _) |
						TAbstract({aPath: {pack: [], name: "Bool"}}, _): "Dynamic" + suffix;
					case t if (typeHasMetaKey(Meta.NotNull, t)): "Dynamic" + suffix;
					case _: typeStringSuff(suffix, t, remap);
				}
			case TEnum(enumDef, _): cppEnumPathOf(enumDef) + suffix;
			case TInst(klass, params): classString(klass, suffix, params, remap);
			case TType(typeDef, params):
				switch [typeDef.tPath.pack, typeDef.tPath.name] {
					case [[], "Array"]:
						switch params {
							case [t] if (typeString(follow(t)) == "Dynamic"): "Dynamic";
							case [t]: "Array< " + typeString(follow(t)) + " >";
							case _: die("", "cppAstTools.ml");
						}
					case [["cpp"], "FastIterator"]:
						switch params {
							case [t]: "::cpp::FastIterator< " + typeString(follow(t)) + " >";
							case _: die("", "cppAstTools.ml");
						}
					case [["cpp"], "Pointer"] | [["cpp"], "ConstPointer"]:
						switch params {
							case [t]: "::cpp::Pointer< " + typeString(follow(t)) + " >";
							case _: die("", "cppAstTools.ml");
						}
					case [["cpp"], "RawPointer"]:
						switch params {
							case [t]: " " + typeString(follow(t)) + " *";
							case _: die("", "cppAstTools.ml");
						}
					case [["cpp"], "RawConstPointer"]:
						switch params {
							case [t]: "const " + typeString(follow(t)) + " *";
							case _: die("", "cppAstTools.ml");
						}
					case [["cpp"], "Function"]:
						"::cpp::Function< " + cppFunctionSignatureParams(params) + " >";
					case _:
						typeStringSuff(suffix, applyTypedef(typeDef, params), remap);
				}
			case TFun(_): "Dynamic" + suffix;
			case TAnon(a): "Dynamic";
			/*
				(match !(a.a_status) with
				| ClassStatics c -> type_string_suff suffix (TInst (c,List.map snd c.cl_params))
				| EnumStatics e -> type_string_suff suffix (TEnum (e,List.map snd e.e_params))
				| _ -> "Dynamic"  ^ suffix )
			 */
			case TDynamic(_): "Dynamic" + suffix;
			case TLazy(func): typeStringSuff(suffix, lazyType(func), remap);
			case TAbstract(abs, pl) if (abs.aImpl != null):
				typeStringSuff(suffix, core.Abstract.getUnderlyingType(abs, pl), remap);
			case TAbstract(abs, pl):
				"::" + joinClassPathRemap(abs.aPath, "::") + suffix;
		}
	}

	public static function typeStringRemap(remap:Bool, haxeType:T):String return typeStringSuff("", haxeType, remap);

	public static function typeString(haxeType:T):String return typeStringSuff("", haxeType, true);

	public static function cppEnumPathOf(enumDef:TEnum):String {
		var globalNamespace = switch Ast.getMetaString(enumDef.eMeta, Meta.Native) {
			case null: "::";
			case s: s;
		}
		return globalNamespace + joinClassPathRemap(enumDef.ePath, "::");
	}

	public static function arrayElementType(haxeType:T):String {
		return switch typeString(haxeType) {
			case x if (cantBeNull(haxeType)): x;
			case x if (isInterfaceType(follow(haxeType))): x;
			case "::String": "::String";
			case _: "::Dynamic";
		}
	}

	public static function cppFunctionSignature(tfun:T, abi:String):String {
		function genInterfaceArgTypeName(name:String, opt:Bool, typ:T):String {
			var typeStr = typeString(typ);
			/* type_str may have already converted Null<X> to Dynamic because of NotNull tag ... */
			return (if (opt && cantBeNull(typ) && typeStr != "Dynamic") "::hx::Null< " + typeStr + " > " else typeStr) + " " + keywordRemap(name);
		}
		function genTfunInterfaceArgList(args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>):String
			return args.map(function(a) return genInterfaceArgTypeName(a.name, a.optional, a.type)).join(",");
		return switch follow(tfun) {
			case TFun(sig): typeString(sig.ret) + " " + abi + "(" + genTfunInterfaceArgList(sig.args) + ")";
			case _: "void *";
		}
	}

	public static function cppFunctionSignatureParams(params:TParams):String {
		return switch params {
			case [t, abi]:
				switch follow(abi) {
					case TInst(klass, _):
						cppFunctionSignature(t, switch Ast.getMetaString(klass.clMeta, Meta.Abi) {
							case null: "";
							case s: s;
						});
					case _:
						Sys.println(typeString(abi));
						die("", "cppAstTools.ml");
				}
			case _:
				Sys.println("Params:" + params.map(typeString).join(","));
				die("", "cppAstTools.ml");
		}
	}

	public static function cantBeNull(haxeType:T):Bool return isNumeric(haxeType) || typeHasMetaKey(Meta.NotNull, haxeType);

	public static function isCppScalar(cppType:Tcpp):Bool return cppType.match(TCppScalar(_));

	public static function isCppArrayImplementer(cppType:Tcpp):Bool {
		return switch cppType {
			case TCppInst(cls, _) if (cls.clArrayAccess != null): true;
			case TCppInterface(cls) if (cls.clArrayAccess != null): true;
			case _: false;
		}
	}

	public static function cppIsStructAccess(t:Tcpp):Bool {
		return switch t {
			case TCppFunction(_): true;
			case TCppStruct(_): false;
			case TCppInst(classDef, _): Meta.has(Meta.StructAccess, classDef.clMeta);
			case TCppReference(TCppMarshalNativeType(_)): true;
			case TCppReference(r): cppIsStructAccess(r);
			case _: false;
		}
	}

	public static function cppIsNativeArrayAccess(t:Tcpp):Bool {
		return switch t {
			case TCppMarshalNativeType(_): true;
			case TCppStruct(s): cppIsNativeArrayAccess(s);
			case TCppReference(s): cppIsNativeArrayAccess(s);
			case TCppInst(klass, _) if (klass.clArrayAccess != null && isExternClass(klass) && Meta.has(Meta.NativeArrayAccess, klass.clMeta)): true;
			case _: false;
		}
	}

	public static function cppIsDynamicType(t:Tcpp):Bool {
		return switch t {
			case TCppDynamic | TCppObject | TCppVariant(_) | TCppGlobal | TCppNull | TCppInterface(_) | TCppCallable(_): true;
			case _: false;
		}
	}

	public static function isObjectElement(memberType:Tcpp):Bool {
		return switch memberType {
			case TCppMarshalManagedType(_) | TCppMarshalNativeType(_, Promoted): true;
			case TCppInst(x, _) | TCppInterface(x): !isExternClass(x);
			case TCppDynamic | TCppObject | TCppObjectPtr | TCppEnum(_) | TCppString | TCppFunction(_) | TCppDynamicArray | TCppObjectArray(_) |
				TCppScalarArray(_) | TCppClass | TCppCallable(_): true;
			case _: false;
		}
	}

	public static function cppVariantTypeOf(t:Tcpp):Tcpp {
		return switch t {
			case TCppDynamic | TCppUnchanged | TCppObject | TCppObjectPtr | TCppReference(_) | TCppStruct(_) | TCppMarshalNativeType(_) |
				TCppMarshalManagedType(_) | TCppStar(_) | TCppVoid | TCppFastIterator(_) | TCppDynamicArray | TCppObjectArray(_) |
				TCppScalarArray(_) | TCppObjC(_) | TCppObjCBlock(_) | TCppRest(_) | TCppInst(_) | TCppInterface(_) | TCppProtocol(_) |
				TCppCode(_) | TCppClass | TCppGlobal | TCppNull | TCppEnum(_) | TCppCallable(_): TCppDynamic;
			case TCppString: TCppString;
			case TCppFunction(_) | TCppNativePointer(_) | TCppPointer(_) | TCppRawPointer(_) | TCppAutoCast | TCppVarArg | TCppVoidStar:
				TCppVoidStar;
			case TCppScalar("Int") | TCppScalar("bool") | TCppScalar("Float"): t;
			case TCppScalar("::cpp::Int64"): TCppScalar("Int64");
			case TCppScalar("double") | TCppScalar("float"): TCppScalar("Float");
			case TCppScalar(_): TCppScalar("int");
			case TCppVariant(v): TCppVariant(v);
		}
	}

	public static function cppCastVariantTypeOf(t:Tcpp):Tcpp {
		return switch t {
			case TCppObjectArray(_) | TCppScalarArray(_) | TCppDynamicArray | TCppClass | TCppEnum(_) | TCppInst(_) | TCppMarshalManagedType(_): t;
			case _: cppVariantTypeOf(t);
		}
	}

	public static function enumGetterType(t:Tcpp):String {
		return switch cppVariantTypeOf(t) {
			case TCppString: "String";
			case TCppScalar("int"): "Int";
			case TCppScalar("bool"): "Bool";
			case TCppScalar(x): x;
			case _: "Object";
		}
	}

	public static function intOfTcppClassFlag(flag:TcppClassFlags):Int return std.Type.enumIndex(flag);

	public static function setTcppClassFlag(flags:Int, c:TcppClassFlags):Int return setFlag(flags, intOfTcppClassFlag(c));

	public static function hasTcppClassFlag(c:TcppClass, flag:TcppClassFlags):Bool return hasFlag(c.tclFlags, intOfTcppClassFlag(flag));

	public static function allInterfaceFunctions(tcppInterface:TcppInterface):Array<TcppInterfaceFunction> {
		function addInterfaceFunctions(existing:Array<TcppInterfaceFunction>, iface:TcppInterface):Array<TcppInterfaceFunction> {
			var acc = existing;
			for (cur in iface.ifFunctions) {
				if (!Lambda.exists(acc, function(f) return f.iffName == cur.iffName)) acc = [cur].concat(acc);
			}
			return acc;
		}
		function visitInterface(existing:Array<TcppInterfaceFunction>, iface:TcppInterface):Array<TcppInterfaceFunction> {
			var initial = switch iface.ifExtends {
				case null: existing;
				case sup: visitInterface(existing, sup);
			}
			return addInterfaceFunctions(initial, iface);
		}
		var r = visitInterface([], tcppInterface);
		r.reverse();
		return r;
	}
}
