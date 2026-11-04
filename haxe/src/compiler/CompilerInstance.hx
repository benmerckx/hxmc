package compiler;

import compiler.io.CompilerIo;
import compiler.server.Server;
import compiler.server.ServerCache;
import compiler.server.ServerCompilationContext;

// port: not upstream: a compilation server without a transport: what `haxe --wait`
// ... keeps between requests (the context, the module cache, the macro interpreter)
// ... and the lifecycle of one request, upstream's in the worker domain of
// ... create_worker. Server.waitLoop's worker (sockets, a queue, a thread) runs its
// ... requests here, and so do hosts that hand it requests themselves (the
// ... playground's worker: site/compiler). The compiler's hooks and statics are the
// ... process's: one instance per process.
class CompilerInstance {
	public final sctx:ServerCompilationContext;

	public function new(verbose = false) {
		Init.initHooks();
		sctx = Server.setupServerContext(verbose, true);
	}

	/** one request (from a client's message: Server.parseRequest), its output on `io`,
		closed after, then `afterOutput` (the transport's: the connection closed), then
		what the server does between requests. Oom returns right after `afterOutput`:
		the host exits, as `haxe --wait` does. */
	public function request(request:Request, io:CompilerIoData, ?afterOutput:Void->Void):RequestOutcome {
		sctx.currentStdin = request.stdin;
		var outcome = Server.runRequest(sctx, io, request);
		CompilerIo.close(io);
		if (afterOutput != null) afterOutput();
		switch outcome {
			case Oom:
				return outcome;
			case _:
		}
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
