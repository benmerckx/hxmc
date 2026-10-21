/*
 *  Neko Compiler
 *  Copyright (c)2005 Motion-Twin
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License or the LICENSE file for more details.
 */

package libs.neko;

import haxe.ds.StringMap;
import haxe.ds.Vector;
import libs.neko.Nast;
import libs.neko.Nbytecode;

// port: haxe/libs/neko/ncompile.ml

/*
 *  Neko Compiler
 *  Copyright (c)2005 Motion-Twin
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License or the LICENSE file for more details.
 */
enum Access {
	XEnv(n:Int);
	XStack(n:Int);
	XGlobal(n:Int);
	XField(s:String);
	XIndex(n:Int);
	XArray;
	XThis;
}

@:structInit class Label {
	public final lname:String;
	public final ltraps:Array<Int>;
	public final lstack:Int;
	public var lpos:Null<Int>;
	public var lwait:Array<Void->Void>;
}

@:structInit class FunctionCode {
	public final ops:Array<Opcode>;
	public final pos:Array<DebugPos>;
	public final gid:Int;
	public final nargs:Int;
}

@:structInit class Globals {
	// port: (global,int) Hashtbl.t, only looked up: keyed by `globalKey`.
	public final globals:StringMap<Int>;
	// port: (string list,int) Hashtbl.t: keyed by the joined list; the list is kept for
	// iteration, which upstream sorts by id.
	public final gobjects:StringMap<{fields:Array<String>, id:Int}>;
	public var gobjectsCount:Int;
	// port: a list with the newest function first, as upstream.
	public var functions:Array<FunctionCode>;
	public var gtable:Array<Global>;
	public final labels:StringMap<Label>;
	public final hfiles:StringMap<Int>;
	public final files:Array<String>;
}

@:structInit class Context {
	public final g:Globals;
	public final version:Int;
	public var ops:Array<Opcode>;
	// port: (string,int) PMap.t, persistent: updates go through `PMap.add` copies.
	public var locals:StringMap<Int>;
	public var env:StringMap<Int>;
	public var nenv:Int;
	public var stack:Int;
	public var loopLimit:Int;
	public var loopTraps:Int;
	public var limit:Int;
	// port: OCaml lists, newest first.
	public var traps:Array<Int>;
	public var breaks:Array<{f:Void->Void, p:Pos}>;
	public var continues:Array<{f:Void->Void, p:Pos}>;
	public var pos:Array<DebugPos>;
	public var curpos:DebugPos;
	public var curfile:String;
}

class Error extends haxe.Exception {
	public final msg:String;
	public final pos:Pos;

	public function new(msg:String, pos:Pos) {
		super(msg);
		this.msg = msg;
		this.pos = pos;
	}
}

private typedef SavedBreaks = {
	ctx:Context,
	oldc:Array<{f:Void->Void, p:Pos}>,
	oldb:Array<{f:Void->Void, p:Pos}>,
	oldl:Int,
	oldt:Int
};

class Ncompile {
	static function error(e:String, p:Pos):Dynamic throw new Error(e, p);

	static function errorMsg(s:String):String return s;

	static function assertFalse():Dynamic throw new core.ds.Failure("Assert_failure ncompile.ml");

	static function globalKey(g:Global):String return switch g {
		case GlobalVar(s): "v" + s;
		case GlobalFunction(p, nargs): "F" + p + ":" + nargs;
		case GlobalString(s): "s" + s;
		case GlobalFloat(s): "f" + s;
		case GlobalDebug(_): throw new core.ds.Failure("ncompile: GlobalDebug is never a global key");
		case GlobalVersion(v): "V" + v;
	}

	static function pmapAdd(k:String, v:Int, m:StringMap<Int>):StringMap<Int> {
		var out = m.copy();
		out.set(k, v);
		return out;
	}

	static function stackDelta(o:Opcode):Int {
		return switch o {
			case AccNull | AccTrue | AccFalse | AccThis | AccInt(_) | AccInt32(_) | AccStack(_) | AccGlobal(_) | AccEnv(_) | AccField(_) | AccBuiltin(_) |
				AccIndex(_) | JumpIf(_) | JumpIfNot(_) | Jump(_) | JumpTable(_) | Ret(_) | SetGlobal(_) | SetStack(_) | SetEnv(_) | SetThis | Bool | IsNull |
				IsNotNull | Not | Hash | TypeOf | New | AccStack0 | AccStack1 | AccIndex0 | AccIndex1 | Loop:
				0;
			case Add | Sub | Mult | Div | Mod | Shl | Shr | UShr | Or | And | Xor | Eq | Neq | Gt | Gte | Lt | Lte | PhysCompare:
				-1;
			case AccArray: -1;
			case SetField(_) | SetIndex(_) | Compare: -1;
			case SetArray: -2;
			case Push: 1;
			case Pop(x): -x;
			case Apply(nargs) | Call(nargs) | TailCall(nargs, _): -nargs;
			case ObjCall(nargs): -(nargs + 1);
			case MakeEnv(size) | MakeArray(size): -size;
			case Trap(_): Nbytecode.trapStackDelta;
			case EndTrap: -Nbytecode.trapStackDelta;
		}
	}

