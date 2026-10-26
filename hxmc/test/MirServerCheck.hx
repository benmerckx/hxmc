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
// Context.error ends its macro only. And an uncaught exception of macro code
// is reported at the line it was thrown on, then its callers' lines (through
// recursion, a lambda, a callback of the compiler, a build macro): those
// lines expected (EXPECTED), the exit code the reference's. In
// bin/hxmc-t/mir-server (removed when every check passes):
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

	// uncaught exceptions of macro code: where they were thrown, called from where
	static final EXCEPTIONS = [
		"E.hx" => "import haxe.macro.Context;

class E {
	public static function boom() {
		throw \"boom\";
	}

	static function deep(n:Int) {
		if (n == 0) inner(); else deep(n - 1);
	}

	static function inner() {
		var o:Dynamic = null;
		helper(o);
	}

	static function helper(o:Dynamic) {
		throw \"deep \" + Std.string(o);
	}

	public static function rec() {
		deep(3);
	}

	public static function err() {
		throw new haxe.macro.Expr.Error(\"an error\", Context.currentPos());
	}

	public static function lam() {
		[1, 2].map(x -> x == 2 ? throw \"in lambda\" : x);
	}

	public static function caught() {
		try boom() catch (e:String) {}
		throw \"after catch\";
	}

	public static function exc() {
		throw new haxe.Exception(\"exc\");
	}

	public static function callback() {
		Context.onAfterTyping(_ -> fail(\"in callback\"));
	}

	static function fail(s:String) {
		throw s;
	}

	public static function rethrow() {
		try fail(\"first\") catch (e:String) throw e + \" again\";
	}

	public static macro function build():Array<haxe.macro.Expr.Field> {
		fail(\"in build\");
		return null;
	}
}
",
		"Built.hx" => "@:build(E.build()) class Built {
	public function new() {}
}
",
		"UseBuilt.hx" => "class UseBuilt {
	static function main() {
		new Built();
	}
}
",
	];

	// (one message per line, the frames' positions as written)
	static final CLASSIC = ["-D", "message.reporting=classic"];

	// what each one reports: at the line of its innermost frame of macro code
	// (a function without calls of its own, inlined, is its caller's), then
	// each caller's line, the macro call last (unknown: --macro's)
	static final EXPECTED = [
		{name: "boom", lines: ["E.hx:5: characters 1-16 : Uncaught exception boom\n(unknown) : Called from here"]},
		{
			name: "rec",
			lines: [
				"E.hx:9: characters 1-41 : Uncaught exception deep null\nE.hx:9: characters 1-41 : Called from E.deep (3 times)\nE.hx:22: characters 1-11 : Called from E.rec\n(unknown) : Called from here"
			]
		},
		{name: "err", lines: ["(unknown) : an error"]},
		{name: "lam", lines: ["E.hx:30: characters 1-51 : Uncaught exception in lambda\nE.hx:30: characters 1-51 : Called from E.lam\n(unknown) : Called from here"]},
		{name: "caught", lines: ["E.hx:35: characters 1-23 : Uncaught exception after catch\n(unknown) : Called from here"]},
		{name: "exc", lines: ["E.hx:39: characters 1-35 : Uncaught exception exc\n(unknown) : Called from here"]},
		{name: "callback", lines: ["E.hx:43: characters 1-51 : Uncaught exception in callback"]},
		{name: "rethrow", lines: ["E.hx:51: characters 1-57 : Uncaught exception first again\n(unknown) : Called from here"]},
		{name: "build", lines: ["E.hx:55: characters 1-20 : Uncaught exception in build\nBuilt.hx:1: characters 1-8 : Called from here"]},
		{name: "boom-again", lines: ["E.hx:5: characters 1-16 : Uncaught exception boom\n(unknown) : Called from here"]},
	];

	static function macros(names:Array<String>):Array<String> {
		var a = [];
		for (n in names)
			a = a.concat(["--macro", n]);
		return a;
	}

	static final SCENARIOS:Array<{name:String, files:Map<String, String>, steps:Array<{name:String, ?edit:Map<String, String>, args:Array<String>, ?expect:Array<String>}>}> = [
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
			name: "exceptions",
			files: EXCEPTIONS,
			steps: [
				for (e in EXPECTED)
					{name: e.name, args: CLASSIC.concat(e.name == "build" ? ["-main", "UseBuilt"] : macros(["E." + (e.name == "boom-again" ? "boom" : e.name) + "()"])), expect: e.lines}
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
				var args = ["-cp", ".", "--interp", "--no-output"].concat(s.args.indexOf("-main") < 0 ? ["-main", "Main"] : []).concat(s.args);
				var a = client([ref], r.port, args, proj);
				var b = client(mir, p.port, args, proj);
				var what = '${sc.name}:${s.name}';
				// (expected lines: the reference's exit code, and these lines in the report)
				var same = s.expect != null ? a.code == b.code && Lambda.foreach(s.expect, l -> (b.out + b.err).indexOf(l) >= 0) : a.code == b.code && a.out == b.out && a.err == b.err;
				if (same) {
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
