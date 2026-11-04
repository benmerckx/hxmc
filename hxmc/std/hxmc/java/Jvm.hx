package hxmc.java;

import hxmc.unsafe.*;

// The Java VM a program's Java calls go to (docs/interop.md, "Java (JNI)"):
// one per process, found in one of three ways.
//
// - **Embedded** (create): libjvm opened at run time (dlopen; libjvm), its
//   JNI_CreateJavaVM given the options (-Djava.class.path=..., -Xcheck:jni);
//   a JVM the process has already (JNI_GetCreatedJavaVMs) is used instead.
// - **Loaded into a JVM** (onLoad): the program is a shared library
//   (-D hxmc.shared, -D hxmc.exports=JNI_OnLoad) that Java loads
//   (System.loadLibrary); its JNI_OnLoad calls onLoad, which keeps the JVM
//   and the class loader of the loading code, then runs main on a thread of
//   its own and waits for it.
// - **An Android activity's** (useActivity): ANativeActivity's vm, and its
//   class loader (the app's, which knows classes.dex's).
//
// Calls attach the threads that make them (as daemon threads, detached as
// they end); a thread the runtime did not start that Java calls on (a
// native method) is attached to the runtime as COM's are.
class Jvm {
	// whether a JVM is there (made, found, or given)
	public static var exists(get, never):Bool;

	static function get_exists():Bool {
		if (!@:privateAccess JavaException.available()) return false;
		return @:privateAccess hxmc.rt.JniKind.hasVm();
	}

	// a JVM embedded with these options (nothing when there is one): libjvm
	// found by libjvm(); Java's own -Djava.class.path is CLASSPATH's when the
	// options give none. Throws a JavaException when it cannot be made
	public static function create(?options:Array<String>, ?lib:String):Void {
		if (!@:privateAccess JavaException.available()) {
			@:privateAccess JavaException.unavailable();
			return;
		}
		if (exists) return;
		var opts = options != null ? options.copy() : [];
		var cp = Sys.getEnv("CLASSPATH");
		if (cp != null && !Lambda.exists(opts, o -> StringTools.startsWith(o, "-Djava.class.path="))) opts.push("-Djava.class.path=" + cp);
		var path = lib != null ? lib : libjvm();
		if (path == null) throw new JavaException("java.lang.UnsatisfiedLinkError", "no libjvm: set JAVA_HOME (or HXMC_LIBJVM)", "", null);
		var err = @:privateAccess hxmc.rt.JniKind.create(path, opts);
		if (err != null) throw new JavaException("java.lang.UnsatisfiedLinkError", err, "", null);
	}

	// where create finds libjvm: HXMC_LIBJVM (the file), else in the JDK or
	// JRE of JAVA_HOME (lib/server/libjvm.so, JDK 9 on; jre/lib/<arch>/server
	// for 8; libjvm.dylib on macOS), else the system's default JDK
	// (/usr/lib/jvm/default-java), else the loader's search for libjvm.so
	public static function libjvm():Null<String> {
		var given = Sys.getEnv("HXMC_LIBJVM");
		if (given != null && given != "") return given;
		var ext = Mem.os() == 1 ? "dylib" : "so";
		var arch = Mem.arm() ? "aarch64" : "amd64";
		var homes = [];
		for (v in ["JAVA_HOME", "JDK_HOME"]) {
			var h = Sys.getEnv(v);
			if (h != null && h != "") homes.push(h);
		}
		if (Mem.os() == 0) homes.push("/usr/lib/jvm/default-java");
		for (h in homes)
			for (sub in ["lib/server", "jre/lib/server", 'jre/lib/$arch/server', "lib/client"]) {
				var p = '$h/$sub/libjvm.$ext';
				if (sys.FileSystem.exists(p)) return p;
			}
		return Mem.os() == 1 ? null : "libjvm.so";
	}

	// JNI_OnLoad's JVM (no Haxe code has run: the runtime starts here, its
	// main run on a thread of its own, waited for): JNI's version, or -1.
	//   @:hxmc.export("JNI_OnLoad") @:hxmc.unsafe static function onLoad(vm:Ptr, reserved:Ptr):Int
	//     return hxmc.java.Jvm.onLoad(vm);
	@:hxmc.unsafe public static function onLoad(vm:Ptr):Int {
		if (!@:privateAccess JavaException.available()) return -1;
		return @:privateAccess hxmc.rt.JniKind.onLoad(vm);
	}

	// an Android activity's JVM and class loader (its ANativeActivity)
	public static function useActivity(activity:Ptr):Void {
		if (!@:privateAccess JavaException.available()) {
			@:privateAccess JavaException.unavailable();
			return;
		}
		@:privateAccess hxmc.rt.JniKind.useActivity(activity);
	}
}