	static function checkStack(ctx:Context, stack:Int, p:Pos):Void {
		if (ctx.stack != stack) error("Stack alignment failure", p);
	}

	static inline function pos(ctx:Context):Int return ctx.ops.length;

	static final realNullPos:Pos = {pline: 0, psource: "<null>"};

	static function setPos(ctx:Context, p:Pos):Void {
		if (p.psource == ctx.curfile) {
			if (p.pline != ctx.curpos.line) ctx.curpos = new DebugPos(ctx.curpos.file, p.pline);
		} else if (p.equals(realNullPos)) {} else {
			var fid = ctx.g.hfiles.get(p.psource);
			if (fid == null) {
				fid = ctx.g.files.length;
				ctx.g.files.push(p.psource);
				ctx.g.hfiles.set(p.psource, fid);
			}
			ctx.curfile = p.psource;
			ctx.curpos = new DebugPos(fid, p.pline);
		}
	}

	static function write(ctx:Context, op:Opcode):Void {
		ctx.stack = ctx.stack + stackDelta(op);
		ctx.pos.push(ctx.curpos);
		if (Nbytecode.opParam(op)) ctx.pos.push(ctx.curpos);
		ctx.ops.push(op);
	}

	static function jmp(ctx:Context):Void->Void {
		var p = pos(ctx);
		write(ctx, Jump(0));
		return () -> ctx.ops[p] = Jump(pos(ctx) - p);
	}

	static function cjmp(cond:Bool, ctx:Context):Void->Void {
		var p = pos(ctx);
		write(ctx, Jump(0));
		return () -> ctx.ops[p] = (cond ? JumpIf(pos(ctx) - p) : JumpIfNot(pos(ctx) - p));
	}

	static function trap(ctx:Context):Void->Void {
		var p = pos(ctx);
		write(ctx, Trap(0));
		return () -> ctx.ops[p] = Trap(pos(ctx) - p);
	}

	static function goto(ctx:Context, p:Int):Void {
		write(ctx, Jump(p - pos(ctx)));
	}

	static function global(ctx:Context, g:Global):Int {
		var ginf = ctx.g;
		var key = globalKey(g);
		var found = ginf.globals.get(key);
		if (found != null) return found;
		var gid = ginf.gtable.length;
		ginf.globals.set(key, gid);
		ginf.gtable.push(g);
		return gid;
	}

	static function saveBreaks(ctx:Context):SavedBreaks {
		var oldc = ctx.continues;
		var oldb = ctx.breaks;
		var oldl = ctx.loopLimit;
		var oldt = ctx.loopTraps;
		ctx.loopTraps = ctx.traps.length;
		ctx.loopLimit = ctx.stack;
		ctx.breaks = [];
		ctx.continues = [];
		return {
			ctx: ctx,
			oldc: oldc,
			oldb: oldb,
			oldl: oldl,
			oldt: oldt
		};
	}

	static function processContinues(s:SavedBreaks):Void {
		var ctx = s.ctx;
		for (c in ctx.continues) c.f();
		ctx.continues = s.oldc;
	}

	static function processBreaks(s:SavedBreaks):Void {
		var ctx = s.ctx;
		for (b in ctx.breaks) b.f();
		ctx.loopLimit = s.oldl;
		ctx.loopTraps = s.oldt;
		ctx.breaks = s.oldb;
	}

	static function checkBreaks(ctx:Context):Void {
		for (b in ctx.breaks) error("Break outside a loop", b.p);
		for (c in ctx.continues) error("Continue outside a loop", c.p);
	}

	static function makeArray(p:Pos, el:Array<Expr>):Expr return new Expr(ECall(new Expr(EConst(Builtin("array")), p), el), p);

	// port: raises core.ds.Exit where upstream raises Exit.
	static function getCasesInts(cases:Array<{e1:Expr, e2:Expr}>):{ints:Array<{n:Int, e:Expr}>, size:Int} {
		var max = -1;
		var l = cases.map(c -> switch c.e1.decl {
			case EConst(Int(n)) if (n >= 0):
				if (n > max) max = n;
				{n: n, e: c.e2};
			case _:
				throw core.ds.Exit.raise();
		});
		/* // only create jump table if small or >10% cases matched */
		var nmatches = l.length;
		if (nmatches < 3) throw core.ds.Exit.raise();
		if (max >= 16 && Std.int((nmatches * 100) / (max + 1)) < 10) throw core.ds.Exit.raise();
		if (max > 512) throw core.ds.Exit.raise();
		return {ints: l, size: max + 1};
	}

