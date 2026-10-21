// Classes extending StringBuf, the runtime's extern class (upstream's
// unit.issues.Issue6446): the subclass starts with T_STRINGBUF's layout
// (Lower.classInfo), its super() fills it (Str.sbInit), and the inherited
// methods, the inline addChar included, work on it; fields of its own, a
// subclass of the subclass, one without a constructor of its own, one made
// by Type.createInstance, and the hidden slots out of reflection's sight.
// The output is the reference's (--interp).
class Tagged extends StringBuf {
	public var tag:String;
	public var count:Int;

	public function new(tag:String) {
		super();
		this.tag = tag;
		count = 0;
	}

	public function line(s:String) {
		count++;
		add(tag);
		add(": ");
		add(s);
		addChar("\n".code);
	}
}

class Deeper extends Tagged {
	public var level = 2;

	public function new() {
		super("deep");
	}
}

class Plain extends StringBuf {}

class StringBufSubclass {
	static function main() {
		var t = new Tagged("a");
		t.line("one");
		t.line("two");
		for (i in 0...300)
			t.addChar("x".code + i % 3);
		t.addSub("hello world", 6, 3);
		t.add(42);
		t.add(1.5);
		t.add([1, 2]);
		var s = t.toString();
		trace(s.length);
		trace(s.substr(0, 20));
		trace(s.substr(s.length - 12));
		trace(t.length + " " + t.count + " " + t.tag);
		var d = new Deeper();
		d.line("x");
		d.addChar(0xE9);
		trace(d.toString().length + " " + d.level + " " + d.count);
		var p = new Plain();
		p.add(" custom");
		trace(p.toString());
		p.clear();
		p.add("again");
		trace(p.toString() + " " + p.length);
		var buf:StringBuf = new Tagged("b");
		buf.add("through StringBuf");
		trace(buf.toString());
		var c = Type.createInstance(Tagged, ["made"]);
		c.line("by createInstance");
		trace(c.toString());
		var fs = Type.getInstanceFields(Tagged).filter(f -> f == "tag" || f == "count" || f.charAt(0) == "#");
		fs.sort(Reflect.compare);
		trace(fs);
		trace(Reflect.fields(t).filter(f -> f.charAt(0) == "#").length);
		var many = [for (i in 0...2000) new Tagged("t" + i)];
		for (i in 0...2000)
			many[i].line("" + i);
		var ok = true;
		for (i in 0...2000)
			if (many[i].toString() != "t" + i + ": " + i + "\n") ok = false;
		trace(ok);
	}
}
