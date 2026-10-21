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

package syntax;

import core.Ast;
import core.Ast.*;
import core.Globals;
import core.Globals.Pos;
import core.Meta;
import core.MetaList.StrictMeta;
import core.ds.Stream;
import core.display.DisplayPosition;
import core.DisplayTypes.DisplayModeValue;
import syntax.Parser;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

// port: ppx_parser semantics (see ppx_parser lib/parser.ml): a `match%parser` case is
// selected by its first element. A terminal first element is matched against
// Stream.peek (guards are evaluated before junking); a call first element is
// selected unless it raises Stream.Failure. Once selected, any later element
// that fails raises Stream.Error "Parse error.". No selected case raises
// Stream.Failure. `tail` converts Stream.Failure from later call elements.
private typedef S = Stream<syntax.Lexer.LexedToken>;

private enum DeclResult<T> {
	DSuccess(v:T);
	DEnd(p:Pos);
	DError(msg:String);
}

class Grammar {
	static var parsingMacroCond = false;

	// port: entry points used by ParserEntry.

	public static function parseFileStream(ctx:ParserContext, s:S):Package {
		var r = parseFile(ctx, s);
		return {pack: r.pack, declarations: Vector.fromArrayCopy(r.decls)};
	}

	public static function parseExpressionStream(ctx:ParserContext, s:S):Expr return expr(ctx, s);

	// port: ppx_parser helpers

	static inline function peek(s:S):ParserToken return s.peek();

	static function tail<T>(f:Void->T):T {
		try return f()
		catch (_:StreamFailure) throw new StreamError("Parse error.");
	}

	// port: inline so the result is the caller's concrete {v:T} (HashLink otherwise
	// converts the generic structure with a dynamic lookup per call).
	static inline function tryHead<T>(f:Void->T):Null<{v:T}> {
		var r:Null<{v:T}> = null;
		// port: Stream.Failure is only ever thrown as the shared instance: an identity
		// test instead of the typed catch's Exception.caught and type check.
		try r = {v: f()} catch (e:haxe.Exception) {
			if (e != StreamFailure.instance) throw e;
		}
		return r;
	}

	static function fail<T>():T throw StreamFailure.raise();

	static function serror<T>():T throw new StreamError("Parse error.");

	static function expectTok(s:S, t:Token):Pos {
		var tk = peek(s);
		if (tk != null && Type.enumEq(tk.token, t)) {
			s.junk();
			return tk.pos;
		}
		return serror();
	}

	static function isTok(s:S, t:Token):Bool {
		var tk = peek(s);
		return tk != null && Type.enumEq(tk.token, t);
	}

	// port: accept a token without arguments: returns its position, or null.
	static function acceptTok(s:S, t:Token):Null<Pos> {
		var tk = peek(s);
		if (tk != null && Type.enumEq(tk.token, t)) {
			s.junk();
			return tk.pos;
		}
		return null;
	}

	static function isKwd(s:S, k:Keyword):Bool {
		var tk = peek(s);
		return tk != null && switch tk.token {
			case Kwd(k2): k2 == k;
			case _: false;
		};
	}

	static function acceptKwd(s:S, k:Keyword):Null<Pos> {
		if (isKwd(s, k)) {
			var tk = peek(s);
			s.junk();
			return tk.pos;
		}
		return null;
	}

	static function expectKwd(s:S, k:Keyword):Pos {
		var p = acceptKwd(s, k);
		return p == null ? serror() : p;
	}

	static function acceptBinop(s:S, op:Binop):Null<Pos> {
		var tk = peek(s);
		if (tk != null) switch tk.token {
			case Binop(op2) if (Type.enumEq(op, op2)):
				s.junk();
				return tk.pos;
			case _:
		}
		return null;
	}

	static function expectBinop(s:S, op:Binop):Pos {
		var p = acceptBinop(s, op);
		return p == null ? serror() : p;
	}

	static inline function mk(e:ExprDef, p:Pos):Expr return {expr: e, pos: p};

	static function pn(name:String, p:Pos):PlacedName return {name: name, pos: p};

	// port: popt, plist and the psep* helpers are inline for the same reason, and
	// because HashLink builds an Array<T> of a type parameter as an ArrayDyn.
	public static inline function popt<T>(f:S->T, s:S):Null<T> {
		var r = tryHead(function() return f(s));
		return r == null ? null : r.v;
	}

	public static inline function plist<T>(f:S->T, s:S):Array<T> {
		var acc = [];
		while (true) {
			var r = tryHead(function() return f(s));
			if (r == null) break;
			acc.push(r.v);
		}
		return acc;
	}

	public static inline function psepNonempty<T>(sep:Token, f:S->T, s:S):Array<T> {
		var v = f(s);
		var acc = [v];
		while (true) {
			if (isTok(s, sep)) {
				s.junk();
				acc.push(tail(function() return f(s)));
			} else break;
		}
		return acc;
	}

	public static inline function psep<T>(sep:Token, f:S->T, s:S):Array<T> {
		var r = tryHead(function() return psepNonempty(sep, f, s));
		return r == null ? [] : r.v;
	}

	public static inline function psepTrailing<T>(sep:Token, f:S->T, s:S):Array<T> {
		var acc = [];
		while (true) {
			var r = tryHead(function() return f(s));
			if (r == null) break;
			acc.push(r.v);
			if (isTok(s, sep)) s.junk()
			else break;
		}
		return acc;
	}

	static function pignore(f:Void->Dynamic):Void {
		try f()
		catch (_:StreamError) {} catch (_:StreamFailure) {}
	}

	static function expectUnlessResumeP(ctx:ParserContext, t:Token, s:S):Pos {
		var tk = peek(s);
		if (tk != null && Type.enumEq(tk.token, t)) {
			s.junk();
			return tk.pos;
		}
		return Parser.syntaxError(ctx, Expected([core.Ast.Ast.sToken(t)]), s, Parser.nextPos(ctx, s));
	}

	static function ident(s:S):PlacedName {
		var tk = peek(s);
		return switch tk.token {
			case Const(Ident(i)):
				s.junk();
				pn(i, tk.pos);
			case _: fail();
		}
	}

	static function dollarIdent(s:S):PlacedName {
		var tk = peek(s);
		return switch tk.token {
			case Const(Ident(i)):
				s.junk();
				pn(i, tk.pos);
			case Dollar(i):
				s.junk();
				pn("$" + i, tk.pos);
			case _: fail();
		}
	}

	static function dollarIdentMacro(pack:Array<String>, s:S):PlacedName {
		var tk = peek(s);
		return switch tk.token {
			case Const(Ident(i)):
				s.junk();
				pn(i, tk.pos);
			case Dollar(i):
				s.junk();
				pn("$" + i, tk.pos);
			case Kwd(Macro) if (pack.length > 0):
				s.junk();
				pn("macro", tk.pos);
			case Kwd(Extern) if (pack.length > 0):
				s.junk();
				pn("extern", tk.pos);
			case Kwd(Function) if (pack.length > 0):
				s.junk();
				pn("function", tk.pos);
			case _: fail();
		}
	}

	static function lowerIdentOrMacro(s:S):String {
		var tk = peek(s);
		return switch tk.token {
			case Const(Ident(i)) if (isLowerIdent(i)):
				s.junk();
				i;
			case Kwd(Macro):
				s.junk();
				"macro";
			case Kwd(Extern):
				s.junk();
				"extern";
			case Kwd(Function):
				s.junk();
				"function";
			case _: fail();
		}
	}

	static function propertyIdent(s:S):PlacedName {
		var r = tryHead(function() return ident(s));
		if (r != null) return r.v;
		var tk = peek(s);
		return switch tk.token {
			case Kwd(Private):
				s.junk();
				var tk2 = peek(s);
				switch tk2.token {
					case Const(Ident(i)):
						s.junk();
						pn("private " + i, punion(tk.pos, tk2.pos));
					case _: serror();
				}
			case Kwd(Dynamic):
				s.junk();
				pn("dynamic", tk.pos);
			case Kwd(Default):
				s.junk();
				pn("default", tk.pos);
			case Kwd(Null):
				s.junk();
				pn("null", tk.pos);
			case _: fail();
		}
	}

	static function questionableDollarIdent(ctx:ParserContext, s:S):{opt:Bool, name:PlacedName} {
		var po = acceptTok(s, Question);
		var n = dollarIdent(s);
		if (po == null) return {opt: false, name: n};
		if (n.pos.pmin != po.pmax) Parser.syntaxError(ctx, Custom('Invalid usage of ?, use ?${n.name} instead'), s, null, po);
		return {opt: true, name: n};
	}

	static function questionMark(s:S):Pos {
		var p = acceptTok(s, Question);
		return p == null ? fail() : p;
	}

	static function semicolon(ctx:ParserContext, s:S):Pos {
		if (Parser.lastToken(ctx, s).token == BrClose) {
			var p = acceptTok(s, Semicolon);
			return p != null ? p : Parser.lastToken(ctx, s).pos;
		} else {
			var p = acceptTok(s, Semicolon);
			return p != null ? p : Parser.syntaxError(ctx, MissingSemicolon, s, Parser.nextPos(ctx, s));
		}
	}

	static function checkRedundantVar(ctx:ParserContext, p1:Pos, s:S):Void {
		var p2 = acceptKwd(s, Var);
		if (p2 != null) Parser.syntaxError(ctx, Custom("`final var` is not supported, use `final` instead"), s, null, punion(p1, p2));
	}

	// port: declarations

	static function parseFile(ctx:ParserContext, s:S):{pack:Array<String>, decls:Array<TypeDecl>} {
		if (isKwd(s, Package)) {
			s.junk();
			var pack = tail(function() return parsePackage(s));
			var tk = peek(s);
			switch tk.token {
				case Const(Ident(_)) if (pack.length == 0):
					s.junk();
					return Parser.error(Custom("Package name must start with a lowercase character"), tk.pos);
				case _:
			}
			var psem = semicolon(ctx, s);
			var l = tail(function() return parseTypeDecls(ctx, TCAfterImport, psem.pmax, pack, [], s));
			return {pack: pack, decls: l};
		}
		var l = parseTypeDecls(ctx, TCBeforePackage, -1, [], [], s);
		return {pack: [], decls: l};
	}

	static function parseTypeDecls(ctx:ParserContext, mode:TypeDeclCompletionMode, pmax:Int, pack:Array<String>, acc:Array<TypeDecl>,
			s:S):Array<TypeDecl> {
		while (true) {
			Parser.checkTypeDeclCompletion(ctx, mode, pmax, s);
			var result:DeclResult<TypeDecl>;
			try {
				var r = tryHead(function() return parseTypeDecl(ctx, mode, s));
				if (r != null) result = DSuccess(r.v)
				else {
					var tk = peek(s);
					if (tk.token == Eof) {
						s.junk();
						result = DEnd(tk.pos);
					} else result = DError("Parse error.");
				}
			} catch (e:TypePathCompletion) {
				if (e.pack.length == 0 && e.type != null && !e.type.isSub) {
					var name = e.type.name;
					// resolve imports
					// port: upstream iterates the reversed accumulator
					var racc = acc.copy();
					racc.reverse();
					for (d in racc) switch d.definition {
						case EImport(imp):
							var t = imp.path.copy();
							t.reverse();
							if (t.length > 0 && t[0].name == name) {
								var path = t.slice(1);
								if (core.ds.ArrayTools.foreach(path, function(i) return isLowerIdent(i.name))) {
									var p2 = [for (i in path) i.name];
									p2.reverse();
									throw new TypePathCompletion(p2, {name: name, isSub: false}, e.inImport, e.pos);
								}
							}
						case _:
					}
					throw new TypePathCompletion(pack, {name: name, isSub: true}, e.inImport, e.pos);
				}
				throw e;
			} catch (e:StreamError) {
				if (!ctx.config.inDisplayFile) throw e;
				result = DError(e.message);
			}
			switch result {
				case DSuccess(td):
					mode = switch td.definition {
						case EImport(_) | EUsing(_): TCAfterImport;
						case _: TCAfterType;
					};
					acc.push(td);
					pmax = td.pos.pmax;
				case DEnd(_):
					return acc;
				case DError(msg):
					Parser.handleStreamError(ctx, msg, s);
					resume(ctx, false, false, s);
					pmax = Parser.lastPos(ctx, s).pmax;
			}
		}
	}

	static function parseAbstract(ctx:ParserContext, doc:Null<String>, meta:Metadata, flags:Array<AbstractFlag>, p1:Pos,
			s:S):{d:AbstractDefinition, p:Pos} {
		var name = typeName(ctx, s);
		var tl = tail(function() return parseConstraintParams(ctx, s));
		var st = tail(function() return parseAbstractSubtype(ctx, s));
		var sl = tail(function() return plist(function(s) return parseAbstractRelations(ctx, s), s));
		var fl:Array<ClassField>, p2:Pos;
		if (isTok(s, BrOpen)) {
			s.junk();
			var r = tail(function() return parseClassFields(ctx, false, p1, s));
			fl = r.fields;
			p2 = r.pos;
		} else {
			var r = Parser.syntaxError(ctx, Expected(["{", "to", "from"]), s, {fields: [], pos: Parser.lastPos(ctx, s)});
			fl = r.fields;
			p2 = r.pos;
		}
		var flags = st == null ? flags : [AbOver(st)].concat(flags);
		return {
			d: {
				name: name,
				doc: docFromStringOpt(doc),
				meta: meta,
				params: Vector.fromArrayCopy(tl),
				flags: Vector.fromArrayCopy(flags.concat(sl)),
				data: Vector.fromArrayCopy(fl)
			},
			p: punion(p1, p2)
		};
	}

