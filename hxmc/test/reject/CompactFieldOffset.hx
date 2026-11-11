// A compressed reference (@:hxmc.compact) has no 8-byte slot whose address
// atomics or the runtime's registrations could take.
// expect: Struct.fieldOffset: Node.next is a compressed reference (@:hxmc.compact
@:hxmc.compact
class Node {
	public var next:Node;

	public function new() {}
}

class CompactFieldOffset {
	static function main()
		trace(hxmc.unsafe.Struct.fieldOffset(new Node(), "next"));
}
