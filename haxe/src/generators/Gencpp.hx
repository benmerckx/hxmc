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

package generators;

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
import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.Meta;
import core.Define;
import generators.cpp.CppAst;
import generators.cpp.CppStrings.*;
import generators.cpp.CppTypeUtils.*;
import generators.cpp.CppAstTools.*;
import generators.cpp.CppSourceWriter;
import generators.cpp.CppContext;
import generators.cpp.CppMarshalling.*;
import generators.cpp.CppError;
import generators.cpp.CppError.CppErrorKind;
import generators.cpp.CppRetyper;
import generators.cpp.gen.CppGen;
import generators.cpp.gen.CppReferences;
import generators.cpp.gen.CppGenClassHeader;
import generators.cpp.gen.CppGenClassImplementation;
import generators.cpp.gen.CppGenInterfaceHeader;
import generators.cpp.gen.CppGenInterfaceImplementation;
import generators.cpp.gen.CppGenEnum;
import generators.cpp.gen.CppCppia;
import haxe.ds.StringMap;
import core.ds.VectorTools.vector;

/*
	The common_ctx contains the haxe AST in the "types" field and the resources
 */
@:structInit class GensrcCtx {
	public var externSrc:Array<String>;
	public var buildXml:String;
	public var bootClasses:Array<GlobalTypePath>;
	public var initClasses:Array<GlobalTypePath>;
	public var nonbootClasses:Array<GlobalTypePath>;
	public var bootEnums:Array<GlobalTypePath>;
	public var exeClasses:Array<{path:GlobalTypePath, deps:Array<GlobalTypePath>, def:ModuleType}>;
	public var decls:Array<TcppDecl>;
	public var ids:ObjectIds;
	public var slots:InterfaceSlots;
}

class Gencpp {
	public static function makeBaseDirectory(dir:String):Void {
		core.Path.mkdirRecursive("", ~/[\\\/]+/g.split(dir));
	}

	public static function getMetaString(meta:Metadata, key:core.MetaList.StrictMeta):String {
		for (m in meta) if (Meta.metaEq(key, m.meta)) switch m.exprs {
			case [{expr: EConst(String(name, _))}]: return name;
			case _:
		}
		return "";
	}

	public static function getMetaStringPath(meta:Metadata, key:core.MetaList.StrictMeta):String {
		for (m in meta) if (Meta.metaEq(key, m.meta)) switch m.exprs {
			case [{expr: EConst(String(name, _))}]: return makePathAbsolute(name, m.pos);
			case _:
		}
		return "";
	}

	public static function writeResources(commonCtx:Gctx):Void {
		var idx = 0;
		var resources = CppContext.resourcesInHashtblOrder(commonCtx);

		for (r in resources) {
			var data = r.data;
			var id = "__res_" + Std.string(idx);
			var resourceFile = CppSourceWriter.newCppFile(commonCtx, commonCtx.file, {pack: ["resources"], name: id});
			resourceFile.write("namespace hx {\n");
			resourceFile.writeI("unsigned char " + id + "[] = {\n");
			resourceFile.writeI("0x80, 0x00, 0x00, 0x80,\n");
			var buf = new StringBuf();
			for (i in 0...data.length) {
				var code = data.get(i);
				resourceFile.write(Std.string(code) + ",");
				if ((i % 10) == 9) resourceFile.write("\n");
			}
			resourceFile.write("0x00 };\n");
			idx++;
			resourceFile.write("}\n");
			resourceFile.close();
		}

		var resourceFile = CppSourceWriter.newCppFile(commonCtx, commonCtx.file, {pack: [], name: "__resources__"});
		resourceFile.writeH("#include <hxcpp.h>\n\n");
		resourceFile.write("namespace hx {\n");

		idx = 0;
		for (r in resources) {
			var id = "__res_" + Std.string(idx);
			resourceFile.writeI("extern unsigned char " + id + "[];\n");
			idx++;
		}

		resourceFile.write("}\n\n");

		idx = 0;
		resourceFile.write("::hx::Resource __Resources[] = ");
		resourceFile.beginBlock();
		for (r in resources) {
			var id = "__res_" + Std.string(idx);
			resourceFile.writeI("{ " + (strq(commonCtx, r.name)) + "," + Std.string(r.data.length) + "," + "::hx::" + id + " + 4 },\n");
			idx++;
		}

		resourceFile.writeI("{ ::String(null()),0,0 }\n");
		resourceFile.endBlockLine();
		resourceFile.write(";\n\n");
		resourceFile.write("namespace hx { Resource *GetResources() { return __Resources; } }\n");
		resourceFile.close();
	}

