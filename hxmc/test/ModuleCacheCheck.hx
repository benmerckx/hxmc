import Harness.*;
import sys.FileSystem;
import sys.io.File;

using StringTools;

// The gate of the persistent module cache (hxmc/src/hxmc/ModuleCache.hx,
// docs/plans/compiler.md, "Cached modules"): every build with the cache writes the same
// output, byte for byte, as the same build without it, through a cold run
// (an empty cache), a warm run, a run after a file's date changes (the same
// content), after an edit of one module, after an edit of a std override,
// after a new file shadows a module, and back. For the hxmc target (the tool,
// and `haxe` with hxmc built in for the hello world), JS and Eval (`haxe
// --interp`: what the program prints), on a
// hello world, a program of several modules (interfaces, a @:generic class,
// inline functions across modules, enums, abstracts, static
// initialization), one with macros (a build macro, an expression macro
// reading a file through Context with its dependency registered), one
// whose typed program keeps a Null<Unknown> (a monomorph's modifier, which
// HXB does not keep), and one for the finer keys and the early cutoff: a
// define no module reads (nothing typed again), a define one module's
// condition reads in a body (that module only), a body edited in a
// dependency (only it typed again, its dependents restored), an inline
// function edited (its dependents typed again), a body edited in a cycle
// (only that module), and one whose build macro keeps state another macro
// reads (restored while no macro of the build uses that state, else the
// build runs again with those modules typed). Three for modules typed again
// under restored ones that refer to them: an interface's property read
// through the accessor Haxe makes for it (the interface edited, its user
// restored), a cycle whose edited module's class is built while a restored
// one of the cycle is read (and a field that one reads removed: the same
// errors; full DCE), and a build macro whose state another module's build
// macro forces (that module edited: typed again with it; then an error in
// it: the same errors as without the cache, then fixed). The warm runs must restore
// every module (none typed again), an edit undone restores the earlier
// variant. Copies of the std (hxmc's and upstream's) are edited, never the
// repository's. In bin/hxmc-t/module-cache (removed when every check passes):
//   bin/hxmc/hxmc -cp hxmc/test -cp haxe/test --run ModuleCacheCheck [--port] [--haxe <haxe>]
// --port adds the port itself (haxe/src: a large program) for the hxmc target;
// --nondet runs only the cases of macros whose results change from run to run,
// --late those of modules macros define outside the typing of a module;
// --haxe names `haxe` with hxmc built in (default: bin/npm/native/<host>/haxe).
class ModuleCacheCheck {
	static var dir:String;
	static var tool:String;
	// `haxe` with hxmc built in (HaxeMain: the npm package's compiler)
	static var haxeBin:String;
	static var failures = 0;
	static var builds = 0;

	static function check(what:String, ok:Bool) {
		Sys.println((ok ? "ok    " : "FAIL  ") + what);
		if (!ok) failures++;
	}

	static function write(path:String, s:String) {
		var d = haxe.io.Path.directory(path);
		if (d != "" && !FileSystem.exists(d)) mkdirs(d);
		File.saveContent(path, s);
	}

