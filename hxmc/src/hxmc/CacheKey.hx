package hxmc;

// The key of an entry of the store: a hash of its content and of the hashes
// of what it depends on (their interfaces, or their whole contents), with
// the kind of entry first. Two entries have the same key when they were made
// from the same inputs; the key is also the entry's file name.
abstract CacheKey(String) to String {
	inline function new(s:String)
		this = s;

	public var kind(get, never):CacheKind;

	inline function get_kind():CacheKind
		return cast this.charAt(0);

	// the key of content and of the hashes of its dependencies, in that order
	public static function of(kind:CacheKind, content:String, ?deps:Array<String>):CacheKey {
		var b = new StringBuf();
		b.add(kind);
		b.add("\x00");
		b.add(content);
		if (deps != null)
			for (d in deps) {
				b.add("\x00");
				b.add(d);
			}
		return new CacheKey(kind + Fingerprint.hash(b.toString()));
	}

	// the key of a hash its user made already (Fingerprint's key of a
	// function's or a module's code, which hashes its dependencies' digests)
	public static function ofHash(kind:CacheKind, hash:String):CacheKey
		return new CacheKey(kind + hash);
}
