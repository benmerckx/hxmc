// What EReg and Bytes throw (upstream's unit tests TestEReg, TestIO): a
// match read before any match threw nothing (matched gave null); a Bytes
// range out of bounds threw the String "OutsideBounds" instead of
// haxe.io.Error.OutsideBounds.
class ErrorValues {
	static function main() {
		var r = ~/a/;
		try {
			Sys.println(r.matched(0));
		} catch (e:Dynamic) Sys.println("matched: " + e);
		try {
			Sys.println(r.matchedLeft());
		} catch (e:Dynamic) Sys.println("left: " + e);
		try {
			Sys.println(r.matchedPos());
		} catch (e:Dynamic) Sys.println("pos: " + e);
		r.match("xyz");
		try {
			Sys.println(r.matched(0));
		} catch (e:Dynamic) Sys.println("matched after a failed match: " + e);
		var o = new haxe.io.BytesOutput();
		try {
			o.writeBytes(haxe.io.Bytes.alloc(4), -1, 5);
		} catch (e:Dynamic) Sys.println(Std.isOfType(e, haxe.io.Error) + " " + e);
		try {
			haxe.io.Bytes.alloc(4).blit(0, haxe.io.Bytes.alloc(2), 0, 4);
		} catch (e:Dynamic) Sys.println(Std.isOfType(e, haxe.io.Error) + " " + e);
		try {
			haxe.io.Bytes.alloc(4).sub(2, 4);
		} catch (e:Dynamic) Sys.println(Std.isOfType(e, haxe.io.Error) + " " + e);
		try {
			haxe.io.Bytes.alloc(4).getString(2, 4);
		} catch (e:Dynamic) Sys.println(Std.isOfType(e, haxe.io.Error) + " " + e);
	}
}
