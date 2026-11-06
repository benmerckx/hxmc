import compiler.CompilerInstance;
import compiler.io.CompilerIo;
import hxmc.unsafe.*;

// The playground's compiler (bin/wasm/hih.wasm): the port as a wasm32-wasi module,
// kept between the page's requests (site/client/Worker.hx). main makes the cache
// (compiler.CompilerInstance.InMemoryCache, what `haxe --wait` keeps: the typed std,
// the modules), hands the page the address of `request` and returns. The runtime
// stays as main left it (docs/using.md, "wasm32-wasi"), and the page calls `request`
// through the exported __indirect_function_table for each request: the file
// /request, JSON {args, ?request, ?clean}, the compiler's arguments and
//
// - a JSON-RPC request (display requests, checks): a CompilerInstance of those
//   arguments answers it (context.display.DisplayJson.dispatch) on stderr, as
//   `haxe --display`;
// - none: a build of those arguments (Run, Compile to HXB), its output on stdout and
//   stderr as `haxe` prints it, its exit code the result; `clean`: from source,
//   whatever is cached (-D hxmc.clean).
@:hxmc.lib("playground") extern class Host {
	/** the compiler is ready: `request` is the table index of its request function */
	@:hxmc.c("serve") static function serve(request:Ptr):Void;
}

class PlaygroundCompiler {
	static var cache:InMemoryCache;

	/** the instance of the last display request's arguments (the page's change with the main class) */
	static var instance:Null<{args:String, instance:CompilerInstance}> = null;

	static function main() {
		core.ds.GcPolicy.init();
		cache = InMemoryCache.create();
		Host.serve(Callback.addr(request));
	}

	@:hxmc.callback static function request():Int {
		var status = try {
			var r:{args:Array<String>, ?request:Dynamic, ?clean:Bool} = haxe.Json.parse(sys.io.File.getContent("/request"));
			if (r.request == null) {
				var instances = CompilerInstance.ofRequest(compiler.Args.expandArgs(compiler.Args.parseArgs(r.args)), cache);
				CompilerInstance.buildAll(instances, CompilerIo.createStdioIo(), {clean: r.clean == true}).code;
			} else {
				var key = haxe.Json.stringify(r.args);
				if (instance == null || instance.args != key) instance = {args: key, instance: CompilerInstance.ofArgs(r.args, cache)};
				context.display.DisplayJson.dispatch(instance.instance, CompilerIo.createStdioIo(), haxe.Json.stringify(r.request));
				0;
			}
		} catch (e:core.ds.Exit) {
			// (a request that is not one, or names no method: its error is the response)
			1;
		} catch (e:core.ds.ArgumentError) {
			// (as haxe reports a bad argument)
			Sys.stderr().writeString(e.message + "\n");
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
