import Harness.*;
import Server.client;
import Server.startServer;
import Server.stopServer;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// Mir macros' statics in the compilation server against Eval's (docs/hxmc.md,
// "Macros on the Mir interpreter"): projects whose init macros keep state in
// statics, compiled through edits on a server of the reference and one of the
// port with Mir macros (-D hxmc.macros=mir); every request's exit code and
// output must agree. What they show: initialized statics start again every
// compilation (EvalMain.doReuse: in the order of the classes' paths' hashes)
// and uninitialized ones do not; __init__ runs again; a batch's classes are
// initialized in the order they were handed over; a type typed again starts
// its statics again while the others keep theirs, also when the macro
// context is typed again partway through a compilation (a new generation of
// Mir bundles: a class not typed again carries its statics over); a macro
// first called in a later compilation shares the statics the earlier ones
// set (the module's types handed over again as other objects); a closure
// kept from an earlier compilation reads the statics of its own class; a
// Context.error ends its macro only. In bin/hxmc-t/mir-server (removed when
// every check passes):
//   HXMC_HAXE=<haxe> HAXE_REFERENCE=<haxe> bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run MirServerCheck
class MirServerCheck {
	static final MAIN = "class Main {\n\tstatic function main() {}\n}\n";

	// init order, resets, __init__, an edited dependency, errors
	static final PROBE = [
		"Probe.hx" => "class Dep {
	public static var log:Array<String> = [];
}

class Probe {
	static var initInt = 5;
	static var initStr = \"s\";
	static var initArr = [1];
	static final finArr = [10];
	static var prop(default, null) = 7;
	static var noInitInt:Int;
	static var noInitArr:Array<Int>;
	static var noInitFn:Void->String;
	static var fromInit:Int;

	static function __init__() {
		fromInit = (fromInit == null ? 0 : fromInit) + 100;
		Dep.log.push(\"init\");
	}

	public static function fail() {
		haxe.macro.Context.error(\"boom\", haxe.macro.Context.currentPos());
	}

	public static function run() {
		initInt++;
		initStr += \"!\";
		initArr.push(initArr.length + 1);
		finArr.push(0);
		prop++;
		noInitInt = (noInitInt == null ? 0 : noInitInt) + 1;
		if (noInitArr == null) noInitArr = [];
		noInitArr.push(noInitArr.length);
		var prevFn = noInitFn == null ? \"none\" : noInitFn();
		var stamp = Other.stamp();
		noInitFn = () -> \"fn@\" + stamp + \" initInt=\" + initInt + \" other=\" + Other.counter;
		Other.counter++;
		fromInit++;
		Sys.println('initInt=$initInt initStr=$initStr initArr=$initArr finArr=$finArr prop=$prop noInitInt=$noInitInt '
			+ 'noInitArr=$noInitArr fromInit=$fromInit log=${Dep.log} other=${Other.counter}/${Other.bump()} prevFn=[$prevFn]');
	}
}
",
		"Other.hx" => "class Other {
	public static var counter = 0;
	static var untouched:Int;

	public static function bump():Int {
		untouched = (untouched == null ? 0 : untouched) + 1;
		return untouched;
	}

	public static function stamp():String
		return \"v1\";
}
",
	];

	// unchanged classes keep their statics when another is typed again
	static final REGISTRY = [
		"Registry.hx" => "class Registry {
	public static var make:Void->(Void->String);
	public static var bump:Void->Void;
}
",
		"Changing.hx" => "class Changing {
	public static var n = 0;
	public static var arr = [0];
	static var noInit:Int;

	public static function touch() {
		Registry.make = make;
		Registry.bump = bump;
	}

	public static function bump() {
		n++;
		arr.push(n);
		noInit = (noInit == null ? 0 : noInit) + 1;
	}

