package context.display;

import core.Globals;
import core.Globals.GlobalTypePath;
import core.Json;
import core.Json.JsonValue;
import core.Json.JsonField;
import core.TFunctions.*;
import core.Timer;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import core.json.Genjson;
import core.json.Genjson.*;
import core.json.JsonRpc;
import core.json.JsonrpcHandler;
import compiler.CompilationCache;
import compiler.DisplayProcessingGlobals;
import compiler.io.CompilerIo;
import compiler.io.CompilerIo.CompilerIoData;
import compiler.server.ServerConfig;
import context.Common;
import core.DisplayTypes;
import core.TType;

// port: exception JsonCompleted
class JsonCompleted extends haxe.Exception {
	public function new() super("JsonCompleted");
}

class DisplayHandler {
	final jsonrpc:JsonrpcHandler;
	final com:CommonContext;
	final cs:Cache;

	public function new(jsonrpc:JsonrpcHandler, com:CommonContext, cs:Cache) {
		this.jsonrpc = jsonrpc;
		this.com = com;
		this.cs = cs;
	}

	public function getCs():Cache return cs;

	public function enableDisplay(?skipDefine:Bool = false, mode:DisplayModeValue):Void
		DisplayRequests.enableDisplay(com, skipDefine, mode);

	// port: set_display_file's reading of the request's file, contents, offset and file
	// ... contents, in its order (so a bad request fails as upstream's does), as the
	// ... parameters of DisplayRequests (which sets them as set_display_file does)
	public function fileParams(requiresOffset:Bool):{
		file:Null<haxe.display.FsPath>,
		?contents:String,
		offset:Int,
		?fileContents:Array<{file:haxe.display.FsPath, ?contents:String}>
	} {
		var file:Null<String> = jsonrpc.getOptParam(() -> jsonrpc.getStringParam("file"), null);
		var contents:Null<String> = jsonrpc.getOptParam(function():Null<String> {
			var s = jsonrpc.getStringParam("contents");
			return s;
		}, null);
		var pos = requiresOffset ? jsonrpc.getIntParam("offset") : -1;
		var fileContents = if (file != null) null else {
			var fileContents:Array<JsonValue> = jsonrpc.getOptParam(function() return jsonrpc.getOptParam(function() return
				jsonrpc.getArrayParam("fileContents"), []), []);
			fileContents.map(function(fc):{file:haxe.display.FsPath, ?contents:String} return switch fc {
				case JObject(fl):
					var file = jsonrpc.getStringField("fileContents", "file", fl);
					var contents:Null<String> = jsonrpc.getOptParam(function():Null<String> {
						var s = jsonrpc.getStringField("fileContents", "contents", fl);
						return s;
					}, null);
					{file: new haxe.display.FsPath(file), contents: contents};
				case _: throw new core.ds.InvalidArgument("fileContents");
			});
		}
		return {
			file: file == null ? null : new haxe.display.FsPath(file),
			contents: contents,
			offset: pos,
			fileContents: fileContents
		};
	}
}

class HxbReaderApiCom implements compiler.hxb.HxbReaderApi {
	final typingMode:compiler.hxb.HxbData.TypingMode;
	final com:CommonContext;
	final cc:ContextCache;

