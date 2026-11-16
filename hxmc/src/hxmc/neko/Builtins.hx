package hxmc.neko;

import haxe.io.Bytes;
import hxmc.neko.Value;

using hxmc.neko.Builtins.Check;

// argument checks: neko_error() throws the primitive's name
class Check {
	public static inline function int(v:NValue):Int {
		if (!Tag.isInt(v)) throw Builtins.failure;
		return v.asInt();
	}

	public static inline function str(v:NValue):NStr {
		if (!Tag.isString(v)) throw Builtins.failure;
		return v.asStr();
	}

	public static inline function arr(v:NValue):NArr {
		if (!Tag.isArray(v)) throw Builtins.failure;
		return v.asArr();
	}

	public static inline function obj(v:NValue):NObj {
		if (!Tag.isObject(v)) throw Builtins.failure;
		return v.asObj();
	}

	public static inline function fun(v:NValue):NFun {
		if (!Tag.isFunction(v)) throw Builtins.failure;
		return v.asFun();
	}

	public static inline function float(v:NValue):Float {
		if (!Tag.isFloat(v)) throw Builtins.failure;
		return v.asFloat();
	}

	public static inline function number(v:NValue):Float {
		if (!Tag.isFloat(v) && !Tag.isInt(v)) throw Builtins.failure;
		return v.asFloat();
	}

	public static inline function bool(v:NValue):Bool {
		if (!Tag.isBool(v)) throw Builtins.failure;
		return v.asBool();
	}

	public static inline function abs(v:NValue, kind:String):Dynamic {
		if (!Tag.isAbstract(v) || v.asAbs().kind != kind) throw Builtins.failure;
		return v.asAbs().data;
	}
}

// a neko_error() of a primitive: the thrown value is the primitive's name,
// which the call (VM.callPrim) fills in
class Failure {
	public function new() {}
}

// neko/vm/builtins.c
class Builtins {
	public static final failure = new Failure();

	static var builtins:NObj;
	static final lock = new sys.thread.Mutex();

	public static function get():NObj {
		lock.acquire();
		if (builtins == null) builtins = make();
		lock.release();
		return builtins;
	}

