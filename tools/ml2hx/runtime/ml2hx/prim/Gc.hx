package ml2hx.prim;

import ml2hx.rt.*;
import ocaml.stdlib.GcModule.GcStat;
import ocaml.stdlib.GcModule.GcControl;
import ocaml.stdlib.GcModule.GcMemprofT;
import ocaml.stdlib.GcModule.GcMemprofTracker;

// OCaml's gc.c: the host's collector is not OCaml's. The control settings
// are kept; the statistics count nothing; collections and finalisers are the
// host's business (a finaliser never runs: OCaml runs them only after a
// collection finds the value unreachable).
class Gc {
	static inline function z():Int63 return Int63.zero;
	static var control:Null<GcControl> = null;

	public static function camlGcStat(_:Unit):GcStat return new GcStat(0, 0, 0, z(), z(), z(), z(), z(), z(), z(), z(), z(), z(), z(), z(), z(), z());
	public static function camlGcQuickStat(_:Unit):GcStat return camlGcStat(Unit.value);
	public static function camlGcCounters(_:Unit):Tuple3<Float, Float, Float> return new Tuple3(0.0, 0.0, 0.0);
	public static function camlGcMinorWords(_:Unit):Float return 0;
	public static function camlGcGet(_:Unit):GcControl {
		if (control == null) control = new GcControl(Int63.ofInt(262144), Int63.ofInt(15), Int63.ofInt(120), z(), Int63.ofInt(500), Int63.ofInt(134217728),
			Int63.ofInt(2), Int63.one, Int63.ofInt(44), Int63.ofInt(100), Int63.ofInt(70000));
		return control;
	}
	public static function camlGcSet(c:GcControl):Unit {
		control = c;
		return Unit.value;
	}
	public static function camlGcMinor(_:Unit):Unit return Unit.value;
	public static function camlGcMajorSlice(n:Int63):Int63 return z();
	public static function camlGcMajor(_:Unit):Unit return Unit.value;
	public static function camlGcFullMajor(_:Unit):Unit return Unit.value;
	public static function camlGcCompaction(_:Unit):Unit return Unit.value;
	public static function camlGetMinorFree(_:Unit):Int63 return z();
	public static function camlFinalRegister<T>(f:T->Unit, v:T):Unit return Unit.value;
	public static function camlFinalRegisterCalledWithoutValue<T>(f:Unit->Unit, v:T):Unit return Unit.value;
	public static function camlFinalRelease(_:Unit):Unit return Unit.value;
	public static function camlMemprofStart<A, B>(rate:Float, size:Int63, t:GcMemprofTracker<A, B>):GcMemprofT return new GcMemprofT();
	public static function camlMemprofStop(_:Unit):Unit return Unit.value;
	public static function camlMemprofDiscard(t:GcMemprofT):Unit return Unit.value;
}
