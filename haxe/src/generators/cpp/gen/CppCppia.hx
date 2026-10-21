package generators.cpp.gen;

import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.Meta;
import core.Define;
import generators.Gctx;
import generators.cpp.CppAst;
import generators.cpp.CppTypeUtils.*;
import generators.cpp.CppAstTools.*;
import generators.cpp.CppContext;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

enum ScriptType {
	ScriptBool;
	ScriptInt;
	ScriptFloat;
	ScriptString;
	ScriptObject;
	ScriptVoid;
}

enum ArrayOf {
	ArrayInterface(i:Int);
	ArrayData(s:String);
	ArrayObject;
	ArrayAny;
	ArrayNone;
}

enum CppiaOp {
	IaFunction;
	IaVar;
	IaToInterface;
	IaToDynArray;
	IaToDataArray;
	IaToInterfaceArray;
	IaFun;
	IaCast;
	IaTCast;
	IaBlock;
	IaBreak;
	IaContinue;
	IaIsNull;
	IaNotNull;
	IaSet;
	IaCall;
	IaCallGlobal;
	IaCallStatic;
	IaCallMember;
	IaCallSuper;
	IaCallThis;
	IaCallSuperNew;
	IaCreateEnum;
	IaADef;
	IaIf;
	IaIfElse;
	IaFStatic;
	IaFName;
	IaFThisInst;
	IaFLink;
	IaFThisName;
	IaFEnum;
	IaThrow;
	IaArrayI;
	IaPlusPlus;
	IaPlusPlusPost;
	IaMinusMinus;
	IaMinusMinusPost;
	IaNeg;
	IaBitNot;
	IaLogicNot;
	IaTVars;
	IaVarDecl;
	IaVarDeclI;
	IaNew;
	IaReturn;
	IaRetVal;
	IaPosInfo;
	IaObjDef;
	IaClassOf;
	IaWhile;
	IaFor;
	IaEnumI;
	IaSwitch;
	IaTry;
	IaImplDynamic;
	IaConstInt;
	IaConstFloat;
	IaConstString;
	IaConstFalse;
	IaConstTrue;
	IaConstNull;
	IaConsThis;
	IaConstSuper;
	IaCastInt;
	IaCastBool;
	IaInterface;
	IaClass;
	IaAccessNormal;
	IaAccessNot;
	IaAccessResolve;
	IaAccessCall;
	IaEnum;
	IaInline;
	IaMain;
	IaNoMain;
	IaResources;
	IaReso;
	IaNoCast;
	IaAccessCallNative;
	IaBinOp(op:Binop);
}

class CppCppia {
	public static function cppTypeOf(basic:BasicTypes, t:T):Tcpp return CppRetyper.cppTypeOf(basic, CppRetyper.withReferenceValueType, t);

	public static function toScriptType(tcpp:Tcpp):ScriptType {
		return switch tcpp {
			case TCppScalar("bool"): ScriptBool;
			case TCppScalar("int") | TCppScalar("::cpp::Int32"): ScriptInt;
			case TCppScalar("float") | TCppScalar("double") | TCppScalar("Float") | TCppScalar("::cpp::Float32") | TCppScalar("::cpp::Float64"): ScriptFloat;
			case TCppString: ScriptString;
			case TCppVoid: ScriptVoid;
			case _: ScriptObject;
		}
	}

	public static function toScriptTypeSignature(scriptType:ScriptType):String {
		return switch scriptType {
			case ScriptBool: "b";
			case ScriptInt: "i";
			case ScriptFloat: "f";
			case ScriptString: "s";
			case ScriptVoid: "v";
			case ScriptObject: "o";
		}
	}

	public static function toScriptTypeString(scriptType:ScriptType):String {
		return switch scriptType {
			case ScriptBool | ScriptInt: "Int";
			case ScriptFloat: "Float";
			case ScriptString: "String";
			case ScriptVoid: "Void";
			case ScriptObject: "Object";
		}
	}

	public static function toScriptTypeSize(scriptType:ScriptType):String {
		return switch scriptType {
			case ScriptBool | ScriptInt: "int";
			case ScriptObject: "void*";
			case ScriptFloat: "Float";
			case ScriptString: "String";
			case v: toScriptTypeString(v);
		}
	}

	public static function scriptTypeString(haxeType:T):String {
		return switch haxeType {
			case TAbstract({aPath: {pack: [], name: "Null"}}, [t]):
				switch follow(t) {
					case TAbstract({aPath: {pack: [], name: "Int"}}, _) | TAbstract({aPath: {pack: [], name: "Float"}}, _) |
						TAbstract({aPath: {pack: [], name: "Bool"}}, _):
						"Dynamic";
					case _: scriptTypeString(t);
				}
			case TInst({clPath: {pack: [], name: "Null"}}, [t]):
				switch follow(t) {
					case TAbstract({aPath: {pack: [], name: "Int"}}, _) | TAbstract({aPath: {pack: [], name: "Float"}}, _) |
						TAbstract({aPath: {pack: [], name: "Bool"}}, _):
						"Dynamic";
					case _: scriptTypeString(t);
				}
			case _:
				switch follow(haxeType) {
					case TType({tPath: {pack: [], name: "Array"}}, params): "Array";
					case TInst({clPath: {pack: [], name: "Array"}}, params):
						switch params {
							case [t]:
								switch typeStringSuff("", t, false) {
									case "int": "Array.int";
									case "Float": "Array.Float";
									case "bool": "Array.bool";
									case "::String": "Array.String";
									case "unsigned char": "Array.unsigned char";
									case "::cpp::UInt8": "Array.unsigned char";
									case "Dynamic": "Array.Any";
									case _: "Array.Object";
								}
							case _: "Array.Object";
						}
					case TAbstract(abs, pl) if (abs.aImpl != null):
						scriptTypeString(core.Abstract.getUnderlyingType(abs, pl));
					case _: typeStringSuff("", haxeType, false);
				}
		}
	}

	public static function scriptCpptypeString(cppType:Tcpp):String {
		return switch cppType {
			case TCppDynamic | TCppUnchanged | TCppObject | TCppMarshalManagedType(_) | TCppCallable(_): "Dynamic";
			case TCppObjectPtr: ".*.hx.Object*";
			case TCppReference(t): ".ref." + scriptCpptypeString(t);
			case TCppStruct(t): ".struct." + scriptCpptypeString(t);
			case TCppStar(t, _): "*." + scriptCpptypeString(t);
			case TCppVoid: "void";
			case TCppVoidStar: "*.void";
			case TCppRest(_): "vaarg_list";
			case TCppVarArg: "vararg";
			case TCppAutoCast: ".cpp.AutoCast";
			case TCppVariant(_): ".cpp.Variant";
			case TCppEnum(enumDef): joinClassPath(enumDef.ePath, ".");
			case TCppScalar(scalar): scalar;
			case TCppString: "String";
			case TCppFastIterator(it): "cpp.FastIterator." + scriptCpptypeString(it);
			case TCppPointer(_, valueType):
				"cpp.Pointer." + scriptCpptypeString(valueType);
			case TCppRawPointer(_, valueType):
				"cpp.RawPointer." + scriptCpptypeString(valueType);
			case TCppMarshalNativeType(ValueClass(cls, _), _):
				"cpp.MarshalValueClass." + (joinClassPath(cls.clPath, "."));
			case TCppMarshalNativeType(ValueEnum(abs), _):
				"cpp.MarshalValueEnum." + joinClassPath(abs.aPath, ".");
			case TCppMarshalNativeType(Pointer(cls, _), _):
				"cpp.MarshalPointer." + joinClassPath(cls.clPath, ".");
			case TCppFunction(_): "cpp.Function";
			case TCppObjCBlock(_): "cpp.ObjCBlock";
			case TCppDynamicArray: "Array.Any";
			case TCppObjectArray(_): "Array.Object";
			case TCppScalarArray(value): "Array." + scriptCpptypeString(value);
			case TCppObjC(_): "cpp.ObjC";
			case TCppProtocol(_): "cpp.ObjC.Protocol";
			case TCppNativePointer(klass):
				"cpp.Pointer." + joinClassPath(klass.clPath, ".");
			case TCppInterface(klass): joinClassPath(klass.clPath, ".");
			case TCppInst(klass, _): joinClassPath(klass.clPath, ".");
			case TCppClass: "Class";
			case TCppGlobal: "?global";
			case TCppNull: "null";
			case TCppCode(_): "Dynamic";
		}
	}

	public static function isTemplateType(t:T):Bool return false;

