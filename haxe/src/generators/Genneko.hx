/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

package generators;

import core.OcamlFilename;

import haxe.io.Bytes;
import haxe.ds.Vector;
import core.Globals;
import core.Globals.*;
import core.Globals.Pos;
import core.Ast.Binop;
import core.Ast.Unop;
import core.Ast.UnopFlag;
import core.TType;
import core.TFunctions;
import core.TFunctions.*;
import core.TOther.TClassTools;
import core.Define;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import libs.neko.Nast.Nast;
import libs.neko.Nast.Constant;
import libs.neko.Nast.ExprDecl;
import libs.neko.Nast.WhileFlag;
import libs.neko.Binast.Binast;
import libs.neko.Nbytecode.Nbytecode;
import libs.neko.Ncompile.Ncompile;
import libs.neko.Ncompile.Error as NcompileError;
import libs.neko.Nast.Pos as NPos;
import libs.neko.Nast.Expr as NExpr;

using core.ds.VectorTools;

/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA
 */
@:structInit private class Context {
	public final version:Int;
	public final com:Gctx;
	// port: (string list, unit) Hashtbl.t and (path, string) Hashtbl.t, only looked up:
	// keyed by the joined path.
	public final packages:haxe.ds.StringMap<Bool>;
	public final globals:haxe.ds.StringMap<String>;
	public var curglobal:Int;
	public var macros:Bool;
	public var curclass:String;
	public var curmethod:String;
	// port: a list with the newest init first, as upstream.
	public var inits:Array<{c:TClass, e:TExpr}>;
	public var labelCount:Int;
}

class Genneko {
	// port: (string, string) Hashtbl.t, only looked up.
	static final files = new haxe.ds.StringMap<String>();

	// port: the Neko AST holds byte strings (see libs.neko.Nast): `bs` encodes a Haxe string
	// to UTF-8 and returns it with one character per byte. Every string coming from the
	// typed AST or the file system goes through it exactly once, in the node helpers below.
	static function bs(s:String):String {
		for (i in 0...s.length) if (StringTools.fastCodeAt(s, i) >= 0x80) return bytesStr(Bytes.ofString(s));
		return s;
	}

	static function bytesStr(b:Bytes):String {
		var sb = new StringBuf();
		for (i in 0...b.length) sb.addChar(b.get(i));
		return sb.toString();
	}

	// port: the inverse of `bs`, for strings that leave the Neko AST (error positions).
	static function unbs(s:String):String {
		var b = Bytes.alloc(s.length);
		for (i in 0...s.length) b.set(i, StringTools.fastCodeAt(s, i));
		return b.toString();
	}

	static function pos(ctx:Context, p:Pos):NPos {
		if (ctx.macros) return {
			psource: bs(p.pfile),
			pline: p.pmin | ((p.pmax - p.pmin) << 20),
		};
		var file = (switch ctx.com.debug {
			case true:
				ctx.curclass + "::" + ctx.curmethod;
			case false:
				var found = files.get(p.pfile);
				if (found != null) found else {
					var path = (switch Gctx.defined(ctx.com, Define.AbsolutePath) {
						case true:
							if (OcamlFilename.isRelative(p.pfile)) OcamlFilename.concat(OcamlFilename.sysGetcwd(), p.pfile) else p.pfile;
						case false:
							try {
								/* lookup relative path */
								var len = p.pfile.length;
								var base = ctx.com.classPaths.find(path -> {
									var path = path.path;
									var l = path.length;
									len > l && p.pfile.substr(0, l) == path;
								});
								var l = base.path.length;
								p.pfile.substr(l, len - l);
							} catch (_:Dynamic) p.pfile;
					});
					files.set(p.pfile, path);
					path;
				}
		});
		return {
			psource: bs(file),
			pline: syntax.Lexer.getErrorLine(p),
		};
	}

	static function pathKey(path:GlobalTypePath):String return path.pack.join(".") + "\x00" + path.name;

	static function genGlobalName(ctx:Context, path:GlobalTypePath):String {
		if (path.pack.length == 0) return path.name;
		var found = ctx.globals.get(pathKey(path));
		if (found != null) return found;
		var name = "@G" + Std.string(ctx.curglobal);
		ctx.curglobal = ctx.curglobal + 1;
		ctx.globals.set(pathKey(path), name);
		return name;
	}

	static inline function null_(p:NPos):NExpr return new NExpr(EConst(Null), p);

	static inline function this_(p:NPos):NExpr return new NExpr(EConst(This), p);

	static inline function int(p:NPos, n:Int):NExpr return new NExpr(EConst(Int(n)), p);

	static function str(p:NPos, s:String):NExpr return new NExpr(EConst(String(bs(s))), p);

	static function ident(p:NPos, s:String):NExpr {
		var l = s.length;
		return if (l > 10 && s.substr(0, 10) == "__dollar__") new NExpr(EConst(Builtin(bs(s.substr(10, l - 10)))), p) else new NExpr(EConst(Ident(bs(s))),
			p);
	}

	static function field(p:NPos, e:NExpr, f:String):NExpr return new NExpr(EField(e, bs(f)), p);

	static function builtin(p:NPos, n:String):NExpr return new NExpr(EConst(Builtin(bs(n))), p);

	static inline function call(p:NPos, e:NExpr, el:Array<NExpr>):NExpr return new NExpr(ECall(e, el), p);

	static function array(p:NPos, el:Array<NExpr>):NExpr return call(p, builtin(p, "array"), el);

