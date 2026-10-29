import sys.io.File;

using StringTools;

// What a function body asks the lowering (hxmc/src/hxmc/ir/LowerQueries.hx)
// is covered by the compilation server's reuse of bodies (LowerCache.hx):
// every query is tagged with how (@:logged, @:derived, @:declared, @:pure),
// each @:logged one is overridden in LowerCache.hx (it records the query and
// replays it), and no other is (the tag would not say what the cache does).
// Each recorded call (LowerCache's LCall) and each construct of the IR (Ir's
// Stmt, Ex, Ty, RefTy, TypeRef) is written by the store's codec
// (LoweredBodies.hx), which reads them back by their order.
// A query added without a thought for the cache fails here (`make quick`).
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run LowerQueriesCheck
class LowerQueriesCheck {
	static final TAGS = ["logged", "derived", "declared", "pure"];

	static function main() {
		var queries = File.getContent("hxmc/src/hxmc/ir/LowerQueries.hx");
		var cache = File.getContent("hxmc/src/hxmc/LowerCache.hx");
		var start = queries.indexOf("interface LowerQueries");
		var end = queries.indexOf("\n}", start);
		if (start < 0 || end < 0) fail("no interface LowerQueries");
		var failures = [];
		var n = 0;
		var fn = ~/^\s*(?:@:(\w+)\s+)?function\s+(\w+)\s*\(/;
		for (line in queries.substring(start, end).split("\n")) {
			if (!fn.match(line)) continue;
			n++;
			var tag = fn.matched(1), name = fn.matched(2);
			if (tag == null || !TAGS.contains(tag)) {
				failures.push('$name: no tag (${TAGS.map(t -> "@:" + t).join(", ")})');
				continue;
			}
			var overridden = cache.indexOf("override public function " + name + "(") >= 0;
			if (tag == "logged" && !overridden) failures.push('$name: @:logged, not overridden in LowerCache.hx');
			if (tag != "logged" && overridden) failures.push('$name: @:$tag, but overridden in LowerCache.hx (@:logged?)');
		}
		if (n == 0) failures.push("no queries found");
		// (the codec: each constructor written, by name; read back by its index)
		var codec = File.getContent("hxmc/src/hxmc/LoweredBodies.hx");
		var ir = File.getContent("hxmc/src/hxmc/ir/Ir.hx");
		function ctors(src:String, name:String):Array<String> {
			var s = src.indexOf("enum " + name + " {");
			if (s < 0) {
				failures.push('no enum $name');
				return [];
			}
			var e = src.indexOf("\n}", s);
			var re = ~/^\t([A-Z]\w*)\b/;
			return [for (l in src.substring(s, e).split("\n")) if (re.match(l)) re.matched(1)];
		}
		var nc = 0;
		for (en in [{src: cache, name: "LCall"}, {src: ir, name: "Stmt"}, {src: ir, name: "Ex"}, {src: ir, name: "Ty"}, {src: ir, name: "RefTy"}, {src: ir, name: "TypeRef"}])
			for (c in ctors(en.src, en.name)) {
				nc++;
				if (!new EReg("case [^:]*\\b" + c + "\\b", "").match(codec)) failures.push('${en.name}.$c: not written by LoweredBodies.hx');
			}
		for (f in failures)
			Sys.println("FAIL  " + f);
		Sys.println(failures.length == 0 ? 'lower queries: $n, each covered; $nc constructors written by the store' : 'lower queries: ${failures.length} not covered');
		Sys.exit(failures.length == 0 ? 0 : 1);
	}

	static function fail(msg:String) {
		Sys.println("FAIL  " + msg);
		Sys.exit(1);
	}
}
