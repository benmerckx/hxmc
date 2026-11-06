package hxmc;

import compiler.server.Server;
import compiler.server.ServerCompilationContext;

// The module cache (ModuleCache) as a CompilerInstance's cache: the builds of one
// process, with a server context of their own (as SkipCache's) that the store fills.
// Each part of a build (--next) opens its index once its arguments are processed
// (beforeTyping) and writes it at its end (endPart). What the cache cannot do for a
// part (display, init macros, libraries, ...) it decides in beforeTyping: such a part
// types everything from source, as SkipCache's.
class OnDiskCache implements compiler.CompilerInstance.CompilerCache {
	/** whether hxmc's code generation failed (its generateHook): the part is not kept */
	final generationFailed:Void->Bool;

	var ended = false;

	public function new(generationFailed:Void->Bool)
		this.generationFailed = generationFailed;

	public function hooks():core.CacheHooks
		return ModuleCache.hooks;

	public function begin():ServerCompilationContext
		return Server.setupServerContext(false, false);

	public function beforeTyping(com:context.Common.CommonContext, actx:compiler.ParsedArg.ArgContext):Void
		ModuleCache.beforeTyping(com, actx);

	public function endPart(com:context.Common.CommonContext, code:Int):Void {
		ended = true;
		ModuleCache.finish(generationFailed() ? 1 : code);
	}

	public function end(sctx:ServerCompilationContext, code:Int):Void {
		ServerCompilationContext.dispose(sctx);
		// (a part that ended with an exception: nothing kept)
		if (ModuleCache.current() != null) {
			ended = true;
			ModuleCache.finish(1);
		}
	}

	/** After the process's builds: the store settled when no part ended (bad arguments, a
		display request). */
	public function close():Void
		if (!ended) ModuleCache.finish(1);
}