	// port: `pmap_list f p`: PMap.fold in key order, consing, so the largest key comes first.
	static function pmapList<V>(f:V->NExpr, p:haxe.ds.StringMap<V>):Array<NExpr> {
		var acc = core.ds.PMap.fold((v, acc:Array<NExpr>) -> {
			acc.push(f(v));
			acc;
		}, p, []);
		acc.reverse();
		return acc;
	}

	static function needsReturn(e:NExpr):Bool {
		return switch e.decl {
			case EBlock(l):
				function loop(l:Array<NExpr>, i:Int):Bool {
					return if (i >= l.length) true else if (i == l.length - 1) needsReturn(l[i]) else loop(l, i + 1);
				}
				loop(l, 0);
			case EReturn(_):
				false;
			case _:
				true;
		}
	}

	static function withReturn(e:NExpr):NExpr {
		if (needsReturn(e)) {
			var p = e.pos;
			var ret = new NExpr(EReturn(null_(p)), p);
			return switch e.decl {
				case EBlock(l):
					new NExpr(EBlock(l.concat([ret])), p);
				case _:
					new NExpr(EBlock([e, ret]), p);
			}
		} else
			return e;
	}

	static function genTypePath(p:NPos, path:GlobalTypePath):NExpr {
		var t = path.name;
		return switch path.pack {
			case []:
				ident(p, t);
			case pack:
				var epath = ident(p, pack[0]);
				for (i in 1...pack.length) epath = field(p, epath, pack[i]);
				field(p, epath, t);
		}
	}

	// port: the split works on the UTF-8 bytes of `s` (`String.length` and `String.sub` are
	// byte-wise upstream); `genBigStringBytes` takes the byte string and builds the
	// constants without re-encoding them.
	static function genBigString(ctx:Context, p:NPos, s:String):NExpr return genBigStringBytes(ctx, p, bs(s));

	static function genBigStringBytes(ctx:Context, p:NPos, s:String):NExpr {
		var max = (1 << 16) - 1;
		return if (s.length > max) new NExpr(EBinop("+", new NExpr(EConst(String(s.substr(0, max))), p),
			genBigStringBytes(ctx, p, s.substr(max, s.length - max))), p) else new NExpr(EConst(String(s)), p);
	}

	static function genConstant(ctx:Context, pe:Pos, c:TConstant):NExpr {
		var p = pos(ctx, pe);
		return switch c {
			case TInt(i):
				var h = i >>> 24;
				if ((h & 128 == 0) != (h & 64 == 0)) {
					if (ctx.version < 2) core.Error.abort("This integer is too big to be compiled to a Neko 31-bit integer. Please use a Float instead", pe);
					new NExpr(EConst(Int32(i)), p);
				} else
					int(p, i);
			case TFloat(f):
				new NExpr(EConst(Float(bs(core.Texpr.replaceSeparators(f, "")))), p);
			case TString(s):
				call(p, field(p, ident(p, "String"), "new"), [genBigString(ctx, p, s)]);
			case TBool(b):
				new NExpr(EConst(if (b) True else False), p);
			case TNull:
				null_(p);
			case TThis:
				this_(p);
			case TSuper:
				Globals.die("", "genneko.ml");
		}
	}

	static function genBinop(ctx:Context, p:NPos, op:Binop, e1:TExpr, e2:TExpr):NExpr {
		return new NExpr(EBinop(core.Ast.sBinop(op), genExpr(ctx, e1), genExpr(ctx, e2)), p);
	}

	static function genUnop(ctx:Context, p:NPos, op:Unop, flag:UnopFlag, e:TExpr):NExpr {
		return switch op {
			case Increment: new NExpr(EBinop((if (flag == Prefix) "+=" else "++="), genExpr(ctx, e), int(p, 1)), p);
			case Decrement: new NExpr(EBinop((if (flag == Prefix) "-=" else "--="), genExpr(ctx, e), int(p, 1)), p);
			case Not: call(p, builtin(p, "not"), [genExpr(ctx, e)]);
			case Neg: new NExpr(EBinop("-", int(p, 0), genExpr(ctx, e)), p);
			case NegBits: new NExpr(EBinop("-", int(p, -1), genExpr(ctx, e)), p);
			case Spread: Globals.die("Unhandled spread operator", "genneko.ml", e.epos);
		}
	}

	static function genCall(ctx:Context, p:NPos, e:TExpr, el:Vector<TExpr>):NExpr {
		switch [e.eexpr, el] {
			case [TConst(TSuper), _]:
				var c = (switch follow(e.etype) {
					case TInst(c, _): c;
					case _: Globals.die("", "genneko.ml");
				});
				return call(p, builtin(p, "call"), [
					field(p, genTypePath(p, c.clPath), "__construct__"),
					this_(p),
					array(p, el.mapToArray(genExpr.bind(ctx)))
				]);
			case [TIdent("__resources__"), []]:
				return call(p, builtin(p, "array"), ctx.com.resources.fold((name, data, acc:Array<NExpr>) -> {
					[
						new NExpr(EObject([
							{name: "name", expr: genConstant(ctx, e.epos, TString(name))},
							{name: "data", expr: genBigStringBytes(ctx, p, bytesStr(data))}
						]), p)
					].concat(acc);
				}, []));
			case [TField({eexpr: TConst(TSuper), etype: t}, f), _]:
				var c = (switch follow(t) {
					case TInst(c, _): c;
					case _: Globals.die("", "genneko.ml");
				});
				return call(p, builtin(p, "call"), [
					field(p, genTypePath(p, new GlobalTypePath(c.clPath.pack, "@" + c.clPath.name)), fieldName(f)),
					this_(p),
					array(p, el.mapToArray(genExpr.bind(ctx)))
				]);
			case [_, _]:
				var e = (switch genExpr(ctx, e) {
					case e = {decl: EFunction(_)}: new NExpr(EBlock([e]), p);
					case e: e;
				});
				return call(p, e, el.mapToArray(genExpr.bind(ctx)));
		}
	}