	public static function cppiaOpInfo(op:CppiaOp):{name:String, index:Int} {
		inline function r(n:String, i:Int) return {name: n, index: i};
		return switch op {
			case IaFunction: r("FUNCTION", 1);
			case IaVar: r("VAR", 2);
			case IaToInterface: r("TOINTERFACE", 3);
			case IaToDynArray: r("TODYNARRAY", 4);
			case IaToDataArray: r("TODATAARRAY", 5);
			case IaToInterfaceArray: r("TOINTERFACEARRAY", 6);
			case IaFun: r("FUN", 7);
			case IaCast: r("CAST", 8);
			case IaBlock: r("BLOCK", 9);
			case IaBreak: r("BREAK", 10);
			case IaContinue: r("CONTINUE", 11);
			case IaIsNull: r("ISNULL", 12);
			case IaNotNull: r("NOTNULL", 13);
			case IaSet: r("SET", 14);
			case IaCall: r("CALL", 15);
			case IaCallGlobal: r("CALLGLOBAL", 16);
			case IaCallStatic: r("CALLSTATIC", 17);
			case IaCallMember: r("CALLMEMBER", 18);
			case IaCallSuper: r("CALLSUPER", 19);
			case IaCallThis: r("CALLTHIS", 20);
			case IaCallSuperNew: r("CALLSUPERNEW", 21);
			case IaCreateEnum: r("CREATEENUM", 22);
			case IaADef: r("ADEF", 23);
			case IaIf: r("IF", 24);
			case IaIfElse: r("IFELSE", 25);
			case IaFName: r("FNAME", 27);
			case IaFStatic: r("FSTATIC", 28);
			case IaFThisInst: r("FTHISINST", 29);
			case IaFLink: r("FLINK", 30);
			case IaFThisName: r("FTHISNAME", 31);
			case IaFEnum: r("FENUM", 32);
			case IaThrow: r("THROW", 33);
			case IaArrayI: r("ARRAYI", 34);
			case IaPlusPlus: r("++", 35);
			case IaPlusPlusPost: r("+++", 36);
			case IaMinusMinus: r("--", 37);
			case IaMinusMinusPost: r("---", 38);
			case IaNeg: r("NEG", 39);
			case IaBitNot: r("~", 40);
			case IaLogicNot: r("!", 41);
			case IaTVars: r("TVARS", 42);
			case IaVarDecl: r("VARDECL", 43);
			case IaVarDeclI: r("VARDECLI", 44);
			case IaNew: r("NEW", 45);
			case IaReturn: r("RETURN", 46);
			case IaRetVal: r("RETVAL", 47);
			case IaPosInfo: r("POSINFO", 48);
			case IaObjDef: r("OBJDEF", 49);
			case IaClassOf: r("CLASSOF", 50);
			case IaWhile: r("WHILE", 51);
			case IaFor: r("FOR", 52);
			case IaEnumI: r("ENUMI", 53);
			case IaSwitch: r("SWITCH", 54);
			case IaTry: r("TRY", 55);
			case IaImplDynamic: r("IMPLDYNAMIC", 56);
			case IaConstInt: r("i", 57);
			case IaConstFloat: r("f", 58);
			case IaConstString: r("s", 59);
			case IaConstFalse: r("false", 60);
			case IaConstTrue: r("true", 61);
			case IaConstNull: r("NULL", 62);
			case IaConsThis: r("THIS", 63);
			case IaConstSuper: r("SUPER", 64);
			case IaCastInt: r("CASTINT", 65);
			case IaCastBool: r("CASTBOOL", 66);
			case IaInterface: r("INTERFACE", 67);
			case IaClass: r("CLASS", 68);
			case IaAccessNormal: r("N", 69);
			case IaAccessNot: r("n", 70);
			case IaAccessResolve: r("R", 71);
			case IaAccessCall: r("C", 72);
			case IaEnum: r("ENUM", 73);
			case IaInline: r("INLINE", 74);
			case IaMain: r("MAIN", 75);
			case IaNoMain: r("NOMAIN", 76);
			case IaResources: r("RESOURCES", 77);
			case IaReso: r("RESO", 78);
			case IaNoCast: r("NOCAST", 79);
			case IaAccessCallNative: r("V", 80);
			case IaBinOp(OpAdd): r("+", 101);
			case IaBinOp(OpMult): r("*", 102);
			case IaBinOp(OpDiv): r("/", 103);
			case IaBinOp(OpSub): r("-", 104);
			case IaBinOp(OpAssign): r("=", 105);
			case IaBinOp(OpEq): r("==", 106);
			case IaBinOp(OpNotEq): r("!=", 107);
			case IaBinOp(OpGte): r(">=", 108);
			case IaBinOp(OpLte): r("<=", 109);
			case IaBinOp(OpGt): r(">", 110);
			case IaBinOp(OpLt): r("<", 111);
			case IaBinOp(OpAnd): r("&", 112);
			case IaBinOp(OpOr): r("|", 113);
			case IaBinOp(OpXor): r("^", 114);
			case IaBinOp(OpBoolAnd): r("&&", 115);
			case IaBinOp(OpBoolOr): r("||", 116);
			case IaBinOp(OpShr): r(">>", 117);
			case IaBinOp(OpUShr): r(">>>", 118);
			case IaBinOp(OpShl): r("<<", 119);
			case IaBinOp(OpMod): r("%", 120);
			case IaBinOp(OpInterval): r("...", 121);
			case IaBinOp(OpArrow): r("=>", 122);
			case IaBinOp(OpIn): r(" in ", 123);
			case IaBinOp(OpNullCoal): r("??", 124);
			case IaBinOp(OpAssignOp(OpAdd)): r("+=", 201);
			case IaBinOp(OpAssignOp(OpMult)): r("*=", 202);
			case IaBinOp(OpAssignOp(OpDiv)): r("/=", 203);
			case IaBinOp(OpAssignOp(OpSub)): r("-=", 204);
			case IaBinOp(OpAssignOp(OpAnd)): r("&=", 212);
			case IaBinOp(OpAssignOp(OpOr)): r("|=", 213);
			case IaBinOp(OpAssignOp(OpXor)): r("^=", 214);
			case IaBinOp(OpAssignOp(OpBoolAnd)): r("&&=", 215);
			case IaBinOp(OpAssignOp(OpBoolOr)): r("||=", 216);
			case IaBinOp(OpAssignOp(OpShr)): r(">>=", 217);
			case IaBinOp(OpAssignOp(OpUShr)): r(">>>=", 218);
			case IaBinOp(OpAssignOp(OpShl)): r("<<=", 219);
			case IaBinOp(OpAssignOp(OpMod)): r("%=", 220);
			case IaBinOp(OpAssignOp(OpIn)) | IaBinOp(OpAssignOp(OpNullCoal)) | IaBinOp(OpAssignOp(OpInterval)) | IaBinOp(OpAssignOp(OpAssign)) |
				IaBinOp(OpAssignOp(OpEq)) | IaBinOp(OpAssignOp(OpNotEq)) | IaBinOp(OpAssignOp(OpGte)) | IaBinOp(OpAssignOp(OpLte)) |
				IaBinOp(OpAssignOp(OpGt)) | IaBinOp(OpAssignOp(OpLt)) | IaBinOp(OpAssignOp(OpAssignOp(_))) | IaBinOp(OpAssignOp(OpArrow)):
				die("", "cppCppia.ml");
			case IaTCast: r("TCAST", 221);
		}
	}

	public static function isMatchingInterfaceType(t0:T, t1:T):Bool {
		return switch [follow(t0), follow(t1)] {
			case [TInst(k0, _), TInst(k1, _)]: k0 == k1;
			case _: false;
		}
	}

	public static function isNull(expr:TExpr):Bool {
		return switch expr.eexpr {
			case TConst(TNull): true;
			case TParenthesis(expr) | TMeta(_, expr): isNull(expr);
			case TCast(e, null): isNull(e);
			case _: false;
		}
	}

	public static function isVirtualArray(expr:TExpr):Bool return typeString(expr.etype) == "cpp::VirtualArray";

	public static function removeParens(expression:TExpr):TExpr {
		return switch expression.eexpr {
			case TParenthesis(e): removeParens(e);
			case TMeta(_, e): removeParens(e);
			case _: expression;
		}
	}

	public static function removeParensCast(expression:TExpr):TExpr {
		return switch expression.eexpr {
			case TParenthesis(e): removeParensCast(e);
			case TMeta(_, e): removeParensCast(e);
			case TCast(e, null): removeParensCast(e);
			case _: expression;
		}
	}

	public static function isThis(expression:TExpr):Bool return removeParens(expression).eexpr.match(TConst(TThis));

	public static function isSuper(expression:TExpr):Bool return removeParens(expression).eexpr.match(TConst(TSuper));

	public static function isNativePointer(expr:TExpr):Bool {
		var t = typeString(expr.etype);
		var l = t.length;
		return l > 1 && t.substr(l - 1, 1) == "*";
	}

	public static function isExternClassInstance(obj:TExpr):Bool {
		return switch follow(obj.etype) {
			case TInst(klass, params): hasClassFlag(klass, CExtern);
			case _: false;
		}
	}

	public static function isDynamicInCpp(ctx:Context, expr:TExpr):Bool {
		var exprType = typeString(switch follow(expr.etype) {
			case TFun(sig): sig.ret;
			case _: expr.etype;
		});
		return if (exprType == "Dynamic" || exprType == "cpp::ArrayBase") true else {
			var result = switch expr.eexpr {
				case TEnumParameter(obj, _, index): true; /* TODO? */
				case TField(obj, field):
					isDynamicMemberLookupInCpp(ctx, obj, field) || isDynamicMemberReturnInCpp(ctx, obj, field);
				case TArray(obj, index): isDynamicInCpp(ctx, obj) || isVirtualArray(obj);
				case TTypeExpr(_): false;
				case TCall(func, args):
					var isIaCall = switch removeParensCast(func).eexpr {
						case TField({eexpr: TIdent("__global__")}, field): false;
						case TField(obj, FStatic(classDef, field)) if (isRealFunction(field)):
							false;
						case TField(obj, FInstance(_, _, field)) if (isThis(obj) && isRealFunction(field)):
							false;
						case TField(obj, FInstance(_, _, field)) if (isSuper(obj)): false;
						case TField(obj, FInstance(_, _, field)) if (field.cfName == "_hx_getIndex"):
							false;
						case TField(obj, FInstance(_, _, field)) if (field.cfName == "__Index" || (!isDynamicInCppia(ctx, obj)) && isRealFunction(field)):
							false;
						case TField(obj, FDynamic(name)) if (isInternalMember(name) || (typeString(obj.etype) == "::String" && name == "cca")):
							false;
						case TConst(TSuper): false;
						case TField(_, FEnum(enumDef, field)): false;
						case _: true;
					}
					if (isIaCall) true else switch follow(func.etype) {
						case TFun(_): isDynamicInCpp(ctx, func);
						case _: true;
					}
				case TParenthesis(expr) | TMeta(_, expr): isDynamicInCpp(ctx, expr);
				case TCast(e, null): typeString(expr.etype) == "Dynamic";
				case TIdent("__global__"): false;
				case TConst(TNull): true;
				case _: false; /* others ? */
			}
			result;
		}
	}

