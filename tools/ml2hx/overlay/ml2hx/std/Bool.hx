package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// Stdlib.Bool
class Bool {
	public static inline function not(b:StdTypes.Bool):StdTypes.Bool return !b;
	public static inline function equal(a:StdTypes.Bool, b:StdTypes.Bool):StdTypes.Bool return a == b;
	public static inline function compare(a:StdTypes.Bool, b:StdTypes.Bool):Int63 return Int63.ofInt(Runtime.compareBool(a, b));
	public static inline function toInt(b:StdTypes.Bool):Int63 return b ? Int63.one : Int63.zero;
	public static inline function toFloat(b:StdTypes.Bool):Float return b ? 1.0 : 0.0;
	public static inline function toString(b:StdTypes.Bool):String return b ? "true" : "false";
	public static function ofString(s:String):StdTypes.Bool return s == "true" ? true : s == "false" ? false : throw new InvalidArgument("Bool.of_string");
}
