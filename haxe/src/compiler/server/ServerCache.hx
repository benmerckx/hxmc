package compiler.server;

import core.Ast;
import core.ClassPaths;
import core.ClassPaths.ResolvedFile;
import core.Globals;
import core.Globals.GlobalTypePath;
import core.Globals.Pos;
import core.TType;
import core.TFunctions;
import core.TPrinting;
import core.TPrinting.Printer;
import core.Message.WarningCode;
import core.Define;
import core.Timer;
import core.ds.NotFound;
import core.ds.Failure;
import core.display.DisplayPosition;
import context.Common;
import context.CommonCache;
import context.TyperPass;
import compiler.CompilationCache;
import compiler.hxb.HxbData;
import compiler.hxb.HxbReader;
import compiler.hxb.HxbReaderApi;
import syntax.Parser.ParseResult;
import typing.TypeloadCacheHook;
import typing.TypeloadParse;

class Dirty extends haxe.Exception {
	public final reason:ModuleSkipReason;

	public function new(reason:ModuleSkipReason) {
		super("Dirty");
		this.reason = reason;
	}
}

class ServerError extends haxe.Exception {}

class ServerCache {
	// port: hxmc's persistent module cache (hxmc/src/hxmc/ModuleCache.hx) checks here what a module
	// ... cached by an earlier process needs beyond the checks below (its file's content, the file its
	// ... path resolves to, dependencies it did not keep); always null in the compiler itself.
	public static var checkModuleHook:Null<(com:CommonContext, mPath:GlobalTypePath, mExtra:ModuleDefExtra) -> Null<ModuleSkipReason>> = null;
	// port: and gives back there, once a reader has read them, what HXB does not keep of a module's
	// ... monomorphs (their modifiers); always null in the compiler itself.
	public static var readerCreatedHook:Null<(com:CommonContext, path:GlobalTypePath, reader:HxbReader) -> Void> = null;
	// port: and decides there whether a module stays good although a dependency is dirty (the dependency is
	// ... typed again, its interface unchanged: early cutoff), and types such a dependency from its source where
	// ... the server expects it cached; always null in the compiler itself.
	public static var dependencyDirtyHook:Null<(com:CommonContext, mPath:GlobalTypePath, mExtra:ModuleDefExtra, dep:ModuleDep,
		reason:ModuleSkipReason) -> Bool> = null;
	public static var loadDirtyModuleHook:Null<(com:CommonContext, path:GlobalTypePath, p:Pos) -> Null<ModuleDef>> = null;
	// port: and checks there a module a reader finds in the binary cache as a dependency of the module it reads,
	// ... which the checks of that module do not reach when they leave out the dependencies (partial typing):
	// ... a reason makes it typed from its source (loadDirtyModuleHook); always null in the compiler itself.
	public static var readerFindModuleHook:Null<(com:CommonContext, mPath:GlobalTypePath) -> Null<ModuleSkipReason>> = null;

	public static function parseFile(sctx:ServerCompilationContext, com:CommonContext, rfile:ResolvedFile, p:Pos):ParseResult<Package> {
		var cc = CommonCache.getCache(com);
		var file = rfile.file;
		var ffile = core.Path.getFullPath(rfile.file);
		var fkey:String = com.partScope.fileKeys.get(file);
		var isDisplayFile = DisplayPosition.displayPosition.isInFile(com.partScope.fileKeys.get(ffile));
		switch [isDisplayFile, sctx.currentStdin] {
			case [true, stdin] if (stdin != null && (com.fileContents.length > 0 || Common.defined(com, Define.DisplayStdin))):
				return TypeloadParse.parseFileFromString(com, file, p, stdin);
			case _:
				var ftime = Common.fileTime(ffile);
				var stop = Timer.startTimer(com.timerCtx, ["server", "parser cache"]);
				var data = try {
					try {
						var cfile = cc.findFile(fkey);
						if (cfile.cTime != ftime) throw NotFound.raise();
						ParseSuccess(({pack: cfile.cPackage, declarations: cfile.cDecls} : Package), cfile.cPdi);
					} catch (_:NotFound) {
						var parseResult = TypeloadParse.parseFile(com, rfile, p);
						var info:String, isUnusual:Bool;
						switch parseResult {
							case ParseError(_, _, _):
								info = "not cached, has parse error";
								isUnusual = true;
							case ParseSuccess(data, pdi):
								if (isDisplayFile) {
									if (pdi.pdErrors.length > 0) {
										info = "not cached, is display file with parse errors";
										isUnusual = true;
									} else if (com.display.dmsPerFile) {
										cc.cacheFile(fkey, rfile, ftime, data, pdi);
										info = "cached, is intact display file";
										isUnusual = true;
									} else {
										info = "not cached, is display file";
										isUnusual = true;
									}
								} else {
									try {
										/* We assume that when not in display mode it's okay to cache stuff that has #if display
											checks. The reasoning is that non-display mode has more information than display mode. */
										if (com.display.dmsFullTyping) throw NotFound.raise();
										var ident:String = com.partScope.parserState.specialIdentifierFiles.find(fkey);
										info = "not cached, using \"" + ident + "\" define";
										isUnusual = true;
									} catch (_:NotFound) {
										cc.cacheFile(fkey, ({file: ffile, classPath: rfile.classPath} : ResolvedFile), ftime, data, pdi);
										info = "cached";
										isUnusual = false;
									}
								}
						}
						if (isUnusual) ServerMessage.parsed(com, "", ffile, info);
						parseResult;
					}
				} catch (e:Dynamic) {
					stop();
					throw e;
				}
				stop();
				return data;
		}
	}

