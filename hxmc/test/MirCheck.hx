import Harness.*;
import haxe.io.Path;
import sys.FileSystem;

// The Mir lane (make mir-check; CI's test jobs, on each machine but Intel
// Macs): the native compiler with Mir macros and --run (bin/npm/native/<host>/haxe)
//   <eval> -cp hxmc/test -cp haxe/test --run MirCheck --eval <eval> --haxe <haxe> --reference <haxe> [-j N] [--summary <file>] [case ...]
// - the corpus run inside the compiler on the Mir interpreter (Corpus
//   --mir-run; the cases known to fail there: Corpus.MIR_RUN_KNOWN);
// - the macro cases with Mir macros against the reference (Conformance
//   --target-only; known: KNOWN);
// - Mir macros' compiled functions kept across builds (MirCacheCheck);
// - Mir macros' statics in the compilation server, against the reference's
//   (MirServerCheck; not on Windows: the servers run through /bin/sh).
// HXMC_STD: hxmc's std for the macro context. Each part runs; exits 1 if one
// failed.
class MirCheck {
	// (Issue11631 uses Eval's own mbedtls package)
	static final KNOWN = ["eval-Issue11631-compile"];

	static function main() {
		var a = parseArgs(Sys.args(), ["--eval", "--haxe", "--reference", "-j", "--summary"]);
		var eval = a.get("--eval"), haxe = a.get("--haxe"), ref = a.get("--reference");
		if (eval == null || haxe == null || ref == null) fail("usage: MirCheck --eval <eval> --haxe <haxe> --reference <haxe> [-j N] [--summary <file>] [case ...]");
		if (Sys.getEnv("HXMC_STD") == null) fail("MirCheck: HXMC_STD (hxmc's std for the macro context)");
		var jobs = a.get("-j", "4"), summary = a.has("--summary") ? ["--summary", a.get("--summary")] : [];
		// (forward slashes: the port's command runs through a shell, Windows too)
		haxe = Path.normalize(FileSystem.fullPath(haxe));
		Sys.putEnv("HXMC_HAXE", haxe);
		Sys.putEnv("HAXE_REFERENCE", Path.normalize(FileSystem.fullPath(ref)));
		var parts = [
			{name: "corpus", args: ["Corpus", "--mir-run", "-v", "-j", jobs].concat(a.rest)},
			{name: "cache", args: ["MirCacheCheck"]}
		];
		if (!windows) parts.push({name: "server", args: ["MirServerCheck"]});
		// (last: it sets the port the harnesses before it would take)
		parts.push({name: "macros", args: ["Conformance", "-j", jobs, "--cases", "haxe/test/conformance-macro-cases.txt", "--target-only", "--parallel", "1", "--known", KNOWN.join(",")].concat(summary)});
		var failed = [];
		for (p in parts) {
			Sys.println('== Mir lane: ${p.name}');
			if (p.name == "macros") Sys.putEnv("HAXE_IN_HAXE_PORT", haxe + " -D hxmc.macros=mir");
			if (Sys.command(eval, ["-cp", "hxmc/test", "-cp", "haxe/test", "--run"].concat(p.args)) != 0) failed.push(p.name);
		}
		if (failed.length > 0) fail("MirCheck: failed: " + failed.join(", "));
		Sys.println("MirCheck: all passed");
	}
}
