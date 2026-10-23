package hxmc;

/**
	An unsigned byte: as the element of an `hxmc.NativeArray` (so of a
	`haxe.ds.Vector`, and `haxe.io.BytesData`, which a `haxe.io.Bytes` holds),
	one byte of storage, which keeps the low 8 bits of what is written and
	reads them back as an Int from 0 to 255. Anywhere else (a variable, a
	field, an Array's element) a Byte is an Int, not narrowed.
**/
@:notNull abstract Byte(Int) from Int to Int {}