	static function genExpr(ctx:Context, e:TExpr):NExpr {
		var p = pos(ctx, e.epos);
		switch e.eexpr {
			case TConst(c):
				return genConstant(ctx, e.epos, c);
			case TIdent(s) if (s.charAt(0) == "$"):
				return new NExpr(EConst(Builtin(bs(s.substr(1, s.length - 1)))), p);
			case TLocal(v):
				return if (hasVarFlag(v, VCaptured)) new NExpr(EArray(ident(p, v.vName), int(p, 0)), p) else ident(p, v.vName);
			case TArray(e1, e2):
				return new NExpr(EArray(genExpr(ctx, e1), genExpr(ctx, e2)), p);
			case TBinop(OpAssign, {eexpr: TField(e1, f)}, e2):
				return new NExpr(EBinop("=", field(p, genExpr(ctx, e1), fieldName(f)), genExpr(ctx, e2)), p);
			case TBinop(op, e1, e2):
				return genBinop(ctx, p, op, e1, e2);
			case TField(e2, FClosure(_, f)):
				function emit(n:Int):NExpr {
					if (n > 5) core.Error.abort("Cannot create closure with more than 5 arguments", e.epos);
					var tmp = ident(p, "@tmp");
					return new NExpr(EBlock([
						new NExpr(EVars([
							{name: "@tmp", expr: genExpr(ctx, e2)},
							{name: "@fun", expr: field(p, tmp, f.cfName)}
						]), p),
						if (ctx.macros) call(p, builtin(p, "closure"), [ident(p, "@fun"), tmp]) else
							call(p, ident(p, "@closure" + Std.string(n)), [tmp, ident(p, "@fun")])
					]), p);
				}
				return switch followWithCoro(e.etype) {
					case NotCoro(TFun(sig)):
						var n = sig.args.length;
						emit(n);
					case Coro(sig):
						var n = sig.args.length;
						emit(n + 1);
					case _:
						Globals.die("", "genneko.ml");
				}
			case TEnumParameter(e, _, i):
				return new NExpr(EArray(field(p, genExpr(ctx, e), "args"), int(p, i)), p);
			case TEnumIndex(e):
				return field(p, genExpr(ctx, e), "index");
			case TField(e, f):
				return field(p, genExpr(ctx, e), fieldName(f));
			case TTypeExpr(t):
				return genTypePath(p, tPath(t));
			case TParenthesis(e):
				return new NExpr(EParenthesis(genExpr(ctx, e)), p);
			case TMeta(_, e):
				return genExpr(ctx, e);
			case TObjectDecl(fl):
				var hasToString = false;
				var fl = fl.mapToArray(fe -> {
					var f = fe.key.name, e = fe.expr;
					if (f == "toString") hasToString = (switch follow(e.etype) {
						case TFun({args: []}): true;
						case _: false;
					});
					{name: bs(f), expr: genExpr(ctx, e)};
				});
				return new NExpr(EObject(if (hasToString) [{name: "__string", expr: ident(p, "@default__string")}].concat(fl) else fl), p);
			case TArrayDecl(el):
				return call(p, field(p, ident(p, "Array"), "new1"), [array(p, el.mapToArray(genExpr.bind(ctx))), int(p, el.length)]);
			case TCall(e, el):
				return genCall(ctx, p, e, el);
			case TNew(c, tl, params):
				return call(p, field(p, genTypePath(p, c.clPath), "new"), params.mapToArray(genExpr.bind(ctx)));
			case TUnop(op, flag, e):
				return genUnop(ctx, p, op, flag, e);
			case TVar(v, eo):
				var e = (if (eo == null) {
					if (hasVarFlag(v, VCaptured)) call(p, builtin(p, "array"), [null_(p)]) else null;
				} else {
					var e = genExpr(ctx, eo);
					if (hasVarFlag(v, VCaptured)) call(p, builtin(p, "array"), [e]) else e;
				});
				return new NExpr(EVars([{name: bs(v.vName), expr: e}]), p);
			case TFunction(f):
				var inits = [];
				for (arg in f.tfArgs) {
					var a = arg.variable, c = arg.defaultValue;
					if (hasVarFlag(a, VCaptured)) inits.unshift(new NExpr(EBinop("=", ident(p, a.vName), call(p, builtin(p, "array"), [ident(p, a.vName)])), p));
					switch c {
						case null | {eexpr: TConst(TNull)}:
						case c:
							inits.unshift(genExpr(ctx, core.Texpr.setDefault(ctx.com.basic, a, c, e.epos)));
					}
				}
				var e = genExpr(ctx, f.tfExpr);
				var e = (switch inits {
					case []: e;
					case _:
						var l = [e].concat(inits);
						l.reverse();
						new NExpr(EBlock(l), p);
				});
				return new NExpr(EFunction(f.tfArgs.mapToArray(a -> bs(argName(a))), withReturn(e)), p);
			case TBlock(el):
				return new NExpr(EBlock(el.mapToArray(genExpr.bind(ctx))), p);
			case TIf(cond, e1, e2):
				/* if(e)-1 is parsed as if( e - 1 ) */
				function parent(e:TExpr) return mk(TParenthesis(e), e.etype, e.epos);
				var e1 = (switch e1.eexpr {
					case TConst(TInt(n)) if (n < 0): parent(e1);
					case TConst(TFloat(f)) if (f.charAt(0) == "-"): parent(e1);
					case _: e1;
				});
				return new NExpr(EIf(genExpr(ctx, cond), genExpr(ctx, e1), (e2 == null ? null : genExpr(ctx, e2))), p);
			case TWhile(econd, e, flag):
				return new NExpr(EWhile(genExpr(ctx, econd), genExpr(ctx, e), (flag == core.Ast.WhileFlag.NormalWhile ? NormalWhile : DoWhile)), p);
			case TTry(e, catchs):
				function loop(i:Int):NExpr {
					if (i >= catchs.length) return call(p, builtin(p, "rethrow"), [ident(p, "@tmp")]);
					var v = catchs[i].variable, e = catchs[i].expr;
					var e2 = loop(i + 1);
					var path = (switch follow(v.vType) {
						case TInst(c, _): c.clPath;
						case TEnum(e, _): e.ePath;
						case TAbstract(a, _): a.aPath;
						case TDynamic(_): null;
						case _: Globals.die("", "genneko.ml");
					});
					var cond = (if (path == null) new NExpr(EConst(True), p) else
						call(p, field(p, genTypePath(p, new GlobalTypePath(["neko"], "Boot")), "__instanceof"), [ident(p, "@tmp"), genTypePath(p, path)]));
					var id = ident(p, "@tmp");
					var id = (if (hasVarFlag(v, VCaptured)) call(p, builtin(p, "array"), [id]) else id);
					var e = genExpr(ctx, e);
					return new NExpr(EIf(cond, new NExpr(EBlock([new NExpr(EVars([{name: bs(v.vName), expr: id}]), p), e,]), p), e2), p);
				}
				var catchs = loop(0);
				var catchs = new NExpr(EBlock([
					new NExpr(EIf(new NExpr(EBinop("==", call(p, builtin(p, "typeof"), [ident(p, "@tmp")]), builtin(p, "tstring")), p),
						new NExpr(EBinop("=", ident(p, "@tmp"), call(p, field(p, ident(p, "String"), "new"), [ident(p, "@tmp")])), p), null),
						p),
					catchs,
				]), p);
				return new NExpr(ETry(genExpr(ctx, e), "@tmp", catchs), p);
			case TReturn(eo):
				return new NExpr(EReturn(eo == null ? null_(p) : genExpr(ctx, eo)), p);
			case TBreak:
				return new NExpr(EBreak(null), p);
			case TContinue:
				return new NExpr(EContinue, p);
			case TThrow(e):
				return call(p, builtin(p, "throw"), [genExpr(ctx, e)]);
			case TCast(e, null):
				return genExpr(ctx, e);
			case TCast(e1, t):
				return genExpr(ctx, codegen.Codegen.defaultCast(ctx.com.basic, ctx.com.std, e1, t, e.etype, e.epos, "@tmp"));
			case TIdent(s):
				return ident(p, s);
			case TSwitch({switchSubject: e, switchCases: cases, switchDefault: eo}):
				var e = genExpr(ctx, e);
				var eo = (eo == null ? null : genExpr(ctx, eo));
				// port: upstream raises Exit from the case mapping when a case has several patterns.
				var single = true;
				for (c in cases) switch c.casePatterns {
					case []:
					case [_]:
					case _:
						single = false;
				}
				if (single) {
					return new NExpr(ESwitch(e, cases.mapToArray(c -> switch c.casePatterns.map(genExpr.bind(ctx)) {
						case []: Globals.die("", "genneko.ml");
						case [e]: {e1: e, e2: genExpr(ctx, c.caseExpr)};
						case _: throw core.ds.Exit.raise();
					}), eo), p);
				} else {
					var rcases = cases.rev();
					var acc = (eo == null ? null_(p) : eo);
					for (c in rcases) {
						var el = c.casePatterns, e = c.caseExpr;
						var cond = (switch el {
							case []: Globals.die("", "genneko.ml");
							case _:
								function eq(e:TExpr) return new NExpr(EBinop("==", ident(p, "@tmp"), genExpr(ctx, e)), p);
								var acc = eq(el[0]);
								for (i in 1...el.length) acc = new NExpr(EBinop("||", acc, eq(el[i])), p);
								acc;
						});
						acc = new NExpr(EIf(cond, genExpr(ctx, e), acc), p);
					}
					return new NExpr(EBlock([new NExpr(EVars([{name: "@tmp", expr: e}]), p), acc]), p);
				}
		}
	}

