package compiler;

import core.Globals;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.TFunctions.*;
import core.Define;
import core.display.DisplayPosition;
import compiler.ParsedArg.ArgContext;
import compiler.CompilationCache;
import compiler.DisplayProcessingGlobals;
import context.Common;
import context.Typecore.Typer;
import context.display.DisplayException;
import context.display.DisplayJson;
import core.DisplayTypes;
import core.TType;

enum DisplayPathKind {
	DPKNormal(path:GlobalTypePath);
	DPKMacro(path:GlobalTypePath);
	DPKDirect(file:String);
	DPKInput(input:String);
	DPKNone;
}

class DisplayProcessing {
	// 1. Argument processing from --display
	public static function processDisplayArg(com:CommonContext, actx:ArgContext):ParseInputResult {
		var resultHandler = com.requestScope.resultHandler;
		return resultHandler.setCom(com);
	}

	// 2. Compilation start, setup display configuration in context

	public static function processDisplayConfiguration(com:CommonContext):Void {
		if (Common.isDiagnostics(com)) {
			com.info = function(s, p, ?depth:Int = 0) {
				Common.addDiagnosticsMessage(com, s, p, core.Message.CompilerMessageKind.MKInfo, depth);
			};
			com.warning = function(w, options, s, p, ?depth:Int = 0) {
				switch core.Warning.getMode(w, options.concat(com.warningOptions)) {
					case WMEnable:
						Common.addDiagnosticsMessage(com, s, p, core.Message.CompilerMessageKind.MKWarning(w, options), depth);
					case WMDisable:
				}
			};
		}
	}

	public static function processDisplayFile(com:CommonContext, actx:ArgContext):DisplayPathKind {
		function getModulePathFromFilePath(com:CommonContext, spath:String):Null<GlobalTypePath> {
			function loop(l:Array<core.ClassPath.IClassPath>, i:Int):Null<GlobalTypePath> {
				if (i >= l.length) return null;
				var cp = l[i].path;
				var cp = cp == "" ? "./" : cp;
				var c = core.Path.addTrailingSlash(core.Path.getRealPath(cp));
				var clen = c.length;
				if (clen < spath.length && spath.substr(0, clen) == c) {
					var path = spath.substr(clen, spath.length - clen);
					try {
						var pp = core.Path.parsePath(path);
						var path:GlobalTypePath = {pack: pp.pack, name: pp.name};
						var r = loop(l, i + 1);
						if (r != null && Globals.sTypePath(r).length < Globals.sTypePath(path).length) return r;
						return path;
					} catch (_:Dynamic) {
						return loop(l, i + 1);
					}
				} else return loop(l, i + 1);
			}
			return loop((com.classPaths : core.ClassPaths).asList(), 0);
		}
		switch com.display.dmsDisplayFilePolicy {
			case DFPNo:
				return DPKNone;
			case DFPOnly if (DisplayPosition.displayPosition.get().pfile == DisplayProcessingGlobals.fileInputMarker):
				actx.classes = [];
				com.main.mainPath = null;
				var fc = com.fileContents;
				if (fc.length == 1 && fc[0].content != null) {
					var input = fc[0].content;
					com.fileContents = [];
					return DPKInput(input);
				}
				return DPKNone;
			case dfp:
				if (dfp == DFPOnly) {
					actx.classes = [];
					com.main.mainPath = null;
				}
				var dpk = DisplayPosition.displayPosition.getFiles().map(function(fileKey) {
					var real = core.Path.getRealPath(core.Path.UniqueKey.toString(fileKey));
					var dpk = {
						var path = getModulePathFromFilePath(com, real);
						if (path != null) {
							if (com.display.dmsKind == DMPackage) DisplayException.sendPackageRaise(com, path.pack);
							switch path.name.split(".") {
								case [name, "macro"]:
									// If we have a .macro.hx path, don't add the file to classes because the compiler won't find it.
									// This can happen if we're completing in such a file.
									DPKMacro({pack: path.pack, name: name});
								case [name]:
									actx.classes.unshift(path);
									DPKNormal(path);
								case [name, target]:
									var path:GlobalTypePath = {pack: path.pack, name: name};
									actx.classes.unshift(path);
									DPKNormal(path);
								case _:
									throw new core.ds.Failure("Invalid display file '" + real + "'");
							}
						} else {
							if (!sys.FileSystem.exists(real)) throw new core.ds.Failure("Display file does not exist");
							var parts = real.split(core.Path.pathSep);
							var file = parts[parts.length - 1];
							if (file != null
								&& file.length > 0
								&& StringTools.fastCodeAt(file, 0) >= "a".code
								&& StringTools.fastCodeAt(file,
									0) <= "z".code) throw new core.ds.Failure("Display file '"
									+ file
									+ "' should not start with a lowercase letter");
							DPKDirect(real);
						}
					};
					Common.log(com, "Display file : " + real);
					return dpk;
				});
				Common.log(com, "Classes found : [" + actx.classes.map(Globals.sTypePath).join(",") + "]");
				return dpk.length == 1 ? dpk[0] : DPKNone;
		}
	}

