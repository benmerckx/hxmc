package compiler;

import compiler.Args;
import compiler.io.CompilerIo;
import compiler.io.CompilerOutput;
import compiler.server.Server;
import compiler.server.ServerCompilationContext;
import core.Message.CompilerMessage;
import context.display.DisplayResult;

// port: not upstream: the compiler as an API. An instance is a set of arguments
// ... (expanded: hxml read, parts split; without --display, --connect, --wait) and
// ... a cache, given once; each build runs the whole pipeline on them (the init
// ... macros included), as a request to the server does. The compiler's hooks and
// ... statics are the process's: one build at a time per process.
// ... Design: docs/plans/compiler-instance.md.
class CompilerInstance {
	public final args:RequestArgs;
	public final cache:CompilerCache;

	/** the display/* methods of the protocol, typed */
	public final display:DisplayServices;

	/** the server/* methods of the protocol (and typer/compiledTypes), typed */
	public final server:ServerServices;

	public function new(args:RequestArgs, cache:CompilerCache) {
		if (args.displayArg != null) throw new core.ds.ArgumentError("CompilerInstance: --display is a call of its own, not an argument");
		if (args.connectArg != null) throw new core.ds.ArgumentError("CompilerInstance: --connect is a client's, not an argument");
		switch args.serverMode {
			case SMNone:
			case _: throw new core.ds.ArgumentError("CompilerInstance: --wait and --server-connect are a server's, not arguments");
		}
		Init.initHooks();
		this.args = args;
		this.cache = cache;
		this.display = new DisplayServices(this);
		this.server = new ServerServices(this);
	}

	/** Parses and expands command-line arguments (as `haxe` does) into an instance. */
	public static function ofArgs(args:Array<String>, cache:CompilerCache):CompilerInstance {
		return new CompilerInstance(Args.expandArgs(Args.parseArgs(args)), cache);
	}

	/** Builds every part of the arguments; the messages go to `io` as `haxe` prints
		them, and are returned. Throws what the compiler throws (an ArgumentError, an
		internal error), with the cache released. */
	public function build(io:CompilerIoData):BuildResult {
		var sctx = cache.begin();
		var scope = Server.createRequestScope(sctx.isServer, io);
		var messages:Array<CompilerMessage> = [];
		var flush = scope.resultHandler.flushMessages;
		scope.resultHandler.flushMessages = function(hasError, com) {
			// (partScope.messages is newest first)
			var i = com.partScope.messages.length;
			while (i-- > 0) messages.push(com.partScope.messages[i]);
			flush(hasError, com);
		}
		var code = try run(sctx, scope, args) catch (e:Dynamic) {
			cache.end(sctx);
			throw e;
		}
		// (a server's result handler reports the timers itself)
		if (code == 0 && !sctx.isServer) {
			var timerCtx = scope.timerCtx;
			if (timerCtx.measureTimes == core.Timer.MeasureTimes.Yes)
				CompilerOutput.sendTimerReport(io, timerCtx);
		}
		cache.end(sctx);
		return {code: code, messages: messages};
	}

	/** One request of the protocol (a JSON-RPC request's compilation, as `--display`
		runs it): `start` sees the context once the arguments are processed and says how
		the request is answered (RequestStep). A ServiceError thrown by `start` or by a
		deferred answer ends the compilation and is rethrown. `env`: the request's io and
		timers, and what is done when it is answered (default: no output). */
	public function request<T>(start:context.Common.CommonContext->RequestStep<T>, ?env:RequestEnv):RequestOutcome<T> {
		var sctx = cache.begin();
		var ownIo = env == null;
		var io = ownIo ? CompilerIo.create(_ -> {}, _ -> {}, _ -> {}, () -> {}, null) : env.io;
		var scope = Server.createRequestScope(sctx.isServer, io);
		if (env != null) scope.timerCtx = env.timerCtx;
		var answered = false;
		var answer:Null<T> = null;
		var failure:Null<ServiceError> = null;
		var found:Null<context.display.DisplayResult> = null;
		var errors:Null<Array<CompilerMessage>> = null;
		function unexpected(what:String):Dynamic
			throw new core.Globals.InternalCompilerError("CompilerInstance.request: " + what + " outside a JSON-RPC request", "");
		function completed():Dynamic
			throw new context.display.DisplayJson.JsonCompleted();
		// (where upstream sends its response)
		function now():Void
			if (env != null && env.onAnswer != null) env.onAnswer();
		scope.resultHandler = {
			sendResult: _ -> unexpected("send_result"),
			sendResultRaise: _ -> unexpected("send_result_raise"),
			sendError: _ -> unexpected("send_error"),
			sendErrorRaise: _ -> unexpected("send_error_raise"),
			sendDisplayResultRaise: function(_, r):Dynamic {
				found = r;
				now();
				return completed();
			},
			// (as the JSON-RPC handler: with errors, the compilation failed; otherwise there
			// was nothing to answer)
			flushMessages: function(hasError, com) {
				if (hasError) {
					errors = [];
					var i = com.partScope.messages.length;
					while (i-- > 0) errors.push(com.partScope.messages[i]);
				} else {
					found = DRNone;
					now();
				}
			},
			// port: DisplayJson.handler's responses: an answer now (Completed), typing for
			// ... a display result, or an answer deferred to a stage of the compilation
			setCom: function(com) {
				return try switch start(com) {
					case Answer(v):
						answered = true;
						answer = v;
						now();
						Completed;
					case Typing:
						NeedsTyping;
					case After(stage, f):
						function answerLater():Void {
							try {
								answer = f();
								answered = true;
								now();
							} catch (e:ServiceError) failure = e;
							completed();
						}
						switch stage {
							case AfterInitMacros: com.callbacks.addAfterInitMacros(answerLater);
							case AfterFilters: com.callbacks.addAfterFilters(answerLater);
						}
						NeedsTyping;
				} catch (e:ServiceError) {
					failure = e;
					Completed;
				}
			}
		};
		// (HighLevel's hasDisplay: the arguments of a display request)
		var displayArgs = args.clone();
		displayArgs.displayArg = "";
		try run(sctx, scope, displayArgs) catch (e:Dynamic) {
			if (ownIo) CompilerIo.close(io);
			cache.end(sctx);
			throw e;
		}
		if (ownIo) CompilerIo.close(io);
		cache.end(sctx);
		if (failure != null) throw failure;
		return if (answered) Answered(answer) else if (found != null) Found(found) else if (errors != null) Failed(errors) else Found(DRNone);
	}

