package generators.cpp;

import core.Globals;
import core.Define;
import core.TType;
import generators.Gctx;
import generators.cpp.CppAst;
import generators.cpp.CppAstTools.*;
import generators.cpp.CppSourceWriter.SourceWriter;
import haxe.ds.StringMap;

/* CPP code generation context */
/*
	ctx_debug_level
	0 = no debug
	1 = function + line debug via macros, which can be activated at cpp compile-time
	2 = include macros for HXCPP_DEBUGGER
	3 = annotate source with additional info about AST and types
	4 = console output at haxe compile-time

	normal = 1
 */
// port: `(string, string) PMap.t ref`: a mutable cell shared by the contexts copied from one another.
class FileInfo {
	public var value:StringMap<String>;

	public function new(value:StringMap<String>) this.value = value;
}

class Context {
	public var ctxCommon:Gctx;
	public var ctxDebugLevel:Int;
	/* cached as required */
	public var ctxFileInfo:FileInfo;
	/* Per file */
	public var ctxOutput:String->Void;
	public var ctxWriter:SourceWriter;
	// port: `int ref`.
	public var ctxFileId:{value:Int};
	public var ctxIsHeader:Bool;
	public var ctxSuperDeps:PathMap<Array<GlobalTypePath>>;
	public var ctxConstructorDeps:PathMap<TClassField>;
	public var ctxClassMemberTypes:StringMap<String>;
	/* This is for returning from the child nodes of TSwitch && TTry */
	public var ctxRealThisPtr:Bool;

	public function new() {}

	// port: `{ ctx with ... }` record copy.
	public function copy():Context {
		var c = new Context();
		c.ctxCommon = ctxCommon;
		c.ctxDebugLevel = ctxDebugLevel;
		c.ctxFileInfo = ctxFileInfo;
		c.ctxOutput = ctxOutput;
		c.ctxWriter = ctxWriter;
		c.ctxFileId = ctxFileId;
		c.ctxIsHeader = ctxIsHeader;
		c.ctxSuperDeps = ctxSuperDeps;
		c.ctxConstructorDeps = ctxConstructorDeps;
		c.ctxClassMemberTypes = ctxClassMemberTypes;
		c.ctxRealThisPtr = ctxRealThisPtr;
		return c;
	}
}

class CppContext {
	public static function newContext(commonCtx:Gctx, debug:Int, fileInfo:FileInfo, memberTypes:StringMap<String>,
			superDeps:PathMap<Array<GlobalTypePath>>, constructorDeps:PathMap<TClassField>):Context {
		var nullFile = new SourceWriter(commonCtx, function(_) {}, function(_) {}, function() {});
		function hasDef(def:String):Bool return Gctx.definedValueSafe(commonCtx, def) != "";
		var result = new Context();
		result.ctxCommon = commonCtx;
		result.ctxWriter = nullFile;
		result.ctxFileId = {value: -1};
		result.ctxIsHeader = false;
		result.ctxOutput = nullFile.write;
		result.ctxDebugLevel = if (hasDef(Define.AnnotateSource)) 3 else if (hasDef(Define.HxcppDebugger)) 2 else debug;
		result.ctxRealThisPtr = true;
		result.ctxClassMemberTypes = memberTypes;
		result.ctxFileInfo = fileInfo;
		result.ctxSuperDeps = superDeps;
		result.ctxConstructorDeps = constructorDeps;
		return result;
	}

	public static function fileContext(ctx:Context, writer:SourceWriter, debug:Int, header:Bool):Context {
		var c = ctx.copy();
		c.ctxWriter = writer;
		c.ctxOutput = writer.write;
		c.ctxIsHeader = header;
		c.ctxFileId = {value: -1};
		return c;
	}

	/* todo - is this how it's done? */
	// port: PMap.iter goes through the keys in increasing order; the result is reversed.
	public static function pmapKeys<V>(pmap:StringMap<V>):Array<String> {
		var keys = core.ds.PMap.keys(pmap);
		keys.reverse();
		return keys;
	}

	public static function pmapValues<V>(pmap:StringMap<V>):Array<V> {
		var values = [for (k in core.ds.PMap.keys(pmap)) pmap.get(k)];
		values.reverse();
		return values;
	}

	// port: `Hashtbl.iter` over `common_ctx.resources`, collected once for the several passes.
	public static function resourcesInHashtblOrder(com:Gctx):Array<{name:String, data:haxe.io.Bytes}> {
		var result = [];
		com.resources.iter(function(name, data) result.push({name: name, data: data}));
		return result;
	}

	public static function findFileOr(com:Gctx, file:String):String {
		return try Gctx.findFile(com, file) catch (e:core.ds.NotFound) file;
	}

	public static function isGcElement(ctx:Context, memberType:Tcpp):Bool
		return Gctx.defined(ctx.ctxCommon, Define.HxcppGcGenerational) && switch memberType {
			case TCppFunction(_, _, _): false;
			case _: isObjectElement(memberType);
		};

	public static function stripFile(ctx:Gctx, file:String):String {
		return switch Gctx.defined(ctx, Define.AbsolutePath) {
			case true: core.Path.getFullPath(file);
			case false: ctx.classPaths.relativePath(file);
		}
	}
}
