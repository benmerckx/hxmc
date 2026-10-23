package hxmc;

import haxe.io.BytesData;

// haxe.Resource's content (--resource, Context.addResource), by index in
// genjs's order (hxmc.ir.Lower.resources). names() is a new array of the
// names as literals (FnLower); the bytes are the program's read-only data,
// each resource's once (DataGen.resources; under -D hxmc.wasm-gc a passive
// data segment each, GcModule.resourceBytes), read by the runtime
// (hxmc.rt.Bytes) only when asked for.
extern class NativeResource {
	static function names():Array<String>;
	// a copy of resource i's bytes (the caller may write it)
	static function bytes(i:Int):BytesData;
	// resource i's bytes decoded from UTF-8 (as haxe.io.Bytes.toString)
	static function string(i:Int):String;
}
