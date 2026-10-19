package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Error (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

typedef LuvErrorT = PolyVariant;
class Luv__Error {
	public static function strerror(e:LuvErrorT):String return e.label;
	// the handler of exceptions raised by callbacks: no libuv callbacks run
	static var onUnhandled:Null<MlException->Unit> = null;
	public static function setOnUnhandledException(f:MlException->Unit):Unit {
		onUnhandled = f;
		return Unit.value;
	}
}
