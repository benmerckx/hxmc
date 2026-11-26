class HotClosurePerInvoke {
	public static function main():Void {
		var shared = 0;
		final a = textNode(() -> shared);
		final b = textNode(() -> shared);
		shared = 1;
		a.run();
		b.run();
		if (a.ref.v != 1 || b.ref.v != 1)
			throw 'per-invoke closure collision (a=${a.ref.v} b=${b.ref.v})';
	}

	public static function textNode(read:() -> Int):Slot {
		var last:Null<Int> = null;
		final ref = {v: (null : Null<Int>)};
		final run = function() {
			final s = read();
			if (ref.v == null)
				ref.v = s;
			else if (s != last)
				ref.v = s;
			last = s;
		};
		run();
		return {ref: ref, run: run};
	}
}

typedef Slot = {
	var ref:{v:Null<Int>};
	var run:Void -> Void;
}