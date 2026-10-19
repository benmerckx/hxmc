// haxe.ds.Vector.blit (hxmc.NativeArray.blit, hxmc.rt.NArray.move):
// Float, Int, Bool, String, struct and Dynamic elements, a few (copied
// inline) and many (moved by the runtime), between vectors and within one
// in both directions (overlapping), zero and negative lengths, from generic
// code (a NativeArray of any kind seen through Dynamic), Dynamic elements
// within one vector; references moved into and within an old vector, kept
// across collections (the barrier), and Vector.copy.
import haxe.ds.Vector;

@:hxmc.struct @:publicFields class P2 {
	var x:Float;
	var y:Float;

	inline function new(x = 0.0, y = 0.0) {
		this.x = x;
		this.y = y;
	}
}

class VectorBlit {
	static function floats(n:Int):Vector<Float> {
		var v = new Vector<Float>(n);
		for (i in 0...n)
			v[i] = i + 0.5;
		return v;
	}

	static function ints(n:Int):Vector<Int> {
		var v = new Vector<Int>(n);
		for (i in 0...n)
			v[i] = i;
		return v;
	}

	static function strs(n:Int):Vector<String> {
		var v = new Vector<String>(n);
		for (i in 0...n)
			v[i] = "s" + i;
		return v;
	}

	static function show<T>(v:Vector<T>):String
		return v.toArray().join(",");

	// generic code: Vector<T>'s elements read as references, whatever T is
	static function gblit<T>(src:Vector<T>, sp:Int, dst:Vector<T>, dp:Int, n:Int)
		Vector.blit(src, sp, dst, dp, n);

	static function churn(k:Int) {
		var keep = 0;
		for (i in 0...k) {
			var a = [i, i + 1, i + 2];
			keep += a.length + ("x" + i).length;
		}
		return keep;
	}

	static function main() {
		// between vectors: few (inline) and many, offsets
		for (n in [0, 1, 3, 4, 5, 9]) {
			var d = new Vector<Float>(12);
			Vector.blit(floats(10), 1, d, 2, n);
			Sys.println("f " + n + ": " + show(d));
		}
		var di = new Vector<Int>(8);
		Vector.blit(ints(8), 2, di, 0, 6);
		Sys.println("i: " + show(di));
		var db = new Vector<Bool>(6);
		var sb = new Vector<Bool>(6);
		for (i in 0...6)
			sb[i] = i % 2 == 0;
		Vector.blit(sb, 0, db, 1, 5);
		Sys.println("b: " + show(db));
		var ds = new Vector<String>(7);
		Vector.blit(strs(7), 3, ds, 1, 4);
		Vector.blit(strs(7), 0, ds, 5, 2);
		Sys.println("s: " + show(ds));
		var sp = new Vector<P2>(6);
		for (i in 0...6)
			sp[i] = new P2(i, -i);
		var dp = new Vector<P2>(6);
		Vector.blit(sp, 0, dp, 0, 6);
		Vector.blit(sp, 4, dp, 0, 2);
		Sys.println("p: " + [for (i in 0...6) dp[i].x + "/" + dp[i].y].join(","));
		var dd = new Vector<Dynamic>(5);
		var sd = new Vector<Dynamic>(5);
		sd[0] = 1;
		sd[1] = "two";
		sd[2] = 3.5;
		sd[3] = true;
		sd[4] = null;
		Vector.blit(sd, 0, dd, 0, 5);
		Sys.println("d: " + show(dd));

		// within one vector, overlapping, both directions, few and many
		for (n in [1, 3, 6]) {
			var up = ints(10);
			Vector.blit(up, 0, up, 2, n);
			var down = ints(10);
			Vector.blit(down, 2, down, 0, n);
			var same = ints(10);
			Vector.blit(same, 3, same, 3, n);
			Sys.println("o " + n + ": " + show(up) + " | " + show(down) + " | " + show(same));
		}
		var fo = floats(9);
		Vector.blit(fo, 1, fo, 3, 6);
		Vector.blit(fo, 4, fo, 0, 5);
		Sys.println("fo: " + show(fo));
		var so = strs(9);
		Vector.blit(so, 0, so, 1, 8);
		Vector.blit(so, 3, so, 2, 6);
		Sys.println("so: " + show(so));

		// zero and negative lengths: nothing
		var z = ints(4);
		Vector.blit(ints(4), 0, z, 0, 0);
		Vector.blit(ints(4), 2, z, 1, -3);
		Vector.blit(z, 1, z, 0, -1);
		Sys.println("z: " + show(z));

		// generic code
		var gf = new Vector<Float>(10);
		gblit(floats(10), 0, gf, 1, 9);
		gblit(gf, 1, gf, 0, 2);
		var gs = new Vector<String>(6);
		gblit(strs(6), 1, gs, 0, 5);
		Sys.println("g: " + show(gf) + " | " + show(gs));

		// Dynamic elements (numbers, boxed) moved within a Vector<Dynamic>
		// from generic code
		var mixed = new Vector<Dynamic>(8);
		for (i in 0...8)
			mixed[i] = i * 1.25;
		gblit(mixed, 0, mixed, 2, 6);
		Sys.println("m: " + show(mixed) + " " + ((mixed[7] : Float) * 2));

		// references moved into an old vector and within it, then collections
		var old = new Vector<String>(64);
		churn(20000); // promoted
		for (round in 0...3) {
			var young = strs(40);
			for (i in 0...40)
				young[i] = "y" + round + "_" + i;
			Vector.blit(young, 0, old, 2, 3); // few
			Vector.blit(young, 10, old, 20, 30); // many (the whole object remembered)
			Vector.blit(old, 2, old, 6, 3); // within, up
			Vector.blit(old, 20, old, 10, 4); // within, down
			young = null;
			churn(20000);
			Sys.println("gc " + round + ": " + [old[2], old[4], old[6], old[8], old[10], old[13], old[20], old[49]].join(","));
		}
		var oldf = new Vector<Float>(40);
		churn(20000);
		Vector.blit(floats(40), 0, oldf, 0, 40);
		churn(20000);
		Sys.println("gcf: " + oldf[0] + "," + oldf[39]);

		// Vector.copy (through blit)
		var c = floats(6).copy();
		var cs = strs(5).copy();
		Sys.println("copy: " + show(c) + " | " + show(cs) + " " + c.length + " " + cs.length);
	}
}
