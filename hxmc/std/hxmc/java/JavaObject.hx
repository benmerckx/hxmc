package hxmc.java;

// java.lang.Object, which a declaration of a Java class can extend to have
// its methods (docs/interop.md, "Java (JNI)")
@:hxmc.java("java.lang.Object") extern class JavaObject {
	function new();
	function toString():String;
	function hashCode():Int;
	function equals(o:Dynamic):Bool;
}
