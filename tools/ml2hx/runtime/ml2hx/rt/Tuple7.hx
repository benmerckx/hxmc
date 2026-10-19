package ml2hx.rt;

class Tuple7<T0, T1, T2, T3, T4, T5, T6> implements Block {
	public final v0:T0;
	public final v1:T1;
	public final v2:T2;
	public final v3:T3;
	public final v4:T4;
	public final v5:T5;
	public final v6:T6;

	public inline function new(v0:T0, v1:T1, v2:T2, v3:T3, v4:T4, v5:T5, v6:T6) {
		this.v0 = v0;
		this.v1 = v1;
		this.v2 = v2;
		this.v3 = v3;
		this.v4 = v4;
		this.v5 = v5;
		this.v6 = v6;
	}

	public function blockTag():Int
		return 0;

	public function blockSize():Int
		return 7;

	public function blockField(i:Int):Dynamic
		return switch i {
			case 0: v0;
			case 1: v1;
			case 2: v2;
			case 3: v3;
			case 4: v4;
			case 5: v5;
			case _: v6;
		}
}
