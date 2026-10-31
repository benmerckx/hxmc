import hxmc.objc.AutoreleasePool;
import hxmc.unsafe.Int64;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableArray extends NSObject {
	static function alloc():NSMutableArray;
	override function init():NSMutableArray;
	function addObject(o:NSObject):Void;
	function objectAtIndex(i:Int64):NSObject;
}

class Peer extends NSObject {
	public var tag:String;
	public function new(tag) this.tag = tag;
}

class ObjCIdentity {
	static function main() AutoreleasePool.run(() -> {
		var o = NSObject.alloc().init();
		var arr:Array<NSObject> = [NSObject.alloc().init(), o];
		trace("indexOf: " + arr.indexOf(o));
		var m = new Map<NSObject, String>();
		m[o] = "a";
		m[o] = "b";
		trace("map: " + m[o] + ", " + [for (k in m.keys()) k].length + " key");
		var d1:Dynamic = o, d2:Dynamic = o;
		trace("Dynamic ==: " + (d1 == d2));

		// a Haxe class's instance coming back from Objective-C as an id
		var p = new Peer("p");
		var objs:Array<NSObject> = [p];
		var ns = NSMutableArray.alloc().init();
		ns.addObject(p);
		var back = ns.objectAtIndex(0);
		trace("peer through Objective-C: indexOf " + objs.indexOf(back) + ", same object " + ((back : Dynamic) == (p : Dynamic)));

		// many boxes, moved by collections
		var many = [for (i in 0...10000) NSObject.alloc().init()];
		var boxed:Array<NSObject> = [for (x in many) x];
		for (_ in 0...2) hxmc.rt.Gc.collect(true);
		var ok = 0;
		for (i in 0...many.length) if (boxed.indexOf(many[i]) == i) ok++;
		trace("after collections: " + ok + " of " + many.length);
	});
}
