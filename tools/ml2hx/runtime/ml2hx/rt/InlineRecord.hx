package ml2hx.rt;

// The record of a constructor with an inline record (C of {x; y}): OCaml
// lays its fields out in the constructor's block, so compare, hash, Obj and
// Marshal see them there.
interface InlineRecord extends Block {}
