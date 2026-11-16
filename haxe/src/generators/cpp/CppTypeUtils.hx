package generators.cpp;

/* Various helper functions to run checks on haxe classes and various other ast types */
/* functions in here operate on standard haxe ast types, not gencpp ast types */
import core.Globals;
import core.TType;
import core.TFunctions.*;
import core.TFunctions;
import core.Meta;
import core.ds.NotFound;
import generators.cpp.CppMarshalling.*;

class CppTypeUtils {
	public static function follow(t:T):T return core.Abstract.followWithAbstracts(t);

	public static function isNativeGenClass(classDef:TClass):Bool {
		return Meta.has(Meta.NativeGen, classDef.clMeta) || switch classDef.clKind {
			case KAbstractImpl(abstractDef): Meta.has(Meta.NativeGen, abstractDef.aMeta);
			case _: false;
		}
	}

	public static function isNativeGenModule(t:ModuleType):Bool return switch t {
		case TClassDecl(classDef): isNativeGenClass(classDef);
		case _: false;
	}

	public static function isExternClass(classDef:TClass):Bool {
		return hasClassFlag(classDef, CExtern) || Meta.has(Meta.Extern, classDef.clMeta) || switch classDef.clKind {
			case KAbstractImpl(abstractDef): Meta.has(Meta.Extern, abstractDef.aMeta);
			case _: false;
		}
	}

	public static function isExternEnum(enumDef:TEnum):Bool return hasEnumFlag(enumDef, EnExtern) || Meta.has(Meta.Extern, enumDef.eMeta);

	/* The internal classes are implemented by the core hxcpp system, so the cpp classes should not be generated */
	public static function isInternalClass(path:GlobalTypePath):Bool {
		return switch [path.pack, path.name] {
			case [[], "Int"] | [[], "Void"] | [[], "String"] | [[], "Null"] | [[], "Float"] | [[], "Array"] | [[], "Class"] | [[], "Enum"] |
				[[], "Bool"] | [[], "Dynamic"] | [[], "ArrayAccess"] | [[], "Math"] | [[], "Single"] | [["cpp"], "FastIterator"] |
				[["cpp"], "Pointer"] | [["cpp"], "ConstPointer"] | [["cpp"], "RawPointer"] | [["cpp"], "RawConstPointer"] |
				[["cpp"], "Function"] | [["cpp"], "VirtualArray"] | [["cpp"], "Int8"] | [["cpp"], "UInt8"] | [["cpp"], "Char"] |
				[["cpp"], "Char16"] | [["cpp"], "Char32"] | [["cpp"], "Int16"] | [["cpp"], "UInt16"] | [["cpp"], "Int32"] |
				[["cpp"], "UInt32"] | [["cpp"], "Int64"] | [["cpp"], "UInt64"] | [["cpp"], "Float32"] | [["cpp"], "Float64"]:
				true;
			case _:
				false;
		}
	}

	public static function isNativeClass(classDef:TClass):Bool
		return (isExternClass(classDef) || isNativeGenClass(classDef))
			&& !isInternalClass(classDef.clPath)
			&& !isMarshallingNativeValueClass(classDef);

	// port: upstream defines can_quick_alloc and real_interfaces twice; the later definitions shadow the first ones.
	public static function canQuickAlloc(klass:TClass):Bool {
		function implementsNativeInterface(classDef:TClass):Bool {
			return Lambda.exists(classDef.clImplements, function(i) return isNativeGenClass(i.cls) || implementsNativeInterface(i.cls))
				|| switch classDef.clSuper {
					case null: false;
					case s: implementsNativeInterface(s.cls);
				}
		}
		return (!isNativeClass(klass)) && !implementsNativeInterface(klass);
	}

	public static function realInterfaces(classes:Array<ClassAndParams>):Array<ClassAndParams> {
		return classes.filter(function(i) return switch [i.cls.clPath, i.params] {
			case [{pack: ["cpp", "rtti"]}, []]: false;
			case _: true;
		});
	}

