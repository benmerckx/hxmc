package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
#if (hxmc.target == "wasm32-wasi")
import hxmc.rt.wasm.Wasi;
import hxmc.rt.wasm.WasiApi;
#else
import hxmc.unsafe.Posix;
#end

// Math.random and Std.random: xoshiro256** (Blackman and Vigna), one state
// per thread (@:hxmc.threadLocal: no lock), seeded on the thread's first
// draw from the system's random bytes: getrandom(2) by its number on Linux
// and Android (glibc 2.17, the dynamic mode's floor, has no wrapper), else
// /dev/urandom; arc4random_buf on macOS and iOS; BCryptGenRandom on Windows;
// random_get on WASI. Without them, the time and addresses mixed by
// splitmix64. So every run, and every thread, draws its own sequence.
// Nothing here allocates or reaches a GC point (FnLower.NOGC: Math_random).
@:keep
class Random {
	// the state; all zero (a new thread's) until seeded
	@:hxmc.threadLocal static var s0:I64;
	@:hxmc.threadLocal static var s1:I64;
	@:hxmc.threadLocal static var s2:I64;
	@:hxmc.threadLocal static var s3:I64;

	static inline function k(hi:Int, lo:Int):I64
		return ((hi : I64) << 32) | ((lo : I64) & ((((1 : I64) << 32) - 1)));

	static inline function rotl(x:I64, n:Int):I64
		return (x << n) | (x >>> (64 - n));

	// the next 64 bits
	@:hxmc.unsafe public static function next():I64 {
		var a = s0, b = s1, c = s2, d = s3;
		if ((a | b | c | d) == 0) {
			seed();
			a = s0;
			b = s1;
			c = s2;
			d = s3;
		}
		var r = rotl(b * 5, 7) * 9;
		var t = b << 17;
		c ^= a;
		d ^= b;
		b ^= c;
		a ^= d;
		c ^= t;
		d = rotl(d, 45);
		s0 = a;
		s1 = b;
		s2 = c;
		s3 = d;
		return r;
	}

	// [0, 1): 53 bits
	@:hxmc.unsafe public static function float():Float {
		var f:Float = cast(next() >>> 11);
		return f * 1.1102230246251565e-16; // 2^-53
	}

	// [0, n), unbiased (Lemire's multiply and reject); 0 when n <= 1
	@:hxmc.unsafe public static function int(n:Int):Int {
		if (n <= 1) return 0;
		var lo32 = ((1 : I64) << 32) - 1;
		var m = (next() >>> 32) * n;
		if ((m & lo32) < n) {
			var t = (((1 : I64) << 32) - n) % n; // 2^32 mod n
			while ((m & lo32) < t)
				m = (next() >>> 32) * n;
		}
		return (m >>> 32).toInt();
	}

	// splitmix64's step: x advanced in place, its output returned
	@:hxmc.unsafe static function splitmix(x:Ptr):I64 {
		var z = Mem.getI64(x, 0) + k(0x9E3779B9, 0x7F4A7C15);
		Mem.setI64(x, 0, z);
		z = (z ^ (z >>> 30)) * k(0xBF58476D, 0x1CE4E5B9);
		z = (z ^ (z >>> 27)) * k(0x94D049BB, 0x133111EB);
		return z ^ (z >>> 31);
	}

	@:hxmc.unsafe static function seed() {
		var buf = Mem.stack(32);
		if (entropy(buf)) {
			s0 = Mem.getI64(buf, 0);
			s1 = Mem.getI64(buf, 8);
			s2 = Mem.getI64(buf, 16);
			s3 = Mem.getI64(buf, 24);
			if (!((s0 | s1 | s2 | s3) == 0)) return; // (I64 has no !=)
		}
		// no system randomness: the time (seconds, nanoseconds) and this
		// thread's stack address, mixed
		var x = Mem.stack(8);
		LibC.clock_gettime(0, buf); // CLOCK_REALTIME
		Mem.setI64(x, 0, Mem.getI64(buf, 0) * k(0x2545F491, 0x4F6CDD1D) ^ (Mem.getI64(buf, 8) & k(0, -1)) ^ (buf.toI64() << 20));
		s0 = splitmix(x);
		s1 = splitmix(x);
		s2 = splitmix(x);
		s3 = splitmix(x);
	}

	// 32 bytes of the system's randomness at buf, or false
	@:hxmc.unsafe static function entropy(buf:Ptr):Bool {
		#if (hxmc.target == "wasm32-wasi")
		return WasiApi.random_get(Wasi.a32(buf), 32) == 0;
		#else
		if (Mem.os() == 2) return Bcrypt.BCryptGenRandom(Ptr.nil(), buf, 32, 2) == 0; // BCRYPT_USE_SYSTEM_PREFERRED_RNG
		if (Mem.os() == 1) {
			Apple.arc4random_buf(buf, 32);
			return true;
		}
		// getrandom(buf, 32, GRND_NONBLOCK): 32 bytes come whole once the
		// kernel's pool is ready; before that (early boot), /dev/urandom
		if (Sc.syscall(Mem.arm() ? 278 : 318, buf.toI64(), 32, 1, 0, 0, 0) == 32) return true;
		var path = Mem.stack(16);
		Mem.setI64(path, 0, k(0x6172752F, 0x7665642F)); // "/dev/ura"
		Mem.setI64(path, 8, k(0, 0x6D6F646E)); // "ndom\0"
		var fd = Posix.open(path, 0x80000, 0); // O_RDONLY | O_CLOEXEC
		if (fd < 0) return false;
		var n = Posix.read(fd, buf, 32);
		Posix.close(fd);
		return n == 32;
		#end
	}
}

#if (hxmc.target != "wasm32-wasi")
// Linux and Android: syscall(2), as hxmc.unsafe.Linux declares it, but fast
// (no safe region: Math.random is no GC point)
@:hxmc.c @:hxmc.fast private extern class Sc {
	@:hxmc.varargs(1) static function syscall(nr:I64, a:I64, b:I64, c:I64, d:I64, e:I64, f:I64):I64;
}

// macOS and iOS (libSystem)
@:hxmc.c @:hxmc.fast private extern class Apple {
	static function arc4random_buf(buf:Ptr, n:I64):Void;
}

// Windows
@:hxmc.c @:hxmc.fast @:hxmc.lib("bcrypt") private extern class Bcrypt {
	static function BCryptGenRandom(alg:Ptr, buf:Ptr, n:Int, flags:Int):Int;
}
#end
