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

package context;

import Std as StdTools;
import core.ds.Cancelled;
import core.Globals;
import core.DisplayTypes;
import core.Json.JsonValue;
import core.ClassPath.ClassPathScope;
import core.ds.NotFound;
import core.ds.ArgumentError;
import context.HxbReaderStats;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther.ExtType;
import core.Message;
import core.Error;
import core.Define;
import core.Meta;
import core.WarningList;
import core.ds.AtomicLazy;
import context.Lookup;
import context.PlatformConfig;
import compiler.io.CompilerIo;

enum PackageRule {
	Forbidden;
	Remap(name:String);
}

@:structInit class StatsData {
	public var sFilesParsed:Int;
	public var sModulesTyped:Int;
	public var sModulesRestored:Int;
	public var sClassesBuilt:Int;
	public var sMethodsTyped:Int;
	public var sMacrosCalled:Int;

	public inline function new(sFilesParsed:Int, sModulesTyped:Int, sModulesRestored:Int, sClassesBuilt:Int, sMethodsTyped:Int,
			sMacrosCalled:Int) {
		this.sFilesParsed = sFilesParsed;
		this.sModulesTyped = sModulesTyped;
		this.sModulesRestored = sModulesRestored;
		this.sClassesBuilt = sClassesBuilt;
		this.sMethodsTyped = sMethodsTyped;
		this.sMacrosCalled = sMacrosCalled;
	}

	public inline function clone():StatsData return new StatsData(sFilesParsed, sModulesTyped, sModulesRestored, sClassesBuilt,
		sMethodsTyped, sMacrosCalled);
}

class Stats {
	public static function create():StatsData return {
		sFilesParsed: 0,
		sModulesTyped: 0,
		sModulesRestored: 0,
		sClassesBuilt: 0,
		sMethodsTyped: 0,
		sMacrosCalled: 0
	};
}

// port: the list is kept oldest first (OCaml conses each callback onto the front,
// and run walks it reversed): unshift per registration was quadratic
@:structInit class CallbackList {
	public var value:Array<Void->Void>;

	public inline function new(value:Array<Void->Void>) {
		this.value = value;
	}

	public inline function clone():CallbackList return new CallbackList(value);
}

// port: (string*pos) list -> (WarningList.warning*string*pos) list -> unit
typedef NullSafetyReportCallback = Array<{msg:String, pos:Pos}>->Array<{warning:WarningCode, msg:String, pos:Pos}>->Void;

class CompilerCallbacks {
	var beforeTyperCreate:CallbackList = {value: []};
	var afterInitMacros:CallbackList = {value: []};
	var afterTyping:Array<Array<ModuleType>->Void> = [];
	var beforeSave:CallbackList = {value: []};
	var afterSave:CallbackList = {value: []};
	var afterFilters:CallbackList = {value: []};
	var afterGeneration:CallbackList = {value: []};
	var nullSafetyReport:Array<NullSafetyReportCallback> = [];

	public function new() {}

	public function addBeforeTyperCreate(f:Void->Void):Void beforeTyperCreate.value.push(f);

	public function addAfterInitMacros(f:Void->Void):Void afterInitMacros.value.push(f);

	public function addAfterTyping(f:Array<ModuleType>->Void):Void afterTyping.unshift(f);

	public function addBeforeSave(f:Void->Void):Void beforeSave.value.push(f);

	public function addAfterSave(f:Void->Void):Void afterSave.value.push(f);

	public function addAfterFilters(f:Void->Void):Void afterFilters.value.push(f);

	public function addAfterGeneration(f:Void->Void):Void afterGeneration.value.push(f);

	public function addNullSafetyReport(f:NullSafetyReportCallback):Void nullSafetyReport.unshift(f);

	public function run(handleError:CompilerError->Void, r:CallbackList):Void {
		while (r.value.length > 0) {
			var ordered = r.value;
			r.value = [];
			for (f in ordered) try f()
			catch (e:core.Error.TypingError) handleError(e.error);
		}
	}

	public function getBeforeTyperCreate():CallbackList return beforeTyperCreate;

	public function getAfterInitMacros():CallbackList return afterInitMacros;

	public function getAfterTyping():Array<Array<ModuleType>->Void> return afterTyping;

	public function getBeforeSave():CallbackList return beforeSave;

	public function getAfterSave():CallbackList return afterSave;

	public function getAfterFilters():CallbackList return afterFilters;

	public function getAfterGeneration():CallbackList return afterGeneration;

	public function getNullSafetyReport():Array<NullSafetyReportCallback> return nullSafetyReport;
}

class FileKeys {
	var cache:Map<String, String> = [];
	var virtualCounter = 0;

	public function new() {}

	public function get(file:String):String {
		if (cache.exists(file)) return cache.get(file);
		var key = core.Path.UniqueKey.create(file);
		cache.set(file, key);
		return key;
	}

	public function generateVirtual(mpath:GlobalTypePath, step:Int):String {
		virtualCounter++;
		return (mpath.pack.length == 0 ? "." : mpath.pack.join("/")) + "/" + mpath.name + "_" + step + "_" + virtualCounter;
	}
}

enum CompilerStage {
	CCreated; // Context was just created
	CInitialized; // Context was initialized (from CLI args and such).
	CInitMacrosStart; // Init macros are about to run.
	CInitMacrosDone; // Init macros did run - at this point the signature is locked.
	CTypingDone; // The typer is done - at this point com.types/modules/main is filled.
	CFilteringStart; // Filtering just started (nothing changed yet).
	CAnalyzerStart; // Some filters did run, the analyzer is about to run.
	CAnalyzerDone; // The analyzer just finished.
	CSaveStart; // The type state is about to be saved.
	CSaveDone; // The type state has been saved - at this point we can destroy things.
	CDceStart; // DCE is about to run - everything is still available.
	CDceDone; // DCE just finished.
	CFilteringDone; // Filtering just finished.
	CGenerationStart; // Generation is about to begin.
	CGenerationDone; // Generation just finished.
}

enum ReportMode {
	RMNone;
	RMDiagnostics(files:Array<String>);
	RMStatistics;
}

class ModuleLut extends HashtblLookup<GlobalTypePath, ModuleDef> {
	var typeLut:HashtblLookup<GlobalTypePath, GlobalTypePath> = new HashtblLookup();

	public function new() super();

