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
import generators.cpp.CppStrings.*;
import generators.cpp.CppTypeUtils.*;
import generators.cpp.CppAstTools.*;
import generators.cpp.CppSourceWriter;
import generators.cpp.CppSourceWriter.SourceWriter;
import generators.cpp.CppContext;
import generators.cpp.CppMarshalling.*;
import generators.cpp.CppError;
import generators.cpp.CppError.CppErrorKind;
import haxe.ds.Vector;

using core.ds.VectorTools;

@:structInit class TInject {
	public var injPrologue:Bool->Void;
	public var injSetvar:String;
	public var injTail:String;
}

class CppGen {
	public static function cppTypeOf(basic:BasicTypes, t:T):Tcpp return CppRetyper.cppTypeOf(basic, CppRetyper.withStackValueType, t);

	public static function cppTypeOfNull(basic:BasicTypes, handler:CppRetyper.ValueTypeHandler, t:T):Tcpp return CppRetyper.cppTypeOfNull(basic, handler, t);

	public static function cppInstanceType(basic:BasicTypes, klass:TClass, params:TParams, handler:CppRetyper.ValueTypeHandler):Tcpp
		return CppRetyper.cppInstanceType(basic, klass, params, handler);

	public static function typeToString(basic:BasicTypes, haxeType:T):String return tcppToString(cppTypeOf(basic, haxeType));

	public static function typeCantBeNull(tcpp:Tcpp):Bool return tcpp.match(TCppScalar(_));

	public static function typeArgToString(v:TcppVar, defaultVal:Null<TExpr>, prefix:String):{type:String, name:String} {
		var remapName = v.tcppvName;
		var typeStr = tcppToString(v.tcppvType);

		return switch defaultVal {
			case null: {type: typeStr, name: remapName};
			case {eexpr: TConst(TNull)}: {type: typeStr, name: remapName};
			case constant if (v.tcppvType.match(TCppScalar(_))):
				{type: "::hx::Null< " + typeStr + " > ", name: prefix + remapName};
			case constant: {type: typeStr, name: prefix + remapName};
		}
	}

	/* Generate prototype text, including allowing default values to be null */
	public static function printArg(v:TcppVar, defaultVal:Null<TExpr>, prefix:String):String {
		var r = typeArgToString(v, defaultVal, prefix);
		return r.type + " " + r.name;
	}

	/* Generate prototype text, including allowing default values to be null */
	public static function printArgName(v:TcppVar, defaultVal:Null<TExpr>, prefix:String):String return typeArgToString(v, defaultVal, prefix).name;

	public static function printArgList(argList:Array<TcppArg>, prefix:String):String
		return argList.map(function(a) return printArg(a.v, a.o, prefix)).join(",");

	public static function printArgListName(argList:Array<TcppArg>, prefix:String):String
		return argList.map(function(a) return printArgName(a.v, a.o, prefix)).join(",");

	public static function printArgNames(args:Array<TcppTfunArg>):String return args.map(function(arg) return arg.tfaName).join(", ");

	public static function printRetypedTfunArgList(includeNames:Bool, argList:Array<TcppTfunArg>):String {
		function oType(o:Bool, argType:Tcpp):String {
			var typeStr = tcppToString(argType);
			/* type_str may have already converted Null<X> to Dynamic because of NotNull tag ... */
			return if (o && typeCantBeNull(argType) && typeStr != "Dynamic") "::hx::Null< " + typeStr + " > " else typeStr;
		}
		return argList.map(function(arg) return oType(arg.tfaOptional, arg.tfaType) + (if (includeNames) " " + arg.tfaName else "")).join(",");
	}

	public static function cppMemberNameOf(member:TClassField):String {
		return switch Ast.getMetaString(member.cfMeta, Meta.Native) {
			case null: keywordRemap(member.cfName);
			case n: n;
		}
	}

	public static function functionSignature(basic:BasicTypes, includeNames:Bool, tfun:T, abi:String):String {
		function printTfunArgList(includeNames:Bool, argList:haxe.ds.Vector<{name:String, optional:Bool, type:T}>):String {
			return printRetypedTfunArgList(includeNames, argList.mapToArray(function(a) return CppRetyper.retypeArg(basic, CppRetyper.withStackValueType, a)));
		}

		return switch follow(tfun) {
			case TFun(sig):
				typeToString(basic, sig.ret) + " " + abi + "(" + printTfunArgList(includeNames, sig.args) + ")";
			case _: "void *";
		}
	}

	public static function cppNoDebugSynbol(ctx:Context, v:TcppVar):Bool {
		return ctx.ctxDebugLevel <= 1 || (switch v.tcppvVar.vKind {
			case VUser(_): false;
			case _: true;
		}) || switch v.tcppvType {
			case TCppStar(_) | TCppReference(_) | TCppMarshalNativeType(_): true;
			case TCppInst(classDef, _) if (Meta.has(Meta.StructAccess, classDef.clMeta)):
				true;
			case TCppInst(classDef, _) if (Meta.has(Meta.Unreflective, classDef.clMeta)):
				true;
			case _:
				var name = cppVarDebugNameOf(v.tcppvVar);
				name.length > 4 && name.substr(0, 4) == "_hx_";
		}
	}

	public static function cppDebugVarVisible(ctx:Context, v:TcppArg):Bool return !cppNoDebugSynbol(ctx, v.v);

	public static function cppCallableArgs(arguments:Array<TcppArg>, prefix:String):String {
		function makeArg(a:TcppArg):String {
			var ret = tcppToString(a.v.tcppvType);
			var prefixed = switch a.o {
				case null: a.v.tcppvName;
				case {eexpr: TConst(TNull)}: a.v.tcppvName;
				case _: prefix + a.v.tcppvName;
			}
			return ret + " " + prefixed;
		}
		return arguments.map(makeArg).join(",");
	}

	public static function cppCallableSignaure(closure:TcppClosure):String {
		var ret = tcppToString(closure.closeType);
		var arguments = cppCallableArgs(closure.closeArgs, "");
		return '$ret($arguments)';
	}

	public static function funcToCallableString(wrapper:String, func:TcppClassFunction):String {
		var returnStr = tcppToString(func.tcfReturn);
		var argumentsStr = func.tcfArgs.map(function(a) return a.v.tcppvType).map(tcppToString).join(",");

		return '$wrapper< $returnStr ($argumentsStr) >';
	}

	public static function mkInjection(prologue:Bool->Void, setVar:String, tail:String):Null<TInject>
		return {injPrologue: prologue, injSetvar: setVar, injTail: tail};

	public static function genType(ctx:Context, haxeType:T):Void ctx.ctxOutput(typeToString(ctx.ctxCommon.basic, haxeType));

	public static function cppMacroVarTypeOf(v:TcppVar):String {
		var t = tcppToString(v.tcppvType);
		return if (t.indexOf(",") >= 0) t.split(",").join(" HX_COMMA ") else t;
	}

	public static function cppClassName(klass:TClass):String {
		return if (isMarshallingNativeValueClass(klass)) getNativeMarshalledType(ValueClass(klass, [])) else
			if (isMarshallingNativePointer(klass)) getNativeMarshalledType(Pointer(klass, [])) else if (isMarshallingManagedClass(klass)) {
				var r = buildType(klass.clPath, klass.clPos, ([] : Array<Tcpp>), klass.clMeta, Meta.CppManagedType, tcppToString);
				var standardNaming = r.flags.indexOf("StandardNaming") >= 0;
				if (standardNaming) r.type + "_obj" else r.type;
			} else {
				var globalNamespace = switch Ast.getMetaString(klass.clMeta, Meta.Native) {
					case null: "::";
					case _: "";
				}
				var path = globalNamespace + joinClassPathRemap(klass.clPath, "::");
				if (isNativeClass(klass) || path == "::String") path else path + "_obj";
			}
	}

	public static function cppIsStaticExtension(member:TClassField):Bool return Meta.has(Meta.NativeStaticExtension, member.cfMeta);

	public static function cppEnumNameOf(field:TEnumField):String {
		return switch Ast.getMetaString(field.efMeta, Meta.Native) {
			case null: keywordRemap(field.efName);
			case n: n;
		}
	}

	public static function stringOfPath(path:GlobalTypePath):String return "::" + joinClassPathRemap(path, "::") + "_obj";

	public static function isRenderableConstant(value:TExpr):Bool {
		return switch value.eexpr {
			case TConst(_) | TField(_, FEnum(_)): true;
			case _: false;
		}
	}

	public static function defaultValueString(ctx:Gctx, value:TExpr):String {
		return switch value.eexpr {
			case TConst(TInt(i)): Std.string(i);
			case TConst(TFloat(floatAsString)):
				"((Float)" + core.Texpr.replaceSeparators(floatAsString, "") + ")";
			case TConst(TString(s)): strq(ctx, s);
			case TConst(TBool(b)): b ? "true" : "false";
			case TConst(TNull): "null()";
			case TField(_, FEnum(enumDef, field)):
				stringOfPath(enumDef.ePath) + "::" + cppEnumNameOf(field) + "_dyn()";
			case _: "/* Hmmm " + core.TPrinting.sExprKind(value) + " */";
		}
	}

	public static function cppClassHash(iface:TClass):String return genHash(0, joinClassPath(iface.clPath, "::"));

	public static function cppTemplateParam(path:GlobalTypePath, native:Bool):String {
		var path = "::" + joinClassPathRemap(path, "::");
		return if (native) path else switch path {
			case "::Array": "::hx::ArrayBase";
			case "::Int": "int";
			case "::Bool": "bool";
			case x: x;
		}
	}

	public static function isConstantZero(expr:TcppExpr):Bool {
		return switch expr.cppexpr {
			case CppFloat(x) if (core.ds.OcamlFloat.ofString(x) == 0.0): true;
			case CppInt(i) if (i == 0): true;
			case CppCastScalar(expr, _): isConstantZero(expr);
			case _: false;
		}
	}

	public static function cppIsConstScalarArray(arrayType:Tcpp, expressions:Array<TcppExpr>):Bool {
		return expressions.length > 0 && switch arrayType {
			case TCppScalarArray(_):
				Lambda.foreach(expressions, function(expr) return switch expr.cppexpr {
					case CppInt(_) | CppFloat(_) | CppString(_) | CppBool(_): true;
					case _: false;
				});
			case _: false;
		}
	}

