package ml2hx.std;

// Types of luv's Luv.File.Statfs (libuv's uv_statfs_t); see Luv__File_Stat.
class LuvFileStatfsT implements ml2hx.rt.Block {
	public final type_:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final bsize:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final blocks:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final bfree:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final bavail:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final files:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final ffree:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final fSpare:ml2hx.rt.Tuple4<ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, ml2hx.std.Unsigned_UInt64.UnsignedUInt64T>;
	public function new(type_:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, bsize:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, blocks:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, bfree:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, bavail:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, files:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, ffree:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, fSpare:ml2hx.rt.Tuple4<ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, ml2hx.std.Unsigned_UInt64.UnsignedUInt64T>) {
		this.type_ = type_;
		this.bsize = bsize;
		this.blocks = blocks;
		this.bfree = bfree;
		this.bavail = bavail;
		this.files = files;
		this.ffree = ffree;
		this.fSpare = fSpare;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 8;
	public function blockField(i:Int):Dynamic return ([type_, bsize, blocks, bfree, bavail, files, ffree, fSpare] : Array<Dynamic>)[i];
}

class Luv__File_Statfs {}
