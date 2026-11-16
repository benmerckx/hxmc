package hxmc.neko;

import haxe.io.Bytes;
import hxmc.neko.Value;

using hxmc.neko.Builtins.Check;

// $loader (neko/vm/load.c): the module path, the cache of loaded modules,
// the program's arguments, loadprim (the primitives are this VM's own, by
// library: Prims) and loadmodule
class Loader {
	public static function make(args:Array<String>):NObj {
		var o = new NObj();
		o.set(Fields.id("path"), initPath(Sys.getEnv("NEKOPATH")));
		o.set(Fields.id("cache"), new NObj());
		var argv = Arr.make(args.length);
		for (i in 0...args.length)
			argv[i] = NStr.of(args[i]);
		o.set(Fields.id("args"), argv);
		o.set(Fields.id("loadprim"), Builtins.prim("loadprim", 2, loadprim));
		o.set(Fields.id("loadmodule"), Builtins.prim("loadmodule", 2, loadmodule));
		return o;
	}

	// a list [dir, next] of the directories, each with a trailing slash
	static function initPath(path:Null<String>):NValue {
		if (path == null) path = "/usr/lib/neko:/usr/local/lib/neko:/usr/local/bin:/usr/bin";
		var l:NValue = null;
		var parts = [];
		var cur = new StringBuf();
		var i = 0;
		while (i < path.length) {
			var c = path.charAt(i);
			// (a Windows drive letter)
			if (cur.length == 0 && i + 1 < path.length && path.charAt(i + 1) == ":" && c != ":" && c != ";") {
				cur.add(c);
				cur.add(":");
				i += 2;
				continue;
			}
			if (c == ":" || c == ";") {
				parts.push(cur.toString());
				cur = new StringBuf();
			} else
				cur.add(c);
			i++;
		}
		parts.push(cur.toString());
		for (p in parts) {
			var last = p.length == 0 ? "" : p.charAt(p.length - 1);
			var d = last != "/" && last != "\\" ? p + "/" : p;
			var cell = Arr.pair(NStr.of(d), l);
			l = cell;
		}
		return l;
	}

	// neko_select_file
	public static function selectFile(path:NValue, file:String, ext:String):String {
		var ff = file + ext;
		if (sys.FileSystem.exists(ff)) {
			if (file.indexOf("/") >= 0 || file.indexOf("\\") >= 0) return ff;
			return "./" + ff;
		}
		while (Tag.isArray(path) && path.asArr().length == 2) {
			var a = path.asArr();
			path = a[1];
			var p = VM.current().toBytes(a[0]).toString() + ff;
			if (sys.FileSystem.exists(p)) return p;
		}
		return ff;
	}

	static function loadprim(vm:VM, a:haxe.ds.Vector<NValue>):NValue {
		var o = vm.vthis.obj();
		var name = a[0].str().toString();
		var nargs = a[1].int();
		if (nargs >= 10 || nargs < -1) throw Builtins.failure;
		var f = Prims.find(name, nargs);
		if (f == null) throw VM.failure("Primitive not found : " + name + "(" + nargs + ")", "load.c", 357);
		return f;
	}

	static function loadmodule(vm:VM, a:haxe.ds.Vector<NValue>):NValue {
		var o = vm.vthis.obj();
		var mname = a[0].str();
		var vthis = a[1].obj();
		var cache = o.get(Fields.id("cache")).obj();
		var mid = Fields.idBytes(mname.b);
		var mv = cache.get(mid);
		if (Tag.isAbstract(mv) && mv.asAbs().kind == "module") return (mv.asAbs().data : Module).exports;
		var name = mname.toString();
		var file = StringTools.endsWith(name, ".n") ? selectFile(o.get(Fields.id("path")), name, "") : selectFile(o.get(Fields.id("path")), name, ".n");
		var bytes = try sys.io.File.getBytes(file) catch (_:Dynamic) throw VM.failure("Module not found : " + name, "load.c", 181);
		var m = try Module.read(bytes, vthis) catch (e:Module.ReadError) throw VM.failure("Invalid module : " + name, "load.c", 398);
		m.name = new NStr(mname.b.sub(0, mname.b.length));
		cache.set(mid, new NAbs("module", m));
		vm.execute(m);
		return m.exports;
	}
}
