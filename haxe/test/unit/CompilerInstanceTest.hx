package unit;

import compiler.CompilerInstance;
import compiler.DisplayServices;
import haxe.display.FsPath;

/** A CompilerInstance over an in-memory cache: a build, then the typed display calls on
	the same program (hover, completion, definition, signature help, diagnostics), and a
	display call on a program that does not compile. */
class CompilerInstanceTest {
	static final source = [
		"class Main {",
		"\tstatic function main() {",
		"\t\tvar greeting = \"hello\";",
		"\t\ttrace(greeting.length);",
		"\t\tgreet(greeting);",
		"\t}",
		"\tstatic function greet(name:String, times = 1) {}",
		"}",
		""
	].join("\n");

	public static function main():Void {
		var dir = sys.FileSystem.fullPath(".") + "/bin/test/compiler-instance";
		sys.FileSystem.createDirectory(dir);
		var file = dir + "/Main.hx";
		sys.io.File.saveContent(file, source);
		var cache = InMemoryCache.create();
		var instance = CompilerInstance.ofArgs(["-cp", dir, "--main", "Main", "--no-output"], cache);

		var io = compiler.io.CompilerIo.create(_ -> {}, _ -> {}, _ -> {}, () -> {}, null);
		var built = instance.build(io);
		compiler.io.CompilerIo.close(io);
		check("the build succeeds", built.code == 0, 'exit ${built.code}, ${built.messages.map(m -> m.cmMessage)}');

		var path = new FsPath(file);
		function at(needle:String, delta = 0):Int {
			var i = source.indexOf(needle);
			if (i < 0) throw 'no "$needle" in the source';
			return i + delta;
		}

		var hover = instance.display.hover({file: path, offset: at("greeting.length", 2)});
		check("hover finds the local", hover != null, "null");
		check("hover's position is the local's use", hover.hpos.pmin == at("greeting.length"), core.TPrinting.Printer.sPos(hover.hpos));

		var completion = instance.display.completion({file: path, offset: at("length"), wasAutoTriggered: false});
		check("completion finds fields", completion != null, "null");
		var names = completion.fitems.map(core.display.CompletionItem.getName);
		check("completion has String's length", names.indexOf("length") >= 0, names.join(","));

		var definition = instance.display.definition({file: path, offset: at("greeting.length", 2)});
		check("definition finds one place", definition.length == 1, '${definition.length} places');
		check("definition is the declaration", definition[0].pmin == at("greeting = "), core.TPrinting.Printer.sPos(definition[0]));

		var help = instance.display.signatureHelp({file: path, offset: at("greet(greeting)", 6), wasAutoTriggered: false});
		check("signature help finds greet", help != null && help.signatures.length == 1, help == null ? "null" : '${help.signatures.length}');
		check("signature help's argument is the first", help.activeParameter == 0, '${help.activeParameter}');

		var diagnostics = instance.display.diagnostics({file: path});
		check("diagnostics run", diagnostics != null, "null");

		// (a call with unsaved contents: only the displayed file's, as the protocol has it)
		var broken = source.split("greeting.length").join("greeting.nope");
		var failed = try {
			instance.display.hover({file: path, offset: at("greeting.length", 2), contents: broken});
			null;
		} catch (e:DisplayError) e;
		var hoverOnBroken = failed == null ? "a result" : failed.message;
		check("hover on a broken program still finds the local", failed == null, hoverOnBroken);

		var outside = CompilerInstance.ofArgs(["-cp", dir, "--main", "Main", "--no-output", "--macro", "Missing.init()"], cache);
		var error = try {
			outside.display.hover({file: path, offset: at("greeting.length", 2)});
			null;
		} catch (e:DisplayError) e;
		check("a failing init macro fails as a DisplayError", error != null && error.messages.length > 0, "no error");
		cache.dispose();
		Sys.println("CompilerInstanceTest: ok");
	}

	static function check(what:String, ok:Bool, got:String):Void
		if (!ok) throw 'CompilerInstanceTest: $what failed (got: $got)';
}
