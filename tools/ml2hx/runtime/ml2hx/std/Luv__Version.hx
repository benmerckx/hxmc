package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// luv's Luv.Version: not available in the generated compiler yet
// (eval.luv); its functions raise Failure.

// (the version of the libuv hxmc links, as UvLayouts reads it: NativeUv.constant's group 9)
class Luv__Version {
	#if (target.name == "hxmc")
	public static final hex:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(hxmc.NativeUv.constant(9, 4));
	#else
	public static var hex(get, never):ml2hx.rt.Int63;
	static function get_hex():ml2hx.rt.Int63 throw new Failure("luv: Luv.Version.hex is not available in the generated compiler");
	#end
	#if (target.name == "hxmc")
	public static final isRelease:Bool = hxmc.NativeUv.constant(9, 3) != 0;
	#else
	public static var isRelease(get, never):Bool;
	static function get_isRelease():Bool throw new Failure("luv: Luv.Version.isRelease is not available in the generated compiler");
	#end
	#if (target.name == "hxmc")
	public static final major:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(hxmc.NativeUv.constant(9, 0));
	#else
	public static var major(get, never):ml2hx.rt.Int63;
	static function get_major():ml2hx.rt.Int63 throw new Failure("luv: Luv.Version.major is not available in the generated compiler");
	#end
	#if (target.name == "hxmc")
	public static final minor:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(hxmc.NativeUv.constant(9, 1));
	#else
	public static var minor(get, never):ml2hx.rt.Int63;
	static function get_minor():ml2hx.rt.Int63 throw new Failure("luv: Luv.Version.minor is not available in the generated compiler");
	#end
	#if (target.name == "hxmc")
	public static final patch:ml2hx.rt.Int63 = ml2hx.rt.Int63.ofInt(hxmc.NativeUv.constant(9, 2));
	#else
	public static var patch(get, never):ml2hx.rt.Int63;
	static function get_patch():ml2hx.rt.Int63 throw new Failure("luv: Luv.Version.patch is not available in the generated compiler");
	#end
	public static function string(a0:ml2hx.rt.Unit):String { throw new Failure("luv: Luv.Version.string is not available in the generated compiler"); }
	#if (target.name == "hxmc")
	public static final suffix:String = hxmc.NativeUv.versionSuffix();
	#else
	public static var suffix(get, never):String;
	static function get_suffix():String throw new Failure("luv: Luv.Version.suffix is not available in the generated compiler");
	#end
}
