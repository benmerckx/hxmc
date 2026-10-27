import hxmc.I64;
import hxmc.NativeGc;
import hxmc.unsafe.*;
import sys.thread.Lock;
import sys.thread.Thread;

// Blocking C calls and the collector (docs/interop.md, "Blocking calls"):
// two threads wait on pipes nobody has written yet, one in a call of an
// extern declared @:hxmc.blocking (read, which the runtime itself declares
// @:hxmc.fast; ReadFile on Windows), one in a fast call between
// Blocking.enter and Blocking.leave, while the main thread allocates and
// collects. Collections stop the world: without the safe regions they would
// wait for the readers forever, and the readers wait for the main thread.
@:hxmc.c extern class Io {
	@:hxmc.blocking @:native("read") static function read(fd:Int, p:Ptr, n:I64):I64;
	@:hxmc.blocking @:hxmc.lib("kernel32") static function ReadFile(h:Ptr, p:Ptr, n:Int, got:Ptr, ov:Ptr):Int;
	@:hxmc.fast @:hxmc.lib("kernel32") static function WriteFile(h:Ptr, p:Ptr, n:Int, put:Ptr, ov:Ptr):Int;
}
#if (hxmc.target != "wasm32-wasi") // (no threads nor pipes on WebAssembly: Corpus.WASM_EXCLUDED; Crosshost builds it)
class BlockingCalls {
	// a pipe: its read and write ends (descriptors, or Windows' handles)
	static function pipe():Array<I64> {
		var a = Arena.create();
		var p = a.alloc(16);
		var ok = Mem.os() == 2 ? Win32.CreatePipe(p, p.add(8), Ptr.nil(), 0) != 0 : Posix.pipe(p) == 0;
		var r = Mem.os() == 2 ? [Mem.getI64(p, 0), Mem.getI64(p, 8)] : [(Mem.getI32(p, 0) : I64), (Mem.getI32(p, 4) : I64)];
		a.dispose();
		if (!ok) throw "pipe";
		return r;
	}

	static function put(w:I64, v:Int) {
		var buf = IoBuffer.alloc(8);
		buf.set(0, v);
		if (Mem.os() == 2) Io.WriteFile(Ptr.ofI64(w), buf.ptr, 1, buf.ptr.add(4), Ptr.nil()) else Posix.write(w.toInt(), buf.ptr, 1);
		buf.free();
	}

	// a read in a call declared @:hxmc.blocking
	static function readMarked(r:I64, buf:IoBuffer):Int {
		if (Mem.os() == 2) {
			var ok = Io.ReadFile(Ptr.ofI64(r), buf.ptr, 1, buf.ptr.add(4), Ptr.nil());
			return ok != 0 ? buf.getInt32(4) : -1;
		}
		return Io.read(r.toInt(), buf.ptr, 1).toInt();
	}

	// the same in a fast call, in a safe region entered by hand
	@:hxmc.unsafe static function readByHand(r:I64, p:Ptr):Int {
		var region = Blocking.enter();
		var n = Mem.os() == 2 ? readWin(r, p) : Posix.read(r.toInt(), p, 1).toInt();
		Blocking.leave(region);
		return n;
	}

	@:hxmc.unsafe static function readWin(r:I64, p:Ptr):Int
		return ReadFast.ReadFile(Ptr.ofI64(r), p, 1, p.add(4), Ptr.nil()) != 0 ? Mem.getI32(p, 4) : -1;

	static function main() {
		var a = pipe(), b = pipe();
		var done = new Lock();
		var got = [];
		Thread.create(() -> {
			var buf = IoBuffer.alloc(8);
			var n = readMarked(a[0], buf);
			got.push('marked: $n byte(s), ${buf.get(0)}');
			buf.free();
			done.release();
		});
		Thread.create(() -> {
			var buf = IoBuffer.alloc(8);
			var n = readByHand(b[0], buf.ptr);
			got.push('by hand: $n byte(s), ${buf.get(0)}');
			buf.free();
			done.release();
		});
		// allocations and collections while both wait
		var keep = [];
		for (r in 0...40) {
			for (i in 0...3000)
				keep.push({i: i, s: "v" + i});
			if (keep.length > 20000) keep = [];
			NativeGc.collect(r % 4 == 3);
		}
		trace("collected while blocked");
		put(a[1], 42);
		done.wait();
		put(b[1], 7);
		done.wait();
		trace(got.join("; "));
	}
}

@:hxmc.c @:hxmc.fast @:hxmc.lib("kernel32") extern class ReadFast {
	@:native("ReadFile") static function ReadFile(h:Ptr, p:Ptr, n:Int, got:Ptr, ov:Ptr):Int;
}
#else
class BlockingCalls {
	static function main() {}
}
#end
