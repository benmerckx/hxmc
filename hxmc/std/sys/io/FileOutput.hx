// hxmc: haxe/upstream/std/sys/io/FileOutput.hx, a file descriptor written through
// hxmc.NativeSys

package sys.io;

import hxmc.NativeSys;

/**
	Use `sys.io.File.write` to create a `FileOutput`.
**/
class FileOutput extends haxe.io.Output {
	var fd:Int;
	var one:haxe.io.Bytes;

	function new(fd:Int) {
		this.fd = fd;
	}

	override public function writeByte(c:Int):Void {
		if (one == null) one = haxe.io.Bytes.alloc(1);
		one.set(0, c);
		writeBytes(one, 0, 1);
	}

	override public function writeBytes(b:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (fd < 0) throw haxe.io.Error.Custom("write error"); // (closed: as EBADF)
		var n = NativeSys.fileWrite(fd, b, pos, len);
		if (n < 0) throw haxe.io.Error.Custom("write error");
		return n;
	}

	override public function flush():Void
		NativeSys.fileFlush(fd);

	// once: a second close would close whatever descriptor reused the number
	// meanwhile (another file, a pipe another thread reads); upstream's
	// channels close once too
	override public function close():Void {
		var f = fd;
		if (f < 0) return;
		fd = -1;
		NativeSys.fileClose(f);
	}

	public function seek(p:Int, pos:FileSeek):Void
		NativeSys.fileSeek(fd, p, switch pos {
			case SeekBegin: 0;
			case SeekCur: 1;
			case SeekEnd: 2;
		});

	public function tell():Int
		return NativeSys.fileTell(fd);
}
