package ml2hx.std;

import Array;
import String;
import StdTypes;
import ml2hx.rt.*;

// Stdlib.Gc: the host's collector is not OCaml's; the control settings are
// kept (and ignored) and the statistics are zero.
class GcControl implements Block {
	public final minorHeapSize:Int63;
	public final majorHeapIncrement:Int63;
	public final spaceOverhead:Int63;
	public final verbose:Int63;
	public final maxOverhead:Int63;
	public final stackLimit:Int63;
	public final allocationPolicy:Int63;
	public final windowSize:Int63;
	public final customMajorRatio:Int63;
	public final customMinorRatio:Int63;
	public final customMinorMaxSize:Int63;
	public function new(a:Int63, b:Int63, c:Int63, d:Int63, e:Int63, f:Int63, g:Int63, h:Int63, i:Int63, j:Int63, k:Int63) {
		minorHeapSize = a; majorHeapIncrement = b; spaceOverhead = c; verbose = d; maxOverhead = e; stackLimit = f;
		allocationPolicy = g; windowSize = h; customMajorRatio = i; customMinorRatio = j; customMinorMaxSize = k;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 11;
	public function blockField(i:Int):Dynamic return [minorHeapSize, majorHeapIncrement, spaceOverhead, verbose, maxOverhead, stackLimit, allocationPolicy, windowSize, customMajorRatio, customMinorRatio, customMinorMaxSize][i];
}

class GcStat implements Block {
	public final minorWords:Float = 0;
	public final promotedWords:Float = 0;
	public final majorWords:Float = 0;
	public final minorCollections:Int63 = Int63.zero;
	public final majorCollections:Int63 = Int63.zero;
	public final heapWords:Int63 = Int63.zero;
	public final heapChunks:Int63 = Int63.zero;
	public final liveWords:Int63 = Int63.zero;
	public final liveBlocks:Int63 = Int63.zero;
	public final freeWords:Int63 = Int63.zero;
	public final freeBlocks:Int63 = Int63.zero;
	public final largestFree:Int63 = Int63.zero;
	public final fragments:Int63 = Int63.zero;
	public final compactions:Int63 = Int63.zero;
	public final topHeapWords:Int63 = Int63.zero;
	public final stackSize:Int63 = Int63.zero;
	public final forcedMajorCollections:Int63 = Int63.zero;
	public function new() {}
	public function blockTag():Int return 0;
	public function blockSize():Int return 17;
	public function blockField(i:Int):Dynamic return ([minorWords, promotedWords, majorWords, minorCollections, majorCollections, heapWords, heapChunks, liveWords, liveBlocks, freeWords, freeBlocks, largestFree, fragments, compactions, topHeapWords, stackSize, forcedMajorCollections] : std.Array<Dynamic>)[i];
}

class Gc {
	static var control = new GcControl(Int63.ofInt(262144), Int63.ofInt(15), Int63.ofInt(120), Int63.zero, Int63.ofInt(500), Int63.zero, Int63.ofInt(2), Int63.one, Int63.ofInt(44), Int63.ofInt(100), Int63.ofInt(70000));
	public static function get(_:Unit):GcControl return control;
	public static function set(c:GcControl):Unit { control = c; return Unit.value; }
	public static function stat(_:Unit):GcStat return new GcStat();
	public static function quickStat(_:Unit):GcStat return new GcStat();
	public static function counters(_:Unit):Tuple3<Float, Float, Float> return new Tuple3(0.0, 0.0, 0.0);
	public static function minorWords(_:Unit):Float return 0;
	public static function minor(_:Unit):Unit return Unit.value;
	public static function major(_:Unit):Unit return Unit.value;
	public static function fullMajor(_:Unit):Unit return Unit.value;
	public static function compact(_:Unit):Unit return Unit.value;
	public static function heapWords(_:Unit):Int63 return Int63.zero;
}
