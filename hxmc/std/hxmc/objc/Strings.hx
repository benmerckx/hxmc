package hxmc.objc;

import hxmc.rt.Repr;
import hxmc.rt.Str;
import hxmc.unsafe.*;

// Haxe strings and NSStrings (CFStrings: toll-free bridged), unit for unit:
// both are UTF-16, kept one byte per unit when every unit fits (Latin-1),
// so neither direction goes through UTF-8 (which would also change a lone
// surrogate, a string's U+DC80 to U+DCFF bytes included). Ids as Ptr (a
// cast makes one an NSString of the declarations: `cast Strings.toNSString(s)`)
@:access(hxmc.rt.Str)
class Strings {
	static inline var LATIN1 = 0x0201; // kCFStringEncodingISOLatin1

	// an NSString of s (null: nil), autoreleased as every id a value is
	public static function toNSString(s:Null<String>):Ptr {
		if (s == null) return Ptr.nil();
		var n:I64 = Str.len(s);
		// (no GC point from the address of the units to the copy)
		var r = Str.isOne(s) ? CF.CFStringCreateWithBytes(Ptr.nil(), Str.chars1(s), n, LATIN1, false) : CF.CFStringCreateWithCharacters(Ptr.nil(),
			Str.chars2(s), n);
		return Rt.objc_autorelease(r);
	}

	// the string of an NSString (nil: null)
	public static function ofNSString(ns:Ptr):Null<String> {
		if (ns.isNull()) return null;
		var n = CF.CFStringGetLength(ns).toInt();
		var latin1 = CF.CFStringGetCStringPtr(ns, LATIN1);
		if (!latin1.isNull()) {
			var r = Str.make1(n);
			if (n > 0) LibC.memcpy(Str.chars1(r), latin1, (n : I64));
			return r;
		}
		var r = Str.make2(n);
		if (n > 0) CF.CFStringGetCharacters(ns, new CFRange(0, n), Str.chars2(r));
		return Repr.fitsOne(Str.chars2(r), 0, n) ? Str.range(r, 0, n) : r;
	}
}

@:hxmc.struct private class CFRange {
	public var location:I64;
	public var length:I64;

	public inline function new(location:I64, length:I64) {
		this.location = location;
		this.length = length;
	}
}

// (fast: the copies read and write the units in the heap, no collection may
// move them meanwhile; short, and never calling Haxe unless a Haxe class
// extends NSString)
@:hxmc.c @:hxmc.lib("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation") private extern class CF {
	@:hxmc.fast static function CFStringCreateWithBytes(alloc:Ptr, bytes:Ptr, numBytes:I64, encoding:Int, isExternal:Bool):Ptr;
	@:hxmc.fast static function CFStringCreateWithCharacters(alloc:Ptr, chars:Ptr, numChars:I64):Ptr;
	static function CFStringGetLength(s:Ptr):I64;
	static function CFStringGetCStringPtr(s:Ptr, encoding:Int):Ptr;
	@:hxmc.fast static function CFStringGetCharacters(s:Ptr, range:CFRange, buffer:Ptr):Void;
}

@:hxmc.c @:hxmc.lib("/usr/lib/libobjc.A.dylib") private extern class Rt {
	static function objc_autorelease(o:Ptr):Ptr;
}
