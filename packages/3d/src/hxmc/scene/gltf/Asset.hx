package hxmc.scene.gltf;

#if macro
import haxe.macro.Context;
#end

// Files built into the program (the asset step's start): Asset.embed(path)
// is the file's bytes, read when compiling (path relative to a class path,
// else to the working directory), so a model needs no file system at run
// time (the browser, phones).
class Asset {
	public static macro function embed(path:String):haxe.macro.Expr {
		var file = try Context.resolvePath(path) catch (_:Dynamic) path;
		if (!sys.FileSystem.exists(file)) Context.error('Asset.embed: $path not found', Context.currentPos());
		Context.registerModuleDependency(Context.getLocalModule(), file);
		var b = sys.io.File.getBytes(file);
		return macro haxe.crypto.Base64.decode($v{haxe.crypto.Base64.encode(b)});
	}
}
