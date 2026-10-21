/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

package macros.eval;

import core.Globals;
import core.Globals.Pos;
import core.ds.Failure;
import core.ds.InvalidArgument;
import core.ds.NotFound;
import core.ds.GlobalsIntMap;
import core.ds.OcamlHashtbl;
import haxe.io.Bytes;
import macros.eval.EvalStdLibA.Zresult;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalHash;
import macros.eval.EvalString;
import macros.eval.EvalEncode;
import macros.eval.EvalDecode;
import macros.eval.EvalExceptions;
import macros.eval.EvalPrinting;
import macros.eval.EvalMisc;
import macros.eval.EvalField;
import macros.eval.EvalStdLib;
import macros.eval.EvalStdLibA;
import macros.eval.EvalStdLibA.StdCompress;
import compiler.io.CompilerIo;
import haxe.ds.Vector;

using macros.eval.EvalValue.EvalValueTools;
// port: the host natives of hxmc (hxmc/std)
#if (target.name == "hxmc")
import hxmc.NativeNet;
#end

// port: haxe/src/macro/eval/evalStdLib.ml, second half (lines 1485-3367: `StdLog` ..
// `StdNativeString`; `lineEnd` is `EvalStdLibA.lineEnd`). Each `module StdX` is class `StdX`.
//
// Deviations (see also the comments at each site):
// - Natives are `static final` values; upstream aliases between modules
//   (`fastCodeAt = StdString.charCodeAt`, ...) are read-only properties so they
//   do not depend on the static initialisation order of the classes.
// - `Math.random`/`Std.random` use the host generator instead of OCaml's
//   `Random.State`.
// - Sockets (`eval.vm.NativeSocket`) use BSD sockets through `hxmc.NativeNet`
//   on the hxmc host (hxmc/) and `EvalHostNet` on HashLink; on other hosts
//   every native throws a clear error.
// - Threads are host threads: `exit` of a `Thread`-mode thread behaves as
//   upstream's `Domain` branch (there is no `Thread.exit`), and `join` waits
//   for the thread's `finished` lock.
// - `sys.thread.Condition` keeps its own mutex on the host: acquire/release/wait
//   use the condition's lock instead of `Vcondition.cmutex`.
// - zlib streams (`Vzlib.z`) are libs.extc.Extc streams (see `StdCompress`).
// - `haxe.Resource.listNames` follows the host map's key order (OCaml `Hashtbl`
//   order cannot be reproduced).
class StdLibBHelpers {
	public static function encodeListIterator(l:Array<Value>):Value {
		var l = l;
		return EvalEncode.encodeObj([
			{
				name: EvalHash.key_hasNext,
				value: EvalEncode.vifun0(_ -> l.length == 0 ? VFalse : VTrue)
			},
			{
				name: EvalHash.key_next,
				value: EvalEncode.vifun0(_ -> {
					if (l.length == 0) VNull
					else {
						var v = l[0];
						l = l.slice(1);
						v;
					}
				})
			}
		]);
	}

	public static function mapKeyValueIterator(path:Int):Value {
		return EvalEncode.vifun0(vthis -> {
			var ctx = EvalContext.getCtx();
			var vit = EvalEncode.encodeInstance(path);
			var fnew = EvalContext.getInstanceConstructor(ctx, path, Globals.nullPos);
			EvalPrinting.callValueOn(vit, fnew.force(), [vthis]);
			vit;
		});
	}

	// port: `List.nth`: Failure "nth" past the end, Invalid_argument "List.nth" for a negative index.
	public static function listNth<T>(l:Array<T>, n:Int):T {
		if (n < 0) throw new InvalidArgument("List.nth");
		if (n >= l.length) throw new Failure("nth");
		return l[n];
	}

	// port: physical equality (`==`) on values.
	public static function physicalEquals(a:Value, b:Value):Bool {
		return switch [a, b] {
			case [VNull, VNull] | [VTrue, VTrue] | [VFalse, VFalse]: true;
			case [VEnumValue(a), VEnumValue(b)]: a == b;
			case [VObject(a), VObject(b)]: a == b;
			case [VInstance(a), VInstance(b)]: a == b;
			case [VString(a), VString(b)]: a == b;
			case [VArray(a), VArray(b)]: a == b;
			case [VVector(a), VVector(b)]: a == b;
			case [VPrototype(a), VPrototype(b)]: a == b;
			case [VNativeString(a), VNativeString(b)]: a == b;
			case [VHandle(a), VHandle(b)]: a == b;
			case [VLazy(a), VLazy(b)]: a == b;
			case _: false;
		}
	}

	// port: OCaml `int_of_float` (amd64) followed by `Int32.of_int`.
	public static function intOfFloat(f:Float):Int {
		if (Math.isNaN(f) || f >= 9223372036854775808.0 || f <= -9223372036854775808.0) return 0;
		var t = f < 0 ? Math.fceil(f) : Math.ffloor(f);
		var m = t % 4294967296.0;
		if (m >= 2147483648.0) m -= 4294967296.0;
		if (m < -2147483648.0) m += 4294967296.0;
		return Std.int(m);
	}

	// port: host errors standing for upstream's `Failure`/`Unix_error` in `process_catch`.
	public static function processCatch<A, B>(f:A->B, arg:A):B {
		try {
			return f(arg);
		} catch (e:RunTimeException) {
			throw e;
		} catch (e:NotFound) {
			throw e;
		} catch (e:Failure) {
			return EvalContext.excString(e.message);
		} catch (e:haxe.Exception) {
			return EvalContext.excString(e.message);
		}
	}

	public static function socketsNotSupported():Dynamic {
		return EvalContext.excString("Sockets (eval.vm.NativeSocket) are not supported by haxe-in-haxe");
	}
}

class StdLog {
	static final key_fileName = EvalHash.hash("fileName");
	static final key_lineNumber = EvalHash.hash("lineNumber");
	static final key_customParams = EvalHash.hash("customParams");

	public static final trace = EvalEncode.vfun2((v, infos) -> {
		var s = EvalPrinting.valueString(v);
		var s = switch infos {
				case VNull: s + EvalStdLibA.lineEnd;
				case _:
					var infos = EvalDecode.decodeObject(infos);
					var fileName = EvalDecode.decodeString(EvalField.objectField(infos, key_fileName));
					var lineNumber = EvalDecode.decodeInt(EvalField.objectField(infos, key_lineNumber));
					var l = switch EvalField.objectField(infos, key_customParams) {
							case VArray(va): [s].concat([for (v in EvalArray.toList(va)) EvalPrinting.valueString(v)]);
							case _: [s];
						}
					'$fileName:$lineNumber: ${l.join(",")}' + EvalStdLibA.lineEnd;
			}
		CompilerIo.writeOut(EvalContext.getCtx().curapi.getCom().requestScope.io, s);
		VNull;
	});
}

class StdIntMap {
	static function thisValue(vthis:Value):RuntimeIntHashtbl<Value> {
		return switch vthis {
			case VInstance({ikind: IIntMap(h)}): h;
			case v: EvalExceptions.unexpectedValue(v, "int map");
		}
	}

	public static final copy = EvalEncode.vifun0(vthis -> {
		var copied = thisValue(vthis).copy();
		EvalEncode.encodeIntMapDirect(copied);
	});

	public static final exists = EvalEncode.vifun1((vthis, vkey) -> {
		(thisValue(vthis).mem(EvalDecode.decodeInt(vkey))).vbool();
	});

	public static final get = EvalEncode.vifun1((vthis, vkey) -> {
		try thisValue(vthis).find(EvalDecode.decodeInt(vkey))
		catch (_:NotFound) VNull;
	});

	public static final iterator = EvalEncode.vifun0(vthis -> {
		var keys = thisValue(vthis).fold((_, v, acc:Array<Value>) -> {
			acc.push(v);
			acc;
		}, []);
		keys.reverse();
		StdLibBHelpers.encodeListIterator(keys);
	});

	public static final keys = EvalEncode.vifun0(vthis -> {
		var keys = thisValue(vthis).fold((k, _, acc:Array<Value>) -> {
			acc.push(k.vint());
			acc;
		}, []);
		keys.reverse();
		StdLibBHelpers.encodeListIterator(keys);
	});

	public static final keyValueIterator = StdLibBHelpers.mapKeyValueIterator(EvalHash.key_haxe_iterators_map_key_value_iterator);

	public static final remove = EvalEncode.vifun1((vthis, vkey) -> {
		var self = thisValue(vthis);
		var key = EvalDecode.decodeInt(vkey);
		var b = self.mem(key);
		self.remove(key);
		b.vbool();
	});

	public static final set = EvalEncode.vifun2((vthis, vkey, vvalue) -> {
		thisValue(vthis).add(EvalDecode.decodeInt(vkey), vvalue);
		VNull;
	});

	public static final toString = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		var l = self.fold((key, vvalue, acc:Array<Vstring>) -> {
			acc.push(EvalString.join(EvalString.emptyString, [
				EvalString.createAscii(Std.string(key)),
				EvalString.createAscii(" => "),
				EvalPrinting.sValue(0, vvalue)
			]));
			acc;
		}, []);
		l.reverse();
		var s = EvalString.join(EvalPrinting.rcomma, l);
		var s = EvalString.join(EvalString.emptyString, [EvalPrinting.rbkopen, s, EvalPrinting.rbkclose]);
		VString(s);
	});

	public static final clear = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).clear();
		VNull;
	});

	public static final size = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).size().vint();
	});
}

class StdInt64Map {
	static function thisValue(vthis:Value):RuntimeInt64Hashtbl<Value> {
		return switch vthis {
			case VInstance({ikind: IInt64Map(h)}): h;
			case v: EvalExceptions.unexpectedValue(v, "int64 map");
		}
	}

	public static final copy = EvalEncode.vifun0(vthis -> {
		var copied = thisValue(vthis).copy();
		EvalEncode.encodeInt64MapDirect(copied);
	});

	public static final exists = EvalEncode.vifun1((vthis, vkey) -> {
		(thisValue(vthis).mem(EvalIntegers.decodeI64(vkey))).vbool();
	});

	public static final get = EvalEncode.vifun1((vthis, vkey) -> {
		try thisValue(vthis).find(EvalIntegers.decodeI64(vkey))
		catch (_:NotFound) VNull;
	});

	public static final iterator = EvalEncode.vifun0(vthis -> {
		var keys = thisValue(vthis).fold((_, v, acc:Array<Value>) -> {
			acc.push(v);
			acc;
		}, []);
		keys.reverse();
		StdLibBHelpers.encodeListIterator(keys);
	});

