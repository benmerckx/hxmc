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

import haxe.io.Bytes;

// port: `hash` is OCaml's `Hashtbl.hash` on the
// string's UTF-8 bytes (caml_hash: MurmurHash3 mixing, then masked to 30 bits),
// so hashed names, and every ordering derived from them (object field order,
// `Reflect.fields`), match the reference compiler.
class EvalHash {
	static final reverseMap:Map<Int, String> = new Map();

	public static function revHash(i:Int):String {
		var s = reverseMap.get(i);
		if (s == null) throw core.ds.NotFound.raise();
		return s;
	}

	// port: the names hashed before (Hashtbl.hash on each call is C upstream;
	// here a lookup is cheaper than the UTF-8 copy). Upstream registers a hash in
	// the reverse table once per domain (its `registered` set and `recent` cache):
	// the first name hashed to it stays there (one domain here).
	static final hashCache:Map<String, Int> = new Map();

	public static function hash(f:String):Int {
		var c = hashCache.get(f);
		if (c != null) return c;
		var i = camlHashString(f);
		if (!reverseMap.exists(i)) reverseMap.set(i, f);
		hashCache.set(f, i);
		return i;
	}

	public static function pathHash(path:core.Globals.GlobalTypePath):Int return hash(core.Globals.sTypePath(path));

	// port: 32-bit multiplication on every target (JS numbers lose the low bits)
	static inline function mul32(a:Int, b:Int):Int return ((a & 0xFFFF) * b + ((((a >>> 16) * b) & 0xFFFF) << 16)) | 0;

	static inline function rotl32(x:Int, n:Int):Int return (x << n) | (x >>> (32 - n));

	static inline function mix(h:Int, d:Int):Int {
		d = mul32(d, 0xcc9e2d51);
		d = rotl32(d, 15);
		d = mul32(d, 0x1b873593);
		h ^= d;
		h = rotl32(h, 13);
		return (mul32(h, 5) + 0xe6546b64) | 0;
	}

	public static function camlHashString(s:String):Int {
		var b = Bytes.ofString(s);
		var len = b.length;
		var h = 0;
		var i = 0;
		while (i + 4 <= len) {
			h = mix(h, b.get(i) | (b.get(i + 1) << 8) | (b.get(i + 2) << 16) | (b.get(i + 3) << 24));
			i += 4;
		}
		var w = 0;
		switch (len & 3) {
			case 3:
				w = (b.get(i + 2) << 16) | (b.get(i + 1) << 8) | b.get(i);
				h = mix(h, w);
			case 2:
				w = (b.get(i + 1) << 8) | b.get(i);
				h = mix(h, w);
			case 1:
				w = b.get(i);
				h = mix(h, w);
			case _:
		}
		h ^= len;
		// port: FINAL_MIX of the OCaml runtime's hash.c
		h ^= h >>> 16;
		h = mul32(h, 0x85ebca6b);
		h ^= h >>> 13;
		h = mul32(h, 0xc2b2ae35);
		h ^= h >>> 16;
		return h & 0x3FFFFFFF;
	}