	static function parseClassContent(ctx:ParserContext, doc:Null<String>, meta:Metadata, flags:Array<{flag:DeclFlag, pos:Pos}>,
			n:Array<ClassFlag>, p1:Pos, s:S):TypeDecl {
		var name = typeName(ctx, s);
		var tl = parseConstraintParams(ctx, s);
		function loop(hadDisplay:Bool, p0:Pos, acc:Array<ClassFlag>):Array<ClassFlag> {
			inline function checkDisplay(p1:Pos) {
				if (!hadDisplay
					&& ctx.config.inDisplayFile
					&& ctx.config.displayMode == DMDefault
					&& DisplayPosition.displayPosition.enclosedIn(p1))
					Parser.syntaxCompletion(n.indexOf(HInterface) >= 0 ? SCInterfaceRelation : SCClassRelation, null,
						DisplayPosition.displayPosition.withPos(p1));
			}
			var tk = peek(s);
			switch tk.token {
				case Kwd(Extends):
					var p1 = tk.pos;
					s.junk();
					var r = tail(function() return parseTypePathOrResume(ctx, p1, s));
					checkDisplay({pfile: p1.pfile, pmin: p0.pmax, pmax: p1.pmin});
					var p0 = r.ptp.posFull;
					// If we don't have type parameters, we have to offset by one so to not complete `extends`
					// and `implements` after the identifier.
					p0 = {pfile: p0.pfile, pmin: p0.pmin, pmax: p0.pmax + (r.ptp.path.tparams.length == 0 ? 1 : 0)};
					acc.unshift(HExtends(r.ptp));
					return loop(hadDisplay || r.b, p0, acc);
				case Kwd(Implements):
					var p1 = tk.pos;
					s.junk();
					var r = tail(function() return parseTypePathOrResume(ctx, p1, s));
					checkDisplay({pfile: p1.pfile, pmin: p0.pmax, pmax: p1.pmin});
					var p0 = r.ptp.posFull;
					p0 = {pfile: p0.pfile, pmin: p0.pmin, pmax: p0.pmax + (r.ptp.path.tparams.length == 0 ? 1 : 0)};
					acc.unshift(HImplements(r.ptp));
					return loop(hadDisplay || r.b, p0, acc);
				case BrOpen:
					var p1 = tk.pos;
					s.junk();
					checkDisplay({pfile: p1.pfile, pmin: p0.pmax, pmax: p1.pmin});
					var l = acc.copy();
					l.reverse();
					return l;
				case _:
					switch tk.token {
						case Const(Ident(name)) if (DisplayPosition.displayPosition.enclosedIn(tk.pos)):
							return Parser.syntaxCompletion(n.indexOf(HInterface) >= 0 ? SCInterfaceRelation : SCClassRelation, name,
								tk.pos);
						case _:
							checkDisplay({pfile: p1.pfile, pmin: p0.pmax, pmax: Parser.nextPos(ctx, s).pmax});
							var l = acc.copy();
							l.reverse();
							return Parser.syntaxError(ctx, Expected(["extends", "implements", "{"]), s, l);
					}
			}
		}
		var hl = loop(false, Parser.lastPos(ctx, s), []);
		var r = parseClassFields(ctx, false, p1, s);
		var cflags:Array<ClassFlag> = [];
		for (f in flags) {
			var c = Parser.declFlagToClassFlag(ctx, f);
			if (c != null) cflags.push(c);
		}
		return {
			definition: EClass({
				name: name,
				doc: docFromStringOpt(doc),
				meta: meta,
				params: Vector.fromArrayCopy(tl),
				flags: Vector.fromArrayCopy(cflags.concat(n).concat(hl)),
				data: Vector.fromArrayCopy(r.fields)
			}),
			pos: punion(p1, r.pos)
		};
	}

	static function moduleFieldFlags(ctx:ParserContext, c:Array<{flag:DeclFlag, pos:Pos}>):Array<PlacedAccess> {
		var out = [];
		for (f in c) {
			var a = Parser.declFlagToModuleFieldFlag(ctx, f);
			if (a != null) out.push(a);
		}
		return out;
	}

	static function parseTypeDecl(ctx:ParserContext, mode:TypeDeclCompletionMode, s:S):TypeDecl {
		var tk = peek(s);
		switch tk.token {
			case Kwd(Import):
				s.junk();
				return parseImport(ctx, s, tk.pos);
			case Kwd(Using):
				s.junk();
				return parseUsing(ctx, s, tk.pos);
			case _:
		}
		var doc = Parser.getDoc(ctx, s);
		var meta = parseMeta(ctx, s);
		var c = parseCommonFlags(s);
		var tk = peek(s);
		switch tk.token {
			case Kwd(Function):
				var p1 = tk.pos;
				s.junk();
				var name = tail(function() return dollarIdent(s));
				var pl = tail(function() return parseConstraintParams(ctx, s));
				expectTok(s, POpen);
				var args = tail(function() return psepTrailing(Comma, function(s) return parseFunParam(ctx, s), s));
				expectTok(s, PClose);
				var t = tail(function() return popt(function(s) return parseTypeHint(ctx, s), s));
				var e:Null<Expr>, p2:Pos;
				var r = tryHead(function() return expr(ctx, s));
				if (r != null) {
					semicolon(ctx, s);
					e = r.v;
					p2 = r.v.pos;
				} else {
					var r2 = tryHead(function() return semicolon(ctx, s));
					if (r2 == null) serror();
					e = null;
					p2 = r2.v;
				}
				var f:Func = {
					fParams: Vector.fromArrayCopy(pl),
					fArgs: Vector.fromArrayCopy(args),
					fType: t,
					fExpr: e
				};
				return {
					definition: EStatic({
						name: name,
						doc: docFromStringOpt(doc),
						meta: meta,
						params: Vector.fromArrayCopy(pl),
						flags: Vector.fromArrayCopy(moduleFieldFlags(ctx, c)),
						data: FFun(f)
					}),
					pos: punion(p1, p2)
				};
			case Kwd(Var):
				var p1 = tk.pos;
				s.junk();
				var name = tail(function() return dollarIdent(s));
				var p2:Pos, t:ClassFieldKind;
				if (isTok(s, POpen)) {
					s.junk();
					var i1 = tail(function() return propertyIdent(s));
					expectTok(s, Comma);
					var i2 = tail(function() return propertyIdent(s));
					expectTok(s, PClose);
					var th = popt(function(s) return parseTypeHint(ctx, s), s);
					var r = parseVarFieldAssignment(ctx, s);
					p2 = r.pos;
					t = FProp(i1, i2, th, r.e);
				} else {
					var th = popt(function(s) return parseTypeHint(ctx, s), s);
					var r = parseVarFieldAssignment(ctx, s);
					p2 = r.pos;
					t = FVar(th, r.e);
				}
				return {
					definition: EStatic({
						name: name,
						doc: docFromStringOpt(doc),
						meta: meta,
						params: vector(),
						flags: Vector.fromArrayCopy(moduleFieldFlags(ctx, c)),
						data: t
					}),
					pos: punion(p1, p2)
				};
			case Kwd(Enum):
				var p1 = tk.pos;
				s.junk();
				var tk2 = peek(s);
				switch tk2.token {
					case Kwd(Abstract):
						var p1 = tk2.pos;
						s.junk();
						var r = tail(function() return parseAbstract(ctx, doc, meta, [AbEnum].concat(Parser.convertAbstractFlags(ctx, c)),
							p1, s));
						return {definition: EAbstract(r.d), pos: r.p};
					case _:
						var name = typeName(ctx, s);
						var tl = tail(function() return parseConstraintParams(ctx, s));
						expectTok(s, BrOpen);
						var l = tail(function() return plist(function(s) return parseEnum(ctx, s), s));
						var p2 = expectTok(s, BrClose);
						var eflags = [];
						for (f in c) {
							var ef = Parser.declFlagToEnumFlag(ctx, f);
							if (ef != null) eflags.push(ef);
						}
						return {
							definition: EEnum({
								name: name,
								doc: docFromStringOpt(doc),
								meta: meta,
								params: Vector.fromArrayCopy(tl),
								flags: Vector.fromArrayCopy(eflags),
								data: Vector.fromArrayCopy(l)
							}),
							pos: punion(p1, p2)
						};
				}
			case Kwd(Class) | Kwd(Interface):
				var cf = parseClassFlags(s);
				return parseClassContent(ctx, doc, meta, c, cf.flags, cf.pos, s);
			case Kwd(Typedef):
				var p1 = tk.pos;
				s.junk();
				var name = tail(function() return typeName(ctx, s));
				var tl = tail(function() return parseConstraintParams(ctx, s));
				var p2 = expectBinop(s, OpAssign);
				var t = tail(function() return parseComplexTypeAt(ctx, p2, s));
				acceptTok(s, Semicolon);
				var tflags = [];
				for (f in c) {
					var tf = Parser.declFlagToTypedefFlag(ctx, f);
					if (tf != null) tflags.push(tf);
				}
				return {
					definition: ETypedef({
						name: name,
						doc: docFromStringOpt(doc),
						meta: meta,
						params: Vector.fromArrayCopy(tl),
						flags: Vector.fromArrayCopy(tflags),
						data: t
					}),
					pos: punion(p1, t.pos)
				};
			case Kwd(Abstract):
				var p1 = tk.pos;
				s.junk();
				var r = tryHead(function() return parseAbstract(ctx, doc, meta, Parser.convertAbstractFlags(ctx, c), p1, s));
				if (r != null) return {definition: EAbstract(r.v.d), pos: r.v.p};
				var c2 = parseCommonFlags(s);
				var r2 = tryHead(function() return parseClassFlags(s));
				if (r2 != null) return parseClassContent(ctx, doc, meta, c.concat(c2), [HAbstract].concat(r2.v.flags), p1, s);
				return serror();
			case _:
				var rc = c.copy();
				rc.reverse();
				if (rc.length > 0 && rc[0].flag == DFinal) {
					var p1 = rc[0].pos;
					var crest = rc.slice(1);
					var r = tryHead(function() return dollarIdent(s));
					if (r != null) {
						var name = r.v;
						var t = tail(function() return popt(function(s) return parseTypeHint(ctx, s), s));
						var a = tail(function() return parseVarFieldAssignment(ctx, s));
						crest.reverse();
						return {
							definition: EStatic({
								name: name,
								doc: docFromStringOpt(doc),
								meta: meta,
								params: vector(),
								flags: Vector.fromArrayCopy(moduleFieldFlags(ctx, crest)).snoc({access: AFinal, pos: p1}),
								data: FVar(t, a.e)
							}),
							pos: punion(p1, a.pos)
						};
					}
					Parser.checkTypeDeclFlagCompletion(ctx, mode, c, s);
					return fail();
				}
				if (meta.length > 0) Parser.syntaxError(ctx, Custom("Type or field expected after metadata"), s, null, meta[0].pos);
				Parser.checkTypeDeclFlagCompletion(ctx, mode, c, s);
				return fail();
		}
	}

	static function parseClass(ctx:ParserContext, doc:Documentation, meta:Metadata, cflags:Array<{flag:ClassFlag, pos:Pos}>,
			needName:Bool, s:S):TypeDecl {
		var optName:S->PlacedName = needName ? function(s) return typeName(ctx, s) : function(s) {
			var n = popt(function(s) return typeName(ctx, s), s);
			return n == null ? pn("", Globals.nullPos) : n;
		};
		var cf = parseClassFlags(s);
		var name = tail(function() return optName(s));
		var tl = tail(function() return parseConstraintParams(ctx, s));
		var hl = tail(function() return plist(function(s) return parseClassHerit(ctx, s), s));
		expectTok(s, BrOpen);
		var r = tail(function() return parseClassFields(ctx, !needName, cf.pos, s));
		return {
			definition: EClass({
				name: name,
				doc: doc,
				meta: meta,
				params: Vector.fromArrayCopy(tl),
				flags: Vector.fromArrayCopy([for (f in cflags) f.flag].concat(cf.flags).concat(hl)),
				data: Vector.fromArrayCopy(r.fields)
			}),
			pos: punion(cf.pos, r.pos)
		};
	}

	static function parseImport2(ctx:ParserContext, s:S, p1:Pos):Import {
		function loop(pn0:Pos, acc:Array<PlacedName>):Import {
			var tk = peek(s);
			switch tk.token {
				case Dot:
					var p = tk.pos;
					s.junk();
					function resume():Void {
						Parser.typePath([for (a in acc) a.name], true, punion(pn0, p));
					}
					Parser.checkResume(ctx, p, resume, function() {});
					var tk2 = peek(s);
					switch tk2.token {
						case Const(Ident(k)):
							s.junk();
							return loop(pn0, [pn(k, tk2.pos)].concat(acc));
						case Kwd(Macro):
							s.junk();
							return loop(pn0, [pn("macro", tk2.pos)].concat(acc));
						case Kwd(Extern):
							s.junk();
							return loop(pn0, [pn("extern", tk2.pos)].concat(acc));
						case Kwd(Function):
							s.junk();
							return loop(pn0, [pn("function", tk2.pos)].concat(acc));
						case Binop(OpMult):
							s.junk();
							var l = acc.copy();
							l.reverse();
							return {path: Vector.fromArrayCopy(l), mode: IAll};
						case _:
							popt(function(s) return semicolon(ctx, s), s);
							var l = acc.copy();
							l.reverse();
							return Parser.syntaxError(ctx, Expected(["identifier"]), s, ({path: Vector.fromArrayCopy(l), mode: INormal} : core.Ast.Import));
					}
				case Kwd(In):
					s.junk();
					var tk2 = peek(s);
					switch tk2.token {
						case Const(Ident(name)):
							s.junk();
							var l = acc.copy();
							l.reverse();
							return {path: Vector.fromArrayCopy(l), mode: IAsName(pn(name, tk2.pos))};
						case _:
							return serror();
					}
				case Const(Ident("as")):
					s.junk();
					var tk2 = peek(s);
					switch tk2.token {
						case Const(Ident(name)):
							s.junk();
							var l = acc.copy();
							l.reverse();
							return {path: Vector.fromArrayCopy(l), mode: IAsName(pn(name, tk2.pos))};
						case _:
							return serror();
					}
				case _:
					var l = acc.copy();
					l.reverse();
					return {path: Vector.fromArrayCopy(l), mode: INormal};
			}
		}
		var tk = peek(s);
		return switch tk.token {
			case Const(Ident(name)):
				s.junk();
				loop(tk.pos, [pn(name, tk.pos)]);
			case _:
				if (Parser.wouldSkipDisplayPosition(ctx, p1, true,
					s)) ({path: vector(), mode: INormal} : core.Ast.Import) else Parser.syntaxError(ctx, Expected(["identifier"]), s,
					({path: vector(), mode: INormal} : core.Ast.Import));
		}
	}

	static function parseImport(ctx:ParserContext, s:S, p1:Pos):TypeDecl {
		var imp = parseImport2(ctx, s, p1);
		var p2 = acceptTok(s, Semicolon);
		if (p2 == null) {
			p2 = if (Parser.wouldSkipDisplayPosition(ctx, p1, true,
				s)) DisplayPosition.displayPosition.withPos(p1) else Parser.syntaxError(ctx, Expected([".", ";", "as"]), s,
				Parser.lastPos(ctx, s));
		}
		return {definition: EImport(imp), pos: punion(p1, p2)};
	}

	static function parseUsing2(ctx:ParserContext, s:S, p1:Pos):Array<PlacedName> {
		function loop(pn0:Pos, acc:Array<PlacedName>):Array<PlacedName> {
			var tk = peek(s);
			switch tk.token {
				case Dot:
					var p = tk.pos;
					s.junk();
					Parser.checkResume(ctx, p, function() {
						Parser.typePath([for (a in acc) a.name], false, punion(pn0, p));
					}, function() {});
					var tk2 = peek(s);
					switch tk2.token {
						case Const(Ident(k)):
							s.junk();
							return loop(pn0, [pn(k, tk2.pos)].concat(acc));
						case Kwd(Macro):
							s.junk();
							return loop(pn0, [pn("macro", tk2.pos)].concat(acc));
						case Kwd(Extern):
							s.junk();
							return loop(pn0, [pn("extern", tk2.pos)].concat(acc));
						case Kwd(Function):
							s.junk();
							return loop(pn0, [pn("function", tk2.pos)].concat(acc));
						case _:
							var l = acc.copy();
							l.reverse();
							return Parser.syntaxError(ctx, Expected(["identifier"]), s, l);
					}
				case _:
					var l = acc.copy();
					l.reverse();
					return l;
			}
		}
		var tk = peek(s);
		return switch tk.token {
			case Const(Ident(name)):
				s.junk();
				loop(tk.pos, [pn(name, tk.pos)]);
			case _:
				if (Parser.wouldSkipDisplayPosition(ctx, p1, true, s)) [] else Parser.syntaxError(ctx, Expected(["identifier"]), s, []);
		}
	}

	static function parseUsing(ctx:ParserContext, s:S, p1:Pos):TypeDecl {
		var path = parseUsing2(ctx, s, p1);
		var p2 = acceptTok(s, Semicolon);
		if (p2 == null) {
			p2 = if (Parser.wouldSkipDisplayPosition(ctx, p1, true,
				s)) DisplayPosition.displayPosition.withPos(p1) else
				Parser.syntaxError(ctx, Expected([".", ";"]), s, Parser.lastPos(ctx, s));
		}
		return {definition: EUsing(Vector.fromArrayCopy(path)), pos: punion(p1, p2)};
	}

