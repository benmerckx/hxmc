package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.*;

// The stacks of a native program: walked through the frame records every
// generated function keeps (docs/hxmc.md, "Debugging": x86-64 by default,
// arm64 always), the way the unwind tables describe the frames, and named
// through the program's table of its functions and source lines
// (hxmc_stacks: hxmc/src/hxmc/StackTable.hx, from the records -debug's DWARF
// lines come from). One facility for haxe.CallStack (callStack, exception
// stacks: haxe.NativeStackTrace) and the report of an uncaught exception or
// a null access (Start.throwValue). A walk goes up while a frame's return
// address is in a function of the table, so it stops at the first frame of
// C code (the C library's start, a thread's entry, a callback's caller) and
// never follows a frame pointer it cannot trust; with an empty table (the
// program names no stacks, -D hxmc.no-stacks) or no frame records
// (-D hxmc.no-frame-pointers, WebAssembly) the stacks are empty.
@:hxmc.native @:keep @:allow(hxmc.rt)
class Stacks {
	// the frames a stack keeps at most
	public static inline var MAX = 256;

	// the table's functions sorted by address, 24 bytes each (start, end, the
	// entry), made on first use (two threads may both make it: one is kept)
	static var index:Ptr;
	static var count:Int;

	// what the program reads of stacks, the value of the absolute symbol
	// hxmc_stack_flags (the linker's: Driver, after Reach): EXCEPTION_STACKS,
	// throws record their stack (haxe.NativeStackTrace.exceptionStack is
	// live); STACKS, an exception records its stack when made (an exception's
	// stack is read: haxe.Exception.get_stack is live). A program that reads
	// neither walks no stack when it throws.
	public static inline var EXCEPTION_STACKS = 1;
	public static inline var STACKS = 2;

	@:hxmc.noGc public static inline function flags():Int
		return Mem.sym("hxmc_stack_flags").toI64().toInt();

	// the last throw's return addresses, per thread
	@:hxmc.threadLocal static var thrown:Ptr;
	@:hxmc.threadLocal static var thrownLen:Int;

	@:hxmc.noGc static inline function table():Ptr
		return Mem.sym("hxmc_stacks");

	@:hxmc.noGc static function ensureIndex():Bool {
		if (!index.isNull()) return true;
		var t = table();
		var n = Mem.getI32(t, 8);
		if (n == 0) return false;
		var ix = LibC.malloc((n : I64) * 24);
		for (i in 0...n) {
			var e = t.add(20 + 16 * i);
			var start = e.addL((Mem.getI32(e, 0) : I64));
			Mem.setPtr(ix, 24 * i, start);
			Mem.setPtr(ix, 24 * i + 8, start.add(Mem.getI32(e, 4)));
			Mem.setPtr(ix, 24 * i + 16, e);
		}
		// (heap sort by start)
		var k = (n >> 1) - 1;
		while (k >= 0) {
			sift(ix, k, n);
			k--;
		}
		var end = n - 1;
		while (end > 0) {
			swap(ix, 0, end);
			sift(ix, 0, end);
			end--;
		}
		count = n;
		index = ix;
		return true;
	}

	@:hxmc.noGc static inline function less(ix:Ptr, a:Int, b:Int):Bool
		return Mem.getPtr(ix, 24 * a).ult(Mem.getPtr(ix, 24 * b));

	@:hxmc.noGc static function swap(ix:Ptr, a:Int, b:Int) {
		for (k in 0...3) {
			var x = Mem.getI64(ix, 24 * a + 8 * k);
			Mem.setI64(ix, 24 * a + 8 * k, Mem.getI64(ix, 24 * b + 8 * k));
			Mem.setI64(ix, 24 * b + 8 * k, x);
		}
	}

	@:hxmc.noGc static function sift(ix:Ptr, root:Int, end:Int) {
		var r = root;
		while (true) {
			var c = 2 * r + 1;
			if (c >= end) break;
			if (c + 1 < end && less(ix, c, c + 1)) c++;
			if (!less(ix, r, c)) break;
			swap(ix, r, c);
			r = c;
		}
	}

	// the table's entry of the function holding code address a, or null
	@:hxmc.noGc public static function find(a:Ptr):Ptr {
		if (!ensureIndex()) return Ptr.nil();
		var lo = 0, hi = count - 1;
		while (lo <= hi) {
			var mid = (lo + hi) >> 1;
			if (a.ult(Mem.getPtr(index, 24 * mid))) hi = mid - 1 else if (!a.ult(Mem.getPtr(index, 24 * mid + 8))) lo = mid + 1 else
				return Mem.getPtr(index, 24 * mid + 16);
		}
		return Ptr.nil();
	}

	// the return addresses known to be in functions of the table, by a hash
	// of the address (CACHE of them, made on first use; another thread's
	// store of a whole word at worst replaces an entry): a walk looks each
	// up once, as the program throws its exceptions from the same places
	static inline var CACHE = 8192;
	static var cache:Ptr;