	static function scanLabels(ctx:Context, supported:Bool, inBlock:Bool, e:Expr):Void {
		switch e.decl {
			case EFunction(args, e):
				var nargs = args.length;
				var traps = ctx.traps;
				ctx.traps = [];
				ctx.stack = ctx.stack + nargs;
				scanLabels(ctx, supported, false, e);
				ctx.stack = ctx.stack - nargs;
				ctx.traps = traps;
			case EBlock(_):
				var old = ctx.stack;
				Nast.iter(scanLabels.bind(ctx, supported, true), e);
				ctx.stack = old;
			case EVars(l):
				if (!inBlock) error("Variable declaration must be done inside a block", e.pos);
				for (v in l) {
					if (v.expr != null) scanLabels(ctx, supported, false, v.expr);
					ctx.stack = ctx.stack + 1;
				}
			case ELabel(l) if (!supported):
				error("Label is not supported in this part of the program", e.pos);
			case ELabel(l) if (ctx.g.labels.exists(l)):
				error("Duplicate label " + l, e.pos);
			case ELabel(l):
				var rtraps = ctx.traps.copy();
				rtraps.reverse();
				var label:Label = {
					lname: l,
					ltraps: rtraps,
					lstack: ctx.stack,
					lpos: null,
					lwait: [],
				};
				ctx.g.labels.set(l, label);
			case ETry(e, _, e2):
				ctx.stack = ctx.stack + Nbytecode.trapStackDelta;
				ctx.traps = [ctx.stack].concat(ctx.traps);
				scanLabels(ctx, supported, false, e);
				ctx.stack = ctx.stack - Nbytecode.trapStackDelta;
				ctx.traps = (ctx.traps.length == 0 ? assertFalse() : ctx.traps.slice(1));
				ctx.stack = ctx.stack + 1;
				scanLabels(ctx, supported, false, e2);
				ctx.stack = ctx.stack - 1;
			case EBinop("=", e1, e2):
				function isExtended(e:Expr):Bool {
					return switch e.decl {
						case EParenthesis(e): isExtended(e);
						case EArray(_) | EField(_):
							true;
						case _:
							false;
					}
				}
				var ext = isExtended(e1);
				if (ext) ctx.stack = ctx.stack + 1;
				scanLabels(ctx, supported, false, e2);
				ctx.stack = ctx.stack + 1;
				scanLabels(ctx, supported, false, e1);
				ctx.stack = ctx.stack - (ext ? 2 : 1);
			case ECall({decl: EConst(Builtin("array"))}, args) if (args.length > 0):
				var e = args[0], el = args.slice(1);
				if (ctx.version >= 2) {
					scanLabels(ctx, supported, false, e);
					for (e in el) {
						ctx.stack = ctx.stack + 1;
						scanLabels(ctx, supported, false, e);
					}
					ctx.stack = ctx.stack - el.length;
				} else {
					for (e in el) {
						scanLabels(ctx, supported, false, e);
						ctx.stack = ctx.stack + 1;
					}
					scanLabels(ctx, supported, false, e);
					ctx.stack = ctx.stack - el.length;
				}
			case ECall({decl: EConst(Builtin(x))}, el) if (x != "apply"):
				Nast.iter(scanLabels.bind(ctx, false, false), e);
			case ECall({decl: EConst(Builtin("apply"))}, args) if (args.length > 0):
				var e = args[0], el = args.slice(1);
				scanCall(ctx, supported, e, el);
			case ECall(e, el):
				scanCall(ctx, supported, e, el);
			case EObject(fl):
				ctx.stack = ctx.stack + 2;
				for (f in fl) scanLabels(ctx, supported, false, f.expr);
				ctx.stack = ctx.stack - 2;
			case ESwitch(ee, [{e1: econd, e2: exec}], eo):
				var p = e.pos;
				scanLabels(ctx, supported, false, new Expr(EIf(new Expr(EBinop("==", ee, econd), p), exec, eo), p));
			case ESwitch(e, cases, eo):
				scanLabels(ctx, supported, false, e);
				var delta = try {
					getCasesInts(cases);
					0;
				} catch (_:core.ds.Exit) 1;
				ctx.stack = ctx.stack + delta;
				for (c in cases) {
					ctx.stack = ctx.stack + delta;
					scanLabels(ctx, supported, false, c.e1);
					ctx.stack = ctx.stack - delta;
					scanLabels(ctx, supported, false, c.e2);
				}
				if (eo != null) scanLabels(ctx, supported, false, eo);
				ctx.stack = ctx.stack - delta;
			case ENext(e1, e2):
				scanLabels(ctx, supported, inBlock, e1);
				scanLabels(ctx, supported, inBlock, e2);
			case EConst(_) | EContinue | EBreak(_) | EReturn(_) | EIf(_) | EWhile(_) | EParenthesis(_):
				Nast.iter(scanLabels.bind(ctx, supported, false), e);
			case EBinop(_, _, _) | EArray(_) | EField(_):
				Nast.iter(scanLabels.bind(ctx, false, false), e);
			case ENeko(_):
				assertFalse();
		}
	}

	// port: the shared body of the `ECall (Builtin "apply", e :: el) | ECall (e,el)` or-pattern.
	static function scanCall(ctx:Context, supported:Bool, e:Expr, el:Array<Expr>):Void {
		for (e in el) {
			scanLabels(ctx, supported, false, e);
			ctx.stack = ctx.stack + 1;
		}
		scanLabels(ctx, supported, false, e);
		ctx.stack = ctx.stack - el.length;
	}

