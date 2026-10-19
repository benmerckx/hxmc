package ml2hx.rt;

// A value OCaml keeps in a block of Abstract_tag (ephemerons and weak
// arrays): compare raises "compare: abstract value", hash skips it; Obj.size
// is its block's size.
interface Abstract {
	function abstractSize():Int;
}
