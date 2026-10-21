package generators.cpp;

import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.TFunctions.MaybeCoro;
import core.Meta;
import core.Define;
import core.ds.NotFound;
import generators.Gctx;
import generators.cpp.CppAst;
import generators.cpp.CppTypeUtils.*;
import generators.cpp.CppAstTools.*;
import generators.cpp.CppContext;
import generators.cpp.CppMarshalling.*;
import generators.cpp.CppError;
import generators.cpp.CppError.CppErrorKind;
import generators.cpp.filters.CppFilterValueType;
import generators.cpp.filters.CppFilterAutoCast;
import haxe.ds.Vector;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// port: value-type handlers (`unit -> marshal_type_state`).
typedef ValueTypeHandler = Void->MarshalTypeState;

@:structInit class RetyperCtx {
	public var closureId:Int;
	public var closures:Array<TcppClosure>;
	public var injection:Bool;
	public var declarations:IntPMap<TcppVar>;
	public var undeclared:IntPMap<TcppVar>;
	public var usesThis:Null<TcppThis>;
	public var thisReal:TcppThis;
	public var gcStack:Bool;
	public var functionReturnType:Tcpp;
	public var gotoId:Int;
	public var loopStack:Array<{id:Int, used:Bool}>;

	// port: `{ retyper_ctx with ... }`.
	public function copy():RetyperCtx return {
		closureId: closureId,
		closures: closures,
		injection: injection,
		declarations: declarations,
		undeclared: undeclared,
		usesThis: usesThis,
		thisReal: thisReal,
		gcStack: gcStack,
		functionReturnType: functionReturnType,
		gotoId: gotoId,
		loopStack: loopStack
	};
}

class CppRetyper {
	/* TODO : Not have this basically be a duplicated unify_cf */
	public static function unifyCf2(mapType:T->T, c:TClass, cf:TClassField, elArgs:Vector<TExpr>,
			elRet:TExpr):Null<typing.FieldCallCandidate.FieldCallCandidateData<typing.OverloadResolution.ResolvedOverload>> {
		var monos = cf.cfParams.map(function(_) return mkMono());
		return switch follow(applyParams(cf.cfParams, monos, mapType(cf.cfType))) {
			case tf = TFun({args: tl2, ret: ret}):
				core.TUnification.unify(elRet.etype, ret);
				// port: elArgs and tl2 walked in lockstep from i on (upstream: their tails), acc being elArgs' first i elements
				function loop2(i:Int) {
					return if (i < elArgs.length && i < tl2.length) {
						var e = elArgs[i], t = tl2[i].type;
						var unified = try {
							core.TUnification.unify(e.etype, t);
							true;
						} catch (_:Dynamic) false;
						if (unified) loop2(i + 1) else {
							if (core.TOther.ExtType.isRest(follow(t))) {
								switch [follow(t), tl2.length - i - 1] {
									case [TAbstract({aPath: {pack: ["haxe"], name: "Rest"}}, [t]), 0]:
										try {
											var args = new Vector<TExpr>(elArgs.length - 1);
											Vector.blit(elArgs, 0, args, 0, i);
											for (j in i + 1...elArgs.length) {
												var e = elArgs[j];
												core.TUnification.unify(t, e.etype);
												args[j - 1] = e;
											}
											var fcc = typing.FieldCallCandidate.makeFieldCallCandidate(args, ret, monos, tf, cf,
												({cls: c, field: cf, monos: monos} : typing.OverloadResolution.ResolvedOverload));
											fcc;
										} catch (_:Dynamic) null;
									case _:
										die("", "cppRetyper.ml");
								}
							} else null;
						}
					} else if (i == elArgs.length && i == tl2.length) {
						typing.FieldCallCandidate.makeFieldCallCandidate(elArgs.copy(), ret, monos, tf, cf,
							({cls: c, field: cf, monos: monos} : typing.OverloadResolution.ResolvedOverload));
					} else null;
				}
				loop2(0);
			case t:
				null;
		}
	}

	public static function withReferenceValueType():MarshalTypeState return Reference;

	public static function withPromotedValueType():MarshalTypeState return Promoted;

	public static function withStackValueType():MarshalTypeState return Stack;

	public static function isLvalueExpr(expr:TExpr):Bool {
		function checker(expr:TExpr):Bool {
			return switch expr.eexpr {
				case TLocal(_): true;
				case TField(_, FInstance(_, _, field)) if (isVarField(field)): true;
				case TField(_, FStatic(_, field)) if (isVarField(field)): true;
				case TCast(e, _): checker(e);
				case _: false;
			}
		}
		return checker(expr);
	}

	static function cppTypeOfStack(stack:Array<T>, basic:BasicTypes, valueTypeHandler:ValueTypeHandler, haxeType:T):Tcpp {
		if (Lambda.exists(stack, function(s) return core.TUnification.fastEq(haxeType, s))) return TCppDynamic else {
			var stack = [haxeType].concat(stack);
			return switch haxeType {
				case TMono(r):
					r.tmType == null ? TCppDynamic : cppTypeOfStack(stack, basic, valueTypeHandler, r.tmType);
				case TEnum(enumDef, params): TCppEnum(enumDef);
				case TInst({clPath: {pack: [], name: "Array"}, clKind: KTypeParameter(_)}, _):
					TCppObject;
				case TInst({clKind: KTypeParameter(_)}, _): TCppDynamic;
				case TInst(klass, params):
					cppInstanceTypeStack(stack, basic, klass, params, valueTypeHandler);
				case TAbstract({aPath: {pack: ["haxe", "coro"], name: "Coroutine"}, aPos: pos}, [t]):
					switch follow(t) {
						case TFun(sig):
							var expanded = context.Common.expandCoroType(basic, sig.args, sig.ret);
							cppTypeOfStack(stack, basic, valueTypeHandler, TFun(expanded));
						case t:
							CppError.cppAbort(InternalError, pos);
					}
				case TAbstract(abs, pl) if (isMarshallingNativeEnum(abs)):
					TCppMarshalNativeType(ValueEnum(abs), valueTypeHandler());
				case TAbstract(abs, pl) if (!Meta.has(Meta.CoreType, abs.aMeta)):
					cppTypeFromPathStack(stack, basic, abs.aPath, pl, valueTypeHandler,
						function() return cppTypeOfStack(stack, basic, valueTypeHandler, core.Abstract.getUnderlyingType(abs, pl, true)));
				case TAbstract(a, params):
					cppTypeFromPathStack(stack, basic, a.aPath, params, valueTypeHandler, function() {
						return if (isScalarAbstract(a)) switch Ast.getMetaString(a.aMeta, Meta.Native) {
							case null: TCppScalar(joinClassPath(a.aPath, "::"));
							case s: TCppScalar(s);
						} else TCppDynamic;
					});
				case TType(typeDef, params):
					/* Can't really remember why / what this is doing */
					/* I only have vague memories of nightmares about trying to stop recursive typedefs turning stuff dynamic */
					function find(s:Array<T>, t:T):Bool {
						if (Lambda.exists(s, function(x) return core.TUnification.fastEq(t, x))) {
							return true;
						} else {
							var s = [t].concat(s);
							return switch t {
								case TMono(r):
									r.tmType == null ? false : find(s, r.tmType);
								case TEnum(_, tl) | TInst(_, tl):
									tl.exists(function(x) return find(s, x));
								case TAbstract(abs, tl):
									if (!Meta.has(Meta.CoreType, abs.aMeta) && find(s, core.Abstract.getUnderlyingType(abs, tl, true))) true else
										tl.exists(function(x) return find(s, x));
								case TType(tdef, tl):
									find(s, applyTypedef(tdef, tl));
								case TFun(sig):
									if (find(s, sig.ret)) true else {
										sig.args.exists(function(a) return find(s, a.type));
									}
								case TLazy(f):
									find(s, lazyType(f));
								case TDynamic(t2) if (t2 != null):
									find(s, t2);
								case _:
									false;
							}
						}
					}
					if (find([], haxeType)) cppTypeFromPathStack(stack, basic, typeDef.tPath, params, valueTypeHandler, function() return TCppDynamic) else
						cppTypeFromPathStack(stack, basic, typeDef.tPath, params, valueTypeHandler,
							function() return cppTypeOfStack(stack, basic, valueTypeHandler, applyTypedef(typeDef, params)));
				case TFun(sig):
					var retypedArguments = sig.args.mapToArray(function(a) return cppTfunArgTypeOfStack(stack, basic, a.optional, withReferenceValueType, a.type));
					var retypedReturn = cppTypeOfStack(stack, basic, withStackValueType, sig.ret);
					TCppCallable(retypedArguments, retypedReturn);
				case TAnon(_): TCppObject;
				case TDynamic(_): TCppDynamic;
				case TLazy(func): cppTypeOfStack(stack, basic, valueTypeHandler, lazyType(func));
			}
		}
	}

	static function cppTypeFromPathStack(stack:Array<T>, basic:BasicTypes, path:GlobalTypePath, params:TParams, valueTypeHandler:ValueTypeHandler,
			def:Void->Tcpp):Tcpp {
		return switch [path.pack, path.name, params] {
			case [[], "Void", _]: TCppVoid;
			case [[], "void", _]: TCppVoid; /* for old code with @:void */
			case [[], "Bool", _]: TCppScalar("bool");
			case [[], "Float", _]: TCppScalar("Float");
			case [[], "Int", _]: TCppScalar("int");
			case [[], "EnumValue", _]: TCppObject;
			case [[], "Class", _]: TCppClass;
			case [[], "Enum", _]: TCppClass;
			case [[], "Single", _]: TCppScalar("float");
			case [["cpp"], "Char", _]: TCppScalar("char");
			case [["cpp"], "Char16", _]: TCppScalar("char16_t");
			case [["cpp"], "Char32", _]: TCppScalar("char32_t");
			case [["cpp"], "Object", _]: TCppObjectPtr;
			case [["cpp"], "Float32", _]: TCppScalar("float");
			case [["cpp"], "Float64", _]: TCppScalar("double");
			case [["cpp"], "Int8", _]: TCppScalar("signed char");
			case [["cpp"], "Int16", _]: TCppScalar("short");
			case [["cpp"], "Int32", _]: TCppScalar("int");
			case [["cpp"], "Int64", _]: TCppScalar("::cpp::Int64");
			case [["cpp"], "UInt8", _]: TCppScalar("unsigned char");
			case [["cpp"], "UInt16", _]: TCppScalar("unsigned short");
			case [["cpp"], "UInt32", _]: TCppScalar("unsigned int");
			case [["cpp"], "UInt64", _]: TCppScalar("::cpp::UInt64");
			case [["cpp"], "VarArg", _]: TCppVarArg;
			case [["cpp"], "AutoCast", _]: TCppAutoCast;
			case [[], "String", []]: TCppString;
			/* Things with type parameters hxcpp knows about ... */
			case [["cpp"], "FastIterator", [p]]: TCppFastIterator(cppTypeOfStack(stack, basic, valueTypeHandler, p));
			case [["cpp"], "Pointer", [p]]: TCppPointer("Pointer", cppTypeOfStack(stack, basic, valueTypeHandler, p));
			case [["cpp"], "ConstPointer", [p]]:
				TCppPointer("ConstPointer", cppTypeOfStack(stack, basic, valueTypeHandler, p));
			case [["cpp"], "RawPointer", [p]]: TCppRawPointer("", cppTypeOfStack(stack, basic, valueTypeHandler, p));
			case [["cpp"], "RawConstPointer", [p]]:
				TCppRawPointer("const ", cppTypeOfStack(stack, basic, valueTypeHandler, p));
			case [["cpp"], "Function", [functionType, abi]]:
				cppFunctionTypeOfStack(stack, basic, functionType, abi, valueTypeHandler);
			case [["cpp"], "Callable", [functionType]] | [["cpp"], "CallableData", [functionType]]:
				cppFunctionTypeOfStringStack(stack, basic, functionType, "", valueTypeHandler);
			case [["cpp", "objc"], "ObjcBlock", [functionType]]:
				var r = cppFunctionTypeOfArgsRetStack(stack, basic, valueTypeHandler, functionType);
				TCppObjCBlock(r.args, r.ret);
			case [["cpp"], "Rest", [rest]]: TCppRest(cppTypeOfStack(stack, basic, valueTypeHandler, rest));
			case [["cpp", "objc"], "Protocol", [interfaceType]]:
				switch follow(interfaceType) {
					case TInst(klass, []) if (hasClassFlag(klass, CInterface)):
						TCppProtocol(klass);
					/* TODO - get the line number here */
					case _:
						printEndline("cpp.objc.Protocol must refer to an interface");
						die("", "cppRetyper.ml");
				}
			case [["cpp"], "Reference", [param]]:
				TCppReference(cppTypeOfStack(stack, basic, valueTypeHandler, param));
			case [["cpp"], "Struct", [param]]: TCppStruct(cppTypeOfStack(stack, basic, valueTypeHandler, param));
			case [["cpp"], "Star", [param]]:
				TCppStar(cppTypeOfPointerStack(stack, basic, valueTypeHandler, param), false);
			case [["cpp"], "ConstStar", [param]]:
				TCppStar(cppTypeOfPointerStack(stack, basic, valueTypeHandler, param), true);
			case [[], "Array", [p]]:
				var arrayOf = cppTypeOfStack(stack, basic, withPromotedValueType, p);
				switch arrayOf {
					case TCppVoid /* ? */ | TCppDynamic: TCppDynamicArray;
					case TCppObject | TCppObjectPtr | TCppReference(_) | TCppStruct(_) | TCppStar(_) | TCppEnum(_) | TCppInst(_) | TCppInterface(_) |
						TCppProtocol(_) | TCppClass | TCppDynamicArray | TCppObjectArray(_) | TCppScalarArray(_) | TCppMarshalNativeType(_) |
						TCppMarshalManagedType(_) | TCppCallable(_):
						TCppObjectArray(arrayOf);
					case _: TCppScalarArray(arrayOf);
				}
			case [[], "Null", [p]]: cppTypeOfNullStack(stack, basic, valueTypeHandler, p);
			case _: def();
		}
	}

	static function cppTypeOfNullStack(stack:Array<T>, basic:BasicTypes, valueTypeHandler:ValueTypeHandler, p:T):Tcpp {
		return switch cppTypeOfStack(stack, basic, withPromotedValueType, p) {
			case other if (isCppScalar(other) || typeHasMetaKey(Meta.NotNull, p)):
				TCppObject;
			case other:
				other;
		}
	}