	// a program: its directory, files, the build arguments per target
	static function programs():Array<{name:String, files:Map<String, String>, args:Array<String>, edit:String, run:String}> {
		var hello = [
			"src/Main.hx" => 'class Main {\n\tstatic function main() {\n\t\ttrace("hello " + [1, 2, 3].map(x -> x * 2));\n\t\ttrace(StringTools.lpad("x", ".", 4));\n\t}\n}\n'
		];
		var multi = [
			"src/Main.hx" => [
				"import shapes.*;",
				"import util.Util;",
				"import util.Box;",
				"class Main {",
				"\tstatic function main() {",
				"\t\tvar shapes:Array<Shape> = [new Circle(1.5), new Square(2)];",
				"\t\tfor (s in shapes) trace(s.name() + \" \" + Util.round(s.area()));",
				"\t\tvar b = new Box<Int>(Util.twice(21));",
				"\t\ttrace(b.get() + \" \" + Util.label + \" \" + (Color.Red : Int));",
				"\t\tvar m:util.Meters = 3.5;",
				"\t\ttrace(m.toFeet());",
				"\t\tswitch Color.Green { case Green: trace(\"green\"); case _: }",
				"\t}",
				"}"
			].join("\n") + "\n",
			"src/shapes/Shape.hx" => "package shapes;\ninterface Shape {\n\tfunction area():Float;\n\tfunction name():String;\n}\n",
			"src/shapes/Circle.hx" => "package shapes;\nclass Circle implements Shape {\n\tvar r:Float;\n\tpublic function new(r) this.r = r;\n\tpublic function area() return Math.PI * r * r;\n\tpublic function name() return \"circle\";\n}\n",
			"src/shapes/Square.hx" => "package shapes;\nclass Square implements Shape {\n\tvar s:Float;\n\tpublic function new(s) this.s = s;\n\tpublic function area() return s * s;\n\tpublic function name() return \"square\";\n}\n",
			"src/Color.hx" => "enum abstract Color(Int) to Int {\n\tvar Red = 1;\n\tvar Green = 2;\n}\n",
			"src/util/Util.hx" => "package util;\nclass Util {\n\tpublic static var label = \"v\" + 1;\n\tpublic static inline function twice(x:Int) return x * 2;\n\tpublic static function round(f:Float) return Math.round(f * 100) / 100;\n}\n",
			"src/util/Box.hx" => "package util;\n@:generic class Box<T> {\n\tvar v:T;\n\tpublic function new(v:T) this.v = v;\n\tpublic function get():T return v;\n}\n",
			"src/util/Meters.hx" => "package util;\nabstract Meters(Float) from Float {\n\tpublic inline function toFeet():Float return this * 3.28084;\n}\n"
		];
		var macros = [
			"src/Main.hx" => [
				"@:build(Builder.build())",
				"class Main {",
				"\tstatic function main() {",
				"\t\ttrace(Builder.data());",
				"\t\ttrace(greeting());",
				"\t\ttrace(Other.twice(4));",
				"\t}",
				"}"
			].join("\n") + "\n",
			"src/Other.hx" => "class Other {\n\tpublic static function twice(x:Int) return x * 2;\n}\n",
			"src/Builder.hx" => [
				"import haxe.macro.Context;",
				"import haxe.macro.Expr;",
				"class Builder {",
				"\tpublic static macro function data():Expr {",
				"\t\tvar path = Context.resolvePath(\"data.txt\");",
				"\t\tContext.registerModuleDependency(Context.getLocalModule(), path);",
				"\t\treturn macro $v{sys.io.File.getContent(path)};",
				"\t}",
				"\tpublic static macro function build():Array<Field> {",
				"\t\tvar fields = Context.getBuildFields();",
				"\t\tvar n = fields.length;",
				"\t\tfields.push({name: \"greeting\", access: [AStatic, APublic], kind: FFun({args: [], ret: null, expr: macro return \"built \" + $v{n}}), pos: Context.currentPos()});",
				"\t\treturn fields;",
				"\t}",
				"}"
			].join("\n") + "\n",
			"src/data.txt" => "data one"
		];
		// (a monomorph Null<Unknown> left in the typed program: HXB does not
		// keep its modifier, the cache does)
		var lossy = [
			"src/Main.hx" => "class Main {\n\tstatic function main() {\n\t\tLossy.run();\n\t\ttrace(Other.x);\n\t}\n}\n",
			"src/Other.hx" => "class Other {\n\tpublic static var x = 3;\n}\n",
			"src/Lossy.hx" => "class Lossy {\n\tstatic function time<A, R>(f:A->R, arg:A):R return f(arg);\n\tpublic static function run() trace(time(function(_) return 1, null));\n}\n"
		];
		// (early cutoff and defines: a body edited, an interface edited, a
		// define one module reads, a cycle)
		var cutoff = [
			"src/Main.hx" => "class Main {\n\tstatic function main() {\n\t\ttrace(Calc.add(1, 2) + Calc.twice(3));\n\t\ttrace(Flags.mode());\n\t\ttrace(new User().run());\n\t\ttrace(Ping.ping(3));\n\t}\n}\n",
			"src/Calc.hx" => "class Calc {\n\tpublic static inline function twice(x:Int):Int return x * 2;\n\n\tpublic static function add(a:Int, b:Int):Int return a + b;\n}\n",
			"src/User.hx" => "class User {\n\tpublic function new() {}\n\n\tpublic function run():Int return Calc.add(10, 20);\n}\n",
			"src/Flags.hx" => "class Flags {\n\tpublic static function mode():String {\n\t\t#if fast\n\t\treturn \"fast\";\n\t\t#else\n\t\treturn \"safe\";\n\t\t#end\n\t}\n}\n",
			"src/Ping.hx" => "class Ping {\n\tpublic static function ping(n:Int):Int return n <= 0 ? 0 : 1 + Pong.pong(n - 1);\n}\n",
			"src/Pong.hx" => "class Pong {\n\tpublic static function pong(n:Int):Int return n <= 0 ? 0 : 10 + Ping.ping(n - 1);\n}\n"
		];
		// (a build macro keeping what other macros read: the classes an
		// @:autoBuild registers, checked by an expression macro of Main, which a
		// define types again, Impl restored: the build runs again; the gfx
		// package's shaders work so)
		var registry = [
			"src/Main.hx" => "class Main {\n\tstatic function main() {\n\t\t#if again trace(1); #end\n\t\ttrace(RegMacro.registered(Impl));\n\t\ttrace(new Impl().f());\n\t}\n}\n",
			"src/Reg.hx" => "@:autoBuild(RegMacro.build())\ninterface Reg {}\n",
			"src/Impl.hx" => "class Impl implements Reg {\n\tpublic function new() {}\n\n\tpublic function f():Int return 7;\n}\n",
			"src/RegMacro.hx" => [
				"import haxe.macro.Context;",
				"import haxe.macro.Expr;",
				"class RegMacro {",
				"\tstatic var names:Array<String> = [];",
				"\tpublic static macro function build():Array<Field> {",
				"\t\tnames.push(Context.getLocalClass().get().name);",
				"\t\treturn null;",
				"\t}",
				"\tpublic static macro function registered(e:Expr):Expr {",
				"\t\tvar n = haxe.macro.ExprTools.toString(e);",
				"\t\tContext.getType(n);",
				"\t\tif (names.indexOf(n) < 0) Context.error(n + \" is not registered\", e.pos);",
				"\t\treturn macro $v{n};",
				"\t}",
				"}"
			].join("\n") + "\n"
		];
		// (full DCE and a class used through a structure: Main's typing marks
		// Bag.iterator as maybe used, which keeps it; edited not to, the build
		// without the cache drops it, so must the cache, Bag restored)
		var dcefull = [
			"src/Main.hx" => "class Main {\n\tstatic function count<T>(it:Iterable<T>):Int {\n\t\tvar n = 0;\n\t\tfor (_ in it) n++;\n\t\treturn n;\n\t}\n\n\tstatic function main() {\n\t\tvar b = new Bag();\n\t\ttrace(b.size());\n\t\ttrace(count(b));\n\t}\n}\n",
			"src/Bag.hx" => "class Bag {\n\tpublic var items:Array<Int>;\n\n\tpublic function new() items = [1, 2];\n\n\tpublic function iterator():Iterator<Int> return items.iterator();\n\n\tpublic function size():Int return items.length;\n}\n"
		];
		// (an interface's property read through its accessor by a restored
		// module, the interface typed again: the accessor Haxe makes for it,
		// in a later pass, read before that pass)
		var accessor = [
			"src/Main.hx" => "class Main {\n\tstatic function main() {\n\t\ttrace(User.width(User.make()));\n\t}\n}\n",
			"src/Shape.hx" => "interface Shape {\n\tvar width(get, never):Float;\n}\n",
			"src/Box.hx" => "class Box implements Shape {\n\tpublic var width(get, never):Float;\n\n\tpublic function new() {}\n\n\tfunction get_width():Float return 2.5;\n}\n",
			"src/User.hx" => "class User {\n\tpublic static function make():Shape return new Box();\n\n\tpublic static function width(s:Shape):Float return s.width;\n}\n"
		];
		// (a cycle, Ui and Text: Ui typed again, its class built when its
		// field's type names Text, Text restored then would read a field of
		// Ui that its build has not made yet)
		var building = [
			"src/Main.hx" => "class Main {\n\tstatic function main() {\n\t\tvar ui = new Ui();\n\t\ttrace(ui.select());\n\t}\n}\n",
			"src/Ui.hx" => "class Ui {\n\tpublic static var reach = 1.5;\n\n\tpublic var selection:Null<{node:Text, caret:Int}> = null;\n\n\tpublic function new() {}\n\n\tpublic function select():Int {\n\t\tselection = {node: new Text(this), caret: 3};\n\t\treturn selection.node.caret();\n\t}\n}\n",
			"src/Text.hx" => "class Text {\n\tvar ui:Ui;\n\n\tpublic function new(ui:Ui) this.ui = ui;\n\n\tpublic function caret():Int return ui.selection == null ? -1 : ui.selection.caret + Std.int(Ui.reach);\n}\n"
		];
		// (a build macro keeping the fields of Rt, its class built by Copy's
		// build macro, which copies them into Rt_1: the state Rt's typing
		// makes, Copy's typed again needs Rt typed again; hxmc.view's
		// runtimes work so)
		var state = [
			"src/Main.hx" => "class Main {\n\tstatic function main() {\n\t\ttrace(Copy.make());\n\t}\n}\n",
			"src/Rt.hx" => "@:build(RtMacro.build())\nclass Rt {\n\tpublic static function f():Int return 1;\n}\n",
			"src/Copy.hx" => "@:build(RtMacro.copy())\nclass Copy {\n\tpublic static function make():Int return Rt_1.f() + 10;\n}\n",
			"src/RtMacro.hx" => [
				"import haxe.macro.Context;",
				"import haxe.macro.Expr;",
				"class RtMacro {",
				"\tstatic var template:Null<Array<Field>> = null;",
				"\tpublic static macro function build():Array<Field> {",
				"\t\ttemplate = Context.getBuildFields();",
				"\t\treturn null;",
				"\t}",
				"\tpublic static macro function copy():Array<Field> {",
				"\t\ttry {",
				"\t\t\tContext.getType(\"Rt_1\");",
				"\t\t} catch (_:Dynamic) {",
				"\t\t\tswitch Context.getType(\"Rt\") {",
				"\t\t\t\tcase TInst(c, _): c.get().statics.get();",
				"\t\t\t\tcase _:",
				"\t\t\t}",
				"\t\t\tif (template == null) Context.fatalError(\"Rt's fields are not known\", Context.currentPos());",
				"\t\t\tContext.defineType({pack: [], name: \"Rt_1\", pos: Context.currentPos(), kind: TDClass(), fields: template});",
				"\t\t}",
				"\t\treturn null;",
				"\t}",
				"}"
			].join("\n") + "\n"
		];
		return [
			{name: "accessor", files: accessor, args: ["-cp", "src", "-main", "Main"], edit: "src/Shape.hx", run: "accessor"},
			{name: "building", files: building, args: ["-cp", "src", "-main", "Main"], edit: "src/Ui.hx", run: "building"},
			{name: "state", files: state, args: ["-cp", "src", "-main", "Main"], edit: "src/Copy.hx", run: "state"},
			{name: "dcefull", files: dcefull, args: ["-cp", "src", "-main", "Main", "-dce", "full"], edit: "src/Main.hx", run: "dcefull"},
			{name: "registry", files: registry, args: ["-cp", "src", "-main", "Main"], edit: "src/Impl.hx", run: "registry"},
			{name: "cutoff", files: cutoff, args: ["-cp", "src", "-main", "Main"], edit: "src/User.hx", run: "cutoff"},
			{name: "lossy", files: lossy, args: ["-cp", "src", "-main", "Main"], edit: "src/Other.hx", run: "lossy"},
			{name: "hello", files: hello, args: ["-cp", "src", "-main", "Main"], edit: "src/Main.hx", run: "hello"},
			{name: "multi", files: multi, args: ["-cp", "src", "-cp", "src2", "-main", "Main"], edit: "src/util/Util.hx", run: "multi"},
			{name: "macros", files: macros, args: ["-cp", "src", "-main", "Main"], edit: "src/data.txt", run: "macros"}
		];
	}

