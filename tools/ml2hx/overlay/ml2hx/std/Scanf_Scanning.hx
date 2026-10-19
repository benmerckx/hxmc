package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Scanf.Scanning: a character source with one character of lookahead.
class ScanfScanningInChannel {
	final next:Void->Int; // -1 at end
	var peeked = -2;
	public function new(next:Void->Int) this.next = next;
	public function peek():Int {
		if (peeked == -2) peeked = next();
		return peeked;
	}
	public function take():Int {
		var c = peek();
		peeked = -2;
		return c;
	}
}

class Scanf_Scanning {
	public static function fromString(s:String):ScanfScanningInChannel {
		var i = 0;
		return new ScanfScanningInChannel(() -> i < s.length ? StringTools.fastCodeAt(s, i++) : -1);
	}
	public static function fromFunction(f:Unit->Int):ScanfScanningInChannel
		return new ScanfScanningInChannel(() -> try f(Unit.value) catch (e:EndOfFile) -1);
}