	public static function writeBuildData(commonCtx:Gctx, filename:String, classes:Array<{path:GlobalTypePath, deps:Array<GlobalTypePath>, def:ModuleType}>,
			mainDeps:Array<GlobalTypePath>, bootDeps:Array<GlobalTypePath>, buildExtra:String, externSrc:Array<String>, exeName:String):Void {
		var buildfile = new StringBuf();
		function outputString(s:String) buildfile.add(s);
		var includePrefix = CppSourceWriter.getIncludePrefix(commonCtx, true);
		function addClassToBuildfile(classPath:GlobalTypePath, deps:Array<GlobalTypePath>, fileXml:String):Void {
			var cpp = (joinClassPath(classPath, "/")) + (CppSourceWriter.sourceFileExtension(commonCtx));
			outputString("  <file name=\"src/" + cpp + "\" ");
			if (fileXml != "") outputString(fileXml);
			outputString(">\n");
			var projectDeps = deps.filter(function(path) return !isInternalClass(path));
			for (path in projectDeps) outputString("   <depend name=\"" + (switch path {
				case {pack: ["@verbatim"], name: file}: file;
				case _: "include/" + includePrefix + (joinClassPath(path, "/")) + ".h";
			}) + "\"/>\n");
			outputString("  </file>\n");
		}
		function addClassdefToBuildfile(c:{path:GlobalTypePath, deps:Array<GlobalTypePath>, def:ModuleType}):Void {
			var fileXml = switch c.def {
				case TClassDecl(classDef): getMetaString(classDef.clMeta, Meta.FileXml);
				case TEnumDecl(enumDef): getMetaString(enumDef.eMeta, Meta.FileXml);
				case _: "";
			}
			addClassToBuildfile(c.path, c.deps, fileXml);
		}

		outputString("<xml>\n");
		var apiString = (Gctx.definedValue(commonCtx, Define.HxcppApiLevel));
		outputString("<set name=\"HXCPP_API_LEVEL\" value=\"" + apiString + "\" />\n");
		outputString("<files id=\"haxe\">\n");
		outputString("<compilerflag value=\"-Iinclude\"/>\n");
		for (c in classes) addClassdefToBuildfile(c);
		addClassToBuildfile({pack: [], name: "__boot__"}, bootDeps, "");
		addClassToBuildfile({pack: [], name: "__files__"}, [], "if='HXCPP_DEBUGGER'");
		outputString("   <file name=\"${HXCPP}/src/hx/NoFiles.cpp\" unless=\"HXCPP_DEBUGGER\" />\n");
		addClassToBuildfile({pack: [], name: "__resources__"}, [], "");
		outputString("</files>\n");
		outputString("<files id=\"__lib__\">\n");
		outputString("<compilerflag value=\"-Iinclude\"/>\n");
		addClassToBuildfile({pack: [], name: "__lib__"}, mainDeps, "");
		outputString("</files>\n");
		outputString("<files id=\"__main__\">\n");
		outputString("<compilerflag value=\"-Iinclude\"/>\n");
		addClassToBuildfile({pack: [], name: "__main__"}, mainDeps, "");
		outputString("</files>\n");
		outputString("<files id=\"__resources__\">\n");
		var idx = 0;
		var ext = CppSourceWriter.sourceFileExtension(commonCtx);
		for (_ in CppContext.resourcesInHashtblOrder(commonCtx)) {
			var id = "__res_" + Std.string(idx);
			outputString("<file name=\"src/resources/" + id + ext + "\" tags=\"optim-none\" />\n");
			idx++;
		}
		outputString("</files>\n");
		outputString("<files id=\"__externs__\">\n");
		for (src in externSrc) outputString("<file name=\"" + src + "\" />\n");
		outputString("</files>\n");
		outputString("<set name=\"HAXE_OUTPUT\" value=\"" + exeName + "\" />\n");
		outputString("<include name=\"${HXCPP}/build-tool/BuildCommon.xml\"/>\n");
		outputString(buildExtra);
		if (Gctx.defined(commonCtx, Define.HxcppSmartStings))
			outputString("<error value=\"Hxcpp is out of date - please update\" unlessApi=\"" + apiString + "\" />\n");
		outputString("</xml>\n");
		sys.io.File.saveBytes(filename, haxe.io.Bytes.ofString(buildfile.toString()));
	}