	@:hxmc.noGc static function known(ret:Ptr):Bool {
		if (cache.isNull()) {
			if (!ensureIndex()) return false;
			var c = LibC.malloc(8 * CACHE);
			LibC.memset(c, 0, 8 * CACHE);
			cache = c;
		}
		var h = ((ret.toI64() >> 2).toInt() ^ (ret.toI64() >> 15).toInt()) & (CACHE - 1);
		if (Mem.getPtr(cache, 8 * h) == ret) return true;
		if (find(ret.add(-1)).isNull()) return false;
		Mem.setPtr(cache, 8 * h, ret);
		return true;
	}

	// the return addresses from frame record f up, at most max, into out,
	// below `limit` (an address in a frame: the frames of the functions it
	// calls are below it, the stack growing down; null: none); how many
	@:hxmc.noGc static function walkFrom(f:Ptr, out:Ptr, max:Int, limit:Ptr):Int {
		var n = 0;
		while (n < max && !f.isNull() && (f.toI64() & 7) == 0 && (limit.isNull() || f.ult(limit))) {
			var ret = Mem.getPtr(f, 8);
			var up = Mem.getPtr(f, 0);
			if (limit.isNull()) {
				// (the caller is a function of the table: its frame record is one)
				if (!known(ret)) break;
			} else if (!f.ult(up)) {
				// (below a limit, records only up the stack, up to the limit: all
				// of them in the stack's memory, so none is checked against the
				// table; an address of C code is left out when named, describe)
				break;
			}
			Mem.setPtr(out, 8 * n, ret);
			n++;
			f = up;
		}
		walkEnd = f;
		return n;
	}

	// the record a walk stopped at (walkFrom)
	@:hxmc.threadLocal static var walkEnd:Ptr;

	// the return addresses from the caller's caller up (the function calling
	// walk is the first frame)
	@:hxmc.noGc public static function walk(out:Ptr, max:Int):Int
		return walkFrom(Mem.frame(), out, max, Ptr.nil());

	// the stack here, from the caller of the function calling capture, as
	// the bytes of its return addresses (8 each)
	public static function capture():haxe.io.Bytes {
		var buf = Mem.stack(8 * MAX);
		var n = walk(buf, MAX);
		return ofAddresses(buf, n);
	}

	static function ofAddresses(p:Ptr, n:Int):haxe.io.Bytes {
		var b = haxe.io.Bytes.alloc(8 * n);
		copyInto(b.getData(), p, n);
		return b;
	}

	// (b: the haxe.io.BytesData of a haxe.io.Bytes)
	@:hxmc.noGc static function copyInto(b:Dynamic, p:Ptr, n:Int)
		LibC.memcpy(Bytes.bytes(b), p, (8 * n : I64));

	// rt_throw: the thrower's stack up to the frame of the try that catches
	// it, `handler` (its jump buffer, in that frame), when the program reads
	// exception stacks: the frames between the throw and the catch, which an
	// exception stack is (haxe.CallStack.exceptionStack), the last the
	// catching function's, at the call the throw came from. Not the whole
	// stack: a program may throw millions of times (the port's self-compile
	// throws 2.3 million times, 150 frames deep on average: 2.3 s more
	// recorded whole, against 7 s)
	@:hxmc.noGc @:hxmc.withStacks public static function recordThrow(handler:Ptr) {
		if ((flags() & EXCEPTION_STACKS) == 0) return;
		if (thrown.isNull()) thrown = LibC.malloc(8 * MAX);
		thrownLen = walkFrom(Mem.frame(), thrown, MAX, handler);
		thrownTop = handler.isNull() ? Ptr.nil() : walkEnd;
	}

	// the frame record of the function that caught the last throw (where its
	// recorded stack stops: recordThrow), per thread
	@:hxmc.threadLocal static var thrownTop:Ptr;

	// the last throw's stack (of this thread), as capture's: the frames up to
	// the function catching it, then, while that function runs (a catch
	// block, or a function it calls: haxe.CallStack.exceptionStack,
	// haxe.Exception.caught), its callers as they are now (the rest of the
	// stack of the throw)
	public static function lastThrow():haxe.io.Bytes {
		if (thrown.isNull()) return haxe.io.Bytes.alloc(0);
		var buf = Mem.stack(8 * MAX);
		return ofAddresses(buf, lastThrowInto(buf));
	}

	@:hxmc.noGc static function lastThrowInto(buf:Ptr):Int {
		var n = thrownLen;
		LibC.memcpy(buf, thrown, (8 * n : I64));
		var top = thrownTop;
		if (top.isNull() || n >= MAX) return n;
		// (the catching function's record on the stack of this call: its frame is live)
		var f = Mem.frame();
		while (!f.isNull() && f.ult(top) && (f.toI64() & 7) == 0 && known(Mem.getPtr(f, 8)))
			f = Mem.getPtr(f, 0);
		if (f != top) return n;
		return n + walkFrom(top, buf.add(8 * n), MAX - n, Ptr.nil());
	}

	// ---- names