	static function stat(dir:String):Float {
		// port: Unix.stat raises Unix_error when the directory is gone.
		return sys.FileSystem.stat(core.Path.removeTrailingSlash(dir)).mtime.getTime() / 1000.0;
	}

	/* Gets a list of changed directories for the current compilation. */
	static function getChangedDirectoriesImpl(sctx:ServerCompilationContext, com:CommonContext):Array<CachedDirectory> {
		var cs = sctx.cs;
		var sign = Define.getSignature(com.defines);
		var dirs = try {
			/* First, check if we already have determined changed directories for current compilation. */
			sctx.changedDirectories.find(sign);
		} catch (_:NotFound) {
			var dirs = try {
				/* Next, get all directories from the cache and filter the ones that haven't changed. */
				var allDirs = cs.findDirectories(sign);
				var dirs:Array<CachedDirectory> = [];
				for (dir in allDirs) {
					try {
						var time2 = stat(dir.cPath);
						if (dir.cMtime < time2) {
							dir.cMtime = time2;
							var subDirs = core.Path.findDirectories(Globals.platformName(com.platform), false, [dir.cPath]);
							for (dir in subDirs) {
								if (!cs.hasDirectory(sign, dir)) {
									var time = stat(dir);
									ServerMessage.addedDirectory(com, "", dir);
									cs.addDirectory(sign, CompilationCache.createDirectory(dir, time));
								}
							}
							dirs.unshift(CompilationCache.createDirectory(dir.cPath, time2));
						}
					} catch (e:Dynamic) {
						if (Std.isOfType(e, NotFound)) throw e;
						cs.removeDirectory(sign, dir.cPath);
						ServerMessage.removedDirectory(com, "", dir.cPath);
					}
				}
				ServerMessage.changedDirectories(com, "", dirs);
				dirs;
			} catch (_:NotFound) {
				/* There were no directories in the cache, so this must be a new context. Let's add
					an empty list to make sure no crazy recursion happens. */
				cs.addDirectories(sign, []);
				/* Register the delay that is going to populate the cache dirs. */
				sctx.delays.unshift(function() {
					var dirs:Array<CachedDirectory> = [];
					function addDir(path:String) {
						try {
							var time = stat(path);
							dirs.unshift(CompilationCache.createDirectory(path, time));
						} catch (_:Dynamic) {}
					}
					var classPathStrings:Array<String> = com.classPaths.asStringList();
					for (path in classPathStrings) addDir(path);
					for (path in core.Path.findDirectories(Globals.platformName(com.platform), true, classPathStrings)) addDir(path);
					ServerMessage.foundDirectories(com, "", dirs);
					cs.addDirectories(sign, dirs);
				});
				/* Returning [] should be fine here because it's a new context, so we won't do any
					shadowing checks anyway. */
				[];
			}
			sctx.changedDirectories.add(sign, dirs);
			dirs;
		}
		return dirs;
	}

	static function getChangedDirectories(sctx:ServerCompilationContext, com:CommonContext):Array<CachedDirectory> {
		return Timer.time(com.timerCtx, ["server", "module cache", "changed dirs"],
			function(com) return getChangedDirectoriesImpl(sctx, com), com);
	}

	public static function getTypingMode(com:CommonContext, mExtra:ModuleDefExtra):TypingMode {
		var fullTyping = com.isMacroContext
			|| com.display.dmsFullTyping
			|| Define.defined(com.defines, Define.DisableHxbCache)
			|| Define.defined(com.defines, Define.DisableHxbOptimizations)
			|| DisplayPosition.displayPosition.isInFile(core.Path.UniqueKey.lazyKey(mExtra.mFile));
		return if (fullTyping) FullTyping else AllowPartialTyping;
	}

