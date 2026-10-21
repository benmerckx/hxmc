package core.ds;

class StringDynArray {
	var values:haxe.ds.Vector<String>;

	public var length(default, null):Int = 0;

	public function new(capacity:Int) {
		values = new haxe.ds.Vector(capacity, "");
	}

	public function add(value:String):Void {
		var capacity = values.length;
		if (length == capacity) {
			var expanded = new haxe.ds.Vector(capacity * 2, "");
			haxe.ds.Vector.blit(values, 0, expanded, 0, capacity);
			values = expanded;
		}
		values[length] = value;
		length++;
	}

	// port: `Array.unsafe_get d.arr i`, which callers do on `arr` directly upstream
	public function get(index:Int):String {
		return values[index];
	}

	public function iter(callback:String->Void):Void {
		for (index in 0...length) callback(values[index]);
	}
}