	static function make():NObj {
		var o = new NObj();
		function add(name:String, nargs:Int, f:Prim)
			o.set(Fields.id(name), prim("$" + name, nargs, f));
		add("print", -1, (vm, a) -> {
			for (v in a)
				vm.print(vm.toBytes(v));
			return null;
		});
		add("array", -1, (vm, a) -> a.toArray());
		add("amake", 1, (vm, a) -> {
			var n = a[0].int();
			if (n < 0) throw failure;
			var r:NArr = [for (_ in 0...n) null];
			return r;
		});
		add("acopy", 1, (vm, a) -> a[0].arr().copy());
		add("asize", 1, (vm, a) -> a[0].arr().length);
		add("asub", 3, (vm, a) -> {
			var arr = a[0].arr(), p = a[1].int(), l = a[2].int();
			if (p < 0 || l < 0 || p + l < 0 || p + l > arr.length) throw failure;
			return arr.slice(p, p + l);
		});
		add("ablit", 5, (vm, a) -> {
			var dst = a[0].arr(), dp = a[1].int(), src = a[2].arr(), sp = a[3].int(), l = a[4].int();
			if (dp < 0 || sp < 0 || l < 0 || dp + l < 0 || sp + l < 0 || dp + l > dst.length || sp + l > src.length) throw failure;
			if (dst == src && dp > sp) {
				var i = l;
				while (i-- > 0)
					dst[dp + i] = src[sp + i];
			} else
				for (i in 0...l)
					dst[dp + i] = src[sp + i];
			return null;
		});
		add("aconcat", 1, (vm, a) -> {
			var r:NArr = [];
			for (x in a[0].arr())
				r = r.concat(x.arr());
			return r;
		});
		add("smake", 1, (vm, a) -> {
			var n = a[0].int();
			if (n < 0) throw failure;
			var b = Bytes.alloc(n);
			b.fill(0, n, 0);
			return new NStr(b);
		});
		add("ssize", 1, (vm, a) -> a[0].str().b.length);
		add("scopy", 1, (vm, a) -> new NStr(a[0].str().b.sub(0, a[0].str().b.length)));
		add("ssub", 3, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int(), l = a[2].int();
			if (p < 0 || l < 0 || p + l < 0 || p + l > s.length) throw failure;
			return new NStr(s.sub(p, l));
		});
		add("sget", 2, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int();
			return p < 0 || p >= s.length ? null : s.get(p);
		});
		add("sset", 3, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int(), c = a[2].int();
			if (p < 0 || p >= s.length) return (null : NValue);
			s.set(p, c & 0xFF);
			return c & 0xFF;
		});
		add("sblit", 5, (vm, a) -> {
			var dst = a[0].str().b, dp = a[1].int(), src = a[2].str().b, sp = a[3].int(), l = a[4].int();
			if (dp < 0 || sp < 0 || l < 0 || dp + l < 0 || sp + l < 0 || dp + l > dst.length || sp + l > src.length) throw failure;
			dst.blit(dp, src, sp, l);
			return null;
		});
		add("sfind", 3, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int(), pat = a[2].str().b;
			var l = s.length, l2 = pat.length;
			if (p < 0 || p >= l) throw failure;
			while (l - p >= l2) {
				var ok = true;
				for (i in 0...l2)
					if (s.get(p + i) != pat.get(i)) {
						ok = false;
						break;
					}
				if (ok) return (p : NValue);
				p++;
			}
			return null;
		});
		add("sget16", 3, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int();
			if (p < 0 || p + 2 > s.length) return (null : NValue);
			var v = s.getUInt16(p);
			if (a[2] == true) v = ((v & 0xFF) << 8) | (v >> 8);
			return v;
		});
		add("sget32", 3, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int();
			if (p < 0 || p + 4 > s.length) return (null : NValue);
			var v = s.getInt32(p);
			if (a[2] == true) v = swap32(v);
			return v;
		});
		add("sgetf", 3, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int();
			if (p < 0 || p + 4 > s.length) return (null : NValue);
			var v = s.getInt32(p);
			if (a[2] == true) v = swap32(v);
			return (haxe.io.FPHelper.i32ToFloat(v) : Float);
		});
		add("sgetd", 3, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int();
			if (p < 0 || p + 8 > s.length) return (null : NValue);
			var lo = s.getInt32(p), hi = s.getInt32(p + 4);
			if (a[2] == true) {
				var t = swap32(lo);
				lo = swap32(hi);
				hi = t;
			}
			return haxe.io.FPHelper.i64ToDouble(lo, hi);
		});
		add("sset16", 4, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int(), v = a[2].int();
			if (p < 0 || p + 2 > s.length) throw failure;
			if (a[3] == true) v = ((v & 0xFF) << 8) | ((v >> 8) & 0xFF);
			s.setUInt16(p, v & 0xFFFF);
			return null;
		});
		add("sset32", 4, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int(), v = a[2].int();
			if (p < 0 || p + 4 > s.length) throw failure;
			if (a[3] == true) v = swap32(v);
			s.setInt32(p, v);
			return null;
		});
		add("ssetf", 4, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int(), f = a[2].float();
			if (p < 0 || p + 4 > s.length) throw failure;
			var v = haxe.io.FPHelper.floatToI32(f);
			if (a[3] == true) v = swap32(v);
			s.setInt32(p, v);
			return null;
		});
		add("ssetd", 4, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int(), f = a[2].float();
			if (p < 0 || p + 8 > s.length) throw failure;
			var i = haxe.io.FPHelper.doubleToI64(f);
			var lo = i.low, hi = i.high;
			if (a[3] == true) {
				var t = swap32(lo);
				lo = swap32(hi);
				hi = t;
			}
			s.setInt32(p, lo);
			s.setInt32(p + 4, hi);
			return null;
		});
		add("itof", 2, (vm, a) -> {
			var v = a[0].int();
			if (a[1] == true) v = swap32(v);
			return (haxe.io.FPHelper.i32ToFloat(v) : Float);
		});
		add("ftoi", 2, (vm, a) -> {
			var v = haxe.io.FPHelper.floatToI32(a[0].float());
			if (a[1] == true) v = swap32(v);
			return v;
		});
		add("itod", 3, (vm, a) -> {
			var lo = a[0].int(), hi = a[1].int();
			if (a[2] == true) {
				var t = swap32(lo);
				lo = swap32(hi);
				hi = t;
			}
			return haxe.io.FPHelper.i64ToDouble(lo, hi);
		});
		add("dtoi", 3, (vm, a) -> {
			var f = a[0].float(), out = a[1].arr();
			if (out.length < 2) throw failure;
			var i = haxe.io.FPHelper.doubleToI64(f);
			if (a[2] == true) {
				out[1] = swap32(i.low);
				out[0] = swap32(i.high);
			} else {
				out[0] = i.low;
				out[1] = i.high;
			}
			return null;
		});
		add("isbigendian", 0, (vm, a) -> false);
		add("new", 1, (vm, a) -> {
			if (a[0] != null && !Tag.isObject(a[0])) throw failure;
			return VM.newObject(a[0]);
		});
		add("objget", 2, (vm, a) -> {
			if (!Tag.isObject(a[0])) return (null : NValue);
			return a[0].asObj().get(a[1].int());
		});
		add("objset", 3, (vm, a) -> {
			if (!Tag.isObject(a[0])) return (null : NValue);
			a[0].asObj().set(a[1].int(), a[2]);
			return a[2];
		});
		add("objcall", 3, (vm, a) -> {
			if (!Tag.isObject(a[0])) return (null : NValue);
			var o = a[0].asObj();
			var f = o.get(a[1].int());
			return vm.callEx(o, f, a[2].arr().copy());
		});
		add("objfield", 2, (vm, a) -> {
			var id = a[1].int();
			return Tag.isObject(a[0]) && a[0].asObj().hasOwn(id);
		});
		add("objremove", 2, (vm, a) -> a[0].obj().remove(a[1].int()));
		add("objfields", 1, (vm, a) -> {
			var o = a[0].obj();
			var r:NArr = [for (i in 0...o.n) o.ids[i]];
			return r;
		});
		add("hash", 1, (vm, a) -> Fields.idBytes(a[0].str().b));
		add("fasthash", 1, (vm, a) -> Fields.hash(a[0].str().b));
		add("field", 1, (vm, a) -> {
			var n = Fields.nameBytes(a[0].int());
			return n == null ? null : new NStr(n);
		});
		add("objsetproto", 2, (vm, a) -> {
			var o = a[0].obj();
			o.proto = a[1] == null ? null : a[1].obj();
			return null;
		});
		add("objgetproto", 1, (vm, a) -> a[0].obj().proto);
		add("int", 1, (vm, a) -> toInt(a[0]));
		add("float", 1, (vm, a) -> {
			var v:NValue = a[0];
			if (Tag.isString(v)) return strtod(v.asStr().b);
			if (Tag.isInt(v) || Tag.isFloat(v)) return (v.asFloat() : NValue);
			return null;
		});
		add("string", 1, (vm, a) -> {
			var b = vm.toBytes(a[0]);
			return new NStr(b.sub(0, b.length));
		});
		add("typeof", 1, (vm, a) -> Tag.of(a[0]));
		add("closure", -1, (vm, a) -> {
			if (a.length <= 1) throw VM.error("Invalid closure arguments number");
			var f = a[0].fun();
			if (f.nargs != -1 && f.nargs < a.length - 2) throw VM.error("Invalid closure arguments number");
			return prim("closure_callback", -1, closureCallback, a.toArray());
		});
		add("apply", -1, (vm, a) -> {
			if (a.length < 1) throw failure;
			var f = a[0].fun();
			var args = [for (i in 1...a.length) a[i]];
			if (args.length == 0) return f;
			if (f.nargs == args.length || f.nargs == -1) return vm.callN(f, args);
			if (args.length > f.nargs) throw failure;
			var env:NArr = [f];
			for (x in args)
				env.push(x);
			while (env.length < f.nargs + 1)
				env.push(null);
			return applyClosure(f.nargs - args.length, env);
		});
		add("varargs", 1, (vm, a) -> {
			var f = a[0].fun();
			if (f.nargs != 1 && f.nargs != -1) throw failure;
			return prim("varargs", -1, (vm, args) -> vm.callN(vm.env, [args.toArray()]), f);
		});
		add("compare", 2, (vm, a) -> {
			var r = vm.compare(a[0], a[1]);
			return r == VM.INVALID ? null : r;
		});
		add("pcompare", 2, (vm, a) -> {
			if (Tag.isInt(a[0]) && Tag.isInt(a[1])) {
				var x = a[0].asInt(), y = a[1].asInt();
				return x == y ? 0 : (x < y ? -1 : 1);
			}
			return VM.same(a[0], a[1]) ? 0 : 1;
		});
		add("not", 1, (vm, a) -> VM.isFalse(a[0]));
		add("istrue", 1, (vm, a) -> !VM.isFalse(a[0]));
		add("throw", 1, (vm, a) -> throw new NekoError(a[0]));
		add("rethrow", 1, (vm, a) -> {
			var ne = new NekoError(a[0]);
			ne.rethrown = true;
			throw ne;
		});
		add("nargs", 1, (vm, a) -> a[0].fun().nargs);
		add("call", 3, (vm, a) -> vm.callEx(a[1], a[0], a[2].arr().copy()));
		add("isnan", 1, (vm, a) -> Tag.isFloat(a[0]) && Math.isNaN(a[0].asFloat()));
		add("isinfinite", 1, (vm, a) -> Tag.isFloat(a[0]) && !Math.isNaN(a[0].asFloat()) && !Math.isFinite(a[0].asFloat()));
		add("getkind", 1, (vm, a) -> {
			if (!Tag.isAbstract(a[0])) throw failure;
			return new NAbs("kind", a[0].asAbs().kind);
		});
		add("iskind", 2, (vm, a) -> {
			var k = a[1].abs("kind");
			return Tag.isAbstract(a[0]) && a[0].asAbs().kind == k;
		});
		add("hnew", 1, (vm, a) -> new NAbs("hash", new NHash(a[0].int())));
		add("hget", 3, (vm, a) -> a[0].abs("hash").get(vm, a[1], cmpFun(a[2])));
		add("hmem", 3, (vm, a) -> a[0].abs("hash").mem(vm, a[1], cmpFun(a[2])));
		add("hset", 4, (vm, a) -> a[0].abs("hash").set(vm, a[1], a[2], cmpFun(a[3])));
		add("hadd", 3, (vm, a) -> {
			a[0].abs("hash").add(vm, a[1], a[2]);
			return null;
		});
		add("hremove", 3, (vm, a) -> a[0].abs("hash").remove(vm, a[1], cmpFun(a[2])));
		add("hresize", 2, (vm, a) -> {
			a[0].abs("hash").resize(a[1].int());
			return null;
		});
		add("hkey", 1, (vm, a) -> NHash.hashOf(a[0]));
		add("hcount", 1, (vm, a) -> (a[0].abs("hash") : NHash).nitems);
		add("hsize", 1, (vm, a) -> (a[0].abs("hash") : NHash).cells.length);
		add("hiter", 2, (vm, a) -> {
			var h:NHash = a[0].abs("hash");
			var f = a[1].fun();
			for (c in h.cells) {
				var c = c;
				while (c != null) {
					vm.callN(f, [c.key, c.val]);
					c = c.next;
				}
			}
			return null;
		});
		add("iadd", 2, (vm, a) -> a[0].asInt() + a[1].asInt());
		add("isub", 2, (vm, a) -> a[0].asInt() - a[1].asInt());
		add("imult", 2, (vm, a) -> a[0].asInt() * a[1].asInt());
		add("idiv", 2, (vm, a) -> {
			if (a[1].asInt() == 0) throw failure;
			return Std.int(a[0].asInt() / a[1].asInt());
		});
		add("excstack", 0, (vm, a) -> vm.excStack.copy());
		add("callstack", 0, (vm, a) -> vm.callStack());
		add("version", 0, (vm, a) -> 240);
		add("neko_build_year", 0, (vm, a) -> 2024);
		add("setresolver", 1, (vm, a) -> {
			vm.resolver = a[0] == null ? null : a[0].fun();
			return null;
		});
		return o;
	}

	static function cmpFun(v:NValue):NValue {
		if (v != null) v.fun();
		return v;
	}

	public static function prim(name:String, nargs:Int, f:Prim, ?env:NValue):NFun {
		// (a Failure thrown is the primitive's name: VM.wrap, by the primitive the VM called last)
		return NFun.primitive(name, nargs, f, env);
	}

	static inline function swap32(v:Int):Int
		return ((v >>> 24) & 0xFF) | ((v >> 8) & 0xFF00) | ((v & 0xFF00) << 8) | (v << 24);

	static function closureCallback(vm:VM, args:haxe.ds.Vector<NValue>):NValue {
		var env = vm.env.asArr();
		var f = env[0].asFun();
		var o:NValue = env[1];
		var cargs = env.length - 2;
		if (f.nargs != cargs + args.length && f.nargs != -1) return (null : NValue);
		var a = env.slice(2).concat(args.toArray());
		return vm.callEx(o, f, a);
	}

	// a partial application: env = [f, the given arguments, the missing ones]
	public static function applyClosure(nargs:Int, env:NArr):NFun {
		if (nargs < 1 || nargs > 5) throw VM.error("Too many apply arguments");
		return NFun.primitive("apply", nargs, (vm, args) -> {
			var e = vm.env.asArr();
			var a = e.slice(1);
			var n = a.length;
			for (i in 0...args.length)
				a[n - args.length + i] = args[i];
			return vm.callN(e[0], a);
		}, env);
	}

	// $int
	public static function toInt(v:NValue):NValue {
		if (Tag.isFloat(v)) {
			var f = v.asFloat();
			// (fmod by 2^32, then to unsigned: the low 32 bits)
			if (Math.isNaN(f) || !Math.isFinite(f)) return 0;
			var m = f % 4294967296.0;
			if (m < 0) m += 4294967296.0;
			var t = Math.ffloor(m);
			return t >= 2147483648.0 ? Std.int(t - 4294967296.0) : Std.int(t);
		}
		if (Tag.isString(v)) {
			var s = v.asStr().b;
			var i = 0;
			while (i < s.length && isSpace(s.get(i)))
				i++;
			var sign = i < s.length ? s.get(i) : 0;
			var signed = sign == "-".code || sign == "+".code;
			var j = signed ? i + 1 : i;
			if (j + 1 < s.length && s.get(j) == "0".code && (s.get(j + 1) == "x".code || s.get(j + 1) == "X".code)) {
				var h = 0;
				j += 2;
				while (j < s.length) {
					var k = s.get(j++);
					if (k >= "0".code && k <= "9".code) h = (h << 4) | (k - "0".code) else if (k >= "A".code && k <= "F".code) h = (h << 4) | (k - "A".code + 10) else
						if (k >= "a".code && k <= "f".code) h = (h << 4) | (k - "a".code + 10) else break;
				}
				return sign == "-".code ? -h : h;
			}
			// strtol, the result as a C int
			var neg = sign == "-".code;
			var start = j;
			var h:Float = 0;
			while (j < s.length && s.get(j) >= "0".code && s.get(j) <= "9".code) {
				h = h * 10 + (s.get(j) - "0".code);
				j++;
			}
			if (j == start) return (null : NValue);
			if (neg) h = -h;
			// (strtol saturates at long's range, then the int cast keeps the low bits)
			if (h > 9223372036854775807.0) h = 9223372036854775807.0;
			if (h < -9223372036854775808.0) h = -9223372036854775808.0;
			return lowBits(h);
		}
		if (Tag.isInt(v)) return v;
		return null;
	}

	static function lowBits(h:Float):Int {
		if (h >= -2147483648.0 && h <= 2147483647.0) return Std.int(h);
		var m = h % 4294967296.0;
		if (m < 0) m += 4294967296.0;
		return m >= 2147483648.0 ? Std.int(m - 4294967296.0) : Std.int(m);
	}

	static inline function isSpace(c:Int):Bool
		return c == " ".code || (c >= 9 && c <= 13);

	// strtod's longest prefix, null when there is none
	public static function strtod(s:Bytes):NValue {
		var i = 0;
		while (i < s.length && isSpace(s.get(i)))
			i++;
		var start = i;
		if (i < s.length && (s.get(i) == "-".code || s.get(i) == "+".code)) i++;
		var rest = s.getString(i, s.length - i).toLowerCase();
		if (StringTools.startsWith(rest, "inf") || StringTools.startsWith(rest, "nan")) {
			var v = StringTools.startsWith(rest, "nan") ? Math.NaN : Math.POSITIVE_INFINITY;
			return s.get(start) == "-".code ? -v : v;
		}
		var digits = 0;
		while (i < s.length && s.get(i) >= "0".code && s.get(i) <= "9".code) {
			i++;
			digits++;
		}
		if (i < s.length && s.get(i) == ".".code) {
			i++;
			while (i < s.length && s.get(i) >= "0".code && s.get(i) <= "9".code) {
				i++;
				digits++;
			}
		}
		if (digits == 0) return (null : NValue);
		if (i < s.length && (s.get(i) == "e".code || s.get(i) == "E".code)) {
			var j = i + 1;
			if (j < s.length && (s.get(j) == "-".code || s.get(j) == "+".code)) j++;
			var ed = j;
			while (j < s.length && s.get(j) >= "0".code && s.get(j) <= "9".code)
				j++;
			if (j > ed) i = j;
		}
		var f:Float = Std.parseFloat(s.getString(start, i - start));
		return f;
	}
}

