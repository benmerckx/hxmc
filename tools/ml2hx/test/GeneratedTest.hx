import core.ds.Ring;
import compiler.server.ServerConfig;
import context.TyperPass;
import ml2hx.rt.Int63;

class GeneratedTest {
	static function eq<T>(a:T, b:T):Void if (a != b) throw 'expected $b, got $a';
	static function main() {
		var r = new Ring<Int>(4, 0);
		var values = [];
		r.iter(v -> values.push(v));
		eq(values.join(","), "0,0,0,0");
		eq(r.isFilled(), false);
		for (i in 1...7) r.push(i);
		values = [];
		r.iter(v -> values.push(v));
		eq(values.join(","), "3,4,5,6");
		eq(r.fold("", (a, b) -> a + b), "3456");
		// Upstream find visits storage order, not the rotation used by iter/fold.
		eq(r.find(v -> v > 0), 5);
		var missing = false;
		try r.find(v -> v == 9) catch (_:core.ds.NotFound) missing = true;
		eq(missing, true);
		eq(r.isFilled(), true);
		r.resetFilled();
		eq(r.isFilled(), false);
		// A tail-recursive search/fold must not exhaust a JavaScript or Eval stack.
		var large = new Ring<Int>(100000, 1);
		eq(large.fold(0, (a, b) -> a + b), 100000);
		missing = false;
		try large.find(v -> false) catch (_:core.ds.NotFound) missing = true;
		eq(missing, true);
		ServerConfig.doNotCheckModules = true;
		ServerConfig.maxCompletionItems = 55;
		ServerConfig.staleContextMaxAgeSeconds = -1;
		ServerConfig.reset();
		eq(ServerConfig.doNotCheckModules, false);
		eq(ServerConfig.maxCompletionItems, 0);
		eq(ServerConfig.staleContextMaxAgeSeconds, ServerConfig.defaultStaleContextMaxAge);
		eq(TyperPassTools.allTyperPassesLength, 7);
		eq(TyperPassTools.allTyperPasses[0], PBuildModule);
		eq(TyperPassTools.allTyperPasses[6], PFinal);
		eq(Int63.add(Int63.parse("4611686018427387903"), Int63.ofInt(1)).toString(), "-4611686018427387904");
		eq(Int63.div(Int63.parse("4294967296"), Int63.ofInt(2)).toString(), "2147483648");
		eq(Int63.mod(Int63.ofInt(-7), Int63.ofInt(3)).toString(), "-1");
		#if js js.Syntax.code("console.log('generated modules: pass')"); #else Sys.println("generated modules: pass"); #end
	}
}
