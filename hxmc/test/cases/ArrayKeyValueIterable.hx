// An Array as a KeyValueIterable (a structure): its keyValueIterator was not
// in Array's method table, and the call threw "Cannot call null" (upstream's
// unit test TestArray); through Dynamic, keyValueIterator and resize.
class ArrayKeyValueIterable {
	static function main() {
		var a:Array<Int> = [1, 2, 3, 5, 8];
		var it:KeyValueIterable<Int, Int> = a;
		Sys.println([for (k => v in it) k * v]);
		var s:KeyValueIterable<Int, String> = ["a", "b"];
		Sys.println([for (k => v in s) v + k]);
		var d:Dynamic = a;
		var kv:KeyValueIterator<Int, Int> = d.keyValueIterator();
		Sys.println([for (k => v in kv) k + v]);
		d.resize(2);
		Sys.println(a);
	}
}