	static function cppTypeOfPointerStack(stack:Array<T>, basic:BasicTypes, valueTypeHandler:ValueTypeHandler, p:T):Tcpp {
		return switch p {
			case TAbstract({aPath: {pack: [], name: "Null"}}, [t]): cppTypeOfStack(stack, basic, valueTypeHandler, t);
			case x: cppTypeOfStack(stack, basic, valueTypeHandler, x);
		}
	}

	/* Optional types are Dynamic if they norally could not be null */
	public static function cppFunArgTypeOf(basic:BasicTypes, tvar:TVar, opt:Null<TExpr>, valueTypeHandler:ValueTypeHandler):Tcpp {
		return switch opt {
			case null: cppTypeOfStack([], basic, valueTypeHandler, tvar.vType);
			case _: cppTypeOfNullStack([], basic, valueTypeHandler, tvar.vType);
		}
	}

	static function cppTfunArgTypeOfStack(stack:Array<T>, basic:BasicTypes, opt:Bool, valueTypeHandler:ValueTypeHandler, t:T):Tcpp
		return if (opt) cppTypeOfNullStack(stack, basic, valueTypeHandler, t) else cppTypeOfStack(stack, basic, valueTypeHandler, t);

	static function cppFunctionTypeOfStack(stack:Array<T>, basic:BasicTypes, functionType:T, abi:T, valueTypeHandler:ValueTypeHandler):Tcpp {
		var abi = switch follow(abi) {
			case TInst(klass1, _):
				switch Ast.getMetaString(klass1.clMeta, Meta.Abi) {
					case null: "";
					case s: s;
				}
			case _: die("", "cppRetyper.ml");
		}
		return cppFunctionTypeOfStringStack(stack, basic, functionType, abi, valueTypeHandler);
	}

	static function cppFunctionTypeOfStringStack(stack:Array<T>, basic:BasicTypes, functionType:T, abiString:String,
			valueTypeHandler:ValueTypeHandler):Tcpp {
		var r = cppFunctionTypeOfArgsRetStack(stack, basic, valueTypeHandler, functionType);
		return TCppFunction(r.args, r.ret, abiString);
	}

	static function cppFunctionTypeOfArgsRetStack(stack:Array<T>, basic:BasicTypes, valueTypeHandler:ValueTypeHandler,
			functionType:T):{args:Array<Tcpp>, ret:Tcpp} {
		return switch follow(functionType) {
			case TFun(sig):
				/* Optional types are Dynamic if they norally could not be null */
				function cppArgTypeOf(a:{name:String, optional:Bool, type:T}):Tcpp {
					return if (a.optional) cppTypeOfNullStack(stack, basic, valueTypeHandler, a.type) else
						cppTypeOfStack(stack, basic, valueTypeHandler, a.type);
				}
				{args: sig.args.mapToArray(cppArgTypeOf), ret: cppTypeOfStack(stack, basic, valueTypeHandler, sig.ret)};
			case _:
				/* ? */
				{args: [TCppVoid], ret: TCppVoid};
		}
	}

	static function cppInstanceTypeStack(stack:Array<T>, basic:BasicTypes, klass:TClass, params:TParams, valueTypeHandler:ValueTypeHandler):Tcpp {
		function fallbackHandler():Tcpp {
			return if (isObjcClass(klass)) TCppObjC(klass) else if (hasClassFlag(klass, CInterface) && isNativeGenClass(klass))
				TCppNativePointer(klass) else if (hasClassFlag(klass, CInterface)) TCppInterface(klass) else
				if (hasClassFlag(klass, CExtern) && !isInternalClass(klass.clPath)) {
					if (isMarshallingNativeValueClass(klass)) {
						var tcppParams = params.mapToArray(function(p) return cppTypeOfStack(stack, basic, withStackValueType, p));
						TCppMarshalNativeType(ValueClass(klass, tcppParams), valueTypeHandler());
					} else if (isMarshallingNativePointer(klass)) {
						var tcppParams = params.mapToArray(function(p) return cppTypeOfStack(stack, basic, withStackValueType, p));
						TCppMarshalNativeType(Pointer(klass, tcppParams), valueTypeHandler());
					} else if (isMarshallingManagedClass(klass)) {
						var tcppParams = params.mapToArray(function(p) return cppTypeOfStack(stack, basic, valueTypeHandler, p));
						TCppMarshalManagedType(klass, tcppParams);
					} else {
						var tcppParams = params.mapToArray(function(p) return cppTypeOfStack(stack, basic, valueTypeHandler, p));
						TCppInst(klass, tcppParams);
					}
				} else {
					var tcppParams = params.mapToArray(function(p) return cppTypeOfStack(stack, basic, valueTypeHandler, p));
					TCppInst(klass, tcppParams);
				}
		}

		return cppTypeFromPathStack(stack, basic, klass.clPath, params, valueTypeHandler, fallbackHandler);
	}

	public static function cppTypeOf(basic:BasicTypes, valueTypeHandler:ValueTypeHandler, haxeType:T):Tcpp
		return cppTypeOfStack([], basic, valueTypeHandler, haxeType);

	public static function cppTypeFromPath(basic:BasicTypes, path:GlobalTypePath, params:TParams, valueTypeHandler:ValueTypeHandler,
			def:Void->Tcpp):Tcpp
		return cppTypeFromPathStack([], basic, path, params, valueTypeHandler, def);

	public static function cppTypeOfNull(basic:BasicTypes, valueTypeHandler:ValueTypeHandler, p:T):Tcpp
		return cppTypeOfNullStack([], basic, valueTypeHandler, p);

	public static function cppTypeOfPointer(basic:BasicTypes, valueTypeHandler:ValueTypeHandler, p:T):Tcpp
		return cppTypeOfPointerStack([], basic, valueTypeHandler, p);

	public static function cppTfunArgTypeOf(basic:BasicTypes, opt:Bool, valueTypeHandler:ValueTypeHandler, t:T):Tcpp
		return cppTfunArgTypeOfStack([], basic, opt, valueTypeHandler, t);

	public static function cppFunctionTypeOf(basic:BasicTypes, functionType:T, abi:T, valueTypeHandler:ValueTypeHandler):Tcpp
		return cppFunctionTypeOfStack([], basic, functionType, abi, valueTypeHandler);

	public static function cppFunctionTypeOfString(basic:BasicTypes, functionType:T, abiString:String, valueTypeHandler:ValueTypeHandler):Tcpp
		return cppFunctionTypeOfStringStack([], basic, functionType, abiString, valueTypeHandler);

	public static function cppFunctionTypeOfArgsRet(basic:BasicTypes, valueTypeHandler:ValueTypeHandler, functionType:T):{args:Array<Tcpp>, ret:Tcpp}
		return cppFunctionTypeOfArgsRetStack([], basic, valueTypeHandler, functionType);

	public static function cppInstanceType(basic:BasicTypes, klass:TClass, params:TParams, valueTypeHandler:ValueTypeHandler):Tcpp
		return cppInstanceTypeStack([], basic, klass, params, valueTypeHandler);

	public static function sanitiseStackOnlyType(pos:Pos, tcpp:Tcpp):Tcpp {
		return switch tcpp {
			case TCppMarshalNativeType(ValueClass(cls, _), Promoted) if (isStackOnlyMarshallingNativeValueClass(cls)):
				CppError.cppAbort(PromotedStackOnlyValueType, pos);
			case _:
				tcpp;
		}
	}

	public static function retypeTvar(basic:BasicTypes, tvar:TVar):TcppVar {
		var copyingVar = switch tvar.vKind {
			case VUser(TVOLocalVariable | TVOArgument | TVOForVariable | TVOCatchVariable) | VInlined | VInlinedConstructorVariable(_): true;
			case _: false;
		}
		var handler = if (copyingVar) {
			if (hasVarFlag(tvar, VCaptured)) withPromotedValueType else withStackValueType;
		} else withReferenceValueType;

		return {
			tcppvVar: tvar,
			tcppvType: sanitiseStackOnlyType(tvar.vPos, cppTypeOf(basic, handler, tvar.vType)),
			tcppvName: cppVarNameOf(tvar),
			tcppvDebugName: keywordRemap(tvar.vName)
		};
	}

	public static function retypeFuncArg(basic:BasicTypes, tvar:TVar, expr:Null<TExpr>):TcppVar {
		var handler = switch tvar.vKind {
			case VAbstractThis: withReferenceValueType;
			case _: if (hasVarFlag(tvar, VCaptured)) withPromotedValueType else withStackValueType;
		}

		return {
			tcppvVar: tvar,
			tcppvType: sanitiseStackOnlyType(tvar.vPos, cppFunArgTypeOf(basic, tvar, expr, handler)),
			tcppvName: cppVarNameOf(tvar),
			tcppvDebugName: keywordRemap(tvar.vName)
		};
	}

	public static function retypeArg(basic:BasicTypes, handler:ValueTypeHandler, a:{name:String, optional:Bool, type:T}):TcppTfunArg {
		return {
			tfaName: keywordRemap(a.name),
			tfaOptional: a.optional,
			tfaType: cppTypeOf(basic, handler, a.type)
		};
	}

	public static function expression(ctx:Context, requestType:Tcpp, functionArgs:Array<TcppArg>, functionType:Tcpp, expressionTree:TExpr,
			forInjection:Bool):TcppExpr {
		return new ExpressionRetyper(ctx, requestType, functionArgs, functionType, expressionTree, forInjection).run();
	}

	public static function getId(path:GlobalTypePath, ids:ObjectIds):{id:Int, ids:ObjectIds} {
		var className = classText(path);
		function needsNewId(id:Int):Bool {
			/* IDs less than 100 are reserved for hxcpp internal classes */
			/* If the map already contains this ID we also need a new one */
			return id < 100 || ObjectIds.collision(id, ids);
		}

		function makeId(seed:Int):Int {
			var id = CppStrings.genHash32(seed, className);
			return if (needsNewId(id)) makeId(seed + 100) else id;
		}

		return switch ObjectIds.findOpt(path, ids) {
			case null:
				var newId = makeId(0);
				{id: newId, ids: ObjectIds.add(path, newId, ids)};
			case existing:
				{id: existing, ids: ids};
		}
	}

	public static function nativeFieldNameRemap(field:TClassField):String {
		return switch Ast.getMetaString(field.cfMeta, Meta.Native) {
			case null: keywordRemap(field.cfName);
			case nativeImpl: keywordRemap(nativeImpl);
		}
	}

	// port: Option.get.
	static function optionGet<A>(o:Null<A>):A {
		if (o == null) throw new core.ds.InvalidArgument("Option.get");
		return o;
	}

