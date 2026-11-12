import hxmc.Buffer;
import hxmc.Out;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.objc.AutoreleasePool;
import hxmc.objc.Id;
import hxmc.unsafe.Int64;
import hxmc.unsafe.UInt8;

// Core Foundation's typed calls (docs/interop.md, "Objects of C"): a
// @:hxmc.safe function takes objects beside Strings and spans; an
// hxmc.Out<T> of an object is owned by a function of the Create rule
// (CFErrorRef *), borrowed otherwise (the Get rule's `const void **`); a
// Null<Span> passes NULL. Built with -D hxmc.strict.
// define: hxmc.strict
extern class CFAllocator implements Id {}
extern class CFString implements Id {}
extern class CFData implements Id {}
extern class CFError implements Id {}
extern class CFDictionary implements Id {}

@:hxmc.c @:hxmc.safe @:hxmc.framework("CoreFoundation") extern class CF {
	@:hxmc.retained static function CFStringCreateWithCString(alloc:Null<CFAllocator>, cStr:String, encoding:Int):CFString;
	static function CFStringGetLength(s:CFString):Int64;
	@:hxmc.retained @:hxmc.len(bytes, length) static function CFDataCreate(alloc:Null<CFAllocator>, bytes:ReadOnlySpan<UInt8>, length:Int64):CFData;
	@:hxmc.retained @:hxmc.len(format, 1)
	static function CFPropertyListCreateWithData(alloc:Null<CFAllocator>, data:CFData, options:Int64, format:Null<Span<Int64>>, error:Out<CFError>):Null<CFDictionary>;
	static function CFErrorGetCode(e:CFError):Int64;
	static function CFDictionaryGetValueIfPresent(d:CFDictionary, key:Id, value:Out<Id>):Bool;
	static function CFGetRetainCount(o:Id):Int64;
}

class ObjCCFTyped {
	static function data(s:String):CFData {
		var b = haxe.io.Bytes.ofString(s);
		return Buffer.scoped(b.length, buf -> {
			buf.blitFromBytes(0, b, 0, b.length);
			CF.CFDataCreate(null, ReadOnlySpan.ofBuffer(buf), b.length);
		});
	}

	static function main() {
		var kept = new Out<CFError>();
		AutoreleasePool.run(() -> {
			var s = CF.CFStringCreateWithCString(null, "héllo", 0x08000100);
			trace(CF.CFStringGetLength(s));
			var plist = '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>a</key><string>bcd</string></dict></plist>';
			var format:Int64 = 0;
			var none = new Out<CFError>();
			var dict = CF.CFPropertyListCreateWithData(null, data(plist), 0, Span.of(format), none);
			trace(dict != null, format, none.value == null);
			var v = new Out<Id>();
			trace(CF.CFDictionaryGetValueIfPresent(dict, CF.CFStringCreateWithCString(null, "a", 0x08000100), v), CF.CFStringGetLength(cast v.value));
			trace(CF.CFDictionaryGetValueIfPresent(dict, CF.CFStringCreateWithCString(null, "z", 0x08000100), v), v.value == null);
			trace(CF.CFPropertyListCreateWithData(null, data("not a plist"), 0, null, kept) == null, CF.CFErrorGetCode(kept.value));
			// (the error's: created +1, autoreleased; the Out's box's)
			trace(CF.CFGetRetainCount(kept.value));
		});
		// (the pool drained: the Out's only)
		trace(CF.CFGetRetainCount(kept.value));
	}
}
