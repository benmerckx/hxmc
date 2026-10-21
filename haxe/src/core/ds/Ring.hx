package core.ds;

class Ring<T> {
	var values:haxe.ds.Vector<T>;
	var index:Int = 0;
	var numFilled:Int = 0;

	public function new(length:Int, initial:T) {
		values = new haxe.ds.Vector(length, initial);
	}

	public function push(value:T):Void {
		values[index] = value;
		numFilled++;
		index = index == values.length - 1 ? 0 : index + 1;
	}

	public function iter(callback:T->Void):Void {
		var len = values.length;
		for (i in 0...len) {
			var off = index + i;
			var off = off >= len ? off - len : off;
			callback(values[off]);
		}
	}

	public function fold<Result>(initial:Result, callback:Result->T->Result):Result {
		var len = values.length;
		var acc = initial;
		for (i in 0...len) {
			var off = index + i;
			var off = off >= len ? off - len : off;
			acc = callback(acc, values[off]);
		}
		return acc;
	}

	public function find(predicate:T->Bool):T {
		for (value in values) if (predicate(value)) return value;
		throw NotFound.raise();
	}

	public function isFilled():Bool {
		return numFilled >= values.length;
	}

	public function resetFilled():Void {
		numFilled = 0;
	}
}