	public function addModuleType(m:ModuleDef, mt:ModuleType):Void {
		var t = tInfos(mt);
		try {
			var path2 = typeLut.find(t.mtPath), p = t.mtPos;
			if (!Common.samePath(m.mPath, path2)
				&& sTypePath(path2).toLowerCase() == sTypePath(m.mPath)
					.toLowerCase()) Error.raiseTypingError("Module "
					+ sTypePath(path2)
					+ " is loaded with a different case than "
					+ sTypePath(m.mPath), p);
			// port: Digest signatures are already hexadecimal, so Digest.to_hex is not needed.
			var m2 = find(path2),
				hex1 = m.mExtra.mSign,
				hex2 = m2.mExtra.mSign;
			var s = hex1 == hex2 ? hex1 : "was " + hex2 + ", is " + hex1;
			Error.raiseTypingError("Type name " + sTypePath(t.mtPath) + " is redefined from module " + sTypePath(path2) + " (" + s + ")",
				p);
		} catch (_:NotFound) {
			typeLut.add(t.mtPath, m.mPath);
		}
	}

	override public function add(path:GlobalTypePath, m:ModuleDef):Void {
		super.add(path, m);
		for (mt in m.mTypes) addModuleType(m, mt);
	}

	override public function remove(path:GlobalTypePath):Void {
		try {
			for (mt in find(path).mTypes) typeLut.remove(tPath(mt));
			super.remove(path);
		} catch (_:NotFound) {}
	}

	public function findByType(path:GlobalTypePath):ModuleDef return find(typeLut.find(path));

	override public function clear():Void {
		super.clear();
		typeLut.clear();
	}

	public function getTypeLut():HashtblLookup<GlobalTypePath, GlobalTypePath> return typeLut;
}

interface AbstractHxbLib {
	public function load():Void;
	public function getBytes(target:String, path:GlobalTypePath):Null<haxe.io.Bytes>;
	public function close():Void;
	public function getFilePath():String;
	public function getStringPool(target:String):Null<Array<String>>;
}

@:structInit class ParserState {
	public var wasAutoTriggered:Bool;
	public var hadParserResume:Bool;
	public var displayModuleHasMacroDefines:Bool;
	public var delayedSyntaxCompletion:{value:Null<syntax.Parser.SyntaxCompletionOn>};
	public var specialIdentifierFiles:core.ds.ThreadSafeHashtbl<String, String>;

	public inline function new(wasAutoTriggered:Bool, hadParserResume:Bool, displayModuleHasMacroDefines:Bool,
			delayedSyntaxCompletion:{value:Null<syntax.Parser.SyntaxCompletionOn>},
			specialIdentifierFiles:core.ds.ThreadSafeHashtbl<String, String>) {
		this.wasAutoTriggered = wasAutoTriggered;
		this.hadParserResume = hadParserResume;
		this.displayModuleHasMacroDefines = displayModuleHasMacroDefines;
		this.delayedSyntaxCompletion = delayedSyntaxCompletion;
		this.specialIdentifierFiles = specialIdentifierFiles;
	}

	public inline function clone():ParserState return new ParserState(wasAutoTriggered, hadParserResume, displayModuleHasMacroDefines,
		delayedSyntaxCompletion, specialIdentifierFiles);
}

interface LocalWrapperApi {
	public function capturedType(t:T):T;
	public function mkInit(av:TVar, v:TVar, p:Pos):TExpr;
	public function mkRef(v:TVar, e:Null<TExpr>, p:Pos):TExpr;
	public function mkRefAccess(e:TExpr, v:TVar):TExpr;
}

class LocalWrapper {
	public static final nullWrapper:LocalWrapperApi = new NullLocalWrapper();
}

private class NullLocalWrapper implements LocalWrapperApi {
	public function new() {}

	public function capturedType(t:T):T return t;

	public function mkRef(v:TVar, e:Null<TExpr>, p:Pos):TExpr {
		var ev = core.Texpr.Builder.makeLocal(v, p);
		return e == null ? ev : core.Texpr.Builder.binop(OpAssign, ev, e, ev.etype, p);
	}

	public function mkRefAccess(e:TExpr, v:TVar):TExpr return e;

	public function mkInit(av:TVar, v:TVar, p:Pos):TExpr return mk(TVar(av, mk(TLocal(v), v.vType, p)), tDynamic, p);
}

@:structInit class PartScope {
	public var runtimeArgs:Array<String>;
	public var warnedPositions:core.ds.OcamlHashtbl<{file:String, offset:Int},
		{message:String, pos:Pos, options:Array<Array<WarningOption>>}>;
	public var hasNext:Bool;
	public var messages:Array<CompilerMessage>;
	public var hasError:Bool;
	public var reportMode:ReportMode;
	public var messageCapture:Null<{value:Array<CompilerMessage>}>;
	public var compilationStep:Int;
	public var passDebugMessages:Array<String>;
	public var dumpConfig:DumpConfig.DumpConfiguration;
	public var parserState:ParserState;
	public var fileKeys:FileKeys;
	public var storedTypedExprs:Lookup<Int, TExpr>;
	public var cachedMacros:Lookup<{path:GlobalTypePath, name:String}, typing.MacroContext.LoadedMacro>;

	public inline function new(runtimeArgs:Array<String>,
			warnedPositions:core.ds.OcamlHashtbl<{file:String, offset:Int}, {message:String, pos:Pos, options:Array<Array<WarningOption>>}>,
			hasNext:Bool, messages:Array<CompilerMessage>, hasError:Bool, reportMode:ReportMode,
			messageCapture:Null<{value:Array<CompilerMessage>}>, compilationStep:Int, passDebugMessages:Array<String>,
			dumpConfig:DumpConfig.DumpConfiguration, parserState:ParserState, fileKeys:FileKeys, storedTypedExprs:Lookup<Int, TExpr>,
			cachedMacros:Lookup<{
			path:GlobalTypePath,
			name:String
		}, typing.MacroContext.LoadedMacro>) {
		this.runtimeArgs = runtimeArgs;
		this.warnedPositions = warnedPositions;
		this.hasNext = hasNext;
		this.messages = messages;
		this.hasError = hasError;
		this.reportMode = reportMode;
		this.messageCapture = messageCapture;
		this.compilationStep = compilationStep;
		this.passDebugMessages = passDebugMessages;
		this.dumpConfig = dumpConfig;
		this.parserState = parserState;
		this.fileKeys = fileKeys;
		this.storedTypedExprs = storedTypedExprs;
		this.cachedMacros = cachedMacros;
		}

	public inline function clone():PartScope return new PartScope(runtimeArgs, warnedPositions, hasNext, messages, hasError, reportMode,
		messageCapture, compilationStep, passDebugMessages, dumpConfig, parserState, fileKeys, storedTypedExprs, cachedMacros);
}

enum ParseInputResult {
	NeedsTyping;
	NoCompletionPointFound;
	Completed;
}

