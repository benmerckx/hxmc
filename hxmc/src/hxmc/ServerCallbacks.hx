package hxmc;

import compiler.server.ServerCache;
import context.Common;
import core.Globals.GlobalTypePath;
import core.TType;

// The compilation server and the modules a macro's callback defines
// (Context.defineType or defineModule in an onAfterTyping, onGenerate or
// onAfterGenerate callback: helder's Late_<hash>, a class made from the
// program's types). Such a module is kept with no module
// (MacroContext.defineType: the module the macro API names as current there
// did not make it), so a later compilation has it only if the callback runs
// again. A callback a macro registered while a module was typed is
// registered again only when that module is typed again: a compilation that
// reuses it would build a program without the definition, which a fresh
// build has. So the module whose typing registered a callback that defined
// a module is typed again in the server's next compilation
// (ServerCache.checkModuleHook), as the module cache types such a module
// every build (ModuleCache, WatchedCallbacks); its typing registers the
// callback again, or does not, and the module is reused after.
class ServerCallbacks {
	// (by context signature and path, across the server's compilations)
	static final registrants = new Map<String, Bool>();
	static final mutex = new sys.thread.Mutex();

	// a compilation of the server (ModuleCache.hook: its own cache is not used there)
	public static function install() {
		typing.MacroContext.callbackDefinedHook = defined;
		ServerCache.checkModuleHook = check;
	}

	// any other compilation (the module cache's checks, or none)
	public static function uninstall() {
		typing.MacroContext.callbackDefinedHook = null;
	}

	static function key(sign:String, path:GlobalTypePath):String
		return sign + "|" + core.Globals.sTypePath(path);

	// MacroContext.callbackDefinedHook: a callback that m's typing registered defined a module
	static function defined(m:ModuleDef) {
		if (m.mExtra.mKind != MCode) return;
		mutex.acquire();
		registrants.set(key(m.mExtra.mSign, m.mPath), true);
		mutex.release();
	}

	// ServerCache.checkModuleHook: such a module typed again (once: its typing
	// marks it again if its callback defines a module again)
	static function check(com:CommonContext, mPath:GlobalTypePath, mExtra:ModuleDefExtra):Null<ModuleSkipReason> {
		mutex.acquire();
		var mine = registrants.remove(key(mExtra.mSign, mPath));
		mutex.release();
		return mine ? FileChanged(core.Path.UniqueKey.lazyPath(mExtra.mFile) + " (a callback its macros registered defined a module)") : null;
	}
}