	// environment variables the macros of the nondeterministic programs read,
	// and HXMC_MODULE_CACHE_LOG for their builds with the cache
	static var extraEnv = new Map<String, Null<String>>();

	static function env(cache:Bool):Map<String, Null<String>> {
		var e:Map<String, Null<String>> = [
			// (the builds without the cache keep their objects apart)
			"HXMC_CACHE" => dir + (cache ? "/cache" : "/refcache"),
			"HXMC_MODULE_CACHE" => cache ? "1" : "0",
			"HXMC_MODULE_CACHE_LOG" => null,
			"HXMC_STATS" => "1",
			"HXMC_RT_DIR" => FileSystem.fullPath("bin/hxmc/rt"),
			"HAXE_STD_PATH" => dir + "/upstream-std"
		];
		for (k => v in extraEnv)
			e.set(k, k == "HXMC_MODULE_CACHE_LOG" && !cache ? null : v);
		return e;
	}

	// a build: its output's bytes (null: failed), the modules it read from
	// the store and encoded
	static function build(target:String, pdir:String, args:Array<String>, cache:Bool):{out:Null<haxe.io.Bytes>, read:Int, encoded:Int, typed:Int, log:String} {
		builds++;
		var out = pdir + "/out." + target;
		for (f in [out, out + ".hxmc"])
			rmrf(f);
		var cmd = switch target {
			case "js": [haxeBin, "--js", out].concat(args);
			case "interp": [haxeBin, "--interp"].concat(args);
			case "haxe-hxmc": [haxeBin].concat(args).concat(["-cp", dir + "/std", "--custom-target", "hxmc=" + out]);
			case _: [tool, out].concat(args).concat(["-cp", dir + "/std", "--custom-target", "hxmc"]);
		}
		var r = exec(cmd, {cwd: pdir, env: env(cache), merge: true});
		var read = 0, encoded = -1, typed = -1;
		var re = ~/module cache: (\d+) modules of \d+ variants read/;
		if (re.match(r.out)) read = Std.parseInt(re.matched(1));
		var re2 = ~/module cache: \d+ checked \(\d+ ms\), (\d+) modules encoded/;
		if (re2.match(r.out)) encoded = Std.parseInt(re2.matched(1));
		else if (cache && r.code == 0) Sys.println("(no module cache summary in the build's output)\n" + tail(r.out, 3000));
		var re3 = ~/module cache: .*, (\d+) typed from source/;
		if (re3.match(r.out)) typed = Std.parseInt(re3.matched(1));
		// (--interp: what the program prints)
		if (target == "interp" && r.code == 0)
			File.saveContent(out, [for (l in r.out.split("\n")) if (!l.startsWith("hxmc:")) l].join("\n"));
		if (r.code != 0 || !FileSystem.exists(out)) {
			Sys.println(tail(r.out, 2000));
			return {out: null, read: read, encoded: encoded, typed: typed, log: r.out};
		}
		return {out: File.getBytes(out), read: read, encoded: encoded, typed: typed, log: r.out};
	}

