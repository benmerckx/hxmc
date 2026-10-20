package hxmc.macro;

import haxe.io.Bytes;

// A file of lines "name field...", sorted by name (<exe>.syms: Link writes
// them so; <exe>.fps: Driver), looked up by a binary search over its bytes:
// the jit compiler reads both at each start, 72k and 20k lines, which as
// maps of strings took 0.56 G instructions and 40 ms.
class SymFile {
	final b:Bytes;

	function new(b:Bytes)
		this.b = b;

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
		// (lo: a line's first byte; hi: one, or the end)
		var lo = 0, hi = b.length;
		while (lo < hi) {
			var p = (lo + hi) >> 1;
			while (p > lo && b.get(p - 1) != "\n".code)
				p--;
			var c = compareName(name, p);
			if (c == 0) return p;
			if (c < 0) hi = p else {
				while (p < b.length && b.get(p) != "\n".code)
					p++;
				lo = p + 1;
			}
		}
		return -1;
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
