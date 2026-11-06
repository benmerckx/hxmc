package hxmc.java;

// java.lang.CharSequence as the declarations of a jar (--java-lib) have it
// (codegen.JavaModern, hxmc.ir.Jni): a String (a java.lang.String at the
// call, as a String parameter's) or a Java CharSequence (a Spanned, a
// StringBuilder). A result is a String when Java's is one, else the Java
// object. The jar's own java.lang.CharSequence is referred to only here, so
// this is typed only where a jar declares it.
abstract CharSequence(Dynamic) from String from java.lang.CharSequence to java.lang.CharSequence {
	// its characters: a String's own, a Java object's toString()
	public inline function toString():String
		return Std.isOfType(this, String) ? this : Java.toString(this);
}
