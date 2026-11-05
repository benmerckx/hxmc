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
		var scope = Server.createRequestScope(sctx.isServer, io, null);
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

	/** One display request: `configure` sets up the context as the method asks
		(context.display.DisplayRequests), then the compilation finds the result. No output. */
	public function displayRequest(configure:context.Common.CommonContext->Void):DisplayOutcome {
		var sctx = cache.begin();
		var io = CompilerIo.create(_ -> {}, _ -> {}, _ -> {}, () -> {}, null);
		var scope = Server.createRequestScope(sctx.isServer, io, null);
		var found:Null<context.display.DisplayResult> = null;
		var errors:Null<Array<CompilerMessage>> = null;
		function unexpected(what:String):Dynamic
			throw new core.Globals.InternalCompilerError("CompilerInstance.displayRequest: " + what + " outside a JSON-RPC request", "");
		scope.resultHandler = {
			sendResult: _ -> unexpected("send_result"),
			sendResultRaise: _ -> unexpected("send_result_raise"),
			sendError: _ -> unexpected("send_error"),
			sendErrorRaise: _ -> unexpected("send_error_raise"),
			sendDisplayResultRaise: function(_, r):Dynamic {
				found = r;
				throw new context.display.DisplayJson.JsonCompleted();
			},
			// (as the JSON-RPC handler: with errors, the compilation failed; otherwise there
			// was nothing at the position)
			flushMessages: function(hasError, com) {
				if (hasError) {
					errors = [];
					var i = com.partScope.messages.length;
					while (i-- > 0) errors.push(com.partScope.messages[i]);
				} else found = DRNone;
			},
			setCom: function(com) {
				configure(com);
				return NeedsTyping;
			}
		};
		// (HighLevel's hasDisplay: the arguments of a display request)
		var displayArgs = args.clone();
		displayArgs.displayArg = "";
		try run(sctx, scope, displayArgs) catch (e:Dynamic) {
			CompilerIo.close(io);
			cache.end(sctx);
			throw e;
		}
		CompilerIo.close(io);
		cache.end(sctx);
		return if (found != null) DOResult(found) else if (errors != null) DOErrors(errors) else DOResult(DRNone);
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

enum DisplayOutcome {
	/** what the request found (DRNone: nothing at the position) */
	DOResult(result:context.display.DisplayResult);

	/** the compilation failed before finding anything: its errors, oldest first */
	DOErrors(messages:Array<CompilerMessage>);
}

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
