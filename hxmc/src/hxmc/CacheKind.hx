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
}
