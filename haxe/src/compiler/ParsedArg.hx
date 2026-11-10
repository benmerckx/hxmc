package compiler;

import core.Globals.GlobalTypePath;
import core.Globals.Platform;

enum NativeLibKind {
	JavaLib;
	SwfLib;
	HxbLib;
}

@:structInit class NativeLibArg {
	public var libFile:String;
	public var libKind:NativeLibKind;
	public var libExtern:Bool;

	public inline function new(libFile:String, libKind:NativeLibKind, libExtern:Bool) {
		this.libFile = libFile;
		this.libKind = libKind;
		this.libExtern = libExtern;
	}

	public inline function clone():NativeLibArg return new NativeLibArg(libFile, libKind, libExtern);
}

enum ExpandingArgFunction {
	AddLibs(libs:Array<String>, cwd:String);
}

enum ExpandingArgState {
	NotYetExpanded(f:ExpandingArgFunction);
	AlreadyExpanded(args:Array<ParsedArg>);
}

class ExpandingArg {
	public final original:Array<ParsedArg>;
	public var state:ExpandingArgState;

	public function new(original:Array<ParsedArg>, state:ExpandingArgState) {
		this.original = original;
		this.state = state;
	}
}

enum ParsedArg {
	// Targets
	SetPlatform(platform:Platform, output:String);
	SetCustomTarget(name:String, path:String);
	/** --cppia: cpp target with cppia define */
	SetCppiaTarget(output:String);
	// Compilation
	AddClassPath(path:String);
	AddLibClassPath(path:String, name:Null<String>);
	AddHxbLib(file:String);
	// port: the `path` (pack, name) as the flat list pack @ [name].
	SetMain(path:Array<String>);
	AddLib(name:String);
	HaxelibGlobal;
	Define(flag:String, value:Null<String>);
	Undefine(flag:String);
	SetVerbose;
	SetDebug;
	/** --interp: eval target + interp flag */
	Interp;
	/** --run: path + runtime args (terminal; rest becomes argv) */
	Run(path:String, arguments:Array<String>);
	/** -x: shorthand run (non-terminal; subsequent args are still build args) */
	RunX(path:String);
	AddResource(file:String, name:String);
	RunCmd(command:String);
	SetSwfVersion(version:Float);
	SetDce(mode:String);
	AddNativeLib(library:NativeLibArg);
	AddNekoLibPath(path:String);
	Remap(pack:String, target:String);
	SetCustomExtension(extension:String);
	AddMacro(expression:String);
	SetDisplayArg(input:String);
	SetXmlOut(file:String);
	SetJsonOut(file:String);
	SetHxbOut(file:String);
	SetNoOutput;
	SetMeasureTimes;
	AddWarning(setting:String);

	// port: the `path` (pack, name) as the flat list pack @ [name].
	AddClass(path:Array<String>);
	IncludeModule(module:String);
	SetPrompt;
	// Batch
	Next;
	Each;
	Expand(ex:ExpandingArg);
	// Server
	ServerListen(hostPort:String);
	ServerConnect(hostPort:String);
	Connect(hostPort:String);
	// Working directory - applied eagerly for hxml resolution
	Cwd(path:String);
	// Hxml file reference - expanded lazily in process_params
	HxmlFile(file:String);
	// Early-exit helpers (raise HelpMessage when processed)
	ShowVersion;
	ShowHelp;
	ShowHelpDefines;
	ShowHelpMetas;
	ShowHelpUserDefines;
	ShowHelpUserMetas;
}

@:structInit class ArgContext {
	public var classes:Array<GlobalTypePath>;
	public var xmlOut:Null<String>;
	public var hxbOut:Null<String>;
	public var jsonOut:Null<String>;
	public var cmds:Array<String>;
	public var configMacros:Array<String>;
	public var noOutput:Bool;
	public var didSomething:Bool;
	public var forceTyping:Bool;
	public var preCompilation:Array<Void->Void>;
	public var interp:Bool;
	public var jvmFlag:Bool;
	public var swfVersion:Bool;
	public var hxbLibs:Array<NativeLibArg>;
	public var nativeLibs:Array<NativeLibArg>;
	public var raiseUsage:Void->Void;
	public var displayArg:Null<String>;

	public var measureTimes:Bool;

	public inline function new(classes:Array<GlobalTypePath>, xmlOut:Null<String>, hxbOut:Null<String>, jsonOut:Null<String>,
			cmds:Array<String>, configMacros:Array<String>, noOutput:Bool, didSomething:Bool, forceTyping:Bool,
			preCompilation:Array<Void->Void>, interp:Bool, jvmFlag:Bool, swfVersion:Bool, hxbLibs:Array<NativeLibArg>,
			nativeLibs:Array<NativeLibArg>, raiseUsage:Void->Void, displayArg:Null<String>, measureTimes:Bool) {
		this.classes = classes;
		this.xmlOut = xmlOut;
		this.hxbOut = hxbOut;
		this.jsonOut = jsonOut;
		this.cmds = cmds;
		this.configMacros = configMacros;
		this.noOutput = noOutput;
		this.didSomething = didSomething;
		this.forceTyping = forceTyping;
		this.preCompilation = preCompilation;
		this.interp = interp;
		this.jvmFlag = jvmFlag;
		this.swfVersion = swfVersion;
		this.hxbLibs = hxbLibs;
		this.nativeLibs = nativeLibs;
		this.raiseUsage = raiseUsage;
		this.displayArg = displayArg;
		this.measureTimes = measureTimes;
	}

	public inline function clone():ArgContext return new ArgContext(classes, xmlOut, hxbOut, jsonOut, cmds, configMacros, noOutput,
		didSomething, forceTyping, preCompilation, interp, jvmFlag, swfVersion, hxbLibs, nativeLibs, raiseUsage, displayArg, measureTimes);
}

class ParsedArgTools {
	public static function createNativeLib(file:String, extern_:Bool, kind:NativeLibKind):NativeLibArg {
		return {
			libFile: file,
			libExtern: extern_,
			libKind: kind
		};
	}
}