	public static function isInterfaceType(t:T):Bool {
		return switch follow(t) {
			case TInst(klass, params): hasClassFlag(klass, CInterface);
			case _: false;
		}
	}

	public static function isObjcType(t:T):Bool {
		return switch t {
			case TInst(cl, _): hasClassFlag(cl, CExtern) && Meta.has(Meta.Objc, cl.clMeta);
			case TType(td, _): Meta.has(Meta.Objc, td.tMeta);
			case TAbstract(a, _): Meta.has(Meta.Objc, a.aMeta);
			case TMono(r): r.tmType != null && isObjcType(r.tmType);
			case TLazy(f): isObjcType(lazyType(f));
			case _: false;
		}
	}

	public static function isDynamicTypeParam(classKind:TClassKind):Bool return classKind.match(KTypeParameter(_));

	public static function isDynamicArrayParam(t:T):Bool {
		return switch follow(t) {
			case TAbstract({aPath: {pack: [], name: "Dynamic"}}, []): true;
			case TInst(klass, params):
				switch klass {
					case {clPath: {pack: [], name: "Array"}} | {clPath: {pack: [], name: "Class"}} | {clPath: {pack: ["cpp"], name: "FastIterator"}} |
						{clPath: {pack: ["cpp"], name: "RawPointer"}} | {clPath: {pack: ["cpp"], name: "ConstRawPointer"}} |
						{clPath: {pack: ["cpp"], name: "Pointer"}} | {clPath: {pack: ["cpp"], name: "ConstPointer"}} |
						{clPath: {pack: ["cpp"], name: "Function"}}: false;
					case {clKind: KTypeParameter(_)}: true;
					case _: false;
				}
			case _: false;
		}
	}

	public static function isNumeric(t:T):Bool {
		return switch follow(t) {
			case TAbstract({aPath: {pack: [], name: "Int"}}, []) | TAbstract({aPath: {pack: [], name: "Float"}}, []) |
				TAbstract({aPath: {pack: [], name: "Single"}}, []) | TAbstract({aPath: {pack: ["cpp"], name: "Char"}}, []) |
				TAbstract({aPath: {pack: ["cpp"], name: "Char16"}}, []) | TAbstract({aPath: {pack: ["cpp"], name: "Char32"}}, []) |
				TAbstract({aPath: {pack: ["cpp"], name: "Float32"}}, []) | TAbstract({aPath: {pack: ["cpp"], name: "Float64"}}, []) |
				TAbstract({aPath: {pack: ["cpp"], name: "Int8"}}, []) | TAbstract({aPath: {pack: ["cpp"], name: "Int16"}}, []) |
				TAbstract({aPath: {pack: ["cpp"], name: "Int32"}}, []) | TAbstract({aPath: {pack: ["cpp"], name: "Int64"}}, []) |
				TAbstract({aPath: {pack: ["cpp"], name: "UInt8"}}, []) | TAbstract({aPath: {pack: ["cpp"], name: "UInt16"}}, []) |
				TAbstract({aPath: {pack: ["cpp"], name: "UInt32"}}, []) | TAbstract({aPath: {pack: ["cpp"], name: "UInt64"}}, []):
				true;
			case _:
				false;
		}
	}

	public static function isObjcClass(klass:TClass):Bool return hasClassFlag(klass, CExtern) && Meta.has(Meta.Objc, klass.clMeta);

	public static function isVarField(field:TClassField):Bool {
		return switch field.cfKind {
			case Var(_) | Method(MethDynamic): true;
			case _: false;
		}
	}

