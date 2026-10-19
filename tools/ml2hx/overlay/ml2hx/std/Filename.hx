package ml2hx.std;

import String;
import ml2hx.rt.*;

// Stdlib.Filename with the Unix conventions (filename.ml's Unix module).
class Filename {
	public static final currentDirName = ".";
	public static final parentDirName = "..";
	public static final dirSep = "/";
	static inline function isDirSep(s:String, i:Int):Bool return StringTools.fastCodeAt(s, i) == "/".code;

	public static function isRelative(n:String):Bool return n.length < 1 || StringTools.fastCodeAt(n, 0) != "/".code;
	public static function isImplicit(n:String):Bool
		return isRelative(n) && !(n.length >= 2 && n.substr(0, 2) == "./") && !(n.length >= 3 && n.substr(0, 3) == "../");
	public static function concat(dir:String, file:String):String {
		var l = dir.length;
		return (l == 0 || isDirSep(dir, l - 1)) ? dir + file : dir + "/" + file;
	}
	public static function checkSuffix(name:String, suff:String):Bool
		return StringTools.endsWith(name, suff);
	public static function chopSuffix(name:String, suff:String):String {
		var n = name.length - suff.length;
		if (n < 0) throw new InvalidArgument("Filename.chop_suffix");
		return name.substr(0, n);
	}
	public static function chopSuffixOpt(suffix:String, name:String):MlOption<String>
		return checkSuffix(name, suffix) ? Some(name.substr(0, name.length - suffix.length)) : None;
	static function extensionLen(name:String):Int {
		function check(i0:Int, i:Int):Int {
			while (true) {
				if (i < 0 || isDirSep(name, i)) return 0;
				if (StringTools.fastCodeAt(name, i) == ".".code) i--; else return name.length - i0;
			}
		}
		var i = name.length - 1;
		while (true) {
			if (i < 0 || isDirSep(name, i)) return 0;
			if (StringTools.fastCodeAt(name, i) == ".".code) return check(i, i - 1);
			i--;
		}
	}
	public static function extension(name:String):String {
		var l = extensionLen(name);
		return l == 0 ? "" : name.substr(name.length - l, l);
	}
	public static function chopExtension(name:String):String {
		var l = extensionLen(name);
		if (l == 0) throw new InvalidArgument("Filename.chop_extension");
		return name.substr(0, name.length - l);
	}
	public static function removeExtension(name:String):String {
		var l = extensionLen(name);
		return l == 0 ? name : name.substr(0, name.length - l);
	}
	public static function basename(name:String):String {
		if (name == "") return currentDirName;
		var n = name.length - 1;
		while (n >= 0 && isDirSep(name, n)) n--;
		if (n < 0) return name.substr(0, 1);
		var p = n + 1;
		while (n >= 0 && !isDirSep(name, n)) n--;
		return n < 0 ? name.substr(0, p) : name.substr(n + 1, p - n - 1);
	}
	public static function dirname(name:String):String {
		if (name == "") return currentDirName;
		var n = name.length - 1;
		while (n >= 0 && isDirSep(name, n)) n--;
		if (n < 0) return name.substr(0, 1);
		while (n >= 0 && !isDirSep(name, n)) n--;
		if (n < 0) return currentDirName;
		while (n >= 0 && isDirSep(name, n)) n--;
		if (n < 0) return name.substr(0, 1);
		return name.substr(0, n + 1);
	}
	public static function quote(s:String):String {
		var b = new StringBuf();
		b.add("'");
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if (c == "'".code) b.add("'\\''"); else b.addChar(c);
		}
		b.add("'");
		return b.toString();
	}
	public static function getTempDirName(_:Unit):String {
		#if sys
		var t = std.Sys.getEnv("TMPDIR");
		return t == null ? "/tmp" : ByteString.ofNative(t);
		#else
		return "/tmp";
		#end
	}
}
