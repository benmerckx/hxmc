package hxmc.wasm;

import hxmc.Obj;
import hxmc.wasm.Enc;

// The emitter interface for WebAssembly: functions go through WasmGen
// (Driver); allocation stubs are written here directly.
class WasmEmitter implements hxmc.Target.Emitter {
	var obj:Obj;

	public function new(obj:Obj) {
		this.obj = obj;
	}

	public function func(f:hxmc.Lir.LFunc, usedRegs:haxe.ds.Vector<Bool>, global:Bool):Obj.Symbol
		throw "hxmc: wasm: no machine code";

	public function useSection(name:Null<String>) {}

	// (MirBuild rejects the intrinsics that need them on WebAssembly)
	public function stub(name:String)
		throw "hxmc: wasm: no runtime stub " + name;

	// () -> i64: hxmc_alloc_slow(lo, type index, bytes), with no locals (laid
	// out as WasmGen's functions: the signature, the body's size as a padded LEB)
	public function allocStub(name:String, lo:Int, tySym:Null<String>, tyVal:Int, bytes:Int):Bool {
		var sec = obj.section(WasmGen.SECTION, Text, 1);
		var out = sec.buf;
		var start = out.len;
		out.u8(0);
		out.u8(Enc.I64);
		var b = new Buf(32);
		var relocs:Array<{off:Int, kind:RelKind, sym:String}> = [];
		Enc.uleb(b, 0);
		b.u8(Op.I32Const);
		Enc.sleb(b, lo);
		b.u8(Op.I32Const);
		if (tySym != null) {
			relocs.push({off: b.len, kind: RWasmAddr32, sym: tySym});
			for (_ in 0...4)
				b.u8(0x80);
			b.u8(0);
		} else
			Enc.sleb(b, tyVal);
		b.u8(Op.I32Const);
		Enc.sleb(b, bytes);
		b.u8(Op.Call);
		relocs.push({off: b.len, kind: RWasmFunc, sym: "hxmc_alloc_slow"});
		Enc.uleb5(b, 0);
		b.u8(Op.End);
		Enc.uleb5(out, b.len);
		var base = out.len;
		out.buf(b);
		for (r in relocs)
			sec.relocs.push(new Reloc(base + r.off, r.kind, obj.sym(r.sym), 0));
		obj.define(name, sec, start, out.len - start, true);
		obj.sym(name).func = true;
		return true;
	}
}
