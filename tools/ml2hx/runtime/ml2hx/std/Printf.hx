package ml2hx.std;

import Array;
import String;
import StdTypes;
import ml2hx.rt.*;

// Stdlib.Printf: the format is an ml2hx.rt.Fmt (Fmt.of("...") of the
// literal), the arguments an array (ml2hx.rt.Fmt lists what each
// conversion takes). OCaml prints when the last argument is given: here all
// are given at once.
class Printf {
	public static function sprintf(fmt:Fmt, args:Array<Dynamic>):String {
		var b = new StringBuf();
		fmt.run(args, s -> b.add(s), (f:Dynamic, x:Dynamic, alpha:Bool) -> b.add(alpha ? f(Unit.value, x) : f(Unit.value)), () -> {});
		return b.toString();
	}

	public static function bprintf(buf:Buffer.BufferT, fmt:Fmt, args:Array<Dynamic>):Unit {
		fmt.run(args, s -> buf.sb.add(s), (f:Dynamic, x:Dynamic, alpha:Bool) -> if (alpha) f(buf, x) else f(buf), () -> {});
		return Unit.value;
	}

	public static function fprintf(oc:Stdlib.StdlibOutChannel, fmt:Fmt, args:Array<Dynamic>):Unit {
		fmt.run(args, s -> oc.addString(s), (f:Dynamic, x:Dynamic, alpha:Bool) -> if (alpha) f(oc, x) else f(oc), () -> oc.flush());
		return Unit.value;
	}

	public static inline function printf(fmt:Fmt, args:Array<Dynamic>):Unit
		return fprintf(Stdlib.stdout, fmt, args);

	public static inline function eprintf(fmt:Fmt, args:Array<Dynamic>):Unit
		return fprintf(Stdlib.stderr, fmt, args);

	public static function ksprintf<R>(k:String->R, fmt:Fmt, args:Array<Dynamic>):R
		return k(sprintf(fmt, args));

	public static inline function kprintf<R>(k:String->R, fmt:Fmt, args:Array<Dynamic>):R
		return ksprintf(k, fmt, args);

	public static function kbprintf<R>(k:Buffer.BufferT->R, buf:Buffer.BufferT, fmt:Fmt, args:Array<Dynamic>):R {
		bprintf(buf, fmt, args);
		return k(buf);
	}

	public static function kfprintf<R>(k:Stdlib.StdlibOutChannel->R, oc:Stdlib.StdlibOutChannel, fmt:Fmt, args:Array<Dynamic>):R {
		fprintf(oc, fmt, args);
		return k(oc);
	}

	public static function ifprintf<O>(o:O, fmt:Fmt, args:Array<Dynamic>):Unit
		return Unit.value;
}
