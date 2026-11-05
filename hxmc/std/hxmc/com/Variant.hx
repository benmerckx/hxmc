package hxmc.com;

import hxmc.unsafe.*;

// A VARIANT (oaidl.h; docs/interop.md, "COM"): 24 bytes on the 64-bit
// targets, its type (vt) then its value, in a struct value as C has it (by
// value or behind a Ptr in COM methods' signatures). Variants makes and
// reads the common types; a variant holding a BSTR or an interface owns it
// (clear frees it: VariantClear). As any struct value, a copy is the same
// bytes: clear one of them once.
@:hxmc.struct class Variant {
	public var vt:UInt16;
	var reserved1:UInt16;
	var reserved2:UInt16;
	var reserved3:UInt16;
	// the value (lVal, dblVal, boolVal, bstrVal, punkVal: the first bytes)
	public var value:Int64;
	var record:Int64;

	public function new() {}
}
