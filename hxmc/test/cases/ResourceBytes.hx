// resource: ResourceBytes.bin@bin
// resource: Resources.txt@text
// resource: ResourceBytes.empty@empty
// haxe.Resource over the program's read-only data (hxmc.NativeResource,
// DataGen.resources): binary bytes (zeros, bytes from 0x80) as they are,
// UTF-8 text decoded, an empty resource, the names in the order of the
// other targets, a missing name; getBytes gives a copy, which writes do not
// reach the data. (Not one added by a macro, Context.addResource: the corpus
// compiles the case from its HXB archive, which does not carry resources.)
class ResourceBytes {
	static function main() {
		Sys.println(haxe.Resource.listNames());
		var names = haxe.Resource.listNames();
		names.sort(Reflect.compare);
		Sys.println(names);
		// (a new array each call)
		names.push("x");
		Sys.println(haxe.Resource.listNames().length);

		var b = haxe.Resource.getBytes("bin");
		Sys.println(b.length + " " + b.toHex());
		var sum = 0;
		for (i in 0...b.length)
			sum += b.get(i);
		Sys.println("sum " + sum);
		// a copy: writing it changes neither the data nor a later copy
		b.set(0, 0x5A);
		b.fill(1, 4, 0xEE);
		var c = haxe.Resource.getBytes("bin");
		Sys.println(b.toHex().substr(0, 12) + " " + c.toHex().substr(0, 12) + " " + (b != c) + " " + (b.compare(c) != 0));

		var s = haxe.Resource.getString("text");
		Sys.println(s);
		Sys.println(s.length + " " + haxe.Resource.getBytes("text").length);
		Sys.println(s == haxe.Resource.getBytes("text").toString());
		// (the text of bytes that are not UTF-8: as Bytes.toString makes it)
		Sys.println(haxe.Resource.getString("bin") == haxe.Resource.getBytes("bin").toString());

		var e = haxe.Resource.getBytes("empty");
		Sys.println(e.length + " [" + haxe.Resource.getString("empty") + "] " + (haxe.Resource.getString("empty") == ""));
		var e2 = haxe.Resource.getBytes("empty");
		Sys.println(e2.length);

		Sys.println(haxe.Resource.getString("missing") + " " + haxe.Resource.getBytes("missing") + " " + haxe.Resource.getBytes("") + " "
			+ haxe.Resource.getString("Bin"));
	}
}
