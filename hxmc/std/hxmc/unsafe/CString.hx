package hxmc.unsafe;

// C's `const char *`: a NUL-terminated string of UTF-8 bytes outside the
// GC heap (docs/interop.md, "C interop"). Made by Arena.cstring (copied
// once into the arena); read back as a Haxe String with toString.
abstract CString(Ptr<UInt8>) from Ptr<UInt8> to Ptr<UInt8> {
	public inline function isNull():Bool
		return this.isNull();

	// the length in bytes, without the NUL
	public inline function length():Int
		return LibC.strlen(this).toInt();

	// a Haxe String decoded from the UTF-8 bytes (null for a null pointer)
	public function toString():String
		return this.isNull() ? null : hxmc.rt.Str.ofUtf8(this, length());

	@:to inline function toVoid():Ptr<Void>
		return this;
}
