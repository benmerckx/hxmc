package compiler;

import core.Globals;
import core.Globals.*;
import core.TType;
import core.Ast;
import core.Path;
import core.Timer;
import core.Define;
import core.ds.Failure;
import core.ds.NotFound;
import context.Common;
import context.Parallel;
import compiler.hxb.HxbWriter;
import compiler.hxb.HxbData;
import compiler.hxb.HxbWriterConfig;

class MissingHxbModule extends haxe.Exception {
	public function new() super("Missing_hxb_module");
}

class Generate {
	public static function checkAuxiliaryOutput(com:CommonContext, actx:compiler.ParsedArg.ArgContext):Void {
		switch actx.xmlOut {
			case null:
			case "hx":
				generators.Genhxold.generate(com);
			case file:
				Common.log(com, "Generating xml: " + file);
				Path.mkdirFromPath(file);
				codegen.Genxml.generate(com, file);
		}
		switch actx.jsonOut {
			case null:
			case file:
				Common.log(com, "Generating json : " + file);
				Path.mkdirFromPath(file);
				core.json.Genjson.generate(com.timerCtx, com.types, file);
		}
	}

	public static function createWriter(com:CommonContext, config:WriterTargetConfig):{writer:HxbWriter, close:Void->haxe.io.Bytes} {
		if (config.hxbVersion != HxbData.VERSION) throw new Failure("Unsupported HXB version: " + config.hxbVersion);
		var anonIdentification = new typing.TanonIdentification<Dynamic>();
		function warn(w:core.Message.WarningCode, s:String, p:Pos):Void com.warning(w, com.warningOptions, s, p);
		var writer = new HxbWriter(config, warn, anonIdentification);
		return {writer: writer, close: writer.exportModule};
	}

	public static function exportHxb(fromCache:Bool, com:CommonContext, config:WriterTargetConfig,
			cc:compiler.CompilationCache.ContextCache, platform:String, m:ModuleDef):Null<{
			path:String,
			bytes:haxe.io.Bytes
		}> {
		return switch m.mExtra.mKind {
			case MCode | MMacro | MFake | MExtern:
				// Printf.eprintf "Export module %s\n" (s_type_path m.m_path);
				var path = [platform].concat(m.mPath.pack).concat([m.mPath.name]).join("/") + ".hxb";
				if (fromCache) {
					var cache = try cc.getHxbModule(m.mPath) catch (e:Dynamic) {
						if (!Std.isOfType(e, NotFound)) throw e;
						throw new MissingHxbModule();
					};
					var out = new haxe.io.BytesOutput();
					HxbData.writeHeader(out);
					for (chunk in cache.mcChunks) {
						HxbData.writeChunkPrefix(chunk.kind, chunk.data.length, out);
						out.write(chunk.data);
					}
					{path: path, bytes: out.getBytes()};
				} else {
					var writer = createWriter(com, config);
					writer.writer.writeModule(m);
					{path: path, bytes: writer.close()};
				}
			case _: null;
		};
		}

	public static function checkHxbOutput(com:CommonContext, config:HxbWriterConfig):Void {
		inline function matchPathList(list:Array<Array<String>>,
				path:Array<String>):Bool return core.ds.ArrayTools.exists(list, function(part) return Ast.matchPath(true, path, part));
		function tryWrite(fromCache:Bool):Void {
			var path = StringTools.replace(config.archivePath, "$target", Globals.platformName(com.platform));
			var stop = Timer.startTimer(com.timerCtx, ["generate", "hxb"]);
			Path.mkdirFromPath(path);
			var zip;
			try zip = new core.ZipOutput(path, 0)
			catch (e:Dynamic) {
				throw new HxbOutputError(Std.string(e));
			}
			inline function export(com:CommonContext, config:WriterTargetConfig):Void {
				var cc = context.CommonCache.getCache(com);
				var target = Common.platformNameMacro(com);
				function emit(m:ModuleDef):Null<{path:String, bytes:haxe.io.Bytes}> {
					var path = m.mPath.pack.concat([m.mPath.name]);
					return !matchPathList(config.exclude, path)
						|| matchPathList(config.include,
							path) ? Timer.time(com.timerCtx, ["generate", "hxb", sTypePath(m.mPath)],
							function(_) return exportHxb(fromCache, com, config, cc, target, m), null) : null;
				}
				var input = com.modules.copy();
				var output = Parallel.runWithPool(com.sctx.pool, function(pool) return ParallelArray.map(pool, emit, input, null));
				for (entry in output) if (entry != null) zip.addBytesEntry(entry.bytes, entry.path);
			}
			var failed:Dynamic = null;
			var didFail = false;
			try {
				if (config.targetConfig.generate) export(com, config.targetConfig);
				if (config.macroConfig.generate) {
					var macroCom = com.getMacros();
					if (macroCom != null) export(macroCom, config.macroConfig);
				}
			} catch (e:Dynamic) {
				failed = e;
				didFail = true;
			}
			zip.close();
			stop();
			if (didFail) throw failed;
		}
		try {
			// This case shouldn't happen, unless some modules are not stored in hxb cache (which should not be the case currently)
			if (com.sctx.isServer) try tryWrite(true)
			catch (_:MissingHxbModule) tryWrite(false);
			else tryWrite(false);
		} catch (e:HxbOutputError) com.error("Could not write to " + config.archivePath + ": " + e.message, nullPos);
	}