	static function same(a:Null<haxe.io.Bytes>, b:Null<haxe.io.Bytes>):Bool
		return a != null && b != null && a.compare(b) == 0;

	// the build with the cache against the build without it
	static function gate(what:String, target:String, pdir:String, args:Array<String>, ?expectEncoded:Int, ?expectTyped:Int):{read:Int, encoded:Int, typed:Int, log:String} {
		var ref = build(target, pdir, args, false);
		var got = build(target, pdir, args, true);
		var ok = same(ref.out, got.out);
		var extra = ' (${got.read} read, ${got.encoded} encoded)';
		if (expectEncoded != null && got.encoded != expectEncoded) {
			ok = false;
			extra += ' expected $expectEncoded encoded';
		}
		if (expectTyped != null) {
			extra += ' (${got.typed} typed)';
			if (got.typed != expectTyped) {
				ok = false;
				extra += ' expected $expectTyped typed';
			}
		}
		check('$target: $what: the same output$extra', ok);
		return {read: got.read, encoded: got.encoded, typed: got.typed, log: got.log};
	}

	// a build that fails with the cache and without it, with the same errors
	static function gateFail(what:String, target:String, pdir:String, args:Array<String>) {
		function errors(log:String):String
			return [for (l in log.split("\n")) if (!l.startsWith("hxmc:") && l.trim() != "") l].join("\n");
		var ref = build(target, pdir, args, false);
		var got = build(target, pdir, args, true);
		var ok = ref.out == null && got.out == null && errors(ref.log) == errors(got.log) && errors(ref.log) != "";
		check('$target: $what: the same errors' + (ok ? "" : "\n" + errors(got.log) + "\nwithout the cache:\n" + errors(ref.log)), ok);
	}

	static function edit(path:String, f:String->String)
		File.saveContent(path, f(File.getContent(path)));

