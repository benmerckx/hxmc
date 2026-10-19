package ml2hx.prim;

import ml2hx.rt.*;
import ocaml.stdlib.ParsingModule.ParsingParseTables;
import ocaml.stdlib.ParsingModule.ParsingParserEnv;
import ocaml.stdlib.ParsingModule.ParsingParserInput;
import ocaml.stdlib.ParsingModule.ParsingParserOutput;

// OCaml's parsing.c: the ocamlyacc automaton, driven by Parsing.yyparse.
class Parsing {
	static inline var ERRCODE = 256;
	static var trace = false;

	public static function camlSetParserTrace(b:Bool):Bool {
		var old = trace;
		trace = b;
		return old;
	}

	// a signed 16-bit little-endian entry of a table string
	static inline function short(tbl:String, n:Int):Int {
		var v = StringTools.fastCodeAt(tbl, 2 * n) | (StringTools.fastCodeAt(tbl, 2 * n + 1) << 8);
		return (v << 16) >> 16;
	}
	static inline function int(n:Int63):Int return n.toInt();
	static inline function ml(n:Int):Int63 return Int63.ofInt(n);

	public static function camlParseEngine(tables:ParsingParseTables, env:ParsingParserEnv, cmd:ParsingParserInput, arg:Any):ParsingParserOutput {
		var state = 0, sp = 0, errflag = 0;
		var n = 0, n1 = 0, n2 = 0, m = 0, state1 = 0;
		inline function save() {
			env.sp = ml(sp);
			env.state = ml(state);
			env.errflag = ml(errflag);
		}
		inline function restore() {
			sp = int(env.sp);
			state = int(env.state);
			errflag = int(env.errflag);
		}
		var tablesize = int(tables.tablesize);
		// the labels of the C code
		var label = switch cmd {
			case Start:
				state = 0;
				sp = int(env.sp);
				errflag = 0;
				"loop";
			case Token_read:
				restore();
				if (Obj.isInt(arg)) {
					env.currChar = tables.translConst[Poly.immediateOf(arg).low];
					env.lval = Int63.zero;
				} else {
					env.currChar = tables.translBlock[int(Obj.camlObjTag(arg))];
					env.lval = Obj.field(arg, Int63.zero);
				}
				"testshift";
			case Error_detected:
				restore();
				"recover";
			case Stacks_grown_1:
				restore();
				"push";
			case Stacks_grown_2:
				restore();
				"semantic_action";
			case Semantic_action_computed:
				restore();
				env.sStack[sp] = ml(state);
				env.vStack[sp] = arg;
				var asp = int(env.asp);
				env.symbEndStack[sp] = env.symbEndStack[asp];
				if (sp > asp) env.symbStartStack[sp] = env.symbEndStack[asp];
				"loop";
		}
		while (true) {
			switch label {
				case "loop":
					n = short(tables.defred, state);
					if (n != 0) {
						label = "reduce";
						continue;
					}
					if (int(env.currChar) >= 0) {
						label = "testshift";
						continue;
					}
					save();
					return Read_token;
				case "testshift":
					var c = int(env.currChar);
					n1 = short(tables.sindex, state);
					n2 = n1 + c;
					if (n1 != 0 && n2 >= 0 && n2 <= tablesize && short(tables.check, n2) == c) {
						label = "shift";
						continue;
					}
					n1 = short(tables.rindex, state);
					n2 = n1 + c;
					if (n1 != 0 && n2 >= 0 && n2 <= tablesize && short(tables.check, n2) == c) {
						n = short(tables.table, n2);
						label = "reduce";
						continue;
					}
					if (errflag > 0) {
						label = "recover";
						continue;
					}
					save();
					return Call_error_function;
				case "recover":
					if (errflag < 3) {
						errflag = 3;
						while (true) {
							state1 = int(env.sStack[sp]);
							n1 = short(tables.sindex, state1);
							n2 = n1 + ERRCODE;
							if (n1 != 0 && n2 >= 0 && n2 <= tablesize && short(tables.check, n2) == ERRCODE) break;
							if (sp <= int(env.stackbase)) return Raise_parse_error;
							sp--;
						}
						label = "shift_recover";
						continue;
					}
					if (int(env.currChar) == 0) return Raise_parse_error;
					env.currChar = ml(-1);
					label = "loop";
				case "shift":
					env.currChar = ml(-1);
					if (errflag > 0) errflag--;
					label = "shift_recover";
				case "shift_recover":
					state = short(tables.table, n2);
					sp++;
					if (sp < int(env.stacksize)) {
						label = "push";
						continue;
					}
					save();
					return Grow_stacks_1;
				case "push":
					env.sStack[sp] = ml(state);
					env.vStack[sp] = env.lval;
					env.symbStartStack[sp] = env.symbStart;
					env.symbEndStack[sp] = env.symbEnd;
					label = "loop";
				case "reduce":
					m = short(tables.len, n);
					env.asp = ml(sp);
					env.ruleNumber = ml(n);
					env.ruleLen = ml(m);
					sp = sp - m + 1;
					m = short(tables.lhs, n);
					state1 = int(env.sStack[sp - 1]);
					n1 = short(tables.gindex, m);
					n2 = n1 + state1;
					if (n1 != 0 && n2 >= 0 && n2 <= tablesize && short(tables.check, n2) == state1) state = short(tables.table, n2);
					else state = short(tables.dgoto, m);
					if (sp < int(env.stacksize)) {
						label = "semantic_action";
						continue;
					}
					save();
					return Grow_stacks_2;
				case "semantic_action":
					save();
					return Compute_semantic_action;
				case _:
					throw new InvalidArgument("Parsing: bad state");
			}
		}
	}
}