	public static function writeBuildOptions(commonCtx:Gctx, filename:String, defines:StringMap<String>):Void {
		var writer = CppSourceWriter.cachedSourceWriter(commonCtx, filename);
		function writeDefine(name:String, value:String) writer.write('$name=$value\n');
		core.ds.PMap.iter(function(name, value) switch name {
			case "true" | "sys" | "dce" | "cpp" | "debug":
			case _: writeDefine(name, escapeCommand(value));
		}, defines);
		// port: Unix.open_process_args_in "haxelib" [|"haxelib"; "path"; "hxcpp"|] and input_line.
		var pin = new sys.io.Process("haxelib", ["path", "hxcpp"]);
		var line = try pin.stdout.readLine() catch (_:haxe.io.Eof) {
			pin.close();
			throw new haxe.Exception("End_of_file");
		}
		writeDefine("hxcpp", line);
		pin.close();
		writer.close();
	}

	public static function createMemberTypes(commonCtx:Gctx):StringMap<String> {
		var acc = new StringMap<String>();
		for (objectDef in commonCtx.types) switch objectDef {
			case TClassDecl(classDef) if (!hasClassFlag(classDef, CInterface)):
				function addOverride(toSuper:TClass):Void {
					var className = (joinClassPath(toSuper.clPath, "."));
					for (member in classDef.clOrderedFields) acc.set(className + "." + member.cfName, "virtual ");
					switch toSuper.clSuper {
						case null:
						case sup: addOverride(sup.cls);
					}
				}
				switch classDef.clSuper {
					case null:
					case sup: addOverride(sup.cls);
				}
			case _:
		}
		return acc;
	}

	/* Builds inheritance tree, so header files can include parents defs.  */
	public static function createSuperDependencies(commonCtx:Gctx):PathMap<Array<GlobalTypePath>> {
		function realNonNativeInterfaces(l:Array<ClassAndParams>):Array<ClassAndParams> {
			return l.filter(function(i) return switch [i.cls, i.params] {
				case [{clPath: {pack: ["cpp", "rtti"]}}, []]: false;
				case _: !isNativeGenClass(i.cls);
			});
		}
		var acc = PathMap.empty();
		for (objectDef in commonCtx.types) switch objectDef {
			case TClassDecl(classDef) if (!hasClassFlag(classDef, CExtern)):
				var initial = switch classDef.clSuper {
					case null:
						[];
					case {cls: cls} if (!hasClassFlag(cls, CExtern)):
						[cls.clPath];
					case _:
						[];
				}

				var deps = initial;
				for (i in realNonNativeInterfaces(classDef.clImplements)) if (!hasClassFlag(i.cls, CExtern)) deps = [i.cls.clPath].concat(deps);

				acc = acc.add(classDef.clPath, deps);
			case TEnumDecl(enumDef) if (!hasEnumFlag(enumDef, EnExtern)):
				acc = acc.add(enumDef.ePath, []);
			case _:
		}
		return acc;
	}

	public static function createConstructorDependencies(commonCtx:Gctx):PathMap<TClassField> {
		var acc = PathMap.empty();
		for (objectDef in commonCtx.types) switch objectDef {
			case TClassDecl(classDef) if (!hasClassFlag(classDef, CExtern)):
				switch classDef.clConstructor {
					case null:
					case func: acc = acc.add(classDef.clPath, func);
				}
			case _:
		}
		return acc;
	}

	public static function isAssignOp(op:Binop):Bool {
		return switch op {
			case OpAssign | OpAssignOp(_): true;
			case _: false;
		}
	}

