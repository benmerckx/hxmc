package ml2hx.rt;

class Failure extends MlException {
	public final v0:String;

	public function new(v0:String) {
		super();
		this.v0 = v0;
	}

	override public function exnArity():Int
		return 1;

	override public function exnArg(i:Int):Dynamic
		return switch i {
			case 0: v0;
			case _: super.exnArg(i);
		}

	override public function exnName():String
		return "Failure";
}
