package generators.cpp;

import core.Globals;
import core.Define;
import generators.Gctx;
import generators.cpp.CppStrings.*;
import generators.cpp.CppAstTools.*;
import generators.cpp.CppTypeUtils.*;

/*
	Code for generating source files.
	It manages creating directories, indents, blocks and only modifying files
	when the content changes.
 */
class SourceWriter {
	final commonCtx:Gctx;
	final writeHeaderFunc:String->Void;
	final writeFunc:String->Void;
	final closeFunc:Void->Void;
	final indentStr = "\t";
	var indent = "";
	var indents:Array<String> = [];
	var justFinishedBlock = false;
	final headerLines = new haxe.ds.StringMap<Bool>();

	public function new(commonCtx:Gctx, writeHeaderFunc:String->Void, writeFunc:String->Void, closeFunc:Void->Void) {
		this.commonCtx = commonCtx;
		this.writeHeaderFunc = writeHeaderFunc;
		this.writeFunc = writeFunc;
		this.closeFunc = closeFunc;
	}

	public function close():Void {
		closeFunc();
	}

	public function write(x:String):Void {
		writeFunc(x);
		justFinishedBlock = false;
	}

	public function writeH(x:String):Void {
		writeHeaderFunc(x);
	}

	public function writeHUnique(x:String):Void {
		if (!headerLines.exists(x)) {
			headerLines.set(x, true);
			writeH(x);
		}
	}

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

	public function beginBlock():Void {
		write("{\n");
		pushIndent();
	}

	public function endBlock():Void {
		popIndent();
		writeI("}\n");
		justFinishedBlock = true;
	}

	public function endBlockLine():Void {
		popIndent();
		writeI("}");
		justFinishedBlock = true;
	}

	public function terminateLine():Void {
		write(justFinishedBlock ? "" : ";\n");
	}

	public function addBigClosures():Void {
		writeHUnique("#include <hx/MacrosJumbo.h>\n");
	}

	public function addInclude(classPath:GlobalTypePath):Void {
		switch classPath {
			case {pack: ["@verbatim"], name: file}:
				writeHUnique(CppSourceWriter.guardedInclude(file));
			case _:
				var prefix = if (CppSourceWriter.shouldPrefixInclude(classPath)) "" else CppSourceWriter.getIncludePrefix(commonCtx, true);
				writeH("#ifndef INCLUDED_" + joinClassPath(classPath, "_") + "\n");
				writeH("#include <" + prefix + joinClassPath(classPath, "/") + ".h>\n");
				writeH("#endif\n");
		}
	}
}

class CppSourceWriter {
	public static function getIncludePrefix(commonCtx:Gctx, withSlash:Bool):String {
		return try Gctx.definedValue(commonCtx, Define.IncludePrefix) + (withSlash ? "/" : "") catch (_:core.ds.NotFound) "";
	}

	public static function shouldPrefixInclude(x:GlobalTypePath):Bool {
		return switch x {
			case x if (isInternalClass(x)): false;
			case {pack: [], name: "hxMath"}: true;
			case _: false;
		}
	}

	public static function verbatimInclude(file:String):String {
		// port: String.sub file 0 1 raises Invalid_argument on an empty name.
		if (file.length == 0) throw new core.ds.InvalidArgument("String.sub / Bytes.sub");
		return switch file.substr(0, 1) {
			case "@": "@import " + file.substr(1) + ";\n";
			case _: "#include \"" + file + "\"\n";
		}
	}

	public static function guardedInclude(file:String):String {
		var guardName = "INCLUDED_" + hash64(file);
		return "#ifndef " + guardName + "\n" + "#define " + guardName + "\n" + verbatimInclude(file) + "#endif\n";
	}

	public static function sourceFileExtension(commonCtx:Gctx):String {
		/* no need to -D file_extension if -D objc is defined */
		return if (Gctx.defined(commonCtx, Define.Objc)) ".mm" else try "." + Gctx.definedValue(commonCtx, Define.FileExtension)
		catch (_:core.ds.NotFound) ".cpp";
	}

	public static function readWholeFile(filename:String):haxe.io.Bytes return sys.io.File.getBytes(filename);

	/*
		The cached_source_writer will not write to the file if it has not changed,
		thus allowing the makefile dependencies to work correctly
	 */
	public static function cachedSourceWriter(commonCtx:Gctx, filename:String):SourceWriter {
		var header = new StringBuf();
		function addHeader(str:String):Void header.add(str);
		var buffer = new StringBuf();
		function addBuf(str:String):Void buffer.add(str);
		function close():Void {
			header.add(buffer.toString());
			var contents = haxe.io.Bytes.ofString(header.toString());
			var same = try {
				var oldContents = readWholeFile(filename);
				contents.compare(oldContents) == 0;
			} catch (_:Dynamic) false;
			if (!same) sys.io.File.saveBytes(filename, contents);
		}
		return new SourceWriter(commonCtx, addHeader, addBuf, close);
	}

	public static function newSourceFile(commonCtx:Gctx, baseDir:String, subDir:String, extension:String, classPath:GlobalTypePath):SourceWriter {
		var includePrefix = getIncludePrefix(commonCtx, true);
		var fullDir = if (subDir == "include" && includePrefix != "") {
			var dir = switch classPath.pack {
				case []: baseDir + "/include/" + getIncludePrefix(commonCtx, false);
				case path: baseDir + "/include/" + includePrefix + path.join("/");
			}
			core.Path.mkdirRecursive(baseDir, ["include", includePrefix].concat(classPath.pack));
			dir;
		} else {
			core.Path.mkdirRecursive(baseDir, [subDir].concat(classPath.pack));
			baseDir + "/" + subDir + "/" + classPath.pack.join("/");
		}
		var file = cachedSourceWriter(commonCtx, fullDir + "/" + classPath.name + extension);
		Gctx.mapSourceHeader(commonCtx.defines, function(s) file.writeH('// $s\n'));
		return file;
	}

	public static function newCppFile(commonCtx:Gctx, baseDir:String, classPath:GlobalTypePath):SourceWriter
		return newSourceFile(commonCtx, baseDir, "src", sourceFileExtension(commonCtx), classPath);

	public static function newHeaderFile(commonCtx:Gctx, baseDir:String, classPath:GlobalTypePath):SourceWriter
		return newSourceFile(commonCtx, baseDir, "include", ".h", classPath);

	public static function newPlacedCppFile(commonCtx:Gctx, classPath:GlobalTypePath):SourceWriter {
		var baseDir = commonCtx.file;
		return if (Gctx.defined(commonCtx, Define.Vcproj)) {
			core.Path.mkdirRecursive(baseDir, ["src"]);
			cachedSourceWriter(commonCtx, baseDir + "/src/" + classPath.pack.join("-") + "-" + classPath.name + sourceFileExtension(commonCtx));
		} else newCppFile(commonCtx, commonCtx.file, classPath);
	}
}