	public static function generateSource(ctx:Context):Void {
		var commonCtx = ctx.ctxCommon;
		makeBaseDirectory(commonCtx.file);
		var mainDeps = [];
		var scriptable = (Gctx.defined(commonCtx, Define.Scriptable));

		var initial:GensrcCtx = {
			externSrc: [],
			buildXml: "",
			bootClasses: [],
			initClasses: [],
			nonbootClasses: [],
			bootEnums: [],
			exeClasses: [],
			decls: [],
			ids: ObjectIds.empty(),
			slots: InterfaceSlots.empty()
		};

		function folder(acc:GensrcCtx, cur:ModuleType):GensrcCtx {
			function noSemanticsMeta(pos:Pos):Dynamic return CppError.cppAbort(MissingValueSemantics, pos);

			if (!Gctx.defined(commonCtx, Define.Objc)) switch cur {
				case TClassDecl(classDef) if (Meta.has(Meta.Objc, classDef.clMeta)):
					core.Error.abort("In order to compile '@:objc' classes, please define '-D objc'", classDef.clPos);
				case _:
			}

			return switch cur {
				case TAbstractDecl(abs) if (isMarshallingNativeEnum(abs) && !core.TOther.ExtType.hasValueSemantics(TAbstract(abs, vector()))):
					noSemanticsMeta(abs.aPos);
				case TClassDecl(classDef) if (isExternClass(classDef)):
					if ((isMarshallingNativeValueClass(classDef) || isMarshallingNativePointer(classDef))
						&& !core.TOther.ExtType.hasValueSemantics(TInst(classDef, vector()))) noSemanticsMeta(classDef.clPos);

					if (isMarshallingNativePointer(classDef) && classDef.clConstructor != null) CppError.cppAbort(PointerTypeConstructor, classDef.clPos);

					var accBuildXml = acc.buildXml + (CppGen.getClassCode(classDef, Meta.BuildXml));
					var accExternSrc = switch Ast.getMetaString(classDef.clMeta, Meta.SourceFile) {
						case null: acc.externSrc;
						case source: [makePathAbsolute(source, classDef.clPos)].concat(acc.externSrc);
					}

					var r:GensrcCtx = copy(acc);
					r.buildXml = accBuildXml;
					r.externSrc = accExternSrc;
					r;
				case TClassDecl(classDef) if (isInternalClass(classDef.clPath)):
					acc;
				case TClassDecl(classDef):
					var nativeGen = Meta.has(Meta.NativeGen, classDef.clMeta);
					var b = switch hasClassFlag(classDef, CInterface) {
						case true:
							var r = CppRetyper.tcppInterfaceFromTclass(ctx, acc.slots, classDef);
							var bootable = hasBootField(classDef);
							if (nativeGen) {bootable: bootable, decl: NativeInterface(r.iface), slots: r.slots, ids: acc.ids} else
								{bootable: bootable, decl: ManagedInterface(r.iface), slots: r.slots, ids: acc.ids};
						case false:
							var r = CppRetyper.tcppClassFromTclass(ctx, acc.ids, acc.slots, classDef, vector());
							var bootable = hasTcppClassFlag(r.cls, Boot);
							if (nativeGen) {bootable: bootable, decl: NativeClass(r.cls), slots: r.slots, ids: r.ids} else
								{bootable: bootable, decl: ManagedClass(r.cls), slots: r.slots, ids: r.ids};
					}

					var accDecls = [b.decl].concat(acc.decls);
					var accBuildXml = acc.buildXml + (CppGen.getClassCode(classDef, Meta.BuildXml));
					var accInitClasses = if (hasInitField(classDef)) [classDef.clPath].concat(acc.initClasses) else acc.initClasses;
					var accBootClasses = if (b.bootable) [classDef.clPath].concat(acc.bootClasses) else acc.bootClasses;
					var accNonbootClasses = if (Meta.has(Meta.NativeGen, classDef.clMeta)) acc.nonbootClasses else [classDef.clPath].concat(acc.nonbootClasses);
					var accExeClasses = if ((hasClassFlag(classDef, CInterface)) && (isNativeGenClass(classDef))) acc.exeClasses else {
						var deps = CppReferences.findReferencedTypes(ctx, TClassDecl(classDef), ctx.ctxSuperDeps, ctx.ctxConstructorDeps, false, true, scriptable);

						[{path: classDef.clPath, deps: deps, def: cur}].concat(acc.exeClasses);
					}

					var r:GensrcCtx = copy(acc);
					r.buildXml = accBuildXml;
					r.decls = accDecls;
					r.initClasses = accInitClasses;
					r.bootClasses = accBootClasses;
					r.nonbootClasses = accNonbootClasses;
					r.exeClasses = accExeClasses;
					r.ids = b.ids;
					r.slots = b.slots;
					r;
				case TEnumDecl(enumDef) if (isExternEnum(enumDef) || isInternalClass(enumDef.ePath)):
					acc;
				case TEnumDecl(enumDef):
					var deps = CppReferences.findReferencedTypes(ctx, TEnumDecl(enumDef), ctx.ctxSuperDeps, PathMap.empty(), false, true, false);
					var e = CppRetyper.tcppEnumFromTenum(ctx, acc.ids, enumDef);
					var accDecls = [TcppDecl.Enum(e.enumDef)].concat(acc.decls);
					var accBootEnums = [enumDef.ePath].concat(acc.bootEnums);
					var accExeClasses = [{path: enumDef.ePath, deps: deps, def: cur}].concat(acc.exeClasses);

					var r:GensrcCtx = copy(acc);
					r.decls = accDecls;
					r.bootEnums = accBootEnums;
					r.exeClasses = accExeClasses;
					r.ids = e.ids;
					r;
				case _:
					acc;
			}
		}
		var srcctx = initial;
		for (t in commonCtx.types) srcctx = folder(srcctx, t);

		for (tcppType in srcctx.decls) switch tcppType {
			case ManagedClass(tcppClass):
				CppGenClassHeader.generateManagedHeader(ctx, tcppClass);
				CppGenClassImplementation.generateManagedClass(ctx, tcppClass);
			case NativeClass(tcppClass):
				CppGenClassHeader.generateNativeHeader(ctx, tcppClass);
				CppGenClassImplementation.generateNativeClass(ctx, tcppClass);
			case ManagedInterface(interfaceDef):
				CppGenInterfaceHeader.generateManagedInterface(ctx, interfaceDef);
				CppGenInterfaceImplementation.generateManagedInterface(ctx, interfaceDef);
			case NativeInterface(interfaceDef):
				CppGenInterfaceHeader.generateNativeInterface(ctx, interfaceDef);
			case Enum(tcppEnum):
				CppGenEnum.generate(ctx, tcppEnum);
		}

		switch commonCtx.main.mainExpr {
			case null: CppGen.generateDummyMain(commonCtx);
			case e:
				var mainField = mkField("__main__", tDynamic, e.epos, nullPos);
				mainField.cfExpr = e;
				var classDef = nullClass.clone();
				classDef.clPath = {pack: [], name: "@Main"};
				classDef.clOrderedStatics = [mainField];
				mainDeps = CppReferences.findReferencedTypes(ctx, TClassDecl(classDef), ctx.ctxSuperDeps, ctx.ctxConstructorDeps, false, true, false);
				CppGen.generateMain(ctx, ctx.ctxSuperDeps, classDef);
		}

		CppGen.generateBoot(ctx, srcctx.bootEnums, srcctx.bootClasses, srcctx.nonbootClasses, srcctx.initClasses, srcctx.slots);

		CppGen.generateFiles(commonCtx, ctx.ctxFileInfo);

		writeResources(commonCtx);

		/* Output class info if requested */
		if (scriptable || (Gctx.defined(commonCtx, Define.DllExport))) {
			var filename = try {
				var value = Gctx.definedValue(commonCtx, Define.DllExport);
				if (value == "1") throw core.ds.NotFound.raise();
				value;
			} catch (_:core.ds.NotFound) "export_classes.info";
			if (filename != "") {
				function escape(s:String):String {
					var b = new StringBuf();
					for (i in 0...s.length) {
						var c = s.charAt(i);
						switch c {
							case "\\":
								b.add(c);
								b.add(c);
							case " ":
								b.add("\\");
								b.add("s");
							case "\n":
								b.add("\\");
								b.add("n");
							case _:
								b.add(c);
						}
					}
					return b.toString();
				}

				var exeClasses = new StringBuf();
				var out = function(s:String) exeClasses.add(s);
				function outline(str:String) exeClasses.add(str + "\n");
				function spath(path:GlobalTypePath) return (joinClassPath(path, "."));
				for (c in srcctx.exeClasses) switch c.def {
					case TClassDecl(classDef):
						outline((if (hasClassFlag(classDef, CInterface)) "interface " else "class ") + (spath(c.path)));
					case TEnumDecl(enumDef):
						out("enum " + (spath(c.path)) + "\n");
					case _:
				}

				/* Output file info too */
				for (file in listSort(stringCompare, CppContext.pmapKeys(ctx.ctxFileInfo.value))) {
					var fullPath = core.Path.getFullPath(CppContext.findFileOr(commonCtx, file));
					if (file != "?") out("file " + (escape(file)) + " " + (escape(fullPath)) + "\n");
				}
				sys.io.File.saveBytes(filename, haxe.io.Bytes.ofString(exeClasses.toString()));
			}
		}

		var outputName = switch commonCtx.main.mainPath {
			case null: "output";
			case path: path.name;
		}

		var bootDeps = srcctx.bootEnums.concat(srcctx.bootClasses);
		writeBuildData(commonCtx, commonCtx.file + "/Build.xml", srcctx.exeClasses, mainDeps, bootDeps, srcctx.buildXml, srcctx.externSrc, outputName);
		writeBuildOptions(commonCtx, commonCtx.file + "/Options.txt", commonCtx.defines.values);
		if (!Gctx.defined(commonCtx, Define.NoCompilation)) {
			core.Timer.time(commonCtx.timerCtx, ["generate", "cpp", "native compilation"], function(_) {
				var oldDir = Sys.getCwd();
				Sys.setCwd(commonCtx.file);
				var cmd = ["run", "hxcpp", "Build.xml", "haxe"];
				if (commonCtx.debug) cmd = cmd.concat(["-Ddebug"]);
				core.ds.PMap.iter(function(name, value) switch name {
					case "true" | "sys" | "dce" | "cpp" | "debug":
					case _: cmd = cmd.concat(['-D$name="${escapeCommand(value)}"']);
				}, commonCtx.defines.values);
				for (path in commonCtx.classPaths.asStringList()) cmd = cmd.concat(['-I"${escapeCommand(path)}"']);
				compiler.io.CompilerIo.writeOut(commonCtx.io, "haxelib " + cmd.join(" ") + "\n");
				if (commonCtx.runCommandArgs("haxelib", cmd) != 0) throw new core.ds.Failure("Build failed");
				Sys.setCwd(oldDir);
				return null;
			}, null);
		}
	}

	static function copy(g:GensrcCtx):GensrcCtx return {
		externSrc: g.externSrc,
		buildXml: g.buildXml,
		bootClasses: g.bootClasses,
		initClasses: g.initClasses,
		nonbootClasses: g.nonbootClasses,
		bootEnums: g.bootEnums,
		exeClasses: g.exeClasses,
		decls: g.decls,
		ids: g.ids,
		slots: g.slots
	};

	public static function generate(commonCtx:Gctx):Void {
		var debugLevel = if (Gctx.defined(commonCtx, Define.NoDebug)) 0 else 1;
		var superDeps = createSuperDependencies(commonCtx);
		var constructorDeps = createConstructorDependencies(commonCtx);
		if (Gctx.defined(commonCtx, Define.Cppia)) {
			var ctx = CppContext.newContext(commonCtx, debugLevel, new FileInfo(new StringMap()), new StringMap(), superDeps, constructorDeps);
			CppCppia.generateCppia(ctx);
		} else {
			var ctx = CppContext.newContext(commonCtx, debugLevel, new FileInfo(new StringMap()), createMemberTypes(commonCtx), superDeps, constructorDeps);
			generateSource(ctx);
		}
	}
}
