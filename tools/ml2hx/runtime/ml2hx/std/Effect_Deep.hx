package ml2hx.std;

import ml2hx.rt.*;
import ml2hx.std.Effect;

// A continuation of a deep handler: resumed (continue) with a value or an
// exception (discontinue), at most once.
class EffectDeepContinuation<A, B> {
	public var used = false;
	public var resumed = false;
	public var value:Null<A> = null;
	public var failure:Null<MlException> = null;
	public function new() {}
}

class EffectDeepEffectHandler<A> implements Block {
	public var effc:EffectBase->MlOption<EffectDeepContinuation<Any, A>->A>;
	public function new(effc) this.effc = effc;
	public function blockTag():Int return 0;
	public function blockSize():Int return 1;
	public function blockField(i:Int):Dynamic return effc;
}

class EffectDeepHandler<A, B> implements Block {
	public var retc:A->B;
	public var exnc:MlException->B;
	public var effc:EffectBase->MlOption<EffectDeepContinuation<Any, B>->B>;
	public function new(retc, exnc, effc) {
		this.retc = retc;
		this.exnc = exnc;
		this.effc = effc;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 3;
	public function blockField(i:Int):Dynamic return i == 0 ? retc : i == 1 ? exnc : effc;
}

// The end of a handled computation decided in an effect's handler: the
// handler's result (it did not resume) or its exception, delivered to the
// handler's try_with.
private class Finish extends haxe.Exception {
	public final frame:Frame;
	public final value:Dynamic;
	public final error:Null<haxe.Exception>;
	public function new(frame, value, error) {
		super("effect handler finished");
		this.frame = frame;
		this.value = value;
		this.error = error;
	}
}

private class Frame {
	public final effc:EffectBase->MlOption<Dynamic>;
	public function new(effc) this.effc = effc;
}

// Deep handlers whose effect handlers resume their continuation last (or
// not at all): `perform` calls the handler where it is performed (with the
// handlers outside it installed) and returns the value it resumes with. A
// handler that does work after `continue` does it before the computation
// resumes (unlike OCaml, where the computation runs inside `continue`).
class Effect_Deep {
	static var frames:Array<Frame> = [];

	public static function perform<A>(e:EffectBase):A {
		var i = frames.length - 1;
		while (i >= 0) {
			var frame = frames[i];
			switch frame.effc(e) {
				case Some(h):
					var k = new EffectDeepContinuation<A, Dynamic>();
					var saved = frames;
					frames = frames.slice(0, i);
					var result:Dynamic = null;
					try {
						result = (h : EffectDeepContinuation<A, Dynamic>->Dynamic)(k);
					} catch (x:haxe.Exception) {
						frames = saved;
						throw new Finish(frame, null, x);
					}
					frames = saved;
					if (k.resumed) return k.value;
					if (k.failure != null) throw k.failure;
					throw new Finish(frame, result, null);
				case None:
					i--;
			}
		}
		throw new EffectUnhandledExn(e);
	}

	static function run<C, A, B>(f:C->A, x:C, effc:EffectBase->MlOption<Dynamic>, retc:A->B, exnc:MlException->B):B {
		var frame = new Frame(effc);
		frames.push(frame);
		var depth = frames.length;
		var r:A;
		try {
			r = f(x);
		} catch (fin:Finish) {
			frames.resize(depth - 1);
			if (fin.frame != frame) throw fin;
			if (fin.error != null) throw fin.error;
			return fin.value;
		} catch (e:haxe.Exception) {
			frames.resize(depth - 1);
			return exnc(MlException.wrap(e));
		}
		frames.resize(depth - 1);
		return retc(r);
	}

	public static function tryWith<C, A>(f:C->A, x:C, h:EffectDeepEffectHandler<A>):A
		return run(f, x, cast h.effc, (v:A) -> v, (e:MlException) -> throw e);

	public static function matchWith<C, A, B>(f:C->A, x:C, h:EffectDeepHandler<A, B>):B
		return run(f, x, cast h.effc, h.retc, h.exnc);

	public static function continueValue<A, B>(k:EffectDeepContinuation<A, B>, v:A):B {
		if (k.used) throw EffectContinuationAlreadyResumedExn.instance;
		k.used = true;
		k.resumed = true;
		k.value = v;
		return cast null;
	}

	public static function discontinue<A, B>(k:EffectDeepContinuation<A, B>, e:MlException):B {
		if (k.used) throw EffectContinuationAlreadyResumedExn.instance;
		k.used = true;
		k.failure = e;
		return cast null;
	}
}
