package generators.cpp.gen;

import core.Globals;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.Meta;
import core.Define;
import generators.Gctx;
import generators.cpp.CppAst;
import generators.cpp.CppStrings.*;
import generators.cpp.CppTypeUtils.*;
import generators.cpp.CppAstTools.*;
import generators.cpp.CppSourceWriter;
import generators.cpp.CppContext;
import generators.cpp.gen.CppGen.*;
import generators.cpp.gen.CppCppia.ScriptType;

class CppGenClassImplementation {
	public static function writeCallableHeader(callableName:String, captures:Null<String>, func:TcppClassFunction, returnTypeStr:String, prefix:String,
			output:String->Void):Void {
		var signature = funcToCallableString("::hx::AutoCallable_obj", func);

		output('struct $callableName final : public $signature {\n');
		switch captures {
			case null:
				output('\t$callableName() {} \n');
			case objName:
				output('\t::hx::ObjectPtr<$objName> __this;\n');
				output('\t$callableName(::hx::ObjectPtr<$objName> obj = null()) : __this(obj) {} \n');
		}

		/* Override __Compare */
		output("\tint __Compare(const ::hx::Object* inRhs) const override {\n");
		output('\t\tauto casted = dynamic_cast<const $callableName*>(inRhs);\n');
		output("\t\tif (!casted) { return -1; }\n");
		if (captures != null) output("\t\tif (__this != casted->__this) return 1;\n");
		output("\t\treturn 0;\n");
		output("\t}\n");

		/* Override callableId, Haxe function closures are only compared based on name, not signature */
		output("\tstd::type_index callableId() const override {\n");
		output('\t\treturn std::type_index{ typeid($callableName) };\n');
		output("\t}\n");

		output('\t$returnTypeStr HX_LOCAL_RUN(${cppCallableArgs(func.tcfArgs, prefix)}) override {\n');
	}

	public static function writeCallableTrailer(captures:Null<String>, output:String->Void):Void {
		output("\t}\n");
		if (captures != null) {
			output("\tvoid __Mark(hx::MarkContext* __inCtx) override { HX_MARK_MEMBER(__this); }\n");
			output("#ifdef HXCPP_VISIT_ALLOCS\n");
			output("\tvoid __Visit(hx::VisitContext* __inCtx) override { HX_VISIT_MEMBER(__this); }\n");
			output("#endif\n");
		}

		output("};\n\n");
	}

	public static function genFunction(ctx:Context, tcppClass:TcppClass, isStatic:Bool, func:TcppClassFunction):Void {
		var output = ctx.ctxOutput;
		var returnType = cppTypeOf(ctx.ctxCommon.basic, func.tcfFunc.tfType);

		var r = switch returnType {
			case TCppVoid:
				{ret: "(void)", isVoid: true, returnTypeStr: "void"};
			case other:
				{ret: "return ", isVoid: false, returnTypeStr: tcppToString(other)};
		}
		var ret = r.ret, returnTypeStr = r.returnTypeStr;

		/* The actual function definition */
		output(returnTypeStr);
		output(" " + tcppClass.tclName + "::" + func.tcfName + "(");
		output(printArgList(func.tcfArgs, "__o_"));
		output(")");

		switch Ast.getMetaString(func.tcfField.cfMeta, Meta.Native) {
			case nativeImpl if (nativeImpl != null && isStatic):
				output(" {\n");
				output("\t" + ret + "::" + nativeImpl + "(" + printArgListName(func.tcfArgs, "__o_") + ");\n");
				output("}\n\n");
			case _:
				ctx.ctxRealThisPtr = true;
				var code = getCode(func.tcfField.cfMeta, Meta.FunctionCode);
				var tailCode = getCode(func.tcfField.cfMeta, Meta.FunctionTailCode);

				withDebug(ctx, func.tcfField.cfMeta,
					function(noDebug) genCppFunctionBody(ctx, tcppClass.tclClass, isStatic, func.tcfField.cfName, func, code, tailCode, noDebug));
		}

		output("\n\n");

		/* generate dynamic version too ... */
		if ((!func.tcfIsVirtual || !func.tcfIsOverriding) && func.tcfIsReflective) {
			var callableName = '__${tcppClass.tclName}${func.tcfName}';
			var signature = funcToCallableString("::hx::Callable", func);
			if (isStatic) output('$signature ${tcppClass.tclName}::${func.tcfName}_dyn() { return _hx_alloc$callableName; }\n\n') else
				output('$signature ${tcppClass.tclName}::${func.tcfName}_dyn() { return new $callableName(this); }\n\n');
		}
	}

	static function fullName(tcppClass:TcppClass):String
		return tcppClass.tclClass.clPath.pack.map(keywordRemap).join("::") + "::" + tcppClass.tclName;

	public static function genFunctionClosures(ctx:Context, tcppClass:TcppClass, isStatic:Bool, func:TcppClassFunction):Void {
		if ((!func.tcfIsVirtual || !func.tcfIsOverriding) && func.tcfIsReflective) {
			var output = ctx.ctxOutput;
			var returnTypeStr = typeToString(ctx.ctxCommon.basic, func.tcfFunc.tfType);
			var returnType = cppTypeOf(ctx.ctxCommon.basic, func.tcfFunc.tfType);
			var isVoid = returnType.match(TCppVoid);
			var callableName = '__${tcppClass.tclName}${func.tcfName}';
			var fullName = fullName(tcppClass);
			var captures = if (isStatic) null else fullName;

			writeCallableHeader(callableName, captures, func, returnTypeStr, "", output);

			var argsPass = func.tcfArgs.map(function(a) return a.v.tcppvName).join(", ");
			var prefix = if (isVoid) "\t\t" else "\t\treturn ";
			if (isStatic) output('$prefix$fullName::${func.tcfName}($argsPass);\n') else output('${prefix}__this->${func.tcfName}($argsPass);\n');

			writeCallableTrailer(captures, output);

			if (isStatic) {
				var signature = funcToCallableString("::hx::Callable", func);
				output('$signature _hx_alloc$callableName;\n\n');
			}
		}
	}

	public static function genStaticClosureAlloc(ctx:Context, tcppClass:TcppClass, func:TcppClassFunction):Void {
		if ((!func.tcfIsVirtual || !func.tcfIsOverriding) && func.tcfIsReflective) {
			var output = ctx.ctxOutput;
			var callableName = '__${tcppClass.tclName}${func.tcfName}';
			output('_hx_alloc$callableName = new (::hx::NewObjectType::NewObjConst) $callableName();\n\n');
		}
	}