	public static function tcppClassFromTclass(ctx:Context, ids:ObjectIds, slots:InterfaceSlots, classDef:TClass,
			classParams:TParams):{slots:InterfaceSlots, ids:ObjectIds, cls:TcppClass} {
		var scriptable = Gctx.defined(ctx.ctxCommon, Define.Scriptable);
		var basic = ctx.ctxCommon.basic;

		function createFunction(field:TClassField, func:TFunc):TcppClassFunction return {
			tcfField: field,
			tcfName: nativeFieldNameRemap(field),
			tcfArgs: func.tfArgs.mapToArray(function(a) return ({v: retypeFuncArg(basic, a.variable, a.defaultValue), o: a.defaultValue} : TcppArg)),
			tcfFunc: func,
			tcfIsVirtual: !Meta.has(Meta.NonVirtual, field.cfMeta),
			tcfIsReflective: reflective(classDef, field),
			tcfIsExternal: !isInternalMember(field.cfName),
			tcfIsOverriding: isOverride(field),
			tcfIsScriptable: scriptable,
			tcfReturn: cppTypeOf(basic, withStackValueType, func.tfType)
		};

		function createVariable(field:TClassField):TcppClassVariable {
			var tcpp = cppTypeOf(basic, withPromotedValueType, field.cfType);

			return {
				tcvField: field,
				tcvName: nativeFieldNameRemap(field),
				tcvType: tcpp,
				tcvDefault: null,
				tcvHasGetter: switch field.cfKind {
					case Var({vRead: AccCall | AccPrivateCall}): true;
					case _: false;
				},
				tcvIsStackonly: Meta.has(Meta.StackOnly, field.cfMeta),
				tcvIsReflective: reflective(classDef, field),
				tcvIsGcElement: CppContext.isGcElement(ctx, tcpp)
			};
		}

		function createDynamicFuncVariable(field:TClassField, func:TFunc):TcppClassVariable {
			var args = func.tfArgs.mapToArray(function(a) return retypeFuncArg(basic, a.variable, a.defaultValue)).map(function(v) return v.tcppvType);
			var ret = cppTypeOf(basic, withStackValueType, func.tfType);
			var tcpp = TCppCallable(args, ret);
			var f = field.clone();
			f.cfExpr = null;
			f.cfKind = Var({vRead: AccNormal, vWrite: AccNormal});

			return {
				tcvField: f,
				tcvName: nativeFieldNameRemap(field),
				tcvType: tcpp,
				tcvDefault: null,
				tcvHasGetter: false,
				tcvIsStackonly: false,
				tcvIsReflective: reflective(classDef, field),
				tcvIsGcElement: true
			};
		}

		function filterFunctions(isStatic:Bool, field:TClassField):Null<TcppClassFunction> {
			return if (shouldImplementField(field)) {
				switch [field.cfKind, field.cfExpr] {
					case [Method(MethNormal | MethInline), {eexpr: TFunction(func)}]:
						createFunction(field, func);
					case [Method(MethNormal), _] if (hasClassFieldFlag(field, CfAbstract)):
						/* We need to fetch the default values for abstract functions from the @:Value meta */
						var abstractTfunc = {
							var sig = switch followWithCoro(field.cfType) {
								case Coro(sig): context.Common.expandCoroType(basic, sig.args, sig.ret);
								case NotCoro(TFun(sig)): sig;
								case _: CppError.cppAbort(InternalError, field.cfPos);
							}
							var args = sig.args, ret = sig.ret;

							function getDefaultValue(name:String):Null<TExpr> {
								return try {
									var m = Meta.get(Meta.Value, field.cfMeta);
									switch m.exprs {
										case [{expr: EObjectDecl(decls)}]:
											var found:Null<ObjectField> = null;
											for (d in decls) if (d.key.name == name) {
												found = d;
												break;
											}
											if (found == null) throw NotFound.raise();
											core.Texpr.typeConstantValue(basic, found.expr);
										case _: null;
									}
								} catch (_:NotFound) null;
							}

							/* Generate a no op tfunc for our abstract */
							/* This allows it to go through the rest of the generator with no special cases */
							/* We can't implement abstract functions as pure virtual due to cppia needing to construct the class */
							function mapArg(a:{name:String, optional:Bool, type:T}) {
								return {variable: allocVar(VGenerated, a.name, a.type, nullPos), defaultValue: getDefaultValue(a.name)};
							}
							var expr:TExpr = switch follow(ret) {
								case TAbstract({aPath: {pack: [], name: "Void"}}, _):
									{eexpr: TReturn(null), etype: ret, epos: nullPos};
								case _:
									var zeroVal:TExpr = {eexpr: TConst(TInt(0)), etype: ret, epos: nullPos};
									{eexpr: TReturn(zeroVal), etype: ret, epos: nullPos};
							}

							({
								tfArgs: args.map(mapArg),
								tfType: ret,
								tfExpr: expr
							} : TFunc);
						}

						createFunction(field, abstractTfunc);
					case _:
						null;
				}
			} else null;
		}

		function filterDynamicFunctions(funcForStaticField:Bool, field:TClassField):Null<TcppClassFunction> {
			return if (shouldImplementField(field)) {
				switch [field.cfKind, field.cfExpr] {
					case [Method(MethDynamic), {eexpr: TFunction(func)}]:
						createFunction(field, func);
					/* static variables with a default function value get a dynamic function generated as the implementation */
					case [Var(_), {eexpr: TFunction(func)}] if (funcForStaticField):
						createFunction(field, func);
					case _:
						null;
				}
			} else null;
		}

		function filterVariables(field:TClassField):Null<TcppClassVariable> {
			return if (isPhysicalField(field)) {
				switch [field.cfKind, field.cfExpr] {
					case [Var(_), _]:
						switch follow(field.cfType) {
							case TInst(cls, _) if (CppMarshalling.isStackOnlyMarshallingNativeValueClass(cls)):
								CppError.cppAbort(PromotedStackOnlyValueType, field.cfPos);
							case _:
								createVariable(field);
						}
					/* Dynamic methods are implemented as a physical field holding a closure, an overriding one shares the field of its parent */
					case [Method(MethDynamic), {eexpr: TFunction(func)}] if (!isOverride(field)):
						createDynamicFuncVariable(field, func);
					/* Some (create_variable { field with cf_expr = None; cf_kind = Var ({ v_read = AccNormal; v_write = AccNormal }) }) */
					/* Below should cause abstracts which have functions with no implementation to be generated as a field */
					/* See Int32.hx as an example */
					case [Method(MethNormal | MethInline), null] if (!hasClassFieldFlag(field, CfAbstract)):
						createVariable(field);
					case _:
						null;
				}
			} else null;
		}

		function filterProperties(field:TClassField):Null<TcppClassVariable> {
			return switch field.cfKind {
				case Var(_) if (!isPhysicalVarField(field)):
					createVariable(field);
				case _:
					null;
			}
		}

		function filterMap<A, B>(f:A->Null<B>, l:Array<A>):Array<B> {
			var r = [];
			for (x in l) {
				var y = f(x);
				if (y != null) r.push(y);
			}
			return r;
		}

		var idr = getId(classDef.clPath, ids);
		var id = idr.id;
		var ids = idr.ids;

		var staticFunctions = filterMap(function(f) return filterFunctions(true, f), classDef.clOrderedStatics);

		var staticDynamicFunctions = filterMap(function(f) return filterDynamicFunctions(true, f), classDef.clOrderedStatics);

		var staticVariables = filterMap(filterVariables, classDef.clOrderedStatics.filter(function(field) return field.cfName != "__meta__"
			&& field.cfName != "__rtti"));

		var staticProperties = filterMap(filterProperties, classDef.clOrderedStatics.filter(function(field) return field.cfName != "__meta__"
			&& field.cfName != "__rtti"));

		var functions = filterMap(function(f) return filterFunctions(true, f), classDef.clOrderedFields);

		var dynamicFunctions = filterMap(function(f) return filterDynamicFunctions(false, f), classDef.clOrderedFields);

		var variables = filterMap(filterVariables, classDef.clOrderedFields);

		var properties = filterMap(filterProperties, classDef.clOrderedFields);

		var constructor = switch classDef.clConstructor {
			case null:
				null;
			case field = {cfExpr: {eexpr: TFunction(definition)}}:
				createFunction(field, definition);
			case _:
				null;
		}

		/* All interfaces (and sub-interfaces) implemented */
		function folder(acc:{slots:InterfaceSlots, haxe:PathMap<TcppInterface>, native:PathMap<TcppInterface>},
				i:ClassAndParams):{slots:InterfaceSlots, haxe:PathMap<TcppInterface>, native:PathMap<TcppInterface>} {
			var iface = i.cls;
			var r = tcppInterfaceFromTclass(ctx, acc.slots, iface);
			var acc = if (isNativeClass(iface)) {
				var a = {slots: r.slots, haxe: acc.haxe, native: acc.native.add(iface.clPath, r.iface)};
				for (x in iface.clImplements) a = folder(a, x);
				a;
			} else {
				var a = {slots: r.slots, haxe: acc.haxe.add(iface.clPath, r.iface), native: acc.native};
				for (x in iface.clImplements) a = folder(a, x);
				a;
			}

			return switch iface.clSuper {
				case null: acc;
				case sup: folder(acc, sup);
			}
		}

		var parentr = switch classDef.clSuper {
			case null:
				{slots: slots, ids: ids, parent: null};
			case {cls: cls} if (Meta.has(Meta.CppManagedType, cls.clMeta)):
				CppError.cppAbort(ExtendingManagedType, classDef.clPos);
			case {cls: cls, params: params}:
				var r = tcppClassFromTclass(ctx, ids, slots, cls, params);
				{slots: r.slots, ids: r.ids, parent: r.cls};
		}
		var slots:InterfaceSlots = parentr.slots;
		var ids:ObjectIds = parentr.ids;
		var parent:Null<TcppClass> = parentr.parent;
		var acc = {slots: slots, haxe: PathMap.empty(), native: PathMap.empty()};
		for (x in realInterfaces(classDef.clImplements)) acc = folder(acc, x);
		slots = acc.slots;
		var haxeImplementations = acc.haxe.bindings().map(function(b) return b.value);
		var nativeImplementations = acc.native.bindings().map(function(b) return b.value);

		var gcContainerType = {
			function typeCantBeNull(t:T):Bool return cppTypeOf(basic, withPromotedValueType, t).match(TCppScalar(_));

			function gcContainer(variables:Array<TcppClassVariable>, sup:Null<TcppClass>, v:TcppClassContainer):Null<TcppClassContainer> {
				return switch [Lambda.exists(variables, function(v) return !typeCantBeNull(v.tcvField.cfType)), sup] {
					case [true, _]: v;
					case [false, null]: null;
					case [false, sup]: gcContainer(sup.tclVariables, sup.tclSuper, Parent);
				}
			}

			gcContainer(variables, parent, Current);
		}

		/* Static functions can have their closure objects pre-allocated, do that in the boot section of the class */
		var wantsClosures = {
			function needsClosures(func:TcppClassFunction):Bool {
				return switch Ast.getMetaString(func.tcfField.cfMeta, Meta.Native) {
					case null if ((!func.tcfIsVirtual || !func.tcfIsOverriding) && func.tcfIsReflective):
						true;
					case null:
						false;
					case _:
						false;
				}
			}
			Lambda.exists(staticFunctions, needsClosures);
		}

		var flags = 0;
		if (scriptable && !classDef.clPrivate) flags = setTcppClassFlag(flags, Scriptable);
		if (canQuickAlloc(classDef)) flags = setTcppClassFlag(flags, QuickAlloc);
		if (hasGetMemberField(classDef)) flags = setTcppClassFlag(flags, MemberGet);
		if (hasSetMemberField(classDef)) flags = setTcppClassFlag(flags, MemberSet);
		if (hasGetStaticField(classDef)) flags = setTcppClassFlag(flags, StaticGet);
		if (hasSetStaticField(classDef)) flags = setTcppClassFlag(flags, StaticSet);
		if (hasGetFields(classDef)) flags = setTcppClassFlag(flags, GetFields);
		if (hasCompareField(classDef)) flags = setTcppClassFlag(flags, Compare);
		if (hasBootField(classDef) || wantsClosures) flags = setTcppClassFlag(flags, Boot);

		var metaField = Lambda.find(classDef.clOrderedStatics, function(field) return field.cfName == "__meta__");
		var metaExpr = metaField == null ? null : optionGet(metaField.cfExpr);
		var rttiField = Lambda.find(classDef.clOrderedStatics, function(field) return field.cfName == "__rtti");
		var rttiExpr = rttiField == null ? null : optionGet(rttiField.cfExpr);

		var cls:TcppClass = {
			tclClass: classDef,
			tclParams: classParams,
			tclId: id,
			tclName: className(classDef),
			tclFlags: flags,
			tclSuper: parent,
			tclContainer: gcContainerType,
			tclDebugLevel: if (Meta.has(Meta.NoDebug, classDef.clMeta) || Gctx.defined(ctx.ctxCommon, Define.NoDebug)) 0 else ctx.ctxDebugLevel,
			tclStaticVariables: staticVariables,
			tclStaticProperties: staticProperties,
			tclStaticFunctions: staticFunctions,
			tclStaticDynamicFunctions: staticDynamicFunctions,
			tclVariables: variables,
			tclProperties: properties,
			tclFunctions: functions,
			tclDynamicFunctions: dynamicFunctions,
			tclHaxeInterfaces: haxeImplementations,
			tclNativeInterfaces: nativeImplementations,
			tclConstructor: constructor,
			tclMeta: metaExpr,
			tclRtti: rttiExpr,
			tclInit: core.TOther.TClassTools.getClInit(classDef)
		};

		return {slots: slots, ids: ids, cls: cls};
	}

	public static function tcppInterfaceFromTclass(ctx:Context, slots:InterfaceSlots, classDef:TClass):{slots:InterfaceSlots, iface:TcppInterface} {
		var scriptable = Gctx.defined(ctx.ctxCommon, Define.Scriptable) && !classDef.clPrivate;
		var basic = ctx.ctxCommon.basic;

		function functionFilter(handler:ValueTypeHandler, acc:{slots:InterfaceSlots, fields:Array<TcppInterfaceFunction>},
				field:TClassField):{slots:InterfaceSlots, fields:Array<TcppInterfaceFunction>} {
			return switch [field.cfType, field.cfKind] {
				case [TFun(sig), Method(_)]:
					var slots = if (scriptable) InterfaceSlots.add(field.cfName, acc.slots) else acc.slots;
					var retyped:TcppInterfaceFunction = {
						iffField: field,
						iffName: nativeFieldNameRemap(field),
						iffArgs: sig.args.mapToArray(function(a) return retypeArg(basic, handler, a)),
						iffReturn: cppTypeOf(basic, handler, sig.ret),
						iffScriptSlot: InterfaceSlots.findOpt(field.cfName, slots)
					};
					{slots: slots, fields: [retyped].concat(acc.fields)};
				case _:
					acc;
			}
		}
		function variableFilter(field:TClassField):Bool {
			return switch field.cfKind {
				case Var(_) if (isPhysicalVarField(field)):
					switch follow(field.cfType) {
						case TInst(cls, _) if (CppMarshalling.isStackOnlyMarshallingNativeValueClass(cls)):
							CppError.cppAbort(PromotedStackOnlyValueType, field.cfPos);
						case _:
							true;
					}
				case _: false;
			}
		}

		var debugLevel = if (Meta.has(Meta.NoDebug, classDef.clMeta) || Gctx.defined(ctx.ctxCommon, Define.NoDebug)) 0 else ctx.ctxDebugLevel;
		var metaField = Lambda.find(classDef.clOrderedStatics, function(field) return field.cfName == "__meta__");
		var metaExpr = metaField == null ? null : optionGet(metaField.cfExpr);
		var rttiField = Lambda.find(classDef.clOrderedStatics, function(field) return field.cfName == "__rtti");
		var rttiExpr = rttiField == null ? null : optionGet(rttiField.cfExpr);
		var ext = switch classDef.clSuper {
			case null:
				{slots: slots, iface: null};
			case {cls: s}:
				tcppInterfaceFromTclass(ctx, slots, s);
		}
		var slots = ext.slots;
		var ext:Null<TcppInterface> = ext.iface;

		var acc = {slots: slots, fields: []};
		for (f in classDef.clOrderedFields) acc = functionFilter(withStackValueType, acc, f);
		var functions = acc.fields.copy();
		functions.reverse();

		var iface:TcppInterface = {
			ifClass: classDef,
			ifName: className(classDef),
			ifHash: CppStrings.genHash(0, joinClassPath(classDef.clPath, "::")),
			ifDebugLevel: debugLevel,
			ifFunctions: functions,
			ifVariables: classDef.clOrderedFields.filter(variableFilter),
			ifMeta: metaExpr,
			ifRtti: rttiExpr,
			ifExtends: ext,
			ifScriptable: scriptable
		};

		return {slots: acc.slots, iface: iface};
	}

	public static function tcppEnumFromTenum(ctx:Context, ids:ObjectIds, enumDef:TEnum):{ids:ObjectIds, enumDef:TcppEnum} {
		var basic = ctx.ctxCommon.basic;

		function sortConstructors(f1:TEnumField, f2:TEnumField):Int return f1.efIndex - f2.efIndex;

		var r = getId(enumDef.ePath, ids);
		var selfId = r.id, ids = r.ids;
		var strq = function(s) return CppStrings.strq(ctx.ctxCommon, s);
		function stackOnlyChecker(t:T):Bool {
			return switch follow(t) {
				case TInst(cls, _):
					CppMarshalling.isStackOnlyMarshallingNativeValueClass(cls);
				case _:
					false;
			}
		}
		function retypeArgs(t:T, pos:Pos):Null<Array<TcppTfunArg>> {
			return switch t {
				case TFun(sig) if (sig.args.exists(function(a) return stackOnlyChecker(a.type))):
					CppError.cppAbort(PromotedStackOnlyValueType, pos);
				case TFun(sig):
					sig.args.mapToArray(function(a) return retypeArg(basic, withPromotedValueType, a));
				case _:
					null;
			}
		}
		var constructors = listSort(sortConstructors, CppContext.pmapValues(enumDef.eConstrs)).map(function(f) return ({
			tefField: f,
			tefName: keywordRemap(f.efName),
			tefHash: strq(f.efName),
			tefArgs: retypeArgs(f.efType, f.efPos)
		} : TcppEnumField));
		var enumv:TcppEnum = {teEnum: enumDef, teId: selfId, teConstructors: constructors};

		return {ids: ids, enumDef: enumv};
	}
}

