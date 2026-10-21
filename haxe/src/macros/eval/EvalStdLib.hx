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
import core.Globals.GlobalTypePath;
import core.ds.Failure;
import core.ds.GlobalsIntMap;
import core.ds.NotFound;
import haxe.io.Bytes;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalHash;
import macros.eval.EvalString;
import macros.eval.EvalEncode;
import macros.eval.EvalDecode;
import macros.eval.EvalExceptions;
import macros.eval.EvalMisc;
import macros.eval.EvalStdLibA.StdEvalVector;
import macros.eval.EvalStdLibA.StdArray;
import macros.eval.EvalStdLibA.StdBytes;
import macros.eval.EvalStdLibA.StdBytesBuffer;
import macros.eval.EvalStdLibA.StdCompress;
import macros.eval.EvalStdLibA.StdContext;
import macros.eval.EvalStdLibA.StdCrc32;
import macros.eval.EvalStdLibA.StdDate;
import macros.eval.EvalStdLibA.StdDeque;
import macros.eval.EvalStdLibA.StdEReg;
import macros.eval.EvalStdLibA.StdFile;
import macros.eval.EvalStdLibA.StdFileInput;
import macros.eval.EvalStdLibA.StdFileOutput;
import macros.eval.EvalStdLibA.StdFPHelper;
import macros.eval.EvalStdLibA.StdFileSystem;
import macros.eval.EvalStdLibA.StdGc;
import macros.eval.EvalStdLibA.StdHost;
import macros.eval.EvalStdLibA.StdLock;
import macros.eval.EvalStdLibB.StdLog;
import macros.eval.EvalStdLibB.StdIntMap;
import macros.eval.EvalStdLibB.StdInt64Map;
import macros.eval.EvalStdLibB.StdStringMap;
import macros.eval.EvalStdLibB.StdObjectMap;
import macros.eval.EvalStdLibB.StdMath;
import macros.eval.EvalStdLibB.StdMd5;
import macros.eval.EvalStdLibB.StdMutex;
import macros.eval.EvalStdLibB.StdSemaphore;
import macros.eval.EvalStdLibB.StdCondition;
import macros.eval.EvalStdLibB.StdNativeProcess;
import macros.eval.EvalStdLibB.StdReflect;
import macros.eval.EvalStdLibB.StdResource;
import macros.eval.EvalStdLibB.StdSha1;
import macros.eval.EvalStdLibB.StdSocket;
import macros.eval.EvalStdLibB.StdStd;
import macros.eval.EvalStdLibB.StdString;
import macros.eval.EvalStdLibB.StdStringBuf;
import macros.eval.EvalStdLibB.StdStringTools;
import macros.eval.EvalStdLibB.StdSys;
import macros.eval.EvalStdLibB.StdThread;
import macros.eval.EvalStdLibB.StdTls;
import macros.eval.EvalStdLibB.StdType;
import macros.eval.EvalStdLibB.StdUncompress;
import macros.eval.EvalStdLibB.StdUtf8;
import macros.eval.EvalStdLibB.StdNativeString;
import macros.eval.EvalStdLibB.StdLibBHelpers;

using macros.eval.EvalValue.EvalValueTools;
// port: the host natives of hxmc (hxmc/std)
#if (target.name == "hxmc")
import hxmc.NativeNet;
#end

// port: haxe/src/macro/eval/evalStdLib.ml: the shared helpers (lines 1-44) and the
// registration of the standard library natives (`init_fields` .. the end).
// The `StdX` modules are in `EvalStdLibA` (first half) and `EvalStdLibB`.
//
// Deviations:
// - `catch_unix_error`: the host raises no `Unix_error`; any host exception
//   other than an interpreter exception (`RunTimeException`) or `Not_found`
//   becomes an Eval string exception carrying the host message.
// - `hashtbl_keys` follows the host map's key order (OCaml `Hashtbl` order is
//   not reproduced).
// - libuv (`EvalLuv`) and mbedtls (`EvalSsl`) work on the hxmc host
//   (hxmc/); elsewhere their natives throw "... is not supported by
//   haxe-in-haxe". Sockets use `hxmc.NativeNet` on the hxmc host and
//   `EvalHostNet` on HashLink, and fail likewise on other hosts.
// - zlib streams are libs.extc.Extc streams (Zlib for deflate, Inflater for inflate).
// - Field lists are `{name, value}` pairs instead of OCaml tuples.
class EvalStdLib {
	public static function catchUnixError<A, B>(f:A->B, arg:A):B {
		try {
			return f(arg);
		} catch (e:RunTimeException) {
			throw e;
		} catch (e:NotFound) {
			throw e;
		} catch (e:haxe.Exception) {
			return EvalContext.excString(e.message);
		}
	}

	public static function ptmapKeys<V>(h:GlobalsIntMap<V>):Array<Int> {
		return h.fold((k, _, acc:Array<Int>) -> {
			acc.unshift(k);
			acc;
		}, []);
	}

	public static function hashtblKeys<V>(h:haxe.ds.StringMap<V>):Array<String> {
		var acc = [];
		for (k in h.keys()) acc.unshift(k);
		return acc;
	}

	static function notSupported(what:String):Dynamic {
		return EvalContext.excString(what + " is not supported by haxe-in-haxe");
	}

	// port: hxmc's persistent module cache (hxmc/src/hxmc/ModuleCache.hx) learns here what a macro's
	// ... result depends on beyond the sources: a call whose result changes from run to run
	// ... (volatileHook: the time, randomness, the network, processes; its name), a file read
	// ... (fileHook: its kind, "c" the content, "d" a directory's listing, "e" whether it exists and
	// ... what it is, "s" its status, "p" its full path; then the path as given), an environment
	// ... variable read (envHook: its name, null for the whole environment). Called before the
	// ... native runs (a file that does not exist is a dependency too); always null in the compiler
	// ... itself, where the wrapped natives do what upstream's do.
	public static var volatileHook:Null<String->Void> = null;
	public static var fileHook:Null<(kind:String, path:String) -> Void> = null;
	public static var envHook:Null<Null<String>->Void> = null;

	// port: a native wrapped to tell volatileHook it ran (what: the call, as a user writes it)
	static function volatile(what:String, v:Value):Value {
		return switch v {
			case VFunction(f, isStatic):
				VFunction(vl -> {
					var h = volatileHook;
					if (h != null) h(what);
					f(vl);
				}, isStatic);
			case _: v;
		}
	}

	// port: every native of a list wrapped by volatile
	static function volatileFields(what:String, l:Array<{name:String, value:Value}>):Array<{name:String, value:Value}> {
		return [for (f in l) {name: f.name, value: volatile(what, f.value)}];
	}

