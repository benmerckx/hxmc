package ml2hx.prim;

import ml2hx.rt.*;

// An ephemeron (Obj.Ephemeron, Weak arrays): keys and data. The host's
// collector does not report reachability to OCaml code, so no key is ever
// found dead; OCaml allows that (a key goes only after a collection finds it
// unreachable).
class Ephemeron {
	public final keys:Array<Dynamic>;
	public final set:Array<Bool>;
	public var data:Dynamic = null;
	public var hasData = false;
	public function new(n:Int) {
		keys = [for (_ in 0...n) null];
		set = [for (_ in 0...n) false];
	}
}

typedef WeakT<T> = Ephemeron;

class Weak {
	static inline var MAX = 0x7FFFFF;
	static function check(e:Ephemeron, i:Int63, what:String):Int {
		if (Int63.lt(i, Int63.zero) || Int63.ge(i, Int63.ofInt(e.keys.length))) throw new InvalidArgument(what);
		return i.toInt();
	}
	public static function camlEpheCreate(n:Int63):Ephemeron {
		if (Int63.lt(n, Int63.zero) || Int63.gt(n, Int63.ofInt(MAX))) throw new InvalidArgument("Obj.Ephemeron.create");
		return new Ephemeron(n.toInt());
	}
	public static function camlWeakCreate(n:Int63):Ephemeron {
		if (Int63.lt(n, Int63.zero) || Int63.gt(n, Int63.ofInt(MAX))) throw new InvalidArgument("Weak.create");
		return new Ephemeron(n.toInt());
	}
	public static function camlEpheGetKey(e:Ephemeron, i:Int63):MlOption<Dynamic> {
		var k = check(e, i, "Obj.Ephemeron.get_key");
		return e.set[k] ? Some(e.keys[k]) : None;
	}
	public static function camlEpheGetKeyCopy(e:Ephemeron, i:Int63):MlOption<Dynamic> return camlEpheGetKey(e, i);
	public static function camlWeakGet(e:Ephemeron, i:Int63):MlOption<Dynamic> {
		var k = check(e, i, "Weak.get");
		return e.set[k] ? Some(e.keys[k]) : None;
	}
	public static function camlWeakGetCopy(e:Ephemeron, i:Int63):MlOption<Dynamic> return camlWeakGet(e, i);
	public static function camlEpheSetKey(e:Ephemeron, i:Int63, v:Dynamic):Unit {
		var k = check(e, i, "Obj.Ephemeron.set_key");
		e.keys[k] = v;
		e.set[k] = true;
		return Unit.value;
	}
	public static function camlEpheUnsetKey(e:Ephemeron, i:Int63):Unit {
		var k = check(e, i, "Obj.Ephemeron.unset_key");
		e.keys[k] = null;
		e.set[k] = false;
		return Unit.value;
	}
	public static function camlEpheCheckKey(e:Ephemeron, i:Int63):Bool return e.set[check(e, i, "Obj.Ephemeron.check_key")];
	public static function camlWeakCheck(e:Ephemeron, i:Int63):Bool return e.set[check(e, i, "Weak.check")];
	public static function camlEpheBlitKey(a:Ephemeron, ai:Int63, b:Ephemeron, bi:Int63, n:Int63):Unit {
		var x = ai.toInt(), y = bi.toInt(), len = n.toInt();
		var ks = a.keys.slice(x, x + len), ss = a.set.slice(x, x + len);
		for (k in 0...len) {
			b.keys[y + k] = ks[k];
			b.set[y + k] = ss[k];
		}
		return Unit.value;
	}
	public static function camlWeakBlit(a:Ephemeron, ai:Int63, b:Ephemeron, bi:Int63, n:Int63):Unit return camlEpheBlitKey(a, ai, b, bi, n);
	public static function camlEpheGetData(e:Ephemeron):MlOption<Dynamic> return e.hasData ? Some(e.data) : None;
	public static function camlEpheGetDataCopy(e:Ephemeron):MlOption<Dynamic> return camlEpheGetData(e);
	public static function camlEpheSetData(e:Ephemeron, v:Dynamic):Unit {
		e.data = v;
		e.hasData = true;
		return Unit.value;
	}
	public static function camlEpheUnsetData(e:Ephemeron):Unit {
		e.data = null;
		e.hasData = false;
		return Unit.value;
	}
	public static function camlEpheCheckData(e:Ephemeron):Bool return e.hasData;
	public static function camlEpheBlitData(a:Ephemeron, b:Ephemeron):Unit {
		b.data = a.data;
		b.hasData = a.hasData;
		return Unit.value;
	}
}
