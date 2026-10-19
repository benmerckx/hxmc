package ml2hx.rt;

// An OCaml heap block as polymorphic compare, equality and hashing see it
// (ml2hx.rt.Poly): records, tuples, refs and the runtime's own records
// implement it. The tag is OCaml's (0 for records and tuples; 254, Double_array_tag,
// for a record of floats only); the fields are in declaration order.
interface Block {
	function blockTag():Int;
	function blockSize():Int;
	function blockField(i:Int):Dynamic;
}