class HCell {
	public var hkey:Int;
	public var key:NValue;
	public var val:NValue;
	public var next:Null<HCell>;

	public function new(hkey, key, val, next) {
		this.hkey = hkey;
		this.key = key;
		this.val = val;
		this.next = next;
	}
}

// $hnew's tables (val_hash, builtin_h*)
class NHash {
	public var cells:Array<Null<HCell>>;
	public var nitems = 0;

	public function new(size:Int) {
		if (size <= 0) size = 7;
		cells = [for (_ in 0...size) null];
	}

	public static function hashOf(v:NValue):Int {
		var h = [0];
		hashRec(v, h, []);
		return h[0] & 0x3FFFFFFF;
	}

	static inline function big(h:Array<Int>, x:Int)
		h[0] = h[0] * 65599 + x;

	static inline function small(h:Array<Int>, x:Int)
		h[0] = h[0] * 19 + x;

	// (C's char is signed)
	static inline function schar(c:Int):Int
		return c >= 128 ? c - 256 : c;

	static function hashRec(v:NValue, h:Array<Int>, l:NArr) {
		switch Tag.of(v) {
			case Tag.TINT:
				big(h, v.asInt());
			case Tag.TNULL:
				small(h, 0);
			case Tag.TFLOAT:
				var i = haxe.io.FPHelper.doubleToI64(v.asFloat());
				var k = 8;
				while (k > 0) {
					k--;
					var w = k >= 4 ? i.high : i.low;
					small(h, schar((w >>> ((k & 3) * 8)) & 0xFF));
				}
			case Tag.TBOOL:
				small(h, v.asBool() ? 1 : 0);
			case Tag.TSTRING:
				var b = v.asStr().b;
				var k = b.length;
				while (k > 0)
					small(h, schar(b.get(--k)));
			case Tag.TOBJECT | Tag.TARRAY:
				for (k in 0...l.length)
					if (l[l.length - 1 - k] == v) {
						small(h, k);
						return;
					}
				l.push(v);
				if (Tag.isObject(v)) {
					var o = v.asObj();
					for (i in 0...o.n) {
						big(h, o.ids[i]);
						hashRec(o.vals[i], h, l);
					}
					if (o.proto != null) hashRec(o.proto, h, l);
				} else {
					var a = v.asArr();
					var k = a.length;
					while (k > 0)
						hashRec(a[--k], h, l);
				}
				l.pop();
			case _:
		}
	}

