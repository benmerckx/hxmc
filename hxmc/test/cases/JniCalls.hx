import hxmc.java.*;
import hxmc.unsafe.*;

// Java through JNI (docs/interop.md, "Java (JNI)"): an embedded JVM
// (hxmc.java.Jvm.create: libjvm opened at run time, JNI_CreateJavaVM),
// JniCalls.java compiled by the corpus. Static and instance methods of
// every primitive type with the JNI signatures hxmc makes from the Haxe
// types, overloads (@:overload: the signature of the one the call chose;
// constructors: the one the arguments' types choose), explicit signatures
// and names, fields, strings as UTF-16, Null<Int> as Integer, Dynamic as
// Object, a Java object's one box (==), Java exceptions thrown as
// JavaException (class, message, stack), a call on null.
@:hxmc.java("jnitest.JniCalls") extern class Calls extends JavaObject {
	static var instances:Int;
	static var label:String;
	static final PI:Float;
	var count:Int;
	var name:String;
	var flag:Bool;
	var letter:UInt16;
	var big:haxe.Int64;
	var ratio:Float32;
	var small:Int8;
	var mid:Int16;
	@:overload(function(c:Int):Void {})
	@:overload(function(n:String):Void {})
	@:overload(function(n:String, c:Int):Void {})
	function new();
	static function add(a:Int, b:Int):Int;
	static function mul(a:haxe.Int64, b:haxe.Int64):haxe.Int64;
	static function half(d:Float):Float;
	static function third(f:Float32):Float32;
	static function not(b:Bool):Bool;
	static function negByte(b:Int8):Int8;
	static function upper(c:UInt16):UInt16;
	static function twice(s:Int16):Int16;
	static function mixed(i:Int, d:Float, b:Bool, s:String, l:haxe.Int64, f:Float32):Int;
	static function greet(s:String):String;
	@:hxmc.java.signature("(Ljava/lang/CharSequence;)I") static function length(s:String):Int;
	static function codes(s:String):String;
	static function make(n:Int):String;
	static function nothing():String;
	@:overload(function(s:String):String {})
	@:overload(function(d:Float):String {})
	@:overload(function(a:Int, b:Int):String {})
	static function show(i:Int):String;
	function next():Int;
	function describe():String;
	function self():Calls;
	function other():Calls;
	@:hxmc.java.name("create") static function make2(c:Int):Calls;
	static function kind(o:Dynamic):String;
	static function text(o:Dynamic):String;
	static function any(which:Int):Dynamic;
	static function boxed(i:Null<Int>):Null<Int>;
	static function boxedD(d:Null<Float>):Null<Float>;
	static function boxedB(b:Null<Bool>):Null<Bool>;
	static function fail(why:String):Void;
	static function deep(n:Int):Int;
	static function failCause():Void;
	// (no such method: NoSuchMethodError at the call)
	static function missing():Void;
}

@:hxmc.java("java.lang.Integer") extern class JInteger {
	@:hxmc.java.name("toString") static function str(i:Int, radix:Int):String;
	static function parseInt(s:String):Int;
	static final MAX_VALUE:Int;
}

class JniCalls {
	static function main() {
		Jvm.create(["-Djava.class.path=classes", "-Xcheck:jni"]);
		trace(Jvm.exists);
		// primitives
		trace(Calls.add(2, 3), Calls.half(5), Calls.third(1.5), Calls.not(false));
		trace(haxe.Int64.toStr(Calls.mul(haxe.Int64.make(1, 0), 3)), Calls.negByte(5), Calls.negByte(-128), Calls.upper("a".code), Calls.twice(-300), Calls.twice(20000));
		trace(Calls.mixed(1, 2.9, true, "four", 5, 6.5));
		// strings: UTF-16 both ways (a surrogate pair, a NUL, Latin-1)
		trace(Calls.greet("wörld €"), Calls.nothing(), Calls.length("𝄞 clef"), Calls.codes("a\x00é𝄞"));
		var long = Calls.make(1000);
		trace(long.length, long.substr(990), Calls.greet(long).length);
		trace(Calls.label, Calls.PI);
		Calls.label = "changed";
		trace(Calls.label);
		// overloads, constructors
		trace(Calls.show(1), Calls.show("s"), Calls.show(1.5), Calls.show(3, 4));
		var c = new Calls(10);
		trace(c.next(), c.next(), c.describe(), c.count, Calls.instances);
		c.count = 100;
		c.count += 5;
		c.name = "renamed";
		c.flag = true;
		c.letter = "Q".code;
		c.big = haxe.Int64.make(0, 77);
		c.ratio = 0.25;
		c.small = 9;
		c.mid = -2;
		trace(c.describe(), c.count, c.flag, String.fromCharCode(c.letter), c.ratio, c.small, c.mid);
		var d = new Calls("named");
		var e = new Calls("both", 3);
		trace(d.describe(), e.describe(), Calls.instances, new Calls().describe(), Calls.instances);
		// one box per object, while Haxe holds it
		trace(c.self() == c, c.other() == c, Calls.make2(4).describe(), c.equals(c), c.equals(d), c.hashCode() == c.self().hashCode());
		// Dynamic as Object (boxing), Null<T> as the boxes
		trace(Calls.kind(1), Calls.kind(2.5), Calls.kind(true), Calls.kind("x"), Calls.kind(c), Calls.kind(null));
		trace(Calls.text(1), Calls.text(2.5), Calls.text(true), Calls.text("x"));
		trace([for (i in 0...7) Calls.any(i)]);
		trace(Calls.any(0) + 1, Calls.any(1) * 2);
		trace(Calls.boxed(1), Calls.boxed(null), Calls.boxedD(1.25), Calls.boxedD(null), Calls.boxedB(true), Calls.boxedB(null));
		// the JDK's classes
		trace(JInteger.str(255, 16), JInteger.parseInt("-42"), JInteger.MAX_VALUE, Java.toString(c).indexOf("jnitest.JniCalls@") == 0);
		// exceptions: class, message, the stack's first frames
		try Calls.fail("no") catch (x:JavaException) trace(x.className, x.javaMessage, x.message, x.javaStack.split("\n")[1]);
		try Calls.deep(3) catch (x:JavaException) trace(x.message, x.javaStack.split("\n").length >= 5, x.javaStack.split("\n")[4]);
		try Calls.failCause() catch (x:JavaException) trace(x.message);
		try Calls.missing() catch (x:JavaException) trace(x.className, x.javaMessage);
		try JInteger.parseInt("nope") catch (x:JavaException) trace(x.message);
		var none:Calls = null;
		try none.next() catch (x:JavaException) trace(x.className, x.javaMessage);
		try trace(none.count) catch (x:JavaException) trace(x.className, x.javaMessage);
		// a thrown exception caught as Dynamic, the next call fine
		try Calls.fail("dyn") catch (x:Dynamic) trace(Std.isOfType(x, JavaException), Std.string(x));
		trace(Calls.add(40, 2));
		// Java.same, isInstance
		trace(Java.same(c, c.self()), Java.same(c, d), Java.isInstance(c, "java.lang.Object"), Java.isInstance(c, "java.lang.Number"), Java.isInstance("s", "java.lang.CharSequence"));
	}
}
