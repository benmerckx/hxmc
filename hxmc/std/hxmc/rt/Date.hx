package hxmc.rt;

import hxmc.I64;
import hxmc.rt.C;
import hxmc.rt.Repr;
import hxmc.unsafe.LibC;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;
import hxmc.scoped.Scope;
import hxmc.scoped.Slice;

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
	// "YYYY-MM-DD hh:mm:ss" (local): hxmc.rt.DateText
	@:hxmc.host("Date_fromString") static function fromString(s:String):Dynamic {
		var f:Slice<Int> = Scope.scratch(6);
		switch DateText.parse(hxmc.scoped.Str.view(s), f) {
			case 1:
				return of((f[3] * 3600.0 + f[4] * 60 + f[5]) * 1000.0);
			case 2:
				return make(f[0], f[1] - 1, f[2], 0, 0, 0);
			case 3:
				return make(f[0], f[1] - 1, f[2], f[3], f[4], f[5]);
			case _:
		}
		var n = Str.len(s);
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

	// "%04d-%02d-%02d %02d:%02d:%02d" of the local time: hxmc.rt.DateText
	@:hxmc.host("Date_toString") static function toString(d:Dynamic):String {
		var tm = Repr.dateFields(d);
		var f:Slice<Int> = Scope.scratch(6);
		f[0] = tm.get(Repr.F_YEAR) + Repr.YEAR_BASE;
		f[1] = tm.get(Repr.F_MON) + 1;
		f[2] = tm.get(Repr.F_MDAY);
		f[3] = tm.get(Repr.F_HOUR);
		f[4] = tm.get(Repr.F_MIN);
		f[5] = tm.get(Repr.F_SEC);
		var s = Str.make(DateText.length(f));
		DateText.write(f, hxmc.scoped.Str.view(s));
		return s;
	}

	#if !(hxmc.wasm_gc)
	// ---- Math.random: [0, 1) from rand() (the UCRT's has 15 bits: two make 30)
	@:hxmc.host("Math_random") @:hxmc.noGc static function random():Float {
		if (windows()) return ((LibC.rand() << 15) ^ LibC.rand()) / 1073741824.0;
		return LibC.rand() / 2147483648.0;
	}
	#end
}
