package compiler;

import core.Globals;
import core.DisplayTypes;
import core.ClassPath.ClassPathScope;
import core.DefineRegistry;
import core.Message.WarningCode;
import core.ds.ArgumentError;
import core.ds.Failure;
import core.ds.Cancelled;
import core.ds.NotFound;
import core.ds.OcamlInt;
import compiler.ParsedArg.ArgContext;
import context.Typecore.Typer;
import context.TyperPass;
import Std as StdTools;
import core.Globals.*;
import core.TType;
import core.Message;
import core.Message.CompilerMessage as MessageData;
import core.Error;
import core.Define;
import core.Timer;
import core.Path;
import context.Common;
import context.Common.*;
import context.Parallel;
import context.DumpConfig;
import compiler.io.CompilerIo;
import compiler.io.CompilerMessage;
import compiler.io.CompilerOutput;
import typing.Finalization;
import compiler.server.ServerCache;
import compiler.server.ServerMessage;
import compiler.server.ServerCompilationContext;
import context.CommonCache;

class Compiler {
	public static function errorExt(com:CommonContext, err:core.Error.CompilerError):Void com.errorExt(err);

	public static function error(com:CommonContext, msg:String, p:Pos):Void errorExt(com, Error.makeError(Custom(msg), p));

	public static function hasError(com:CommonContext):Bool return com.partScope.hasError;

	public static function handleDiagnostics(com:CommonContext, msg:String, p:Pos, kind:CompilerMessageKind,
			?diagnosticsKind:MessageKind):Void {
		if (diagnosticsKind == null) diagnosticsKind = DKCompilerMessage;
		com.partScope.hasError = true;
		Common.addDiagnosticsMessage(com, msg, p, kind, 0, diagnosticsKind);
		switch com.partScope.reportMode {
			case RMDiagnostics(_):
				DisplayOutput.emitDiagnostics(com);
			case _:
				throw new InternalCompilerError("compiler.ml: handle_diagnostics outside diagnostics", "");
		}
	}

	public static function runOrDiagnose<A>(com:CommonContext, f:Void->A):Null<A> {
		if (Common.isDiagnostics(com)) {
			try return f()
			catch (e:core.Error.TypingError) {
				com.partScope.hasError = true;
				Error.recurseError(function(depth,
						err) Common.addDiagnosticsMessage(com, Error.errorMsg(err.errMessage), err.errPos, MKError, depth),
					e.error);
				switch com.partScope.reportMode {
					case RMDiagnostics(_):
						DisplayOutput.emitDiagnostics(com);
					case _:
						throw new InternalCompilerError("compiler.ml: run_or_diagnose outside diagnostics", "");
				}
			} catch (e:syntax.Parser.ParserError) handleDiagnostics(com, syntax.Parser.errorMsg(e.error), e.pos, MKError, DKParserError)
			catch (e:syntax.Lexer.LexerError) handleDiagnostics(com, syntax.Lexer.errorMsg(e.message), e.pos, MKError, DKParserError);
			return null;
		}
		return f();
	}

	static function runCommandImpl(com:CommonContext, cmd:String):Int {
		var io = com.requestScope.io;
		// TODO: this is a hack
		var cmd = if (com.sctx.isServer) {
			var h = ["__file__" => com.file, "__platform__" => platformName(com.platform)];
			Helper.expandEnv(cmd, h);
		} else cmd;
		var len = cmd.length;
		var result = if (len > 3 && cmd.substr(0, 3) == "cd ") {
			Sys.setCwd(cmd.substr(3));
			0;
		} else if (!com.sctx.isServer)
			// In non-server mode, inherit stdin/stdout/stderr so that interactive commands work
			Sys.command(cmd);
		else
			// In server mode, capture stdout/stderr through the output target and
			// forward the client's stdin from request_scope.
			PipeThings.runCommand(io, cmd);
		return result;
	}

	public static function runCommand(com:CommonContext,
			cmd:String):Int return Timer.time(com.timerCtx, ["command", cmd], function(cmd) return runCommandImpl(com, cmd), cmd);