@:structInit class RequestScope {
	public var stats:StatsData;
	public var timerCtx:core.Timer.TimerContext;
	public var cancellationRequested:Bool;
	public var io:CompilerIoData;
	public var resultHandler:ResultHandler;

	public inline function new(stats:StatsData, timerCtx:core.Timer.TimerContext, cancellationRequested:Bool, io:CompilerIoData,
			resultHandler:ResultHandler) {
		this.stats = stats;
		this.timerCtx = timerCtx;
		this.cancellationRequested = cancellationRequested;
		this.io = io;
		this.resultHandler = resultHandler;
	}

	public inline function clone():RequestScope return new RequestScope(stats, timerCtx, cancellationRequested, io, resultHandler);
}

@:structInit class ResultHandler {
	public var sendResult:JsonValue->Void;
	// port: 'a . Json.t -> 'a: never returns
	public var sendResultRaise:JsonValue->Dynamic;
	public var sendError:Array<JsonValue>->Void;
	public var sendErrorRaise:Array<JsonValue>->Dynamic;

	/** Finalize message output at the end of compilation.
		Handles error signaling, timer reports, log file writing, etc. */
	public var flushMessages:Bool->CommonContext->Void;
	public var setCom:CommonContext->ParseInputResult;

	public inline function new(sendResult:JsonValue->Void, sendResultRaise:JsonValue->Dynamic, sendError:Array<JsonValue>->Void,
			sendErrorRaise:Array<JsonValue>->Dynamic, flushMessages:Bool->CommonContext->Void, setCom:CommonContext->ParseInputResult) {
		this.sendResult = sendResult;
		this.sendResultRaise = sendResultRaise;
		this.sendError = sendError;
		this.sendErrorRaise = sendErrorRaise;
		this.flushMessages = flushMessages;
		this.setCom = setCom;
	}

	public inline function clone():ResultHandler return new ResultHandler(sendResult, sendResultRaise, sendError, sendErrorRaise,
		flushMessages, setCom);
}

// port: (string * (path -> pos -> Ast.package option))
typedef ExternTypeLoader = {name:String, load:GlobalTypePath->Pos->Null<Package>};
// port: (string list * metadata_entry * (bool * bool * bool))
typedef GlobalMetadataEntry = {path:Array<String>, meta:MetadataEntry, recursive:Bool, toTypes:Bool, toFields:Bool};
// port: (Path.UniqueKey.t * string option)
typedef FileContent = {fileKey:String, content:Null<String>};
// port: (string * string): file, position ("top"/"bottom"/"inline")
typedef IncludeFile = {file:String, position:String};

typedef CommonContext = {
	var requestScope:RequestScope;
	var partScope:PartScope;
	var stage:CompilerStage;
	var sctx:compiler.server.ServerCompilationContext;
	var cs:compiler.CompilationCache.Cache;
	var cache:Null<compiler.CompilationCache.ContextCache>;
	var isMacroContext:Bool;
	var timerCtx:core.Timer.TimerContext;
	// config
	var parsedArgs:Array<compiler.ParsedArg>;
	var display:DisplaySettings;
	var debug:Bool;
	var verbose:Bool;
	var foptimize:Bool;
	var doinline:Bool;
	var platform:Platform;
	var config:PlatformConfig;
	var customExt:Null<String>;
	var emptyClassPath:core.ClassPath.IClassPath;
	var classPaths:core.ClassPaths;
	var main:{mainPath:Null<GlobalTypePath>, mainFile:Null<String>, mainExpr:Null<TExpr>};
	var packageRules:haxe.ds.StringMap<PackageRule>;
	// communication
	var error:String->Pos->Void;
	var errorExt:CompilerError->Void;
	var info:(msg:String, p:Pos, ?depth:Int) -> Void;
	var warning:(w:WarningCode, options:Array<Array<WarningOption>>, msg:String, p:Pos, ?depth:Int) -> Void;
	var warningOptions:Array<Array<WarningOption>>;
	var getMessages:Void->Array<CompilerMessage>;
	var filterMessages:(CompilerMessage->Bool)->Void;
	var runCommand:String->Int;
	var runCommandArgs:String->Array<String>->Int;
	// typing setup
	var loadExternType:Array<ExternTypeLoader>; // allow finding types which are not in sources
	var callbacks:CompilerCallbacks;
	var defines:DefineContext;
	var userDefines:haxe.ds.StringMap<core.Define.UserDefine>;
	var userMetas:haxe.ds.StringMap<core.Meta.UserMeta>;
	var getMacros:Void->Null<CommonContext>;
	var localWrapper:LocalWrapperApi;
	// typing state
	var std:TClass;
	var globalMetadata:Array<GlobalMetadataEntry>;
	var fileContents:Array<FileContent>;
	var parserCache:Lookup<String, Array<TypeDecl>>;
	var moduleToFile:Lookup<GlobalTypePath, core.ClassPaths.ResolvedFile>;
	var overloadCache:Lookup<{path:GlobalTypePath, name:String}, Array<CastField>>;
	var moduleLut:ModuleLut;
	var moduleNonexistentLut:Lookup<GlobalTypePath, Bool>;
	// output
	var file:String;
	var features:Map<String, Bool>;
	var modules:Array<ModuleDef>;
	var types:Array<ModuleType>;
	var resources:core.ds.OcamlHashtbl<String, haxe.io.Bytes>;
	// target-specific
	var flashVersion:Float;
	var nekoLibPaths:Array<String>;
	var includeFiles:Array<IncludeFile>;
	var nativeLibs:NativeLibraries.NativeLibrariesData;
	var hxbLibs:Array<AbstractHxbLib>;
	var jsGen:Null<Void->Void>;
	// misc
	var basic:BasicTypes;
	var memoryMarker:Array<Float>;
	var hxbReaderApi:Null<compiler.hxb.HxbReaderApi>;
	var hxbReaderStats:HxbReaderStatsData;
	var hxbWriterConfig:Null<compiler.hxb.HxbWriterConfig>;
}

class Common {
	public static function samePath(a:GlobalTypePath,
			b:GlobalTypePath):Bool return a.name == b.name && a.pack.length == b.pack.length && a.pack.join(".") == b.pack.join(".");

	public static function sCompilerStage(stage:CompilerStage):String return Type.enumConstructor(stage);