	// 3. Loaders for display file that might be called

	public static function loadDisplayModuleInMacro(tctx:Typer, displayFileDotPath:Null<GlobalTypePath>, clear:Bool):Null<Typer> {
		if (displayFileDotPath == null) return null;
		var cpath = displayFileDotPath;
		var p = Globals.nullPos;
		try {
			var mctx = typing.MacroContext.getMacroContext(tctx);
			// Tricky stuff: We want to remove the module from our lookups and load it again in
			// display mode. This covers some cases like --macro typing it in non-display mode (issue #7017).
			if (clear) {
				try {
					var m = mctx.com.moduleLut.find(cpath);
					mctx.com.moduleLut.remove(cpath);
					mctx.com.moduleLut.getTypeLut().remove(cpath);
					for (mt in m.mTypes) {
						var ti = tInfos(mt);
						mctx.com.moduleLut.remove(ti.mtPath);
						mctx.com.moduleLut.getTypeLut().remove(ti.mtPath);
					}
				} catch (_:core.ds.NotFound) {}
			}
			typing.MacroContext.loadMacroModule(typing.MacroContext.getMacroContext(tctx), tctx.com, cpath, true, p);
			typing.Finalization.finalize(mctx);
			return mctx;
		} catch (e:DisplayException) {
			throw e;
		} catch (e:syntax.Parser.TypePathCompletion) {
			throw e;
		} catch (e:JsonCompleted) {
			throw e;
		} catch (_:Dynamic) {
			return null;
		}
	}

	public static function loadDisplayFileStandalone(ctx:Typer, file:String):Void {
		var com = ctx.com;
		var parsed = typing.TypeloadParse.parseModuleFile(com, {file: file, classPath: ctx.com.emptyClassPath}, Globals.nullPos);
		var pack = parsed.data.pack, decls = parsed.data.declarations;
		var path = core.Path.FilePath.parse(file);
		var name = path.fileName == null ? "?DISPLAY" : path.fileName;
		if (path.directory != null) {
			var dir = path.directory;
			// Chop off number of package parts from the dir and use that as class path.
			var parts = dir.split(path.backslash ? "\\" : "/");
			var parts = parts.slice(0, parts.length - pack.length < 0 ? 0 : parts.length - pack.length);
			var dir = parts.join(path.backslash ? "\\" : "/");
			(com.classPaths : core.ClassPaths).add(new core.ClassPath.DirectoryClassPath(dir, User));
		}
		typing.TypeloadModule.typeModule(ctx.com, ctx.g, {pack: pack, name: name}, file, decls, Globals.nullPos, true);
	}

	public static function loadDisplayContentStandalone(ctx:Typer, input:String):Void {
		var com = ctx.com;
		var file = DisplayProcessingGlobals.fileInputMarker;
		var p = Globals.filePos(file);
		var parsed = typing.TypeloadParse.parseFileFromString(com, file, p, input);
		var r = typing.TypeloadParse.handleParserResult(com, p, parsed);
		typing.TypeloadModule.typeModule(ctx.com, ctx.g, {pack: r.data.pack, name: "?DISPLAY"}, file, r.data.declarations, p, true);
	}

	// 4. Display processing before typing

	public static function maybeLoadDisplayFileBeforeTyping(tctx:Typer, displayFileDotPath:DisplayPathKind):Null<GlobalTypePath> {
		return switch displayFileDotPath {
			case DPKMacro(path):
				loadDisplayModuleInMacro(tctx, path, true);
				path;
			case DPKNormal(path):
				path;
			case DPKNone:
				null;
			case DPKDirect(file):
				loadDisplayFileStandalone(tctx, file);
				null;
			case DPKInput(input):
				loadDisplayContentStandalone(tctx, input);
				null;
		};
	}

	// 5. Display processing after typing

