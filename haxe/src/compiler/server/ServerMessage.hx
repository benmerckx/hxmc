package compiler.server;

import core.Globals;
import core.Globals.Pos;
import core.TType;
import core.Define;
import context.Common;
import compiler.CompilationCache.CachedDirectory;

@:structInit class ServerMessageOptions {
	public var printCompilerStage:Bool;
	public var printAddedDirectory:Bool;
	public var printFoundDirectories:Bool;
	public var printChangedDirectories:Bool;
	public var printModulePathChanged:Bool;
	public var printNotCached:Bool;
	public var printParsed:Bool;
	public var printRemovedDirectory:Bool;
	public var printReusing:Bool;
	public var printRetyping:Bool;
	public var printSkippingDep:Bool;
	public var printUnchangedContent:Bool;
	public var printCachedModules:Bool;
	public var printClassPathsChanged:Bool;
	public var printArguments:Bool;
	public var printCompletion:Bool;
	public var printDefines:Bool;
	public var printSignature:Bool;
	public var printDisplayPosition:Bool;
	public var printStats:Bool;
	public var printMessage:Bool;
	public var printSocketMessage:Bool;
	public var printUncaughtError:Bool;
	public var printNewContext:Bool;
}

class ServerMessage {
	public static final config:ServerMessageOptions = {
		printCompilerStage: false,
		printAddedDirectory: false,
		printFoundDirectories: false,
		printChangedDirectories: false,
		printModulePathChanged: false,
		printNotCached: false,
		printParsed: false,
		printRemovedDirectory: false,
		printReusing: false,
		printRetyping: false,
		printSkippingDep: false,
		printUnchangedContent: false,
		printCachedModules: false,
		printClassPathsChanged: false,
		printArguments: false,
		printCompletion: false,
		printDefines: false,
		printSignature: false,
		printDisplayPosition: false,
		printStats: false,
		printMessage: false,
		printSocketMessage: false,
		printUncaughtError: false,
		printNewContext: false
	};

	// port: OCaml print_endline: writes the line and flushes stdout.
	static function printEndline(s:String):Void {
		var out = Sys.stdout();
		out.writeString(s + "\n");
		out.flush();
	}

	// port: Printf "%Ni": right-aligned in a field of width N.
	static function pad(s:String, width:Int):String {
		return StringTools.lpad(s, " ", width);
	}

	public static function signString(com:CommonContext):String {
		var sign = Define.getSignature(com.defines);
		var cs = com.cs;
		var signId = cs.getContext(sign).getIndex();
		return pad(Std.string(signId), 2) + "," + pad(Common.shortPlatformName(com.platform), 3) + ": ";
	}

	public static function compilerStage(com:CommonContext):Void {
		if (config.printCompilerStage) printEndline("compiler stage: " + Common.sCompilerStage(com.stage));
	}

	public static function addedDirectory(com:CommonContext, tabs:String, dir:String):Void {
		if (config.printAddedDirectory) printEndline(signString(com) + "added directory " + dir);
	}

	public static function foundDirectories(com:CommonContext, tabs:String, dirs:Array<CachedDirectory>):Void {
		if (config.printFoundDirectories) printEndline(signString(com) + "found " + dirs.length + " directories");
	}

	public static function changedDirectories(com:CommonContext, tabs:String, dirs:Array<CachedDirectory>):Void {
		if (config.printChangedDirectories) printEndline(signString(com) + "changed directories: ["
			+ dirs.map(dir -> "\"" + dir.cPath + "\"").join(", ") + "]");
	}

	// port: Printf "%2.0f"
	static function float0(f:Float):String {
		return pad(Std.string(Math.fround(f)), 2);
	}

	public static function modulePathChanged(com:CommonContext, tabs:String, mPath:GlobalTypePath, mExtra:ModuleDefExtra, time:Float,
			file:String):Void {
		if (config.printModulePathChanged) printEndline(signString(com) + "module path might have changed: " + Globals.sTypePath(mPath)
			+ "\n\twas: " + float0(mExtra.mTime) + " " + core.Path.UniqueKey.lazyPath(mExtra.mFile) + "\n\tnow: " + float0(time) + " "
			+ file);
	}

	public static function notCached(com:CommonContext, tabs:String, mPath:GlobalTypePath):Void {
		if (config.printNotCached) printEndline(signString(com) + Globals.sTypePath(mPath) + " not cached (" + "modified" + ")");
	}

	public static function parsed(com:CommonContext, tabs:String, ffile:String, info:String):Void {
		if (config.printParsed) printEndline(signString(com) + "parsed " + ffile + " (" + info + ")");
	}

	public static function removedDirectory(com:CommonContext, tabs:String, dir:String):Void {
		if (config.printRemovedDirectory) printEndline(signString(com) + "removed directory " + dir);
	}

	public static function reusing(com:CommonContext, tabs:String, m:ModuleDef):Void {
		if (config.printReusing) printEndline(signString(com) + tabs + "reusing " + Globals.sTypePath(m.mPath));
	}

	/* [reason] is only formatted when the message is printed: the string holds the whole dependency chain */
	public static function skippingDep(com:CommonContext, tabs:String, mpath:GlobalTypePath, reason:Void->String):Void {
		if (config.printSkippingDep) printEndline(signString(com) + "skipping " + Globals.sTypePath(mpath) + " (" + reason() + ")");
	}

