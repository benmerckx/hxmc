package ml2hx.std;

import Array as HArray;
import String;
import StdTypes;
import ml2hx.rt.*;

// The ipaddr library's parsing and printing (ipaddr.ml), what the compiler
// uses: V4/V6 of_string_exn and to_string, with_port_of_string.
enum IpaddrV4v6<A, B> {
	V4(v0:A);
	V6(v0:B);
}
typedef IpaddrT = IpaddrV4v6<Ipaddr_V4.IpaddrV4T, Ipaddr_V6.IpaddrV6T>;

class IpaddrParseError extends MlException {
	public final v0:String;
	public final v1:String;
	public function new(v0:String, v1:String) {
		super();
		this.v0 = v0;
		this.v1 = v1;
	}
	override public function exnName():String return "Ipaddr.Parse_error";
	override public function exnArity():Int return 2;
	override public function exnArg(i:Int):Dynamic return i == 0 ? v0 : v1;
}

@:allow(ml2hx.std.Ipaddr_V4)
@:allow(ml2hx.std.Ipaddr_V6)
class Ipaddr {
	static function digit(c:Int):Int {
		if (c >= "0".code && c <= "9".code) return c - "0".code;
		if (c >= "a".code && c <= "f".code) return 10 + c - "a".code;
		if (c >= "A".code && c <= "F".code) return 10 + c - "A".code;
		return -1;
	}
	static function badChar(i:Int, s:String):IpaddrParseError return new IpaddrParseError('invalid character \'${std.String.fromCharCode(StringTools.fastCodeAt(s, i))}\' at $i', s);
	static function needMore(s:String):IpaddrParseError return new IpaddrParseError("not enough data", s);
	static function parseInt(base:Int, s:String, i:Ref<Int>):Int {
		var len = s.length;
		if (i.value >= len) throw needMore(s);
		var k = digit(StringTools.fastCodeAt(s, i.value));
		if (k < 0 || k >= base) throw badChar(i.value, s);
		var v = 0;
		while (i.value < len) {
			var d = digit(StringTools.fastCodeAt(s, i.value));
			if (d < 0 || d >= base) break;
			v = v * base + d;
			i.value++;
		}
		return v;
	}
	static function expectChar(s:String, i:Ref<Int>, c:Int) {
		if (i.value < s.length) {
			if (StringTools.fastCodeAt(s, i.value) != c) throw badChar(i.value, s);
			i.value++;
		} else throw needMore(s);
	}
	static function expectEnd(s:String, i:Ref<Int>) if (s.length > i.value) throw badChar(i.value, s);
	static function ofStringRaw(s:String, o:Ref<Int>):IpaddrT {
		if (s.length < o.value + 1) throw needMore(s);
		if (StringTools.fastCodeAt(s, 0) == "[".code) return V6(Ipaddr_V6.ofStringRaw(s, o));
		var pos = o.value;
		try return V4(Ipaddr_V4.ofStringRaw(s, o)) catch (e4:IpaddrParseError) {
			o.value = pos;
			try return V6(Ipaddr_V6.ofStringRaw(s, o)) catch (e6:IpaddrParseError)
				throw new IpaddrParseError('not an IPv4 address: ${e4.v0}\nnot an IPv6 address: ${e6.v0}', s);
		}
	}
	public static function withPortOfString(defaultValue:Int63, s:String):Stdlib.StdlibResult<Tuple2<IpaddrT, Int63>, PolyVariant> {
		var o = new Ref(0);
		try {
			var ip = ofStringRaw(s, o);
			if (o.value < s.length && StringTools.fastCodeAt(s, o.value) == ":".code) {
				o.value++;
				var port = parseInt(10, s, o);
				expectEnd(s, o);
				return Ok(new Tuple2(ip, Int63.ofInt(port)));
			}
			expectEnd(s, o);
			return Ok(new Tuple2(ip, defaultValue));
		} catch (e:IpaddrParseError) {
			return Error(new PolyVariant1(3855332, "Msg", "Ipaddr: " + e.v0));
		}
	}
	public static function toString(ip:IpaddrT):String return switch ip { case V4(x): Ipaddr_V4.toString(x); case V6(x): Ipaddr_V6.toString(x); };
}