	static function genMethod(ctx:Context, p:NPos, c:TClassField, acc:Array<{name:String, e:NExpr}>):Array<{name:String, e:NExpr}> {
		ctx.curmethod = c.cfName;
		if (!isPhysicalField(c)) return acc;
		var e = c.cfExpr;
		if (e == null) return [{name: c.cfName, e: null_(p)}].concat(acc);
		switch e.eexpr {
			case TCall({eexpr: TField(_, FStatic({clPath: {pack: ["neko"], name: "Lib"}}, {cfName: load = "load" | "loadLazy"}))},
				[{eexpr: TConst(TString(m))}, {eexpr: TConst(TString(f))}, {eexpr: TConst(TInt(n))}]):
				var p = pos(ctx, e.epos);
				var e = call(p, new NExpr(EField(builtin(p, "loader"), "loadprim"), p),
					[new NExpr(EBinop("+", new NExpr(EBinop("+", str(p, m), str(p, "@")), p), str(p, f)), p), new NExpr(EConst(Int(n)), p)]);
				var e = (if (load == "load") e else new NExpr(ETry(e, "@e", call(p, ident(p, "@lazy_error"), [ident(p, "@e")])), p));
				return [{name: c.cfName, e: e}].concat(acc);
			case TFunction(_):
				return [{name: (if (c.cfName == "new") "__construct__" else c.cfName), e: genExpr(ctx, e)}].concat(acc);
			case _:
				return [{name: c.cfName, e: null_(p)}].concat(acc);
		}
	}

