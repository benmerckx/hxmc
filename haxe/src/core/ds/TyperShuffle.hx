package core.ds;

// port: `Random.State.make [|Hashtbl.hash seed|]` and `Random.State.int` of the typer
// shuffle (HAXE_TYPER_SHUFFLE): a xorshift32 generator seeded by the same hash, not
// OCaml's LXM, so a seed gives another order than upstream's (the order is only a
// debugging aid: typing must not depend on it)
class TyperShuffle {
	var state:Int;

	public function new(seed:String) {
		state = OcamlHash.hashString(seed);
		if (state == 0) state = 0x9E3779B9;
	}

	// 0 <= result < bound
	public function int(bound:Int):Int {
		var x = state;
		x ^= x << 13;
		x ^= x >>> 17;
		x ^= x << 5;
		state = x;
		return (x >>> 1) % bound;
	}
}
