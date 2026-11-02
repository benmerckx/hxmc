import hxmc.I64;
import hxmc.objc.AutoreleasePool;
import hxmc.objc.Id;
import hxmc.objc.Strings;
import hxmc.unsafe.*;

// lightweight generics: type parameters bound to Objective-C objects (Id,
// or a class or protocol), whose values are ids; their default (Id) where
// none is given; invariant (a mutable array of strings takes no other
// object), an immutable one widened by `upcast`

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject implements Id {
	static function alloc():NSObject;
	function init():NSObject;
	function isEqual(o:NSObject):Bool;
	function hash():I64;
}

@:hxmc.objc extern interface NSCopying extends Id {
	function copyWithZone(zone:Ptr):Id;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject implements NSCopying {
	function copyWithZone(zone:Ptr):Id;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSArray<ObjectType:Id = Id> extends NSObject {
	static function arrayWithObject<ObjectType:Id>(o:ObjectType):NSArray<ObjectType>;
	function objectAtIndex(i:I64):ObjectType;
	function count():I64;
	function arrayByAddingObject(o:ObjectType):NSArray<ObjectType>;
	function firstObjectCommonWithArray(other:NSArray<ObjectType>):Null<ObjectType>;
	// (covariant: an array of a subtype one of the supertype)
	static inline function upcast<T:U, U:Id>(a:NSArray<T>):NSArray<U>
		return cast a;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableArray<ObjectType:Id = Id> extends NSArray<ObjectType> {
	static function alloc<ObjectType:Id>():NSMutableArray<ObjectType>;
	override function init():NSMutableArray<ObjectType>;
	function addObject(o:ObjectType):Void;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableDictionary<KeyType:NSCopying = NSCopying, ObjectType:Id = Id> extends NSObject {
	static function alloc<KeyType:NSCopying, ObjectType:Id>():NSMutableDictionary<KeyType, ObjectType>;
	function init():NSMutableDictionary<KeyType, ObjectType>;
	function setObject(o:ObjectType, forKey:KeyType):Void;
	function objectForKey(key:KeyType):Null<ObjectType>;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSValue extends NSObject {}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSNumber extends NSValue {
	static function numberWithInt(i:Int):NSNumber;
	function intValue():Int;
}

class Mine extends NSObject {
	public var n:Int;

	public function new(n)
		this.n = n;
}

// a Haxe key: NSCopying, copied by the dictionary
class Key extends NSObject implements NSCopying {
	public var name:String;

	public function new(name)
		this.name = name;

	public function copyWithZone(zone:Ptr):Id
		return new Key(name);

	override function isEqual(o:NSObject):Bool {
		var k = Std.downcast(o, Key);
		return k != null && k.name == name;
	}

	override function hash():I64
		return name.length;
}

// Haxe code generic over Objective-C objects
class Box<T:Id> {
	public var items:Array<T> = [];
	public var last:Null<T>;

	public function new() {}

	public function add(x:T) {
		items.push(x);
		last = x;
	}
}

class ObjCGenerics {
	static function ns(s:String):NSString
		return cast Strings.toNSString(s);

	static function first<T:Id>(a:NSArray<T>):T
		return a.objectAtIndex(0);

	static function countValues(a:NSArray<NSValue>)
		return a.count();

	static function main() AutoreleasePool.run(() -> {
		// an element type, inferred and given
		var strings = NSArray.arrayWithObject(ns("x")).arrayByAddingObject(ns("y"));
		var s:NSString = strings.objectAtIndex(1);
		trace("strings: " + Strings.ofNSString(cast s) + " " + strings.count());
		// the default: any object
		var any:NSArray = NSArray.upcast(strings);
		trace("any: " + any.count() + " " + Std.isOfType(any.objectAtIndex(0), NSString) + " " + Std.isOfType(any.objectAtIndex(0), Id));

		// Haxe objects in a typed array, out of it as themselves
		var mine = NSArray.arrayWithObject(new Mine(7));
		trace("mine: " + mine.objectAtIndex(0).n + " " + first(mine).n + " " + (mine.firstObjectCommonWithArray(mine) == first(mine)));

		// a mutable one, its element type from where it goes
		var ma:NSMutableArray<Mine> = NSMutableArray.alloc().init();
		ma.addObject(new Mine(3));
		var loose = NSMutableArray.alloc().init();
		loose.addObject(new Mine(4));
		trace("mutable: " + ma.objectAtIndex(0).n + " " + loose.objectAtIndex(0).n + " " + NSMutableArray.alloc().init().count());

		// covariance: numbers as values
		var numbers = NSArray.arrayWithObject(NSNumber.numberWithInt(1)).arrayByAddingObject(NSNumber.numberWithInt(2));
		trace("values: " + countValues(NSArray.upcast(numbers)) + " " + numbers.objectAtIndex(1).intValue());

		// a dictionary keyed by a protocol's objects (Haxe ones, copied)
		var d:NSMutableDictionary<Key, Mine> = NSMutableDictionary.alloc().init();
		d.setObject(new Mine(11), new Key("k"));
		for (_ in 0...2)
			hxmc.rt.Gc.collect(true);
		var found = d.objectForKey(new Key("k"));
		trace("dictionary: " + (found != null ? found.n : -1) + " " + (d.objectForKey(new Key("other")) == null));

		// Haxe code over T:Id, kept across collections
		var box = new Box<Mine>();
		box.add(new Mine(5));
		box.add(first(mine));
		for (_ in 0...2)
			hxmc.rt.Gc.collect(true);
		var f:Mine->Int = x -> x.n;
		var dyn:Dynamic = box.last;
		trace("box: " + box.items[0].n + " " + f(box.items[1]) + " " + (box.items[1] == first(mine)) + " " + (dyn : Mine).n);
		var copies = new Box<NSCopying>();
		copies.add(ns("c"));
		copies.add(new Key("q"));
		trace("protocol box: " + copies.items.length + " " + Std.isOfType(copies.items[1], Key));
	});
}
