package hxmc;

// What an entry of the store is (CacheStore.hx): its first character in the key,
// so that two kinds of entry never share a name.
enum abstract CacheKind(String) to String {
	// a class path's typed modules (ModuleCache: the working directory, the
	// class paths and the std)
	var ModuleIndex = "m";
	// the objects an output's last build used (Driver), or a command line's
	// Mir macros (interp.BundleCache): what the trim keeps
	var ObjectList = "l";
	// an output's up-to-date record (UpToDate)
	var BuildRecord = "u";
	// a module's object (Driver)
	var ModuleObject = "o";
	// a Mir macro function's object (interp.BundleCache)
	var MacroFunction = "f";
	// a typed module: its file's content, the reads it was typed with and
	// the hashes its dependencies had (Variant.typedKey); a variant of a
	// module index today, the name of its later stages' entries
	var TypedModule = "t";
	// a module's lowered bodies (LoweredBodies): its TypedModule key and what
	// the lowering and the filters read beyond the module's dependencies
	var LoweredBodies = "b";
	// not entries: what a module's dependents check it by (ModuleCache's
	// Closure), the hash of its interface with its dependencies', or of its
	// whole content with theirs
	var Interface = "n";
	var Content = "w";
}
