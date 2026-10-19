package ml2hx.prim;

import ml2hx.rt.*;
import ocaml.stdlib.DomainModule.DomainRawTermSync;
import ocaml.stdlib.DomainModule.DomainRawState;
import ocaml.stdlib.StdlibModule.StdlibResult;

// OCaml's domain.c: a domain is a thread of its own (with its own
// domain-local state) under the master lock with the others (ml2hx.rt.Gil:
// one at a time, a valid schedule of parallel domains; no threads: it runs
// to completion when spawned). Its end is published as domain.c does it:
// the term_sync's state set and its condition broadcast under its mutex.
class Domain {
	static var nextId = 1;

	public static function camlDomainSpawn<T>(body:Unit->T, sync:DomainRawTermSync<T>):Int63 {
		var id = nextId++;
		ml2hx.std.Thread.spawn(new ml2hx.std.Thread.DomainState(id), _ -> {
			var state = try DomainRawState.Finished(StdlibResult.Ok(body(Unit.value))) catch (e:haxe.Exception) DomainRawState.Finished(StdlibResult.Error(MlException.wrap(e)));
			Sync.camlMlMutexLock(sync.mut);
			sync.state = state;
			Sync.camlMlConditionBroadcast(sync.cond);
			Sync.camlMlMutexUnlock(sync.mut);
		});
		return Int63.ofInt(id);
	}
	public static function camlMlDomainId(_:Unit):Int63 return Int63.ofInt(ml2hx.std.Thread.current.domain.id);
	public static function camlMlDomainIndex(_:Unit):Int63 return Int63.ofInt(ml2hx.std.Thread.current.domain.id);
	// (spinning domains let the others run)
	public static function camlMlDomainCpuRelax(_:Unit):Unit return ml2hx.std.Thread.yield(Unit.value);
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
