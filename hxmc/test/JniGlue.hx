import sys.FileSystem;
import sys.io.File;

using StringTools;

// The reference generator of the Java glue hxmc's JNI interop expects
// (docs/plans/jni.md, "The glue"): from the manifest hxmc writes next to a
// program that has Haxe classes implementing Java interfaces
// (<output>.jni.json: hxmc.ir.Jni.manifest), the Java sources of
// org.hxmc.Peer (the proxies' base: the handle, the cleanup of collected
// proxies), org.hxmc.HaxeException (what a Haxe exception is in Java) and
// each proxy class. helder.pack does the same for an app (and dexes them);
// the corpus's JNI cases and JniCheck compile these with javac.
//   bin/hxmc/hxmc -cp hxmc/test --run JniGlue <manifest.jni.json> <output directory>
class JniGlue {
	static function main() {
		var args = Sys.args();
		if (args.length != 2) {
			Sys.println("usage: JniGlue <manifest.jni.json> <output directory>");
			Sys.exit(2);
		}
		for (f in generate(args[0], args[1]))
			Sys.println(f);
	}

	// the Java sources for a manifest (null: only Peer and HaxeException),
	// written under dir by package; their paths
	public static function generate(manifest:Null<String>, dir:String):Array<String> {
		var files = [];
		function write(cls:String, src:String) {
			var path = dir + "/" + cls.replace(".", "/") + ".java";
			mkdirs(haxe.io.Path.directory(path));
			if (!FileSystem.exists(path) || File.getContent(path) != src) File.saveContent(path, src);
			files.push(path);
		}
		write("org.hxmc.Peer", PEER);
		write("org.hxmc.HaxeException", HAXE_EXCEPTION);
		if (manifest == null || !FileSystem.exists(manifest)) return files;
		var m:Manifest = haxe.Json.parse(File.getContent(manifest));
		for (p in m.proxies)
			write(p.cls(), proxy(p));
		return files;
	}

	static function mkdirs(d:String)
		if (d != "" && !FileSystem.exists(d)) FileSystem.createDirectory(d);

	// a proxy: org.hxmc.Peer's subclass implementing the interfaces, each
	// method calling its static native with the handle first
	static function proxy(p:Proxy):String {
		var name = p.cls();
		var dot = name.lastIndexOf(".");
		var b = new StringBuf();
		b.add("// Generated from hxmc's manifest (JniGlue): the Java proxy of the Haxe class " + p.haxe + ".\n");
		if (dot > 0) b.add("package " + name.substr(0, dot) + ";\n\n");
		var ifaces = [for (i in p.interfaces) source(i)];
		b.add("public final class " + name.substr(dot + 1) + " extends org.hxmc.Peer" + (ifaces.length > 0 ? " implements " + ifaces.join(", ") : "") + " {\n");
		b.add("\tprivate " + name.substr(dot + 1) + "(long handle) {\n\t\tsuper(handle);\n\t}\n");
		for (m in p.methods) {
			var sig = parse(m.signature);
			var params = [for (i in 0...sig.args.length) sig.args[i] + " a" + i];
			var names = [for (i in 0...sig.args.length) "a" + i];
			b.add('\n\tprivate static native ${sig.ret} ${m.native}(${["long handle"].concat(params).join(", ")});\n');
			b.add('\n\t@Override\n\tpublic ${sig.ret} ${m.name}(${params.join(", ")}) {\n');
			b.add('\t\t${sig.ret == "void" ? "" : "return "}${m.native}(${["hxmcHandle"].concat(names).join(", ")});\n\t}\n');
		}
		b.add("}\n");
		return b.toString();
	}

	// a JNI signature's Java types: (ILjava/lang/String;)V
	static function parse(sig:String):{args:Array<String>, ret:String} {
		var i = 1;
		function one():String {
			var dims = "";
			while (sig.charAt(i) == "[") {
				dims += "[]";
				i++;
			}
			var c = sig.charAt(i++);
			var t = switch c {
				case "Z": "boolean";
				case "B": "byte";
				case "C": "char";
				case "S": "short";
				case "I": "int";
				case "J": "long";
				case "F": "float";
				case "D": "double";
				case "V": "void";
				case "L":
					var end = sig.indexOf(";", i);
					var n = sig.substring(i, end);
					i = end + 1;
					source(n);
				case _: throw 'JniGlue: a bad signature $sig';
			}
			return t + dims;
		}
		var args = [];
		while (sig.charAt(i) != ")")
			args.push(one());
		i++;
		return {args: args, ret: one()};
	}

	// a JNI or binary name as Java source names it (java/util/Map$Entry: java.util.Map.Entry)
	static function source(n:String):String
		return n.replace("/", ".").replace("$", ".");

	// the proxies' base class
	public static final PEER = "// The base of hxmc's Java proxies (docs/plans/jni.md, \"The glue\"): a Java
// object standing for a Haxe object that implements Java interfaces. Its
// handle is the Haxe object's peer entry; every proxy method passes it to
// its static native. While a proxy lives, its Haxe object is kept (the
// runtime's toggle); once Java collects it, the phantom reference below is
// enqueued and hxmcRelease (a native the runtime registers) tells Haxe.
package org.hxmc;

import java.lang.ref.PhantomReference;
import java.lang.ref.ReferenceQueue;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

public abstract class Peer {
	protected final long hxmcHandle;

	private static final ReferenceQueue<Peer> queue = new ReferenceQueue<>();
	private static final Set<Ref> live = ConcurrentHashMap.newKeySet();
	private static Thread drainer;

	protected Peer(long handle) {
		hxmcHandle = handle;
		live.add(new Ref(this, handle));
		start();
	}

	private static synchronized void start() {
		if (drainer != null) return;
		drainer = new Thread(Peer::drain, \"hxmc-peers\");
		drainer.setDaemon(true);
		drainer.start();
	}

	private static void drain() {
		while (true) {
			Ref r;
			try {
				r = (Ref) queue.remove();
			} catch (InterruptedException e) {
				return;
			}
			live.remove(r);
			hxmcRelease(r.handle);
		}
	}

	private static native void hxmcRelease(long handle);

	private static final class Ref extends PhantomReference<Peer> {
		final long handle;

		Ref(Peer p, long handle) {
			super(p, queue);
			this.handle = handle;
		}
	}
}
";

	// what a Haxe exception reaching Java is
	public static final HAXE_EXCEPTION = "// A Haxe exception that reached Java (docs/interop.md, \"Java (JNI)\"): a
// Haxe method Java called threw it; its message is the exception's.
package org.hxmc;

public class HaxeException extends RuntimeException {
	public HaxeException(String message) {
		super(message);
	}
}
";
}

typedef Manifest = {version:Int, proxies:Array<Proxy>}

@:forward abstract Proxy({haxe:String, interfaces:Array<String>, methods:Array<{name:String, signature:String, native:String}>}) {
	// ("class": a keyword in Haxe)
	public function cls():String
		return Reflect.field(this, "class");
}
