package ml2hx.rt;

// 'a ref: a record of one mutable field (`contents`)
class Ref<T> implements Block {
	public var value:T;

	public inline function new(value:T)
		this.value = value;

	public function blockTag():Int
		return 0;

	public function blockSize():Int
		return 1;

	public function blockField(i:Int):Dynamic
		return value;
}
