package hxmc.neko;

import haxe.io.Bytes;
import hxmc.neko.Prims.Register;
import hxmc.neko.Value;

using hxmc.neko.Builtins.Check;

class NFile {
	public var name:String;
	public var input:Null<haxe.io.Input>;
	public var output:Null<haxe.io.Output>;
	public var eof = false;
	public var std = false;

	public function new(name, input, output) {
		this.name = name;
		this.input = input;
		this.output = output;
	}
}

// a growable byte buffer (neko's buffer)
class NBuf {
	public var b:Bytes;
	public var len = 0;

	public function new()
		b = Bytes.alloc(64);

	public function reserve(n:Int) {
		if (len + n <= b.length) return;
		var size = b.length * 2;
		while (size < len + n)
			size *= 2;
		var nb = Bytes.alloc(size);
		nb.blit(0, b, 0, len);
		b = nb;
	}

	public function addBytes(s:Bytes, p:Int, l:Int) {
		reserve(l);
		b.blit(len, s, p, l);
		len += l;
	}

	public inline function add(s:Bytes)
		addBytes(s, 0, s.length);

	public function addByte(c:Int) {
		reserve(1);
		b.set(len++, c);
	}

	public function bytes():Bytes
		return b.sub(0, len);
}

class NThread {
	public static final tls = new sys.thread.Tls<NThread>();
	static var main:NThread;

	public final messages = new sys.thread.Deque<Dynamic>();
	public final handle:NAbs;

	public function new()
		handle = new NAbs("thread", this);

	public static function current():NThread {
		var t = tls.value;
		if (t == null) {
			t = new NThread();
			tls.value = t;
		}
		return t;
	}
}

class NCond {
	public final mutex = new sys.thread.Mutex();
	public final cond = new sys.thread.Condition();

	public function new() {}
}

// libs/std: the primitives of std.ndll
class StdPrims {
	public static var programPath:Null<String>;

	static inline function str(s:String):NStr
		return NStr.of(s);

	// a list [v, next] of the values (neko's sys_read_dir, string_split)
	static function list(a:Array<Dynamic>):Dynamic {
		var l:Dynamic = null;
		var i = a.length;
		while (i-- > 0) {
			var cell:Array<Dynamic> = [a[i], l];
			l = cell;
		}
		return l;
	}

	static function fileError(msg:String, f:String):NekoError {
		var a:Array<Dynamic> = [str(msg), str(f)];
		return new NekoError(a);
	}

	static function file(v:Dynamic):NFile
		return v.abs("file");

	public static function register(add:Register) {
		var r = (n, k, f) -> add("std@" + n, k, f);
		buffer(r);
		math(r);
		strings(r);
		misc(r);
		files(r);
		system(r);
		process(r);
		threads(r);
		dates(r);
		int32(r);
		random(r);
		utf8(r);
		modules(r);
	}

	static function buffer(add:Register) {
		inline function buf(v:Dynamic):NBuf
			return v.abs("buffer");
		add("buffer_new", 0, (vm, a) -> new NAbs("buffer", new NBuf()));
		add("buffer_add", 2, (vm, a) -> {
			buf(a[0]).add(vm.toBytes(a[1]));
			return null;
		});
		add("buffer_add_char", 2, (vm, a) -> {
			var c = a[1].int();
			if (c < 0 || c > 255) throw Builtins.failure;
			buf(a[0]).addByte(c);
			return null;
		});
		add("buffer_add_sub", 4, (vm, a) -> {
			var b = buf(a[0]), s = a[1].str().b, p = a[2].int(), l = a[3].int();
			if (p < 0 || l < 0 || p + l > s.length) throw Builtins.failure;
			b.addBytes(s, p, l);
			return null;
		});
		add("buffer_string", 1, (vm, a) -> new NStr(buf(a[0]).bytes()));
		add("buffer_reset", 1, (vm, a) -> {
			var b = buf(a[0]);
			b.len = 0;
			return null;
		});
		add("buffer_get_length", 1, (vm, a) -> buf(a[0]).len);
	}

	static function math(add:Register) {
		function f1(name:String, f:Float->Float)
			add(name, 1, (vm, a) -> (f(a[0].number()) : Float));
		f1("math_sqrt", Math.sqrt);
		f1("math_atan", Math.atan);
		f1("math_cos", Math.cos);
		f1("math_sin", Math.sin);
		f1("math_tan", Math.tan);
		f1("math_log", Math.log);
		f1("math_exp", Math.exp);
		f1("math_acos", Math.acos);
		f1("math_asin", Math.asin);
		add("math_pi", 0, (vm, a) -> Math.PI);
		add("math_atan2", 2, (vm, a) -> Math.atan2(a[0].number(), a[1].number()));
		add("math_pow", 2, (vm, a) -> Math.pow(a[0].number(), a[1].number()));
		add("math_abs", 1, (vm, a) -> {
			if (Tag.isInt(a[0])) {
				var i:Int = a[0];
				return (i < 0 ? -i : i : Dynamic);
			}
			return Math.abs(a[0].float());
		});
		inline function toInt(f:Float):Dynamic
			return Builtins.toInt(f);
		add("math_ceil", 1, (vm, a) -> Tag.isInt(a[0]) ? a[0] : toInt(Math.fceil(a[0].float())));
		add("math_floor", 1, (vm, a) -> Tag.isInt(a[0]) ? a[0] : toInt(Math.ffloor(a[0].float())));
		add("math_round", 1, (vm, a) -> Tag.isInt(a[0]) ? a[0] : toInt(Math.ffloor(a[0].float() + 0.5)));
		add("math_int", 1, (vm, a) -> {
			if (Tag.isInt(a[0])) return a[0];
			var f = a[0].float();
			return toInt(f < 0 ? Math.fceil(f) : Math.ffloor(f));
		});
		add("math_fceil", 1, (vm, a) -> Math.fceil(a[0].number()));
		add("math_ffloor", 1, (vm, a) -> Math.ffloor(a[0].number()));
		add("math_fround", 1, (vm, a) -> Math.ffloor(a[0].number() + 0.5));
	}

