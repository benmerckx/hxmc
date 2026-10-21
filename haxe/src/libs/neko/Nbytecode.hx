/*
 *  Neko Compiler
 *  Copyright (c)2005 Motion-Twin
 *
 *  This library is free software; you can redistribute it and/lor
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, lor (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY lor FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License lor the LICENSE file for more details.
 */

package libs.neko;

import haxe.ds.Vector;
import libs.neko.IO;

// port: haxe/libs/neko/nbytecode.ml

/*
 *  Neko Compiler
 *  Copyright (c)2005 Motion-Twin
 *
 *  This library is free software; you can redistribute it and/lor
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, lor (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY lor FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License lor the LICENSE file for more details.
 */
enum Opcode {
	/* getters */
	AccNull;
	AccTrue;
	AccFalse;
	AccThis;
	AccInt(n:Int);
	AccStack(n:Int);
	AccGlobal(n:Int);
	AccEnv(n:Int);
	AccField(s:String);
	AccArray;
	AccIndex(n:Int);
	AccBuiltin(s:String);
	/* setters */
	SetStack(n:Int);
	SetGlobal(n:Int);
	SetEnv(n:Int);
	SetField(s:String);
	SetArray;
	SetIndex(n:Int);
	SetThis;
	/* stack ops */
	Push;
	Pop(n:Int);
	Call(n:Int);
	ObjCall(n:Int);
	Jump(n:Int);
	JumpIf(n:Int);
	JumpIfNot(n:Int);
	Trap(n:Int);
	EndTrap;
	Ret(n:Int);
	MakeEnv(n:Int);
	MakeArray(n:Int);
	/* value ops */
	Bool;
	IsNull;
	IsNotNull;
	Add;
	Sub;
	Mult;
	Div;
	Mod;
	Shl;
	Shr;
	UShr;
	Or;
	And;
	Xor;
	Eq;
	Neq;
	Gt;
	Gte;
	Lt;
	Lte;
	Not;
	/* extra ops */
	TypeOf;
	Compare;
	Hash;
	New;
	JumpTable(n:Int);
	Apply(n:Int);
	AccStack0;
	AccStack1;
	AccIndex0;
	AccIndex1;
	PhysCompare;
	TailCall(args:Int, st:Int);
	Loop;
	/* ocaml-specific */
	AccInt32(n:Int);
}

// port: the `(int * int)` debug position: file index and line.
@:structInit final class DebugPos {
	public final file:Int;
	public final line:Int;

	public inline function new(file:Int, line:Int) {
		this.file = file;
		this.line = line;
	}
}

enum Global {
	GlobalVar(s:String);
	GlobalFunction(p:Int, nargs:Int);
	GlobalString(s:String);
	GlobalFloat(s:String);
	GlobalDebug(files:Vector<String>, inf:Vector<DebugPos>);
	GlobalVersion(v:Int);
}

class InvalidFile extends haxe.Exception {
	public function new() super("Nbytecode.Invalid_file");
}

class Nbytecode {
	public static function error(msg:String):Dynamic throw new core.ds.Failure(msg);

	public static inline var trapStackDelta = 6;

	// port: OCaml's 63-bit `h * 223 + c` keeps the same low 32 bits as 32-bit wrapping
	// arithmetic; the 64-bit result is the low 31 bits sign-extended.
	public static function hashField(f:String):Int {
		var h = 0;
		for (i in 0...f.length) {
			h = mul32(h, 223) + StringTools.fastCodeAt(f, i);
			h = h | 0;
		}
		return (h << 1) >> 1;
	}

	static inline function mul32(a:Int, b:Int):Int return ((a & 0xFFFF) * b + ((((a >>> 16) * b) & 0xFFFF) << 16)) | 0;

