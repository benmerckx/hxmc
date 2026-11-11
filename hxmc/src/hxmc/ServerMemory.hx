package hxmc;

import compiler.server.ServerCompilationContext;
import context.Common;

// What a compilation server keeps between requests, kept under a cap
// (-D hxmc.server-mb=<n>, else HXMC_SERVER_MB=<n>: n MB of live heap; unset
// or 0: no cap; each compilation's own, read at its start). The server
// keeps a context per signature (the typed modules of every program it built,
// with their macros' contexts), hxmc keeps the objects of each output it wrote
// (Driver.memObjs), the lowered bodies of the last program (LowerCache) and
// the macro interpreter: a second project built in the same server keeps the
// first's as well, which a server with little memory (a browser's worker,
// wasm32: its memory never shrinks) cannot afford.
//
// A compilation's group is its signature's (at the start of its typing) and
// the contexts it used (those its typing touched, and their children: the
// contexts their modules depend on). With a cap:
//   - a compilation of another group than the last request's (another
//     project, or the same with other defines), when other groups are kept,
//     starts with a major collection; if what is live (and, when its own
//     group is not kept, as much again as a kept group holds on average) is
//     more than the cap, the least recently used other groups are dropped
//     before it types anything, one by one, until it fits;
//   - after a request, when the heap holds more than the cap (garbage
//     included) and other groups are kept, a major collection; while what
//     is live is more than the cap, the least recently used other groups
//     are dropped the same way.
// A group dropped: its contexts (ServerMemory.dropContexts: not those a kept
// group uses), the objects of the outputs it wrote, the lowered bodies when
// they are its program's, and the macro interpreter (it holds the types of
// every macro context it ran: made again by the next compilation). A dropped
// project's next build is a cold one. What a single group keeps is never
// dropped: the cap is not a limit on one project. hxmc.stats (HXMC_STATS=1)
// prints what is dropped.
class ServerMemory {
	// (the running or last compilation's: -D hxmc.server-mb, else HXMC_SERVER_MB, read in begin)
	static var cap:Float = -1;
	static var stats = false; // (-D hxmc.stats, else HXMC_STATS)

	static var groups:Array<Group> = [];
	static var current:Null<Group> = null; // the running compilation's
	static var last:Null<Group> = null; // the last request's
	static var start = 0.0; // the running compilation's start (its contexts are those touched since)
	static var requests = 0;

	public static inline function capped():Bool
		return cap > 0;

	// the start of a compilation of the server (ModuleCache.hook, before its typing)
	public static function begin(com:CommonContext) {
		var v = Std.parseFloat(Options.flag("hxmc.server-mb", com.defines) ?? "");
		cap = Math.isNaN(v) || v <= 0 ? -1 : v * 1048576;
		stats = Options.on("hxmc.stats", false, com.defines);
		var key = core.Define.getSignature(com.defines);
		requests++;
		var g = Lambda.find(groups, g -> g.key == key);
		if (g == null) {
			g = new Group(key);
			groups.push(g);
		}
		g.used = requests;
		current = g;
		// (the signature's context was touched just before the hook)
		start = Sys.time() - 1e-3;
		if (!capped() || last == g || lru(g) == null) return;
		var cs = com.cs;
		NativeGc.collect(true);
		var live = GcStats.liveBytes();
		// (a group not kept is assumed to need as much as those kept do, each)
		var kept = groups.filter(x -> x != g && x.signs.length > 0).length;
		var need = g.signs.length > 0 || kept == 0 ? live : live + live / kept;
		while (need > cap) {
			var x = lru(g);
			if (x == null) break;
			drop(cs, x, "before a build of another group");
			NativeGc.collect(true);
			var now = GcStats.liveBytes();
			need -= live - now;
			live = now;
		}
	}

	// the end of a request (ServerCache.cleanupHook)
	public static function end(sctx:ServerCompilationContext) {
		var g = current;
		current = null;
		if (g == null) return;
		last = g;
		// (the contexts it touched, and theirs)
		var cs = sctx.cs;
		var signs = new Map<String, Bool>();
		for (cc in cs.getContexts())
			if (cc.getLastAccessTime() >= start) signs.set(cc.getSign(), true);
		signs.set(g.key, true);
		g.signs = [for (s in closure(cs, signs).keys()) s];
		if (!capped() || GcStats.liveBytes() <= cap || lru(g) == null) return;
		NativeGc.collect(true);
		while (GcStats.liveBytes() > cap) {
			var x = lru(g);
			if (x == null) break;
			drop(cs, x, "after a request");
			NativeGc.collect(true);
		}
	}

	// an output a compilation wrote, its objects kept (Driver.build)
	public static function output(out:String) {
		if (current != null && current.outs.indexOf(out) < 0) current.outs.push(out);
	}

	// the least recently used group with something kept, but g
	static function lru(g:Group):Null<Group> {
		var best:Null<Group> = null;
		for (x in groups)
			if (x != g && (x.signs.length > 0 || x.outs.length > 0) && (best == null || x.used < best.used)) best = x;
		return best;
	}

	static function drop(cs:compiler.CompilationCache.Cache, x:Group, why:String) {
		var before = GcStats.liveBytes();
		var keep = new Map<String, Bool>();
		for (y in groups)
			if (y != x) for (s in y.signs) keep.set(s, true);
		var gone = dropContexts(cs, [for (s in x.signs) if (!keep.exists(s)) s]);
		for (o in x.outs)
			Driver.forgetOutput(o);
		Main.forgetLowered(x.signs);
		// (and what the last compilations left that holds their programs: the
		// macro interpreter, made again by the next compilation's first macro,
		// the filters of the last macro context, the lowering's basic types)
		typing.MacroContext.macroInterpCache = null;
		typing.MacroContext.lateFieldFilters = null;
		@:privateAccess hxmc.ir.Lower.basic = null;
		x.signs = [];
		x.outs = [];
		if (stats)
			Sys.println('hxmc: server memory: ${gone} contexts of another group dropped $why (live ${Std.int(before / 1048576)} MB, cap ${Std.int(cap / 1048576)} MB)');
	}

	// signs and the contexts they reach (their children: a module of one may depend on the other's)
	static function closure(cs:compiler.CompilationCache.Cache, signs:Map<String, Bool>):Map<String, Bool> {
		var work = [for (s in signs.keys()) s];
		while (work.length > 0) {
			var s = work.pop();
			var cc = Lambda.find(cs.getContexts(), c -> c.getSign() == s);
			if (cc == null) continue;
			cc.getChildren().iter((child, _) -> if (!signs.exists(child)) {
				signs.set(child, true);
				work.push(child);
			});
		}
		return signs;
	}

	// the contexts of signs removed from the cache (as Cache.removeStaleContexts
	// removes those not used for a while): how many there were
	static function dropContexts(cs:compiler.CompilationCache.Cache, signs:Array<String>):Int @:privateAccess {
		var n = 0;
		for (s in signs)
			if (cs.contexts.findOpt(s) != null) {
				cs.contexts.remove(s);
				cs.clearDirectories(s);
				n++;
			}
		cs.contextList = cs.contextList.filter(cc -> signs.indexOf(cc.getSign()) < 0);
		return n;
	}
}

private class Group {
	public final key:String;
	public var signs:Array<String> = [];
	public var outs:Array<String> = [];
	public var used = 0;

	public function new(key)
		this.key = key;
}
