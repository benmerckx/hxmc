package compiler.hxb;

import core.Globals.GlobalTypePath;
import core.Timer;
import core.Timer.TimerContext;
import core.ZipInput;
import core.ds.AtomicLazy;
import core.ds.Failure;
import core.ds.NotFound;
import context.Common;
import context.Common.AbstractHxbLib;
import context.Common.CommonContext;
import haxe.io.Bytes;

class HxbLibrary implements AbstractHxbLib {
	final timerCtx:TimerContext;
	final filePath:String;
	final hxbTimes:Null<TimerContext>;

	final zip:AtomicLazy<ZipInput>;

	var cachedFiles:Array<String> = [];
	// port: upstream's Hashtbl keyed by (pack,name), keyed by `key` here; lookups see the latest binding.
	final modules:Map<String, {filename:String, entry:ZipEntry}> = new Map();
	var closed = false;
	var loaded = false;
	var stringPool:Null<haxe.ds.Vector<String>> = null;
	var macroStringPool:Null<haxe.ds.Vector<String>> = null;

	public function new(timerCtx:TimerContext, filePath:String, hxbTimes:Null<TimerContext>) {
		this.timerCtx = timerCtx;
		this.filePath = filePath;
		this.hxbTimes = hxbTimes;
		zip = AtomicLazy.fromFun(function() return ZipInput.openIn(filePath));
	}

	static function key(pack:Array<String>, name:String):String return pack.join("/") + "#" + name;

	function doLoad():Void {
		for (entry in zip.force().entries) {
			var filename = entry.filename;
			if (!entry.isDirectory && StringTools.endsWith(filename, ".hxb")) {
				var pack = filename.split("/");
				pack.reverse();
				if (pack.length == 0) continue;
				var name = pack.shift();
				name = name.substr(0, name.length - 4);
				pack.reverse();
				modules.set(key(pack, name), {filename: filename, entry: entry});
			}
		}
	}

	public function load():Void {
		if (!loaded) {
			loaded = true;
			Timer.time(timerCtx, ["hxblib", "read"], function(_) doLoad(), null);
		}
	}

	public function getBytes(target:String, path:GlobalTypePath):Null<Bytes> {
		var m = modules.get(key([target].concat(path.pack), path.name));
		if (m == null) return null;
		var entry = m.entry;
		var data = Timer.time(timerCtx, ["hxblib", "get bytes"], function(_) {
			var zip = zip.force();
			return zip.readEntry(entry);
		}, null);
		return data;
	}

	public function close():Void {
		if (!closed) {
			closed = true;
			zip.force().closeIn();
		}
	}

	public function getFilePath():String return filePath;

	public function getStringPool(target:String):Null<haxe.ds.Vector<String>> {
		return if (target == "macro" && macroStringPool != null) macroStringPool else stringPool;
	}
}

class HxbLib {
	public static function createHxbLib(com:CommonContext, filePath:String):HxbLibrary {
		var file = if (sys.FileSystem.exists(filePath)) filePath else try {
			Common.findFile(com, filePath);
		} catch (_:NotFound) {
			throw new Failure("hxb lib " + filePath + " not found");
		}
		return new HxbLibrary(com.timerCtx, file, Common.defined(com, core.Define.HxbTimes) ? com.timerCtx : null);
	}
}
