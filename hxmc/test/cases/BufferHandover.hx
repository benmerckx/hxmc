// Memory handed between raw code and an owned Buffer without a copy:
// Buffer.adopt takes an IoBuffer raw code made (none refused, one of no
// bytes taken), detach gives it back (the Buffer closed, empty: close() then
// does nothing), refused once closed. Built -D hxmc.strict: only the
// trusted functions touch the raw side.
// define: hxmc.strict
import hxmc.Buffer;
import hxmc.unsafe.IoBuffer;

class BufferHandover {
	// raw code's buffer, adopted
	@:hxmc.unsafe(gc) static function made():Buffer {
		var io = IoBuffer.alloc(4);
		io.setInt32(0, 0x04030201);
		return Buffer.adopt(io);
	}

	// detached, read by raw code, freed
	@:hxmc.unsafe(gc) static function given(b:Buffer):Int {
		var io = b.detach();
		var v = io.get(0) + io.get(3);
		io.free();
		return v;
	}

	// a buffer of no bytes adopted
	@:hxmc.unsafe(gc) static function empty():Buffer
		return Buffer.adopt(IoBuffer.alloc(0));

	// a null IoBuffer refused
	@:hxmc.unsafe(gc) static function nothing():String
		return try {
			Buffer.adopt(cast hxmc.unsafe.Ptr.nil());
			"adopted";
		} catch (e:String) e;

	static function main() {
		var b = made();
		Sys.println("adopted: " + b.length + " bytes, " + b.get(0) + " " + b.get(3));
		b.set(0, 10);
		Sys.println("detached: " + given(b) + ", closed " + b.closed + ", length " + b.length);
		Sys.println("null: " + nothing());
		b.close();
		Sys.println("closed after: " + b.closed + ", length " + b.length);
		var e = empty();
		Sys.println("empty: " + e.length + " bytes, " + e.getBytes(0, 0).length);
		e.close();
		Sys.println("again: " + (try {
			given(b);
			"detached";
		} catch (e:String) e));
	}
}