	public static function isDynamicMemberLookupInCpp(ctx:Context, fieldObject:TExpr, field:TFieldAccess):Bool {
		var member = fieldName(field);
		return if (isInternalMember(member)) false else if (isNativePointer(fieldObject)) false else if (isPointer(fieldObject.etype, true)) false else
			if (fieldObject.eexpr.match(TTypeExpr(_))) false else if (isDynamicInCpp(ctx, fieldObject)) true else if (isArray(fieldObject.etype)) false else {
				var tstr = typeString(fieldObject.etype);
				switch tstr {
					/* Internal classes have no dynamic members */
					case "::String" | "Null" | "::hx::Class" | "::Enum" | "::Math" | "::ArrayAccess":
						false;
					case "Dynamic": true;
					case name:
						var fullName = name + "." + member;
						if (ctx.ctxClassMemberTypes.exists(fullName)) false else !isExternClassInstance(fieldObject);
				}
			}
	}

	public static function isDynamicMemberReturnInCpp(ctx:Context, fieldObject:TExpr, field:TFieldAccess):Bool {
		var member = fieldName(field);
		return if (isArray(fieldObject.etype)) false else if (isPointer(fieldObject.etype, true)) false else if (isInternalMember(member)) false else
			switch fieldObject.eexpr {
				case TTypeExpr(t):
					var fullName = "::" + joinClassPathRemap(tPath(t), "::") + "." + member;
					switch ctx.ctxClassMemberTypes.get(fullName) {
						case null: true;
						case memType: memType == "Dynamic" || memType == "cpp::ArrayBase" || memType == "cpp::VirtualArray";
					}
				case _:
					var tstr = typeString(fieldObject.etype);
					switch tstr {
						/* Internal classes have no dynamic members */
						case "::String" | "Null" | "::hx::Class" | "::Enum" | "::Math" | "::ArrayAccess":
							false;
						case "Dynamic" | "cpp::ArrayBase" | "cpp::VirtualArray": true;
						case name:
							var fullName = name + "." + member;
							switch ctx.ctxClassMemberTypes.get(fullName) {
								case null: true;
								case memType: memType == "Dynamic" || memType == "cpp::ArrayBase" || memType == "cpp::VirtualArray";
							}
					}
			}
	}

	public static function isDynamicInCppia(ctx:Context, expr:TExpr):Bool {
		return switch expr.eexpr {
			case TCast(_, null): true;
			case _: isDynamicInCpp(ctx, expr);
		}
	}

	public static function generateScriptClass(commonCtx:Gctx, script:ScriptWriter, classDef:TClass):Void {
		script.incClasses();
		var classText = joinClassPath(classDef.clPath, ".");
		script.comment("Class " + classText);
		script.writeOp(if (hasClassFlag(classDef, CInterface)) IaInterface else IaClass);
		script.instName(classDef);
		switch classDef.clSuper {
			case null: script.ident("");
			case {cls: c}: script.instName(c);
		}
		script.wint(classDef.clImplements.length);
		for (i in classDef.clImplements) script.instName(i.cls);
		script.write("\n");
		/* Looks like some map impl classes have their bodies discarded - not sure best way to filter */
		function nonDodgyFunction(allowEmpty:Bool, field:TClassField):Bool {
			return hasClassFlag(classDef, CInterface) || switch [field.cfKind, field.cfExpr] {
				case [Var(_), _]: true;
				case [Method(MethDynamic), _]: true;
				case [Method(MethNormal), null] if (allowEmpty): true;
				case [Method(_), e] if (e != null): true;
				case _: false;
			}
		}
		var orderedStatics = classDef.clOrderedStatics.filter(function(f) return nonDodgyFunction(false, f));
		var orderedFields = classDef.clOrderedFields.filter(function(f) return nonDodgyFunction(true, f));
		script.write(Std.string(orderedFields.length + orderedStatics.length + (if (classDef.clConstructor != null) 1 else 0)
			+ (if (core.TOther.TClassTools.getClInit(classDef) != null) 1 else 0))
			+ "\n");

		function generateField(isStatic:Bool, field:TClassField):Void {
			switch [field.cfKind, follow(field.cfType)] {
				case [Var({vRead: AccInline, vWrite: AccNever}), _]:
					script.writeOpLine(IaInline);
				case [Var(v), _]:
					function modeCode(mode:VarAccess):CppiaOp {
						return switch mode {
							case AccNormal | AccCtor: IaAccessNormal;
							case AccNo: IaAccessNot;
							case AccNever: IaAccessNot;
							case AccCall | AccPrivateCall:
								if (Meta.has(Meta.NativeProperty, classDef.clMeta)
									|| Meta.has(Meta.NativeProperty, field.cfMeta)
									|| Gctx.defined(commonCtx, Define.ForceNativeProperty)) IaAccessCallNative else IaAccessCall;
							case AccInline: IaAccessNormal;
							case AccRequire(_, _): IaAccessNormal;
						}
					}
					var isExtern = !isPhysicalField(field);
					script.varField(modeCode(v.vRead), modeCode(v.vWrite), isExtern, isStatic, field.cfName, field.cfType, field.cfExpr);
				case [Method(MethDynamic), TFun(sig)]:
					script.func(isStatic, true, field.cfName, sig.ret, sig.args, hasClassFlag(classDef, CInterface), field.cfExpr, field.cfPos);
				case [Method(_), TFun(sig)] if (field.cfName == "new"):
					script.func(true, false, "new", TInst(classDef, vector()), sig.args, false, field.cfExpr, field.cfPos);
				case [Method(_), TFun(sig)]:
					script.func(isStatic, false, field.cfName, sig.ret, sig.args, hasClassFlag(classDef, CInterface), field.cfExpr, field.cfPos);
				case [Method(_), _]:
					printEndline("Unknown method type " + joinClassPath(classDef.clPath, ".") + "." + field.cfName);
			}
		}
		switch classDef.clConstructor {
			case null:
			case field: generateField(true, field);
		}
		switch core.TOther.TClassTools.getClInit(classDef) {
			case null:
			case expression: script.voidFunc(true, false, "__init__", expression);
		}

		for (f in orderedFields) generateField(false, f);
		for (f in orderedStatics) generateField(true, f);
		script.write("\n");
	}

	public static function generateScriptEnum(script:ScriptWriter, enumDef:TEnum, meta:Null<TExpr>):Void {
		script.incClasses();
		var sortedItems = listSort(function(f1:TEnumField, f2:TEnumField) return f1.efIndex - f2.efIndex, CppContext.pmapValues(enumDef.eConstrs));
		script.writeList(script.op(IaEnum) + script.enumText(enumDef), sortedItems.length);

		for (constructor in sortedItems) {
			var name = script.stringText(constructor.efName);
			switch constructor.efType {
				case TFun(sig):
					script.write(name + " " + Std.string(sig.args.length));
					for (a in sig.args) {
						// port: OCaml evaluates the operands of `^` right to left.
						var t = script.typeText(a.type);
						script.write(" " + script.stringText(a.name) + " " + t);
					}
					script.write("\n");
				case _: script.write(name + " 0\n");
			}
		}

		switch meta {
			case null:
				script.write("0\n");
				script.write("\n");
			case expr:
				script.write("1\n");
				script.genExpression(expr);
		}
	}

	public static function generateCppia(ctx:Context):Void {
		var commonCtx = ctx.ctxCommon;
		var debug = ctx.ctxDebugLevel;
		core.Path.mkdirFromPath(commonCtx.file);
		var script = new ScriptWriter(ctx, commonCtx.file, commonCtx.debug, commonCtx.basic);
		script.stringId("");
		script.typeId("");

		for (objectDef in commonCtx.types) switch objectDef {
			case TClassDecl(classDef) if (hasClassFlag(classDef, CExtern)):
				/*if (gen_externs) then gen_extern_class common_ctx class_def;*/
			case TClassDecl(classDef):
				var isInternal = isInternalClass(classDef.clPath);
				if (isInternal) {
					if (debug >= 4) printEndline(" internal class " + joinClassPath(classDef.clPath, "."));
				} else generateScriptClass(commonCtx, script, classDef);
			case TEnumDecl(enumDef) if (hasEnumFlag(enumDef, EnExtern)):
			case TEnumDecl(enumDef):
				var isInternal = isInternalClass(enumDef.ePath);
				if (isInternal) {
					if (debug >= 4) printEndline(" internal enum " + joinClassPath(enumDef.ePath, "."));
				} else {
					var meta = core.Texpr.buildMetadata(commonCtx.basic, objectDef);
					if (hasEnumFlag(enumDef, EnExtern)) if (debug >= 4) printEndline("external enum " + joinClassPath(enumDef.ePath, "."));
					generateScriptEnum(script, enumDef, meta);
				}
			case TTypeDecl(_) | TAbstractDecl(_): /* already done */
		}

		switch commonCtx.main.mainExpr {
			case null: script.writeOpLine(IaNoMain);
			case e:
				script.writeOpLine(IaMain);
				script.genExpression(e);
		}

		var resources = CppContext.resourcesInHashtblOrder(commonCtx);
		script.write(script.op(IaResources) + Std.string(resources.length) + "\n");
		for (r in resources) script.write(script.op(IaReso) + script.stringText(r.name) + Std.string(r.data.length) + "\n");
		for (r in resources) script.writeData(r.data);

		script.close();
	}
}