	public static function listNum<A>(l:Array<A>):String return Std.string(l.length);

	/* This gets the class include order correct.  In the header files, we forward declare
		the class types so the header file does not have any undefined variables.
		In the cpp files, we include all the required header files, providing the actual
		types for everything.  This way there is no problem with circular class references.
	 */
	public static function genForwardDecl(writer:SourceWriter, classPath:GlobalTypePath, isNative:Bool):Void {
		var output = writer.write;
		switch classPath {
			case {pack: ["@verbatim"], name: file}: writer.write(CppSourceWriter.guardedInclude(file));
			case _:
				var name = remapClassPath(classPath).pack;
				output((if (isNative) "HX_DECLARE_NATIVE" else "HX_DECLARE_CLASS") + listNum(name) + "(");
				for (packagePart in name) output(packagePart + ",");
				output(classPath.name + ")\n");
		}
	}

	public static function formatCode(code:String):String return code.split("\r\n").join("\n");

	public static function getMetaStringFullFilename(meta:Metadata, key:core.MetaList.StrictMeta):String {
		for (m in meta) if (Meta.metaEq(key, m.meta)) {
			var pos = m.pos;
			return if (core.OcamlFilename.isRelative(pos.pfile)) core.Path.normalizePath(core.OcamlFilename.concat(core.OcamlFilename.sysGetcwd(), pos.pfile)) else pos.pfile;
		}
		return "";
	}

	public static function getMetaStringFullDirname(meta:Metadata, key:core.MetaList.StrictMeta):String {
		var name = getMetaStringFullFilename(meta, key);
		return try core.Path.normalizePath(core.OcamlFilename.dirname(name)) catch (_:core.ds.InvalidArgument) "";
	}

	public static function getCode(meta:Metadata, key:core.MetaList.StrictMeta):String {
		var code = switch Ast.getMetaString(meta, key) {
			case null: "";
			case s: s;
		}
		var magicVar = "${GENCPP_SOURCE_DIRECTORY}";
		var code = if (code.indexOf(magicVar) >= 0) {
			var sourceDirectory = getMetaStringFullDirname(meta, key);
			// port: ExtString.String.replace replaces the first occurrence.
			var idx = code.indexOf(magicVar);
			code.substr(0, idx) + sourceDirectory + code.substr(idx + magicVar.length);
		} else code;
		return if (code != "") formatCode(code) + "\n" else code;
	}

	public static function getClassCode(classDef:TClass, key:core.MetaList.StrictMeta):String {
		return switch classDef.clKind {
			case KAbstractImpl(abstractDef):
				var value = getCode(abstractDef.aMeta, key);
				value;
			case _: getCode(classDef.clMeta, key);
		}
	}

	public static function withDebug(ctx:Context, metadata:Metadata, run:Bool->Void):Void {
		var oldDebug = ctx.ctxDebugLevel;
		var noDebug = Meta.has(Meta.NoDebug, metadata);
		if (noDebug) ctx.ctxDebugLevel = 0;
		run(noDebug);
		ctx.ctxDebugLevel = oldDebug;
	}

	public static function hxStackPush(ctx:Context, output:String->Void, clazz:String, funcName:String, pos:Pos, gcStack:Bool):Void {
		if (ctx.ctxDebugLevel > 0) {
			var strippedFile = CppContext.stripFile(ctx.ctxCommon, pos.pfile);
			var escFile = core.StringHelper.sEscape(strippedFile);
			ctx.ctxFileInfo.value = core.ds.PMap.add(strippedFile, pos.pfile, ctx.ctxFileInfo.value);
			var fullName = clazz + "." + funcName + if (clazz == "*") " (" + escFile + ":" + Std.string(syntax.Lexer.getErrorLine(pos)) + ")" else "";

			var hashClassFunc = genHash(0, clazz + "." + funcName);
			var hashFile = genHash(0, strippedFile);

			var lineName = Std.string(syntax.Lexer.getErrorLine(pos));
			ctx.ctxFileId.value++;
			var classId = hash64(clazz + "." + strippedFile);
			var varName = "_hx_pos_" + classId + "_" + lineName + "_" + funcName;
			var decl = varName + ",\"" + clazz + "\",\"" + funcName + "\"," + hashClassFunc + ",\"" + fullName + "\",\"" + escFile + "\"," + lineName + ","
				+ hashFile;
			if (ctx.ctxIsHeader) ctx.ctxWriter.writeHUnique("HX_DECLARE_STACK_FRAME" + "(" + varName + ")\n") else
				ctx.ctxWriter.writeHUnique((if (funcName == "new") "HX_DEFINE_STACK_FRAME" else "HX_LOCAL_STACK_FRAME") + "(" + decl + ")\n");
			output((if (gcStack) "HX_GC_STACKFRAME" else "HX_STACKFRAME") + "(&" + varName + ")\n");
		} else if (gcStack) output("HX_JUST_GC_STACKFRAME\n");
	}

	/* Add include to source code */
	public static function addInclude(writer:SourceWriter, classPath:GlobalTypePath):Void writer.addInclude(classPath);

	public static function canInlineConstructor(baseCtx:Context, classDef:TClass):Bool {
		return switch classDef.clConstructor {
			case null: true;
			case {cfExpr: null}: true;
			case {cfExpr: superFunc}:
				var isSimple = true;
				function checkSimple(e:TExpr):Void {
					switch e.eexpr {
						case TReturn(_): isSimple = false;
						case TArrayDecl(e) if (e.length > 0): isSimple = false;
						case _:
					}
					if (isSimple) core.Texpr.iter(checkSimple, e);
				}
				checkSimple(superFunc);
				isSimple && {
					function knownClasses(classDef:TClass, soFar:Array<GlobalTypePath>):Array<GlobalTypePath> {
						return switch classDef.clSuper {
							case null: soFar;
							case sup: knownClasses(sup.cls, [sup.cls.clPath].concat(soFar));
						}
					}
					var allowed = knownClasses(classDef, [classDef.clPath]);
					/* Check to see if all the types required by the constructor are already in the header */
					/* This is quite restrictive, since most classes are forward-declared */
					var deps = CppReferences.findReferencedTypesFlags(baseCtx, TClassDecl(classDef), "new", baseCtx.ctxSuperDeps, baseCtx.ctxConstructorDeps,
						false, false, true).deps;
					Lambda.foreach(deps, function(dep) return Lambda.exists(allowed, function(a) return pathEq(dep, a)));
				}
		}
	}

	// port: structural equality on paths.
	public static function pathEq(a:GlobalTypePath, b:GlobalTypePath):Bool {
		if (a.name != b.name || a.pack.length != b.pack.length) return false;
		for (i in 0...a.pack.length) if (a.pack[i] != b.pack[i]) return false;
		return true;
	}

	public static function beginNamespace(output:String->Void, classPath:GlobalTypePath):Void {
		for (namespace in classPath.pack.map(keywordRemap)) output("namespace " + namespace + "{\n");
	}

	public static function endNamespace(output:String->Void, classPath:GlobalTypePath):Void {
		for (namespace in classPath.pack) output("}" + " // end namespace " + namespace + "\n");
	}

	public static function beginHeaderFile(outputH:String->Void, defString:String, nativeGen:Bool):Void {
		outputH("#ifndef INCLUDED_" + defString + "\n");
		outputH("#define INCLUDED_" + defString + "\n\n");
		outputH("#ifndef HXCPP_H\n");
		if (nativeGen) {
			outputH("#ifdef HXCPP_API_LEVEL\n");
			outputH("#include <hxcpp.h>\n");
			outputH("#else\n");
			outputH("#include <hx/Native.h>\n");
			outputH("#endif\n");
		} else outputH("#include <hxcpp.h>\n");
		outputH("#endif\n\n");
	}

	public static function endHeaderFile(outputH:String->Void, defString:String):Void {
		outputH("\n#endif /* INCLUDED_" + defString + " */ \n");
	}

	public static function cppTfunSignature(includeNames:Bool, args:Array<TcppTfunArg>, returnType:Tcpp):String {
		var argList = printRetypedTfunArgList(includeNames, args);
		var returnType = tcppToString(returnType);
		return "( " + returnType + " (::hx::Object::*)(" + argList + "))";
	}

	public static function findClassImplementation(func:TcppInterfaceFunction, tcppClass:TcppClass):String {
		function find(def:TcppClass):Null<TcppClassFunction> {
			return switch Lambda.find(def.tclFunctions, function(f) return f.tcfName == func.iffName) {
				case null:
					switch def.tclSuper {
						case null: null;
						case s: find(s);
					}
				case f: f;
			}
		}

		return switch find(tcppClass) {
			case null: "";
			case func: printArgList(func.tcfArgs, "");
		}
	}

	public static function genGcName(classPath:GlobalTypePath):String {
		var classNameText = joinClassPath(classPath, ".");
		return constCharStar(classNameText);
	}

	public static function neededInterfaceFunctions(implementedInstanceFields:Array<TcppClassFunction>,
			nativeImplementations:Array<TcppInterface>):Array<TcppInterfaceFunction> {
		var have = new haxe.ds.StringMap<Bool>();
		for (func in implementedInstanceFields) have.set(func.tcfName, true);
		var acc = [];
		for (iface in nativeImplementations) for (func in iface.ifFunctions) {
			if (!have.exists(func.iffName)) {
				have.set(func.iffName, true);
				acc = [func].concat(acc);
			}
		}
		return acc;
	}

	public static function genCppAstExpressionTree(ctx:Context, className:String, funcName:String, functionArgs:Array<TcppArg>, functionType:Tcpp,
			injection:Null<TInject>, tree:TExpr):Void {
		new ExprGenerator(ctx, className, funcName, functionArgs, functionType, injection, tree).run();
	}