	public static function opParam(x:Opcode):Bool {
		return switch x {
			case AccInt(_) | AccInt32(_) | AccStack(_) | AccGlobal(_) | AccEnv(_) | AccField(_) | AccBuiltin(_) | SetStack(_) | SetGlobal(_) | SetEnv(_) |
				SetField(_) | Pop(_) | Call(_) | ObjCall(_) | Jump(_) | JumpIf(_) | JumpIfNot(_) | JumpTable(_) | Trap(_) | MakeEnv(_) | MakeArray(_) | Ret(_) |
				AccIndex(_) | SetIndex(_) | Apply(_) | TailCall(_):
				true;
			case AccNull | AccTrue | AccFalse | AccThis | AccArray | SetArray | SetThis | Push | EndTrap | Bool | Add | Sub | Mult | Div | Mod | Shl | Shr |
				UShr | Or | And | Xor | Eq | Neq | Gt | Gte | Lt | Lte | IsNull | IsNotNull | Not | TypeOf | Compare | Hash | New | AccStack0 | AccStack1 |
				AccIndex0 | AccIndex1 | PhysCompare | Loop:
				false;
		}
	}

	static function codeTables(ops:Vector<Opcode>):{ids:Array<String>, pos:Vector<Int>, size:Int} {
		// port: (int,string) Hashtbl.t, only looked up.
		var ids = new haxe.ds.IntMap<String>();
		var fids = [];
		for (x in ops) {
			switch x {
				case AccField(s) | SetField(s) | AccBuiltin(s):
					var id = hashField(s);
					var f = ids.get(id);
					if (f != null) {
						if (f != s) error("Field hashing conflict " + s + " and " + f);
					} else {
						ids.set(id, s);
						fids.push(s);
					}
				case _:
			}
		}
		var p = 0;
		var pos = new Vector(ops.length + 1, 0);
		for (i in 0...ops.length) {
			pos[i] = p;
			p = p + (opParam(ops[i]) ? 2 : 1);
		}
		pos[ops.length] = p;
		return {ids: fids, pos: pos, size: p};
	}

	static function writeDebugInfos(ch:haxe.io.Output, files:Vector<String>, inf:Vector<DebugPos>):Void {
		var nfiles = files.length;
		/*
			// the encoding of nfiles was set to keep
			// backward compatibility with 1.3 which
			// only allowed up to 127 filenames
		 */
		var lotOfFiles = false;
		if (nfiles < 0x80) IO.writeByte(ch, nfiles) else if (nfiles < 0x8000) {
			lotOfFiles = true;
			IO.writeByte(ch, (nfiles >>> 8) | 0x80);
			IO.writeByte(ch, nfiles & 0xFF);
		} else
			throw new core.ds.Failure("Assert_failure nbytecode.ml");
		for (s in files) IO.writeString(ch, s);
		IO.writeI32(ch, inf.length);
		var curfile = 0;
		var curpos = 0;
		var rcount = 0;
		function flushRepeat(p:Int):Void {
			if (rcount > 0) {
				if (rcount > 15) {
					IO.writeByte(ch, (15 << 2) | 2);
					rcount = rcount - 15;
					flushRepeat(p);
				} else {
					var delta = p - curpos;
					var delta = (delta > 0 && delta < 4 ? delta : 0);
					IO.writeByte(ch, (delta << 6) | (rcount << 2) | 2);
					rcount = 0;
					curpos = curpos + delta;
				}
			}
		}
		for (fp in inf) {
			var f = fp.file, p = fp.line;
			if (f != curfile) {
				flushRepeat(p);
				curfile = f;
				if (lotOfFiles) {
					IO.writeByte(ch, (f >>> 7) | 1);
					IO.writeByte(ch, f & 0xFF);
				} else
					IO.writeByte(ch, (f << 1) | 1);
			}
			if (p != curpos) flushRepeat(p);
			if (p == curpos) rcount = rcount + 1 else {
				var delta = p - curpos;
				if (delta > 0 && delta < 32) IO.writeByte(ch, (delta << 3) | 4) else {
					IO.writeByte(ch, p << 3);
					IO.writeByte(ch, p >>> 5);
					IO.writeByte(ch, p >>> 13);
				}
				curpos = p;
			}
		}
		flushRepeat(curpos);
	}

