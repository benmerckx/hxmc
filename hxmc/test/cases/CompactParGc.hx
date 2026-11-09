import hxmc.NativeGc;

// The parallel collections (docs/hxmc.md, "Garbage collection") against
// @:hxmc.compact objects: four threads, each rewiring a graph of them at random
// (a deterministic generator per thread) by compiled stores and by reflection,
// so that every thread's remembered set holds compressed references' 4-byte
// slots, checked against a copy of the edges kept as indices, while all of
// them allocate garbage. With a nursery of a megabyte or more (Tiers' lane
// "CompactParGc adaptive", RT_MINOR_KB unset) its minor and major collections
// copy in parallel (parScanYoung's compact map, parRemembered's tagged slots);
// the corpus' small nursery collects serially.
@:hxmc.compact
class Node {
	public var id:Int;
	public var a:Node;
	public var b:Node;
	public var c:Node;
	public var d:Node;
	public var e:Node;
	public var f:Node;
	public var g:Node;
	public var h:Node;
	public var r0:Node; public var r1:Node; public var r2:Node; public var r3:Node; public var r4:Node;
	public var r5:Node; public var r6:Node; public var r7:Node; public var r8:Node; public var r9:Node;
	public var r10:Node; public var r11:Node; public var r12:Node; public var r13:Node; public var r14:Node;
	public var r15:Node; public var r16:Node; public var r17:Node; public var r18:Node; public var r19:Node;
	public var r20:Node; public var r21:Node; public var r22:Node; public var r23:Node; public var r24:Node;
	public var r25:Node; public var r26:Node; public var r27:Node; public var r28:Node; public var r29:Node;
	public var tag:String;

	public function new(id:Int) {
		this.id = id;
		tag = "n" + id;
	}
}

class CompactParGc {
	static inline var N = 4000;
	static inline var R = 38;
	static final FIELDS = ["a", "b", "c", "d", "e", "f", "g", "h"].concat([for (k in 0...30) "r" + k]);

	static function work(t:Int):String {
		var seed = 777 + 31 * t;
		inline function rnd(n:Int):Int {
			seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
			return (seed >> 8) % n;
		}
		var nodes = [for (i in 0...N) new Node(i)];
		var edges = [for (_ in 0...N * R) -1];
		var bad = 0;
		var sink = [for (_ in 0...64) (null : Node)];
		var fresh = N;
		for (round in 0...6) {
			for (step in 0...60000) {
				var i = rnd(N), j = rnd(N), k = rnd(R);
				switch rnd(16) {
					case 0 if (rnd(64) == 0):
						// a young node in i's place, the old ones referring to it
						var w = new Node(nodes[i].id);
						for (kk in 0...R) {
							var e = edges[i * R + kk];
							Reflect.setField(w, FIELDS[kk], e < 0 ? null : nodes[e]);
						}
						nodes[i] = w;
						for (x in 0...N) {
							var base = x * R;
							for (kk in 0...R)
								if (edges[base + kk] == i) Reflect.setField(nodes[x], FIELDS[kk], w);
						}
					case 1 | 2:
						Reflect.setField(nodes[i], FIELDS[k], null);
						edges[i * R + k] = -1;
					case 3 | 4 | 5:
						nodes[i].a = nodes[j];
						edges[i * R] = j;
					case 6 | 7 | 8:
						nodes[i].r29 = nodes[j];
						edges[i * R + 37] = j;
					case 9 | 10:
						nodes[i].h = nodes[j];
						edges[i * R + 7] = j;
					case _:
						Reflect.setField(nodes[i], FIELDS[k], nodes[j]);
						edges[i * R + k] = j;
				}
				// garbage, some of it referring to the graph (young to old) and kept a while
				var gnode = new Node(fresh++);
				gnode.a = nodes[j];
				sink[step & 63] = gnode;
				if (step % 3 == 0) new Node(-1).b = gnode;
			}
			for (i in 0...N) {
				var w = nodes[i];
				if (w.tag != "n" + w.id) bad++;
				for (k in 0...R) {
					var v:Node = Reflect.field(w, FIELDS[k]);
					var e = edges[i * R + k];
					if (e < 0 ? v != null : v != nodes[e]) bad++;
				}
				if ((edges[i * R] < 0 ? w.a != null : w.a != nodes[edges[i * R]])
					|| (edges[i * R + 37] < 0 ? w.r29 != null : w.r29 != nodes[edges[i * R + 37]]))
					bad++;
			}
			if (round % 3 == 2) NativeGc.collect(true);
		}
		var live = 0;
		for (s in sink)
			if (s != null && s.a != null) live++;
		return 'thread $t: bad=$bad sink=$live';
	}

	static function main() {
		var lock = new sys.thread.Lock();
		var results = [for (_ in 0...4) ""];
		for (t in 0...4)
			sys.thread.Thread.create(() -> {
				results[t] = work(t);
				lock.release();
			});
		for (_ in 0...4)
			lock.wait();
		for (r in results)
			trace(r);
	}
}
