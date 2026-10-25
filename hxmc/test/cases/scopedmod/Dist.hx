package scopedmod;

import hxmc.scoped.*;

@:hxmc.scoped class Dist {
	public static function sq(x:Int):Int
		return x * x;
}

// a module-level function: scoped, as the module's own type is
function total(n:Int):Int {
	var g = new Grow<Int>();
	for (i in 0...n)
		g.push(Dist.sq(i));
	var t = 0;
	for (v in g)
		t += v;
	return t;
}