	// macros whose results change from run to run (docs/hxmc.md, "Module
	// cache"): a module whose macro calls Date.now or runs a process is typed
	// every build, its dependents restored (Clock: User restored) unless the
	// result is where they copy it (Stamp's inline variable: Main typed with
	// it); a file a macro reads is a dependency by content (Data: typed again
	// when data.txt changes, not when only its date does); an environment
	// variable a macro reads is in the module's key (Env); @:hxmc.noCache
	// (Plain) and -D hxmc.no-cache=lib (lib.Thing) type a module every build;
	// HXMC_MODULE_CACHE_LOG says why. A macro making an HTTP request (to a
	// closed port: no network needed) types its module every build (Net).
	static function nondeterministic(target:String) {
		var files = [
			"src/Main.hx" => "class Main {\n\tstatic function main() {\n\t\ttrace(User.use());\n\t\ttrace(Data.text());\n\t\ttrace(Env.greeting());\n\t\ttrace(Proc.out());\n\t\ttrace(Stamp.YEAR > 2000);\n\t\ttrace(Plain.x() + lib.Thing.y() + Stable.z());\n\t}\n}\n",
			"src/User.hx" => "class User {\n\tpublic static function use():String return \"clock \" + Clock.stamp();\n}\n",
			"src/Clock.hx" => "class Clock {\n\tpublic static function stamp():Bool return Macros.now();\n}\n",
			"src/Stamp.hx" => "class Stamp {\n\tpublic static inline final YEAR:Int = Macros.year();\n}\n",
			"src/Data.hx" => "class Data {\n\tpublic static function text():String return Macros.read(\"data.txt\");\n}\n",
			"src/Env.hx" => "class Env {\n\tpublic static function greeting():String return Macros.env(\"GATE_GREETING\");\n}\n",
			"src/Proc.hx" => "class Proc {\n\tpublic static function out():Int return Macros.proc();\n}\n",
			"src/Plain.hx" => "@:hxmc.noCache\nclass Plain {\n\tpublic static function x():Int return 1;\n}\n",
			"src/lib/Thing.hx" => "package lib;\n\nclass Thing {\n\tpublic static function y():Int return 2;\n}\n",
			"src/Stable.hx" => "class Stable {\n\tpublic static function z():Int return 3;\n}\n",
			"src/Macros.hx" => [
				"import haxe.macro.Expr;",
				"class Macros {",
				"\tpublic static macro function now():Expr {",
				"\t\tvar d = Date.now();",
				"\t\tSys.println(\"clock macro ran\");",
				"\t\treturn macro $v{d.getFullYear() > 2000};",
				"\t}",
				"\tpublic static macro function year():Expr {",
				"\t\treturn macro $v{Date.now().getFullYear()};",
				"\t}",
				"\tpublic static macro function read(path:String):Expr {",
				"\t\treturn macro $v{sys.io.File.getContent(path)};",
				"\t}",
				"\tpublic static macro function env(name:String):Expr {",
				"\t\treturn macro $v{Sys.getEnv(name)};",
				"\t}",
				"\tpublic static macro function proc():Expr {",
				"\t\tvar p = new sys.io.Process(\"node\", [\"-e\", \"process.stdout.write('7')\"]);",
				"\t\tvar o = p.stdout.readAll().toString();",
				"\t\tp.close();",
				"\t\treturn macro $v{Std.parseInt(o)};",
				"\t}",
				"}"
			].join("\n") + "\n",
			"data.txt" => "data one"
		];
		var pdir = dir + "/" + target + "-nondet";
		for (f => c in files)
			write(pdir + "/" + f, c);
		var args = ["-cp", "src", "-main", "Main", "-D", "hxmc.no-cache=lib"];
		extraEnv = ["GATE_GREETING" => "hello", "HXMC_MODULE_CACHE_LOG" => "1"];
		rmrf(dir + "/cache");
		gate("nondet cold", target, pdir, args);
		// every build: Clock (Date.now), Proc (a process), Stamp (Date.now in
		// an inline variable) and Main with it, Plain, lib.Thing; User, Data,
		// Env and Stable restored
		var w = gate("nondet warm", target, pdir, args, null, 6);
		check('$target: nondet warm: the clock macro ran again', w.log.indexOf("clock macro ran") >= 0);
		check('$target: nondet warm: User restored (Clock typed again, its interface the same)', w.log.indexOf("User dirty") < 0 && w.log.indexOf("Stable dirty") < 0);
		for (l in [
			"Clock typed every build (macro called Date.now at src/Macros.hx:4)",
			"Stamp typed every build (macro called Date.now at src/Macros.hx:9, its dependents with it)",
			"Proc typed every build (macro called sys.io.Process at src/Macros.hx:18)",
			"Plain typed every build (@:hxmc.noCache, its dependents with it)",
			"lib.Thing typed every build (-D hxmc.no-cache)"
		])
			check('$target: nondet warm: the log says "$l"', w.log.indexOf(l) >= 0);
		// the file the macro reads: a new date, the same content, then edited
		exec(["touch", "-d", "1 hour ago", pdir + "/data.txt"]);
		gate("nondet, data.txt with a new date", target, pdir, args, null, 6);
		File.saveContent(pdir + "/data.txt", "data two");
		var d = gate("nondet, data.txt edited", target, pdir, args, null, 7);
		check('$target: nondet, data.txt edited: the log names it', d.log.indexOf("data.txt, read by a macro") >= 0);
		gate("nondet, data.txt edited, warm", target, pdir, args, null, 6);
		// the environment variable the macro reads
		extraEnv.set("GATE_GREETING", "bonjour");
		var e = gate("nondet, GATE_GREETING changed", target, pdir, args, null, 7);
		check('$target: nondet, GATE_GREETING changed: the log names it', e.log.indexOf("environment variable GATE_GREETING, read by a macro") >= 0);
		gate("nondet, GATE_GREETING changed, warm", target, pdir, args, null, 6);
		extraEnv.set("GATE_GREETING", "hello");
		gate("nondet, GATE_GREETING back", target, pdir, args, null, 6);
		// an HTTP request: Net typed every build (the request fails: no network)
		var net = [
			"src/Main.hx" => "class Main {\n\tstatic function main() {\n\t\ttrace(Net.status());\n\t\ttrace(Other.v());\n\t}\n}\n",
			"src/Other.hx" => "class Other {\n\tpublic static function v():Int return 5;\n}\n",
			"src/Net.hx" => "class Net {\n\tpublic static function status():String return NetMacro.request();\n}\n",
			"src/NetMacro.hx" => "class NetMacro {\n\tpublic static macro function request():haxe.macro.Expr {\n\t\tvar h = new haxe.Http(\"http://127.0.0.1:1/\");\n\t\tvar r = \"none\";\n\t\th.onError = e -> r = \"error\";\n\t\th.request();\n\t\treturn macro $v{r};\n\t}\n}\n"
		];
		var ndir = dir + "/" + target + "-nethttp";
		for (f => c in net)
			write(ndir + "/" + f, c);
		var nargs = ["-cp", "src", "-main", "Main"];
		gate("nethttp cold", target, ndir, nargs);
		var n = gate("nethttp warm", target, ndir, nargs);
		check('$target: nethttp warm: Net typed every build, Other restored',
			n.log.indexOf("Net typed every build (macro called sys.net.Socket") >= 0 && n.log.indexOf("Other dirty") < 0);
		extraEnv = new Map();
	}

