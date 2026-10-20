// The smallest iOS app (make ios-check, ios-sim-check): no UIKit, the
// program's main run by hxmc's generated main as on any other target; it
// prints a line and returns, and the process ends.
class IosHello {
	static function main() {
		// (the collector, a map, an exception: the runtime at work)
		var squares = [for (i in 0...1000) Std.string(i * i)];
		var m = new Map<String, Int>();
		for (s in squares) m[s] = s.length;
		var caught = try {
			throw "boom";
		} catch (e:String) e;
		Sys.println('hello from hxmc on ' + Sys.systemName() + ': ' + squares[999] + ' ' + m["998001"] + ' ' + caught);
	}
}
