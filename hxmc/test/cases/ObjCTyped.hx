import haxe.io.Bytes;
import hxmc.Buffer;
import hxmc.Out;
import hxmc.ReadOnlySpan;
import hxmc.Span;
import hxmc.objc.AutoreleasePool;
import hxmc.objc.Id;
import hxmc.unsafe.Int64;
import hxmc.unsafe.UInt8;

// Typed messages (docs/interop.md, "Typed messages"): a String is `const
// char *` (a property's too), a span passes its address with @:hxmc.len
// naming its count, Span.of and ReadOnlySpan.of are out- and in-parameters,
// a function type @:hxmc.callback names is a C function pointer (a block
// otherwise), hxmc.Out<T> an `NSError **` or `id *` (borrowed, as ARC's
// __autoreleasing). Built with -D hxmc.strict: no raw memory left.
// define: hxmc.strict
@:hxmc.struct @:publicFields class NSRange {
	var location:Int64;
	var length:Int64;

	inline function new(location:Int64, length:Int64) {
		this.location = location;
		this.length = length;
	}
}

@:hxmc.objc extern class NSObject implements Id {
	static function alloc():NSObject;
	function init():NSObject;
	function description():NSString;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	static function stringWithUTF8String(s:String):Null<NSString>;
	function UTF8String():String;
	var lowercaseString(default, never):NSString;
	@:selector("UTF8String") function utf8():String;
	function length():Int64;
	@:hxmc.len(startPtr, 1) @:hxmc.len(end, 1) @:hxmc.len(contentsEnd, 1)
	function getLineStart(startPtr:Span<Int64>, end:Span<Int64>, contentsEnd:Span<Int64>, forRange:NSRange):Void;
	static function stringWithContentsOfFile(path:NSString, encoding:Int64, error:Out<NSError>):Null<NSString>;
	function writeToFile(path:NSString, atomically:Bool, encoding:Int64, error:Out<NSError>):Bool;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSError extends NSObject {
	function code():Int64;
	function domain():NSString;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSData extends NSObject {
	@:hxmc.len(bytes, length) static function dataWithBytes(bytes:Null<ReadOnlySpan<UInt8>>, length:Int64):NSData;
	function length():Int64;
	@:hxmc.fast @:hxmc.len(buffer, length) function getBytes(buffer:Span<UInt8>, length:Int64):Void;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSValue extends NSObject {
	@:hxmc.len(value, 1) static function valueWithBytes(value:ReadOnlySpan<NSRange>, objCType:String):NSValue;
	function rangeValue():NSRange;
	var objCType(default, never):String;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSNumber extends NSObject {
	static function numberWithInt(v:Int):NSNumber;
	function intValue():Int;
	function boolValue():Bool;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSArray extends NSObject {
	@:hxmc.nilTerminated static function arrayWithObjects(firstObj:Null<NSObject>, ...rest:NSObject):NSArray;
	function count():Int64;
	function objectAtIndex(i:Int64):NSObject;
	@:hxmc.callback(comparator)
	function sortedArrayUsingFunction(comparator:(a:NSNumber, b:NSNumber, context:hxmc.I64) -> Int64, context:hxmc.I64):NSArray;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSURL extends NSObject {
	static function fileURLWithPath(path:NSString):NSURL;
	function getResourceValue(value:Out<Id>, forKey:NSString, error:Out<NSError>):Bool;
}

class ObjCTyped {
	static var kept:Out<NSError>;

	@:hxmc.callback static function descending(a:NSNumber, b:NSNumber, context:hxmc.I64):Int64 {
		var d = b.intValue() - a.intValue();
		return d < 0 ? -1 : d > 0 ? 1 : 0;
	}

	static function ns(s:String):NSString
		return NSString.stringWithUTF8String(s);

	static function main() {
		AutoreleasePool.run(() -> {
			// Strings: `const char *` both ways, a property's too
			var s = ns("héllo, wörld\nline two");
			trace(s.length(), s.UTF8String().length, s.utf8() == s.UTF8String(), ns("ABC").lowercaseString.UTF8String());
			// out-parameters from GC code
			var start:Int64 = 0, end:Int64 = 0, contents:Int64 = 0;
			s.getLineStart(Span.of(start), Span.of(end), Span.of(contents), new NSRange(15, 1));
			trace(start, end, contents);
			var v = NSValue.valueWithBytes(ReadOnlySpan.of(new NSRange(3, 4)), "{_NSRange=QQ}");
			var r = v.rangeValue();
			trace(r.location, r.length, v.objCType);
			// spans of a Buffer and of a Bytes (a fast message), a null span
			var b = new Buffer(4);
			for (i in 0...4)
				b.set(i, 65 + i);
			var data = NSData.dataWithBytes(ReadOnlySpan.ofBuffer(b), 4);
			var back = Bytes.alloc(3);
			data.getBytes(Span.ofBytes(back), 3);
			b.close();
			trace(data.length(), back.toString(), NSData.dataWithBytes(null, 0).length());
			// NSError **: borrowed, kept by the Out
			var error = new Out<NSError>();
			trace(NSString.stringWithContentsOfFile(ns("/nonexistent/x"), 4, error) == null, error.value.code(), error.value.domain().UTF8String());
			kept = error;
			var ok = new Out<NSError>();
			trace(s.writeToFile(ns("/tmp/hxmc-objc-typed.txt"), true, 4, ok), ok.value == null,
				NSString.stringWithContentsOfFile(ns("/tmp/hxmc-objc-typed.txt"), 4, ok).length());
			// id *: an NSNumber
			var dir = new Out<Id>();
			trace(NSURL.fileURLWithPath(ns("/")).getResourceValue(dir, ns("NSURLIsDirectoryKey"), null), (cast dir.value : NSNumber).boolValue());
			// a C function pointer
			var a = NSArray.arrayWithObjects(NSNumber.numberWithInt(2), NSNumber.numberWithInt(7), NSNumber.numberWithInt(5));
			var sorted = a.sortedArrayUsingFunction(descending, 0);
			trace([for (i in 0...sorted.count()) (cast sorted.objectAtIndex(i) : NSNumber).intValue()]);
		});
		hxmc.rt.Gc.collect(true);
		trace(kept.value.code());
	}
}