	public static function cppGenDefaultValues(ctx:Context, dotName:String, funcName:String, args:Array<TcppArg>, prefix:String):Void {
		for (a in args) {
			var v = a.v, o = a.o;
			var notNull = typeHasMetaKey(Meta.NotNull, v.tcppvVar.vType) || isCppScalar(v.tcppvType);
			var spacer = if (ctx.ctxDebugLevel > 0) "            \t" else "";
			var pname = prefix + v.tcppvName;
			var vname = v.tcppvName;
			var tname = tcppToString(v.tcppvType);
			switch o {
				case null:
				case {eexpr: TConst(TNull)}:
				case const if (isRenderableConstant(const)):
					ctx.ctxOutput(spacer + "\t" + tname + " " + vname + " = " + pname);
					ctx.ctxOutput(if (notNull) ".Default(" + defaultValueString(ctx.ctxCommon, const) + ");\n" else
						";\n" + spacer + "\tif (::hx::IsNull(" + pname + ")) " + vname + " = " + defaultValueString(ctx.ctxCommon, const) + ";\n");
				case const:
					function genAssign():Void {
						genDefaultValueExpr(ctx, dotName, funcName, v.tcppvType, vname + " = ", const);
					}
					if (notNull) {
						ctx.ctxOutput(spacer + "\t" + tname + " " + vname + ";\n");
						ctx.ctxOutput(spacer + "\tif (::hx::IsNull(" + pname + ")) ");
						genAssign();
						ctx.ctxOutput(spacer + "\telse " + vname + " = " + pname + ";\n");
					} else {
						ctx.ctxOutput(spacer + "\t" + tname + " " + vname + " = " + pname + ";\n");
						ctx.ctxOutput(spacer + "\tif (::hx::IsNull(" + pname + ")) ");
						genAssign();
					}
			}
		}
	}

	public static function genDefaultValueExpr(ctx:Context, dotName:String, funcName:String, ftype:Tcpp, lhs:String, expr:TExpr):Void {
		var injection = mkInjection(function(_) {}, lhs, "");
		genCppAstExpressionTree(ctx, dotName, funcName, [], ftype, injection, mkBlock(expr));
	}

	public static function genCppInit(ctx:Context, dotName:String, funcName:String, varName:String, expr:TExpr):Void {
		var output = ctx.ctxOutput;
		function prologue(gcStack:Bool):Void {
			var spacer = if (ctx.ctxDebugLevel > 0) "            \t" else "\t";
			function outputI(s:String) output(spacer + s);
			hxStackPush(ctx, outputI, dotName, funcName, expr.epos, gcStack);
		}
		var injection = mkInjection(prologue, varName, "");
		genCppAstExpressionTree(ctx, dotName, funcName, [], TCppDynamic, injection, mkBlock(expr));
	}

	public static function generateMainHeader(outputMain:String->Void):Void {
		outputMain("#include <hxcpp.h>\n\n");
		outputMain("#include <stdio.h>\n\n");
		outputMain("extern \"C\" void __hxcpp_main();\n\n");
		outputMain("extern \"C\" void __hxcpp_lib_main();\n\n");
	}

	public static function generateMainFooter1(outputMain:String->Void):Void outputMain("void __hxcpp_main() {\n");

	public static function generateMainFooter2(outputMain:String->Void):Void {
		outputMain("\t}\n\n");
		outputMain("void __hxcpp_lib_main() {\n");
		outputMain("\tHX_TOP_OF_STACK\n");
		outputMain("\t::hx::Boot();\n");
		outputMain("\t__boot_all();\n");
		outputMain("\t__hxcpp_main();\n");
		outputMain("\t}\n");
	}

	public static function generateMain(ctx:Context, superDeps:PathMap<Array<GlobalTypePath>>, classDef:TClass):Void {
		var commonCtx = ctx.ctxCommon;
		/* main routine should be a single static function */
		var mainExpression = switch classDef.clOrderedStatics {
			case [{cfExpr: expression}] if (expression != null): expression;
			case _: die("", "cppGen.ml");
		}
		CppReferences.findReferencedTypes(ctx, TClassDecl(classDef), superDeps, PathMap.empty(), false, false, false);
		var dependReferenced = CppReferences.findReferencedTypes(ctx, TClassDecl(classDef), superDeps, PathMap.empty(), false, true, false);
		function generateStartup(filename:String, isMain:Bool):Void {
			/*make_class_directories base_dir ( "src" :: []);*/
			var cppFile = CppSourceWriter.newCppFile(commonCtx, commonCtx.file, {pack: [], name: filename});
			var outputMain = cppFile.write;

			generateMainHeader(cppFile.writeH);

			for (p in dependReferenced) addInclude(cppFile, p);
			outputMain("\n\n");

			if (isMain) outputMain("\n#include <hx/HxcppMain.h>\n\n");

			generateMainFooter1(outputMain);

			var ctx = CppContext.fileContext(ctx, cppFile, 1, false);
			genCppInit(ctx, "hxcpp", "__hxcpp_main", "", mainExpression);

			generateMainFooter2(outputMain);
			cppFile.close();
		}
		generateStartup("__main__", true);
		generateStartup("__lib__", false);
	}

	public static function generateDummyMain(commonCtx:Gctx):Void {
		function generateStartup(filename:String, isMain:Bool):Void {
			var mainFile = CppSourceWriter.newCppFile(commonCtx, commonCtx.file, {pack: [], name: filename});
			var outputMain = mainFile.write;
			generateMainHeader(mainFile.writeH);
			if (isMain) outputMain("\n#include <hx/HxcppMain.h>\n\n");
			generateMainFooter1(outputMain);
			generateMainFooter2(outputMain);
			mainFile.close();
		}
		generateStartup("__main__", true);
		generateStartup("__lib__", false);
	}

	public static function generateBoot(ctx:Context, bootEnums:Array<GlobalTypePath>, bootClasses:Array<GlobalTypePath>, nonbootClasses:Array<GlobalTypePath>,
			initClasses:Array<GlobalTypePath>, slots:InterfaceSlots):Void {
		var commonCtx = ctx.ctxCommon;
		/* Write boot class too ... */
		var baseDir = commonCtx.file;
		var bootFile = CppSourceWriter.newCppFile(commonCtx, baseDir, {pack: [], name: "__boot__"});
		var outputBoot = bootFile.write;
		bootFile.writeH("#include <hxcpp.h>\n\n");

		for (classPath in bootEnums.concat(bootClasses).concat(nonbootClasses)) bootFile.addInclude(classPath);

		var newScriptable = Gctx.defined(commonCtx, Define.Scriptable);
		if (newScriptable) {
			outputBoot("#include <hx/Scriptable.h>\n");

			var funcs = [for (k in core.ds.PMap.keys(slots.hash)) {name: k, id: slots.hash.get(k)}];
			var sorted = listSort(function(a:{name:String, id:Int}, b:{name:String, id:Int}) return a.id - b.id, funcs);
			outputBoot("static const char *scriptableInterfaceFuncs[] = {\n\t0,\n\t0,\n");
			for (f in sorted) outputBoot("\t\"" + f.name + "\", //" + Std.string(-f.id) + "\n");
			outputBoot("};\n");
		}

		outputBoot("\nvoid __files__boot();\n");
		outputBoot("\nvoid __boot_all()\n{\n");
		outputBoot("__files__boot();\n");
		outputBoot("::hx::RegisterResources( ::hx::GetResources() );\n");
		if (newScriptable) outputBoot("::hx::ScriptableRegisterNameSlots(scriptableInterfaceFuncs," + Std.string(slots.next) + ");\n");

		for (classPath in bootEnums.concat(bootClasses).concat(nonbootClasses))
			outputBoot("::" + joinClassPathRemap(classPath, "::") + "_obj::__register();\n");

		function dumpBoot(l:Array<GlobalTypePath>) for (classPath in l) outputBoot("::" + joinClassPathRemap(classPath, "::") + "_obj::__boot();\n");

		dumpBoot(bootEnums);

		var revInit = initClasses.copy();
		revInit.reverse();
		for (classPath in revInit) outputBoot("::" + joinClassPathRemap(classPath, "::") + "_obj::__init__();\n");

		function isCppClass(p:GlobalTypePath):Bool {
			return switch p {
				case _ if (p.pack.length > 0 && p.pack[0] == "cpp"): true;
				case {pack: [], name: "EReg"}: true;
				case {pack: ["haxe"], name: "Log"}: true;
				case _: false;
			}
		}

		var revBoot = bootClasses.copy();
		revBoot.reverse();
		dumpBoot(revBoot.filter(function(path) return isCppClass(path)));
		dumpBoot(revBoot.filter(function(path) return !isCppClass(path)));

		outputBoot("}\n\n");
		bootFile.close();
	}

	public static function generateFiles(commonCtx:Gctx, fileInfo:FileInfo):Void {
		/* Write __files__ class too ... */
		var baseDir = commonCtx.file;
		var filesFile = CppSourceWriter.newCppFile(commonCtx, baseDir, {pack: [], name: "__files__"});
		var outputFiles = filesFile.write;
		var types = commonCtx.types;
		filesFile.writeH("#include <hxcpp.h>\n\n");
		outputFiles("namespace hx {\n");
		outputFiles("const char *__hxcpp_all_files[] = {\n");
		outputFiles("#ifdef HXCPP_DEBUGGER\n");
		for (file in listSort(stringCompare, CppContext.pmapKeys(fileInfo.value))) outputFiles(constCharStar(file) + ",\n");
		outputFiles("#endif\n");
		outputFiles(" 0 };\n");
		outputFiles("\n");

		outputFiles("const char *__hxcpp_all_files_fullpath[] = {\n");
		outputFiles("#ifdef HXCPP_DEBUGGER\n");
		for (file in listSort(stringCompare, CppContext.pmapKeys(fileInfo.value)))
			outputFiles(constCharStar(core.Path.getFullPath(CppContext.findFileOr(commonCtx, file))) + ",\n");
		outputFiles("#endif\n");
		outputFiles(" 0 };\n");
		outputFiles("\n");

		outputFiles("const char *__hxcpp_all_classes[] = {\n");
		outputFiles("#ifdef HXCPP_DEBUGGER\n");
		for (objectDef in types) switch objectDef {
			case TClassDecl(classDef) if (isExternClass(classDef)):
			case TClassDecl(classDef) if (hasClassFlag(classDef, CInterface)):
			case TClassDecl(classDef):
				outputFiles(constCharStar(joinClassPath(classDef.clPath, ".")) + ",\n");
			case _:
		}
		outputFiles("#endif\n");
		outputFiles(" 0 };\n");

		outputFiles("} // namespace hx\n");
		outputFiles("void __files__boot() { __hxcpp_set_debugger_info(::hx::__hxcpp_all_classes, ::hx::__hxcpp_all_files_fullpath); }\n");

		filesFile.close();
	}

