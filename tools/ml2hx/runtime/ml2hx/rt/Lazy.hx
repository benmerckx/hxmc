package ml2hx.rt;

// 'a Lazy.t. Forcing a suspension that raises re-raises on later forces;
// forcing it recursively raises CamlinternalLazy.Undefined.
class Lazy<T> {
	var state:Int; // 0 suspended, 1 forcing, 2 value, 3 raised
	var thunk:Void->T;
	var result:T;
	var error:Any;
	public function new(thunk:Void->T) { this.thunk = thunk; state = 0; }
	public static function fromVal<T>(v:T):Lazy<T> { var l = new Lazy<T>(null); l.state = 2; l.result = v; return l; }
	public function force():T {
		switch state {
			case 2: return result;
			case 3: throw error;
			case 1: throw LazyUndefined.instance;
			case _:
		}
		state = 1;
		try {
			result = thunk();
			state = 2;
			thunk = null;
			return result;
		} catch (e:haxe.Exception) {
			error = MlException.wrap(e);
			state = 3;
			throw error;
		}
	}
	public inline function isVal():Bool return state == 2;
}

class LazyUndefined extends MlException {
	public static final instance = new LazyUndefined();
	public function new() super();
	override public function exnName():String return "CamlinternalLazy.Undefined";
}
