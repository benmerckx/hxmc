package hxmc.android;

import haxe.io.Bytes;
import haxe.ds.Vector;

// ECDSA over NIST P-256 with SHA-256, in plain Haxe, for the APK's debug
// signature (Apk): the public key of a private scalar, and signatures with
// the nonce of RFC 6979 (deterministic: the same APK signs the same way; no
// random source needed). Numbers are arrays of 18 limbs of 15 bits (270
// bits, little-endian), so that every product and carry fits a 32-bit Int;
// multiplications are Montgomery's (CIOS) modulo p (the field) or n (the
// group's order), points Jacobian (a = -3). Not constant-time: it signs
// with a key of the developer's own machine.
class P256 {
	static inline var BITS = 15;
	static inline var MASK = 0x7fff;
	static inline var L = 18;

	public static final P = fromHex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff");
	public static final N = fromHex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551");
	static final B = fromHex("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b");
	static final GX = fromHex("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296");
	static final GY = fromHex("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5");

	static var fp:Mont;
	static var fn:Mont;

	static function init() {
		if (fp == null) {
			fp = new Mont(P);
			fn = new Mont(N);
		}
	}

	// ---- numbers

	public static function fromBytes(b:Bytes):Vector<Int> {
		var r = new Vector<Int>(L, 0);
		for (i in 0...b.length) {
			var byte = b.get(b.length - 1 - i), bit = 8 * i;
			for (k in 0...8)
				if (byte & (1 << k) != 0) r[Std.int((bit + k) / BITS)] |= 1 << ((bit + k) % BITS);
		}
		return r;
	}

	public static function toBytes(a:Vector<Int>, len = 32):Bytes {
		var b = Bytes.alloc(len);
		for (i in 0...8 * len) {
			if (a[Std.int(i / BITS)] & (1 << (i % BITS)) != 0) {
				var at = len - 1 - (i >> 3);
				b.set(at, b.get(at) | (1 << (i & 7)));
			}
		}
		return b;
	}

	static function fromHex(h:String):Vector<Int>
		return fromBytes(Bytes.ofHex(h));

	public static function cmp(a:Vector<Int>, b:Vector<Int>):Int {
		var i = L - 1;
		while (i >= 0) {
			if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
			i--;
		}
		return 0;
	}

	static function isZero(a:Vector<Int>):Bool {
		for (x in a)
			if (x != 0) return false;
		return true;
	}

	static function addRaw(a:Vector<Int>, b:Vector<Int>):Vector<Int> {
		var r = new Vector<Int>(L, 0), c = 0;
		for (i in 0...L) {
			var s = a[i] + b[i] + c;
			r[i] = s & MASK;
			c = s >> BITS;
		}
		return r;
	}

	// a - b, a >= b
	static function subRaw(a:Vector<Int>, b:Vector<Int>):Vector<Int> {
		var r = new Vector<Int>(L, 0), c = 0;
		for (i in 0...L) {
			var s = a[i] - b[i] - c;
			c = s < 0 ? 1 : 0;
			r[i] = s & MASK;
		}
		return r;
	}

	// a mod m for a < 2^(15*18) (the inputs: digests, RFC 6979's candidates)
	static function reduce(a:Vector<Int>, m:Vector<Int>):Vector<Int> {
		var r = a;
		while (cmp(r, m) >= 0)
			r = subRaw(r, m);
		return r;
	}

	// ---- the curve: Jacobian points [X, Y, Z] in Montgomery form (Z = 0: infinity)

	static function pt(x:Vector<Int>, y:Vector<Int>, z:Vector<Int>):Vector<Vector<Int>> {
		var q = new Vector<Vector<Int>>(3);
		q[0] = x;
		q[1] = y;
		q[2] = z;
		return q;
	}

	static function double(q:Vector<Vector<Int>>):Vector<Vector<Int>> {
		var f = fp;
		if (isZero(q[2])) return q;
		var delta = f.mul(q[2], q[2]), gamma = f.mul(q[1], q[1]), beta = f.mul(q[0], gamma);
		var t = f.mul(f.sub(q[0], delta), f.add(q[0], delta));
		var alpha = f.add(f.add(t, t), t);
		var beta4 = f.add(beta, beta);
		beta4 = f.add(beta4, beta4);
		var x3 = f.sub(f.mul(alpha, alpha), f.add(beta4, beta4));
		var yz = f.add(q[1], q[2]);
		var z3 = f.sub(f.sub(f.mul(yz, yz), gamma), delta);
		var g2 = f.mul(gamma, gamma);
		var g8 = f.add(g2, g2);
		g8 = f.add(g8, g8);
		g8 = f.add(g8, g8);
		var y3 = f.sub(f.mul(alpha, f.sub(beta4, x3)), g8);
		return pt(x3, y3, z3);
	}

