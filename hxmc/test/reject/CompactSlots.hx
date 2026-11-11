// A @:hxmc.compact class has at most 32 slots (the collector's one word of
// its compact map), its subclasses too, on every target.
// expect: Big is @:hxmc.compact (as its superclass is) and has 33 slots: at most 32
@:hxmc.compact
class Small {
	public var a:Small;

	public function new() {}
}

class Big extends Small {
	public var f0:Float; public var f1:Float; public var f2:Float; public var f3:Float; public var f4:Float;
	public var f5:Float; public var f6:Float; public var f7:Float; public var f8:Float; public var f9:Float;
	public var f10:Float; public var f11:Float; public var f12:Float; public var f13:Float; public var f14:Float;
	public var f15:Float; public var f16:Float; public var f17:Float; public var f18:Float; public var f19:Float;
	public var f20:Float; public var f21:Float; public var f22:Float; public var f23:Float; public var f24:Float;
	public var f25:Float; public var f26:Float; public var f27:Float; public var f28:Float; public var f29:Float;
	public var f30:Float; public var f31:Float;
}

class CompactSlots {
	static function main()
		trace(new Big().a);
}
