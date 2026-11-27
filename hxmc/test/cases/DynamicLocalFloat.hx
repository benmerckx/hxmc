class DynamicLocalFloat {
	static function isNumber(v:Dynamic):Bool
		return Std.isOfType(v, Float);

	static function viaLocal(a0:Dynamic):Bool {
		var v = a0;
		return isNumber(v) && Math.isFinite(v) && Math.ffloor(v) == v;
	}

	static function direct(a0:Dynamic):Bool
		return isNumber(a0) && Math.isFinite(a0) && Math.ffloor(a0) == a0;

	static function main() {
		var s:Dynamic = "a";
		Sys.println(viaLocal(s) + " " + direct(s) + " " + isNumber(s) + " " + viaLocal(2.0) + " " + viaLocal(2.5));
	}
}
