import Harness.*;

using StringTools;

// The x86-64 and AArch64 encoders against llvm-mc:
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run EncCheck [--arch x64|a64]
// Runs hxmc/test/encoder/EncTest.hx (or EncTestA64.hx) on Eval, which prints
// `<assembly>|<hex bytes>` per instruction, assembles the same text with
// llvm-mc and compares the encodings.
class EncCheck {
	static function main() {
		var a = parseArgs(Sys.args(), ["--arch"]);
		var x64 = a.get("--arch", "x64") == "x64";
		var r = exec([Sys.getEnv("HXMC_TOOL") ?? "bin/hxmc/hxmc", "-cp", "hxmc/src", "-cp", "haxe/src", "-cp", "hxmc/test/encoder", "--run", x64 ? "EncTest" : "EncTestA64"], {merge: true});
		if (r.code != 0) fail(r.out);
		var cases = [for (l in r.out.split("\n")) if (l.contains("|")) {var i = l.lastIndexOf("|"); {text: l.substr(0, i), hex: l.substr(i + 1)};}];
		var src = (x64 ? ".intel_syntax noprefix\n" : "") + [for (c in cases) c.text].join("\n") + "\n";
		var input = tempName() + ".s";
		sys.io.File.saveContent(input, src);
		var mc = exec(["llvm-mc", x64 ? "-triple=x86_64" : "-triple=aarch64", "--show-encoding", input]);
		sys.FileSystem.deleteFile(input);
		if (mc.code != 0) fail(mc.err.substr(0, 3000));
		var re = ~/encoding: \[([^\]]*)\]/;
		var encs = [];
		for (line in mc.out.split("\n"))
			if (re.match(line)) encs.push([for (b in re.matched(1).split(",")) b.trim().substr(2).lpad("0", 2)].join("").toLowerCase());
		if (encs.length != cases.length) fail('llvm-mc produced ${encs.length} encodings for ${cases.length} lines');
		var bad = 0;
		for (i in 0...cases.length)
			if (cases[i].hex != encs[i]) {
				if (bad++ < 40) Sys.println('MISMATCH ${pad(cases[i].text, 50)} ours ${pad(cases[i].hex, 24)} llvm-mc ${encs[i]}');
			}
		Sys.println('${cases.length - bad}/${cases.length} encodings match');
		Sys.exit(bad > 0 ? 1 : 0);
	}
}