// port: OCaml evaluates the operands of `^` right to left, and the string and type tables
// number their entries in first-use order, so where one concatenation registers two
// entries the right one is computed first (`({ var st = stringText(...); ... })`).
class ScriptWriter {
	final ctx:Context;
	final filename:String;
	final asciiOut:Bool;
	final debug:Bool;
	final basic:BasicTypes;
	final doComment:Bool;
	final indentStr:String;
	var indent = "";
	var indents:Array<String> = [];
	var justFinishedBlock = false;
	var classCount = 0;
	var returnType:T = mkMono();
	final buffer = new haxe.io.BytesBuffer();
	final identTable = new haxe.ds.StringMap<Int>();
	var identCount = 0;
	final fileTable = new haxe.ds.StringMap<Int>();
	final identBuffer = new StringBuf();
	final cppiaAst:Bool;
	final typeTable = new haxe.ds.StringMap<Int>();
	var typeCount = 0;
	final typeBuffer = new StringBuf();

	public function new(ctx:Context, filename:String, asciiOut:Bool, basic:BasicTypes) {
		this.ctx = ctx;
		this.filename = filename;
		this.asciiOut = asciiOut;
		this.basic = basic;
		debug = asciiOut;
		doComment = asciiOut && Gctx.defined(ctx.ctxCommon, Define.AnnotateSource);
		indentStr = if (asciiOut) "\t" else "";
		cppiaAst = !Gctx.defined(ctx.ctxCommon, Define.NoCppiaAst);
	}

	public function stringId(name:String):Int {
		return switch identTable.get(name) {
			case null:
				var size = identCount;
				identTable.set(name, size);
				identCount++;
				identBuffer.add(Std.string(byteLength(name)) + " " + name + "\n");
				size;
			case id: id;
		}
	}

	public function incClasses():Void classCount = classCount + 1;

	public function stringText(name:String):String return Std.string(stringId(name)) + " ";

	public function typeId(name:String):Int {
		var name = if (name == "::hx::Class") "::Class" else name;
		return switch typeTable.get(name) {
			case null:
				var size = typeCount;
				typeTable.set(name, size);
				typeCount++;
				typeBuffer.add(Std.string(byteLength(name)) + " " + name + "\n");
				size;
			case id: id;
		}
	}

	public function write(str:String):Void {
		if (asciiOut) buffer.addString(str) else {
			function push(i:Int) buffer.addByte(i & 255);
			function pushI32(i:Int) push(i & 255);
			// port: Str.split (Str.regexp "[\n\t ]+") drops the empty leading and trailing fields.
			var tokens = ~/[\n\t ]+/g.split(str).filter(function(t) return t != "");
			for (tok in tokens) {
				var i = core.ds.OcamlInt32.ofString(tok);
				if (i >= 0 && i < 254) pushI32(i) else if (i >= 0 && i < 65536) {
					push(254);
					pushI32(i);
					pushI32(i >> 8);
				} else {
					push(255);
					pushI32(i);
					pushI32(i >> 8);
					pushI32(i >> 16);
					pushI32(i >> 24);
				}
			}
		}
		justFinishedBlock = false;
	}

	public function comment(text:String):Void if (doComment) write("# " + text + "\n");

	public function commentOf(text:String):String return if (doComment) " # " + text else "";

	public function typeTextString(typeName:String):String return Std.string(typeId(typeName)) + " ";

	public function typeText(typeT:T):String {
		var tname = if (cppiaAst) CppCppia.scriptCpptypeString(CppCppia.cppTypeOf(basic, typeT)) else CppCppia.scriptTypeString(typeT);
		return Std.string(typeId(tname)) + " ";
	}

	public function astType(cppType:Tcpp):String return Std.string(typeId(CppCppia.scriptCpptypeString(cppType))) + " ";

	public function writeType(typeT:T):Void write(typeText(typeT));

	public function toCppType(etype:T):String return Std.string(typeId(CppCppia.scriptCpptypeString(CppCppia.cppTypeOf(basic, etype)))) + " ";

	public function boolText(value:Bool):String return if (value) "1" else "0";

	public function writeBool(value:Bool):Void write(if (value) "1 " else "0 ");

	public function staticText(value:Bool):String return if (value) "1" else "0";

	public function writeData(data:haxe.io.Bytes):Void buffer.add(data);

	public function wint(ival:Int):Void write(Std.string(ival) + " ");

	public function ident(name:String):Void wint(stringId(name));

	public function cppInstText(clazz:TClass):String {
		return switch clazz.clPath {
			case {pack: [], name: "Array"}: typeTextString("Array");
			case x: typeTextString(joinClassPath(x, "."));
		}
	}

	public function instText(clazz:TClass):String {
		return switch clazz.clPath {
			case {pack: [], name: "Array"}: Std.string(typeId("Array< ::Dynamic >")) + " ";
			case _: typeText(TInst(clazz, vector()));
		}
	}

	public function instName(clazz:TClass):Void write(if (cppiaAst) cppInstText(clazz) else instText(clazz));

	public function enumText(e:TEnum):String return typeText(TEnum(e, vector()));

	public function close():Void {
		var out = new haxe.io.BytesBuffer();
		out.addString(if (asciiOut) "CPPIA\n" else "CPPIB\n");
		var idents = identBuffer.toString();
		out.addString(Std.string(identCount) + "\n");
		out.addString(idents);
		var types = typeBuffer.toString();
		out.addString(Std.string(typeCount) + "\n");
		out.addString(types);
		out.addString(Std.string(classCount) + "\n");
		out.add(buffer.getBytes());
		sys.io.File.saveBytes(filename, out.getBytes());
	}

	public function fileId(file:String):Int {
		return switch fileTable.get(file) {
			case null:
				var strippedFile = CppContext.stripFile(ctx.ctxCommon, file);
				var result = stringId(strippedFile);
				fileTable.set(file, result);
				result;
			case id: id;
		}
	}

	public function constText(c:TConstant):String {
		return switch c {
			case TInt(i): op(IaConstInt) + Std.string(i) + " ";
			case TFloat(f):
				op(IaConstFloat) + stringText(core.Texpr.replaceSeparators(f, ""));
			case TString(s): op(IaConstString) + stringText(s);
			case TBool(true): op(IaConstTrue);
			case TBool(false): op(IaConstFalse);
			case TNull: op(IaConstNull);
			case TThis: op(IaConsThis);
			case TSuper: op(IaConstSuper);
		}
	}

	public function getArrayType(t:T):ArrayOf {
		return switch follow(t) {
			case TInst({clPath: {pack: [], name: "Array"}}, [param]):
				var typeName = typeStringSuff("", param, false);
				switch typeName {
					case "::String": ArrayData("String");
					case "int" | "Float" | "bool" | "String" | "unsigned char" | "::cpp::UInt8":
						ArrayData(typeName);
					case "cpp::ArrayBase" | "cpp::VirtualArray" | "Dynamic": ArrayAny;
					case _ if (isInterfaceType(param)):
						ArrayInterface(typeId(CppCppia.scriptTypeString(param)));
					case _: ArrayOf.ArrayObject;
				}
			case TAbstract(abs, pl) if (abs.aImpl != null):
				getArrayType(core.Abstract.getUnderlyingType(abs, pl));
			case _: ArrayNone;
		}
	}

	public function pushReturn(inType:T):Void->Void {
		var oldReturnType = returnType;
		returnType = inType;
		return function() returnType = oldReturnType;
	}

	public function fileText(file:String):String return Std.string(fileId(file));

	public function indentOne():Void write(indentStr);

	public function pushIndent():Void {
		indents = [indentStr].concat(indents);
		indent = indents.join("");
	}

	public function popIndent():Void {
		if (indents.length > 0) {
			indents = indents.slice(1);
			indent = indents.join("");
		} else indent = "/*?*/";
	}

	public function writeI(x:String):Void write(indent + x);

	public function getIndent():String return indent;

	public function beginExpr():Void pushIndent();

	public function endExpr():Void {
		if (!justFinishedBlock) write("\n");
		popIndent();
		justFinishedBlock = true;
	}

	public function op(x:CppiaOp):String {
		var info = CppCppia.cppiaOpInfo(x);
		return (if (debug) info.name else Std.string(info.index)) + " ";
	}

	public function writeOp(o:CppiaOp):Void write(op(o));

	public function writeOpLine(o:CppiaOp):Void write(op(o) + "\n");

	public function voidFunc(isStatic:Bool, isDynamic:Bool, funcName:String, fieldExpression:TExpr):Void {
		comment(funcName);
		write(op(IaFunction) + staticText(isStatic) + " " + boolText(isDynamic) + " " + stringText(funcName) + " ");
		write(typeTextString("Void") + "0\n");
		genExpression(fieldExpression);
	}