	/** A display request: `configure` sets up the context as the method asks
		(context.display.DisplayRequests), then the compilation finds the result. */
	public function displayRequest(configure:context.Common.CommonContext->Void, ?env:RequestEnv):RequestOutcome<Any>
		return request(function(com) {
			configure(com);
			return Typing;
		}, env);

	function run(sctx:ServerCompilationContext, scope:context.Common.RequestScope, args:RequestArgs):Int
		return sctx.isServer ? process(sctx, scope, args) : HighLevel.entry(sctx, scope, args);

	// Server.process, keeping the exit code
	function process(sctx:ServerCompilationContext, scope:context.Common.RequestScope, args:RequestArgs):Int {
		var t0 = Sys.time();
		var curdir = Sys.getCwd();
		compiler.server.ServerMessage.arguments(Args.stringOfRequestArgs(args));
		ServerCompilationContext.reset(sctx);
		if (sctx.persistentCwd != null) try Sys.setCwd(sctx.persistentCwd)
		catch (_:Dynamic) {}
		var code = try HighLevel.entry(sctx, scope, args) catch (e:Dynamic) {
			core.Path.restoreCwd(curdir);
			throw e;
		}
		core.Path.restoreCwd(curdir);
		ServerCompilationContext.runDelays(sctx);
		compiler.server.ServerMessage.stats(scope.stats, Sys.time() - t0);
		return code;
	}
}

/** How a request is answered, once the arguments are processed. */
enum RequestStep<T> {
	/** now, from the context: no typing */
	Answer(v:T);

	/** by typing: the display result it finds */
	Typing;

	/** by `f`, at a stage of the compilation */
	After(stage:RequestStage, f:Void->T);
}

enum RequestStage {
	AfterInitMacros;
	AfterFilters;
}

enum RequestOutcome<T> {
	/** the answer (Answer, After) */
	Answered(v:T);

	/** what typing found (DRNone: nothing) */
	Found(result:context.display.DisplayResult);

	/** the compilation failed before answering: its errors, oldest first */
	Failed(messages:Array<CompilerMessage>);
}

/** Where a request's output goes: its io (the messages the compilation prints, traces)
	and its timers (--times). */
@:structInit class RequestEnv {
	public final io:compiler.io.CompilerIo.CompilerIoData;
	public final timerCtx:core.Timer.TimerContext;

	/** called when the request is answered, inside the compilation (where upstream
		writes its response: the timers it reports are taken there) */
	public final onAnswer:Null<Void->Void> = null;
}

/** A method's error that is not the compilation's (an invalid parameter, a module the
	cache does not have): the protocol's error response with this message. */
class ServiceError extends haxe.Exception {}

@:structInit class BuildResult {
	/** the exit code `haxe` gives (0: built) */
	public final code:Int;

	/** every part's messages, oldest first */
	public final messages:Array<CompilerMessage>;
}

/** Where a CompilerInstance's builds keep what they typed. */
interface CompilerCache {
	/** the server context of a build: its module cache (`cs`), with the typing and
		parsing hooks pointed at it */
	function begin():ServerCompilationContext;

	/** after the build, whether it succeeded or not */
	function end(sctx:ServerCompilationContext):Void;
}

/** Nothing kept: every build types everything from source (a plain `haxe`). */
class SkipCache implements CompilerCache {
	public function new() {}

	public function begin():ServerCompilationContext
		return Server.setupServerContext(false, false);

	public function end(sctx:ServerCompilationContext):Void
		ServerCompilationContext.dispose(sctx);
}

/** One module cache kept between builds, in memory (`haxe --wait`'s). Instances of
	several argument sets can share one, as the server's requests do: their defines
	partition it. */
class InMemoryCache implements CompilerCache {
	public final sctx:ServerCompilationContext;

	public function new(sctx:ServerCompilationContext)
		this.sctx = sctx;

	public static function create(verbose = false):InMemoryCache
		return new InMemoryCache(Server.setupServerContext(verbose, true));

	public function begin():ServerCompilationContext {
		// (the hooks are the process's: another cache may have pointed them elsewhere)
		compiler.server.ServerCache.enableCacheMode(sctx);
		return sctx;
	}

	// (between requests the server cleans up and explores, after the client has its
	// answer: the host's, as Server's worker does)
	public function end(sctx:ServerCompilationContext):Void {}

	public function dispose():Void
		ServerCompilationContext.dispose(sctx);
}
