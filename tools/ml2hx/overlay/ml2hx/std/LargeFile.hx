package ml2hx.std;

import String;
import StdTypes;

import ml2hx.rt.*;

// Stdlib.LargeFile: channel positions and lengths as int64.
class LargeFile {
	public static function seekOut(oc:Stdlib.StdlibOutChannel, pos:haxe.Int64):Unit return Stdlib.seekOut(oc, Int63.ofInt64(pos));
	public static function posOut(oc:Stdlib.StdlibOutChannel):haxe.Int64 return Stdlib.posOut(oc).toInt64();
	public static function outChannelLength(oc:Stdlib.StdlibOutChannel):haxe.Int64 return Stdlib.outChannelLength(oc).toInt64();
	public static function seekIn(ic:Stdlib.StdlibInChannel, pos:haxe.Int64):Unit return Stdlib.seekIn(ic, Int63.ofInt64(pos));
	public static function posIn(ic:Stdlib.StdlibInChannel):haxe.Int64 return Stdlib.posIn(ic).toInt64();
	public static function inChannelLength(ic:Stdlib.StdlibInChannel):haxe.Int64 return Stdlib.inChannelLength(ic).toInt64();
}
