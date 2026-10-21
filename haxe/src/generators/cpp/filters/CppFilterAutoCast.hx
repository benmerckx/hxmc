package generators.cpp.filters;

import core.TType;
import core.Meta;
import generators.cpp.CppAst;
import generators.cpp.CppAstTools.*;
import generators.cpp.CppTypeUtils.*;
import generators.cpp.CppError;
import core.ds.VectorTools.vector;

class CppFilterAutoCast {
	public static function autocastFilter(forCppia:Bool, returnType:Tcpp, cppexpr:TcppExpr):TcppExpr {
		var objectExpression = switch cppexpr.cpptype {
			case TCppVariant(_) | TCppDynamic | TCppObject: true;
			case _: false;
		}

		function mkCppexpr(newExpr:TcppExprExpr, newType:Tcpp):TcppExpr return {cppexpr: newExpr, cpptype: newType, cpppos: cppexpr.cpppos};

		function castToVarArgs():TcppExpr {
			return switch cppVariantTypeOf(cppexpr.cpptype) {
				case TCppVoidStar | TCppScalar(_):
					cppexpr;
				case TCppString:
					mkCppexpr(CppVar(VarInternal(cppexpr, ".", "raw_ptr()")), TCppPointer("ConstPointer", TCppScalar("char")));
				case TCppDynamic:
					mkCppexpr(CppCastNative(cppexpr), TCppVoidStar);
				case _:
					var toDynamic = mkCppexpr(CppCast(cppexpr, TCppDynamic), TCppDynamic);
					mkCppexpr(CppCastNative(toDynamic), TCppVoidStar);
			}
		}

		function castFromObject():TcppExpr {
			function isVariant(t:Tcpp):Bool return t.match(TCppVariant(_));

			return switch returnType {
				case TCppUnchanged:
					cppexpr;
				case inst = TCppInst(t, _) if (Meta.has(Meta.StructAccess, t.clMeta)):
					var structType = TCppStruct(inst);
					var structCast = mkCppexpr(CppCast(cppexpr, structType), structType);
					mkCppexpr(CppCast(structCast, inst), inst);
				case TCppObjectArray(_) | TCppScalarArray(_) | TCppNativePointer(_) | TCppDynamicArray | TCppObjectPtr | TCppVarArg |
					TCppMarshalManagedType(_) | TCppInst(_):
					mkCppexpr(CppCast(cppexpr, returnType), returnType);
				case TCppObjC(k):
					mkCppexpr(CppCastObjC(cppexpr, k), returnType);
				case TCppObjCBlock(ret, args):
					mkCppexpr(CppCastObjCBlock(cppexpr, ret, args), returnType);
				case TCppScalar(scalar):
					mkCppexpr(CppCastScalar(cppexpr, scalar), returnType);
				case TCppString:
					mkCppexpr(CppCastScalar(cppexpr, "::String"), returnType);
				case TCppInterface(_) if (isVariant(cppexpr.cpptype)):
					mkCppexpr(CppCastVariant(cppexpr), returnType);
				case TCppDynamic if (isVariant(cppexpr.cpptype)):
					mkCppexpr(CppCastVariant(cppexpr), returnType);
				case TCppCallable(_) if (isVariant(cppexpr.cpptype)):
					mkCppexpr(CppCast(cppexpr, returnType), returnType);
				case ptr = TCppStar(t, isConst):
					var ptrType = TCppPointer((isConst ? "ConstPointer" : "Pointer"), t);
					var ptrCast = mkCppexpr(CppCast(cppexpr, ptrType), ptrType);
					mkCppexpr(CppCast(ptrCast, ptr), ptr);
				/* When going from a dynamic or variant add an explicit cast so the ::cpp::marshal::Reference constructor
				 * takes care of checking the dynamic type */
				case TCppMarshalNativeType(_, _):
					mkCppexpr(CppCast(cppexpr, returnType), returnType);
				case _:
					cppexpr;
			}
		}

		function castOther():TcppExpr {
			return switch [cppexpr.cpptype, returnType] {
				case [_, TCppUnchanged]:
					cppexpr;
				// port: a line comment: the upstream block comment nests `/* */`.
				// Using the 'typedef hack', where we use typedef X<T> = T, allows the
				// haxe compiler to use these types interchangeably. We then work
				// out the correct way to convert between them when one is expected, but another provided.
				//
				// TCppFunction: these do not really interact with the haxe function type, T
				// Since they are implemented with cpp::Function, conversion to/from Dynamic should happen automatically
				// CallableData<T> = T;
				// FunctionData<T,ABI> = T;
				//
				// TCppObjCBlock can move in and out of Dyanmic
				// ObjcBlock<T> = T;
				//
				// TCppProtocol can move in and out of Dyanmic, via delegate creation
				// Protocol<T /*:interface*/ > = T;
				//
				// Explicitly wrapped type - already interacts well with Dynamic and T
				// Struct<T> = T;
				//
				// TCppStar, TCppStruct, TCppReference - for interacting with native code
				// Star<T> = T;
				// ConstStar<T> = T;
				// Reference<T> = T;
				// T may be an extern class, with @:structAccess - in which case
				// Dynamic interaction must be handled explicitly
				// These types, plus Dynamic can be used interchangeably by haxe
				// Derived/inherited types may also be mixed in
				case [TCppAutoCast, _] | [TCppObjC(_), TCppDynamic] | [TCppObjCBlock(_), TCppDynamic]:
					mkCppexpr(CppCast(cppexpr, returnType), returnType);
				/* Infer type from right-hand-side for pointer or reference to Dynamic */
				case [TCppReference(TCppDynamic), TCppReference(_)]:
					cppexpr;
				case [TCppReference(TCppDynamic), t]:
					mkCppexpr(cppexpr.cppexpr, TCppReference(t));
				case [TCppStar(TCppDynamic, _), TCppStar(_, _)]:
					cppexpr;
				case [TCppStar(TCppDynamic, isConst), t]:
					mkCppexpr(cppexpr.cppexpr, TCppStar(t, isConst));
				case [TCppStar(t, isConst), TCppDynamic]:
					var ptrType = TCppPointer((isConst ? "ConstPointer" : "Pointer"), t);
					var ptrCast = mkCppexpr(CppCast(cppexpr, ptrType), ptrType);
					mkCppexpr(CppCast(ptrCast, TCppDynamic), TCppDynamic);
				case [TCppStar(t, isConst), TCppReference(_)] | [TCppStar(t, isConst), TCppInst(_)] | [TCppStar(t, isConst), TCppMarshalManagedType(_)] |
					[TCppStar(t, isConst), TCppStruct(_)]:
					mkCppexpr(CppDereference(cppexpr), returnType);
				case [TCppInst(t, _), TCppStar(_)] if (isNativeClass(t) && cppexpr.cppexpr.match(CppCall(FuncNew(_), _))):
					mkCppexpr(CppNewNative(cppexpr), returnType);
				case [TCppInst(_), TCppStar(p, isConst)] | [TCppMarshalManagedType(_), TCppStar(p, isConst)] | [TCppStruct(_), TCppStar(p, isConst)]:
					mkCppexpr(CppAddressOf(cppexpr), returnType);
				case [TCppObjectPtr, TCppObjectPtr]:
					cppexpr;
				case [TCppObjectPtr, _]:
					mkCppexpr(CppCast(cppexpr, TCppDynamic), TCppDynamic);
				case [TCppProtocol(_), TCppProtocol(_)]:
					cppexpr;
				case [t, TCppProtocol(protocol)]:
					mkCppexpr(CppCastProtocol(cppexpr, protocol), returnType);
				case [inst = TCppInst(t, _), TCppDynamic] if (Meta.has(Meta.StructAccess, t.clMeta)):
					var structType = TCppStruct(inst);
					var structCast = mkCppexpr(CppCast(cppexpr, structType), structType);
					mkCppexpr(CppCast(structCast, TCppDynamic), TCppDynamic);
				case [_, TCppObjectPtr]:
					mkCppexpr(CppCast(cppexpr, TCppObjectPtr), TCppObjectPtr);
				case [TCppDynamicArray, TCppScalarArray(_)] | [TCppDynamicArray, TCppObjectArray(_)] | [TCppScalarArray(_), TCppDynamicArray] |
					[TCppObjectArray(_), TCppDynamicArray] if (forCppia):
					mkCppexpr(CppCast(cppexpr, returnType), returnType);
				case [TCppScalar(from), TCppScalar(too)] if (from != too):
					mkCppexpr(CppCastScalar(cppexpr, too), returnType);
				/* If we are going between two pointers or value type classes which mismatch add a cast so the reference type reinterprets the pointer */
				/* This happens in inheritance related situations */
				case [TCppMarshalNativeType((ValueClass(fstCls, fstParams) | Pointer(fstCls, fstParams)), _),
					TCppMarshalNativeType(dst = (ValueClass(sndCls, sndParams) | Pointer(sndCls, sndParams)), _)]
					if (!core.TUnification.fastEq(TInst(fstCls, vector()), TInst(sndCls, vector()))):
					var reference = TCppMarshalNativeType(dst, Reference);
					mkCppexpr(CppCast(cppexpr, reference), reference);
				/* Ensure we wrap any access to the stack or promoted type in a reference object. */
				/* TIdents are wrapped at retyping but array access and others won't be, so this will wrap them. */
				case [TCppMarshalNativeType(ValueClass(cls, _), (Stack | Reference)), other]
					if (CppMarshalling.isStackOnlyMarshallingNativeValueClass(cls) && isObjectElement(other)):
					CppError.cppAbort(PromotedStackOnlyValueType, cppexpr.cpppos);
				case [TCppMarshalNativeType(valueType, Stack), (TCppPointer(_))] | [TCppMarshalNativeType(valueType, Stack), (TCppRawPointer(_))] |
					[TCppMarshalNativeType(valueType, Stack), (TCppStar(_))] | [TCppMarshalNativeType(valueType, Stack), (TCppReference(_))] |
					[TCppMarshalNativeType(_, Stack), TCppMarshalNativeType(valueType, (Promoted))]:
					var reference = TCppMarshalNativeType(valueType, Reference);
					mkCppexpr(CppCast(cppexpr, reference), reference);
				case [TCppMarshalNativeType(valueType, Promoted), (TCppPointer(_))] | [TCppMarshalNativeType(valueType, Promoted), (TCppRawPointer(_))] |
					[TCppMarshalNativeType(valueType, Promoted), (TCppStar(_))] | [TCppMarshalNativeType(valueType, Promoted), (TCppReference(_))] |
					[TCppMarshalNativeType(_, Promoted), TCppMarshalNativeType(valueType, (Stack))]:
					var reference = TCppMarshalNativeType(valueType, Reference);
					mkCppexpr(CppCast(cppexpr, reference), reference);
				case [TCppMarshalNativeType(valueType, (Stack | Promoted)), (TCppMarshalNativeType(_, Reference) | TCppDynamic | TCppVariant(_))]:
					var reference = TCppMarshalNativeType(valueType, Reference);
					mkCppexpr(CppCast(cppexpr, reference), reference);
				case _:
					cppexpr;
			}
		}

		return switch returnType {
			case TCppVoid:
				mkCppexpr(cppexpr.cppexpr, TCppVoid);
			case TCppVarArg:
				castToVarArgs();
			case _ if (objectExpression):
				castFromObject();
			case _:
				castOther();
		}
	}
}
