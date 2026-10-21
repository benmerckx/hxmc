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
import core.Ast;
import core.Globals;
import core.Globals.Pos;
import core.Define.DefineContext;
import core.ds.Stream;
import core.Message.WarningCode;
import syntax.Lexer.LexerContext;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

enum ParserPreprocessorError {
	InvalidEnd;
	InvalidElse;
	InvalidElseif;
	UnclosedConditional;
}

enum ErrorMsg {
	Unexpected(token:Token);
	DuplicateDefault;
	MissingSemicolon;
	PreprocessorError(error:ParserPreprocessorError);
	Unimplemented;
	MissingType;
	Expected(values:Array<String>);
	StreamError(message:String);
	Custom(message:String);
}

enum DeclFlag {
	DPrivate;
	DExtern;
	DFinal;
	DMacro;
	DDynamic;
	DInline;
	DPublic;
	DStatic;
	DOverload;
}

enum TypeDeclCompletionMode {
	TCBeforePackage;
	TCAfterImport;
	TCAfterType;
}

enum SyntaxCompletion {
	SCComment;
	SCClassRelation;
	SCInterfaceRelation;
	SCTypeDecl(mode:TypeDeclCompletionMode);
	SCAfterTypeFlag(flags:Array<DeclFlag>);
}

enum SequenceParsingResult<T> {
	Success(value:T);
	End(pos:Pos);
	Error(message:String);
}

@:structInit class SyntaxCompletionOn {
	public var kind:SyntaxCompletion;
	public var subject:core.DisplayTypes.CompletionSubject;

	public inline function new(kind:SyntaxCompletion, subject:core.DisplayTypes.CompletionSubject) {
		this.kind = kind;
		this.subject = subject;
	}

	public inline function clone():SyntaxCompletionOn return new SyntaxCompletionOn(kind, subject);
}

class ParserError extends haxe.Exception {
	public final error:ErrorMsg;
	public final pos:Pos;

	public function new(error:ErrorMsg, pos:Pos) {
		super(Parser.errorMsg(error));
		this.error = error;
		this.pos = pos;
	}
}

class TypePathCompletion extends haxe.Exception {
	public final pack:Array<String>;
	public final type:Null<{name:String, isSub:Bool}>;
	public final inImport:Bool; // in import
	public final pos:Pos;

	public function new(pack, type, inImport, pos) {
		super("TypePath");
		this.pack = pack;
		this.type = type;
		this.inImport = inImport;
		this.pos = pos;
	}
}

class SyntaxCompletionException extends haxe.Exception {
	public final completion:SyntaxCompletionOn;

	public function new(completion) {
		super("SyntaxCompletion");
		this.completion = completion;
	}
}

@:structInit class ParserConfiguration {
	public var defines:DefineContext;
	public var inDisplay:Bool;
	public var inDisplayFile:Bool;
	public var displayMode:DisplayModeValue;
	public var wasAutoTriggered:Bool;
	public var specialIdentifierFiles:Null<core.ds.ThreadSafeHashtbl<String, String>>;

	public inline function new(defines:DefineContext, inDisplay:Bool, inDisplayFile:Bool, displayMode:DisplayModeValue,
			wasAutoTriggered:Bool, specialIdentifierFiles:Null<core.ds.ThreadSafeHashtbl<String, String>>) {
		this.defines = defines;
		this.inDisplay = inDisplay;
		this.inDisplayFile = inDisplayFile;
		this.displayMode = displayMode;
		this.wasAutoTriggered = wasAutoTriggered;
		this.specialIdentifierFiles = specialIdentifierFiles;
	}

	public inline function clone():ParserConfiguration return new ParserConfiguration(defines, inDisplay, inDisplayFile, displayMode,
		wasAutoTriggered, specialIdentifierFiles);
}

