package hxmc.simd;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
#end

// The vector types' operations (docs/plans/simd.md), each a WebAssembly
// SIMD instruction by name: on hxmc's native and WebAssembly targets the
// compiler's intrinsic (Simd, expanded inline), elsewhere (the Mir
// interpreter, Eval, JavaScript, ...) the same operation lane by lane (Ref,
// by opcode, with the same results). Lanes and constants' words are
// literals.
@:noCompletion class Ops {
	#if macro
	// (OpList's names and opcodes, the compiler's too: hxmc.SimdOps)
	static final CODES:Map<String, Int> = [for (x in OpList.LIST) x.name => x.code];

	static function native():Bool
		return Context.definedValue("target.name") == "hxmc" && !Context.defined("hxmc.interp");

	static function code(op:Expr):Expr {
		var n = switch op.expr {
			case EConst(CString(s, _)): s;
			case _: Context.error("hxmc.simd: the operation must be a literal", op.pos);
		};
		if (!CODES.exists(n)) Context.error("hxmc.simd: no operation " + n, op.pos);
		return macro $v{CODES.get(n)};
	}

	static function call(fn:String, op:Null<Expr>, args:Array<Expr>):Expr {
		if (native()) return macro hxmc.simd.Simd.$fn($a{op == null ? args : [op].concat(args)});
		if (fn == "load" || fn == "store") return macro hxmc.simd.RefMem.$fn($a{[code(op)].concat(args)});
		return macro hxmc.simd.Ref.$fn($a{op == null ? args : [code(op)].concat(args)});
	}
	#end

	public static macro function op1(op:Expr, a:Expr):Expr
		return call("op1", op, [a]);

	public static macro function op2(op:Expr, a:Expr, b:Expr):Expr
		return call("op2", op, [a, b]);

	public static macro function op3(op:Expr, a:Expr, b:Expr, c:Expr):Expr
		return call("op3", op, [a, b, c]);

	public static macro function shift(op:Expr, a:Expr, n:Expr):Expr
		return call("shift", op, [a, n]);

	public static macro function splatInt(op:Expr, x:Expr):Expr
		return call("splatInt", op, [x]);

	public static macro function splatI64(op:Expr, x:Expr):Expr
		return call("splatI64", op, [x]);

	public static macro function splatFloat(op:Expr, x:Expr):Expr
		return call("splatFloat", op, [x]);

	public static macro function extractInt(op:Expr, a:Expr, lane:Expr):Expr
		return call("extractInt", op, [a, lane]);

	public static macro function extractI64(op:Expr, a:Expr, lane:Expr):Expr
		return call("extractI64", op, [a, lane]);

	public static macro function extractFloat(op:Expr, a:Expr, lane:Expr):Expr
		return call("extractFloat", op, [a, lane]);

	public static macro function replaceInt(op:Expr, a:Expr, lane:Expr, x:Expr):Expr
		return call("replaceInt", op, [a, lane, x]);

	public static macro function replaceI64(op:Expr, a:Expr, lane:Expr, x:Expr):Expr
		return call("replaceI64", op, [a, lane, x]);

	public static macro function replaceFloat(op:Expr, a:Expr, lane:Expr, x:Expr):Expr
		return call("replaceFloat", op, [a, lane, x]);

	public static macro function test(op:Expr, a:Expr):Expr
		return call("test", op, [a]);

	public static macro function shuffle(a:Expr, b:Expr, lanes:Array<Expr>):Expr
		return call("shuffle", null, [a, b].concat(lanes));

	public static macro function const(w0:Expr, w1:Expr, w2:Expr, w3:Expr):Expr
		return call("const", null, [w0, w1, w2, w3]);

	// raw memory at p + off (hxmc only)
	public static macro function load(op:Expr, p:Expr, off:Expr):Expr
		return call("load", op, [p, off]);

	public static macro function store(op:Expr, p:Expr, off:Expr, v:Expr):Expr
		return call("store", op, [p, off, v]);
}