	// port: OCaml structural inequality (`<>`) on parsed declarations.
	static function structurallyDifferent(a:Dynamic, b:Dynamic):Bool {
		function eq(a:Dynamic, b:Dynamic):Bool {
			if (a == b) return true;
			if (a == null || b == null) return false;
			if (Std.isOfType(a, std.String) || Std.isOfType(b, std.String)) return a == b;
			if (Std.isOfType(a, Array)) {
				if (!Std.isOfType(b, Array)) return false;
				var aa:Array<Dynamic> = a, bb:Array<Dynamic> = b;
				if (aa.length != bb.length) return false;
				for (i in 0...aa.length) if (!eq(aa[i], bb[i])) return false;
				return true;
			}
			return switch [Type.typeof(a), Type.typeof(b)] {
				case [TEnum(ea), TEnum(eb)]: ea == eb && Type.enumIndex(a) == Type.enumIndex(b) && eq(Type.enumParameters(a),
						Type.enumParameters(b));
				case [TClass(ca), TClass(cb)]:
					if (ca != cb) return false;
					for (f in Type.getInstanceFields(ca)) {
						var va = Reflect.field(a, f);
						if (Reflect.isFunction(va)) continue;
						if (!eq(va, Reflect.field(b, f))) return false;
					}
					true;
				case [TObject, TObject]:
					var fa = Reflect.fields(a), fb = Reflect.fields(b);
					if (fa.length != fb.length) return false;
					for (f in fa) if (!eq(Reflect.field(a, f), Reflect.field(b, f))) return false;
					true;
				case _:
					a == b;
			}
		}
		return !eq(a, b);
	}