@:structInit class ParserContext {
	public var lexerCtx:LexerContext;
	public var syntaxErrors:Array<ParseErrorInfo>;
	public var syntaxWarnings:Array<ParseWarning>;
	public var lastDoc:Null<{doc:String, position:Int}>;
	public var inMacro:Bool;
	public var code:Lexer;
	public var hadResume:Bool;
	public var delayedSyntaxCompletion:Null<SyntaxCompletionOn>;
	public var cache:Array<ParserToken>;
	public var config:ParserConfiguration;

	public inline function new(lexerCtx:LexerContext, syntaxErrors:Array<ParseErrorInfo>, syntaxWarnings:Array<ParseWarning>,
			lastDoc:Null<{doc:String, position:Int}>, inMacro:Bool, code:Lexer, hadResume:Bool,
			delayedSyntaxCompletion:Null<SyntaxCompletionOn>, cache:Array<ParserToken>, config:ParserConfiguration) {
		this.lexerCtx = lexerCtx;
		this.syntaxErrors = syntaxErrors;
		this.syntaxWarnings = syntaxWarnings;
		this.lastDoc = lastDoc;
		this.inMacro = inMacro;
		this.code = code;
		this.hadResume = hadResume;
		this.delayedSyntaxCompletion = delayedSyntaxCompletion;
		this.cache = cache;
		this.config = config;
	}

	public inline function clone():ParserContext return new ParserContext(lexerCtx, syntaxErrors, syntaxWarnings, lastDoc, inMacro, code,
		hadResume, delayedSyntaxCompletion, cache, config);
}

typedef ParserToken = syntax.Lexer.LexedToken;
typedef ParseData = Package;

@:structInit class ParseErrorInfo {
	public var message:ErrorMsg;
	public var pos:Pos;

	public inline function new(message:ErrorMsg, pos:Pos) {
		this.message = message;
		this.pos = pos;
	}

	public inline function clone():ParseErrorInfo return new ParseErrorInfo(message, pos);
}

@:structInit class ParseWarning {
	public var warning:WarningCode;
	public var pos:Pos;

	public inline function new(warning:WarningCode, pos:Pos) {
		this.warning = warning;
		this.pos = pos;
	}

	public inline function clone():ParseWarning return new ParseWarning(warning, pos);
}

@:structInit class ParserDisplayInformation {
	public var pdErrors:Array<ParseErrorInfo>;
	public var pdWarnings:Array<ParseWarning>;
	public var pdDeadBlocks:Array<{pos:Pos, expr:Expr}>;
	public var pdConditions:Array<Expr>;
	public var pdWasDisplayFile:Bool;
	public var pdHadResume:Bool;
	public var pdDelayedSyntaxCompletion:Null<SyntaxCompletionOn>;

	public inline function new(pdErrors:Array<ParseErrorInfo>, pdWarnings:Array<ParseWarning>, pdDeadBlocks:Array<{pos:Pos, expr:Expr}>,
			pdConditions:Array<Expr>, pdWasDisplayFile:Bool, pdHadResume:Bool, pdDelayedSyntaxCompletion:Null<SyntaxCompletionOn>) {
		this.pdErrors = pdErrors;
		this.pdWarnings = pdWarnings;
		this.pdDeadBlocks = pdDeadBlocks;
		this.pdConditions = pdConditions;
		this.pdWasDisplayFile = pdWasDisplayFile;
		this.pdHadResume = pdHadResume;
		this.pdDelayedSyntaxCompletion = pdDelayedSyntaxCompletion;
	}

	public inline function clone():ParserDisplayInformation return new ParserDisplayInformation(pdErrors, pdWarnings, pdDeadBlocks,
		pdConditions, pdWasDisplayFile, pdHadResume, pdDelayedSyntaxCompletion);
}

enum ParseResult<T> {
	ParseSuccess(data:T, display:ParserDisplayInformation);
	ParseError(data:T, error:ParseErrorInfo, errors:Array<ParseErrorInfo>);
}

class Parser {
	public static function errorMsg(error:ErrorMsg):String return switch error {
		case Unexpected(Kwd(k)): "Unexpected keyword \"" + Ast.sKeyword(k) + "\"";
		case Unexpected(t): "Unexpected " + Ast.sToken(t);
		case DuplicateDefault: "Duplicate default";
		case MissingSemicolon: "Missing ;";
		case PreprocessorError(ppe): switch ppe {
				case UnclosedConditional: "Unclosed conditional compilation block";
				case InvalidEnd: "Invalid #end";
				case InvalidElse: "Invalid #else";
				case InvalidElseif: "Invalid #elseif";
			};
		case Unimplemented: "Not implemented for current platform";
		case MissingType: "Missing type declaration";
		case Expected(sl): "Expected " + sl.join(" or ");
		case StreamError(s), Custom(s): s;
	};