	static function parseAbstractRelations(ctx:ParserContext, s:S):AbstractFlag {
		function checkDisplay(p1:Pos, t:TypeHint):TypeHint {
			if (ctx.config.inDisplayFile
				&& p1.pmax < DisplayPosition.displayPosition.get().pmin
				&& t.pos.pmin >= DisplayPosition.displayPosition.get().pmax)
				// This means we skipped the display position between the to/from and the type-hint we parsed.
				// Very weird case, it was probably a {} like in #7137. Let's discard it and use magic.
				return Parser.magicTypeTh(DisplayPosition.displayPosition.withPos(t.pos));
			return t;
		}
		var tk = peek(s);
		return switch tk.token {
			case Const(Ident("to")):
				s.junk();
				var t = tail(function() return parseComplexTypeAt(ctx, tk.pos, s));
				AbTo(checkDisplay(tk.pos, t));
			case Const(Ident("from")):
				s.junk();
				var t = tail(function() return parseComplexTypeAt(ctx, tk.pos, s));
				AbFrom(checkDisplay(tk.pos, t));
			case _: fail();
		}
	}

	static function parseAbstractSubtype(ctx:ParserContext, s:S):Null<TypeHint> {
		if (isTok(s, POpen)) {
			s.junk();
			var t = tail(function() return parseComplexType(ctx, s));
			expectTok(s, PClose);
			return t;
		}
		return null;
	}

	static function parsePackage(s:S):Array<String> return psep(Dot, lowerIdentOrMacro, s);

	static function resume(ctx:ParserContext, tdecl:Bool, fdecl:Bool, s:S):Bool {
		// look for next variable/function or next type declaration
		function junk(k:Int) {
			while (k > 0) {
				s.junk();
				k--;
			}
		}
		function revTokens(k:Int):Array<Token> {
			var l = [for (t in s.npeek(k)) t.token];
			l.reverse();
			return l;
		}
		function isIdentOrKwd(t:Token):Bool return switch t {
			case Const(Ident(_)) | Kwd(_): true;
			case _: false;
		}
		// walk back tokens which are prefixing a type/field declaration
		function junkTokens(k:Int):Void {
			if (k == 0) return;
			var l = revTokens(k);
			if (l.length > 0 && l[0].match(Kwd(Private))) return junkTokens(k - 1);
			if (l.length >= 3 && isIdentOrKwd(l[0]) && l[1] == DblDot && l[2] == At) return junkTokens(l.length - 3);
			if (l.length >= 2 && isIdentOrKwd(l[0]) && l[1] == At) return junkTokens(l.length - 2);
			if (l.length > 0 && l[0] == PClose) {
				// count matching parenthesises for metadata call
				function loop(n:Int, l:Array<Token>):Array<Token> {
					var i = 0;
					while (i < l.length) {
						switch l[i] {
							case POpen:
								if (n == 0) return l.slice(i + 1);
								n--;
							case PClose:
								n++;
							case _:
						}
						i++;
					}
					return [];
				}
				var r = loop(0, l.slice(1));
				if (r.length >= 2 && isIdentOrKwd(r[0]) && r[1] == At) return junkTokens(r.length - 2);
				if (r.length >= 3 && isIdentOrKwd(r[0]) && r[1] == DblDot && r[2] == At) return junkTokens(r.length - 3);
				junk(k);
				return;
			}
			junk(k);
		}
		var k = 1;
		while (true) {
			var l = revTokens(k);
			if (l.length == 0) return false;
			// metadata
			if (l.length >= 2 && l[0].match(Kwd(_)) && l[1] == At) {
				k++;
				continue;
			}
			if (l.length >= 3 && l[0].match(Kwd(_)) && l[1] == DblDot && l[2] == At) {
				k++;
				continue;
			}
			// field declaration
			if (fdecl && l.length >= 2 && (l[0].match(Const(_)) || l[0].match(Kwd(New))) && l[1].match(Kwd(Function))) {
				junkTokens(k - 2);
				return true;
			}
			if (fdecl && switch l[0] {
					case Kwd(Macro | Public | Static | Var | Final | Override | Dynamic | Inline | Overload): true;
					case _: false;
				}) {
				junkTokens(k - 1);
				return true;
				}
			if (tdecl && l[0] == BrClose) {
				junkTokens(k - 1);
				return false;
			}
			// type declaration
			switch l[0] {
				case Eof | Kwd(Import | Using | Extern | Class | Interface | Enum | Typedef | Abstract):
					junkTokens(k - 1);
					return false;
				case _:
			}
			k++;
		}
	}

	static function parseClassFieldResume(ctx:ParserContext, acc:Array<ClassField>, tdecl:Bool, s:S):{fields:Array<ClassField>, pos:Pos} {
		while (true) {
			var result:DeclResult<ClassField>;
			try {
				var r = tryHead(function() return parseClassField(ctx, tdecl, s));
				if (r != null) result = DSuccess(r.v)
				else {
					var tk = peek(s);
					if (tk.token == BrClose) {
						s.junk();
						result = DEnd(tk.pos);
					} else result = DError("Parse error.");
				}
			} catch (e:StreamError) {
				result = DError(e.message);
			}
			switch result {
				case DSuccess(cff):
					acc.push(cff);
				case DEnd(p):
					return {fields: acc, pos: p};
				case DError(msg):
					Parser.handleStreamError(ctx, msg, s);
					if (!resume(ctx, tdecl, true, s)) {
						// port: upstream returns the (reversed) accumulator here
						var l = acc.copy();
						l.reverse();
						return {fields: l, pos: Parser.lastPos(ctx, s)};
					}
			}
		}
	}

	static function parseClassFields(ctx:ParserContext, tdecl:Bool, p1:Pos, s:S):{fields:Array<ClassField>, pos:Pos} {
		if (!ctx.config.inDisplayFile) {
			var acc = plist(function(s) return parseClassField(ctx, tdecl, s), s);
			var p2 = acceptTok(s, BrClose);
			if (p2 == null) p2 = Parser.error(Expected(["}"]), Parser.nextPos(ctx, s));
			return {fields: acc, pos: p2};
		} else return parseClassFieldResume(ctx, [], tdecl, s);
	}

	static function parseCommonFlags(s:S):Array<{flag:DeclFlag, pos:Pos}> {
		var acc = [];
		while (true) {
			var tk = peek(s);
			var f = switch tk.token {
				case Kwd(Private): DPrivate;
				case Kwd(Extern): DExtern;
				case Kwd(Final): DFinal;
				case Kwd(Macro): DMacro;
				case Kwd(Dynamic): DDynamic;
				case Kwd(Inline): DInline;
				case Kwd(Public): DPublic;
				case Kwd(Static): DStatic;
				case Kwd(Overload): DOverload;
				case _: null;
			};
			if (f == null) return acc;
			s.junk();
			acc.push({flag: f, pos: tk.pos});
		}
	}

	static function parseMetaArgumentExpr(ctx:ParserContext, s:S):Expr {
		var e = expr(ctx, s);
		return switch e.expr {
			case EDisplay(e1, DKDot):
				try Parser.typePath(stringListOfExprPathRaise(e1), false, e1.pos) catch (_:core.ds.Exit) e;
			case _:
				e;
		}
	}

	static function parseMetaParams(ctx:ParserContext, pname:Pos, s:S):Vector<Expr> {
		var tk = peek(s);
		switch tk.token {
			case POpen if (tk.pos.pmin == pname.pmax):
				s.junk();
				var params = tail(function() return psepTrailing(Comma, function(s) return parseMetaArgumentExpr(ctx, s), s));
				expectUnlessResumeP(ctx, PClose, s);
				return Vector.fromArrayCopy(params);
			case _:
				return vector();
		}
	}

	static function parseMetaEntry(ctx:ParserContext, s:S):MetadataEntry {
		var tk = peek(s);
		if (tk.token != At) return fail();
		var p1 = tk.pos;
		s.junk();
		var meta:Null<MetadataEntry> = Parser.checkResume(ctx, p1,
			function():MetadataEntry return {meta: StrictMeta.HxCompletion, exprs: vector(), pos: p1}, function() return null);
		var r = tryHead(function() return parseMetaName(ctx, p1, s));
		if (r != null) {
			var params = tail(function() return parseMetaParams(ctx, r.v.pos, s));
			return {meta: r.v.meta, exprs: params, pos: punion(p1, r.v.pos)};
		}
		return meta == null ? serror() : meta;
	}

	static function parseMeta(ctx:ParserContext, s:S):Metadata {
		var acc = [];
		while (true) {
			var r = tryHead(function() return parseMetaEntry(ctx, s));
			if (r == null) return acc;
			acc.push(r.v);
		}
	}

	static function parseMetaName2(ctx:ParserContext, p1:Pos, acc:Array<String>, s:S):{names:Array<String>, pos:Pos} {
		var tk = peek(s);
		var part:String, p:Pos;
		switch tk.token {
			case Const(Ident(i)) if (tk.pos.pmin == p1.pmax):
				s.junk();
				part = i;
				p = tk.pos;
			case Kwd(k) if (tk.pos.pmin == p1.pmax):
				s.junk();
				part = sKeyword(k);
				p = tk.pos;
			case _:
				return fail();
		}
		var acc = [part].concat(acc);
		var tk = peek(s);
		if (tk.token == Dot) {
			s.junk();
			var r = tail(function() return parseMetaName2(ctx, tk.pos, acc, s));
			return {names: r.names, pos: punion(p, r.pos)};
		}
		return {names: acc, pos: punion(p1, p)};
	}

	static function parseMetaName(ctx:ParserContext, p1:Pos, s:S):{meta:StrictMeta, pos:Pos} {
		var tk = peek(s);
		switch tk.token {
			case DblDot if (tk.pos.pmin == p1.pmax):
				var p = tk.pos;
				s.junk();
				var meta:Null<{meta:StrictMeta, pos:Pos}> = Parser.checkResume(ctx, p,
					function() return {meta: StrictMeta.HxCompletion, pos: p}, function() return null);
				var r = tryHead(function() return parseMetaName2(ctx, p, [], s));
				if (r != null) return {meta: core.Meta.parse(Parser.revConcat(".", r.v.names)), pos: r.v.pos};
				return meta == null ? fail() : meta;
			case _:
				var r = parseMetaName2(ctx, p1, [], s);
				return {meta: StrictMeta.Custom(Parser.revConcat(".", r.names)), pos: r.pos};
		}
	}

	static function parseEnumFlags(s:S):{flags:Array<ClassFlag>, pos:Pos} {
		var p = acceptKwd(s, Enum);
		return p == null ? fail() : {flags: [], pos: p};
	}

	static function parseClassFlags(s:S):{flags:Array<ClassFlag>, pos:Pos} {
		var tk = peek(s);
		return switch tk.token {
			case Kwd(Class):
				s.junk();
				{flags: [], pos: tk.pos};
			case Kwd(Interface):
				s.junk();
				{flags: [HInterface], pos: tk.pos};
			case _: fail();
		}
	}

	static function parseComplexTypeAt(ctx:ParserContext, p:Pos, s:S):TypeHint {
		var r = tryHead(function() return parseComplexType(ctx, s));
		if (r != null) return r.v;
		if (Parser.wouldSkipDisplayPosition(ctx, p, false, s)) return Parser.magicTypeTh(DisplayPosition.displayPosition.withPos(p));
		return serror();
	}

	static function parseTypeHint(ctx:ParserContext, s:S):TypeHint {
		var tk = peek(s);
		if (tk.token != DblDot) return fail();
		var p1 = tk.pos;
		s.junk();
		var f = function() return parseComplexTypeAt(ctx, p1, s);
		return Parser.checkResumeRange(ctx, p1, s, function(p2) {
			pignore(f);
			return Parser.magicTypeTh(DisplayPosition.displayPosition.withPos(p1));
		}, f);
	}

	static function parseTypeOpt(ctx:ParserContext, s:S):Null<TypeHint> return popt(function(s) return parseTypeHint(ctx, s), s);

	static function parseComplexType(ctx:ParserContext, s:S):TypeHint return parseComplexTypeMaybeNamed(ctx, false, s);

	static function parseComplexTypeMaybeNamed(ctx:ParserContext, allowNamed:Bool, s:S):TypeHint {
		var tk = peek(s);
		if (tk.token == POpen) {
			var p1 = tk.pos;
			s.junk();
			var tl = tail(function() return psepTrailing(Comma, function(s) return parseComplexTypeMaybeNamed(ctx, true, s), s));
			var p2 = expectTok(s, PClose);
			if (tl.length == 0 || (tl.length == 1 && tl[0].type.match(CTNamed(_, _))))
				// it was () or (a:T) - clearly a new function type syntax, proceed with parsing return type
				return parseFunctionTypeNext(ctx, tl, p1, s);
			if (tl.length == 1) {
				// it was some single unnamed type in parenthesis - use old function type syntax
				var t:TypeHint = {type: CTParent(tl[0]), pos: punion(p1, p2)};
				return parseComplexTypeNext(ctx, t, s);
			}
			// it was multiple arguments - clearly a new function type syntax, proceed with parsing return type
			return parseFunctionTypeNext(ctx, tl, p1, s);
		}
		var t = parseComplexTypeInner(ctx, allowNamed, s);
		return parseComplexTypeNext(ctx, t, s);
	}

	static function parseStructuralExtension(ctx:ParserContext, s:S):PlacedTypePath {
		var p1 = acceptBinop(s, OpGt);
		if (p1 == null) return fail();
		var r = tryHead(function() return parseTypePath(ctx, s));
		if (r != null) {
			var t = r.v;
			if (acceptTok(s, Comma) != null) return t;
			return Parser.syntaxError(ctx, Expected([","]), s, t);
		}
		if (Parser.wouldSkipDisplayPosition(ctx, p1, false, s)) {
			acceptTok(s, Comma);
			var p = DisplayPosition.displayPosition.withPos(p1);
			return makePtp(Parser.magicTypePath, p);
		}
		return fail();
	}

