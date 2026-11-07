// define: hxmc.checked
// define: hxmc.native-array-outofbounds=silent
// define: hxmc.null-checks=0
// define: hxmc.span-checks=0
// The checked profile wins over narrower switches that disable checks.
class CheckedBuild {
	public static function main() {
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
		var d:Dynamic = a;
		try {
			var x = d[2];
			Sys.println('unexpected dynamic read $x');
		} catch (_:haxe.exceptions.ArgumentException) caught++;
		try d[2] = 0 catch (_:haxe.exceptions.ArgumentException) caught++;
		try hxmc.NativeArray.blit(a, 1, a, 0, 2) catch (_:haxe.exceptions.ArgumentException) caught++;
		if (caught != 9) throw "library checks disabled";
		Sys.println("ok");
	}
}