	static function strings(add:Register) {
		add("string_split", 2, (vm, a) -> {
			var o = a[0].str().b, s = a[1].str().b;
			var ilen = o.length, slen = s.length;
			var out:Array<Dynamic> = [];
			var start = 0;
			var pos = slen == 0 ? 1 : 0;
			while (pos <= ilen - slen) {
				var ok = true;
				for (i in 0...slen)
					if (o.get(pos + i) != s.get(i)) {
						ok = false;
						break;
					}
				if (ok) {
					out.push(new NStr(o.sub(start, pos - start)));
					start = pos + slen;
					if (slen > 0) pos = start - 1;
				}
				pos++;
			}
			if (ilen > 0 && slen > 0) out.push(start > 0 ? new NStr(o.sub(start, ilen - start)) : a[0]);
			return list(out);
		});
		add("url_encode", 1, (vm, a) -> {
			var s = a[0].str().b;
			var b = new NBuf();
			for (i in 0...s.length) {
				var c = s.get(i);
				if ((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "-".code || c == ".".code
					|| c == "_".code)
					b.addByte(c)
				else {
					b.addByte("%".code);
					b.add(Bytes.ofString(StringTools.hex(c, 2)));
				}
			}
			return new NStr(b.bytes());
		});
		add("url_decode", 1, (vm, a) -> {
			var s = a[0].str().b;
			var b = new NBuf();
			var i = 0;
			inline function hex(c:Int):Int
				return c >= "0".code && c <= "9".code ? c - "0".code : (c >= "a".code && c <= "f".code ? c - "a".code + 10 : (c >= "A".code
					&& c <= "F".code ? c - "A".code + 10 : -1));
			while (i < s.length) {
				var c = s.get(i++);
				if (c == "+".code) b.addByte(" ".code) else if (c == "%".code && i + 1 < s.length + 0) {
					var h1 = hex(s.get(i)), h2 = i + 1 < s.length ? hex(s.get(i + 1)) : -1;
					if (h1 < 0 || h2 < 0) b.addByte(c) else {
						b.addByte((h1 << 4) | h2);
						i += 2;
					}
				} else
					b.addByte(c);
			}
			return new NStr(b.bytes());
		});
		add("base_encode", 2, (vm, a) -> {
			var s = a[0].str().b, base = a[1].str().b;
			var len = base.length;
			var nbits = 1;
			while (len > 1 << nbits)
				nbits++;
			if (nbits > 8 || len != 1 << nbits) throw Builtins.failure;
			var size = Std.int((s.length * 8 + nbits - 1) / nbits);
			var out = Bytes.alloc(size);
			var buf = 0, curbits = 0, mask = (1 << nbits) - 1, p = 0;
			for (i in 0...size) {
				while (curbits < nbits) {
					curbits += 8;
					buf <<= 8;
					buf |= p < s.length ? s.get(p) : 0;
					p++;
				}
				curbits -= nbits;
				out.set(i, base.get((buf >> curbits) & mask));
			}
			return new NStr(out);
		});
		add("base_decode", 2, (vm, a) -> {
			var s = a[0].str().b, base = a[1].str().b;
			var len = base.length;
			var nbits = 1;
			while (len > 1 << nbits)
				nbits++;
			if (nbits > 8 || len != 1 << nbits) throw Builtins.failure;
			var tbl = [for (_ in 0...256) -1];
			for (i in 0...len)
				tbl[base.get(i)] = i;
			var size = Std.int((s.length * nbits) / 8);
			var out = Bytes.alloc(size);
			var buf = 0, curbits = 0, p = 0;
			for (i in 0...size) {
				while (curbits < 8) {
					curbits += nbits;
					buf <<= nbits;
					var c = tbl[s.get(p++)];
					if (c == -1) throw Builtins.failure;
					buf |= c;
				}
				curbits -= 8;
				out.set(i, (buf >> curbits) & 0xFF);
			}
			return new NStr(out);
		});
		add("make_md5", 1, (vm, a) -> new NStr(haxe.crypto.Md5.make(a[0].str().b)));
		add("make_sha1", 3, (vm, a) -> {
			var s = a[0].str().b, p = a[1].int(), l = a[2].int();
			if (p < 0 || l < 0 || p + l > s.length) throw Builtins.failure;
			return new NStr(haxe.crypto.Sha1.make(s.sub(p, l)));
		});
	}

	static function misc(add:Register) {
		add("float_bytes", 2, (vm, a) -> {
			var b = Bytes.alloc(4);
			var v = haxe.io.FPHelper.floatToI32(a[0].number());
			if (a[1] == true) b.setInt32(0, swap(v)) else b.setInt32(0, v);
			return new NStr(b);
		});
		add("double_bytes", 2, (vm, a) -> {
			var b = Bytes.alloc(8);
			b.setDouble(0, a[0].number());
			if (a[1] == true) reverse(b);
			return new NStr(b);
		});
		add("float_of_bytes", 2, (vm, a) -> {
			var s = a[0].str().b;
			if (s.length != 4) throw Builtins.failure;
			var v = s.getInt32(0);
			return (haxe.io.FPHelper.i32ToFloat(a[1] == true ? swap(v) : v) : Float);
		});
		add("double_of_bytes", 2, (vm, a) -> {
			var s = a[0].str().b;
			if (s.length != 8) throw Builtins.failure;
			var b = s.sub(0, 8);
			if (a[1] == true) reverse(b);
			return b.getDouble(0);
		});
		add("run_gc", 1, (vm, a) -> null);
		add("gc_stats", 0, (vm, a) -> {
			var o = new NObj();
			o.set(Fields.id("heap"), 0);
			o.set(Fields.id("free"), 0);
			return o;
		});
		add("enable_jit", 1, (vm, a) -> a[0] == null ? false : null);
		add("test", 0, (vm, a) -> null);
		add("print_redirect", 1, (vm, a) -> {
			if (a[0] == null) vm.print = b -> {
				var o = Sys.stdout();
				o.writeBytes(b, 0, b.length);
				o.flush();
			} else {
				var f = a[0].fun();
				vm.print = b -> vm.callN(f, [new NStr(b)]);
			}
			return null;
		});
		add("set_trusted", 1, (vm, a) -> null);
		add("same_closure", 2, (vm, a) -> {
			var f1 = a[0], f2 = a[1];
			if (!Tag.isFunction(f1) || !Tag.isFunction(f2)) return false;
			var x:NFun = f1, y:NFun = f2;
			if (x == y) return true;
			if (x.nargs != y.nargs || x.module != y.module || x.addr != y.addr || x.prim != y.prim) {
				// closures of $closure: the same function on the same object
				if (x.name == "closure_callback" && y.name == "closure_callback") {
					var e1:Array<Dynamic> = x.env, e2:Array<Dynamic> = y.env;
					if (e1.length != e2.length) return false;
					for (i in 0...e1.length)
						if (!VM.same(e1[i], e2[i])) return false;
					return true;
				}
				return false;
			}
			if (!Tag.isArray(x.env) || !Tag.isArray(y.env)) return VM.same(x.env, y.env);
			var e1:Array<Dynamic> = x.env, e2:Array<Dynamic> = y.env;
			if (e1.length != e2.length) return false;
			for (i in 0...e1.length)
				if (!VM.same(e1[i], e2[i])) return false;
			return true;
		});
		add("merge_sort", 3, (vm, a) -> {
			var arr = a[0].arr(), len = a[1].int(), cmp = a[2].fun();
			var tmp = arr.slice(0, len);
			mergeSort(vm, tmp, cmp);
			for (i in 0...len)
				arr[i] = tmp[i];
			return null;
		});
		add("mem_size", 1, (vm, a) -> 0);
		add("serialize", 1, (vm, a) -> throw VM.error("serialize is not supported"));
		add("unserialize", 2, (vm, a) -> throw VM.error("unserialize is not supported"));
	}

	static function mergeSort(vm:VM, a:Array<Dynamic>, cmp:NFun) {
		if (a.length < 2) return;
		var mid = a.length >> 1;
		var l = a.slice(0, mid), r = a.slice(mid);
		mergeSort(vm, l, cmp);
		mergeSort(vm, r, cmp);
		var i = 0, j = 0, k = 0;
		while (i < l.length && j < r.length) {
			var c:Dynamic = vm.callN(cmp, [l[i], r[j]]);
			if (!Tag.isInt(c)) throw Builtins.failure;
			if ((c : Int) <= 0) a[k++] = l[i++] else a[k++] = r[j++];
		}
		while (i < l.length)
			a[k++] = l[i++];
		while (j < r.length)
			a[k++] = r[j++];
	}

	static inline function swap(v:Int):Int
		return ((v >>> 24) & 0xFF) | ((v >> 8) & 0xFF00) | ((v & 0xFF00) << 8) | (v << 24);

	static function reverse(b:Bytes) {
		for (i in 0...b.length >> 1) {
			var t = b.get(i);
			b.set(i, b.get(b.length - 1 - i));
			b.set(b.length - 1 - i, t);
		}
	}

	static var stdinFile:NFile;
	static var stdoutFile:NFile;
	static var stderrFile:NFile;

	static function files(add:Register) {
		stdinFile = new NFile("stdin", Sys.stdin(), null);
		stdoutFile = new NFile("stdout", null, Sys.stdout());
		stderrFile = new NFile("stderr", null, Sys.stderr());
		stdinFile.std = stdoutFile.std = stderrFile.std = true;
		add("file_stdin", 0, (vm, a) -> new NAbs("file", stdinFile));
		add("file_stdout", 0, (vm, a) -> new NAbs("file", stdoutFile));
		add("file_stderr", 0, (vm, a) -> new NAbs("file", stderrFile));
		add("file_open", 2, (vm, a) -> {
			var name = a[0].str().toString(), mode = a[1].str().toString();
			var binary = mode.indexOf("b") >= 0;
			var f = try {
				if (mode.indexOf("+") >= 0) {
					if (mode.charAt(0) == "r") {
						if (!sys.FileSystem.exists(name)) throw "missing";
						var o = sys.io.File.update(name, binary);
						var i = sys.io.File.read(name, binary);
						new NFile(name, i, o);
					} else {
						var o = mode.charAt(0) == "a" ? sys.io.File.append(name, binary) : sys.io.File.write(name, binary);
						new NFile(name, sys.io.File.read(name, binary), o);
					}
				} else switch mode.charAt(0) {
					case "r":
						if (!sys.FileSystem.exists(name) || sys.FileSystem.isDirectory(name)) throw "missing";
						new NFile(name, sys.io.File.read(name, binary), null);
					case "w":
						new NFile(name, null, sys.io.File.write(name, binary));
					case "a":
						new NFile(name, null, sys.io.File.append(name, binary));
					case _:
						throw "mode";
				}
			} catch (e:Dynamic) throw fileError("file_open", name);
			return new NAbs("file", f);
		});
		add("file_close", 1, (vm, a) -> {
			var f = file(a[0]);
			if (!f.std) {
				if (f.input != null) f.input.close();
				if (f.output != null) f.output.close();
			}
			return null;
		});
		add("file_name", 1, (vm, a) -> str(file(a[0]).name));
		add("file_write", 4, (vm, a) -> {
			var f = file(a[0]), s = a[1].str().b, p = a[2].int(), l = a[3].int();
			if (p < 0 || l < 0 || p + l > s.length) throw Builtins.failure;
			if (f.output == null) throw fileError("file_write", f.name);
			try {
				f.output.writeFullBytes(s, p, l);
				if (f.std) f.output.flush();
			} catch (e:Dynamic) throw fileError("file_write", f.name);
			return l;
		});
		add("file_read", 4, (vm, a) -> {
			var f = file(a[0]), s = a[1].str().b, p = a[2].int(), l = a[3].int();
			if (p < 0 || l < 0 || p + l > s.length) throw Builtins.failure;
			if (f.input == null) throw fileError("file_read", f.name);
			var got = 0;
			while (got < l) {
				var n = try f.input.readBytes(s, p + got, l - got) catch (e:haxe.io.Eof) {
					f.eof = true;
					0;
				} catch (e:Dynamic) 0;
				if (n <= 0) break;
				got += n;
			}
			if (got == 0 && l > 0) throw fileError("file_read", f.name);
			return got;
		});
		add("file_write_char", 2, (vm, a) -> {
			var f = file(a[0]), c = a[1].int();
			if (c < 0 || c > 255) throw Builtins.failure;
			if (f.output == null) throw fileError("file_write_char", f.name);
			f.output.writeByte(c);
			if (f.std) f.output.flush();
			return null;
		});
		add("file_read_char", 1, (vm, a) -> {
			var f = file(a[0]);
			if (f.input == null) throw fileError("file_read_char", f.name);
			return try f.input.readByte() catch (e:Dynamic) {
				f.eof = true;
				throw fileError("file_read_char", f.name);
			}
		});
		add("file_seek", 3, (vm, a) -> {
			var f = file(a[0]), pos = a[1].int(), kind = a[2].int();
			var k:sys.io.FileSeek = switch kind {
				case 0: SeekBegin;
				case 1: SeekCur;
				case 2: SeekEnd;
				case _: throw Builtins.failure;
			}
			try {
				if (Std.isOfType(f.input, sys.io.FileInput)) (cast f.input : sys.io.FileInput).seek(pos, k);
				if (Std.isOfType(f.output, sys.io.FileOutput)) (cast f.output : sys.io.FileOutput).seek(pos, k);
			} catch (e:Dynamic) throw fileError("file_seek", f.name);
			f.eof = false;
			return null;
		});
		add("file_tell", 1, (vm, a) -> {
			var f = file(a[0]);
			if (Std.isOfType(f.input, sys.io.FileInput)) return (cast f.input : sys.io.FileInput).tell();
			if (Std.isOfType(f.output, sys.io.FileOutput)) return (cast f.output : sys.io.FileOutput).tell();
			throw fileError("file_tell", f.name);
		});
		add("file_eof", 1, (vm, a) -> {
			var f = file(a[0]);
			if (f.eof) return true;
			if (Std.isOfType(f.input, sys.io.FileInput)) return (cast f.input : sys.io.FileInput).eof();
			return false;
		});
		add("file_flush", 1, (vm, a) -> {
			var f = file(a[0]);
			if (f.output != null) f.output.flush();
			return null;
		});
		add("file_contents", 1, (vm, a) -> {
			var name = a[0].str().toString();
			return try new NStr(sys.io.File.getBytes(name)) catch (e:Dynamic) throw fileError("file_contents", name);
		});
	}

	static function system(add:Register) {
		add("get_env", 1, (vm, a) -> {
			var v = Sys.getEnv(a[0].str().toString());
			return v == null ? null : str(v);
		});
		add("put_env", 2, (vm, a) -> {
			var k = a[0].str().toString();
			if (a[1] == null) Sys.putEnv(k, null) else Sys.putEnv(k, a[1].str().toString());
			return null;
		});
		add("set_time_locale", 1, (vm, a) -> false);
		add("get_cwd", 0, (vm, a) -> {
			var c = Sys.getCwd();
			if (!StringTools.endsWith(c, "/") && !StringTools.endsWith(c, "\\")) c += "/";
			return str(c);
		});
		add("set_cwd", 1, (vm, a) -> {
			try Sys.setCwd(a[0].str().toString()) catch (e:Dynamic) throw Builtins.failure;
			return true;
		});
		add("sys_sleep", 1, (vm, a) -> {
			Sys.sleep(a[0].number());
			return true;
		});
		add("sys_command", 1, (vm, a) -> {
			var cmd = a[0].str().toString();
			if (cmd.length == 0) return -1;
			Sys.stdout().flush();
			return Sys.command(cmd);
		});
		add("sys_exit", 1, (vm, a) -> {
			Sys.stdout().flush();
			Sys.stderr().flush();
			Sys.exit(a[0].int());
			return true;
		});
		add("sys_string", 0, (vm, a) -> str(Sys.systemName()));
		add("sys_is64", 0, (vm, a) -> true);
		add("sys_cpu_arch", 0, (vm, a) -> str(cpuArch()));
		add("sys_stat", 1, (vm, a) -> {
			var p = a[0].str().toString();
			var s = try sys.FileSystem.stat(p) catch (e:Dynamic) throw Builtins.failure;
			var o = new NObj();
			o.set(Fields.id("gid"), s.gid);
			o.set(Fields.id("uid"), s.uid);
			o.set(Fields.id("atime"), Std.int(s.atime.getTime() / 1000));
			o.set(Fields.id("mtime"), Std.int(s.mtime.getTime() / 1000));
			o.set(Fields.id("ctime"), Std.int(s.ctime.getTime() / 1000));
			o.set(Fields.id("dev"), s.dev);
			o.set(Fields.id("ino"), s.ino);
			o.set(Fields.id("mode"), s.mode);
			o.set(Fields.id("nlink"), s.nlink);
			o.set(Fields.id("rdev"), s.rdev);
			o.set(Fields.id("size"), s.size);
			return o;
		});
		add("sys_time", 0, (vm, a) -> Sys.time());
		add("sys_cpu_time", 0, (vm, a) -> Sys.cpuTime());
		add("sys_thread_cpu_time", 0, (vm, a) -> Sys.cpuTime());
		add("sys_exists", 1, (vm, a) -> sys.FileSystem.exists(a[0].str().toString()));
		add("file_exists", 1, (vm, a) -> sys.FileSystem.exists(a[0].str().toString()));
		add("file_delete", 1, (vm, a) -> {
			var p = a[0].str().toString();
			if (!sys.FileSystem.exists(p) || sys.FileSystem.isDirectory(p)) throw Builtins.failure;
			try sys.FileSystem.deleteFile(p) catch (e:Dynamic) throw Builtins.failure;
			return true;
		});
		add("sys_rename", 2, (vm, a) -> {
			try sys.FileSystem.rename(a[0].str().toString(), a[1].str().toString()) catch (e:Dynamic) throw Builtins.failure;
			return true;
		});
		add("sys_file_type", 1, (vm, a) -> {
			var p = a[0].str().toString();
			if (!sys.FileSystem.exists(p)) throw Builtins.failure;
			return str(sys.FileSystem.isDirectory(p) ? "dir" : "file");
		});
		add("sys_create_dir", 2, (vm, a) -> {
			var p = a[0].str().toString();
			if (sys.FileSystem.exists(p)) throw Builtins.failure;
			try sys.FileSystem.createDirectory(p) catch (e:Dynamic) throw Builtins.failure;
			return true;
		});
		add("sys_remove_dir", 1, (vm, a) -> {
			try sys.FileSystem.deleteDirectory(a[0].str().toString()) catch (e:Dynamic) throw Builtins.failure;
			return true;
		});
		add("sys_read_dir", 1, (vm, a) -> {
			var p = a[0].str().toString();
			var names = try sys.FileSystem.readDirectory(p) catch (e:Dynamic) throw Builtins.failure;
			return list([for (n in names) str(n)]);
		});
		add("file_full_path", 1, (vm, a) -> {
			var p = try sys.FileSystem.fullPath(a[0].str().toString()) catch (e:Dynamic) null;
			if (p == null) throw Builtins.failure;
			return str(p);
		});
		add("sys_exe_path", 0, (vm, a) -> str(Sys.programPath()));
		add("sys_program_path", 0, (vm, a) -> programPath == null ? null : str(programPath));
		add("sys_env", 0, (vm, a) -> {
			var l:Dynamic = null;
			var env = Sys.environment();
			var keys = [for (k in env.keys()) k];
			var i = keys.length;
			while (i-- > 0) {
				var cell:Array<Dynamic> = [str(keys[i]), str(env.get(keys[i])), l];
				l = cell;
			}
			return l;
		});
		add("sys_getch", 1, (vm, a) -> Sys.getChar(a[0].bool()));
		add("sys_get_pid", 0, (vm, a) -> {
			var p = try sys.FileSystem.fullPath("/proc/self") catch (e:Dynamic) null;
			return p == null ? 0 : Std.parseInt(haxe.io.Path.withoutDirectory(p));
		});
	}

	static function cpuArch():String {
		var m = try {
			var p = new sys.io.Process("uname", ["-m"]);
			var s = StringTools.trim(p.stdout.readAll().toString());
			p.close();
			s;
		} catch (e:Dynamic) "x86_64";
		return switch m {
			case "aarch64" | "arm64": "arm64";
			case "x86_64" | "amd64": "x86_64";
			case m: m;
		}
	}

	static function process(add:Register) {
		inline function proc(v:Dynamic):sys.io.Process
			return v.abs("process");
		add("process_run", 2, (vm, a) -> {
			var cmd = a[0].str().toString();
			var args:Array<String> = a[1] == null ? null : [for (x in a[1].arr()) (x : Dynamic).str().toString()];
			var p = try new sys.io.Process(cmd, args) catch (e:Dynamic) throw Builtins.failure;
			return new NAbs("process", p);
		});
		function read(p:haxe.io.Input, a:Array<Dynamic>):Dynamic {
			var s = a[1].str().b, pos = a[2].int(), len = a[3].int();
			if (pos < 0 || len < 0 || pos + len > s.length) throw Builtins.failure;
			var n = try p.readBytes(s, pos, len) catch (e:Dynamic) 0;
			if (n <= 0) throw Builtins.failure;
			return n;
		}
		add("process_stdout_read", 4, (vm, a) -> read(proc(a[0]).stdout, a));
		add("process_stderr_read", 4, (vm, a) -> read(proc(a[0]).stderr, a));
		add("process_stdin_write", 4, (vm, a) -> {
			var p = proc(a[0]), s = a[1].str().b, pos = a[2].int(), len = a[3].int();
			if (pos < 0 || len < 0 || pos + len > s.length) throw Builtins.failure;
			try {
				p.stdin.writeBytes(s, pos, len);
				p.stdin.flush();
			} catch (e:Dynamic) throw Builtins.failure;
			return len;
		});
		add("process_stdin_close", 1, (vm, a) -> {
			try proc(a[0]).stdin.close() catch (e:Dynamic) throw Builtins.failure;
			return null;
		});
		add("process_exit", 1, (vm, a) -> proc(a[0]).exitCode(true));
		add("process_pid", 1, (vm, a) -> proc(a[0]).getPid());
		add("process_close", 1, (vm, a) -> {
			proc(a[0]).close();
			return null;
		});
		add("process_kill", 1, (vm, a) -> {
			proc(a[0]).kill();
			return null;
		});
	}

	static function threads(add:Register) {
		add("thread_create", 2, (vm, a) -> {
			var f = a[0].fun(), p = a[1];
			var t = new NThread();
			var print = vm.print;
			sys.thread.Thread.create(() -> {
				NThread.tls.value = t;
				var tvm = new VM();
				tvm.print = print;
				try
					tvm.callN(f, [p])
				catch (e:Dynamic) {
					var ne = tvm.wrap(e);
					Main.report(tvm, ne, true);
				}
			});
			return t.handle;
		});
		add("thread_current", 0, (vm, a) -> NThread.current().handle);
		add("thread_send", 2, (vm, a) -> {
			var t:NThread = a[0].abs("thread");
			t.messages.add(a[1]);
			return null;
		});
		add("thread_read_message", 1, (vm, a) -> NThread.current().messages.pop(a[0] == true));
		add("thread_stack", 1, (vm, a) -> {
			var r:Array<Dynamic> = [];
			return r;
		});
		add("lock_create", 0, (vm, a) -> new NAbs("lock", new sys.thread.Lock()));
		add("lock_release", 1, (vm, a) -> {
			(a[0].abs("lock") : sys.thread.Lock).release();
			return null;
		});
		add("lock_wait", 2, (vm, a) -> {
			var l:sys.thread.Lock = a[0].abs("lock");
			return a[1] == null ? l.wait() : l.wait(a[1].number());
		});
		add("tls_create", 0, (vm, a) -> new NAbs("tls", new sys.thread.Tls<Dynamic>()));
		add("tls_get", 1, (vm, a) -> (a[0].abs("tls") : sys.thread.Tls<Dynamic>).value);
		add("tls_set", 2, (vm, a) -> {
			(a[0].abs("tls") : sys.thread.Tls<Dynamic>).value = a[1];
			return null;
		});
		add("mutex_create", 0, (vm, a) -> new NAbs("mutex", new sys.thread.Mutex()));
		add("mutex_acquire", 1, (vm, a) -> {
			(a[0].abs("mutex") : sys.thread.Mutex).acquire();
			return null;
		});
		add("mutex_try", 1, (vm, a) -> (a[0].abs("mutex") : sys.thread.Mutex).tryAcquire());
		add("mutex_release", 1, (vm, a) -> {
			(a[0].abs("mutex") : sys.thread.Mutex).release();
			return null;
		});
		add("deque_create", 0, (vm, a) -> new NAbs("deque", new sys.thread.Deque<Dynamic>()));
		add("deque_add", 2, (vm, a) -> {
			(a[0].abs("deque") : sys.thread.Deque<Dynamic>).add(a[1]);
			return null;
		});
		add("deque_push", 2, (vm, a) -> {
			(a[0].abs("deque") : sys.thread.Deque<Dynamic>).push(a[1]);
			return null;
		});
		add("deque_pop", 2, (vm, a) -> (a[0].abs("deque") : sys.thread.Deque<Dynamic>).pop(a[1] == true));
		add("cond_create", 0, (vm, a) -> new NAbs("condition", new sys.thread.Condition()));
		add("cond_acquire", 1, (vm, a) -> {
			(a[0].abs("condition") : sys.thread.Condition).acquire();
			return null;
		});
		add("cond_try_acquire", 1, (vm, a) -> (a[0].abs("condition") : sys.thread.Condition).tryAcquire());
		add("cond_release", 1, (vm, a) -> {
			(a[0].abs("condition") : sys.thread.Condition).release();
			return null;
		});
		add("cond_wait", 1, (vm, a) -> {
			(a[0].abs("condition") : sys.thread.Condition).wait();
			return null;
		});
		add("cond_signal", 1, (vm, a) -> {
			(a[0].abs("condition") : sys.thread.Condition).signal();
			return null;
		});
		add("cond_broadcast", 1, (vm, a) -> {
			(a[0].abs("condition") : sys.thread.Condition).broadcast();
			return null;
		});
	}

	// a date: an Int, the seconds since the epoch
	static function dates(add:Register) {
		inline function date(v:Dynamic):Date
			return Date.fromTime((v.int() : Float) * 1000);
		inline function secs(d:Date):Int
			return Std.int(d.getTime() / 1000);
		function fields(names:Array<String>, vals:Array<Int>):NObj {
			var o = new NObj();
			for (i in 0...names.length)
				o.set(Fields.id(names[i]), vals[i]);
			return o;
		}
		add("date_now", 0, (vm, a) -> secs(Date.now()));
		add("date_new", 1, (vm, a) -> {
			if (a[0] == null) return secs(Date.now());
			var s = a[0].str().toString();
			var d = try Date.fromString(s) catch (e:Dynamic) throw VM.error("Invalid date format : " + s);
			return secs(d);
		});
		add("date_format", 2, (vm, a) -> {
			var fmt = a[1] == null ? "%Y-%m-%d %H:%M:%S" : a[1].str().toString();
			return str(DateTools.format(date(a[0]), fmt));
		});
		add("date_utc_format", 2, (vm, a) -> {
			var fmt = a[1] == null ? "%Y-%m-%d %H:%M:%S" : a[1].str().toString();
			var d = date(a[0]);
			var u = new Date(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds());
			return str(DateTools.format(u, fmt));
		});
		add("date_set_hour", 4, (vm, a) -> {
			var d = date(a[0]);
			return secs(new Date(d.getFullYear(), d.getMonth(), d.getDate(), a[1].int(), a[2].int(), a[3].int()));
		});
		add("date_set_day", 4, (vm, a) -> {
			var d = date(a[0]);
			return secs(new Date(a[1].int(), a[2].int() - 1, a[3].int(), d.getHours(), d.getMinutes(), d.getSeconds()));
		});
		add("date_get_hour", 1, (vm, a) -> {
			var d = date(a[0]);
			return fields(["h", "m", "s"], [d.getHours(), d.getMinutes(), d.getSeconds()]);
		});
		add("date_get_utc_hour", 1, (vm, a) -> {
			var d = date(a[0]);
			return fields(["h", "m", "s"], [d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds()]);
		});
		add("date_get_day", 1, (vm, a) -> {
			var d = date(a[0]);
			return fields(["y", "m", "d"], [d.getFullYear(), d.getMonth() + 1, d.getDate()]);
		});
		add("date_get_utc_day", 1, (vm, a) -> {
			var d = date(a[0]);
			return fields(["y", "m", "d"], [d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate()]);
		});
		add("date_get_tz", 1, (vm, a) -> -date(a[0]).getTimezoneOffset());
	}

	static function int32(add:Register) {
		inline function i(v:Dynamic):Int {
			if (!Tag.isInt(v)) throw Builtins.failure;
			return v;
		}
		add("int32_new", 1, (vm, a) -> Tag.isFloat(a[0]) ? Builtins.toInt(a[0]) : i(a[0]));
		add("int32_to_int", 1, (vm, a) -> i(a[0]));
		add("int32_to_float", 1, (vm, a) -> (i(a[0]) : Float));
		add("int32_compare", 2, (vm, a) -> {
			var x = i(a[0]), y = i(a[1]);
			return x == y ? 0 : (x < y ? -1 : 1);
		});
		add("int32_add", 2, (vm, a) -> i(a[0]) + i(a[1]));
		add("int32_sub", 2, (vm, a) -> i(a[0]) - i(a[1]));
		add("int32_mul", 2, (vm, a) -> i(a[0]) * i(a[1]));
		add("int32_div", 2, (vm, a) -> {
			if (i(a[1]) == 0) throw Builtins.failure;
			return Std.int(i(a[0]) / i(a[1]));
		});
		add("int32_mod", 2, (vm, a) -> {
			if (i(a[1]) == 0) throw Builtins.failure;
			return i(a[0]) % i(a[1]);
		});
		add("int32_shl", 2, (vm, a) -> i(a[0]) << i(a[1]));
		add("int32_shr", 2, (vm, a) -> i(a[0]) >> i(a[1]));
		add("int32_ushr", 2, (vm, a) -> i(a[0]) >>> i(a[1]));
		add("int32_or", 2, (vm, a) -> i(a[0]) | i(a[1]));
		add("int32_and", 2, (vm, a) -> i(a[0]) & i(a[1]));
		add("int32_xor", 2, (vm, a) -> i(a[0]) ^ i(a[1]));
		add("int32_neg", 1, (vm, a) -> -i(a[0]));
		add("int32_complement", 1, (vm, a) -> ~i(a[0]));
		add("int32_address", 1, (vm, a) -> 0);
	}

	static function random(add:Register) {
		add("random_new", 0, (vm, a) -> new NAbs("random", new Rand(Std.int(Sys.time() * 1000) ^ Std.random(0x7FFFFFFF))));
		add("random_set_seed", 2, (vm, a) -> {
			(a[0].abs("random") : Rand).seed(a[1].int());
			return null;
		});
		add("random_int", 2, (vm, a) -> {
			var max = a[1].int();
			if (max <= 0) return 0;
			return (a[0].abs("random") : Rand).int() % max;
		});
		add("random_float", 1, (vm, a) -> (a[0].abs("random") : Rand).float());
	}

	static function utf8(add:Register) {
		add("utf8_buf_alloc", 1, (vm, a) -> new NAbs("utf8buf", new NBuf()));
		add("utf8_buf_add", 2, (vm, a) -> {
			var b:NBuf = a[0].abs("utf8buf");
			var c = a[1].int();
			if (c < 0) throw Builtins.failure;
			if (c <= 0x7F) b.addByte(c) else if (c <= 0x7FF) {
				b.addByte(0xC0 | (c >> 6));
				b.addByte(0x80 | (c & 63));
			} else if (c <= 0xFFFF) {
				b.addByte(0xE0 | (c >> 12));
				b.addByte(0x80 | ((c >> 6) & 63));
				b.addByte(0x80 | (c & 63));
			} else if (c <= 0x10FFFF) {
				b.addByte(0xF0 | (c >> 18));
				b.addByte(0x80 | ((c >> 12) & 63));
				b.addByte(0x80 | ((c >> 6) & 63));
				b.addByte(0x80 | (c & 63));
			} else
				throw Builtins.failure;
			return null;
		});
		add("utf8_buf_content", 1, (vm, a) -> new NStr((a[0].abs("utf8buf") : NBuf).bytes()));
		add("utf8_buf_length", 1, (vm, a) -> utf8Codes((a[0].abs("utf8buf") : NBuf).bytes()).length);
		add("utf8_buf_size", 1, (vm, a) -> (a[0].abs("utf8buf") : NBuf).len);
		add("utf8_validate", 1, (vm, a) -> try {
			utf8Codes(a[0].str().b);
			true;
		} catch (e:Dynamic) false);
		add("utf8_length", 1, (vm, a) -> utf8Codes(a[0].str().b).length);
		add("utf8_get", 2, (vm, a) -> {
			var c = utf8Codes(a[0].str().b);
			var n = a[1].int();
			if (n < 0 || n >= c.length) throw Builtins.failure;
			return c[n];
		});
		add("utf8_iter", 2, (vm, a) -> {
			var f = a[1].fun();
			for (c in utf8Codes(a[0].str().b))
				vm.callN(f, [c]);
			return null;
		});
		add("utf8_compare", 2, (vm, a) -> {
			var x = utf8Codes(a[0].str().b), y = utf8Codes(a[1].str().b);
			for (i in 0...(x.length < y.length ? x.length : y.length))
				if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
			return x.length == y.length ? 0 : (x.length < y.length ? -1 : 1);
		});
		add("utf8_sub", 3, (vm, a) -> {
			var s = a[0].str().b, pos = a[1].int(), len = a[2].int();
			// the byte offsets of the code points
			var offs = [];
			var i = 0;
			while (i < s.length) {
				offs.push(i);
				var c = s.get(i);
				i += c < 0x80 ? 1 : (c < 0xE0 ? 2 : (c < 0xF0 ? 3 : 4));
			}
			offs.push(s.length);
			if (pos < 0 || len < 0 || pos + len > offs.length - 1) throw Builtins.failure;
			return new NStr(s.sub(offs[pos], offs[pos + len] - offs[pos]));
		});
	}

	static function utf8Codes(s:Bytes):Array<Int> {
		var r = [];
		var i = 0;
		while (i < s.length) {
			var c = s.get(i++);
			if (c < 0x80) r.push(c) else if (c < 0xC0) throw Builtins.failure else {
				var n = c < 0xE0 ? 1 : (c < 0xF0 ? 2 : 3);
				var v = c & (c < 0xE0 ? 0x1F : (c < 0xF0 ? 0x0F : 0x07));
				for (_ in 0...n) {
					if (i >= s.length) throw Builtins.failure;
					var d = s.get(i++);
					if (d & 0xC0 != 0x80) throw Builtins.failure;
					v = (v << 6) | (d & 63);
				}
				r.push(v);
			}
		}
		return r;
	}

	// neko.vm.Module
	static function modules(add:Register) {
		inline function mod(v:Dynamic):Module
			return v.abs("module");
		function load(vm:VM, bytes:Bytes, loader:Dynamic):Dynamic {
			var m = try Module.read(bytes, loader == null ? null : loader.obj()) catch (e:Module.ReadError) throw Builtins.failure;
			m.name = str("");
			return new NAbs("module", m);
		}
		add("module_read", 2, (vm, a) -> {
			var f = a[0].fun();
			var b = new NBuf();
			var chunk = new NStr(Bytes.alloc(4096));
			while (true) {
				var n:Dynamic = vm.callN(f, [chunk, 0, 4096]);
				if (!Tag.isInt(n) || (n : Int) <= 0) break;
				b.addBytes(chunk.b, 0, n);
			}
			return load(vm, b.bytes(), a[1]);
		});
		add("module_read_string", 2, (vm, a) -> load(vm, a[0].str().b, a[1]));
		add("module_read_path", 3, (vm, a) -> {
			var name = a[1].str().toString();
			var file = Loader.selectFile(a[0], name, StringTools.endsWith(name, ".n") ? "" : ".n");
			var bytes = try sys.io.File.getBytes(file) catch (e:Dynamic) throw VM.error("Module not found : " + name);
			var m:NAbs = load(vm, bytes, a[2]);
			(m.data : Module).name = str(name);
			return m;
		});
		add("module_exec", 1, (vm, a) -> vm.execute(mod(a[0])));
		add("module_name", 1, (vm, a) -> mod(a[0]).name);
		add("module_set_name", 2, (vm, a) -> {
			mod(a[0]).name = a[1].str();
			return null;
		});
		add("module_exports", 1, (vm, a) -> mod(a[0]).exports);
		add("module_loader", 1, (vm, a) -> mod(a[0]).loader);
		add("module_nglobals", 1, (vm, a) -> mod(a[0]).globals.length);
		add("module_global_get", 2, (vm, a) -> {
			var m = mod(a[0]), i = a[1].int();
			if (i < 0 || i >= m.globals.length) throw Builtins.failure;
			return m.globals[i];
		});
		add("module_global_set", 3, (vm, a) -> {
			var m = mod(a[0]), i = a[1].int();
			if (i < 0 || i >= m.globals.length) throw Builtins.failure;
			m.globals[i] = a[2];
			return null;
		});
		add("module_code_size", 1, (vm, a) -> mod(a[0]).code.length - 1);
	}
}

// libs/std/random.c's generator
class Rand {
	var cur = 0;
	var seeds:Array<Int>;

