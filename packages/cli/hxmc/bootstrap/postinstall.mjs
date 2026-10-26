// @hxmc/cli's postinstall (best effort: never fails the install, no
// network, writes only inside the package): the native compiler of the
// platform package (@hxmc/<os>-<cpu>) in place of the launcher, once it is
// seen to run here (not on a noexec file system, in a sandbox without
// processes, ...), so that on Unix
// node_modules/.bin/haxe runs it without node (on Windows npm's haxe.cmd always
// starts node; dist/haxe.exe is the native compiler for editors and lix).
// With install scripts disabled, the launcher does the same on its first call.
// (Not while hxmc-rebuild's compiler is in use: that one runs through the
// launcher.)
try {
	const { install, nativeRuns, platformBinary, rebuilt, setupDist } = await import('./launcher.mjs');
	setupDist();
	const native = platformBinary();
	if (native && !rebuilt() && nativeRuns(native)) install(native);
} catch {
	// (the launcher still works)
}
process.exit(0);