	public static function toGctx(com:CommonContext):generators.Gctx return {
		platform: com.platform,
		defines: com.defines,
		basic: com.basic,
		classPaths: com.classPaths,
		runCommand: com.runCommand,
		runCommandArgs: com.runCommandArgs,
		warning: com.warning,
		error: com.error,
		io: com.requestScope.io,
		debug: com.debug,
		file: com.file,
		version: com.sctx.version,
		features: com.features,
		modules: com.modules,
		main: com.main,
		types: com.types,
		resources: com.resources,
		nativeLibs: switch com.platform {
			case Jvm: [for (l in com.nativeLibs.javaLibs) (cast l : NativeLibraries.NativeLibraryBase)];
			case Flash: [for (l in com.nativeLibs.swfLibs) (cast l : NativeLibraries.NativeLibraryBase)];
			case _: [];
		},
		includeFiles: com.includeFiles,
		std: com.std,
		timerCtx: com.timerCtx,
		pool: com.sctx.pool
	};

	// port: (string,string) Hashtbl.t; OcamlHashtbl keeps OCaml's iteration order, which the
	// generators' resource output and haxe.Resource.listNames depend on.
	public static function newResources():core.ds.OcamlHashtbl<String, haxe.io.Bytes>
		return new core.ds.OcamlHashtbl(core.ds.OcamlHash.hashString, (a:String, b:String) -> a == b);

	public static function enterStage(com:CommonContext, stage:CompilerStage):Void
		// print_endline (Printf.sprintf "Entering stage %s" (s_compiler_stage stage));
		com.stage = stage;

	public static function ignoreError(com:CommonContext):Bool {
		var b = com.display.dmsErrorPolicy == EPIgnore;
		if (b) com.partScope.hasError = true;
		return b;
	}

	public static function canRecoverInDisplay(com:CommonContext):Bool {
		return com.display.dmsErrorPolicy == EPIgnore && !com.display.dmsFullTyping;
	}

	public static function moduleWarning(com:CommonContext, m:ModuleDef, w:WarningCode, options:Array<Array<WarningOption>>, msg:String,
			p:Pos):Void {
		if (com.display.dmsFullTyping) m.mExtra.mCacheBoundObjects.push(Message(Message.makeMessage(com.isMacroContext, msg, p, 0,
			MKWarning(w, options))));
		com.warning(w, options, msg, p);
	}

	// Defines

	public static function defined(com:CommonContext, s:String):Bool return Define.defined(com.defines, s);

	public static function rawDefined(com:CommonContext, s:String):Bool return Define.rawDefined(com.defines, s);

	public static function definedValue(com:CommonContext, s:String):String return Define.definedValue(com.defines, s);

	public static function definedValueSafe(com:CommonContext, s:String,
			?defaultValue:String):String return Define.definedValueSafe(com.defines, s, defaultValue);

	public static function define(com:CommonContext, s:String):Void Define.define(com.defines, s);

	public static function rawDefine(com:CommonContext, s:String):Void Define.rawDefine(com.defines, s);

	public static function defineValue(com:CommonContext, k:String, v:String):Void Define.defineValue(com.defines, k, v);

	public static function convertDefine(k:String):String return k.split("-").join("_");

	public static function isNext(com:CommonContext):Bool return defined(com, Define.HaxeNext);

	public static function failFast(com:CommonContext):Bool return defined(com, Define.FailFast);

	// port: hxmc's persistent module cache (hxmc/src/hxmc/ModuleCache.hx) records here the defines macros
	// ... read (a null key: all of them) and write; always null in the compiler itself.
	public static var externalDefinesHook:Null<(com:CommonContext, key:Null<String>, write:Bool) -> Void> = null;

	public static function externalDefined(com:CommonContext, k:String):Bool {
		if (externalDefinesHook != null) externalDefinesHook(com, convertDefine(k), false);
		return Define.rawDefined(com.defines, convertDefine(k));
	}

	public static function externalDefinedValue(com:CommonContext, k:String):String {
		if (externalDefinesHook != null) externalDefinesHook(com, convertDefine(k), false);
		return Define.rawDefinedValue(com.defines, convertDefine(k));
	}

	public static final reservedFlags = [
		"true", "false", "null", "cross", "js", "lua", "neko", "flash", "php", "cpp", "java", "jvm", "python", "hl", "hlc", "swc",
		"macro", "sys", "static", "utf16", "haxe", "haxe_ver"
	];
	public static final reservedFlagNamespaces = ["target"];

	public static function convertAndValidate(k:String):String {
		var converted = convertDefine(k);
		if (reservedFlags.contains(converted)) throw new ArgumentError("`"
			+ k
			+ "` is a reserved compiler flag and cannot be defined from the command line");
		for (ns in reservedFlagNamespaces) if (StringTools.startsWith(converted,
			ns + ".")) throw new ArgumentError("`" + k + "` uses the reserved compiler flag namespace `" + ns
				+ ".*` and cannot be defined from the command line");
		return converted;
	}

	public static function externalDefineValue(com:CommonContext, k:String, v:String):Void {
		if (externalDefinesHook != null) externalDefinesHook(com, k, true);
		Define.rawDefineValue(com.defines, convertAndValidate(k), v);
	}

	public static function externalDefine(com:CommonContext, k:String):Void {
		if (externalDefinesHook != null) externalDefinesHook(com, k, true);
		Define.rawDefine(com.defines, convertAndValidate(k));
	}

	public static function externalUndefine(com:CommonContext, k:String):Void {
		if (externalDefinesHook != null) externalDefinesHook(com, k, true);
		Define.rawUndefine(com.defines, convertAndValidate(k));
	}

	public static function definesForExternal(com:CommonContext):haxe.ds.StringMap<String> {
		if (externalDefinesHook != null) externalDefinesHook(com, null, false);
		var result = new haxe.ds.StringMap<String>();
		var names:Array<String> = [for (k in com.defines.values.keys()) k];
		names.sort(core.ds.Key.compareStrings);
		for (k in names) {
			var v = com.defines.values.get(k);
			result.set(k, v);
			if (k.split("_").length > 1) result.set(k.split("_").join("-"), v);
		}
		return result;
	}

	public static function shortPlatformName(p:Platform):String return switch p {
		case Cross: "x";
		case Js: "js";
		case Lua: "lua";
		case Neko: "n";
		case Flash: "swf";
		case Php: "php";
		case Cpp: "cpp";
		case Jvm: "jvm";
		case Python: "py";
		case Hl: "hl";
		case Eval: "evl";
		case CustomTarget(n): "c_" + n;
	};

