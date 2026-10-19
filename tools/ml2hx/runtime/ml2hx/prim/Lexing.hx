package ml2hx.prim;

import Array as HArray;
import String;
import StdTypes;
import ml2hx.rt.*;

// The C primitives of Stdlib.Lexing (converted from OCaml): the OCaml
// runtime's lexing.c. The converted records are reached by field name.
class Lexing {
	// ---------------------------------------------------------------- lexing.c
	static inline function short(tbl:String, n:Int):Int {
		var v = StringTools.fastCodeAt(tbl, 2 * n) | (StringTools.fastCodeAt(tbl, 2 * n + 1) << 8);
		return v >= 0x8000 ? v - 0x10000 : v;
	}
	static inline function geti(o:Dynamic, f:String):Int return (Reflect.field(o, f) : Int63).toInt();
	static inline function seti(o:Dynamic, f:String, v:Int) Reflect.setField(o, f, Int63.ofInt(v));
	static function engine(tbl:Dynamic, startState:Int63, lb:Dynamic, withMem:Bool):Int63 {
		var base = (Reflect.field(tbl, "lexBase") : String), backtrkT = (Reflect.field(tbl, "lexBacktrk") : String);
		var defT = (Reflect.field(tbl, "lexDefault") : String), trans = (Reflect.field(tbl, "lexTrans") : String), check = (Reflect.field(tbl, "lexCheck") : String);
		var state = startState.toInt();
		if (state >= 0) {
			var cur = geti(lb, "lexCurrPos");
			seti(lb, "lexLastPos", cur);
			seti(lb, "lexStartPos", cur);
			seti(lb, "lexLastAction", -1);
		} else state = -state - 1;
		var code = withMem ? (Reflect.field(tbl, "lexCode") : String) : null;
		var mem:HArray<Int63> = withMem ? Reflect.field(lb, "lexMem") : null;
		function run(pc:Int, curr:Null<Int>) {
			while (true) {
				var dst = StringTools.fastCodeAt(code, pc++);
				if (dst == 0xff) return;
				var src = StringTools.fastCodeAt(code, pc++);
				mem[dst] = src == 0xff ? Int63.ofInt(curr == null ? -1 : curr) : mem[src];
			}
		}
		while (true) {
			var b = short(base, state);
			if (b < 0) {
				if (withMem) run(short(Reflect.field(tbl, "lexBaseCode"), state), null);
				return Int63.ofInt(-b - 1);
			}
			var backtrk = short(backtrkT, state);
			if (backtrk >= 0) {
				if (withMem) run(short(Reflect.field(tbl, "lexBacktrkCode"), state), null);
				seti(lb, "lexLastPos", geti(lb, "lexCurrPos"));
				seti(lb, "lexLastAction", backtrk);
			}
			var c:Int;
			var cur = geti(lb, "lexCurrPos");
			if (cur >= geti(lb, "lexBufferLen")) {
				if (!(Reflect.field(lb, "lexEofReached") : Bool)) return Int63.ofInt(-state - 1);
				c = 256;
			} else {
				c = (Reflect.field(lb, "lexBuffer") : haxe.io.Bytes).get(cur);
				seti(lb, "lexCurrPos", cur + 1);
			}
			var pstate = state;
			state = short(check, b + c) == state ? short(trans, b + c) : short(defT, state);
			if (state < 0) {
				seti(lb, "lexCurrPos", geti(lb, "lexLastPos"));
				var act = geti(lb, "lexLastAction");
				if (act == -1) throw new Failure("lexing: empty token");
				return Int63.ofInt(act);
			}
			if (withMem) {
				var baseCode = short(Reflect.field(tbl, "lexBaseCode"), pstate);
				var pc = short(Reflect.field(tbl, "lexCheckCode"), baseCode + c) == pstate ? short(Reflect.field(tbl, "lexTransCode"), baseCode + c) : short(Reflect.field(tbl, "lexDefaultCode"), pstate);
				if (pc > 0) run(pc, geti(lb, "lexCurrPos"));
			}
			if (c == 256) Reflect.setField(lb, "lexEofReached", false);
		}
	}
	public static function camlLexEngine<T, L>(tbl:T, state:Int63, lb:L):Int63 return engine(tbl, state, lb, false);
	public static function camlNewLexEngine<T, L>(tbl:T, state:Int63, lb:L):Int63 return engine(tbl, state, lb, true);
}