	public static function createContext(lexerCtx:LexerContext, config:ParserConfiguration, inMacro:Bool, code:Lexer):ParserContext return {
		lexerCtx: lexerCtx,
		syntaxErrors: [],
		syntaxWarnings: [],
		lastDoc: null,
		inMacro: inMacro,
		code: code,
		hadResume: false,
		delayedSyntaxCompletion: null,
		cache: [],
		config: config
	};

	public static function createConfig(defines:DefineContext, inDisplay:Bool, inDisplayFile:Bool, displayMode:DisplayModeValue,
			wasAutoTriggered:Bool, specialIdentifierFiles:Null<core.ds.ThreadSafeHashtbl<String, String>>):ParserConfiguration return {
			defines: defines,
			inDisplay: inDisplay,
			inDisplayFile: inDisplayFile,
			displayMode: displayMode,
			wasAutoTriggered: wasAutoTriggered,
			specialIdentifierFiles: specialIdentifierFiles
		};

	public static function sDeclFlag(flag:DeclFlag):String return switch flag {
		case DPrivate: "private";
		case DExtern: "extern";
		case DFinal: "final";
		case DMacro: "macro";
		case DDynamic: "dynamic";
		case DInline: "inline";
		case DPublic: "public";
		case DStatic: "static";
		case DOverload: "overload";
	};

	public static function syntaxCompletion(kind:SyntaxCompletion, so:Null<String>,
			p:Pos):Dynamic throw new SyntaxCompletionException({kind: kind, subject: DisplayTypes.makeSubject(so, p)});

	public static function error(m:ErrorMsg, p:Pos):Dynamic throw new ParserError(m, p);

	public static function lastToken(ctx:ParserContext, s:Stream<syntax.Lexer.LexedToken>):ParserToken {
		var n:Int = s.count();
		return ctx.cache[n == 0 ? 0 : n - 1];
	}

	public static function lastPos(ctx:ParserContext, s:Stream<syntax.Lexer.LexedToken>):Pos return lastToken(ctx, s).pos;

	public static function nextToken(ctx:ParserContext, s:Stream<syntax.Lexer.LexedToken>):ParserToken {
		var tk:ParserToken = s.peek();
		return tk == null ? {token: Eof, pos: lastToken(ctx, s).pos} : tk;
	}

	public static function nextPos(ctx:ParserContext, s:Stream<syntax.Lexer.LexedToken>):Pos return nextToken(ctx, s).pos;

	public static function resetState():Void DisplayPosition.displayPosition.reset();

	public static function syntaxErrorWithPos<T>(ctx:ParserContext, message:ErrorMsg, p:Pos, v:T):T {
		if (p.pmax == 0x7FFFFFFF) p = {pfile: p.pfile, pmin: p.pmin, pmax: p.pmin + 1};
		if (!ctx.config.inDisplay) error(message, p);
		ctx.syntaxErrors.unshift({message: message, pos: p});
		return v;
	}

	public static function syntaxError<T>(ctx:ParserContext, message:ErrorMsg, s:Stream<syntax.Lexer.LexedToken>, v:T,
			?pos:Pos):T return syntaxErrorWithPos(ctx, message, pos == null ? nextPos(ctx, s) : pos, v);

	public static function syntaxWarningWithPos(ctx:ParserContext, warning:WarningCode, p:Pos):Void {
		if (p.pmax == 0x7FFFFFFF) p = {pfile: p.pfile, pmin: p.pmin, pmax: p.pmin + 1};
		ctx.syntaxWarnings.unshift({warning: warning, pos: p});
	}

	public static function syntaxWarning(ctx:ParserContext, warning:WarningCode, s:Stream<syntax.Lexer.LexedToken>,
			?pos:Pos):Void syntaxWarningWithPos(ctx, warning, pos == null ? nextPos(ctx, s) : pos);