	// q + (x2, y2) (affine, Montgomery form)
	static function addAffine(q:Vector<Vector<Int>>, x2:Vector<Int>, y2:Vector<Int>):Vector<Vector<Int>> {
		var f = fp;
		if (isZero(q[2])) return pt(x2, y2, f.one);
		var z1z1 = f.mul(q[2], q[2]);
		var u2 = f.mul(x2, z1z1), s2 = f.mul(y2, f.mul(q[2], z1z1));
		var h = f.sub(u2, q[0]);
		var rr = f.sub(s2, q[1]);
		if (isZero(h)) return isZero(rr) ? double(pt(x2, y2, f.one)) : pt(f.one, f.one, new Vector<Int>(L, 0));
		var hh = f.mul(h, h);
		var i = f.add(hh, hh);
		i = f.add(i, i);
		var j = f.mul(h, i);
		var r = f.add(rr, rr);
		var v = f.mul(q[0], i);
		var x3 = f.sub(f.sub(f.mul(r, r), j), f.add(v, v));
		var y1j = f.mul(q[1], j);
		var y3 = f.sub(f.mul(r, f.sub(v, x3)), f.add(y1j, y1j));
		var zh = f.add(q[2], h);
		var z3 = f.sub(f.sub(f.mul(zh, zh), z1z1), hh);
		return pt(x3, y3, z3);
	}

	// k * G as affine (x, y), plain numbers
	static function mulG(k:Vector<Int>):{x:Vector<Int>, y:Vector<Int>} {
		init();
		var f = fp;
		var gx = f.to(GX), gy = f.to(GY);
		var q = pt(f.one, f.one, new Vector<Int>(L, 0));
		var i = 8 * 32 - 1;
		while (i >= 0) {
			q = double(q);
			if (k[Std.int(i / BITS)] & (1 << (i % BITS)) != 0) q = addAffine(q, gx, gy);
			i--;
		}
		if (isZero(q[2])) throw "P256: the point at infinity";
		var zi = f.inverse(q[2]);
		var zi2 = f.mul(zi, zi);
		return {x: f.from(f.mul(q[0], zi2)), y: f.from(f.mul(q[1], f.mul(zi2, zi)))};
	}

	// ---- keys and signatures

	// the uncompressed public point (0x04, X, Y) of the private scalar d (32 bytes)
	public static function publicKey(d:Bytes):Bytes {
		var p = mulG(fromBytes(d));
		var out = Bytes.alloc(65);
		out.set(0, 4);
		out.blit(1, toBytes(p.x), 0, 32);
		out.blit(33, toBytes(p.y), 0, 32);
		return out;
	}

	// whether d is a valid private scalar (1 <= d < n)
	public static function validPrivate(d:Bytes):Bool {
		if (d.length != 32) return false;
		var x = fromBytes(d);
		return !isZero(x) && cmp(x, N) < 0;
	}

	// the DER signature (SEQUENCE of r and s) of message's SHA-256 with d
	public static function sign(d:Bytes, message:Bytes):Bytes {
		init();
		var h = haxe.crypto.Sha256.make(message);
		var e = reduce(fromBytes(h), N);
		var x = fromBytes(d);
		// RFC 6979, 3.2 (HMAC-SHA256; qlen = hlen = 256)
		var hmac = new haxe.crypto.Hmac(SHA256);
		function cat(parts:Array<Bytes>):Bytes {
			var b = new haxe.io.BytesBuffer();
			for (p in parts)
				b.add(p);
			return b.getBytes();
		}
		var v = Bytes.alloc(32), k = Bytes.alloc(32);
		v.fill(0, 32, 1);
		var xo = toBytes(x), ho = toBytes(e);
		k = hmac.make(k, cat([v, Bytes.ofHex("00"), xo, ho]));
		v = hmac.make(k, v);
		k = hmac.make(k, cat([v, Bytes.ofHex("01"), xo, ho]));
		v = hmac.make(k, v);
		while (true) {
			v = hmac.make(k, v);
			var kn = fromBytes(v);
			if (!isZero(kn) && cmp(kn, N) < 0) {
				var r = reduce(mulG(kn).x, N);
				if (!isZero(r)) {
					var g = fn;
					// s = k^-1 (e + r d) mod n
					var s = g.from(g.mul(g.inverse(g.to(kn)), g.add(g.to(e), g.mul(g.to(r), g.to(x)))));
					if (!isZero(s)) return Der.seq([Der.integer(toBytes(r)), Der.integer(toBytes(s))]);
				}
			}
			k = hmac.make(k, cat([v, Bytes.ofHex("00")]));
			v = hmac.make(k, v);
		}
	}
}

