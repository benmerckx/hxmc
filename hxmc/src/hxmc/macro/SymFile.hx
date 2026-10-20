package hxmc.macro;

import haxe.io.Bytes;

// A file of lines "name field...", sorted by name (<exe>.syms: Link writes
// them so; <exe>.fps: Driver), looked up by a binary search over its bytes:
// the jit compiler reads both at each start, 72k and 20k lines, which as
// maps of strings took 0.56 G instructions and 40 ms. The lines' starts
// are found at the first lookup, and the names looked up are remembered (a
// build of many macros looks the same symbols up again at each step).
class SymFile {
	final b:Bytes;
	var starts:Null<Array<Int>> = null;
	final found = new Map<String, Int>();

	function new(b:Bytes)
		this.b = b;

	function lines():Array<Int> {
		var s = [];
		var at = 0, n = b.length;
		while (at < n) {
			var e = at;
			while (e < n && b.get(e) != "\n".code)
				e++;
			if (e > at) s.push(at);
			at = e + 1;
		}
		return s;
	}

	public static function read(path:String):Null<SymFile>
		return sys.FileSystem.exists(path) ? new SymFile(sys.io.File.getBytes(path)) : null;

	inline function end(c:Int):Bool
		return c == " ".code || c == "\n".code;

	inline function at(i:Int):Int
		return i < b.length ? b.get(i) : "\n".code;

	// name against the name of the line at p
	function compareName(name:String, p:Int):Int {
		for (i in 0...name.length) {
			var c = at(p + i);
			if (end(c)) return 1;
			var d = StringTools.fastCodeAt(name, i) - c;
			if (d != 0) return d;
		}
		return end(at(p + name.length)) ? 0 : -1;
	}

	// the line named name (its first byte), -1 when there is none
	public function find(name:String):Int {
		var r = found.get(name);
		if (r != null) return r;
		if (starts == null) starts = lines();
		var s = starts;
		var lo = 0, hi = s.length - 1;
		r = -1;
		while (lo <= hi) {
			var mid = (lo + hi) >> 1;
			var c = compareName(name, s[mid]);
			if (c == 0) {
				r = s[mid];
				break;
			}
			if (c < 0) hi = mid - 1 else lo = mid + 1;
		}
		found.set(name, r);
		return r;
	}

	// the field k of the line at p (0: its name), "" past its last one;
	// k < 0: the rest of the line after its name
	public function field(p:Int, k:Int):String {
		var i = p;
		var f = 0;
		var target = k < 0 ? 1 : k;
		while (f < target) {
			var c = at(i);
			if (c == "\n".code) return "";
			if (c == " ".code) f++;
			i++;
		}
		var j = i;
		while (j < b.length && b.get(j) != "\n".code && (k < 0 || b.get(j) != " ".code))
			j++;
		return b.getString(i, j - i);
	}
}

// <exe>.syms: "name kind value" per line
class HostSyms {
	final f:SymFile;

	public function new(f:SymFile)
		this.f = f;

	public function get(name:String):Null<{k:String, v:Int}> {
		var p = f.find(name);
		return p < 0 ? null : {k: f.field(p, 1), v: Std.parseInt(f.field(p, 2))};
	}

	public inline function exists(name:String):Bool
		return f.find(name) >= 0;
}

// <exe>.fps: "symbol fingerprint" per line (none: no function the compiler's)
class HostFps {
	final f:Null<SymFile>;

	public function new(f:Null<SymFile>)
		this.f = f;

	public function get(name:String):Null<String> {
		if (f == null) return null;
		var p = f.find(name);
		return p < 0 ? null : f.field(p, -1);
	}
}
