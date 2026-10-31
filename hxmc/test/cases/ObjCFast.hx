import hxmc.objc.AutoreleasePool;
import hxmc.unsafe.*;

// @:hxmc.fast messages (docs/interop.md, "Calls"): sent without a safe
// region, as a fast C function is called; one Objective-C answers by
// calling back into Haxe (containsObject: sends isEqual: to Haxe objects,
// which allocate) leaves its caller running as before, so what the caller
// allocates next is safe.
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject implements hxmc.objc.Id {
	function isEqual(o:NSObject):Bool;
	@:hxmc.fast function hash():Int64;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableArray extends NSObject {
	static function array():NSMutableArray;
	function addObject(o:NSObject):Void;
	@:hxmc.fast function containsObject(o:NSObject):Bool;
	@:hxmc.fast function count():Int64;
}

class Item extends NSObject {
	public static var compared = 0;

	public var name:String;

	public function new(name:String)
		this.name = name;

	override function isEqual(o:NSObject):Bool {
		compared++;
		var other = Std.downcast((cast o : Item), Item);
		// (allocating: a collection may run inside the fast message)
		var tag = [for (i in 0...20) name + i].join("");
		return other != null && other.name == name && tag.length > 0;
	}

	override function hash():Int64
		return name.length;
}

class ObjCFast {
	static function main() AutoreleasePool.run(() -> {
		var arr = NSMutableArray.array();
		for (i in 0...30)
			arr.addObject(new Item("item" + i));
		var found = 0, corrupt = 0;
		for (round in 0...300) {
			if (arr.containsObject(new Item("item" + (round % 40)))) found++;
			// Haxe work after the fast message: objects a collection must not move under it
			var xs = [for (i in 0...100) {n: i, s: "v" + i}];
			var sum = 0;
			for (x in xs) {
				if (x.s != "v" + x.n) corrupt++;
				sum += x.n;
			}
			if (sum != 4950) corrupt++;
		}
		var h:Int64 = 0;
		for (_ in 0...1000)
			h += (cast arr : NSObject).hash();
		trace("found " + found + ", corrupt " + corrupt + ", count " + arr.count().toInt() + ", isEqual called " + (Item.compared > 0) + ", hash " + (h > 0));
	});
}
