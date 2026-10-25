package hxmc.rt.wasm;

import hxmc.I64;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The rest of the C library the runtime's Haxe code calls (hxmc.unsafe.LibC),
// for WebAssembly: musl's rand, the calendar in UTC (WASI has no time zones:
// localtime_r is gmtime_r), clock_gettime over WASI's clocks, errno.
@:hxmc.wasm @:keep
class Libc {
	static var seed:I64;
	static var errnoCell:Ptr;

	static inline function m32():I64
		return ((1 : I64) << 32) - 1;

	// musl: seed = 6364136223846793005 * seed + 1, the top 31 bits
	// correctly rounded (hxmc.rt.FloatText)
	@:hxmc.export("strtod") @:hxmc.noGc static function strtod(s:Ptr, end:Ptr):Float {
		#if hxmc.wasm_gc
		// (typed under -D hxmc.wasm-gc, not run there)
		return 0;
		#else
		// (the bytes as units, ASCII as they are)
		var n = Heap.strlen(s).toInt();
		var u = Heap.malloc(2 * n + 2);
		for (i in 0...n)
			Mem.setU16At(u, 0, i, Mem.getU8(s, i));
		var r = hxmc.rt.FloatText.parse(new hxmc.scoped.Str(u, n));
		Heap.free(u);
		if (!end.isNull()) Mem.setPtr(end, 0, s.add(r.end));
		return r.value;
		#end
	}

	@:hxmc.export("rand") @:hxmc.noGc static function rand():Int {
		var a:I64 = ((0x5851F42D : I64) << 32) | (0x4C957F2D : I64);
		seed = a * seed + 1;
		return (seed >>> 33).toInt();
	}

	@:hxmc.export("srand") @:hxmc.noGc static function srand(s:Int):Void
		seed = ((s : I64) & m32()) - 1;

	@:hxmc.export("__errno_location") @:hxmc.noGc static function errnoLocation():Ptr {
		if (errnoCell.isNull()) errnoCell = Heap.calloc(1, 8);
		return errnoCell;
	}

	// struct timespec: int64 seconds, int64 nanoseconds
	@:hxmc.export("clock_gettime") @:hxmc.noGc static function clockGettime(clock:Int, ts:Ptr):Int {
		var ns = Wasi.clockNs(clock);
		var s = ns / 1000000000;
		Mem.setI64(ts, 0, s);
		Mem.setI64(ts, 8, ns - s * 1000000000);
		return 0;
	}

	// days since 1970-01-01 of a civil date (proleptic Gregorian; Howard Hinnant's algorithm)
	@:hxmc.noGc static function daysFromCivil(y:Int, m:Int, d:Int):I64 {
		if (m <= 2) y--;
		var era = Std.int((y >= 0 ? y : y - 399) / 400);
		var yoe = y - era * 400;
		var doy = Std.int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1;
		var doe = yoe * 365 + Std.int(yoe / 4) - Std.int(yoe / 100) + doy;
		return (era : I64) * 146097 + doe - 719468;
	}

	// struct tm: nine ints (sec min hour mday mon year wday yday isdst), then
	// long tm_gmtoff and const char *tm_zone (musl)
	@:hxmc.export("gmtime_r") @:hxmc.noGc static function gmtimeR(t:Ptr, tm:Ptr):Ptr {
		var secs = Mem.getI64(t, 0);
		var days = secs / 86400;
		var rem = (secs - days * 86400).toInt();
		if (rem < 0) {
			rem += 86400;
			days = days - 1;
		}
		Mem.setI32(tm, 0, rem % 60);
		Mem.setI32(tm, 4, Std.int(rem / 60) % 60);
		Mem.setI32(tm, 8, Std.int(rem / 3600));
		// weekday: 1970-01-01 was a Thursday
		var wd = ((days + 4) % 7).toInt();
		if (wd < 0) wd += 7;
		Mem.setI32(tm, 24, wd);
		// civil from days
		var z = days + 719468;
		var era = (z >= 0 ? z : z - 146096) / 146097;
		var doe = (z - era * 146097).toInt();
		var yoe = Std.int((doe - Std.int(doe / 1460) + Std.int(doe / 36524) - Std.int(doe / 146096)) / 365);
		var y = yoe + (era * 400).toInt();
		var doy = doe - (365 * yoe + Std.int(yoe / 4) - Std.int(yoe / 100));
		var mp = Std.int((5 * doy + 2) / 153);
		var d = doy - Std.int((153 * mp + 2) / 5) + 1;
		var m = mp < 10 ? mp + 3 : mp - 9;
		if (m <= 2) y++;
		Mem.setI32(tm, 12, d);
		Mem.setI32(tm, 16, m - 1);
		Mem.setI32(tm, 20, y - 1900);
		Mem.setI32(tm, 28, (days - daysFromCivil(y, 1, 1)).toInt());
		Mem.setI32(tm, 32, 0);
		Mem.setI64(tm, 40, 0);
		Mem.setI64(tm, 48, 0);
		return tm;
	}

	@:hxmc.export("localtime_r") @:hxmc.noGc static function localtimeR(t:Ptr, tm:Ptr):Ptr
		return gmtimeR(t, tm);

	// timegm (normalizing the fields as mktime does)
	@:hxmc.export("mktime") @:hxmc.noGc static function mktime(tm:Ptr):I64 {
		var mon = Mem.getI32(tm, 16);
		var y = Mem.getI32(tm, 20) + 1900;
		var ym = Std.int(mon / 12);
		mon -= ym * 12;
		if (mon < 0) {
			mon += 12;
			ym--;
		}
		y += ym;
		var days = daysFromCivil(y, mon + 1, 1) + Mem.getI32(tm, 12) - 1;
		var t = days * 86400 + (Mem.getI32(tm, 8) : I64) * 3600 + (Mem.getI32(tm, 4) : I64) * 60 + Mem.getI32(tm, 0);
		var tt = Mem.stack(8);
		Mem.setI64(tt, 0, t);
		gmtimeR(tt, tm);
		return t;
	}

	@:hxmc.export("fflush") @:hxmc.noGc static function fflush(f:Ptr):Int {
		Wasi.flush();
		return 0;
	}

	@:hxmc.export("exit") @:hxmc.noGc static function exit(code:Int):Void {
		Wasi.exit(code);
	}
}
