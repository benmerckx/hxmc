package ml2hx.rt;

class AssertFailure extends MlException {
	public final v0:String;
	public final v1:Int63;
	public final v2:Int63;

	public function new(v0:String, v1:Int63, v2:Int63) {
		super();
		this.v0 = v0;
		this.v1 = v1;
		this.v2 = v2;
	}

	override public function exnArity():Int
		return 3;

	override public function exnArg(i:Int):Dynamic
		return switch i {
			case 0: v0;
			case 1: v1;
			case 2: v2;
			case _: super.exnArg(i);
		}

	override public function exnName():String
		return "Assert_failure";
}
