// Std.string of values that contain themselves (upstream's unit test
// Issue7903): the recursion overflowed the stack (SIGSEGV). Arrays, enum
// values and structures deeper than 5 print as <...>, as on Eval and
// JavaScript; a toString (a Map's) starts again.
enum R {
	Node(children:Array<R>);
	Leaf;
}

class PrintDepth {
	static function main() {
		var a:Array<Dynamic> = [];
		a.push(a);
		Sys.println(Std.string(a));
		var kids = [Leaf];
		var n = Node(kids);
		kids.push(n);
		Sys.println(Std.string(n));
		Sys.println(Std.string([[[[[[[[[[1, 2]]]]]]]]]]));
		Sys.println(Std.string([[[[[1, 2]]]]]));
		Sys.println(Std.string([haxe.ds.Option.Some([haxe.ds.Option.Some([haxe.ds.Option.Some([haxe.ds.Option.Some([1])])])])]));
		var m:Map<String, Dynamic> = ["a" => [[[[[[["b"]]]]]]]];
		Sys.println(Std.string(m));
	}
}