	static function parseComplexTypeInner(ctx:ParserContext, allowNamed:Bool, s:S):TypeHint {
		var tk = peek(s);
		switch tk.token {
			case POpen:
				var p1 = tk.pos;
				s.junk();
				var t = tail(function() return parseComplexType(ctx, s));
				var p2 = expectTok(s, PClose);
				return {type: CTParent(t), pos: punion(p1, p2)};
			case BrOpen:
				var p1 = tk.pos;
				s.junk();
				var r = tryHead(function() return parseTypeAnonymous(ctx, s));
				if (r != null) return {type: CTAnonymous(Vector.fromArrayCopy(r.v.fields)), pos: punion(p1, r.v.pos)};
				var r = tryHead(function() return parseStructuralExtension(ctx, s));
				if (r != null) {
					var tl = [r.v].concat(plist(function(s) return parseStructuralExtension(ctx, s), s));
					var r2 = tryHead(function() return parseTypeAnonymous(ctx, s));
					if (r2 != null) return {type: CTExtend(Vector.fromArrayCopy(tl), Vector.fromArrayCopy(r2.v.fields)), pos: punion(p1, r2.v.pos)};
					var r3 = tryHead(function() return parseClassFields(ctx, true, p1, s));
					if (r3 != null) return {type: CTExtend(Vector.fromArrayCopy(tl), Vector.fromArrayCopy(r3.v.fields)), pos: punion(p1, r3.v.pos)};
					return fail();
				}
				var r = tryHead(function() return parseClassFields(ctx, true, p1, s));
				if (r != null) return {type: CTAnonymous(Vector.fromArrayCopy(r.v.fields)), pos: punion(p1, r.v.pos)};
				return serror();
			case Question:
				var p1 = tk.pos;
				s.junk();
				var t = tail(function() return parseComplexTypeInner(ctx, allowNamed, s));
				return {type: CTOptional(t), pos: punion(p1, t.pos)};
			case Spread:
				var p1 = tk.pos;
				s.junk();
				var t = tail(function() return parseComplexTypeInner(ctx, allowNamed, s));
				var hint = switch t.type {
					case CTNamed(_, hint): hint;
					case _: t;
				};
				var p = punion(p1, t.pos);
				return {type: CTPath(makePtp(mkTypePath(["haxe"], "Rest", vector(TPType(hint))), p)), pos: p};
			case Kwd(Default):
				s.junk();
				return {type: CTPath(makePtp(mkTypePath(["$"], "_hx_default"), tk.pos)), pos: tk.pos};
			case _:
		}
		var r = tryHead(function() return dollarIdent(s));
		if (r != null) {
			var n = r.v;
			var tk = peek(s);
			if (tk.token == DblDot && allowNamed) {
				s.junk();
				var t = tail(function() return parseComplexType(ctx, s));
				var p1 = n.pos;
				var p2 = t.pos;
				return {type: CTNamed(n, t), pos: punion(p1, p2)};
			}
			var ptp = parseTypePath2(ctx, null, [], n.name, n.pos, s);
			return {type: CTPath(ptp), pos: ptp.posFull};
		}
		var ptp = parseTypePath(ctx, s);
		return {type: CTPath(ptp), pos: ptp.posFull};
	}

	static function parseTypePath(ctx:ParserContext, s:S):PlacedTypePath return parseTypePath1(ctx, null, [], s);

	static function parseTypePath1(ctx:ParserContext, p0:Null<Pos>, pack:Array<String>, s:S):PlacedTypePath {
		var n = dollarIdentMacro(pack, s);
		return parseTypePath2(ctx, p0, pack, n.name, n.pos, s);
	}

	// port: pack is in reverse order (head = innermost), as upstream.
	static function parseTypePath2(ctx:ParserContext, p0:Null<Pos>, pack:Array<String>, name:String, p1:Pos, s:S):PlacedTypePath {
		inline function revPack(l:Array<String>):Array<String> {
			var r = l.copy();
			r.reverse();
			return r;
		}
		inline function checkDisplay(f:Void->PlacedTypePath):PlacedTypePath {
			var p = p0 == null ? p1 : punion(p0, p1);
			if (ctx.config.inDisplayFile
				&& DisplayPosition.displayPosition.enclosedIn(p)) return makePtp(mkTypePath(revPack(pack), name), p);
			return f();
		}
		if (isLowerIdent(name)) {
			var tk = peek(s);
			switch tk.token {
				case Dot:
					var p = tk.pos;
					s.junk();
					return Parser.checkResume(ctx, p,
						function() return throw new TypePathCompletion(revPack([name].concat(pack)), null, false,
							punion(p0 == null ? p1 : p0, p)),
						function() return parseTypePath1(ctx, p0 == null ? p1 : p0, [name].concat(pack), s));
				case Semicolon:
					s.junk();
					return checkDisplay(function() return Parser.error(Custom("Type name should start with an uppercase letter"), p1));
				case _:
					return checkDisplay(serror);
			}
		}
		var sub:Null<String>, p2:Pos;
		var tk = peek(s);
		if (tk.token == Dot) {
			var p = tk.pos;
			s.junk();
			var r = Parser.checkResume(ctx, p,
				function() return throw new TypePathCompletion(revPack(pack), {name: name, isSub: false}, false,
					punion(p0 == null ? p1 : p0, p)),
				function() {
					var tk2 = peek(s);
					return switch tk2.token {
						case Const(Ident(name)) if (!isLowerIdent(name)):
							s.junk();
							{sub: name, p2: tk2.pos};
						case _:
							serror();
					}
				});
			sub = r.sub;
			p2 = r.p2;
		} else {
			sub = null;
			p2 = p1;
		}
		var p1 = p0 == null ? p1 : p0;
		var pPath = punion(p1, p2);
		var params:Array<TypeParamOrConst>;
		var plt = acceptBinop(s, OpLt);
		if (plt != null) {
			var l = tail(function() return psep(Comma, function(s) return parseTypePathOrConst(ctx, plt, s), s));
			var pgt = acceptBinop(s, OpGt);
			if (pgt != null) {
				params = l;
				p2 = pgt;
			} else {
				var r = Parser.syntaxError(ctx, Expected([">"]), s, {l: l, p: Parser.lastToken(ctx, s).pos});
				params = r.l;
				p2 = r.p;
			}
		} else params = [];
		var tp = mkTypePath(revPack(pack), name, Vector.fromArrayCopy(params), sub);
		var pFull = punion(p1, p2);
		return makePtp(tp, pFull, pPath);
	}

	static function typeName(ctx:ParserContext, s:S):PlacedName {
		var tk = peek(s);
		return switch tk.token {
			case Const(Ident(name)):
				s.junk();
				if (isLowerIdent(name)) Parser.syntaxError(ctx, Custom("Type name should start with an uppercase letter"), s,
					pn(name, tk.pos), tk.pos) else pn(name, tk.pos);
			case Dollar(name):
				s.junk();
				pn("$" + name, tk.pos);
			case _: fail();
		}
	}

	static function parseTypePathOrConst(ctx:ParserContext, plt:Pos, s:S):TypeParamOrConst {
		// we can't allow (expr) here
		var tk = peek(s);
		if (tk.token == BkOpen) {
			s.junk();
			var e = tail(function() return parseArrayDecl(ctx, tk.pos, s));
			return TPExpr(e);
		}
		var r = tryHead(function() return parseComplexType(ctx, s));
		if (r != null) return TPType(r.v);
		var tk = peek(s);
		switch tk.token {
			case Unop(op):
				s.junk();
				var tk2 = peek(s);
				return switch tk2.token {
					case Const(c):
						s.junk();
						TPExpr(Parser.makeUnop(op, mk(EConst(c), tk2.pos), tk.pos));
					case _: serror();
				}
			case Binop(OpSub):
				s.junk();
				var tk2 = peek(s);
				return switch tk2.token {
					case Const(c):
						s.junk();
						TPExpr(Parser.makeUnop(Neg, mk(EConst(c), tk2.pos), tk.pos));
					case _: serror();
				}
			case Const(c):
				s.junk();
				return TPExpr(mk(EConst(c), tk.pos));
			case Kwd(True):
				s.junk();
				return TPExpr(mk(EConst(Ident("true")), tk.pos));
			case Kwd(False):
				s.junk();
				return TPExpr(mk(EConst(Ident("false")), tk.pos));
			case _:
		}
		var r = tryHead(function() return expr(ctx, s));
		if (r != null) return TPExpr(r.v);
		if (ctx.config.inDisplayFile) {
			if (Parser.wouldSkipDisplayPosition(ctx, plt, false,
				s)) return TPType(Parser.magicTypeTh(DisplayPosition.displayPosition.withPos(plt)));
			return fail();
		}
		return serror();
	}

	static function parseComplexTypeNext(ctx:ParserContext, t:TypeHint, s:S):TypeHint {
		inline function makeFun(t2:ComplexType, p2:Pos):TypeHint {
			return switch t2 {
				case CTFunction(args, r): {type: CTFunction(VectorTools.cons(t, args), r), pos: punion(t.pos, p2)};
				case _: {type: CTFunction(vector(t), {type: t2, pos: p2}), pos: punion(t.pos, p2)};
			}
		}
		inline function makeIntersection(t2:ComplexType, p2:Pos):TypeHint {
			return switch t2 {
				case CTIntersection(tl): {type: CTIntersection(VectorTools.cons(t, tl)), pos: punion(t.pos, p2)};
				case _: {type: CTIntersection(vector(t, {type: t2, pos: p2})), pos: punion(t.pos, p2)};
			}
		}
		var tk = peek(s);
		switch tk.token {
			case Arrow:
				var pa = tk.pos;
				s.junk();
				var r = tryHead(function() return parseComplexType(ctx, s));
				if (r != null) return makeFun(r.v.type, r.v.pos);
				if (Parser.wouldSkipDisplayPosition(ctx, pa, false, s)) {
					var p = DisplayPosition.displayPosition.withPos(pa);
					return makeFun(Parser.magicTypeCt(p), p);
				}
				return serror();
			case Binop(OpAnd):
				var pa = tk.pos;
				s.junk();
				var r = tryHead(function() return parseComplexType(ctx, s));
				if (r != null) return makeIntersection(r.v.type, r.v.pos);
				if (Parser.wouldSkipDisplayPosition(ctx, pa, false, s)) {
					var p = DisplayPosition.displayPosition.withPos(pa);
					return makeIntersection(Parser.magicTypeCt(p), p);
				}
				return serror();
			case _:
				return t;
		}
	}

	static function parseFunctionTypeNext(ctx:ParserContext, tl:Array<TypeHint>, p1:Pos, s:S):TypeHint {
		var tk = peek(s);
		if (tk.token != Arrow) return serror();
		var pa = tk.pos;
		s.junk();
		var r = tryHead(function() return parseComplexTypeInner(ctx, false, s));
		if (r != null) return {type: CTFunction(Vector.fromArrayCopy(tl), r.v), pos: punion(p1, r.v.pos)};
		if (Parser.wouldSkipDisplayPosition(ctx, pa, false, s)) {
			var ct = Parser.magicTypeTh(DisplayPosition.displayPosition.withPos(pa));
			return {type: CTFunction(Vector.fromArrayCopy(tl), ct), pos: punion(p1, pa)};
		}
		return serror();
	}

	static function parseTypeAnonymous(ctx:ParserContext, s:S):{fields:Array<ClassField>, pos:Pos} {
		var p0 = popt(questionMark, s);
		var r = tryHead(function() return dollarIdent(s));
		if (r == null) return p0 == null ? fail() : serror();
		var name = r.v.name;
		var p1 = r.v.pos;
		var t = tail(function() return parseTypeHint(ctx, s));
		var opt = p0 != null;
		if (opt) p1 = punion(p0, p1);
		var p2 = Parser.lastToken(ctx, s).pos;
		inline function next(acc:Array<ClassField>):Array<ClassField> {
			return ([
				{
					cffName: pn(name, p1),
					cffMeta: opt ? ([{meta: StrictMeta.Optional, exprs: vector(), pos: Globals.nullPos}] : Array<MetadataEntry>) : [],
					cffAccess: [],
					cffDoc: null,
					cffKind: FVar(t, null),
					cffPos: punion(p1, p2)
				}
			] : Array<ClassField>).concat(acc);
		}
		var tk = peek(s);
		switch tk.token {
			case BrClose:
				s.junk();
				return {fields: next([]), pos: tk.pos};
			case Comma:
				s.junk();
				var tk2 = peek(s);
				if (tk2.token == BrClose) {
					s.junk();
					return {fields: next([]), pos: tk2.pos};
				}
				var r2 = tryHead(function() return parseTypeAnonymous(ctx, s));
				if (r2 != null) return {fields: next(r2.v.fields), pos: punion(p1, r2.v.pos)};
				return serror();
			case _:
				return Parser.syntaxError(ctx, Expected([",", "}"]), s, {fields: next([]), pos: p2});
		}
	}

	static function parseEnum(ctx:ParserContext, s:S):EnumConstructor {
		var doc = Parser.getDoc(ctx, s);
		var meta = parseMeta(ctx, s);
		var n = ident(s);
		var params = tail(function() return parseConstraintParams(ctx, s));
		var args = if (isTok(s, POpen)) {
			s.junk();
			var l = tail(function() return psepTrailing(Comma, function(s) return parseEnumParam(ctx, s), s));
			expectTok(s, PClose);
			l;
		} else [];
		var t = popt(function(s) return parseTypeHint(ctx, s), s);
		var r = tryHead(function() return semicolon(ctx, s));
		var p2 = r == null ? serror() : r.v;
		return {
			ecName: n,
			ecDoc: docFromStringOpt(doc),
			ecMeta: meta,
			ecArgs: Vector.fromArrayCopy(args),
			ecParams: Vector.fromArrayCopy(params),
			ecType: t,
			ecPos: punion(n.pos, p2)
		};
	}

	static function parseEnumParam(ctx:ParserContext, s:S):EnumConstructorArg {
		if (isTok(s, Question)) {
			s.junk();
			var n = tail(function() return ident(s));
			var t = tail(function() return parseTypeHint(ctx, s));
			return {name: n.name, optional: true, type: t};
		}
		var n = ident(s);
		var t = tail(function() return parseTypeHint(ctx, s));
		return {name: n.name, optional: false, type: t};
	}

	static function parseFunctionField(ctx:ParserContext, doc:Null<String>, meta:Metadata, al:Array<PlacedAccess>, s:S):FieldParts {
		var p1 = acceptKwd(s, Function);
		if (p1 == null) return fail();
		var name = tail(function() return parseFunName(s));
		var pl = tail(function() return parseConstraintParams(ctx, s));
		expectTok(s, POpen);
		var args = tail(function() return psepTrailing(Comma, function(s) return parseFunParam(ctx, s), s));
		expectTok(s, PClose);
		var t = tail(function() return popt(function(s) return parseTypeHint(ctx, s), s));
		var e:Null<Expr>, p2:Pos;
		var r = tryHead(function() return expr(ctx, s));
		if (r != null) {
			semicolon(ctx, s);
			e = r.v;
			p2 = r.v.pos;
		} else {
			var r2 = tryHead(function() return semicolon(ctx, s));
			if (r2 == null) serror();
			e = null;
			p2 = r2.v;
		}
		var f:Func = {
			fParams: Vector.fromArrayCopy(pl),
			fArgs: Vector.fromArrayCopy(args),
			fType: t,
			fExpr: e
		};
		return {
			name: name,
			pos: punion(p1, p2),
			kind: FFun(f),
			access: al,
			meta: meta
		};
	}

	static function parseVarFieldAssignment(ctx:ParserContext, s:S):{e:Null<Expr>, pos:Pos} {
		if (acceptBinop(s, OpAssign) != null) {
			var plt = acceptBinop(s, OpLt);
			if (plt != null) {
				var e = Parser.handleXmlLiteral(ctx, plt);
				// accept but don't expect semicolon
				var p2 = acceptTok(s, Semicolon);
				return {e: e, pos: p2 != null ? p2 : e.pos};
			}
			var r = tryHead(function() return expr(ctx, s));
			if (r != null) {
				var p2 = tail(function() return semicolon(ctx, s));
				return {e: r.v, pos: p2};
			}
			return serror();
		}
		var r = tryHead(function() return semicolon(ctx, s));
		if (r != null) return {e: null, pos: r.v};
		return serror();
	}

