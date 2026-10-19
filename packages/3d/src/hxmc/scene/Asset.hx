package hxmc.scene;

// A handle to data that may not be here yet (a model loaded at run time:
// Model.load, Model.of(path, Lazy)): returned at once, its state Loading,
// then Ready with its value, or Failed. then(f) runs f once it is ready
// (at once if it is); onChange(f) each time the value is replaced after
// that (a reload swapping the data behind the same handle). Loads advance
// when Assets.poll runs: Stages.frame does it, else the program each frame.
class Asset<T> {
	public var state(default, null):AssetState = Loading;
	public var value(default, null):Null<T>;
	public var ready(get, never):Bool;

	final waiting:Array<T->Void> = [];
	final changes:Array<T->Void> = [];

	public function new() {}

	inline function get_ready():Bool
		return state == Ready;

	public function then(f:T->Void):Asset<T> {
		if (state == Ready) f(value) else waiting.push(f);
		return this;
	}

	public function onChange(f:T->Void):Asset<T> {
		changes.push(f);
		return this;
	}

	// the value arrived (again: swapped, onChange's functions told)
	public function resolve(v:T) {
		var again = state == Ready;
		value = v;
		state = Ready;
		if (again) {
			for (f in changes.copy())
				f(v);
			return;
		}
		var w = waiting.copy();
		waiting.resize(0);
		for (f in w)
			f(v);
	}

	public function fail(error:String)
		state = Failed(error);
}

enum AssetState {
	Loading;
	Ready;
	Failed(error:String);
}