	public static function make()
		return () -> 'v1 n=$n arr=$arr noInit=$noInit';
}
",
		"Unrelated.hx" => "class Unrelated {
	static var u:Int;

	public static function run() {
		u = (u == null ? 0 : u) + 1;
		Sys.println('unrelated u=$u v1');
	}
}
",
		"Keeper.hx" => "class Keeper {
	static var fn:Void->String;
	static var hits:Int;
	static var kept = 0;

	public static function run() {
		hits = (hits == null ? 0 : hits) + 1;
		kept++;
		var prev = fn == null ? \"none\" : fn();
		fn = Registry.make();
		Registry.bump();
		Sys.println('hits=$hits kept=$kept prev=[$prev] now=[${fn()}]');
	}
}
",
	];

	// a macro first called in a later compilation
	static final LATER = [
		"Reg.hx" => "class Reg {
	public static var hits = 0;
	public static var obj:Array<Int>;
}
",
		"A.hx" => "class A {
	public static function run() {
		Reg.hits++;
		if (Reg.obj == null) Reg.obj = [];
		Reg.obj.push(1);
		Sys.println('A hits=${Reg.hits} obj=${Reg.obj}');
	}
}
",
		"B.hx" => "class B {
	public static function run() {
		Reg.hits++;
		if (Reg.obj == null) Reg.obj = [];
		Reg.obj.push(2);
		Sys.println('B hits=${Reg.hits} obj=${Reg.obj}');
	}
}
",
	];

	static function macros(names:Array<String>):Array<String> {
		var a = [];
		for (n in names)
			a = a.concat(["--macro", n]);
		return a;
	}

	static final SCENARIOS:Array<{name:String, files:Map<String, String>, steps:Array<{name:String, ?edit:Map<String, String>, args:Array<String>}>}> = [
		{
			name: "probe",
			files: PROBE,
			steps: [
				{name: "first", args: macros(["Probe.run()"])},
				{name: "second", args: macros(["Probe.run()"])},
				{name: "edit-dependency", edit: ["Other.hx" => PROBE["Other.hx"].replace("v1", "v2")], args: macros(["Probe.run()"])},
				{name: "after-edit", args: macros(["Probe.run()"])},
				{name: "without-macro", args: []},
				{name: "macro-again", args: macros(["Probe.run()"])},
				{name: "type-error", edit: ["Main.hx" => "class Main {\n\tstatic function main() {\n\t\tvar x:Int = \"no\";\n\t}\n}\n"], args: macros(["Probe.run()"])},
				{name: "fixed", edit: ["Main.hx" => MAIN], args: macros(["Probe.run()"])},
				{name: "context-error", args: macros(["Probe.fail()", "Probe.run()"])},
				{name: "after-context-error", args: macros(["Probe.run()"])},
			]
		},
		{
			name: "registry",
			files: REGISTRY,
			steps: [
				{name: "first", args: macros(["Changing.touch()", "Unrelated.run()", "Keeper.run()"])},
				{name: "second", args: macros(["Changing.touch()", "Unrelated.run()", "Keeper.run()"])},
				{name: "edit-unrelated", edit: ["Unrelated.hx" => REGISTRY["Unrelated.hx"].replace("v1", "v2")], args: macros(["Changing.touch()", "Unrelated.run()", "Keeper.run()"])},
				{name: "after-edit", args: macros(["Changing.touch()", "Unrelated.run()", "Keeper.run()"])},
				{name: "edit-changing", edit: ["Changing.hx" => REGISTRY["Changing.hx"].replace("v1", "v2")], args: macros(["Changing.touch()", "Unrelated.run()", "Keeper.run()"])},
				{name: "after-second-edit", args: macros(["Changing.touch()", "Unrelated.run()", "Keeper.run()"])},
			]
		},
		{
			name: "later",
			files: LATER,
			steps: [
				{name: "a", args: macros(["A.run()"])},
				{name: "a-then-b", args: macros(["A.run()", "B.run()"])},
				{name: "b-then-a", args: macros(["B.run()", "A.run()"])},
			]
		},
	];

	static var failures = 0;

	static function main() {
		var port = Sys.getEnv("HXMC_HAXE");
		var ref = Sys.getEnv("HAXE_REFERENCE");
		if (port == null || ref == null) fail("set HXMC_HAXE (the compiler) and HAXE_REFERENCE (the reference compiler)");
		var dir = FileSystem.fullPath(".") + "/bin/hxmc-t/mir-server";
		rmrf(dir);
		mkdirs(dir);
		var mir = [port, "-D", "hxmc.macros=mir"];
		for (sc in SCENARIOS) {
			var proj = '$dir/${sc.name}';
			mkdirs(proj);
			File.saveContent('$proj/Main.hx', MAIN);
			for (f => text in sc.files)
				File.saveContent('$proj/$f', text);
			var r = startServer("reference", [ref], '$dir/${sc.name}-reference.log');
			var p = startServer("port", mir, '$dir/${sc.name}-port.log');
			for (s in sc.steps) {
				if (s.edit != null) {
					Sys.sleep(1.1); // file times have one-second resolution on some hosts
					for (f => text in s.edit)
						File.saveContent('$proj/$f', text);
				}
				var args = ["-cp", ".", "-main", "Main", "--interp", "--no-output"].concat(s.args);
				var a = client([ref], r.port, args, proj);
				var b = client(mir, p.port, args, proj);
				var what = '${sc.name}:${s.name}';
				if (a.code == b.code && a.out == b.out && a.err == b.err) {
					Sys.println("ok    " + what);
				} else {
					failures++;
					Sys.println("FAIL  " + what);
					for (x in [{who: "reference", o: a}, {who: "mir", o: b}])
						Sys.println('      ${x.who} (exit ${x.o.code}):\n' + [for (l in (x.o.out + x.o.err).trim().split("\n")) "        " + l].join("\n"));
				}
			}
			stopServer(r);
			stopServer(p);
		}
		if (failures > 0) {
			Sys.println('MirServerCheck: $failures failures (in $dir)');
			Sys.exit(1);
		}
		rmrf(dir);
		Sys.println("MirServerCheck: all ok");
	}
}
