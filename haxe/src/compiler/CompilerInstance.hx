package compiler;

import compiler.Args;
import compiler.io.CompilerIo;
import compiler.io.CompilerOutput;
import compiler.server.Server;
import compiler.server.ServerCompilationContext;
import core.Message.CompilerMessage;
import context.display.DisplayResult;

// port: not upstream: the compiler as an API: expanded arguments (no --display,
// ... --connect, --wait) and a cache. Each call runs the whole pipeline, init macros
// ... included. The hooks and statics are the process's: one call at a time.
// ... Design: docs/plans/compiler-instance.md.
class CompilerInstance {
	public final args:RequestArgs;
	public final cache:CompilerCache;

	public final display:DisplayServices;
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

	/** Builds every part; the messages go to `io` as `haxe` prints them, and are returned. */
	public function build(io:CompilerIoData):BuildResult {
		var sctx = cache.begin();
		sctx.cache = cache;
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
			cache.end(sctx, 1);
			throw e;
		}
		// (a server's result handler reports the timers itself)
		if (code == 0 && !sctx.isServer) {
			var timerCtx = scope.timerCtx;
			if (timerCtx.measureTimes == core.Timer.MeasureTimes.Yes)
				CompilerOutput.sendTimerReport(io, timerCtx);
		}
		cache.end(sctx, code);
		return {code: code, messages: messages};
	}

	/** One request, as `--display` runs it: once the arguments are processed, `start`
		says how it is answered. A ServiceError it throws ends the compilation and is
		rethrown. Without `env`, no output. */
	public function request<T>(start:context.Common.CommonContext->RequestStep<T>, ?env:RequestEnv):RequestOutcome<T> {
		var sctx = cache.begin();
		sctx.cache = cache;
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
		// (where upstream writes its response)
		var answerDir:Null<String> = null;
		function now():Void
			if (env != null) {
				if (env.keepCwd) answerDir = Sys.getCwd();
				if (env.onAnswer != null) env.onAnswer();
			}
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
			// (errors: the compilation failed; otherwise there was nothing to answer)
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
			cache.end(sctx, 1);
			throw e;
		}
		if (answerDir != null) core.Path.restoreCwd(answerDir);
		if (ownIo) CompilerIo.close(io);
		cache.end(sctx, 0);
		if (failure != null) throw failure;
		return if (answered) Answered(answer) else if (found != null) Found(found) else if (errors != null) Failed(errors) else Found(DRNone);
	}

	/** A display request: `configure` sets it up (DisplayRequests), typing finds the result. */
	public function displayRequest(configure:context.Common.CommonContext->Void, ?env:RequestEnv):RequestOutcome<Any>
		return request(function(com) {
			configure(com);
			return Typing;
		}, env);

	/** A request `start` answers (Answer, After); null: none. Failure: a CompilationError. */
	public function answer<T>(start:context.Common.CommonContext->RequestStep<T>, ?env:RequestEnv):Null<T>
		return switch request(start, env) {
			case Answered(v): v;
			case Found(DRNone): null;
			case Found(r): throw new core.Globals.InternalCompilerError('a request found ${Type.enumConstructor(r)}', "");
			case Failed(messages): throw new CompilationError(messages);
		}

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

/** A request's io and timers (--times). */
@:structInit class RequestEnv {
	public final io:compiler.io.CompilerIo.CompilerIoData;
	public final timerCtx:core.Timer.TimerContext;

	/** called when it is answered, inside the compilation (upstream writes its response there) */
	public final onAnswer:Null<Void->Void> = null;

	/** the directory current when it is answered (--cwd, server/setCwd) stays current
		after it, for the caller to restore: relative positions resolve against it */
	public final keepCwd:Bool = false;
}

/** A method's own error (an invalid directory, an unknown module): the protocol's error response. */
class ServiceError extends haxe.Exception {}

/** A compilation that failed before answering: its errors, oldest first. */
class CompilationError extends haxe.Exception {
	public final messages:Array<CompilerMessage>;

	public function new(messages:Array<CompilerMessage>) {
		super(messages.length == 0 ? "Compilation failed" : messages[0].cmMessage);
		this.messages = messages;
	}
}

@:structInit class BuildResult {
	/** the exit code `haxe` gives (0: built) */
	public final code:Int;

	/** every part's messages, oldest first */
	public final messages:Array<CompilerMessage>;
}

/** Where a CompilerInstance's builds keep what they typed. */
interface CompilerCache {
	/** the build's server context, with the hooks pointed at it */
	function begin():ServerCompilationContext;

	/** once the arguments are processed, before the init macros: what the cache can do
		for this build (Compiler.beforeTypingHook) */
	function beforeTyping(com:context.Common.CommonContext, actx:compiler.ParsedArg.ArgContext):Void;

	/** after the build, with its exit code (0: built) */
	function end(sctx:ServerCompilationContext, code:Int):Void;
}

/** Nothing kept: every build types everything from source (a plain `haxe`). */
class SkipCache implements CompilerCache {
	public function new() {}

	public function begin():ServerCompilationContext
		return Server.setupServerContext(false, false);

	public function beforeTyping(com:context.Common.CommonContext, actx:compiler.ParsedArg.ArgContext):Void {}

	public function end(sctx:ServerCompilationContext, code:Int):Void
		ServerCompilationContext.dispose(sctx);
}

/** One module cache kept in memory (`haxe --wait`'s); instances of several argument sets
	can share it (their defines partition it). */
class InMemoryCache implements CompilerCache {
	public final sctx:ServerCompilationContext;

	public function new(sctx:ServerCompilationContext)
		this.sctx = sctx;

	public static function create(verbose = false):InMemoryCache
		return new InMemoryCache(Server.setupServerContext(verbose, true));

	/** a build ended since the last idle */
	var used = false;

	public function begin():ServerCompilationContext {
		// (a host that did not call idle)
		if (used) cleanup();
		used = true;
		// (the hooks are the process's: another cache may have pointed them elsewhere)
		compiler.server.ServerCache.enableCacheMode(sctx);
		return sctx;
	}

	public function beforeTyping(com:context.Common.CommonContext, actx:compiler.ParsedArg.ArgContext):Void {}

	public function end(sctx:ServerCompilationContext, code:Int):Void {}

	/** The server's work between requests: the cleanup, and after a compilation the class
		paths' exploration, as a task for a host that runs tasks while idle. */
	public function idle():Void {
		cleanup();
		var cs:compiler.CompilationCache.Cache = sctx.cs;
		if (sctx.wasCompilation) cs.addTask(new compiler.Tasks.ServerExplorationTask(cs));
	}

	/** ServerCache.cleanup: drops the display requests' temporary cache, whose modules a
		later request must not reuse. */
	function cleanup():Void {
		used = false;
		compiler.server.ServerCache.cleanup(sctx);
	}

	public function dispose():Void
		ServerCompilationContext.dispose(sctx);
}