	public static final keys = EvalEncode.vifun0(vthis -> {
		var keys = thisValue(vthis).fold((k, _, acc:Array<Value>) -> {
			acc.push(k.vint64());
			acc;
		}, []);
		keys.reverse();
		StdLibBHelpers.encodeListIterator(keys);
	});

	public static final keyValueIterator = StdLibBHelpers.mapKeyValueIterator(EvalHash.key_haxe_iterators_map_key_value_iterator);

	public static final remove = EvalEncode.vifun1((vthis, vkey) -> {
		var self = thisValue(vthis);
		var key = EvalIntegers.decodeI64(vkey);
		var b = self.mem(key);
		self.remove(key);
		b.vbool();
	});

	public static final set = EvalEncode.vifun2((vthis, vkey, vvalue) -> {
		thisValue(vthis).add(EvalIntegers.decodeI64(vkey), vvalue);
		VNull;
	});

	public static final toString = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		var l = self.fold((key, vvalue, acc:Array<Vstring>) -> {
			acc.push(EvalString.join(EvalString.emptyString, [
				EvalString.createAscii(haxe.Int64.toStr(key)),
				EvalString.createAscii(" => "),
				EvalPrinting.sValue(0, vvalue)
			]));
			acc;
		}, []);
		l.reverse();
		var s = EvalString.join(EvalPrinting.rcomma, l);
		var s = EvalString.join(EvalString.emptyString, [EvalPrinting.rbkopen, s, EvalPrinting.rbkclose]);
		VString(s);
	});

	public static final clear = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).clear();
		VNull;
	});

	public static final size = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).size().vint();
	});
}

class StdStringMap {
	static function thisValue(vthis:Value):RuntimeStringHashtbl<Value> {
		return switch vthis {
			case VInstance({ikind: IStringMap(h)}): h;
			case v: EvalExceptions.unexpectedValue(v, "string map");
		}
	}

	public static final copy = EvalEncode.vifun0(vthis -> {
		var copied = thisValue(vthis).copy();
		EvalEncode.encodeStringMapDirect(copied);
	});

	public static final exists = EvalEncode.vifun1((vthis, vkey) -> {
		(thisValue(vthis).mem(EvalDecode.decodeVstring(vkey))).vbool();
	});

	public static final get = EvalEncode.vifun1((vthis, vkey) -> {
		try thisValue(vthis).find(EvalDecode.decodeVstring(vkey)).value
		catch (_:NotFound) VNull;
	});

	public static final iterator = EvalEncode.vifun0(vthis -> {
		var keys = thisValue(vthis).fold((_, e, acc:Array<Value>) -> {
			acc.push(e.value);
			acc;
		}, []);
		keys.reverse();
		StdLibBHelpers.encodeListIterator(keys);
	});

	public static final keys = EvalEncode.vifun0(vthis -> {
		var keys = thisValue(vthis).fold((_, e, acc:Array<Value>) -> {
			acc.push(VString(e.key));
			acc;
		}, []);
		keys.reverse();
		StdLibBHelpers.encodeListIterator(keys);
	});

	public static final keyValueIterator = StdLibBHelpers.mapKeyValueIterator(EvalHash.key_haxe_iterators_map_key_value_iterator);

	public static final remove = EvalEncode.vifun1((vthis, vkey) -> {
		var self = thisValue(vthis);
		var key = EvalDecode.decodeVstring(vkey);
		var b = self.mem(key);
		self.remove(key);
		b.vbool();
	});

	public static final set = EvalEncode.vifun2((vthis, vkey, vvalue) -> {
		thisValue(vthis).add(EvalDecode.decodeVstring(vkey), vvalue);
		VNull;
	});

	public static final toString = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		var l = self.fold((_, e, acc:Array<Vstring>) -> {
			acc.push(EvalString.join(EvalString.emptyString, [e.key, EvalString.createAscii(" => "), EvalPrinting.sValue(0, e.value)]));
			acc;
		}, []);
		l.reverse();
		var s = EvalString.join(EvalPrinting.rcomma, l);
		var s = EvalString.join(EvalString.emptyString, [EvalPrinting.rbkopen, s, EvalPrinting.rbkclose]);
		VString(s);
	});

	public static final clear = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).clear();
		VNull;
	});

	public static final size = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).size().vint();
	});
}

class StdObjectMap {
	static function thisValue(vthis:Value):OcamlHashtbl<Value, Value> {
		return switch vthis {
			case VInstance({ikind: IObjectMap(h)}): h;
			case v: EvalExceptions.unexpectedValue(v, "int map");
		}
	}

	public static final copy = EvalEncode.vifun0(vthis -> {
		var copied = thisValue(vthis).copy();
		EvalEncode.encodeObjectMapDirect(copied);
	});

	public static final exists = EvalEncode.vifun1((vthis, vkey) -> {
		(thisValue(vthis).mem(vkey)).vbool();
	});

	public static final get = EvalEncode.vifun1((vthis, vkey) -> {
		try thisValue(vthis).find(vkey)
		catch (_:NotFound) VNull;
	});

	public static final iterator = EvalEncode.vifun0(vthis -> {
		var keys = thisValue(vthis).fold((_, v, acc:Array<Value>) -> {
			acc.push(v);
			acc;
		}, []);
		keys.reverse();
		StdLibBHelpers.encodeListIterator(keys);
	});

	public static final keys = EvalEncode.vifun0(vthis -> {
		var keys = thisValue(vthis).fold((k, _, acc:Array<Value>) -> {
			acc.push(k);
			acc;
		}, []);
		keys.reverse();
		StdLibBHelpers.encodeListIterator(keys);
	});

	public static final keyValueIterator = StdLibBHelpers.mapKeyValueIterator(EvalHash.key_haxe_iterators_map_key_value_iterator);

	public static final remove = EvalEncode.vifun1((vthis, vkey) -> {
		var self = thisValue(vthis);
		var b = self.mem(vkey);
		self.remove(vkey);
		b.vbool();
	});

	public static final set = EvalEncode.vifun2((vthis, vkey, vvalue) -> {
		thisValue(vthis).replace(vkey, vvalue);
		VNull;
	});

	public static final toString = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		var l = self.fold((key, vvalue, acc:Array<Vstring>) -> {
			acc.push(EvalString.join(EvalString.emptyString, [
				EvalPrinting.sValue(0, key),
				EvalString.createAscii(" => "),
				EvalPrinting.sValue(0, vvalue)
			]));
			acc;
		}, []);
		l.reverse();
		var s = EvalString.join(EvalPrinting.rcomma, l);
		var s = EvalString.join(EvalString.emptyString, [EvalPrinting.rbkopen, s, EvalPrinting.rbkclose]);
		VString(s);
	});

	public static final clear = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).reset();
		VNull;
	});

	public static final size = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).length().vint();
	});
}

// port: `let random = Random.State.make_self_init()`: the host generator is used instead.

class StdMath {
	// port: Int32.of_float (mod_float f 2147483648.0); on amd64 OCaml converts nan
	// (also mod_float of an infinity) to min_int (cvttsd2si's "integer indefinite")
	static function toInt(f:Float):Int {
		var m = f % 2147483648.0;
		if (Math.isNaN(m)) return 0x80000000;
		return Std.int(m);
	}

	public static final nan = VFloat(Math.NaN);
	public static final negativeInfinity = VFloat(Math.NEGATIVE_INFINITY);
	public static final pi = VFloat(4.0 * Math.atan(1.0));
	public static final positiveInfinity = VFloat(Math.POSITIVE_INFINITY);

	public static final abs = EvalEncode.vfun1(v -> {
		switch v {
			case VInt32(i): VInt32(i < 0 ? -i : i); // port: Int32.abs (min_int stays min_int)
			case VFloat(f): VFloat(Math.abs(f));
			case _: EvalExceptions.unexpectedValue(v, "number");
		}
	});

	public static final acos = EvalEncode.vfun1(v -> VFloat(Math.acos(EvalDecode.num(v))));
	public static final asin = EvalEncode.vfun1(v -> VFloat(Math.asin(EvalDecode.num(v))));
	public static final atan = EvalEncode.vfun1(v -> VFloat(Math.atan(EvalDecode.num(v))));
	public static final atan2 = EvalEncode.vfun2((a, b) -> VFloat(Math.atan2(EvalDecode.num(a), EvalDecode.num(b))));
	public static final ceil = EvalEncode.vfun1(v -> switch v {
		case VInt32(_): v;
		case _: VInt32(toInt(Math.fceil(EvalDecode.num(v))));
	});
	public static final cos = EvalEncode.vfun1(v -> VFloat(Math.cos(EvalDecode.num(v))));
	public static final exp = EvalEncode.vfun1(v -> VFloat(Math.exp(EvalDecode.num(v))));
	public static final fceil = EvalEncode.vfun1(v -> VFloat(Math.fceil(EvalDecode.num(v))));
	public static final ffloor = EvalEncode.vfun1(v -> VFloat(Math.ffloor(EvalDecode.num(v))));
	public static final floor = EvalEncode.vfun1(v -> switch v {
		case VInt32(_): v;
		case _: VInt32(toInt(Math.ffloor(EvalDecode.num(v))));
	});
	public static final fround = EvalEncode.vfun1(v -> VFloat(Math.ffloor(EvalDecode.num(v) + 0.5)));
	public static final isFinite = EvalEncode.vfun1(v -> (switch v {
		case VFloat(f): f != Math.POSITIVE_INFINITY && f != Math.NEGATIVE_INFINITY && f == f;
		case _: true;
	}).vbool());
	public static final isNaN = EvalEncode.vfun1(v -> (switch v {
		case VFloat(f): f != f;
		case VInt32(_): false;
		case _: true;
	}).vbool());
	public static final log = EvalEncode.vfun1(v -> VFloat(Math.log(EvalDecode.num(v))));

	public static final max = EvalEncode.vfun2((a, b) -> {
		var a = EvalDecode.num(a);
		var b = EvalDecode.num(b);
		VFloat(if (a < b) b else if (b != b) b else a);
	});

	public static final min = EvalEncode.vfun2((a, b) -> {
		var a = EvalDecode.num(a);
		var b = EvalDecode.num(b);
		VFloat(if (a < b) a else if (a != a) a else b);
	});

	public static final pow = EvalEncode.vfun2((a, b) -> VFloat(Math.pow(EvalDecode.num(a), EvalDecode.num(b))));
	public static final random = EvalEncode.vfun0(() -> VFloat(Math.random()));
	public static final round = EvalEncode.vfun1(v -> switch v {
		case VInt32(_): v;
		case _: VInt32(toInt(Math.ffloor(EvalDecode.num(v) + 0.5)));
	});
	public static final sin = EvalEncode.vfun1(v -> VFloat(Math.sin(EvalDecode.num(v))));