	public static function handleStreamError(ctx:ParserContext, msg:String, s:Stream<syntax.Lexer.LexedToken>):Void {
		if (msg == "Parse error.") {
			var next = nextToken(ctx, s);
			syntaxError(ctx, Unexpected(next.token), s, null, next.pos);
		} else syntaxError(ctx, StreamError(msg), s, null);
	}

	public static function getDoc(ctx:ParserContext, s:Stream<syntax.Lexer.LexedToken>):Null<String> {
		// do the peek first to make sure we fetch the doc
		if (s.peek() == null || ctx.lastDoc == null) return null;
		var doc = ctx.lastDoc.doc;
		ctx.lastDoc = null;
		return doc;
	}

	public static function unsupportedDeclFlag<T>(decl:String, flag:DeclFlag, pos:Pos,
			ctx:ParserContext):Null<T> return syntaxErrorWithPos(ctx, Custom(sDeclFlag(flag) + " modifier is not supported for " + decl),
			pos,
			null);

	public static function unsupportedDeclFlagClass<T>(flag:DeclFlag, pos:Pos,
			ctx:ParserContext):Null<T> return unsupportedDeclFlag("classes", flag, pos, ctx);

	public static function unsupportedDeclFlagEnum<T>(flag:DeclFlag, pos:Pos,
			ctx:ParserContext):Null<T> return unsupportedDeclFlag("enums", flag, pos, ctx);

	public static function unsupportedDeclFlagAbstract<T>(flag:DeclFlag, pos:Pos,
			ctx:ParserContext):Null<T> return unsupportedDeclFlag("abstracts", flag, pos, ctx);

	public static function unsupportedDeclFlagTypedef<T>(flag:DeclFlag, pos:Pos,
			ctx:ParserContext):Null<T> return unsupportedDeclFlag("typedefs", flag, pos, ctx);

	public static function unsupportedDeclFlagModuleField<T>(flag:DeclFlag, pos:Pos,
			ctx:ParserContext):Null<T> return unsupportedDeclFlag("module-level fields", flag, pos, ctx);

	public static function declFlagToClassFlag(ctx:ParserContext, entry:{flag:DeclFlag, pos:Pos}):Null<ClassFlag> return switch entry.flag {
		case DPrivate: HPrivate;
		case DExtern: HExtern;
		case DFinal: HFinal;
		case _: unsupportedDeclFlagClass(entry.flag, entry.pos, ctx);
	};

	public static function declFlagToEnumFlag(ctx:ParserContext, entry:{flag:DeclFlag, pos:Pos}):Null<EnumFlag> return switch entry.flag {
		case DPrivate: EPrivate;
		case DExtern: EExtern;
		case _: unsupportedDeclFlagEnum(entry.flag, entry.pos, ctx);
	};

	public static function declFlagToAbstractFlag(ctx:ParserContext,
			entry:{flag:DeclFlag, pos:Pos}):Null<AbstractFlag> return switch entry.flag {
			case DPrivate: AbPrivate;
			case DExtern: AbExtern;
			case _: unsupportedDeclFlagAbstract(entry.flag, entry.pos, ctx);
		};

	public static function declFlagToTypedefFlag(ctx:ParserContext,
			entry:{flag:DeclFlag, pos:Pos}):Null<TypedefFlag> return switch entry.flag {
			case DPrivate: TDPrivate;
			case DExtern: TDExtern;
			case _: unsupportedDeclFlagTypedef(entry.flag, entry.pos, ctx);
		};

	public static function declFlagToModuleFieldFlag(ctx:ParserContext,
			entry:{flag:DeclFlag, pos:Pos}):Null<PlacedAccess> return switch entry.flag {
			case DPrivate: {access: APrivate, pos: entry.pos};
			case DMacro: {access: AMacro, pos: entry.pos};
			case DDynamic: {access: ADynamic, pos: entry.pos};
			case DInline: {access: AInline, pos: entry.pos};
			case DOverload: {access: AOverload, pos: entry.pos};
			case DExtern: {access: AExtern, pos: entry.pos};
			case _: unsupportedDeclFlagModuleField(entry.flag, entry.pos, ctx);
		};

