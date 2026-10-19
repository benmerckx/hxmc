// hxmc: haxe/upstream/std/sys/io/FileInput.hx, a file descriptor read through
// hxmc.NativeSys

package sys.io;

import hxmc.NativeSys;

/**
	Use `sys.io.File.read` to create a `FileInput`.
**/
class FileInput extends haxe.io.Input {
	var fd:Int;
	var atEof = false;
	var one:haxe.io.Bytes;

	function new(fd:Int) {
		this.fd = fd;
	}

	override public function readByte():Int {
		if (one == null) one = haxe.io.Bytes.alloc(1);
		readBytes(one, 0, 1);
		return one.get(0);
	}

	override public function readBytes(b:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (len == 0) return 0;
		if (fd < 0) throw haxe.io.Error.Custom("read error"); // (closed: as EBADF)
		var n = NativeSys.fileRead(fd, b, pos, len);
		if (n == 0) {
			atEof = true;
			throw new haxe.io.Eof();
		}
		if (n < 0) throw haxe.io.Error.Custom("read error");
		return n;
	}

	// once: a second close would close whatever descriptor reused the number
	// meanwhile (another file, a pipe another thread reads); upstream's
	// channels close once too
	override public function close():Void {
		var f = fd;
		if (f < 0) return;
		fd = -1;
		NativeSys.fileClose(f);
	}

	public function seek(p:Int, pos:FileSeek):Void {
		atEof = false;
		NativeSys.fileSeek(fd, p, switch pos {
			case SeekBegin: 0;
			case SeekCur: 1;
			case SeekEnd: 2;
		});
	}

	public function tell():Int
		return NativeSys.fileTell(fd);

	public function eof():Bool
		return atEof;
}
