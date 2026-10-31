import hxmc.objc.AutoreleasePool;
import hxmc.objc.Id;
import hxmc.unsafe.*;

// objects of C (docs/interop.md, "Objects of C"): Core Graphics' types are
// extern classes implementing Id, without an Objective-C class; their
// values are ids, retained by Haxe's storage as any. A function of the
// Create rule is @:hxmc.retained (its result owned, autoreleased at once);
// the others' results are borrowed. A bitmap context drawn into, a path
// (the mutable type where the immutable one goes), an image of the context.
@:hxmc.struct @:publicFields class CGRect {
	var x:Float;
	var y:Float;
	var w:Float;
	var h:Float;

	function new(x:Float, y:Float, w:Float, h:Float) {
		this.x = x;
		this.y = y;
		this.w = w;
		this.h = h;
	}
}

extern class CGColorSpace implements Id {}
extern class CGColor implements Id {}
extern class CGPath implements Id {}
extern class CGMutablePath extends CGPath {}
extern class CGContext implements Id {}
extern class CGImage implements Id {}

@:hxmc.c @:hxmc.framework("CoreGraphics") extern class CG {
	@:hxmc.retained static function CGColorSpaceCreateDeviceRGB():CGColorSpace;
	@:hxmc.retained static function CGColorCreateSRGB(r:Float, g:Float, b:Float, a:Float):CGColor;
	static function CGColorGetAlpha(c:CGColor):Float;
	@:hxmc.retained static function CGPathCreateMutable():CGMutablePath;
	static function CGPathAddRect(p:CGMutablePath, m:Ptr, r:CGRect):Void;
	static function CGPathGetBoundingBox(p:CGPath):CGRect;
	@:hxmc.retained static function CGBitmapContextCreate(data:Ptr, w:UInt64, h:UInt64, bitsPerComponent:UInt64, bytesPerRow:UInt64, space:CGColorSpace,
		info:Int):CGContext;
	static function CGContextSetFillColorWithColor(c:CGContext, color:CGColor):Void;
	static function CGContextAddPath(c:CGContext, p:CGPath):Void;
	static function CGContextFillPath(c:CGContext):Void;
	static function CGBitmapContextGetData(c:CGContext):Ptr;
	@:hxmc.retained static function CGBitmapContextCreateImage(c:CGContext):CGImage;
	static function CGImageGetWidth(i:CGImage):UInt64;
	static function CGImageGetColorSpace(i:CGImage):CGColorSpace;
}

@:hxmc.c @:hxmc.framework("CoreFoundation") extern class CF {
	static function CFGetRetainCount(o:Id):Int64;
}

class ObjCCoreGraphics {
	static var kept:CGColor;
	static var image:CGImage;
	static var colors:Array<CGColor> = [];

	static function pixel(ctx:CGContext, x:Int, y:Int):String {
		var p = CG.CGBitmapContextGetData(ctx);
		var at = (y * 4 + x) * 4;
		return [for (i in 0...4) Mem.getU8(p, at + i)].join(",");
	}

	static function main() {
		AutoreleasePool.run(() -> {
			var space = CG.CGColorSpaceCreateDeviceRGB();
			// (premultiplied last: kCGImageAlphaPremultipliedLast)
			var ctx = CG.CGBitmapContextCreate(Ptr.nil(), 4, 4, 8, 16, space, 1);
			var red = CG.CGColorCreateSRGB(1, 0, 0, 1);
			var path = CG.CGPathCreateMutable();
			CG.CGPathAddRect(path, Ptr.nil(), new CGRect(1, 1, 2, 2));
			var box = CG.CGPathGetBoundingBox(path);
			trace("path", box.x, box.y, box.w, box.h);
			CG.CGContextSetFillColorWithColor(ctx, red);
			CG.CGContextAddPath(ctx, path);
			CG.CGContextFillPath(ctx);
			trace("pixels", pixel(ctx, 0, 0), pixel(ctx, 1, 1), pixel(ctx, 2, 2), pixel(ctx, 3, 3));
			// an image kept past the pool: a static holds it
			image = CG.CGBitmapContextCreateImage(ctx);
			// (a Get function's result: borrowed, not released)
			trace("image", CG.CGImageGetWidth(image).toInt(), CG.CGImageGetColorSpace(image) != null);
			// owned once by the pool, once by the static
			kept = CG.CGColorCreateSRGB(0, 0.5, 1, 0.25);
			trace("kept before the drain", CF.CFGetRetainCount(kept));
		});
		trace("kept after the drain", CF.CFGetRetainCount(kept), CG.CGColorGetAlpha(kept));
		// many made and dropped; some held by an array, by Dynamic, by a closure
		AutoreleasePool.run(() -> {
			for (i in 0...1000) {
				var c = CG.CGColorCreateSRGB(i / 1000, 0, 0, 1);
				if (i % 100 == 0) colors.push(c);
			}
		});
		var dyn:Dynamic = colors[3];
		var f = () -> CG.CGColorGetAlpha(colors[9]);
		for (_ in 0...3)
			hxmc.rt.Gc.collect(true);
		AutoreleasePool.run(() -> trace("held", colors.length, CF.CFGetRetainCount(colors[0]), CG.CGColorGetAlpha(dyn), f(), CG.CGImageGetWidth(image).toInt()));
		// the last holders gone: freed (zombies catch a release too many)
		colors = [];
		dyn = null;
		kept = null;
		for (_ in 0...3)
			hxmc.rt.Gc.collect(true);
		trace("done");
	}
}
