package hxmc;

import compiler.server.Server;
import compiler.server.ServerCompilationContext;

// The module cache (ModuleCache) as a CompilerInstance's cache: a build of its own
// process, with a server context of its own (as SkipCache's) that the store fills.
// What the cache cannot do for a build (a server, display, init macros, several
// compilations, ...) it decides once the arguments are processed (beforeTyping):
// such a build types everything from source, as SkipCache's.
class OnDiskCache implements compiler.CompilerInstance.CompilerCache {
	/** whether hxmc's code generation failed (its generateHook): the build is not kept */
	final generationFailed:Void->Bool;

	var ended = false;

	public function new(generationFailed:Void->Bool) {
		this.generationFailed = generationFailed;
		ModuleCache.observe();
	}

	public function begin():ServerCompilationContext
		return Server.setupServerContext(false, false);

	public function beforeTyping(com:context.Common.CommonContext, actx:compiler.ParsedArg.ArgContext):Void
		ModuleCache.beforeTyping(com, actx);

	public function end(sctx:ServerCompilationContext, code:Int):Void {
		ServerCompilationContext.dispose(sctx);
		ended = true;
		ModuleCache.finish(generationFailed() ? 1 : code);
	}

	/** After the process's builds: the store settled when none ended (bad arguments, a
		display request). */
	public function close():Void
		if (!ended) ModuleCache.finish(1);
}