	public function new(typingMode:compiler.hxb.HxbData.TypingMode, com:CommonContext, cc:ContextCache) {
		this.typingMode = typingMode;
		this.com = com;
		this.cc = cc;
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

	public function resolveType(pack:Array<String>, mname:String, tname:String, _:compiler.hxb.HxbData.TypingMode):ModuleType {
		var path:GlobalTypePath = {pack: pack, name: mname};
		var m = findModule(path);
		for (t in m.mTypes) if (tPath(t).name == tname) return t;
		throw core.ds.NotFound.raise();
	}

	public function resolveModule(path:GlobalTypePath, _:compiler.hxb.HxbData.TypingMode):ModuleDef {
		return findModule(path);
	}

	public function findModule(mPath:GlobalTypePath):ModuleDef {
		try {
			return com.moduleLut.find(mPath);
		} catch (_:core.ds.NotFound) {
			var m = cc.findModuleOpt(mPath);
			if (m != null) return m;
			var mc = cc.getHxbModule(mPath);
			var reader = new compiler.hxb.HxbReader(mc.mcPath, com.hxbReaderStats,
				if (Common.defined(com, core.Define.HxbTimes)) com.timerCtx else null);
			return reader.readChunksUntil(this, mc.mcChunks, if (typingMode == FullTyping) EOM else MTF, typingMode).m;
		}
	}

	public function basicTypes():BasicTypes {
		return com.basic;
	}

	public function getVarId(i:Int):Int {
		return i;
	}

	public function readExpressionEagerly(cf:TClassField):Bool {
		return false;
	}

	public function makeLazyType(t:T, f:Void->T):T {
		return TLazy(Common.makeUnforcedLazy(t, f, "com-api"));
	}
}

@:structInit class HandlerContext {
	public var com:CommonContext;
	public var jsonrpc:JsonrpcHandler;
	public var display:DisplayHandler;

	public inline function new(com:CommonContext, jsonrpc:JsonrpcHandler, display:DisplayHandler) {
		this.com = com;
		this.jsonrpc = jsonrpc;
		this.display = display;
	}
}

enum ApiDeferrence {
	AfterInitMacros;
	AfterFilters;
}

enum ApiResponse {
	NoResponse;
	Result(json:JsonValue);
	Error(json:JsonValue);
	Deferred(deferrence:ApiDeferrence, f:Void->ApiResponse);
}

class ApiError extends haxe.Exception {
	public final json:JsonValue;

	public function new(json:JsonValue) {
		super("Api_error");
		this.json = json;
	}
}

class DisplayJson {
	// Generate the JSON of our times.
	public static function jsonOfTimes(root:core.Timer.TimerNode):Null<JsonValue> {
		function loop(node:core.Timer.TimerNode):Null<JsonValue> {
			if (node == root || node.time > 0.0009) {
				var children = [];
				for (c in node.children) {
					var j = loop(c);
					if (j != null) children.push(j);
				}
				var fl = [
					kv("name", jstring(node.name)),
					kv("path", jstring(node.path)),
					kv("info", jstring(node.info)),
					kv("time", jfloat(node.time)),
					kv("calls", jint(node.numCalls)),
					kv("percentTotal", jfloat(root.time == 0.?0.:(node.time * 100. / root.time))),
					kv("percentParent", jfloat(if (node == root || node.parent.time == 0.) 0.else node.time * 100. / node.parent.time))
				];
				if (children.length > 0) fl.unshift(kv("children", jarray(children)));
				return jobject(fl);
			}
			return null;
		}
		return loop(root);
	}

	public static var supportsResolve = false;

	public static function sendString(io:CompilerIoData, j:String):Void CompilerIo.writeResult(io, j);

	public static function sendJson(io:CompilerIoData, json:JsonValue):Void sendString(io, Json.stringOfJson(json));

	/*
		send_string_raise writes the string to io and then raises JsonCompleted.
		JsonCompleted is a control-flow exception signaling that a JSON-RPC response has been
		sent and no further output should be produced. It is caught by catch_completion_and_exit
		which calls finalize and exits cleanly.
		Raising is necessary for call-sites that send their response from within compilation
		(display output handlers, deferred callbacks, flush_context), where we need to abort
		further processing once the response is sent.
	*/
	public static function sendStringRaise<R>(io:CompilerIoData, j:String):R {
		sendString(io, j);
		throw new JsonCompleted();
	}

	public static function sendJsonRaise<R>(io:CompilerIoData, json:JsonValue):R return sendStringRaise(io, Json.stringOfJson(json));

	public static function findModule(typingMode:compiler.hxb.HxbData.TypingMode, com:CommonContext, cc:ContextCache,
			path:GlobalTypePath):ModuleDef {
		return new HxbReaderApiCom(typingMode, com, cc).findModule(path);
	}