	static function compileConstant(ctx:Context, c:Constant, p:Pos):Void {
		switch c {
			case True:
				write(ctx, AccTrue);
			case False:
				write(ctx, AccFalse);
			case Null:
				write(ctx, AccNull);
			case This:
				write(ctx, AccThis);
			case Int(n):
				write(ctx, AccInt(n));
			case Int32(n):
				write(ctx, AccInt32(n));
			case Float(f):
				write(ctx, AccGlobal(global(ctx, GlobalFloat(f))));
			case String(s):
				write(ctx, AccGlobal(global(ctx, GlobalString(s))));
			case Builtin(s):
				switch s {
					case "tnull":
						write(ctx, AccInt(0));
					case "tint":
						write(ctx, AccInt(1));
					case "tfloat":
						write(ctx, AccInt(2));
					case "tbool":
						write(ctx, AccInt(3));
					case "tstring":
						write(ctx, AccInt(4));
					case "tobject":
						write(ctx, AccInt(5));
					case "tarray":
						write(ctx, AccInt(6));
					case "tfunction":
						write(ctx, AccInt(7));
					case "tabstract":
						write(ctx, AccInt(8));
					case s:
						write(ctx, AccBuiltin(s));
				}
			case Ident(s):
				var l = ctx.locals.get(s);
				if (l != null) {
					if (l <= ctx.limit) {
						var e = ctx.env.get(s);
						if (e == null) {
							e = ctx.nenv;
							ctx.nenv = ctx.nenv + 1;
							ctx.env = pmapAdd(s, e, ctx.env);
						}
						write(ctx, AccEnv(e));
					} else {
						var p = ctx.stack - l;
						write(ctx, (p == 0 ? AccStack0 : p == 1 ? AccStack1 : AccStack(p)));
					}
				} else {
					var g = global(ctx, GlobalVar(s));
					write(ctx, AccGlobal(g));
				}
		}
	}

	static function compileAccess(ctx:Context, e:Expr):Access {
		return switch e.decl {
			case EConst(Ident(s)):
				var l = ctx.locals.get(s);
				if (l != null) {
					if (l <= ctx.limit) {
						var e = ctx.env.get(s);
						if (e == null) {
							e = ctx.nenv;
							ctx.nenv = ctx.nenv + 1;
							ctx.env = pmapAdd(s, e, ctx.env);
						}
						XEnv(e);
					} else
						XStack(l);
				} else {
					var g = global(ctx, GlobalVar(s));
					XGlobal(g);
				}
			case EField(e, f):
				compile(ctx, false, e);
				write(ctx, Push);
				XField(f);
			case EArray(e1, {decl: EConst(Int(n))}):
				compile(ctx, false, e1);
				write(ctx, Push);
				XIndex(n);
			case EArray(ea, ei):
				compile(ctx, false, ei);
				write(ctx, Push);
				compile(ctx, false, ea);
				write(ctx, Push);
				XArray;
			case EConst(This):
				XThis;
			case _:
				error("Invalid access", e.pos);
		}
	}

	static function compileAccessSet(ctx:Context, a:Access):Void {
		switch a {
			case XEnv(n):
				write(ctx, SetEnv(n));
			case XStack(l):
				write(ctx, SetStack(ctx.stack - l));
			case XGlobal(g):
				write(ctx, SetGlobal(g));
			case XField(f):
				write(ctx, SetField(f));
			case XIndex(i):
				write(ctx, SetIndex(i));
			case XThis:
				write(ctx, SetThis);
			case XArray:
				write(ctx, SetArray);
		}
	}

	static function compileAccessGet(ctx:Context, a:Access):Void {
		switch a {
			case XEnv(n):
				write(ctx, AccEnv(n));
			case XStack(l):
				write(ctx, AccStack(ctx.stack - l));
			case XGlobal(g):
				write(ctx, AccGlobal(g));
			case XField(f):
				write(ctx, AccField(f));
			case XIndex(i):
				write(ctx, AccIndex(i));
			case XThis:
				write(ctx, AccThis);
			case XArray:
				write(ctx, Push);
				write(ctx, AccStack(2));
				write(ctx, AccArray);
		}
	}

	static function writeOp(ctx:Context, op:String, p:Pos):Void {
		switch op {
			case "+":
				write(ctx, Add);
			case "-":
				write(ctx, Sub);
			case "/":
				write(ctx, Div);
			case "*":
				write(ctx, Mult);
			case "%":
				write(ctx, Mod);
			case "<<":
				write(ctx, Shl);
			case ">>":
				write(ctx, Shr);
			case ">>>":
				write(ctx, UShr);
			case "|":
				write(ctx, Or);
			case "&":
				write(ctx, And);
			case "^":
				write(ctx, Xor);
			case "==":
				write(ctx, Eq);
			case "!=":
				write(ctx, Neq);
			case ">":
				write(ctx, Gt);
			case ">=":
				write(ctx, Gte);
			case "<":
				write(ctx, Lt);
			case "<=":
				write(ctx, Lte);
			case _:
				error("Unknown operation", p);
		}
	}

