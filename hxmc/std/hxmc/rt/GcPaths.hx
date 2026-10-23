package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The slow paths of allocation and reference stores that generated code
// calls (WebAssembly's are in wasm/Gc.hx): one call sequence each, so that
// every allocation or reference store site has a short slow path.
@:hxmc.native @:keep
class GcPaths {
	// Gc.allocSlow with the header assembled here (the type index is a
	// link-time constant: it cannot be shifted into place by the linker): a
	// record's (Types.isRecord) with its slots from the bytes, else an array's,
	// w0 its first word (its type and width), len its length
	@:hxmc.export("hxmc_alloc_slow") @:hxmc.collects static function allocSlow(len:Int, w0:Int, bytes:Int):Ptr
		return Gc.allocSlow(Types.isRecord(w0 & 0xFFFF) ? Types.recordHdr(w0 & 0xFFFF, (bytes >> 3) - 1) : Types.arrayHdr(w0, len), bytes);

	// the rest of the barrier once obj is known not to be young: the slot
	// now holds a young pointer, and held none (a slot of an old object that
	// holds a young pointer is remembered already: every such store comes
	// through here or rt_barrier_range)
	@:hxmc.export("hxmc_barrier_slow") @:hxmc.noGc static function barrierSlow(obj:Ptr, slot:Ptr, v:Ptr, prev:Ptr):Void {
		if (Gc.inYoung(v) && !Gc.inYoung(prev)) Gc.remember(slot);
	}
}
