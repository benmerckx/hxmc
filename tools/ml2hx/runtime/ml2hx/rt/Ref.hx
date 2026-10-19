package ml2hx.rt;

// 'a ref: a record with one mutable field.
class Ref<T> implements Structural {
	public var value:T;
	public inline function new(value:T) this.value = value;
	public function structuralFields():Array<Any> return [value];
}