// port: the closures of `CppRetyper.expression`, sharing its arguments.
private class ExpressionRetyper {
	final ctx:Context;
	final requestType:Tcpp;
	final expressionTree:TExpr;
	final forCppia:Bool;
	final initialCtx:RetyperCtx;
	final basic:BasicTypes;

	public function new(ctx:Context, requestType:Tcpp, functionArgs:Array<TcppArg>, functionType:Tcpp, expressionTree:TExpr, forInjection:Bool) {
		this.ctx = ctx;
		this.requestType = requestType;
		this.expressionTree = expressionTree;
		this.basic = ctx.ctxCommon.basic;
		forCppia = Gctx.defined(ctx.ctxCommon, Define.Cppia);
		initialCtx = {
			closures: [],
			closureId: 0,
			injection: forInjection,
			undeclared: IntPMap.empty(),
			declarations: IntPMap.ofList(functionArgs.map(function(a) return {key: a.v.tcppvVar.vId, value: a.v})), /* '__trace' is at the top-level */
			usesThis: null,
			thisReal: if (ctx.ctxRealThisPtr) ThisReal else ThisDynamic,
			gcStack: false,
			functionReturnType: functionType,
			gotoId: 0,
			loopStack: []
		};
	}

	public function run():TcppExpr return retype(initialCtx, requestType, expressionTree).expr;

	/* Helper functions */
	function allocFileId(retyperCtx:RetyperCtx):{ctx:RetyperCtx, id:Int} {
		var c = retyperCtx.copy();
		c.gotoId = retyperCtx.gotoId + 1;
		return {ctx: c, id: retyperCtx.gotoId + 1};
	}

	function beginLoop(retyperCtx:RetyperCtx):{ctx:RetyperCtx, resolver:RetyperCtx->{ctx:RetyperCtx, id:Int}} {
		var newCtx = retyperCtx.copy();
		newCtx.gotoId = retyperCtx.gotoId + 1;
		newCtx.loopStack = [{id: retyperCtx.gotoId + 1, used: false}].concat(retyperCtx.loopStack);
		function resolver(retyperCtx:RetyperCtx):{ctx:RetyperCtx, id:Int} {
			return switch retyperCtx.loopStack {
				case []:
					core.Error.abort("Invalid inernal loop handling", expressionTree.epos);
				case l:
					var c = retyperCtx.copy();
					c.loopStack = l.slice(1);
					{ctx: c, id: if (l[0].used) l[0].id else -1};
			}
		}

		return {ctx: newCtx, resolver: resolver};
	}

	inline function cppTypeOf(handler:ValueTypeHandler, t:T):Tcpp return CppRetyper.cppTypeOf(basic, handler, t);

	function cppReturnType(haxeType:T):Tcpp {
		return switch followWithCoro(haxeType) {
			case Coro(sig): cppTypeOf(CppRetyper.withStackValueType, context.Common.expandCoroType(basic, sig.args, sig.ret).ret);
			case NotCoro(TFun(sig)): cppTypeOf(CppRetyper.withStackValueType, sig.ret);
			case _: TCppDynamic;
		}
	}

	function cppMemberReturnType(member:TClassField):Tcpp return cppReturnType(member.cfType);

	static function isCppObjcType(cpptype:Tcpp):Bool return cpptype.match(TCppObjC(_));

	static function cppIsRealArray(obj:TcppExpr):Bool {
		return switch obj.cpptype {
			case TCppScalarArray(_) | TCppObjectArray(_): true;
			case _: false;
		}
	}

	function toLvalue(value:TcppExpr):{lvalue:TcppLValue, gc:Bool} {
		return switch value.cppexpr {
			case CppVar(varloc = VarClosure(v)) if (CppContext.isGcElement(ctx, v.tcppvType)):
				{lvalue: CppVarRef(varloc), gc: true};
			case CppVar(varloc = VarThis(member, _)) if (CppContext.isGcElement(ctx, cppTypeOf(CppRetyper.withPromotedValueType, member.cfType))):
				{lvalue: CppVarRef(varloc), gc: true};
			case CppVar(varloc = VarInstance(obj, member, _, "->")) if (CppContext.isGcElement(ctx, cppTypeOf(CppRetyper.withPromotedValueType, member.cfType))):
				{lvalue: CppVarRef(varloc), gc: true};
			case CppVar(varloc):
				{lvalue: CppVarRef(varloc), gc: false};
			case CppArray(arrayloc):
				{
					lvalue: CppArrayRef(arrayloc),
					gc: switch arrayloc {
						case ArrayObject(arrayObj, index, _) if (CppContext.isGcElement(ctx, TCppDynamic)):
							true;
						case ArrayTyped(arrayObj, index, t) if (CppContext.isGcElement(ctx, t)): true;
						case _: false;
					}
				};
			case CppDynamicField(expr, name):
				{lvalue: CppDynamicRef(expr, name), gc: false};
			case CppTCast(cppExpr, _) | CppCast(cppExpr, _) | CppCastStatic(cppExpr, _) | CppCastObjC(cppExpr, _) | CppCastObjCBlock(cppExpr, _, _) |
				CppCastScalar(cppExpr, _):
				toLvalue(cppExpr);
			case CppCastVariant(cppExpr): toLvalue(cppExpr);
			case CppExtern(name, isGlobal):
				{lvalue: CppExternRef(name, isGlobal), gc: false};
			case _:
				core.Error.abort("Could not convert expression to l-value (" + sTcpp(value.cppexpr) + ")", value.cpppos);
		}
	}

	static function isArraySpliceCall(obj:TcppExpr, member:TClassField):Bool {
		return switch [obj.cpptype, member.cfName] {
			case [TCppScalarArray(_), "splice"] | [TCppObjectArray(_), "splice"]: true;
			case [_, _]: false;
		}
	}

	static function isMapPath(cls:TClass):Bool {
		return switch cls.clPath {
			case {pack: ["cpp"], name: "Int64Map"} | {pack: ["haxe", "ds"], name: "IntMap"} | {pack: ["haxe", "ds"], name: "StringMap"} |
				{pack: ["haxe", "ds"], name: "ObjectMap"}:
				true;
			case _: false;
		}
	}

	static function isMapGetCall(obj:TcppExpr, member:TClassField):Bool {
		return member.cfName == "get" && switch obj.cpptype {
			case TCppInst(cls, _) if (isMapPath(cls)): true;
			case _: false;
		}
	}

	static function isMapSetCall(obj:TcppExpr, member:TClassField):Bool {
		return member.cfName == "set" && switch obj.cpptype {
			case TCppInst(cls, _) if (isMapPath(cls)): true;
			case _: false;
		}
	}

	static function isArrayConcatCall(obj:TcppExpr, member:TClassField):Bool {
		return switch [obj.cpptype, member.cfName] {
			case [TCppScalarArray(_), "concat"] | [TCppObjectArray(_), "concat"]: true;
			case [_, _]: false;
		}
	}

	static function cppCanStaticCast(funcType:Tcpp, inferredType:Tcpp):Bool {
		return switch funcType {
			case TCppReference(_) | TCppStar(_) | TCppStruct(_) | TCppMarshalNativeType(_): false;
			case _:
				switch inferredType {
					case TCppInst(cls, _) if (isExternClass(cls)): false;
					case TCppEnum(e) if (isExternEnum(e)): false;
					case TCppInst(_) | TCppClass | TCppEnum(_) | TCppMarshalManagedType(_):
						tcppToString(funcType) != tcppToString(inferredType);
					case _: false;
				}
		}
	}

	static function cppIsTemplatedCall(member:TClassField):Bool return Meta.has(Meta.TemplatedCall, member.cfMeta);

	static function isComplexCompare(t:Tcpp):Bool {
		return switch t {
			case TCppScalar(_): false;
			case TCppString: false;
			case _: true;
		}
	}

	static function isPointerCompare(t:Tcpp):Bool {
		return switch t {
			case TCppObjectArray(_) | TCppScalarArray(_) | TCppDynamicArray | TCppClass | TCppEnum(_):
				true;
			case _: false;
		}
	}

	static function isInstanceCompare(t:Tcpp):Bool {
		return switch t {
			case TCppInterface(_) | TCppInst(_) | TCppMarshalManagedType(_): true;
			case _: false;
		}
	}

	static function cppAppendBlock(block:TcppExpr, expr:TcppExpr):TcppExpr {
		return switch block.cppexpr {
			case CppBlock(exprList, closures, gcStack):
				{cppexpr: CppBlock(exprList.concat([expr]), closures, gcStack), cpptype: block.cpptype, cpppos: block.cpppos};
			case _: core.Error.abort("Internal error appending expression", block.cpppos);
		}
	}

	static function constIntOf(expr:TExpr):Int {
		return switch expr.eexpr {
			case TConst(TInt(x)): x;
			case TConst(TBool(x)): x ? 1 : 0;
			case TParenthesis(e): constIntOf(e);
			case _: throw NotFound.raise();
		}
	}

	// port: OCaml (=) on tcpp values against constant constructors.
	static inline function isVoid(t:Tcpp):Bool return t.match(TCppVoid);