	// port: PMap.fold (gen_method ctx p) over a field map, in key order.
	static function foldMethods(ctx:Context, p:NPos, fields:haxe.ds.StringMap<TClassField>,
			acc:Array<{name:String, e:NExpr}>):Array<{name:String, e:NExpr}> {
		return core.ds.PMap.fold((f, acc) -> genMethod(ctx, p, f, acc), fields, acc);
	}

	static function genClass(ctx:Context, c:TClass):NExpr {
		ctx.curclass = sTypePath(c.clPath);
		ctx.curmethod = "$init";
		var p = pos(ctx, c.clPos);
		var clpath = genTypePath(p, new GlobalTypePath(c.clPath.pack, "@" + c.clPath.name));
		var stpath = genTypePath(p, c.clPath);
		var fnew = (switch c.clConstructor {
			case null:
				[];
			case f:
				switch f.cfExpr {
					case {eexpr: TFunction(tf)}:
						var params = tf.tfArgs.map(a -> a.variable.vName);
						genMethod(ctx, p, f, [
							{
								name: "new",
								e: new NExpr(EFunction(params.mapToArray(bs), new NExpr(EBlock([
									new NExpr(EVars([{name: "@o", expr: call(p, builtin(p, "new"), [null_(p)])}]), p),
									(call(p, builtin(p, "objsetproto"), [ident(p, "@o"), clpath])),
									(call(p, builtin(p, "call"), [
										field(p, this_(p), "__construct__"),
										ident(p, "@o"),
										array(p, params.mapToArray(ident.bind(p)))
									])),
									new NExpr(EReturn(ident(p, "@o")), p)
								]), p)), p)
							}
						]);
					case _:
						[];
				}
		});
		var fstring = (switch c.clFields.get("toString") {
			case null:
				[];
			case f:
				switch follow(f.cfType) {
					case TFun({args: []}): [{name: "__string", e: ident(p, "@default__string")}];
					case _: [];
				}
		});
		var fserialize = {name: "__serialize", e: ident(p, "@serialize")};
		var others = (switch c.clImplements {
			case []: [];
			case l: [{name: "__interfaces__", e: array(p, l.map(ci -> genTypePath(p, ci.cls.clPath)))}];
		}).concat(switch c.clSuper {
			case null: [];
			case {cls: c}: [{name: "__super__", e: genTypePath(p, c.clPath)}];
		});
		function build(fe:{name:String, e:NExpr}) return new NExpr(EBinop("=", field(p, ident(p, "@tmp"), fe.name), fe.e), p);
		var tmp = new NExpr(EVars([{name: "@tmp", expr: call(p, builtin(p, "new"), [null_(p)])}]), p);
		var estat = new NExpr(EBinop("=", stpath, ident(p, "@tmp")), p);
		function genProps(props:Array<{name:String, field:String}>) return new NExpr(EObject(props.map(ns -> {name: bs(ns.name), expr: str(p, ns.field)})), p);
		var sprops = (switch codegen.Codegen.getProperties(c.clOrderedStatics) {
			case []: [];
			case l: [{name: "__properties__", e: genProps(l)}];
		});
		var sfields = [{name: "prototype", e: clpath}].concat(sprops).concat(foldMethods(ctx, p, c.clStatics, fnew.concat(others))).map(build);
		var eclass = new NExpr(EBinop("=", clpath, ident(p, "@tmp")), p);
		var mfields = foldMethods(ctx, p, c.clFields, [fserialize].concat(fstring)).map(build);
		var props = codegen.Codegen.getProperties(c.clOrderedFields);
		var emeta = [new NExpr(EBinop("=", field(p, clpath, "__class__"), stpath), p)].concat(switch props {
			case []: [];
			case _:
				var props = genProps(props);
				var props = (switch c.clSuper {
					case {cls: csup} if (codegen.Codegen.hasProperties(csup)):
						new NExpr(EBlock([
							new NExpr(EVars([{name: "@tmp", expr: props}]), p),
							call(p, builtin(p, "objsetproto"), [
								ident(p, "@tmp"),
								field(p, field(p, genTypePath(p, csup.clPath), "prototype"), "__properties__")
							]),
							ident(p, "@tmp")
						]), p);
					case _: props;
				});
				[new NExpr(EBinop("=", field(p, clpath, "__properties__"), props), p)];
		}).concat(switch c.clPath {
			case {pack: [], name: name}: [new NExpr(EBinop("=", field(p, ident(p, "@classes"), name), ident(p, name)), p)];
			case _: [];
		});
		var emeta = if (ctx.macros) {
			// port: `Obj.magic (TClassDecl c)` hands the OCaml type to the macro interpreter;
			// genneko only runs with macros = false here.
			throw new core.ds.Failure("haxe-in-haxe: genneko macro context (typewrap) is not supported");
		} else emeta;
		var eextends = (switch c.clSuper {
			case null: [];
			case {cls: c}:
				var esuper = genTypePath(p, new GlobalTypePath(c.clPath.pack, "@" + c.clPath.name));
				[call(p, builtin(p, "objsetproto"), [clpath, esuper])];
		});
		return new NExpr(EBlock([tmp, eclass].concat(mfields).concat([tmp, estat]).concat(sfields).concat(eextends).concat(emeta)), p);
	}

