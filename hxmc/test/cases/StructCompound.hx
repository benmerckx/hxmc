import haxe.io.Bytes;
import hxmc.Span;
import hxmc.unsafe.UInt8;

// Compound assignments and increments of a struct's field reached through
// a place (a span's element, an object's field, a static, nested): Haxe's
// typer binds the place to a temporary first (`var fh = s[i]; fh.f -= v`),
// which names the place itself, not a copy (FnLower.places). With Haxe's
// analyzer off (Off) as on (On): the analyzer folds some of them back, the
// typer's form alone stays without it.
@:hxmc.struct @:publicFields class CV {
	var x:Float;
	var y:Float;

	function new() {}
}

@:hxmc.struct @:publicFields class CS {
	var n:Int;
	var cnt:Int;
	var v:CV;

	function new() {}
}

class CHolder {
	public var s:CS;

	public function new() {}
}

@:analyzer(ignore) @:hxmc.kernel class Off {
	public static function ops(raw:Span<UInt8>):Int {
		var st:Span<CS> = raw.reinterpret();
		st[0].cnt -= 5;
		st[0].cnt += 2;
		st[0].cnt++;
		st[0].cnt--;
		++st[0].cnt;
		--st[0].n;
		var a = st[0].cnt++;
		var b = st[0].cnt--;
		var c = ++st[0].n;
		var d = --st[0].n;
		var i = 0;
		st[i++].v.x += 1.5;
		st[i].v.y -= 2;
		st[1].v.y *= 3;
		return st[0].cnt * 100000 + st[0].n * 10000 + a * 100 + b + c * 10 + d + i * 1000 + Std.int(st[0].v.x * 2 + st[1].v.y);
	}
}

@:hxmc.kernel class On {
	public static function ops(raw:Span<UInt8>):Int {
		var st:Span<CS> = raw.reinterpret();
		st[0].cnt -= 5;
		st[0].cnt += 2;
		st[0].cnt++;
		st[0].cnt--;
		++st[0].cnt;
		--st[0].n;
		var a = st[0].cnt++;
		var b = st[0].cnt--;
		var c = ++st[0].n;
		var d = --st[0].n;
		var i = 0;
		st[i++].v.x += 1.5;
		st[i].v.y -= 2;
		st[1].v.y *= 3;
		return st[0].cnt * 100000 + st[0].n * 10000 + a * 100 + b + c * 10 + d + i * 1000 + Std.int(st[0].v.x * 2 + st[1].v.y);
	}
}

@:analyzer(ignore)
class StructCompound {
	static var g:CS;

	static function churn(n:Int):Int
		return [for (i in 0...n) [i]].length;

	static function bytes():Bytes {
		var b = Bytes.alloc(64);
		b.fill(0, 64, 0);
		b.setInt32(4, 61);
		return b;
	}

	static function main() {
		var b = bytes();
		trace(Off.ops(Span.ofBytes(b)), b.getInt32(0), b.getInt32(4));
		b = bytes();
		trace(On.ops(Span.ofBytes(b)), b.getInt32(0), b.getInt32(4));
		// (in an object, which a collection moves while the right side allocates)
		var h = new CHolder();
		h.s.n += churn(1000);
		h.s.v.x += churn(2000);
		h.s.n++;
		var a = h.s.n--;
		var hs = [new CHolder(), new CHolder()];
		hs[1].s.cnt += 4;
		++hs[1].s.cnt;
		trace(h.s.n, a, h.s.v.x, hs[1].s.cnt);
		g.n += 3;
		g.v.y -= 1;
		g.cnt++;
		trace(g.n, g.v.y, g.cnt);
	}
}
