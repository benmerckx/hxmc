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
		var names = completion.fields.fitems.map(core.display.CompletionItem.getName);
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
		} catch (e:CompilationError) e;
		var hoverOnBroken = failed == null ? "a result" : failed.message;
		check("hover on a broken program still finds the local", failed == null, hoverOnBroken);

		var outside = CompilerInstance.ofArgs(["-cp", dir, "--main", "Main", "--no-output", "--macro", "Missing.init()"], cache);
		var error = try {
			outside.display.hover({file: path, offset: at("greeting.length", 2)});
			null;
		} catch (e:CompilationError) e;
		check("a failing init macro fails as a CompilationError", error != null && error.messages.length > 0, "no error");

		// (the methods answered without typing, or at a stage of the compilation)
		var defines = instance.display.defines({compiler: true, user: false});
		check("defines lists the compiler's", defines != null && defines.length > 0, defines == null ? "null" : '${defines.length}');
		var contexts = instance.server.contexts();
		check("the cache has a context", contexts.length > 0, '${contexts.length}');
		var invalid = try {
			instance.server.setCwd({dir: dir + "/missing"});
			null;
		} catch (e:ServiceError) e;
		check("setCwd to a missing directory is the method's error", invalid != null && invalid.message.indexOf("Invalid directory") == 0,
			invalid == null ? "no error" : invalid.message);

		// (edits, as an editor makes them: the file saved, server/invalidate, diagnostics; within
		// a second, so only the invalidation tells the cache. The cleanup between requests
		// drops what display requests typed: without it a module of an earlier request is reused)
		var edited = source.split("greeting.length").join("greeting.nope");
		function errors():Int
			return instance.display.diagnostics({file: path}).messages.filter(m -> switch core.Message.Message.severity(m) {
				case Error: true;
				case _: false;
			}).length;
		function errorsAfterEdit(code:String):Int {
			sys.io.File.saveContent(file, code);
			instance.server.invalidate({file: path});
			return errors();
		}
		check("an edit that breaks the program is seen", errorsAfterEdit(edited) > 0, "no error");
		check("its fix is seen", errorsAfterEdit(source) == 0, "errors");
		check("unchanged, it stays fixed", errors() == 0, "errors");
		check("the same edit again is seen", errorsAfterEdit(edited) > 0, "no error");
		// (restored within the same second: only the invalidation tells the cache)
		sys.io.File.saveContent(file, source);
		instance.server.invalidate({file: path});

		// (a clean build: from source whatever is cached, the cache refreshed. A module typed
		// again gets another id; one reused keeps its own)
		var lastMessages = "";
		function buildWith(?options:BuildOptions):Int {
			var io = compiler.io.CompilerIo.create(_ -> {}, _ -> {}, _ -> {}, () -> {}, null);
			var r = instance.build(io, options);
			compiler.io.CompilerIo.close(io);
			lastMessages = r.messages.map(m -> m.cmMessage).join("; ");
			return r.code;
		}
		function mainId():Int {
			for (cc in instance.server.contexts())
				if (instance.server.modules({signature: cc.getSign()}).indexOf("Main") >= 0)
					return instance.server.module({signature: cc.getSign(), path: "Main"}).module.mId;
			return -1;
		}
		check("a build", buildWith() == 0, lastMessages);
		var first = mainId();
		check("a build again", buildWith() == 0, lastMessages);
		check("a build again reuses Main", mainId() == first, '${mainId()} after $first');
		check("a clean build", buildWith({clean: true}) == 0, lastMessages);
		var cleaned = mainId();
		check("a clean build types Main again", cleaned != first && cleaned != -1, '$cleaned after $first');
		check("a build after it", buildWith() == 0, lastMessages);
		check("a build after it reuses the clean build's Main", mainId() == cleaned, '${mainId()} after $cleaned');
		cache.dispose();
		Sys.println("CompilerInstanceTest: ok");
	}

	static function check(what:String, ok:Bool, got:String):Void
		if (!ok) throw 'CompilerInstanceTest: $what failed (got: $got)';
}
