// The tagged words of type parameters' values (hxmc.rt.Tagged; docs/hxmc.md,
// "Values of type parameters"): MemLower's inline encoding (Mem.tagInt,
// tagFloat, tagBool, untag*) against the runtime's (Tagged.ofInt, ofFloat)
// and the expected bits. Round trips of Ints, of Floats (NaN made
// canonical, -0, the infinities, subnormals, the extremes) and of
// references (null, objects, boxes); words of the other kind converted as
// Dynamic converts; words in reference slots through minor and major
// collections (the collector skips them; wasm32's granule table is bounded,
// and RT_VERIFY checks them); and with -D hxmc.verify-tags (the corpus's
// verify lanes), a word read as a reference ending the program, natively
// (a child: the runtime's Mem.addr, generated code's field read).
import hxmc.I64;
import hxmc.rt.Tagged;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

class Obj {
	public var n:Int;

	public function new(n)
		this.n = n;
}

class TaggedWords {
	static var bad = 0;

	static function check(what:String, ok:Bool)
		if (!ok) {
			bad++;
			Sys.println("FAIL " + what);
		}

	static function hex(w:I64):String {
		var s = "";
		for (k in 0...16) {
			var d = ((w >>> (60 - 4 * k)) & 15).toInt();
			s += "0123456789abcdef".charAt(d);
		}
		return s;
	}

	static function bits(f:Float):I64
		return Mem.f64Bits(f);

	static inline function word(hi:Int, lo:Int):I64
		return ((hi : I64) << 32) | (((lo : I64) << 32) >>> 32);

	// the word a reference slot holds for d (read from an array's storage:
	// no raw address kept)
	static function wordOf(d:Dynamic):I64 {
		var a:Array<Dynamic> = [d];
		return Mem.getI64(Mem.getPtr(Mem.addr(a), 8), 0);
	}

	static function main() {
		var args = Sys.args();
		if (args.length > 0) {
			trap(args[0]);
			return;
		}
		Sys.println("Int 5: " + hex(Mem.tagInt(5)) + ", -1: " + hex(Mem.tagInt(-1)));
		Sys.println("Float 1.5: " + hex(Mem.tagFloat(1.5)) + ", -0: " + hex(Mem.tagFloat(-0.0)) + ", NaN: " + hex(Mem.tagFloat(Math.NaN)) + ", -Infinity: "
			+ hex(Mem.tagFloat(Math.NEGATIVE_INFINITY)));
		ints();
		floats();
		refs();
		collections();
		verify();
		Sys.println(bad == 0 ? "all ok" : bad + " failed");
	}

	static function ints() {
		var vs = [0, 1, -1, 5, 127, -128, -129, 1023, 1024, 65535, 65536, 123456789, -987654321, 0x7FFFFFFF, -0x7FFFFFFF - 1];
		for (v in vs) {
			var w = Mem.tagInt(v);
			check('Int $v: inline and runtime', w == Tagged.ofInt(v));
			check('Int $v: the word', w == word(0xFFFF0000, v));
			check('Int $v: kind', Tagged.isScalar(w) && Tagged.isInt(w) && !Tagged.isDouble(w) && Tagged.valid(w));
			check('Int $v: back', Mem.untagInt(w) == v && Tagged.intOf(w) == v);
			check('Int $v: as Float', Mem.untagFloat(w) == v);
			check('Int $v: as Bool', Mem.untagBool(w) == (v != 0));
			var d:Dynamic = Mem.untagDynamic(w);
			check('Int $v: as Dynamic', Std.isOfType(d, Int) && (d : Int) == v && Std.string(d) == Std.string(v));
		}
	}

	static function floats() {
		var vs = [
			0.0, -0.0, 1.5, -1.5, 1 / 3, Math.PI, 1e300, -1e-300, 2147483647.0, 2147483648.5, -2147483649.0, Mem.bitsF64(1), // the least subnormal
			Mem.bitsF64(word(0x80000000, 1)), Mem.bitsF64(word(0x000FFFFF, 0xFFFFFFFF)), // the greatest subnormal
			Mem.bitsF64(word(0x00100000, 0)), // the least normal
			Mem.bitsF64(word(0x7FEFFFFF, 0xFFFFFFFF)), // the greatest
			Mem.bitsF64(word(0xFFEFFFFF, 0xFFFFFFFF)), Math.POSITIVE_INFINITY, Math.NEGATIVE_INFINITY, Math.NaN
		];
		var lo = (1 : I64) << 49, hi = word(0xFFF20000, 0);
		for (v in vs) {
			var w = Mem.tagFloat(v);
			var s = hex(bits(v));
			check('Float $s: inline and runtime', w == Tagged.ofFloat(v));
			check('Float $s: kind', Tagged.isScalar(w) && Tagged.isDouble(w) && !Tagged.isInt(w) && Tagged.valid(w));
			check('Float $s: in range', !Mem.ult(w, lo) && !Mem.ult(hi, w));
			var back = Mem.untagFloat(w);
			if (Math.isNaN(v))
				check('Float $s: NaN', w == word(0x7FFA0000, 0) && Math.isNaN(back) && Math.isNaN(Tagged.floatOf(w)))
			else {
				check('Float $s: the word', w == bits(v) + lo);
				check('Float $s: back', bits(back) == bits(v) && bits(Tagged.floatOf(w)) == bits(v));
			}
			check('Float $s: as Int', Mem.untagInt(w) == Std.int(v));
			check('Float $s: as Bool', Mem.untagBool(w) == (v != 0));
			var d:Dynamic = Mem.untagDynamic(w);
			check('Float $s: as Dynamic', Std.isOfType(d, Float) && (Math.isNaN(v) ? Math.isNaN(d) : bits(d) == bits(v)));
		}
		// NaNs of other bits: the canonical one's word
		for (b in [word(0x7FF00000, 1), word(0x7FFFFFFF, 0xFFFFFFFF), word(0xFFF80000, 0), word(0xFFFFFFFF, 0xFFFFFFFF), word(0xFFF00000, 1)]) {
			var w = Mem.tagFloat(Mem.bitsF64(b));
			check("NaN " + hex(b), w == word(0x7FFA0000, 0) && Tagged.ofFloat(Mem.bitsF64(b)) == w);
		}
		// words outside the encoding
		for (w in [word(0x10000, 0), word(0x1FFFF, 0xFFFFFFFF), word(0xFFFF0001, 0), word(0x7FFA0000, 1), word(0x7FF60000, 0), word(0xFFF20000, 1)])
			check("not a word: " + hex(w), !Tagged.valid(w));
	}