	public static function genDynamicFunction(ctx:Context, tcppClass:TcppClass, isStatic:Bool, func:TcppClassFunction):Void {
		var output = ctx.ctxOutput;
		var funcName = "__default_" + func.tcfName;
		var noDebug = Meta.has(Meta.NoDebug, func.tcfField.cfMeta);
		var returnTypeStr = tcppToString(func.tcfReturn);
		var captures = fullName(tcppClass);

		writeCallableHeader(funcName, captures, func, returnTypeStr, "__o_", output);

		ctx.ctxRealThisPtr = false;

		genCppFunctionBody(ctx, tcppClass.tclClass, isStatic, funcName, func, "", "", noDebug);

		writeCallableTrailer(captures, output);
	}

	public static function genStaticVariable(ctx:Context, tcppClass:TcppClass, v:TcppClassVariable):Void {
		var output = ctx.ctxOutput;
		var tcppStr = tcppToString(v.tcvType);
		output('$tcppStr ${tcppClass.tclName}::${v.tcvName};\n\n');
	}

	public static function genDynamicFunctionInit(ctx:Context, func:TcppClassFunction):Void {
		switch func.tcfField.cfExpr {
			case null:
			case {eexpr: TFunction(functionDef)}:
				ctx.ctxOutput('\t${func.tcfName} = new ${"__default_" + func.tcfName};\n\n');
			case _:
		}
	}

	public static function genBootField(ctx:Context, outputCpp:String->Void, tcppClass:TcppClass):Void {
		if (hasTcppClassFlag(tcppClass, Boot)) {
			function genVarInit(ctx:Context, classDef:TClass, v:TcppClassVariable):Void {
				switch v.tcvField.cfExpr {
					case null:
					case expr:
						var dst = core.Texpr.Builder.makeStaticField(classDef, v.tcvField, v.tcvField.cfPos);
						var op = core.Texpr.Builder.binop(OpAssign, dst, expr, expr.etype, expr.epos);

						genCppInit(ctx, joinClassPath(classDef.clPath, "."), "boot", "", op);
				}
			}

			outputCpp("void " + tcppClass.tclName + "::__boot()\n{\n");

			var dotName = joinClassPath(tcppClass.tclClass.clPath, ".");

			switch tcppClass.tclMeta {
				case null:
				case expr: genCppInit(ctx, dotName, "boot", "__mClass->__meta__ = ", expr);
			}

			switch tcppClass.tclRtti {
				case null:
				case expr: genCppInit(ctx, dotName, "boot", "__mClass->__rtti__ = ", expr);
			}

			/* Allocating static function lambdas must be done first */
			/* Init functionality might depend on these being assigned */
			for (f in tcppClass.tclStaticFunctions) genStaticClosureAlloc(ctx, tcppClass, f);

			for (v in tcppClass.tclStaticVariables) genVarInit(ctx, tcppClass.tclClass, v);
			for (f in tcppClass.tclStaticDynamicFunctions) genDynamicFunctionInit(ctx, f);

			outputCpp("}\n\n");
		}
	}

	public static function genInitFunction(ctx:Context, outputCpp:String->Void, tcppClass:TcppClass):Void {
		switch tcppClass.tclInit {
			case null:
			case expression:
				outputCpp("void " + tcppClass.tclName + "::__init__()");
				genCppInit(ctx, cppClassName(tcppClass.tclClass), "__init__", "", mkBlock(expression));
				outputCpp("\n\n");
		}
	}

	public static function newDefaultClosure(func:TcppClassFunction, obj:String):String {
		return '${funcToCallableString("::hx::Callable", func)}(new __default_${func.tcfName}($obj))';
	}

	public static function genDynamicFunctionAllocator(ctx:Context, outputCpp:String->Void, tcppClass:TcppClass):Void {
		switch tcppClass.tclDynamicFunctions {
			case []:
			case functions:
				function mapper(func:TcppClassFunction):String
					return '\tif (!_hx_obj->${func.tcfName}.mPtr) { _hx_obj->${func.tcfName} = ${newDefaultClosure(func, "_hx_obj")}; }';
				function folder(acc:Array<String>, classDef:TClass):Array<String> {
					return if (hasDynamicMemberFunctions(classDef)) {
						var superName = joinClassPathRemap(classDef.clPath, "::") + "_obj";

						['\t$superName::__alloc_dynamic_functions(_hx_ctx, _hx_obj);'].concat(acc);
					} else switch classDef.clSuper {
						case null: acc;
						case sup: folder(acc, sup.cls);
					}
				}

				var initial = functions.map(mapper);
				var allocs = switch tcppClass.tclClass.clSuper {
					case null:
						initial;
					case sup:
						folder(initial, sup.cls);
				}

				var rev = allocs.copy();
				rev.reverse();
				var str = rev.join("\n");

				outputCpp('void ${tcppClass.tclName}::__alloc_dynamic_functions(::hx::Ctx* _hx_ctx, ${tcppClass.tclName}* _hx_obj) {\n$str\n}\n');
		}
	}

	public static function printReflectiveFields(ctxCommon:Gctx, classDef:TClass, variables:Array<TcppClassVariable>,
			functions:Array<TcppClassFunction>):Null<String> {
		var calls = ["\t::String(null())"];
		var i = variables.length;
		while (--i >= 0) {
			var v = variables[i];
			if (v.tcvIsReflective) calls = ['\t${strq(ctxCommon, v.tcvField.cfName)}'].concat(calls);
		}
		var i = functions.length;
		while (--i >= 0) {
			var func = functions[i];
			if (func.tcfIsReflective) calls = ['\t${strq(ctxCommon, func.tcfField.cfName)}'].concat(calls);
		}

		return if (calls.length > 1) calls.join(",\n") else null;
	}

	public static function cppInterfaceImplName(cls:TClass):String return "_hx_" + joinClassPath(cls.clPath, "_");

