import hxmc.scoped.*;
import hxmc.unsafe.UInt16;

// Goose's bench/goose/strlist.goose: a list of strings. A text of random
// words (3 to 20 letters) built, split into a list, the list scanned four
// times. Scoped: the text in a Grow of code units, the words views of it;
// GC: a StringBuf, String.split, an Array of Strings.
//   StrList scoped|gc [n]
@:hxmc.scoped class Scoped {
	public static function run(n:Int, out:Grow<Int>) {
		var text = new Grow<UInt16>();
		var r = 12345;
		for (i in 0...n) {
			r ^= r << 13;
			r ^= r >>> 17;
			r ^= r << 5;
			var wl = 3 + (r >>> 1) % 18;
			for (j in 0...wl) {
				r ^= r << 13;
				r ^= r >>> 17;
				r ^= r << 5;
				var c = "a".code + (r >>> 1) % 26; // (an Int: UInt16's arithmetic would wrap first)
				text.push(c);
			}
			text.push(" ".code);
		}
		var all = new Str(text.slice().ptr(), text.length);
		var words = new Grow<Str>();
		var start = 0;
		for (i in 0...all.length)
			if (all[i] == " ".code) {
				if (i > start) words.push(all.sub(start, i - start));
				start = i + 1;
			}
		var total = 0;
		for (p in 0...4)
			for (w in words)
				total += w.length + w[0] + w[w.length - 1];
		out.push(words.length);
		out.push(total);
	}
}

class Gc {
	public static function run(n:Int, out:Array<Int>) {
		var b = new StringBuf();
		var r = 12345;
		for (i in 0...n) {
			r ^= r << 13;
			r ^= r >>> 17;
			r ^= r << 5;
			var wl = 3 + (r >>> 1) % 18;
			for (j in 0...wl) {
				r ^= r << 13;
				r ^= r >>> 17;
				r ^= r << 5;
				b.addChar("a".code + (r >>> 1) % 26);
			}
			b.addChar(" ".code);
		}
		var words = [for (w in b.toString().split(" ")) if (w.length > 0) w];
		var total = 0;
		for (p in 0...4)
			for (w in words)
				total += w.length + StringTools.fastCodeAt(w, 0) + StringTools.fastCodeAt(w, w.length - 1);
		out.push(words.length);
		out.push(total);
	}
}

class StrList {
	static function main() {
		var args = Sys.args();
		var n = args.length > 1 ? Std.parseInt(args[1]) : 400000;
		if (args[0] == "gc") {
			var out = [];
			Gc.run(n, out);
			for (x in out)
				Sys.println(x);
		} else {
			var out = new Grow<Int>();
			Scoped.run(n, out);
			for (x in out)
				Sys.println(x);
		}
	}
}