	public static function unchangedContent(com:CommonContext, tabs:String, file:String):Void {
		if (config.printUnchangedContent) printEndline(signString(com) + file + " changed time not but content, reusing");
	}

	public static function cachedModules(com:CommonContext, tabs:String, i:Int):Void {
		if (config.printCachedModules) printEndline(signString(com) + "Cached " + i + " modules");
	}

	public static function classPathsChanged(com:CommonContext, tabs:String):Void {
		if (config.printClassPathsChanged) printEndline(signString(com) + "class paths changed, resetting directories");
	}

	// port: JS functions have their own `arguments`; on C++, @:native would turn the call into a global function
	#if js @:native("arguments_") #end
	public static function arguments(data:String):Void {
		if (config.printArguments) printEndline("Processing Arguments " + data);
	}

	public static function completion(str:String):Void {
		if (config.printCompletion) printEndline("Completion Response =\n" + str);
	}

	public static function defines(com:CommonContext, tabs:String):Void {
		if (config.printDefines) {
			var buffer = new StringBuf();
			buffer.add("Defines ");
			// port: PMap.iter: ascending key order
			var keys = [for (k in com.defines.values.keys()) k];
			keys.sort(core.ds.Key.compareStrings);
			for (k in keys) buffer.add(k + "=" + com.defines.values.get(k) + ",");
			var s = buffer.toString();
			printEndline(s.substr(0, s.length - 1));
		}
	}

	public static function signature(com:CommonContext, tabs:String, sign:String):Void {
		// port: signatures are already hexadecimal (Digest.to_hex).
		if (config.printSignature) printEndline("Using signature " + sign);
	}

	public static function displayPosition(com:CommonContext, tabs:String, p:Pos):Void {
		if (config.printDisplayPosition) printEndline("Display position: " + core.TPrinting.Printer.sPos(p));
	}

	public static function stats(stats:StatsData, time:Float):Void {
		if (config.printStats) {
			printEndline("Stats = " + stats.sFilesParsed + " files, " + stats.sClassesBuilt + " classes, " + stats.sMethodsTyped
				+ " methods, " + stats.sMacrosCalled + " macros");
			printEndline("Time spent : " + formatSeconds(time) + "s");
		}
	}

	// port: Printf "%.3f"
	static function formatSeconds(t:Float):String {
		var ms = Math.round(t * 1000);
		var s = Std.string(Std.int(ms / 1000)), frac = Std.string(ms % 1000);
		return s + "." + StringTools.lpad(frac, "0", 3);
	}

	public static function message(s:String):Void {
		if (config.printMessage) printEndline("> " + s);
	}

	public static function socketMessage(s:String):Void {
		if (config.printSocketMessage) printEndline(s);
	}

	public static function uncaughtError(s:String):Void {
		if (config.printUncaughtError) printEndline("Uncaught Error : " + s);
	}

	public static function enableAll():Void {
		config.printCompilerStage = true;
		config.printAddedDirectory = true;
		config.printFoundDirectories = true;
		config.printChangedDirectories = true;
		config.printModulePathChanged = true;
		config.printNotCached = true;
		config.printParsed = true;
		config.printRemovedDirectory = true;
		config.printReusing = true;
		config.printRetyping = true;
		config.printSkippingDep = true;
		config.printUnchangedContent = true;
		config.printCachedModules = true;
		config.printArguments = true;
		config.printCompletion = true;
		config.printDefines = true;
		config.printSignature = true;
		config.printDisplayPosition = true;
		config.printStats = true;
		config.printMessage = true;
		config.printSocketMessage = true;
		config.printUncaughtError = true;
		config.printNewContext = true;
	}

	public static function setByName(name:String, value:Bool):Void {
		switch name {
			case "compilerStage":
				config.printCompilerStage = value;
			case "addedDirectory":
				config.printAddedDirectory = value;
			case "foundDirectories":
				config.printFoundDirectories = value;
			case "changedDirectories":
				config.printChangedDirectories = value;
			case "modulePathChanged":
				config.printModulePathChanged = value;
			case "notCached":
				config.printNotCached = value;
			case "parsed":
				config.printParsed = value;
			case "removedDirectory":
				config.printRemovedDirectory = value;
			case "reusing":
				config.printReusing = value;
			case "retyping":
				config.printRetyping = value;
			case "skippingDep":
				config.printSkippingDep = value;
			case "unchangedContent":
				config.printUnchangedContent = value;
			case "cachedModules":
				config.printCachedModules = value;
			case "arguments":
				config.printArguments = value;
			case "completion":
				config.printCompletion = value;
			case "defines":
				config.printDefines = value;
			case "signature":
				config.printSignature = value;
			case "displayPosition":
				config.printDisplayPosition = value;
			case "stats":
				config.printStats = value;
			case "message":
				config.printMessage = value;
			case "socketMessage":
				config.printSocketMessage = value;
			case "uncaughtError":
				config.printUncaughtError = value;
			case "newContext":
				config.printNewContext = value;
			case _:
				throw core.ds.NotFound.raise();
		}
	}
}
