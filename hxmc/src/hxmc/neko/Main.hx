package hxmc.neko;

import haxe.io.BytesBuffer;
import hxmc.neko.Value;

// `neko <module> [args]`: neko/vm/main.c
class Main {
	static function main() {
		var args = Sys.args();
		while (args.length > 0) {
			switch args[0] {
				case "-interp" | "-stats":
					args.shift();
					continue;
				case "-version":
					Sys.println("2.4.0");
					return;
				case _:
			}
			break;
		}
		if (args.length == 0) {
			Sys.println("NekoVM 2.4.0 (c)2005-2024 Haxe Foundation\n  Usage : neko <file>");
			Sys.exit(1);
		}
		Sys.exit(run(args[0], args.slice(1)));
	}

	public static function run(file:String, args:Array<String>):Int {
		var vm = new VM();
		var loader = Loader.make(args);
		var full = Loader.selectFile(loader.get(Fields.id("path")), file, StringTools.endsWith(file, ".n") ? "" : ".n");
		StdPrims.programPath = try sys.FileSystem.fullPath(full) catch (e:Dynamic) full;
		try {
			vm.callEx(loader, loader.get(Fields.id("loadmodule")), [NStr.of(file), loader]);
		} catch (e:Dynamic) {
			report(vm, VM.wrap(e), true);
			flush();
			return 1;
		}
		flush();
		return 0;
	}

	static function flush() {
		Sys.stdout().flush();
		Sys.stderr().flush();
	}

	// report: the stack, then the exception
	public static function report(vm:VM, e:NekoError, isExc:Bool) {
		var b = new BytesBuffer();
		var st:Array<Dynamic> = e.stack == null ? [] : e.stack.copy();
		st.reverse();
		for (s in st) {
			b.addString("Called from ");
			if (s == null) b.addString("a C function") else if (Tag.isString(s)) {
				b.add((s : NStr).b);
				b.addString(" (no debug available)");
			} else if (Tag.isArray(s) && (s : Array<Dynamic>).length == 2) {
				var a:Array<Dynamic> = s;
				vm.buffer(b, a[0], []);
				b.addString(" line ");
				vm.buffer(b, a[1], []);
			} else
				vm.buffer(b, s, []);
			b.addString("\n");
		}
		if (isExc) b.addString("Uncaught exception - ");
		try vm.buffer(b, e.value, []) catch (_:Dynamic) b.addString("???");
		b.addString("\n");
		var bytes = b.getBytes();
		Sys.stdout().flush();
		Sys.stderr().writeBytes(bytes, 0, bytes.length);
		Sys.stderr().flush();
	}
}
