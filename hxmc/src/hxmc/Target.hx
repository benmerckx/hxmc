package hxmc;

import hxmc.Lir;
import hxmc.Mir;

// A target architecture's code generator: instruction selection (which
// also tells the register allocator about its instructions) and emission.
interface Selector extends Regalloc.RegTarget {
	function select(mf:MFunc, layout:haxe.ds.Vector<MBlock>):LFunc;
}

interface Emitter {
	function func(f:LFunc, usedRegs:haxe.ds.Vector<Bool>, global:Bool):Obj.Symbol;
	// where the next functions go: their own section (`name`, Link's dead
	// code removal may drop it), or the object's .text (null)
	function useSection(name:Null<String>):Void;
	// an allocation stub (DataGen.allocStubs) written directly: false when
	// the target has no such writer (the stub is then a compiled function)
	function allocStub(name:String, lo:Int, tySym:Null<String>, tyVal:Int, bytes:Int):Bool;
	// one of the runtime's machine-code stubs (MirBuild.STUB_*: a stack
	// switch, zeroing), written directly
	function stub(name:String):Void;
}

class Target {
	public static function selector(abi:Abi):Selector
		return abi.arm ? new hxmc.a64.Isel(abi) : new hxmc.x64.Isel(abi);

	public static function emitter(abi:Abi, obj:Obj):Emitter
		return abi.wasm ? new hxmc.wasm.WasmEmitter(obj) : abi.arm ? new hxmc.a64.Emit(obj, abi.os == "windows") : new hxmc.x64.Emit(obj, abi.os == "windows", abi.framePointers);
}