	static function genEnumConstr(ctx:Context, path:NExpr, c:TEnumField):NExpr {
		ctx.curmethod = c.efName;
		var p = pos(ctx, c.efPos);
		return new NExpr(EBinop("=", field(p, path, c.efName), switch follow(c.efType) {
			case TFun(sig):
				var params = sig.args.map(a -> a.name);
				new NExpr(EFunction(params.mapToArray(bs), new NExpr(EBlock([
					new NExpr(EVars([
						{
							name: "@tmp",
							expr: new NExpr(EObject([
								{name: "tag", expr: str(p, c.efName)},
								{name: "index", expr: int(p, c.efIndex)},
								{name: "args", expr: array(p, params.mapToArray(ident.bind(p)))},
							]), p)
						}
					]), p),
					call(p, builtin(p, "objsetproto"), [ident(p, "@tmp"), field(p, path, "prototype")]),
					ident(p, "@tmp"),
				]), p)), p);
			case _:
				new NExpr(EBlock([
					new NExpr(EVars([
						{
							name: "@tmp",
							expr: new NExpr(EObject([
								{name: "tag", expr: str(p, c.efName)},
								{name: "index", expr: int(p, c.efIndex)},
								{name: "__serialize", expr: ident(p, "@tag_serialize")}
							]), p)
						}
					]), p),
					call(p, builtin(p, "objsetproto"), [ident(p, "@tmp"), field(p, path, "prototype")]),
					ident(p, "@tmp"),
				]), p);
		}), p);
	}

	static function genEnum(ctx:Context, e:TEnum):NExpr {
		ctx.curclass = sTypePath(e.ePath);
		ctx.curmethod = "$init";
		var p = pos(ctx, e.ePos);
		var path = genTypePath(p, e.ePath);
		var uname = new NExpr(EConst(Ident(bs(genGlobalName(ctx, e.ePath)))), p);
		return new NExpr(EBlock([
			new NExpr(EBinop("=", uname, call(p, builtin(p, "new"), [null_(p)])), p),
			new NExpr(EBinop("=", path, uname), p),
			new NExpr(EBinop("=", field(p, uname, "prototype"), new NExpr(EObject([
				{name: "__enum__", expr: uname},
				{name: "__serialize", expr: ident(p, "@serialize")},
				{name: "__string", expr: ident(p, "@enum_to_string")}
			]), p)), p)
		].concat(pmapList(genEnumConstr.bind(ctx, uname), e.eConstrs)).concat(switch e.ePath {
			case {pack: [], name: name}: [new NExpr(EBinop("=", field(p, ident(p, "@classes"), name), ident(p, name)), p)];
			case _: [];
		})), p);
	}

	static function genType(ctx:Context, t:ModuleType, acc:Array<NExpr>):Array<NExpr> {
		switch t {
			case TClassDecl(c):
				switch TClassTools.getClInit(c) {
					case null:
					case e:
						ctx.inits.unshift({c: c, e: e});
				}
				return if (hasClassFlag(c, CExtern)) acc else [genClass(ctx, c)].concat(acc);
			case TEnumDecl(e):
				return if (hasEnumFlag(e, EnExtern)) acc else [genEnum(ctx, e)].concat(acc);
			case TTypeDecl(_) | TAbstractDecl(_):
				return acc;
		}
	}

	static function genStaticVars(ctx:Context, t:ModuleType):Array<NExpr> {
		switch t {
			case TEnumDecl(_) | TTypeDecl(_) | TAbstractDecl(_):
				return [];
			case TClassDecl(c):
				if (hasClassFlag(c, CExtern)) return [];
				// port: List.fold_right: the last static is processed first.
				var acc = [];
				var i = c.clOrderedStatics.length;
				while (i-- > 0) {
					var f = c.clOrderedStatics[i];
					var e = f.cfExpr;
					if (e == null) continue;
					switch e.eexpr {
						case TFunction(_):
						case _:
							ctx.curclass = sTypePath(c.clPath);
							ctx.curmethod = "$statics";
							var p = pos(ctx, e.epos);
							acc.unshift(new NExpr(EBinop("=", (field(p, genTypePath(p, c.clPath), f.cfName)), genExpr(ctx, e)), p));
					}
				}
				return acc;
		}
	}

	static function genPackage(ctx:Context, t:ModuleType):Array<NExpr> {
		function loop(acc:Array<String>, p:Array<String>, i:Int):Array<NExpr> {
			if (i >= p.length) return [];
			var x = p[i];
			var path = acc.concat([x]);
			var key = path.join(".");
			if (!ctx.packages.exists(key)) {
				var p2 = pos(ctx, tInfos(t).mtPos);
				var e = new NExpr(EBinop("=", genTypePath(p2, new GlobalTypePath(acc, x)), call(p2, builtin(p2, "new"), [null_(p2)])), p2);
				ctx.packages.set(key, true);
				return switch acc {
					case []:
						var reg = new NExpr(EBinop("=", field(p2, ident(p2, "@classes"), x), ident(p2, x)), p2);
						[e, reg].concat(loop(path, p, i + 1));
					case _:
						[e].concat(loop(path, p, i + 1));
				}
			} else
				return loop(path, p, i + 1);
		}
		return loop([], tPath(t).pack, 0);
	}

	static function genBoot(ctx:Context):NExpr {
		return new NExpr(EBlock([
			new NExpr(EBinop("=", field(Nast.nullPos, genTypePath(Nast.nullPos, new GlobalTypePath(["neko"], "Boot")), "__classes"),
				ident(Nast.nullPos, "@classes")), Nast.nullPos),
			call(Nast.nullPos, field(Nast.nullPos, genTypePath(Nast.nullPos, new GlobalTypePath(["neko"], "Boot")), "__init"), []),
		]), Nast.nullPos);
	}

