package ml2hx.rt;

class Tuple2<T0, T1> implements Block {
	public final v0:T0;
	public final v1:T1;

	public inline function new(v0:T0, v1:T1) {
		this.v0 = v0;
		this.v1 = v1;
	}

	public function blockTag():Int
		return 0;

	public function blockSize():Int
		return 2;

	public function blockField(i:Int):Dynamic
		return switch i {
			case 0: v0;
			case _: v1;
		}
}