	public static function apiError<R>(j:JsonValue):R throw new ApiError(j);

	public static final handler:OcamlHashtbl<String, HandlerContext->ApiResponse> = makeHandler();

	static function makeHandler():OcamlHashtbl<String, HandlerContext->ApiResponse> {
		var h = new OcamlHashtbl<String, HandlerContext->ApiResponse>(OcamlHash.hashString, (a, b) -> a == b, 0);
		function defer(deferrence:ApiDeferrence, f:Void->ApiResponse):ApiResponse return Deferred(deferrence, function() return f());
		var l:Array<{name:String, f:HandlerContext->ApiResponse}> = [
			{
				name: "initialize",
				f: function(hctx) {
					supportsResolve = hctx.jsonrpc.getOptParam(() -> hctx.jsonrpc.getBoolParam("supportsResolve"), false);
					hctx.jsonrpc.getOptParam(function() {
						ServerConfig.maxCompletionItems = hctx.jsonrpc.getIntParam("maxCompletionItems");
						return null;
					}, null);
					hctx.jsonrpc.getOptParam(function() {
						ServerConfig.staleContextMaxAgeSeconds = hctx.jsonrpc.getIntParam("staleContextMaxAge");
						return null;
					}, null);
					var exclude = hctx.jsonrpc.getOptParam(() -> hctx.jsonrpc.getArrayParam("exclude"), []);
					DisplayToplevel.exclude = exclude.map(e -> switch e {
						case JString(s): s;
						case _: throw new core.Globals.InternalCompilerError("displayJson.ml: exclude entry is not a string", "");
					});
					var methods = handler.fold(function(k, _, acc:Array<JsonValue>) {
						acc.unshift(jstring(k));
						return acc;
					}, []);
					var version:core.Globals.CompilerVersion = hctx.com.sctx.version;
					return Result(JObject([
						kv("methods", jarray(methods)),
						kv("haxeVersion", jobject([
							kv("major", jint(version.major)),
							kv("minor", jint(version.minor)),
							kv("patch", jint(version.revision)),
							kv("pre", version.pre == null ? jnull : jstring(version.pre)),
							kv("build", version.extra == null ? jnull : jstring(version.extra.build))
						])),
						kv("protocolVersion", jobject([kv("major", jint(0)), kv("minor", jint(5)), kv("patch", jint(0))]))
					]));
				}
			},
			{
				name: "display/completionItem/resolve",
				f: function(hctx) {
					var i = hctx.jsonrpc.getIntParam("index");
					if (i < 0 || i >= DisplayException.lastCompletionResult.length) return Error(jstring('Invalid index: $i'));
					var item = DisplayException.lastCompletionResult[i];
					var ctx = Genjson.createFullConfig();
					return Result(jobject([kv("item", core.display.CompletionItem.toJson(ctx, null, item))]));
				}
			},
			{
				name: "display/completion",
				f: function(hctx) {
					var wasAutoTriggered = hctx.jsonrpc.getBoolParam("wasAutoTriggered");
					var p = hctx.display.fileParams(true);
					DisplayRequests.completion(hctx.com, {
						file: p.file,
						contents: p.contents,
						offset: p.offset,
						fileContents: p.fileContents,
						wasAutoTriggered: wasAutoTriggered
					});
					return NoResponse;
				}
			},
			{
				name: "display/definition",
				f: function(hctx) {
					var p = hctx.display.fileParams(true);
					DisplayRequests.definition(hctx.com, {
						file: p.file,
						contents: p.contents,
						offset: p.offset,
						fileContents: p.fileContents
					});
					return NoResponse;
				}
			},
			{
				name: "display/diagnostics",
				f: function(hctx) {
					var p = hctx.display.fileParams(false);
					DisplayRequests.diagnostics(hctx.com, {file: p.file, contents: p.contents, fileContents: p.fileContents});
					return NoResponse;
				}
			},
			{
				name: "display/statistics",
				f: function(hctx) {
					var p = hctx.display.fileParams(false);
					DisplayRequests.statistics(hctx.com, {file: p.file, contents: p.contents, fileContents: p.fileContents});
					return NoResponse;
				}
			},
			{
				name: "display/implementation",
				f: function(hctx) {
					var p = hctx.display.fileParams(true);
					DisplayRequests.implementation(hctx.com, {
						file: p.file,
						contents: p.contents,
						offset: p.offset,
						fileContents: p.fileContents
					});
					return NoResponse;
				}
			},
			{
				name: "display/typeDefinition",
				f: function(hctx) {
					var p = hctx.display.fileParams(true);
					DisplayRequests.typeDefinition(hctx.com, {
						file: p.file,
						contents: p.contents,
						offset: p.offset,
						fileContents: p.fileContents
					});
					return NoResponse;
				}
			},
			{
				name: "display/references",
				f: function(hctx) {
					var p = hctx.display.fileParams(true);
					var kind = hctx.jsonrpc.getOptParam(() -> hctx.jsonrpc.getStringParam("kind"), "normal");
					DisplayRequests.references(hctx.com, {
						file: p.file,
						contents: p.contents,
						offset: p.offset,
						fileContents: p.fileContents,
						kind: cast kind
					});
					return NoResponse;
				}
			},
			{
				name: "display/hover",
				f: function(hctx) {
					var p = hctx.display.fileParams(true);
					DisplayRequests.hover(hctx.com, {
						file: p.file,
						contents: p.contents,
						offset: p.offset,
						fileContents: p.fileContents
					});
					return NoResponse;
				}
			},
			{
				name: "display/package",
				f: function(hctx) {
					var p = hctx.display.fileParams(false);
					DisplayRequests.determinePackage(hctx.com, {file: p.file, contents: p.contents, fileContents: p.fileContents});
					return NoResponse;
				}
			},
			{
				name: "display/documentSymbols",
				f: function(hctx) {
					var p = hctx.display.fileParams(false);
					DisplayRequests.documentSymbols(hctx.com, {file: p.file, contents: p.contents, fileContents: p.fileContents});
					return NoResponse;
				}
			},
			{
				name: "display/workspaceSymbols",
				f: function(hctx) {
					DisplayRequests.workspaceSymbols(hctx.com, {filter: hctx.jsonrpc.getStringParam("filter")});
					return NoResponse;
				}
			},
			{
				name: "display/signatureHelp",
				f: function(hctx) {
					var wasAutoTriggered = hctx.jsonrpc.getBoolParam("wasAutoTriggered");
					var p = hctx.display.fileParams(true);
					DisplayRequests.signatureHelp(hctx.com, {
						file: p.file,
						contents: p.contents,
						offset: p.offset,
						fileContents: p.fileContents,
						wasAutoTriggered: wasAutoTriggered
					});
					return NoResponse;
				}
			},
			{
				name: "display/metadata",
				f: function(hctx) {
					var includeCompilerMeta = hctx.jsonrpc.getBoolParam("compiler");
					var includeUserMeta = hctx.jsonrpc.getBoolParam("user");
					return defer(AfterInitMacros, function() {
						var all = core.Meta.getMetaList(hctx.com.userMetas);
						var all = all.filter(m -> switch m.info.mOrigin {
							case Compiler if (includeCompilerMeta): true;
							case UserDefined(_) if (includeUserMeta): true;
							case _: false;
						});
						return Result(jarray(all.map(function(m) {
							var data = m.info;
							var fields = [
								kv("name", jstring(m.name)),
								kv("doc", jstring(data.mDoc)),
								kv("parameters", jarray(data.mParams.map(jstring))),
								kv("platforms", jarray(data.mPlatforms.map(p -> jstring(Globals.platformName(p))))),
								kv("targets", jarray(data.mUsedOn.map(u -> jstring(core.MetaList.printMetaUsage(u))))),
								kv("internal", jbool(data.mInternal)),
								kv("origin", jstring(switch data.mOrigin {
									case Compiler: "haxe compiler";
									case UserDefined(null): "user-defined";
									case UserDefined(o): o;
								})),
								kv("links", jarray(data.mLinks.map(jstring)))
							];
							return jobject(fields);
						})));
					});
				}
			},
			{
				name: "display/defines",
				f: function(hctx) {
					var includeCompilerDefines = hctx.jsonrpc.getBoolParam("compiler");
					var includeUserDefines = hctx.jsonrpc.getBoolParam("user");
					return defer(AfterInitMacros, function() {
						var all = core.Define.getDefineList(hctx.com.userDefines);
						var all = all.filter(d -> switch d.info.dOrigin {
							case Compiler if (includeCompilerDefines): true;
							case UserDefined(_) if (includeUserDefines): true;
							case _: false;
						});
						return Result(jarray(all.map(function(d) {
							var data = d.info;
							var fields = [
								kv("name", jstring(d.name)),
								kv("doc", jstring(data.dDoc)),
								kv("parameters", jarray(data.dParams.map(jstring))),
								kv("platforms", jarray(data.dPlatforms.map(p -> jstring(Globals.platformName(p))))),
								kv("origin",
									jstring(switch data.dOrigin {
										case Compiler: "haxe compiler";
										case UserDefined(null): "user-defined";
										case UserDefined(o): o;
									})),
								kv("deprecated", jopt(jstring, data.dDeprecated)),
								kv("links", jarray(data.dLinks.map(jstring))),
								kv("reserved", jopt(jbool, data.dReserved))
							];
							return jobject(fields);
						})));
					});
				}
			},
			{
				name: "server/resetCache",
				f: function(hctx) {
					(hctx.com.cs : Cache).clear();
					supportsResolve = false;
					DisplayException.reset();
					ServerConfig.reset();
					return Result(jobject([kv("success", jbool(true))]));
				}
			},
			{
				name: "server/resetState",
				f: function(hctx) {
					hctx.com.sctx.persistentCwd = null;
					(hctx.com.cs : Cache).softClear();
					supportsResolve = false;
					DisplayException.reset();
					ServerConfig.reset();
					return Result(jobject([kv("success", jbool(true))]));
				}
			},
			{
				name: "server/setCwd",
				f: function(hctx) {
					var dir = hctx.jsonrpc.getStringParam("dir");
					var dir = core.Path.getFullPath(dir);
					if (!(sys.FileSystem.exists(dir) && sys.FileSystem.isDirectory(dir))) throw new ApiError(jstring("Invalid directory: "
						+ dir));
					hctx.com.sctx.persistentCwd = dir;
					return Result(jnull);
				}
			},
			{
				name: "server/gcCompact",
				f: function(hctx) {
					var t0 = Sys.time();
					#if hl
					var before = hl.Gc.stats().currentMemory;
					hl.Gc.major();
					var after = hl.Gc.stats().currentMemory;
					#else
					var before = 0., after = 0.;
					#end
					return Result(jobject([
						kv("time", jfloat(Sys.time() - t0)),
						kv("before", jint(Std.int(before))),
						kv("after", jint(Std.int(after)))
					]));
				}
			},
			{
				name: "server/readClassPaths",
				f: function(hctx) {
					var wait = hctx.jsonrpc.hasParams() && hctx.jsonrpc.getOptParam(() -> hctx.jsonrpc.getBoolParam("wait"), false);
					return defer(AfterInitMacros, function() {
						var cc = hctx.display.getCs().getContext(core.Define.getSignature(hctx.com.defines));
						cc.setInitialized(true);
						DisplayToplevel.readClassPaths(hctx.com, ["init"]);
						if (wait) hctx.display.getCs().runTasks(true, task -> task.getId()[0] == "explore");
						var files = hctx.display.getCs().getFiles();
						return Result(jobject([kv("files", jint(files.length))]));
					});
				}
			},
			{
				name: "server/contexts",
				f: function(hctx) {
					var l = hctx.display.getCs().getContexts().map(cc -> cc.getJson());
					var l = l.filter(json -> json != JNull);
					return Result(jarray(l));
				}
			},
			{
				name: "server/modules",
				f: function(hctx) {
					var sign = hctx.jsonrpc.getStringParam("signature");
					var cc = hctx.display.getCs().getContext(sign);
					var l = cc.getHxb().fold(function(_, m:compiler.hxb.HxbData.ModuleCache, acc:Array<JsonValue>) {
						if (m.mcExtra.mKind != MFake) acc.unshift(jstring(Globals.sTypePath(m.mcPath)));
						return acc;
					}, []);
					return Result(jarray(l));
				}
			},
			{
				name: "server/module",
				f: function(hctx) {
					var sign = hctx.jsonrpc.getStringParam("signature");
					var path = core.Ast.Ast.parsePath(hctx.jsonrpc.getStringParam("path"));
					var cs = hctx.display.getCs();
					var cc = cs.getContext(sign);
					var typingMode:compiler.hxb.HxbData.TypingMode = if (core.Define.defined(hctx.com.defines, core.Define.DisableHxbOptimizations)) FullTyping else AllowPartialTyping;
					try {
						var m = findModule(typingMode, hctx.com, cc, path);
						return Result(Genjson.generateModule(cc.getHxb(), findModule.bind(typingMode, hctx.com, cc), m));
					} catch (_:core.ds.NotFound) {
						return Error(jstring("No such module"));
					}
				}
			},
			{
				name: "server/type",
				f: function(hctx) {
					var sign = hctx.jsonrpc.getStringParam("signature");
					var path = core.Ast.Ast.parsePath(hctx.jsonrpc.getStringParam("modulePath"));
					var typeName = hctx.jsonrpc.getStringParam("typeName");
					var cc = hctx.display.getCs().getContext(sign);
					try {
						var m = findModule(FullTyping, hctx.com, cc, path);
						for (mt in m.mTypes) {
							switch mt {
								case TClassDecl(c):
									c.clRestore();
								case _:
							}
							var infos = tInfos(mt);
							if (infos.mtPath.name == typeName) {
								var ctx = Genjson.createFullConfig();
								return Result(Genjson.generateModuleType(ctx, mt));
							}
						}
						return Error(jstring("No such type"));
					} catch (_:core.ds.NotFound) {
						return Error(jstring("No such module"));
					}
				}
			},
			{
				name: "server/typeContexts",
				f: function(hctx) {
					var path = core.Ast.Ast.parsePath(hctx.jsonrpc.getStringParam("modulePath"));
					var typeName = hctx.jsonrpc.getStringParam("typeName");
					var contexts = hctx.display.getCs().getContexts();
					var acc:Array<JsonValue> = [];
					for (cc in contexts) {
						var m = cc.findModuleOpt(path);
						if (m == null) continue;
						for (mt in m.mTypes) {
							switch mt {
								case TClassDecl(c):
									c.clRestore();
								case _:
							}
							if (tInfos(mt).mtPath.name == typeName) {
								acc.unshift(cc.getJson());
								break;
							}
						}
					}
					return Result(jarray(acc));
				}
			},
			{
				name: "server/moduleCreated",
				f: function(hctx) {
					var file = hctx.jsonrpc.getStringParam("file");
					var file = core.Path.getFullPath(file);
					var key = hctx.com.partScope.fileKeys.get(file);
					var cs = hctx.display.getCs();
					for (cc in cs.getContexts()) cc.getRemovedFiles().replace(key, {file: file, classPath: hctx.com.emptyClassPath});
					return Result(jstring(file));
				}
			},
			{
				name: "server/files",
				f: function(hctx) {
					var sign = hctx.jsonrpc.getStringParam("signature");
					var cc = hctx.display.getCs().getContext(sign);
					var files = cc.getFiles().fold(function(file, cfile, acc:Array<{key:String, cfile:CachedFile}>) {
						acc.unshift({key: file, cfile: cfile});
						return acc;
					}, []);
					haxe.ds.ArraySort.sort(files, (a, b) -> Display.compareStrings(a.key, b.key));
					var files = files.map(f -> jobject([
						kv("file", jstring(f.cfile.cFilePath.file)),
						kv("time", jfloat(f.cfile.cTime)),
						kv("pack", jstring(f.cfile.cPackage.join("."))),
						kv("moduleName", jopt(jstring, f.cfile.cModuleName))
					]));
					return Result(jarray(files));
				}
			},
			{
				name: "server/invalidate",
				f: function(hctx) {
					var file = hctx.jsonrpc.getStringParam("file");
					var fkey = hctx.com.partScope.fileKeys.get(file);
					var cs = hctx.display.getCs();
					cs.taintModules(fkey, ServerInvalidate);
					cs.removeFiles(fkey);
					return Result(jnull);
				}
			},
			{
				name: "server/configure",
				f: function(hctx) {
					var print = hctx.jsonrpc.getOptParam(() -> hctx.jsonrpc.getObjectParam("print"), []);
					var l = print.map(function(f) {
						var name = f.name;
						var value = hctx.jsonrpc.getBool("value", f.value);
						try {
							compiler.server.ServerMessage.setByName(name, value);
							return jstring('Printing $name ' + (value ? "enabled" : "disabled"));
						} catch (_:core.ds.NotFound) {
							return apiError(jstring("Invalid print parame name: " + name));
						}
					});
					hctx.jsonrpc.getOptParam(function() {
						var b = hctx.jsonrpc.getBoolParam("noModuleChecks");
						ServerConfig.doNotCheckModules = b;
						l.unshift(jstring("Module checks " + (b ? "disabled" : "enabled")));
						return null;
					}, null);
					return Result(jarray(l));
				}
			},
			{
				name: "server/memory",
				f: function(hctx) {
					var j = DisplayMemory.getMemoryJson(hctx.display.getCs(), MCache);
					return Result(j);
				}
			},
			{
				name: "server/memory/context",
				f: function(hctx) {
					var sign = hctx.jsonrpc.getStringParam("signature");
					var j = DisplayMemory.getMemoryJson(hctx.display.getCs(), MContext(sign));
					return Result(j);
				}
			},
			{
				name: "server/memory/module",
				f: function(hctx) {
					var sign = hctx.jsonrpc.getStringParam("signature");
					var path = core.Ast.Ast.parsePath(hctx.jsonrpc.getStringParam("path"));
					var j = DisplayMemory.getMemoryJson(hctx.display.getCs(), MModule(sign, path));
					return Result(j);
				}
			},
			{
				name: "typer/compiledTypes",
				f: function(hctx) {
					return defer(AfterFilters, function() {
						var ctx = Genjson.createFullConfig();
						var l = hctx.com.types.map(Genjson.generateModuleType.bind(ctx));
						return Result(jarray(l));
					});
				}
			}
		];
		for (e in l) h.add(e.name, e.f);
		return h;
	}

