package ml2hx.std;

import Array;
import ml2hx.rt.*;
import ml2hx.rt.MlOption;

// extlib's Option, which shadows Stdlib.Option in the compiler (its get
// raises Option.No_value, not Invalid_argument), with Stdlib.Option's other values
class Option {
	public static function may<A>(f:A->Unit, o:MlOption<A>):Unit
		return switch o { case Some(v): f(v); case None: Unit.value; };

	public static function defaultValue<A>(v:A, o:MlOption<A>):A
		return switch o { case Some(x): x; case None: v; };

	public static function mapDefault<A, B>(f:A->B, v:B, o:MlOption<A>):B
		return switch o { case Some(x): f(x); case None: v; };

	public static inline function none<A>():MlOption<A>
		return None;

	public static inline function some<A>(v:A):MlOption<A>
		return Some(v);

	public static function value<A>(o:MlOption<A>, default_:A):A
		return switch o { case Some(v): v; case None: default_; };

	public static function get<A>(o:MlOption<A>):A
		return switch o { case Some(v): v; case None: throw OptionNoValue.instance; };

	public static function bind<A, B>(o:MlOption<A>, f:A->MlOption<B>):MlOption<B>
		return switch o { case Some(v): f(v); case None: None; };

	public static function join<A>(o:MlOption<MlOption<A>>):MlOption<A>
		return switch o { case Some(v): v; case None: None; };

	public static function map<A, B>(f:A->B, o:MlOption<A>):MlOption<B>
		return switch o { case Some(v): Some(f(v)); case None: None; };

	public static function fold<A, B>(none:B, some:A->B, o:MlOption<A>):B
		return switch o { case Some(v): some(v); case None: none; };

	public static function iter<A>(f:A->Unit, o:MlOption<A>):Unit
		return switch o { case Some(v): f(v); case None: Unit.value; };

	public static function isNone<A>(o:MlOption<A>):Bool
		return switch o { case Some(_): false; case None: true; };

	public static function isSome<A>(o:MlOption<A>):Bool
		return switch o { case Some(_): true; case None: false; };

	public static function equal<A>(eq:(A, A) -> Bool, a:MlOption<A>, b:MlOption<A>):Bool
		return switch [a, b] {
			case [None, None]: true;
			case [Some(x), Some(y)]: eq(x, y);
			case _: false;
		}

	public static function compare<A>(cmp:(A, A) -> Int63, a:MlOption<A>, b:MlOption<A>):Int63
		return switch [a, b] {
			case [None, None]: Int63.zero;
			case [None, Some(_)]: Int63.minusOne;
			case [Some(_), None]: Int63.one;
			case [Some(x), Some(y)]: cmp(x, y);
		}

	public static function toList<A>(o:MlOption<A>):MlList<A>
		return switch o { case Some(v): Cons(v, Nil); case None: Nil; };

	public static function toSeq<A>(o:MlOption<A>):Seq.SeqT<A>
		return switch o { case Some(v): Seq.returnValue(v); case None: Seq.empty(); };
}

class OptionNoValue extends MlException {
	public static final instance = new OptionNoValue();

	public function new()
		super();

	override public function exnName():std.String
		return "Option.No_value";
}