	@:hxmc.noGc static function uleb(p:Ptr, at:Ptr):Int {
		var v = 0, shift = 0, i = Mem.getI32(at, 0);
		while (true) {
			var c = Mem.getU8(p, i++);
			v |= (c & 0x7f) << shift;
			if (c < 0x80) break;
			shift += 7;
		}
		Mem.setI32(at, 0, i);
		return v;
	}

	@:hxmc.noGc static function sleb(p:Ptr, at:Ptr):Int {
		var v = 0, shift = 0, i = Mem.getI32(at, 0), c = 0;
		while (true) {
			c = Mem.getU8(p, i++);
			v |= (c & 0x7f) << shift;
			shift += 7;
			if (c < 0x80) break;
		}
		Mem.setI32(at, 0, i);
		return shift < 32 && (c & 0x40) != 0 ? v | (-1 << shift) : v;
	}

	// the rest of entry e (StackTable): its line area, the offset there
	@:hxmc.noGc static inline function lineArea():Ptr
		return table().add(Mem.getI32(table(), 16));

	// the Haxe name of entry e's function (pack.Class.field), or null
	public static function name(e:Ptr):Null<String> {
		var owner = Mem.getI32(e, 8), rest = Mem.getI32(e, 12);
		var field = 0;
		if (rest != 0) {
			var at = Mem.stack(8);
			Mem.setI32(at, 0, rest);
			field = uleb(lineArea(), at);
		}
		if (owner == 0) return field == 0 ? null : str(field);
		return field == 0 ? str(owner) : str(owner) + "." + str(field);
	}

	static function str(off:Int):String {
		var p = table().add(Mem.getI32(table(), 12) + off);
		var n = LibC.strlen(p).toInt();
		return Str.decode(Repr.octetsAt(p, n), 0, n);
	}

	// the row of entry e at code address a (the return address of a call: its
	// instruction is before it): the file's string and the line, packed as
	// file << 32 | line; 0 when the function has no lines
	@:hxmc.noGc static function row(e:Ptr, a:Ptr):I64 {
		var rest = Mem.getI32(e, 12);
		if (rest == 0) return 0;
		var p = lineArea();
		var start = e.addL((Mem.getI32(e, 0) : I64));
		var off = a.diff(start).toInt() - 1;
		var at = Mem.stack(8);
		Mem.setI32(at, 0, rest);
		uleb(p, at); // (the field)
		var n = uleb(p, at);
		var pos = 0, file = 0, line = 0, o = 0, f = 0, l = 0;
		for (k in 0...n) {
			var w = uleb(p, at);
			o += w >> 1;
			if ((w & 1) != 0) f = uleb(p, at);
			l += sleb(p, at);
			if (k > 0 && o > off) break;
			pos = o;
			file = f;
			line = l;
		}
		return ((file : I64) << 32) | (line : I64);
	}

	// the function, file and line of return address a (null: not a function
	// of the table)
	public static function describe(a:Ptr):Null<{name:Null<String>, file:Null<String>, line:Int}> {
		var e = find(a.add(-1));
		if (e.isNull()) return null;
		var r = row(e, a);
		var f = (r >> 32).toInt();
		return {name: name(e), file: f == 0 ? null : str(f), line: (r & 0xffffffff).toInt()};
	}

	// the return address k of a stack capture made
	@:hxmc.noGc public static function at(b:haxe.io.Bytes, k:Int):Ptr
		return Mem.getPtr(Bytes.bytes(b.getData()), 8 * k);

	// whether a frame is the runtime's own (not shown in stacks)
	public static function internal(name:Null<String>):Bool
		return name == null || StringTools.startsWith(name, "hxmc.rt.") || StringTools.startsWith(name, "hxmc.unsafe.");

	// the constructors of an object's class and its superclasses
	// (pack.Class.new: the top frames of an exception's stack made in them,
	// haxe.Exception.get_stack), from the runtime's types (no reflection)
	public static function constructors(o:Dynamic):Array<String> {
		var r = [];
		var t = Types.tindex(o);
		while (t >= Types.T_FIRST) {
			var ty = Types.ty(t);
			r.push(Str.ofAscii(Types.name(ty)) + ".new");
			t = Types.sup(ty);
		}
		return r;
	}

	// ---- reports

	// an uncaught exception's report (Start.throwValue): the frames of the
	// throw, as haxe.CallStack.toString prints them, on stderr
	@:hxmc.withStacks public static function report() {
		var buf = Mem.stack(8 * MAX);
		var n = walk(buf, MAX);
		var s = new StringBuf();
		for (k in 0...n) {
			var d = describe(Mem.getPtr(buf, 8 * k));
			if (d == null || d.file == null || internal(d.name)) continue;
			s.add("Called from ");
			s.add(d.name);
			if (d.file != null) {
				s.add(" (");
				s.add(d.file);
				s.add(" line ");
				s.add(d.line);
				s.add(")");
			}
			s.add("\n");
		}
		if (s.length == 0) return;
		var c = Str.toUtf8(s.toString());
		Os.write(c, LibC.strlen(c).toInt());
		LibC.free(c);
	}
}