	static function compileBinop(ctx:Context, tail:Bool, op:String, e1:Expr, e2:Expr, p:Pos):Void {
		switch op {
			case "=":
				var a = compileAccess(ctx, e1);
				compile(ctx, false, e2);
				compileAccessSet(ctx, a);
			case "&&":
				compile(ctx, false, e1);
				var jnext = cjmp(false, ctx);
				compile(ctx, tail, e2);
				jnext();
			case "||":
				compile(ctx, false, e1);
				var jnext = cjmp(true, ctx);
				compile(ctx, tail, e2);
				jnext();
			case "++=" | "--=":
				write(ctx, Push);
				var base = ctx.stack;
				var a = compileAccess(ctx, e1);
				compileAccessGet(ctx, a);
				write(ctx, SetStack(ctx.stack - base));
				write(ctx, Push);
				compile(ctx, false, e2);
				writeOp(ctx, op.substr(0, op.length - 2), p);
				compileAccessSet(ctx, a);
				write(ctx, AccStack(0));
				write(ctx, Pop(1));
			case "+=" | "-=" | "/=" | "*=" | "%=" | "<<=" | ">>=" | ">>>=" | "|=" | "&=" | "^=":
				var a = compileAccess(ctx, e1);
				compileAccessGet(ctx, a);
				write(ctx, Push);
				compile(ctx, false, e2);
				writeOp(ctx, op.substr(0, op.length - 1), p);
				compileAccessSet(ctx, a);
			case _:
				switch [op, e1.decl, e2.decl] {
					case ["==", _, EConst(Null)]:
						compile(ctx, false, e1);
						write(ctx, IsNull);
					case ["!=", _, EConst(Null)]:
						compile(ctx, false, e1);
						write(ctx, IsNotNull);
					case ["==", EConst(Null), _]:
						compile(ctx, false, e2);
						write(ctx, IsNull);
					case ["!=", EConst(Null), _]:
						compile(ctx, false, e2);
						write(ctx, IsNotNull);
					case ["-", EConst(Int(0)), EConst(Int(i))]:
						compile(ctx, tail, new Expr(EConst(Int(-i)), p));
					case _:
						compile(ctx, false, e1);
						write(ctx, Push);
						compile(ctx, false, e2);
						writeOp(ctx, op, p);
				}
		}
	}

	static function compileFunction(main:Context, params:Array<String>, e:Expr):Void {
		var ctx:Context = {
			g: main.g,
			/* // reset */
			ops: [],
			pos: [],
			breaks: [],
			continues: [],
			env: new StringMap(),
			nenv: 0,
			traps: [],
			loopTraps: 0,
			limit: main.stack,
			/* // dup */
			version: main.version,
			stack: main.stack,
			locals: main.locals,
			loopLimit: main.loopLimit,
			curpos: main.curpos,
			curfile: main.curfile,
		};
		for (v in params) {
			ctx.stack = ctx.stack + 1;
			ctx.locals = pmapAdd(v, ctx.stack, ctx.locals);
		}
		var s = ctx.stack;
		compile(ctx, true, e);
		write(ctx, Ret(ctx.stack - ctx.limit));
		checkStack(ctx, s, e.pos);
		checkBreaks(ctx);
		/* // add let */
		var gid = ctx.g.gtable.length;
		ctx.g.functions.unshift({
			ops: ctx.ops,
			pos: ctx.pos,
			gid: gid,
			nargs: params.length
		});
		ctx.g.gtable.push(GlobalFunction(gid, -1));
		/* // environment */
		if (ctx.nenv > 0) {
			var a = new Vector(ctx.nenv, "");
			for (v => i in ctx.env) a[i] = v;
			for (v in a) {
				compileConstant(main, Ident(v), e.pos);
				write(main, Push);
			}
			write(main, AccGlobal(gid));
			write(main, MakeEnv(ctx.nenv));
		} else
			write(main, AccGlobal(gid));
	}