	/* Core Retyping */
	function retype(retyperCtx:RetyperCtx, returnType:Tcpp, expr:TExpr):{ctx:RetyperCtx, expr:TcppExpr} {
		inline function cppTypeOfWith(handler:ValueTypeHandler, t:T):Tcpp return this.cppTypeOf(handler, t);
		function cppTypeOf(t:T):Tcpp return this.cppTypeOf(CppRetyper.withReferenceValueType, t);
		function mkCppexpr(newExpr:TcppExprExpr, newType:Tcpp):TcppExpr return {cppexpr: newExpr, cpptype: newType, cpppos: expr.epos};
		function retypeFunctionArgs(retyperCtx:RetyperCtx, args:Vector<TExpr>, argTypes:Array<Tcpp>):{ctx:RetyperCtx, args:Array<TcppExpr>} {
			// port: ExtList.List.fold_left2 raises on lists of different lengths.
			if (args.length != argTypes.length) throw new core.ds.InvalidArgument("fold_left2");
			var c = retyperCtx;
			var acc = [];
			for (i in 0...args.length) {
				var r = retype(c, argTypes[i], args[i]);
				c = r.ctx;
				acc.push(r.expr);
			}
			return {ctx: c, args: acc};
		}
		function res(c:RetyperCtx, e:TcppExprExpr, t:Tcpp):{c:RetyperCtx, e:TcppExprExpr, t:Tcpp} return {c: c, e: e, t: t};
		function argTypesOf(args:Vector<TExpr>):Array<Tcpp> return args.mapToArray(function(a) return cppTypeOf(a.etype));

		var r:{c:RetyperCtx, e:TcppExprExpr, t:Tcpp} = switch expr.eexpr {
			case TEnumParameter(enumObj, enumField, enumIndex):
				var rr = retype(retyperCtx, TCppDynamic, enumObj);
				res(rr.ctx, CppEnumParameter(rr.expr, enumField, enumIndex), cppCastVariantTypeOf(cppTypeOf(getNthType(enumField, enumIndex))));
			case TEnumIndex(enumObj):
				var rr = retype(retyperCtx, TCppDynamic, enumObj);
				res(rr.ctx, CppEnumIndex(rr.expr), TCppScalar("int"));
			case TConst(TThis):
				var c = retyperCtx.copy();
				c.usesThis = retyperCtx.thisReal;
				res(c, CppThis(c.thisReal), if (c.thisReal == ThisDynamic) TCppDynamic else cppTypeOfWith(CppRetyper.withReferenceValueType, expr.etype));
			case TConst(TSuper):
				var c = retyperCtx.copy();
				c.usesThis = retyperCtx.thisReal;
				res(c, CppSuper(c.thisReal), if (c.thisReal == ThisDynamic) TCppDynamic else cppTypeOf(expr.etype));
			case TConst(TNull) if (isObjcType(expr.etype)): res(retyperCtx, CppNil, TCppNull);
			case TConst(x):
				switch x {
					case TInt(i): res(retyperCtx, CppInt(i), TCppScalar("int"));
					case TBool(b): res(retyperCtx, CppBool(b), TCppScalar("bool"));
					case TFloat(f): res(retyperCtx, CppFloat(core.Texpr.replaceSeparators(f, "")), TCppScalar("Float"));
					case TString(s): res(retyperCtx, CppString(s), TCppString);
					case _:
						/* TNull, TThis & TSuper should already be handled */
						/* We want to preserve the original type with a null marshal type as these may be handled differently in filtering */
						switch returnType {
							case TCppMarshalNativeType(_):
								res(retyperCtx, CppNull, returnType);
							case _:
								res(retyperCtx, CppNull, TCppNull);
						}
				}
			case TIdent("__global__"):
				/* functions/vars will appear to be members of the virtual global object */
				res(retyperCtx, CppClassOf({pack: [], name: ""}, false), TCppGlobal);
			case TLocal(tvar):
				switch retyperCtx.declarations.findOpt(tvar.vId) {
					case null:
						var newVar = CppRetyper.retypeTvar(basic, tvar);
						var newCtx = retyperCtx.copy();
						newCtx.undeclared = retyperCtx.undeclared.add(tvar.vId, newVar);
						if (hasVarFlag(tvar, VCaptured)) res(newCtx, CppVar(VarClosure(newVar)), newVar.tcppvType) else
							res(newCtx, CppExtern(newVar.tcppvVar.vName, false), newVar.tcppvType);
					case found:
						res(retyperCtx, CppVar(VarLocal(found)), found.tcppvType);
				}
			case TIdent(name): res(retyperCtx, CppExtern(name, false), returnType);
			case TBreak:
				if (forCppia) res(retyperCtx, CppBreak, TCppVoid) else switch retyperCtx.loopStack {
					case []:
						res(retyperCtx, CppBreak, TCppVoid);
					case l:
						var c = retyperCtx.copy();
						c.loopStack = [{id: l[0].id, used: true}].concat(l.slice(1));
						res(c, CppGoto(l[0].id), TCppVoid);
				}
			case TContinue: res(retyperCtx, CppContinue, TCppVoid);
			case TThrow(e1):
				var rr = retype(retyperCtx, TCppDynamic, e1);
				res(rr.ctx, CppThrow(rr.expr), TCppVoid);
			case TMeta(m, e) if (Meta.metaEq(Meta.Fixed, m.meta)):
				var rr = retype(retyperCtx, returnType, e);
				var cppType = rr.expr;
				switch cppType.cppexpr {
					case CppObjectDecl(def, false):
						res(rr.ctx, CppObjectDecl(def, true), cppType.cpptype);
					case _:
						res(rr.ctx, cppType.cppexpr, cppType.cpptype);
				}
			case TMeta(_, e) | TParenthesis(e):
				var rr = retype(retyperCtx, returnType, e);
				res(rr.ctx, rr.expr.cppexpr, rr.expr.cpptype);
			case TField(obj, FStatic({clPath: {pack: ["cpp", "marshal"], name: "Intrinsics"}}, {cfKind: Method(_)})):
				CppError.cppAbort(InvalidIntrinsicUse, expr.epos);
			/* Marshal type functions, need to be able to resolve type parameters to a concrete type, hance the special handling */
			case TField(_, FClosure(c, _)) if (c != null && (isMarshallingNativeValueClass(c.cls) || isMarshallingNativePointer(c.cls))):
				CppError.cppAbort(NativeMarshallingFunctionClosures, expr.epos);
			case TField(obj, FInstance(cls, params, member = {cfType: TFun(_)})) if (isMarshallingNativeValueClass(cls)
				|| isMarshallingNativePointer(cls)):
				switch applyParams(cls.clParams, params, expr.etype) {
					case t = TFun({args: args, ret: ret}):
						var templateTypes = {
							var fakedExprs = args.map(function(a) return a.type).map(function(t) return core.Texpr.Builder.makeNull(t, nullPos));
							var mapper = function(t) return applyParams(cls.clParams, params, t);

							switch CppRetyper.unifyCf2(mapper, cls, member, fakedExprs, core.Texpr.Builder.makeNull(ret, nullPos)) {
								case null:
									CppError.cppAbort(InternalError, expr.epos);
								case fcc:
									var ts = fcc.fcData.monos;
									function filter(idx:Int, t:T):Bool {
										return switch followLazyAndMono(t) {
											case TMono(_):
												CppError.cppAbort(UnresolvedTypeParameter(member.cfParams[idx].ttpName), expr.epos);
											case _:
												true;
										}
									}
									var kept = [];
									for (i in 0...ts.length) if (filter(i, ts[i])) kept.push(ts[i]);
									kept.map(cppTypeOf);
							}
						}

						var clazzType = CppRetyper.cppInstanceType(basic, cls, params, CppRetyper.withReferenceValueType);
						var rr = retype(retyperCtx, clazzType, obj);
						var retypedObj = rr.expr;
						var handler = if (isMarshallingNativeValueClass(cls)) CppRetyper.withStackValueType else CppRetyper.withPromotedValueType;
						var access = if (cppIsStructAccess(retypedObj.cpptype)) InstStruct else InstPtr(clazzType);
						var funcReturn = cppTypeOfWith(handler, ret);
						var exprType = cppTypeOfWith(handler, t);
						res(rr.ctx, CppFunction(FuncInstance(retypedObj, access, member, templateTypes), funcReturn), exprType);
					case _:
						CppError.cppAbort(InternalError, expr.epos);
				}
			case TField(_, FStatic(cls, member = {cfType: TFun(_)})) if (isMarshallingNativeValueClass(cls) || isMarshallingNativePointer(cls)):
				switch expr.etype {
					case t = TFun({args: args, ret: ret}):
						var templateTypes = {
							var fakedExprs = args.map(function(a) return a.type).map(function(t) return core.Texpr.Builder.makeNull(t, nullPos));
							var mapper = function(t:T) return t;

							switch CppRetyper.unifyCf2(mapper, cls, member, fakedExprs, core.Texpr.Builder.makeNull(ret, nullPos)) {
								case null:
									CppError.cppAbort(InternalError, expr.epos);
								case fcc:
									var ts = fcc.fcData.monos;
									function filter(idx:Int, t:T):Bool {
										return switch followLazyAndMono(t) {
											case TMono(_):
												CppError.cppAbort(UnresolvedTypeParameter(member.cfParams[idx].ttpName), expr.epos);
											case _:
												true;
										}
									}
									var kept = [];
									for (i in 0...ts.length) if (filter(i, ts[i])) kept.push(ts[i]);
									kept.map(cppTypeOf);
							}
						}

						var funcReturn = cppTypeOfWith(CppRetyper.withStackValueType, ret);
						var exprType = cppTypeOfWith(CppRetyper.withPromotedValueType, t);

						res(retyperCtx, CppFunction(FuncStatic(cls, false, member, templateTypes), funcReturn), exprType);
					case _:
						CppError.cppAbort(InternalError, expr.epos);
				}
			case TField(obj, field):
				retypeField(retyperCtx, returnType, expr, obj, field);
			/* magic intrinsic functions */
			case TCall({epos: epos, etype: TFun({args: [{type: TAbstract(_, [t])}], ret: r}),
				eexpr: TField(obj, FStatic({clPath: {pack: ["cpp", "marshal"], name: "Intrinsics"}}, {cfName: name = ("sizeof" | "alignof")}))},
				_):
				var ret = cppTypeOf(r);
				var arg = marshalTypeParameterToString(expr.epos, cppTypeOf(t));
				var str = '$name($arg)';

				res(retyperCtx, CppCode(str, []), ret);
			case TCall({eexpr: TIdent("__cpp__")}, argList):
				var rr:{c:RetyperCtx, e:TcppExprExpr} = switch argList {
					case [{eexpr: TConst(TString(code))}]: {c: retyperCtx, e: CppCode(code, [])};
					case _ if (argList.length > 0 && argList[0].eexpr.match(TConst(TString(_)))):
						var code = switch argList[0].eexpr {
							case TConst(TString(code)): code;
							case _: throw "unreachable";
						}
						var remaining = argList.slice(1);
						var curCtx = retyperCtx;
						var args = [];
						for (arg in remaining) {
							var r2 = retype(curCtx, TCppCode(cppTypeOf(arg.etype)), arg);
							curCtx = r2.ctx;
							args.push(r2.expr);
						}
						{c: curCtx, e: CppCode(code, args)};
					case _: core.Error.abort("__cpp__'s first argument must be a string", expr.epos);
				}
				res(rr.c, rr.e, TCppCode(cppTypeOf(expr.etype)));
			case TCall(func, args):
				retypeCall(retyperCtx, returnType, expr, func, args);
			case TNew(classDef, params, args):
				var constructorType = switch typing.OverloadResolution.maybeResolveConstructorOverload(classDef, params, args) {
					case null: core.Error.abort("Could not find overload", expr.epos);
					case r: r.field.cfType;
				}
				var argTypes = CppRetyper.cppFunctionTypeOfArgsRet(basic, CppRetyper.withStackValueType, constructorType).args;
				var rr = retypeFunctionArgs(retyperCtx, args, argTypes);
				var createdType = cppTypeOf(expr.etype);
				var gcStack = rr.ctx.gcStack || switch createdType {
					case TCppInst(t, _): !isNativeClass(t);
					case TCppMarshalManagedType(_): true;
					case _: false;
				}
				var c = rr.ctx.copy();
				c.gcStack = gcStack;
				res(c, CppCall(FuncNew(createdType), rr.args), createdType);
			case TFunction(func):
				/* TODO - this_dynamic ? */
				var newCtx = retyperCtx.copy();
				newCtx.declarations = IntPMap.ofList(func.tfArgs.mapToArray(function(a) return {
					key: a.variable.vId,
					value: CppRetyper.retypeFuncArg(basic, a.variable, a.defaultValue)
				}));
				newCtx.undeclared = IntPMap.empty();
				newCtx.thisReal = ThisFake;
				newCtx.usesThis = null;
				newCtx.functionReturnType = cppTypeOfWith(CppRetyper.withPromotedValueType, func.tfType);
				var rr = retype(newCtx, TCppVoid, mkBlock(func.tfExpr));
				var newCtx = rr.ctx;
				var cppExpr = rr.expr;

				var result:TcppClosure = {
					closeExpr: cppExpr,
					closeId: retyperCtx.closureId,
					closeUndeclared: newCtx.undeclared,
					closeType: newCtx.functionReturnType,
					closeArgs: func.tfArgs.mapToArray(function(a) return ({v: CppRetyper.retypeFuncArg(basic, a.variable, a.defaultValue), o: a.defaultValue} : TcppArg)),
					closeThis: newCtx.usesThis
				};
				var newUndeclared = retyperCtx.undeclared;
				for (b in newCtx.undeclared.bindings()) if (!retyperCtx.declarations.mem(b.key)) newUndeclared = newUndeclared.add(b.key, b.value);

				var c = retyperCtx.copy();
				c.closureId = retyperCtx.closureId + 1;
				c.closures = [result].concat(retyperCtx.closures);
				c.undeclared = newUndeclared;
				c.usesThis = if (newCtx.usesThis != null) retyperCtx.thisReal else retyperCtx.usesThis;

				var args = result.closeArgs.map(function(a) return a.v).map(function(v) return v.tcppvType);
				var ret = result.closeType;

				res(c, CppCallable(result), TCppCallable(args, ret));
			case TArray(e1, e2):
				var ar:{c:RetyperCtx, e:TcppExprExpr, t:Tcpp} = switch cppIsNativeArrayAccess(cppTypeOf(e1.etype)) {
					case true:
						var r1 = retype(retyperCtx, cppTypeOf(e1.etype), e1);
						var r2 = retype(r1.ctx, TCppScalar("int"), e2);
						res(r2.ctx, CppArray(ArrayRawPointer(r1.expr, r2.expr)), cppTypeOf(expr.etype));
					case false:
						var r1 = retype(retyperCtx, TCppDynamic, e1);
						var r2 = retype(r1.ctx, TCppScalar("int"), e2);
						var retypedObj = r1.expr, retypedIdx = r2.expr;
						var c = r2.ctx;
						switch retypedObj.cpptype {
							case TCppScalarArray(scalar):
								res(c, CppArray(ArrayTyped(retypedObj, retypedIdx, scalar)), scalar);
							case TCppPointer(_, elem):
								res(c, CppArray(ArrayPointer(retypedObj, retypedIdx)), elem);
							case TCppRawPointer(_, elem):
								res(c, CppArray(ArrayRawPointer(retypedObj, retypedIdx)), elem);
							case TCppObjectArray(TCppDynamic):
								res(c, CppArray(ArrayObject(retypedObj, retypedIdx, TCppDynamic)), TCppDynamic);
							/* | TCppObjectArray TCppMarshalNativeType (cls, params, _) as elem ->
								let inner = mk_cppexpr (CppArray (ArrayObject (retypedObj, retypedIdx, TCppDynamic))) elem in
								let reference = TCppMarshalNativeType (cls, params, Reference) in

								( retyper_ctx,
								CppCast (inner, reference),
								reference ) */
							case TCppObjectArray(elem):
								res(c, CppArray(ArrayObject(retypedObj, retypedIdx, elem)), elem);
							case TCppInst(klass, _) if (klass.clArrayAccess != null):
								res(c, CppArray(ArrayImplements(klass, retypedObj, retypedIdx)), cppTypeOf(expr.etype));
							case TCppDynamicArray:
								res(c, CppArray(ArrayVirtual(retypedObj, retypedIdx)), TCppDynamic);
							case _:
								res(c, CppArray(ArrayDynamic(retypedObj, retypedIdx)), TCppDynamic);
						}
				}
				var returnType = cppTypeOf(expr.etype);
				if (cppCanStaticCast(ar.t, returnType)) res(ar.c, CppCastStatic(mkCppexpr(ar.e, returnType), returnType), returnType) else
					res(ar.c, ar.e, ar.t);
			case TTypeExpr(moduleType):
				/* If we try and use the coreType / runtimeValue cpp.Int64 abstract with Class<T> then we get a class decl of the abstract */
				/* as that abstract has functions in its declaration */
				/* Intercept it and replace it with the path of the actual int64 type so the generated cpp is correct */
				var path:GlobalTypePath = switch moduleType {
					case TClassDecl({clPath: {pack: ["cpp", "_Int64"], name: "Int64_Impl_"}}):
						{pack: ["cpp"], name: "Int64"};
					case _: tPath(moduleType);
				}
				res(retyperCtx, CppClassOf(path, isNativeGenModule(moduleType)), TCppClass);
			case TBinop(op, left, right):
				retypeBinop(retyperCtx, expr, op, left, right);
			case TUnop(op, pre, e1):
				var targetType = switch op {
					case Not: TCppScalar("bool");
					case NegBits: TCppScalar("int");
					case _: cppTypeOf(e1.etype);
				}

				var rr = retype(retyperCtx, targetType, e1);
				var e1 = rr.expr;
				var c = rr.ctx;
				var reference = switch op {
					case Increment:
						var lv = toLvalue(e1);
						if (lv.gc) {
							c = c.copy();
							c.gcStack = true;
						}
						CppCrement(CppIncrement, pre, lv.lvalue);
					case Decrement:
						var lv = toLvalue(e1);
						if (lv.gc) {
							c = c.copy();
							c.gcStack = true;
						}
						CppCrement(CppDecrement, pre, lv.lvalue);
					case Neg: CppUnop(CppNeg, e1);
					case Not: CppUnop(CppNot, e1);
					case NegBits: CppUnop(CppNegBits, e1);
					case Spread: die("Unexpected spread operator", "cppRetyper.ml", expr.epos);
				}
				res(c, reference, cppTypeOf(expr.etype));
			case TWhile(e1, e2, flag):
				var r1 = retype(retyperCtx, TCppScalar("bool"), e1);
				var bl = beginLoop(r1.ctx);
				var r2 = retype(bl.ctx, TCppVoid, mkBlock(e2));
				var cl = bl.resolver(r2.ctx);
				res(cl.ctx, CppWhile(r1.expr, r2.expr, flag, cl.id), TCppVoid);
			case TArrayDecl(el):
				var elTypes = el.mapToArray(function(e) return cppTypeOf(e.etype));
				var rr = retypeFunctionArgs(retyperCtx, el, elTypes);
				res(rr.ctx, CppArrayDecl(rr.args), cppTypeOf(expr.etype));
			case TBlock(exprList):
				if (!isVoid(returnType) && !forCppia)
					printEndline("Value from a block not handled " + expr.epos.pfile + " " + Std.string(syntax.Lexer.getErrorLine(expr.epos)));

				var newCtx = retyperCtx.copy();
				newCtx.closures = [];
				newCtx.injection = false;
				var cppExprs = [];
				var remaining = exprList.length;
				for (e in exprList) {
					var targetType = if (retyperCtx.injection && remaining == 1) cppTypeOf(e.etype) else TCppVoid;
					var rr = retype(newCtx, targetType, e);
					newCtx = rr.ctx;
					cppExprs.push(rr.expr);
					remaining--;
				}

				/* Add back any undeclared variables */
				/* Needed for tracking variables captured by variables */
				var newUndeclared = retyperCtx.undeclared;
				for (b in newCtx.undeclared.bindings()) if (!retyperCtx.declarations.mem(b.key)) newUndeclared = newUndeclared.add(b.key, b.value);

				var closures = newCtx.closures.copy();
				closures.reverse();
				var c = newCtx.copy();
				c.declarations = retyperCtx.declarations;
				c.undeclared = newUndeclared;
				c.closures = retyperCtx.closures;
				res(c, CppBlock(cppExprs, closures, newCtx.gcStack), TCppVoid);
			case TObjectDecl([
				{key: {name: "fileName"}, expr: {eexpr: TConst(TString(file))}},
				{key: {name: "lineNumber"}, expr: {eexpr: TConst(TInt(line))}},
				{key: {name: "className"}, expr: {eexpr: TConst(TString(className))}},
				{key: {name: "methodName"}, expr: {eexpr: TConst(TString(meth))}}
			]):
				res(retyperCtx, CppPosition(file, line, className, meth), TCppDynamic);
			case TObjectDecl(el):
				var elExprs = el.map(function(f) return f.expr);
				var elNames = el.map(function(f) return f.key.name);

				var rr = retypeFunctionArgs(retyperCtx, elExprs, el.mapToArray(function(f) return cppTypeOf(f.expr.etype)));
				var joined = [for (i in 0...elNames.length) {name: elNames[i], e: rr.args[i]}];

				switch returnType {
					case TCppVoid: res(rr.ctx, CppObjectDecl(joined, false), TCppVoid);
					case _: res(rr.ctx, CppObjectDecl(joined, false), TCppDynamic);
				}
			case TVar(v, null) if (isMarshallingNativeValueClassTvar(v)):
				CppError.cppAbort(ValueTypeUndefined, expr.epos);
			/* Even with value semantics the compiler will sometimes generate temporary variables e.g. long function call chains. */
			/* In these cases the generated variables should be value types, not references, so we're not dealing with c++ const& temporaries. */
			/* So if the RHS of the generated variable is not a lvalue make sure we assign it as a value type, not reference. */
			/* We then need to store this in the retyper context so locals get the correct marshalling state for these special variables. */
			/* TODO : Could this be handled in the cppFilterValueType filter? */
			case TVar(v = {vKind: VGenerated}, eo) if (eo != null && isMarshallingNativeValueClassTvar(v) && !CppRetyper.isLvalueExpr(eo)):
				var newVar:TcppVar = {
					var handler = if (hasVarFlag(v, VCaptured)) CppRetyper.withPromotedValueType else CppRetyper.withStackValueType;
					{
						tcppvVar: v,
						tcppvType: cppTypeOfWith(handler, v.vType),
						tcppvName: cppVarNameOf(v),
						tcppvDebugName: keywordRemap(v.vName),
					};
				}
				var rr = retype(retyperCtx, newVar.tcppvType, eo);
				var c = rr.ctx.copy();
				c.declarations = rr.ctx.declarations.add(v.vId, newVar);
				res(c, CppVarDecl(newVar, rr.expr), newVar.tcppvType);
			case TVar(v, eo):
				var newVar = CppRetyper.retypeTvar(basic, v);
				var c = retyperCtx;
				var init:Null<TcppExpr> = switch eo {
					case null: null;
					case e:
						var rr = retype(retyperCtx, newVar.tcppvType, e);
						c = rr.ctx;
						rr.expr;
				}
				var c2 = c.copy();
				c2.declarations = c.declarations.add(v.vId, newVar);
				res(c2, CppVarDecl(newVar, init), newVar.tcppvType);
			case TIf(ec, e1, e2):
				var rc = retype(retyperCtx, TCppScalar("bool"), ec);
				var blockify = if (!isVoid(returnType)) function(e:TExpr) return e else mkBlock;
				var r1 = retype(rc.ctx, returnType, blockify(e1));
				var c = r1.ctx;
				var e2r:Null<TcppExpr> = switch e2 {
					case null: null;
					case e:
						var r2 = retype(c, returnType, blockify(e));
						c = r2.ctx;
						r2.expr;
				}
				res(c, CppIf(rc.expr, r1.expr, e2r), if (isVoid(returnType)) TCppVoid else cppTypeOf(expr.etype));
			/* Switch internal return - wrap whole thing in block  */
			case TSwitch({switchSubject: condition, switchCases: cases, switchDefault: def}):
				if (!isVoid(returnType)) core.Error.abort("Value from a switch not handled", expr.epos);

				var conditionType = cppTypeOf(condition.etype);
				var rc = retype(retyperCtx, conditionType, condition);
				var condition = rc.expr;
				var c = rc.ctx;
				var cppDef:Null<TcppExpr> = switch def {
					case null: null;
					case e:
						var rd = retype(c, TCppVoid, mkBlock(e));
						c = rd.ctx;
						rd.expr;
				}
				if (forCppia) {
					var curCtx = c;
					var acc = [];
					for (sc in cases) {
						var rb = retype(curCtx, TCppVoid, mkBlock(sc.caseExpr));
						var newCtx = rb.ctx;
						var blocks = [];
						for (t in sc.casePatterns) {
							var rp = retype(newCtx, conditionType, t);
							newCtx = rp.ctx;
							blocks.push(rp.expr);
						}
						curCtx = newCtx;
						acc.push({values: blocks, e: rb.expr});
					}
					res(curCtx, CppSwitch(condition, conditionType, acc, cppDef, -1), TCppVoid);
				} else {
					try {
						switch conditionType {
							case TCppScalar("int") | TCppScalar("bool"):
							case _: throw NotFound.raise();
						}
						var curCtx = c;
						var acc = [];
						for (sc in cases) {
							var rb = retype(curCtx, TCppVoid, mkBlock(sc.caseExpr));
							curCtx = rb.ctx;
							acc.push({values: sc.casePatterns.mapToArray(constIntOf), e: rb.expr});
						}
						res(curCtx, CppIntSwitch(condition, acc, cppDef), TCppVoid);
					} catch (_:NotFound) {
						var al = allocFileId(c);
						var label = al.id;
						/* do something better maybe ... */
						var curCtx = al.ctx;
						var acc = [];
						for (sc in cases) {
							var rb = retype(curCtx, TCppVoid, mkBlock(sc.caseExpr));
							var newCtx = rb.ctx;
							var gotoExpr:TcppExpr = {
								cppexpr: CppGoto(label),
								cpptype: TCppVoid,
								cpppos: sc.caseExpr.epos
							};
							var cppBlock = cppAppendBlock(rb.expr, gotoExpr);
							var blocks = [];
							for (t in sc.casePatterns) {
								var rp = retype(newCtx, conditionType, t);
								newCtx = rp.ctx;
								blocks.push(rp.expr);
							}
							curCtx = newCtx;
							acc.push({values: blocks, e: cppBlock});
						}
						res(curCtx, CppSwitch(condition, conditionType, acc, cppDef, label), TCppVoid);
					}
				}
			case TTry(tryBlock, catches):
				/* TTry internal return - wrap whole thing in block ? */
				if (!isVoid(returnType)) core.Error.abort("Value from a try-block not handled", expr.epos);
				var rb = retype(retyperCtx, TCppVoid, tryBlock);
				var c = rb.ctx;
				var cppCatches = [];
				for (ctch in catches) {
					var tvar = ctch.variable, catchBlock = ctch.expr;
					var retypedTvar = CppRetyper.retypeTvar(basic, tvar);
					var c1 = c.copy();
					c1.declarations = c.declarations.add(tvar.vId, retypedTvar);
					var rc = retype(c1, TCppVoid, catchBlock);
					var c2 = rc.ctx.copy();
					c2.declarations = rc.ctx.declarations.remove(tvar.vId);
					c = c2;
					cppCatches.push({v: retypedTvar, e: rc.expr});
				}
				res(c, CppTry(rb.expr, cppCatches), TCppVoid);
			case TReturn(eo):
				var c = retyperCtx;
				var e:Null<TcppExpr> = switch eo {
					case null: null;
					case e:
						var rr = retype(retyperCtx, retyperCtx.functionReturnType, e);
						c = rr.ctx;
						rr.expr;
				}
				res(c, CppReturn(e), TCppVoid);
			case TCast(base, null):
				var returnType = cppTypeOfWith(CppRetyper.withReferenceValueType, expr.etype);
				var rr = retype(retyperCtx, returnType, base);
				var baseCpp = rr.expr;
				var c = rr.ctx;
				var baseStr = tcppToString(baseCpp.cpptype);
				var returnStr = tcppToString(returnType);
				if (baseStr == returnStr) res(c, baseCpp.cppexpr, baseCpp.cpptype /* nothing to do */) else switch returnType {
					case TCppMarshalNativeType(_):
						res(c, baseCpp.cppexpr, baseCpp.cpptype /* use autocasting rules */);
					case TCppObjC(k): res(c, CppCastObjC(baseCpp, k), returnType);
					case TCppPointer(_, _) | TCppRawPointer(_, _) | TCppStar(_) | TCppMarshalManagedType(_) | TCppInst(_):
						res(c, CppCast(baseCpp, returnType), returnType);
					case TCppString: res(c, CppCastScalar(baseCpp, "::String"), returnType);
					case TCppCode(t) if (baseStr != tcppToString(t)):
						res(c, CppCast(baseCpp, t), t);
					case TCppNativePointer(klass): res(c, CppCastNative(baseCpp), returnType);
					case TCppObjCBlock(args, ret):
						res(c, CppCastObjCBlock(baseCpp, args, ret), returnType);
					case TCppProtocol(p): res(c, CppCastProtocol(baseCpp, p), returnType);
					case TCppDynamic if (baseCpp.cpptype.match(TCppClass)):
						res(c, CppCast(baseCpp, TCppDynamic), TCppDynamic);
					case TCppScalar(_) if (baseCpp.cpptype.match(TCppNull)):
						res(c, CppCast(baseCpp, returnType), returnType);
					case _: res(c, baseCpp.cppexpr, baseCpp.cpptype /* use autocasting rules */);
				}
			case TCast(base, t):
				var rr = retype(retyperCtx, cppTypeOf(base.etype), base);
				var baseCpp = rr.expr;
				var c = rr.ctx;
				var baseStr = tcppToString(baseCpp.cpptype);
				var defaultReturnType = if (returnType.match(TCppUnchanged)) cppTypeOf(expr.etype) else returnType;
				var returnType = CppRetyper.cppTypeFromPath(basic, tPath(t), vector(), CppRetyper.withReferenceValueType, function() return defaultReturnType);
				var returnStr = tcppToString(returnType);

				if (baseStr == returnStr) res(c, baseCpp.cppexpr, baseCpp.cpptype /* nothing to do */) else switch returnType {
					case TCppNativePointer(klass):
						res(c, CppCastNative(baseCpp), returnType);
					case TCppVoid:
						res(c, CppTCast(baseCpp, cppTypeOf(expr.etype)), returnType);
					case TCppDynamic:
						res(c, baseCpp.cppexpr, baseCpp.cpptype);
					case _:
						res(c, CppTCast(baseCpp, returnType), returnType);
				}
		}

		/* Filter order is important */
		/* first thing we want to do is determine construction as autocast will then insert casts which can confuse things */
		var e = mkCppexpr(r.e, r.t);
		e = CppFilterValueType.filterDetermineConstruction(returnType, e);
		e = CppFilterAutoCast.autocastFilter(forCppia, returnType, e);
		e = CppFilterValueType.filterValueEnumCasting(returnType, e);
		e = CppFilterValueType.filterAddBoxedPointerConstruction(returnType, e);
		return {ctx: r.c, expr: e};
	}

