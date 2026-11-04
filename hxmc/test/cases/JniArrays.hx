import hxmc.java.*;
import hxmc.unsafe.*;

// Java's arrays (docs/interop.md, "Java (JNI)"): an Array, Bytes or a
// String[] parameter or result is copied at the call (Array<Int> as int[],
// <Float> as double[], <Float32> float[], <Bool> boolean[], <Int64> long[],
// <Int16> short[], <UInt16> char[], Bytes byte[], <String> String[], <C> C[],
// <Dynamic> Object[]); a JavaArray is the Java array itself: its elements
// read and written in place (critical: GetPrimitiveArrayCritical), Java's
// changes and Haxe's seen by both.
@:hxmc.java("jnitest.JniArrays") extern class Arrays {
	var id:Int;
	static var held:JavaArray<Int>;
	function new(id:Int);
	static function sum(a:Array<Int>):Int;
	static function squares(n:Int):Array<Int>;
	static function scale(a:Array<Float>, k:Float):Array<Float>;
	static function halves(a:Array<Float32>):Array<Float32>;
	static function invert(a:Array<Bool>):Array<Bool>;
	static function total(a:Array<haxe.Int64>):haxe.Int64;
	static function shorts(n:Int):Array<Int16>;
	static function chars(s:String):Array<UInt16>;
	static function ofChars(c:Array<UInt16>):String;
	static function reverse(b:haxe.io.Bytes):haxe.io.Bytes;
	static function join(a:Array<String>):String;
	static function split(s:String):Array<String>;
	static function many(n:Int):Array<Arrays>;
	static function ids(a:Array<Arrays>):Int;
	static function kinds(a:Array<Dynamic>):String;
	static function mixed():Array<Dynamic>;
	static function empty():Array<Int>;
	static function none():Array<Int>;
	static function shared():JavaArray<Int>;
	static function heldText():String;
	static function big(n:Int):Array<Int>;
	static function strings(a:Array<String>):String;
	static function grid():JavaArray<JavaArray<String>>;
	@:hxmc.java.signature("([Ljava/lang/Object;)Ljava/lang/String;") static function gridText(g:JavaArray<JavaArray<String>>):String;
}

class JniArrays {
	static function main() {
		Jvm.create(["-Djava.class.path=classes", "-Xcheck:jni"]);
		// copied in and out
		trace(Arrays.sum([1, 2, 3, 4]), Arrays.squares(6), Arrays.scale([1.5, -2], 2), Arrays.halves([1, 3]), Arrays.invert([true, false, false]));
		trace(haxe.Int64.toStr(Arrays.total([haxe.Int64.make(1, 0), 5])), Arrays.shorts(4), Arrays.chars("hé𝄞"), Arrays.ofChars([0x68, 0xe9, 0xd834, 0xdd1e]));
		var b = haxe.io.Bytes.ofHex("61626300ff");
		trace(Arrays.reverse(b).toHex(), b.toHex());
		trace(Arrays.join(["a", "b", "c"]), Arrays.split("x,y,,z"), Arrays.strings(["s", null, "t"]));
		var objs = Arrays.many(4);
		trace(objs.length, [for (o in objs) o.id], Arrays.ids(objs), Arrays.ids([objs[3], null, new Arrays(1)]), objs[1] == Arrays.many(2)[1]);
		trace(Arrays.kinds([1, "two", 3.5, true, null, objs[0]]), Arrays.mixed().length, Arrays.mixed().slice(0, 5));
		trace(Arrays.empty(), Arrays.none(), Arrays.sum([]));
		var big = Arrays.big(100000);
		var s = 0.0;
		for (x in big) s += x;
		trace(big.length, s, Arrays.sum(big));
		// a Java array in place: its elements read and written (critical), seen by Java
		var held = Arrays.shared();
		trace(held.length, Arrays.heldText());
		held.critical((p, n) -> {
			for (i in 0...n)
				Mem.setI32(p, 4 * i, Mem.getI32(p, 4 * i) * 10);
		});
		trace(Arrays.heldText());
		var out = Mem.stack(16);
		held.getRegion(5, 1, 2, out);
		trace(Mem.getI32(out, 0), Mem.getI32(out, 4));
		Mem.setI32(out, 0, -7);
		held.setRegion(5, 3, 1, out);
		trace(Arrays.heldText(), Arrays.held == held);
		var fresh = JavaArray.ofInts(3);
		Arrays.held = fresh;
		trace(Arrays.heldText(), fresh.length);
		var g = Arrays.grid();
		trace(g.length, g.get(0).length, g.get(0).get(1), g.get(1).get(0), Arrays.gridText(g));
		g.get(1).set(0, "changed");
		trace(Arrays.gridText(g));
		var os = JavaArray.ofObjects(2, "java.lang.String");
		os.set(0, "first");
		trace(os.get(0), os.get(1), os.length);
	}
}