	/* Checks if module [m] can be reused from the cache and returns None in that case. Otherwise, returns
		[Some m'] where [m'] is the module responsible for [m] not being reusable. */
	public static function checkModule(sctx:ServerCompilationContext, com:CommonContext, mPath:GlobalTypePath, mExtra:ModuleDefExtra,
			p:Pos):Null<ModuleSkipReason> {
		var cc = CommonCache.getCache(com);
		function contentChanged(mPath:GlobalTypePath, file:String):Bool {
			var fkey:String = com.partScope.fileKeys.get(file);
			try {
				var cfile = cc.findFile(fkey);
				/* We must use the module path here because the file path is absolute and would cause
					positions in the parsed declarations to differ. */
				var decls = TypeloadParse.parseModule(com, mPath, p).declarations;
				return structurallyDifferent(cfile.cDecls, decls);
			} catch (_:NotFound) {
				return true;
			}
		}
		function checkModuleShadowing(paths:Array<CachedDirectory>, mPath:GlobalTypePath, mExtra:ModuleDefExtra) {
			for (dir in paths) {
				var file = (dir.cPath + mPath.name) + ".hx";
				if (sys.FileSystem.exists(file)) {
					var time = Common.fileTime(file);
					if (time > mExtra.mTime) {
						ServerMessage.modulePathChanged(com, "", mPath, mExtra, time, file);
						throw new Dirty(Shadowed(file));
					}
				}
			}
		}
		var startMark = sctx.compilationStep;
		var unknownStateModules:Array<ModuleDefExtra> = [];
		function check(mPath:GlobalTypePath, mExtra:ModuleDefExtra):Null<ModuleSkipReason> {
			function checkModulePath() {
				var directories = getChangedDirectories(sctx, com);
				switch mExtra.mKind {
					case MFake | MImport: /* don't get classpath */
					case MExtern:
						/* if we have a file then this will override our extern type */
						checkModuleShadowing(directories, mPath, mExtra);
						function loop(l:Array<context.Common.ExternTypeLoader>, i:Int) {
							if (i >= l.length) {
								if (sctx.verbose) Sys.println("No library file was found for " + Globals.sTypePath(mPath)); /* TODO */
								throw new Dirty(LibraryChanged);
							}
							var entry = l[i];
							var file = entry.name;
							var load = entry.load;
							switch load(mPath, p) {
								case null:
									loop(l, i + 1);
								case _:
									if (com.partScope.fileKeys.get(file) != core.Path.UniqueKey.lazyKey(mExtra.mFile)) {
										if (sctx.verbose) Sys.println("Library file was changed for "
											+ Globals.sTypePath(mPath)); /* TODO */
										throw new Dirty(LibraryChanged);
									}
							}
						}
						loop(com.loadExternType, 0);
					case MCode:
						checkModuleShadowing(directories, mPath, mExtra);
					case MMacro if (com.isMacroContext):
						checkModuleShadowing(directories, mPath, mExtra);
					case MMacro:
						switch com.getMacros() {
							case null:
							case mcom:
								checkModuleShadowing(getChangedDirectories(sctx, mcom), mPath, mExtra);
						}
				}
			}
			function hasPolicy(policy:ModuleCheckPolicy) {
				return mExtra.mCheckPolicy.indexOf(policy) >= 0 || switch policy {
					case NoFileSystemCheck if (ServerConfig.doNotCheckModules && com.display.dmsKind != DMNone): true;
					case _: false;
				}}
			function checkFile() {
				var file = core.Path.UniqueKey.lazyPath(mExtra.mFile);
				if (Common.fileTime(file) != mExtra.mTime) {
					if (hasPolicy(CheckFileContentModification) && !contentChanged(mPath, file)) {
						ServerMessage.unchangedContent(com, "", file);
					} else {
						ServerMessage.notCached(com, "", mPath);
						if (mExtra.mKind == MFake) com.cs.getContext(mExtra.mSign).removeFakeModule(core.Path.UniqueKey.lazyKey(mExtra.mFile));
						throw new Dirty(FileChanged(file));
					}
				}
			}
			function findModuleExtra(sign:String, mpath:GlobalTypePath):ModuleDefExtra {
				return com.cs.getContext(sign).findModuleExtra(mpath);
			}
			function checkDependencies() {
				// port: PMap.iter: ascending module ids
				var keys = [for (k in mExtra.mDeps.keys()) k];
				keys.sort((a, b) -> a - b);
				for (k in keys) {
					var mdep = mExtra.mDeps.get(k);
					var sign = mdep.mdSign;
					var mpath = mdep.mdPath;
					var m2Extra = try {
						findModuleExtra(sign, mpath);
					} catch (_:NotFound) {
						Globals.die("Could not find dependency "
							+ Globals.sTypePath(mpath)
							+ " of "
							+ Globals.sTypePath(mPath)
							+ " in the cache",
							"serverCache.ml");
					}
					switch check(mpath, m2Extra) {
						case null:
						case reason if (dependencyDirtyHook != null && dependencyDirtyHook(com, mPath, mExtra, mdep, reason)):
						case reason:
							throw new Dirty(DependencyDirty(mpath, reason));
					}
				}
			}
			function check():Null<ModuleSkipReason> {
				try {
					if (checkModuleHook != null) switch checkModuleHook(com, mPath, mExtra) {
						case null:
						case reason: throw new Dirty(reason);
					}
					checkModulePath();
					if (!hasPolicy(NoFileSystemCheck)
						|| core.Path.fileExtension(core.Path.UniqueKey.lazyPath(mExtra.mFile)) != "hx") checkFile();
					if (getTypingMode(com, mExtra) == FullTyping) checkDependencies();
					return null;
				} catch (e:Dirty) {
					return e.reason;
				}
			}
			/* If the module mark matches our compilation mark, we are done */
			if (mExtra.mChecked == startMark) {
				return switch mExtra.mCacheState {
					case MSGood | MSUnknown:
						null;
					case MSBad(reason):
						reason;
				}
			} else {
				/* Otherwise, set to current compilation mark for recursion */
				mExtra.mChecked = startMark;
				var dirty = switch mExtra.mCacheState {
					case MSBad(reason):
						/* If we are already dirty, stick to it. */
						reason;
					case MSUnknown:
						/* This should not happen because any MSUnknown module is supposed to have the current m_checked. */
						Globals.die("", "serverCache.ml");
					case MSGood:
						/* Otherwise, run the checks */
						mExtra.mCacheState = MSUnknown;
						check();
				}
				/* Update the module now. It will use this dirty status for the remainder of this compilation. */
				switch dirty {
					case null:
						/* We cannot update if we're clean because at this point it might just be an assumption.
							Instead We add the module to a list which is updated at the end of handling this subgraph. */
						unknownStateModules.unshift(mExtra);
					case reason:
						/* Update the state if we're dirty. */
						mExtra.mCacheState = MSBad(reason);
				}
				return dirty;
			}
		}
		var state = check(mPath, mExtra);
		switch state {
			case null:
				/* If the entire subgraph is clean, we can set all modules to good state */
				for (mExtra in unknownStateModules) mExtra.mCacheState = MSGood;
			case _:
				/* Otherwise, unknown state module may or may not be dirty. We didn't check everything eagerly, so we have
					to make sure that the module is checked again if it appears in a different check. This is achieved by
					setting m_checked to a lower value and assuming Good state again. */
				for (mExtra in unknownStateModules) switch mExtra.mCacheState {
					case MSUnknown:
						mExtra.mChecked = startMark - 1;
						mExtra.mCacheState = MSGood;
					case MSGood | MSBad(_):
				}
		}
		return state;
	}