	function same(vm:VM, key:NValue, k:NValue, cmp:NValue):Bool {
		if (cmp == null) return vm.compare(key, k) == 0;
		var r = vm.callN(cmp, [key, k]);
		return Tag.isInt(r) && r.asInt() == 0;
	}

	public function get(vm:VM, key:NValue, cmp:NValue):NValue {
		var c = cells[hashOf(key) % cells.length];
		while (c != null) {
			if (same(vm, key, c.key, cmp)) return c.val;
			c = c.next;
		}
		return null;
	}

	public function mem(vm:VM, key:NValue, cmp:NValue):Bool {
		var c = cells[hashOf(key) % cells.length];
		while (c != null) {
			if (same(vm, key, c.key, cmp)) return true;
			c = c.next;
		}
		return false;
	}

	public function remove(vm:VM, key:NValue, cmp:NValue):Bool {
		var k = hashOf(key) % cells.length;
		var c = cells[k], prev:HCell = null;
		while (c != null) {
			if (same(vm, key, c.key, cmp)) {
				if (prev == null) cells[k] = c.next else prev.next = c.next;
				nitems--;
				return true;
			}
			prev = c;
			c = c.next;
		}
		return false;
	}

	public function set(vm:VM, key:NValue, val:NValue, cmp:NValue):Bool {
		var hkey = hashOf(key);
		var c = cells[hkey % cells.length];
		while (c != null) {
			if (same(vm, key, c.key, cmp)) {
				c.val = val;
				return false;
			}
			c = c.next;
		}
		insert(hkey, key, val);
		return true;
	}

	public function add(vm:VM, key:NValue, val:NValue) {
		insert(hashOf(key), key, val);
	}

	function insert(hkey:Int, key:NValue, val:NValue) {
		if (nitems >= cells.length << 1) resize(cells.length << 1);
		var k = hkey % cells.length;
		cells[k] = new HCell(hkey, key, val, cells[k]);
		nitems++;
	}

	public function resize(size:Int) {
		if (size <= 0) size = 7;
		var cc:Array<Null<HCell>> = [for (_ in 0...size) null];
		// (add_rec: each chain from its end, so it keeps its order)
		for (c in cells) {
			var chain = [];
			var c = c;
			while (c != null) {
				chain.push(c);
				c = c.next;
			}
			var i = chain.length;
			while (i-- > 0) {
				var x = chain[i];
				var k = x.hkey % size;
				x.next = cc[k];
				cc[k] = x;
			}
		}
		cells = cc;
	}
}