	// port: eval.luv.Env's getEnv and environ wrapped by envRead
	static function luvEnv(l:Array<{name:String, value:Value}>):Array<{name:String, value:Value}> {
		return [
			for (f in l)
				{name: f.name, value: f.name == "getEnv" ? envRead(false, f.value) : f.name == "environ" ? envRead(true, f.value) : f.value}
		];
	}

	// port: a constructor wrapped to tell volatileHook it ran
	static function volatileConstructor(what:String, f:Array<Value>->Value):Array<Value>->Value {
		return vl -> {
			var h = volatileHook;
			if (h != null) h(what);
			f(vl);
		}
	}

	// port: a native whose first argument is a path, wrapped to tell fileHook it is read
	static function fileRead(kind:String, v:Value):Value {
		return switch v {
			case VFunction(f, isStatic):
				VFunction(vl -> {
					var h = fileHook;
					if (h != null && vl.length > 0) {
						var path = try EvalDecode.decodeString(vl[0]) catch (_:Dynamic) null;
						if (path != null) h(kind, path);
					}
					f(vl);
				}, isStatic);
			case _: v;
		}
	}

	// port: Sys.getEnv (whole: Sys.environment), wrapped to tell envHook
	static function envRead(whole:Bool, v:Value):Value {
		return switch v {
			case VFunction(f, isStatic):
				VFunction(vl -> {
					var h = envHook;
					if (h != null) {
						if (whole) h(null) else if (vl.length > 0) {
							var name = try EvalDecode.decodeString(vl[0]) catch (_:Dynamic) null;
							if (name != null) h(name);
						}
					}
					f(vl);
				}, isStatic);
			case _: v;
		}
	}

	public static function initFields(builtins:Builtins, path:GlobalTypePath, staticFields:Array<{name:String, value:Value}>,
			instanceFields:Array<{name:String, value:Value}>):Void {
		function map(f:{name:String, value:Value}):{name:Int, value:Value}
			return {name: EvalHash.hash(f.name), value: f.value};
		var path = EvalHash.pathHash(path);
		builtins.staticBuiltins = builtins.staticBuiltins.add(path, staticFields.map(map));
		builtins.instanceBuiltins = builtins.instanceBuiltins.add(path, instanceFields.map(map));
	}

	static inline function tp(pack:Array<String>, name:String):GlobalTypePath return new GlobalTypePath(pack, name);

	public static function initMaps(builtins:Builtins):Void {
		initFields(builtins, tp(["haxe", "ds"], "IntMap"), [], [
			{name: "copy", value: StdIntMap.copy},
			{name: "exists", value: StdIntMap.exists},
			{name: "get", value: StdIntMap.get},
			{name: "iterator", value: StdIntMap.iterator},
			{name: "keys", value: StdIntMap.keys},
			{name: "keyValueIterator", value: StdIntMap.keyValueIterator},
			{name: "remove", value: StdIntMap.remove},
			{name: "set", value: StdIntMap.set},
			{name: "toString", value: StdIntMap.toString},
			{name: "clear", value: StdIntMap.clear},
			{name: "size", value: StdIntMap.size},
		]);
		initFields(builtins, tp(["haxe", "ds"], "Int64Map"), [], [
			{name: "copy", value: StdInt64Map.copy},
			{name: "exists", value: StdInt64Map.exists},
			{name: "get", value: StdInt64Map.get},
			{name: "iterator", value: StdInt64Map.iterator},
			{name: "keys", value: StdInt64Map.keys},
			{name: "keyValueIterator", value: StdInt64Map.keyValueIterator},
			{name: "remove", value: StdInt64Map.remove},
			{name: "set", value: StdInt64Map.set},
			{name: "toString", value: StdInt64Map.toString},
			{name: "clear", value: StdInt64Map.clear},
			{name: "size", value: StdInt64Map.size},
		]);
		initFields(builtins, tp(["haxe", "ds"], "ObjectMap"), [], [
			{name: "copy", value: StdObjectMap.copy},
			{name: "exists", value: StdObjectMap.exists},
			{name: "get", value: StdObjectMap.get},
			{name: "iterator", value: StdObjectMap.iterator},
			{name: "keys", value: StdObjectMap.keys},
			{name: "keyValueIterator", value: StdObjectMap.keyValueIterator},
			{name: "remove", value: StdObjectMap.remove},
			{name: "set", value: StdObjectMap.set},
			{name: "toString", value: StdObjectMap.toString},
			{name: "clear", value: StdObjectMap.clear},
			{name: "size", value: StdObjectMap.size},
		]);
		initFields(builtins, tp(["haxe", "ds"], "StringMap"), [], [
			{name: "copy", value: StdStringMap.copy},
			{name: "exists", value: StdStringMap.exists},
			{name: "get", value: StdStringMap.get},
			{name: "iterator", value: StdStringMap.iterator},
			{name: "keys", value: StdStringMap.keys},
			{name: "keyValueIterator", value: StdStringMap.keyValueIterator},
			{name: "remove", value: StdStringMap.remove},
			{name: "set", value: StdStringMap.set},
			{name: "toString", value: StdStringMap.toString},
			{name: "clear", value: StdStringMap.clear},
			{name: "size", value: StdStringMap.size},
		]);
	}

	static function die():Dynamic throw new Failure("evalStdLib: unexpected constructor arguments");

	static final tlsCounter = new haxe.atomic.AtomicInt(0);