	public static function checkDefines(com:CommonContext):Void {
		if (Common.defined(com, Define.DisableParallelism)) Parallel.enable = false;
		var keys:Array<String> = [for (k in com.defines.values.keys()) k];
		keys.sort(core.ds.Key.compareStrings);
		for (k in keys) {
			var v = com.defines.values.get(k),
				reason = Define.deprecationLut.get(k);
			if (reason == null) continue;
			var p = Globals.fakePos("-D " + k);
			switch reason {
				case DueTo(reason):
					com.warning(WDeprecatedDefine, [], reason, p);
				case InFavorOf(d):
					Define.rawDefineValue(com.defines, d, v);
					com.warning(WDeprecatedDefine, [], "-D " + k + " has been deprecated in favor of -D " + d, p);
			}
		}
	}

	/** Creates the typer context and types [classes] into it. */
	public static function doType(com:CommonContext, mctx:Null<Typer>, actx:ArgContext,
			displayFileDotPath:DisplayProcessing.DisplayPathKind):{
		typer:Typer,
		displayPath:Null<GlobalTypePath>
	} {
		var cs:CompilationCache.Cache = com.cs;
		CommonCache.maybeAddContextSign(cs, com, "before_init_macros");
		Common.enterStage(com, CInitMacrosStart);
		ServerMessage.compilerStage(com);
		if (beforeTypingHook != null) beforeTypingHook(com, actx);
		Setup.initNativeLibs(com, actx.hxbLibs);
		var configMacros = actx.configMacros.copy();
		configMacros.reverse();
		for (path in configMacros) mctx = typing.MacroContext.callInitMacro(com, mctx, path);
		Common.enterStage(com, CInitMacrosDone);
		checkDefines(com);
		Common.updatePlatformConfig(com); // make sure to adapt all flags changes defined during init macros
		ServerMessage.compilerStage(com);
		var macros = mctx == null ? null : mctx.g.macros;
		Setup.initNativeLibs(com, actx.nativeLibs);
		var tctx = Setup.createTyperContext(com, macros);
		var displayFileDotPath = DisplayProcessing.maybeLoadDisplayFileBeforeTyping(tctx, displayFileDotPath);
		// Make sure display module is being typed
		if (displayFileDotPath != null) actx.classes.unshift(displayFileDotPath);
		DumpConfig.updateFromDefines(com.partScope.dumpConfig, com.defines);
		CommonCache.lockSignature(com, "after_init_macros");
		if (mctx != null) typing.MacroContext.finalizeMacroApi(tctx, mctx);
		try {
			com.callbacks.run(com.errorExt, com.callbacks.getAfterInitMacros());
			runOrDiagnose(com, function() {
				if (com.display.dmsKind != DMNone) context.display.DisplayTexpr.checkDisplayFile(tctx, cs);
				var classes = actx.classes.copy();
				classes.reverse();
				for (path in classes) {
					tctx.g.doLoadModule(tctx, path, nullPos);
					context.Typecore.flushPass(tctx.g, PBuildClass, "actx.classes");
				}
				Finalization.finalize(tctx);
				return null;
			});
		} catch (_:typing.TypeloadParse.DisplayInMacroBlock) {
			DisplayProcessing.loadDisplayModuleInMacro(tctx, displayFileDotPath, true);
		}
		Common.enterStage(com, CTypingDone);
		ServerMessage.compilerStage(com);
		// If we are trying to find references, let's syntax-explore everything we know to check for the
		// identifier we are interested in. We then type only those modules that contain the identifier.
		switch com.display.dmsKind {
			case DMUsage(_) | DMImplementation:
				context.display.FindReferences.findPossibleReferences(tctx, cs);
			case _:
		}
		return {typer: tctx, displayPath: displayFileDotPath};
	}

	static function finalizeTypingImpl(com:CommonContext, tctx:Typer):Void {
		var main = Finalization.maybeLoadMain(tctx);
		Common.enterStage(com, CFilteringStart);
		ServerMessage.compilerStage(com);
		var output = runOrDiagnose(com, function() return Finalization.generate(tctx, main));
		com.main.mainExpr = output.main.expr;
		com.main.mainFile = output.main.path;
		com.types = output.types;
		com.modules = output.modules;
	}

