package ml2hx.std;

import Array as HArray;
import String;
import StdTypes;
import ml2hx.rt.*;
import ml2hx.std.Random_State;

// Stdlib.Random over the default state (State.make [|314159265|]).
class Random {
	static var state = new RandomStateT(haxe.Int64.make(0xAA0047AA, 0x8490D7F7), haxe.Int64.make(0x0823ED43, 0x4F15BE25), haxe.Int64.make(0x88C5AE8A, 0x97BA9E31), haxe.Int64.make(0x58A8EA37, 0x93DB4C0C));
	public static function init(seed:Int63):Unit { state = Random_State.make([seed]); return Unit.value; }
	public static function fullInit(seed:HArray<Int63>):Unit { state = Random_State.make(seed); return Unit.value; }
	public static function selfInit(_:Unit):Unit { state = Random_State.makeSelfInit(Unit.value); return Unit.value; }
	public static function bits(_:Unit):Int63 return Random_State.bits(state);
	public static function int(bound:Int63):Int63 return Random_State.int(state, bound);
	public static function fullInt(bound:Int63):Int63 return Random_State.fullInt(state, bound);
	public static function int64(bound:haxe.Int64):haxe.Int64 return Random_State.int64(state, bound);
	public static function float(bound:Float):Float return Random_State.float(state, bound);
	public static function bool(_:Unit):Bool return Random_State.bool(state);
	public static function bits32(_:Unit):haxe.Int32 return Random_State.bits32(state);
	public static function bits64(_:Unit):haxe.Int64 return Random_State.bits64(state);
	public static function getState(_:Unit):RandomStateT return Random_State.copy(state);
	public static function setState(s:RandomStateT):Unit { state = Random_State.copy(s); return Unit.value; }
	public static function split(_:Unit):RandomStateT return Random_State.split(state);
}
