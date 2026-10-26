package hxmc.rt.gc;

import hxmc.rt.gc.GcRepr.GcStringBuf;

// -D hxmc.wasm-gc: what linear memory's generated code does inline (string
// equality, StringBuf.addChar's common case); the rest of the strings is
// hxmc.rt.Str's
@:keep @:hxmc.wasmgc
class GcStr {
	@:hxmc.host("hx_str_eq") @:hxmc.unsafe static function eq(a:String, b:String):Bool {
		if (W.isNull(a) || W.isNull(b)) return W.isNull(a) && W.isNull(b);
		var n = W.strLen(a);
		if (n != W.strLen(b)) return false;
		for (i in 0...n)
			if (W.strGet(a, i) != W.strGet(b, i)) return false;
		return true;
	}

	@:hxmc.host("StringBuf_addChar") static function sbAddChar(b:Dynamic, c:Int):Void {
		var g:GcStringBuf = b;
		if (c < 0x10000 && g.len < W.strLen(g.chars)) W.strSet(g.chars, g.len++, c) else @:privateAccess hxmc.rt.Str.sbAddCharSlow(b, c);
	}
}
