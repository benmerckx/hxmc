package hxmc.rt;

import hxmc.rt.C;

// What the faulting instruction calls (Faults.redirect, natively), and what the
// explicit tests of a reference call when it is null (MirBuild.nullCheck:
// WebAssembly in linear memory, -D hxmc.null-checks=1): the message is
// Eval's for most null accesses (its field reads say "field access on
// null"). The value thrown is the literal: nothing is allocated before
// the handler runs. Its own module, loaded into every program (Runtime):
// a test may be in any function, Faults is the native targets' only, and
// WasmGC has its own (GcNative).
@:keep @:allow(hxmc.rt)
class NullAccess {
	@:hxmc.export("rt_null_access") static function nullAccess():Void
		Rt.rt_throw("Null Access");
}
