// The frame chain (Abi.framePointers): with a frame record in every function
// (arm64 always; x86-64 by default, unless -D hxmc.frame-pointers=0), a
// walk from Mem.frame() through the saved frame pointers
// passes every frame up to main's, as a profiler (perf record -g) or a
// debugger unwinds: through recursion, closures, the runtime's Haxe code
// calling back (Array.sort), a caught exception and collections. Where
// functions keep no records (WebAssembly), Mem.frame() is null and the
// checks are skipped (the output is the same).
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

class FrameChain {
	static var top:Ptr;
	static var sink:Array<Array<Int>> = [];

	// the return addresses from the caller's frame up to main's (each record
	// above the last), or null when the chain is broken
	static function walk():Null<Array<Ptr>> {
		var f = Mem.frame();
		var rets:Array<Ptr> = [];
		while (f != top) {
			// (the saved rbp; windows-x86_64 with -D hxmc.llvm: LLVM's frames keep
			// their record a constant above rbp, hxmc.rt.Stacks.callerOf)
			var up = @:privateAccess hxmc.rt.Stacks.callerOf(f, Mem.getPtr(f, 8));
			if (up.isNull() || !f.ult(up) || rets.length > 100000) return null;
			rets.push(Mem.getPtr(f, 8));
			f = up;
		}
		return rets;
	}

	static function check(what:String, rets:Null<Array<Ptr>>, minFrames:Int, maxDistinct:Int) {
		if (top.isNull()) {
			Sys.println(what + ": ok");
			return;
		}
		if (rets == null) {
			Sys.println(what + ": broken chain");
			return;
		}
		var distinct:Array<Ptr> = [];
		for (r in rets) {
			var seen = false;
			for (d in distinct)
				if (d == r) seen = true;
			if (!seen) distinct.push(r);
		}
		var ok = rets.length >= minFrames && distinct.length <= maxDistinct;
		Sys.println(what + ": " + (ok ? "ok" : 'unexpected (${rets.length} frames, ${distinct.length} return addresses)'));
	}

	// (allocates on the way down: collections happen during the recursion)
	static function rec(n:Int):Null<Array<Ptr>> {
		sink.push([for (i in 0...64) i * n]);
		if (sink.length > 32) sink.shift();
		if (n == 0) return walk();
		var r = rec(n - 1);
		return r;
	}

	static function main() {
		top = Mem.frame();
		// 40 frames of rec, all returning to the same place (and a few more)
		check("recursion", rec(40), 41, 8);
		// a closure called from the runtime's sort
		var inSort:Null<Array<Ptr>> = null;
		var a = [3, 1, 2];
		a.sort((x, y) -> {
			if (inSort == null) inSort = walk();
			return x - y;
		});
		check("runtime callback", inSort, 2, 1000);
		// after an exception was caught in a deeper frame
		var afterCatch:Null<Array<Ptr>> = null;
		try {
			throwAt(10);
		} catch (e:String) {
			afterCatch = walk();
		}
		check("after catch", afterCatch, 0, 1000);
		check("after throw", rec(5), 6, 8);
	}

	static function throwAt(n:Int):Int {
		if (n == 0) throw "deep";
		return throwAt(n - 1) + 1;
	}
}
