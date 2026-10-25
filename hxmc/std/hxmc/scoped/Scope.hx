package hxmc.scoped;

#if !hxmc.wasm_gc
import hxmc.rt.DataStacks;
#end
import hxmc.unsafe.*;
import hxmc.scoped.Slice;
#if hxmc.wasm_gc
import hxmc.scoped.Slice.SliceData;
#end

// Memory of the current scope (docs/plans/lowlevel.md, "Scoped memory"):
// fresh, freed when the scope ends (linear memory: on the data stack; WasmGC:
// the engine's array, which its collector reclaims).
class Scope {
	// n zeroed elements
	public static inline function slice<T>(n:Int):Slice<T> {
		#if hxmc.wasm_gc
		return cast SliceData.fresh(new NativeArray<T>(n), n);
		#else
		var bytes = (Ptr.nil() : Ptr<T>).offset(n).toI64().toInt();
		var p = DataStacks.alloc(bytes);
		LibC.memset(p, 0, (bytes : I64));
		return new Slice((p : Ptr<T>), n);
		#end
	}

	// n elements not zeroed (WasmGC's are): for the std's cores, which write
	// every element before reading it, of scalars only (garbage read as a
	// reference would not be memory safe)
	@:noCompletion public static inline function scratch<T>(n:Int):Slice<T> {
		#if hxmc.wasm_gc
		return cast SliceData.fresh(new NativeArray<T>(n), n);
		#else
		var p = DataStacks.alloc((Ptr.nil() : Ptr<T>).offset(n).toI64().toInt());
		return new Slice((p : Ptr<T>), n);
		#end
	}

	// the bytes of the current thread's scoped memory in use, and its
	// Grows and Pools live (WasmGC: none, the engine's collector holding it)
	public static inline function used():Int
		return #if hxmc.wasm_gc 0 #else DataStacks.used() #end;

	public static inline function claimed():Int
		return #if hxmc.wasm_gc 0 #else DataStacks.claimed() #end;
}
