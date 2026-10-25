import hxmc.scoped.*;

// Goose's bench/goose/push.goose: growth while holding element references.
// Scoped: the items in a Grow (nothing moves), every 64th's reference kept
// in another; GC: objects in an Array, every 64th kept.
//   Push scoped|gc [n]
@:hxmc.scoped class Item {
	public var key:Int;
	public var val:Int;

	public function new(key, val) {
		this.key = key;
		this.val = val;
	}
}

@:hxmc.scoped class Scoped {
	public static function run(n:Int, out:Grow<Int>) {
		var items = new Grow<Item>();
		var marks = new Grow<Ref<Item>>();
		var r = 12345;
		for (i in 0...n) {
			r ^= r << 13;
			r ^= r >>> 17;
			r ^= r << 5;
			var e = items.push(new Item((r >>> 1) % 1000000, i % 97));
			if (i % 64 == 0) marks.push(e);
		}
		var total = 0;
		for (it in items)
			total += it.key;
		var mt = 0;
		for (m in marks)
			mt += m.value.val;
		out.push(items.length);
		out.push(marks.length);
		out.push(total);
		out.push(mt);
	}
}

class GItem {
	public var key:Int;
	public var val:Int;

	public function new(key, val) {
		this.key = key;
		this.val = val;
	}
}

class Gc {
	public static function run(n:Int, out:Array<Int>) {
		var items = [];
		var marks = [];
		var r = 12345;
		for (i in 0...n) {
			r ^= r << 13;
			r ^= r >>> 17;
			r ^= r << 5;
			var e = new GItem((r >>> 1) % 1000000, i % 97);
			items.push(e);
			if (i % 64 == 0) marks.push(e);
		}
		var total = 0;
		for (it in items)
			total += it.key;
		var mt = 0;
		for (m in marks)
			mt += m.val;
		out.push(items.length);
		out.push(marks.length);
		out.push(total);
		out.push(mt);
	}
}

class Push {
	static function main() {
		var args = Sys.args();
		var n = args.length > 1 ? Std.parseInt(args[1]) : 4000000;
		if (args[0] == "gc") {
			var out = [];
			Gc.run(n, out);
			for (x in out)
				Sys.println(x);
		} else {
			var out = new Grow<Int>();
			Scoped.run(n, out);
			for (x in out)
				Sys.println(x);
		}
	}
}
