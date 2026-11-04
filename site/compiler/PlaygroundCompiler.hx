import compiler.CompilerInstance;
import compiler.io.CompilerIo;
import compiler.server.Server.RequestOutcome;
import hxmc.unsafe.*;

// The playground's compiler (bin/wasm/hih.wasm): the port as a wasm32-wasi
// module, with two ways to start (site/client/Worker.hx):
//
// - as `haxe` (haxe.Main): arguments in, one compilation, exit status out,
//   a fresh instance of the module per program the page runs;
// - with PLAYGROUND_SERVER in the environment, as a compilation server
//   without a socket: main makes a compiler.CompilerInstance (what
//   `haxe --wait` keeps between requests: the typed std, the module cache),
//   hands the page the address of `request` and returns. The runtime stays
//   as main left it (docs/hxmc.md, "WebAssembly"), and the page calls
//   `request` through the exported __indirect_function_table for each
//   display request: the request is the file /request, JSON {args, ?stdin}
//   (stdin: the text of the display file, which need not be saved, as an
//   editor sends it), its output goes to stdout and stderr as a compilation's.
@:hxmc.lib("playground") extern class Host {
	/** the server is ready: `request` is the table index of its request function */
	@:hxmc.c("serve") static function serve(request:Ptr):Void;
}

class PlaygroundCompiler {
	static var instance:CompilerInstance;

	static function main() {
		core.ds.GcPolicy.init();
		if (Sys.getEnv("PLAYGROUND_SERVER") == null) Sys.exit(haxe.Main.run(Sys.args()));
		instance = new CompilerInstance();
		Host.serve(Callback.addr(request));
	}

	@:hxmc.callback static function request():Int {
		var outcome = try {
			var request:{args:Array<String>, ?stdin:String} = haxe.Json.parse(sys.io.File.getContent("/request"));
			instance.request({args: compiler.Args.parseArgs(request.args), stdin: request.stdin, conn: null}, CompilerIo.createStdioIo());
		} catch (e:Dynamic) {
			Sys.stderr().writeString(Std.string(e) + "\n");
			Errored;
		}
		Sys.stdout().flush();
		Sys.stderr().flush();
		return switch outcome {
			case Success: 0;
			case Cancelled | Errored: 1;
			case Oom: 2;
		}
	}
}