	static function parseClassField(ctx:ParserContext, tdecl:Bool, s:S):ClassField {
		var doc = Parser.getDoc(ctx, s);
		var meta = parseMeta(ctx, s);
		var al = plist(parseCfRights, s);
		inline function checkOptional(opt:Bool, name:PlacedName):Metadata {
			if (opt) {
				if (!tdecl) Parser.syntaxError(ctx, Custom("?var syntax is only allowed in structures"), s, null, name.pos);
				return ([{meta: StrictMeta.Optional, exprs: vector(), pos: Globals.nullPos}] : Array<core.Ast.MetadataEntry>).concat(meta);
			}
			return meta;
		}
		var parts:FieldParts;
		var tk = peek(s);
		switch tk.token {
			case Kwd(Var):
				var p1 = tk.pos;
				s.junk();
				var q = tail(function() return questionableDollarIdent(ctx, s));
				var meta = checkOptional(q.opt, q.name);
				if (isTok(s, POpen)) {
					s.junk();
					var i1 = tail(function() return propertyIdent(s));
					expectTok(s, Comma);
					var i2 = tail(function() return propertyIdent(s));
					expectTok(s, PClose);
					var t = popt(function(s) return parseTypeHint(ctx, s), s);
					var a = parseVarFieldAssignment(ctx, s);
					parts = {
						name: q.name,
						pos: punion(p1, a.pos),
						kind: FProp(i1, i2, t, a.e),
						access: al,
						meta: meta
					};
				} else {
					var t = popt(function(s) return parseTypeHint(ctx, s), s);
					var a = parseVarFieldAssignment(ctx, s);
					parts = {
						name: q.name,
						pos: punion(p1, a.pos),
						kind: FVar(t, a.e),
						access: al,
						meta: meta
					};
				}
			case Kwd(Final):
				var p1 = tk.pos;
				s.junk();
				checkRedundantVar(ctx, p1, s);
				var q = tryHead(function() return questionableDollarIdent(ctx, s));
				if (q != null) {
					var opt = q.v.opt, name = q.v.name;
					if (isTok(s, POpen)) {
						s.junk();
						var i1 = tail(function() return propertyIdent(s));
						expectTok(s, Comma);
						var i2 = tail(function() return propertyIdent(s));
						expectTok(s, PClose);
						var t = tail(function() return popt(function(s) return parseTypeHint(ctx, s), s));
						var a = tail(function() return parseVarFieldAssignment(ctx, s));
						var meta = checkOptional(opt, name);
						parts = {
							name: name,
							pos: punion(p1, a.pos),
							kind: FProp(i1, i2, t, a.e),
							access: al.concat([{access: AFinal, pos: p1}]),
							meta: meta
						};
					} else {
						var t = popt(function(s) return parseTypeHint(ctx, s), s);
						var a = tail(function() return parseVarFieldAssignment(ctx, s));
						var meta = checkOptional(opt, name);
						parts = {
							name: name,
							pos: punion(p1, a.pos),
							kind: FVar(t, a.e),
							access: al.concat([{access: AFinal, pos: p1}]),
							meta: meta
						};
					}
				} else {
					var al2 = plist(parseCfRights, s);
					parts = tail(function() return parseFunctionField(ctx, doc, meta, al.concat([{access: AFinal, pos: p1}]).concat(al2),
						s));
				}
			case _:
				var r = tryHead(function() return parseFunctionField(ctx, doc, meta, al, s));
				if (r != null) parts = r.v
				else {
					if (al.length == 0) return fail();
					var last = al[al.length - 1];
					switch last.access {
						case AOverride:
							var po = last.pos;
							var c = Parser.checkCompletion(ctx, po, true, s);
							if (c == null) return serror();
							var f:Func = {
								fParams: vector(),
								fArgs: vector(),
								fType: null,
								fExpr: null
							};
							var name = c.name == null ? "" : c.name;
							parts = {
								name: pn(name, c.pos),
								pos: punion(po, c.pos),
								kind: FFun(f),
								access: al,
								meta: ([
									{
										meta: StrictMeta.DisplayOverride,
										exprs: vector(),
										pos: Globals.nullPos
									}
								] : Array<core.Ast.MetadataEntry>).concat(meta)
							};
						case _:
							return serror();
					}
				}
		}
		var pos = parts.access.length == 0 ? parts.pos : punion(parts.access[0].pos, parts.pos);
		return {
			cffName: parts.name,
			cffDoc: docFromStringOpt(doc),
			cffMeta: parts.meta,
			cffAccess: parts.access,
			cffPos: pos,
			cffKind: parts.kind
		};
	}

	static function parseCfRights(s:S):PlacedAccess {
		var tk = peek(s);
		var a = switch tk.token {
			case Kwd(Static): AStatic;
			case Kwd(Macro): AMacro;
			case Kwd(Public): APublic;
			case Kwd(Private): APrivate;
			case Kwd(Override): AOverride;
			case Kwd(Dynamic): ADynamic;
			case Kwd(Inline): AInline;
			case Kwd(Extern): AExtern;
			case Kwd(Abstract): AAbstract;
			case Kwd(Overload): AOverload;
			case _: return fail();
		};
		s.junk();
		return {access: a, pos: tk.pos};
	}

	static function parseFunName(s:S):PlacedName {
		var r = tryHead(function() return dollarIdent(s));
		if (r != null) return r.v;
		var p = acceptKwd(s, New);
		return p == null ? fail() : pn("new", p);
	}

	static function parseFunParam(ctx:ParserContext, s:S):FuncArg {
		var meta = parseMeta(ctx, s);
		var tk = peek(s);
		switch tk.token {
			case Question:
				s.junk();
				var n = tail(function() return dollarIdent(s));
				var t = tail(function() return popt(function(s) return parseTypeHint(ctx, s), s));
				var c = tail(function() return parseFunParamValue(ctx, s));
				return {
					name: n,
					optional: true,
					meta: meta,
					type: t,
					expr: c
				};
			case _:
		}
		var r = tryHead(function() return dollarIdent(s));
		if (r != null) {
			var t = tail(function() return popt(function(s) return parseTypeHint(ctx, s), s));
			var c = tail(function() return parseFunParamValue(ctx, s));
			return {
				name: r.v,
				optional: false,
				meta: meta,
				type: t,
				expr: c
			};
		}
		var tk = peek(s);
		if (tk.token == Spread) {
			s.junk();
			var n = tail(function() return dollarIdent(s));
			var t = tail(function() return popt(function(s) return parseTypeHint(ctx, s), s));
			var c = tail(function() return parseFunParamValue(ctx, s));
			var t:TypeHint = t != null ? t : {type: ctMono(), pos: Globals.nullPos};
			var t:TypeHint = {type: CTPath(makePtp(mkTypePath(["haxe"], "Rest", vector(TPType(t))), t.pos)), pos: t.pos};
			return {
				name: n,
				optional: false,
				meta: meta,
				type: t,
				expr: c
			};
		}
		return fail();
	}

	static function parseFunParamValue(ctx:ParserContext, s:S):Null<Expr> {
		if (acceptBinop(s, OpAssign) != null) return tail(function() return expr(ctx, s));
		return null;
	}

	static function parseFunParamType(ctx:ParserContext, s:S):{name:PlacedName, opt:Bool, t:TypeHint} {
		if (isTok(s, Question)) {
			s.junk();
			var name = tail(function() return ident(s));
			var t = tail(function() return parseTypeHint(ctx, s));
			return {name: name, opt: true, t: t};
		}
		var name = ident(s);
		var t = tail(function() return parseTypeHint(ctx, s));
		return {name: name, opt: false, t: t};
	}

	static function parseConstraintParams(ctx:ParserContext, s:S):Array<TypeParam> {
		if (acceptBinop(s, OpLt) == null) return [];
		var r = tryHead(function() return psepNonempty(Comma, function(s) return parseConstraintParam(ctx, s), s));
		if (r != null) {
			expectBinop(s, OpGt);
			return r.v;
		}
		var pos = acceptBinop(s, OpGt); // junk > so we don't get weird follow-up errors
		return Parser.syntaxError(ctx, Expected(["type parameter"]), s, [], pos);
	}

	static function parseConstraintParam(ctx:ParserContext, s:S):TypeParam {
		var meta = parseMeta(ctx, s);
		var r = tryHead(function() return typeName(ctx, s));
		if (r != null) {
			var cto = if (acceptTok(s, DblDot) != null) {
				var r2 = tryHead(function() return parseComplexType(ctx, s));
				r2 == null ? serror() : r2.v;
			} else null;
			var def = if (acceptBinop(s, OpAssign) != null) {
				var r2 = tryHead(function() return parseComplexType(ctx, s));
				r2 == null ? serror() : r2.v;
			} else null;
			return {
				tpName: r.v,
				tpParams: vector(),
				tpConstraints: cto,
				tpDefault: def,
				tpMeta: meta
			};
		}
		// If we have a metadata but no name afterwards, we have to fail hard.
		if (meta.length > 0) Parser.syntaxError(ctx, Expected(["type name"]), s, null);
		return fail();
	}

	static function parseTypePathOrResume(ctx:ParserContext, p1:Pos, s:S):{ptp:PlacedTypePath, b:Bool} {
		inline function checkResume(exc:Dynamic):{ptp:PlacedTypePath, b:Bool} {
			if (Parser.isCompletion(ctx) && Parser.wouldSkipDisplayPosition(ctx, p1, true, s)) {
				var p = DisplayPosition.displayPosition.withPos(p1);
				return {ptp: makePtp(Parser.magicTypePath, p), b: true};
			}
			throw exc;
		}
		try {
			var t = parseTypePath(ctx, s);
			return {ptp: t, b: false};
		} catch (e:StreamFailure) {
			return checkResume(e);
		} catch (e:StreamError) {
			return checkResume(e);
		}
	}

	static function parseClassHerit(ctx:ParserContext, s:S):ClassFlag {
		var tk = peek(s);
		return switch tk.token {
			case Kwd(Extends):
				s.junk();
				HExtends(tail(function() return parseTypePathOrResume(ctx, tk.pos, s)).ptp);
			case Kwd(Implements):
				s.junk();
				HImplements(tail(function() return parseTypePathOrResume(ctx, tk.pos, s)).ptp);
			case _: fail();
		}
	}

	// port: blocks

	static function block1(ctx:ParserContext, s:S):ExprDef {
		var r = tryHead(function() return dollarIdent(s));
		if (r != null) return block2(ctx, {name: r.v.name, pos: r.v.pos, quote: NoQuotes}, Ident(r.v.name), r.v.pos, s);
		var tk = peek(s);
		switch tk.token {
			case Const(String(name, qs)):
				s.junk();
				return block2(ctx, {name: name, pos: tk.pos, quote: DoubleQuotes}, String(name, qs), tk.pos, s); // STRINGTODO: qs... hmm
			case _:
		}
		var b = block(ctx, [], s);
		return EBlock(Vector.fromArrayCopy(b));
	}

	static function block2(ctx:ParserContext, name:{name:String, pos:Pos, quote:QuoteStatus}, ident:Constant, p:Pos, s:S):ExprDef {
		if (acceptTok(s, DblDot) != null) {
			var e = secureExpr(ctx, s);
			return parseObjDecl(ctx, name, e, p, s).expr;
		}
		function f(s:S):Expr {
			var e = exprNext(ctx, mk(EConst(ident), p), s);
			semicolon(ctx, s);
			return e;
		}
		var r = blockWithPos2(ctx, [], f, p, s);
		return EBlock(Vector.fromArrayCopy(r.el));
	}

	static function block(ctx:ParserContext, acc:Array<Expr>, s:S):Array<Expr> return blockWithPos(ctx, acc, Globals.nullPos, s).el;

	static function blockWithPos2(ctx:ParserContext, acc:Array<Expr>, f:S->Expr, p:Pos, s:S):{el:Array<Expr>, pos:Pos} {
		while (true) {
			try {
				// because of inner recursion, we can't put Display handling in errors below
				var e = f(s);
				acc.push(e);
				p = e.pos;
				f = function(s) return parseBlockElt(ctx, s);
			} catch (_:StreamFailure) {
				return {el: acc, pos: p};
			} catch (e:StreamError) {
				if (!ctx.config.inDisplayFile) throw e;
				Parser.handleStreamError(ctx, e.message, s);
				p = Parser.nextPos(ctx, s);
				f = function(s) return parseBlockElt(ctx, s);
			}
		}
	}

	static function blockWithPos(ctx:ParserContext, acc:Array<Expr>, p:Pos, s:S):{el:Array<Expr>, pos:Pos}
		return blockWithPos2(ctx, acc, function(s) return parseBlockElt(ctx, s), p, s);

	static function parseBlockVar(ctx:ParserContext, s:S):{vl:Array<EVar>, pos:Pos} {
		var tk = peek(s);
		switch tk.token {
			case Kwd(Var):
				var p1 = tk.pos;
				s.junk();
				var vl = tail(function() return parseVarDecls(ctx, false, p1, s));
				var p2 = tail(function() return semicolon(ctx, s));
				return {vl: vl, pos: punion(p1, p2)};
			case Kwd(Final):
				var p1 = tk.pos;
				s.junk();
				checkRedundantVar(ctx, p1, s);
				var r = tryHead(function() return parseVarDecls(ctx, true, p1, s));
				if (r != null) {
					var p2 = tail(function() return semicolon(ctx, s));
					return {vl: r.v, pos: punion(p1, p2)};
				}
				return serror();
			case _:
				return fail();
		}
	}

	static function parseBlockElt(ctx:ParserContext, s:S):Expr {
		var r = tryHead(function() return parseBlockVar(ctx, s));
		if (r != null) return mk(EVars(Vector.fromArrayCopy(r.v.vl)), r.v.pos);
		var tk = peek(s);
		switch tk.token {
			case Kwd(Function):
				var p1 = tk.pos;
				s.junk();
				var e = tail(function() return parseFunction(ctx, p1, false, s));
				tail(function() return semicolon(ctx, s));
				return e;
			case Kwd(Inline):
				var p1 = tk.pos;
				s.junk();
				if (isKwd(s, Function)) {
					s.junk();
					var e = tail(function() return parseFunction(ctx, p1, true, s));
					tail(function() return semicolon(ctx, s));
					return e;
				}
				var r = tryHead(function() return secureExpr(ctx, s));
				if (r != null) {
					tail(function() return semicolon(ctx, s));
					return Parser.makeMeta(StrictMeta.Inline, vector(), r.v, p1);
				}
				return serror();
			case Kwd(Static):
				var p = tk.pos;
				s.junk();
				var r = tryHead(function() return parseBlockVar(ctx, s));
				if (r != null) {
					var vl = r.v.vl.mapToVector(ev -> ({
							evName:ev.evName, evFinal:ev.evFinal, evStatic:true, evType:ev.evType, evExpr:ev.evExpr, evMeta:ev.evMeta
						} : EVar));
					return mk(EVars(vl), r.v.pos);
				}
				return Parser.syntaxError(ctx, Expected(["var", "final"]), s, Parser.mkNullExpr(p));
			case Binop(OpLt):
				var p1 = tk.pos;
				s.junk();
				var e = Parser.handleXmlLiteral(ctx, p1);
				// accept but don't expect semicolon
				acceptTok(s, Semicolon);
				return e;
			case _:
		}
		var e = expr(ctx, s);
		tail(function() return semicolon(ctx, s));
		return e;
	}