	static function compileBuiltin(ctx:Context, tail:Bool, b:String, el:Array<Expr>, p:Pos):Void {
		switch [b, el] {
			case ["istrue", [e]]:
				compile(ctx, false, e);
				write(ctx, Bool);
			case ["not", [e]]:
				compile(ctx, false, e);
				write(ctx, Not);
			case ["typeof", [e]]:
				compile(ctx, false, e);
				write(ctx, TypeOf);
			case ["hash", [e]]:
				compile(ctx, false, e);
				write(ctx, Hash);
			case ["new", [e]]:
				compile(ctx, false, e);
				write(ctx, New);
			case ["compare", [e1, e2]]:
				compile(ctx, false, e1);
				write(ctx, Push);
				compile(ctx, false, e2);
				write(ctx, Compare);
			case ["pcompare", [e1, e2]]:
				compile(ctx, false, e1);
				write(ctx, Push);
				compile(ctx, false, e2);
				write(ctx, PhysCompare);
			case ["goto", [{decl: EConst(Ident(l))}]]:
				var name = l;
				var l = ctx.g.labels.get(name);
				if (l == null) error("Unknown label " + name, p);
				var os = ctx.stack;
				var l1 = ctx.traps.copy();
				l1.reverse();
				var l2 = l.ltraps;
				var i = 0;
				while (i < l1.length && i < l2.length && l1[i] == l2[i]) i++;
				var straps = l1.slice(i), dtraps = l2.slice(i);
				straps.reverse();
				for (l in straps) {
					if (ctx.stack != l) write(ctx, Pop(ctx.stack - l));
					write(ctx, EndTrap);
				}
				var dtraps = dtraps.map(l -> {
					var l = l - Nbytecode.trapStackDelta;
					if (l < ctx.stack) write(ctx, Pop(ctx.stack - l));
					while (ctx.stack < l) {
						write(ctx, Push);
					}
					trap(ctx);
				});
				if (l.lstack < ctx.stack) write(ctx, Pop(ctx.stack - l.lstack));
				while (l.lstack > ctx.stack) {
					write(ctx, Push);
				}
				ctx.stack = os;
				if (l.lpos == null) l.lwait = [jmp(ctx)].concat(l.lwait) else write(ctx, Jump(l.lpos));
				for (t in dtraps) {
					t();
					write(ctx, Push);
					compileConstant(ctx, Builtin("raise"), p);
					write(ctx, Call(1));
					/* // insert an infinite loop in order to
						// comply with bytecode checker */
					var _jmp = jmp(ctx);
				}
			case ["goto", _]:
				error("Invalid $goto statement", p);
			case ["array", el0] if (el0.length > 0):
				var e = el0[0], el = el0.slice(1);
				var count = el.length;
				/* // a single let can't have >128 stack */
				if (count > 120 - ctx.stack && count > 8) {
					/* // split in 8 and recurse */
					var part = count >>> 3;
					function loop(el:Array<Expr>, i:Int, acc:Array<Expr>, count:Int):Array<Array<Expr>> {
						var out = [];
						while (true) {
							if (i >= el.length) {
								out.push(acc);
								return out;
							}
							var e = el[i];
							if (count == part) {
								out.push(acc);
								acc = [];
								count = 0;
							} else {
								acc.push(e);
								i++;
								count = count + 1;
							}
						}
					}
					var arr = makeArray(p, loop(el0, 0, [], 0).map(a -> makeArray(p, a)));
					compileBuiltin(ctx, tail, "aconcat", [arr], p);
				} else if (ctx.version >= 2) {
					compile(ctx, false, e);
					for (e in el) {
						write(ctx, Push);
						compile(ctx, false, e);
					}
					write(ctx, MakeArray(count));
				} else {
					for (e in el) {
						compile(ctx, false, e);
						write(ctx, Push);
					}
					compile(ctx, false, e);
					write(ctx, MakeArray(count));
				}
			case ["apply", el0] if (el0.length > 0):
				var e = el0[0], el = el0.slice(1);
				for (e in el) {
					compile(ctx, false, e);
					write(ctx, Push);
				}
				compile(ctx, false, e);
				var nargs = el.length;
				if (nargs > 0) write(ctx, Apply(nargs));
			case _:
				for (e in el) {
					compile(ctx, false, e);
					write(ctx, Push);
				}
				compileConstant(ctx, Builtin(b), p);
				if (tail) write(ctx, TailCall(el.length, ctx.stack - ctx.limit)) else write(ctx, Call(el.length));
		}
	}

	static function isBuiltinArray(e:Expr):Bool return switch e.decl {
		case EConst(Builtin("array")): true;
		case _: false;
	}