	public static function serror():Dynamic throw new core.ds.Stream.StreamError("Parse error.");

	public static final magicDisplayFieldName = " - display - ";
	public static final magicTypePath:TypePath = {
		tpackage: [],
		tname: "",
		tparams: vector(),
		tsub: null
	};

	public static function magicTypeCt(p:Pos):ComplexType return Ast.makePtpCt(magicTypePath, p);

	public static function magicTypeTh(p:Pos):TypeHint return {type: magicTypeCt(p), pos: p};

	public static function delaySyntaxCompletion(ctx:ParserContext, kind:SyntaxCompletion, so:Null<String>,
			p:Pos):Void ctx.delayedSyntaxCompletion = {
			kind: kind,
			subject: DisplayTypes.makeSubject(so, p)
		};

	public static function typePath(sl:Array<String>, inImport:Bool, p:Pos):Dynamic {
		var reversed = sl.copy();
		reversed.reverse();
		if (sl.length > 0 && sl[0].charAt(0) >= "A" && sl[0].charAt(0) <= "Z") {
			reversed.pop();
			throw new TypePathCompletion(reversed, {name: sl[0], isSub: false}, inImport, p);
		}
		throw new TypePathCompletion(reversed, null, inImport, p);
	}

	public static function wouldSkipDisplayPosition(ctx:ParserContext, p1:Pos, plusOne:Bool, s:Stream<syntax.Lexer.LexedToken>):Bool {
		if (!ctx.config.inDisplayFile) return false;
		var peek:Array<ParserToken> = s.npeek(1);
		if (peek.length != 1) return false;
		var p2 = peek[0].pos;
		return DisplayPosition.displayPosition.enclosedIn({pfile: p2.pfile, pmin: p1.pmax + (plusOne ? 1 : 0), pmax: p2.pmax});
	}

	public static function cutPosAtDisplay(p:Pos):Pos return DisplayPosition.displayPosition.cut(p);

	public static function isDollarIdent(e:Expr):Bool return switch e.expr {
		case EConst(Ident(n)) if (StringTools.startsWith(n, "$")): true;
		case _: false;
	};

	public static function revConcat(s:String, sl:Array<String>):String {
		var reversed = sl.copy();
		reversed.reverse();
		return reversed.join(s);
	}

	public static function precedence(op:Binop):{priority:Int, left:Bool}
		return switch op {
			case OpIn: {priority: 0, left: false};
			case OpMod: {priority: 1, left: true};
			case OpMult, OpDiv: {priority: 2, left: true};
			case OpAdd, OpSub: {priority: 3, left: true};
			case OpShl, OpShr, OpUShr: {priority: 4, left: true};
			case OpOr, OpAnd, OpXor: {priority: 5, left: true};
			case OpNullCoal: {priority: 6, left: true};
			case OpEq, OpNotEq, OpGt, OpLt, OpGte, OpLte: {priority: 7, left: true};
			case OpInterval: {priority: 8, left: true};
			case OpBoolAnd: {priority: 9, left: true};
			case OpBoolOr: {priority: 10, left: true};
			case OpArrow: {priority: 11, left: false};
			case OpAssign, OpAssignOp(_): {priority: 12, left: false};
		};

	public static function isHigherThanTernary(op:Binop):Bool return switch op {
		case OpAssign, OpAssignOp(_), OpArrow: false;
		case _: true;
	};

	public static function swap(op1:Binop, op2:Binop):Bool {
		var p1 = precedence(op1);
		var p2 = precedence(op2);
		return p1.left && p1.priority <= p2.priority;
	}

	public static function makeBinop(op:Binop, e:Expr, e2:Expr):Expr return switch e2.expr {
		case EBinop(other, left, right) if (swap(op, other)):
			var left = makeBinop(op, e, left);
			{expr: EBinop(other, left, right), pos: Ast.punion(left.pos, right.pos)};
		case ETernary(e1, e2, e3) if (isHigherThanTernary(op)):
			var e = makeBinop(op, e, e1);
			{expr: ETernary(e, e2, e3), pos: Ast.punion(e.pos, e3.pos)};
		case _: {expr: EBinop(op, e, e2), pos: Ast.punion(e.pos, e2.pos)};
	};

