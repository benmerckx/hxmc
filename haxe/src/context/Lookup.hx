package context;

import core.ds.PMap;
import core.ds.Hashtbl;

interface Lookup<K, V> {
	public function add(key:K, value:V):Void;
	public function remove(key:K):Void;
	public function find(key:K):V;
	public function findOpt(key:K):Null<V>;
	public function iter(f:K->V->Void):Void;
	public function fold<A>(f:K->V->A->A, acc:A):A;
	public function mem(key:K):Bool;
	public function clear():Void;
}

// port: upstream's `pmap_lookup`, which nothing instantiates there or here: string
// keys alone, the keys of core.ds.PMap.
class PmapLookup<V> implements Lookup<String, V> {
	var lut:PMap<V>;

	public function new() lut = PMap.empty();

	public function add(key:String, value:V):Void lut = lut.add(key, value);

	public function remove(key:String):Void lut = lut.remove(key);

	public function find(key:String):V return lut.find(key);

	public function findOpt(key:String):Null<V> return lut.get(key);

	public function iter(f:String->V->Void):Void lut.iter(f);

	public function fold<A>(f:String->V->A->A, acc:A):A return lut.foldi(f, acc);

	public function mem(key:String):Bool return lut.exists(key);

	public function clear():Void lut = PMap.empty();
}

class HashtblLookup<K, V> implements Lookup<K, V> {
	final lut:Hashtbl<K, V>;

	public function new() lut = new Hashtbl(0);

	public function add(key:K, value:V):Void lut.replace(key, value);

	public function remove(key:K):Void lut.remove(key);

	public function find(key:K):V return lut.find(key);

	public function findOpt(key:K):Null<V> return lut.findOpt(key);

	public function iter(f:K->V->Void):Void lut.iter(f);

	public function fold<A>(f:K->V->A->A, acc:A):A return lut.fold(f, acc);

	public function mem(key:K):Bool return lut.mem(key);

	public function clear():Void lut.clear();
}