	public static final defaultConfig:PlatformConfig = {
		pfStatic: true,
		pfSys: true,
		pfCapturePolicy: CPNone,
		pfPadNulls: false,
		pfAddFinalReturn: false,
		pfOverload: false,
		pfCanSkipNonNullableArgument: true,
		pfReservedTypePaths: [],
		pfSupportsFunctionEquality: true,
		pfUsesUtf16: true,
		pfThisBeforeSuper: true,
		pfSupportsThreads: false,
		pfSupportsUnicode: true,
		pfSupportsRestArgs: false,
		pfExceptions: {
			ecNativeThrows: [],
			ecNativeCatches: [],
			ecWildcardCatch: {pack: ["StdTypes"], name: "Dynamic"},
			ecBaseThrow: {pack: ["StdTypes"], name: "Dynamic"},
			ecAvoidWrapping: true,
			ecSpecialThrow: function(_) return false
		},
		pfScoping: {vsScope: BlockScope, vsFlags: []},
		pfSupportsAtomics: false
	};

	public static function getConfig(com:CommonContext):PlatformConfig {
		inline function path(pack:Array<String>, name:String):GlobalTypePath return {pack: pack, name: name};
		if (com.platform == Cross) return defaultConfig;
		var c:PlatformConfig = cast core.ds.Record.copy(defaultConfig);
		c.pfExceptions = cast core.ds.Record.copy(defaultConfig.pfExceptions);
		c.pfScoping = cast core.ds.Record.copy(defaultConfig.pfScoping);
		switch com.platform {
			case Cross:
				return defaultConfig;
			case CustomTarget(_):
				// impossible to reach. see update_platform_config
				throw core.ds.Exit.raise();
			case Js:
				var es6 = getEsVersion(com.defines) >= 6;
				c.pfStatic = false;
				c.pfSys = false;
				c.pfCapturePolicy = es6 ? CPNone : CPLoopVars;
				c.pfReservedTypePaths = [path([], "Object"), path([], "Error")];
				c.pfThisBeforeSuper = !es6; // cannot access `this` before `super()` when generating ES6 classes
				c.pfSupportsRestArgs = true;
				c.pfExceptions.ecNativeThrows = [path(["js", "lib"], "Error"), path(["haxe"], "Exception")];
				c.pfExceptions.ecAvoidWrapping = false;
				c.pfScoping = {
					vsScope: es6 ? BlockScope : FunctionScope,
					vsFlags: [
						defined(com, Define.JsUnflatten) ? ReserveAllTopLevelSymbols : ReserveAllTypesFlat
					].concat(es6 ? [NoShadowing, SwitchCasesNoBlocks] : [VarHoisting, NoCatchVarShadowing])
				};
				c.pfSupportsAtomics = true;
			case Lua:
				c.pfStatic = false;
				c.pfCapturePolicy = CPLoopVars;
				c.pfUsesUtf16 = false;
				c.pfSupportsRestArgs = true;
				c.pfExceptions.ecAvoidWrapping = false;
			case Neko:
				c.pfStatic = false;
				c.pfPadNulls = true;
				c.pfUsesUtf16 = false;
				c.pfSupportsThreads = true;
				c.pfSupportsUnicode = false;
				c.pfScoping.vsFlags = [ReserveAllTopLevelSymbols];
				c.pfExceptions.ecAvoidWrapping = false;
			case Flash:
				c.pfSys = false;
				c.pfCapturePolicy = CPLoopVars;
				c.pfCanSkipNonNullableArgument = false;
				c.pfReservedTypePaths = [path([], "Object"), path([], "Error")];
				c.pfSupportsRestArgs = true;
				c.pfExceptions.ecNativeThrows = [path(["flash", "errors"], "Error"), path(["haxe"], "Exception")];
				c.pfExceptions.ecNativeCatches = [path(["flash", "errors"], "Error"), path(["haxe"], "Exception")];
				c.pfExceptions.ecAvoidWrapping = false;
				c.pfScoping = {vsScope: FunctionScope, vsFlags: [VarHoisting]};
			case Php:
				c.pfStatic = false;
				c.pfUsesUtf16 = false;
				c.pfSupportsRestArgs = true;
				c.pfExceptions.ecNativeThrows = [path(["php"], "Throwable"), path(["haxe"], "Exception")];
				c.pfExceptions.ecNativeCatches = [path(["php"], "Throwable"), path(["haxe"], "Exception")];
				c.pfExceptions.ecWildcardCatch = path(["php"], "Throwable");
				c.pfExceptions.ecBaseThrow = path(["php"], "Throwable");
				c.pfScoping = {vsScope: FunctionScope, vsFlags: [VarHoisting]};
			case Cpp:
				c.pfCapturePolicy = CPWrapRef;
				c.pfPadNulls = true;
				c.pfAddFinalReturn = true;
				c.pfSupportsThreads = true;
				c.pfSupportsUnicode = defined(com, Define.Cppia) || !defined(com, Define.DisableUnicodeStrings);
				c.pfExceptions.ecAvoidWrapping = false;
				c.pfScoping = {vsFlags: [NoShadowing], vsScope: FunctionScope};
				c.pfSupportsAtomics = true;
			case Jvm:
				c.pfCapturePolicy = CPWrapRef;
				c.pfPadNulls = true;
				c.pfOverload = true;
				c.pfSupportsThreads = true;
				c.pfSupportsRestArgs = true;
				c.pfThisBeforeSuper = false;
				c.pfExceptions.ecNativeThrows = [path(["java", "lang"], "RuntimeException"), path(["haxe"], "Exception")];
				c.pfExceptions.ecNativeCatches = [path(["java", "lang"], "Throwable"), path(["haxe"], "Exception")];
				c.pfExceptions.ecWildcardCatch = path(["java", "lang"], "Throwable");
				c.pfExceptions.ecBaseThrow = path(["java", "lang"], "RuntimeException");
				c.pfSupportsAtomics = true;
			case Python:
				c.pfStatic = false;
				c.pfCapturePolicy = CPLoopVars;
				c.pfUsesUtf16 = false;
				c.pfSupportsThreads = true;
				c.pfSupportsRestArgs = true;
				c.pfExceptions.ecNativeThrows = [path(["python", "Exceptions"], "BaseException")];
				c.pfExceptions.ecNativeCatches = [path(["python", "Exceptions"], "BaseException")];
				c.pfExceptions.ecWildcardCatch = path(["python", "Exceptions"], "BaseException");
				c.pfExceptions.ecBaseThrow = path(["python", "Exceptions"], "BaseException");
				c.pfScoping = {vsScope: FunctionScope, vsFlags: [VarHoisting]};
			case Hl:
				c.pfCapturePolicy = CPWrapRef;
				c.pfPadNulls = true;
				c.pfSupportsThreads = true;
				c.pfSupportsAtomics = true;
				c.pfScoping = {vsScope: BlockScope, vsFlags: [NoShadowing]};
				c.pfExceptions.ecAvoidWrapping = false;
			case Eval:
				c.pfStatic = false;
				c.pfPadNulls = true;
				c.pfUsesUtf16 = false;
				c.pfSupportsThreads = true;
				c.pfCapturePolicy = CPWrapRef;
				c.pfExceptions.ecAvoidWrapping = false;
				c.pfSupportsAtomics = true;
		}
		return c;
	}

