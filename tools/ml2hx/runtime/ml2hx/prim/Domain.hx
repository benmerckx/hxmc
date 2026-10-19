package ml2hx.prim;

import ml2hx.rt.*;
import ocaml.stdlib.DomainModule.DomainRawTermSync;
import ocaml.stdlib.DomainModule.DomainRawState;
import ocaml.stdlib.StdlibModule.StdlibResult;

// OCaml's domain.c and sync.c on one thread: a spawned domain runs to
// completion when spawned (with its own domain-local state); locking a
// locked mutex, or waiting on a condition, could never return.
class Domain {
	static var current = 0;
	static var nextId = 1;

	public static function camlDomainSpawn<T>(body:Unit->T, sync:DomainRawTermSync<T>):Int63 {
		var id = nextId++;
		var saved = Builtin.dls, savedId = current;
		current = id;
		try {
			var r = body(Unit.value);
			sync.state = DomainRawState.Finished(StdlibResult.Ok(r));
		} catch (e:haxe.Exception) {
			sync.state = DomainRawState.Finished(StdlibResult.Error(MlException.wrap(e)));
		}
		Builtin.dls = saved;
		current = savedId;
		return Int63.ofInt(id);
	}
	public static function camlMlDomainId(_:Unit):Int63 return Int63.ofInt(current);
	public static function camlMlDomainIndex(_:Unit):Int63 return Int63.ofInt(current);
	public static function camlMlDomainCpuRelax(_:Unit):Unit return Unit.value;
	public static function camlRecommendedDomainCount(_:Unit):Int63 return Int63.one;
	public static function camlDomainDlsSet(s:Array<Dynamic>):Unit {
		Builtin.dls = s;
		return Unit.value;
	}
	public static function camlDomainDlsCompareAndSet(old:Array<Dynamic>, s:Array<Dynamic>):Bool {
		if (Builtin.dls != old) return false;
		Builtin.dls = s;
		return true;
	}

}