	public static function genCppFunctionBody(ctx:Context, clazz:TClass, isStatic:Bool, funcName:String, functionDef:TcppClassFunction, headCode:String,
			tailCode:String, noDebug:Bool):Void {
		var output = ctx.ctxOutput;
		var dotName = joinClassPath(clazz.clPath, ".");
		if (noDebug) ctx.ctxDebugLevel = 0;
		function prologue(gcStack:Bool):Void {
			var spacer = if (noDebug) "\t" else "            \t";
			function outputI(s:String) output(spacer + s);
			cppGenDefaultValues(ctx, dotName, funcName, functionDef.tcfArgs, "__o_");
			hxStackPush(ctx, outputI, dotName, funcName, functionDef.tcfFunc.tfExpr.epos, gcStack);
			if (ctx.ctxDebugLevel >= 2) {
				if (!isStatic) outputI("HX_STACK_THIS(" + (if (ctx.ctxRealThisPtr) "this" else "__this") + ")\n");
				for (a in functionDef.tcfArgs) if (!cppNoDebugSynbol(ctx, a.v)) outputI("HX_STACK_ARG(" + a.v.tcppvName + ",\"" + a.v.tcppvDebugName + "\")\n");

				var line = syntax.Lexer.getErrorLine(functionDef.tcfFunc.tfExpr.epos);
				var lineName = StringTools.lpad(Std.string(line), " ", 4);
				output("HXLINE(" + lineName + ")\n");
			}
			if (headCode != "") outputI(headCode + "\n");
		}

		var injection = mkInjection(prologue, "", tailCode);
		genCppAstExpressionTree(ctx, dotName, funcName, functionDef.tcfArgs, functionDef.tcfReturn, injection, mkBlock(functionDef.tcfFunc.tfExpr));
	}

	public static function constructorArgVarList(tcppClass:TcppClass):Array<{type:String, name:String}> {
		return switch tcppClass.tclConstructor {
			case null: [];
			case constructor:
				constructor.tcfArgs.map(function(a) return typeArgToString(a.v, a.o, "__o_"));
			/* | Some definition ->
				(match follow definition.cf_type with
				| TFun (args, _) -> List.map (fun (a, _, t) -> type_to_string t, a) args
				| _ -> []) */
		}
	}

	public static function generateConstructor(ctx:Context, out:String->Void, tcppClass:TcppClass, isHeader:Bool):Void {
		var className = tcppClass.tclName;
		var ptrName = classPointer(tcppClass.tclClass);
		var canQuickAlloc = hasTcppClassFlag(tcppClass, QuickAlloc);
		var gcName = genGcName(tcppClass.tclClass.clPath);
		var cargs = constructorArgVarList(tcppClass);
		var constructorTypeArgs = cargs.map(function(a) return a.type + " " + a.name).join(",");
		var constructorVarList = cargs.map(function(a) return a.name);
		var constructorArgs = constructorVarList.join(",");

		var classScope = if (isHeader) "" else className + "::";
		var staticHead = if (isHeader) "inline static " else "";
		out(staticHead + ptrName + " " + classScope + "__new(" + constructorTypeArgs + ") {\n");
		out("\t" + ptrName + " __this = new " + className + "();\n");
		out("\t__this->__construct(" + constructorArgs + ");\n");
		out("\treturn __this;\n");
		out("}\n\n");

		if (canQuickAlloc) {
			out(staticHead + ptrName + " " + classScope + "__alloc(::hx::Ctx *_hx_ctx" + (if (constructorTypeArgs == "") "" else "," + constructorTypeArgs)
				+ ") {\n");
			out('\t$className* __this = ($className*)(::hx::Ctx::alloc(_hx_ctx, sizeof($className), ${tcppClass.tclContainer != null}, $gcName));\n');
			out("\t*(void **)__this = " + className + "::_hx_vtable;\n");
			function dumpDynamic(classDef:TClass):Void {
				if (hasDynamicMemberFunctions(classDef)) out("\t" + joinClassPathRemap(classDef.clPath, "::") + "_obj::__alloc_dynamic_functions(_hx_ctx,__this);\n") else
					switch classDef.clSuper {
						case null:
						case sup: dumpDynamic(sup.cls);
					}
			}
			dumpDynamic(tcppClass.tclClass);

			if (isHeader) switch tcppClass.tclConstructor {
				case null:
				case constructor:
					function cb(noDebug:Bool):Void {
						ctx.ctxRealThisPtr = false;
						genCppFunctionBody(ctx, tcppClass.tclClass, false, "new", constructor, "", "", noDebug);
						out("\n");
					}
					withDebug(ctx, constructor.tcfField.cfMeta, cb);
			} else out("\t__this->__construct(" + constructorArgs + ");\n");

			out("\treturn __this;\n");
			out("}\n\n");
		}
	}

	public static function generateNativeConstructor(ctx:Context, out:String->Void, tcppClass:TcppClass, isHeader:Bool):Void {
		var constructorTypeArgs = constructorArgVarList(tcppClass).map(function(a) return '${a.type} ${a.name}').join(",");

		switch tcppClass.tclConstructor {
			case null:
			case constructor:
				if (isHeader) out("\t\t" + tcppClass.tclName + "(" + constructorTypeArgs + ");\n\n") else {
					function cb(noDebug:Bool):Void {
						ctx.ctxRealThisPtr = true;
						out(tcppClass.tclName + "::" + tcppClass.tclName + "(" + constructorTypeArgs + ")");

						switch tcppClass.tclSuper {
							case null:
							case klass:
								function findSuperArgs(l:Array<TExprDef>):Null<Vector<TExpr>> {
									return switch l {
										case [] : null;
										case _:
											var rest = l.slice(1);
											switch l[0] {
												case TCall({eexpr: TConst(TSuper)}, args): args;
												case TParenthesis(e) | TMeta(_, e) | TCast(e, null):
													findSuperArgs([e.eexpr].concat(rest));
												case TBlock(e):
													findSuperArgs(e.mapToArray(function(e) return e.eexpr).concat(rest));
												case _: findSuperArgs(rest);
											}
									}
								}
								switch findSuperArgs([constructor.tcfFunc.tfExpr.eexpr]) {
									case null:
									case args:
										out("\n:" + (cppClassPathOf(klass.tclClass, [])) + "(");
										var sep = "";
										for (arg in args) {
											out(sep);
											sep = ",";
											genCppAstExpressionTree(ctx, "", "", [], TCppDynamic, null, arg);
										}
										out(")\n");
								}
						}

						var headCode = getCode(constructor.tcfField.cfMeta, Meta.FunctionCode);
						var tailCode = getCode(constructor.tcfField.cfMeta, Meta.FunctionTailCode);
						genCppFunctionBody(ctx, tcppClass.tclClass, false, "new", constructor, headCode, tailCode, noDebug);
					}
					withDebug(ctx, constructor.tcfField.cfMeta, cb);
				}
		}
	}
}

// port: the closures of `gen_cpp_ast_expression_tree`, sharing its arguments.
private class ExprGenerator {
	final ctx:Context;
	final className:String;
	final funcName:String;
	final injection:Null<TInject>;
	final tree:TExpr;
	final writer:SourceWriter;
	final out:String->Void;
	var lastLine = -1;
	var tempId = 0;
	final spacer:String;
	final cppTree:TcppExpr;
	final classHash:String;

	public function new(ctx:Context, className:String, funcName:String, functionArgs:Array<TcppArg>, functionType:Tcpp, injection:Null<TInject>,
			tree:TExpr) {
		this.ctx = ctx;
		this.className = className;
		this.funcName = funcName;
		this.injection = injection;
		this.tree = tree;
		writer = ctx.ctxWriter;
		out = ctx.ctxOutput;
		spacer = if (ctx.ctxDebugLevel > 0) "            \t" else "";
		var forInjection = switch injection {
			case null: false;
			case inject: inject.injSetvar != "";
		}
		cppTree = CppRetyper.expression(ctx, TCppVoid, functionArgs, functionType, tree, forInjection);
		classHash = genHashSmall(0, className);
	}

	public function run():Void genWithInjection(injection, cppTree, true);

	inline function strq(s:String):String return CppStrings.strq(ctx.ctxCommon, s);

	inline function cppTypeOf(t:T):Tcpp return CppGen.cppTypeOf(ctx.ctxCommon.basic, t);

	function outputI(value:String):Void {
		out(spacer);
		writer.writeI(value);
	}

	function outputP(expr:TcppExpr, value:String):Void {
		if (ctx.ctxDebugLevel > 0) {
			var line = syntax.Lexer.getErrorLine(expr.cpppos);
			var lineName = StringTools.lpad(Std.string(line), " ", 4);
			var macro_ = if (line != lastLine) "HXLINE" else "HXDLIN";
			out(macro_ + "(" + lineName + ")\t");
			lastLine = line;
		}
		writer.writeI(value);
	}

	static function labelName(i:Int):String return '_hx_goto_$i';