	// a module a macro defines outside the typing of a module (an
	// onAfterTyping callback's Context.defineType, as helder's view macros
	// make their late classes): two programs (A, B) of one class path built
	// one after the other with the cache. The callback's module is not the
	// typing of the module the compiler names as its definer (the macro
	// API's current module: Shared, whose build macro made the macros'
	// context), so restoring Shared must not bring back A's class into B: B
	// defines its own (named by a counter: "Cannot redefine module Late_0";
	// named by the program: A's class in B's output), as without the cache,
	// nor the module the callback asked for in A (Only_a, by Context.getType,
	// a dependency of Shared then). And a module a macro defines in the
	// typing of the first module that asks for it (Gen, by DA in MA, by DB in
	// MB): MB, whose DB finds it (Context.getType), must not get MA's, nor
	// DA with it; MA, warm, gets it with DA restored
	static function lateDefined(target:String) {
		var files = [
			"src/Macro.hx" => [
				"#if macro",
				"import haxe.macro.Context;",
				"#end",
				"import haxe.macro.Expr;",
				"",
				"class Macro {",
				"\tstatic var hooked = false;",
				"\tstatic var n = 0;",
				"\tstatic var seen:Array<String> = [];",
				"",
				"\tpublic static macro function noop():Array<Field>",
				"\t\treturn null;",
				"",
				"\tpublic static macro function mark(s:String):Expr {",
				"\t\tseen.push(s);",
				"\t\tif (!hooked) {",
				"\t\t\thooked = true;",
				"\t\t\tContext.onAfterTyping(late);",
				"\t\t}",
				"\t\treturn macro null;",
				"\t}",
				"",
				"\t#if macro",
				"\tstatic function late(types:Array<haxe.macro.Type.ModuleType>) {",
				"\t\tif (seen.length == 0) return;",
				"\t\tvar msg = seen.join(\",\");",
				"\t\tseen = [];",
				"\t\tfor (s in msg.split(\",\")) Context.getType(\"Only_\" + s);",
				"\t\tvar name = \"Late_\" + (Context.defined(\"late_by_main\") ? msg : Std.string(n++));",
				"\t\tContext.defineType({",
				"\t\t\tpack: [],",
				"\t\t\tname: name,",
				"\t\t\tpos: Context.currentPos(),",
				"\t\t\tkind: TDClass(),",
				"\t\t\tmeta: [{name: \":keep\", pos: Context.currentPos()}],",
				"\t\t\tfields: (macro class {",
				"\t\t\t\tstatic function __init__() trace($v{name + \": \" + msg});",
				"\t\t\t}).fields",
				"\t\t});",
				"\t}",
				"\t#end",
				"}"
			].join("\n") + "\n",
			"src/Shared.hx" => "@:build(Macro.noop())\nclass Shared {\n\tpublic static function f() {}\n}\n",
			"src/A.hx" => "class A {\n\tstatic function main() {\n\t\tShared.f();\n\t\tMacro.mark(\"a\");\n\t}\n}\n",
			"src/B.hx" => "class B {\n\tstatic function main() {\n\t\tShared.f();\n\t\tMacro.mark(\"b\");\n\t}\n}\n",
			"src/Only_a.hx" => "@:keep class Only_a {\n\tstatic function __init__() trace(\"only a\");\n}\n",
			"src/Only_b.hx" => "@:keep class Only_b {\n\tstatic function __init__() trace(\"only b\");\n}\n",
			// (a module defined in the typing of a module, Gen: by DA in MA, by
			// DB in MB; MB must not restore MA's, nor DA with it)
			"src/Def.hx" => [
				"#if macro",
				"import haxe.macro.Context;",
				"#end",
				"",
				"class Def {",
				"\tpublic static macro function ensure():haxe.macro.Expr {",
				"\t\tvar by = Context.getLocalModule();",
				"\t\ttry Context.getType(\"Gen\") catch (_:Dynamic) Context.defineType({",
				"\t\t\tpack: [],",
				"\t\t\tname: \"Gen\",",
				"\t\t\tpos: Context.currentPos(),",
				"\t\t\tkind: TDClass(),",
				"\t\t\tmeta: [{name: \":keep\", pos: Context.currentPos()}],",
				"\t\t\tfields: (macro class {",
				"\t\t\t\tstatic function __init__() trace($v{\"Gen by \" + by});",
				"\t\t\t}).fields",
				"\t\t});",
				"\t\treturn macro null;",
				"\t}",
				"}"
			].join("\n") + "\n",
			"src/DA.hx" => "class DA {\n\tstatic function __init__() trace(\"DA\");\n\n\tpublic static function f() Def.ensure();\n}\n",
			"src/DB.hx" => "class DB {\n\tpublic static function f() Def.ensure();\n}\n",
			"src/MA.hx" => "class MA {\n\tstatic function main() {\n\t\tDA.f();\n\t\tDB.f();\n\t}\n}\n",
			"src/MB.hx" => "class MB {\n\tstatic function main() {\n\t\tDB.f();\n\t}\n}\n"
		];
		var pdir = dir + "/" + target + "-late";
		for (f => c in files)
			write(pdir + "/" + f, c);
		for (byMain in [false, true]) {
			var how = byMain ? "named by the program" : "named by a counter";
			var extra = byMain ? ["-D", "late_by_main"] : [];
			rmrf(dir + "/cache");
			for (m in ["A", "B", "A", "B"])
				gate('late class $how, $m', target, pdir, ["-cp", "src", "-main", m].concat(extra));
		}
		rmrf(dir + "/cache");
		for (m in ["MA", "MB", "MA", "MB"])
			gate('a module defined in the typing of another, $m', target, pdir, ["-cp", "src", "-main", m]);
	}