	public function func(isStatic:Bool, isDynamic:Bool, funcName:String, ret:T, args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>, isInterface:Bool,
			fieldExpression:Null<TExpr>, abstractPos:Pos):Void {
		comment(funcName);
		write(op(IaFunction) + staticText(isStatic) + " " + boolText(isDynamic) + " " + stringText(funcName) + " ");
		write(typeText(ret) + Std.string(args.length) + " ");
		for (a in args) {
			// port: OCaml evaluates the operands of `^` right to left.
			var t = typeText(a.type);
			write(stringText(a.name) + boolText(a.optional) + " " + t + " ");
		}
		write("\n");
		if (!isInterface) switch fieldExpression {
			case e = {eexpr: TFunction(functionDef)} if (e != null):
				if (cppiaAst) {
					var args = functionDef.tfArgs.mapToArray(function(a) return retypeDefaultArg(a.variable, a.defaultValue));
					var cppExpr = CppRetyper.expression(ctx, TCppVoid, args, CppCppia.cppTypeOf(basic, functionDef.tfType), functionDef.tfExpr, false);
					beginExpr();
					writePos(functionDef.tfExpr);
					write(op(IaFun) + typeText(functionDef.tfType) + Std.string(args.length) + "\n");
					var close = genFuncArgs(args);
					genExpressionTree(cppExpr);
					endExpr();
					close();
				} else genExpression(e);
			case _:
				/* Abstract function - dummp implementation that (should) not get called */
				beginExpr();
				wpos(abstractPos);
				writeOpLine(IaReturn);
				endExpr();
		}
	}

	public function varField(readAcc:CppiaOp, writeAcc:CppiaOp, isExtern:Bool, isStatic:Bool, name:String, varType:T, varExpr:Null<TExpr>):Void {
		// port: OCaml evaluates the operands of `^` right to left.
		var t = typeText(varType);
		write(op(IaVar) + staticText(isStatic) + " " + op(readAcc) + op(writeAcc) + boolText(isExtern) + " " + stringText(name) + t
			+ (if (varExpr != null) "1" else "0") + if (doComment) " # " + name + "\n" else "\n");
		switch varExpr {
			case null:
			case expression:
				if (cppiaAst) {
					var varType = CppCppia.cppTypeOf(basic, expression.etype);
					var cppExpr = CppRetyper.expression(ctx, varType, [], TCppDynamic, expression, false);
					genExpressionTree(cppExpr);
				} else genExpression(expression);
		}
	}

	public function implDynamic():Void writeOpLine(IaImplDynamic);

	public function writeVar(v:TVar):Void {
		ident(v.vName);
		wint(v.vId);
		writeBool(hasVarFlag(v, VCaptured));
		writeType(v.vType);
	}

	public function writeList(prefix:String, len:Int):Void write(prefix + " " + Std.string(len) + "\n");

	public function wpos(p:Pos):Void {
		if (debug) write(fileText(core.Path.getFullPath(p.pfile)) + "\t" + Std.string(syntax.Lexer.getErrorLine(p)) + indent);
	}

	public function writePos(expr:TExpr):Void wpos(expr.epos);

	public function writeCppPos(expr:TcppExpr):Void wpos(expr.cpppos);

	public function checkCast(toType:T, expr:TExpr, forceCast:Bool, fromGenExpression:Bool):Void {
		function writeCast(text:String):Bool {
			if (!fromGenExpression) writePos(expr);
			write(text + "\n");
			beginExpr();
			genExpression(expr);
			endExpr();
			return true;
		}
		var wasCast = if (isInterfaceType(toType)) {
			// port: OCaml evaluates the operands of `^` right to left.
			if (CppCppia.isDynamicInCppia(ctx, expr)) {
				var d = typeTextString("Dynamic");
				writeCast(op(IaToInterface) + typeText(toType) + " " + d);
			} else if (!CppCppia.isMatchingInterfaceType(toType, expr.etype)) {
				var e = typeText(expr.etype);
				writeCast(op(IaToInterface) + typeText(toType) + " " + e);
			} else false;
		} else {
			function getArrayExprType(expr:TExpr):ArrayOf return if (CppCppia.isDynamicInCppia(ctx, expr)) ArrayNone else getArrayType(expr.etype);
			switch [getArrayType(toType), getArrayExprType(expr)] {
				case [ArrayAny, _]: false;
				case [ArrayOf.ArrayObject, ArrayData(_)]: writeCast(op(IaToDynArray));
				case [ArrayOf.ArrayObject, ArrayOf.ArrayObject]: false;
				case [ArrayOf.ArrayObject, ArrayNone] | [ArrayOf.ArrayObject, ArrayAny]:
					writeCast(op(IaToDataArray) + typeTextString("Array.Object"));
				case [ArrayData(t), ArrayNone] | [ArrayData(t), ArrayOf.ArrayObject] | [ArrayData(t), ArrayAny]:
					writeCast(op(IaToDataArray) + typeTextString("Array." + t));
				case [ArrayInterface(t), ArrayNone] | [ArrayInterface(t), ArrayAny]:
					writeCast(op(IaToInterfaceArray) + Std.string(t));
				case [_, _]:
					/* a0,a1 ->
						let arrayString a =
						match a with
						| ArrayNone -> "ArrayNone"
						| ArrayAny -> "ArrayAny"
						| ArrayObject -> "ArrayObject"
						| ArrayData _ -> "ArrayData"
						| ArrayInterface _ -> "ArrayInterface"
						in
						this#write ("NOCAST " ^ (arrayString a0) ^ "=" ^ (arrayString a1)); */
					false;
			}
		}

		if (!wasCast) {
			if (forceCast) {
				var o = switch typeString(expr.etype) {
					case "int": IaCastInt;
					case "bool": IaCastBool;
					case _ if (isInterfaceType(toType)): IaNoCast;
					case _: IaCast;
				}
				writeOpLine(o);
			}
			genExpression(expr);
		}
	}

	function retypeDefaultArg(v:TVar, e:Null<TExpr>):TcppArg {
		var v = switch e {
			case null: v;
			case {eexpr: TConst(_)}: v;
			case _ if (isCppScalar(CppCppia.cppTypeOf(basic, v.vType))):
				var c = v.clone();
				c.vType = basic.tnull(v.vType);
				c;
			case _: v;
		}
		return {v: CppRetyper.retypeTvar(basic, v), o: e};
	}

	public function genFuncArgs(args:Array<TcppArg>):Void->Void {
		var genInits:Array<{arg:TcppVar, e:TExpr}> = [];
		for (a in args) {
			var arg = a.v, init = a.o;
			write(indent + indentStr);
			writeVar(arg.tcppvVar);
			switch init {
				case null: write("0\n");
				case {eexpr: TConst(TNull)}: write("0\n");
				case const = {eexpr: TConst(_)}:
					var argType = CppCppia.cppTypeOf(basic, const.etype);
					if (isCppScalar(argType) || argType.match(TCppString)) {
						write("1 ");
						genExpressionOnly(const);
						write("\n");
					} else {
						genInits = [{arg: arg, e: const}].concat(genInits);
						write("0\n");
					}
				case init:
					genInits = [{arg: arg, e: init}].concat(genInits);
					write("0\n");
			}
		}

		genInits.reverse();
		return if (genInits.length == 0) function() {} else {
			beginExpr();
			writePos(genInits[0].e);
			writeList(op(IaBlock), genInits.length + 1);
			for (gi in genInits) {
				var arg = gi.arg, const = gi.e;
				function startExpr():Void {
					beginExpr();
					writePos(const);
				}
				function localVar():Void {
					beginExpr();
					writePos(const);
					write(op(IaVar) + Std.string(arg.tcppvVar.vId) + commentOf(arg.tcppvVar.vName));
					endExpr();
				}

				startExpr();
				writeOpLine(IaIf);
				startExpr();
				writeOpLine(IaIsNull);
				localVar();
				endExpr();
				startExpr();
				writeOpLine(IaSet);
				localVar();
				genExpression(const);
				endExpr();
				beginExpr();
			}
			function() endExpr();
		}
	}

	public function genExpression(expr:TExpr):Void {
		beginExpr();
		writePos(expr);
		genExpressionOnly(expr);
		endExpr();
	}