	function genWithInjection(injection:Null<TInject>, expr:TcppExpr, newLine:Bool):Void {
		switch expr.cppexpr {
			case CppBlock(exprs, closures, gcStack):
				writer.beginBlock();
				for (c in closures) genClosure(c);
				switch injection {
					case null:
					case inject: inject.injPrologue(gcStack);
				}
				var remaining = exprs.length;
				lastLine = syntax.Lexer.getErrorLine(tree.epos);
				for (e in exprs) {
					outputP(e, "");
					if (remaining == 1) switch injection {
						case null:
						case inject: out(inject.injSetvar);
					}
					gen(e);
					remaining--;
					writer.terminateLine();
				}
				switch injection {
					case null:
					case inject: out(inject.injTail);
				}
				out(spacer);
				if (newLine) writer.endBlock() else writer.endBlockLine();
			case CppInt(i):
				out(if (i > -1000000000 && i < 1000000000) Std.string(i) else "(int)" + Std.string(i));
			case CppFloat(floatAsString): out("((Float)" + floatAsString + ")");
			case CppString(s): out(strq(s));
			case CppBool(b): out(if (b) "true" else "false");
			case CppNull: out("null()");
			case CppNil: out("nil");
			case CppThis(ThisReal): out("::hx::ObjectPtr<OBJ_>(this)");
			case CppThis(_): out("__this");
			case CppSuper(thiscall):
				out("::hx::ObjectPtr<super>(" + (if (thiscall == ThisReal) "this" else "__this.mPtr") + ")");
			case CppBreak: out("break");
			case CppContinue: out("continue");
			case CppGoto(label): out("goto " + labelName(label));
			case CppVarDecl(v, init):
				if (CppGen.cppNoDebugSynbol(ctx, v)) out(tcppToString(v.tcppvType) + " " + v.tcppvName) else {
					var dbgName = cppVarDebugNameOf(v.tcppvVar);
					var macro_ = if (init == null) "HX_VAR" else "HX_VARI";
					var varType = CppGen.cppMacroVarTypeOf(v);
					if (v.tcppvName != dbgName) out(macro_ + "_NAME( " + varType + "," + v.tcppvName + ",\"" + dbgName + "\")") else
						out(macro_ + "( " + varType + "," + v.tcppvName + ")");
				}
				switch init {
					case null:
					case init:
						out(" = ");
						gen(init);
				}
			case CppEnumIndex(obj):
				gen(obj);
				if (cppIsDynamicType(obj.cpptype)) out(".StaticCast< ::hx::EnumBase >()");
				out("->_hx_getIndex()");
			case CppNullAccess: out("::hx::Throw(" + strq("Null access") + ")");
			case CppFunction(func, tcpp):
				switch func {
					case FuncThis(field, _):
						out("this->" + CppGen.cppMemberNameOf(field) + "_dyn()");
					case FuncInstance(expr, inst, field, _):
						/* array map is a special case as it is implemented as a templated function */
						/* so we need to figure out the target array type of the map function to generate the template params */
						var templateExtra = if (field.cfName == "map") {
							switch inst {
								case InstPtr(TCppObjectArray(_)) | InstPtr(TCppScalarArray(_)) | InstPtr(TCppDynamicArray):
									switch tcpp {
										case TCppObjectArray(el) | TCppScalarArray(el):
											'< ${tcppToString(el)} >';
										case TCppDynamicArray:
											tcppToString(TCppDynamic);
										case _:
											CppError.cppAbort(InternalError, expr.cpppos);
									}
								case _:
									"";
							}
						} else "";
						var access = if (expr.cpptype.match(TCppString) || inst.match(InstStruct)) "." else "->";
						gen(expr);
						out('$access${CppGen.cppMemberNameOf(field)}_dyn$templateExtra()');
					case FuncInterface(expr, _, field):
						gen(expr);
						out("->__Field(" + strq(field.cfName) + ", ::hx::paccDynamic)");
					case FuncStatic(clazz, _, field, _):
						switch Ast.getMetaString(field.cfMeta, Meta.Native) {
							case null:
								out(CppGen.cppClassName(clazz));
								out("::" + CppGen.cppMemberNameOf(field) + "_dyn()");
							case n: out(n);
						}
					case FuncExpression(expr): gen(expr);
					case FuncExtern(name, isGlobal):
						if (isGlobal) out(" ::");
						out(name);
					case FuncInternal(expr, name, _):
						gen(expr);
						out("->__Field(" + strq(name) + ",::hx::paccDynamic)");
					case FuncSuper(_) | FuncSuperConstruct(_):
						core.Error.abort("Can't create super closure", expr.cpppos);
					case FuncNew(_): core.Error.abort("Can't create new closure", expr.cpppos);
					case FuncEnumConstruct(_):
						core.Error.abort("Enum constructor outside of CppCall", expr.cpppos);
					case FuncFromStaticFunction:
						core.Error.abort("Can't create cpp.Function.fromStaticFunction closure", expr.cpppos);
					case FuncTemplate(_):
						core.Error.abort("Can't create template function closure", expr.cpppos);
				}
			case CppCall(FuncInterface(expr, clazz, field), args) if (!isNativeGenClass(clazz)):
				out(CppGen.cppClassName(clazz) + "::" + CppGen.cppMemberNameOf(field) + "(");
				gen(expr);
				for (arg in args) {
					out(",");
					gen(arg);
				}
				out(")");
			case CppCall(func = FuncStatic(_, true, field, _), argList) | CppCall(func = FuncInstance(_, InstObjC, field, _), argList):
				out("[ ");
				switch func {
					case FuncStatic(cl, _, _, _): out(joinClassPathRemap(cl.clPath, "::"));
					case FuncInstance(expr, _, _, params): gen(expr);
					case _:
				}

				var names = field.cfName.split(":");
				var fieldName = names[0], argNames = names.slice(1);
				out(" " + fieldName);
				switch argList {
					case []:
					case [singleArg]:
						out(": ");
						gen(singleArg);
					case _:
						var firstArg = argList[0], args = argList.slice(1);
						out(": ");
						gen(firstArg);
						// port: List.iter2 raises Invalid_argument (after the common prefix) on lists of different lengths.
						var n = args.length < argNames.length ? args.length : argNames.length;
						for (i in 0...n) {
							out(" " + argNames[i] + ": ");
							gen(args[i]);
						}
						if (args.length != argNames.length) {
							/* not all arguments names are known */
							core.Error.abort("The function called here with name " + names.join(":")
								+ " does not contain the right amount of arguments' names as required"
								+ " by the objective-c calling / naming convention:" + " expected " + Std.string(argList.length) + " and found "
								+ Std.string(argNames.length),
								expr.cpppos);
						}
				}
				out(" ]");
			case CppCall(FuncNew(TCppInst(klass, p)), args) if (canQuickAlloc(klass)):
				out(cppClassPathOf(klass, p) + "_obj::__alloc( HX_CTX ");
				for (arg in args) {
					out(",");
					gen(arg);
				}
				out(")");
			case CppCall(func, args):
				var doCall = true;
				var closeCall = "";
				var argsRef = args;
				switch func {
					case FuncThis(field, _): out("this->" + CppGen.cppMemberNameOf(field));
					case FuncInstance(expr, inst, field, templateTypes):
						var op = if (expr.cpptype.match(TCppString) || inst.match(InstStruct)) "." else "->";
						function printer(tcpp:Tcpp):String {
							return switch tcpp {
								case TCppMarshalNativeType(valueType = Pointer(_), _): getNativeMarshalledType(valueType) + "*";
								case TCppMarshalNativeType(valueType, _): getNativeMarshalledType(valueType);
								case other: tcppToString(other);
							}
						}
						var template = switch templateTypes {
							case []: "";
							case types: '< ${types.map(printer).join(", ")} >';
						}
						gen(expr);
						out(op + CppGen.cppMemberNameOf(field) + template);
					case FuncInterface(expr, _, field):
						gen(expr);
						out("->" + CppGen.cppMemberNameOf(field));
					case FuncStatic(clazz, false, field, _) if (CppGen.cppIsStaticExtension(field)):
						switch args {
							case []:
								core.Error.abort("Native static extensions must have at least 1 argument", expr.cpppos);
							case _:
								argsRef = args.slice(1);
								gen(args[0]);
								out("->" + CppGen.cppMemberNameOf(field));
						}
					case FuncStatic(clazz, _, field, templateTypes) if (isMarshallingNativeValueClass(clazz) || isMarshallingNativePointer(clazz)):
						var funcName = switch Ast.getMetaString(field.cfMeta, Meta.Native) {
							case null: CppGen.cppMemberNameOf(field);
							case renamed: renamed;
						}
						function printer(tcpp:Tcpp):String {
							return switch tcpp {
								case TCppMarshalNativeType(valueType = Pointer(_), _): getNativeMarshalledType(valueType) + "*";
								case TCppMarshalNativeType(valueType, _): getNativeMarshalledType(valueType);
								case other: tcppToString(other);
							}
						}
						var template = switch templateTypes {
							case []: "";
							case types: '< ${types.map(printer).join(", ")} >';
						}
						out('${CppGen.cppClassName(clazz)}::$funcName$template');
					case FuncStatic(clazz, _, field, _):
						switch Ast.getMetaString(field.cfMeta, Meta.Native) {
							case null:
								out(CppGen.cppClassName(clazz));
								out("::" + CppGen.cppMemberNameOf(field));
							case rename:
								/* This is the case if you use @:native('new foo').  c++ wil group the space undesirably */
								if (rename.indexOf(" ") >= 0) {
									out("(");
									closeCall = ")";
								}
								out(rename);
						}
					case FuncTemplate(clazz, field, tpath, native):
						switch Ast.getMetaString(field.cfMeta, Meta.Native) {
							case null:
								out(CppGen.cppClassName(clazz));
								out("::" + CppGen.cppMemberNameOf(field));
							case rename:
								/* This is the case if you use @:native('new foo').  c++ wil group the space undesirably */
								if (rename.indexOf(" ") >= 0) {
									out("(");
									closeCall = ")";
								}
								out(rename);
						}
						out("< " + CppGen.cppTemplateParam(tpath, native) + "  >");
					case FuncFromStaticFunction:
						core.Error.abort("Unexpected FuncFromStaticFunction", expr.cpppos);
					case FuncEnumConstruct(enumDef, field):
						out(CppGen.stringOfPath(enumDef.ePath) + "::" + CppGen.cppEnumNameOf(field));
					case FuncSuperConstruct(TCppInst(klass, _)) if (isNativeClass(klass)):
						doCall = false;
					case FuncSuperConstruct(_):
						out((if (!ctx.ctxRealThisPtr) "__this->" else "") + "super::__construct");
					case FuncSuper(_, TCppInst(klass, p), field) if (isNativeClass(klass)):
						out(cppClassPathOf(klass, p) + "::" + CppGen.cppMemberNameOf(field));
					case FuncSuper(thisKind, _, field):
						out((if (thisKind == ThisReal) "this->" else "__->") + "super::" + CppGen.cppMemberNameOf(field));
					case FuncNew(newType):
						var objName = switch newType {
							case TCppString: "::String";
							case TCppDynamicArray: "::cpp::VirtualArray_obj::__new";
							case TCppObjectArray(_): "::Array_obj< ::Dynamic>::__new";
							case TCppScalarArray(value):
								"::Array_obj< " + tcppToString(value) + " >::__new";
							case TCppObjC(klass): cppClassPathOf(klass, []) + "_obj::__new";
							case TCppNativePointer(klass): "new " + cppClassPathOf(klass, []);
							case TCppMarshalNativeType(valueType, Promoted):
								closeCall = ")";
								var b = getExternValueTypeBoxed(valueType);
								'${b.ptr}( new ${b.obj} ';
							case TCppMarshalManagedType(cls, params):
								var r = buildType(cls.clPath, cls.clPos, params, cls.clMeta, Meta.CppManagedType, tcppToString);
								var typeStr = r.type;
								var standardNaming = r.flags.indexOf("StandardNaming") >= 0;
								var ptr = if (standardNaming) typeStr else '::hx::ObjectPtr< $typeStr >';
								var obj = if (standardNaming) typeStr + "_obj" else typeStr;
								closeCall = ")";
								'$ptr( new $obj ';
							case TCppMarshalNativeType(valueType, Stack):
								tcppToString(newType);
							case TCppInst(klass, p) if (isNativeClass(klass)):
								cppClassPathOf(klass, p);
							case TCppInst(klass, p): cppClassPathOf(klass, p) + "_obj::__new";
							case TCppClass: "::hx::Class_obj::__new";
							case TCppFunction(_): tcppToString(newType);
							case _:
								core.Error.abort("Unknown 'new' target " + tcppToString(newType), expr.cpppos);
						}
						out(objName);
					case FuncInternal(func, name, join):
						gen(func);
						out(join + name);
					case FuncExtern(name, isGlobal):
						if (isGlobal) out(" ::");
						out(name);
					case FuncExpression(expr): gen(expr);
				}
				if (doCall) {
					var sep = "";
					out("(");
					for (arg in argsRef) {
						out(sep);
						sep = ",";
						gen(arg);
					}
					out(")" + closeCall);
				}
			case CppNewNative(e):
				out("new ");
				gen(e);
			case CppAddressOf(e = {cpptype: TCppMarshalNativeType(_, Reference)}):
				out("(");
				gen(e);
				out(".ptr)");
			case CppAddressOf(e):
				out("&(");
				gen(e);
				out(")");
			case CppDereference(e = {cpptype: TCppMarshalNativeType(_, Reference)}):
				out("(*(");
				gen(e);
				out(").ptr)");
			case CppDereference(e):
				out("(*(");
				gen(e);
				out("))");
			case CppFunctionAddress(klass, member):
				var signature = CppGen.functionSignature(ctx.ctxCommon.basic, false, member.cfType, "");
				var name = CppGen.cppMemberNameOf(member);
				/*let void_cast = has_meta_key field.cf_meta Meta.Void in*/
				out("::cpp::Function< " + signature + ">(::hx::AnyCast(");
				out("&::" + joinClassPathRemap(klass.clPath, "::") + "_obj::" + name);
				out(" ))");
			case CppExtern(name, isGlobal):
				if (isGlobal) out(" ::");
				out(name);
			case CppDynamicField(obj, name):
				gen(obj);
				out("->__Field(" + strq(name) + ",::hx::paccDynamic)");
			case CppArray(arrayLoc):
				switch arrayLoc {
					/* Special case for pointers to marshal type pointers */
					/* ::cpp::Pointer array access returns a T& but we want a T* for the marhsal pointer type reference */
					/* So do some manual pointer arithmatic */
					case ArrayPointer(arrayObj = {cpptype: TCppPointer(_, TCppMarshalNativeType(Pointer(_), _))}, index):
						gen(arrayObj);
						out(".ptr + ");
						gen(index);
					case ArrayRawPointer(arrayObj = {cpptype: TCppRawPointer(_, TCppMarshalNativeType(Pointer(_), _))}, index):
						gen(arrayObj);
						out(" + ");
						gen(index);
					/* The reference wrappers use templated get and set functions instead of the subscript operator due to templated []operator being a bit of a pain in c++ */
					/* Treat is as the special case it is here. */
					case ArrayRawPointer(arrayObj = {cpptype: TCppMarshalNativeType(_, Reference)}, index):
						gen(arrayObj);
						out('.get< ${tcppToString(expr.cpptype)} >(');
						gen(index);
						out(")");
					case ArrayTyped(arrayObj, index, _):
						gen(arrayObj);
						out("->__get(");
						gen(index);
						out(")");
					case ArrayPointer(arrayObj, index):
						gen(arrayObj);
						out(".ptr[");
						gen(index);
						out("]");
					case ArrayRawPointer(arrayObj, index):
						gen(arrayObj);
						out("[");
						gen(index);
						out("]");
					case ArrayObject(arrayObj, index, elem):
						var close = if (cppIsDynamicType(elem)) "" else if (elem.match(TCppDynamicArray)) {
							out(tcppToString(elem) + "( ");
							")";
						} else ".StaticCast< " + tcppToString(elem) + " >()";
						gen(arrayObj);
						out("->__get(");
						gen(index);
						out(")" + close);
					case ArrayVirtual(arrayObj, index):
						gen(arrayObj);
						out("->__get(");
						gen(index);
						out(")");
					case ArrayDynamic(arrayObj, index):
						gen(arrayObj);
						out("->__GetItem(");
						gen(index);
						out(")");
					case ArrayImplements(_, arrayObj, index):
						gen(arrayObj);
						out("->__get(");
						gen(index);
						out(")");
				}
			case CppSet(lvalue, rvalue):
				var close = if (expr.cpptype.match(TCppVoid)) "" else {
					out("(");
					")";
				}
				switch lvalue {
					case CppVarRef(VarClosure(v)) if (CppContext.isGcElement(ctx, v.tcppvType)):
						out("this->_hx_set_" + v.tcppvName + "(HX_CTX, ");
						gen(rvalue);
						out(")");
					case CppVarRef(VarThis(member, _)) if (CppContext.isGcElement(ctx, cppTypeOf(member.cfType))):
						out("this->_hx_set_" + CppGen.cppMemberNameOf(member) + "(HX_CTX, ");
						gen(rvalue);
						out(")");
					case CppVarRef(VarInstance(obj, member, _, "->")) if (CppContext.isGcElement(ctx, cppTypeOf(member.cfType))):
						gen(obj);
						out("->_hx_set_" + CppGen.cppMemberNameOf(member) + "(HX_CTX, ");
						gen(rvalue);
						out(")");
					case CppVarRef(VarInternal(obj, op, member)):
						gen(obj);
						out(op + member);
					case CppVarRef(varLoc):
						genValLoc(varLoc);
						out(" = ");
						gen(rvalue);
					case CppArrayRef(arrayLoc):
						switch arrayLoc {
							case ArrayObject(arrayObj, index, _) if (CppContext.isGcElement(ctx, TCppDynamic)):
								gen(arrayObj);
								out("->setCtx( HX_CTX, ");
								gen(index);
								out(",");
								gen(rvalue);
								out(")");
							case ArrayTyped(arrayObj, index, t) if (CppContext.isGcElement(ctx, t)):
								gen(arrayObj);
								out("->setCtx( HX_CTX, ");
								gen(index);
								out(",");
								gen(rvalue);
								out(")");
							/* The reference wrappers use templated get and set functions instead of the subscript operator due to templated []operator being a bit of a pain in c++ */
							/* Treat is as the special case it is here. */
							case ArrayRawPointer(arrayObj = {cpptype: TCppMarshalNativeType(_, Reference)}, index):
								gen(arrayObj);
								out('.set< ${tcppToString(rvalue.cpptype)} >(');
								gen(index);
								out(",");
								gen(rvalue);
								out(")");
							case ArrayObject(arrayObj, index, _) | ArrayTyped(arrayObj, index, _) | ArrayRawPointer(arrayObj, index):
								gen(arrayObj);
								out("[");
								gen(index);
								out("] = ");
								gen(rvalue);
							case ArrayPointer(arrayObj, index):
								gen(arrayObj);
								out(".ptr[");
								gen(index);
								out("] = ");
								gen(rvalue);
							case ArrayVirtual(arrayObj, index):
								gen(arrayObj);
								out("->set(");
								gen(index);
								out(",");
								gen(rvalue);
								out(")");
							case ArrayDynamic(arrayObj, index):
								gen(arrayObj);
								out("->__SetItem(");
								gen(index);
								out(",");
								gen(rvalue);
								out(")");
							case ArrayImplements(_, arrayObj, index):
								gen(arrayObj);
								out("->__set(");
								gen(index);
								out(",");
								gen(rvalue);
								out(")");
						}
					case CppDynamicRef(expr, name):
						gen(expr);
						out("->__SetField(" + strq(name) + ",");
						gen(rvalue);
						out(",::hx::paccDynamic)");
					case CppExternRef(name, isGlobal):
						if (isGlobal) out(" ::");
						out(name + " = ");
				}
				out(close);
			case CppCrement(incFlag, preFlag, lvalue):
				var op = if (incFlag == CppIncrement) "++" else "--";
				if (preFlag == Prefix) out(op);
				genLvalue(lvalue);
				if (preFlag == Postfix) out(op);
			case CppModify(op, lvalue, rvalue):
				out(stringOfOpEq(op, expr.cpppos));
				out("(");
				genLvalue(lvalue);
				out(",");
				gen(rvalue);
				out(")");
			case CppPosition(name, line, clazz, func):
				out("::hx::SourceInfo(" + strq(name) + "," + Std.string(line) + "," + strq(clazz) + "," + strq(func) + ")");
			case CppClassOf(path, native):
				var path = "::" + joinClassPathRemap(path, "::");
				var path = switch path {
					case "::Int": "int";
					case "::Bool": "bool";
					case x: x;
				}
				if (native) out("null()") else if (path == "::Array") out("::hx::ArrayBase::__mClass") else out("::hx::ClassOf< " + path + " >()");
			case CppVar(loc): genValLoc(loc);
			case CppCallable(closure):
				var captured = closure.closeUndeclared.bindings().map(function(b) return b.value).map(function(v) return v.tcppvName).join(",");
				out('::hx::Callable< ${CppGen.cppCallableSignaure(closure)} >(new _hx_Closure_${closure.closeId}($captured))');
			case CppObjectDecl(values, isStruct):
				var length = values.length;
				var lengthStr = Std.string(length);
				if (!expr.cpptype.match(TCppVoid)) out(" ::Dynamic(");
				if (isStruct && length > 0 && length <= 5) {
					out("::hx::AnonStruct" + lengthStr + "_obj< " + values.map(function(v) return tcppToString(v.e.cpptype)).join(",") + " >::Create(");
					var sep = "";
					for (v in values) {
						out(sep + strq(v.name) + ",");
						sep = ",";
						gen(v.e);
					}
					out(")");
				} else {
					out("::hx::Anon_obj::Create(" + lengthStr + ")");
					var sorted = listSort(function(a:{name:String, value:TcppExpr, h:Int}, b:{name:String, value:TcppExpr, h:Int}) return a.h < b.h ? -1 : a.h > b.h ? 1 : 0,
						values.map(function(v) return {name: v.name, value: v.e, h: genHash32(0, v.name)}));
					writer.pushIndent();
					for (idx in 0...sorted.length) {
						var s = sorted[idx];
						out("\n" + spacer);
						writer.writeI("->setFixed(" + Std.string(idx) + "," + strq(s.name) + ",");
						gen(s.value);
						out(")");
					}
				}
				if (!expr.cpptype.match(TCppVoid)) out(")");
				writer.popIndent();
			case CppArrayDecl(exprList) if (CppGen.cppIsConstScalarArray(expr.cpptype, exprList)):
				var arrayType = switch expr.cpptype {
					case TCppScalarArray(value): value;
					case _: throw new haxe.Exception("Assert_failure cppGen.ml");
				}
				var typeName = tcppToString(arrayType);
				ctx.ctxFileId.value++;

				var id = "_hx_array_data_" + classHash + "_" + Std.string(ctx.ctxFileId.value);

				var outTop = ctx.ctxWriter.writeH;
				outTop("static const " + typeName + " " + id + "[] = {\n\t");
				for (expr in exprList) switch expr.cppexpr {
					case CppInt(i): outTop('($typeName)$i,');
					case CppFloat(f): outTop(f + ",");
					case CppString(s): outTop(strq(s) + ",");
					case CppBool(b): outTop(if (b) "1," else "0,");
					case _: die("", "cppGen.ml");
				}
				outTop("\n};\n");
				out("::Array_obj< " + typeName + " >::fromData( " + id + "," + CppGen.listNum(exprList) + ")");
			case CppArrayDecl(exprList):
				var count = exprList.length;
				var countStr = Std.string(count);
				var r = switch expr.cpptype {
					case TCppObjectArray(_): {arrayType: "::Array_obj< ::Dynamic>", close: ""};
					case TCppScalarArray(value):
						{arrayType: "::Array_obj< " + tcppToString(value) + " >", close: ""};
					case TCppDynamicArray: {arrayType: "::cpp::VirtualArray_obj", close: ""};
					case _: {arrayType: " ::Dynamic( ::cpp::VirtualArray_obj", close: ")"};
				}
				out(r.arrayType + "::__new(" + countStr + ")");
				for (idx in 0...exprList.length) {
					out("->init(" + Std.string(idx) + ",");
					gen(exprList[idx]);
					out(")");
				}
				out(r.close);
			case CppBinop(OpUShr, left, right):
				out("::hx::UShr(");
				gen(left);
				out(",");
				gen(right);
				out(")");
			case CppBinop(OpMod, left, right):
				if (CppGen.isConstantZero(right)) {
					out("::hx::Mod(");
					gen(left);
					out(",(double)( ");
					gen(right);
					out(" ))");
				} else {
					out("::hx::Mod(");
					gen(left);
					out(",");
					gen(right);
					out(")");
				}
			case CppBinop(OpDiv, left, right) if (CppGen.isConstantZero(right)):
				out("::hx::DivByZero(");
				gen(left);
				out(")");
			case CppBinop(op, left, right):
				var op = stringOfOp(op, expr.cpppos);
				out("(");
				gen(left);
				out(" " + op + " ");
				gen(right);
				out(")");
			case CppCompare(opName, left, right, _):
				out("::hx::" + opName + "( ");
				gen(left);
				out(",");
				gen(right);
				out(" )");
			case CppNullCompare(op, left):
				out("::hx::" + op + "( ");
				gen(left);
				out(" )");
			case CppThrow(value):
				out("HX_STACK_DO_THROW(");
				gen(value);
				out(")");
			case CppReturn(null): out("return");
			case CppReturn(value):
				out("return ");
				gen(value);
			case CppEnumField(enumDef, field):
				out(CppGen.stringOfPath(enumDef.ePath) + "::" + CppGen.cppEnumNameOf(field) + "_dyn()");
			case CppEnumParameter(obj, field, index):
				var valueType = cppTypeOf(getNthType(field, index));
				var baseType = enumGetterType(valueType);
				gen(obj);
				if (cppIsDynamicType(obj.cpptype)) out(".StaticCast< ::hx::EnumBase >()");
				out("->_hx_get" + baseType + "(" + Std.string(index) + ")");
				switch valueType {
					case TCppObjectArray(_) | TCppScalarArray(_) | TCppDynamicArray | TCppClass | TCppEnum(_) | TCppInst(_) | TCppMarshalManagedType(_):
						out(".StaticCast< " + tcppToString(valueType) + " >()");
					case _:
				}
			case CppIntSwitch(condition, cases, defVal):
				out("switch((int)(");
				gen(condition);
				out("))");
				writer.beginBlock();
				for (c in cases) {
					out(spacer);
					writer.writeI("");
					for (value in c.values) out("case (int)" + Std.string(value) + ": ");
					gen(c.e);
					out(spacer);
					writer.writeI("break;\n");
				}
				switch defVal {
					case null:
					case expr:
						outputI("default:");
						gen(expr);
				}
				out(spacer);
				writer.endBlock();
			case CppSwitch(condition, conditionType, cases, optionalDefault, label):
				var tmpName = "_hx_switch_" + Std.string(tempId);
				tempId++;
				out(tcppToString(conditionType) + " " + tmpName + " = ");
				gen(condition);
				out(";\n");
				for (c in cases) {
					outputI("if ( ");
					var orStr = "";
					for (value in c.values) {
						out(orStr + " (" + tmpName + "==");
						gen(value);
						out(")");
						orStr = " || ";
					}
					out(" )");
					gen(c.e);
				}
				switch optionalDefault {
					case null:
					case def:
						outputI("/* default */");
						gen(def);
				}
				outputI(labelName(label) + ":");
			case CppUnop(unop, value):
				out(switch unop {
					case CppNot: "!";
					case CppNeg: "-";
					case CppNegBits: "~";
				});
				out("(");
				gen(value);
				out(")");
			case CppWhile(condition, block, whileFlag, loopId):
				switch whileFlag {
					case NormalWhile:
						out("while(");
						gen(condition);
						out(")");
						lastLine = -1;
						gen(block);
					case DoWhile:
						out("do ");
						lastLine = -1;
						genWithInjection(null, block, false);
						out(" while(");
						gen(condition);
						out(");\n");
				}
				if (loopId > -1) outputI(labelName(loopId) + ":");
			case CppIf(condition, block, null):
				out("if (");
				gen(condition);
				out(") ");
				gen(block);
			case CppIf(condition, block, elze) if (expr.cpptype.match(TCppVoid)):
				out("if (");
				gen(condition);
				out(") ");
				gen(block);
				outputI("else ");
				gen(elze);
			case CppIf(condition, block, elze):
				gen(condition);
				out(" ? ");
				gen(block);
				out(" : ");
				gen(elze);
			case CppFor(v, init, loop):
				var varType = tcppToString(v.tcppvType);
				out("for(::cpp::FastIterator_obj< " + varType + " > *__it = ::cpp::CreateFastIterator< " + varType + " >(");
				gen(init);
				out(");  __it->hasNext(); )");
				function prologue(_:Bool) outputI(varType + " " + v.tcppvName + " = __it->next();\n");
				genWithInjection(CppGen.mkInjection(prologue, "", ""), loop, true);
			case CppTry(block, catches):
				function prologue(_:Bool):Void {
					for (idx in 0...catches.length) outputI("HX_STACK_CATCHABLE(" + CppGen.cppMacroVarTypeOf(catches[idx].v) + ", " + Std.string(idx) + ");\n");
				}
				out("try ");
				genWithInjection(CppGen.mkInjection(prologue, "", ""), block, catches.length < 0);
				if (catches.length > 0) {
					out(" catch( ::Dynamic _hx_e) ");
					writer.beginBlock();

					var seenDynamic = false;
					var elseStr = "";
					for (c in catches) {
						var v = c.v, ctch = c.e;
						var typeName = tcppToString(v.tcppvType);
						switch v.tcppvType {
							case TCppInterface(klass):
								var hash = CppGen.cppClassHash(klass);
								outputI(elseStr + "if (::hx::TIsInterface< (int)" + hash + " >(_hx_e.mPtr))");
							case TCppString:
								outputI(elseStr + "if (_hx_e.IsClass< ::String >() && _hx_e->toString()!=null() )");
							case _:
								if (typeName == "Dynamic") {
									seenDynamic = true;
									outputI(elseStr);
								} else outputI(elseStr + "if (_hx_e.IsClass< " + typeName + " >() )");
						}

						function prologue(_:Bool):Void {
							outputI("HX_STACK_BEGIN_CATCH\n");
							outputI(typeName + " " + v.tcppvName + " = _hx_e;\n");
						}
						genWithInjection(CppGen.mkInjection(prologue, "", ""), ctch, true);
						elseStr = "else ";
					}

					if (!seenDynamic) {
						outputI("else {\n");
						outputI("\tHX_STACK_DO_THROW(_hx_e);\n");
						outputI("}\n");
					}
					out(spacer);
					writer.endBlock();
				}
			case CppCode(value, exprs):
				codegen.Codegen.interpolateCode(ctx.ctxCommon.error, CppGen.formatCode(value), exprs, out, function(e) gen(e), expr.cpppos);
			case CppTCast(expr, cppType):
				switch cppType {
					case TCppInterface(i):
						out(" ::hx::interface_check(");
						gen(expr);
						out("," + CppGen.cppClassHash(i) + ")");
					case _:
						var toType = tcppToString(cppType);
						if (toType == "Dynamic") {
							out(" ::Dynamic(");
							gen(expr);
							out(")");
						} else {
							out("::hx::TCast< " + toType + " >::cast(");
							gen(expr);
							out(")");
						}
				}
			case CppCastStatic(expr, toType):
				var close = switch expr.cpptype {
					case TCppDynamic: "";
					case _:
						out("Dynamic( ");
						")";
				}
				gen(expr);
				out(close + ".StaticCast< " + tcppToString(toType) + " >()");
			case CppCast(expr, toType):
				switch [expr.cppexpr, expr.cpptype, toType] {
					case [CppCall(FuncInternal(_), _), _, _]:
						gen(expr);
						out(".StaticCast< " + tcppToString(toType) + " >()");
					case [_, TCppObjC(_), _] | [_, TCppObjCBlock(_), _]:
						out("( (" + tcppToString(toType) + ")((id) ( ");
						gen(expr);
						out(") ))");
					case [_, _, TCppObjectPtr]:
						out("::hx::DynamicPtr(");
						gen(expr);
						out(")");
					case [_, TCppPointer(_, _), TCppStar(_, _)] | [_, TCppPointer(_, _), TCppRawPointer(_, _)]:
						out("( (" + tcppToString(toType) + ")( (");
						gen(expr);
						out(").get_raw()) )");
					case _:
						out("( (" + tcppToString(toType) + ")(");
						gen(expr);
						out(") )");
				}
			case CppCastScalar(expr, scalar):
				out("( (" + scalar + ")(");
				gen(expr);
				out(") )");
			case CppCastVariant(expr):
				out(" ::Dynamic(");
				gen(expr);
				out(")");
			case CppCastObjC(expr, klass):
				var path = joinClassPathRemap(klass.clPath, "::");
				var toType = if (hasClassFlag(klass, CInterface)) "id < " + path + ">" else path + " *";
				out("( (" + toType + ") (id) (");
				gen(expr);
				out(") )");
			case CppCastObjCBlock(expr, args, ret):
				out(tcppObjcBlockStruct(args, ret) + "::create( ");
				gen(expr);
				out(")");
			case CppCastProtocol(expr, klass):
				out(joinClassPathRemap(klass.clPath, "::") + "_obj::_hx_toProtocol( ");
				gen(expr);
				out(")");
			case CppCastNative(expr):
				out("(");
				gen(expr);
				out(").mPtr");
		}
		if (ctx.ctxDebugLevel >= 3) out("/* " + sTcpp(expr.cppexpr) + ":" + tcppToString(expr.cpptype) + " */");
	}