	static function parseObjDecl(ctx:ParserContext, name:{name:String, pos:Pos, quote:QuoteStatus}, e:Expr, p0:Pos, s:S):Expr {
		inline function makeObjDecl(el:Array<ObjectField>, p1:Pos):Expr {
			return mk(EObjectDecl(VectorTools.ofArrayReversed(el)), punion(p0, p1));
		}
		// port: the recursion `loop p_end acc` as a loop. A missing ':' calls
		// `syntax_error ctx (Expected [":"]) s (next_expr key)`, whose argument parses the
		// rest of the object first: those calls are made once the loop is done, innermost
		// first, at the stream position where the object ends.
		var acc:Array<ObjectField> = [{key: name, expr: e}];
		var pEnd = p0;
		var missingColons = 0;
		while (true) {
			if (acceptTok(s, Comma) == null) break;
			inline function nextExpr(key) {
				var e = secureExpr(ctx, s);
				pEnd = e.pos;
				acc.unshift({key: key, expr: e});
			}
			inline function next(key) {
				if (acceptTok(s, DblDot) != null) nextExpr(key) else {
					missingColons++;
					nextExpr(key);
				}
			}
			var r = tryHead(function() return ident(s));
			if (r != null) {
				next({name: r.v.name, pos: r.v.pos, quote: NoQuotes});
				continue;
			}
			var tk = peek(s);
			switch tk.token {
				case Const(String(name, qs)):
					s.junk();
					next({name: name, pos: tk.pos, quote: DoubleQuotes}); // STRINGTODO: use qs?
					continue;
				case _:
					break;
			}
		}
		for (_ in 0...missingColons) Parser.syntaxError(ctx, Expected([":"]), s, null);
		return makeObjDecl(acc, pEnd);
	}

	static function parseArrayDecl(ctx:ParserContext, p1:Pos, s:S):Expr {
		inline function resumeOrFail(p1:Pos):{el:Array<Expr>, p:Pos} {
			var p = Parser.punionNext(ctx, p1, s);
			return Parser.syntaxError(ctx, Expected(["expr", "]"]), s, {el: [Parser.mkNullExpr(p)], p: p});
		}
		var el:Array<Expr>, p2:Pos = null;
		var tk = peek(s);
		if (tk.token == BkClose) {
			s.junk();
			el = [];
			p2 = tk.pos;
		} else {
			var r = tryHead(function() return secureExpr(ctx, s));
			if (r != null) {
				var acc = [r.v];
				while (true) {
					var tk = peek(s);
					if (tk.token == Comma) {
						var pk = tk.pos;
						s.junk();
						var tk2 = peek(s);
						if (tk2.token == BkClose) {
							s.junk();
							p2 = tk2.pos;
							break;
						}
						var r2 = tryHead(function() return secureExpr(ctx, s));
						if (r2 != null) {
							acc.unshift(r2.v);
							continue;
						}
						var res = Parser.syntaxError(ctx, Expected(["expr", "]"]), s, {acc: acc, p: pk});
						acc = res.acc;
						p2 = res.p;
						break;
					} else if (tk.token == BkClose) {
						s.junk();
						p2 = tk.pos;
						break;
					} else {
						var res = Parser.syntaxError(ctx, Expected([",", "]"]), s, {acc: acc, p: Parser.nextPos(ctx, s)});
						acc = res.acc;
						p2 = res.p;
						break;
					}
				}
				el = acc;
				el.reverse();
			} else {
				var r = resumeOrFail(p1);
				// port: upstream applies List.rev to the resumed list as well
				el = r.el.copy();
				el.reverse();
				p2 = r.p;
			}
		}
		return mk(EArrayDecl(Vector.fromArrayCopy(el)), punion(p1, p2));
	}

	static function parseVarDeclHead(ctx:ParserContext, isFinal:Bool, s:S):{
		meta:Metadata,
		name:String,
		isFinal:Bool,
		t:Null<TypeHint>,
		pos:Pos
	} {
		var meta = parseMeta(ctx, s);
		var r = tryHead(function() return dollarIdent(s));
		if (r != null) {
			// port: upstream's second case (property accessors, "Cannot define property accessors for local
			// vars") is unreachable: its first case starts with `popt`, which always matches.
			var t = popt(function(s) return parseTypeHint(ctx, s), s);
			return {
				meta: meta,
				name: r.v.name,
				isFinal: isFinal,
				t: t,
				pos: r.v.pos
			};
		}
		// This nonsense is here for the var @ case in issue #9639
		for (m in meta) if (Type.enumEq(m.meta, StrictMeta.HxCompletion)) return {
			meta: meta,
			name: "",
			isFinal: false,
			t: null,
			pos: Globals.nullPos
		};
		return Parser.noKeyword("variable name", s);
	}

	static function parseVarAssignment(ctx:ParserContext, s:S):Null<Expr> {
		if (acceptBinop(s, OpAssign) != null) return secureExpr(ctx, s);
		return null;
	}

	static function parseVarAssignmentResume(ctx:ParserContext, isFinal:Bool, name:String, pn0:Pos, t:Null<TypeHint>, meta:Metadata,
			s:S):EVar {
		var eo = parseVarAssignment(ctx, s);
		return mkEvar(pn(name, pn0), t, eo, meta, isFinal);
	}

	static function parseVarDeclsNext(ctx:ParserContext, isFinal:Bool, vl:Array<EVar>, s:S):Array<EVar> {
		while (true) {
			if (!isTok(s, Comma)) return vl;
			s.junk();
			var h = tail(function() return parseVarDeclHead(ctx, isFinal, s));
			// port: upstream shadows `final` with the head's result for the rest of the list
			isFinal = h.isFinal;
			vl.push(parseVarAssignmentResume(ctx, h.isFinal, h.name, h.pos, h.t, h.meta, s));
		}
	}

	static function parseVarDecls(ctx:ParserContext, isFinal:Bool, p1:Pos, s:S):Array<EVar> {
		var r = tryHead(function() return parseVarDeclHead(ctx, isFinal, s));
		if (r != null) {
			var h = r.v;
			var vDecl = parseVarAssignmentResume(ctx, h.isFinal, h.name, h.pos, h.t, h.meta, s);
			return parseVarDeclsNext(ctx, h.isFinal, [vDecl], s);
		}
		return Parser.error(Custom("Missing variable identifier"), p1);
	}

	static function parseVarDecl(ctx:ParserContext, isFinal:Bool, s:S):EVar {
		var h = parseVarDeclHead(ctx, isFinal, s);
		return tail(function() return parseVarAssignmentResume(ctx, h.isFinal, h.name, h.pos, h.t, h.meta, s));
	}

	static function inlineFunction(s:S):{inl:Bool, pos:Pos} {
		var tk = peek(s);
		switch tk.token {
			case Kwd(Inline):
				s.junk();
				var p1 = expectKwd(s, Function);
				return {inl: true, pos: p1};
			case Kwd(Function):
				s.junk();
				return {inl: false, pos: tk.pos};
			case _:
				return fail();
		}
	}

	static function parseMacroExpr(ctx:ParserContext, p:Pos, s:S):Expr {
		var tk = peek(s);
		switch tk.token {
			case DblDot:
				s.junk();
				var t = tail(function() return parseComplexType(ctx, s));
				var toType = Reification.reify(ctx.inMacro).toCtype;
				var t = toType(t, p);
				var ct = makePtpCt(mkTypePath(["haxe", "macro"], "Expr", null, "ComplexType"), Globals.nullPos);
				return mk(ECheckType(t, {type: ct, pos: p}), p);
			case Kwd(Var):
				var p1 = tk.pos;
				s.junk();
				var vl = tail(function() return psep(Comma, function(s) return parseVarDecl(ctx, false, s), s));
				return Reification.reifyExpr(mk(EVars(Vector.fromArrayCopy(vl)), p1), ctx.inMacro);
			case Kwd(Final):
				var p1 = tk.pos;
				s.junk();
				checkRedundantVar(ctx, p1, s);
				var r = tryHead(function() return psep(Comma, function(s) return parseVarDecl(ctx, true, s), s));
				if (r != null) return Reification.reifyExpr(mk(EVars(Vector.fromArrayCopy(r.v)), p1), ctx.inMacro);
				return serror();
			case _:
		}
		var r = tryHead(function() return parseClass(ctx, null, [], [], false, s));
		if (r != null) {
			var toType = Reification.reify(ctx.inMacro).toTypeDef;
			var ct = makePtpCt(mkTypePath(["haxe", "macro"], "Expr", null, "TypeDefinition"), Globals.nullPos);
			return mk(ECheckType(toType(r.v), {type: ct, pos: Globals.nullPos}), p);
		}
		var e = secureExpr(ctx, s);
		return Reification.reifyExpr(e, ctx.inMacro);
	}

	static function parseFunction(ctx:ParserContext, p1:Pos, inl:Bool, s:S):Expr {
		var name = popt(dollarIdent, s);
		var pl = parseConstraintParams(ctx, s);
		if (isTok(s, POpen)) {
			s.junk();
			var al = tail(function() return psepTrailing(Comma, function(s) return parseFunParam(ctx, s), s));
			expectTok(s, PClose);
			var t = tail(function() return popt(function(s) return parseTypeHint(ctx, s), s));
			inline function make(e:Expr):Expr {
				var f:Func = {
					fParams: Vector.fromArrayCopy(pl),
					fType: t,
					fArgs: Vector.fromArrayCopy(al),
					fExpr: e
				};
				return mk(EFunction(name == null ? FKAnonymous : FKNamed(name, inl), f), punion(p1, e.pos));
			}
			return make(secureExpr(ctx, s));
		}
		// Generate pseudo function to avoid toplevel-completion (issue #10691). We check against p1 here in order to cover cases
		// like `function a|b`
		if (Parser.wouldSkipDisplayPosition(ctx, p1, false, s)) {
			var f:Func = {
				fParams: vector(),
				fType: null,
				fArgs: vector(),
				fExpr: null
			};
			var p = punion(p1, Parser.nextPos(ctx, s));
			var name = pn("_hx_magic", p);
			return mk(EFunction(FKNamed(name, inl), f), p);
		}
		return serror();
	}

	static function arrowExpr(ctx:ParserContext, s:S):Expr {
		if (acceptTok(s, Arrow) != null) return tail(function() return expr(ctx, s));
		return serror();
	}

	static function arrowFunction(ctx:ParserContext, p1:Pos, al:Array<FuncArg>, er:Expr, s:S):Expr {
		inline function make(e:Expr):Expr {
			var p = e.pos;
			var ret = mk(EMeta({meta: StrictMeta.ImplicitReturn, exprs: vector(), pos: Globals.nullPos}, mk(EReturn(e), p)), p);
			return mk(EFunction(FKArrow, {
				fParams: vector(),
				fType: null,
				fArgs: Vector.fromArrayCopy(al),
				fExpr: ret
			}), punion(p1, p));
		}
		for (a in al) if (a.meta.length > 0) Parser.syntaxError(ctx, Custom("Metadata on arrow function arguments is not allowed"), s,
			null, a.meta[0].pos);
		return make(er);
	}

	static function arrowIdentChecktype(e:Expr):{np:PlacedName, t:Null<TypeHint>} {
		return switch e.expr {
			case EConst(Ident(n)): {np: pn(n, e.pos), t: null};
			case ECheckType({expr: EConst(Ident(n)), pos: p}, t): {np: pn(n, p), t: t};
			case _: serror();
		}
	}

	static function arrowFirstParam(ctx:ParserContext, e:Expr, s:S):FuncArg {
		return switch e.expr {
			case EConst(Ident("true" | "false" | "null" | "this" | "super")):
				Parser.syntaxError(ctx, Custom("Invalid argument name"), s, ({
					name: pn("", Globals.nullPos),
					optional: false,
					meta: [],
					type: null,
					expr: null
				} : core.Ast.FuncArg), e.pos);
			case EConst(Ident(n)):
				{
					name: pn(n, e.pos),
					optional: false,
					meta: [],
					type: null,
					expr: null
				};
			case EBinop(OpAssign, e1, e2) | EParenthesis({expr: EBinop(OpAssign, e1, e2)}):
				var r = arrowIdentChecktype(e1);
				{
					name: r.np,
					optional: true,
					meta: [],
					type: r.t,
					expr: e2
				};
			case EParenthesis(e):
				var r = arrowIdentChecktype(e);
				{
					name: r.np,
					optional: false,
					meta: [],
					type: r.t,
					expr: null
				};
			case _:
				serror();
		}
	}

	// port: expressions

