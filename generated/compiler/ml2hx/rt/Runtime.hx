package ml2hx.rt;
import ml2hx.rt.MlList;
class Runtime {
	public static function listLength<T>(xs:MlList<T>):Int63 {
		var n = Int63.ofInt(0);
		while (true) switch xs {
			case Nil: return n;
			case Cons(_, tail): n = Int63.add(n, Int63.ofInt(1)); xs = tail;
		}
	}
	public static function toArray<T>(xs:MlList<T>):Array<T> {
		var a = [];
		while (true) switch xs {
			case Nil: return a;
			case Cons(head, tail): a.push(head); xs = tail;
		}
	}
	public static function arrayMake<T>(length:Int63, value:T):Array<T> {
		var n = length.toInt();
		if (n < 0) throw new haxe.Exception("Invalid_argument Array.make");
		return [for (_ in 0...n) value];
	}
	public static function arrayGet<T>(a:Array<T>, i:Int63):T {
		var n = i.toInt();
		if (n < 0 || n >= a.length) throw new haxe.Exception("Invalid_argument index out of bounds");
		return a[n];
	}
	public static function arraySet<T>(a:Array<T>, i:Int63, value:T):Unit {
		var n = i.toInt();
		if (n < 0 || n >= a.length) throw new haxe.Exception("Invalid_argument index out of bounds");
		a[n] = value;
		return Unit.value;
	}
}