	function retypeField(retyperCtx:RetyperCtx, returnType:Tcpp, expr:TExpr, obj:TExpr, field:TFieldAccess):{c:RetyperCtx, e:TcppExprExpr, t:Tcpp} {
		inline function cppTypeOfWith(handler:ValueTypeHandler, t:T):Tcpp return this.cppTypeOf(handler, t);
		function cppTypeOf(t:T):Tcpp return this.cppTypeOf(CppRetyper.withReferenceValueType, t);
		function mkCppexpr(newExpr:TcppExprExpr, newType:Tcpp):TcppExpr return {cppexpr: newExpr, cpptype: newType, cpppos: expr.epos};
		function res(c:RetyperCtx, e:TcppExprExpr, t:Tcpp):{c:RetyperCtx, e:TcppExprExpr, t:Tcpp} return {c: c, e: e, t: t};

		function instanceField(clazz:TClass, params:TParams, member:TClassField) {
			var funcReturn = cppMemberReturnType(member);
			var clazzType = CppRetyper.cppInstanceType(basic, clazz, params, CppRetyper.withReferenceValueType);
			var rr = retype(retyperCtx, clazzType, obj);
			var retyperCtx = rr.ctx;
			var retypedObj = rr.expr;
			/* Value types in haxe classes are always promoted, with value type externs treat them as stack types so the auto casting deals with conversion */
			var handler = if (isMarshallingNativeValueClass(clazz)) CppRetyper.withStackValueType else CppRetyper.withPromotedValueType;
			var exprType = cppTypeOfWith(handler, member.cfType);
			var isObjc = isCppObjcType(retypedObj.cpptype);

			return if (retypedObj.cpptype.match(TCppNull)) res(retyperCtx, CppNullAccess, TCppDynamic) else
				if (retypedObj.cpptype.match(TCppDynamic) && !hasClassFlag(clazz, CInterface)) {
					if (isInternalMember(member.cfName)) res(retyperCtx, CppFunction(FuncInstance(retypedObj, InstPtr(clazzType), member, []), funcReturn), exprType) else
						res(retyperCtx, CppDynamicField(retypedObj, member.cfName), TCppVariant(exprType));
				} else if (cppIsStructAccess(retypedObj.cpptype)) {
					switch retypedObj.cppexpr {
						case CppThis(ThisReal):
							res(retyperCtx, CppVar(VarThis(member, retypedObj.cpptype)), exprType);
						case CppSuper(thisKind):
							res(retyperCtx, CppFunction(FuncSuper(thisKind, retypedObj.cpptype, member), funcReturn), exprType);
						case _:
							if (isVarField(member)) res(retyperCtx, CppVar(VarInstance(retypedObj, member, tcppToString(clazzType), ".")), exprType) else
								res(retyperCtx, CppFunction(FuncInstance(retypedObj, InstStruct, member, []), funcReturn), exprType);
					}
				} else if (isVarField(member)) {
					var exprType = switch [retypedObj.cpptype, exprType] {
						case [TCppPointer(_, t), TCppDynamic] | [TCppRawPointer(_, t), TCppDynamic /* the 'type parameter' will show up as Dynamic */]:
							t;
						case _: exprType;
					}

					switch retypedObj.cppexpr {
						case CppThis(ThisReal):
							res(retyperCtx, CppVar(VarThis(member, retypedObj.cpptype)), exprType);
						case _:
							switch [retypedObj.cpptype, member.cfName] {
								/* Special variable remapping ... */
								case [TCppDynamicArray, "length"] if (!forCppia):
									res(retyperCtx, CppCall(FuncInternal(retypedObj, "get_length", "->"), []), exprType);
								case [TCppInterface(_), _] | [TCppDynamic, _]:
									res(retyperCtx, CppDynamicField(retypedObj, member.cfName), TCppVariant(exprType));
								case [TCppObjC(_), _]:
									res(retyperCtx, CppVar(VarInstance(retypedObj, member, tcppToString(clazzType), ".")), exprType);
								case _:
									var op = if (cppIsStructAccess(retypedObj.cpptype) || retypedObj.cpptype.match(TCppString)) "." else "->";
									res(retyperCtx, CppVar(VarInstance(retypedObj, member, tcppToString(clazzType), op)), exprType);
							}
					}
				} else if (hasClassFlag(clazz, CInterface) && !isObjc /* Use instance call for objc interfaces */) {
					res(retyperCtx, CppFunction(FuncInterface(retypedObj, clazz, member), funcReturn), exprType);
				} else {
					var isArrayObj = switch retypedObj.cpptype {
						case TCppDynamicArray | TCppObjectArray(_) | TCppScalarArray(_):
							true;
						case _:
							false;
					}
					/* Special array return values */
					var funcReturn = if (isArrayObj) {
						switch member.cfName {
							case "map":
								switch expr.etype {
									case TFun(sig):
										cppTypeOfWith(handler, sig.ret);
									case _:
										CppError.cppAbort(InternalError, member.cfPos);
								}
							case "splice" | "slice" | "concat" | "copy" | "filter":
								retypedObj.cpptype;
							case _:
								funcReturn;
						}
					} else switch [retypedObj.cpptype, funcReturn] {
						case [TCppPointer(_, t), TCppDynamic] | [TCppRawPointer(_, t), TCppDynamic /* the 'type parameter' will show up as Dynamic */]:
							t;
						case _: funcReturn;
					}
					switch retypedObj.cppexpr {
						case CppThis(ThisReal):
							res(retyperCtx, CppFunction(FuncThis(member, retypedObj.cpptype), funcReturn), exprType);
						case CppSuper(thisKind):
							res(retyperCtx, CppFunction(FuncSuper(thisKind, retypedObj.cpptype, member), funcReturn), exprType);
						case _:
							res(retyperCtx, CppFunction(FuncInstance(retypedObj, (if (isObjc) InstObjC else InstPtr(clazzType)), member, []), funcReturn),
								exprType);
					}
				}
		}

		function anonField(field:TClassField) {
			var rr = retype(retyperCtx, TCppDynamic, obj);
			var retyperCtx = rr.ctx;
			var obj = rr.expr;
			var fieldName = field.cfName;
			return if (obj.cpptype.match(TCppGlobal)) res(retyperCtx, CppExtern(fieldName, true), cppTypeOf(expr.etype)) else
				if (obj.cpptype.match(TCppNull)) res(retyperCtx, CppNullAccess, TCppDynamic) else if (isInternalMember(fieldName)) {
					var cppType = cppReturnType(expr.etype);
					if (obj.cpptype.match(TCppString)) res(retyperCtx, CppFunction(FuncInternal(obj, fieldName, "."), cppType), cppType) else
						res(retyperCtx, CppFunction(FuncInternal(obj, fieldName, "->"), cppType), cppType);
				} else res(retyperCtx, CppDynamicField(obj, field.cfName), TCppVariant(null));
		}

		return switch field {
			// port: tested before the `FClosure (Some _)` case below (null-safe structure patterns); the cases do not overlap.
			case FClosure(null, field):
				anonField(field);
			case FInstance(clazz, params, member) | FClosure({cls: clazz, params: params}, member):
				instanceField(clazz, params, member);
			case FStatic(_, member = {cfName: "nativeFromStaticFunction"}):
				var funcReturn = cppMemberReturnType(member);
				var exprType = cppTypeOf(member.cfType);
				res(retyperCtx, CppFunction(FuncFromStaticFunction, funcReturn), exprType);
			case FStatic({clKind: KAbstractImpl(abs)}, member) if (isMarshallingNativeEnum(abs)):
				var exprType = cppTypeOfWith(CppRetyper.withPromotedValueType, member.cfType);
				var enumName = '${getNativeMarshalledType(ValueEnum(abs))}::${member.cfName}';

				res(retyperCtx, CppCall((FuncNew(exprType)), [mkCppexpr(CppExtern(enumName, false), exprType)]), exprType);
			case FStatic(clazz, member):
				var exprType = cppTypeOfWith(CppRetyper.withPromotedValueType, member.cfType);
				var objC = isObjcClass(clazz);
				if (isVarField(member)) res(retyperCtx, CppVar(VarStatic(clazz, objC, member)), exprType) else
					res(retyperCtx, CppFunction(FuncStatic(clazz, objC, member, []), cppMemberReturnType(member)), exprType);
			case FAnon(field):
				anonField(field);
			case FDynamic(fieldName):
				var rr = retype(retyperCtx, TCppDynamic, obj);
				var retyperCtx = rr.ctx;
				var obj = rr.expr;
				if (obj.cpptype.match(TCppNull)) res(retyperCtx, CppNullAccess, TCppDynamic) else
					if (fieldName == "cca" && obj.cpptype.match(TCppString)) res(retyperCtx, CppFunction(FuncInternal(obj, "cca", "."), TCppScalar("int")), TCppDynamic) else
					if (fieldName == "__s" && obj.cpptype.match(TCppString)) res(retyperCtx, CppVar(VarInternal(obj, ".", "utf8_str()")),
						TCppRawPointer("const ", TCppScalar("char"))) else if (fieldName == "__Index") res(retyperCtx, CppEnumIndex(obj), TCppScalar("int")) else
					if (isInternalMember(fieldName) || cppIsRealArray(obj)) {
						var cppType = cppReturnType(expr.etype);
						if (obj.cpptype.match(TCppString)) res(retyperCtx, CppFunction(FuncInternal(obj, fieldName, "."), cppType), cppType) else
							res(retyperCtx, CppFunction(FuncInternal(obj, fieldName, "->"), cppType), cppType);
					} else if (obj.cpptype.match(TCppGlobal)) res(retyperCtx, CppExtern(fieldName, true), cppTypeOf(expr.etype)) else
						if (obj.cpptype.match(TCppClass)) {
							switch obj.cppexpr {
								case CppClassOf(path, _):
									res(retyperCtx, CppExtern(joinClassPathRemap(path, "::") + "_obj::" + fieldName, true), cppTypeOf(expr.etype));
								case _:
									res(retyperCtx, CppVar(VarInternal(obj, "->", fieldName)), cppTypeOf(expr.etype));
							}
						} else res(retyperCtx, CppDynamicField(obj, fieldName), TCppVariant(null));
			case FEnum(enumDef, enumField):
				res(retyperCtx, CppEnumField(enumDef, enumField), TCppEnum(enumDef));
		}
	}