	public static function finalizeTyping(com:CommonContext, tctx:Typer):Void Timer.time(com.timerCtx, ["finalize"], function(tctx) {
		finalizeTypingImpl(com, tctx);
		return null;
	}, tctx);

	public static function filter(com:CommonContext, tctx:Typer, ectx:Null<filters.exception.Exceptions.ExceptionContext>,
			beforeDestruction:Void->Void):Void Timer.time(com.timerCtx, ["filters"],
			function(_:Null<Bool>) return runOrDiagnose(com, function() {
				filters.Filters.run(com, ectx, beforeDestruction);
				return null;
			}), null);

	// port: code generators of other targets (hxmc/) receive the filtered program here; always null in the compiler itself.
	public static var generateHook:Null<CommonContext->Void> = null;

	// port: hxmc puts its persistent module cache in place here (hxmc/src/hxmc/ModuleCache.hx); always null in the compiler itself.
	public static var beforeTypingHook:Null<(CommonContext, ArgContext) -> Void> = null;

	public static function compile(com:CommonContext, actx:ArgContext, sctx:ServerCompilationContext):Void {
		// Set up display configuration
		DisplayProcessing.processDisplayConfiguration(com);
		var restore = Common.disableReportMode(com);
		var displayFileDotPath = DisplayProcessing.processDisplayFile(com, actx);
		restore();
		var mctx:Null<Typer> = switch com.platform {
			case CustomTarget(name):
				try typing.MacroContext.callInitMacro(com, null, name + ".Init.init()") catch (e:core.Error.TypingError) {
					switch e.error.errMessage {
						// ignore if <target_name>.Init doesn't exist
						case ModuleNotFound({pack: [pack], name: "Init"}) if (pack == name): null;
						case _: throw e;
					}
				}
			case _: null;
		};
		// Initialize target: This allows access to the appropriate std packages and sets the -D defines.
		var ext = Setup.initializeTarget(com, actx);
		Common.updatePlatformConfig(com); // make sure to adapt all flags changes defined after platform
		ServerCache.afterTargetInit(sctx, com);
		Timer.time(com.timerCtx, ["init"], function(_:Null<Bool>) {
			var callbacks = actx.preCompilation.copy();
			callbacks.reverse();
			for (f in callbacks) f();
			if (actx.hxbOut != null) com.hxbWriterConfig = compiler.hxb.HxbWriterConfig.processArgument(actx.hxbOut);
			return null;
		}, null);
		Common.enterStage(com, CInitialized);
		ServerMessage.compilerStage(com);
		if (actx.classes.length == 1 && actx.classes[0].pack.length == 0 && actx.classes[0].name == "Std" && !actx.forceTyping) {
			if (actx.cmds.length == 0 && !actx.didSomething) actx.raiseUsage();
		} else {
			// Actual compilation starts here
			var typed = Timer.time(com.timerCtx, ["typing"], function(_:Null<Bool>) return doType(com, mctx, actx, displayFileDotPath),
				null),
				tctx = typed.typer;
			var displayFileDotPath = typed.displayPath;
			if (DisplayProcessing.handleDisplayAfterTyping(com, tctx, displayFileDotPath)) throw new Abort();
			var ectx = filters.exception.ExceptionInit.createExceptionContext(tctx);
			finalizeTyping(com, tctx);
			codegen.Dump.maybeGenerateDump(com, AfterTyping);
			var isCompilation = Common.isCompilation(com);
			com.callbacks.addAfterSave(function() {
				ServerCache.afterSave(sctx, com);
				if (isCompilation && com.hxbWriterConfig != null) Generate.checkHxbOutput(com, com.hxbWriterConfig);
			});
			if (Common.isDiagnostics(com))
				filter(com, tctx, ectx, function() DisplayProcessing.handleDisplayAfterFinalization(com, tctx, displayFileDotPath));
			else {
				DisplayProcessing.handleDisplayAfterFinalization(com, tctx, displayFileDotPath);
				filter(com, tctx, ectx, function() {});
			}
			if (hasError(com) && isCompilation) throw new Abort();
			if (isCompilation) Generate.checkAuxiliaryOutput(com, actx);
			Common.enterStage(com, CGenerationStart);
			ServerMessage.compilerStage(com);
			codegen.Dump.maybeGenerateDump(com, AfterDce);
			Generate.maybeGenerateDumpDependencies(com, tctx);
			if (!actx.noOutput) Generate.generate(com, tctx, ext, actx);
			if (generateHook != null) generateHook(com);
			Common.enterStage(com, CGenerationDone);
			ServerMessage.compilerStage(com);
		}
		// port: the Haxe host owns signal handling; there is no Sys.catch_break.
		com.callbacks.run(com.errorExt, com.callbacks.getAfterGeneration());
		if (!actx.noOutput) {
			var commands = actx.cmds.copy();
			commands.reverse();
			for (cmd in commands) {
				var result = runCommand(com, cmd);
				if (result != 0) throw new Failure("Command failed with error " + result);
			}
		}
	}