	static function compile(ctx:Context, tail:Bool, ep:Expr):Void {
		var p = ep.pos;
		setPos(ctx, p);
		switch ep.decl {
			case EConst(c):
				compileConstant(ctx, c, p);
			case EBlock([]):
				write(ctx, AccNull);
			case EBlock(el):
				var locals = ctx.locals;
				var stack = ctx.stack;
				var n = el.length;
				for (i in 0...n) {
					var e = el[i];
					if (i == n - 1) compile(ctx, tail, e) else if (i == n - 2 && el[n - 1].decl.match(ELabel(_))) compile(ctx, tail, e) else
						compile(ctx, false, e);
				}
				if (stack < ctx.stack) write(ctx, Pop(ctx.stack - stack));
				checkStack(ctx, stack, p);
				ctx.locals = locals;
			case EParenthesis(e):
				compile(ctx, tail, e);
			case EField(e, f):
				compile(ctx, false, e);
				write(ctx, AccField(f));
			case ECall(e, args) if (args.length >= 6 && !isBuiltinArray(e)):
				var call = new Expr(EConst(Builtin("call")), p);
				var args = new Expr(ECall(new Expr(EConst(Builtin("array")), p), args), p);
				switch e.decl {
					case EField(e2, name):
						var p2 = e.pos;
						var locals = ctx.locals;
						var etmp = new Expr(EConst(Ident("$tmp")), p2);
						compile(ctx, false, new Expr(EVars([{name: "$tmp", expr: e2}]), p2));
						compile(ctx, tail, new Expr(ECall(call, [new Expr(EField(etmp, name), p2), etmp, args]), p));
						write(ctx, Pop(1));
						ctx.locals = locals;
					case _:
						compile(ctx, tail, new Expr(ECall(call, [e, new Expr(EConst(This), p), args]), p));
				}
			case ECall({decl: EConst(Builtin(b))}, el):
				compileBuiltin(ctx, tail, b, el, p);
			case ECall({decl: EField(e, f)}, el):
				for (e in el) {
					compile(ctx, false, e);
					write(ctx, Push);
				}
				compile(ctx, false, e);
				write(ctx, Push);
				write(ctx, AccField(f));
				write(ctx, ObjCall(el.length));
			case ECall(e, el):
				for (e in el) {
					compile(ctx, false, e);
					write(ctx, Push);
				}
				compile(ctx, false, e);
				if (tail) write(ctx, TailCall(el.length, ctx.stack - ctx.limit)) else write(ctx, Call(el.length));
			case EArray(e1, {decl: EConst(Int(n))}):
				compile(ctx, false, e1);
				write(ctx, (n == 0 ? AccIndex0 : n == 1 ? AccIndex1 : AccIndex(n)));
			case EArray(e1, e2):
				compile(ctx, false, e1);
				write(ctx, Push);
				compile(ctx, false, e2);
				write(ctx, AccArray);
			case EVars(vl):
				for (v in vl) {
					if (v.expr == null) write(ctx, AccNull) else compile(ctx, false, v.expr);
					write(ctx, Push);
					ctx.locals = pmapAdd(v.name, ctx.stack, ctx.locals);
				}
			case EWhile(econd, e, NormalWhile):
				var start = pos(ctx);
				if (ctx.version >= 2) write(ctx, Loop);
				compile(ctx, false, econd);
				var jend = cjmp(false, ctx);
				var save = saveBreaks(ctx);
				compile(ctx, false, e);
				processContinues(save);
				goto(ctx, start);
				processBreaks(save);
				jend();
			case EWhile(econd, e, DoWhile):
				var start = pos(ctx);
				if (ctx.version >= 2) write(ctx, Loop);
				var save = saveBreaks(ctx);
				compile(ctx, false, e);
				processContinues(save);
				compile(ctx, false, econd);
				write(ctx, JumpIf(start - pos(ctx)));
				processBreaks(save);
			case EIf(e, e1, e2):
				var stack = ctx.stack;
				compile(ctx, false, e);
				var jelse = cjmp(false, ctx);
				compile(ctx, tail, e1);
				checkStack(ctx, stack, p);
				if (e2 == null) {
					jelse();
				} else {
					var jend = jmp(ctx);
					jelse();
					compile(ctx, tail, e2);
					checkStack(ctx, stack, p);
					jend();
				}
			case ETry(e, v, ecatch):
				var trap = trap(ctx);
				ctx.traps = [ctx.stack].concat(ctx.traps);
				compile(ctx, false, e);
				write(ctx, EndTrap);
				ctx.traps = (ctx.traps.length == 0 ? assertFalse() : ctx.traps.slice(1));
				var jend = jmp(ctx);
				trap();
				write(ctx, Push);
				var locals = ctx.locals;
				ctx.locals = pmapAdd(v, ctx.stack, ctx.locals);
				compile(ctx, tail, ecatch);
				write(ctx, Pop(1));
				ctx.locals = locals;
				jend();
			case EBinop(op, e1, e2):
				compileBinop(ctx, tail, op, e1, e2, p);
			case EReturn(e):
				if (e == null) write(ctx, AccNull) else compile(ctx, ctx.traps.length == 0, e);
				var stack = ctx.stack;
				for (t in ctx.traps) {
					if (ctx.stack > t) write(ctx, Pop(ctx.stack - t));
					write(ctx, EndTrap);
				}
				write(ctx, Ret(ctx.stack - ctx.limit));
				ctx.stack = stack;
			case EBreak(e):
				if (e != null) compile(ctx, false, e);
				var s = ctx.stack;
				var n = ctx.traps.length - ctx.loopTraps;
				for (t in ctx.traps) {
					if (n > 0) {
						n--;
						if (ctx.stack > t) write(ctx, Pop(ctx.stack - t));
						write(ctx, EndTrap);
					}
				}
				if (ctx.loopLimit != ctx.stack) write(ctx, Pop(ctx.stack - ctx.loopLimit));
				ctx.stack = s;
				ctx.breaks = [{f: jmp(ctx), p: p}].concat(ctx.breaks);
			case EContinue:
				var s = ctx.stack;
				var n = ctx.traps.length - ctx.loopTraps;
				for (t in ctx.traps) {
					if (n > 0) {
						n--;
						if (ctx.stack > t) write(ctx, Pop(ctx.stack - t));
						write(ctx, EndTrap);
					}
				}
				if (ctx.loopLimit != ctx.stack) write(ctx, Pop(ctx.stack - ctx.loopLimit));
				ctx.stack = s;
				ctx.continues = [{f: jmp(ctx), p: p}].concat(ctx.continues);
			case EFunction(params, e):
				compileFunction(ctx, params, e);
			case ENext(e1, e2):
				compile(ctx, false, e1);
				compile(ctx, tail, e2);
			case EObject([]):
				write(ctx, AccNull);
				write(ctx, New);
			case EObject(fl):
				var fields = fl.map(f -> f.name);
				fields.sort(core.ds.Key.compareStrings);
				// port: the string list key; field names never contain NUL.
				var key = fields.join("\x00");
				var found = ctx.g.gobjects.get(key);
				var id = if (found != null) found.id else {
					var id = global(ctx, GlobalVar("o:" + Std.string(ctx.g.gobjectsCount)));
					ctx.g.gobjects.set(key, {fields: fields, id: id});
					ctx.g.gobjectsCount++;
					id;
				}
				write(ctx, AccGlobal(id));
				write(ctx, New);
				write(ctx, Push);
				for (f in fl) {
					write(ctx, Push);
					compile(ctx, false, f.expr);
					write(ctx, SetField(f.name));
					write(ctx, AccStack0);
				}
				write(ctx, Pop(1));
			case ELabel(l):
				var l = ctx.g.labels.get(l);
				if (l == null) assertFalse();
				var rtraps = ctx.traps.copy();
				rtraps.reverse();
				if (ctx.stack != l.lstack || !intListEq(rtraps, l.ltraps)) error('Label failure ${ctx.stack} ${l.lstack}', p);
				for (f in l.lwait) f();
				l.lwait = [];
				l.lpos = pos(ctx);
			case ESwitch(e, [{e1: econd, e2: exec}], eo):
				compile(ctx, tail, new Expr(EIf(new Expr(EBinop("==", e, econd), p), exec, eo), p));
			case ENeko(_):
				assertFalse();
			case ESwitch(e, cases, eo):
				var ci = try getCasesInts(cases) catch (_:core.ds.Exit) null;
				if (ci != null) {
					var ints = ci.ints, size = ci.size;
					compile(ctx, false, e);
					write(ctx, JumpTable(size));
					var tbl = new Vector<Null<Expr>>(size);
					for (ie in ints) {
						tbl[ie.n] = ie.e;
					}
					var tbl = tbl.map(e -> {j: jmp(ctx), e: e});
					for (je in tbl) {
						if (je.e == null) je.j();
					}
					if (eo == null) write(ctx, AccNull) else compile(ctx, tail, eo);
					var jumpEnd = jmp(ctx);
					var tbl = tbl.map(je -> {
						if (je.e != null) {
							je.j();
							compile(ctx, tail, je.e);
							jmp(ctx);
						} else
							() -> {};
					});
					jumpEnd();
					for (j in tbl) j();
				} else {
					compile(ctx, false, e);
					write(ctx, Push);
					var jumps = cases.map(c -> {
						write(ctx, AccStack0);
						write(ctx, Push);
						compile(ctx, false, c.e1);
						write(ctx, Eq);
						{j: cjmp(true, ctx), e: c.e2};
					});
					if (eo == null) write(ctx, AccNull) else compile(ctx, tail, new Expr(EBlock([eo]), p));
					var jumpEnd = jmp(ctx);
					var jumps = jumps.map(je -> {
						je.j();
						compile(ctx, tail, new Expr(EBlock([je.e]), p));
						jmp(ctx);
					});
					jumpEnd();
					for (j in jumps) j();
					write(ctx, Pop(1));
				}
		}
	}

