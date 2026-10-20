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

import core.display.DisplayPosition;
import core.DisplayTypes;
import core.DisplayTypes.DisplayModeValue;
import core.Globals;
import core.Globals.Pos;
import core.Ast;
import core.Define;
import core.Define.DefineContext;
import syntax.Parser;
import syntax.Lexer.LexerContext;
import syntax.SemVer;
import core.ds.Stream;

// eval
enum SmallType {
	TNull;
	TBool(value:Bool);
	TFloat(value:Float);
	TString(value:String);
	TVersion(value:SemVer);
}

private class ComparisonExit extends haxe.Exception {
	public function new() super("Incomparable conditional values");
}

private class ComparisonError extends haxe.Exception {}

class ConditionHandler {
	var conditionalExpressions:Array<Expr> = [];
	var conditionalStack:Array<{expr:Expr, elseSeen:Bool}> = [];
	var depths:Array<Int> = [];

	public function new() {}

	function maybeParent(allowAnd:Bool, e:Expr):Expr return switch e.expr {
		case EBinop(op, _, _): op == OpBoolAnd && allowAnd ? e : {expr: EParenthesis(e), pos: e.pos};
		case _: e;
	};

	function negate(e:Expr):Expr return switch e.expr {
		case EUnop(Not, _, e1): e1;
		case EBinop(OpBoolAnd, e1, e2): {expr: EBinop(OpBoolOr, negate(e1), negate(e2)), pos: e.pos};
		case EBinop(OpBoolOr, e1, e2): {expr: EBinop(OpBoolAnd, negate(e1), negate(e2)), pos: e.pos};
		case _: {expr: EUnop(Not, Prefix, e), pos: e.pos};
	};

	function conjoin(lhs:Expr, rhs:Expr):Expr {
		lhs = maybeParent(true, lhs);
		rhs = maybeParent(true, rhs);
		return {expr: EBinop(OpBoolAnd, lhs, rhs), pos: Ast.punion(lhs.pos, rhs.pos)};
	}

	function condIfInner(e:Expr):Void {
		conditionalExpressions.unshift(e);
		conditionalStack.unshift({expr: e, elseSeen: false});
	}

	public function condIf(e:Expr):Void {
		condIfInner(e);
		depths.unshift(1);
	}

	public function condElse(p:Pos):Void {
		if (conditionalStack.length == 0 || conditionalStack[0].elseSeen) Parser.error(PreprocessorError(InvalidElse), p);
		var first = conditionalStack[0];
		conditionalStack[0] = {expr: negate(first.expr), elseSeen: true};
	}

	public function condElseif(e:Expr, p:Pos):Void {
		condElse(p);
		condIfInner(e);
		if (depths.length == 0) Parser.error(PreprocessorError(InvalidElseif), p);
		depths[0]++;
	}

	public function condEnd(p:Pos):Void {
		if (depths.length == 0) Parser.error(PreprocessorError(InvalidEnd), p);
		var depth = depths.shift();
		for (_ in 0...depth) {
			if (conditionalStack.length == 0) throw "conditionHandler: empty conditional stack";
			conditionalStack.shift();
		}
	}

	public function getCurrentCondition():Expr {
		if (conditionalStack.length == 0) return {expr: EConst(Ident("true")), pos: Globals.nullPos};
		var result = conditionalStack[0].expr;
		for (entry in conditionalStack.slice(1)) result = conjoin(result, entry.expr);
		return result;
	}

	public function getConditions():Array<Expr> return conditionalExpressions;
}

class DeadBlockCollector {
	final conds:ConditionHandler;
	var deadBlocks:Array<{pos:Pos, expr:Expr}> = [];
	var currentBlock:Array<{pos:Pos, expr:Expr}> = [];

	public function new(conds:ConditionHandler) this.conds = conds;

	public function openDeadBlock(p:Pos):Void currentBlock.unshift({
		pos: {pfile: p.pfile, pmin: p.pmax, pmax: p.pmax},
		expr: conds.getCurrentCondition()
	});