	public static function generateNativeClass(baseCtx:Context, tcppClass:TcppClass):Void {
		var classDef = tcppClass.tclClass;
		var classPath = classDef.clPath;
		var debug = tcppClass.tclDebugLevel;
		var cppFile = CppSourceWriter.newPlacedCppFile(baseCtx.ctxCommon, classPath);
		var cppCtx = CppContext.fileContext(baseCtx, cppFile, debug, false);
		var ctx = cppCtx;
		var outputCpp = cppFile.write;
		var scriptable = hasTcppClassFlag(tcppClass, Scriptable);

		cppFile.writeH("#include <hxcpp.h>\n\n");

		var allReferenced = CppReferences.findReferencedTypes(ctx, TClassDecl(classDef), ctx.ctxSuperDeps, ctx.ctxConstructorDeps, false, false, scriptable);
		for (p in allReferenced) addInclude(cppFile, p);

		if (scriptable) cppFile.writeH("#include <hx/Scriptable.h>\n");

		cppFile.writeH("\n");

		outputCpp(getClassCode(classDef, Meta.CppFileCode));
		var includes = getAllMetaStringPath(classDef.clMeta, Meta.CppInclude);
		function printer(inc:String) outputCpp("#include \"" + inc + "\"\n");
		for (inc in includes) printer(inc);

		outputCpp("\n");
		outputCpp("namespace {\n\n");

		for (f in tcppClass.tclDynamicFunctions) genDynamicFunction(ctx, tcppClass, false, f);
		for (f in tcppClass.tclStaticDynamicFunctions) genDynamicFunction(ctx, tcppClass, true, f);

		for (f in tcppClass.tclFunctions) genFunctionClosures(ctx, tcppClass, false, f);
		for (f in tcppClass.tclStaticFunctions) genFunctionClosures(ctx, tcppClass, true, f);

		outputCpp("}\n\n");

		beginNamespace(outputCpp, classPath);

		outputCpp(getClassCode(classDef, Meta.CppNamespaceCode));

		genInitFunction(ctx, outputCpp, tcppClass);

		for (f in tcppClass.tclFunctions) genFunction(ctx, tcppClass, false, f);

		for (f in tcppClass.tclStaticFunctions) genFunction(ctx, tcppClass, true, f);
		for (v in tcppClass.tclStaticVariables) genStaticVariable(ctx, tcppClass, v);

		outputCpp("\n");

		genDynamicFunctionAllocator(ctx, outputCpp, tcppClass);

		generateNativeConstructor(ctx, outputCpp, tcppClass, false);
		genBootField(ctx, outputCpp, tcppClass);

		endNamespace(outputCpp, classPath);

		cppFile.close();
	}