	static function intListEq(a:Array<Int>, b:Array<Int>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (a[i] != b[i]) return false;
		return true;
	}

	// port: upstream's toplevel `compile`, which shadows the recursive one above.
	public static function compileAst(version:Int, ast:Expr):{globals:Vector<Global>, ops:Vector<Opcode>} {
		var g:Globals = {
			globals: new StringMap(),
			gobjects: new StringMap(),
			gobjectsCount: 0,
			gtable: [],
			functions: [],
			labels: new StringMap(),
			hfiles: new StringMap(),
			files: [],
		};
		var ctx:Context = {
			g: g,
			version: version,
			stack: 0,
			loopLimit: 0,
			loopTraps: 0,
			limit: -1,
			locals: new StringMap(),
			ops: [],
			breaks: [],
			continues: [],
			env: new StringMap(),
			nenv: 0,
			traps: [],
			pos: [],
			curpos: new DebugPos(0, 0),
			curfile: "_",
		};
		if (version >= 2) g.gtable.push(GlobalVersion(version));
		scanLabels(ctx, true, true, ast);
		compile(ctx, false, ast);
		checkBreaks(ctx);
		if (g.functions.length != 0 || g.gobjectsCount != 0) {
			var ctxops = ctx.ops;
			var ctxpos = ctx.pos;
			var ops = [];
			var pos = [];
			ctx.pos = pos;
			ctx.ops = ops;
			write(ctx, Jump(0));
			var functions = g.functions.copy();
			functions.reverse();
			for (f in functions) {
				g.gtable[f.gid] = GlobalFunction(ops.length, f.nargs);
				for (o in f.ops) ops.push(o);
				for (p in f.pos) pos.push(p);
			}
			ops[0] = Jump(ops.length);
			var objects = [for (o in g.gobjects) o];
			objects.sort((a, b) -> a.id - b.id);
			for (o in objects) {
				var fl = o.fields, g = o.id;
				write(ctx, AccNull);
				write(ctx, New);
				write(ctx, SetGlobal(g));
				for (f in fl) {
					write(ctx, AccGlobal(g));
					write(ctx, Push);
					write(ctx, SetField(f));
				}
			}
			for (p in ctxpos) pos.push(p);
			for (o in ctxops) ops.push(o);
		}
		g.gtable.push(GlobalDebug(Vector.fromArrayCopy(ctx.g.files), Vector.fromArrayCopy(ctx.pos)));
		return {globals: Vector.fromArrayCopy(g.gtable), ops: Vector.fromArrayCopy(ctx.ops)};
	}
}