	public static function write(ch:haxe.io.Output, code:{globals:Vector<Global>, ops:Vector<Opcode>}):Void {
		var globals = code.globals, ops = code.ops;
		IO.nwriteString(ch, "NEKO");
		var t = codeTables(ops);
		var ids = t.ids, pos = t.pos, csize = t.size;
		IO.writeI32(ch, globals.length);
		IO.writeI32(ch, ids.length);
		IO.writeI32(ch, csize);
		for (x in globals) {
			switch x {
				case GlobalVar(s):
					IO.writeByte(ch, 1);
					IO.writeString(ch, s);
				case GlobalFunction(p, nargs):
					IO.writeByte(ch, 2);
					IO.writeI32(ch, pos[p] | (nargs << 24));
				case GlobalString(s):
					IO.writeByte(ch, 3);
					IO.writeUi16(ch, s.length);
					IO.nwriteString(ch, s);
				case GlobalFloat(s):
					IO.writeByte(ch, 4);
					IO.writeString(ch, s);
				case GlobalDebug(files, inf):
					IO.writeByte(ch, 5);
					writeDebugInfos(ch, files, inf);
				case GlobalVersion(v):
					IO.writeByte(ch, 6);
					IO.writeByte(ch, v);
			}
		}
		for (s in ids) IO.writeString(ch, s);
		for (i in 0...ops.length) {
			var op = ops[i];
			var pop:Null<Int> = null;
			var opid = switch op {
				case AccNull: 0;
				case AccTrue: 1;
				case AccFalse: 2;
				case AccThis: 3;
				case AccInt(n):
					pop = n;
					4;
				case AccInt32(n):
					var opid = 4;
					IO.writeByte(ch, (opid << 2) | 3);
					IO.writeRealI32(ch, n);
					-1;
				case AccStack(n):
					pop = n - 2;
					5;
				case AccGlobal(n):
					pop = n;
					6;
				case AccEnv(n):
					pop = n;
					7;
				case AccField(s):
					pop = hashField(s);
					8;
				case AccArray: 9;
				case AccIndex(n):
					pop = n - 2;
					10;
				case AccBuiltin(s):
					pop = hashField(s);
					11;
				case SetStack(n):
					pop = n;
					12;
				case SetGlobal(n):
					pop = n;
					13;
				case SetEnv(n):
					pop = n;
					14;
				case SetField(s):
					pop = hashField(s);
					15;
				case SetArray: 16;
				case SetIndex(n):
					pop = n;
					17;
				case SetThis: 18;
				case Push: 19;
				case Pop(n):
					pop = n;
					20;
				case Call(n):
					pop = n;
					21;
				case ObjCall(n):
					pop = n;
					22;
				case Jump(n):
					pop = pos[i + n] - pos[i];
					23;
				case JumpIf(n):
					pop = pos[i + n] - pos[i];
					24;
				case JumpIfNot(n):
					pop = pos[i + n] - pos[i];
					25;
				case Trap(n):
					pop = pos[i + n] - pos[i];
					26;
				case EndTrap: 27;
				case Ret(n):
					pop = n;
					28;
				case MakeEnv(n):
					pop = n;
					29;
				case MakeArray(n):
					pop = n;
					30;
				case Bool: 31;
				case IsNull: 32;
				case IsNotNull: 33;
				case Add: 34;
				case Sub: 35;
				case Mult: 36;
				case Div: 37;
				case Mod: 38;
				case Shl: 39;
				case Shr: 40;
				case UShr: 41;
				case Or: 42;
				case And: 43;
				case Xor: 44;
				case Eq: 45;
				case Neq: 46;
				case Gt: 47;
				case Gte: 48;
				case Lt: 49;
				case Lte: 50;
				case Not: 51;
				case TypeOf: 52;
				case Compare: 53;
				case Hash: 54;
				case New: 55;
				case JumpTable(n):
					pop = n;
					56;
				case Apply(n):
					pop = n;
					57;
				case AccStack0: 58;
				case AccStack1: 59;
				case AccIndex0: 60;
				case AccIndex1: 61;
				case PhysCompare: 62;
				case TailCall(args, st):
					pop = args | (st << 3);
					63;
				case Loop:
					pop = 64;
					0;
			}
			if (pop == null) {
				if (opid >= 0) IO.writeByte(ch, opid << 2);
			} else {
				var n:Int = pop;
				if (opid < 32 && (n == 0 || n == 1)) IO.writeByte(ch, (opid << 3) | (n << 2) | 1) else if (n >= 0 && n <= 0xFF) {
					IO.writeByte(ch, (opid << 2) | 2);
					IO.writeByte(ch, n);
				} else {
					IO.writeByte(ch, (opid << 2) | 3);
					IO.writeI32(ch, n);
				}
			}
		}
	}
}