	public static function generateManagedClass(baseCtx:Context, tcppClass:TcppClass):Void {
		var commonCtx = baseCtx.ctxCommon;
		var classDef = tcppClass.tclClass;
		var classPath = classDef.clPath;
		var debug = tcppClass.tclDebugLevel;
		var cppFile = CppSourceWriter.newPlacedCppFile(baseCtx.ctxCommon, classPath);
		var cppCtx = CppContext.fileContext(baseCtx, cppFile, debug, false);
		var ctx = cppCtx;
		var outputCpp = cppFile.write;
		var strq = function(s) return CppStrings.strq(ctx.ctxCommon, s);
		var scriptable = hasTcppClassFlag(tcppClass, Scriptable);

		var classSuperName = switch classDef.clSuper {
			case null: "";
			case {cls: klass, params: params}:
				tcppToStringSuffix("_obj", cppInstanceType(ctx.ctxCommon.basic, klass, params, CppRetyper.withStackValueType));
		}

		cppFile.writeH("#include <hxcpp.h>\n\n");

		var allReferenced = CppReferences.findReferencedTypes(ctx, TClassDecl(classDef), ctx.ctxSuperDeps, ctx.ctxConstructorDeps, false, false, scriptable);
		for (p in allReferenced) addInclude(cppFile, p);

		if (scriptable) cppFile.writeH("#include <hx/Scriptable.h>\n");

		cppFile.writeH("\n");

		outputCpp(getClassCode(classDef, Meta.CppFileCode));
		var includes = getAllMetaStringPath(classDef.clMeta, Meta.CppInclude);
		function printer(inc:String) outputCpp("#include \"" + inc + "\"\n");
		for (inc in includes) printer(inc);

		outputCpp("\n");
		outputCpp("namespace {\n\n");

		for (f in tcppClass.tclFunctions) genFunctionClosures(ctx, tcppClass, false, f);
		for (f in tcppClass.tclStaticFunctions) genFunctionClosures(ctx, tcppClass, true, f);

		for (f in tcppClass.tclDynamicFunctions) genDynamicFunction(ctx, tcppClass, false, f);
		for (f in tcppClass.tclStaticDynamicFunctions) genDynamicFunction(ctx, tcppClass, true, f);

		outputCpp("}\n\n");

		beginNamespace(outputCpp, classPath);
		outputCpp("\n");

		outputCpp(getClassCode(classDef, Meta.CppNamespaceCode));

		var className = tcppClass.tclName;
		var cargs = constructorArgVarList(tcppClass);
		var constructorVarList = cargs.map(function(a) return a.name);
		var constructorTypeArgs = cargs.map(function(a) return '${a.type} ${a.name}').join(",");

		outputCpp("void " + className + "::__construct(" + constructorTypeArgs + ")");
		switch tcppClass.tclConstructor {
			case null: outputCpp(" { }\n\n");
			case constructor:
				/* Ensure we reset this real this ptr flag, it may have been set to false in the above gen_dynamic_function */
				ctx.ctxRealThisPtr = true;

				function cb(noDebug:Bool):Void {
					genCppFunctionBody(ctx, classDef, false, "new", constructor, "", "", noDebug);
					outputCpp("\n");
				}
				withDebug(ctx, constructor.tcfField.cfMeta, cb);
		}

		/* Destructor goes in the cpp file so we can "see" the full definition of the member vars */
		if (!hasClassFlag(classDef, CAbstract)) {
			var ptrName = classPointer(classDef);
			function arrayArgList(inList:Array<String>):String return [for (idx in 0...inList.length) 'inArgs[$idx]'].join(",");

			outputCpp('::Dynamic $className::__CreateEmpty() { return new $className; }\n\n');

			outputCpp('void* $className::_hx_vtable = 0;\n\n');

			outputCpp('::Dynamic $className::__Create(::hx::DynamicArray inArgs)\n');
			outputCpp('{\n\t$ptrName _hx_result = new $className();\n');
			outputCpp('\t_hx_result->__construct(${arrayArgList(constructorVarList)});\n');
			outputCpp("\treturn _hx_result;\n}\n\n");
		}

		outputCpp("bool " + className + "::_hx_isInstanceOf(int inClassId) {\n");
		function parentIdFolder(acc:Array<Int>, cur:TcppClass):Array<Int> {
			return switch cur.tclSuper {
				case null: [cur.tclId].concat(acc);
				case s: parentIdFolder([cur.tclId].concat(acc), s);
			}
		}
		var implementedClasses = listSort(function(a:Int, b:Int) return a < b ? -1 : a > b ? 1 : 0, parentIdFolder([1], tcppClass));
		function txt(cId:Int):String return "0x" + hex(cId, 8);
		function dumpClasses(indent:String, classes:Array<Int>):Void {
			switch classes {
				case []:
				case [c]: outputCpp(indent + "return inClassId==(int)" + txt(c) + ";\n");
				case [c, c1]:
					outputCpp(indent + "return inClassId==(int)" + txt(c) + " || inClassId==(int)" + txt(c1) + ";\n");
				case _:
					var len = classes.length;
					var mid = classes[Std.int(len / 2)];
					var low = classes.filter(function(e) return e <= mid);
					var high = classes.filter(function(e) return !(e <= mid));
					outputCpp(indent + "if (inClassId<=(int)" + txt(mid) + ") {\n");
					dumpClasses(indent + "\t", low);
					outputCpp(indent + "} else {\n");
					dumpClasses(indent + "\t", high);
					outputCpp(indent + "}\n");
			}
		}
		dumpClasses("\t", implementedClasses);
		outputCpp("}\n\n");

		if (tcppClass.tclHaxeInterfaces.length > 0) {
			var cname = cppInterfaceImplName(classDef);
			var implName = cppClassName(classDef);

			function foldInterface(acc:{glued:haxe.ds.StringMap<String>, calls:Array<String>}, iface:TcppInterface) {
				function genInterfaceFuncs(iface:TcppInterface):{glued:haxe.ds.StringMap<String>, funcs:Array<String>} {
					function foldField(acc:{glued:haxe.ds.StringMap<String>, funcs:Array<String>}, func:TcppInterfaceFunction) {
						var castStr = cppTfunSignature(false, func.iffArgs, func.iffReturn);
						var realName = cppMemberNameOf(func.iffField);

						/* C++ can't work out which function it needs to take the addrss of
							when the implementation is overloaded - currently the map-set functions.
							Change the castKey to force a glue function in this case (could double-cast the pointer, but it is ugly)
						 */
						var suffix = switch iface.ifClass.clPath {
							case {pack: ["haxe"], name: "IMap"} if (realName == "set"): "*";
							case _: "";
						}
						var castKey = '$realName::${castStr}$suffix';
						var implementationKey = '$realName::${findClassImplementation(func, tcppClass)}';

						return if (castKey == implementationKey) {glued: acc.glued, funcs: ['\t${castStr}&$implName::$realName'].concat(acc.funcs)} else {
							var glue = '${func.iffField.cfName}_${hex(genHash32(0, castStr), 8)}';
							var glued = if (acc.glued.exists(castKey)) acc.glued else {
								var argList = printRetypedTfunArgList(true, func.iffArgs);
								var returnType = tcppToString(func.iffReturn);
								var returnStr = if (returnType == "void") "" else "return ";
								var cppCode = '$returnType $className::$glue($argList) { $returnStr$realName(${printArgNames(func.iffArgs)}); }\n';
								var g = acc.glued.copy();
								g.set(castKey, cppCode);
								g;
							}
							{glued: glued, funcs: ['\t${castStr}&$implName::$glue'].concat(acc.funcs)};
						}
					}

					var initial = switch iface.ifExtends {
						case null: {glued: acc.glued, funcs: []};
						case sup: genInterfaceFuncs(sup);
					}
					var a = initial;
					for (f in iface.ifFunctions) a = foldField(a, f);
					return a;
				}

				var interfaceName = cppInterfaceImplName(iface.ifClass);
				var g = genInterfaceFuncs(iface);
				var funcs = g.funcs.copy();
				funcs.reverse();
				var combined = funcs.join(",\n");
				var call = 'static ${cppClassName(iface.ifClass)} ${cname}_$interfaceName = {\n$combined\n};\n';
				return {glued: g.glued, calls: [call].concat(acc.calls)};
			}

			var acc = {glued: new haxe.ds.StringMap<String>(), calls: []};
			for (iface in tcppClass.tclHaxeInterfaces) acc = foldInterface(acc, iface);

			outputCpp(acc.calls.join("\n"));
			outputCpp([for (k in core.ds.PMap.keys(acc.glued)) acc.glued.get(k)].join("\n"));

			outputCpp("void *" + className + "::_hx_getInterface(int inHash) {\n");
			outputCpp("\tswitch(inHash) {\n");

			function iter(iface:TcppInterface)
				outputCpp("\t\tcase (int)" + iface.ifHash + ": return &" + cname + "_" + cppInterfaceImplName(iface.ifClass) + ";\n");
			for (iface in tcppClass.tclHaxeInterfaces) iter(iface);

			outputCpp("\t}\n");

			if (classSuperName == "") {
				outputCpp("\t#ifdef HXCPP_SCRIPTABLE\n");
				outputCpp("\treturn super::_hx_getInterface(inHash);\n");
				outputCpp("\t#else\n");
				outputCpp("\treturn 0;\n");
				outputCpp("\t#endif\n");
			} else outputCpp("\treturn super::_hx_getInterface(inHash);\n");
			outputCpp("}\n\n");
		}

		genInitFunction(ctx, outputCpp, tcppClass);

		for (f in tcppClass.tclFunctions) genFunction(ctx, tcppClass, false, f);

		for (f in tcppClass.tclStaticFunctions) genFunction(ctx, tcppClass, true, f);
		for (v in tcppClass.tclStaticVariables) genStaticVariable(ctx, tcppClass, v);

		outputCpp("\n");

		genDynamicFunctionAllocator(ctx, outputCpp, tcppClass);

		var inlineConstructor = canInlineConstructor(baseCtx, classDef);
		if ((!inlineConstructor) && !hasClassFlag(classDef, CAbstract)) generateConstructor(ctx, outputCpp, tcppClass, false);

		/* Initialise non-static variables */
		outputCpp(className + "::" + className + "()\n{\n");
		for (func in tcppClass.tclDynamicFunctions) outputCpp('\t${func.tcfName} = ${newDefaultClosure(func, "this")};\n');
		outputCpp("}\n\n");

		if (tcppClass.tclContainer != null && tcppClass.tclContainer.match(Current)) {
			function findNextSuperIteration(cls:TcppClass):Null<String> {
				return switch cls.tclSuper {
					case null:
						null;
					case sup if (sup.tclContainer != null && sup.tclContainer.match(Current)):
						tcppToStringSuffix("_obj", cppInstanceType(ctx.ctxCommon.basic, sup.tclClass, sup.tclParams, CppRetyper.withStackValueType));
					case sup:
						findNextSuperIteration(sup);
				}
			}

			var superNeedsIteration = findNextSuperIteration(tcppClass);
			var smartClassName = classPath.name;
			function dumpFieldIterator(macro_:String, v:TcppClassVariable) outputCpp('\t$macro_(${v.tcvName}, "${v.tcvField.cfName}");\n');

			/* MARK function - explicitly mark all child pointers */
			outputCpp("void " + className + "::__Mark(HX_MARK_PARAMS)\n{\n");
			outputCpp("\tHX_MARK_BEGIN_CLASS(" + smartClassName + ");\n");
			for (v in tcppClass.tclVariables) dumpFieldIterator("HX_MARK_MEMBER_NAME", v);
			switch superNeedsIteration {
				case null:
				case sup: outputCpp("\t" + sup + "::__Mark(HX_MARK_ARG);\n");
			}
			outputCpp("\tHX_MARK_END_CLASS();\n");
			outputCpp("}\n\n");

			/* Visit function - explicitly visit all child pointers */
			outputCpp("void " + className + "::__Visit(HX_VISIT_PARAMS)\n{\n");
			for (v in tcppClass.tclVariables) dumpFieldIterator("HX_VISIT_MEMBER_NAME", v);
			switch superNeedsIteration {
				case null:
				case sup: outputCpp("\t" + sup + "::__Visit(HX_VISIT_ARG);\n");
			}
			outputCpp("}\n\n");
		}

		function dumpQuickFieldTest(fields:Array<{field:String, len:Int, result:String}>):Void {
			if (fields.length > 0) {
				var sfields = listSort(function(f1:{field:String, len:Int, result:String}, f2:{field:String, len:Int, result:String}) return f1.len - f2.len, fields);
				var lenCase = -1;
				outputCpp("\tswitch(inName.length) {\n");
				for (f in sfields) {
					if (f.len != lenCase) {
						if (lenCase >= 0) outputCpp("\t\tbreak;\n");
						outputCpp("\tcase " + Std.string(f.len) + ":\n");
						lenCase = f.len;
					}
					outputCpp("\t\tif (HX_FIELD_EQ(inName,\"" + core.StringHelper.sEscape(f.field) + "\") ) { " + f.result + " }\n");
				}
				outputCpp("\t}\n");
			}
		}

		function checkPropCall(field:TClassField):String {
			return if (Meta.has(Meta.NativeProperty, classDef.clMeta)
				|| Meta.has(Meta.NativeProperty, field.cfMeta)
				|| Gctx.defined(commonCtx, Define.ForceNativeProperty)) "inCallProp != ::hx::paccNever" else "inCallProp == ::hx::paccAlways";
		}

		function getWrapper(field:TClassField, value:String):String {
			return switch CppRetyper.cppTypeOf(ctx.ctxCommon.basic, CppRetyper.withPromotedValueType, field.cfType) {
				case inst = TCppInst(t, _) if (Meta.has(Meta.StructAccess, t.clMeta)):
					'(::cpp::Struct< ${tcppToString(inst)} >) $value';
				case TCppStar(_):
					'(::cpp::Pointer<void*>) $value';
				case _:
					value;
			}
		}

		function entry(field:String, result:String) return {field: field, len: byteLength(field), result: result};

		function printVariable(varPrinter:String->String, getPrinter:String->String->String->String, v:TcppClassVariable,
				acc:Array<{field:String, len:Int, result:String}>) {
			return if (v.tcvIsReflective && !isAbstractImpl(classDef)) {
				var variable = getWrapper(v.tcvField, v.tcvName);

				if (v.tcvHasGetter) {
					var propCheck = checkPropCall(v.tcvField);
					var getter = getWrapper(v.tcvField, 'get_${v.tcvField.cfName}()');

					[entry(v.tcvField.cfName, getPrinter(propCheck, getter, variable))].concat(acc);
				} else [entry(v.tcvField.cfName, varPrinter(variable))].concat(acc);
			} else acc;
		}

		function printFunction(printer:String->String, func:TcppClassFunction, acc:Array<{field:String, len:Int, result:String}>) {
			return if (func.tcfIsReflective) {
				var ident = printer(getWrapper(func.tcfField, func.tcfName));
				[entry(func.tcfField.cfName, ident)].concat(acc);
			} else acc;
		}

		function printProperty(printer:String->String->String, v:TcppClassVariable, acc:Array<{field:String, len:Int, result:String}>) {
			return if (v.tcvHasGetter && v.tcvIsReflective && !isAbstractImpl(classDef)) {
				var propCheck = checkPropCall(v.tcvField);
				var getter = getWrapper(v.tcvField, 'get_${v.tcvField.cfName}()');
				[entry(v.tcvField.cfName, printer(propCheck, getter))].concat(acc);
			} else acc;
		}

		function castable(v:TcppClassVariable):String {
			return switch v.tcvType {
				case inst = TCppInst(t, _) if (Meta.has(Meta.StructAccess, t.clMeta)):
					"cpp::Struct< " + tcppToString(inst) + " > ";
				case TCppStar(t, _):
					"cpp::Pointer< " + tcppToString(t) + " >";
				case other:
					tcppToString(other);
			}
		}

		// port: List.fold_right.
		function foldRight<A, B>(f:A->B->B, l:Array<A>, acc:B):B {
			var i = l.length;
			while (--i >= 0) acc = f(l[i], acc);
			return acc;
		}

		if (hasTcppClassFlag(tcppClass, MemberGet)) {
			/* Dynamic "Get" Field function - string version */
			outputCpp('::hx::Val $className::__Field(const ::String &inName,::hx::PropertyAccess inCallProp)\n{\n');

			function varPrinter(ident:String) return 'return ::hx::Val( $ident );';
			function getPrinter(check:String, getter:String, ident:String) return 'return ::hx::Val( $check ? $getter : $ident );';
			function funPrinter(ident:String) return 'return ::hx::Val( ${ident}_dyn() );';
			function propPrinter(check:String, ident:String) return 'if ($check) { return ::hx::Val( $ident ); }';

			var allFields = [];
			allFields = foldRight(function(v, acc) return printVariable(varPrinter, getPrinter, v, acc), tcppClass.tclVariables, allFields);
			allFields = foldRight(function(v, acc) return printProperty(propPrinter, v, acc), tcppClass.tclProperties, allFields);
			allFields = foldRight(function(f, acc) return printFunction(funPrinter, f, acc), tcppClass.tclFunctions, allFields);

			dumpQuickFieldTest(allFields);
			outputCpp("\treturn super::__Field(inName,inCallProp);\n}\n\n");
		}

		if (hasTcppClassFlag(tcppClass, StaticGet)) {
			outputCpp('bool $className::__GetStatic(const ::String &inName, ::Dynamic &outValue, ::hx::PropertyAccess inCallProp)\n{\n');

			function varPrinter(ident:String) return 'outValue = $ident; return true;';
			function getPrinter(check:String, getter:String, ident:String) return 'outValue = $check ? $getter : $ident; return true;';
			function funPrinter(ident:String) return 'outValue = ${ident}_dyn(); return true;';
			function propPrinter(check:String, ident:String) return 'if ($check) { outValue = $ident; return true; }';

			var allFields = [];
			allFields = foldRight(function(v, acc) return printVariable(varPrinter, getPrinter, v, acc), tcppClass.tclStaticVariables, allFields);
			allFields = foldRight(function(v, acc) return printProperty(propPrinter, v, acc), tcppClass.tclStaticProperties, allFields);
			allFields = foldRight(function(f, acc) return printFunction(funPrinter, f, acc), tcppClass.tclStaticFunctions, allFields);

			dumpQuickFieldTest(allFields);
			outputCpp("\treturn false;\n}\n\n");
		}

		if (hasTcppClassFlag(tcppClass, MemberSet)) {
			outputCpp('::hx::Val $className::__SetField(const ::String& inName, const ::hx::Val& inValue, ::hx::PropertyAccess inCallProp)\n{\n');

			function foldVariable(v:TcppClassVariable, acc:Array<{field:String, len:Int, result:String}>) {
				return if (v.tcvIsReflective && !isAbstractImpl(classDef)) {
					var casted = castable(v);
					var def = if (v.tcvIsGcElement) '_hx_set_${v.tcvName}(HX_CTX_GET, inValue.Cast< $casted >()); return inValue;' else
						'${v.tcvName} = inValue.Cast< $casted >(); return inValue;';

					switch v.tcvField.cfKind {
						case Var({vWrite: AccCall | AccPrivateCall}):
							var propCall = checkPropCall(v.tcvField);
							var setter = getWrapper(v.tcvField, 'set_${v.tcvField.cfName}');
							var call = 'if ($propCall) { return ::hx::Val( $setter(inValue.Cast< $casted >()) ); } else { $def }';

							[entry(v.tcvField.cfName, call)].concat(acc);
						case Var({vWrite: AccNormal | AccNo | AccNever}):
							[entry(v.tcvField.cfName, def)].concat(acc);
						case _:
							acc;
					}
				} else acc;
			}

			function foldProperty(v:TcppClassVariable, acc:Array<{field:String, len:Int, result:String}>) {
				return if (v.tcvIsReflective && !isAbstractImpl(classDef)) {
					var casted = castable(v);

					switch v.tcvField.cfKind {
						case Var({vWrite: AccCall | AccPrivateCall}):
							var propCall = checkPropCall(v.tcvField);
							var setter = getWrapper(v.tcvField, 'set_${v.tcvField.cfName}');
							var call = 'if ($propCall) { return ::hx::Val( $setter(inValue.Cast< $casted >()) ); }';

							[entry(v.tcvField.cfName, call)].concat(acc);
						case _:
							acc;
					}
				} else acc;
			}

			var allFields = [];
			allFields = foldRight(foldVariable, tcppClass.tclVariables, allFields);
			allFields = foldRight(foldProperty, tcppClass.tclProperties, allFields);

			dumpQuickFieldTest(allFields);
			outputCpp("\treturn super::__SetField(inName,inValue,inCallProp);\n}\n\n");
		}

		if (hasTcppClassFlag(tcppClass, StaticSet)) {
			outputCpp('bool $className::__SetStatic(const ::String& inName, ::Dynamic& ioValue, ::hx::PropertyAccess inCallProp)\n{\n');

			function foldVariable(v:TcppClassVariable, acc:Array<{field:String, len:Int, result:String}>) {
				return if (v.tcvIsReflective && !isAbstractImpl(classDef)) {
					var casted = castable(v);

					switch v.tcvField.cfKind {
						case Var({vWrite: AccCall | AccPrivateCall}):
							var propCall = checkPropCall(v.tcvField);
							var setter = getWrapper(v.tcvField, 'set_${v.tcvField.cfName}');
							var call = 'if ($propCall) { ioValue = $setter(ioValue.Cast< $casted >()); } else { ${v.tcvName} = ioValue.Cast< $casted >(); } return true;';

							[entry(v.tcvField.cfName, call)].concat(acc);
						case Var({vWrite: AccNormal | AccNo}):
							[entry(v.tcvField.cfName, '${v.tcvName} = ioValue.Cast< $casted >(); return true;')].concat(acc);
						case _:
							acc;
					}
				} else acc;
			}

			function foldProperty(v:TcppClassVariable, acc:Array<{field:String, len:Int, result:String}>) {
				return if (v.tcvIsReflective && !isAbstractImpl(classDef)) {
					switch v.tcvField.cfKind {
						case Var({vWrite: AccCall | AccPrivateCall}):
							var propCall = checkPropCall(v.tcvField);
							var setter = getWrapper(v.tcvField, 'set_${v.tcvField.cfName}');
							var casted = castable(v);

							[entry(v.tcvField.cfName, 'if ($propCall) { ioValue = $setter(ioValue.Cast< $casted >()); }')].concat(acc);
						case _:
							acc;
					}
				} else acc;
			}

			var allFields = [];
			allFields = foldRight(foldVariable, tcppClass.tclStaticVariables, allFields);
			allFields = foldRight(foldProperty, tcppClass.tclStaticProperties, allFields);

			dumpQuickFieldTest(allFields);
			outputCpp("\treturn false;\n}\n\n");
		}

		/* For getting a list of data members (eg, for serialization) */
		if (hasTcppClassFlag(tcppClass, GetFields)) {
			function append(v:TcppClassVariable, acc:Array<String>) return ['\toutFields->push(${strq(v.tcvField.cfName)});'].concat(acc);
			var fields = ["\tsuper::__GetFields(outFields);"];
			fields = foldRight(append, tcppClass.tclVariables, fields);
			fields = foldRight(append, tcppClass.tclProperties, fields);

			outputCpp('void $className::__GetFields(::Array< ::String >& outFields)\n{\n${fields.join("\n")}\n}\n\n');
		}

		function storage(field:TClassField):String {
			return switch cppTypeOf(ctx.ctxCommon.basic, field.cfType) {
				case TCppScalar("bool"): "::hx::fsBool";
				case TCppScalar("int"): "::hx::fsInt";
				case TCppScalar("Float"): "::hx::fsFloat";
				case TCppString: "::hx::fsString";
				case o if (isObjectElement(o)):
					"::hx::fsObject" + " /* " + tcppToString(o) + " */ ";
				case u: "::hx::fsUnknown" + " /* " + tcppToString(u) + " */ ";
			}
		}
		function dumpMemberStorage(v:TcppClassVariable)
			outputCpp('\t{ ${storage(v.tcvField)}, (int)offsetof($className, ${v.tcvName}), ${strq(v.tcvField.cfName)} },\n');
		function dumpStaticStorage(v:TcppClassVariable)
			outputCpp('\t{ ${storage(v.tcvField)}, (void*) &$className::${v.tcvName}, ${strq(v.tcvField.cfName)} },\n');

		outputCpp("#ifdef HXCPP_SCRIPTABLE\n");

		if (tcppClass.tclVariables.length > 0) {
			outputCpp('static ::hx::StorageInfo ${className}_sMemberStorageInfo[] = {\n');
			for (v in tcppClass.tclVariables) dumpMemberStorage(v);
			outputCpp("\t{ ::hx::fsUnknown, 0, null()}\n};\n");
		} else outputCpp('static ::hx::StorageInfo* ${className}_sMemberStorageInfo = 0;\n');

		if (tcppClass.tclStaticVariables.length > 0) {
			outputCpp('static ::hx::StaticInfo ${className}_sStaticStorageInfo[] = {\n');
			for (v in tcppClass.tclStaticVariables) dumpStaticStorage(v);
			outputCpp("\t{ ::hx::fsUnknown, 0, null()}\n};\n");
		} else outputCpp('static ::hx::StaticInfo* ${className}_sStaticStorageInfo = 0;\n');

		outputCpp("#endif\n\n");

		switch printReflectiveFields(ctx.ctxCommon, classDef, tcppClass.tclVariables, tcppClass.tclFunctions) {
			case null:
				outputCpp('static ::String* ${className}_sMemberFields = 0;\n\n');
			case str:
				outputCpp('static ::String ${className}_sMemberFields[] = {\n$str\n};\n\n');
		}

		if (tcppClass.tclStaticVariables.length > 0) {
			function dumpFieldIterator(macro_:String, v:TcppClassVariable):String return '\t$macro_($className::${v.tcvName}, "${v.tcvField.cfName}");';

			/* Mark static variables as used */
			var marks = tcppClass.tclStaticVariables.map(function(v) return dumpFieldIterator("HX_MARK_MEMBER_NAME", v)).join("\n");

			outputCpp('static void ${className}_sMarkStatics(HX_MARK_PARAMS) { \n$marks\n };\n\n');

			/* Visit static variables */
			var visits = tcppClass.tclStaticVariables.map(function(v) return dumpFieldIterator("HX_VISIT_MEMBER_NAME", v)).join("\n");

			outputCpp("#ifdef HXCPP_VISIT_ALLOCS\n");
			outputCpp('static void ${className}_sVisitStatics(HX_VISIT_PARAMS) { \n$visits\n };\n\n');
			outputCpp("#endif\n\n");
		}

		function generateScriptFunction(isStatic:Bool, field:TcppClassFunction, scriptName:String, callName:String):String {
			var isTemplated = !isStatic;
			if (isTemplated) outputCpp("\ntemplate<bool _HX_SUPER=false>");
			outputCpp("\nstatic void CPPIA_CALL " + scriptName + "(::hx::CppiaCtx *ctx) {\n");

			var scriptReturnType = CppCppia.toScriptType(field.tcfReturn);

			switch field.tcfReturn {
				case TCppVoid:
				case TCppMarshalNativeType(nativeType, _):
					outputCpp('ctx->return${CppCppia.toScriptTypeString(scriptReturnType)}(${tcppToString(TCppMarshalNativeType(nativeType, Reference))}(');
				case _:
					outputCpp('ctx->return${CppCppia.toScriptTypeString(scriptReturnType)}(');
			}

			function dumpCall(castPrefix:String):String {
				if (isStatic) outputCpp('$className::$callName(') else outputCpp('(($className*)ctx->getThis())->${castPrefix}$callName(');

				var signature = CppCppia.toScriptTypeSignature(scriptReturnType), sep = "", size = "sizeof(void*)";
				for (a in field.tcfArgs) {
					var scriptType = switch CppCppia.toScriptType(a.v.tcppvType) {
						case ScriptInt | ScriptFloat | ScriptBool if (a.o != null): ScriptObject;
						case other: other;
					}
					outputCpp('${sep}ctx->get${CppCppia.toScriptTypeString(scriptType)}($size)');
					signature = signature + CppCppia.toScriptTypeSignature(scriptType);
					sep = ",";
					size = size + "+sizeof(" + CppCppia.toScriptTypeSize(scriptType) + ")";
				}
				outputCpp(")");
				return signature;
			}
			var signature = if (isTemplated) {
				outputCpp(" _HX_SUPER ? ");
				dumpCall(className + "::");
				outputCpp(" : ");
				dumpCall("");
			} else dumpCall("");

			switch field.tcfReturn {
				case TCppVoid:
				case TCppMarshalNativeType(nativeType, _):
					outputCpp("))");
				case _:
					outputCpp(")");
			}
			outputCpp(";\n}\n");
			return signature;
		}

		if (scriptable) {
			function dumpScriptFunc(idx:Int, func:TcppClassFunction):Void {
				var args = printArgList(func.tcfArgs, "");
				var returnType = tcppToString(func.tcfReturn);
				var ret = if (returnType == "Void" || returnType == "void") " " else "return ";
				var vtable = '__scriptVTable[${idx + 1}]';

				outputCpp('\t$returnType ${func.tcfName}($args) override {\n');
				outputCpp('\tif ($vtable) {\n');
				outputCpp("\t\t::hx::CppiaCtx *__ctx = ::hx::CppiaCtx::getCurrent();\n");
				outputCpp("\t\t::hx::AutoStack __as(__ctx);\n");
				outputCpp("\t\t__ctx->pushObject( this );\n");

				function wrap(v:TcppVar):String {
					return switch v.tcppvType {
						case TCppMarshalNativeType(nativeType, _):
							'${tcppToString(TCppMarshalNativeType(nativeType, Reference))}(${v.tcppvName})';
						case _:
							v.tcppvName;
					}
				}

				outputCpp(func.tcfArgs.map(function(a) {
					var scriptType = switch CppCppia.toScriptType(a.v.tcppvType) {
						case ScriptInt | ScriptFloat | ScriptBool if (a.o != null): ScriptObject;
						case other: other;
					}
					return '\t\t__ctx->push${CppCppia.toScriptTypeString(scriptType)}(${wrap(a.v)});';
				}).join("\n"));

				outputCpp("\n");
				outputCpp("\t\t" + ret + "__ctx->run" + CppCppia.toScriptTypeString(CppCppia.toScriptType(func.tcfReturn)) + "(" + vtable + ");\n");
				outputCpp("\t}  else " + ret);

				var names = func.tcfArgs.map(function(a) return wrap(a.v));

				outputCpp(className + "::" + func.tcfName + "(" + names.join(",") + ");");

				if (returnType != "void") outputCpp("return null();");

				outputCpp("}\n");
			}

			var scriptName = className + "__scriptable";
			var hasFunkyToString = Lambda.exists(tcppClass.tclStaticFunctions, function(func) return func.tcfName == "toString")
				|| Lambda.exists(tcppClass.tclFunctions, function(func) return func.tcfName == "toString" && func.tcfFunc.tfArgs.length != 0);
			var superString = if (hasFunkyToString) className + "::super" else className;

			outputCpp('class $scriptName : public $className {\n');
			outputCpp('\ttypedef $scriptName __ME;\n');
			outputCpp('\ttypedef $className super;\n');
			outputCpp('\ttypedef $superString __superString;\n');
			outputCpp('\tHX_DEFINE_SCRIPTABLE(HX_ARR_LIST${constructorVarList.length})\n');
			outputCpp("\tHX_DEFINE_SCRIPTABLE_DYNAMIC;\n");

			/*
				Functions are added in reverse order (oldest on right), then list is reversed because this is easier in ocaml
				The order is important because cppia looks up functions by index
			 */
			var flattenTcppClassFunctions = {
				function currentVirtualFunctionsRev(cls:TcppClass, baseFunctions:Array<TcppClassFunction>):Array<TcppClassFunction> {
					var result = baseFunctions;
					for (elem in cls.tclFunctions) {
						result = if (elem.tcfIsOverriding) {
							if (Lambda.exists(result, function(f) return f.tcfName == elem.tcfName)) result else [elem].concat(result);
						} else [elem].concat(result);
					}
					return result;
				}

				function flattenTcppClassFunctionsRec(cls:TcppClass):Array<TcppClassFunction> {
					var initial = switch cls.tclSuper {
						case null: [];
						case sup: flattenTcppClassFunctionsRec(sup);
					}
					return currentVirtualFunctionsRev(cls, initial);
				}

				var r = flattenTcppClassFunctionsRec(tcppClass);
				r.reverse();
				r;
			}

			var filtered = flattenTcppClassFunctions.filter(function(f) return f.tcfName != "toString" /* toString is provided by HX_DEFINE_SCRIPTABLE */);
			for (i in 0...filtered.length) dumpScriptFunc(i, filtered[i]);
			outputCpp("};\n\n");

			if (tcppClass.tclFunctions.length > 0 || tcppClass.tclStaticFunctions.length > 0) {
				function dumpScript(isStatic:Bool, f:TcppClassFunction, acc:Array<String>):Array<String> {
					var signature = generateScriptFunction(isStatic, f, "__s_" + f.tcfField.cfName, f.tcfName);
					var superCall = if (isStatic) "0" else "__s_" + f.tcfField.cfName + "<true>";
					var named = '\t::hx::ScriptNamedFunction("${f.tcfField.cfName}", __s_${f.tcfField.cfName}, "$signature", ${if (isStatic) "true" else "false"}, $superCall, ${/* toString implicitly overrides hx::Object::toString */ if (f.tcfIsOverriding || f.tcfName == "toString") "true" else "false"})';

					return [named].concat(acc);
				}

				var sigs = ["\t::hx::ScriptNamedFunction()"];
				sigs = foldRight(function(f, acc) return dumpScript(false, f, acc), tcppClass.tclFunctions, sigs);
				sigs = foldRight(function(f, acc) return dumpScript(true, f, acc), tcppClass.tclStaticFunctions, sigs);

				outputCpp('static ::hx::ScriptNamedFunction __scriptableFunctions[] = {\n${sigs.join(",\n")}\n};\n\n');
			} else outputCpp("static ::hx::ScriptNamedFunction *__scriptableFunctions = 0;\n");
		}

		var classNameText = joinClassPath(classPath, ".");

		/* Initialise static in boot function ... */
		/* Remap the specialised "extern" classes back to the generic names */
		outputCpp("::hx::Class " + className + "::__mClass;\n\n");
		if (scriptable) switch tcppClass.tclConstructor {
			case null:
				outputCpp("::hx::ScriptFunction " + className + "::__script_construct(0,0);\n");
			case f:
				var signature = generateScriptFunction(false, f, "__script_construct_func", "__construct");
				outputCpp("::hx::ScriptFunction " + className + "::__script_construct(__script_construct_func,\"" + signature + "\");\n");
		}

		switch printReflectiveFields(ctx.ctxCommon, classDef, tcppClass.tclStaticVariables, tcppClass.tclStaticFunctions) {
			case null:
				outputCpp('static ::String* ${className}_sStaticFields = 0;\n\n');
			case str:
				outputCpp('static ::String ${className}_sStaticFields[] = {\n$str\n};\n\n');
		}

		outputCpp("void " + className + "::__register()\n{\n");
		if (!hasClassFlag(classDef, CAbstract)) {
			outputCpp("\t" + className + " _hx_dummy;\n");
			outputCpp("\t" + className + "::_hx_vtable = *(void **)&_hx_dummy;\n");
		}
		outputCpp("\t::hx::Static(__mClass) = new ::hx::Class_obj();\n");
		outputCpp("\t__mClass->mName = " + strq(classNameText) + ";\n");
		outputCpp("\t__mClass->mSuper = &super::__SGetClass();\n");
		if (!hasClassFlag(classDef, CAbstract)) {
			outputCpp("\t__mClass->mConstructEmpty = &__CreateEmpty;\n");
			outputCpp("\t__mClass->mConstructArgs = &__Create;\n");
		}
		outputCpp("\t__mClass->mGetStaticField = &"
			+ if (hasTcppClassFlag(tcppClass, StaticGet)) className + "::__GetStatic;\n" else "::hx::Class_obj::GetNoStaticField;\n");
		outputCpp("\t__mClass->mSetStaticField = &"
			+ if (hasTcppClassFlag(tcppClass, StaticSet)) className + "::__SetStatic;\n" else "::hx::Class_obj::SetNoStaticField;\n");
		if (tcppClass.tclStaticVariables.length > 0) outputCpp("\t__mClass->mMarkFunc = " + className + "_sMarkStatics;\n");
		outputCpp('\t__mClass->mStatics = ::hx::Class_obj::dupFunctions(${className}_sStaticFields);\n');
		outputCpp('\t__mClass->mMembers = ::hx::Class_obj::dupFunctions(${className}_sMemberFields);\n');
		outputCpp("\t__mClass->mCanCast = ::hx::TCanCast< " + className + " >;\n");
		if (tcppClass.tclStaticVariables.length > 0)
			outputCpp("#ifdef HXCPP_VISIT_ALLOCS\n\t__mClass->mVisitFunc = " + className + "_sVisitStatics;\n#endif\n");
		outputCpp("#ifdef HXCPP_SCRIPTABLE\n\t__mClass->mMemberStorageInfo = " + className + "_sMemberStorageInfo;\n#endif\n");
		outputCpp("#ifdef HXCPP_SCRIPTABLE\n\t__mClass->mStaticStorageInfo = " + className + "_sStaticStorageInfo;\n#endif\n");
		outputCpp("\t::hx::_hx_RegisterClass(__mClass->mName, __mClass);\n");
		if (scriptable) outputCpp("  HX_SCRIPTABLE_REGISTER_CLASS(\"" + classNameText + "\"," + className + ");\n");
		for (intfDef in tcppClass.tclNativeInterfaces)
			outputCpp("\tHX_REGISTER_VTABLE_OFFSET( " + className + "," + joinClassPathRemap(intfDef.ifClass.clPath, "::") + ");\n");
		outputCpp("}\n\n");

		genBootField(ctx, outputCpp, tcppClass);

		endNamespace(outputCpp, classPath);

		cppFile.close();
	}
}
