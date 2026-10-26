package hxmc.unsafe;

// C's float: a Float (double) in Haxe code, single precision in memory
// (Ptr<Float32>, @:hxmc.struct fields) and in calls of C functions, where
// the value is rounded to the nearest float (docs/interop.md, "C interop").
abstract Float32(Float) from Float to Float {}