	static function genName(ctx:Context, acc:Array<NExpr>, t:ModuleType):Array<NExpr> {
		switch t {
			case TEnumDecl(e) if (hasEnumFlag(e, EnExtern)):
				return acc;
			case TEnumDecl(e):
				var p = pos(ctx, e.ePos);
				var name = e.ePath.pack.concat([e.ePath.name]);
				var arr = call(p, field(p, ident(p, "Array"), "new1"), [array(p, name.map(n -> genConstant(ctx, e.ePos, TString(n)))), int(p, name.length)]);
				var path = genTypePath(p, e.ePath);
				var setname = new NExpr(EBinop("=", field(p, path, "__ename__"), arr), p);
				var arr = call(p, field(p, ident(p, "Array"), "new1"), [array(p, e.eNames.map(n -> genConstant(ctx, e.ePos, TString(n)))), int(p, e.eNames.length)]);
				var setconstrs = new NExpr(EBinop("=", field(p, path, "__constructs__"), arr), p);
				var meta = (switch core.Texpr.buildMetadata(ctx.com.basic, TEnumDecl(e)) {
					case null: [];
					case e: [new NExpr(EBinop("=", field(p, path, "__meta__"), genExpr(ctx, e)), p)];
				});
				var meta = if (ctx.macros) {
					// port: `Obj.magic t` hands the OCaml type to the macro interpreter; genneko
					// only runs with macros = false here.
					throw new core.ds.Failure("haxe-in-haxe: genneko macro context (typewrap) is not supported");
				} else meta;
				return [setname, setconstrs].concat(meta).concat(acc);
			case TClassDecl(c):
				if (hasClassFlag(c, CExtern) || c.clKind.match(KTypeParameter(_))) return acc;
				var p = pos(ctx, c.clPos);
				var name = c.clPath.pack.concat([c.clPath.name]);
				var arr = call(p, field(p, ident(p, "Array"), "new1"), [array(p, name.map(n -> genConstant(ctx, c.clPos, TString(n)))), int(p, name.length)]);
				return [new NExpr(EBinop("=", field(p, genTypePath(p, c.clPath), "__name__"), arr), p)].concat(switch c.clImplements {
					case []: acc;
					case l:
						var interf = field(p, genTypePath(p, c.clPath), "__interfaces__");
						[new NExpr(EBinop("=", interf, call(p, field(p, ident(p, "Array"), "new1"), [interf, int(p, l.length)])), p)].concat(acc);
				});
			case TTypeDecl(_) | TAbstractDecl(_):
				return acc;
		}
	}

	static function generateLibsInit(libs:Array<String>):Array<NExpr> {
		if (libs.length == 0) return [];
		/*
			var @s = $loader.loadprim("std@sys_string",0)();
			if( $version() >= 240 )
				@s = @s + switch $loader.loadprim("std@sys_cpu_arch",0)() {
					"arm64" => "Arm64"
					"arm" => "Arm"
					"x86_64" => "64"
					default => ""
				};
			else if( $loader.loadprim("std@sys_is64",0)() )
				@s = @s + 64;
			@s = @s + "/";
		 */
		var p = Nast.nullPos;
		var es = ident(p, "@s");
		function loadp(n:String, nargs:Int) return call(p, field(p, builtin(p, "loader"), "loadprim"), [str(p, "std@" + n), int(p, nargs)]);
		function op(o:String, e1:NExpr, e2:NExpr) return new NExpr(EBinop(o, e1, e2), p);
		var boot = [
			new NExpr(EVars([{name: "@s", expr: call(p, loadp("sys_string", 0), [])},]), p),
			new NExpr(EIf(op(">=", call(p, builtin(p, "version"), []), int(p, 240)), (op("=", es, op("+", es, new NExpr(ESwitch(call(p, loadp("sys_cpu_arch", 0), []), [
				{e1: str(p, "arm64"), e2: str(p, "Arm64")},
				{e1: str(p, "arm"), e2: str(p, "Arm")},
				{e1: str(p, "x86_64"), e2: str(p, "64")},
			], str(p, "")), p)))), new NExpr(EIf(call(p, loadp("sys_is64", 0), []), op("=", es, op("+", es, int(p, 64))), null), p)), p),
			op("=", es, op("+", es, str(p, "/"))),
		];
		var lpath = field(p, builtin(p, "loader"), "path");
		return boot.concat(libs.map(dir -> {
			var dstr = str(p, dir);
			/*
				// for each lib dir
				$loader.path = $array(dir+@s,$loader.path);
			 */
			op("=", lpath, call(p, builtin(p, "array"), [op("+", dstr, ident(p, "@s")), lpath]));
		}));
	}

	static function newContext(com:Gctx, ver:Int, macros:Bool):Context {
		return {
			version: ver,
			com: com,
			globals: new haxe.ds.StringMap(),
			curglobal: 0,
			packages: new haxe.ds.StringMap(),
			macros: macros,
			curclass: "$boot",
			curmethod: "$init",
			inits: [],
			labelCount: 0,
		};
	}

