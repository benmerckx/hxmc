// The raw-address check follows a view of a heap object into a struct value: a view of the maps' index (hxmc.rt.MapIndex) must not live across a GC point.
// expect: RawView.hx:6: RawView.main: a raw heap address (Mem.addr) in st is live across the allocation of an array
class RawView {
	static var keep:Array<Int>;

	static function main() {
		var a = new hxmc.rt.MapSlots<Int>(16);
		var v = a.index(0, 7);
		keep = [1, 2, 3];
		hxmc.rt.MapIndex.insert(v, 3, 3, 0);
		trace(a[7]);
	}
}