	public static function makeIceMessage(com:CommonContext, msg:String,
			backtrace:String):String return msg + "\nHaxe: " + sVersionFull(com.sctx.version) + "; OS type: "
			+ (Sys.systemName() == "Windows" ? "windows" : "unix") + ";\n" + backtrace;

	static function compileSafeImpl(com:CommonContext, f:Void->Void):Void {
		try f()
		catch (e:core.Error.FatalError) errorExt(com, e.error)
		catch (e:syntax.Lexer.LexerError) error(com, syntax.Lexer.errorMsg(e.message), e.pos)
		catch (e:syntax.Parser.ParserError) error(com, syntax.Parser.errorMsg(e.error), e.pos)
		catch (e:context.Typecore.ForbidPackage) {
			if (com.display.dmsKind != DMNone && com.partScope.hasNext) {
				com.partScope.hasError = false;
				com.partScope.messages = [];
			} else {
				var sub = e.positions.map(p -> Error.makeError(Custom(Error.complMsg("referenced here")), p));
				errorExt(com,
					Error.makeError(Custom("You cannot access the "
						+ e.forbidden.name
						+ " package while "
						+ (e.reason == "macro" ? "in a macro" : "targeting " + e.reason)
						+ " (for "
						+ sTypePath(e.forbidden.path)
						+ ")"),
						e.forbidden.pos, sub));
			}
		} catch (e:core.Error.TypingError) errorExt(com, e.error)
		catch (e:ArgumentError) error(com, "Error: " + e.message, nullPos)
		catch (e:Failure) {
			if (Common.isDiagnostics(com)) handleDiagnostics(com, e.message, nullPos, MKError);
			else if (!Helper.isDebugRun) error(com, "Error: " + e.message, nullPos);
			else throw e;
		} catch (e:core.Globals.InternalCompilerError) {
			if (Common.isDiagnostics(com)) handleDiagnostics(com, makeIceMessage(com, e.message, e.stack.toString()), nullPos, MKError);
			else if (!Helper.isDebugRun) error(com, "Error: " + makeIceMessage(com, e.message, e.stack.toString()), nullPos);
			else throw e;
		} catch (e:Helper.HelpMessage) CompilerIo.writeOut(com.requestScope.io, e.message + "\n")
		catch (e:syntax.Parser.TypePathCompletion) DisplayOutput.handleTypePathException(com, e.pack, e.type, e.inImport, e.pos)
		catch (e:syntax.Parser.SyntaxCompletionException) {
			DisplayOutput.handleSyntaxCompletion(com, e.completion.kind, e.completion.subject);
			error(com, "Error: No completion point was found", nullPos);
		} catch (e:context.display.DisplayException) DisplayOutput.handleDisplayException(com, e.kind)
		// We don't want these to be caught by the catchall below
		catch (e:Abort) throw e
		catch (e:macros.eval.EvalTypes.SysExit) throw e
		catch (e:generators.Hlinterp.SysExit) throw e
		catch (e:context.display.DisplayJson.JsonCompleted) throw e
		catch (e:Cancelled) throw e
		catch (e:Dynamic) {
			// port: Printexc.to_string: Invalid_argument's form; another port
			// exception's is its message (its toString, which Std.string does not
			// call on a WasmGC host)
			if (Sys.getEnv("OCAMLRUNPARAM") != "b" && !Helper.isDebugRun) error(com,
				StdTools.isOfType(e, core.ds.InvalidArgument) ? 'Invalid_argument("${(cast e : haxe.Exception).message}")' : StdTools.isOfType(e,
					haxe.Exception) ? (cast e : haxe.Exception).message : StdTools.string(e), nullPos);
			else {
				Sys.stderr().writeString(haxe.CallStack.toString(@:privateAccess haxe.Exception.caught(e).stack) + "\n");
				throw e;
			}
		}
	}