	static function header():Array<NExpr> {
		var p:NPos = {psource: "<header>", pline: 1};
		function fields(l:Array<String>):NExpr {
			var l = l.copy();
			l.reverse();
			function loop(i:Int):NExpr {
				return if (i >= l.length) Globals.die("", "genneko.ml") else if (i == l.length - 1) ident(p, l[i]) else field(p, loop(i + 1), l[i]);
			}
			return loop(0);
		}
		function func(pl:Array<String>, e:NExpr) return new NExpr(EFunction(pl, new NExpr(EReturn(e), p)), p);
		var inits = [
			{v: "@classes", e: call(p, builtin(p, "new"), [null_(p)])},
			{v: "@enum_to_string", e: func([], call(p, fields(["neko", "Boot", "__enum_str"]), [this_(p)]))},
			{v: "@serialize", e: func([], call(p, fields(["neko", "Boot", "__serialize"]), [this_(p)]))},
			{v: "@tag_serialize", e: func([], call(p, fields(["neko", "Boot", "__tagserialize"]), [this_(p)]))},
			{
				v: "@lazy_error",
				e: func(["e"], call(p, builtin(p, "varargs"), [func(["_"], call(p, builtin(p, "throw"), [ident(p, "e")]))]))
			},
			{
				v: "@default__string",
				e: func([], new NExpr(EBlock([
					new NExpr(EVars([{name: "@s", expr: call(p, field(p, this_(p), "toString"), [])}]), p),
					new NExpr(EIf(new NExpr(EBinop("!=", call(p, builtin(p, "typeof"), [ident(p, "@s")]), builtin(p, "tobject")), p),
						new NExpr(EReturn(null_(p)), p), null), p),
					new NExpr(EReturn(field(p, ident(p, "@s"), "__s")), p),
				]), p))
			}
		];
		var inits = inits.concat([0, 1, 2, 3, 4, 5].map(nargs -> {
			var args = [for (i in 0...nargs) std.String.fromCharCode('a'.code + i)];
			var efun = new NExpr(EFunction(args, new NExpr(EBlock([
				new NExpr(EBinop("=", new NExpr(EConst(This), p), ident(p, "@this")), p),
				call(p, ident(p, "@fun"), args.map(ident.bind(p))),
			]), p)), p);
			var eif = EIf(new NExpr(EBinop("==", ident(p, "@fun"), null_(p)), p), null_(p), efun);
			var e = func(["@this", "@fun"], new NExpr(eif, p));
			{v: "@closure" + Std.string(nargs), e: e};
		}));
		return inits.map(ve -> new NExpr(EBinop("=", ident(p, ve.v), ve.e), p));
	}

	static function build(ctx:Context, types:Array<ModuleType>):Array<NExpr> {
		var packs = [];
		for (t in types) packs = packs.concat(genPackage(ctx, t));
		var names = [];
		for (t in types) names = genName(ctx, names, t);
		var methods = [];
		for (t in types) methods = genType(ctx, t, methods);
		methods.reverse();
		var boot = genBoot(ctx);
		var rinits = ctx.inits.copy();
		rinits.reverse();
		var inits = rinits.map(ce -> {
			ctx.curclass = sTypePath(ce.c.clPath);
			ctx.curmethod = "__init__";
			genExpr(ctx, ce.e);
		});
		ctx.inits = [];
		var vars = [];
		for (t in types) vars = vars.concat(genStaticVars(ctx, t));
		return packs.concat(methods).concat([boot]).concat(names).concat(inits).concat(vars);
	}

	public static function generate(nekoLibPaths:Array<String>, com:Gctx):Void {
		files.clear();
		var ctx = newContext(com, (if (Gctx.defined(com, Define.NekoV1)) 1 else 2), false);
		var libs = new NExpr(EBlock((if (Gctx.defined(com, Define.NekoNoHaxelibPaths)) [] else generateLibsInit(nekoLibPaths))), {
			psource: "<header>",
			pline: 1,
		});
		var el = build(ctx, com.types);
		var emain = (switch com.main.mainExpr {
			case null: [];
			case e: [genExpr(ctx, e)];
		});
		var e = new NExpr(EBlock(header().concat([libs]).concat(el).concat(emain)), Nast.nullPos);
		var source = Gctx.defined(com, Define.NekoSource);
		var useNekoc = Gctx.defined(com, Define.UseNekoc);
		if (!useNekoc) {
			try {
				core.Path.mkdirFromPath(com.file);
				var ch = sys.io.File.write(com.file, true);
				// port: the bytecode is built in memory, then written to the opened file.
				var out = new haxe.io.BytesOutput();
				try {
					Nbytecode.write(out, Ncompile.compileAst(ctx.version, e));
				} catch (err:Dynamic) {
					ch.close();
					throw err;
				}
				ch.write(out.getBytes());
				ch.close();
			} catch (err:NcompileError) {
				var msg = unbs(err.msg), pos = err.pos;
				var pfile = Gctx.findFile(com, unbs(pos.psource));
				function loop(p:Int):Pos {
					while (true) {
						var pp:Pos = {pfile: pfile, pmin: p, pmax: p};
						if (syntax.Lexer.getErrorLine(pp) >= pos.pline) return pp else p = p + 1;
					}
				}
				core.Error.abort(msg, loop(0));
			}
		}
		function command(cmd:String, args:Array<String>):Int return try com.runCommandArgs(cmd, args) catch (_:Dynamic) -1;
		var nekoFile = (try OcamlFilename.chopExtension(com.file) catch (_:Dynamic) com.file) + ".neko";
		if (source || useNekoc) {
			var ch = sys.io.File.write(nekoFile, true);
			var out = new haxe.io.BytesOutput();
			Binast.write(out, e);
			ch.write(out.getBytes());
			ch.close();
		}
		if (useNekoc
			&& command("nekoc", (if (ctx.version > 1) ["-version", Std.string(ctx.version), OcamlFilename.quote(nekoFile)] else [OcamlFilename.quote(nekoFile)])) != 0)
			throw new core.ds.Failure("Neko compilation failure");
		if (source) {
			if (command("nekoc", ["-p", OcamlFilename.quote(nekoFile)]) != 0) throw new core.ds.Failure("Failed to print neko code");
			sys.FileSystem.deleteFile(nekoFile);
			sys.FileSystem.rename((try OcamlFilename.chopExtension(com.file) catch (_:Dynamic) com.file) + "2.neko", nekoFile);
		}
	}
}
