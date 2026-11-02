// Objective-C from many threads at once (GCD's workers, dispatch_apply):
// blocks capturing and global, comparators allocating, Haxe methods
// Objective-C calls with blocks, strings, blocks and peers kept and called
// later from the main thread, collections among them; then the closures
// collected once the blocks are released. N, ROUNDS: the environment
import hxmc.objc.AutoreleasePool;
import hxmc.objc.Block;
import hxmc.objc.Strings;
import hxmc.unsafe.*;
import sys.thread.Mutex;

@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSNumber extends NSObject {
	static function numberWithLongLong(v:Int64):NSNumber;
	var longLongValue(get, never):Int64;
	function get_longLongValue():Int64;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSArray extends NSObject {
	var count(get, never):Int64;
	function get_count():Int64;
	function objectAtIndex(i:Int64):NSObject;
	function enumerateObjectsUsingBlock(block:(obj:NSObject, idx:Int64, stop:Ptr) -> Void):Void;
	function sortedArrayUsingComparator(cmptr:(a:NSObject, b:NSObject) -> Int64):NSArray;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSMutableArray extends NSArray {
	static function alloc():NSMutableArray;
	override function init():NSMutableArray;
	function addObject(o:NSObject):Void;
	function removeAllObjects():Void;
}

@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	var length(default, null):Int64;
}

@:hxmc.c extern class Dispatch {
	static function dispatch_apply(iterations:Int64, queue:Ptr, block:Block<(i:Int64) -> Void>):Void;
	static function dispatch_get_global_queue(identifier:Int64, flags:Int64):Ptr;
}

// a Haxe class Objective-C calls, on any thread
class Peer extends NSObject {
	public var seed:Int;
	public var tag:String;

	public function new(seed:Int) {
		this.seed = seed;
		tag = "peer" + seed;
	}

	public function compute(x:Int64):Int64
		return x * 2 + seed + tag.length - tag.length;

	public function applyTwice(f:(x:Int64) -> Int64):Int64
		return f(f(seed));

	// a block given a block, and a block returning a block
	public function withOffset(f:(add:(x:Int64) -> Int64) -> Int64):Int64
		return f(x -> x + seed);

	public function scaler(k:Int64):(x:Int64) -> ((y:Int64) -> Int64)
		return x -> y -> (x + y) * k + seed;
}

@:hxmc.objc extern class PeerMessages extends NSObject {
	function compute(x:Int64):Int64;
	function applyTwice(f:(x:Int64) -> Int64):Int64;
	function withOffset(f:(add:(x:Int64) -> Int64) -> Int64):Int64;
	function scaler(k:Int64):(x:Int64) -> ((y:Int64) -> Int64);
}

class ObjCStress {
	static var N = 2000;
	static inline var K = 20;
	static var lock = new Mutex();
	static var held:NSMutableArray; // blocks and peers kept for later (under lock)
	static var keepPeers:Array<Peer> = [];
	static var failures:Array<String> = [];
	static var globalCalls = 0;
	static var finalised = 0;

	static function fail(s:String) {
		lock.acquire();
		if (failures.length < 20) failures.push(s);
		lock.release();
	}

	// (a global block: captures nothing)
	static function countGlobal(o:NSObject, idx:Int64, stop:Ptr):Void {
		lock.acquire();
		globalCalls++;
		lock.release();
	}

	static function num(o:NSObject):Int64
		return (cast o : NSNumber).longLongValue;

	static function iteration(i:Int) {
		AutoreleasePool.run(() -> {
			var arr = NSMutableArray.alloc().init();
			for (k in 0...K)
				arr.addObject(NSNumber.numberWithLongLong((k * 7 + i) % 13));
			// a capturing block
			var sum:Int64 = 0;
			arr.enumerateObjectsUsingBlock((o, idx, stop) -> sum += num(o) + idx);
			var expect:Int64 = 0;
			for (k in 0...K)
				expect += (k * 7 + i) % 13 + k;
			if (sum != expect) fail('sum $i: $sum != $expect');
			// a global block
			arr.enumerateObjectsUsingBlock(countGlobal);
			// a comparator, allocating meanwhile
			var sorted = arr.sortedArrayUsingComparator((a, b) -> {
				var junk = [for (j in 0...4) "c" + j];
				var x = num(a), y = num(b);
				x < y ? -1 : x > y ? 1 : junk.length - 4;
			});
			for (k in 1...K)
				if (num(sorted.objectAtIndex(k - 1)) > num(sorted.objectAtIndex(k))) fail('sort $i');
			// a peer: messages on this thread, a block through its method
			var p = new Peer(i);
			var pm:PeerMessages = cast (p : NSObject);
			if (pm.compute(5) != 10 + i) fail('compute $i');
			var mul = 3;
			var r = pm.applyTwice(x -> x * mul);
			if (r != (i : Int64) * 9) fail('applyTwice $i: $r');
			// blocks of blocks, both ways
			var w = pm.withOffset(add -> add(mul) + add(1));
			if (w != (2 * i + 4 : Int64)) fail('withOffset $i: $w');
			var sc = pm.scaler(mul)(2);
			hxmc.rt.Gc.collect(false);
			if (sc(i) != ((i + 2) * 3 + i : Int64)) fail('scaler $i');
			// strings, unit for unit
			var s = "iteration " + i + " € " + String.fromCharCode(0x4e00 + i % 100);
			var back = Strings.ofNSString(Strings.toNSString(s));
			if (back != s) fail('string $i');
			// kept for later: a block capturing i and a marker, and the peer
			var marker = {i: i};
			hxmc.rt.Gc.finalise(_ -> {
				lock.acquire();
				finalised++;
				lock.release();
			}, marker);
			var later:Block<() -> Int64> = () -> (marker.i : Int64) * 2;
			lock.acquire();
			held.addObject(cast later);
			if (i % 10 == 0) {
				held.addObject(p);
				keepPeers.push(p);
			}
			lock.release();
			// garbage, and now and then a collection
			var junk = [for (j in 0...200) {a: j, s: "x" + j}];
			if (junk.length != 200) fail("junk");
			if (i % 97 == 0) hxmc.rt.Gc.collect(i % 194 == 0);
		});
	}

	static function main() {
		var n = Sys.getEnv("N");
		if (n != null) N = Std.parseInt(n);
		var rounds = Sys.getEnv("ROUNDS") == null ? 1 : Std.parseInt(Sys.getEnv("ROUNDS"));
		for (round in 0...rounds) {
			globalCalls = 0;
			finalised = 0;
			keepPeers = [];
			round1();
		}
	}

	static function round1() {
		held = NSMutableArray.alloc().init();
		Dispatch.dispatch_apply(N, Dispatch.dispatch_get_global_queue(0, 0), i -> iteration(i.toInt()));
		// the kept blocks and peers, from the main thread, after collections
		hxmc.rt.Gc.collect(true);
		var blocks:Int64 = 0, peers = 0, peerSum:Int64 = 0;
		AutoreleasePool.run(() -> {
			for (k in 0...(held.count : Int)) {
				var o = held.objectAtIndex(k);
				var p:Null<Peer> = Std.downcast(cast o, Peer);
				if (p != null) {
					peers++;
					peerSum += (cast o : PeerMessages).compute(1);
				} else {
					var f:() -> Int64 = (cast o : Block<() -> Int64>);
					blocks += f();
				}
			}
		});
		var expectBlocks:Int64 = 0;
		for (i in 0...N)
			expectBlocks += i * 2;
		var expectPeerSum:Int64 = 0;
		for (i in 0...N)
			if (i % 10 == 0) expectPeerSum += 2 + i;
		trace("blocks " + (blocks == expectBlocks) + ", peers " + peers + " " + (peerSum == expectPeerSum) + ", global calls " + (globalCalls == N * K));
		// released: the markers' closures collectable
		held.removeAllObjects();
		for (_ in 0...3)
			hxmc.rt.Gc.collect(true);
		hxmc.rt.Gc.runFinalisers();
		trace("finalised " + (finalised == N) + " (" + finalised + ")");
		trace("failures " + failures.length + (failures.length > 0 ? ": " + failures.join(", ") : ""));
	}
}