	public function closeDeadBlock(p:Pos):Void {
		if (currentBlock.length == 0) Parser.error(Custom("Internal error: Trying to close dead block that's not open"), p);
		var first = currentBlock.shift();
		deadBlocks.push({pos: {pfile: first.pos.pfile, pmin: first.pos.pmin, pmax: p.pmin}, expr: first.expr});
	}

	public function getDeadBlocks():Array<{pos:Pos, expr:Expr}> {
		if (currentBlock.length != 0) throw "Unclosed dead blocks";
		return deadBlocks;
	}
}

class ParserEntry {
	public static function isTrue(value:SmallType):Bool return switch value {
		case TBool(false), TNull, TFloat(0): false;
		case _: true;
	};

	public static function sSmallType(value:SmallType):String return switch value {
		case TNull: "null";
		case TBool(_): "boolean";
		case TFloat(_): "float";
		case TString(_): "string";
		case TVersion(_): "version";
	};

	public static function sValue(value:SmallType):String return switch value {
		case TNull: "null";
		case TBool(b): "boolean " + Std.string(b);
		case TFloat(f): "float " + core.Numeric.stringOfFloat(f);
		case TString(s): "string \"" + s + "\"";
		case TVersion(v): "version " + SemVerTools.toString(v);
	};

	public static function parseVersion(s:String, p:Pos):SmallType {
		try return TVersion(SemVerTools.parseVersion(s))
		catch (err:core.ds.InvalidArgument) return Parser.error(Custom(err.message), p);
	}

	public static function cmp(v1:SmallType, v2:SmallType):Int return switch [v1, v2] {
		case [TNull, _], [_, TNull]: throw new ComparisonExit();
		case [TFloat(a), TFloat(b)]: Reflect.compare(a, b);
		case [TString(a), TString(b)]: core.ds.Key.compareStrings(a, b);
		case [TBool(a), TBool(b)]: Reflect.compare(a, b);
		case [TVersion(a), TVersion(b)]: SemVerTools.compareVersion(a, b);
		case [TString(_), TFloat(_)], [TFloat(_), TString(_)], [_, TVersion(_)],
			[TVersion(_), _]: throw new ComparisonError("Cannot compare "
				+ sValue(v1) + " and " + sValue(v2));
		case _: throw new ComparisonExit(); // always false
	};

	static function numeric(s:String):Float {
		return core.ds.OcamlFloat.ofString(s);
	}

	public static function eval(ctx:DefineContext, e:Expr):SmallType return switch e.expr {
		case EConst(Ident(i)): Define.rawDefined(ctx, i) ? TString(Define.rawDefinedValue(ctx, i)) : TNull;
		case EConst(String(s, _)): TString(s);
		case EConst(Int(i, _)): TFloat(numeric(i));
		case EConst(Float(f, _)): TFloat(numeric(f));
		case ECall({expr: EConst(Ident("version"))}, [{expr: EConst(String(s, _)), pos: p}]): parseVersion(s, p);
		case EBinop(OpBoolAnd, e1, e2): TBool(isTrue(eval(ctx, e1)) && isTrue(eval(ctx, e2)));
		case EBinop(OpBoolOr, e1, e2): TBool(isTrue(eval(ctx, e1)) || isTrue(eval(ctx, e2)));
		case EUnop(Not, _, e): TBool(!isTrue(eval(ctx, e)));
		case EParenthesis(e): eval(ctx, e);
		case EBinop(op, e1, e2):
			var values = evalBinopExprs(ctx, e1, e2);
			// port: a single try: HashLink mishandles returning from a nested try here.
			function compare(op:Int->Int->Bool):SmallType {
				var c:Int;
				try c = cmp(values.left, values.right)
				catch (_:ComparisonExit) return TBool(false)
				catch (err:ComparisonError) return Parser.error(Custom(err.message), e.pos);
				return TBool(op(c, 0));
			}
			switch op {
				case OpEq: compare(function(a, b) return a == b);
				case OpNotEq: TBool(!isTrue(compare(function(a, b) return a == b)));
				case OpGt: compare(function(a, b) return a > b);
				case OpGte: compare(function(a, b) return a >= b);
				case OpLt: compare(function(a, b) return a < b);
				case OpLte: compare(function(a, b) return a <= b);
				case _: Parser.error(Custom("Unsupported operation"), e.pos);
			}
		case EField(_, _, _):
			try {
				var sl = Ast.stringListOfExprPathRaise(e);
				sl.reverse();
				var i = sl.join(".");
				Define.rawDefined(ctx, i) ? TString(Define.rawDefinedValue(ctx, i)) : TNull;
			} catch (_:core.ds.Exit) Parser.error(Custom("Invalid condition expression"), e.pos);
		case _: Parser.error(Custom("Invalid condition expression"), e.pos);
	};

