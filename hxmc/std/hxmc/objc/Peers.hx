package hxmc.objc;

// The Haxe objects paired with Objective-C ones (instances of Haxe classes
// extending Objective-C classes; docs/interop.md, "Objective-C").
class Peers {
	// o gives up its hold on its Objective-C object now, as when it is
	// collected: the object is deallocated as soon as Objective-C lets go of
	// it (a view out of its window), not once a collection finds o dead. From
	// here on, messages through o go to nil (nothing happens; results are
	// zero); calls Objective-C still makes into o's class reach o while its
	// object lives. For an owner that knows an object is done with (a UI
	// library's unmounted view). Anything else: nothing. (o is Dynamic, not
	// Id: an id argument is borrowed, autoreleased, which would keep the
	// object until the current pool drains)
	public static function detach(o:Dynamic):Void
		@:privateAccess hxmc.rt.Gc.detach(o);
}
