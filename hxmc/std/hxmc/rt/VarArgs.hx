package hxmc.rt;

// Reflect.makeVarArgs's function: f called with the arguments of a dynamic
// call (Dyn.dynCall, so also Reflect.callMethod and a Dynamic converted to a
// function type, whose adapter calls it dynamically), however many there are.
class VarArgs {
	public final f:Array<Dynamic>->Dynamic;

	public function new(f:Array<Dynamic>->Dynamic)
		this.f = f;

	// (printed as every function is)
	public function toString():String
		return "<function>";
}