	/**
		Attempt to auto-cast operands to a common type
	**/
	public static function evalBinopExprs(ctx:DefineContext, e1:Expr, e2:Expr):{left:SmallType, right:SmallType} {
		var v1 = eval(ctx, e1);
		var v2 = eval(ctx, e2);
		switch [v1, v2] {
			case [TString(s1), TFloat(_)]:
				try v1 = TFloat(numeric(s1))
				catch (_:Dynamic) {}
			case [TFloat(_), TString(s2)]:
				try v2 = TFloat(numeric(s2))
				catch (_:Dynamic) {}
			case [TVersion(_), TString(s)]:
				v2 = parseVersion(s, e2.pos);
			case [TString(s), TVersion(_)]:
				v1 = parseVersion(s, e1.pos);
			case _:
		}
		return {left: v1, right: v2};
	}

	// parse main
	public static function parse<T>(config:ParserConfiguration, entry:ParserContext->Stream<syntax.Lexer.LexedToken>->T,
			lctx:LexerContext, code:Lexer, file:String):ParseResult<T> {
		var defines = config.defines;
		var ctx = Parser.createContext(lctx, config, Define.rawDefined(defines, "macro"), code);
		var parseEntry = entry.bind(ctx);
		Lexer.skipHeader(code);
		inline function sharpError(s:String,
				p:Pos):Dynamic return Parser.error(Custom(core.StringError.stringError("#" + s,
				["#if", "#elseif", "#else", "#end", "#error", "#line"], "Unknown token")), p);
		var conds = new ConditionHandler();
		var dbc = new DeadBlockCollector(conds);
		var lexerToken = Lexer.makeToken(lctx);
		var sraw = new Stream<syntax.Lexer.LexedToken>(function(_) return Lexer.sharpToken(lctx, code));
		inline function preprocessorError(ppe:ParserPreprocessorError, pos:Pos,
				tk:ParserToken):ParserToken return Parser.syntaxError(ctx, PreprocessorError(ppe), sraw, tk, pos);
		var nextToken:Void->ParserToken = null;
		var processToken:ParserToken->ParserToken = null;
		var enterMacro:Bool->Pos->ParserToken = null;
		var skipTokensLoop:Pos->Bool->ParserToken->ParserToken = null;
		var skipTokens:Pos->Bool->ParserToken = null;
		nextToken = function() return processToken(lexerToken(code));
		// port: upstream's tail calls of next_token and process_token (one per
		// comment and per conditional) go round a loop: a host without tail
		// calls, such as WebAssembly, would nest frames per token
		processToken = function(tk:ParserToken):ParserToken {
			while (true) {
				switch tk.token {
					case Comment(s):
						// if encloses_resume (pos tk) then syntax_completion SCComment (pos tk);
						var len = s.length;
						if (len > 0 && s.charAt(0) == "*") ctx.lastDoc = {
							doc: s.substr(1, len - (len > 1 && s.charAt(len - 1) == "*" ? 2 : 1)),
							position: tk.pos.pmin
						};
						tk = lexerToken(code);
					case CommentLine(_):
						if (ctx.config.inDisplayFile) {
							var p = tk.pos;
							// Completion at the / should not pick up the comment (issue #9133)
							if (Parser.isCompletion(ctx)) p = {pfile: p.pfile, pmin: p.pmin + 1, pmax: p.pmax};
							// The > 0 check is to deal with the special case of line comments at the beginning of the file (issue #10322)
							if (DisplayPosition.displayPosition.enclosedIn(p) && p.pmin > 0) Parser.syntaxCompletion(SCComment, null, tk.pos);
						}
						tk = lexerToken(code);
					case Sharp("end"):
						conds.condEnd(tk.pos);
						tk = lexerToken(code);
					case Sharp("elseif"):
						var cond = Grammar.parseMacroCond(ctx, sraw);
						conds.condElseif(cond.expr, tk.pos);
						dbc.openDeadBlock(cond.expr.pos);
						tk = skipTokens(tk.pos, false);
					case Sharp("else"):
						conds.condElse(tk.pos);
						dbc.openDeadBlock(tk.pos);
						tk = skipTokens(tk.pos, false);
					case Sharp("if"):
						tk = enterMacro(true, tk.pos);
					case Sharp("error"):
						var token:ParserToken = lexerToken(code);
						return switch token.token {
							case Const(String(s, _)): Parser.error(Custom(s), token.pos);
							case _: Parser.error(Unimplemented, tk.pos);
						}
					case Sharp("line"):
						var token = nextToken();
						var line:Int = switch token.token {
							case Const(Int(s, _)):
								var parsed = Std.parseInt(s);
								if (parsed == null) Parser.error(Custom("Could not parse ridiculous line number " + s), token.pos);
								parsed;
							case t: Parser.error(Unexpected(t), token.pos);
						};
						lctx.file.lline = line - 1;
						tk = lexerToken(code);
					case Sharp(s):
						return sharpError(s, tk.pos);
					case _:
						return tk;
				}
			}
		};
		enterMacro = function(isIf:Bool, p:Pos):ParserToken {
			var condition = Grammar.parseMacroCond(ctx, sraw);
			if (isIf) conds.condIf(condition.expr);
			else conds.condElseif(condition.expr, p);
			var tk:ParserToken = condition.token == null ? lexerToken(code) : condition.token;
			if (isTrue(eval(defines, condition.expr))) return tk;
			dbc.openDeadBlock(condition.expr.pos);
			return skipTokensLoop(p, true, tk);
		};
		// port: the tail calls of skip_tokens (one per skipped token) and
		// skip_tokens_loop go round a loop, as in processToken
		skipTokensLoop = function(p:Pos, test:Bool, tk:ParserToken):ParserToken {
			while (true) {
				switch tk.token {
					case Sharp("end"):
						conds.condEnd(tk.pos);
						dbc.closeDeadBlock(tk.pos);
						return lexerToken(code);
					case Sharp("elseif") if (!test):
						dbc.closeDeadBlock(tk.pos);
						var condition = Grammar.parseMacroCond(ctx, sraw);
						conds.condElseif(condition.expr, tk.pos);
						dbc.openDeadBlock(condition.expr.pos);
						tk = lexerToken(code);
					case Sharp("else") if (!test):
						conds.condElse(tk.pos);
						dbc.closeDeadBlock(tk.pos);
						dbc.openDeadBlock(tk.pos);
						tk = lexerToken(code);
					case Sharp("else"):
						conds.condElse(tk.pos);
						dbc.closeDeadBlock(tk.pos);
						return lexerToken(code);
					case Sharp("elseif"):
						dbc.closeDeadBlock(tk.pos);
						return enterMacro(false, tk.pos);
					case Sharp("if"):
						var condition = Grammar.parseMacroCond(ctx, sraw);
						conds.condIf(condition.expr);
						dbc.openDeadBlock(condition.expr.pos);
						tk = skipTokens(p, false);
					case Sharp("error"), Sharp("line"):
						tk = lexerToken(code);
					case Sharp(s):
						return sharpError(s, tk.pos);
					case Eof:
						return preprocessorError(UnclosedConditional, p, tk);
					case _:
						tk = lexerToken(code);
				}
			}
		};
		skipTokens = function(p, test) return skipTokensLoop(p, test, lexerToken(code));
		var stream = new Stream<syntax.Lexer.LexedToken>(function(_) {
			var token = nextToken();
			ctx.cache.push(token);
			return token;
		});
		try {
			var data = parseEntry(stream);
			var next:ParserToken = stream.peek();
			// null: Eof could already have been consumed
			// Eof: This is what we want
			// anything else: This isn't
			if (next != null && next.token != Eof) Parser.error(Unexpected(next.token), next.pos);
			var errors = ctx.syntaxErrors.copy();
			errors.reverse();
			var warnings = ctx.syntaxWarnings.copy();
			warnings.reverse();
			var display:ParserDisplayInformation = {
				pdErrors: errors,
				pdWarnings: warnings,
				pdDeadBlocks: dbc.getDeadBlocks(),
				pdConditions: conds.getConditions(),
				pdWasDisplayFile: ctx.config.inDisplayFile,
				pdHadResume: ctx.hadResume,
				pdDelayedSyntaxCompletion: ctx.delayedSyntaxCompletion
			};
			return ctx.config.inDisplayFile
				|| errors.length == 0 ? ParseSuccess(data, display) : ParseError(data, errors[0], errors.slice(1));
		} catch (_:StreamError) {
			var last:ParserToken = stream.peek();
			if (last == null) last = Parser.lastToken(ctx, stream);
			return Parser.error(Unexpected(last.token), last.pos);
		} catch (_:StreamFailure) {
			var last:ParserToken = stream.peek();
			if (last == null) last = Parser.lastToken(ctx, stream);
			return Parser.error(Unexpected(last.token), last.pos);
		}
	}

