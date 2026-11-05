package compiler;

import compiler.Args;
import compiler.io.CompilerIo;
import compiler.io.CompilerOutput;
import compiler.server.Server;
import compiler.server.ServerCompilationContext;
import core.Message.CompilerMessage;

// port: not upstream: the compiler as an API. An instance is a set of arguments
// ... (expanded: hxml read, parts split; without --display, --connect, --wait) and
// ... a cache, given once; each build runs the whole pipeline on them (the init
// ... macros included), as a request to the server does. The compiler's hooks and
// ... statics are the process's: one build at a time per process.
// ... Design: docs/plans/compiler-instance.md.
class CompilerInstance {
	public final args:RequestArgs;
	public final cache:CompilerCache;

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
		var code = try (sctx.isServer ? process(sctx, scope) : HighLevel.entry(sctx, scope, args)) catch (e:Dynamic) {
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

	// Server.process, keeping the exit code
	function process(sctx:ServerCompilationContext, scope:context.Common.RequestScope):Int {
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