	public static function parseSwfHeader(com:CommonContext, h:String):Null<{width:Int, height:Int, fps:Float, color:Int}> {
		return switch h.split(":") {
			case [width, height, fps]:
				{width: intOfString(width), height: intOfString(height), fps: floatOfString(fps), color: 0xFFFFFF};
			case [width, height, fps, color]:
				var color = StringTools.startsWith(color, "0x") ? color : "0x" + color;
				{width: intOfString(width), height: intOfString(height), fps: floatOfString(fps), color: intOfString(color)};
			case _:
				com.error("Invalid SWF header format, expected width:height:fps[:color]", nullPos);
				null;
		}
	}

	// port: int_of_string/float_of_string raise Failure on malformed input.
	static function intOfString(s:String):Int {
		var v = Std.parseInt(s);
		if (v == null) throw new Failure("int_of_string");
		return v;
	}

	static function floatOfString(s:String):Float {
		var v = Std.parseFloat(s);
		if (Math.isNaN(v)) throw new Failure("float_of_string");
		return v;
	}

	public static function deleteFile(file:String):Void {
		try sys.FileSystem.deleteFile(file)
		catch (_:Dynamic) {}
	}

	public static function maybeGenerateDumpDependencies(ctx:CommonContext, tctx:context.Typecore.Typer):Void {
		var com:CommonContext = tctx.com;
		if (com.partScope.dumpConfig.dumpDependencies) {
			codegen.Dump.dumpDependencies(com);
			if (!com.isMacroContext && tctx.g.macros != null) codegen.Dump.dumpDependencies(tctx.g.macros.typer.com, "macro");
		}
	}

	// port: HXB output is emitted by the after-save callback before backend destruction.
	public static function generate(com:CommonContext, tctx:context.Typecore.Typer, ext:String, actx:compiler.ParsedArg.ArgContext):Void {
		// check file extension. In case of wrong commandline, we don't want
		// to accidentaly delete a source file. HL leaves its bytecode alone when it
		// has not changed (see Genhl.generate), so it needs the previous file.
		if (Path.fileExtension(com.file) == ext && com.platform != Hl) deleteFile(com.file);
		if (com.platform == Flash || com.platform == Cpp || com.platform == Hl) for (t in com.types) codegen.FixOverrides.fixOverrides(com,
			t);
		switch com.platform {
			case Neko | Hl | Eval if (actx.interp):
			case Cpp if (Common.defined(com, Define.Cppia)):
			case Cpp | Php:
				Path.mkdirFromPath(com.file + "/.");
			case _:
				Path.mkdirFromPath(com.file);
		}
		if (actx.interp) {
			var timer = Timer.startTimer(com.timerCtx, ["interp"]);
			try typing.MacroContext.interpret(tctx, com.partScope.runtimeArgs)
			catch (e:Dynamic) {
				timer();
				throw e;
			}
			timer();
		} else {
			var generate:generators.Gctx->Void, name:String;
			switch com.platform {
				// port: -D hih_no_generators (the playground's WebAssembly build) leaves the target
				// generators out of the binary
				#if hih_no_generators
				case Flash | Neko | Js | Lua | Php | Cpp | Jvm | Python | Hl:
					throw new Failure("haxe-in-haxe: this build has no target generators (-D hih_no_generators)");
				#else
				case Flash:
					var header = try parseSwfHeader(com, Common.definedValue(com, Define.SwfHeader)) catch (_:NotFound) null;
					generate = generators.Genswf.generate.bind(header, cast com.nativeLibs.swfLibs, com.flashVersion);
					name = "swf";
				case Neko:
					generate = generators.Genneko.generate.bind(com.nekoLibPaths);
					name = "neko";
				case Js:
					// port: hxmc ESM (-D esm / esm.hot) is only on the npm compiler (EsmHook).
					if (core.Define.rawDefined(com.defines, "esm") || core.Define.rawDefined(com.defines, "esm.hot")
						|| core.Define.rawDefined(com.defines, "esm.prod")) {
						if (generators.EsmHook.generate == null)
							throw 'The reference compiler does not support -D esm (use the hxmc npm compiler)';
						generate = generators.EsmHook.generate;
					} else
						generate = generators.Genjs.generate.bind(com.jsGen);
					name = "js";
				case Lua:
					generate = generators.Genlua.generate;
					name = "lua";
				case Php:
					generate = generators.Genphp7.generate;
					name = "php";
				case Cpp:
					generate = generators.Gencpp.generate;
					name = "cpp";
				case Jvm:
					generate = generators.Genjvm.generate.bind(actx.jvmFlag);
					name = "jvm";
				case Python:
					generate = generators.Genpy.generate;
					name = "python";
				case Hl:
					generate = generators.Genhl.generate;
					name = "hl";
				#end
				case Eval:
					generate = function(_) typing.MacroContext.interpret(tctx, []); /* TODO: ? */
					name = "eval";
				case Cross | CustomTarget(_):
					generate = function(_) {};
					name = "";
			}
			if (name == "") {} else {
				Common.log(com, "Generating " + name + ": " + com.file);
				Timer.time(com.timerCtx, ["generate", name], function(_:Null<Bool>) {
					generate(Common.toGctx(com));
					return null;
				}, null);
			}
		}
	}
}

private class HxbOutputError extends haxe.Exception {}
