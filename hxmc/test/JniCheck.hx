import Harness.*;
import sys.FileSystem;

using StringTools;

// Java through JNI (docs/interop.md, "Java (JNI)"):
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run JniCheck
// - the corpus's JNI cases (Corpus.JNI: an embedded JVM, libjvm opened at
//   run time) in the dynamic glibc mode on linux-x86_64, and again with
//   RT_VERIFY=1, and JniElsewhere (Java without a JVM);
// - hxmc's code loaded into a JVM: hxmc/test/jni/JniLib.hx as a shared
//   library exporting JNI_OnLoad (libhxjni.so), the glue of its manifest
//   (JniGlue) and JniHost.java compiled, `java` loading it
//   (System.loadLibrary) and calling the Haxe object its main registered,
//   from Java's threads;
// - the same library and the JNI cases cross-built for android-arm64 and
//   android-x86_64 (not run: the emulator's runs are helder's), the
//   library's JNI_OnLoad exported.
// Without a JDK (JAVA_HOME, CI's JAVA_HOME_21_X64, or javac on PATH) the
// runs are skipped, the cross builds still made.
class JniCheck {
	static final OUT = "bin/hxmc-jni";
	static var failures:Array<String> = [];

	static function check(what:String, ok:Bool, detail = "") {
		Sys.println(pad(what, 56) + " " + (ok ? "ok" : "FAIL") + (detail != "" ? "  " + detail : ""));
		if (!ok) failures.push(what);
	}

	static function skip(what:String, why:String)
		Sys.println(pad(what, 56) + " skipped  " + why);

	static function main() {
		var tool = FileSystem.fullPath(Sys.getEnv("HXMC_TOOL") ?? "bin/hxmc/hxmc");
		var jdk = Corpus.jdk();
		var cases = [for (k in Corpus.JNI.keys()) k];
		cases.sort(compare);
		cases.push("JniElsewhere");
		// the corpus's cases
		if (jdk == null) skip("the JNI cases (an embedded JVM)", "no JDK (JAVA_HOME, or javac on PATH)");
		else
			for (verify in [false, true]) {
				var r = exec([tool, "-cp", "hxmc/test", "-cp", "haxe/test", "--run", "Corpus", "--libc", "glibc"].concat(cases),
					{env: ["RT_VERIFY" => verify ? "1" : null, "JAVA_HOME" => jdk], merge: true});
				var last = r.out.trim().split("\n").pop();
				check("the JNI cases, glibc mode" + (verify ? ", RT_VERIFY=1" : ""), r.code == 0 && !r.out.contains("excluded"), r.code == 0 ? last : tail(r.out, 1200));
			}
		// hxmc's code loaded into a JVM
		function build(out:String, args:Array<String>):Bool {
			var r = exec([tool, out, "-cp", "hxmc/test/jni", "-cp", "bin/hxmc/std", "-main", "JniLib", "--custom-target", "hxmc", "-D", "disable-parallelism", "-D", "hxmc.exports=JNI_OnLoad"].concat(args), {merge: true});
			if (r.code != 0) Sys.println(tail(r.out, 800));
			return r.code == 0;
		}
		var dir = '$OUT/linux-x86_64';
		mkdirs(dir);
		var lib = '$dir/libhxjni.so';
		var ok = build(lib, ["-D", "hxmc.libc=glibc", "-D", "hxmc.shared", "-D", "hxmc.target=linux-x86_64"]);
		check("linux-x86_64 glibc: JniLib as libhxjni.so builds", ok);
		check("linux-x86_64 glibc: its manifest lists its proxy", FileSystem.exists(lib + ".jni.json") && sys.io.File.getContent(lib + ".jni.json").contains("org.hxmc.proxy.Echo"));
		if (ok && jdk != null) {
			var classes = '$dir/classes';
			rmrf(classes);
			mkdirs(classes);
			var sources = JniGlue.generate(lib + ".jni.json", '$dir/glue').concat(["hxmc/test/jni/JniHost.java"]);
			var c = exec(['$jdk/bin/javac', "-nowarn", "-d", classes].concat(sources), {merge: true});
			check("the glue and JniHost.java compile", c.code == 0, c.code == 0 ? "" : tail(c.out, 600));
			if (c.code == 0) {
				var r = exec(['$jdk/bin/java', "-Xcheck:jni", "-Djava.library.path=" + FileSystem.fullPath(dir), "-cp", classes, "jnihost.JniHost"],
					{merge: true, timeout: 120, env: ["RT_MINOR_KB" => "64"]});
				// (the program's lines; -Xcheck:jni's report of the fault handler the
				// runtime put before the JVM's, which it passes every other fault, may
				// share a line with one)
				var line = ~/(java|haxe): .*/;
				var got = [for (l in r.out.split("\n")) if (line.match(l)) line.matched(0)].join("\n");
				var want = [
					"haxe: main runs at load, an attached thread, Jvm.exists true",
					"java: loaded, a handler true, org.hxmc.proxy.Echo",
					"java: ab-ab-ab #1 on main",
					"java: t-t #2 on worker",
					"java: many calls done true",
					"java: after #1003 on main",
					"java: caught org.hxmc.HaxeException: no string"
				].join("\n");
				check("java loads it (JNI_OnLoad), calls Haxe from its threads", r.code == 0 && got == want, r.code == 0 && got == want ? "" : 'exit ${r.code}\n' + tail(r.out, 1500));
			}
		} else if (ok)
			skip("java loads it (JNI_OnLoad)", "no JDK");
		// Android: the library and the cases cross-built
		for (t in ["android-arm64", "android-x86_64"]) {
			var d = '$OUT/$t';
			mkdirs(d);
			var lib = '$d/libhxjni.so';
			var ok = build(lib, ['-D', 'hxmc.target=$t']);
			check('$t: JniLib as libhxjni.so builds', ok);
			if (ok && exec(["sh", "-c", "command -v readelf"]).code == 0) {
				var syms = exec(["readelf", "-W", "--dyn-syms", lib]).out;
				check('$t: JNI_OnLoad exported', ~/GLOBAL\s+DEFAULT\s+\d+\s+JNI_OnLoad/.match(syms));
			}
			for (c in cases) {
				var r = exec([tool, '$d/lib$c.so', "-cp", "hxmc/test/cases", "-cp", "bin/hxmc/std", "-main", c, "--custom-target", "hxmc", "-D", "disable-parallelism", "-D", 'hxmc.target=$t'], {merge: true});
				check('$t: $c builds', r.code == 0, r.code == 0 ? "" : tail(r.out, 600));
			}
		}
		if (failures.length > 0) {
			Sys.println("JniCheck: " + failures.length + " failed");
			Sys.exit(1);
		}
		Sys.println("JniCheck: all passed");
	}
}