	public static function getHxbModule(com:CommonContext, cc:ContextCache, path:GlobalTypePath, typingMode:TypingMode):FindModuleResult {
		try {
			var mc = cc.getHxbModule(path);
			return switch getTypingMode(com, mc.mcExtra) {
				case AllowPartialTyping:
					mc.mcExtra.mCacheState = MSGood;
					BinaryModule(mc);
				case FullTyping:
					switch mc.mcExtra.mCacheState {
						case MSBad(reason) if (typingMode == AllowPartialTyping): BadBinaryModule(mc, reason);
						case MSBad(reason): BadModule(reason);
						case _: BinaryModule(mc);
					}
			}
		} catch (_:NotFound) {
			return NoModule;
		}
	}

	// port: `new HxbReader.hxb_reader path com.hxb_reader_stats (if Common.defined com Define.HxbTimes then Some com.timer_ctx else None)`
	public static function createHxbReader(com:CommonContext, path:GlobalTypePath):HxbReader {
		var reader = new HxbReader(path, com.hxbReaderStats, if (Common.defined(com, Define.HxbTimes)) com.timerCtx else null);
		if (readerCreatedHook != null) readerCreatedHook(com, path, reader);
		return reader;
	}

	public static function handleCacheBoundObjects(com:CommonContext, cbol:Array<CacheBoundObject>):Void {
		for (cbo in cbol) switch cbo {
			case Resource(name, data):
				com.resources.replace(name, data);
			case IncludeFile(file, position):
				com.includeFiles = [({file: file, position: position} : context.Common.IncludeFile)].concat(com.includeFiles);
			case Message(cm):
				compiler.io.CompilerMessage.replayMessage(com, cm);
		}
	}

	/* Adds module [m] and all its dependencies (recursively) from the cache to the current compilation
		context. */
	public static function addModules(sctx:ServerCompilationContext, com:CommonContext, delay:TyperPass->(Void->Void)->Void, m:ModuleDef,
			fromBinary:Bool, p:Pos):Void {
		var ownSign = CommonCache.getCacheSign(com);
		function addModules(tabs:String, m0:ModuleDef, m:ModuleDef) {
			if (m.mExtra.mCacheState != MSGood) {
				switch m.mExtra.mCacheState {
					case MSBad(reason) if (com.display.dmsFullTyping):
						throw new Failure("Unexpected bad module "
							+ Globals.sTypePath(m.mPath)
							+ " ("
							+ Printer.sModuleSkipReason(reason)
							+ ")");
					case MSBad(reason):
						com.warning(WIgnoredBadModule, com.warningOptions,
							"Ignored bad module "
							+ Globals.sTypePath(m.mPath)
							+ " ("
							+ Printer.sModuleSkipReason(reason)
							+ ")", p);
					case _:
				}
				com.moduleLut.remove(m.mPath);
			} else if (m.mExtra.mAdded < com.partScope.compilationStep) {
				m.mExtra.mAdded = com.partScope.compilationStep;
				switch [m0.mExtra.mKind, m.mExtra.mKind] {
					case [MCode, MMacro] | [MMacro, MCode]:
						/* this was just a dependency to check : do not add to the context */
						handleCacheBoundObjects(com, m.mExtra.mCacheBoundObjects);
					case _:
						ServerMessage.reusing(com, tabs, m);
						for (t in m.mTypes) TFunctions.tInfos(t).mtRestore();
						/* The main module gets added when reading hxb already, so let's not add it again. Note that we
							can't set its m_added ahead of time because we want the rest of the logic here to run. */
						if (!fromBinary)
							com.moduleLut.add(m.mPath, m);
						handleCacheBoundObjects(com, m.mExtra.mCacheBoundObjects);
						var typingMode = getTypingMode(com, m.mExtra);
						var deps = if (typingMode == FullTyping) m.mExtra.mDeps else
							(m.mExtra.mDisplayDeps != null ? m.mExtra.mDisplayDeps : m.mExtra.mDeps);
						// port: PMap.iter: ascending module ids
						var keys = [for (k in deps.keys()) k];
						keys.sort((a, b) -> a - b);
						for (k in keys) {
							var mdep = deps.get(k);
							var mpath = mdep.mdPath;
							if (mdep.mdSign == ownSign) {
								var m2 = try {
									com.moduleLut.find(mpath);
								} catch (_:NotFound) {
									switch typeModule(sctx, com, delay, mpath, p) {
										case GoodModule(m):
											m;
										case BinaryModule(mc):
											throw new Failure("Unexpectedly found unresolved binary module " + Globals.sTypePath(mpath)
												+ " as a dependency of " + Globals.sTypePath(m0.mPath));
										case NoModule:
											throw new Failure("Unexpectedly could not find module " + Globals.sTypePath(mpath)
												+ " as a dependency of " + Globals.sTypePath(m0.mPath));
										case BadBinaryModule(_, reason) | BadModule(reason) if (typingMode == AllowPartialTyping):
											com.warning(WIgnoredBadModule, com.warningOptions,
												"Ignored bad dependency "
												+ Globals.sTypePath(m.mPath)
												+ " ("
												+ Printer.sModuleSkipReason(reason)
												+ ") of "
												+ Globals.sTypePath(m0.mPath),
												p);
											null;
										case BadBinaryModule(_, _) | BadModule(_) if (loadDirtyModuleHook != null
											&& loadDirtyModuleHook(com, mpath, p) != null):
											null;
										case BadBinaryModule(_, reason):
											throw new Failure("Unexpected bad hxb module " + Globals.sTypePath(mpath) + " ("
												+ Printer.sModuleSkipReason(reason) + ") as a dependency of " +
												Globals.sTypePath(m0.mPath));
										case BadModule(reason):
											throw new Failure("Unexpected bad module " + Globals.sTypePath(mpath) + " ("
												+ Printer.sModuleSkipReason(reason) + ") as a dependency of " +
												Globals.sTypePath(m0.mPath));
									}
								}
								if (m2 != null) addModules(tabs + "  ", m0, m2);
							}
						}
				}
			}
		}
		addModules("", m, m);
	}