	public function new(s:Int)
		seed(s);

	static final INIT = [
		0x95f24dab, 0x0b685215, 0xe76ccae7, 0xaf3ec239, 0x715fad23, 0x24a590ad, 0x69e4b5ef, 0xbf456141, 0x96bc1b7b, 0xa7bdf825, 0xc1de75b7, 0x8858a9c9,
		0x2da87693, 0xb657f9dd, 0xffdc8a9f, 0x8121da71, 0x8b823ecb, 0x885d05f5, 0x4e20cd47, 0x5a9ad5d9, 0x512c0c03, 0xea857ccd, 0x4cc1d30f, 0x8891a8a1,
		0xa6b7aadb
	];
	static final MAG = [0, 0x8ebfd028];

	public function seed(s:Int) {
		cur = 0;
		seeds = INIT.copy();
		for (i in 0...25)
			seeds[i] ^= s;
	}

	public function int():Int {
		if (cur == 25) {
			var kk = 0;
			while (kk < 25 - 7) {
				seeds[kk] = seeds[kk + 7] ^ (seeds[kk] >>> 1) ^ MAG[seeds[kk] & 1];
				kk++;
			}
			while (kk < 25) {
				seeds[kk] = seeds[kk + (7 - 25)] ^ (seeds[kk] >>> 1) ^ MAG[seeds[kk] & 1];
				kk++;
			}
			cur = 0;
		}
		var y = seeds[cur++];
		y ^= (y << 7) & 0x2b5b2500;
		y ^= (y << 15) & 0xdb8b0000;
		y ^= y >>> 16;
		return y & 0x3FFFFFFF;
	}

	public function float():Float {
		var big = 4294967296.0;
		return ((int() / big + int()) / big + int()) / big;
	}
}