	public static function initConstructors(builtins:Builtins):Void {
		function add(key:Int, f:Array<Value>->Value) builtins.constructorBuiltins.set(key, f);
		add(EvalHash.key_Array, _ -> EvalEncode.encodeArrayInstance(EvalArray.create(new haxe.ds.Vector(0))));
		add(EvalHash.key_eval_Vector, vl -> switch vl {
			case [size]:
				{
			// port: `Array.make`
			var n = EvalDecode.decodeInt(size);
			if (n < 0) throw new core.ds.InvalidArgument("Array.make");
			EvalEncode.encodeVectorInstance(new haxe.ds.Vector(n, VNull));
		}
			case _: die();
		});
		add(EvalHash.key_Date, vl -> {
			switch vl.map(EvalDecode.decodeInt) {
				case [y, m, d, h, mi, s]:
					// port: Unix.mktime of the local time
					var f = catchUnixError(_ -> new Date(y, m, d, h, mi, s).getTime() / 1000.0, null);
					EvalEncode.encodeInstance(EvalHash.key_Date, IDate(f));
				case _: die();
			}
		});
		add(EvalHash.key_EReg, vl -> switch vl {
			case [r, opt]: EvalEncode.encodeInstance(EvalHash.key_EReg,
					StdEReg.create(EvalDecode.decodeString(r), EvalDecode.decodeString(opt)));
			case _: die();
		});
		add(EvalHash.key_String, vl -> switch vl {
			case [s]: s;
			case _: die();
		});
		add(EvalHash.key_StringBuf, _ -> EvalEncode.encodeInstance(EvalHash.key_StringBuf, IBuffer(EvalString.bufferCreate())));
		add(EvalHash.key_haxe_Utf8, vl -> switch vl {
			case [size]:
				EvalDecode.defaultInt(size, 0);
				EvalEncode.encodeInstance(EvalHash.key_haxe_Utf8, IUtf8(new StringBuf()));
			case _: die();
		});
		add(EvalHash.key_haxe_ds_StringMap, _ -> EvalEncode.encodeStringMapDirect(new RuntimeStringHashtbl()));
		add(EvalHash.key_haxe_ds_IntMap, _ -> EvalEncode.encodeIntMapDirect(new RuntimeIntHashtbl()));
		add(EvalHash.key_haxe_ds_Int64Map, _ -> EvalEncode.encodeInt64MapDirect(new RuntimeInt64Hashtbl()));
		add(EvalHash.key_haxe_ds_ObjectMap, _ -> EvalEncode.encodeObjectMapDirect(EvalValueTools.createValueHashtbl()));
		add(EvalHash.key_haxe_io_BytesBuffer,
			_ -> EvalEncode.encodeInstance(EvalHash.key_haxe_io_BytesBuffer, IOutput(new haxe.io.BytesBuffer())));
		add(EvalHash.key_haxe_io_Bytes, vl -> switch vl {
			case [length, b]:
				var length = EvalDecode.decodeInt(length);
				var b = EvalDecode.decodeBytes(b);
				var blitLength = if (length > b.length) b.length else length;
				var b2 = Bytes.alloc(length);
				b2.blit(0, b, 0, blitLength);
				EvalEncode.encodeBytes(b2);
			case _:
				die();
		});
		add(EvalHash.key_sys_io__Process_NativeProcess, volatileConstructor("sys.io.Process", vl -> switch vl {
			case [cmd, args]:
				var cmd = EvalDecode.decodeString(cmd);
				var args:Null<Array<String>> = switch args {
					case VNull: null;
					case VArray(va): [for (i in 0...va.alength) EvalDecode.decodeString(va.avalues[i])];
					case _: EvalExceptions.unexpectedValue(args, "array");
				}
				var proc = StdLibBHelpers.processCatch(_ -> EvalProcess.run(cmd, args), null);
				EvalEncode.encodeInstance(EvalHash.key_sys_io__Process_NativeProcess, IProcess(proc));
			case _: die();
		}));
		add(EvalHash.key_eval_vm_NativeSocket, volatileConstructor("sys.net.Socket", _ -> {
			#if (target.name == "hxmc" || hl)
			// port: catch_unix_error Unix.socket PF_INET SOCK_STREAM 0
			var fd = macros.eval.EvalStdLibB.StdSocket.check(#if hl macros.eval.EvalHostNet #else NativeNet #end.socket(), "socket");
			EvalEncode.encodeInstance(EvalHash.key_eval_vm_NativeSocket, ISocket(new Vsocket(fd)));
			#else
			notSupported("Sockets (eval.vm.NativeSocket)");
			#end
		}));
		add(EvalHash.key_haxe_zip_Compress, vl -> switch vl {
			case [level]:
				var level = EvalDecode.decodeInt(level);
				var z = libs.extc.Extc.zlibDeflateInit(level);
				EvalEncode.encodeInstance(EvalHash.key_haxe_zip_Compress, IZip(new Vzlib(z, StdCompress.Z_NO_FLUSH)));
			case _: die();
		});
		add(EvalHash.key_haxe_zip_Uncompress, vl -> switch vl {
			case [windowBits]:
				var windowBits = EvalDecode.defaultInt(windowBits, 15);
				var z = libs.extc.Extc.zlibInflateInit2(windowBits);
				EvalEncode.encodeInstance(EvalHash.key_haxe_zip_Uncompress, IZip(new Vzlib(z, StdCompress.Z_NO_FLUSH)));
			case _: die();
		});
		add(EvalHash.key_eval_vm_Thread, vl -> switch vl {
			case [f]:
				var ctx = EvalContext.getCtx();
				if (ctx.isMacro) EvalContext.excString("Creating threads in macros is not supported");
				var thread = EvalThread.spawnDomain(ctx, () -> EvalMisc.callValue(f, []));
				EvalEncode.encodeInstance(EvalHash.key_eval_vm_Thread, IThread(thread));
			case _: die();
		});
		add(EvalHash.key_sys_net_Mutex, _ -> {
			var mutex = new DomainMutex();
			EvalEncode.encodeInstance(EvalHash.key_sys_net_Mutex, IMutex(mutex));
		});
		add(EvalHash.key_sys_net_Semaphore, vl -> {
			// port: List.hd
			if (vl.length == 0) throw new Failure("hd");
			var v = vl[0];
			var sem = new sys.thread.Semaphore(EvalDecode.decodeInt(v));
			EvalEncode.encodeInstance(EvalHash.key_sys_net_Semaphore, ISemaphore(sem));
		});
		add(EvalHash.key_sys_net_Condition, _ -> {
			var cond = new Vcondition();
			EvalEncode.encodeInstance(EvalHash.key_sys_net_Condition, ICondition(cond));
		});
		add(EvalHash.key_sys_net_Lock, _ -> {
			var lock = new Vlock();
			EvalEncode.encodeInstance(EvalHash.key_sys_net_Lock, ILock(lock));
		});
		add(EvalHash.key_sys_net_Tls, _ -> {
			var id = tlsCounter.add(1);
			EvalEncode.encodeInstance(EvalHash.key_sys_net_Tls, ITls(id));
		});
		add(EvalHash.key_sys_net_Deque, _ -> {
			EvalEncode.encodeInstance(EvalHash.key_sys_net_Deque, IDeque(EvalThread.Deque.create()));
		});
		EvalSsl.initConstructors((key, f) -> add(key, volatileConstructor("sys.ssl", f)));
	}

	public static function initEmptyConstructors(builtins:Builtins):Void {
		var h = builtins.emptyConstructorBuiltins;
		h.set(EvalHash.key_Array, () -> EvalEncode.encodeArrayInstance(EvalArray.create(new haxe.ds.Vector(0))));
		h.set(EvalHash.key_eval_Vector, () -> EvalEncode.encodeVectorInstance(new haxe.ds.Vector(0)));
		h.set(EvalHash.key_Date, () -> EvalEncode.encodeInstance(EvalHash.key_Date, IDate(0.)));
		h.set(EvalHash.key_EReg,
			() -> EvalEncode.encodeInstance(EvalHash.key_EReg, IRegex(new Vregex(new EReg("", ""), EvalString.createAscii("~//"), false))));
		h.set(EvalHash.key_String, () -> EvalString.vEmptyString);
		h.set(EvalHash.key_haxe_ds_StringMap,
			() -> EvalEncode.encodeInstance(EvalHash.key_haxe_ds_StringMap, IStringMap(new RuntimeStringHashtbl())));
		h.set(EvalHash.key_haxe_ds_IntMap, () -> EvalEncode.encodeInstance(EvalHash.key_haxe_ds_IntMap, IIntMap(new RuntimeIntHashtbl())));
		h.set(EvalHash.key_haxe_ds_Int64Map,
			() -> EvalEncode.encodeInstance(EvalHash.key_haxe_ds_Int64Map, IInt64Map(new RuntimeInt64Hashtbl())));
		h.set(EvalHash.key_haxe_ds_ObjectMap,
			() -> EvalEncode.encodeInstance(EvalHash.key_haxe_ds_ObjectMap, IObjectMap(EvalValueTools.createValueHashtbl())));
		h.set(EvalHash.key_haxe_io_BytesBuffer,
			() -> EvalEncode.encodeInstance(EvalHash.key_haxe_io_BytesBuffer, IOutput(new haxe.io.BytesBuffer())));
	}

	public static function initStandardLibrary(builtins:Builtins):Void {
		initConstructors(builtins);
		initEmptyConstructors(builtins);
		initMaps(builtins);
		initFields(builtins, tp([], "Array"), [], [
			{name: "concat", value: StdArray.concat},
			{name: "copy", value: StdArray.copy},
			{name: "filter", value: StdArray.filter},
			{name: "indexOf", value: StdArray.indexOf},
			{name: "insert", value: StdArray.insert},
			{name: "iterator", value: StdArray.iterator},
			{name: "join", value: StdArray.join},
			{name: "keyValueIterator", value: StdArray.keyValueIterator},
			{name: "lastIndexOf", value: StdArray.lastIndexOf},
			{name: "map", value: StdArray.map},
			{name: "pop", value: StdArray.pop},
			{name: "push", value: StdArray.push},
			{name: "remove", value: StdArray.remove},
			{name: "resize", value: StdArray.resize},
			{name: "contains", value: StdArray.contains},
			{name: "reverse", value: StdArray.reverse},
			{name: "shift", value: StdArray.shift},
			{name: "slice", value: StdArray.slice},
			{name: "sort", value: StdArray.sort},
			{name: "splice", value: StdArray.splice},
			{name: "toString", value: StdArray.toString},
			{name: "unshift", value: StdArray.unshift},
		]);
		initFields(builtins, tp(["eval"], "Vector"), [{name: "fromArrayCopy", value: StdEvalVector.fromArrayCopy},], [
			{name: "blit", value: StdEvalVector.blit},
			{name: "toArray", value: StdEvalVector.toArray},
			{name: "copy", value: StdEvalVector.copy},
			{name: "join", value: StdEvalVector.join},
			{name: "map", value: StdEvalVector.map},
		]);
		initFields(builtins, tp(["haxe", "io"], "Bytes"), [
			{name: "alloc", value: StdBytes.alloc},
			{name: "fastGet", value: StdBytes.fastGet},
			{name: "ofData", value: StdBytes.ofData},
			{name: "ofString", value: StdBytes.ofString},
			{name: "ofHex", value: StdBytes.ofHex},
		], [
			{name: "blit", value: StdBytes.blit},
			{name: "compare", value: StdBytes.compare},
			{name: "fill", value: StdBytes.fill},
			{name: "get", value: StdBytes.get},
			{name: "getData", value: StdBytes.getData},
			{name: "getDouble", value: StdBytes.getDouble},
			{name: "getFloat", value: StdBytes.getFloat},
			{name: "getInt32", value: StdBytes.getInt32},
			{name: "getInt64", value: StdBytes.getInt64},
			{name: "getString", value: StdBytes.getString},
			{name: "getUInt16", value: StdBytes.getUInt16},
			{name: "set", value: StdBytes.set},
			{name: "setDouble", value: StdBytes.setDouble},
			{name: "setFloat", value: StdBytes.setFloat},
			{name: "setInt32", value: StdBytes.setInt32},
			{name: "setInt64", value: StdBytes.setInt64},
			{name: "setUInt16", value: StdBytes.setUInt16},
			{name: "sub", value: StdBytes.sub},
			{name: "toHex", value: StdBytes.toHex},
			{name: "toString", value: StdBytes.toString},
		]);
		initFields(builtins, tp(["haxe", "io"], "BytesBuffer"), [], [
			{name: "get_length", value: StdBytesBuffer.getLength},
			{name: "addByte", value: StdBytesBuffer.addByte},
			{name: "add", value: StdBytesBuffer.add},
			{name: "addString", value: StdBytesBuffer.addString},
			{name: "addInt32", value: StdBytesBuffer.addInt32},
			{name: "addInt64", value: StdBytesBuffer.addInt64},
			{name: "addFloat", value: StdBytesBuffer.addFloat},
			{name: "addDouble", value: StdBytesBuffer.addDouble},
			{name: "addBytes", value: StdBytesBuffer.addBytes},
			{name: "getBytes", value: StdBytesBuffer.getBytes},
		]);
		initFields(builtins, tp(["haxe"], "NativeStackTrace"), [
			{name: "_callStack", value: EvalStackTrace.getCallStack},
			{name: "exceptionStack", value: EvalStackTrace.getExceptionStack},
		], []);
		initFields(builtins, tp(["haxe", "zip"], "Compress"), [{name: "run", value: StdCompress.run},], [
			{name: "close", value: StdCompress.close},
			{name: "execute", value: StdCompress.execute},
			{name: "setFlushMode", value: StdCompress.setFlushMode},
		]);
		initFields(builtins, tp(["eval", "vm"], "Context"), [
			{name: "addBreakpoint", value: StdContext.addBreakpoint},
			{name: "breakHere", value: StdContext.breakHere},
			{name: "callMacroApi", value: StdContext.callMacroApi},
			{name: "loadPlugin", value: StdContext.loadPlugin},
		], []);
		initFields(builtins, tp(["haxe", "crypto"], "Crc32"), [{name: "make", value: StdCrc32.make},], []);
		initFields(builtins, tp([], "Date"), [
			{name: "fromString", value: StdDate.fromString},
			{name: "fromTime", value: StdDate.fromTime},
			{name: "now", value: volatile("Date.now", StdDate.now)},
		], [
			{name: "getDate", value: StdDate.getDate},
			{name: "getDay", value: StdDate.getDay},
			{name: "getFullYear", value: StdDate.getFullYear},
			{name: "getHours", value: StdDate.getHours},
			{name: "getMinutes", value: StdDate.getMinutes},
			{name: "getMonth", value: StdDate.getMonth},
			{name: "getSeconds", value: StdDate.getSeconds},
			{name: "getUTCDate", value: StdDate.getUTCDate},
			{name: "getUTCDay", value: StdDate.getUTCDay},
			{name: "getUTCFullYear", value: StdDate.getUTCFullYear},
			{name: "getUTCHours", value: StdDate.getUTCHours},
			{name: "getUTCMinutes", value: StdDate.getUTCMinutes},
			{name: "getUTCMonth", value: StdDate.getUTCMonth},
			{name: "getUTCSeconds", value: StdDate.getUTCSeconds},
			{name: "getTime", value: StdDate.getTime},
			{name: "getTimezoneOffset", value: StdDate.getTimezoneOffset},
			{name: "toString", value: StdDate.toString},
		]);
		initFields(builtins, tp(["sys", "thread"], "Deque"), [], [
			{name: "add", value: StdDeque.add},
			{name: "push", value: StdDeque.push},
			{name: "pop", value: StdDeque.pop},
		]);
		initFields(builtins, tp([], "EReg"), [{name: "escape", value: StdEReg.escape},], [
			{name: "map", value: StdEReg.map},
			{name: "match", value: StdEReg.matchValue},
			{name: "matched", value: StdEReg.matched},
			{name: "matchedLeft", value: StdEReg.matchedLeft},
			{name: "matchedPos", value: StdEReg.matchedPos},
			{name: "matchedRight", value: StdEReg.matchedRight},
			{name: "matchSub", value: StdEReg.matchSub},
			{name: "matchedNum", value: StdEReg.matchedNum},
			{name: "replace", value: StdEReg.replace},
			{name: "split", value: StdEReg.split},
		]);
		initFields(builtins, tp(["sys", "io"], "File"), [
			{name: "append", value: StdFile.append},
			{name: "getBytes", value: fileRead("c", StdFile.getBytes)},
			{name: "getContent", value: fileRead("c", StdFile.getContent)},
			{name: "read", value: fileRead("c", StdFile.read)},
			{name: "saveBytes", value: StdFile.saveBytes},
			{name: "saveContent", value: StdFile.saveContent},
			{name: "update", value: StdFile.update},
			{name: "write", value: StdFile.write},
		], []);
		initFields(builtins, tp(["sys", "io"], "FileInput"), [], [
			{name: "close", value: StdFileInput.close},
			{name: "eof", value: StdFileInput.eof},
			{name: "seek", value: StdFileInput.seek},
			{name: "tell", value: StdFileInput.tell},
			{name: "readByte", value: StdFileInput.readByte},
			{name: "readBytes", value: StdFileInput.readBytes},
		]);
		initFields(builtins, tp(["sys", "io"], "FileOutput"), [], [
			{name: "close", value: StdFileOutput.close},
			{name: "flush", value: StdFileOutput.flush},
			{name: "seek", value: StdFileOutput.seek},
			{name: "tell", value: StdFileOutput.tell},
			{name: "writeByte", value: StdFileOutput.writeByte},
			{name: "writeBytes", value: StdFileOutput.writeBytes},
		]);
		initFields(builtins, tp(["haxe", "io"], "FPHelper"), [
			{name: "doubleToI64", value: StdFPHelper.doubleToI64},
			{name: "floatToI32", value: StdFPHelper.floatToI32},
			{name: "i32ToFloat", value: StdFPHelper.i32ToFloat},
			{name: "i64ToDouble", value: StdFPHelper.i64ToDouble},
		], []);
		initFields(builtins, tp(["sys"], "FileSystem"), [
			{name: "createDirectory", value: StdFileSystem.createDirectory},
			{name: "deleteFile", value: StdFileSystem.deleteFile},
			{name: "deleteDirectory", value: StdFileSystem.deleteDirectory},
			{name: "exists", value: fileRead("e", StdFileSystem.exists)},
			{name: "fullPath", value: fileRead("p", StdFileSystem.fullPath)},
			{name: "isDirectory", value: fileRead("e", StdFileSystem.isDirectory)},
			{name: "rename", value: StdFileSystem.rename},
			{name: "readDirectory", value: fileRead("d", StdFileSystem.readDirectory)},
			{name: "stat", value: fileRead("s", StdFileSystem.stat)},
		], []);
		initFields(builtins, tp(["eval", "vm"], "Gc"), [
			{name: "allocated_bytes", value: StdGc.allocatedBytes},
			{name: "compact", value: StdGc.compact},
			{name: "counters", value: StdGc.counters},
			{name: "finalise", value: StdGc.finalise},
			{name: "finalise_release", value: StdGc.finaliseRelease},
			{name: "full_major", value: StdGc.fullMajor},
			{name: "get", value: StdGc.get},
			{name: "major", value: StdGc.major},
			{name: "major_slice", value: StdGc.majorSlice},
			{name: "minor", value: StdGc.minor},
			{name: "print_stat", value: StdGc.printStat},
			{name: "quick_stat", value: StdGc.quickStat},
			{name: "set", value: StdGc.set},
			{name: "stat", value: StdGc.stat},
		], []);
		initFields(builtins, tp(["sys", "net"], "Host"), [
			{name: "localhost", value: volatile("sys.net.Host", StdHost.localhost)},
			{name: "hostReverse", value: volatile("sys.net.Host", StdHost.hostReverse)},
			{name: "hostToString", value: StdHost.hostToString},
			{name: "resolve", value: volatile("sys.net.Host", StdHost.resolve)},
		], []);
		initFields(builtins, tp(["sys", "thread"], "Lock"), [],
			[{name: "release", value: StdLock.release}, {name: "wait", value: StdLock.wait},]);
		initFields(builtins, tp(["haxe"], "Log"), [{name: "trace", value: StdLog.trace},], []);
		initFields(builtins, tp([], "Math"), [
			{name: "NaN", value: StdMath.nan},
			{name: "NEGATIVE_INFINITY", value: StdMath.negativeInfinity},
			{name: "PI", value: StdMath.pi},
			{name: "POSITIVE_INFINITY", value: StdMath.positiveInfinity},
			{name: "abs", value: StdMath.abs},
			{name: "acos", value: StdMath.acos},
			{name: "asin", value: StdMath.asin},
			{name: "atan", value: StdMath.atan},
			{name: "atan2", value: StdMath.atan2},
			{name: "ceil", value: StdMath.ceil},
			{name: "cos", value: StdMath.cos},
			{name: "exp", value: StdMath.exp},
			{name: "fceil", value: StdMath.fceil},
			{name: "ffloor", value: StdMath.ffloor},
			{name: "floor", value: StdMath.floor},
			{name: "fround", value: StdMath.fround},
			{name: "isFinite", value: StdMath.isFinite},
			{name: "isNaN", value: StdMath.isNaN},
			{name: "log", value: StdMath.log},
			{name: "max", value: StdMath.max},
			{name: "min", value: StdMath.min},
			{name: "pow", value: StdMath.pow},
			{name: "random", value: volatile("Math.random", StdMath.random)},
			{name: "round", value: StdMath.round},
			{name: "sin", value: StdMath.sin},
			{name: "sqrt", value: StdMath.sqrt},
			{name: "tan", value: StdMath.tan},
		], []);
		initFields(builtins, tp(["haxe", "crypto"], "Md5"), [{name: "encode", value: StdMd5.encode}, {name: "make", value: StdMd5.make},],
			[]);
		initFields(builtins, tp(["sys", "thread"], "Mutex"), [], [
			{name: "acquire", value: StdMutex.acquire},
			{name: "tryAcquire", value: StdMutex.tryAcquire},
			{name: "release", value: StdMutex.release},
		]);
		initFields(builtins, tp(["sys", "thread"], "Semaphore"), [], [
			{name: "acquire", value: StdSemaphore.acquire},
			{name: "tryAcquire", value: StdSemaphore.tryAcquire},
			{name: "release", value: StdSemaphore.release},
		]);
		initFields(builtins, tp(["sys", "thread"], "Condition"), [], [
			{name: "acquire", value: StdCondition.acquire},
			{name: "tryAcquire", value: StdCondition.tryAcquire},
			{name: "release", value: StdCondition.release},
			{name: "wait", value: StdCondition.wait},
			{name: "signal", value: StdCondition.signal},
			{name: "broadcast", value: StdCondition.broadcast},
		]);
		initFields(builtins, tp(["sys", "io", "_Process"], "NativeProcess"), [], [
			{name: "close", value: StdNativeProcess.close},
			{name: "exitCode", value: StdNativeProcess.exitCode},
			{name: "getPid", value: StdNativeProcess.getPid},
			{name: "kill", value: StdNativeProcess.kill},
			{name: "readStderr", value: StdNativeProcess.readStderr},
			{name: "readStdout", value: StdNativeProcess.readStdout},
			{name: "closeStdin", value: StdNativeProcess.closeStdin},
			{name: "writeStdin", value: StdNativeProcess.writeStdin},
		]);
		initFields(builtins, tp([], "Reflect"), [
			{name: "callMethod", value: StdReflect.callMethod},
			{name: "compare", value: StdReflect.compare},
			{name: "compareMethods", value: StdReflect.compareMethods},
			{name: "copy", value: StdReflect.copy},
			{name: "deleteField", value: StdReflect.deleteField},
			{name: "field", value: StdReflect.fieldValue},
			{name: "fields", value: StdReflect.fields},
			{name: "getProperty", value: StdReflect.getProperty},
			{name: "hasField", value: StdReflect.hasField},
			{name: "isEnumValue", value: StdReflect.isEnumValue},
			{name: "isFunction", value: StdReflect.isFunction},
			{name: "isObject", value: StdReflect.isObject},
			{name: "makeVarArgs", value: StdReflect.makeVarArgs},
			{name: "setField", value: StdReflect.setField},
			{name: "setProperty", value: StdReflect.setProperty},
		], []);
		initFields(builtins, tp(["haxe"], "Resource"), [
			{name: "listNames", value: StdResource.listNames},
			{name: "getString", value: StdResource.getString},
			{name: "getBytes", value: StdResource.getBytes},
		], []);
		initFields(builtins, tp(["haxe", "crypto"], "Sha1"),
			[{name: "encode", value: StdSha1.encode}, {name: "make", value: StdSha1.make},], []);
		initFields(builtins, tp(["eval", "vm"], "NativeSocket"), [{name: "select", value: volatile("sys.net.Socket", StdSocket.select)},], [
			{name: "accept", value: StdSocket.accept},
			{name: "bind", value: StdSocket.bind},
			{name: "close", value: StdSocket.close},
			{name: "connect", value: StdSocket.connect},
			{name: "host", value: StdSocket.host},
			{name: "listen", value: StdSocket.listen},
			{name: "peer", value: StdSocket.peer},
			{name: "receive", value: StdSocket.receive},
			{name: "receiveChar", value: StdSocket.receiveChar},
			{name: "send", value: StdSocket.send},
			{name: "sendChar", value: StdSocket.sendChar},
			{name: "setFastSend", value: StdSocket.setFastSend},
			{name: "setBroadcast", value: StdSocket.setBroadcast},
			{name: "setTimeout", value: StdSocket.setTimeout},
			{name: "shutdown", value: StdSocket.shutdown},
		]);
		initFields(builtins, tp([], "Std"), [
			{name: "downcast", value: StdStd.downcast},
			{name: "instance", value: StdStd.instance},
			{name: "int", value: StdStd.int},
			{name: "is", value: StdStd.isValue},
			{name: "isOfType", value: StdStd.isOfType},
			{name: "parseFloat", value: StdStd.parseFloat},
			{name: "parseInt", value: StdStd.parseInt},
			{name: "string", value: StdStd.string},
			{name: "random", value: volatile("Std.random", StdStd.random)},
		], []);
		initFields(builtins, tp([], "String"), [{name: "fromCharCode", value: StdString.fromCharCode},], [
			{name: "charAt", value: StdString.charAt},
			{name: "charCodeAt", value: StdString.charCodeAt},
			{name: "indexOf", value: StdString.indexOf},
			{name: "lastIndexOf", value: StdString.lastIndexOf},
			{name: "split", value: StdString.split},
			{name: "substr", value: StdString.substr},
			{name: "substring", value: StdString.substring},
			{name: "toLowerCase", value: StdString.toLowerCase},
			{name: "toString", value: StdString.toString},
			{name: "toUpperCase", value: StdString.toUpperCase},
			{name: "cca", value: StdString.cca},
		]);
		initFields(builtins, tp([], "StringBuf"), [], [
			{name: "add", value: StdStringBuf.add},
			{name: "addChar", value: StdStringBuf.addChar},
			{name: "addSub", value: StdStringBuf.addSub},
			{name: "clear", value: StdStringBuf.clear},
			{name: "get_length", value: StdStringBuf.getLength},
			{name: "toString", value: StdStringBuf.toString},
		]);
		initFields(builtins, tp([], "StringTools"), [
			{name: "fastCodeAt", value: StdStringTools.fastCodeAt},
			{name: "replace", value: StdStringTools.replace},
			{name: "urlEncode", value: StdStringTools.urlEncode},
			{name: "urlDecode", value: StdStringTools.urlDecode},
		], []);
		initFields(builtins, tp([], "Sys"), [
			{name: "args", value: StdSys.args},
			{name: "_command", value: volatile("Sys.command", StdSys._command)},
			{name: "cpuTime", value: volatile("Sys.cpuTime", StdSys.cpuTime)},
			{name: "environment", value: envRead(true, StdSys.environment)},
			{name: "exit", value: StdSys.exit},
			{name: "getChar", value: volatile("Sys.getChar", StdSys.getChar)},
			{name: "getCwd", value: StdSys.getCwd},
			{name: "getEnv", value: envRead(false, StdSys.getEnv)},
			{name: "print", value: StdSys.print},
			{name: "println", value: StdSys.println},
			{name: "programPath", value: StdSys.programPath},
			{name: "putEnv", value: StdSys.putEnv},
			{name: "setCwd", value: StdSys.setCwd},
			{name: "setTimeLocale", value: StdSys.setTimeLocale},
			{name: "sleep", value: StdSys.sleep},
			{name: "stderr", value: StdSys.stderr},
			{name: "stdin", value: StdSys.stdin},
			{name: "stdout", value: StdSys.stdout},
			{name: "systemName", value: StdSys.systemName},
			{name: "time", value: volatile("Sys.time", StdSys.time)},
			{name: "timestamp_ms", value: volatile("Sys.time", StdSys.timestampMs)},
		], []);
		initFields(builtins, tp(["eval", "vm"], "NativeThread"), [
			{name: "delay", value: StdThread.delay},
			{name: "exit", value: StdThread.exit},
			{name: "join", value: StdThread.join},
			{name: "readMessage", value: StdThread.readMessage},
			{name: "self", value: StdThread.self},
			{name: "yield", value: StdThread.yield},
		], [
			{name: "id", value: StdThread.id},
			{name: "sendMessage", value: StdThread.sendMessage},
		]);
		initFields(builtins, tp(["sys", "thread"], "Tls"), [], [
			{name: "get_value", value: StdTls.getValue},
			{name: "set_value", value: StdTls.setValue},
		]);
		initFields(builtins, tp([], "Type"), [
			{name: "allEnums", value: StdType.allEnums},
			{name: "createEmptyInstance", value: StdType.createEmptyInstance},
			{name: "createEnum", value: StdType.createEnum},
			{name: "createEnumIndex", value: StdType.createEnumIndex},
			{name: "createInstance", value: StdType.createInstance},
			{name: "enumConstructor", value: StdType.enumConstructor},
			{name: "enumEq", value: StdType.enumEq},
			{name: "enumIndex", value: StdType.enumIndex},
			{name: "enumParameters", value: StdType.enumParameters},
			{name: "getClass", value: StdType.getClass},
			{name: "getClassFields", value: StdType.getClassFields},
			{name: "getClassName", value: StdType.getClassName},
			{name: "getEnum", value: StdType.getEnum},
			{name: "getEnumConstructs", value: StdType.getEnumConstructs},
			{name: "getEnumName", value: StdType.getEnumName},
			{name: "getInstanceFields", value: StdType.getInstanceFields},
			{name: "getSuperClass", value: StdType.getSuperClass},
			{name: "resolveClass", value: StdType.resolveClass},
			{name: "resolveEnum", value: StdType.resolveEnum},
			{name: "typeof", value: StdType.typeof},
		], []);
		initFields(builtins, tp(["haxe", "zip"], "Uncompress"), [{name: "run", value: StdUncompress.run},], [
			{name: "close", value: StdUncompress.close},
			{name: "execute", value: StdUncompress.execute},
			{name: "setFlushMode", value: StdUncompress.setFlushMode},
		]);
		initFields(builtins, tp(["haxe"], "Utf8"), [
			{name: "charCodeAt", value: StdUtf8.charCodeAt},
			{name: "compare", value: StdUtf8.compare},
			{name: "decode", value: StdUtf8.decode},
			{name: "encode", value: StdUtf8.encode},
			{name: "iter", value: StdUtf8.iter},
			{name: "length", value: StdUtf8.length},
			{name: "sub", value: StdUtf8.sub},
			{name: "validate", value: StdUtf8.validate},
		], [
			{name: "addChar", value: StdUtf8.addChar},
			{name: "toString", value: StdUtf8.toString},
		]);
		initFields(builtins, tp(["eval", "_NativeString"], "NativeString_Impl_"), [
			{name: "fromBytes", value: StdNativeString.fromBytes},
			{name: "fromString", value: StdNativeString.fromString},
			{name: "toBytes", value: StdNativeString.toBytes},
			{name: "toString", value: StdNativeString.toString},
			{name: "concat", value: StdNativeString.concat},
			{name: "char", value: StdNativeString.char},
			{name: "code", value: StdNativeString.code},
			{name: "get_length", value: StdNativeString.getLength},
			{name: "sub", value: StdNativeString.sub},
		], []);
		initFields(builtins, tp(["eval", "integers", "_UInt64"], "UInt64_Impl_"), EvalIntegers.uint64Fields, []);
		initFields(builtins, tp(["eval", "integers", "_Int64"], "Int64_Impl_"), EvalIntegers.int64Fields, []);
		initFields(builtins, tp(["eval", "luv", "_UVError"], "UVError_Impl_"), EvalLuv.fields(EvalLuv.uvErrorFields), []);
		initFields(builtins, tp(["eval", "luv", "_Loop"], "Loop_Impl_"), EvalLuv.fields(EvalLuv.loopFields), []);
		initFields(builtins, tp(["eval", "luv", "_Loop"], "LoopOption_Impl_"), EvalLuv.fields(EvalLuv.loopOptionFields), []);
		initFields(builtins, tp(["eval", "luv", "_Handle"], "Handle_Impl_"), EvalLuv.fields(EvalLuv.handleFields), []);
		initFields(builtins, tp(["eval", "luv", "_Idle"], "Idle_Impl_"), EvalLuv.fields(EvalLuv.idleFields), []);
		initFields(builtins, tp(["eval", "luv", "_Async"], "Async_Impl_"), EvalLuv.fields(EvalLuv.asyncFields), []);
		initFields(builtins, tp(["eval", "luv", "_Timer"], "Timer_Impl_"), EvalLuv.fields(EvalLuv.timerFields), []);
		initFields(builtins, tp(["eval", "luv", "_Buffer"], "Buffer_Impl_"), EvalLuv.fields(EvalLuv.bufferFields), []);
		initFields(builtins, tp(["eval", "luv", "_SockAddr"], "SockAddr_Impl_"), EvalLuv.fields(EvalLuv.sockaddrFields), []);
		initFields(builtins, tp(["eval", "luv", "_Tcp"], "Tcp_Impl_"), volatileFields("eval.luv.Tcp", EvalLuv.fields(EvalLuv.tcpFields)), []);
		initFields(builtins, tp(["eval", "luv", "_Udp"], "Udp_Impl_"), volatileFields("eval.luv.Udp", EvalLuv.fields(EvalLuv.udpFields)), []);
		initFields(builtins, tp(["eval", "luv", "_ConnectedUdp"], "ConnectedUdp_Impl_"), volatileFields("eval.luv.Udp", EvalLuv.fields(EvalLuv.connectedUdpFields)), []);
		initFields(builtins, tp(["eval", "luv", "_Pipe"], "Pipe_Impl_"), volatileFields("eval.luv.Pipe", EvalLuv.fields(EvalLuv.pipeFields)), []);
		initFields(builtins, tp(["eval", "luv", "_Tty"], "Tty_Impl_"), EvalLuv.fields(EvalLuv.ttyFields), []);
		initFields(builtins, tp(["eval", "luv", "_Stream"], "Stream_Impl_"), EvalLuv.fields(EvalLuv.streamFields), []);
		initFields(builtins, tp(["eval", "luv", "_Signal"], "Signal_Impl_"), volatileFields("eval.luv.Signal", EvalLuv.fields(EvalLuv.signalFields)), []);
		initFields(builtins, tp(["eval", "luv", "_Signal"], "SigNum_Impl_"), EvalLuv.fields(EvalLuv.signumFields), []);
		initFields(builtins, tp(["eval", "luv", "_Process"], "Process_Impl_"), volatileFields("eval.luv.Process", EvalLuv.fields(EvalLuv.processFields)), []);
		initFields(builtins, tp(["eval", "luv", "_Request"], "Request_Impl_"), EvalLuv.fields(EvalLuv.requestFields), []);
		initFields(builtins, tp(["eval", "luv"], "Dns"), volatileFields("eval.luv.Dns", EvalLuv.fields(EvalLuv.dnsFields)), []);
		initFields(builtins, tp(["eval", "luv", "_File"], "File_Impl_"), volatileFields("eval.luv.File", EvalLuv.fields(EvalLuv.fileFields)), []);
		initFields(builtins, tp(["eval", "luv", "_Dir"], "Dir_Impl_"), volatileFields("eval.luv.Dir", EvalLuv.fields(EvalLuv.dirFields)), []);
		initFields(builtins, tp(["eval", "luv"], "FileSync"), volatileFields("eval.luv.File", EvalLuv.fields(EvalLuv.fileSyncFields)), []);
		initFields(builtins, tp(["eval", "luv"], "DirSync"), volatileFields("eval.luv.Dir", EvalLuv.fields(EvalLuv.dirSyncFields)), []);
		initFields(builtins, tp(["eval", "luv", "_FsEvent"], "FsEvent_Impl_"), volatileFields("eval.luv.FsEvent", EvalLuv.fields(EvalLuv.fsEventFields)), []);
		initFields(builtins, tp(["eval", "luv"], "ThreadPool"), EvalLuv.fields(EvalLuv.threadPoolFields), []);
		initFields(builtins, tp(["eval", "luv", "_Thread"], "Thread_Impl_"), EvalLuv.threadFields, []);
		initFields(builtins, tp(["eval", "luv", "_Once"], "Once_Impl_"), EvalLuv.onceFields, []);
		initFields(builtins, tp(["eval", "luv", "_Mutex"], "Mutex_Impl_"), EvalLuv.mutexFields, []);
		initFields(builtins, tp(["eval", "luv", "_RwLock"], "RwLock_Impl_"), EvalLuv.rwlockFields, []);
		initFields(builtins, tp(["eval", "luv", "_Semaphore"], "Semaphore_Impl_"), EvalLuv.semaphoreFields, []);
		initFields(builtins, tp(["eval", "luv", "_Condition"], "Condition_Impl_"), EvalLuv.conditionFields, []);
		initFields(builtins, tp(["eval", "luv", "_Barrier"], "Barrier_Impl_"), EvalLuv.barrierFields, []);
		initFields(builtins, tp(["eval", "luv"], "Env"), luvEnv(EvalLuv.fields(EvalLuv.envFields)), []);
		initFields(builtins, tp(["eval", "luv"], "Time"), volatileFields("eval.luv.Time", EvalLuv.fields(EvalLuv.timeFields)), []);
		initFields(builtins, tp(["eval", "luv"], "Path"), EvalLuv.fields(EvalLuv.pathFields), []);
		initFields(builtins, tp(["eval", "luv"], "Random"), volatileFields("eval.luv.Random", EvalLuv.fields(EvalLuv.randomFields)), []);
		initFields(builtins, tp(["eval", "luv"], "RandomSync"), volatileFields("eval.luv.Random", EvalLuv.fields(EvalLuv.randomSyncFields)), []);
		initFields(builtins, tp(["eval", "luv"], "Network"), volatileFields("eval.luv.Network", EvalLuv.fields(EvalLuv.networkFields)), []);
		initFields(builtins, tp(["eval", "luv", "_FsPoll"], "FsPoll_Impl_"), volatileFields("eval.luv.FsPoll", EvalLuv.fields(EvalLuv.fsPollFields)), []);
		initFields(builtins, tp(["eval", "luv"], "Resource"), volatileFields("eval.luv.Resource", EvalLuv.fields(EvalLuv.resourceFields)), []);
		initFields(builtins, tp(["eval", "luv"], "SystemInfo"), volatileFields("eval.luv.SystemInfo", EvalLuv.fields(EvalLuv.systemInfoFields)), []);
		initFields(builtins, tp(["eval", "luv"], "Pid"), volatileFields("eval.luv.Pid", EvalLuv.fields(EvalLuv.pidFields)), []);
		initFields(builtins, tp(["eval", "luv"], "Passwd"), EvalLuv.fields(EvalLuv.passwdFields), []);
		initFields(builtins, tp(["eval", "luv"], "Metrics"), volatileFields("eval.luv.Metrics", EvalLuv.fields(EvalLuv.metricsFields)), []);
		initFields(builtins, tp(["eval", "luv", "_Prepare"], "Prepare_Impl_"), EvalLuv.fields(EvalLuv.prepareFields), []);
		initFields(builtins, tp(["eval", "luv", "_Check"], "Check_Impl_"), EvalLuv.fields(EvalLuv.checkFields), []);
		initFields(builtins, tp(["eval", "luv"], "Version"), EvalLuv.fields(EvalLuv.versionFields), []);
		EvalSsl.initFields((path, statics, instance) -> initFields(builtins, tp(path.pack, path.name), statics, instance));
		initFields(builtins, tp(["haxe", "atomic", "_AtomicBool"], "AtomicBool_Impl_"), EvalAtomic.atomicBoolFields, []);
		initFields(builtins, tp(["haxe", "atomic", "_AtomicInt"], "AtomicInt_Impl_"), EvalAtomic.atomicIntFields, []);
		initFields(builtins, tp(["haxe", "atomic", "_AtomicObject"], "AtomicObject_Impl_"), EvalAtomic.atomicObjectFields, []);
	}
}