	function gen(expr:TcppExpr):Void genWithInjection(null, expr, true);

	function genLvalue(lvalue:TcppLValue):Void {
		switch lvalue {
			case CppVarRef(varLoc): genValLoc(varLoc);
			case CppArrayRef(arrayLoc):
				switch arrayLoc {
					case ArrayObject(arrayObj, index, _):
						out("::hx::IndexRef(");
						gen(arrayObj);
						out(".mPtr,");
						gen(index);
						out(")");
					case ArrayTyped(arrayObj, index, _):
						gen(arrayObj);
						out("[");
						gen(index);
						out("]");
					case ArrayPointer(arrayObj, index):
						gen(arrayObj);
						out(".ptr[");
						gen(index);
						out("]");
					case ArrayRawPointer(arrayObj, index):
						gen(arrayObj);
						out("[");
						gen(index);
						out("]");
					case ArrayVirtual(arrayObj, index) | ArrayDynamic(arrayObj, index):
						out("::hx::IndexRef(");
						gen(arrayObj);
						out(".mPtr,");
						gen(index);
						out(")");
					case ArrayImplements(_, arrayObj, index):
						out("::hx::__ArrayImplRef(");
						gen(arrayObj);
						out(",");
						gen(index);
						out(")");
				}
			case CppExternRef(name, isGlobal):
				if (isGlobal) out(" ::");
				out(name);
			case CppDynamicRef(expr, name):
				var objPtr = switch expr.cpptype {
					case TCppVariant(_): "getObject()";
					case _: ".mPtr";
				}
				out("::hx::FieldRef((");
				gen(expr);
				out(")" + objPtr + "," + strq(name) + ")");
		}
	}