	static function main() {
		var withPort = Sys.args().contains("--port");
		dir = FileSystem.fullPath("bin") + "/hxmc-t/module-cache";
		tool = FileSystem.fullPath("bin/hxmc/hxmc");
		var a = parseArgs(Sys.args(), ["--haxe"]);
		haxeBin = a.opts.exists("--haxe") ? FileSystem.fullPath(a.opts.get("--haxe")) : null;
		if (haxeBin == null)
			for (h in ["bin/npm/native/linux-x86_64/haxe", "bin/npm/native/linux-arm64/haxe", "bin/npm/native/macos-arm64/haxe", "bin/npm/native/macos-x86_64/haxe"])
				if (FileSystem.exists(h)) {
					haxeBin = FileSystem.fullPath(h);
					break;
				}
		if (haxeBin == null) fail("no haxe with hxmc built in (make bin/npm/native/<host>/haxe, or --haxe <path>)");
		rmrf(dir);
		mkdirs(dir);
		copyTree("bin/hxmc/std", dir + "/std");
		copyTree("haxe/upstream/std", dir + "/upstream-std");
		// (--nondet: only the nondeterministic macros' cases)
		var only = Sys.args().contains("--nondet");
		// (--late: only the late-defined modules' cases)
		var late = Sys.args().contains("--late");
		if (late) only = true;
		for (target in ["hxmc", "js", "interp", "haxe-hxmc"]) {
			for (p in programs()) {
				if (only) continue;
				// (through haxe for hxmc: the hello program)
				if (target == "haxe-hxmc" && p.name != "hello") continue;
				var pdir = dir + "/" + target + "-" + p.name;
				for (f => s in p.files)
					write(pdir + "/" + f, s);
				mkdirs(pdir + "/src2");
				var name = p.name;
				// cold: an empty cache, written
				rmrf(dir + "/cache");
				var cold = gate('$name cold', target, pdir, p.args);
				check('$target: $name cold: nothing read', cold.read == 0 && cold.encoded > 0);
				// warm: every module restored (Main of the macros program too, its
				// build macro keeping no state; Impl of the registry program too,
				// its macro's state used by no macro of the build)
				var warm = gate('$name warm', target, pdir, p.args, 0);
				var again = 0;
				check('$target: $name warm: read from the store', warm.read > 0);
				// a new date, the same content
				var t = pdir + "/" + p.edit;
				exec(["touch", "-d", "1 hour ago", t]);
				gate('$name, a file with a new date', target, pdir, p.args, again);
				// one module edited
				var orig = File.getContent(t);
				File.saveContent(t, switch name {
					// (the interface the same: its dependents restored)
					case "accessor" | "building": orig + "// edited\n";
					case "state": orig.replace("+ 10", "+ 11");
					case "cutoff": orig.replace("10, 20", "10, 21");
					case "registry": orig.replace("return 7", "return 8");
					case "dcefull": orig.replace("trace(count(b));", "trace(0);");
					case "hello": orig.replace("hello ", "hello again ");
					case "multi": orig.replace("\"v\" + 1", "\"v\" + 2");
					case "lossy": orig.replace("3", "4");
					case _: "data two";
				});
				var e = gate('$name, ${p.edit} edited', target, pdir, p.args);
				check('$target: $name, ${p.edit} edited: some modules restored', name == "hello" || e.encoded < cold.encoded);
				if (name == "state") {
					// a failed build (Copy's own error), then the edit fixed: the
					// error the build without the cache reports, then the output
					var good = File.getContent(t);
					File.saveContent(t, good.replace("+ 11", "+ \"x\""));
					gateFail('state, Copy with an error', target, pdir, p.args);
					gateFail('state, Copy with an error, again', target, pdir, p.args);
					File.saveContent(t, good);
					gate('state, the error fixed', target, pdir, p.args);
				}
				gate('$name, ${p.edit} edited, warm', target, pdir, p.args, again);
				if (name == "building") {
					// a field of Ui that Text reads removed: Text's error, as without
					// the cache; back, Text restored; with full DCE, Ui's static
					// read by Text only
					var edited = File.getContent(t);
					File.saveContent(t, edited.replace("public static var reach = 1.5;", ""));
					gateFail('building, Ui.reach removed', target, pdir, p.args);
					File.saveContent(t, edited);
					gate('building, Ui.reach back', target, pdir, p.args);
					File.saveContent(t, edited + "// again\n");
					gate('building, Ui edited, -dce full', target, pdir, p.args.concat(["-dce", "full"]));
					File.saveContent(t, edited);
				}
				// back to the original (an older entry's content again)
				File.saveContent(t, orig);
				gate('$name, ${p.edit} back', target, pdir, p.args);
				if (name == "registry") {
					// a define Main reads: Main typed again, its macro uses the state
					// Impl's macro kept, Impl restored: the build again, Impl typed,
					// Main's macro finds it registered
					var d = gate('registry, -D again', target, pdir, p.args.concat(["-D", "again"]));
					check('$target: registry, -D again: the build again, the modules whose macros keep that state typed', d.log.indexOf("the build again") >= 0);
					var d2 = gate('registry, -D again, warm', target, pdir, p.args.concat(["-D", "again"]), 0);
					check('$target: registry, -D again, warm: restored, not again', d2.log.indexOf("the build again") < 0);
				}
				if (name == "cutoff") {
					// a define no module reads: nothing typed again
					gate('cutoff, -D unrelated', target, pdir, p.args.concat(["-D", "unrelated"]), 0);
					// a define one module's condition reads: that module typed again,
					// its dependents restored (the condition is in a body)
					gate('cutoff, -D fast (read by Flags only)', target, pdir, p.args.concat(["-D", "fast"]), 1);
					gate('cutoff, -D fast, warm', target, pdir, p.args.concat(["-D", "fast"]), 0);
					gate('cutoff, without -D fast again', target, pdir, p.args, 0);
					// a body of a dependency edited (its type written out): only it typed
					// again, its dependents (Main, User) restored
					var calc = pdir + "/src/Calc.hx";
					var c0 = File.getContent(calc);
					File.saveContent(calc, c0.replace("return a + b;", "return a + b + 100;"));
					gate('cutoff, a body of Calc edited', target, pdir, p.args, 1);
					// its interface edited (an inline function): its dependents typed again
					File.saveContent(calc, c0.replace("return a + b;", "return a + b + 100;").replace("x * 2", "x * 3"));
					var i = gate('cutoff, an inline function of Calc edited', target, pdir, p.args);
					check('$target: cutoff, an inline function of Calc edited: Calc, Main and User typed again', i.encoded == 3);
					File.saveContent(calc, c0);
					gate('cutoff, Calc back', target, pdir, p.args);
					// a body in a cycle (Ping, Pong): Ping typed again, Pong restored
					var ping = pdir + "/src/Ping.hx";
					var p0 = File.getContent(ping);
					File.saveContent(ping, p0.replace("1 + Pong", "2 + Pong"));
					gate('cutoff, a body of Ping edited (a cycle with Pong)', target, pdir, p.args, 1);
					File.saveContent(ping, p0);
					gate('cutoff, Ping back', target, pdir, p.args);
				}
				if (name == "multi" && target == "hxmc") {
					// a second output of the same program: every object from the store
					var o2 = pdir + "/out2.hxmc";
					rmrf(o2);
					var r = exec([tool, o2].concat(p.args).concat(["-cp", dir + "/std", "--custom-target", "hxmc"]), {cwd: pdir, env: env(true), merge: true});
					var re = ~/hxmc: modules (\d+): (\d+) cached, (\d+) compiled/;
					var shared = r.code == 0 && re.match(r.out) && re.matched(3) == "0" && re.matched(1) == re.matched(2);
					var first = build(target, pdir, p.args, true);
					check('hxmc: multi, a second output shares the objects (${re.matched(0)})', shared && same(first.out, File.getBytes(o2)));
				}
				if (name == "multi") {
					// a new file shadows a module (src2, given last, comes first)
					write(pdir + "/src2/util/Util.hx", File.getContent(pdir + "/src/util/Util.hx").replace("\"v\" + 1", "\"shadow\""));
					gate('multi, util.Util shadowed', target, pdir, p.args);
					rmrf(pdir + "/src2/util");
					gate('multi, the shadowing file removed', target, pdir, p.args);
				}
				if (name == "hello") {
					// a std override edited (hxmc's std for hxmc, upstream's for JS)
					var std = target == "js" || target == "interp" ? dir + "/upstream-std/StringTools.hx" : dir + "/std/StringTools.hx";
					var s = File.getContent(std);
					File.saveContent(std, s.replace("public static function lpad(s:String, c:String, l:Int):String {",
						"public static function lpad(s:String, c:String, l:Int):String {\n\t\tif (l == 4) l = 5;"));
					check('$target: hello, the std edit applies', File.getContent(std) != s);
					gate('hello, std StringTools edited', target, pdir, p.args);
					gate('hello, std StringTools edited, warm', target, pdir, p.args, again);
					File.saveContent(std, s);
					gate('hello, std StringTools back', target, pdir, p.args);
				}
			}
		}
		for (target in ["hxmc", "js", "interp"])
			if (!late) nondeterministic(target);
		for (target in ["hxmc", "js", "interp"])
			lateDefined(target);
		// the cache off by HXMC_MODULE_CACHE=0 although the define asks for it
		if (!only) {
			var pdir = dir + "/hxmc-hello";
			var r = exec([tool, pdir + "/out.off", "-cp", "src", "-main", "Main", "-D", "hxmc.module-cache", "-cp", dir + "/std", "--custom-target", "hxmc"],
				{cwd: pdir, env: env(false), merge: true});
			check("HXMC_MODULE_CACHE=0 wins over -D hxmc.module-cache", r.code == 0 && r.out.indexOf("module cache") < 0);
			var r = exec([tool, pdir + "/out.def", "-cp", "src", "-main", "Main", "-cp", dir + "/std", "--custom-target", "hxmc"],
				{cwd: pdir, env: [for (k => v in env(false)) k => k == "HXMC_MODULE_CACHE" ? null : v], merge: true});
			check("on by default", r.code == 0 && r.out.indexOf("variants read") >= 0);
			var r = exec([tool, pdir + "/out.nodef", "-cp", "src", "-main", "Main", "-D", "hxmc.no-module-cache", "-cp", dir + "/std", "--custom-target", "hxmc"],
				{cwd: pdir, env: [for (k => v in env(false)) k => k == "HXMC_MODULE_CACHE" ? null : v], merge: true});
			check("-D hxmc.no-module-cache turns it off", r.code == 0 && r.out.indexOf("module cache") < 0);
			// a display request: no cache, an answer
			var r = exec([tool, "-cp", "src", "--display", "src/Main.hx@0@diagnostics"], {cwd: pdir, env: env(true), merge: true});
			check("a display request does not use it", r.out.indexOf("variants read") < 0);
		}
		if (withPort) {
			var pdir = FileSystem.fullPath(".");
			var args = ["-cp", "haxe/src", "-main", "haxe.Main", "-D", "disable-parallelism"];
			rmrf(dir + "/cache");
			function port(cache:Bool) {
				var out = dir + "/port";
				rmrf(out);
				rmrf(out + ".hxmc");
				builds++;
				var r = exec([tool, out].concat(args).concat(["-cp", dir + "/std", "--custom-target", "hxmc"]),
					{cwd: pdir, env: [for (k => v in env(cache)) k => k == "HAXE_STD_PATH" ? FileSystem.fullPath("haxe/upstream/std") : v], merge: true});
				if (r.code != 0) Sys.println(tail(r.out, 2000));
				return r.code == 0 ? File.getBytes(out) : null;
			}
			var ref = port(false);
			check("the port: cold", same(ref, port(true)));
			check("the port: warm", same(ref, port(true)));
		}
		Sys.println('module cache: $builds builds, ' + (failures == 0 ? "all checks passed" : '$failures failed'));
		if (failures == 0) rmrf(dir);
		Sys.exit(failures == 0 ? 0 : 1);
	}
}
