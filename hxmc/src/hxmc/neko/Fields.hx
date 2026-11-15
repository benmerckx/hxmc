package hxmc.neko;

import haxe.io.Bytes;

// the field hashes and the names they came from (val_id, val_field_name)
class Fields {
	static final names = new Map<Int, Bytes>();
	static final lock = new sys.thread.Mutex();

	public static final idLoader = id("loader");
	public static final idExports = id("exports");
	public static final idString = id("__string");
	public static final idCompare = id("__compare");
	public static final idAdd = id("__add");
	public static final idRadd = id("__radd");
	public static final idSub = id("__sub");
	public static final idRsub = id("__rsub");
	public static final idMult = id("__mult");
	public static final idRmult = id("__rmult");
	public static final idDiv = id("__div");
	public static final idRdiv = id("__rdiv");
	public static final idMod = id("__mod");
	public static final idRmod = id("__rmod");
	public static final idGet = id("__get");
	public static final idSet = id("__set");

	public static function hash(b:Bytes):Int {
		var h = 0;
		for (i in 0...b.length) {
			var c = b.get(i);
			if (c == 0) break;
			h = ((223 * h + c) << 1) >> 1;
		}
		return h;
	}

	public static function id(s:String):Int
		return idBytes(Bytes.ofString(s));

	public static function idBytes(b:Bytes):Int {
		var h = hash(b);
		lock.acquire();
		var old = names.get(h);
		if (old == null) {
			// (a C string: up to the first NUL)
			var n = 0;
			while (n < b.length && b.get(n) != 0) n++;
			names.set(h, n == b.length ? b : b.sub(0, n));
		}
		lock.release();
		if (old != null && old.compare(b) != 0) {
			// (a name with a NUL past its end compares with that NUL)
			var n = 0;
			while (n < b.length && b.get(n) != 0) n++;
			if (old.compare(n == b.length ? b : b.sub(0, n)) != 0)
				throw new hxmc.neko.Value.NekoError(hxmc.neko.Value.NStr.of("Field conflict between " + old.toString() + " and " + b.toString()));
		}
		return h;
	}

	public static function nameBytes(h:Int):Null<Bytes> {
		lock.acquire();
		var n = names.get(h);
		lock.release();
		return n;
	}

	public static function name(h:Int):String {
		var n = nameBytes(h);
		return n == null ? null : n.toString();
	}
}