	// port: Gctx.get_es_version from haxe/src/generators/gctx.ml.
	static function getEsVersion(defines:DefineContext):Int {
		try {
			var version = StdTools.parseInt(Define.definedValue(defines, Define.JsEs));
			return version == null ? 0 : version;
		} catch (_:Dynamic) return 0;
	}

	public static final memoryMarker = [Sys.time()];

	static function newBasicTypes():BasicTypes return {
		tvoid: mkMono(),
		tany: mkMono(),
		tint: mkMono(),
		tfloat: mkMono(),
		tbool: mkMono(),
		tstring: mkMono(),
		texception: mkMono(),
		tnull: function(_) throw "Could use locate abstract Null<T> (was it redefined?)",
		tarray: function(_) throw "Could not locate class Array<T> (was it redefined?)",
		titerator: function(_) throw "Could not locate typedef Iterator<T> (was it redefined?)",
		tunit: mkMono(),
		tcoro: {
			tcoro: AtomicLazy.fromFun(function():TSignature->T return function(_:TSignature):T
				throw "Could not locate abstract Coroutine<T> (was it redefined?)"),
			continuation: AtomicLazy.fromFun(function() return mkMono()),
			suspensionResultClass: AtomicLazy.fromFun(function() return nullClass),
			tasyncIterator: AtomicLazy.fromFun(function():T->T return function(_:T):T
				throw "Could not locate typedef AsyncIterator<T> (was it redefined?)")
		}
	};

	public static function create(sctx:compiler.server.ServerCompilationContext, requestScope:RequestScope, partScope:PartScope,
			displayMode:DisplaySettings):CommonContext {
		// port: OCaml runs Type's reference initialization at link time, before basic types
		// are constructed; here it is an explicit call.
		core.Type.initialize();
		var com:CommonContext = null;
		com = {
			requestScope: requestScope,
			partScope: partScope,
			sctx: sctx,
			cs: sctx.cs,
			cache: null,
			timerCtx: requestScope.timerCtx,
			stage: CCreated,
			parsedArgs: [],
			debug: false,
			display: displayMode,
			verbose: false,
			foptimize: true,
			doinline: true,
			features: new Map(),
			platform: Cross,
			config: defaultConfig,
			customExt: null,
			runCommand: function(cmd) return Sys.command(cmd),
			runCommandArgs: function(s, args) return com.runCommand(s + " " + args.join(" ")),
			emptyClassPath: new core.ClassPath.DirectoryClassPath("", User),
			classPaths: new core.ClassPaths(),
			main: {
				mainPath: null,
				mainFile: null,
				mainExpr: null
			},
			packageRules: new haxe.ds.StringMap(),
			file: "",
			types: [],
			callbacks: new CompilerCallbacks(),
			globalMetadata: [],
			modules: [],
			moduleLut: new ModuleLut(),
			moduleNonexistentLut: new HashtblLookup(),
			flashVersion: 10.0,
			resources: newResources(),
			nativeLibs: NativeLibraries.createNativeLibs(),
			hxbLibs: [],
			nekoLibPaths: [],
			includeFiles: [],
			jsGen: null,
			loadExternType: [],
			defines: Define.emptyDefines(),
			userDefines: new haxe.ds.StringMap(),
			userMetas: new haxe.ds.StringMap(),
			getMacros: function() return null,
			localWrapper: LocalWrapper.nullWrapper,
			info: function(_, _, ?depth) throw "Uninitialized info handler",
			warning: function(_, _, _, _, ?depth) throw "Uninitialized warning handler",
			warningOptions: [
				WarningList.disabledWarnings.map(function(w) return ({
					woWarning: w,
					woMode: WMDisable
				} : core.Message.WarningOption))
			],
			error: function(_, _) throw "Uninitialized error handler",
			errorExt: function(_) throw "Uninitialized error handler",
			getMessages: function() return [],
			filterMessages: function(_) {},
			basic: newBasicTypes(),
			std: nullClass,
			fileContents: [],
			moduleToFile: new HashtblLookup(),
			memoryMarker: memoryMarker,
			parserCache: new HashtblLookup(),
			overloadCache: new HashtblLookup(),
			isMacroContext: false,
			hxbReaderApi: null,
			hxbReaderStats: HxbReaderStats.create(),
			hxbWriterConfig: null
		};
		return com;
	}

	public static function isDiagnostics(com:CommonContext):Bool return switch com.partScope.reportMode {
		case RMDiagnostics(_): true;
		case _: false;
	};

	public static function isCompilation(com:CommonContext):Bool return com.display.dmsKind == DMNone && !isDiagnostics(com);

	public static function hasErrorToReport(com:CommonContext):Bool {
		return com.partScope.hasError && (isCompilation(com) || com.partScope.messages.length != 0);
	}

	public static function activateMessageCapture(com:CommonContext, buf:{value:Array<CompilerMessage>}):Void->Void {
		var oldCapture = com.partScope.messageCapture;
		var oldHook = core.TFunctions.lazyForceHook;
		com.partScope.messageCapture = buf;
		core.TFunctions.lazyForceHook = function(f) {
			var saved = com.partScope.messageCapture;
			com.partScope.messageCapture = null;
			var r:Dynamic;
			try r = f()
			catch (e:haxe.Exception) {
				com.partScope.messageCapture = saved;
				throw e;
			}
			com.partScope.messageCapture = saved;
			return r;
		};
		return function() {
			com.partScope.messageCapture = oldCapture;
			core.TFunctions.lazyForceHook = oldHook;
		};
	}

	public static function commitCapturedMessages(com:CommonContext, buf:Array<CompilerMessage>):Void {
		var ordered = buf.copy();
		ordered.reverse();
		for (cm in ordered) {
			if (com.partScope.messageCapture != null) com.partScope.messageCapture.value.unshift(cm);
			else {
				if (Message.severity(cm) == MessageSeverity.Error) com.partScope.hasError = true;
				com.partScope.messages.unshift(cm);
			}
		}
	}

	public static function disableReportMode(com:CommonContext):Void->Void {
		var old = com.partScope.reportMode;
		com.partScope.reportMode = RMNone;
		return function() com.partScope.reportMode = old;
	}

	public static function log(com:CommonContext, str:String):Void {
		if (com.verbose) CompilerIo.writeOut(com.requestScope.io, str + "\n");
	}

