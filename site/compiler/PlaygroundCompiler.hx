import compiler.CompilerInstance;
import compiler.io.CompilerIo;
import hxmc.unsafe.*;

// The playground's compiler (bin/wasm/hih.wasm): the port as a wasm32-wasi
// module, with two ways to start (site/client/Worker.hx):
//
// - as `haxe` (haxe.Main): arguments in, one compilation, exit status out,
//   a fresh instance of the module per program the page runs;
// - with PLAYGROUND_SERVER in the environment, as a compiler kept between
//   requests: main makes the cache (compiler.CompilerInstance.InMemoryCache,
//   what `haxe --wait` keeps: the typed std, the modules), hands the page the
//   address of `request` and returns. The runtime stays as main left it
//   (docs/using.md, "wasm32-wasi"), and the page calls `request` through the
//   exported __indirect_function_table for each request: the file /request,
//   JSON {args, request}: the compiler's arguments (without --display) and a
//   JSON-RPC request, which a CompilerInstance of those arguments answers
//   (context.display.DisplayJson.dispatch) on stderr, as `haxe --display`.
@:hxmc.lib("playground") extern class Host {
	/** the compiler is ready: `request` is the table index of its request function */
	@:hxmc.c("serve") static function serve(request:Ptr):Void;
}

class PlaygroundCompiler {
	static var cache:InMemoryCache;

	/** the instance of the last request's arguments (the page's change with the main class) */
	static var instance:Null<{args:String, instance:CompilerInstance}> = null;

	static function main() {
		core.ds.GcPolicy.init();
		if (Sys.getEnv("PLAYGROUND_SERVER") == null) Sys.exit(haxe.Main.run(Sys.args()));
		cache = InMemoryCache.create();
		Host.serve(Callback.addr(request));
	}

	@:hxmc.callback static function request():Int {
		var status = try {
			var r:{args:Array<String>, request:Dynamic} = haxe.Json.parse(sys.io.File.getContent("/request"));
			var key = haxe.Json.stringify(r.args);
			if (instance == null || instance.args != key) instance = {args: key, instance: CompilerInstance.ofArgs(r.args, cache)};
			context.display.DisplayJson.dispatch(instance.instance, CompilerIo.createStdioIo(), haxe.Json.stringify(r.request));
			0;
		} catch (e:core.ds.Exit) {
			// (a request that is not one, or names no method: its error is the response)
			1;
		} catch (e:Dynamic) {
			Sys.stderr().writeString(Std.string(e) + "\n");
			1;
		}
		Sys.stdout().flush();
		Sys.stderr().flush();
		return status;
	}
}