	public static final sqrt = EvalEncode.vfun1(v -> {
		var v = EvalDecode.num(v);
		if (v < 0.) nan
		else VFloat(Math.sqrt(v));
	});

	public static final tan = EvalEncode.vfun1(v -> VFloat(Math.tan(EvalDecode.num(v))));
}

class StdMd5 {
	public static final encode = EvalEncode.vfun1(s -> {
		var s = EvalDecode.decodeString(s);
		EvalEncode.encodeString(haxe.crypto.Md5.encode(s));
	});

	public static final make = EvalEncode.vfun1(b -> {
		var b = EvalDecode.decodeBytes(b);
		EvalEncode.encodeBytes(haxe.crypto.Md5.make(b));
	});
}

class StdMutex {
	static function thisValue(vthis:Value):DomainMutex {
		return switch vthis {
			case VInstance({ikind: IMutex(mutex)}): mutex;
			case _: EvalExceptions.unexpectedValue(vthis, "Mutex");
		}
	}

	public static final acquire = EvalEncode.vifun0(vthis -> {
		var mutex = thisValue(vthis);
		var domainId = EvalContext.currentThreadId(EvalContext.getCtx());
		mutex.lock(domainId);
		VNull;
	});

	public static final release = EvalEncode.vifun0(vthis -> {
		var mutex = thisValue(vthis);
		mutex.unlock();
		VNull;
	});

	public static final tryAcquire = EvalEncode.vifun0(vthis -> {
		var mutex = thisValue(vthis);
		var domainId = EvalContext.currentThreadId(EvalContext.getCtx());
		mutex.tryLock(domainId).vbool();
	});
}

class StdSemaphore {
	static function thisValue(vthis:Value):sys.thread.Semaphore {
		return switch vthis {
			case VInstance({ikind: ISemaphore(sem)}): sem;
			case _: EvalExceptions.unexpectedValue(vthis, "Semaphore");
		}
	}

	public static final acquire = EvalEncode.vifun0(vthis -> {
		var sem = thisValue(vthis);
		if (!sem.tryAcquire()) EvalLock.blocking(() -> {
			sem.acquire();
			true;
		});
		VNull;
	});

	public static final tryAcquire = EvalEncode.vifun1((vthis, vtimeout) -> {
		var sem = thisValue(vthis);
		switch vtimeout {
			case VNull:
				sem.tryAcquire().vbool();
			case _:
				var timeout = EvalDecode.num(vtimeout);
				var t = Sys.time() + timeout;
				function loop():Value {
					while (true) {
						if (sem.tryAcquire()) return VTrue;
						else if (Sys.time() >= t) return VFalse;
						else EvalLock.yieldNow();
					}
				}
				loop();
		}
	});

	public static final release = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).release();
		VNull;
	});
}

class StdCondition {
	static function thisValue(vthis:Value):Vcondition {
		return switch vthis {
			case VInstance({ikind: ICondition(cond)}): cond;
			case _: EvalExceptions.unexpectedValue(vthis, "Condition");
		}
	}

	// port: the host condition owns its mutex: Mutex.lock cond.cmutex
	public static final acquire = EvalEncode.vifun0(vthis -> {
		var cond = thisValue(vthis);
		EvalLock.acquireCondition(cond.cond);
		VNull;
	});

	public static final tryAcquire = EvalEncode.vifun0(vthis -> {
		var cond = thisValue(vthis);
		cond.cond.tryAcquire().vbool();
	});

	public static final release = EvalEncode.vifun0(vthis -> {
		var cond = thisValue(vthis);
		cond.cond.release();
		VNull;
	});

	public static final wait = EvalEncode.vifun0(vthis -> {
		var c = thisValue(vthis);
		EvalLock.blocking(() -> {
			c.cond.wait();
			true;
		});
		VNull;
	});

	public static final signal = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).cond.signal();
		VNull;
	});

	public static final broadcast = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).cond.broadcast();
		VNull;
	});
}

class StdNativeProcess {
	static function thisValue(vthis:Value):EvalProcess {
		return switch vthis {
			case VInstance({ikind: IProcess(proc)}): proc;
			case _: EvalExceptions.unexpectedValue(vthis, "NativeProcess");
		}
	}

	static function call(f:(EvalProcess, Bytes, Int, Int) -> Int, vthis:Value, bytes:Value, pos:Value, len:Value):Int {
		var self = thisValue(vthis);
		var bytes = EvalDecode.decodeBytes(bytes);
		var pos = EvalDecode.decodeInt(pos);
		var len = EvalDecode.decodeInt(len);
		return f(self, bytes, pos, len);
	}

	static function processCatch<B>(f:EvalProcess->B, vthis:Value):B {
		return StdLibBHelpers.processCatch(f, thisValue(vthis));
	}

	public static final close = EvalEncode.vifun0(vthis -> {
		processCatch(p -> {
			p.close();
			null;
		}, vthis);
		VNull;
	});

	public static final exitCode = EvalEncode.vifun0(vthis -> {
		var p = thisValue(vthis);
		EvalLock.blocking(() -> p.exit()).vint();
	});

	public static final getPid = EvalEncode.vifun0(vthis -> {
		processCatch(p -> p.pid(), vthis).vint();
	});

	public static final kill = EvalEncode.vifun0(vthis -> {
		processCatch(p -> {
			p.kill();
			null;
		}, vthis);
		VNull;
	});

	public static final readStderr = EvalEncode.vifun3((vthis, bytes, pos, len) -> {
		try call((p, b, pos, len) -> EvalLock.blocking(() -> p.readStderr(b, pos, len)), vthis, bytes, pos, len).vint()
		catch (_:Dynamic) EvalContext.excString("Could not read stderr");
	});

	public static final readStdout = EvalEncode.vifun3((vthis, bytes, pos, len) -> {
		try call((p, b, pos, len) -> EvalLock.blocking(() -> p.readStdout(b, pos, len)), vthis, bytes, pos, len).vint()
		catch (_:Dynamic) EvalContext.excString("Could not read stdout");
	});

	public static final closeStdin = EvalEncode.vifun0(vthis -> {
		processCatch(p -> {
			p.closeStdin();
			null;
		}, vthis);
		VNull;
	});

	public static final writeStdin = EvalEncode.vifun3((vthis, bytes, pos, len) -> {
		call((p, b, pos, len) -> EvalLock.blocking(() -> p.writeStdin(b, pos, len)), vthis, bytes, pos, len).vint();
	});
}

class StdReflect {
	static final r_get_ = EvalString.createAscii("get_");
	static final r_set_ = EvalString.createAscii("set_");

	public static final callMethod = EvalEncode.vfun3((o, f, args) -> {
		EvalPrinting.callValueOn(o, f, EvalDecode.decodeArray(args));
	});

	public static final compare = EvalEncode.vfun2((a, b) -> {
		(switch EvalMisc.compare(a, b) {
			case CEq: 0;
			case CInf: -1;
			case CSup: 1;
			case CUndef: -1;
		}).vint();
	});

	public static final compareMethods = EvalEncode.vfun2((a, b) -> {
		function loop(a:Value, b:Value):Bool {
			return StdLibBHelpers.physicalEquals(a, b) || switch [a, b] {
				case [VFunction(f1, _), VFunction(f2, _)]: Reflect.compareMethods(f1, f2);
				case [VFieldClosure(v1, f1), VFieldClosure(v2, f2)]: Reflect.compareMethods(f1, f2) && EvalMisc.compare(v1, v2) == CEq;
				case _: false;
			}}
		loop(a, b).vbool();
	});

	public static final copy = EvalEncode.vfun1(o -> switch o.vresolve() {
		case VNull: VNull;
		case VObject(o): VObject(new Vobject(o.ofields.copy(), o.oproto));
		case VInstance(vi): VInstance(new Vinstance(vi.ifields.copy(), vi.iproto, vi.ikind));
		case VString(_): o;
		case VArray(va): VArray(new Varray(va.avalues.copy(), va.alength));
		case VVector(vv): VVector(vv.copy());
		case _: EvalExceptions.unexpectedValue(o, "object");
	});

	public static final deleteField = EvalEncode.vfun2((o, name) -> {
		var name = EvalHash.hash(EvalDecode.decodeVstring(name).sstring);
		switch o.vresolve() {
			case VObject(o):
				switch o.oproto {
					case OProto(proto):
						var found = false;
						var fields = proto.pinstanceNames.fold((name2, i, acc:Array<{name:Int, value:Value}>) -> {
							if (name == name2) {
								found = true;
								acc;
							} else {
								acc.unshift({name: name2, value: o.ofields[i]});
								acc;
							}
						}, []);
						if (found) {
							EvalMisc.updateObjectPrototype(o, fields);
							VTrue;
						} else VFalse;
					case ODictionary(d):
						var has = d.mem(name);
						if (has) o.oproto = ODictionary(d.remove(name));
						has.vbool();
				}
			case _:
				VFalse;
		}
	});

	// port: field' upstream
	public static final fieldValue = EvalEncode.vfun2((o, name) -> {
		if (o.match(VNull)) VNull
		else EvalField.dynamicField(o, EvalHash.hash(EvalDecode.decodeVstring(name).sstring));
	});

	public static final fields = EvalEncode.vfun1(o -> {
		function protoFields(proto:Vprototype):Array<Int> return proto.pnames.fold((name, _, acc:Array<Int>) -> {
			acc.unshift(name);
			acc;
		}, []);
		var fields = switch o.vresolve() {
				case VObject(o): [for (f in EvalContext.objectFields(o)) f.name];
				case VInstance(vi): vi.iproto.pinstanceNames.fold((name, _, acc:Array<Int>) -> {
						acc.unshift(name);
						acc;
					}, []);
				case VPrototype(proto): protoFields(proto);
				case VNull: [];
				case VString(_) | VArray(_) | VVector(_): [EvalHash.key_length];
				case _: EvalExceptions.unexpectedValue(o, "object");
			}
		EvalEncode.encodeArray([for (i in fields) EvalEncode.encodeString(EvalHash.revHash(i))]);
	});

	public static final getProperty = EvalEncode.vfun2((o, name) -> {
		if (o.match(VNull)) VNull
		else {
			var name = EvalDecode.decodeVstring(name);
			var nameGet = EvalHash.hash(EvalString.concat(r_get_, name).sstring);
			var vget = EvalField.field(o, nameGet);
			if (!vget.match(VNull)) EvalPrinting.callValueOn(o, vget, [])
			else EvalField.dynamicField(o, EvalHash.hash(name.sstring));
		}
	});

