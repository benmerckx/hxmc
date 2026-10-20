package unit.strings;

// Eval's strings by character index (charCodeAt, charAt, substr, substring,
// indexOf, lastIndexOf, StringBuf.addSub) in random order over ASCII, BMP and
// astral text: the offset cache (evalString.ml's get_offset) steps forward,
// backward and far, with one pointer and two.
class StringOffsets {
	static var seed = 12345;

	static function rand(n:Int):Int {
		seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
		return (seed >> 8) % n;
	}

	static function main() {
		var pieces = ["a", "bc", "é", "日本", "\u{1F600}", "\u{10000}x", " ", "\u{1F680}\u{1F681}"];
		for (round in 0...6) {
			var b = new StringBuf();
			for (i in 0...20 + rand(60)) b.add(pieces[rand(pieces.length)]);
			var s = b.toString();
			var out:Array<Dynamic> = [];
			for (step in 0...200) {
				var i = rand(s.length + 4) - 2;
				switch rand(8) {
					case 0: out.push(s.charCodeAt(i));
					case 1: out.push(s.charAt(i));
					case 2: out.push(s.substr(i, rand(8) - 2));
					case 3: out.push(s.substring(i, rand(s.length + 2)));
					case 4: out.push(s.indexOf(pieces[rand(pieces.length)], i));
					case 5: out.push(s.lastIndexOf(pieces[rand(pieces.length)], i));
					case 6:
						var sb = new StringBuf();
						var pos = i < 0 ? 0 : i > s.length ? s.length : i;
						var len = rand(6);
						sb.addSub(s, pos, pos + len > s.length ? s.length - pos : len);
						out.push(sb.toString());
					case _: out.push(StringTools.fastCodeAt(s, i < 0 ? 0 : i >= s.length ? s.length - 1 : i));
				}
				// sequential runs, forward and backward
				if (step % 50 == 0) {
					var acc = 0;
					for (k in 0...s.length) acc += s.charCodeAt(k);
					var k = s.length;
					while (k-- > 0) acc -= s.charCodeAt(k) >> 1;
					out.push(acc);
				}
			}
			Sys.println(s.length + ": " + out.join("|"));
		}
	}
}