	function genValLoc(loc:TcppVarLoc):Void {
		switch loc {
			case VarClosure(v) | VarLocal(v): out(v.tcppvName);
			case VarStatic(clazz, objc, member):
				switch Ast.getMetaString(member.cfMeta, Meta.Native) {
					case null:
						if (objc) {
							out(joinClassPathRemap(clazz.clPath, "::"));
							out("." + CppGen.cppMemberNameOf(member));
						} else {
							out(CppGen.cppClassName(clazz));
							out("::" + CppGen.cppMemberNameOf(member));
						}
					case n: out(n);
				}
			case VarThis(member, _): out("this->" + CppGen.cppMemberNameOf(member));
			case VarInstance(obj, member, _, op):
				gen(obj);
				out(op + CppGen.cppMemberNameOf(member));
			case VarInternal(obj, op, member):
				gen(obj);
				out(op + member);
			case VarInterface(obj, member):
				gen(obj);
				out("->" + CppGen.cppMemberNameOf(member) + "_get()");
		}
	}

	static function stringOfOpEq(op:Binop, pos:Pos):String {
		return switch op {
			case OpAdd: "::hx::AddEq";
			case OpMult: "::hx::MultEq";
			case OpDiv: "::hx::DivEq";
			case OpSub: "::hx::SubEq";
			case OpAnd: "::hx::AndEq";
			case OpOr: "::hx::OrEq";
			case OpXor: "::hx::XorEq";
			case OpShl: "::hx::ShlEq";
			case OpShr: "::hx::ShrEq";
			case OpUShr: "::hx::UShrEq";
			case OpMod: "::hx::ModEq";
			case _: core.Error.abort("Bad assign op", pos);
		}
	}

