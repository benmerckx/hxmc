// hxmc: haxe/upstream/std/haxe/io/BytesInput.hx's other targets' branch, over
// the BytesData's NativeArray indexing (not tested: the range is), with the
// constructor's test of the range written so that it cannot wrap (upstream's
// pos + len > b.length passes for a pos near 2^31, and the reads then are
// outside the bytes), and readBytes as one copy (hxmc.NativeBytes.blit)

package haxe.io;

class BytesInput extends Input {
	var b:BytesData;
	var pos:Int;
	var len:Int;
	var totlen:Int;

	/** The current position in the stream in bytes. */
	public var position(get, set):Int;

	/** The length of the stream in bytes. */
	public var length(get, never):Int;

	public function new(b:Bytes, ?pos:Int, ?len:Int) {
		if (pos == null)
			pos = 0;
		if (len == null)
			len = b.length - pos;
		if (pos < 0 || len < 0 || pos > b.length - len)
			throw Error.OutsideBounds;
		this.b = b.getData();
		this.pos = pos;
		this.len = len;
		this.totlen = len;
	}

	inline function get_position():Int {
		return pos;
	}

	inline function get_length():Int {
		return totlen;
	}

	function set_position(p:Int):Int {
		if (p < 0)
			p = 0;
		else if (p > length)
			p = length;
		len = totlen - p;
		return pos = p;
	}

	public override function readByte():Int {
		if (this.len == 0)
			throw new Eof();
		len--;
		return b.unsafeGet(pos++);
	}

	public override function readBytes(buf:Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || pos > buf.length - len)
			throw Error.OutsideBounds;
		if (this.len == 0 && len > 0)
			throw new Eof();
		if (this.len < len)
			len = this.len;
		hxmc.NativeBytes.blit(buf.getData(), pos, b, this.pos, len);
		this.pos += len;
		this.len -= len;
		return len;
	}
}
