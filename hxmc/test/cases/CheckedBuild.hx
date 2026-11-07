// define: hxmc.checked
// define: hxmc.native-array-outofbounds=silent
// define: hxmc.null-checks=0
// define: hxmc.span-checks=0
// The checked profile wins over narrower switches that disable checks.
class CheckedBuild {
	static function main() {
		var a = new hxmc.NativeArray<Int>(2);
		a[0] = 17;
		a[1] = 23;
		var caught = 0;
		for (i in [-1, 2, 0x7FFFFFFF]) {
			try {
				var x = a[i];
				Sys.println('unexpected read $x');
			} catch (_:haxe.exceptions.ArgumentException) caught++;
			try a[i] = 0 catch (_:haxe.exceptions.ArgumentException) caught++;
		}
		if (caught != 6 || a[0] != 17 || a[1] != 23) throw "bounds checks disabled";
		Sys.println("ok");
	}
}