	public static final key_length = hash("length");
	public static final key_toString = hash("toString");
	public static final key_OutsideBounds = hash("OutsideBounds");
	public static final key_low = hash("low");
	public static final key_high = hash("high");
	public static final key_next = hash("next");
	public static final key_hasNext = hash("hasNext");
	public static final key___meta__ = hash("__meta__");
	public static final key_get = hash("get");
	public static final key_pos = hash("pos");
	public static final key_min = hash("min");
	public static final key_max = hash("max");
	public static final key_file = hash("file");
	public static final key_len = hash("len");
	public static final key_message = hash("message");
	public static final key_name = hash("name");
	public static final key_error = hash("error");
	public static final key_exception_message = hash("__exceptionMessage");
	public static final key_native_exception = hash("__nativeException");
	public static final key_native_stack = hash("__nativeStack");
	public static final key_custom_stack = hash("__customStack");
	public static final key_Array = hash("Array");
	public static final key_eval_Vector = hash("eval.Vector");
	public static final key_String = hash("String");
	public static final key_haxe_Exception = hash("haxe.Exception");
	public static final key_haxe_ds_Option = hash("haxe.ds.Option");
	public static final key_haxe_ds_StringMap = hash("haxe.ds.StringMap");
	public static final key_haxe_ds_IntMap = hash("haxe.ds.IntMap");
	public static final key_haxe_ds_Int64Map = hash("haxe.ds.Int64Map");
	public static final key_haxe_ds_ObjectMap = hash("haxe.ds.ObjectMap");
	public static final key_haxe_macro_Position = hash("haxe.macro.Position");
	public static final key_haxe_macro_LazyType = hash("haxe.macro.LazyType");
	public static final key_haxe_macro_TypeDecl = hash("haxe.macro.TypeDecl");
	public static final key_haxe_Utf8 = hash("haxe.Utf8");
	public static final key_haxe_macro_Ref = hash("haxe.macro.Ref");
	public static final key_haxe_io_Error = hash("haxe.io.Error");
	public static final key_haxe_io_Bytes = hash("haxe.io.Bytes");
	public static final key_Date = hash("Date");
	public static final key_Dynamic = hash("Dynamic");
	public static final key_ValueType = hash("ValueType");
	public static final key_EReg = hash("EReg");
	public static final key_haxe_io_BytesBuffer = hash("haxe.io.BytesBuffer");
	public static final key_StringBuf = hash("StringBuf");
	public static final key_haxe_macro_Error = hash("haxe.macro.Error");
	public static final key_Int = hash("Int");
	public static final key_Float = hash("Float");
	public static final key_Bool = hash("Bool");
	public static final key_Class = hash("Class");
	public static final key_Enum = hash("Enum");
	public static final key_EnumValue = hash("EnumValue");
	public static final key_gid = hash("gid");
	public static final key_uid = hash("uid");
	public static final key_atime = hash("atime");
	public static final key_mtime = hash("mtime");
	public static final key_ctime = hash("ctime");
	public static final key_dev = hash("dev");
	public static final key_ino = hash("ino");
	public static final key_nlink = hash("nlink");
	public static final key_rdev = hash("rdev");
	public static final key_size = hash("size");
	public static final key_mode = hash("mode");
	public static final key_haxe__Int64____Int64 = hash("haxe._Int64.___Int64");
	public static final key_haxe_macro_Unsafe = hash("haxe.macro.Unsafe");
	public static final key_sys_io__Process_NativeProcess = hash("sys.io._Process.NativeProcess");
	public static final key_sys_io_FileOutput = hash("sys.io.FileOutput");
	public static final key_sys_io_FileInput = hash("sys.io.FileInput");
	public static final key_haxe_io_Eof = hash("haxe.io.Eof");
	public static final key_haxe_macro_ExprDef = hash("haxe.macro.ExprDef");
	public static final key_haxe_macro_EFieldKind = hash("haxe.macro.EFieldKind");
	public static final key_haxe_macro_Binop = hash("haxe.macro.Binop");
	public static final key_haxe_macro_Unop = hash("haxe.macro.Unop");
	public static final key_haxe_macro_Constant = hash("haxe.macro.Constant");
	public static final key_haxe_macro_TypeParam = hash("haxe.macro.TypeParam");
	public static final key_haxe_macro_ComplexType = hash("haxe.macro.ComplexType");
	public static final key_haxe_macro_FieldType = hash("haxe.macro.FieldType");
	public static final key_haxe_macro_Type = hash("haxe.macro.Type");
	public static final key_haxe_macro_FieldKind = hash("haxe.macro.FieldKind");
	public static final key_haxe_macro_MethodKind = hash("haxe.macro.MethodKind");
	public static final key_haxe_macro_VarAccess = hash("haxe.macro.VarAccess");
	public static final key_haxe_macro_Access = hash("haxe.macro.Access");
	public static final key_haxe_macro_ClassKind = hash("haxe.macro.ClassKind");
	public static final key_haxe_macro_TypedExprDef = hash("haxe.macro.TypedExprDef");
	public static final key_haxe_macro_TConstant = hash("haxe.macro.TConstant");
	public static final key_haxe_macro_ModuleType = hash("haxe.macro.ModuleType");
	public static final key_haxe_macro_FieldAccess = hash("haxe.macro.FieldAccess");
	public static final key_haxe_macro_AnonStatus = hash("haxe.macro.AnonStatus");
	public static final key_haxe_macro_ImportMode = hash("haxe.macro.ImportMode");
	public static final key_haxe_macro_QuoteStatus = hash("haxe.macro.QuoteStatus");
	public static final key_haxe_macro_DisplayKind = hash("haxe.macro.DisplayKind");
	public static final key_haxe_macro_DisplayMode = hash("haxe.macro.DisplayMode");
	public static final key_haxe_macro_CapturePolicy = hash("haxe.macro.CapturePolicy");
	public static final key_haxe_macro_VarScope = hash("haxe.macro.VarScope");
	public static final key_haxe_macro_VarScopingFlags = hash("haxe.macro.VarScopingFlags");
	public static final key_haxe_macro_Platform = hash("haxe.macro.Platform");
	public static final key_haxe_macro_PackageRule = hash("haxe.macro.PackageRule");
	public static final key_haxe_macro_Message = hash("haxe.macro.Message");
	public static final key_haxe_macro_FunctionKind = hash("haxe.macro.FunctionKind");
	public static final key_haxe_macro_StringLiteralKind = hash("haxe.macro.StringLiteralKind");
	public static final key___init__ = hash("__init__");
	public static final key_new = hash("new");
	public static final key_questionmark = hash("?");
	public static final key_haxe_StackItem = hash("haxe.StackItem");
	public static final key_eval_vm_NativeSocket = hash("eval.vm.NativeSocket");
	public static final key_ip = hash("ip");
	public static final key_port = hash("port");
	public static final key_sys_net_Socket = hash("sys.net.Socket");
	public static final key_socket = hash("socket");
	public static final key_read = hash("read");
	public static final key_write = hash("write");
	public static final key_others = hash("others");
	public static final key_eval_vm_Thread = hash("eval.vm.NativeThread");
	public static final key_eval_vm_NativeThreadExit = hash("eval.vm.NativeThreadExit");
	public static final key_haxe_zip_Compress = hash("haxe.zip.Compress");
	public static final key_haxe_zip_Uncompress = hash("haxe.zip.Uncompress");
	public static final key_done = hash("done");
	public static final key_eval_toplevel = hash("eval-toplevel");
	public static final key_haxe_iterators_array_key_value_iterator = hash("haxe.iterators.ArrayKeyValueIterator");
	public static final key_haxe_iterators_map_key_value_iterator = hash("haxe.iterators.MapKeyValueIterator");
	public static final key_sys_net_Mutex = hash("sys.thread.Mutex");
	public static final key_sys_net_Semaphore = hash("sys.thread.Semaphore");
	public static final key_sys_net_Condition = hash("sys.thread.Condition");
	public static final key_sys_net_Lock = hash("sys.thread.Lock");
	public static final key_sys_net_Tls = hash("sys.thread.Tls");
	public static final key_sys_net_Deque = hash("sys.thread.Deque");
	public static final key_sys_thread_EventLoop = hash("sys.thread.EventLoop");
	public static final key_mbedtls_Config = hash("mbedtls.Config");
	public static final key_mbedtls_CtrDrbg = hash("mbedtls.CtrDrbg");
	public static final key_mbedtls_Entropy = hash("mbedtls.Entropy");
	public static final key_mbedtls_PkContext = hash("mbedtls.PkContext");
	public static final key_mbedtls_Ssl = hash("mbedtls.Ssl");
	public static final key_mbedtls_X509Crt = hash("mbedtls.X509Crt");
	public static final key_eval_luv_Result = hash("eval.luv.Result");
	public static final key_eval_luv_LuvException = hash("eval.luv.LuvException");
	public static final key_eval_luv_ReceiveHandle = hash("eval.luv.ReceiveHandle");
	public static final key_eval_luv_AddressFamily = hash("eval.luv.AddressFamily");
	public static final key_eval_luv_SocketType = hash("eval.luv.SocketType");
	public static final key_onExit = hash("onExit");
	public static final key_environment = hash("environment");
	public static final key_redirect = hash("redirect");
	public static final key_workingDirectory = hash("workingDirectory");
	public static final key_windowsVerbatimArguments = hash("windowsVerbatimArguments");
	public static final key_detached = hash("detached");
	public static final key_windowsHide = hash("windowsHide");
	public static final key_windowsHideConsole = hash("windowsHideConsole");
	public static final key_windowsHideGui = hash("windowsHideGui");
	public static final key_request = hash("request");
	public static final key_family = hash("family");
	public static final key_sockType = hash("sockType");
	public static final key_protocol = hash("protocol");
	public static final key_flags = hash("flags");
	public static final key_addr = hash("addr");
	public static final key_data = hash("data");
	public static final key_canonName = hash("canonName");
	public static final key_node = hash("node");
	public static final key_service = hash("service");
	public static final key_sec = hash("sec");
	public static final key_nsec = hash("nsec");
	public static final key_usec = hash("usec");
	public static final key_blksize = hash("blksize");
	public static final key_blocks = hash("blocks");
	public static final key_gen = hash("gen");
	public static final key_atim = hash("atim");
	public static final key_mtim = hash("mtim");
	public static final key_ctim = hash("ctim");
	public static final key_birthtim = hash("birthtim");
	public static final key_width = hash("width");
	public static final key_height = hash("height");
	public static final key_type = hash("type");
	public static final key_bsize = hash("bsize");
	public static final key_bfree = hash("bfree");
	public static final key_bavail = hash("bavail");
	public static final key_files = hash("files");
	public static final key_ffree = hash("ffree");
	public static final key_fspare = hash("fspare");
	public static final key_kind = hash("kind");
	public static final key_end = hash("end");
	public static final key_events = hash("events");
	public static final key_child_errors = hash("childErrors");
	public static final key_isInternal = hash("isInternal");
	public static final key_physical = hash("physical");
	public static final key_address = hash("address");
	public static final key_netmask = hash("netmask");
	public static final key_previous = hash("previous");
	public static final key_current = hash("current");
	public static final key_haxe_atomic_AtomicBool = hash("haxe.atomic.AtomicBool");
	public static final key_haxe_atomic_AtomicInt = hash("haxe.atomic.AtomicInt");
	public static final key_haxe_atomic_AtomicObject = hash("haxe.atomic.AtomicObject");
	public static final key_eval_integers_Int64 = hash("eval.integers._Int64.Int64_Impl_"); // TODO: wonky...
}