	function retypeCall(retyperCtx:RetyperCtx, returnType:Tcpp, expr:TExpr, func:TExpr, args:Vector<TExpr>):{c:RetyperCtx, e:TcppExprExpr, t:Tcpp} {
		function cppTypeOf(t:T):Tcpp return this.cppTypeOf(CppRetyper.withReferenceValueType, t);
		function mkCppexpr(newExpr:TcppExprExpr, newType:Tcpp):TcppExpr return {cppexpr: newExpr, cpptype: newType, cpppos: expr.epos};
		function res(c:RetyperCtx, e:TcppExprExpr, t:Tcpp):{c:RetyperCtx, e:TcppExprExpr, t:Tcpp} return {c: c, e: e, t: t};
		function retypeFunctionArgs(retyperCtx:RetyperCtx, args:Vector<TExpr>, argTypes:Array<Tcpp>):{ctx:RetyperCtx, args:Array<TcppExpr>} {
			// port: ExtList.List.fold_left2 raises on lists of different lengths.
			if (args.length != argTypes.length) throw new core.ds.InvalidArgument("fold_left2");
			var c = retyperCtx;
			var acc = [];
			for (i in 0...args.length) {
				var r = retype(c, argTypes[i], args[i]);
				c = r.ctx;
				acc.push(r.expr);
			}
			return {ctx: c, args: acc};
		}
		function argTypesOf(args:Vector<TExpr>):Array<Tcpp> return args.mapToArray(function(a) return cppTypeOf(a.etype));
		function withName(member:TClassField, name:String):TClassField {
			var m = member.clone();
			m.cfName = name;
			return m;
		}

		var rf = retype(retyperCtx, TCppUnchanged, func);
		var retyperCtx = rf.ctx;
		var retypedFunc = rf.expr;

		return switch retypedFunc.cpptype {
			case TCppNull: res(retyperCtx, CppNullAccess, TCppDynamic);
			case TCppFunction(argTypes, retType, _):
				var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
				res(ra.ctx, CppCall(FuncExpression(retypedFunc), ra.args), retType);
			case TCppObjCBlock(argTypes, retType):
				var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
				res(ra.ctx, CppCall(FuncExpression(retypedFunc), ra.args), retType);
			/* If the return type is variant of a callable make sure it gets property retyped as a callable */
			/* Otherwise dynamic calling will occur through the variant */
			// port: TCppVariant None is excluded explicitly (null-safe enum patterns).
			case TCppVariant(v) if (v == null):
				retypeCallDefault(retyperCtx, returnType, expr, func, args, retypedFunc);
			case TCppVariant(TCppCallable(argumentTypes, returnType)):
				var ra = retypeFunctionArgs(retyperCtx, args, argumentTypes);
				var rc = retype(ra.ctx, TCppCallable(argumentTypes, returnType), func);
				res(rc.ctx, CppCall(FuncExpression(rc.expr), ra.args), returnType);
			case _:
				retypeCallDefault(retyperCtx, returnType, expr, func, args, retypedFunc);
		}
	}