	public static function expr(ctx:ParserContext, s:S):Expr {
		var r = tryHead(function() return parseMetaEntry(ctx, s));
		if (r != null) {
			var m = r.v;
			try {
				return Parser.makeMeta(m.meta, m.exprs, secureExpr(ctx, s), m.pos);
			} catch (e:haxe.Exception) {
				if ((Std.isOfType(e, StreamFailure) || Std.isOfType(e, core.ds.Stream.StreamError)) && ctx.config.inDisplayFile) {
					var e = mk(EConst(Ident("null")), Globals.nullPos);
					return Parser.makeMeta(m.meta, m.exprs, e, m.pos);
				}
				throw e;
			}
		}
		var tk = peek(s);
		var p = tk.pos;
		switch tk.token {
			case Binop(OpLt):
				s.junk();
				return Parser.handleXmlLiteral(ctx, p);
			case BrOpen:
				var p1 = p;
				s.junk();
				var rb = tryHead(function() return block1(ctx, s));
				if (rb != null) {
					var b = rb.v;
					var p2 = acceptTok(s, BrClose);
					// Ignore missing } if we are resuming and "guess" the last position.
					if (p2 == null) p2 = Parser.syntaxError(ctx, Expected(["}"]), s, Parser.nextToken(ctx, s).pos);
					var e = mk(b, punion(p1, p2));
					return switch b {
						case EObjectDecl(_): exprNext(ctx, e, s);
						case _: e;
					}
				}
				return Parser.checkResume(ctx, p1, function() return mk(EDisplay(mk(EObjectDecl(vector()), p1), DKStructure), p1), serror);
			case Kwd(k) if (parsingMacroCond):
				s.junk();
				return exprNext(ctx, mk(EConst(Ident(sKeyword(k))), p), s);
			case Kwd(Macro):
				s.junk();
				var tk2 = peek(s);
				if (tk2.token == Dot) {
					s.junk();
					return tail(function() return parseField(ctx, mk(EConst(Ident("macro")), p), EFNormal, tk2.pos, s));
				}
				var r = tryHead(function() return parseMacroExpr(ctx, p, s));
				if (r != null) return r.v;
				return serror();
			case Kwd(Var):
				var p1 = p;
				s.junk();
				var v = tail(function() return parseVarDecl(ctx, false, s));
				return mk(EVars(vector(v)), p1);
			case Kwd(Final):
				var p1 = p;
				s.junk();
				checkRedundantVar(ctx, p1, s);
				var r = tryHead(function() return parseVarDecl(ctx, true, s));
				if (r != null) return mk(EVars(vector(r.v)), p1);
				return serror();
			case Const(c):
				s.junk();
				return exprNext(ctx, mk(EConst(c), p), s);
			case Kwd(This):
				s.junk();
				return exprNext(ctx, mk(EConst(Ident("this")), p), s);
			case Kwd(Abstract):
				s.junk();
				return exprNext(ctx, mk(EConst(Ident("abstract")), p), s);
			case Kwd(True):
				s.junk();
				return exprNext(ctx, mk(EConst(Ident("true")), p), s);
			case Kwd(False):
				s.junk();
				return exprNext(ctx, mk(EConst(Ident("false")), p), s);
			case Kwd(Null):
				s.junk();
				return exprNext(ctx, mk(EConst(Ident("null")), p), s);
			case Kwd(Cast):
				var p1 = p;
				s.junk();
				var tk2 = peek(s);
				if (tk2.token == POpen) {
					var pp = tk2.pos;
					s.junk();
					var e = tail(function() return expr(ctx, s));
					var tk3 = peek(s);
					if (tk3.token == Comma) {
						s.junk();
						var t = tail(function() return parseComplexType(ctx, s));
						var p2 = expectTok(s, PClose);
						return exprNext(ctx, mk(ECast(e, t), punion(p1, p2)), s);
					}
					var rt = tryHead(function() return parseTypeHint(ctx, s));
					if (rt != null) {
						var p2 = expectTok(s, PClose);
						var ep = mk(EParenthesis(mk(ECheckType(e, rt.v), punion(p1, p2))), punion(p1, p2));
						return exprNext(ctx, mk(ECast(ep, null), punion(p1, ep.pos)), s);
					}
					var tk4 = peek(s);
					if (tk4.token == PClose) {
						var p2 = tk4.pos;
						s.junk();
						var ep = exprNext(ctx, mk(EParenthesis(e), punion(pp, p2)), s);
						return exprNext(ctx, mk(ECast(ep, null), punion(p1, ep.pos)), s);
					}
					return serror();
				}
				var r = tryHead(function() return secureExpr(ctx, s));
				if (r != null) return exprNext(ctx, mk(ECast(r.v, null), punion(p1, r.v.pos)), s);
				return fail();
			case Kwd(Throw):
				s.junk();
				var e = tail(function() return expr(ctx, s));
				return mk(EThrow(e), p);
			case Kwd(New):
				var p1 = p;
				s.junk();
				var t = tail(function() return parseTypePathOrResume(ctx, p1, s)).ptp;
				var tk2 = peek(s);
				if (tk2.token == POpen) {
					var po = tk2.pos;
					s.junk();
					var e = tail(function() return parseCallParams(ctx, function(el, p2) return mk(ENew(t, el), punion(p1, p2)), po, s));
					return exprNext(ctx, e, s);
				}
				return Parser.syntaxError(ctx, Expected(["("]), s, mk(ENew(t, vector()), punion(p1, t.posFull)));
			case POpen:
				var p1 = p;
				s.junk();
				return parseParenthesis(ctx, p1, s);
			case BkOpen:
				var p1 = p;
				s.junk();
				var e = tail(function() return parseArrayDecl(ctx, p1, s));
				return exprNext(ctx, e, s);
			case Kwd(Function):
				var p1 = p;
				s.junk();
				var e = tail(function() return parseFunction(ctx, p1, false, s));
				var tk2 = peek(s);
				return switch tk2.token {
					case POpen | BkOpen: e;
					case Unop(op) if (isPostfix(op)): e;
					case _: exprNext(ctx, e, s);
				}
			case Unop(op):
				s.junk();
				var e = tail(function() return expr(ctx, s));
				return Parser.makeUnop(op, e, p);
			case Spread:
				s.junk();
				var e = tail(function() return expr(ctx, s));
				return Parser.makeUnop(Spread, e, punion(p, e.pos));
			case Binop(OpSub):
				s.junk();
				var e = tail(function() return expr(ctx, s));
				return Parser.makeUnop(Neg, e, p);
			// /* removed unary + : this cause too much syntax errors go unnoticed, such as "a + + 1" (missing 'b')
			// 					without adding anything to the language
			// | [ (Binop OpAdd,p1) ] ->
			// 	(match%parser s with
			// 	| [ (Const (Int i),p); [%let e = expr_next ctx (EConst (Int i),p)] ] -> e
			// 	| [ (Const (Float f),p); [%let e = expr_next ctx (EConst (Float f),p)] ] -> e
			// 	| [ ] -> serror()) */
			case Kwd(For):
				s.junk();
				expectTok(s, POpen);
				var it = tail(function() return secureExpr(ctx, s));
				var e = if (acceptTok(s,
					PClose) != null) tail(function() return secureExpr(ctx,
						s)) else Parser.syntaxError(ctx, Expected([")"]), s, Parser.mkNullExpr(it.pos));
				return mk(EFor(it, e), punion(p, e.pos));
			case Kwd(If):
				s.junk();
				expectTok(s, POpen);
				var cond = tail(function() return secureExpr(ctx, s));
				var e1 = if (acceptTok(s,
					PClose) != null) tail(function() return secureExpr(ctx,
						s)) else Parser.syntaxError(ctx, Expected([")"]), s, Parser.mkNullExpr(cond.pos));
				var e2:Null<Expr> = if (acceptKwd(s, Else) != null) tail(function() return secureExpr(ctx, s)) else {
					// We check this in two steps to avoid the lexer missing tokens (#8565).
					var l1 = s.npeek(1);
					if (l1.length == 1 && l1[0].token == Semicolon) {
						var l2 = s.npeek(2);
						if (l2.length == 2 && l2[0].token == Semicolon && l2[1].token.match(Kwd(Else))) {
							s.junk();
							s.junk();
							secureExpr(ctx, s);
						} else null;
					} else null;
				};
				return mk(EIf(cond, e1, e2), punion(p, e2 == null ? e1.pos : e2.pos));
			case Kwd(Return):
				s.junk();
				var r = tryHead(function() return expr(ctx, s));
				if (r != null) return mk(EReturn(r.v), punion(p, r.v.pos));
				if (Parser.wouldSkipDisplayPosition(ctx, p, true,
					s)) return mk(EReturn(Parser.mkNullExpr(Parser.punionNext(ctx, p, s))), p);
				return mk(EReturn(null), p);
			case Kwd(Break):
				s.junk();
				return mk(EBreak, p);
			case Kwd(Continue):
				s.junk();
				return mk(EContinue, p);
			case Kwd(While):
				var p1 = p;
				s.junk();
				expectTok(s, POpen);
				var cond = tail(function() return secureExpr(ctx, s));
				var e = if (acceptTok(s,
					PClose) != null) tail(function() return secureExpr(ctx,
						s)) else Parser.syntaxError(ctx, Expected([")"]), s, Parser.mkNullExpr(cond.pos));
				return mk(EWhile(cond, e, NormalWhile), punion(p1, e.pos));
			case Kwd(Do):
				var p1 = p;
				s.junk();
				var e = tail(function() return secureExpr(ctx, s));
				if (acceptKwd(s, While) != null) {
					expectTok(s, POpen);
					var cond = tail(function() return secureExpr(ctx, s));
					var p2 = expectUnlessResumeP(ctx, PClose, s);
					return mk(EWhile(cond, e, DoWhile), punion(p1, p2));
				}
				return Parser.syntaxError(ctx, Expected(["while"]), s, e); // ignore do
			case Kwd(Switch):
				var p1 = p;
				s.junk();
				var e = tail(function() return secureExpr(ctx, s));
				if (acceptTok(s, BrOpen) != null) {
					var r = tail(function() return parseSwitchCases(ctx, e, [], s));
					var p2 = acceptTok(s, BrClose);
					// Ignore missing } if we are resuming and "guess" the last position.
					if (p2 == null) p2 = Parser.syntaxError(ctx, Expected(["}"]), s, Parser.nextToken(ctx, s).pos);
					return mk(ESwitch(e, Vector.fromArrayCopy(r.cases), r.def), punion(p1, p2));
				}
				return Parser.syntaxError(ctx, Expected(["{"]), s, mk(ESwitch(e, vector(), null), punion(p1, e.pos)));
			case Kwd(Try):
				var p1 = p;
				s.junk();
				var e = tail(function() return secureExpr(ctx, s));
				var r = tail(function() return parseCatches(ctx, e, [], e.pos, s));
				return mk(ETry(e, Vector.fromArrayCopy(r.catches)), punion(p1, r.pmax));
			case IntInterval(i):
				s.junk();
				var e2 = tail(function() return expr(ctx, s));
				return Parser.makeBinop(OpInterval, mk(EConst(Int(i, null)), p), e2);
			case Kwd(Untyped):
				s.junk();
				var e = tail(function() return secureExpr(ctx, s));
				return mk(EUntyped(e), punion(p, e.pos));
			case Dollar(v):
				s.junk();
				return exprNext(ctx, mk(EConst(Ident("$" + v)), p), s);
			case Kwd(Inline):
				s.junk();
				var e = tail(function() return secureExpr(ctx, s));
				return Parser.makeMeta(StrictMeta.Inline, vector(), e, p);
			case _:
				return fail();
		}
	}

	// port: the POpen case of `expr`.
	static function parseParenthesis(ctx:ParserContext, p1:Pos, s:S):Expr {
		var tk = peek(s);
		switch tk.token {
			case PClose:
				s.junk();
				var er = tail(function() return arrowExpr(ctx, s));
				return arrowFunction(ctx, p1, [], er, s);
			case Question:
				s.junk();
				var al = tail(function() return psepTrailing(Comma, function(s) return parseFunParam(ctx, s), s));
				expectTok(s, PClose);
				var er = tail(function() return arrowExpr(ctx, s));
				if (al.length == 0) Globals.die("", "grammar.ml");
				var a0 = al[0];
				al = [
					({
						name: a0.name,
						optional: true,
						meta: [],
						type: a0.type,
						expr: a0.expr
					} : FuncArg)
				].concat(al.slice(1));
				return arrowFunction(ctx, p1, al, er, s);
			case _:
		}
		var r = tryHead(function() return expr(ctx, s));
		if (r == null) return fail();
		var e = r.v;
		var tk = peek(s);
		switch tk.token {
			case PClose:
				s.junk();
				return exprNext(ctx, mk(EParenthesis(e), punion(p1, tk.pos)), s);
			case Comma:
				s.junk();
				var al = tail(function() return psepTrailing(Comma, function(s) return parseFunParam(ctx, s), s));
				expectTok(s, PClose);
				var er = tail(function() return arrowExpr(ctx, s));
				return arrowFunction(ctx, p1, [arrowFirstParam(ctx, e, s)].concat(al), er, s);
			case _:
		}
		var rt = tryHead(function() return parseTypeHint(ctx, s));
		if (rt != null) {
			var t = rt.v;
			var tk = peek(s);
			switch tk.token {
				case PClose:
					var p2 = tk.pos;
					s.junk();
					return exprNext(ctx, mk(EParenthesis(mk(ECheckType(e, t), punion(p1, p2))), punion(p1, p2)), s);
				case Comma:
					s.junk();
					var al = tail(function() return psepTrailing(Comma, function(s) return parseFunParam(ctx, s), s));
					expectTok(s, PClose);
					var er = tail(function() return arrowExpr(ctx, s));
					var np = arrowIdentChecktype(e).np;
					return arrowFunction(ctx, p1, [
						({
							name: np,
							optional: false,
							meta: [],
							type: t,
							expr: null
						} : FuncArg)
					].concat(al), er, s);
				case Binop(OpAssign):
					s.junk();
					var ea1 = tail(function() return expr(ctx, s));
					inline function withArgs(al:Array<FuncArg>, er:Expr):Expr {
						return switch e.expr {
							case EConst(Ident(n)):
								arrowFunction(ctx, p1, [
									({
										name: pn(n, e.pos),
										optional: true,
										meta: [],
										type: t,
										expr: ea1
									} : FuncArg)
								].concat(al), er, s);
							case _: serror();
						}
					}
					var tk2 = peek(s);
					switch tk2.token {
						case PClose:
							s.junk();
							var er = tail(function() return arrowExpr(ctx, s));
							return withArgs([], er);
						case Comma:
							s.junk();
							var al = tail(function() return psepTrailing(Comma, function(s) return parseFunParam(ctx, s), s));
							expectTok(s, PClose);
							var er = tail(function() return arrowExpr(ctx, s));
							return withArgs(al, er);
						case _:
							return serror();
					}
				case _:
					return serror();
			}
		}
		return Parser.syntaxError(ctx, Expected([")", ",", ":"]), s, exprNext(ctx, mk(EParenthesis(e), punion(p1, e.pos)), s));
	}

	static function exprNext(ctx:ParserContext, e1:Expr, s:S):Expr {
		try return exprNext2(ctx, e1, s)
		catch (e:StreamError) {
			if (!ctx.config.inDisplay) throw e;
			Parser.handleStreamError(ctx, e.message, s);
			return e1;
		}
	}

	static function exprNext2(ctx:ParserContext, e1:Expr, s:S):Expr {
		var tk = peek(s);
		switch tk.token {
			case BrOpen if (Parser.isDollarIdent(e1)):
				var p1 = tk.pos;
				s.junk();
				var eparam = tail(function() return expr(ctx, s));
				var p2 = expectTok(s, BrClose);
				return switch e1.expr {
					case EConst(Ident(n)): exprNext(ctx,
							mk(EMeta({meta: core.Meta.fromString(n), exprs: vector(), pos: e1.pos}, eparam), punion(p1, p2)), s);
					case _: Globals.die("", "grammar.ml");
				}
			case Dot:
				s.junk();
				return tail(function() return parseField(ctx, e1, EFNormal, tk.pos, s));
			case QuestionDot:
				s.junk();
				return tail(function() return parseField(ctx, e1, EFSafe, tk.pos, s));
			case POpen:
				var p1 = tk.pos;
				s.junk();
				var e = tail(function() return parseCallParams(ctx, function(el, p2) return mk(ECall(e1, el), punion(e1.pos, p2)), p1, s));
				return exprNext(ctx, e, s);
			case BkOpen:
				var p1 = tk.pos;
				s.junk();
				var e2 = tail(function() return secureExpr(ctx, s));
				var p2 = expectUnlessResumeP(ctx, BkClose, s);
				var e2 = Parser.checkSignatureMark(ctx, e2, p1, p2);
				return exprNext(ctx, mk(EArray(e1, e2), punion(e1.pos, p2)), s);
			case Arrow:
				s.junk();
				var er = secureExpr(ctx, s);
				return arrowFunction(ctx, e1.pos, [arrowFirstParam(ctx, e1, s)], er, s);
			case Binop(OpGt):
				var p1 = tk.pos;
				s.junk();
				var tk2 = peek(s);
				switch tk2.token {
					case Binop(OpGt) if (p1.pmax == tk2.pos.pmin):
						var p2 = tk2.pos;
						s.junk();
						var tk3 = peek(s);
						switch tk3.token {
							case Binop(OpGt) if (p2.pmax == tk3.pos.pmin):
								var p3 = tk3.pos;
								s.junk();
								var tk4 = peek(s);
								switch tk4.token {
									case Binop(OpAssign) if (p3.pmax == tk4.pos.pmin):
										s.junk();
										var e2 = tail(function() return expr(ctx, s));
										return Parser.makeBinop(OpAssignOp(OpUShr), e1, e2);
									case _:
										var r = tryHead(function() return secureExpr(ctx, s));
										if (r == null) return fail();
										return Parser.makeBinop(OpUShr, e1, r.v);
								}
							case Binop(OpAssign) if (p2.pmax == tk3.pos.pmin):
								s.junk();
								var e2 = tail(function() return expr(ctx, s));
								return Parser.makeBinop(OpAssignOp(OpShr), e1, e2);
							case _:
								var r = tryHead(function() return secureExpr(ctx, s));
								if (r == null) return fail();
								return Parser.makeBinop(OpShr, e1, r.v);
						}
					case Binop(OpAssign) if (p1.pmax == tk2.pos.pmin):
						s.junk();
						return Parser.makeBinop(OpGte, e1, secureExpr(ctx, s));
					case _:
						var r = tryHead(function() return secureExpr(ctx, s));
						if (r == null) return fail();
						return Parser.makeBinop(OpGt, e1, r.v);
				}
			case Binop(op):
				s.junk();
				var e2 = tail(function() return secureExpr(ctx, s));
				return Parser.makeBinop(op, e1, e2);
			case Spread:
				s.junk();
				var e2 = tail(function() return secureExpr(ctx, s));
				return Parser.makeBinop(OpInterval, e1, e2);
			case Unop(op) if (isPostfix(op)):
				s.junk();
				return exprNext(ctx, mk(EUnop(op, Postfix, e1), punion(e1.pos, tk.pos)), s);
			case Question:
				s.junk();
				var e2 = tail(function() return expr(ctx, s));
				if (acceptTok(s, DblDot) != null) {
					var e3 = tail(function() return expr(ctx, s));
					return mk(ETernary(e1, e2, e3), punion(e1.pos, e3.pos));
				}
				return Parser.syntaxError(ctx, Expected([":"]), s, e2);
			case Kwd(In):
				s.junk();
				var e2 = tail(function() return expr(ctx, s));
				return Parser.makeBinop(OpIn, e1, e2);
			case Const(Ident("is")):
				s.junk();
				var t = tail(function() return parseComplexType(ctx, s));
				var p1 = e1.pos;
				var p2 = t.pos;
				var eIs = mk(EIs(e1, t), punion(p1, p2));
				return exprNext(ctx, eIs, s);
			case _:
				return e1;
		}
	}