	/* Looks up the module referred to by [mpath] in the cache. If it exists, a check is made to
		determine if it's still valid. If this function returns None, the module is re-typed. */
	public static function typeModule(sctx:ServerCompilationContext, com:CommonContext, delay:TyperPass->(Void->Void)->Void,
			mpath:GlobalTypePath, p:Pos):FindModuleResult {
		var t = Timer.startTimer(com.timerCtx, ["server", "module cache"]);
		var cc = CommonCache.getCache(com);
		function skip(mPath:GlobalTypePath, reason:ModuleSkipReason):FindModuleResult {
			ServerMessage.skippingDep(com, "", mPath, () -> Printer.sModuleSkipReason(reason));
			return BadModule(reason);
		}
		function addModules2(fromBinary:Bool, m:ModuleDef):FindModuleResult {
			Timer.time(com.timerCtx, ["server", "module cache", "add modules"], function(p) {
				addModules(sctx, com, delay, m, fromBinary, p);
				return null;
			}, p);
			return GoodModule(m);
		}
		function checkModule2(sctx:ServerCompilationContext, mPath:GlobalTypePath, mExtra:ModuleDefExtra, p:Pos):Null<ModuleSkipReason> {
			return Timer.time(com.timerCtx, ["server", "module cache", "check"],
				function(p) return checkModule(sctx, com, mpath, mExtra, p), p);
		}
		function findModuleInCache(cc:ContextCache, mPath:GlobalTypePath, p:Pos):FindModuleResult {
			try {
				var m = cc.findModule(mPath);
				return switch m.mExtra.mCacheState {
					case MSBad(reason): BadModule(reason);
					case _: GoodModule(m);
				}
			} catch (_:NotFound) {
				return getHxbModule(com, cc, mPath, FullTyping);
			}
		}
		/* Should not raise anything! */
		var m = switch findModuleInCache(cc, mpath, p) {
			case GoodModule(m):
				/* "Good" here is an assumption, it only means that the module wasn't explicitly invalidated
					in the cache. The true cache state will be known after check_module. */
				switch checkModule2(sctx, mpath, m.mExtra, p) {
					case null:
						addModules2(false, m);
					case reason:
						skip(m.mPath, reason);
				}
			case BinaryModule(mc):
				/* Similarly, we only know that a binary module wasn't explicitly tainted. Decode it only after
					checking dependencies. This means that the actual decoding never has any reason to fail. */
				switch checkModule2(sctx, mpath, mc.mcExtra, p) {
					case null:
						var reader = createHxbReader(com, mpath);
						var typingMode = getTypingMode(com, mc.mcExtra);
						var api:HxbReaderApi = switch com.hxbReaderApi {
							case null:
								var api = new HxbReaderApiServer(com, cc, delay);
								com.hxbReaderApi = api;
								api;
							case api:
								api;
						}
						function fNext(chunks:CachedChunks, until:ChunkKind) {
							var macro_ = if (com.isMacroContext) " (macro)" else "";
							return Timer.time(com.timerCtx, [
								"server",
								"module cache",
								"hxb read" + macro_,
								"until " + HxbData.stringOfChunkKind(until)
							],
								function(typingMode) return reader.readChunksUntil(api, chunks, until, typingMode), typingMode);
						}

						var r = fNext(mc.mcChunks, EOT);
						var m = r.m, chunks = r.remaining;

						/* We try to avoid reading expressions as much as possible, so we only do this for
							our current display file if we're in display mode. */
						switch typingMode {
							case FullTyping: fNext(chunks, EOM);
							case AllowPartialTyping: delay(PConnectField, function() fNext(chunks, EOF));
						}
						com.requestScope.stats.sModulesRestored++;
						addModules2(true, m);
					case reason:
						skip(mpath, reason);
				}
			case BadBinaryModule(_, reason):
				/* A BadModule state here means that the module is already invalidated in the cache, e.g. from server/invalidate. */
				skip(mpath, reason);
			case BadModule(reason):
				/* A BadModule state here means that the module is already invalidated in the cache, e.g. from server/invalidate. */
				skip(mpath, reason);
			case mr = NoModule:
				mr;
		}
		t();
		return m;
	}

