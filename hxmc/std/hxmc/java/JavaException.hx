package hxmc.java;

// A Java exception (docs/interop.md, "Java (JNI)"): what a call of a Java
// method, constructor or field throws when Java left one pending. Its
// message is Throwable.toString's ("java.lang.IllegalStateException: no"),
// javaStack that line and getStackTrace's frames, one "\tat ..." each, as
// printStackTrace prints them; throwable the Java Throwable itself (a Java
// object; null for the runtime's own). One reaching Java again (a Haxe
// method Java called throws it) is that Throwable thrown again; any other
// Haxe exception reaching Java is an org.hxmc.HaxeException of its message.
class JavaException extends haxe.Exception {
	// the Throwable's class (java.lang.IllegalStateException)
	public final className:String;
	// its getMessage (null: none)
	public final javaMessage:Null<String>;
	public final javaStack:String;
	public final throwable:Dynamic;

	public function new(className:String, javaMessage:Null<String>, javaStack:String, throwable:Dynamic) {
		super(javaStack != "" ? javaStack.split("\n")[0] : javaMessage != null ? className + ": " + javaMessage : className);
		this.className = className;
		this.javaMessage = javaMessage;
		this.javaStack = javaStack;
		this.throwable = throwable;
	}

	// (a Java call, field or new where there is no JNI: hxmc.ir.Jni)
	@:keep @:hxmc.host("rt_jni_unavailable") static function unavailable():Void
		throw new JavaException("java.lang.UnsupportedOperationException", "Java (hxmc.java) needs Linux, Android or macOS", "", null);

	// whether there is JNI on this target (Linux, Android, macOS); the
	// std's Java operations throw elsewhere (a test Lower folds)
	static inline function available():Bool
		return hxmc.unsafe.Mem.os() == 0 || hxmc.unsafe.Mem.os() == 1;
}
