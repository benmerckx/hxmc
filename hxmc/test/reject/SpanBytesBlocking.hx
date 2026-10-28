// A Bytes is lent only to a kernel that never enters a safe region: in one, another thread's collection moves it.
// expect: SpanBytesBlocking.main: a span over a Bytes is passed to SpanBytesBlocking.sum, which lets other threads collect (a safe region) while the Bytes may move (kernel: a Bytes is lent only to a kernel that enters no region; lend an IoBuffer's instead)
import hxmc.ReadOnlySpan;
import hxmc.unsafe.UInt8;

class SpanBytesBlocking {
	@:hxmc.blocking static function sum(s:ReadOnlySpan<UInt8>):Int {
		var t = 0;
		for (i in 0...s.length)
			t += s[i];
		return t;
	}

	static function main() {
		var b = haxe.io.Bytes.ofString("abc");
		trace(sum(ReadOnlySpan.ofBytes(b)));
	}
}
