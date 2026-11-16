package core.ds;

// port: a key/value binding of Hashtbl (a class, so static
// targets access it directly).
@:structInit class MapEntry<K, V> {
	public var key:K;
	public var value:V;

	public inline function new(key:K, value:V) {
		this.key = key;
		this.value = value;
	}
}
