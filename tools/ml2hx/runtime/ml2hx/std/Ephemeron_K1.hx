package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;
import ml2hx.std.Hashtbl;

// Stdlib.Ephemeron.K1. The host collector does not report reachability to
// OCaml code, so no key is ever found dead: an ephemeron table keeps all its
// bindings, which is one of the behaviours OCaml allows (a binding goes away
// only after a collection that finds its key unreachable).
typedef EphemeronK1T<K, V> = HashtblT<K, V>;

class EphemeronK1Make<K> extends HashtblMake<K> {
	public function clean<V>(h:HashtblT<K, V>):Unit return Unit.value;
	public function statsAlive<V>(h:HashtblT<K, V>):HashtblStatistics return stats(h);
}

class EphemeronK1MakeSeeded<K> extends HashtblMakeSeeded<K> {
	public function clean<V>(h:HashtblT<K, V>):Unit return Unit.value;
	public function statsAlive<V>(h:HashtblT<K, V>):HashtblStatistics return stats(h);
}

class Ephemeron_K1 {
	public static function Make<K>(h:HashtblHashedType<K>):EphemeronK1Make<K> return new EphemeronK1Make(h);
	public static function MakeSeeded<K>(h:HashtblSeededHashedType<K>):EphemeronK1MakeSeeded<K> return new EphemeronK1MakeSeeded(h);
}