	public static function isPointer(haxeType:T, includeRaw:Bool):Bool {
		return switch follow(haxeType) {
			case TInst(klass, params):
				switch [klass.clPath.pack, klass.clPath.name] {
					case [["cpp"], "Pointer"] | [["cpp"], "ConstPointer"] | [["cpp"], "Function"]: true;
					case [["cpp"], "RawPointer"] if (includeRaw): true;
					case [["cpp"], "RawConstPointer"] if (includeRaw): true;
					case _: false;
				}
			case TType(typeDef, params):
				switch [typeDef.tPath.pack, typeDef.tPath.name] {
					case [["cpp"], "Pointer"] | [["cpp"], "ConstPointer"] | [["cpp"], "Function"]: true;
					case [["cpp"], "RawPointer"] if (includeRaw): true;
					case [["cpp"], "RawConstPointer"] if (includeRaw): true;
					case _: false;
				}
			case _: false;
		}
	}

	public static function isArray(haxeType:T):Bool {
		return switch follow(haxeType) {
			case TInst({clPath: {pack: [], name: "Array"}}, params) | TType({tPath: {pack: [], name: "Array"}}, params):
				if (params.length == 0) throw new core.ds.Failure("hd");
				!isDynamicArrayParam(params[0]);
			case _: false;
		}
	}

	public static function isArrayOrDynArray(haxeType:T):Bool {
		return switch follow(haxeType) {
			case TInst({clPath: {pack: [], name: "Array"}}, _) | TType({tPath: {pack: [], name: "Array"}}, _): true;
			case _: false;
		}
	}

	public static function shouldImplementField(x:TClassField):Bool return isPhysicalField(x);

	public static function isScalarAbstract(abstractDef:TAbstract):Bool
		return Meta.has(Meta.Scalar, abstractDef.aMeta) && Meta.has(Meta.CoreType, abstractDef.aMeta);

	public static function isRealFunction(field:TClassField):Bool {
		return switch field.cfKind {
			case Method(MethNormal) | Method(MethInline): true;
			case _: false;
		}
	}

	public static function getNthType(field:TEnumField, index:Int):T {
		return switch follow(field.efType) {
			case TFun(sig):
				if (index < 0 || index >= sig.args.length) throw NotFound.raise();
				sig.args[index].type;
			case _: throw NotFound.raise();
		}
	}

	public static function isDynamicHaxeMethod(f:TClassField):Bool {
		return switch [f.cfExpr, f.cfKind] {
			case [null, _]: false;
			case [{eexpr: TFunction(_)}, Var(_) | Method(MethDynamic)]: true;
			case _: false;
		}
	}

	public static function hasDynamicMemberFunctions(classDef:TClass):Bool {
		var result = false;
		for (field in classDef.clFields) result = switch field.cfExpr {
			case null: result;
			case {eexpr: TFunction(functionDef)} if (isDynamicHaxeMethod(field)): true;
			case _: result;
		}
		return result;
	}

	public static function hasFieldInit(field:TClassField):Bool {
		return switch field.cfExpr {
			// port: the None case is tested first (null-safe structure patterns).
			case null: false;
			/* Function field */
			case {eexpr: TFunction(functionDef)}: isDynamicHaxeMethod(field);
			/* Data field */
			case _: true;
		}
	}

	public static function isDataMember(field:TClassField):Bool {
		return switch field.cfKind {
			case Var(_) | Method(MethDynamic): true;
			case _: false;
		}
	}

	public static function isOverride(field:TClassField):Bool return hasClassFieldFlag(field, CfOverride);

	public static function unreflectiveType(t:T):Bool {
		function aux(t:T, seen:Array<T>):Bool {
			if (Lambda.exists(seen, function(s) return core.TUnification.fastEq(t, s))) return false else {
				var newSeen = [t].concat(seen);
				return switch follow(t) {
					case TInst(klass, _): Meta.has(Meta.Unreflective, klass.clMeta);
					case TFun(sig):
						var result = aux(sig.ret, newSeen);
						for (a in sig.args) result = result || aux(a.type, newSeen);
						result;
					case _: false;
				}
			}
		}
		return aux(t, []);
	}