	public static final hasField = EvalEncode.vfun2((o, field) -> {
		var name = EvalHash.hash(EvalDecode.decodeVstring(field).sstring);
		var b = switch o.vresolve() {
				case VObject(o):
					switch o.oproto {
						case OProto(proto): proto.pinstanceNames.mem(name);
						case ODictionary(d): d.mem(name);
					}
				case VInstance(vi): vi.iproto.pinstanceNames.mem(name) || vi.iproto.pnames.mem(name);
				case VPrototype(proto): proto.pnames.mem(name);
				case _: false; // issue #10993
			}
		b.vbool();
	});

	public static final isEnumValue = EvalEncode.vfun1(v -> switch v {
		case VEnumValue(_): VTrue;
		case _: VFalse;
	});

	public static final isFunction = EvalEncode.vfun1(f -> switch f {
		case VFunction(_) | VFieldClosure(_): VTrue;
		case _: VFalse;
	});

	public static final isObject = EvalEncode.vfun1(v -> switch v.vresolve() {
		case VObject(_) | VString(_) | VArray(_) | VVector(_) | VInstance(_) | VPrototype(_): VTrue;
		case _: VFalse;
	});

	public static final makeVarArgs = EvalEncode.vfun1(f -> {
		EvalValueTools.vstaticFunction(vl -> EvalMisc.callValue(f, [EvalEncode.encodeArray(vl)]));
	});

	public static final setField = EvalEncode.vfun3((o, name, v) -> {
		try EvalMisc.setFieldRuntime(o, EvalHash.hash(EvalDecode.decodeVstring(name).sstring), v)
		catch (_:NotFound) {}
		VNull;
	});

	public static final setProperty = EvalEncode.vfun3((o, name, v) -> {
		var name = EvalDecode.decodeVstring(name);
		var nameSet = EvalHash.hash(EvalString.concat(r_set_, name).sstring);
		var vset = EvalField.field(o, nameSet);
		if (!vset.match(VNull)) EvalPrinting.callValueOn(o, vset, [v])
		else {
			try EvalMisc.setFieldRuntime(o, EvalHash.hash(name.sstring), v)
			catch (_:NotFound) {}
			VNull;
		}
	});
}

class StdResource {
	static function resources():core.ds.OcamlHashtbl<String, Bytes> return EvalContext.getCtx().curapi.getCom().resources;

	public static final listNames = EvalEncode.vfun0(() -> {
		EvalEncode.encodeArray([for (k in resources().fold((k, _, acc:Array<String>) -> [k].concat(acc), [])) EvalString.createUnknown(k)]);
	});

	public static final getString = EvalEncode.vfun1(name -> {
		var s = resources().findOpt(EvalDecode.decodeString(name));
		s == null ? VNull : EvalString.createUnknown(core.StringHelper.ofBytes(s));
	});

	public static final getBytes = EvalEncode.vfun1(name -> {
		var s = resources().findOpt(EvalDecode.decodeString(name));
		s == null ? VNull : EvalEncode.encodeBytes(s);
	});
}

class StdSha1 {
	public static final encode = EvalEncode.vfun1(s -> {
		var s = EvalDecode.decodeString(s);
		EvalEncode.encodeString(haxe.crypto.Sha1.encode(s));
	});

	public static final make = EvalEncode.vfun1(b -> {
		var b = EvalDecode.decodeBytes(b);
		EvalEncode.encodeBytes(haxe.crypto.Sha1.make(b));
	});
}

#if (target.name == "hxmc")
private typedef SocketHost = NativeNet;
#elseif hl
private typedef SocketHost = macros.eval.EvalHostNet;
#end

// port: sockets: on the hxmc host (hxmc/) the natives call BSD sockets through
// `hxmc.NativeNet` (hxmc/std/hxmc/rt/PosixNet.hx, WinNet.hx) where upstream calls OCaml's Unix
// module; a socket is its file descriptor. On HashLink, EvalHostNet offers
// the same interface over the host's sys.net.Socket. Other hosts keep
// upstream's names and argument checks, then fail ("... is not supported by
// haxe-in-haxe").
class StdSocket {
	static function thisValue(vthis:Value):Dynamic {
		return switch vthis {
			case VInstance({ikind: ISocket(sock)}): sock.closed ? -1 : sock.fd;
			case _: EvalExceptions.unexpectedValue(vthis, "NativeSocket");
		}
	}

	#if (target.name == "hxmc" || hl)
	// port: `catch_unix_error`: `Unix_error(err, cmd, args)` becomes "message(cmd, args)".
	public static function unixError(cmd:String):Dynamic {
		return EvalContext.excString(SocketHost.strerror(SocketHost.errno()) + "(" + cmd + ", )");
	}

	public static inline function check(r:Int, cmd:String):Int {
		if (r < 0) unixError(cmd);
		return r;
	}

	static function encodeAddr(a:Null<Array<Int>>, cmd:String):Value {
		if (a == null) unixError(cmd);
		if (a[1] < 0) Globals.die("", "evalStdLib.ml:StdSocket");
		return EvalEncode.encodeObj([
			{name: EvalHash.key_ip, value: VInt32(a[0])},
			{name: EvalHash.key_port, value: VInt32(a[1])}
		]);
	}

	static function timeoutValue(timeout:Value):Float {
		return switch timeout {
			case VNull: 0.;
			case VInt32(i): i;
			case VFloat(f): f;
			case _: EvalExceptions.unexpectedValue(timeout, "number");
		}
	}
	#end

