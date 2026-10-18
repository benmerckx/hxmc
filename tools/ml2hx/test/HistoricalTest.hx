import history.ServerConfigModule;
import ml2hx.rt.Int63;
import ml2hx.rt.Unit;
#if history_ring
import history.RingModule;
#end
class HistoricalTest {
	static function eq<T>(a:T, b:T):Void if (a != b) throw 'expected $b, got $a';
	static function main() {
		eq(ServerConfigModule.doNotCheckModules.value, false);
		ServerConfigModule.doNotCheckModules.value = true;
		eq(ServerConfigModule.doNotCheckModules.value, true);
		#if history_legacy
		eq(ServerConfigModule.legacyCompletion.value, false);
		ServerConfigModule.legacyCompletion.value = true;
		eq(ServerConfigModule.legacyCompletion.value, true);
		#end
		#if history_ring
		var r = RingModule.create()(Int63.ofInt(4))(0);
		for (i in 1...7) RingModule.push()(r)(i);
		var order = RingModule.fold()(r)("")(s -> i -> s + i);
		eq(order, "3456");
		#if history_ring_find eq(RingModule.find()(r)(i -> i > 0), 5); #end
		eq(RingModule.isFilled()(r), true);
		RingModule.resetFilled()(r);
		eq(RingModule.isFilled()(r), false);
		#end
		#if js js.Syntax.code("console.log('historical generated modules: pass')");
		#else Sys.println("historical generated modules: pass"); #end
	}
}