	public static function reflective(classDef:TClass, field:TClassField):Bool {
		return !(Meta.has(Meta.NativeGen, classDef.clMeta)
			|| Meta.has(Meta.Unreflective, classDef.clMeta)
			|| Meta.has(Meta.Unreflective, field.cfMeta)
			|| unreflectiveType(field.cfType));
	}

	public static function hasInitField(classDef:TClass):Bool return core.TOther.TClassTools.getClInit(classDef) != null;

	public static function isAbstractImpl(classDef:TClass):Bool return classDef.clKind.match(KAbstractImpl(_));

	public static function variableField(field:TClassField):Bool {
		return switch field.cfExpr {
			case null if (hasClassFieldFlag(field, CfAbstract)): false;
			case null: true;
			case {eexpr: TFunction(functionDef)}: isDynamicHaxeMethod(field);
			case _: true;
		}
	}

	public static function isReadable(classDef:TClass, field:TClassField):Bool {
		return switch field.cfKind {
			case Var({vRead: AccNever}) if (!isPhysicalField(field)): false;
			case Var({vRead: AccInline}): false;
			case Var(_) if (isAbstractImpl(classDef)): false;
			case _: true;
		}
	}

	public static function isWritable(classDef:TClass, field:TClassField):Bool {
		return switch field.cfKind {
			case Var({vWrite: AccNever}) if (!isPhysicalField(field)): false;
			case Var({vRead: AccInline}): false;
			case Var(_) if (isAbstractImpl(classDef)): false;
			case _: true;
		}
	}

	public static function staticsExceptMeta(classDef:TClass):Array<TClassField>
		return classDef.clStatics.toArray().filter(function(s) return s.cfName != "__meta__" && s.cfName != "__rtti");

	public static function hasSetMemberField(classDef:TClass):Bool {
		var reflectFields = classDef.clFields.toArray().filter(function(f) return reflective(classDef, f));
		var reflectWritable = reflectFields.filter(function(f) return isWritable(classDef, f));
		return Lambda.exists(reflectWritable, variableField);
	}

	public static function hasSetStaticField(classDef:TClass):Bool {
		var reflectFields = staticsExceptMeta(classDef).filter(function(f) return reflective(classDef, f));
		var reflectWritable = reflectFields.filter(function(f) return isWritable(classDef, f));
		return Lambda.exists(reflectWritable, variableField);
	}

	public static function hasGetFields(classDef:TClass):Bool {
		function isDataField(field:TClassField):Bool return !follow(field.cfType).match(TFun(_));
		return Lambda.exists(classDef.clFields, isDataField);
	}

	public static function hasGetMemberField(classDef:TClass):Bool {
		var reflectFields = classDef.clFields.toArray().filter(function(f) return reflective(classDef, f));
		return Lambda.exists(reflectFields, function(f) return isReadable(classDef, f));
	}

	public static function hasGetStaticField(classDef:TClass):Bool {
		var reflectFields = staticsExceptMeta(classDef).filter(function(f) return reflective(classDef, f));
		return Lambda.exists(reflectFields, function(f) return isReadable(classDef, f));
	}

	public static function hasCompareField(classDef:TClass):Bool return Lambda.exists(classDef.clFields, function(f) return f.cfName == "__compare");

	public static function hasBootField(classDef:TClass):Bool {
		return switch core.TOther.TClassTools.getClInit(classDef) {
			case null: Lambda.exists(classDef.clStatics.toArray().filter(shouldImplementField), hasFieldInit);
			case _: true;
		}
	}

	public static function className(classDef:TClass):String {
		var classPath = classDef.clPath.name;
		var nativeGen = Meta.has(Meta.NativeGen, classDef.clMeta);
		return classPath + (nativeGen ? "" : "_obj");
	}

	public static function classPointer(classDef:TClass):String return "::hx::ObjectPtr< " + className(classDef) + " >";
}