	static function parseField(ctx:ParserContext, e1:Expr, efk:EFieldKind, p:Pos, s:S):Expr {
		return Parser.checkResume(ctx, p, function() return mk(EDisplay(e1, DKDot), p), function() {
			var tk = peek(s);
			var p2 = tk.pos;
			switch tk.token {
				case Kwd(Macro) if (p.pmax == p2.pmin):
					s.junk();
					return exprNext(ctx, mk(EField(e1, "macro", efk), punion(e1.pos, p2)), s);
				case Kwd(Extern) if (p.pmax == p2.pmin):
					s.junk();
					return exprNext(ctx, mk(EField(e1, "extern", efk), punion(e1.pos, p2)), s);
				case Kwd(Function) if (p.pmax == p2.pmin):
					s.junk();
					return exprNext(ctx, mk(EField(e1, "function", efk), punion(e1.pos, p2)), s);
				case Kwd(New) if (p.pmax == p2.pmin):
					s.junk();
					return exprNext(ctx, mk(EField(e1, "new", efk), punion(e1.pos, p2)), s);
				case Kwd(k) if (parsingMacroCond && p.pmax == p2.pmin):
					s.junk();
					return exprNext(ctx, mk(EField(e1, sKeyword(k), efk), punion(e1.pos, p2)), s);
				case Const(Ident(f)) if (p.pmax == p2.pmin):
					s.junk();
					return exprNext(ctx, mk(EField(e1, f, efk), punion(e1.pos, p2)), s);
				case Dollar(v):
					s.junk();
					return exprNext(ctx, mk(EField(e1, "$" + v, efk), punion(e1.pos, p2)), s);
				case _:
					// turn an integer followed by a dot into a float
					return switch e1.expr {
						case EConst(Int(v,
							null)) if (e1.pos.pmax == p.pmin): exprNext(ctx, mk(EConst(Float(v + ".", null)), punion(p, e1.pos)), s);
						case _: serror();
					}
			}
		});
	}

	static function parseGuard(ctx:ParserContext, s:S):Expr {
		if (acceptKwd(s, If) == null) return fail();
		expectTok(s, POpen);
		var e = tail(function() return expr(ctx, s));
		expectTok(s, PClose);
		return e;
	}

	static function exprOrVar(ctx:ParserContext, s:S):Expr {
		var tk = peek(s);
		switch tk.token {
			case Kwd(Var):
				var p1 = tk.pos;
				s.junk();
				var np = tail(function() return dollarIdent(s));
				return mk(EVars(vector(mkEvar(np))), punion(p1, np.pos));
			case Kwd(Final):
				var p1 = tk.pos;
				s.junk();
				checkRedundantVar(ctx, p1, s);
				var r = tryHead(function() return dollarIdent(s));
				if (r != null) return mk(EVars(vector(mkEvar(r.v, null, null, null, true))), punion(p1, r.v.pos));
				return serror();
			case _:
		}
		return secureExpr(ctx, s);
	}

	static function parseSwitchCases(ctx:ParserContext, eswitch:Expr, cases:Array<SwitchCase>,
			s:S):{cases:Array<SwitchCase>, def:Null<SwitchDefault>} {
		var tk = peek(s);
		switch tk.token {
			case Kwd(Default):
				var p1 = tk.pos;
				s.junk();
				var pdot = expectTok(s, DblDot);
				var r = blockWithPos(ctx, [], p1, s);
				var b:SwitchDefault = if (r.el.length == 0) {expr: null, pos: pdot} else {
					var p = punion(p1, r.pos);
					{expr: mk(EBlock(Vector.fromArrayCopy(r.el)), p), pos: p};
				};
				var res = parseSwitchCases(ctx, eswitch, cases, s);
				if (res.def != null) Parser.syntaxError(ctx, DuplicateDefault, s, null, p1);
				return {cases: res.cases, def: b};
			case Kwd(Case):
				var p1 = tk.pos;
				s.junk();
				var el = tail(function() return psep(Comma, function(s) return exprOrVar(ctx, s), s));
				var eg = tail(function() return popt(function(s) return parseGuard(ctx, s), s));
				var pdot = expectUnlessResumeP(ctx, DblDot, s);
				if (ctx.config.wasAutoTriggered) Parser.checkResume(ctx, pdot, function() {}, function() {});
				if (el.length == 0) return Parser.syntaxError(ctx, Custom("case without a pattern is not allowed"), s,
					{cases: [], def: null}, p1);
				var r = blockWithPos(ctx, [], p1, s);
				var b:Null<Expr>, p:Pos;
				if (r.el.length == 0) {
					b = null;
					p = punion(p1, pdot);
				} else {
					p = punion(p1, r.pos);
					b = mk(EBlock(Vector.fromArrayCopy(r.el)), p);
				}
				cases.unshift({
					values: Vector.fromArrayCopy(el),
					guard: eg,
					expr: b,
					pos: p
				});
				return parseSwitchCases(ctx, eswitch, cases, s);
			case _:
				var l = cases.copy();
				l.reverse();
				return {cases: l, def: null};
		}
	}

	static function parseCatch(ctx:ParserContext, etry:Expr, s:S):{c:Catch, pmax:Pos} {
		var p = acceptKwd(s, Catch);
		if (p == null) return fail();
		expectTok(s, POpen);
		var n = tail(function() return dollarIdent(s));
		var rt = tryHead(function() return parseTypeHint(ctx, s));
		if (rt != null) {
			expectTok(s, PClose);
			var e = tail(function() return secureExpr(ctx, s));
			return {
				c: {
					name: n,
					type: rt.v,
					expr: e,
					pos: punion(p, e.pos)
				},
				pmax: e.pos
			};
		}
		var tk = peek(s);
		if (tk.token == PClose) {
			s.junk();
			var e = tail(function() return secureExpr(ctx, s));
			return {
				c: {
					name: n,
					type: null,
					expr: e,
					pos: punion(p, e.pos)
				},
				pmax: e.pos
			};
		}
		s.junk();
		return Parser.error(MissingType, tk.pos);
	}

	static function parseCatches(ctx:ParserContext, etry:Expr, catches:Array<Catch>, pmax:Pos, s:S):{catches:Array<Catch>, pmax:Pos} {
		while (true) {
			var r = tryHead(function() return parseCatch(ctx, etry, s));
			if (r == null) return {catches: catches, pmax: pmax};
			catches.push(r.v.c);
			pmax = r.v.pmax;
		}
	}

	static function parseCallParams(ctx:ParserContext, fv:Vector<Expr>->Pos->Expr, p1:Pos, s:S):Expr {
		inline function f(el:Array<Expr>, p:Pos):Expr return fv(Vector.fromArrayCopy(el), p);
		if (!ctx.config.inDisplayFile) {
			var el = psepTrailing(Comma, function(s) return expr(ctx, s), s);
			var p2 = acceptTok(s, PClose);
			if (p2 != null) return f(el, p2);
			var expected = el.length == 0 ? ["expression", ")"] : [",", ")"];
			return Parser.syntaxError(ctx, Expected(expected), s, f(el, Parser.lastPos(ctx, s)));
		}
		function parseNextParam(acc:Array<Expr>, p1:Pos):Expr {
			var e = try expr(ctx, s) catch (_:StreamFailure) {
				var expected = ["expression"].concat(acc.length == 0 ? [")"] : []);
				Parser.syntaxError(ctx, Expected(expected), s, null);
				Parser.mkNullExpr(Parser.punionNext(ctx, p1, s));
			} catch (err:StreamError) {
				Parser.handleStreamError(ctx, err.message, s);
				Parser.mkNullExpr(Parser.punionNext(ctx, p1, s));
			}
			inline function finish(l:Array<Expr>):Array<Expr> {
				var r = acc.copy();
				r.reverse();
				return r.concat(l);
			}
			var tk = peek(s);
			switch tk.token {
				case PClose:
					var p2 = tk.pos;
					s.junk();
					var e = Parser.checkSignatureMark(ctx, e, p1, p2);
					return f(finish([e]), p2);
				case Comma:
					var p2 = tk.pos;
					s.junk();
					var tk2 = peek(s);
					if (tk2.token == PClose) {
						var p3 = tk2.pos;
						s.junk();
						if (Parser.isSignatureDisplay(ctx)) {
							var prevArgPos = punion(p1, p2);
							var commaParenPos = punion(p2, p3);
							// first check wether the display position is within the previous argument
							if (DisplayPosition.enclosesPositionGt(DisplayPosition.displayPosition.get(), prevArgPos)) {
								// wrap the argument that was just parsed
								var e = Parser.mkDisplayExpr(e, DKMarked);
								return f(finish([e]), p3);
								// then check wether the display position is between the comma and the closing parenthesis
							} else if (DisplayPosition.enclosesPositionGt(DisplayPosition.displayPosition.get(), commaParenPos)) {
								// add a dummy final argument
								var e2 = Parser.mkDisplayExpr(Parser.mkNullExpr(commaParenPos), DKMarked);
								return f(finish([e, e2]), p3);
							} else return f(finish([e]), p3);
						} else {
							// if not in signature display mode don't check anything
							return f(finish([e]), p3);
						}
					}
					var e = Parser.checkSignatureMark(ctx, e, p1, p2);
					return parseNextParam([e].concat(acc), p2);
				case _:
					var p2 = Parser.nextPos(ctx, s);
					Parser.syntaxError(ctx, Expected([",", ")"]), s, null);
					var e = Parser.checkSignatureMark(ctx, e, p1, p2);
					return f(finish([e]), p2);
			}
		}
		var tk = peek(s);
		if (tk.token == PClose) {
			s.junk();
			return f([], tk.pos);
		}
		return parseNextParam([], p1);
	}

	// Tries to parse a toplevel expression and defaults to a null expression when in display mode.
	// This function always accepts in display mode and should only be used for expected expressions,
	// not accepted ones!
	static function secureExpr(ctx:ParserContext, s:S):Expr {
		var r = tryHead(function() return expr(ctx, s));
		if (r != null) return r.v;
		var last = Parser.lastToken(ctx, s);
		var plast = last.pos;
		var offset = switch last.token {
			case Const(_) | Kwd(_) | Dollar(_): 1;
			case _: 0;
		};
		var plast:core.Globals.Pos = {pfile: plast.pfile, pmin: plast.pmax + offset, pmax: plast.pmax};
		return Parser.syntaxError(ctx, Expected(["expression"]), s, Parser.mkNullExpr(Parser.punionNext(ctx, plast, s)));
	}

	// port: conditional compilation

	static function validateMacroCond(ctx:ParserContext, s:S, e:Expr):Expr {
		return switch e.expr {
			case EConst(String(_)) | EConst(Int(_, _)) | EConst(Float(_, _)): e;
			case EConst(Ident(t)): parseMacroIdent(ctx, t, e.pos, s);
			case EUnop(op, p, e1): mk(EUnop(op, p, validateMacroCond(ctx, s, e1)), e.pos);
			case EBinop(op, e1, e2): mk(EBinop(op, validateMacroCond(ctx, s, e1), validateMacroCond(ctx, s, e2)), e.pos);
			case EParenthesis(e1): mk(EParenthesis(validateMacroCond(ctx, s, e1)), e.pos);
			case EField(e1, name, efk): mk(EField(validateMacroCond(ctx, s, e1), name, efk), e.pos);
			case ECall(i = {expr: EConst(Ident(_))}, args): mk(ECall(i, args.map(a -> validateMacroCond(ctx, s, a))), e.pos);
			case _: Parser.syntaxError(ctx, Custom("Invalid conditional expression"), s, mk(EConst(Ident("false")), e.pos), e.pos);
		}
	}

	static function parseMacroIdent(ctx:ParserContext, t:String, p:Pos, s:S):Expr {
		if (t == "display") {
			Parser.syntaxWarningWithPos(ctx, core.Message.WarningCode.WIfDisplay, p);
			if (ctx.config.specialIdentifierFiles != null) ctx.config.specialIdentifierFiles.replace(core.Path.UniqueKey.create(p.pfile),
				t);
		}
		return mk(EConst(Ident(t)), p);
	}

	public static function parseMacroCond(ctx:ParserContext, s:S):{token:Null<ParserToken>, expr:Expr} {
		parsingMacroCond = true;
		try {
			var cond = parseMacroCond2(ctx, s);
			parsingMacroCond = false;
			return cond;
		} catch (e:haxe.Exception) {
			parsingMacroCond = false;
			throw e;
		}
	}

	static function parseMacroCond2(ctx:ParserContext, s:S):{token:Null<ParserToken>, expr:Expr} {
		var tk = peek(s);
		var p = tk.pos;
		switch tk.token {
			case Const(Ident(t)):
				s.junk();
				return {token: null, expr: parseMacroIdent(ctx, t, p, s)};
			case Const(String(str, qs)):
				s.junk();
				return {token: null, expr: mk(EConst(String(str, qs)), p)};
			case Const(Int(i, suffix)):
				s.junk();
				return {token: null, expr: mk(EConst(Int(i, suffix)), p)};
			case Const(Float(f, suffix)):
				s.junk();
				return {token: null, expr: mk(EConst(Float(f, suffix)), p)};
			case Kwd(k):
				s.junk();
				return {token: null, expr: parseMacroIdent(ctx, sKeyword(k), p, s)};
			case Unop(op):
				s.junk();
				var r = tail(function() return parseMacroCond(ctx, s));
				return {token: r.token, expr: Parser.makeUnop(op, r.expr, p)};
			case POpen:
				var p1 = p;
				s.junk();
				var e = tail(function() return expr(ctx, s));
				var p2 = expectTok(s, PClose);
				return {token: null, expr: mk(EParenthesis(validateMacroCond(ctx, s, e)), punion(p1, p2))};
			case _:
				return fail();
		}
	}
}

private typedef FieldParts = {
	var name:PlacedName;
	var pos:Pos;
	var kind:ClassFieldKind;
	var access:Array<PlacedAccess>;
	var meta:Metadata;
}
