package macros.eval;

import macros.eval.EvalValue;
import macros.eval.EvalEncode.vfun1;
import macros.eval.EvalEncode.vfun2;
import macros.eval.EvalEncode.vfun3;
import macros.eval.EvalDecode.decodeBool;
import macros.eval.EvalDecode.decodeInt;
import macros.eval.EvalExceptions.EvalExceptions.unexpectedValue;

// port: OCaml's `Atomic.t` is a mutable cell (`{v}`) here, whose operations
// are made atomic by one global lock; the compare-and-set retry loops become
// a single locked read-modify-write with the same result. Atomic ints are
// 32-bit Haxe Ints (upstream: 63-bit OCaml ints).
class EvalAtomic {
	static final lock = new sys.thread.Mutex();

	static inline function atomically<T>(f:Void->T):T {
		lock.acquire();
		try {
			var r = f();
			lock.release();
			return r;
		} catch (e:Dynamic) {
			lock.release();
			throw e;
		}
	}

	static function get<T>(a:{v:T}):T return atomically(() -> a.v);

	static function set<T>(a:{v:T}, v:T):Void atomically(() -> {
		a.v = v;
		true;
	});

	static function exchange<T>(a:{v:T}, v:T):T return atomically(() -> {
		var old = a.v;
		a.v = v;
		old;
	});

	public static function asAtomicBool(vthis:Value):{v:Bool} {
		return switch vthis {
			case VInstance({ikind: IAtomicBool(i)}): i;
			case _: unexpectedValue(vthis, "AtomicBool");
		}
	}

	public static function asAtomicInt(vthis:Value):{v:Int} {
		return switch vthis {
			case VInstance({ikind: IAtomicInt(i)}): i;
			case _: unexpectedValue(vthis, "AtomicInt");
		}
	}

	public static function asAtomicObject(vthis:Value):{v:Value} {
		return switch vthis {
			case VInstance({ikind: IAtomicObject(i)}): i;
			case _: unexpectedValue(vthis, "AtomicObject");
		}
	}

	public static final atomicObjectFields:Array<{name:String, value:Value}> = [
		{name: "_hx_new", value: vfun1(v -> EvalEncode.encodeInstance(EvalHash.key_haxe_atomic_AtomicObject, IAtomicObject({v: v})))},
		{name: "load", value: vfun1(v -> get(asAtomicObject(v)))},
		{
			name: "store",
			value: vfun2((a, v) -> {
				set(asAtomicObject(a), v);
				v;
			})
		},
		{name: "exchange", value: vfun2((a, v) -> exchange(asAtomicObject(a), v))},
		{
			name: "compareExchange",
			value: vfun3((vthis, a, b) -> {
				var vthis = asAtomicObject(vthis);
				atomically(() -> {
					var original = vthis.v;
					var realReplacement = if (EvalValueTools.equals(original, a)) b else original;
					vthis.v = realReplacement;
					original;
				});
			})
		},
	];

	public static final atomicBoolFields:Array<{name:String, value:Value}> = [
		{
			name: "_hx_new",
			value: vfun1(v -> EvalEncode.encodeInstance(EvalHash.key_haxe_atomic_AtomicBool, IAtomicBool({v: decodeBool(v)})))
		},
		{name: "load", value: vfun1(v -> EvalValueTools.vbool(get(asAtomicBool(v))))},
		{
			name: "store",
			value: vfun2((a, v) -> {
				var x = decodeBool(v);
				set(asAtomicBool(a), x);
				v;
			})
		},
		{
			name: "exchange",
			value: vfun2((a, v) -> {
				var x = decodeBool(v);
				EvalValueTools.vbool(exchange(asAtomicBool(a), x));
			})
		},
		{
			name: "compareExchange",
			value: vfun3((vthis, a, b) -> {
				var vthis = asAtomicBool(vthis);
				var a = decodeBool(a);
				var b = decodeBool(b);
				EvalValueTools.vbool(atomically(() -> {
					var original = vthis.v;
					var realReplacement = if (original == a) b else original;
					vthis.v = realReplacement;
					original;
				}));
			})
		},
	];

	public static function fetchUpdate(self:{v:Int}, f:Int->Int):Int {
		return atomically(() -> {
			var original = self.v;
			var replacement = f(original);
			self.v = replacement;
			original;
		});
	}

	public static final atomicIntFields:Array<{name:String, value:Value}> = [
		{name: "_hx_new", value: vfun1(v -> EvalEncode.encodeInstance(EvalHash.key_haxe_atomic_AtomicInt, IAtomicInt({v: decodeInt(v)})))},
		{name: "load", value: vfun1(v -> VInt(get(asAtomicInt(v))))},
		{
			name: "store",
			value: vfun2((a, v) -> {
				var x = decodeInt(v);
				set(asAtomicInt(a), x);
				v;
			})
		},
		{
			name: "exchange",
			value: vfun2((a, v) -> {
				var x = decodeInt(v);
				VInt(exchange(asAtomicInt(a), x));
			})
		},
		{
			name: "compareExchange",
			value: vfun3((vthis, a, b) -> {
				var vthis = asAtomicInt(vthis);
				var a = decodeInt(a);
				var b = decodeInt(b);
				VInt(atomically(() -> {
					var original = vthis.v;
					var realReplacement = if (original == a) b else original;
					vthis.v = realReplacement;
					original;
				}));
			})
		},
		{
			name: "add",
			value: vfun2((a, v) -> {
				var d = decodeInt(v);
				var a = asAtomicInt(a);
				VInt(fetchUpdate(a, orig -> orig + d));
			})
		},
		{
			name: "sub",
			value: vfun2((a, v) -> {
				var d = -decodeInt(v);
				var a = asAtomicInt(a);
				VInt(fetchUpdate(a, orig -> orig + d));
			})
		},
		{
			name: "and",
			value: vfun2((a, v) -> {
				var v = decodeInt(v);
				VInt(fetchUpdate(asAtomicInt(a), orig -> orig & v));
			})
		},
		{
			name: "or",
			value: vfun2((a, v) -> {
				var v = decodeInt(v);
				VInt(fetchUpdate(asAtomicInt(a), orig -> orig | v));
			})
		},
		{
			name: "xor",
			value: vfun2((a, v) -> {
				var v = decodeInt(v);
				VInt(fetchUpdate(asAtomicInt(a), orig -> orig ^ v));
			})
		},
	];
}
