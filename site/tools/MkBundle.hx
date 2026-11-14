import haxe.io.Bytes;
import haxe.io.BytesOutput;
import sys.FileSystem;
import sys.io.File;

// Writes the std the playground's compiler reads (`node make.mjs site`): the std's
// top-level modules and its haxe/, sys/ and eval/ packages (what --interp,
// macros and HXB need), as one file the page's worker unpacks into its file
// system at /lib/haxe/std (site/client/Worker.hx):
//   <haxe> -cp site/tools --run MkBundle <std dir> <out>
// Format: a little-endian u32 n, n bytes of UTF-8 JSON [[path, size], ...]
// (paths relative to the std, sorted), then the files' bytes in that order.
class MkBundle {
	static function main() {
		var std = Sys.args()[0], out = Sys.args()[1];
		var files = [];
		var top = FileSystem.readDirectory(std);
		top.sort(cmp);
		for (n in top)
			if (!FileSystem.isDirectory('$std/$n') && StringTools.endsWith(n, ".hx")) files.push(n);
		for (pack in ["haxe", "sys", "eval"]) walk(std, pack, files);
		var data = [for (f in files) File.getBytes('$std/$f')];
		var index = Bytes.ofString(haxe.Json.stringify([for (i in 0...files.length) ([files[i], data[i].length] : Array<Dynamic>)]));
		var o = new BytesOutput();
		o.writeInt32(index.length);
		o.write(index);
		for (b in data) o.write(b);
		File.saveBytes(out, o.getBytes());
		Sys.println('mkbundle: ${files.length} files, ${FileSystem.stat(out).size} bytes');
	}

	static function walk(std:String, rel:String, files:Array<String>) {
		var names = FileSystem.readDirectory('$std/$rel');
		names.sort(cmp);
		// files and directories in one order, as os.walk visited them: files of a
		// directory first, then its subdirectories
		for (n in names) if (!FileSystem.isDirectory('$std/$rel/$n')) files.push('$rel/$n');
		for (n in names) if (FileSystem.isDirectory('$std/$rel/$n')) walk(std, '$rel/$n', files);
	}

	static function cmp(a:String, b:String) return a < b ? -1 : a > b ? 1 : 0;
}