	public static function ensureMacroSetup(sctx:ServerCompilationContext):Void {
		if (!sctx.macroContextSetup) {
			sctx.macroContextSetup = true;
			typing.MacroContext.setup();
		}
	}

	public static function cleanup(sctx:ServerCompilationContext):Void {
		switch typing.MacroContext.macroInterpCache {
			case null:
			case interp:
				/* curapi holds a reference to the typing context which we don't want to persist. Replace it with a
					null API so all references to the compilation context are released and it can be garbage collected. */
				macros.MacroEngine.engine.setApi(interp, macros.MacroApi.CompilerApiTools.nullApi());
		}
		sctx.cs.clearTempCache();
		/* Remove context caches that haven't been accessed within the max age window.
			This prevents unbounded accumulation of stale contexts when compilation defines
			change between requests, generating new cache signatures each time. */
		if (ServerConfig.staleContextMaxAgeSeconds > -1) {
			var removed = sctx.cs.removeStaleContexts(ServerConfig.staleContextMaxAgeSeconds);
			if (removed > 0)
				ServerMessage.message("Removed " + removed + " stale context cache(s)");
		}
	}

	public static function beforeAnything(sctx:ServerCompilationContext, ctx:CommonContext):Void {
		ensureMacroSetup(sctx);
	}

	public static function afterTargetInit(sctx:ServerCompilationContext, com:CommonContext):Void {
		var cs = sctx.cs;
		var sign = Define.getSignature(com.defines);
		ServerMessage.defines(com, "");
		ServerMessage.signature(com, "", sign);
		ServerMessage.displayPosition(com, "", DisplayPosition.displayPosition.get());
		var classPathStrings:Array<String> = com.classPaths.asStringList();
		try {
			var previous = sctx.classPaths.find(sign);
			if (core.ds.Key.compare(previous, classPathStrings) != 0) {
				ServerMessage.classPathsChanged(com, "");
				sctx.classPaths.replace(sign, classPathStrings);
				cs.clearDirectories(sign);
				cs.getContext(sign).setInitialized(false);
			}
		} catch (_:NotFound) {
			sctx.classPaths.add(sign, classPathStrings);
		}
	}

	public static function afterSave(sctx:ServerCompilationContext, com:CommonContext):Void {
		if (sctx.isServer && !Common.hasErrorToReport(com))
			CommonCache.maybeCacheContext(com);
	}

	public static function enableCacheMode(sctx:ServerCompilationContext):Void {
		TypeloadCacheHook.typeModuleHook = (com, delay, mpath, p) -> typeModule(sctx, com, delay, mpath, p);
		ensureMacroSetup(sctx);
		TypeloadParse.parseHook = (com, rfile, p) -> parseFile(sctx, com, rfile, p);
	}
}

// port: `hxb_reader_api_server`: the reader callbacks used when restoring modules from the binary cache.
class HxbReaderApiServer implements HxbReaderApi {
	final com:CommonContext;
	final cc:ContextCache;
	final delay:TyperPass->(Void->Void)->Void;

	public function new(com:CommonContext, cc:ContextCache, delay:TyperPass->(Void->Void)->Void) {
		this.com = com;
		this.cc = cc;
		this.delay = delay;
	}

	public function makeModule(path:GlobalTypePath, file:String):ModuleDef {
		var mc = cc.getHxbModule(path);
		/* Creating a new m_extra because if we keep the same reference, display requests */
		/* can alter it with bad data (for example adding dependencies that are not cached) */
		var mExtra = mc.mcExtra.clone();
		mExtra.mDeps = mc.mcExtra.mDeps.copy(); // port: m_deps is a persistent map upstream
		mExtra.mDisplayDeps = null;
		return {
			mId: mc.mcId,
			mPath: path,
			mTypes: [],
			mStatics: null,
			mExtra: mExtra
		};
	}

