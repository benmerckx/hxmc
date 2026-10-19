package ml2hx.prim;

import ml2hx.rt.*;
import ocaml.stdlib.StdlibModule.StdlibOpenFlag;

// OCaml's sys.c over Haxe's sys API. Errors are Sys_error "name: reason".
class Sys {
	static inline function native(s:String):String return ByteString.toNative(s);
	static inline function ocaml(s:String):String return ByteString.ofNative(s);
	static function sysError(name:String, e:Dynamic):Dynamic throw new SysError(name + ": " + Std.string(e));
	static function noSuchFile(name:String):Dynamic throw new SysError(name + ": No such file or directory");

	static var args:Null<Array<String>> = null;
	// %sys_argv: the program name, then the arguments
	public static function argv():Array<String> {
		if (args == null) {
			args = [ocaml(std.Sys.programPath() ?? "")];
			for (x in std.Sys.args()) args.push(ocaml(x));
		}
		return args;
	}

	public static function camlSysGetConfig(_:Unit):Tuple3<String, Int63, Bool> return new Tuple3("Unix", Int63.ofInt(64), false);
	public static function camlSysExecutableName(_:Unit):String return argv()[0];
	public static function camlRuntimeVariant(_:Unit):String return "";
	public static function camlRuntimeParameters(_:Unit):String return "";

	public static function camlSysFileExists(n:String):Bool return sys.FileSystem.exists(native(n));
	public static function camlSysIsDirectory(n:String):Bool {
		if (!sys.FileSystem.exists(native(n))) noSuchFile(n);
		return sys.FileSystem.isDirectory(native(n));
	}
	public static function camlSysIsRegularFile(n:String):Bool {
		if (!sys.FileSystem.exists(native(n))) noSuchFile(n);
		return !sys.FileSystem.isDirectory(native(n));
	}
	public static function camlSysRemove(n:String):Unit {
		if (!sys.FileSystem.exists(native(n))) noSuchFile(n);
		try sys.FileSystem.deleteFile(native(n)) catch (e:Dynamic) sysError(n, e);
		return Unit.value;
	}
	public static function camlSysRename(a:String, b:String):Unit {
		if (!sys.FileSystem.exists(native(a))) noSuchFile(a);
		try sys.FileSystem.rename(native(a), native(b)) catch (e:Dynamic) sysError(a, e);
		return Unit.value;
	}
	public static function camlSysGetenv(name:String):String {
		var v = std.Sys.getEnv(native(name));
		if (v == null) throw NotFound.instance;
		return ocaml(v);
	}
	public static function camlSysSystemCommand(cmd:String):Int63 return Int63.ofInt(std.Sys.command(native(cmd)));
	public static function camlSysTime(_:Unit):Float return std.Sys.cpuTime();
	public static function camlSysChdir(n:String):Unit {
		if (!sys.FileSystem.exists(native(n))) noSuchFile(n);
		try std.Sys.setCwd(native(n)) catch (e:Dynamic) sysError(n, e);
		return Unit.value;
	}
	public static function camlSysGetcwd(_:Unit):String {
		var c = std.Sys.getCwd();
		while (c.length > 1 && StringTools.endsWith(c, "/")) c = c.substr(0, c.length - 1);
		return ocaml(c);
	}
	public static function camlSysMkdir(n:String, perm:Int63):Unit {
		if (sys.FileSystem.exists(native(n))) throw new SysError(n + ": File exists");
		try sys.FileSystem.createDirectory(native(n)) catch (e:Dynamic) sysError(n, e);
		return Unit.value;
	}
	public static function camlSysRmdir(n:String):Unit {
		if (!sys.FileSystem.exists(native(n))) noSuchFile(n);
		try sys.FileSystem.deleteDirectory(native(n)) catch (e:Dynamic) sysError(n, e);
		return Unit.value;
	}
	public static function camlSysReadDirectory(n:String):Array<String> {
		if (!sys.FileSystem.exists(native(n))) noSuchFile(n);
		return try [for (x in sys.FileSystem.readDirectory(native(n))) ocaml(x)] catch (e:Dynamic) sysError(n, e);
	}
	public static function camlSysExit<T>(code:Int63):T {
		std.Sys.exit(code.toInt());
		throw new haxe.Exception("unreachable");
	}
	public static function camlSysRandomSeed(_:Unit):Array<Int63> {
		var a = [];
		for (_ in 0...12) a.push(Int63.ofInt(Std.random(0x40000000)));
		return a;
	}
	// (Sys.signal_behavior is the Sys module's: built by name here.)
	static var handlers = new Map<Int, Dynamic>();
	public static function camlInstallSignalHandler<B>(n:Int63, b:B):B {
		var old:Null<B> = handlers.get(n.toInt());
		handlers.set(n.toInt(), b);
		return old ?? Type.createEnum(Type.getEnum(cast b), "Signal_default");
	}
	static var named = new Map<String, Dynamic>();
	public static function camlRegisterNamedValue<T>(name:String, v:T):Unit {
		named.set(name, v);
		return Unit.value;
	}

	// caml_sys_open: a file descriptor (Io's table). A regular file opened for
	// reading only is read whole; writing goes through Haxe's file outputs.
	public static function camlSysOpen(name:String, flags:MlList<StdlibOpenFlag>, perm:Int63):Int63 {
		var rd = false, wr = false, append = false, creat = false, trunc = false, excl = false;
		var l = flags;
		while (true) switch l {
			case Nil: break;
			case Cons(f, t):
				switch f {
					case Open_rdonly: rd = true;
					case Open_wronly: wr = true;
					case Open_append: append = true; wr = true;
					case Open_creat: creat = true;
					case Open_trunc: trunc = true;
					case Open_excl: excl = true;
					case _:
				}
				l = t;
		}
		var path = native(name);
		var exists = sys.FileSystem.exists(path);
		if (excl && creat && exists) throw new SysError(name + ": File exists");
		if (!exists && !creat) noSuchFile(name);
		if (exists && sys.FileSystem.isDirectory(path) && wr) throw new SysError(name + ": Is a directory");
		var fd = new Io.Fd(name);
		try {
			if (wr) fd.output = append ? sys.io.File.append(path, true) : (trunc || !exists ? sys.io.File.write(path, true) : sys.io.File.update(path, true));
			else if (sys.FileSystem.isDirectory(path)) fd.bytes = haxe.io.Bytes.alloc(0);
			else fd.bytes = exists ? sys.io.File.getBytes(path) : haxe.io.Bytes.alloc(0);
		} catch (e:MlException) {
			throw e;
		} catch (e:Dynamic) {
			sysError(name, e);
		}
		return Int63.ofInt(Io.addFd(fd));
	}
	public static function camlSysClose(fd:Int63):Unit {
		Io.closeFd(fd.toInt());
		return Unit.value;
	}
}
