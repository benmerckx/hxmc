package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Types of luv's Luv.Thread (eval's asynchronous API over libuv). The
// compiler's types mention them; libuv itself is not available to the
// generated compiler, so no values of them are made.

class LuvThreadT {
	function new() {}
}

class Luv__Thread {
	public static function equal(a:LuvThreadT, b:LuvThreadT):Bool return a == b;
}