	public static function clone(com:CommonContext, isMacroContext:Bool):CommonContext {
		// keeps
		// port: the shallow copy keeps the fields upstream copies; the reinits follow.
		var out:CommonContext = cast core.ds.Record.copy(com);
		// port: global_metadata is an immutable list upstream (prepended to): the clone keeps a snapshot
		out.globalMetadata = com.globalMetadata.copy();
		out.defines = {values: com.defines.values, definesSignature: com.defines.definesSignature};
		// reinits
		out.cache = null;
		out.stage = CCreated;
		out.features = new Map();
		out.emptyClassPath = new core.ClassPath.DirectoryClassPath("", User);
		out.classPaths = new core.ClassPaths();
		out.main = {mainPath: null, mainFile: null, mainExpr: null};
		out.types = [];
		out.callbacks = new CompilerCallbacks();
		out.modules = [];
		out.moduleLut = new ModuleLut();
		out.moduleNonexistentLut = new HashtblLookup();
		out.loadExternType = []; // !
		out.basic = newBasicTypes();
		out.localWrapper = LocalWrapper.nullWrapper;
		out.std = nullClass;
		out.moduleToFile = new HashtblLookup();
		out.parserCache = new HashtblLookup();
		out.overloadCache = new HashtblLookup(); // !
		out.isMacroContext = isMacroContext;
		out.hxbReaderApi = null;
		out.hxbReaderStats = HxbReaderStats.create();
		return out;
	}

	// port: Extc.filetime returns zero when stat fails (including absent import.hx).
	public static function fileTime(file:String):Float return try sys.FileSystem.stat(file).mtime.getTime() / 1000.0 catch (_:Dynamic) 0.;

	public static final flashVersions = [
		9., 10., 10.1, 10.2, 10.3, 11., 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 11.7, 11.8, 11.9, 12., 13., 14., 15., 16., 17., 18., 19., 20.,
		21., 22., 23., 24., 25., 26., 27., 28., 29., 31., 32.
	].map(function(v) {
		var major = StdTools.int(v), minor = StdTools.int((v * 10.) % 10.);
		return {version: v, define: StdTools.string(major) + (minor == 0 ? "" : "_" + minor)};
	});

	public static function updatePlatformConfig(com:CommonContext):Void switch com.platform {
		case CustomTarget(_):
			// do nothing, configured with macro api
		case _:
			com.config = getConfig(com);
	};

	public static function initPlatform(com:CommonContext):Void {
		var name = Globals.platformName(com.platform);
		switch com.platform {
			case Flash if (core.Path.fileExtension(com.file) == "swc"):
				define(com, Define.Swc);
			case Jvm:
				rawDefine(com, "java");
			case Hl:
				if (core.Path.fileExtension(com.file) == "c") define(com, Define.Hlc);
			case _:
		}
		// Set the source header, unless the user has set one already or the platform sets a custom one
		if (!defined(com,
			Define.SourceHeader) && com.platform != Hl) defineValue(com, Define.SourceHeader,
				"Generated by Haxe " + sVersionFull(com.sctx.version));
		var packages = ["java"].concat(Globals.platforms.map(Globals.platformName));
		var rules = copyStringMap(com.packageRules);
		for (p in packages) if (p != name && !rules.exists(p)) rules.set(p, Forbidden);
		com.packageRules = rules;
		updatePlatformConfig(com);
		if (com.config.pfStatic) {
			rawDefine(com, "target.static");
			define(com, Define.Static);
		}
		if (com.config.pfSys) {
			rawDefine(com, "target.sys");
			define(com, Define.Sys);
		} else {
			var rules = copyStringMap(com.packageRules);
			rules.set("sys", Forbidden);
			com.packageRules = rules;
		}
		if (com.config.pfUsesUtf16) {
			rawDefine(com, "target.utf16");
			define(com, Define.Utf16);
		}
		if (com.config.pfSupportsThreads) rawDefine(com, "target.threaded");
		if (com.config.pfSupportsUnicode) rawDefine(com, "target.unicode");
		Define.rawDefineValue(com.defines, "target.name", name);
		rawDefine(com, switch com.platform {
			case CustomTarget(_): "custom_target";
			case _: name;
		});
		if (com.config.pfSupportsAtomics) rawDefine(com, "target.atomics");
	}

	static function copyStringMap<A>(m:haxe.ds.StringMap<A>):haxe.ds.StringMap<A> {
		var out = new haxe.ds.StringMap<A>();
		for (k in m.keys()) out.set(k, m.get(k));
		return out;
	}

	public static function setPlatform(com:CommonContext, pf:Platform, file:String):Void {
		if (com.platform != Cross) throw "Multiple targets";
		com.platform = pf;
		com.file = file;
	}

	public static function setCustomTarget(com:CommonContext, name:String, path:String):Void {
		if (core.ds.ArrayTools.exists(Globals.platforms,
			function(pf) return Globals.platformName(pf) == name)) throw new ArgumentError("--custom-target cannot use reserved name "
				+ name);
		if (name.length > maxCustomTargetLen) throw new ArgumentError("--custom-target name " + name + " exceeds the maximum of "
			+ maxCustomTargetLen + " characters");
		if (~/^[a-zA-Z0-9_]+$/.match(name)) setPlatform(com, CustomTarget(name), path);
		else throw new ArgumentError("--custom-target name " + name + " may only contain alphanumeric or underscore characters");
	}

	public static function addFeature(com:CommonContext, f:String):Void com.features.set(f, true);

	public static function hasDce(com:CommonContext):Bool {
		try return definedValue(com, Define.Dce) != "no"
		catch (_:NotFound) {
			return false;
		}
	}

	/*
		TODO: The has_dce check is there because we mark types with @:directlyUsed in the DCE filter,
		which is not run in dce=no and thus we can't know if a type is used directly or not,
		so we just assume that they are.

		If we had dce filter always running (even with dce=no), we would have types marked with @:directlyUsed
		and we wouldn't need to generate unnecessary imports in dce=no, but that's good enough for now.
	*/
	public static function isDirectlyUsed(com:CommonContext, meta:Metadata):Bool return !hasDce(com) || Meta.has(Meta.DirectlyUsed, meta);