	public static function makeUnop(op:Unop, e:Expr, p1:Pos):Expr {
		inline function neg(s:String):String return s.charAt(0) == "-" ? s.substr(1) : "-" + s;
		var expr = switch e.expr {
			case EBinop(bop, left, right): EBinop(bop, makeUnop(op, left, p1), right);
			case ETernary(e1, e2, e3): ETernary(makeUnop(op, e1, p1), e2, e3);
			case EIs(e, t): EIs(makeUnop(op, e, p1), t);
			case EConst(Int(i, suffix)) if (op == Neg): EConst(Int(neg(i), suffix));
			case EConst(Float(j, suffix)) if (op == Neg): EConst(Float(neg(j), suffix));
			case _: EUnop(op, Prefix, e);
		};
		return {expr: expr, pos: Ast.punion(p1, e.pos)};
	}

	public static function makeMeta(name:Dynamic, params:haxe.ds.Vector<Expr>, e:Expr, p1:Pos):Expr {
		var expr = switch e.expr {
			case EBinop(OpAssign, _, _), EBinop(OpAssignOp(_), _, _): EMeta({meta: name, exprs: params, pos: p1}, e);
			case EBinop(bop, left, right): EBinop(bop, makeMeta(name, params, left, p1), right);
			case ETernary(e1, e2, e3): ETernary(makeMeta(name, params, e1, p1), e2, e3);
			case _: EMeta({meta: name, exprs: params, pos: p1}, e);
		};
		return {expr: expr, pos: Ast.punion(p1, e.pos)};
	}

	public static function handleXmlLiteral(ctx:ParserContext, p1:Pos):Expr {
		Lexer.reset(ctx.lexerCtx);
		var end = Lexer.lexXml(ctx.lexerCtx, p1.pmin, ctx.code);
		var xml = Lexer.contents(ctx.lexerCtx);
		return makeMeta(core.Meta.Markup, vector(),
			{expr: EConst(String(xml, SDoubleQuotes)), // STRINGTODO: distinct kind?
				pos: {pfile: p1.pfile, pmin: p1.pmin, pmax: end}}, p1);
	}

	public static function punionNext(ctx:ParserContext, p1:Pos,
			s:Stream<syntax.Lexer.LexedToken>):Pos return {pfile: p1.pfile, pmin: p1.pmin, pmax: nextToken(ctx, s).pos.pmax - 1};

	public static function mkNullExpr(p:Pos):Expr return {expr: EConst(Ident("null")), pos: p};

	public static function mkDisplayExpr(e:Expr, dk:DisplayKind):Expr return {expr: EDisplay(e, dk), pos: e.pos};

	public static function isCompletion(ctx:ParserContext):Bool return ctx.config.displayMode == DMDefault;

	public static function isSignatureDisplay(ctx:ParserContext):Bool return ctx.config.displayMode == DMSignature;

	public static function checkResume<T>(ctx:ParserContext, p:Pos, fyes:Void->T, fno:Void->T):T {
		if (isCompletion(ctx) && ctx.config.inDisplayFile && p.pmax == DisplayPosition.displayPosition.get().pmin) {
			ctx.hadResume = true;
			return fyes();
		}
		return fno();
	}

	public static function checkResumeRange<T>(ctx:ParserContext, p:Pos, s:Stream<syntax.Lexer.LexedToken>, fyes:Pos->T, fno:Void->T):T {
		if (isCompletion(ctx) && ctx.config.inDisplayFile) {
			var next = nextPos(ctx, s);
			var display = DisplayPosition.displayPosition.get();
			if (p.pmin < display.pmin && next.pmin >= display.pmax) return fyes(next);
		}
		return fno();
	}

