package compiler;

import compiler.io.CompilerIo;
import compiler.server.Server;
import compiler.server.ServerCache;
import compiler.server.ServerCompilationContext;

// port: not upstream: a compilation server without a transport, for hosts that
// ... hand it requests themselves (the playground's worker: site/compiler). It
// ... keeps what `haxe --wait` keeps between requests (the context, the module
// ... cache, the macro interpreter) and runs a request as the worker domain of
// ... Server.createWorker does, on an IO the host supplies.
class CompilerInstance {
	public final sctx:ServerCompilationContext;

	public function new(verbose = false) {
		Init.initHooks();
		sctx = Server.setupServerContext(verbose, true);
	}

	/** one request: the arguments a `haxe --connect` client sends, the outputs on `io` (closed after) */
	public function request(args:Array<String>, io:CompilerIoData, ?stdin:String):RequestOutcome {
		var request:Request = {args: Args.parseArgs(args), stdin: stdin, conn: null};
		sctx.currentStdin = stdin;
		var outcome = Server.runRequest(sctx, io, request);
		CompilerIo.close(io);
		sctx.currentStdin = null;
		ServerCache.cleanup(sctx);
		if (sctx.wasCompilation)
			sctx.cs.addTask(new compiler.Tasks.ServerExplorationTask(sctx.cs));
		return outcome;
	}

	/** the server's background work (class path exploration), one task at a time between requests */
	public function hasTask():Bool
		return sctx.cs.hasTask();

	public function runTask():Void
		if (sctx.cs.hasTask()) sctx.cs.getTask().run();

	public function dispose():Void
		ServerCompilationContext.dispose(sctx);
}
