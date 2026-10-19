package ml2hx.rt;

// OCaml's unit. An enum abstract so it costs nothing at run time.
enum abstract Unit(Int) {
	var value = 0;
}
