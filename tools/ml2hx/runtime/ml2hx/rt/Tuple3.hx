package ml2hx.rt;

class Tuple3<T0, T1, T2> implements Block {
	public final v0:T0;
	public final v1:T1;
	public final v2:T2;

	public inline function new(v0:T0, v1:T1, v2:T2) {
		this.v0 = v0;
		this.v1 = v1;
		this.v2 = v2;
	}

	public function blockTag():Int
		return 0;

	public function blockSize():Int
		return 3;

	public function blockField(i:Int):Dynamic
		return switch i {
			case 0: v0;
			case 1: v1;
			case _: v2;
		}
}