	function retypeCallDefault(retyperCtx:RetyperCtx, returnType:Tcpp, expr:TExpr, func:TExpr, args:Vector<TExpr>,
			retypedFunc:TcppExpr):{c:RetyperCtx, e:TcppExprExpr, t:Tcpp} {
		function cppTypeOf(t:T):Tcpp return this.cppTypeOf(CppRetyper.withReferenceValueType, t);
		function mkCppexpr(newExpr:TcppExprExpr, newType:Tcpp):TcppExpr return {cppexpr: newExpr, cpptype: newType, cpppos: expr.epos};
		function res(c:RetyperCtx, e:TcppExprExpr, t:Tcpp):{c:RetyperCtx, e:TcppExprExpr, t:Tcpp} return {c: c, e: e, t: t};
		function retypeFunctionArgs(retyperCtx:RetyperCtx, args:Vector<TExpr>, argTypes:Array<Tcpp>):{ctx:RetyperCtx, args:Array<TcppExpr>} {
			// port: ExtList.List.fold_left2 raises on lists of different lengths.
			if (args.length != argTypes.length) throw new core.ds.InvalidArgument("fold_left2");
			var c = retyperCtx;
			var acc = [];
			for (i in 0...args.length) {
				var r = retype(c, argTypes[i], args[i]);
				c = r.ctx;
				acc.push(r.expr);
			}
			return {ctx: c, args: acc};
		}
		function argTypesOf(args:Vector<TExpr>):Array<Tcpp> return args.mapToArray(function(a) return cppTypeOf(a.etype));
		function withName(member:TClassField, name:String):TClassField {
			var m = member.clone();
			m.cfName = name;
			return m;
		}
			var cppType = cppTypeOf(expr.etype);
			return switch retypedFunc.cppexpr {
				case CppFunction(FuncFromStaticFunction, returnType):
					var argTypes = args.mapToArray(function(a) return cppTypeOf(a.etype));
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					switch ra.args {
						case [{cppexpr: CppFunction(FuncStatic(clazz, false, member, []), funcReturn)}]:
							res(ra.ctx, CppFunctionAddress(clazz, member), funcReturn);
						case _:
							core.Error.abort("cpp.Function.fromStaticFunction must be called on static function", expr.epos);
					}
				case CppEnumIndex(_):
					/* Not actually a TCall...*/
					res(retyperCtx, retypedFunc.cppexpr, retypedFunc.cpptype);
				case CppFunction(FuncInstance(obj, InstPtr(tcpp), member, templateParams), _) if ((!forCppia) && isVoid(returnType)
					&& isArraySpliceCall(obj, member)):
					var argTypes = argTypesOf(args);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					res(ra.ctx, CppCall(FuncInstance(obj, InstPtr(tcpp), withName(member, "removeRange"), templateParams), ra.args), TCppVoid);
				case CppFunction(FuncInstance(obj, InstPtr(tcpp), member, templateParams), _) if (isArrayConcatCall(obj, member)):
					var argTypes = args.mapToArray(function(_) return obj.cpptype);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					res(ra.ctx, CppCall(FuncInstance(obj, InstPtr(tcpp), member, templateParams), ra.args), returnType);
				case CppFunction(FuncStatic(obj, false, member, _), _) if (member.cfName == "::hx::AddressOf"):
					var ra = retype(retyperCtx, TCppUnchanged, listHd(args));
					var arg = ra.expr;
					var rawType = switch arg.cpptype {
						case TCppReference(x): x;
						case x: x;
					}
					res(ra.ctx, CppAddressOf(arg), TCppRawPointer("", rawType));
				case CppFunction(FuncStatic(obj, false, member, _), _) if (member.cfName == "::hx::StarOf"):
					var head = listHd(args);
					var targetType = switch cppTypeOf(head.etype) {
						case TCppMarshalNativeType(valueType, _):
							TCppMarshalNativeType(valueType, Reference);
						case _:
							TCppUnchanged;
					}
					var ra = retype(retyperCtx, targetType, head);
					var arg = ra.expr;
					var rawType = switch arg.cpptype {
						case TCppReference(x): x;
						case x: x;
					}
					res(ra.ctx, CppAddressOf(arg), TCppStar(rawType, false));
				case CppFunction(FuncStatic(obj, false, member, _), _) if (member.cfName == "::hx::Dereference"):
					var ra = retype(retyperCtx, TCppUnchanged, listHd(args));
					var arg = ra.expr;
					var rawType = switch arg.cpptype {
						case TCppStar(x, _): x;
						case x: x;
					}
					res(ra.ctx, CppDereference(arg), TCppReference(rawType));
				case CppFunction(FuncStatic(obj, false, member, _), _) if (member.cfName == "_hx_create_array_length"):
					var argTypes = argTypesOf(args);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					/* gc_stack - not needed yet */
					switch returnType {
						case TCppObjectArray(_) | TCppScalarArray(_):
							res(ra.ctx, CppCall(FuncNew(returnType), ra.args), returnType);
						case _:
							res(ra.ctx, CppCall(FuncNew(TCppDynamicArray), ra.args), returnType);
					}
				case CppFunction(FuncStatic(obj, false, member, _), returnType) if (cppIsTemplatedCall(member)):
					var argTypes = argTypesOf(args);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					switch ra.args {
						case _ if (ra.args.length > 0 && ra.args[0].cppexpr.match(CppClassOf(_))):
							switch ra.args[0].cppexpr {
								case CppClassOf(path, native):
									res(ra.ctx, CppCall(FuncTemplate(obj, member, path, native), ra.args.slice(1)), returnType);
								case _: throw "unreachable";
							}
						case _:
							core.Error.abort("First parameter of template function must be a Class", retypedFunc.cpppos);
					}
				case CppFunction(FuncInstance(obj, InstPtr(tcpp), member, templateParams), _) if (isMapGetCall(obj, member)):
					var argTypes = argTypesOf(args);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					var fr = switch returnType {
						case TCppVoid | TCppScalar("bool"):
							{name: (if (forCppia) "getBool" else "get_bool"), t: returnType};
						case TCppScalar("int"):
							{name: (if (forCppia) "getInt" else "get_int"), t: returnType};
						case TCppScalar("::cpp::Int64"):
							{name: (if (forCppia) "getInt64" else "get_int64"), t: returnType};
						case TCppScalar("Float"):
							{name: (if (forCppia) "getFloat" else "get_float"), t: returnType};
						case TCppString:
							{name: (if (forCppia) "getString" else "get_string"), t: returnType};
						case _: {name: "get", t: TCppDynamic};
					}
					var func = FuncInstance(obj, InstPtr(tcpp), withName(member, fr.name), templateParams);
					/*
						if  cpp_can_static_cast cppType return_type then begin
						let call = mk_cppexpr (CppCall(func,retypedArgs)) cppType in
						CppCastStatic(call, cppType), cppType
						end else
					 */
					res(ra.ctx, CppCall(func, ra.args), fr.t);
				case CppFunction(FuncInstance(obj, InstPtr(tcpp), member, templateParams), _) if (forCppia && isMapSetCall(obj, member)):
					var argTypes = argTypesOf(args);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					var fname = switch ra.args {
						case [_, {cpptype: TCppScalar("bool")}]: "setBool";
						case [_, {cpptype: TCppScalar("int")}]: "setInt";
						case [_, {cpptype: TCppScalar("::cpp::Int64")}]:
							"setInt64";
						case [_, {cpptype: TCppScalar("Float")}]: "setFloat";
						case [_, {cpptype: TCppString}]: "setString";
						case _: "set";
					}
					var func = FuncInstance(obj, InstPtr(tcpp), withName(member, fname), templateParams);
					res(ra.ctx, CppCall(func, ra.args), cppType);
				case CppFunction(func = FuncInstance(obj, InstPtr(tcpp), member, templateParams), returnType) if (cppCanStaticCast(returnType, cppType)):
					var argTypes = argTypesOf(args);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					var call = mkCppexpr(CppCall(func, ra.args), returnType);
					res(ra.ctx, CppCastStatic(call, cppType), cppType);
				/*
					let error_printer file line = Printf.sprintf "%s:%d:" file line in
					let epos = Lexer.get_error_pos error_printer expr.epos in
					print_endline ( "fixed override " ^ member.cf_name ^ " @ " ^  epos ^ " " ^ (tcpp_to_string returnType) ^ "->" ^ (ctx_type_string ctx expr.etype) );
					CppCall(func,retypedArgs), returnType
				 */
				/* Other functions ... */
				case CppFunction(func = FuncInstance(_, InstStruct, {cfType: TFun({args: argTypes})}, templateParams), returnType):
					/* For struct access classes use the types of the arguments instead of the function argument types */
					/* In the case of generic extern classes a TFun arg type could be `MyClass.T` instead of the real type */
					function mapArgs(funcArg:{name:String, optional:Bool, type:T}, passedArg:TExpr) {
						return {name: funcArg.name, optional: funcArg.optional, type: passedArg.etype};
					}
					// port: List.map2 raises Invalid_argument on lists of different lengths.
					if (argTypes.length != args.length) throw new core.ds.InvalidArgument("List.map2");
					var realTypes = [for (i in 0...argTypes.length) mapArgs(argTypes[i], args[i])];
					var argTypes = realTypes.map(function(a) return CppRetyper.cppTfunArgTypeOf(basic, a.optional, CppRetyper.withReferenceValueType, a.type));
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					res(ra.ctx, CppCall(func, ra.args), returnType);
				case CppFunction(func = FuncInstance(_, _, {cfType: TFun({args: argTypes})}, _), returnType) |
					CppFunction(func = FuncStatic(_, _, {cfType: TFun({args: argTypes})}, _), returnType) |
					CppFunction(func = FuncThis({cfType: TFun({args: argTypes})}, _), returnType):
					var argTypes = argTypes.mapToArray(function(a) return CppRetyper.cppTfunArgTypeOf(basic, a.optional, CppRetyper.withReferenceValueType, a.type));
					/* retype args specifically (not just CppDynamic) */
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					res(ra.ctx, CppCall(func, ra.args), returnType);
				case CppFunction(func, returnType):
					var argTypes = argTypesOf(args);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					res(ra.ctx, CppCall(func, ra.args), returnType);
				case CppEnumField(enumDef, field):
					var argTypes = argTypesOf(args);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					res(ra.ctx, CppCall(FuncEnumConstruct(enumDef, field), ra.args), cppType);
				case CppSuper(_):
					var argTypes = argTypesOf(args);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					res(ra.ctx, CppCall(FuncSuperConstruct(retypedFunc.cpptype), ra.args), TCppVoid);
				case CppDynamicField(expr, name):
					var argTypes = argTypesOf(args);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					/* Special function calls */
					switch [expr.cpptype, name] {
						case [TCppGlobal, _]:
							res(ra.ctx, CppCall(FuncExtern(name, true), ra.args), cppType);
						case [TCppString, _]:
							res(ra.ctx, CppCall(FuncInternal(expr, name, "."), ra.args), cppType);
						case [_, "__Tag"]:
							res(ra.ctx, CppCall(FuncInternal(expr, "_hx_getTag", "->"), ra.args), cppType);
						case [_, name] if (isInternalMember(name)):
							res(ra.ctx, CppCall(FuncInternal(expr, name, "->"), ra.args), cppType);
						case _:
							/* not special */
							res(ra.ctx, CppCall(FuncExpression(retypedFunc), ra.args), TCppDynamic);
					}
				case CppExtern(name, isGlobal):
					var argTypes = args.mapToArray(function(_) return TCppUnchanged);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					res(ra.ctx, CppCall(FuncExtern(name, isGlobal), ra.args), cppType);
				case CppVar(VarLocal({tcppvType: TCppCallable(callableArgs, callableRet)}) | VarClosure({tcppvType: TCppCallable(callableArgs, callableRet)})):
					var ra = retypeFunctionArgs(retyperCtx, args, callableArgs);
					res(ra.ctx, CppCall(FuncExpression(retypedFunc), ra.args), callableRet);
				case CppArray(t):
					var er:{expr:TcppExpr, ret:Tcpp} = switch t {
						case ArrayObject(_, _, callable = TCppCallable(_, ret)):
							/* If we have Array<Dynamic> where Dynamic is a callable we need cast the result of the array indexing */
							/* Without that we are doing dynamic calling */
							{expr: mkCppexpr(CppCast(retypedFunc, callable), callable), ret: ret};
						case ArrayDynamic(_) | ArrayVirtual(_):
							{expr: retypedFunc, ret: TCppDynamic};
						case _:
							/* I don't think other array types can contain something which can be invoked, so error */
							CppError.cppAbort(InternalError, expr.epos);
					}

					var argTypes = args.mapToArray(function(_) return TCppUnchanged);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);

					res(ra.ctx, CppCall(FuncExpression(er.expr), ra.args), er.ret);
				case CppCallable(cls):
					var argTypes = cls.closeArgs.map(function(a) return a.v.tcppvType);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					res(ra.ctx, CppCall(FuncExpression(retypedFunc), ra.args), cls.closeType);
				case o:
					var argTypes = args.mapToArray(function(_) return TCppDynamic);
					var ra = retypeFunctionArgs(retyperCtx, args, argTypes);
					res(ra.ctx, CppCall(FuncExpression(retypedFunc), ra.args), TCppDynamic);
			}
	}

	// port: List.hd.
	static function listHd<A>(l:Vector<A>):A {
		if (l.length == 0) throw new core.ds.Failure("hd");
		return l[0];
	}

	function retypeBinop(retyperCtx:RetyperCtx, expr:TExpr, op:Binop, left:TExpr, right:TExpr):{c:RetyperCtx, e:TcppExprExpr, t:Tcpp} {
		function cppTypeOf(t:T):Tcpp return this.cppTypeOf(CppRetyper.withReferenceValueType, t);
		function res(c:RetyperCtx, e:TcppExprExpr, t:Tcpp):{c:RetyperCtx, e:TcppExprExpr, t:Tcpp} return {c: c, e: e, t: t};

		var c = retyperCtx;
		var binOpType = switch op {
			case OpDiv: TCppScalar("Float");
			case OpBoolAnd | OpBoolOr: TCppScalar("bool");
			case OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr: TCppScalar("int");
			case OpAssign:
				var rr = retype(c, TCppUnchanged, left);
				c = rr.ctx;
				rr.expr.cpptype;
			case OpMult | OpSub:
				cppTypeOf(expr.etype);
			case _: TCppUnchanged;
		}
		/* If we have an unchanged type then use the type of the left and right expression as the overall type */
		/* This is needed to ensure we get references to value types from the auto cast filter */
		var lr = switch binOpType {
			case TCppUnchanged:
				{l: cppTypeOf(left.etype), r: cppTypeOf(right.etype)};
			/* if the left type is a value type then ensure the right type is a reference as we are doing assignment */
			case l = TCppMarshalNativeType(valueType, (Stack | Promoted)):
				{l: l, r: TCppMarshalNativeType(valueType, Reference)};
			case other:
				{l: other, r: other};
		}
		var r1 = retype(c, lr.l, left);
		var r2 = retype(r1.ctx, lr.r, right);
		c = r2.ctx;
		var e1 = r1.expr, e2 = r2.expr;
		var complex = isComplexCompare(e1.cpptype) || isComplexCompare(e2.cpptype);
		var pointer = isPointerCompare(e1.cpptype) || isPointerCompare(e2.cpptype);
		var instance = isInstanceCompare(e1.cpptype) || isInstanceCompare(e2.cpptype);
		var e1Null = e1.cpptype.match(TCppNull);
		var e2Null = e2.cpptype.match(TCppNull);
		var reference = switch op {
			case OpAssign:
				var lv = toLvalue(e1);
				if (lv.gc) {
					c = c.copy();
					c.gcStack = true;
				}
				CppSet(lv.lvalue, e2);
			case OpAssignOp(op):
				var lv = toLvalue(e1);
				if (lv.gc) {
					c = c.copy();
					c.gcStack = true;
				}
				CppModify(op, lv.lvalue, e2);
			case OpEq if (e1Null && e2Null): CppBool(true);
			case OpGte if (e1Null && e2Null): CppBool(true);
			case OpLte if (e1Null && e2Null): CppBool(true);
			case OpNotEq if (e1Null && e2Null): CppBool(false);
			case _ if (e1Null && e2Null): CppBool(false);
			case OpEq if (e1Null): CppNullCompare("IsNull", e2);
			case OpGte if (e1Null): CppNullCompare("IsNull", e2);
			case OpLte if (e1Null): CppNullCompare("IsNull", e2);
			case OpNotEq if (e1Null): CppNullCompare("IsNotNull", e2);
			case OpEq if (e2Null): CppNullCompare("IsNull", e1);
			case OpGte if (e2Null): CppNullCompare("IsNull", e1);
			case OpLte if (e2Null): CppNullCompare("IsNull", e1);
			case OpNotEq if (e2Null): CppNullCompare("IsNotNull", e1);
			case OpEq if (instance): CppCompare("IsInstanceEq", e1, e2, op);
			case OpNotEq if (instance): CppCompare("IsInstanceNotEq", e1, e2, op);
			case OpEq if (pointer): CppCompare("IsPointerEq", e1, e2, op);
			case OpNotEq if (pointer): CppCompare("IsPointerNotEq", e1, e2, op);
			case OpEq if (complex): CppCompare("IsEq", e1, e2, op);
			case OpNotEq if (complex): CppCompare("IsNotEq", e1, e2, op);
			case OpGte if (complex): CppCompare("IsGreaterEq", e1, e2, op);
			case OpLte if (complex): CppCompare("IsLessEq", e1, e2, op);
			case OpGt if (complex): CppCompare("IsGreater", e1, e2, op);
			case OpLt if (complex): CppCompare("IsLess", e1, e2, op);
			case _: CppBinop(op, e1, e2);
		}
		return switch [op, e1.cpptype, e2.cpptype] {
			/* Variant + Variant = Variant */
			case [OpAdd, _, TCppVariant(o)] | [OpAdd, TCppVariant(o), _]:
				res(c, reference, TCppVariant(o));
			case [_, _, _]:
				res(c, reference, cppTypeOf(expr.etype));
		}
	}
}
