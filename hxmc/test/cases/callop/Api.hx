package callop;

import callop.Sig;

class Api {
	public static function sig<T>(v:T):Sig<T> return new Sig(v);

	public static function sigFirst<T>(v:T):SigFirst<T> return new SigFirst(v);

	public static function sigPlain<T>(v:T):SigPlain<T> return new SigPlain(v);

	public static function sigPlainFirst<T>(v:T):SigPlainFirst<T> return new SigPlainFirst(v);
}