	static function refs() {
		var o = new Obj(7);
		var big:Dynamic = 5000, small:Dynamic = 5, f:Dynamic = 2.5, t:Dynamic = true, no:Dynamic = false, s:Dynamic = "str", n:Dynamic = null;
		var all:Array<Dynamic> = [o, big, small, f, t, no, s, n, [1, 2]];
		for (i in 0...all.length) {
			var w = wordOf(all[i]);
			check('ref $i: below 2^48', (w >>> 48) == (0 : I64) && !Tagged.isScalar(w) && Tagged.valid(w));
			var d:Dynamic = Mem.untagDynamic(w);
			check('ref $i: back', wordOf(d) == w);
		}
		check("ref: the object", (Mem.untagDynamic(wordOf(o)) : Obj).n == 7);
		check("ref: Int boxes", Mem.untagInt(wordOf(big)) == 5000 && Mem.untagInt(wordOf(small)) == 5 && Mem.untagFloat(wordOf(big)) == 5000);
		check("ref: Float box", Mem.untagFloat(wordOf(f)) == 2.5 && Mem.untagInt(wordOf(f)) == 2);
		check("ref: Bool boxes", Mem.untagBool(wordOf(t)) && !Mem.untagBool(wordOf(no)) && Mem.untagInt(wordOf(t)) == 1);
		check("ref: null", Mem.untagInt(0) == 0 && Mem.untagFloat(0) == 0 && !Mem.untagBool(0) && Mem.untagDynamic(0) == null);
		check("ref: not a number", Mem.untagInt(wordOf(s)) == 0 && Mem.untagBool(wordOf(o)));
		check("Bool: its static box", Mem.tagBool(true) == wordOf(t) && Mem.tagBool(false) == wordOf(no));
		check("Bool: back", Mem.untagBool(Mem.tagBool(true)) && !Mem.untagBool(Mem.tagBool(false)));
	}

	// words in an Array<Dynamic>'s storage beside objects, through collections
	static function collections() {
		var n = 64;
		var holder:Array<Dynamic> = [for (i in 0...n) null];
		var want = [];
		for (i in 0...n) {
			var w = switch i % 4 {
				case 0: Mem.tagInt(i * 1000003);
				case 1: Mem.tagFloat(i * 0.37 - 5);
				case 2: Mem.tagFloat(i % 8 == 2 ? Math.NaN : Math.NEGATIVE_INFINITY);
				case _: (0 : I64);
			}
			want.push(w);
			if (i % 4 == 3) holder[i] = "s" + i else Mem.setI64(Mem.getPtr(Mem.addr(holder), 8), 8 * i, w);
		}
		var junk = [];
		for (round in 0...6) {
			for (k in 0...2000)
				junk.push([k, round]);
			if (junk.length > 6000) junk = [];
			hxmc.NativeGc.collect(round % 2 == 1);
		}
		for (i in 0...n) {
			if (i % 4 == 3) check('slot $i: the object', holder[i] == "s" + i) else
				check('slot $i: the word', Mem.getI64(Mem.getPtr(Mem.addr(holder), 8), 8 * i) == want[i]);
		}
	}

	// -D hxmc.verify-tags (Mem.abi("VERIFY_TAGS")): each way of reading a word
	// as a reference ends the child with the message; one line either way
	static function verify() {
		#if !(hxmc.target == "wasm32-wasi" || hxmc.interp || hxmc.run)
		if (Mem.abi("VERIFY_TAGS") == 1)
			for (how in ["runtime", "field"]) {
				var p = new sys.io.Process(Sys.programPath(), [how]);
				var err = p.stderr.readAll().toString();
				var code = p.exitCode();
				p.close();
				// (qemu-user without binfmt: the child cannot start, nothing to check)
				if (code == 127 && err == "") break;
				check('verify-tags: $how (exit $code: $err)', code == 2 && err.indexOf("was read as a reference") >= 0);
			}
		#end
		Sys.println("verify-tags: checked where built with it");
	}

	static function trap(how:String) {
		var d:Dynamic = Mem.obj(new Ptr(Mem.tagInt(5)));
		switch how {
			case "runtime":
				Sys.println(Std.string(d));
			case _:
				var o:Obj = d;
				Sys.println(o.n);
		}
	}
}