	public static function handleDisplayAfterTyping(com:CommonContext, tctx:Typer, displayFileDotPath:Null<GlobalTypePath>):Bool {
		if (com.display.dmsKind == DMNone && com.partScope.hasError && Common.isCompilation(com)) return true;
		switch [com.display.dmsKind, com.partScope.parserState.delayedSyntaxCompletion.value] {
			case [DMDefault, sc] if (sc != null):
				var sc:syntax.Parser.SyntaxCompletionOn = sc;
				DisplayOutput.handleSyntaxCompletion(com, sc.kind, sc.subject);
			case _:
		}
		if (com.display.dmsExitDuringTyping) {
			if (com.partScope.hasNext || Common.hasErrorToReport(com)) return true;
			// If we didn't find a completion point, load the display file in macro mode.
			if (com.partScope.parserState.displayModuleHasMacroDefines) loadDisplayModuleInMacro(tctx, displayFileDotPath, true);
			return DisplayException.sendNoResultRaise(com);
		}
		return false;
	}

	// 6. Display processing after finalization

	public static function promoteTypeHints(tctx:Typer):Void {
		function exploreTypeHint(md:ModuleDefDisplay, p:Pos, t:T):Void {
			switch t {
				case TMono(r):
					if (r.tmType != null) exploreTypeHint(md, p, r.tmType);
				case TLazy(f):
					exploreTypeHint(md, p, lazyType(f));
				case TInst({clNamePos: pn}, _) | TEnum({eNamePos: pn}, _) | TType({tNamePos: pn}, _) | TAbstract({aNamePos: pn}, _):
					md.mTypeHints.push({hintPos: p, typePos: pn});
				case TDynamic(_):
				case TFun(_) | TAnon(_):
			}
		}
		// port: typeHints holds the list reversed (see Typecore)
		var i = tctx.g.typeHints.length;
		while (i-- > 0) {
			var th = tctx.g.typeHints[i];
			exploreTypeHint(th.display, th.pos, th.type);
		}
	}

	public static function processGlobalDisplayMode(com:CommonContext, tctx:Typer):Void {
		promoteTypeHints(tctx);
		switch com.display.dmsKind {
			case DMUsage(withDefinition, _, _):
				context.display.FindReferences.findReferences(com, withDefinition);
			case DMImplementation:
				context.display.FindReferences.findImplementations(com);
			case DMModuleSymbols(filter):
				var cs:Cache = com.cs;
				var symbols = {
					var macroCom = com.getMacros();
					var l = cs.getContextFiles([Define.getSignature(com.defines)].concat(macroCom == null ? [] : [Define.getSignature(macroCom.defines)]));
					var acc = [];
					for (e in l) {
						var cfile = e.cfile;
						var file = cfile.cFilePath.file;
						if (filter != null || DisplayPosition.displayPosition.isInFile(com.partScope.fileKeys.get(file))) {
							acc.unshift({
								file: file,
								symbols: context.display.DocumentSymbols.collectModuleSymbols({
									file: file,
									name: CompilationCache.getModuleNameOfCfile(file, cfile)
								}, filter == null, {pack: cfile.cPackage, declarations: cfile.cDecls})
							});
						}
					}
					acc;
				};
				DisplayException.sendModuleSymbolsRaise(com,
					context.display.DocumentSymbols.DocumentSymbolsPrinter.jsonOfModuleSymbols(com, symbols, filter));
			case _:
		}
	}

	public static function handleDisplayAfterFinalization(com:CommonContext, tctx:Typer, displayFileDotPath:Null<GlobalTypePath>):Void {
		// Special case for diagnostics: We don't want to load the display file in macro mode because there's a chance it might not be
		// macro-compatible. This means that we might some macro-specific diagnostics, but I don't see what we could do about that.
		var shouldLoadInMacro = // Special case for the special case: If the display file has a block which becomes active if `macro` is defined, we can safely
			// type the module in macro context. (#8682).
			!Common.isDiagnostics(com) || com.partScope.parserState.displayModuleHasMacroDefines;
		if (com.display.dmsForceMacroTyping && shouldLoadInMacro) {
			var mctx = loadDisplayModuleInMacro(tctx, displayFileDotPath, false);
			if (mctx != null) {
				// We don't need a full macro flush here because we're not going to run any macros.
				var r = typing.Finalization.generate(mctx, typing.Finalization.maybeLoadMain(mctx));
				mctx.com.types = r.types;
				mctx.com.modules = r.modules;
			}
		}
		processGlobalDisplayMode(com, tctx);
		switch com.partScope.reportMode {
			case RMDiagnostics(_):
				DisplayOutput.emitDiagnostics(com);
			case RMStatistics:
				DisplayOutput.emitStatistics(com);
			case RMNone:
		}
	}
}
