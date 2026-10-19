package ml2hx.std;

// Types of luv's Luv.File.Stat (libuv's uv_stat_t) that the compiler's
// types mention; libuv is not available to the generated compiler, so no
// values of them are made.
class LuvFileStatT implements ml2hx.rt.Block {
	public final dev:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final mode:ml2hx.std.Luv__File_Mode.LuvFileModeNumeric;
	public final nlink:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final uid:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final gid:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final rdev:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final ino:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final size:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final blksize:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final blocks:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final flags:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final gen:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T;
	public final atim:LuvFileStatTimespec;
	public final mtim:LuvFileStatTimespec;
	public final ctim:LuvFileStatTimespec;
	public final birthtim:LuvFileStatTimespec;
	public function new(dev:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, mode:ml2hx.std.Luv__File_Mode.LuvFileModeNumeric, nlink:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, uid:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, gid:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, rdev:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, ino:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, size:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, blksize:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, blocks:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, flags:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, gen:ml2hx.std.Unsigned_UInt64.UnsignedUInt64T, atim:LuvFileStatTimespec, mtim:LuvFileStatTimespec, ctim:LuvFileStatTimespec, birthtim:LuvFileStatTimespec) {
		this.dev = dev;
		this.mode = mode;
		this.nlink = nlink;
		this.uid = uid;
		this.gid = gid;
		this.rdev = rdev;
		this.ino = ino;
		this.size = size;
		this.blksize = blksize;
		this.blocks = blocks;
		this.flags = flags;
		this.gen = gen;
		this.atim = atim;
		this.mtim = mtim;
		this.ctim = ctim;
		this.birthtim = birthtim;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 16;
	public function blockField(i:Int):Dynamic return ([dev, mode, nlink, uid, gid, rdev, ino, size, blksize, blocks, flags, gen, atim, mtim, ctim, birthtim] : Array<Dynamic>)[i];
}

class LuvFileStatTimespec implements ml2hx.rt.Block {
	public final sec:ml2hx.std.Signed_Long.SignedLongT;
	public final nsec:ml2hx.std.Signed_Long.SignedLongT;
	public function new(sec:ml2hx.std.Signed_Long.SignedLongT, nsec:ml2hx.std.Signed_Long.SignedLongT) {
		this.sec = sec;
		this.nsec = nsec;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 2;
	public function blockField(i:Int):Dynamic return ([sec, nsec] : Array<Dynamic>)[i];
}

class Luv__File_Stat {}
