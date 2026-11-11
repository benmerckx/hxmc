// not-live: hxmc.rt.Gc.minorCompact hxmc.rt.Gc.parCompactMinor hxmc.rt.Gc.parCompactMajor hxmc.rt.Gc.storeCompact
// A program without @:hxmc.compact classes has none of the collector's code
// for compressed references (docs/hxmc.md, "Compressed references"): Mem.compact
// is a constant 0 (hxmc.Main.generate), so the tests of hxmc.rt.GcCore.compactTypes
// fold away, and with them the calls of the scans of compressed references and
// of the runtime's store of one (Dyn.storeSlot): reachability drops them. The
// objects here are as CompactGc's (old ones referring to young ones by compiled
// stores and by reflection, through minor and major collections), with 8-byte
// references.
class Node {
	public var id:Int;
	public var next:Node;
	public var other:Node;
	public var tag:String;

	public function new(id:Int, next:Node) {
		this.id = id;
		this.next = next;
		tag = "n" + id;
	}
}

class CompactFree {
	static function main() {
		var nodes = [for (i in 0...2000) new Node(i, null)];
		var seed = 12345;
		inline function rnd(n:Int):Int {
			seed = (seed * 1103515245 + 12345) & 0x7fffffff;
			return seed % n;
		}
		for (round in 0...6) {
			// (garbage in between: the old nodes refer to young ones)
			for (k in 0...4000) {
				var i = rnd(nodes.length);
				var fresh = new Node(nodes.length + k, nodes[rnd(nodes.length)]);
				if (k & 1 == 0) nodes[i].other = fresh else Reflect.setField(nodes[i], "other", fresh);
				var junk = [for (j in 0...8) "x" + j];
				if (junk.length != 8) throw "junk";
			}
			var bad = 0;
			for (n in nodes)
				if (n.other != null && (n.other.tag != "n" + n.other.id || (n.other.next != null && n.other.next.tag != "n" + n.other.next.id))) bad++;
			trace('round $round: bad=$bad');
		}
		var sum = 0.0;
		var chain:Node = null;
		for (i in 0...100000)
			chain = new Node(i, chain);
		while (chain != null) {
			sum += chain.id;
			chain = chain.next;
		}
		trace("chain: " + sum);
	}
}