	public static function runOnCom(jsonrpc:JsonrpcHandler, f:HandlerContext->ApiResponse, com:CommonContext):ParseInputResult {
		function catchApiError(f:Void->ApiResponse):ApiResponse {
			try {
				return f();
			} catch (e:ApiError) {
				return Error(e.json);
			}
		}
		var resultHandler = com.requestScope.resultHandler;
		var display = new DisplayHandler(jsonrpc, com, com.cs);
		var hctx:HandlerContext = {com: com, jsonrpc: jsonrpc, display: display};
		function maybeSendResponse(r:ApiResponse):ParseInputResult {
			return switch r {
				case NoResponse:
					NeedsTyping;
				case Result(json):
					resultHandler.sendResult(json);
					Completed;
				case Error(json):
					resultHandler.sendError([json]);
					Completed;
				case Deferred(deferrence, f):
					function sendResponse(r:ApiResponse):Void {
						switch r {
							case NoResponse:
							case Result(json):
								resultHandler.sendResultRaise(json);
							case Error(json):
								resultHandler.sendErrorRaise([json]);
							case Deferred(_):
								throw new core.Globals.InternalCompilerError("displayJson.ml: nested deferred response", "");
						}
					}
					function f_():Void sendResponse(catchApiError(f));
					switch deferrence {
						case AfterInitMacros: com.callbacks.addAfterInitMacros(f_);
						case AfterFilters: com.callbacks.addAfterFilters(f_);
					}
					NeedsTyping;
			};
		}
		return maybeSendResponse(catchApiError(() -> f(hctx)));
	}