	public static function compileSafe(com:CommonContext, f:Void->Void):Void {
		try compileSafeImpl(com, f)
		catch (_:Abort) {}
	}

	public static function finalize(com:CommonContext):Void {
		CompilerIo.flush(com.requestScope.io);
		for (lib in com.hxbLibs) lib.close();
		// In server mode any open libs are closed by the lib_build_task. In offline mode
		// we should do it here to be safe.
		if (!com.sctx.isServer) {
			for (lib in com.nativeLibs.javaLibs) lib.close();
			for (lib in com.nativeLibs.swfLibs) lib.close();
		}
	}

	public static function catchCompletionAndExit(com:CommonContext, sctx:ServerCompilationContext, run:CommonContext->Void):Int {
		try {
			run(com);
			return hasError(com) ? 1 : 0;
		} catch (e:context.display.DisplayJson.JsonCompleted) {
			finalize(com);
			return 0;
		} catch (e:macros.eval.EvalTypes.SysExit) {
			if (e.code != 0) com.partScope.hasError = true;
			ContextFlush.flushContext(com);
			finalize(com);
			return e.code;
		} catch (e:generators.Hlinterp.SysExit) {
			if (e.code != 0) com.partScope.hasError = true;
			ContextFlush.flushContext(com);
			finalize(com);
			return e.code;
		}
	}

	public static function processActx(com:CommonContext, actx:ArgContext):Void {
		com.doinline = com.display.dmsInline && !Common.defined(com, Define.NoInline);
		com.timerCtx.measureTimes = actx.measureTimes ? Yes : No;
		function checkDeprecationSettings():Void {
			if (Common.defined(com,
				Define.NoDeprecationWarnings)) com.warningOptions.unshift([{woWarning: WDeprecated, woMode: WMDisable}]);
		}
		switch DisplayProcessing.processDisplayArg(com, actx) {
			case Completed:
				throw new context.display.DisplayJson.JsonCompleted();
			case NeedsTyping:
				actx.didSomething = true;
				actx.forceTyping = true;
				checkDeprecationSettings();
			case NoCompletionPointFound:
				checkDeprecationSettings();
		}
	}

	public static function compileCtx(sctx:ServerCompilationContext,
			com:CommonContext):Int return catchCompletionAndExit(com, sctx, function(com) {
			ServerCache.beforeAnything(sctx, com);
			Setup.setupCommonContext(com);
			compileSafe(com, function() {
				var actx = Args.processArgs(com);
				processActx(com, actx);
				compile(com, actx, sctx);
			});
			ContextFlush.flushContext(com);
			finalize(com);
		});

	public static function createContext(sctx:ServerCompilationContext, requestScope:RequestScope, runtimeArgs:Array<String>,
			hasNext:Bool):CommonContext {
		var part:PartScope = {
			runtimeArgs: runtimeArgs,
			warnedPositions: new core.ds.OcamlHashtbl<{file:String, offset:Int},
				{message:String, pos:Pos, options:Array<Array<core.Message.WarningOption>>}>(k ->
					core.ds.OcamlHash.hash(core.ds.OcamlHash.OcamlValue.OBlock(0,
					[
						core.ds.OcamlHash.OcamlValue.OString(k.file),
						core.ds.OcamlHash.OcamlValue.OInt(k.offset)
					])),
					(a, b) -> a.file == b.file && a.offset == b.offset, 0),
			hasNext: hasNext,
			hasError: false,
			messages: [],
			reportMode: RMNone,
			messageCapture: null,
			compilationStep: sctx.compilationStep,
			passDebugMessages: [],
			dumpConfig: DumpConfig.createDefault(),
			parserState: {
				wasAutoTriggered: false,
				hadParserResume: false,
				displayModuleHasMacroDefines: false,
				delayedSyntaxCompletion: {value: null},
				specialIdentifierFiles: new core.ds.ThreadSafeHashtbl<String, String>(0)
			},
			fileKeys: new FileKeys(),
			storedTypedExprs: new context.Lookup.HashtblLookup(),
			cachedMacros: new context.Lookup.HashtblLookup()
		};
		return Common.create(sctx, requestScope, part, core.DisplayTypes.DisplayMode.create(DMNone));
	}
}

