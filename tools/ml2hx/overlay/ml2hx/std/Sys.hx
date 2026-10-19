package ml2hx.std;

import Array as HArray;
import String;
import ml2hx.rt.*;

// Stdlib.Sys over Haxe's Sys and sys.FileSystem; names cross the host
// boundary as UTF-8 (ml2hx.rt.ByteString).
enum SysSignalBehavior {
	Signal_default;
	Signal_ignore;
	Signal_handle(v0:Int63->Unit);
}

class SysBreak extends MlException {
	public static final instance = new SysBreak();
	public function new() super();
	override public function exnName():String return "Stdlib.Sys.Break";
}

class Sys {
	static inline function native(s:String):String return ByteString.toNative(s);
	static inline function ocaml(s:String):String return ByteString.ofNative(s);
	static function sysError(name:String, e:Dynamic):Dynamic throw new SysError(name + ": " + Std.string(e));

	public static final argv:HArray<String> = {
		#if sys
		var a = [ocaml(std.Sys.programPath() ?? "")];
		for (x in std.Sys.args()) a.push(ocaml(x));
		a;
		#else
		[""];
		#end
	};
	public static final executableName:String = argv[0];
	public static final osType = "Unix";
	public static final unix = true;
	public static final win32 = false;
	public static final cygwin = false;
	public static final wordSize:Int63 = Int63.ofInt(64);
	public static final intSize:Int63 = Int63.ofInt(63);
	public static final bigEndian = false;
	public static final maxStringLength:Int63 = Int63.ofInt(0x7FFFFFFF);
	public static final maxArrayLength:Int63 = Int63.ofInt(0x7FFFFFFF);
	public static final ocamlVersion = "5.3.0";
	public static final interactive = new Ref(false);
	public static final sigabrt:Int63 = Int63.ofInt(-1);
	public static final sigint:Int63 = Int63.ofInt(-6);
	public static final sigkill:Int63 = Int63.ofInt(-7);
	public static final sigterm:Int63 = Int63.ofInt(-11);
	public static final sigpipe:Int63 = Int63.ofInt(-8);
	public static final sigchld:Int63 = Int63.ofInt(-4);

	public static function getenv(name:String):String {
		#if sys
		var v = std.Sys.getEnv(native(name));
		if (v == null) throw NotFound.instance;
		return ocaml(v);
		#else
		throw NotFound.instance;
		#end
	}
	public static function getenvOpt(name:String):MlOption<String> return try Some(getenv(name)) catch (e:NotFound) None;
	public static function command(cmd:String):Int63 {
		#if sys
		return Int63.ofInt(std.Sys.command(native(cmd)));
		#else
		return Int63.ofInt(127);
		#end
	}
	public static function time(_:Unit):Float {
		#if sys
		return std.Sys.cpuTime();
		#else
		return haxe.Timer.stamp();
		#end
	}
	#if sys
	public static function fileExists(n:String):Bool return sys.FileSystem.exists(native(n));
	public static function isDirectory(n:String):Bool {
		if (!sys.FileSystem.exists(native(n))) throw new SysError(n + ": No such file or directory");
		return sys.FileSystem.isDirectory(native(n));
	}
	public static function isRegularFile(n:String):Bool {
		if (!sys.FileSystem.exists(native(n))) throw new SysError(n + ": No such file or directory");
		return !sys.FileSystem.isDirectory(native(n));
	}
	public static function remove(n:String):Unit {
		try sys.FileSystem.deleteFile(native(n)) catch (e:Dynamic) sysError(n, e);
		return Unit.value;
	}
	public static function rename(a:String, b:String):Unit {
		try sys.FileSystem.rename(native(a), native(b)) catch (e:Dynamic) sysError(a, e);
		return Unit.value;
	}
	public static function chdir(n:String):Unit {
		try std.Sys.setCwd(native(n)) catch (e:Dynamic) sysError(n, e);
		return Unit.value;
	}
	public static function getcwd(_:Unit):String {
		var c = std.Sys.getCwd();
		while (c.length > 1 && StringTools.endsWith(c, "/")) c = c.substr(0, c.length - 1);
		return ocaml(c);
	}
	public static function mkdir(n:String, perm:Int63):Unit {
		try sys.FileSystem.createDirectory(native(n)) catch (e:Dynamic) sysError(n, e);
		return Unit.value;
	}
	public static function rmdir(n:String):Unit {
		try sys.FileSystem.deleteDirectory(native(n)) catch (e:Dynamic) sysError(n, e);
		return Unit.value;
	}
	public static function readdir(n:String):HArray<String> {
		return try [for (x in sys.FileSystem.readDirectory(native(n))) ocaml(x)] catch (e:Dynamic) sysError(n, e);
	}
	#end
	public static function catchBreak(b:Bool):Unit return Unit.value;
	public static function signal(n:Int63, b:SysSignalBehavior):SysSignalBehavior return Signal_default;
	public static function setSignal(n:Int63, b:SysSignalBehavior):Unit return Unit.value;
	public static inline function opaqueIdentity<T>(x:T):T return x;
}
