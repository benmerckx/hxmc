// String concatenation in a loop (`s += x`), then the result split and
// read unit by unit: a downstream frontend's benchmark (Node
// runs it in about 20 ms at 300000 words). Not a corpus case (times vary);
// built and run by hand, natively or as a module:
//   bin/hxmc/hxmc -cp hxmc/test/micro -main StrConcatBench -cp bin/hxmc/std --custom-target hxmc=bin/strconcat
//   bin/strconcat [words] [kind]    (default 300000 words, kind loop)
// kind: loop (only appends in the loop: FnLower.appendLoop's StringBuf), read
// (the loop reads the string, s.length in its condition: each append a
// concatenation, a new string of the whole length; 30000 words there).
// x86-64, ms (concat; split and read): before the appends to a StringBuf
// (FnLower.appendLoop) 40552; 12, after 5; 14. wasm32-wasi under node, 30000
// words: 368; 9 -> 6; 6, and 300000 after: 20; 65. read, 30000 words, before
// raw allocations went unzeroed (Gc.allocSlowRaw) -> after: x86-64 255 -> 210,
// wasm 278 -> 218.
class StrConcatBench {
	static function words(n:Int):String {
		var s = "";
		for (i in 0...n)
			s += i % 7 == 0 ? "lorem " : "ipsum ";
		return s;
	}

	static function wordsRead(n:Int):String {
		var s = "";
		var i = 0;
		while (s.length < 6 * n) {
			s += i % 7 == 0 ? "lorem " : "ipsum ";
			i++;
		}
		return s;
	}

	static function main() {
		var args = Sys.args();
		var read = args.length > 1 && args[1] == "read";
		var n = args.length > 0 ? Std.parseInt(args[0]) : read ? 30000 : 300000;
		var t0 = Sys.time();
		var text = read ? wordsRead(n) : words(n);
		var t1 = Sys.time();
		var count = 0, letters = 0;
		for (w in text.split(" "))
			if (w.length > 0) {
				count++;
				letters += w.length;
			}
		var codes = 0;
		for (i in 0...text.length)
			codes += StringTools.fastCodeAt(text, i);
		var t2 = Sys.time();
		Sys.println(count + " " + letters + " " + codes);
		Sys.println("concat " + Math.round((t1 - t0) * 1e4) / 10 + " ms, split and read " + Math.round((t2 - t1) * 1e4) / 10 + " ms");
	}
}