	public static function checkCompletion(ctx:ParserContext, p0:Pos, plusOne:Bool,
			s:Stream<syntax.Lexer.LexedToken>):Null<{name:Null<String>, pos:Pos}> {
		var next:ParserToken = s.peek();
		if (next != null) switch next.token {
			case Const(Ident(name)) if (DisplayPosition.displayPosition.enclosedIn(next.pos)):
				s.junk();
				return {name: name, pos: next.pos};
			case _:
		}
		return wouldSkipDisplayPosition(ctx, p0, plusOne, s) ? {name: null, pos: DisplayPosition.displayPosition.withPos(p0)} : null;
	}

	public static function checkTypeDeclFlagCompletion(ctx:ParserContext, mode:TypeDeclCompletionMode,
			flags:Array<{flag:DeclFlag, pos:Pos}>, s:Stream<syntax.Lexer.LexedToken>):Void {
		if (!ctx.config.inDisplayFile || !isCompletion(ctx)) throw core.ds.Stream.StreamFailure.raise();
		var next:ParserToken = s.peek();
		if (next != null) switch next.token {
			// If there's an identifier coming up, it's probably an incomplete type
			// declaration. Let's just raise syntax completion in that case because
			// the parser would fail otherwise anyway.
			case Const(Ident(name)) if (DisplayPosition.displayPosition.enclosedIn(next.pos)):
				syntaxCompletion(flags.length == 0 ? SCTypeDecl(mode) : SCAfterTypeFlag(flags.map(function(entry) return entry.flag)),
					name, next.pos);
			case _:
		}
		if (flags.length > 0
			&& wouldSkipDisplayPosition(ctx, flags[0].pos, true,
				s)) syntaxCompletion(SCAfterTypeFlag(flags.map(function(entry) return entry.flag)), null,
				DisplayPosition.displayPosition.withPos(flags[0].pos));
		else throw core.ds.Stream.StreamFailure.raise();
	}

	public static function checkTypeDeclCompletion(ctx:ParserContext, mode:TypeDeclCompletionMode, pmax:Int,
			s:Stream<syntax.Lexer.LexedToken>):Void {
		if (!ctx.config.inDisplayFile || !isCompletion(ctx)) return;
		var next:ParserToken = s.peek();
		var pmin = next == null || next.token == Eof ? 0x7FFFFFFF : next.pos.pmin;
		var p:Pos = DisplayPosition.displayPosition.get();
		// print_endline (Printf.sprintf "(%i <= %i) (%i >= %i)" pmax p.pmin pmin p.pmax);
		if (pmax <= p.pmin && pmin >= p.pmax) {
			var so:Null<String> = null;
			if (next != null) {
				p = next.pos;
				switch next.token {
					case Const(Ident(name)) if (DisplayPosition.displayPosition.enclosedIn(p)):
						so = name;
					case _:
				}
			}
			delaySyntaxCompletion(ctx, SCTypeDecl(mode), so, p);
		}
	}

	public static function checkSignatureMark(ctx:ParserContext, e:Expr, p1:Pos, p2:Pos):Expr {
		if (!isSignatureDisplay(ctx)) return e;
		var p = Ast.punion(p1, p2);
		if (true || !ctx.config.wasAutoTriggered) // TODO: #6383
			return DisplayPosition.enclosesPositionGt(DisplayPosition.displayPosition.get(),
			p) ? mkDisplayExpr(e, DKMarked) : e;
		return DisplayPosition.displayPosition.get().pmin == p1.pmax ? mkDisplayExpr(e, DKMarked) : e;
	}

	public static function convertAbstractFlags(ctx:ParserContext, flags:Array<{flag:DeclFlag, pos:Pos}>):Array<AbstractFlag> {
		var out = [];
		for (flag in flags) {
			var value = declFlagToAbstractFlag(ctx, flag);
			if (value != null) out.push(value);
		}
		return out;
	}

	public static function noKeyword(what:String, s:Stream<syntax.Lexer.LexedToken>):Dynamic {
		var next:ParserToken = s.peek();
		if (next != null) switch next.token {
			case Kwd(kwd):
				return error(Custom("Keyword " + Ast.sKeyword(kwd) + " cannot be used as " + what), next.pos);
			case _:
		}
		throw core.ds.Stream.StreamFailure.raise();
	}
}
