package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.rt.Repr;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// The Date natives and Math.random (formerly in rt_std.c), written over
// hxmc.rt.Repr for both runtimes (@:hxmc.anyHeap). A Date holds the
// milliseconds since the epoch (a double); its calendar fields come from
// the C library in linear memory (mktime, localtime_r, gmtime_r; the UCRT's
// _mktime64, _localtime64_s, _gmtime64_s on Windows), whose struct tm
// starts with nine ints on every target, and from the host's Date under
// -D hxmc.wasm-gc.
@:keep @:hxmc.anyHeap
class Date {
	static inline function windows():Bool
		return Mem.os() == 2;

	// toString, for Std.string of a value of any type (hxmc.rt.Dyn.stdString,
	// hxmc.rt.gc.GcDyn.string): set by `of`, which makes every date (a copy
	// aside: Reflect.copy), so that a program making none has no calendar code
	// (natively the C library's time zones)
	@:allow(hxmc.rt) static var printer:Null<Dynamic->String>;

	@:allow(hxmc.rt) static function of(ms:Float):Dynamic {
		if (printer == null) printer = toString;
		return Repr.dateOf(ms);
	}

	static inline function ms(d:Dynamic):Float
		return Repr.dateMs(d);

	@:hxmc.noGc static function mktime(tm:Ptr):I64
		return windows() ? LibC._mktime64(tm) : LibC.mktime(tm);

	// the broken-down time of `ms` into tm (local or UTC)
	@:hxmc.noGc static function breakDown(ms:Float, utc:Bool, tm:Ptr) {
		var t = Mem.stack(8);
		var s:I64 = cast Math.ffloor(ms / 1000.0);
		Mem.setI64(t, 0, s);
		if (windows()) {
			if (utc) LibC._gmtime64_s(tm, t) else LibC._localtime64_s(tm, t);
		} else {
			if (utc) LibC.gmtime_r(t, tm) else LibC.localtime_r(t, tm);
		}
	}

	@:hxmc.host("Date_new") static function make(y:Int, m:Int, d:Int, h:Int, mi:Int, s:Int):Dynamic
		return of(Repr.dateLocal(y, m, d, h, mi, s));

	@:hxmc.host("Date_now") static function now():Dynamic
		return of(Repr.dateNow());

	@:hxmc.host("Date_fromTime") static function fromTime(t:Float):Dynamic
		return of(t);

	// HxOverrides.strDate: "hh:mm:ss" (UTC time of day), "YYYY-MM-DD",
	// "YYYY-MM-DD hh:mm:ss" (local)
	@:hxmc.host("Date_fromString") static function fromString(s:String):Dynamic {
		var n = Str.len(s);
		var f = [0, 0, 0, 0, 0, 0];
		inline function digitsAt(pos:Int, count:Int, k:Int):Bool {
			var v = 0;
			var ok = true;
			for (i in pos...pos + count) {
				var c = Str.unit(s, i);
				if (c < 48 || c > 57) ok = false else v = v * 10 + c - 48;
			}
			f[k] = v;
			return ok;
		}
		inline function sep(pos:Int, c:Int):Bool
			return Str.unit(s, pos) == c;
		if (n == 8 && digitsAt(0, 2, 3) && sep(2, ":".code) && digitsAt(3, 2, 4) && sep(5, ":".code) && digitsAt(6, 2, 5))
			return of((f[3] * 3600.0 + f[4] * 60 + f[5]) * 1000.0);
		if (n == 10 && digitsAt(0, 4, 0) && sep(4, "-".code) && digitsAt(5, 2, 1) && sep(7, "-".code) && digitsAt(8, 2, 2))
			return make(f[0], f[1] - 1, f[2], 0, 0, 0);
		if (n == 19 && digitsAt(0, 4, 0) && sep(4, "-".code) && digitsAt(5, 2, 1) && sep(7, "-".code) && digitsAt(8, 2, 2) && sep(10, " ".code)
			&& digitsAt(11, 2, 3) && sep(13, ":".code) && digitsAt(14, 2, 4) && sep(16, ":".code) && digitsAt(17, 2, 5))
			return make(f[0], f[1] - 1, f[2], f[3], f[4], f[5]);
		Repr.fail(Str.concat("Invalid date format : ", n > 60 ? Str.substr(s, 0, 60) : s));
		return null;
	}

