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
import haxe.display.Display.CompletionParams;
import haxe.display.Display.FindReferencesKind;
import haxe.display.Display.FindReferencesParams;
import haxe.display.Display.PositionParams;
import compiler.CompilationCache;
import compiler.DisplayProcessingGlobals;
import compiler.io.CompilerIo;
import compiler.io.CompilerIo.CompilerIoData;
import compiler.server.ServerConfig;
import context.Common;
import context.display.DisplayResult;
import compiler.CompilerInstance.RequestStep;
import core.DisplayTypes;
import core.TType;

// port: exception JsonCompleted
class JsonCompleted extends haxe.Exception {
	public function new() super("JsonCompleted");
}

// port: DisplayHandler's reading of a request's parameters (and the handlers'), into the
// ... std's types (haxe.display)
class RequestParams {
	final jsonrpc:JsonrpcHandler;

	public function new(jsonrpc:JsonrpcHandler)
		this.jsonrpc = jsonrpc;

	// port: set_display_file's reading of file, contents, offset and fileContents, in its
	// ... order (a bad request fails as upstream's does)
	public function fileParams(requiresOffset:Bool):PositionParams & DisplayRequests.FileContentsParams {
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

	public function position():PositionParams & DisplayRequests.FileContentsParams
		return fileParams(true);

	public function fileInput():DisplayRequests.FileInputParams
		return fileParams(false);

	/** completion's and signature help's: wasAutoTriggered first */
	public function triggered():CompletionParams & DisplayRequests.FileContentsParams {
		var wasAutoTriggered = jsonrpc.getBoolParam("wasAutoTriggered");
		var p = fileParams(true);
		return {
			file: p.file,
			contents: p.contents,
			offset: p.offset,
			fileContents: p.fileContents,
			wasAutoTriggered: wasAutoTriggered
		};
	}

	/** references': the kind after the file */
	public function references():FindReferencesParams & DisplayRequests.FileContentsParams {
		var p = fileParams(true);
		var kind = jsonrpc.getOptParam(() -> jsonrpc.getStringParam("kind"), "normal");
		return {
			file: p.file,
			contents: p.contents,
			offset: p.offset,
			fileContents: p.fileContents,
			kind: (cast kind : FindReferencesKind)
		};
	}

	public function string(name:String):String
		return jsonrpc.getStringParam(name);

	// (the server/* methods': their fields are final)
	public function context():haxe.display.Server.ContextParams
		return {signature: string("signature")};

	public function module():haxe.display.Server.ModuleParams
		return {signature: string("signature"), path: string("path")};

	public function type():haxe.display.Server.TypeParams
		return {signature: string("signature"), modulePath: string("modulePath"), typeName: string("typeName")};

	/** display/metadata's and display/defines' */
	public function origins():{compiler:Bool, user:Bool}
		return {compiler: jsonrpc.getBoolParam("compiler"), user: jsonrpc.getBoolParam("user")};
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

	public static function findModule(typingMode:compiler.hxb.HxbData.TypingMode, com:CommonContext, cc:ContextCache,
			path:GlobalTypePath):ModuleDef {
		return new HxbReaderApiCom(typingMode, com, cc).findModule(path);
	}

	// port: DisplayJson.handler, as a dispatcher: each method decodes its parameters (the
	// ... std's types), calls the instance's typed method (DisplayServices, ServerServices) and
	// ... encodes its value
	public static final handler:OcamlHashtbl<String, HandlerContext->JsonValue> = makeHandler();

	static function makeHandler():OcamlHashtbl<String, HandlerContext->JsonValue> {
		var h = new OcamlHashtbl<String, HandlerContext->JsonValue>(OcamlHash.hashString, (a, b) -> a == b, 0);
		function orNull<T>(v:Null<T>, f:T->JsonValue):JsonValue
			return v == null ? jnull : f(v);
		function positions(pl:Null<Array<Pos>>):JsonValue
			return orNull(pl, pl -> DisplayException.resultToJson(DRPositions(pl)));
		function symbols(s:Null<compiler.DisplayServices.ModuleSymbols>):JsonValue
			return orNull(s, s -> DisplayException.resultToJson(DRModuleSymbols(s, null)));
		function contexts(l:Array<ContextCache>):JsonValue
			return jarray(l.map(cc -> cc.getJson()));
		function success():JsonValue
			return jobject([kv("success", jbool(true))]);
		var l:Array<{name:String, f:HandlerContext->JsonValue}> = [
			{
				name: "initialize",
				f: function(hctx) {
					var jsonrpc = hctx.jsonrpc;
					var p = hctx.params(function() {
						var supportsResolve = jsonrpc.getOptParam(() -> jsonrpc.getBoolParam("supportsResolve"), false);
						var maxCompletionItems:Null<Int> = jsonrpc.getOptParam(() -> (jsonrpc.getIntParam("maxCompletionItems") : Null<Int>), null);
						var staleContextMaxAge:Null<Int> = jsonrpc.getOptParam(() -> (jsonrpc.getIntParam("staleContextMaxAge") : Null<Int>), null);
						var exclude = jsonrpc.getOptParam(() -> jsonrpc.getArrayParam("exclude"), []).map(e -> switch e {
							case JString(s): s;
							case _: throw new core.Globals.InternalCompilerError("displayJson.ml: exclude entry is not a string", "");
						});
						return {
							supportsResolve: supportsResolve,
							maxCompletionItems: maxCompletionItems,
							staleContextMaxAge: staleContextMaxAge,
							exclude: exclude
						};
					});
					return hctx.instance.answer(function(com) {
						supportsResolve = p.supportsResolve;
						if (p.maxCompletionItems != null) ServerConfig.maxCompletionItems = p.maxCompletionItems;
						if (p.staleContextMaxAge != null) ServerConfig.staleContextMaxAgeSeconds = p.staleContextMaxAge;
						DisplayToplevel.exclude = p.exclude;
						var methods = handler.fold(function(k, _, acc:Array<JsonValue>) {
							acc.unshift(jstring(k));
							return acc;
						}, []);
						var version:core.Globals.CompilerVersion = com.sctx.version;
						return Answer(JObject([
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
					}, hctx.env);
				}
			},
			{
				// (the protocol's: an item of the last completion it sent)
				name: "display/completionItem/resolve",
				f: function(hctx) {
					var i = hctx.params(() -> hctx.jsonrpc.getIntParam("index"));
					return hctx.instance.answer(function(_) {
						if (i < 0 || i >= DisplayException.lastCompletionResult.length) throw new compiler.CompilerInstance.ServiceError('Invalid index: $i');
						var item = DisplayException.lastCompletionResult[i];
						var ctx = Genjson.createFullConfig();
						return Answer(jobject([kv("item", core.display.CompletionItem.toJson(ctx, null, item))]));
					}, hctx.env);
				}
			},
			{
				name: "display/completion",
				f: function(hctx) {
					var c = hctx.display.completion(hctx.params(hctx.decode.triggered));
					if (c == null) throw new compiler.CompilerInstance.ServiceError("No completion point");
					return DisplayException.resultToJson(DRFields(c.fields, c.resolvable));
				}
			},
			{
				name: "display/definition",
				f: hctx -> positions(hctx.display.definition(hctx.params(hctx.decode.position)))
			},
			{
				name: "display/diagnostics",
				f: hctx -> orNull(hctx.display.diagnostics(hctx.params(hctx.decode.fileInput)), d -> DisplayException.resultToJson(DRDiagnostics(d)))
			},
			{
				name: "display/statistics",
				f: hctx -> orNull(hctx.display.statistics(hctx.params(hctx.decode.fileInput)), s -> DisplayException.resultToJson(DRStatistics(s)))
			},
			{
				name: "display/implementation",
				f: hctx -> positions(hctx.display.implementation(hctx.params(hctx.decode.position)))
			},
			{
				name: "display/typeDefinition",
				f: hctx -> positions(hctx.display.typeDefinition(hctx.params(hctx.decode.position)))
			},
			{
				name: "display/references",
				f: hctx -> positions(hctx.display.references(hctx.params(hctx.decode.references)))
			},
			{
				name: "display/hover",
				f: hctx -> orNull(hctx.display.hover(hctx.params(hctx.decode.position)), h -> DisplayException.resultToJson(DRHover(h)))
			},
			{
				name: "display/package",
				f: hctx -> orNull(hctx.display.determinePackage(hctx.params(hctx.decode.fileInput)), p -> DisplayException.resultToJson(DRPackage(p)))
			},
			{
				name: "display/documentSymbols",
				f: hctx -> symbols(hctx.display.documentSymbols(hctx.params(hctx.decode.fileInput)))
			},
			{
				name: "display/workspaceSymbols",
				f: hctx -> symbols(hctx.display.workspaceSymbols(hctx.params(() -> {filter: hctx.decode.string("filter")})))
			},
			{
				name: "display/signatureHelp",
				f: hctx -> orNull(hctx.display.signatureHelp(hctx.params(hctx.decode.triggered)),
					s -> DisplayException.resultToJson(DRSignatures(s.signatures, s.activeSignature, s.activeParameter, s.kind)))
			},
			{
				name: "display/metadata",
				f: function(hctx) {
					var p = hctx.params(hctx.decode.origins);
					return orNull(hctx.display.metadata(p), all -> jarray(all.map(function(m) {
						var data = m.info;
						return jobject([
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
						]);
					})));
				}
			},
			{
				name: "display/defines",
				f: function(hctx) {
					var p = hctx.params(hctx.decode.origins);
					return orNull(hctx.display.defines(p), all -> jarray(all.map(function(d) {
						var data = d.info;
						return jobject([
							kv("name", jstring(d.name)),
							kv("doc", jstring(data.dDoc)),
							kv("parameters", jarray(data.dParams.map(jstring))),
							kv("platforms", jarray(data.dPlatforms.map(p -> jstring(Globals.platformName(p))))),
							kv("origin", jstring(switch data.dOrigin {
								case Compiler: "haxe compiler";
								case UserDefined(null): "user-defined";
								case UserDefined(o): o;
							})),
							kv("deprecated", jopt(jstring, data.dDeprecated)),
							kv("links", jarray(data.dLinks.map(jstring))),
							kv("reserved", jopt(jbool, data.dReserved))
						]);
					})));
				}
			},
			{
				name: "server/resetCache",
				f: function(hctx) {
					hctx.server.resetCache();
					return success();
				}
			},
			{
				name: "server/resetState",
				f: function(hctx) {
					hctx.server.resetState();
					return success();
				}
			},
			{
				name: "server/setCwd",
				f: function(hctx) {
					hctx.server.setCwd(hctx.params(() -> {dir: hctx.decode.string("dir")}));
					return jnull;
				}
			},
			{
				name: "server/gcCompact",
				f: function(hctx) {
					var r = hctx.server.gcCompact();
					return jobject([kv("time", jfloat(r.time)), kv("before", jint(r.before)), kv("after", jint(r.after))]);
				}
			},
			{
				name: "server/readClassPaths",
				f: function(hctx) {
					var wait = hctx.params(() -> hctx.jsonrpc.hasParams() && hctx.jsonrpc.getOptParam(() -> hctx.jsonrpc.getBoolParam("wait"), false));
					return orNull(hctx.server.readClassPaths({wait: wait}), n -> jobject([kv("files", jint(n))]));
				}
			},
			{
				name: "server/contexts",
				f: hctx -> contexts(hctx.server.contexts())
			},
			{
				name: "server/modules",
				f: hctx -> jarray(hctx.server.modules(hctx.params(hctx.decode.context)).map(jstring))
			},
			{
				name: "server/module",
				f: hctx -> Genjson.generateModuleSummary(hctx.server.module(hctx.params(hctx.decode.module)))
			},
			{
				name: "server/type",
				f: hctx -> Genjson.generateModuleType(Genjson.createFullConfig(), hctx.server.type(hctx.params(hctx.decode.type)))
			},
			{
				name: "server/typeContexts",
				f: hctx -> contexts(hctx.server.typeContexts(hctx.params(() -> {modulePath: hctx.decode.string("modulePath"), typeName: hctx.decode.string("typeName")})))
			},
			{
				name: "server/moduleCreated",
				f: hctx -> jstring(hctx.server.moduleCreated(hctx.params(() -> {file: new haxe.display.FsPath(hctx.decode.string("file"))})))
			},
			{
				name: "server/files",
				f: function(hctx) {
					var files = hctx.server.files(hctx.params(hctx.decode.context));
					return jarray(files.map(f -> jobject([
						kv("file", jstring(f.cFilePath.file)),
						kv("time", jfloat(f.cTime)),
						kv("pack", jstring(f.cPackage.join("."))),
						kv("moduleName", jopt(jstring, f.cModuleName))
					])));
				}
			},
			{
				name: "server/invalidate",
				f: function(hctx) {
					hctx.server.invalidate(hctx.params(() -> {file: new haxe.display.FsPath(hctx.decode.string("file"))}));
					return jnull;
				}
			},
			{
				name: "server/configure",
				f: function(hctx) {
					var jsonrpc = hctx.jsonrpc;
					var p:compiler.ServerServices.ServerConfigureParams = hctx.params(function() {
						// (upstream applies the settings before a bad value)
						var print = [];
						for (f in jsonrpc.getOptParam(() -> jsonrpc.getObjectParam("print"), [])) {
							var value = try jsonrpc.getBool("value", f.value) catch (e:Dynamic) {
								var before = print.copy();
								throw new ParamsFailed(e, () -> compiler.ServerServices.applyConfigure({print: before}));
							}
							print.push({name: f.name, value: value});
						}
						var noModuleChecks:Null<Bool> = jsonrpc.getOptParam(() -> (jsonrpc.getBoolParam("noModuleChecks") : Null<Bool>), null);
						return {print: print, noModuleChecks: noModuleChecks};
					});
					return jarray(hctx.server.configure(p).map(jstring));
				}
			},
			{
				name: "server/memory",
				f: hctx -> DisplayMemory.cacheMemoryJson(hctx.server.memory())
			},
			{
				name: "server/memory/context",
				f: hctx -> DisplayMemory.contextMemoryJson(hctx.server.contextMemory(hctx.params(hctx.decode.context)))
			},
			{
				name: "server/memory/module",
				f: hctx -> DisplayMemory.moduleMemoryJson(hctx.server.moduleMemory(hctx.params(hctx.decode.module)))
			},
			{
				name: "typer/compiledTypes",
				f: hctx -> orNull(hctx.server.compiledTypes(), types -> jarray(types.map(Genjson.generateModuleType.bind(Genjson.createFullConfig()))))
			}
		];
		for (e in l) h.add(e.name, e.f);
		return h;
	}

	// port: the JSON-RPC result handler's send_result: the response to the request
	public static function resultMessage(at:AnsweredAt, jsonrpc:JsonrpcHandler, json:JsonValue):JsonValue {
		var fl = [kv("result", json), kv("timestamp", jfloat(at.timestamp))];
		var fl = if (at.timers != null) [kv("timers", at.timers)].concat(fl) else fl;
		return JsonRpc.result(jsonrpc.getId(), jobject(fl));
	}

	// port: the start of send_result: the flush, the timestamp and the timers
	public static function answeredAt(timerCtx:core.Timer.TimerContext):AnsweredAt {
		Sys.stdout().flush();
		Sys.stderr().flush();
		var timestamp = Sys.time();
		var timers = if (timerCtx.measureTimes == Yes) jsonOfTimes(Timer.buildTimesTree(timerCtx).root) else null;
		return {timestamp: timestamp, timers: timers};
	}

	// port: the JSON-RPC result handler's send_error
	public static function errorMessage(jsonrpc:JsonrpcHandler, jl:Array<JsonValue>):JsonValue
		return JsonRpc.error(jsonrpc.getId(), 0, JArray(jl), "Compiler error");

	// port: the JSON-RPC result handler's flush_messages: a failed compilation's errors
	public static function messagesToJson(messages:Array<core.Message.CompilerMessage>):Array<JsonValue>
		return messages.map(cm -> JObject([
			kv("severity", JInt(core.Message.Message.severityToInt(core.Message.Message.severity(cm)))),
			kv("location", Genjson.generatePosAsLocation(cm.cmPos)),
			kv("message", JString(cm.cmMessage))
		]));

	/** A JSON-RPC request (`--display`'s argument) on the instance: the response goes to
		`io`. A request that is not one, or names no method, is answered with its error and
		raises Exit. Returns the request's timers. */
	public static function dispatch(instance:compiler.CompilerInstance, io:CompilerIoData, request:String):core.Timer.TimerContext {
		// port: create_json_result_handler (Server.createRequestScope's): the request and its method
		var jsonrpc = JsonRpc.handleJsonrpcError(function() {
			var jsonrpc = new JsonrpcHandler(JsonRpc.parseRequest(request));
			if (handler.findOpt(jsonrpc.getMethodName()) == null) JsonRpc.raiseMethodNotFound(jsonrpc.getId(), jsonrpc.getMethodName());
			return jsonrpc;
		}, function(json) {
			sendJson(io, json);
			throw core.ds.Exit.raise();
		});
		var f = handler.find(jsonrpc.getMethodName());
		var timerCtx = Timer.makeContext(Timer.make(["other"]));
		var at:Null<AnsweredAt> = null;
		var env:compiler.CompilerInstance.RequestEnv = {io: io, timerCtx: timerCtx, onAnswer: () -> at = answeredAt(timerCtx), keepCwd: true};
		var hctx:HandlerContext = {
			jsonrpc: jsonrpc,
			decode: new RequestParams(jsonrpc),
			instance: instance,
			env: env,
			display: new compiler.DisplayServices(instance, env),
			server: new compiler.ServerServices(instance, env)
		};
		function result(json:JsonValue):JsonValue
			return resultMessage(at != null ? at : answeredAt(timerCtx), jsonrpc, json);
		function respond(f:Void->JsonValue):JsonValue
			return try {
				result(f());
			} catch (e:compiler.CompilerInstance.ServiceError) {
				errorMessage(jsonrpc, [jstring(e.message)]);
			} catch (e:compiler.CompilerInstance.CompilationError) {
				errorMessage(jsonrpc, messagesToJson(e.messages));
			}
		var curdir = Sys.getCwd();
		// (encoded in the request's directory, as upstream does: keepCwd)
		function restore() core.Path.restoreCwd(curdir);
		var response = try try {
			respond(() -> f(hctx));
		} catch (e:ParamsFailed) {
			// (upstream reads the parameters after the arguments: the failure is the compilation's)
			var failed = e;
			respond(() -> switch instance.request(function(_):compiler.CompilerInstance.RequestStep<JsonValue> {
				if (failed.before != null) failed.before();
				throw failed.error;
			}, env) {
				case Failed(messages): throw new compiler.CompilerInstance.CompilationError(messages);
				case Answered(json): json;
				case Found(r): DisplayException.resultToJson(r);
			});
		} catch (e:Dynamic) {
			restore();
			throw e;
		}
		sendJson(io, response);
		restore();
		return timerCtx;
	}
}

typedef AnsweredAt = {timestamp:Float, timers:Null<JsonValue>};

// port: not upstream: what a method of the dispatcher (DisplayJson.handler) has
@:structInit class HandlerContext {
	public final jsonrpc:JsonrpcHandler;
	public final decode:RequestParams;
	public final instance:compiler.CompilerInstance;
	public final env:compiler.CompilerInstance.RequestEnv;
	public final display:compiler.DisplayServices;
	public final server:compiler.ServerServices;

	/** the parameters, as `f` reads them: its failure is replayed as the compilation's */
	public function params<T>(f:Void->T):T
		return try f() catch (e:ParamsFailed) throw e catch (e:Dynamic) throw new ParamsFailed(e);
}

/** Reading the parameters failed with `error`: replayed in the request's compilation, after
	`before` (what upstream did with the parameters it read before the failure). */
class ParamsFailed extends haxe.Exception {
	public final error:Dynamic;
	public final before:Null<Void->Void>;

	public function new(error:Dynamic, ?before:Void->Void) {
		super("ParamsFailed");
		this.error = error;
		this.before = before;
	}
}