	static function stringOfOp(op:Binop, pos:Pos):String {
		return switch op {
			case OpAdd: "+";
			case OpMult: "*";
			case OpDiv: "/";
			case OpSub: "-";
			case OpEq: "==";
			case OpNotEq: "!=";
			case OpGt: ">";
			case OpGte: ">=";
			case OpLt: "<";
			case OpLte: "<=";
			case OpAnd: "&";
			case OpOr: "|";
			case OpXor: "^";
			case OpBoolAnd: "&&";
			case OpBoolOr: "||";
			case OpShl: "<<";
			case OpShr: ">>";
			case OpUShr: ">>>";
			case OpMod: "%";
			case OpInterval: "...";
			case OpArrow: "->";
			case OpIn: " in ";
			case OpNullCoal: "??";
			case OpAssign | OpAssignOp(_): core.Error.abort("Unprocessed OpAssign", pos);
		}
	}

	function genClosure(closure:TcppClosure):Void {
		var argc = closure.closeUndeclared.bindings().length;
		if (argc >= 62)
			/* Limited by c++ macro size of 128 args */
			core.Error.abort("Too many capture variables", closure.closeExpr.cpppos);
		if (argc >= 20 || closure.closeArgs.length >= 20) writer.addBigClosures();
		var argsCount = CppGen.listNum(closure.closeArgs);
		var signature = CppGen.cppCallableSignaure(closure);
		var captured = switch closure.closeUndeclared.bindings() {
			case []: "";
			case some:
				", " + some.map(function(b) return b.value).map(function(v) return '${CppGen.cppMacroVarTypeOf(v)},${v.tcppvDebugName}').join(",");
		}

		out('HX_BEGIN_LOCAL_FUNC_S$argc(::hx::AutoCallable_obj< $signature >, _hx_Closure_${closure.closeId}$captured)\n');

		outputI('${tcppToString(closure.closeType)} HX_LOCAL_RUN( ${CppGen.cppCallableArgs(closure.closeArgs, "__o_")} ) override ');

		function prologue(gcStack:Bool):Void {
			CppGen.cppGenDefaultValues(ctx, className, funcName, closure.closeArgs, "__o_");

			CppGen.hxStackPush(ctx, outputI, className, funcName, closure.closeExpr.cpppos, gcStack);
			if (ctx.ctxDebugLevel >= 2) {
				for (a in closure.closeArgs.filter(function(a) return CppGen.cppDebugVarVisible(ctx, a)))
					outputI("HX_STACK_ARG(" + a.v.tcppvName + ",\"" + a.v.tcppvDebugName + "\")\n");

				var line = syntax.Lexer.getErrorLine(closure.closeExpr.cpppos);
				var lineName = StringTools.lpad(Std.string(line), " ", 4);
				out("HXLINE(" + lineName + ")\n");
			}
		}
		genWithInjection(CppGen.mkInjection(prologue, "", ""), closure.closeExpr, true);
		outputI("int __Compare(const ::hx::Object* inRhs) const override {\n");
		outputI('\treturn dynamic_cast<const _hx_Closure_${closure.closeId}*>(inRhs) ? 0 : -1;\n');
		outputI("}\n");
		outputI("::std::type_index callableId() const override {\n");
		outputI('\treturn ::std::type_index{ typeid(_hx_Closure_${closure.closeId}) };\n');
		outputI("}\n");

		var ret = switch closure.closeType {
			case TCppVoid: "(void)";
			case _: "return";
		}

		outputI("HX_END_LOCAL_FUNC" + argsCount + "(" + ret + ")\n\n");
	}
}