	public static function parseString<T>(config:ParserConfiguration, entry:ParserContext->Stream<syntax.Lexer.LexedToken>->T, s:String,
			p:Pos, error:String->Pos->ParseResult<T>, inlined:Bool):ParseResult<T> {
		var oldDisplay = DisplayPosition.displayPosition.get();
		inline function restore():Void {
			if (!inlined) DisplayPosition.displayPosition.set(oldDisplay);
		}
		var lctx = Lexer.createTempCtx(p.pfile);
		if (!inlined) {
			DisplayPosition.displayPosition.reset();
			config = core.ds.Record.copy(config);
			config.inDisplayFile = false;
		}
		var result:ParseResult<T>;
		try result = parse(config, entry, lctx, Lexer.lexbufFromUtf8String(s), p.pfile)
		catch (err:ParserError) {
			restore();
			result = error(Parser.errorMsg(err.error), inlined ? err.pos : p);
		} catch (err:syntax.Lexer.LexerError) {
			restore();
			result = error(Lexer.errorMsg(err.message), inlined ? err.pos : p);
		} catch (err:haxe.Exception) {
			restore();
			throw err;
		}
		restore();
		return result;
	}

	// port: `String.make n ' '`, by doubling (StringTools.lpad is quadratic on hxcpp).
	static function makeSpaces(n:Int):String {
		var r = "", chunk = " ";
		while (n > 0) {
			if (n & 1 != 0) r += chunk;
			chunk += chunk;
			n >>= 1;
		}
		return r;
	}

	public static function parseExprString(config:ParserConfiguration, s:String, p:Pos, error:String->Pos->ParseResult<Expr>,
			inlined:Bool):ParseResult<Expr> {
		if (p.pmin > 0) s = makeSpaces(p.pmin) + s;
		var result = parseString(config, Grammar.parseExpressionStream, s, p, error, inlined);
		if (inlined) return result;
		function loop(e:Expr):Expr {
			var mapped = Ast.mapExpr(loop, e);
			return {expr: mapped.expr, pos: p};
		}
		return switch result {
			case ParseSuccess(data, display): ParseSuccess(loop(data), display);
			case ParseError(data, error, errors): ParseError(loop(data), error, errors);
		};
	}
}