// Montgomery arithmetic modulo an odd m < 2^270 (R = 2^270)
private class Mont {
	static inline var BITS = 15;
	static inline var MASK = 0x7fff;
	static inline var L = 18;

	final m:Vector<Int>;
	final minv:Int; // -m^-1 mod 2^15
	final r2:Vector<Int>; // R^2 mod m
	public final one:Vector<Int>; // R mod m

	public function new(m:Vector<Int>) {
		this.m = m;
		// m^-1 mod 2^15 by Newton's iteration, then negated
		var inv = 1;
		for (_ in 0...5)
			inv = (inv * (2 - ((m[0] * inv) & MASK))) & MASK;
		minv = (-inv) & MASK;
		// R mod m and R^2 mod m by doubling
		var x = new Vector<Int>(L, 0);
		x[0] = 1;
		for (i in 0...2 * BITS * L) {
			x = dbl(x);
			if (i == BITS * L - 1) one = x.copy();
		}
		r2 = x;
	}

	function dbl(a:Vector<Int>):Vector<Int> {
		var r = new Vector<Int>(L, 0), c = 0;
		for (i in 0...L) {
			var s = (a[i] << 1) | c;
			r[i] = s & MASK;
			c = s >> BITS;
		}
		// (a < m < 2^269: 2a fits; one subtraction)
		return c != 0 || cmp(r, m) >= 0 ? subRaw(r, m) : r;
	}

	static function cmp(a:Vector<Int>, b:Vector<Int>):Int {
		var i = L - 1;
		while (i >= 0) {
			if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
			i--;
		}
		return 0;
	}

	static function subRaw(a:Vector<Int>, b:Vector<Int>):Vector<Int> {
		var r = new Vector<Int>(L, 0), c = 0;
		for (i in 0...L) {
			var s = a[i] - b[i] - c;
			c = s < 0 ? 1 : 0;
			r[i] = s & MASK;
		}
		return r;
	}

	public function mul(a:Vector<Int>, b:Vector<Int>):Vector<Int> {
		var t = new Vector<Int>(L + 2, 0);
		for (i in 0...L) {
			var ai = a[i], c = 0;
			for (j in 0...L) {
				var s = t[j] + ai * b[j] + c;
				t[j] = s & MASK;
				c = s >> BITS;
			}
			var s = t[L] + c;
			t[L] = s & MASK;
			t[L + 1] = s >> BITS;
			var u = (t[0] * minv) & MASK;
			s = t[0] + u * m[0];
			c = s >> BITS;
			for (j in 1...L) {
				s = t[j] + u * m[j] + c;
				t[j - 1] = s & MASK;
				c = s >> BITS;
			}
			s = t[L] + c;
			t[L - 1] = s & MASK;
			t[L] = t[L + 1] + (s >> BITS);
		}
		var r = new Vector<Int>(L);
		Vector.blit(t, 0, r, 0, L);
		return t[L] != 0 || cmp(r, m) >= 0 ? subRaw(r, m) : r;
	}

	public function add(a:Vector<Int>, b:Vector<Int>):Vector<Int> {
		var r = new Vector<Int>(L, 0), c = 0;
		for (i in 0...L) {
			var s = a[i] + b[i] + c;
			r[i] = s & MASK;
			c = s >> BITS;
		}
		return c != 0 || cmp(r, m) >= 0 ? subRaw(r, m) : r;
	}

	public function sub(a:Vector<Int>, b:Vector<Int>):Vector<Int> {
		if (cmp(a, b) >= 0) return subRaw(a, b);
		// (a + m - b: a carry or a borrow per limb, s >> 15 either way)
		var r = new Vector<Int>(L, 0), c = 0;
		for (i in 0...L) {
			var s = a[i] + m[i] - b[i] + c;
			r[i] = s & MASK;
			c = s >> BITS;
		}
		return r;
	}

	public inline function to(a:Vector<Int>):Vector<Int>
		return mul(a, r2);

	public function from(a:Vector<Int>):Vector<Int> {
		var o = new Vector<Int>(L, 0);
		o[0] = 1;
		return mul(a, o);
	}

	// a^(m-2) (Montgomery form in and out: Fermat, m prime)
	public function inverse(a:Vector<Int>):Vector<Int> {
		var two = new Vector<Int>(L, 0);
		two[0] = 2;
		var e = subRaw(m, two);
		var r = one;
		var i = BITS * L - 1;
		while (i >= 0) {
			r = mul(r, r);
			if (e[Std.int(i / BITS)] & (1 << (i % BITS)) != 0) r = mul(r, a);
			i--;
		}
		return r;
	}
}
