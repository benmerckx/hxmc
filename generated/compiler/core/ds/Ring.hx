package core.ds;
import core.ds.RingModule.RingState;

// ABI adapter only: every algorithm is generated from upstream ring.ml.
class Ring<T> {
	final state:RingState<T>;
	public function new(length:Int, initial:T) state = RingModule.create()(ml2hx.rt.Int63.ofInt(length))(initial);
	public function push(value:T):Void RingModule.push()(state)(value);
	public function iter(callback:T->Void):Void RingModule.iter()(state)(v -> {callback(v); return ml2hx.rt.Unit.value;});
	public function fold<Result>(initial:Result, callback:Result->T->Result):Result
		return RingModule.fold()(state)(initial)(a -> b -> callback(a, b));
	public function find(predicate:T->Bool):T return RingModule.find()(state)(predicate);
	public function isFilled():Bool return RingModule.isFilled()(state);
	public function resetFilled():Void RingModule.resetFilled()(state);
}
