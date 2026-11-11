import haxe.io.Bytes;
import hxmc.Span;
import hxmc.rt.Text;
import hxmc.unsafe.UInt8;

// The runtime's reports for kernels over spans (hxmc.rt.Text): a line built
// in a span, each function returning where it goes on, what passes the end
// left out; then to stderr and the end of the program (Text.fatal: exit 3).
class KernelText {
	@:hxmc.kernel static function line(b:Span<UInt8>, v:Int):Int {
		var n = Text.lit(b, 0, "v=");
		n = Text.int(b, n, v, 6);
		n = Text.ch(b, n, ";".code);
		return Text.lit(b, n, " é€");
	}

	@:hxmc.kernel static function die(v:Int) {
		var b:Span<UInt8> = Span.stack(64);
		Text.fatal(b, Text.int(b, Text.lit(b, 0, "KernelText: the end "), v, 0), 3);
	}

	static function main() {
		var b = Bytes.alloc(20);
		var n = line(Span.ofBytes(b), -1234);
		trace(n, b.sub(0, 10).toString(), b.get(10), b.get(11));
		var small = Bytes.alloc(5);
		trace(line(Span.ofBytes(small), 42), small.toString());
		die(7);
		trace("not here");
	}
}
