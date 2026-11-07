// Published strings keep their contents and cached hashes after the
// buffer is extended, cleared, widened, grown and collected.
class StringBufSnapshot {
	static function equal(a:String, b:String) {
		if (a != b) throw 'snapshot changed: $a != $b';
	}

	static function main() {
		var b = new StringBuf();
		equal(b.toString(), "");
		b.add("before");
		var first = b.toString();
		var hashes = new Map<String, Int>();
		hashes.set(first, 1);
		for (_ in 0...10) equal(b.toString(), "before");
		b.addChar("!".code);
		equal(first, "before");
		equal(b.toString(), "before!");
		b.clear();
		b.addChar("x".code);
		equal(first, "before");
		equal(b.toString(), "x");
		b.addChar(0x100);
		var wide = b.toString();
		b.addChar(0x1F600);
		equal(wide, "x\u0100");
		equal(b.toString(), "x\u0100😀");
		b.clear();
		b.add("narrow");
		var narrow = b.toString();
		b.addSub(first, 0, 3);
		equal(narrow, "narrow");
		equal(b.toString(), "narrowbef");
		if (hashes.get(first) != 1 || hashes.get("before") != 1) throw "snapshot hash changed";
		var large = new StringBuf();
		for (_ in 0...8192) large.addChar("a".code);
		var oldLarge = large.toString();
		large.clear();
		large.add("tiny");
		var tiny = large.toString();
		large.addChar("!".code);
		equal(tiny, "tiny");
		equal(large.toString(), "tiny!");
		if (oldLarge.length != 8192 || oldLarge.charCodeAt(8191) != "a".code) throw "large snapshot changed";
		var saved = [];
		for (i in 0...2000) {
			var s = new StringBuf();
			for (_ in 0...64) s.add(i);
			saved.push(s.toString());
			s.clear();
			s.addChar(0x100);
		}
		hxmc.NativeGc.collect(true);
		for (i in 0...saved.length) {
			var expected = new StringBuf();
			for (_ in 0...64) expected.add(i);
			equal(saved[i], expected.toString());
		}
		Sys.println("ok");
	}
}
