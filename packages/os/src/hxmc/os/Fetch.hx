package hxmc.os;

import haxe.io.Bytes;
#if (hxmc.target == "wasm32-wasi")
import hxmc.unsafe.*;
#end

// A file read without waiting: in the browser a fetch of its URL (relative
// to the page) in the background, polled; natively the file, read at once
// (it is done when start returns). For data whose path is known only at
// run time; files a program names statically come with it (@hxmc/3d's
// Model.of).
//
//   var f = Fetch.start("levels/2.glb");
//   // each frame:
//   if (f.poll()) use(f.bytes) else if (f.failed) ...;
class Fetch {
	public final path:String;
	public var bytes(default, null):Null<Bytes>;
	public var failed(default, null) = false;
	var handle = 0;

	function new(path:String) {
		this.path = path;
	}

	public static function start(path:String):Fetch {
		var f = new Fetch(path);
		#if (hxmc.target == "wasm32-wasi")
		f.handle = Arena.scopedValue(a -> hxmc.os.web.Dom.fetch_start(a.cstring(path)));
		#else
		try
			f.bytes = sys.io.File.getBytes(path)
		catch (_:Dynamic)
			f.failed = true;
		#end
		return f;
	}

	// whether the bytes are here (false while loading, or failed)
	public function poll():Bool {
		#if (hxmc.target == "wasm32-wasi")
		if (handle != 0) {
			var s = hxmc.os.web.Dom.fetch_state(handle);
			if (s == 1) {
				var n = hxmc.os.web.Dom.fetch_length(handle);
				var b = Bytes.alloc(n);
				var h = handle;
				Arena.scoped(a -> {
					var p = a.alloc(n + 1, 1);
					hxmc.os.web.Dom.fetch_take(h, p);
					BytesPtr.copyIn(b, 0, p, n);
				});
				bytes = b;
				handle = 0;
			} else if (s == -1) {
				hxmc.os.web.Dom.fetch_free(handle);
				handle = 0;
				failed = true;
			}
		}
		#end
		return bytes != null;
	}
}