	public static function createJsonResultHandler(timerCtx:core.Timer.TimerContext, io:CompilerIoData,
			jsonrpc:JsonrpcHandler):ResultHandler {
		function sendResult(send:JsonValue->Void, json:JsonValue):Void {
			Sys.stdout().flush();
			Sys.stderr().flush();
			var fl = [kv("result", json), kv("timestamp", jfloat(Sys.time()))];
			var fl = if (timerCtx.measureTimes == Yes) {
				var root = Timer.buildTimesTree(timerCtx).root;
				var jo = jsonOfTimes(root);
				jo == null ? fl : [kv("timers", jo)].concat(fl);
			} else fl;
			var jo = jobject(fl);
			send(JsonRpc.result(jsonrpc.getId(), jo));
		}
		function sendError(send:JsonValue->Void, jl:Array<JsonValue>):Void {
			send(JsonRpc.error(jsonrpc.getId(), 0, JArray(jl), "Compiler error"));
		}
		var sendResultRaise = function(json:JsonValue):Dynamic {
			sendResult(j -> sendJsonRaise(io, j), json);
			return null;
		};
		var sendResultNoraise = function(json:JsonValue):Void sendResult(j -> sendJson(io, j), json);
		var sendErrorRaise = function(errors:Array<JsonValue>):Dynamic {
			sendError(j -> sendJsonRaise(io, j), errors);
			return null;
		};
		var sendErrorNoraise = function(errors:Array<JsonValue>):Void sendError(j -> sendJson(io, j), errors);
		var methodName = jsonrpc.getMethodName();
		var f = handler.findOpt(methodName);
		if (f == null) JsonRpc.raiseMethodNotFound(jsonrpc.getId(), methodName);
		return {
			sendResult: sendResultNoraise,
			sendResultRaise: sendResultRaise,
			sendError: sendErrorNoraise,
			sendErrorRaise: sendErrorRaise,
			// port: the encoding of each display result, which upstream does where it is found
			sendDisplayResultRaise: function(com:CommonContext, r:DisplayResult):Dynamic {
				if (compiler.io.CompilerOutput.isNoCompletion(com, r)) return sendErrorRaise([jstring("No completion point")]);
				return sendResultRaise(DisplayException.resultToJson(com, r));
			},
			flushMessages: function(hasError:Bool, com:CommonContext) {
				// flush_messages in the JSON-RPC handler is always an error state:
				// a successful completion raises JsonCompleted before flush_context is
				// called, so reaching here means no meaningful result was sent.
				if (hasError) {
					var messages = com.partScope.messages.copy();
					messages.reverse();
					var errors = messages.map(cm -> JObject([
						kv("severity", JInt(core.Message.Message.severityToInt(core.Message.Message.severity(cm)))),
						kv("location", Genjson.generatePosAsLocation(cm.cmPos)),
						kv("message", JString(cm.cmMessage))
					]));
					sendErrorRaise(errors);
				} else {
					// No completion point was found — send an appropriate no-result
					// response so the client is not left waiting.
					DisplayException.sendNoResultRaise(com);
				}
			},
			setCom: runOnCom.bind(jsonrpc, f)
		};
	}
}