	@:hxmc.host("Date_getTime") @:hxmc.noGc static function getTime(d:Dynamic):Float
		return ms(d);

	@:hxmc.noGc static function field(d:Dynamic, utc:Bool, f:Int):Int
		return Repr.dateField(d, utc, f);

	@:hxmc.host("Date_getFullYear") @:hxmc.noGc static function getFullYear(d:Dynamic):Int
		return field(d, false, Repr.F_YEAR) + Repr.YEAR_BASE;

	@:hxmc.host("Date_getMonth") @:hxmc.noGc static function getMonth(d:Dynamic):Int
		return field(d, false, Repr.F_MON);

	@:hxmc.host("Date_getDate") @:hxmc.noGc static function getDate(d:Dynamic):Int
		return field(d, false, Repr.F_MDAY);

	@:hxmc.host("Date_getDay") @:hxmc.noGc static function getDay(d:Dynamic):Int
		return field(d, false, Repr.F_WDAY);

	@:hxmc.host("Date_getHours") @:hxmc.noGc static function getHours(d:Dynamic):Int
		return field(d, false, Repr.F_HOUR);

	@:hxmc.host("Date_getMinutes") @:hxmc.noGc static function getMinutes(d:Dynamic):Int
		return field(d, false, Repr.F_MIN);

	@:hxmc.host("Date_getSeconds") @:hxmc.noGc static function getSeconds(d:Dynamic):Int
		return field(d, false, Repr.F_SEC);

	@:hxmc.host("Date_getUTCFullYear") @:hxmc.noGc static function getUTCFullYear(d:Dynamic):Int
		return field(d, true, Repr.F_YEAR) + Repr.YEAR_BASE;

	@:hxmc.host("Date_getUTCMonth") @:hxmc.noGc static function getUTCMonth(d:Dynamic):Int
		return field(d, true, Repr.F_MON);

	@:hxmc.host("Date_getUTCDate") @:hxmc.noGc static function getUTCDate(d:Dynamic):Int
		return field(d, true, Repr.F_MDAY);

	@:hxmc.host("Date_getUTCDay") @:hxmc.noGc static function getUTCDay(d:Dynamic):Int
		return field(d, true, Repr.F_WDAY);

	@:hxmc.host("Date_getUTCHours") @:hxmc.noGc static function getUTCHours(d:Dynamic):Int
		return field(d, true, Repr.F_HOUR);

	@:hxmc.host("Date_getUTCMinutes") @:hxmc.noGc static function getUTCMinutes(d:Dynamic):Int
		return field(d, true, Repr.F_MIN);

	@:hxmc.host("Date_getUTCSeconds") @:hxmc.noGc static function getUTCSeconds(d:Dynamic):Int
		return field(d, true, Repr.F_SEC);

	@:hxmc.host("Date_getTimezoneOffset") @:hxmc.noGc static function getTimezoneOffset(d:Dynamic):Int
		return Repr.timezoneOffset(d);

	// "%04d-%02d-%02d %02d:%02d:%02d" of the local time
	@:hxmc.host("Date_toString") static function toString(d:Dynamic):String {
		var tm = Repr.dateFields(d);
		var b = new StringBuf();
		inline function pad(v:Int, w:Int) {
			if (v < 0) {
				b.addChar("-".code);
				v = -v;
				w--;
			}
			var s = Str.ofInt(v);
			for (_ in Str.len(s)...w)
				b.addChar("0".code);
			b.add(s);
		}
		pad(tm.get(Repr.F_YEAR) + Repr.YEAR_BASE, 4);
		b.addChar("-".code);
		pad(tm.get(Repr.F_MON) + 1, 2);
		b.addChar("-".code);
		pad(tm.get(Repr.F_MDAY), 2);
		b.addChar(" ".code);
		pad(tm.get(Repr.F_HOUR), 2);
		b.addChar(":".code);
		pad(tm.get(Repr.F_MIN), 2);
		b.addChar(":".code);
		pad(tm.get(Repr.F_SEC), 2);
		return b.toString();
	}

	#if !(hxmc.wasm_gc)
	// ---- Math.random: [0, 1) from rand() (the UCRT's has 15 bits: two make 30)
	@:hxmc.host("Math_random") @:hxmc.noGc static function random():Float {
		if (windows()) return ((LibC.rand() << 15) ^ LibC.rand()) / 1073741824.0;
		return LibC.rand() / 2147483648.0;
	}
	#end
}