	public static final accept = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		#if (target.name == "hxmc" || hl)
		var socket = check(EvalLock.blocking(() -> SocketHost.accept(self)), "accept");
		EvalEncode.encodeInstance(EvalHash.key_eval_vm_NativeSocket, ISocket(new Vsocket(socket)));
		#else
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final bind = EvalEncode.vifun2((vthis, host, port) -> {
		var self = thisValue(vthis);
		var host = EvalDecode.decodeI32(host);
		var port = EvalDecode.decodeInt(port);
		#if (target.name == "hxmc" || hl)
		check(SocketHost.bind(self, host, port), "bind");
		VNull;
		#else
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final close = EvalEncode.vifun0(vthis -> {
		#if (target.name == "hxmc" || hl)
		// port: a closed socket's number is not closed again: -1 fails with EBADF as
		// ... upstream's second Unix.close does (when the number was not reused meanwhile)
		var fd = thisValue(vthis);
		switch vthis {
			case VInstance({ikind: ISocket(sock)}): sock.closed = true;
			case _:
		}
		check(SocketHost.close(fd), "close");
		VNull;
		#else
		thisValue(vthis);
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final connect = EvalEncode.vifun2((vthis, host, port) -> {
		var self = thisValue(vthis);
		var host = EvalDecode.decodeI32(host);
		var port = EvalDecode.decodeInt(port);
		#if (target.name == "hxmc" || hl)
		check(EvalLock.blocking(() -> SocketHost.connect(self, host, port)), "connect");
		VNull;
		#else
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final host = EvalEncode.vifun0(vthis -> {
		#if (target.name == "hxmc" || hl)
		encodeAddr(SocketHost.sockName(thisValue(vthis), false), "getsockname");
		#else
		thisValue(vthis);
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final listen = EvalEncode.vifun1((vthis, connections) -> {
		var self = thisValue(vthis);
		var connections = EvalDecode.decodeInt(connections);
		#if (target.name == "hxmc" || hl)
		check(SocketHost.listen(self, connections), "listen");
		VNull;
		#else
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final peer = EvalEncode.vifun0(vthis -> {
		#if (target.name == "hxmc" || hl)
		encodeAddr(SocketHost.sockName(thisValue(vthis), true), "getpeername");
		#else
		thisValue(vthis);
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final receive = EvalEncode.vifun3((vthis, buf, pos, len) -> {
		var self = thisValue(vthis);
		var buf = EvalDecode.decodeBytes(buf);
		var pos = EvalDecode.decodeInt(pos);
		var len = EvalDecode.decodeInt(len);
		#if (target.name == "hxmc" || hl)
		VInt32(check(EvalLock.blocking(() -> SocketHost.recv(self, buf, pos, len)), "recv"));
		#else
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final receiveChar = EvalEncode.vifun0(vthis -> {
		#if (target.name == "hxmc" || hl)
		var buf = Bytes.alloc(1);
		buf.set(0, 0);
		var self = thisValue(vthis);
		check(EvalLock.blocking(() -> SocketHost.recv(self, buf, 0, 1)), "recv");
		VInt32(buf.get(0));
		#else
		thisValue(vthis);
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final select = EvalEncode.vfun4((read, write, others, timeout) -> {
		#if (target.name == "hxmc" || hl)
		var proto = EvalContext.getInstancePrototype(EvalContext.getCtx(), EvalHash.key_sys_net_Socket, Globals.nullPos);
		var i = EvalContext.getInstanceFieldIndex(proto, EvalHash.key_socket, Globals.nullPos);
		function pair(v:Value):{fd:Int, v:Value} {
			return switch v {
				case VInstance(vi): {fd: thisValue(vi.ifields[i]), v: v};
				case v: EvalExceptions.unexpectedValue(v, "NativeSocket");
			}
		}
		function decodeOptionalArray(v:Value):Array<Value> {
			return switch v {
				case VNull: [];
				case VArray(va): EvalArray.toList(va);
				case v: EvalExceptions.unexpectedValue(v, "array");
			}
		}
		var read = decodeOptionalArray(read).map(pair);
		var write = decodeOptionalArray(write).map(pair);
		var others = decodeOptionalArray(others).map(pair);
		var timeout = timeoutValue(timeout);
		var readFds = [for (p in read) p.fd];
		var writeFds = [for (p in write) p.fd];
		var othersFds = [for (p in others) p.fd];
		check(EvalLock.blocking(() -> SocketHost.select(readFds, writeFds, othersFds, timeout)), "select");
		// port: Unix.select lists the ready descriptors in reverse input order; List.assq
		// maps each back to the first pair holding it
		function ready(pairs:Array<{fd:Int, v:Value}>, fds:Array<Int>):Array<Value> {
			var l = [];
			var k = fds.length;
			while (--k >= 0) {
				if (fds[k] < 0) continue;
				var fd = fds[k];
				var v = null;
				for (p in pairs) if (p.fd == fd) {
					v = p.v;
					break;
				}
				l.push(v);
			}
			return l;
		}
		var read = ready(read, readFds);
		var write = ready(write, writeFds);
		var others = ready(others, othersFds);
		EvalEncode.encodeObj([
			{name: EvalHash.key_read, value: EvalEncode.encodeArray(read)},
			{name: EvalHash.key_write, value: EvalEncode.encodeArray(write)},
			{name: EvalHash.key_others, value: EvalEncode.encodeArray(others)}
		]);
		#else
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final send = EvalEncode.vifun3((vthis, buf, pos, len) -> {
		var self = thisValue(vthis);
		var buf = EvalDecode.decodeBytes(buf);
		var pos = EvalDecode.decodeInt(pos);
		var len = EvalDecode.decodeInt(len);
		#if (target.name == "hxmc" || hl)
		VInt32(check(EvalLock.blocking(() -> SocketHost.send(self, buf, pos, len)), "send"));
		#else
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final sendChar = EvalEncode.vifun1((vthis, char) -> {
		var self = thisValue(vthis);
		var char = EvalDecode.decodeInt(char);
		#if (target.name == "hxmc" || hl)
		// port: char_of_int
		if (char < 0 || char > 255) throw new InvalidArgument("char_of_int");
		var buf = Bytes.alloc(1);
		buf.set(0, char);
		check(EvalLock.blocking(() -> SocketHost.send(self, buf, 0, 1)), "send");
		VNull;
		#else
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final setFastSend = EvalEncode.vifun1((vthis, b) -> {
		var self = thisValue(vthis);
		var b = EvalDecode.decodeBool(b);
		#if (target.name == "hxmc" || hl)
		check(SocketHost.setNoDelay(self, b), "setsockopt");
		VNull;
		#else
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final setBroadcast = EvalEncode.vifun1((vthis, b) -> {
		var self = thisValue(vthis);
		var b = EvalDecode.decodeBool(b);
		#if (target.name == "hxmc" || hl)
		check(SocketHost.setBroadcast(self, b), "setsockopt");
		VNull;
		#else
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final setTimeout = EvalEncode.vifun1((vthis, timeout) -> {
		var self = thisValue(vthis);
		#if (target.name == "hxmc" || hl)
		var timeout = timeoutValue(timeout);
		var timeout = timeout * 1000.;
		check(SocketHost.setTimeout(self, timeout), "setsockopt_float");
		VNull;
		#else
		StdLibBHelpers.socketsNotSupported();
		#end
	});

	public static final shutdown = EvalEncode.vifun2((vthis, read, write) -> {
		var self = thisValue(vthis);
		var mode = switch [read, write] {
				case [VTrue, VTrue]: 2; // port: SHUTDOWN_ALL
				case [VTrue, _]: 0; // port: SHUTDOWN_RECEIVE
				case [_, VTrue]: 1; // port: SHUTDOWN_SEND
				case _: EvalContext.excString("Nothing to shut down");
			}
		#if (target.name == "hxmc" || hl)
		check(SocketHost.shutdown(self, mode), "shutdown");
		VNull;
		#else
		StdLibBHelpers.socketsNotSupported();
		#end
	});
}

class StdStd {
	public static final isOfType = EvalEncode.vfun2((v, t) -> switch t {
		case VNull: VFalse;
		case VPrototype(proto): EvalContext.is(v, proto.ppath).vbool();
		case _: VFalse;
	});

	// port: is' upstream
	public static var isValue(get, never):Value;

	static inline function get_isValue() return isOfType;

	public static final downcast = EvalEncode.vfun2((v, t) -> switch t {
		case VPrototype(proto):
			if (EvalContext.is(v, proto.ppath)) v else VNull;
		case _: VFalse;
	});

	public static var instance(get, never):Value;

	static inline function get_instance() return downcast;

	public static final string = EvalEncode.vfun1(v -> switch v {
		case VString(_): v;
		case _: VString(EvalPrinting.sValue(0, v));
	});

	public static final int = EvalEncode.vfun1(v -> {
		try StdLibBHelpers.intOfFloat(EvalDecode.num(v)).vint()
		catch (_:Dynamic) VNull;
	});

	public static final parseInt = EvalEncode.vfun1(v -> {
		try core.Numeric.parseInt(EvalDecode.decodeString(v)).vint32()
		catch (_:Dynamic) VNull;
	});

	public static final parseFloat = EvalEncode.vfun1(v -> {
		try core.Numeric.parseFloat(EvalDecode.decodeString(v)).vfloat()
		catch (_:Dynamic) VFloat(Math.NaN);
	});

	public static final random = EvalEncode.vfun1(v -> {
		var v = EvalDecode.decodeI32(v);
		Std.random(v <= 0 ? 1 : v).vint32();
	});
}

class StdString {
	static function thisValue(vthis:Value):Vstring {
		return switch vthis {
			case VString(s): s;
			case v: EvalExceptions.unexpectedValue(v, "string");
		}
	}

	public static final charAt = EvalEncode.vifun1((vthis, index) -> {
		var self = thisValue(vthis);
		var i = EvalDecode.decodeInt(index);
		if (i < 0 || i >= self.slength) EvalString.vEmptyString
		else VString(EvalString.fromCharCode(EvalString.charAt(self, i)));
	});

	public static final charCodeAt = EvalEncode.vifun1((vthis, index) -> {
		var self = thisValue(vthis);
		var i = EvalDecode.decodeInt(index);
		if (i < 0 || i >= self.slength) VNull
		else EvalString.charAt(self, i).vint();
	});

	public static final fromCharCode = EvalEncode.vfun1(i -> {
		var i = EvalDecode.decodeInt(i);
		try VString(EvalString.fromCharCode(i))
		catch (_:NotFound) VNull;
	});

	public static final indexOf = EvalEncode.vifun2((vthis, str, startIndex) -> {
		var str = thisValue(str);
		var self = thisValue(vthis);
		var i = EvalDecode.defaultInt(startIndex, 0);
		var i = i < 0 ? 0 : i;
		try {
			if (str.slength == 0) (i < self.slength ? i : self.slength).vint()
			else {
				var i = if (i >= self.slength) throw NotFound.raise() else if (i < 0) {
						var j = self.slength + i;
						j < 0 ? 0 : j;
					} else i;
				var b = EvalString.getOffset(self, i);
				var r = EvalString.findSubstring(self, str, false)(i, b);
				r.c.vint();
			}
		} catch (_:NotFound) {
			(-1).vint();
		}
	});

	public static final lastIndexOf = EvalEncode.vifun2((vthis, str, startIndex) -> {
		var str = thisValue(str);
		var self = thisValue(vthis);
		try {
			if (str.slength == 0) {
				var i = EvalDecode.defaultInt(startIndex, self.slength);
				var m = i < self.slength ? i : self.slength;
					(m > 0 ? m : 0).vint();
			} else {
				var i = EvalDecode.defaultInt(startIndex, self.slength - str.slength);
				var i = if (i < 0) throw NotFound.raise() else if (i >= self.slength - str.slength) self.slength - str.slength else i;
				var b = EvalString.getOffset(self, i);
				var r = EvalString.findSubstring(self, str, true)(i, b);
				r.c.vint();
			}
		} catch (_:NotFound) {
			(-1).vint();
		}
	});

	public static final split = EvalEncode.vifun1((vthis, delimiter) -> {
		var self = thisValue(vthis);
		var s = self.sstring;
		var delimiter = EvalDecode.decodeVstring(delimiter);
		var blDelimiter = delimiter.sstring.length;
		var blThis = s.length;
		function encodeRange(pos:Int, length:Int, clength:Int):Value {
			var s = s.substr(pos, length);
			return VString(EvalString.createWithLength(s, clength));
		}
		if (blDelimiter == 0) {
			var acc = [];
			for (uc in new haxe.iterators.StringIteratorUnicode(s)) {
				acc.push(VString(EvalString.createWithLength(EvalString.stringOfCharCode(uc), 1)));
			}
			EvalEncode.encodeArray(acc);
		} else if (blDelimiter > blThis) {
			EvalEncode.encodeArray([encodeRange(0, blThis, self.slength)]);
		} else {
			var acc = [];
			var f = EvalString.findSubstring(self, delimiter, false);
			function loop(cIndex:Int, bIndex:Int):Void {
				while (true) {
					try {
						var r = f(cIndex, bIndex);
						acc.push(encodeRange(bIndex, r.b - bIndex, r.c - cIndex));
						cIndex = r.c + delimiter.slength;
						bIndex = r.e;
					} catch (_:NotFound) {
						acc.push(encodeRange(bIndex, blThis - bIndex, self.slength - cIndex));
						return;
					}
				}
			}
			loop(0, 0);
			EvalEncode.encodeArrayInstance(EvalArray.ofList(acc));
		}
	});

	public static final substr = EvalEncode.vifun2((vthis, pos, len) -> {
		var self = thisValue(vthis);
		var clThis = self.slength;
		var cPos = EvalDecode.decodeInt(pos);
		if (cPos >= clThis) EvalString.vEmptyString
		else {
			var cPos = if (cPos < 0) {
					var cPos = self.slength + cPos;
					cPos < 0 ? 0 : cPos;
				} else cPos;
			var cLen = switch len {
					case VNull: clThis - cPos;
					case VInt32(i): i;
					case _: EvalExceptions.unexpectedValue(len, "int");
				}
			var cLen = if (cLen < 0) clThis + cLen - cPos else if (cLen > clThis - cPos) clThis - cPos else cLen;
			VString(EvalString.substr(self, cPos, cLen));
		}
	});

	public static final substring = EvalEncode.vifun2((vthis, startIndex, endIndex) -> {
		var self = thisValue(vthis);
		var cFirst = EvalDecode.decodeInt(startIndex);
		var clThis = self.slength;
		var cLast = EvalDecode.defaultInt(endIndex, clThis);
		var cFirst = cFirst < 0 ? 0 : cFirst;
		var cLast = cLast < 0 ? 0 : cLast;
		var swap = cFirst > cLast;
		var cFirst2 = swap ? cLast : cFirst;
		var cLast2 = swap ? cFirst : cLast;
		var cFirst = cFirst2;
		var cLast = cLast2 > clThis ? clThis : cLast2;
		if (cFirst > clThis || cFirst == cLast) EvalString.vEmptyString
		else {
			var bOffset1 = EvalString.getOffset(self, cFirst);
			var cLen = cLast - cFirst;
			var bLen = if (cLast == clThis) self.sstring.length - bOffset1 else EvalString.move(self, bOffset1, cLen) - bOffset1;
			VString(EvalString.createWithLength(self.sstring.substr(bOffset1, bLen), cLen));
		}
	});

	public static final toLowerCase = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		VString(EvalString.caseMap(self, false));
	});

	public static final toString = EvalEncode.vifun0(vthis -> vthis);

	public static final toUpperCase = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		VString(EvalString.caseMap(self, true));
	});

	public static var cca(get, never):Value;

	static inline function get_cca() return charCodeAt;
}

class StdStringBuf {
	static function thisValue(vthis:Value):VstringBuffer {
		return switch vthis {
			case VInstance({ikind: IBuffer(sb)}): sb;
			case v: EvalExceptions.unexpectedValue(v, "string");
		}
	}

	public static final add = EvalEncode.vifun1((vthis, x) -> {
		var self = thisValue(vthis);
		var s = switch x {
				case VString(s): s;
				case _: EvalString.createAscii(EvalPrinting.valueString(x));
			}
		EvalString.bufferAddString(self, s);
		VNull;
	});

	public static final addChar = EvalEncode.vifun1((vthis, c) -> {
		var self = thisValue(vthis);
		var i = EvalDecode.decodeInt(c);
		self.bbuffer.add(EvalString.stringOfCharCode(i));
		self.blength = self.blength + 1;
		VNull;
	});

	public static final addSub = EvalEncode.vifun3((vthis, s, pos, len) -> {
		var self = thisValue(vthis);
		var s = EvalDecode.decodeVstring(s);
		var cPos = EvalDecode.decodeInt(pos);
		var cLen = switch len {
				case VNull: s.slength - cPos;
				case VInt32(i): i;
				case _: EvalExceptions.unexpectedValue(len, "int");
			}
		if (cLen > 0) {
			var bOffset1 = EvalString.getOffset(s, cPos);
			var bOffset2 = EvalString.move(s, bOffset1, cLen);
			EvalString.bufferAddSubstring(self, s, bOffset1, bOffset2 - bOffset1, cLen);
		}
		VNull;
	});

	public static final clear = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		EvalString.bufferClear(self);
		VNull;
	});

	public static final getLength = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		self.blength.vint();
	});

	public static final toString = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		var s = EvalString.bufferContents(self);
		VString(s);
	});
}

class StdStringTools {
	static function urlEncode_(s:String):String {
		var b = new StringBuf();
		core.StringHelper.urlEncode(s, b.add);
		return b.toString();
	}

	public static var fastCodeAt(get, never):Value;

	static inline function get_fastCodeAt() return StdString.charCodeAt;

	public static final replace = EvalEncode.vfun3((s, sub, by) -> {
		var by = EvalDecode.decodeVstring(by);
		var sub = EvalDecode.decodeVstring(sub);
		var s2 = EvalDecode.decodeVstring(s);
		var blS = s2.sstring.length;
		var buf = new StringBuf();
		var replaceCount = 0;
		function create():Value {
			return VString(EvalString.createWithLength(buf.toString(),
				s2.slength + by.slength * replaceCount - sub.slength * replaceCount));
		}
		if (sub.slength == 0) {
			if (by.slength == 0) s
			else {
				for (uc in new haxe.iterators.StringIteratorUnicode(s2.sstring)) {
					buf.addChar(uc);
					// don't add for the final char
					if (replaceCount != s2.slength - 1) {
						buf.add(by.sstring);
						replaceCount++;
					}
				}
				create();
			}
		} else {
			var f = EvalString.findSubstring(s2, sub, false);
			var cIndex = 0;
			var bIndex = 0;
			while (true) {
				try {
					var r = f(cIndex, bIndex);
					buf.add(s2.sstring.substr(bIndex, r.b - bIndex));
					buf.add(by.sstring);
					replaceCount++;
					cIndex = r.c + sub.slength;
					bIndex = r.e;
				} catch (_:NotFound) {
					buf.add(s2.sstring.substr(bIndex, blS - bIndex));
					break;
				}
			}
			create();
		}
	});

	public static final urlEncode = EvalEncode.vfun1(s -> {
		var s = EvalDecode.decodeString(s);
		EvalEncode.encodeString(urlEncode_(s));
	});

	public static final urlDecode = EvalEncode.vfun1(s -> {
		var s = EvalDecode.decodeString(s);
		var b = EvalString.bufferCreate();
		function add(s:Vstring) EvalString.bufferAddString(b, s);
		var len = s.length;
		function decode(c:Int):Null<Int> {
			return if (c >= "0".code && c <= "9".code) c - "0".code else if (c >= "a".code && c <= "f".code) c - "a".code + 10 else
				if (c >= "A".code
					&& c <= "F".code) c
					- "A".code + 10 else null;
		}
		function decodeHex(i:Int):Null<Int> {
			var p1 = i < len ? decode(StringTools.fastCodeAt(s, i)) : null;
			var p2 = i + 1 < len ? decode(StringTools.fastCodeAt(s, i + 1)) : null;
			return if (p1 != null && p2 != null) (p1 << 4) | p2 else null;
		}
		function expectHex(i:Int):Int {
			// port: String.unsafe_get: reading past the end is not checked upstream
			return if (i < len && StringTools.fastCodeAt(s, i) == "%".code) {
				var c = decodeHex(i + 1);
				if (c == null) EvalContext.excString("Malformed")
				else c;
			} else EvalContext.excString("Malformed");
		}
		var i = 0;
		while (i != len) {
			var c = StringTools.fastCodeAt(s, i);
			if (c == "%".code) {
				var c = decodeHex(i + 1);
				if (c != null) {
					if (c < 0x80) {
						add(EvalString.createAscii(String.fromCharCode(c)));
						i += 3;
					} else if (c < 0xE0) {
						var c2 = expectHex(i + 3);
						add(EvalString.fromCharCode(((c & 0x3F) << 6) | (c2 & 0x7F)));
						i += 6;
					} else if (c < 0xF0) {
						var c2 = expectHex(i + 3);
						var c3 = expectHex(i + 6);
						add(EvalString.fromCharCode(((c & 0x1F) << 12) | ((c2 & 0x7F) << 6) | (c3 & 0x7F)));
						i += 9;
					} else {
						var c2 = expectHex(i + 3);
						var c3 = expectHex(i + 6);
						var c4 = expectHex(i + 9);
						var k = ((c & 0x0F) << 18) | ((c2 & 0x7F) << 12) | ((c3 & 0x7F) << 6) | (c4 & 0x7F);
						add(EvalString.fromCharCode(k));
						i += 12;
					}
				} else {
					i += 1;
				}
			} else if (c == "+".code) {
				add(EvalString.createAscii(" "));
				i += 1;
			} else {
				// port: upstream adds the byte; here the native character
				add(EvalString.createUnknownVstring(s.charAt(i)));
				i += 1;
			}
		}
		VString(EvalString.bufferContents(b));
	});
}

class StdSys {
	static function com():context.Common.CommonContext return EvalContext.getCtx().curapi.getCom();

	public static final args = EvalEncode.vfun0(() -> {
		EvalEncode.encodeArray([for (s in EvalContext.getCtx().args) EvalString.createUnknown(s)]);
	});

	public static final _command = EvalEncode.vfun1(cmd -> {
		var cmd = EvalDecode.decodeString(cmd);
		com().runCommand(cmd).vint();
	});

	public static final cpuTime = EvalEncode.vfun0(() -> VFloat(Sys.cpuTime()));

	public static final environment = EvalEncode.vfun0(() -> {
		var env = EvalStdLib.catchUnixError(_ -> Sys.environment(), null);
		var h = new RuntimeStringHashtbl<Value>();
		for (k => v in env) {
			h.add(EvalString.createAscii(k), EvalString.createUnknown(v));
		}
		EvalEncode.encodeStringMapDirect(h);
	});

	public static final exit = EvalEncode.vfun1(code -> {
		throw new EvalTypes.SysExit(EvalDecode.decodeInt(code));
	});

	public static final getChar = EvalEncode.vfun1(echo -> {
		var echo = EvalDecode.decodeBool(echo);
		var com = com();
		EvalLock.blocking(() -> CompilerIo.getch(com.requestScope.io, echo)).vint();
	});

	public static final getCwd = EvalEncode.vfun0(() -> {
		var dir = EvalStdLib.catchUnixError(_ -> Sys.getCwd(), null);
		var l = dir.length;
		if (l == 0) EvalEncode.encodeString("./")
		else switch dir.charAt(l - 1) {
			case "/" | "\\": EvalString.createUnknown(dir);
			case _: EvalString.createUnknown(dir + "/");
		}
	});

	public static final getEnv = EvalEncode.vfun1(s -> {
		var s = EvalDecode.decodeString(s);
		var v = try EvalStdLib.catchUnixError(Sys.getEnv, s) catch (_:Dynamic) null;
		v == null ? VNull : EvalString.createUnknown(v);
	});

	public static final print = EvalEncode.vfun1(v -> {
		var com = com();
		CompilerIo.writeOut(com.requestScope.io, EvalPrinting.valueString(v));
		VNull;
	});

	public static final println = EvalEncode.vfun1(v -> {
		var com = com();
		CompilerIo.writeOut(com.requestScope.io, EvalPrinting.valueString(v) + EvalStdLibA.lineEnd);
		VNull;
	});

	public static final programPath = EvalEncode.vfun0(() -> {
		var com = com();
		var file:Null<String> = com.main.mainFile;
		if (file != null) EvalString.createUnknown(core.Path.getFullPath(file))
		else VNull;
	});

	public static final putEnv = EvalEncode.vfun2((s, v) -> {
		if (v.match(VNull)) {
			// port: Luv.Env.unsetenv upstream
			Sys.putEnv(EvalDecode.decodeString(s), null);
			VNull;
		} else {
			var s = EvalDecode.decodeString(s);
			var v = EvalDecode.decodeString(v);
			EvalStdLib.catchUnixError(_ -> Sys.putEnv(s, v), null);
			VNull;
		}
	});

	public static final setCwd = EvalEncode.vfun1(s -> {
		EvalStdLib.catchUnixError(Sys.setCwd, EvalDecode.decodeString(s));
		VNull;
	});

	public static final setTimeLocale = EvalEncode.vfun1(_ -> VFalse);

	public static final sleep = EvalEncode.vfun1(f -> {
		var t = EvalDecode.num(f);
		if (t > 0.0) EvalLock.blocking(() -> {
			Sys.sleep(t);
			true;
		});
		VNull;
	});

	public static final stderr = EvalEncode.vfun0(() -> {
		var com = com();
		EvalEncode.encodeInstance(EvalHash.key_sys_io_FileOutput, IOutChannel(CompilerIo.getStderr(com.requestScope.io)));
	});

	public static final stdin = EvalEncode.vfun0(() -> {
		var com = com();
		EvalEncode.encodeInstance(EvalHash.key_sys_io_FileInput, IInChannel(CompilerIo.getStdin(com.requestScope.io), {v: false}));
	});

	public static final stdout = EvalEncode.vfun0(() -> {
		var com = com();
		EvalEncode.encodeInstance(EvalHash.key_sys_io_FileOutput, IOutChannel(CompilerIo.getStdout(com.requestScope.io)));
	});

	static var cachedSysName:Null<String> = null;

	// port: upstream runs `uname` on Unix (mapping Darwin to Mac); the host's Sys.systemName is used here.
	public static final systemName = EvalEncode.vfun0(() -> {
		var s = switch cachedSysName {
				case null:
					var n = Sys.systemName();
					cachedSysName = n;
					n;
				case n: n;
			}
		EvalEncode.encodeString(s);
	});

	public static final time = EvalEncode.vfun0(() -> VFloat(EvalStdLib.catchUnixError(_ -> Sys.time(), null)));

	public static final timestampMs = EvalEncode.vfun0(() -> haxe.Int64.fromFloat(Math.ffloor(Sys.time() * 1000.0)).vint64());
}

class StdThread {
	static function thisValue(vthis:Value):Vthread {
		return switch vthis {
			case VInstance({ikind: IThread(thread)}): thread;
			case _: EvalExceptions.unexpectedValue(vthis, "Thread");
		}
	}

	public static final delay = EvalEncode.vfun1(f -> {
		var t = EvalDecode.num(f);
		if (t > 0.0) EvalLock.blocking(() -> {
			Sys.sleep(t);
			true;
		});
		VNull;
	});

	public static final exit = EvalEncode.vfun0(() -> {
		switch EvalContext.getEval(EvalContext.getCtx()).thread.threadMode {
			case LuvThread(_):
				// Caught by catch_exceptions
				throw new macros.MacroApi.Abort();
			// port: upstream's `Domain _` branch, also taken for `Thread _` (upstream: `Thread.exit()`)
			case _:
				var ctx = EvalContext.getCtx();
				var path = EvalHash.key_eval_vm_NativeThreadExit;
				var v = EvalEncode.encodeInstance(path);
				var fnew = EvalContext.getInstanceConstructor(ctx, path, Globals.nullPos);
				EvalPrinting.callValueOn(v, fnew.force(), []);
				EvalContext.exc(v);
		}
		VNull;
	});

	public static final id = EvalEncode.vifun0(vthis -> {
		thisValue(vthis).threadId.vint();
	});

	public static final join = EvalEncode.vfun1(thread -> {
		switch thisValue(thread).threadMode {
			case Domain(_, finished) | Thread(_, finished):
				// port: wait, then release again so that later joins return at once
				EvalLock.blocking(() -> finished.wait());
				finished.release();
			case LuvThread(t):
				EvalLock.blocking(() -> t.join());
			case null:
		}
		VNull;
	});

	public static final self = EvalEncode.vfun0(() -> {
		var eval = EvalContext.getEval(EvalContext.getCtx());
		EvalEncode.encodeInstance(EvalHash.key_eval_vm_Thread, IThread(eval.thread));
	});

	public static final readMessage = EvalEncode.vfun1(blocking -> {
		var eval = EvalContext.getEval(EvalContext.getCtx());
		var blocking = EvalDecode.decodeBool(blocking);
		switch EvalThread.Deque.pop(eval.thread.threadDeque, blocking) {
			case null: VNull;
			case v: v;
		}
	});

	public static final sendMessage = EvalEncode.vifun1((vthis, msg) -> {
		var self = thisValue(vthis);
		EvalThread.Deque.push(self.threadDeque, msg);
		VNull;
	});

	public static final yield = EvalEncode.vfun0(() -> {
		// port: Thread.yield / Domain.cpu_relax upstream
		EvalLock.yieldNow();
		VNull;
	});
}

class StdTls {
	static function thisValue(vthis:Value):Int {
		return switch vthis {
			case VInstance({ikind: ITls(i)}): i;
			case _: EvalExceptions.unexpectedValue(vthis, "Thread");
		}
	}

	// port: TlsStorage is keyed by the Tls value upstream; here by its id
	public static final getValue = EvalEncode.vifun0(vthis -> {
		var id = thisValue(vthis);
		try {
			var eval = EvalContext.getEval(EvalContext.getCtx());
			var v = eval.evalStorage.get(id);
			v == null ? VNull : v;
		} catch (_:NotFound) {
			VNull;
		}
	});

	public static final setValue = EvalEncode.vifun1((vthis, v) -> {
		var id = thisValue(vthis);
		var eval = EvalContext.getEval(EvalContext.getCtx());
		eval.evalStorage.set(id, v);
		v;
	});
}

class StdType {
	static function createEnum_(v:Value, constr:Int, params:Value):Value {
		var vf = EvalField.field(v, constr);
		return switch [vf, params] {
			case [VEnumValue(_), VNull]: vf;
			case [VEnumValue(_), VArray(va)] if (va.alength == 0): vf;
			case [VFunction(_), VArray(va)]: EvalMisc.callValue(vf, EvalArray.toList(va));
			case _: EvalExceptions.unexpectedValue(params, "array");
		}
	}

	public static final allEnums = EvalEncode.vfun1(v -> {
		switch v {
			case VPrototype(proto = {pkind: PEnum(names)}):
				try {
					var l = [];
					for (n in names) {
						try {
							switch EvalField.protoFieldDirect(proto, EvalHash.hash(n.name)) {
								case v = VEnumValue(_): l.push(v);
								case _:
							}
						} catch (_:NotFound) {}
					}
					EvalEncode.encodeArray(l);
				} catch (_:NotFound) {
					VNull;
				}
			case _:
				VNull;
		}
	});

	public static final createEmptyInstance = EvalEncode.vfun1(v -> {
		switch v {
			case VPrototype({pkind: PClass(_), ppath: path}):
				var f = EvalContext.getCtx().builtins.emptyConstructorBuiltins.get(path);
				if (f != null) f() else EvalEncode.encodeInstance(path);
			case _: VNull;
		}
	});

	public static final createEnum = EvalEncode.vfun3((e, constr, params) -> {
		var constr = EvalHash.hash(EvalDecode.decodeVstring(constr).sstring);
		createEnum_(e, constr, params);
	});

	public static final createEnumIndex = EvalEncode.vfun3((e, index, params) -> {
		var index = EvalDecode.decodeInt(index);
		switch e {
			case VPrototype({pkind: PEnum(names)}):
				try {
					createEnum_(e, EvalHash.hash(StdLibBHelpers.listNth(names, index).name), params);
				} catch (_:NotFound) {
					VNull;
				}
			case _:
				VNull;
		}
	});

	public static final createInstance = EvalEncode.vfun2((v, vl) -> {
		switch v {
			case VPrototype({pkind: PClass(_), ppath: path}):
				var ctx = EvalContext.getCtx();
				var f = try EvalContext.getSpecialInstanceConstructorRaise(ctx, path) catch (_:NotFound) null;
				if (f != null) f(EvalDecode.decodeArray(vl)) else {
					var vthis = EvalEncode.encodeInstance(path);
					var fnew = EvalContext.getInstanceConstructor(ctx, path, Globals.nullPos);
					EvalPrinting.callValueOn(vthis, fnew.force(), EvalDecode.decodeArray(vl));
					vthis;
				}
			case _:
				EvalExceptions.unexpectedValue(v, "Class");
		}
	});

	public static final enumConstructor = EvalEncode.vfun1(v -> switch v {
		case VEnumValue(ve):
			try {
				switch EvalContext.getStaticPrototypeRaise(EvalContext.getCtx(), ve.epath).pkind {
					case PEnum(names): EvalEncode.encodeString(StdLibBHelpers.listNth(names, ve.eindex).name);
					case _: throw NotFound.raise();
				}
			} catch (_:NotFound) {
				VNull;
			}
		case v: EvalExceptions.unexpectedValue(v, "enum value");
	});

	public static final enumEq = EvalEncode.vfun2((a, b) -> {
		function weirdEq(a:Value, b:Value):Bool {
			return switch [a, b] {
				case [VEnumValue(a), VEnumValue(b)]: a == b || a.eindex == b.eindex && EvalMisc.arraysEqual(weirdEq, a.eargs,
						b.eargs) && a.epath == b.epath;
				case _: a.equals(b);
			}
		}
		weirdEq(a, b).vbool();
	});

	public static final enumIndex = EvalEncode.vfun1(v -> switch v {
		case VEnumValue(ev): ev.eindex.vint32();
		case v: EvalExceptions.unexpectedValue(v, "enum value");
	});

	public static final enumParameters = EvalEncode.vfun1(v -> switch v {
		case VEnumValue(ev):
			var va = EvalArray.create(ev.eargs);
			VArray(va);
		case v: EvalExceptions.unexpectedValue(v, "enum value");
	});

	public static final getClass = EvalEncode.vfun1(v -> switch v {
		case VInstance(vi) if (vi.iproto.pkind.match(PInstance)): EvalContext.getStaticPrototypeAsValue(EvalContext.getCtx(),
				vi.iproto.ppath, Globals.nullPos);
		case VString(_): EvalContext.getStaticPrototypeAsValue(EvalContext.getCtx(), EvalHash.key_String, Globals.nullPos);
		case VArray(_): EvalContext.getStaticPrototypeAsValue(EvalContext.getCtx(), EvalHash.key_Array, Globals.nullPos);
		case VVector(_): EvalContext.getStaticPrototypeAsValue(EvalContext.getCtx(), EvalHash.key_eval_Vector, Globals.nullPos);
		case _: VNull;
	});

	public static final getClassFields = EvalEncode.vfun1(v -> switch v {
		case VPrototype({pkind: PClass(_), pnames: names}):
			EvalEncode.encodeArray(names.fold((name, _, acc:Array<Value>) -> {
				acc.unshift(EvalEncode.encodeString(EvalHash.revHash(name)));
				acc;
			}, []));
		case _:
			VNull;
	});

	public static final getClassName = EvalEncode.vfun1(v -> switch v {
		case VPrototype({pkind: PClass(_), ppath: path}): EvalEncode.encodeString(EvalHash.revHash(path));
		case _: VNull;
	});

	public static final getEnum = EvalEncode.vfun1(v -> switch v {
		case VEnumValue(ve): EvalContext.getStaticPrototypeAsValue(EvalContext.getCtx(), ve.epath, Globals.nullPos);
		case _: VNull;
	});

	public static final getEnumConstructs = EvalEncode.vfun1(v -> switch v {
		case VPrototype({pkind: PEnum(names)}):
			try {
				EvalEncode.encodeArray([for (n in names) EvalEncode.encodeString(n.name)]);
			} catch (_:NotFound) {
				VNull;
			}
		case _:
			VNull;
	});

	public static final getEnumName = EvalEncode.vfun1(v -> switch v {
		case VPrototype({pkind: PEnum(_), ppath: path}): EvalEncode.encodeString(EvalHash.revHash(path));
		case _: VNull;
	});

	public static final getInstanceFields = EvalEncode.vfun1(v -> switch v {
		case VPrototype(proto):
			try {
				function loop(acc:GlobalsIntMap<Int>, proto:Vprototype):GlobalsIntMap<Int> {
					var acc = switch proto.pparent {
							case null: acc;
							case proto: loop(acc, proto);
						}
					var acc = proto.pinstanceNames.fold((name, _, acc:GlobalsIntMap<Int>) -> acc.add(name, 0), acc);
					return proto.pnames.fold((name, _, acc:GlobalsIntMap<Int>) -> acc.add(name, 0), acc);
				}
				var proto = EvalContext.getInstancePrototype(EvalContext.getCtx(), proto.ppath, Globals.nullPos);
				EvalEncode.encodeArray([
					for (i in EvalStdLib.ptmapKeys(loop(GlobalsIntMap.empty(), proto))) EvalEncode.encodeString(EvalHash.revHash(i))
				]);
			} catch (_:NotFound) {
				VNull;
			}
		case _:
			VNull;
	});

	public static final getSuperClass = EvalEncode.vfun1(v -> switch v {
		case VPrototype({pkind: PClass(_), pparent: proto}) if (proto != null): proto.pvalue;
		case _: VNull;
	});

	public static final resolveClass = EvalEncode.vfun1(v -> {
		var name = EvalDecode.decodeVstring(v).sstring;
		try EvalContext.getStaticPrototypeRaise(EvalContext.getCtx(), EvalHash.hash(name)).pvalue
		catch (_:NotFound) VNull;
	});

	public static final resolveEnum = EvalEncode.vfun1(v -> {
		var name = EvalDecode.decodeVstring(v).sstring;
		try {
			var proto = EvalContext.getStaticPrototypeRaise(EvalContext.getCtx(), EvalHash.hash(name));
			switch proto.pkind {
				case PEnum(_): proto.pvalue;
				case _: VNull;
			}
		} catch (_:NotFound) {
			VNull;
		}
	});

	public static final typeof = EvalEncode.vfun1(v -> {
		var ctx = EvalContext.getCtx();
		function loop(v:Value):{i:Int, vl:Array<Value>} {
			return switch v {
				case VNull: {i: 0, vl: []};
				case VInt32(_): {i: 1, vl: []};
				case VInt64(_) | VUInt64(_): {i: 2, vl: []};
				case VFloat(_): {i: 3, vl: []};
				case VTrue | VFalse: {i: 4, vl: []};
				case VInstance(vi): {i: 7, vl: [EvalContext.getStaticPrototypeAsValue(ctx, vi.iproto.ppath, Globals.nullPos)]};
				case VString(_): {i: 7, vl: [EvalContext.getStaticPrototypeAsValue(ctx, EvalHash.key_String, Globals.nullPos)]};
				case VArray(_): {i: 7, vl: [EvalContext.getStaticPrototypeAsValue(ctx, EvalHash.key_Array, Globals.nullPos)]};
				case VVector(_): {
						i: 7,
						vl: [
							EvalContext.getStaticPrototypeAsValue(ctx, EvalHash.key_eval_Vector, Globals.nullPos)
						]
					};
				case VObject(_) | VPrototype(_): {i: 5, vl: []};
				case VFunction(_) | VFieldClosure(_): {i: 6, vl: []};
				case VEnumValue(ve): {i: 8, vl: [EvalContext.getStaticPrototypeAsValue(ctx, ve.epath, Globals.nullPos)]};
				case VLazy(f): loop(f.force());
				case VNativeString(_) | VHandle(_): {i: 9, vl: []};
			}
		}
		var r = loop(v);
		EvalEncode.encodeEnumValue(EvalHash.key_ValueType, r.i, Vector.fromArrayCopy(r.vl), null);
	});
}

class StdUncompress {
	static function thisValue(vthis:Value):Vzlib {
		return switch vthis {
			case VInstance({ikind: IZip(zip)}): zip;
			case _: EvalExceptions.unexpectedValue(vthis, "Uncompress");
		}
	}

	public static function zlibInflate(z:Dynamic, src:Bytes, spos:Int, slen:Int, dst:Bytes, dpos:Int, dlen:Int, flush:Int):Zresult {
		return libs.extc.Extc.zlibInflate(z, src, spos, slen, dst, dpos, dlen, flush);
	}

	public static final close = EvalEncode.vifun0(vthis -> {
		libs.extc.Extc.zlibInflateEnd(thisValue(vthis).z);
		VNull;
	});

	public static final execute = EvalEncode.vifun4((vthis, src, srcPos, dst, dstPos) -> {
		StdCompress.exec(zlibInflate, vthis, src, srcPos, dst, dstPos);
	});

	public static final run = EvalEncode.vfun2((src, bufsize) -> {
		var src = EvalDecode.decodeBytes(src);
		var bufsize = EvalDecode.defaultInt(bufsize, 1 << 16);
		var zip = libs.extc.Extc.zlibInflateInit();
		var buf = new haxe.io.BytesBuffer();
		var tmp = Bytes.alloc(bufsize);
		tmp.fill(0, bufsize, 0);
		var pos = 0;
		while (true) {
			var r = zlibInflate(zip, src, pos, src.length - pos, tmp, 0, bufsize, StdCompress.Z_SYNC_FLUSH);
			buf.addBytes(tmp, 0, r.z_wrote);
			if (!r.z_finish) pos = pos + r.z_read
			else break;
		}
		EvalEncode.encodeBytes(buf.getBytes());
	});

	public static var setFlushMode(get, never):Value;

	static inline function get_setFlushMode() return StdCompress.setFlushMode;
}

class StdUtf8 {
	static function thisValue(vthis:Value):StringBuf {
		return switch vthis {
			case VInstance({ikind: IUtf8(buf)}): buf;
			case v: EvalExceptions.unexpectedValue(v, "string");
		}
	}

	public static final addChar = EvalEncode.vifun1((vthis, c) -> {
		var c = EvalDecode.decodeInt(c);
		// port: UCharExt.uchar_of_int
		if (c < 0 || c >= 0x8000000) throw new InvalidArgument("UChar.uchar_of_int");
		thisValue(vthis).addChar(c);
		VNull;
	});

	public static var charCodeAt(get, never):Value;

	static inline function get_charCodeAt() return StdString.charCodeAt;

	public static final compare = EvalEncode.vfun2((a, b) -> {
		var a = EvalDecode.decodeString(a);
		var b = EvalDecode.decodeString(b);
		var c = EvalString.compareCodePoints(a, b);
		(c < 0 ? -1 : c > 0 ? 1 : 0).vint();
	});

	public static final decode = EvalEncode.vfun1(s -> {
		var s = EvalDecode.decodeString(s);
		var buf = new StringBuf();
		for (uc in new haxe.iterators.StringIteratorUnicode(s)) {
			// port: UCharExt.char_of
			if (uc > 255) throw new InvalidArgument("UChar.char_of");
			buf.addChar(uc);
		}
		var s = buf.toString();
		EvalString.createUnknown(s);
	});

	public static final encode = EvalEncode.vfun1(s -> {
		var s = EvalDecode.decodeString(s);
		var bytes = Bytes.ofString(s);
		var buf = new StringBuf();
		for (i in 0...bytes.length) buf.addChar(bytes.get(i));
		EvalString.createUnknown(buf.toString());
	});

	public static final iter = EvalEncode.vfun2((s, f) -> {
		var s = EvalDecode.decodeString(s);
		for (uc in new haxe.iterators.StringIteratorUnicode(s)) EvalMisc.callValue(f, [uc.vint()]);
		VNull;
	});

	public static final length = EvalEncode.vfun1(s -> {
		var s = EvalDecode.decodeVstring(s);
		s.slength.vint();
	});

	public static var sub(get, never):Value;

	static inline function get_sub() return StdString.substr;

	public static final toString = EvalEncode.vifun0(vthis -> {
		var self = thisValue(vthis);
		VString(EvalString.createAscii(self.toString()));
	});

	public static final validate = EvalEncode.vfun1(s -> {
		var s = EvalDecode.decodeString(s);
		// port: UTF8.validate on the native string's UTF-8 bytes (bytes that are
		// not UTF-8 are lone surrogates on a UTF-16 host:
		// core.StringHelper.codePointHost)
		(!core.StringHelper.malformedUtf8(s)).vbool();
	});
}

class StdNativeString {
	public static final fromString = EvalEncode.vfun1(v -> {
		switch EvalDecode.decodeOptional(EvalDecode.decodeVstring, v) {
			case null: VNull;
			case s: VNativeString(Bytes.ofString(s.sstring));
		}
	});

	public static final fromBytes = EvalEncode.vfun1(v -> {
		var b = EvalDecode.decodeBytes(v);
		VNativeString(b.sub(0, b.length));
	});

	public static final toString = EvalEncode.vfun1(v -> {
		var s = EvalDecode.decodeNativeString(v);
		EvalString.createUnknown(core.StringHelper.ofBytes(s));
	});

	public static final toBytes = EvalEncode.vfun1(v -> {
		var s = EvalDecode.decodeNativeString(v);
		EvalEncode.encodeBytes(s.sub(0, s.length));
	});

	public static final concat = EvalEncode.vfun2((v1, v2) -> {
		// port: `let ... and ...`: both are evaluated before the concatenation
		var s1 = EvalDecode.decodeNativeString(v1);
		var s2 = EvalDecode.decodeNativeString(v2);
		var b = Bytes.alloc(s1.length + s2.length);
		b.blit(0, s1, 0, s1.length);
		b.blit(s1.length, s2, 0, s2.length);
		VNativeString(b);
	});

	public static final char = EvalEncode.vfun2((v1, v2) -> {
		var s = EvalDecode.decodeNativeString(v1);
		var index = EvalDecode.decodeInt(v2);
		if (index < 0 || index >= s.length) EvalMisc.throwString("index out of bounds", Globals.nullPos)
		else EvalEncode.encodeString(String.fromCharCode(s.get(index)));
	});

	public static final code = EvalEncode.vfun2((v1, v2) -> {
		var s = EvalDecode.decodeNativeString(v1);
		var index = EvalDecode.decodeInt(v2);
		if (index < 0 || index >= s.length) EvalMisc.throwString("index out of bounds", Globals.nullPos)
		else s.get(index).vint();
	});

	public static final getLength = EvalEncode.vfun1(v -> {
		var s = EvalDecode.decodeNativeString(v);
		s.length.vint();
	});

	public static final sub = EvalEncode.vfun3((v1, v2, v3) -> {
		var s = EvalDecode.decodeNativeString(v1);
		var start = EvalDecode.decodeInt(v2);
		var maxLength = s.length - start;
		function stringSub(start:Int, length:Int):Value {
			if (start < 0 || length < 0 || start > s.length - length) return
				EvalMisc.throwString("Invalid arguments for eval.NativeString.sub", Globals.nullPos);
			return VNativeString(s.sub(start, length));
		}
		if (v3.match(VNull)) stringSub(start, maxLength)
		else {
			var length = {
				var l = EvalDecode.decodeInt(v3);
				l > maxLength ? maxLength : l;
			}
			stringSub(start, length);
		}
	});
}
