package hxmc;

import haxe.io.Bytes;
import hxmc.Obj;
import hxmc.CoffReader;

// The program's own native inputs (docs/interop.md, "Calls and linking"):
// prebuilt objects and archives in the target's format, named by
// `-D hxmc.link=<path>[,<path>...]` or `@:hxmc.link("<path>")`, linked as a
// linker would: every object, and the archive members that define what the
// program (or a member already taken) leaves undefined; and the imports of
// C functions from DLLs and dylibs (@:hxmc.lib), written into the import
// tables directly as for the system's libraries. Linux executables are
// static by default: a C function there comes from an object or an archive;
// in the dynamic glibc mode (-D hxmc.libc=glibc) from a shared object too.
class LinkInputs {
	// the objects to link, given the names the program and the runtime
	// objects leave undefined (`wanted`) and those they define (`defined`)
	public static function load(paths:Array<String>, abi:Abi, wanted:Array<String>, defined:Map<String, Bool>):Array<Obj> {
		if (paths.length == 0) return [];
		for (p in paths)
			if (!sys.FileSystem.exists(p)) throw "hxmc: link: no such file: " + p;
		if (abi.os == "windows") {
			// COFF: COMDAT folding, weak externals and import libraries as the
			// runtime object's (MkRt)
			var m = new MkRt();
			m.arm = abi.arm;
			for (n => _ in defined)
				m.markDefined(n);
			for (p in paths) {
				var b = sys.io.File.getBytes(p);
				if (isArchive(b)) m.addArchive(new Archive(b, p)) else m.addCoff(CoffReader.read(b, 0));
			}
			m.selectFor(wanted);
			return [m.mergeObj()];
		}
		var objs:Array<Obj> = [];
		var archives:Array<Archive> = [];
		var have = defined.copy();
		var queue = wanted.copy();
		function add(o:Obj) {
			objs.push(o);
			for (s in o.symbols)
				if (s.global && (s.section != null || s.abs)) have.set(s.name, true);
			for (s in o.symbols)
				if (s.global && s.section == null && !s.abs) queue.push(s.name);
		}
		function read(b:Bytes, what:String):Obj {
			if (abi.os == "macos") {
				var r = MachOReader.read(b);
				if (r.arm != abi.arm) throw "hxmc: link: " + what + " is for another architecture";
				return r.obj;
			}
			return ElfReader.read(b);
		}
		for (p in paths) {
			var b = sys.io.File.getBytes(p);
			if (isArchive(b)) archives.push(new Archive(b, p)) else add(read(b, p));
		}
		var loaded = new Map<String, Bool>();
		while (queue.length > 0) {
			var name = queue.pop();
			if (have.exists(name)) continue;
			for (ar in archives) {
				// (Mach-O archives index the names with their leading underscore)
				var at = ar.index.get(abi.os == "macos" ? "_" + name : name);
				if (at == null) continue;
				var key = ar.path + ":" + at;
				if (loaded.exists(key)) continue;
				loaded.set(key, true);
				add(read(ar.member(at), ar.path));
				break;
			}
		}
		return objs;
	}

	static function isArchive(b:Bytes):Bool
		return b.length >= 8 && b.getString(0, 8) == "!<arch>\n";

	// the file a library name stands for on the target: Windows `name.dll`,
	// macOS `@rpath/libname.dylib` (next to the executable); a name with a
	// dot or a slash is used as it is (macOS: without a slash, under @rpath/)
	public static function libFile(lib:String, abi:Abi):String {
		var plain = lib.indexOf(".") < 0 && lib.indexOf("/") < 0;
		// (Android: the system's libraries have no version suffix, libEGL.so.1 is libEGL.so)
		if (abi.android) {
			if (plain) return "lib" + lib + ".so";
			var v = lib.indexOf(".so.");
			return v > 0 ? lib.substr(0, v + 3) : lib;
		}
		return switch abi.os {
			case "windows": plain ? lib + ".dll" : lib;
			case "macos": plain ? "@rpath/lib" + lib + ".dylib" : lib.indexOf("/") < 0 ? "@rpath/" + lib : lib;
			// (Linux, -D hxmc.libc=glibc: `libname.so` next to the executable, DT_RUNPATH $ORIGIN;
			// libm.so.6 and the like from the system's search path)
			case "linux": plain ? "lib" + lib + ".so" : lib;
			case _: lib;
		}
	}

	// Windows: the imports of the C functions declared with @:hxmc.lib that
	// nothing defines, as the runtime object lists its own (.hxmc.imports)
	public static function peImports(undefined:Array<String>, abi:Abi):Null<Obj> {
		var lines = [];
		for (n in undefined) {
			var lib = hxmc.ir.CInterop.LIBS.get(n);
			if (lib == null) continue;
			var dll = libFile(lib, abi);
			lines.push(dll + "\t" + n + "\t" + n + "\tcode");
			lines.push(dll + "\t__imp_" + n + "\t" + n + "\tdata");
		}
		if (lines.length == 0) return null;
		var o = new Obj();
		var s = o.section(".hxmc.imports", RoData, 1);
		s.buf.str(lines.join("\n") + "\n");
		return o;
	}
}