	public function genExpressionOnly(expr:TExpr):Void {
		/* { */
		var expression = CppCppia.removeParens(expr);
		switch expression.eexpr {
			case TFunction(functionDef):
				write(op(IaFun) + typeText(functionDef.tfType) + Std.string(functionDef.tfArgs.length) + "\n");
				var close = genFuncArgs(functionDef.tfArgs.mapToArray(function(a) return retypeDefaultArg(a.variable, a.defaultValue)));
				var pop = pushReturn(functionDef.tfType);
				genExpression(functionDef.tfExpr);
				pop();
				close();
			case TBlock(exprList):
				writeList(op(IaBlock), exprList.length);
				for (e in exprList) genExpression(e);
			case TConst(const): write(constText(const));
			case TBreak: writeOp(IaBreak);
			case TContinue: writeOp(IaContinue);
			case TBinop(OpAssign, e1, e2):
				writeOpLine(IaSet);
				genExpression(e1);
				checkCast(e1.etype, e2, false, false);
			case TBinop(OpEq, e1, {eexpr: TConst(TNull)}):
				writeOpLine(IaIsNull);
				genExpression(e1);
			case TBinop(OpNotEq, e1, {eexpr: TConst(TNull)}):
				writeOpLine(IaNotNull);
				genExpression(e1);
			case TBinop(OpEq, {eexpr: TConst(TNull)}, e1):
				writeOpLine(IaIsNull);
				genExpression(e1);
			case TBinop(OpNotEq, {eexpr: TConst(TNull)}, e1):
				writeOpLine(IaNotNull);
				genExpression(e1);
			case TBinop(op, e1, e2):
				writeOpLine(IaBinOp(op));
				genExpression(e1);
				genExpression(e2);
			case TThrow(e):
				writeOpLine(IaThrow);
				genExpression(e);
			case TArrayDecl(exprList):
				write(op(IaADef) + typeText(expression.etype) + " " + Std.string(exprList.length) + "\n");
				for (e in exprList) genExpression(e);
			case TIf(e, e1, e2):
				switch e2 {
					case null:
						writeOpLine(IaIf);
						genExpression(e);
						genExpression(e1);
					case elze:
						writeOpLine(IaIfElse);
						genExpression(e);
						genExpression(e1);
						genExpression(elze);
				}
			case TCall(func, argList):
				var argN = Std.string(argList.length) + " ";
				function genCall():Void {
					switch CppCppia.removeParensCast(func).eexpr {
						case TField({eexpr: TIdent("__global__")}, field):
							write(op(IaCallGlobal) + stringText(fieldName(field)) + argN + commentOf(fieldName(field)) + "\n");
						case TField(obj, FStatic(classDef, field)) if (isRealFunction(field)):
							write(({ var st = stringText(field.cfName); op(IaCallStatic) + instText(classDef) + " " + st; }) + argN
								+ commentOf(joinClassPath(classDef.clPath, ".") + "." + field.cfName) + "\n");
						case TField(obj, FInstance(_, _, field)) if (CppCppia.isThis(obj) && isRealFunction(field)):
							write(({ var st = stringText(field.cfName); op(IaCallThis) + typeText(obj.etype) + " " + st; }) + argN + commentOf(field.cfName) + "\n");
						case TField(obj, FInstance(_, _, field)) if (CppCppia.isSuper(obj)):
							write(({ var st = stringText(field.cfName); op(IaCallSuper) + typeText(obj.etype) + " " + st; }) + argN + commentOf(field.cfName) + "\n");
						/* Cppia does not have a "GetEnumIndex" op code - must use IaCallMember ::hx::EnumBase.__Index */
						case TField(obj, FInstance(_, _, field)) if (field.cfName == "_hx_getIndex" && CppCppia.scriptTypeString(obj.etype) == "::hx::EnumBase"):
							write(({ var st = stringText("__Index"); op(IaCallMember) + typeTextString("::hx::EnumBase") + " " + st; }) + argN + commentOf("Enum index") + "\n");
							genExpression(obj);
						case TField(obj, FInstance(_, _, field)) if (field.cfName == "__Index"
							|| (!CppCppia.isDynamicInCppia(ctx, obj)) && isRealFunction(field)):
							write(({ var st = stringText(field.cfName); op(IaCallMember) + typeText(obj.etype) + " " + st; }) + argN + commentOf(field.cfName) + "\n");
							genExpression(obj);
						case TField(obj, FDynamic(name)) if (isInternalMember(name) || (typeString(obj.etype) == "::String" && name == "cca")):
							write(({ var st = stringText(name); op(IaCallMember) + typeText(obj.etype) + " " + st; }) + argN + commentOf(name) + "\n");
							genExpression(obj);
						case TConst(TSuper):
							write(op(IaCallSuperNew) + typeText(func.etype) + " " + argN + "\n");
						case TField(_, FEnum(enumDef, field)):
							write(({ var st = stringText(field.efName); op(IaCreateEnum) + enumText(enumDef) + " " + st; }) + argN + commentOf(field.efName) + "\n");
						case _:
							write(op(IaCall) + argN + "\n");
							genExpression(func);
					}
					var matchedArgs = switch func.etype {
						case TFun(sig):
							// port: List.iter2 raises Invalid_argument (after the common prefix) on lists of different lengths.
							var n = sig.args.length < argList.length ? sig.args.length : argList.length;
							for (i in 0...n) checkCast(sig.args[i].type, argList[i], false, false);
							sig.args.length == argList.length;
						case _: false;
					}
					if (!matchedArgs) for (e in argList) genExpression(e);
				}
				switch CppCppia.removeParensCast(func).eexpr {
					case TField(obj, field) if (isArrayOrDynArray(obj.etype) && fieldName(field) == "map"):
						switch getArrayType(expression.etype) {
							case ArrayData(t):
								write(op(IaToDataArray) + typeTextString("Array." + t) + "\n");
								beginExpr();
								writePos(func);
								genCall();
								endExpr();
							case ArrayInterface(t):
								write(op(IaToInterfaceArray) + Std.string(t) + "\n");
								beginExpr();
								writePos(func);
								genCall();
								endExpr();
							case _: genCall();
						}
					case _: genCall();
				}
			case TField(obj, acc):
				var objType = if (CppCppia.isDynamicInCppia(ctx, obj)) "Dynamic" else CppCppia.scriptTypeString(obj.etype);
				var typeText = if (CppCppia.isDynamicInCppia(ctx, obj)) typeTextString("Dynamic") else typeText(obj.etype);
				switch acc {
					case FDynamic(name):
						write(op(IaFName) + typeText + " " + stringText(name) + commentOf(name) + "\n");
						genExpression(obj);
					case FStatic(classDef, field):
						write(({ var st = stringText(field.cfName); op(IaFStatic) + instText(classDef) + " " + st; }) + commentOf(field.cfName));
					case FInstance(_, _, field) if (CppCppia.isThis(obj)):
						write(op(IaFThisInst) + typeText + " " + stringText(field.cfName) + commentOf(field.cfName));
					case FInstance(_, _, field):
						write(op(IaFLink) + typeText + " " + stringText(field.cfName) + commentOf(objType + "." + field.cfName) + "\n");
						genExpression(obj);
					case FClosure(_, field) if (CppCppia.isThis(obj)):
						write(op(IaFThisName) + typeText + " " + stringText(field.cfName) + "\n");
					case FAnon(field) if (CppCppia.isThis(obj)):
						write(op(IaFThisName) + typeText + " " + stringText(field.cfName) + commentOf(field.cfName) + "\n");
					case FClosure(_, field) | FAnon(field):
						write(op(IaFName) + typeText + " " + stringText(field.cfName) + commentOf(field.cfName) + "\n");
						genExpression(obj);
					case FEnum(enumDef, field):
						write(({ var st = stringText(field.efName); op(IaFEnum) + enumText(enumDef) + " " + st; }) + commentOf(field.efName));
				}
			case TArray(e1, e2):
				write(op(IaArrayI) + typeText(e1.etype) + "\n");
				genExpression(e1);
				genExpression(e2);
			case TUnop(o, flag, e):
				writeOpLine(switch [o, flag] {
					case [Increment, Prefix]: IaPlusPlus;
					case [Increment, _]: IaPlusPlusPost;
					case [Decrement, Prefix]: IaMinusMinus;
					case [Decrement, _]: IaMinusMinusPost;
					case [Not, _]: IaLogicNot;
					case [Neg, _]: IaNeg;
					case [Spread, _]: die("Unexpected spread operator", "cppCppia.ml", e.epos);
					case [NegBits, _]: IaBitNot;
				});
				genExpression(e);
			/* TODO - lval op-assign local/member/array */
			case TLocal(v):
				write(op(IaVar) + Std.string(v.vId) + commentOf(v.vName));
			case TVar(tvar, optionalInit):
				write(op(IaTVars) + Std.string(1) + commentOf(tvar.vName + ":" + CppCppia.scriptTypeString(tvar.vType)) + "\n");
				write("\t\t" + indent);
				switch optionalInit {
					case null:
						writeOp(IaVarDecl);
						writeVar(tvar);
					case init:
						writeOp(IaVarDeclI);
						var init = CppCppia.removeParens(init);
						writeVar(tvar);
						write(" " + typeText(init.etype));
						write("\n");
						checkCast(tvar.vType, init, false, false);
				}
			case TNew(clazz, params, argList):
				write(op(IaNew) + typeText(TInst(clazz, params)) + Std.string(argList.length) + "\n");
				var handled = switch typing.OverloadResolution.maybeResolveConstructorOverload(clazz, params, argList) {
					case {field: {cfType: TFun(sig)}} if (sig.args.length == argList.length):
						for (i in 0...sig.args.length) checkCast(sig.args[i].type, argList[i], false, false);
						true;
					case {field: {cfType: TFun(sig)}}:
						// port: List.iter2 raises Invalid_argument after the common prefix.
						var n = sig.args.length < argList.length ? sig.args.length : argList.length;
						for (i in 0...n) checkCast(sig.args[i].type, argList[i], false, false);
						false;
					case _: false;
				}
				if (!handled) for (e in argList) genExpression(e);
			case TReturn(optval):
				switch optval {
					case null: writeOpLine(IaReturn);
					case value:
						write(op(IaRetVal) + typeText(value.etype) + "\n");
						checkCast(returnType, value, false, false);
				}
			case TObjectDecl([
				{key: {name: "fileName"}, expr: {eexpr: TConst(TString(file))}},
				{key: {name: "lineNumber"}, expr: {eexpr: TConst(TInt(line))}},
				{key: {name: "className"}, expr: {eexpr: TConst(TString(className))}},
				{key: {name: "methodName"}, expr: {eexpr: TConst(TString(meth))}}
			]):
				{
					// port: OCaml evaluates the operands of `^` right to left.
					var m = stringText(meth);
					var c = stringText(className);
					write(op(IaPosInfo) + stringText(file) + Std.string(line) + " " + c + " " + m);
				}
			case TObjectDecl(values):
				write(op(IaObjDef) + Std.string(values.length));
				write(" ");
				for (v in values) write(stringText(v.key.name));
				write("\n");
				for (v in values) genExpression(v.expr);
			case TTypeExpr(typeExpr):
				var klass = "::" + joinClassPath(tPath(typeExpr), "::");
				write(op(IaClassOf) + Std.string(typeId(klass)));
			case TWhile(e1, e2, flag):
				write(op(IaWhile) + (if (flag == NormalWhile) "1" else "0") + "\n");
				genExpression(e1);
				genExpression(e2);
			case TEnumParameter(expr, ef, i):
				var enumDef = switch follow(ef.efType) {
					case TEnum(en, _) | TFun({ret: TEnum(en, _)}): en;
					case _: die("", "cppCppia.ml");
				}
				write(op(IaEnumI) + typeText(TEnum(enumDef, vector())) + Std.string(i) + "\n");
				genExpression(expr);
			case TEnumIndex(expr):
				write(({ var st = stringText("__Index"); op(IaCallMember) + typeTextString("::hx::EnumBase") + " " + st; }) + "0" + commentOf("Enum index") + "\n");
				genExpression(expr);
			case TSwitch({switchSubject: condition, switchCases: cases, switchDefault: optionalDefault}):
				write(op(IaSwitch) + Std.string(cases.length) + " " + (if (optionalDefault == null) "0" else "1") + "\n");
				genExpression(condition);
				for (c in cases) {
					writeList("\t\t\t" + indent, c.casePatterns.length);
					for (value in c.casePatterns) genExpression(value);
					genExpression(c.caseExpr);
				}
				switch optionalDefault {
					case null:
					case expr: genExpression(expr);
				}
			case TTry(e, catches):
				writeList(op(IaTry), catches.length);
				genExpression(e);
				for (c in catches) {
					write("\t\t\t" + indent);
					writeVar(c.variable);
					write("\n");
					genExpression(c.expr);
				}
			// port: the None case is tested first (null-safe enum patterns); it takes the `TCast (cast, _)` branch.
			case TCast(castExpr, null): checkCast(expression.etype, castExpr, true, true);
			case TCast(castExpr, TClassDecl(t)):
				write(op(IaTCast) + typeText(TInst(t, vector())) + "\n");
				genExpression(castExpr);
			case TCast(castExpr, _): checkCast(expression.etype, castExpr, true, true);
			case TParenthesis(_): core.Error.abort("Unexpected parens", expression.epos);
			case TMeta(_, _): core.Error.abort("Unexpected meta", expression.epos);
			case TIdent(_): core.Error.abort("Unexpected ident", expression.epos);
		}
	}