	public function addModule(m:ModuleDef):Void {
		com.moduleLut.add(m.mPath, m);
	}

	public function resolveType(pack:Array<String>, mname:String, tname:String, fullRestore:TypingMode):ModuleType {
		var path:GlobalTypePath = {pack: pack, name: mname};
		var m = resolveModule(path, fullRestore);
		for (t in m.mTypes) if (TFunctions.tPath(t).name == tname) return t;
		throw NotFound.raise();
	}

	public function resolveModule(path:GlobalTypePath, fullRestore:TypingMode):ModuleDef {
		switch findModule(path, fullRestore) {
			case GoodModule(m):
				return m;
			case BinaryModule(mc):
				var reader = ServerCache.createHxbReader(com, path);
				var typingMode = ServerCache.getTypingMode(com, mc.mcExtra);
				function fNext(chunks:CachedChunks, until:ChunkKind) {
					var macro_ = if (com.isMacroContext) " (macro)" else "";
					return Timer.time(com.timerCtx, [
						"server",
						"module cache",
						"hxb read" + macro_,
						"until " + HxbData.stringOfChunkKind(until)
					],
						function(mode) return reader.readChunksUntil(this, chunks, until, mode), typingMode);
				}

				var r = fNext(mc.mcChunks, EOT);
				var m = r.m, chunks = r.remaining;

				/* We try to avoid reading expressions as much as possible, so we only do this for
					our current display file if we're in display mode. */
				switch typingMode {
					case FullTyping: fNext(chunks, EOM);
					case AllowPartialTyping: delay(PConnectField, function() fNext(chunks, EOF));
				}
				com.requestScope.stats.sModulesRestored++;
				return m;
			case BadBinaryModule(mc, reason):
				var reader = ServerCache.createHxbReader(com, path);
				var typingMode = ServerCache.getTypingMode(com, mc.mcExtra);
				function fNext(chunks:CachedChunks, until:ChunkKind) {
					var macro_ = if (com.isMacroContext) " (macro)" else "";
					return Timer.time(com.timerCtx, [
						"server",
						"module cache",
						"hxb read" + macro_,
						"until " + HxbData.stringOfChunkKind(until)
					],
						function(mode) return reader.readChunksUntil(this, chunks, until, mode), fullRestore);
				}

				var r = fNext(mc.mcChunks, EOT);
				var m = r.m, chunks = r.remaining;
				m.mExtra.mCacheState = MSBad(reason);

				/* We try to avoid reading expressions as much as possible, so we only do this for
					our current display file if we're in display mode. */
				switch typingMode {
					case FullTyping: fNext(chunks, EOM);
					case AllowPartialTyping: delay(PConnectField, function() fNext(chunks, EOF));
				}
				com.requestScope.stats.sModulesRestored++;
				return m;
			case BadModule(_) if (ServerCache.loadDirtyModuleHook != null):
				var m = ServerCache.loadDirtyModuleHook(com, path, core.Globals.nullPos);
				if (m != null) return m;
				return Globals.die("Unexpected BadModule " + Globals.sTypePath(path), "serverCache.ml");
			case BadModule(reason):
				return Globals.die("Unexpected BadModule " + Globals.sTypePath(path) + " (" + Printer.sModuleSkipReason(reason) + ")",
					"serverCache.ml");
			case NoModule:
				return Globals.die("Unexpected NoModule " + Globals.sTypePath(path), "serverCache.ml");
		}
	}

	public function findModule(mPath:GlobalTypePath, typingMode:TypingMode):FindModuleResult {
		try {
			return GoodModule(com.moduleLut.find(mPath));
		} catch (_:NotFound) {
			if (ServerCache.readerFindModuleHook != null) switch ServerCache.readerFindModuleHook(com, mPath) {
				case null:
				case reason: return BadModule(reason);
			}
			return ServerCache.getHxbModule(com, cc, mPath, typingMode);
		}
	}

	public function basicTypes():BasicTypes {
		return com.basic;
	}

	public function getVarId(i:Int):Int {
		return i;
	}

	public function readExpressionEagerly(cf:TClassField):Bool {
		return com.isMacroContext || com.display.dmsFullTyping || Define.defined(com.defines, Define.DisableHxbOptimizations);
	}

	public function makeLazyType(t:T, f:Void->T):T {
		var r = Common.makeUnforcedLazy(t, f, "server-api");
		delay(PForce, function() TFunctions.lazyType(r));
		return TLazy(r);
	}
}
