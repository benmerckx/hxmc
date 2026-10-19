package ml2hx.std;

import ml2hx.rt.*;

// Stdlib.Effect: an effect is an extension constructor of 'a Effect.t (the
// type parameter only types `perform`: one base class).
class EffectBase {
	public function new() {}
}

typedef EffectT<A> = EffectBase;
typedef EffectEff<A> = EffectBase;

class EffectUnhandledExn extends MlException {
	public final v0:EffectBase;
	public function new(v0:EffectBase) {
		super();
		this.v0 = v0;
	}
	override public function exnArity():Int return 1;
	override public function exnArg(i:Int):Dynamic return i == 0 ? v0 : super.exnArg(i);
	override public function exnName():String return "Stdlib.Effect.Unhandled";
}

class EffectContinuationAlreadyResumedExn extends MlException {
	public static final instance = new EffectContinuationAlreadyResumedExn();
	public function new() super();
	override public function exnName():String return "Stdlib.Effect.Continuation_already_resumed";
}

class Effect {
	public static function perform<A>(e:EffectBase):A return Effect_Deep.perform(e);
}
