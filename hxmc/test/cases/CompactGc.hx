import hxmc.NativeGc;

// The collector against @:hxmc.compact objects (docs/hxmc.md, "Compressed
// references"): a graph of them rewired at random (a deterministic
// generator), old objects made to refer to young ones by compiled stores and
// by reflection (the write barrier remembers a compressed reference's 4
// bytes), checked against a copy of its edges kept as indices, through many
// minor and some major collections (the corpus' small nurseries, RT_VERIFY).
// Wide's 40 compressed references take the halves past 32 (the compact map's
// second word); Pair's compressed reference shares its slot with an Int.
@:hxmc.compact
class Wide {
	public var id:Int;
	public var r0:Wide; public var r1:Wide; public var r2:Wide; public var r3:Wide; public var r4:Wide;
	public var r5:Wide; public var r6:Wide; public var r7:Wide; public var r8:Wide; public var r9:Wide;
	public var r10:Wide; public var r11:Wide; public var r12:Wide; public var r13:Wide; public var r14:Wide;
	public var r15:Wide; public var r16:Wide; public var r17:Wide; public var r18:Wide; public var r19:Wide;
	public var r20:Wide; public var r21:Wide; public var r22:Wide; public var r23:Wide; public var r24:Wide;
	public var r25:Wide; public var r26:Wide; public var r27:Wide; public var r28:Wide; public var r29:Wide;
	public var r30:Wide; public var r31:Wide; public var r32:Wide; public var r33:Wide; public var r34:Wide;
	public var r35:Wide; public var r36:Wide; public var r37:Wide; public var r38:Wide;
	public var tag:String;

	public function new(id:Int) {
		this.id = id;
		tag = "w" + id;
	}
}

@:hxmc.compact
class Pair {
	public var n:Int;
	public var other:Pair;

	public function new(n:Int, other:Pair) {
		this.n = n;
		this.other = other;
	}
}

class CompactGc {
	static var seed = 12345;

	static function rnd(n:Int):Int {
		seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
		return (seed >> 8) % n;
	}

	static inline var N = 600;
	static inline var R = 39;

	static function main() {
		var nodes = [for (i in 0...N) new Wide(i)];
		// (edges[i * R + k]: the index of node i's field r<k>, -1 for null)
		var edges = [for (_ in 0...N * R) -1];
		var fields = [for (k in 0...R) "r" + k];
		var fresh = N;
		var bad = 0;

		function check(when:String) {
			for (i in 0...N) {
				var w = nodes[i];
				if (w.tag != "w" + w.id) bad++;
				for (k in 0...R) {
					var v:Wide = Reflect.field(w, fields[k]);
					var e = edges[i * R + k];
					if (e < 0 ? v != null : v != nodes[e]) bad++;
				}
				// (the compiled reads of the first and the last)
				if ((edges[i * R] < 0 ? w.r0 != null : w.r0 != nodes[edges[i * R]]) || (edges[i * R + 38] < 0 ? w.r38 != null : w.r38 != nodes[edges[i * R + 38]])) bad++;
			}
			trace(when + ": bad=" + bad);
		}

		for (round in 0...8) {
			for (step in 0...20000) {
				var i = rnd(N), j = rnd(N), k = rnd(R);
				var op = rnd(64);
				switch op < 8 ? op : op < 16 ? 1 : op < 24 ? 2 : op < 32 ? 3 : op < 40 ? 4 : 5 {
					case 0 if (op == 0):
						// a young node in i's place (the old ones' fields then refer to it)
						var w = new Wide(nodes[i].id);
						nodes[i] = w;
						for (kk in 0...R) {
							var e = edges[i * R + kk];
							Reflect.setField(w, fields[kk], e < 0 ? null : nodes[e]);
						}
						for (x in 0...N)
							for (kk in 0...R)
								if (edges[x * R + kk] == i) Reflect.setField(nodes[x], fields[kk], w);
					case 1:
						Reflect.setField(nodes[i], fields[k], null);
						edges[i * R + k] = -1;
					case 2:
						nodes[i].r0 = nodes[j];
						edges[i * R] = j;
					case 3:
						nodes[i].r38 = nodes[j];
						edges[i * R + 38] = j;
					case 4:
						nodes[i].r20 = nodes[j];
						edges[i * R + 20] = j;
					case _:
						Reflect.setField(nodes[i], fields[k], nodes[j]);
						edges[i * R + k] = j;
				}
				// garbage: minor collections
				if (step % 2 == 0) new Wide(fresh++);
			}
			check("round " + round);
			NativeGc.collect(round % 3 == 2);
		}
		check("after");

		// a ring of pairs, each old one's reference set to a young one, garbage between
		var ring = [for (i in 0...2000) new Pair(i, null)];
		NativeGc.collect(true);
		for (round in 0...4) {
			for (i in 0...ring.length) {
				var p = new Pair(ring[i].n + 1, ring[(i + 1) % ring.length]);
				ring[(i + 1) % ring.length].other = p;
				for (_ in 0...20)
					new Pair(-1, p);
			}
			var sum = 0, okRing = 0;
			for (i in 0...ring.length) {
				sum += ring[i].other.n;
				if (ring[i].other.other == ring[i]) okRing++;
			}
			trace("ring " + round + ": " + sum + " " + okRing);
		}
	}
}
