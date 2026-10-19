package ml2hx.rt;

// OCaml blocks represented by classes (records, tuples, exceptions with
// payloads, references): their fields in OCaml's order, for structural
// equality, comparison and hashing.
interface Structural {
	function structuralFields():Array<Any>;
}
