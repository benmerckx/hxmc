package hxmc.neko;

import hxmc.neko.Value;

// the primitives $loader.loadprim finds: "lib@name" with its argument count
// (neko's ndll exports name__N, name__MULT)
class Prims {
	static var table:Map<String, NFun>;
	static final lock = new sys.thread.Mutex();

	public static function find(name:String, nargs:Int):Null<NFun> {
		lock.acquire();
		if (table == null) {
			table = new Map();
			StdPrims.register(add);
			RegexpPrims.register(add);
			ZlibPrims.register(add);
			SocketPrims.register(add);
			SslPrims.register(add);
		}
		var f = table.get(name);
		lock.release();
		if (f == null || f.nargs != nargs) return null;
		return f;
	}

	static function add(name:String, nargs:Int, f:Prim) {
		table.set(name, Builtins.prim(name, nargs, f));
	}
}

typedef Register = (name:String, nargs:Int, f:Prim) -> Void;