	/* } */
	public function genExpressionTree(expressionTree:TcppExpr):Void {
		/* { */
		genTreeExpression(expressionTree);
	}

	function genTreeExpression(expression:TcppExpr):Void {
		beginExpr();
		writeCppPos(expression);
		function matchExpr(expression:TcppExpr):Void {
			switch expression.cppexpr {
				case CppBlock(exprs, closures, _):
					writeList(op(IaBlock), exprs.length);
					for (e in exprs) genTreeExpression(e);
				case CppVarDecl(v, init):
					write(op(IaTVars) + Std.string(1) + commentOf(v.tcppvName + ":" + CppCppia.scriptTypeString(v.tcppvVar.vType)) + "\n");
					write("\t\t" + indent);
					switch init {
						case null:
							writeOp(IaVarDecl);
							writeVar(v.tcppvVar);
						case init:
							writeOp(IaVarDeclI);
							writeVar(v.tcppvVar);
							write(" " + astType(init.cpptype));
							write("\n");
							genTreeExpression(init);
					}
				case CppInt(i): write(op(IaConstInt) + Std.string(i) + " ");
				case CppFloat(floatAsString):
					write(op(IaConstFloat) + stringText(floatAsString));
				case CppString(s): write(op(IaConstString) + stringText(s));
				case CppBool(false): writeOp(IaConstFalse);
				case CppBool(true): writeOp(IaConstTrue);
				case CppNull: writeOp(IaConstNull);
				case CppNil: core.Error.abort("Nil not supported in cppia", expression.cpppos);
				case CppThis(_): writeOp(IaConsThis);
				case CppSuper(_): writeOp(IaConstSuper);
				case CppBreak: writeOp(IaBreak);
				case CppContinue: writeOp(IaContinue);
				case CppGoto(label):
					core.Error.abort("Goto not supported in cppia", expression.cpppos);
				case CppReturn(null): writeOpLine(IaReturn);
				case CppReturn(value):
					write(op(IaRetVal) + astType(value.cpptype) + "\n");
					genTreeExpression(value);
				case CppWhile(condition, block, whileFlag, _):
					write(op(IaWhile) + (if (whileFlag == NormalWhile) "1" else "0") + "\n");
					genTreeExpression(condition);
					genTreeExpression(block);
				case CppIf(condition, block, null):
					writeOpLine(IaIf);
					genTreeExpression(condition);
					genTreeExpression(block);
				case CppIf(condition, block, elze):
					writeOpLine(IaIfElse);
					genTreeExpression(condition);
					genTreeExpression(block);
					genTreeExpression(elze);
				case CppBinop(o, left, right):
					writeOpLine(IaBinOp(o));
					genTreeExpression(left);
					genTreeExpression(right);
				case CppVar(v): genVarLoc(v);
				case CppExtern(name, _):
					core.Error.abort("Unexpected global '" + name + "' in cppia", expression.cpppos);
				case CppSet(lvalue, rvalue):
					writeOpLine(IaSet);
					genLvalue(lvalue, expression.cpppos);
					genTreeExpression(rvalue);
				case CppCall(func, args):
					var argN = Std.string(args.length) + " ";
					switch func {
						case FuncThis(field, inst):
							var name = field.cfName;
							write(({ var st = stringText(name); op(IaCallThis) + astType(inst) + " " + st; }) + argN + commentOf(name) + "\n");
						case FuncInstance(expr, _, field, _) | FuncInterface(expr, _, field):
							write(({ var st = stringText(field.cfName); op(IaCallMember) + astType(expr.cpptype) + " " + st; }) + argN + commentOf(field.cfName) + "\n");
							genTreeExpression(expr);
						case FuncStatic(classDef, _, field, _):
							write(({ var st = stringText(field.cfName); op(IaCallStatic) + cppInstText(classDef) + " " + st; }) + argN
								+ commentOf(joinClassPath(classDef.clPath, ".") + "." + field.cfName) + "\n");
						case FuncTemplate(_):
							core.Error.abort("Templated function call not supported in cppia", expression.cpppos);
						case FuncFromStaticFunction:
							core.Error.abort("Unexpected FuncFromStaticFunction", expression.cpppos);
						case FuncEnumConstruct(enumDef, field):
							write(({ var st = stringText(field.efName); op(IaCreateEnum) + enumText(enumDef) + " " + st; }) + argN + commentOf(field.efName) + "\n");
						case FuncSuperConstruct(TCppInst(klass, _)) if (isNativeGenClass(klass) && isNativeClass(klass)):
							core.Error.abort("Unsupported super for native class constructor", expression.cpppos);
						case FuncSuperConstruct(childType):
							write(op(IaCallSuperNew) + astType(childType) + " " + argN + "\n");
						case FuncSuper(_, TCppInst(klass, _), _) if (isNativeGenClass(klass) && isNativeClass(klass)):
							core.Error.abort("Unsupported super for native class method", expression.cpppos);
						case FuncSuper(_, objType, field):
							write(({ var st = stringText(field.cfName); op(IaCallSuper) + astType(objType) + " " + st; }) + argN + commentOf(field.cfName) + "\n");
						case FuncExtern(name, _):
							write(op(IaCallGlobal) + stringText(name) + argN + commentOf(name) + "\n");
						case FuncNew(newType):
							write(op(IaNew) + astType(newType) + argN + "\n");
						case FuncInternal(obj, "cca", ".") if (obj.cpptype.match(TCppString)):
							write(({ var st = stringText("cca"); op(IaCallMember) + astType(obj.cpptype) + " " + st; }) + argN + commentOf("cca") + "\n");
							genTreeExpression(obj);
						case FuncInternal(obj, name, join):
							/* abort ("Internal function call '" ^ name ^ "' not supported in cppia") expression.cpppos; */
							write(({ var st = stringText(name); op(IaCallMember) + astType(obj.cpptype) + " " + st; }) + argN + commentOf(name) + "\n");
							genTreeExpression(obj);
						case FuncExpression(expr):
							write(op(IaCall) + argN + "\n");
							genTreeExpression(expr);
					}
					for (a in args) genTreeExpression(a);
				case CppFunction(func, _):
					switch func {
						case FuncThis(field, inst):
							write(({ var st = stringText(field.cfName); op(IaFThisName) + astType(inst) + " " + st; })
								+ commentOf(CppCppia.scriptCpptypeString(inst) + "." + field.cfName));
						case FuncInternal(expr, name, _):
							write(({ var st = stringText(name); op(IaFLink) + astType(expr.cpptype) + " " + st; })
								+ commentOf("Internal " + CppCppia.scriptCpptypeString(expr.cpptype) + "." + name) + "\n");
							genTreeExpression(expr);
						case FuncInstance(expr, _, field, _) | FuncInterface(expr, _, field):
							write(({ var st = stringText(field.cfName); op(IaFName) + astType(expr.cpptype) + " " + st; })
								+ commentOf(CppCppia.scriptCpptypeString(expr.cpptype) + "." + field.cfName) + "\n");
							genTreeExpression(expr);
						case FuncStatic(classDef, _, field, _):
							write(({ var st = stringText(field.cfName); op(IaFStatic) + cppInstText(classDef) + " " + st; }) + commentOf(field.cfName));
						case FuncExpression(expr): matchExpr(expr);
						case FuncExtern(name, _):
							core.Error.abort("Can't create extern " + name + " closure", expression.cpppos);
						case FuncSuper(_) | FuncSuperConstruct(_):
							core.Error.abort("Can't create super closure", expression.cpppos);
						case FuncNew(_): core.Error.abort("Can't create new closure", expression.cpppos);
						case FuncEnumConstruct(_):
							core.Error.abort("Enum constructor outside of CppCall", expression.cpppos);
						case FuncFromStaticFunction:
							core.Error.abort("Can't create cpp.Function.fromStaticFunction closure", expression.cpppos);
						case FuncTemplate(_):
							core.Error.abort("Can't create template function closure", expression.cpppos);
					}
				case CppPosition(file, line, className, meth):
					{
					// port: OCaml evaluates the operands of `^` right to left.
					var m = stringText(meth);
					var c = stringText(className);
					write(op(IaPosInfo) + stringText(file) + Std.string(line) + " " + c + " " + m);
				}
				case CppNullCompare("IsNull", e):
					writeOpLine(IaIsNull);
					genTreeExpression(e);
				case CppNullCompare(_, e):
					writeOpLine(IaNotNull);
					genTreeExpression(e);
				case CppCompare(_, left, right, o):
					writeOpLine(IaBinOp(o));
					genTreeExpression(left);
					genTreeExpression(right);
				case CppArray(arrayLoc): genArray(arrayLoc, expression.cpppos);
				case CppArrayDecl(exprList):
					write(op(IaADef) + astType(expression.cpptype) + " " + Std.string(exprList.length) + "\n");
					for (e in exprList) genTreeExpression(e);
				case CppEnumField(enumDef, field):
					write(({ var st = stringText(field.efName); op(IaFEnum) + enumText(enumDef) + " " + st; }) + commentOf(field.efName));
				case CppEnumIndex(obj):
					/* Cppia does not have a "GetEnumIndex" op code - must use IaCallMember ::hx::EnumBase.__Index */
					write(({ var st = stringText("__Index"); op(IaCallMember) + typeTextString("::hx::EnumBase") + " " + st; }) + "0" + commentOf("Enum index") + "\n");
					genTreeExpression(obj);
				case CppDynamicField(obj, name):
					write(({ var st = stringText(name); op(IaFName) + typeTextString("Dynamic") + " " + st; }) + commentOf(name) + "\n");
					genTreeExpression(obj);
				case CppClassOf(path, native):
					var klass = joinClassPath(path, ".");
					write(op(IaClassOf) + typeTextString(klass) + commentOf(klass));
				case CppEnumParameter(obj, field, index):
					write(op(IaEnumI) + typeTextString("Dynamic") + Std.string(index) + "\n");
					genTreeExpression(obj);
				case CppCallable(closure):
					write(op(IaFun) + astType(closure.closeType) + Std.string(closure.closeArgs.length) + "\n");
					var close = genFuncArgs(closure.closeArgs);
					genTreeExpression(closure.closeExpr);
					close();
				case CppObjectDecl(values, isStruct):
					write(op(IaObjDef) + Std.string(values.length));
					write(" ");
					for (v in values) write(stringText(v.name));
					write("\n");
					for (v in values) genTreeExpression(v.e);
				case CppCrement(incFlag, preFlag, lvalue):
					var o = switch [incFlag, preFlag] {
						case [CppIncrement, Prefix]: IaPlusPlus;
						case [CppIncrement, Postfix]: IaPlusPlusPost;
						case [CppDecrement, Prefix]: IaMinusMinus;
						case [CppDecrement, Postfix]: IaMinusMinusPost;
					}
					writeOpLine(o);
					genLvalue(lvalue, expression.cpppos);
				case CppModify(o, lvalue, rvalue):
					writeOpLine(IaBinOp(OpAssignOp(o)));
					genLvalue(lvalue, expression.cpppos);
					genTreeExpression(rvalue);
				case CppUnop(o, expr):
					var o = switch o {
						case CppNot: IaLogicNot;
						case CppNeg: IaNeg;
						case CppNegBits: IaBitNot;
					}
					writeOpLine(o);
					genTreeExpression(expr);
				case CppThrow(value):
					writeOpLine(IaThrow);
					genTreeExpression(value);
				case CppTry(block, catches):
					writeList(op(IaTry), catches.length);
					genTreeExpression(block);
					for (c in catches) {
						write("\t\t\t" + indent);
						writeVar(c.v.tcppvVar);
						write("\n");
						genTreeExpression(c.e);
					}
				case CppIntSwitch(_):
					core.Error.abort("CppIntSwitch not supported in cppia", expression.cpppos);
				case CppSwitch(condition, _, cases, optionalDefault, _):
					write(op(IaSwitch) + Std.string(cases.length) + " " + (if (optionalDefault == null) "0" else "1") + "\n");
					genTreeExpression(condition);
					for (c in cases) {
						writeList("\t\t\t" + indent, c.values.length);
						for (value in c.values) genTreeExpression(value);
						genTreeExpression(c.e);
					}
					switch optionalDefault {
						case null:
						case expr: genTreeExpression(expr);
					}
				case CppTCast(expr, toType):
					write(op(IaTCast) + astType(toType) + "\n");
					genTreeExpression(expr);
				case CppCast(expr, toType):
					switch toType {
						case TCppDynamicArray:
							write(op(IaToDynArray) + "\n");
							genTreeExpression(expr);
						case TCppObjectArray(_):
							write(op(IaToDataArray) + typeTextString("Array.Object") + "\n");
							genTreeExpression(expr);
						case TCppScalarArray(t):
							write(op(IaToDataArray) + typeTextString("Array." + CppCppia.scriptCpptypeString(t)) + "\n");
							genTreeExpression(expr);
						case _: matchExpr(expr);
					}
				case CppCastScalar(expr, "bool"):
					writeOpLine(IaCastBool);
					genTreeExpression(expr);
				case CppCastScalar(expr, "int"):
					writeOpLine(IaCastInt);
					genTreeExpression(expr);
				case CppCastScalar(expr, "Float"):
					write(op(IaTCast) + astType(TCppScalar("Float")) + "\n");
					genTreeExpression(expr);
				case CppCastScalar(expr, _): matchExpr(expr);
				case CppCastVariant(expr): matchExpr(expr);
				case CppCastStatic(expr, _): matchExpr(expr);
				case CppNullAccess:
					writeOpLine(IaThrow);
					beginExpr();
					writeCppPos(expression);
					write(op(IaConstString) + stringText("Null access"));
					endExpr();
				case CppCode(_) | CppFunctionAddress(_) | CppNewNative(_) | CppDereference(_) | CppAddressOf(_) | CppFor(_) | CppCastObjC(_) |
					CppCastObjCBlock(_) | CppCastProtocol(_) | CppCastNative(_):
					core.Error.abort("Unsupported operation in cppia :" + sTcpp(expression.cppexpr), expression.cpppos);
					/*| x -> print_endline ("Unknown cppexpr " ^ (s_tcpp x) );*/
			}
		}

		matchExpr(expression);
		endExpr();
	}