class Setup {
	public static function initializeTarget(com:CommonContext, actx:compiler.ParsedArg.ArgContext):String {
		Common.initPlatform(com);
		com.classPaths.lockContext(com.customExt, Globals.platformName(com.platform), false);
		inline function addStd(dir:String):Void
			com.classPaths.modifyInplace(function(cp:core.ClassPath.IClassPath):Array<core.ClassPath.IClassPath> return switch cp.scope {
				case Std: [cp, new core.ClassPath.DirectoryClassPath(cp.path + dir + "/_std/", StdTarget)];
				case _: [cp];
			});
		return switch com.platform {
			case Cross: "?";
			case CustomTarget(name): name;
			case Flash:
				for (v in Common.flashVersions) {
					if (v.version > com.flashVersion) break;
					Common.rawDefine(com, "flash" + v.define);
				}
				com.packageRules.remove("flash");
				addStd("flash");
				"swf";
			case Neko:
				addStd("neko");
				"n";
			case Js:
				var version = try OcamlInt.ofString(Common.definedValue(com, Define.JsEs)) catch (e:Dynamic) {
					if (StdTools.isOfType(e, NotFound)) {
						Common.defineValue(com, Define.JsEs, "5");
						5;
					} else 0;
				};
				if (version < 5) throw new Failure("Invalid -D js-es value, minimal supported version is 5");
				if (version >= 5) Common.rawDefine(com, "js_es5"); // backward-compatibility
				addStd("js");
				"js";
			case Lua:
				addStd("lua");
				"lua";
			case Php:
				addStd("php");
				"php";
			case Cpp:
				Common.defineValue(com, Define.HxcppApiLevel, "500");
				addStd("cpp");
				if (Common.defined(com, Define.Cppia)) actx.classes.unshift(Path.parsePath("cpp.cppia.HostClasses"));
				"cpp";
			case Jvm:
				addStd("jvm");
				com.packageRules.remove("java");
				"java";
			case Python:
				addStd("python");
				if (!Common.defined(com, Define.PythonVersion)) Common.defineValue(com, Define.PythonVersion, "3.3");
				"python";
			case Hl:
				addStd("hl");
				if (!Common.defined(com, Define.HlVer)) {
					var version = try sys.io.File.getContent(Common.findFile(com, "hl/hl_version")) catch (e:Dynamic) {
						if (!StdTools.isOfType(e, NotFound)) throw e;
						throw new Failure("The file hl_version could not be found. Please make sure HAXE_STD_PATH is set to the standard library corresponding to the used compiler version.");
					};
					Define.defineValue(com.defines, Define.HlVer, version);
				}
				"hl";
			case Eval:
				addStd("eval");
				"eval";
		};
	}

	public static function initNativeLibs(com:CommonContext, nativeLibs:Array<compiler.ParsedArg.NativeLibArg>):Void {
		// Native lib pass 1: Register
		var rev = nativeLibs.copy();
		rev.reverse();
		var fl = [for (lib in rev) context.NativeLibraryHandler.addNativeLib(com, lib)];
		// Native lib pass 2: Initialize
		for (f in fl) f();
	}

	public static function createTyperContext(com:CommonContext, macros:Null<{finalize:Void->Void, typer:Typer}>):Typer {
		var buf = new StringBuf();
		buf.add("Defines: ");
		var keys:Array<String> = [for (k in com.defines.values.keys()) k];
		keys.sort(core.ds.Key.compareStrings);
		for (k in keys) {
			var v = com.defines.values.get(k);
			buf.add(v == "1" ? k + ";" : k + "=" + v + ";");
		}
		var text = buf.toString();
		Common.log(com, text.substr(0, text.length - 1));
		com.callbacks.run(com.errorExt, com.callbacks.getBeforeTyperCreate());
		return typing.TyperEntry.create(com, macros);
	}