	public static function hasFeature(com:CommonContext, f:String):Bool {
		if (com.features.exists(f)) return com.features.get(f);
		if (com.types.length == 0) return !hasDce(com);
		var parts = f.split(".");
		parts.reverse();
		if (parts.length == 0) throw "Invalid feature";
		if (parts.length == 1) return hasFeature(com, parts[0] + ".*");
		var field = parts[0], cl = parts[1], pack = parts.slice(2);
		pack.reverse();
		var result = false;
		try {
			var found:Null<ModuleType> = null;
			for (t in com.types) if (samePath(tPath(t), {pack: pack, name: cl}) && !Meta.has(Meta.RealPath, tInfos(t).mtMeta)) {
				found = t;
				break;
			}
			if (found == null) throw NotFound.raise();
			if (field == "*") result = !hasDce(com) || switch found {
				case TClassDecl(c): hasClassFlag(c, CUsed);
				case TAbstractDecl(a): Meta.has(Meta.ValueUsed, a.aMeta);
				case _: Meta.has(Meta.Used, tInfos(found).mtMeta);
			};
			else switch found {
				case TClassDecl(c) if (hasClassFlag(c, CExtern) && (com.platform != Js || (cl != "Array" && cl != "Math"))):
					if (!hasDce(com)) result = true;
					else {
						var cf = c.clStatics.get(field);
						if (cf == null) cf = c.clFields.get(field);
						if (cf == null) throw NotFound.raise();
						result = hasClassFieldFlag(cf, CfUsed);
					}
				case TClassDecl(c):
					result = c.clStatics.exists(field) || c.clFields.exists(field);
				case _:
					result = false;
			}
		} catch (_:NotFound) {
			result = false;
		}
		com.features.set(f, result);
		return result;
	}

	public static function allowPackage(com:CommonContext, s:String):Void {
		if (com.packageRules.get(s) == Forbidden) {
			var rules = copyStringMap(com.packageRules);
			rules.remove(s);
			com.packageRules = rules;
		}
	}

	public static function platform(com:CommonContext, p:Platform):Bool return com.platform == p;

	public static function platformNameMacro(com:CommonContext):String return defined(com,
		Define.Macro) ? "macro" : Globals.platformName(com.platform);

	public static function findFile(com:CommonContext, f:String):String return com.classPaths.findFile(f).file;

	// port: mem_size is Memory.memSize.
	public static function hash(f:String):Int {
		var h = 0;
		for (i in 0...f.length) h = h * 223 + f.charCodeAt(i);
		return (h << 1) >> 1;
	}

	public static function addDiagnosticsMessage(com:CommonContext, s:String, p:Pos, kind:CompilerMessageKind, depth:Int = 0,
			?diagnosticsKind:MessageKind):Void {
		if (diagnosticsKind == null) diagnosticsKind = DKCompilerMessage;
		var cm = Message.makeDiagnostic(com.isMacroContext, diagnosticsKind, JString(s), p, depth, kind);
		if (com.partScope.messageCapture != null) com.partScope.messageCapture.value.unshift(cm);
		else {
			if (Message.messageKindSeverity(kind) == MessageSeverity.Error) com.partScope.hasError = true;
			com.partScope.messages.unshift(cm);
		}
	}

	public static function displayErrorExt(com:CommonContext, err:CompilerError):Void {
		if (isDiagnostics(com)) Error.recurseError(function(depth,
				err) addDiagnosticsMessage(com, Error.errorMsg(err.errMessage), err.errPos, MKError, depth), err);
		else com.errorExt(err);
	}

	public static function displayError(com:CommonContext, msg:String, pos:Pos,
			?sub:Array<core.Error.MacroError>):Void displayErrorExt(com, Error.convertError({
			msg: msg,
			pos: pos,
			sub: sub == null ? [] : sub
		}));

	public static function adaptDefinesToMacroContext(defines:DefineContext):DefineContext {
		var remove = ["java"].concat(Globals.platforms.map(Globals.platformName));
		for (d in [Define.NoTraces]) remove.unshift(Define.getDefineKey(d));
		for (v in flashVersions) remove.unshift("flash" + v.define);
		var values = new haxe.ds.StringMap<String>();
		var keys:Array<String> = [for (k in defines.values.keys()) k];
		keys.sort(core.ds.Key.compareStrings);
		for (k in keys) if (!remove.contains(k)) values.set(k, defines.values.get(k));
		var result = ({values: values, definesSignature: null} : core.Define.DefineContext);
		Define.define(result, Define.Macro);
		Define.rawDefine(result, Globals.platformName(Eval));
		return result;
	}

	public static function adaptDefinesToDisplayContext(defines:DefineContext):DefineContext {
		var result = adaptDefinesToMacroContext(defines);
		Define.define(result, Define.Display);
		return result;
	}

	public static function getEntryPoint(com:CommonContext):Null<{name:String, cls:TClass, expr:TExpr}> {
		var path = com.main.mainPath;
		if (path == null) return null;
		var m:ModuleDef = null;
		for (candidate in com.modules) if (samePath(candidate.mPath, path)) {
			m = candidate;
			break;
		}
		if (m == null) throw NotFound.raise();
		var c = m.mStatics;
		if (c == null || !c.clStatics.exists("main")) {
			c = null;
			for (t in m.mTypes) switch t {
				case TClassDecl(cls) if (samePath(cls.clPath, path)):
					c = cls;
					break;
				case _:
			}
			if (c == null) throw "Invalid_argument: option is None";
		}
		// must be present at this point
		if (com.main.mainExpr == null) throw "Invalid_argument: option is None";
		return {name: path.name, cls: c, expr: com.main.mainExpr};
	}

	public static function expandCoroType(basic:BasicTypes, args:Array<{name:String, optional:Bool, type:T}>, ret:T):TSignature {
		var args = [
			{name: "_hx_continuation", optional: false, type: basic.tcoro.continuation.force()}
		].concat(args);
		if (ExtType.isVoid(follow(ret))) ret = basic.tunit;
		return {args: args, ret: TInst(basic.tcoro.suspensionResultClass.force(), [ret])};
	}

	// port: hxmc's persistent module cache (hxmc/src/hxmc/ModuleCache.hx) wraps the lazy typings here, to know
	// ... which module's typing one continues; always null in the compiler itself.
	public static var lazyHook:Null<(Void->T)->(Void->T)> = null;

	public static function makeUnforcedLazy(tProc:T, f:Void->T, where:String):TLazy {
		if (lazyHook != null) f = lazyHook(f);
		var r = new TLazy(lazyAvailable(tDynamic));
		r.value = lazyWait(function() {
			try {
				r.value = lazyProcessing(tProc);
				var t = f();
				r.value = lazyAvailable(t);
				return t;
			} catch (e:core.Error.TypingError) {
				throw new core.Error.FatalError(e.error);
			}
		});
		return r;
	}

	public static function checkCancellation(com:CommonContext):Void {
		if (com.requestScope.cancellationRequested) throw new Cancelled();
	}
}