	function genArray(arrayLoc:TcppArrayLoc, pos:Pos):Void {
		switch arrayLoc {
			case TcppArrayLoc.ArrayObject(arrayObj, index, _) | ArrayTyped(arrayObj, index, _):
				write(op(IaArrayI) + astType(arrayObj.cpptype) + "\n");
				genTreeExpression(arrayObj);
				genTreeExpression(index);
			case ArrayPointer(_, _) | ArrayRawPointer(_, _):
				core.Error.abort("Unvalid array access in cppia", pos);
			case ArrayVirtual(arrayObj, index) | ArrayImplements(_, arrayObj, index) | ArrayDynamic(arrayObj, index):
				write(op(IaArrayI) + astType(arrayObj.cpptype) + "\n");
				genTreeExpression(arrayObj);
				genTreeExpression(index);
		}
	}

	function genLvalue(lvalue:TcppLValue, pos:Pos):Void {
		beginExpr();
		wpos(pos);
		switch lvalue {
			case CppVarRef(varLoc): genVarLoc(varLoc);
			case CppArrayRef(arrayLoc): genArray(arrayLoc, pos);
			case CppExternRef(name, _):
				core.Error.abort("Unsupported extern '" + name + "' in cppia", pos);
			case CppDynamicRef(expr, name):
				var typeText = typeTextString("Dynamic");
				write(op(IaFName) + typeText + " " + stringText(name) + commentOf(name) + "\n");
				genTreeExpression(expr);
		}
		endExpr();
	}

	function genVarLoc(loc:TcppVarLoc):Void {
		switch loc {
			case VarClosure(v) | VarLocal(v):
				write(op(IaVar) + Std.string(v.tcppvVar.vId) + commentOf(v.tcppvVar.vName));
			case VarStatic(classDef, _, field):
				write(({ var st = stringText(field.cfName); op(IaFStatic) + cppInstText(classDef) + " " + st; }) + commentOf(field.cfName));
			case VarThis(field, thisType):
				write(({ var st = stringText(field.cfName); op(IaFThisInst) + astType(thisType) + " " + st; }) + commentOf(field.cfName));
			case VarInstance(obj, field, _, _) | VarInterface(obj, field):
				var objType = CppCppia.scriptCpptypeString(obj.cpptype);
				write(({ var st = stringText(field.cfName); op(IaFLink) + astType(obj.cpptype) + " " + st; }) + commentOf(objType + "." + field.cfName) + "\n");
				genTreeExpression(obj);
			case VarInternal(obj, _, name):
				var objType = CppCppia.scriptCpptypeString(obj.cpptype);
				write(({ var st = stringText(name); op(IaFLink) + astType(obj.cpptype) + " " + st; }) + commentOf(objType + "." + name) + "\n");
				genTreeExpression(obj);
				/*
					and get_array_type elem =
					this#stringText (script_cpptype_string elem.cpptype);
				 */
		}
	}
}