	public static function executablePath():String return Sys.programPath();

	public static function getStdClassPaths():Array<{path:String, scope:core.ClassPath.ClassPathScope}> {
		var env = Sys.getEnv("HAXE_STD_PATH");
		if (env != null) {
			var p = Path.removeTrailingSlash(env), parts = ~/[;:]/g.split(p), result = [];
			var i = 0;
			while (i < parts.length) {
				var s = parts[i];
				if (i + 1 < parts.length && s.length == 1 && ~/^[a-zA-Z]$/.match(s)) {
					result.push({path: s + ":" + parts[i + 1], scope: Std});
					i += 2;
				} else {
					result.push({path: s, scope: Std});
					i++;
				}
			}
			return result;
		}
		var base = Path.getRealPath(try executablePath() catch (_:Dynamic) "./");
		if (Sys.systemName() != "Windows") {
			var prefix = haxe.io.Path.directory(base);
			return [
				{path: haxe.io.Path.join([prefix, "share", "haxe/std"]), scope: Std},
				{path: haxe.io.Path.join([prefix, "lib", "haxe/std"]), scope: Std},
				{path: haxe.io.Path.join([base, "std"]), scope: Std}
			];
		}
		return [{path: haxe.io.Path.join([base, "std"]), scope: Std}];
	}

	public static function initStdClassPaths(com:CommonContext):Void {
		var paths = getStdClassPaths();
		paths.reverse();
		for (entry in paths) try {
			if (sys.FileSystem.isDirectory(entry.path))
				com.classPaths.add(new core.ClassPath.DirectoryClassPath(Path.addTrailingSlash(entry.path), entry.scope));
		} catch (_:Dynamic) {}
		com.classPaths.add(com.emptyClassPath);
	}

	static function versionDecimal():String {
		var result = StdTools.string(Globals.version / 1000.);
		if (result.indexOf(".") < 0) result += ".";
		while (result.length - result.indexOf(".") < 4) result += "0";
		return result;
	}

	public static function setupCommonContext(com:CommonContext):Void {
		Common.defineValue(com, Define.HaxeVer, versionDecimal());
		Common.defineValue(com, Define.Haxe, Globals.sVersion);
		Common.rawDefine(com, "true");
		for (entry in Define.defaultValues) Define.rawDefineValue(com.defines, entry.key, entry.value);
		com.info = CompilerMessage.defaultInfoHandler(com);
		com.warning = CompilerMessage.defaultWarningHandler(com);
		com.errorExt = CompilerMessage.defaultErrorHandler(com);
		com.error = function(msg, p) com.errorExt(Error.makeError(Custom(msg), p));
		function filterMessages(keepErrors:Bool, predicate:MessageData->Bool):Array<MessageData> {
			var messages = com.partScope.messages.copy();
			messages.reverse();
			return messages.filter(function(cm) return switch Message.severity(cm) {
				case Error: keepErrors;
				case Information | Warning | Hint: predicate(cm);
			});
		}
		com.getMessages = function() return filterMessages(false,
			function(_) return true).map(function(cm) return switch Message.severity(cm) {
			case Error: throw "Unexpected error in get_messages";
			case Information | Warning | Hint: cm;
		});
		com.filterMessages = function(predicate) {
			var messages = filterMessages(true, predicate);
			messages.reverse();
			com.partScope.messages = messages;
		};
		com.runCommand = function(cmd) return Compiler.runCommand(com, cmd);
		initStdClassPaths(com);
	}
}

class ContextFlush {
	public static function flushContext(com:CommonContext):Void switch com.partScope.reportMode {
		case RMDiagnostics(_):
			// In diagnostics mode, messages are already in the unified buffer.
			// Output happens via DisplayOutput.emit_diagnostics, not flush_messages.
		case _:
			CompilerOutput.flushMessages(com.requestScope.resultHandler, Common.hasErrorToReport(com), com);
	};
}
