/*
 * Copyright (C)2005-2013 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package generators;

import core.Ast;
import core.Globals;
import core.Globals.GlobalTypePath;
import core.Globals.Pos;
import core.TType;
import core.TFunctions.*;
import core.TOther.ExtType;
import core.TOther.TClassTools;
import core.Texpr;
import core.Texpr.Builder;
import core.Error.raiseTypingError;
import core.Meta;
import core.Define;
import generators.JsSourcemap;
import haxe.ds.StringMap;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

/* Loop-related context that gets reset when entering a function scope */
@:structInit class LoopContext {
	public final inLoop:Bool;
	public final inLoopTry:Bool;
	public final breakDepth:Int;
	public final handleContinue:Bool;
	public final useGotoContinue:Bool;
}

class LuaCtx {
	public var com:Gctx;
	// port: Buffer.t; the last character added is kept for check_sep's Buffer.nth.
	public var buf:StringBuf;
	public var bufLast:Int;
	public var smap:Null<Sourcemap>;
	public var current:TClass;
	public var statics:Array<{c:TClass, f:TClassField, e:TExpr}>;
	public var inits:Array<TExpr>;
	public var tabs:String;
	public var inValue:Null<TVar>;
	public var loopCtx:LoopContext;
	public var iifeAssign:Bool;
	public var idCounter:Int;
	public var typeAccessor:ModuleType->String;
	public var separator:Bool;
	public var luaJit:Bool;
	public var luaVanilla:Bool;
	public var luaVer:Float;
	public var declaredLocals:StringMap<Bool>;
	public var inPcall:Bool;
	public var needsSep:Bool;

	public function new() {}
}

class ObjectStore {
	public var osName:String;
	public var osFields:Array<ObjectStore>;

	public function new(osName:String, osFields:Array<ObjectStore>) {
		this.osName = osName;
		this.osFields = osFields;
	}
}

class Genlua {
	static final defaultLoopContext:LoopContext = {
		inLoop: false,
		inLoopTry: false,
		breakDepth: 0,
		handleContinue: false,
		useGotoContinue: false,
	};

	static function replaceFloatSeparators(s:String):String return Texpr.replaceSeparators(s, "");

	static function flatPath(path:GlobalTypePath):String {
		/* Replace _ with __ in paths to prevent name collisions. */
		function escape(str:String):String return str.split("_").join("_");

		return switch path.pack {
			case []: escape(path.name);
			case p: "__" + p.map(escape).join("_") + "_" + (escape(path.name));
		}
	}

	static function getExposed(ctx:LuaCtx, path:String, meta:Metadata):Array<String> {
		var m = Meta.getOpt(Expose, meta);
		if (m == null) return [];
		return switch m.exprs {
			case [{expr: EConst(String(s, _))}]: [s];
			case []: [path];
			case _: raiseTypingError("Invalid @:expose parameters", m.pos);
		}
	}

	static function dotPath(p:GlobalTypePath):String return Globals.sTypePath(p);

	static function sPath(ctx:LuaCtx, path:GlobalTypePath):String {
		var fp = flatPath(path);
		return switch path.pack {
			case []: fp;
			case _: "_hx_c." + fp;
		}
	}

	/* Lua requires decimal encoding for characters, rather than the hex */
	/* provided by StringHelper.s_escape */
	static function sEscapeLua(s:String, dec = true):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			switch c {
				case "\n".code:
					b.add("\\n");
				case "\t".code:
					b.add("\\t");
				case "\r".code:
					b.add("\\r");
				case "\"".code:
					b.add("\\\"");
				case "\\".code:
					b.add("\\\\");
				case c if (c < 32 && dec):
					b.add("\\" + StringTools.lpad(Std.string(c), "0", 3));
				case c:
					b.addChar(c);
			}
		}
		return b.toString();
	}

	/* Lua reserved keywords - used for both field quoting (obj["end"]) and identifier escaping (_end) */
	static final kwds:StringMap<Bool> = {
		var h = new StringMap();
		for (s in [
			"_G", "", "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil", "not", "or",
			"repeat", "return", "then", "true", "until", "while", "goto", "self"
		])
			h.set(s, true);
		h;
	};

	static function validLuaIdent(s:String):Bool {
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if ((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code) {} else if (c >= "0".code
				&& c <= "9".code
				&& i > 0) {} else
				return false;
		}
		return true;
	}

	static function field(s:String):String return if (kwds.exists(s) || !validLuaIdent(s)) "[\"" + s + "\"]" else "." + s;

	static function ident(s:String):String return if (kwds.exists(s)) "_" + s else s;

	static function anonField(s:String):String return if (kwds.exists(s) || !validLuaIdent(s)) "['" + (sEscapeLua(s)) + "']" else s;

	static function staticField(c:TClass, s:String):String {
		return switch s {
			case "length" | "name" if (!hasClassFlag(c, CExtern) || Meta.has(HxGen, c.clMeta)): "._hx" + s;
			case s: field(s);
		}
	}

	static function hasFeature(ctx:LuaCtx, f:String):Bool return Gctx.hasFeature(ctx.com, f);

	static function addFeature(ctx:LuaCtx, f:String):Void Gctx.addFeature(ctx.com, f);

	static final bootClass:ModuleType = TClassDecl(mkClass(nullClass.clModule, {pack: ["lua"], name: "Boot"}, Globals.nullPos, Globals.nullPos));

	static function temp(ctx:LuaCtx):String {
		ctx.idCounter = ctx.idCounter + 1;
		return "_hx_" + Std.string(ctx.idCounter);
	}

	static function isIdentChar(c:Int):Bool
		return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "_".code;

	// port: Buffer.add_string ctx.buf, recording the last character for check_sep.
	static inline function bufAdd(ctx:LuaCtx, s:String):Void {
		if (s.length > 0) {
			ctx.buf.add(s);
			ctx.bufLast = StringTools.fastCodeAt(s, s.length - 1);
		}
	}

	static function checkSep(ctx:LuaCtx, s:String):Void {
		if (ctx.needsSep && s.length > 0) {
			function insertSep() {
				ctx.needsSep = false;
				JsSourcemap.handleNewlines(ctx.smap, ";");
				bufAdd(ctx, ";");
			}
			switch StringTools.fastCodeAt(s, 0) {
				case "(".code:
					insertSep();
				case "\n".code | "\t".code | "\r".code:
				case c if (isIdentChar(c)):
					/* Prevent token merging: end followed by EReg would parse as endEReg */
					if (ctx.bufLast >= 0 && isIdentChar(ctx.bufLast)) insertSep() else ctx.needsSep = false;
				case _:
					ctx.needsSep = false;
			}
		}
	}

	static function spr(ctx:LuaCtx, s:String):Void {
		ctx.separator = false;
		checkSep(ctx, s);
		JsSourcemap.handleNewlines(ctx.smap, s);
		bufAdd(ctx, s);
	}

	// port: Printf.kprintf; the callers format their arguments.
	static function print(ctx:LuaCtx, s:String):Void {
		ctx.separator = false;
		checkSep(ctx, s);
		JsSourcemap.handleNewlines(ctx.smap, s);
		bufAdd(ctx, s);
	}

	static function newline(ctx:LuaCtx):Void print(ctx, "\n" + ctx.tabs);

	/* print with newline */
	static function println(ctx:LuaCtx, s:String):Void {
		ctx.separator = false;
		checkSep(ctx, s);
		bufAdd(ctx, s);
		newline(ctx);
	}

	static function unsupported(p:Pos):Dynamic return raiseTypingError("This expression cannot be compiled to Lua", p);

	static function semicolon(ctx:LuaCtx):Void {
		ctx.needsSep = true;
	}

	extern overload static inline function concat<A>(ctx:LuaCtx, s:String, f:A->Void, l:Array<A>):Void {
		for (i in 0...l.length) {
			if (i > 0) spr(ctx, s);
			f(l[i]);
		}
	}

	extern overload static inline function concat<A>(ctx:LuaCtx, s:String, f:A->Void, l:Vector<A>):Void {
		for (i in 0...l.length) {
			if (i > 0) spr(ctx, s);
			f(l[i]);
		}
	}

	/* create a __lua__ call */
	static function mkLuaCode(com:BasicTypes, code:String, args:Vector<TExpr>, t:T, pos:Pos):TExpr {
		var luaLocal = mk(TIdent("__lua__"), tDynamic, pos);
		var codeConst = Builder.makeString(com, code, pos);
		return mk(TCall(luaLocal, VectorTools.cons(codeConst, args)), t, pos);
	}

	static function injectRestArgs(ctx:LuaCtx, args:haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}>, e:TExpr):TExpr {
		if (args.length > 0 && ExtType.isRest(follow(args[args.length - 1].variable.vType))) {
			var v = args[args.length - 1].variable;
			var rest = mk(TLocal(v), v.vType, v.vPos);
			var initRest = mkLuaCode(ctx.com.basic, "local {0} = {...}", vector(rest), ctx.com.basic.tvoid, v.vPos);
			return switch e.eexpr {
				case TBlock(el):
					{eexpr: TBlock(VectorTools.cons(initRest, el)), etype: e.etype, epos: e.epos};
				case _:
					{eexpr: TBlock(vector(initRest, e)), etype: e.etype, epos: e.epos};
			}
		}
		return e;
	}

	static function funBlock(ctx:LuaCtx, f:TFunc, p:Pos):TExpr {
		var fnBody = injectRestArgs(ctx, f.tfArgs, f.tfExpr);
		var e = fnBody;
		var i = f.tfArgs.length;
		while (i-- > 0) {
			var a = f.tfArgs[i].variable, c = f.tfArgs[i].defaultValue;
			switch c {
				case null | {eexpr: TConst(TNull)}:
				case c:
					e = core.TFunctions.concat(Texpr.setDefault(ctx.com.basic, a, c, p), e);
			}
		}
		return e;
	}

	static function openBlock(ctx:LuaCtx):Void->Void {
		var oldt = ctx.tabs;
		var oldDeclaredLocals = ctx.declaredLocals;
		ctx.tabs = "  " + ctx.tabs;
		ctx.declaredLocals = new StringMap();
		return function() {
			ctx.tabs = oldt;
			ctx.declaredLocals = oldDeclaredLocals;
		}
	}

	static function thisName(_ctx:LuaCtx):String return "self";

	static function isDotAccess(e:TExpr, cf:TFieldAccess):Bool {
		return switch [follow(e.etype), cf] {
			case [TInst(c, _), FInstance(_, _, icf)]:
				switch icf.cfKind {
					case Var(_):
						true;
					case Method(_) if (Meta.has(LuaDotMethod, c.clMeta)):
						true;
					case Method(_) if (Meta.has(LuaDotMethod, icf.cfMeta)):
						true;
					case Method(_):
						false;
				}
			case _:
				false;
		}
	}

	/* Return index of first element in the list for which `f` returns true.
		Polyfill for List.find_index (added in OCaml 5.1). */
	static function indexOf<A>(f:A->Bool, l:Array<A>):Int {
		for (idx in 0...l.length) if (f(l[idx])) return idx;
		throw core.ds.NotFound.raise();
	}

	/* create a multi-return boxing call for given expr */
	static function mkMrBox(ctx:LuaCtx, e:TExpr):TExpr {
		var sFields = switch follow(e.etype) {
			case TInst(c, _):
				c.clOrderedFields.map(f -> "\"" + f.cfName + "\"").join(", ");
			case _: Globals.die("", "genlua.ml");
		}
		addFeature(ctx, "use._hx_box_mr");
		addFeature(ctx, "use._hx_table");
		var code = '_hx_box_mr(_hx_table.pack({0}), {$sFields})';
		return mkLuaCode(ctx.com.basic, code, vector(e), e.etype, e.epos);
	}

	/* create a multi-return select call for given expr and field name */
	static function mkMrSelect(com:BasicTypes, e:TExpr, ecall:TExpr, name:String):TExpr {
		var i = switch follow(ecall.etype) {
			case TInst(c, _):
				indexOf((f:TClassField) -> f.cfName == name, c.clOrderedFields);
			case _:
				Globals.die("", "genlua.ml");
		}
		if (i == 0) return mkLuaCode(com, "{0}", vector(ecall), e.etype, e.epos) else {
			var code = '_G.select(${i + 1}, {0})';
			return mkLuaCode(com, code, vector(ecall), e.etype, e.epos);
		}
	}

	/* from genphp */
	static function isStringType(t:T):Bool {
		return switch follow(t) {
			case TInst({clKind: KTypeParameter(ttp)}, _): getConstraints(ttp).exists(isStringType);
			case TInst({clPath: {pack: [], name: "String"}}, _): true;
			case TAnon(a):
				switch a.aStatus {
					case ClassStatics({clPath: {pack: [], name: "String"}}): true;
					case _: false;
				}
			case TAbstract(a, pl): isStringType(core.Abstract.getUnderlyingType(a, pl));
			case _: false;
		}
	}

	static function isStringExpr(e:TExpr):Bool return isStringType(e.etype);

	/* /from genphp */
	static function isDynamic(t:T):Bool return switch follow(t) {
		case TMono(_) | TDynamic(_) | TInst({clKind: KTypeParameter(_)}, _): true;
		case TAnon(anon):
			switch anon.aStatus {
				case EnumStatics(_) | ClassStatics(_): false;
				case _: true;
			}
		case _: false;
	}

	static function isDynamicExpr(e:TExpr):Bool return isDynamic(e.etype);

	static function isStructuralType(t:T):Bool {
		return switch follow(t) {
			case TDynamic(_): true;
			case TAnon(a): true;
			case TType({tType: TAnon(_)}, _): true;
			case _: false;
		}
	}

	static function isIntType(ctx:LuaCtx, t:T):Bool {
		return switch follow(t) {
			case TInst({clPath: {pack: [], name: "Int"}}, _): true;
			case TAnon(a):
				switch a.aStatus {
					case ClassStatics({clPath: {pack: [], name: "Int"}}): true;
					case _: false;
				}
			case TAbstract({aPath: {pack: [], name: "Float"}}, pl): false;
			case TAbstract({aPath: {pack: [], name: "Int"}}, pl): true;
			case TAbstract(a, pl): isIntType(ctx, core.Abstract.getUnderlyingType(a, pl));
			case _: false;
		}
	}

	static function extractExpr(e:TExpr):TExpr return switch e.eexpr {
		case TParenthesis(e) | TMeta(_, e) | TCast(e, _): extractExpr(e);
		case _: e;
	}

	static function genConstant(ctx:LuaCtx, p:Pos, c:TConstant):Void {
		switch c {
			case TInt(i):
				print(ctx, Std.string(i));
			case TFloat(s):
				spr(ctx, replaceFloatSeparators(s));
			case TString(s):
				addFeature(ctx, "use.string");
				print(ctx, "\"" + sEscapeLua(s) + "\"");
			case TBool(b):
				spr(ctx, if (b) "true" else "false");
			case TNull:
				spr(ctx, "nil");
			case TThis:
				spr(ctx, thisName(ctx));
			case TSuper:
				Globals.die("", "genlua.ml");
		}
	}

	static function isFunctionType(t:T):Bool {
		return switch follow(t) {
			case TFun(_): true;
			case TAbstract({aPath: {pack: ["haxe"], name: "Function"}}, _): true;
			case _: false;
		}
	}

	static function genArgument(ctx:LuaCtx, e:TExpr, reflect = false):Void {
		switch e.eexpr {
			case TField(x, i = (FInstance(_, _, f) | FAnon(f) | FClosure(_, f))) if ((isFunctionType(e.etype)) && (!isDotAccess(x, i))):
				if (reflect) {
					addFeature(ctx, "use._hx_funcToField");
					spr(ctx, "_hx_funcToField(");
				}

				addFeature(ctx, "use._hx_bind");
				print(ctx, "_hx_bind(");
				genValue(ctx, x);
				print(ctx, ",");
				genValue(ctx, x);
				print(ctx, (if (Meta.has(SelfCall, f.cfMeta)) "" else (field(f.cfName))) + ")");

				if (reflect) print(ctx, ")");
			case _:
				genValue(ctx, e);
		}
	}

	static function genParenArguments(ctx:LuaCtx, el:Vector<TExpr>):Void {
		spr(ctx, "(");
		concat(ctx, ", ", genArgument.bind(ctx, _, false), el);
		spr(ctx, ")");
	}

	static function genCall(ctx:LuaCtx, e:TExpr, el:Vector<TExpr>):Void {
		ctx.iifeAssign = true;
		switch [e.eexpr, el] {
			case [TConst(TSuper), params]:
				switch ctx.current.clSuper {
					case null:
						raiseTypingError("Missing api.setCurrentClass", e.epos);
					case {cls: c}:
						print(ctx, ctx.typeAccessor(TClassDecl(c)) + ".super(" + thisName(ctx));
						for (p in params) {
							print(ctx, ",");
							genArgument(ctx, p);
						}
						spr(ctx, ")");
				}
			case [TField({eexpr: TConst(TSuper)}, f), params]:
				switch ctx.current.clSuper {
					case null:
						raiseTypingError("Missing api.setCurrentClass", e.epos);
					case {cls: c}:
						var name = fieldName(f);
						print(ctx, ctx.typeAccessor(TClassDecl(c)) + ".prototype" + field(name) + "(" + thisName(ctx));
						for (p in params) {
							print(ctx, ",");
							genArgument(ctx, p);
						}
						spr(ctx, ")");
				}
			case [TField(_, FStatic({clPath: {pack: [], name: "Reflect"}}, {cfName: "callMethod"})), _] if (el.length >= 3):
				var obj = el[0], fld = el[1], args = el[2];
				genExpr(ctx, e);
				spr(ctx, "(");
				genArgument(ctx, obj);
				spr(ctx, ",");
				genArgument(ctx, fld, true);
				spr(ctx, ",");
				genArgument(ctx, args);
				spr(ctx, ")");
			case [TField(_, FStatic({clPath: {pack: ["lua"], name: "Syntax"}}, {cfName: "code"})), _] if (el.length >= 1):
				var code = el[0], args = el.slice(1);
				switch code.eexpr {
					case TConst(TString(s)):
						codegen.Codegen.interpolateCode(ctx.com.error, s, args.toArray(), spr.bind(ctx, _), genExpr.bind(ctx, _, true), code.epos);
					case _:
						raiseTypingError("The code argument for lua.Syntax.code must be a string constant", code.epos);
				}
			case [TField(_, FStatic({clPath: {pack: ["lua"], name: "Syntax"}}, {cfName: "plainCode"})), [code]]:
				switch code.eexpr {
					case TConst(TString(s)):
						spr(ctx, s.split("\r\n").join("\n"));
					case _:
						raiseTypingError("The code argument for lua.Syntax.plainCode must be a string constant", code.epos);
				}
			case [TCall(x, _), el] if (switch x.eexpr {
					case TIdent("__lua__"): false;
					case _: true;
				}):
				genParen(ctx, vector(e));
				genParenArguments(ctx, el);
			case [TIdent("__new__"), _] if (el.length >= 1 && el[0].eexpr.match(TConst(TString(_)))):
				var cl = switch el[0].eexpr {
					case TConst(TString(cl)): cl;
					case _: throw "unreachable";
				}
				print(ctx, cl + ".new");
				genParenArguments(ctx, el.slice(1));
			case [TIdent("__new__"), _] if (el.length >= 1):
				genValue(ctx, el[0]);
				spr(ctx, ".new");
				genParenArguments(ctx, el.slice(1));
			case [TIdent("__callself__"), _] if (el.length >= 2 && el[0].eexpr.match(TConst(TString(_))) && el[1].eexpr.match(TConst(TString(_)))):
				var head = switch el[0].eexpr {
					case TConst(TString(s)): s;
					case _: throw "unreachable";
				}
				var tail = switch el[1].eexpr {
					case TConst(TString(s)): s;
					case _: throw "unreachable";
				}
				print(ctx, head + ":" + tail);
				genParenArguments(ctx, el.slice(2));
			case [TIdent("__call__"), _] if (el.length >= 1 && el[0].eexpr.match(TConst(TString(_)))):
				var code = switch el[0].eexpr {
					case TConst(TString(s)): s;
					case _: throw "unreachable";
				}
				spr(ctx, code);
				genParenArguments(ctx, el.slice(1));
			case [TIdent("__lua_length__"), [e]]:
				spr(ctx, "#");
				genValue(ctx, e);
			case [TField(_, FStatic({clPath: {pack: ["_G"], name: "table"}}, {cfName: "create"})), el] | [TIdent("__lua_table__"), el]:
				var count = 0;
				spr(ctx, "({");
				for (e in el) {
					switch Texpr.skip(e) {
						case {eexpr: TArrayDecl(arr)}:
							if (count > 0 && arr.length > 0) spr(ctx, ",");
							concat(ctx, ",", genValue.bind(ctx, _), arr);
							if (arr.length > 0) count++;
						case {eexpr: TObjectDecl(fields)}:
							if (count > 0 && fields.length > 0) spr(ctx, ",");
							concat(ctx, ", ", function(fe) {
								print(ctx, anonField(fe.key.name) + " = ");
								genValue(ctx, fe.expr);
							}, fields);
							if (fields.length > 0) count++;
						case {eexpr: TConst(TNull)}:
						case _:
							raiseTypingError("__lua_table__ only accepts array literal and/or anonymous object literal arguments", e.epos);
					}
				}
				spr(ctx, "})");
			case [TIdent("__lua__"), [{eexpr: TConst(TString(code))}]]:
				spr(ctx, code.split("\r\n").join("\n"));
			case [TIdent("__lua__"), _] if (el.length >= 1 && el[0].eexpr.match(TConst(TString(_)))):
				var code = switch el[0].eexpr {
					case TConst(TString(s)): s;
					case _: throw "unreachable";
				}
				var p = el[0].epos;
				codegen.Codegen.interpolateCode(ctx.com.error, code, el.toArray().slice(1), spr.bind(ctx, _), genExpr.bind(ctx, _, true), p);
			case [TIdent("__type__"), [o]]:
				spr(ctx, "type");
				genParen(ctx, vector(o));
			case [TIdent("__define_feature__"), [_, e]]:
				genExpr(ctx, e);
			case [TIdent("__feature__"), _] if (el.length >= 2 && el[0].eexpr.match(TConst(TString(_)))):
				var f = switch el[0].eexpr {
					case TConst(TString(s)): s;
					case _: throw "unreachable";
				}
				var eif = el[1], eelse = el.slice(2);
				if (hasFeature(ctx, f)) genValue(ctx, eif) else switch eelse {
					case []:
					case _: genValue(ctx, eelse[0]);
				}
			case [TIdent("__resources__"), []]:
				spr(ctx, "_hx_tab_array({");
				var count = 0;
				concat(ctx, ",", function(r:{name:String, data:haxe.io.Bytes}) {
					if (count == 0) spr(ctx, "[0]=");
					spr(ctx, "{ ");
					spr(ctx, "name = ");
					genConstant(ctx, e.epos, TString(r.name));
					spr(ctx, ", data = ");
					genConstant(ctx, e.epos, TString(codegen.Codegen.bytesSerialize(r.data)));
					spr(ctx, "}");
					count++;
				}, resourcesFold(ctx.com.resources));
				print(ctx, "}, " + count + ")");
			case [TIdent("`trace"), [e, infos]]:
				if (hasFeature(ctx, "haxe.Log.trace")) {
					var t = null;
					for (t2 in ctx.com.types) {
						var p = tPath(t2);
						if (p.pack.length == 1 && p.pack[0] == "haxe" && p.name == "Log") {
							t = t2;
							break;
						}
					}
					if (t == null) Globals.die("", "genlua.ml");
					spr(ctx, ctx.typeAccessor(t));
					spr(ctx, ".trace(");
					genValue(ctx, e);
					spr(ctx, ",");
					genValue(ctx, infos);
					spr(ctx, ")");
				} else {
					spr(ctx, "_hx_print(");
					genValue(ctx, e);
					spr(ctx, ")");
				}
			case [TField(e = {eexpr: TConst(TInt(_) | TFloat(_) | TString(_) | TBool(_))}, ef = (FInstance(_) | FAnon(_))), el]:
				genParen(ctx, vector(e));
				print(ctx, ":" + fieldName(ef) + "(");
				concat(ctx, ",", genValue.bind(ctx, _), el);
				spr(ctx, ")");
			case [
				TField(_, FStatic({clPath: {pack: [], name: "Std"}}, {cfName: "string"})),
				[el = {eexpr: TCall({eexpr: TField(_, FStatic({clPath: {pack: [], name: "Std"}}, {cfName: "string"}))}, _)}]
			]:
				/* unwrap recursive Std.string(Std.string(...)) declarations to Std.string(...) */
				genValue(ctx, el);
			case [TField(e = {eexpr: TLocal(_)}, ef), el] if (isPossibleStringField(e, fieldName(ef))):
				addFeature(ctx, "use._hx_wrap_if_string_field");
				addFeature(ctx, "use.string");
				spr(ctx, "_hx_wrap_if_string_field(");
				genValue(ctx, e);
				print(ctx, ",'" + fieldName(ef) + "'");
				spr(ctx, ")(");
				concat(ctx, ",", genArgument.bind(ctx, _, false), VectorTools.cons(e, el));
				spr(ctx, ")");
			case [TField({eexpr: TLocal(v)}, f), el] if (Meta.has(MultiReturn, v.vMeta)):
				/* Call to a field of a multi-return local - the field is actually just a local variable */
				var m = Meta.get(core.MetaList.StrictMeta.Custom(":lua_mr_id"), v.vMeta);
				switch m.exprs {
					case [{expr: EConst(String(id, _))}]:
						spr(ctx, id + "_" + (ident(v.vName)) + "_" + (fieldName(f)));
						genParenArguments(ctx, el);
					case _:
						Globals.die("", "genlua.ml");
				}
			case [TField(fieldOwner, (FInstance(_, _, f) | FAnon(f))), el] if (Meta.has(SelfCall, f.cfMeta)):
				/* @:selfCall methods - call the object directly */
				genValue(ctx, fieldOwner);
				genParenArguments(ctx, el);
			case [TField(fieldOwner, ef = (FInstance(_) | FAnon(_) | FDynamic(_))), el]:
				var s = (fieldName(ef));
				if (kwds.exists(s) || !validLuaIdent(s)) {
					addFeature(ctx, "use._hx_apply_self");
					spr(ctx, "_hx_apply_self(");
					genValue(ctx, fieldOwner);
					print(ctx, ",\"" + fieldName(ef) + "\"");
					if (el.length > 0) spr(ctx, ",");
					concat(ctx, ",", genArgument.bind(ctx, _, false), el);
					spr(ctx, ")");
				} else {
					var el = if ((switch ef {
						case FAnon(_) | FDynamic(_): true;
						case _: false;
					}) && isPossibleStringField(fieldOwner, s)) {
						addFeature(ctx, "use._hx_wrap_if_string_field");
						addFeature(ctx, "use.string");
						spr(ctx, "_hx_wrap_if_string_field(");
						genValue(ctx, fieldOwner);
						print(ctx, ",'" + s + "'");
						spr(ctx, ")");
						VectorTools.cons(fieldOwner, el);
					} else {
						genValue(ctx, fieldOwner);
						if (isDotAccess(fieldOwner, ef)) print(ctx, "." + fieldName(ef)) else print(ctx, ":" + fieldName(ef));
						el;
					}
					genParenArguments(ctx, el);
				}
			case _:
				genValue(ctx, e);
				genParenArguments(ctx, el);
		}
		ctx.iifeAssign = false;
	}

	// port: (Hashtbl.fold (fun name data acc -> (name,data) :: acc) ctx.com.resources []).
	static function resourcesFold(resources:core.ds.OcamlHashtbl<String, haxe.io.Bytes>):Array<{name:String, data:haxe.io.Bytes}>
		return resources.fold((name, data, acc:Array<{name:String, data:haxe.io.Bytes}>) -> [{name: name, data: data}].concat(acc), []);

	static function hasContinue(e:TExpr):Bool {
		function loop(e:TExpr):Void {
			switch e.eexpr {
				case TContinue:
					throw core.ds.Exit.raise();
				case TWhile(e1, _, _):
					loop(e1); /* in theory there could be a continue there. Note that we don't want to recurse into the loop body because we do not care about inner continue expressions */
				case _:
					Texpr.iter(loop, e);
			}
		}
		try {
			loop(e);
			return false;
		} catch (_:core.ds.Exit) {
			return true;
		}
	}

	static function genParen(ctx:LuaCtx, el:Vector<TExpr>):Void {
		spr(ctx, "(");
		concat(ctx, ", ", genValue.bind(ctx, _), el);
		spr(ctx, ")");
	}

	static function genCond(ctx:LuaCtx, cond:TExpr):Void {
		ctx.iifeAssign = true;
		genValue(ctx, cond);
		ctx.iifeAssign = false;
	}

	static function genLoop(ctx:LuaCtx, cond:TExpr, doWhile:Bool, e:TExpr):Void {
		var oldLoopCtx = ctx.loopCtx;
		var willContinue = hasContinue(e);
		var newBreakDepth = oldLoopCtx.breakDepth + 1;
		var gotoContinue = ctx.luaJit && willContinue;
		ctx.loopCtx = {
			inLoop: true,
			inLoopTry: false,
			breakDepth: newBreakDepth,
			handleContinue: willContinue,
			useGotoContinue: gotoContinue,
		};
		if (willContinue && !gotoContinue) println(ctx, 'local _hx_continue_$newBreakDepth = false;');
		if (doWhile) println(ctx, 'local _hx_do_first_$newBreakDepth = true;');
		var b = openBlock(ctx);
		print(ctx, "while ");
		if (doWhile) print(ctx, '_hx_do_first_$newBreakDepth or ');
		genCond(ctx, cond);
		print(ctx, " do ");
		if (doWhile) {
			newline(ctx);
			println(ctx, '_hx_do_first_$newBreakDepth = false;');
		}
		if (willContinue) {
			if (gotoContinue) print(ctx, "do ") else {
				newline(ctx);
				print(ctx, "repeat ");
			}
		}
		genBlockElement(ctx, e);
		if (willContinue) {
			if (gotoContinue) {
				println(ctx, "end");
				print(ctx, '::_hx_continue_$newBreakDepth::');
			} else {
				newline(ctx);
				println(ctx, "until true");
				println(ctx, 'if _hx_continue_$newBreakDepth then ');
				println(ctx, '_hx_continue_$newBreakDepth = false;');
				if (ctx.loopCtx.inLoopTry) println(ctx, "_G.error(\"_hx_pcall_break\");") else println(ctx, "break;");
				println(ctx, "end;");
			}
		}
		b();
		newline(ctx);
		print(ctx, "end");
		ctx.loopCtx = oldLoopCtx;
	}

	static function isPossibleStringField(e:TExpr, fieldName:String):Bool {
		/* Special case for String fields — only for truly structural types,
			not statics tables (which are TAnon but never strings) */
		var structuralType = switch follow(e.etype) {
			case TAnon(a):
				switch a.aStatus {
					case ClassStatics(_) | EnumStatics(_) | AbstractStatics(_): false;
					case _: true;
				}
			case _: isStructuralType(e.etype);
		}
		if (!structuralType) return false else return switch fieldName {
			case "length" | "toUpperCase" | "toLowerCase" | "charAt" | "indexOf" | "lastIndexOf" | "split" | "toString" | "substring" | "substr" |
				"charCodeAt":
				true;
			case _:
				false;
		}
	}

	static function ttypeMultireturn(t:T):Bool return switch t {
		case TInst(c, _):
			Meta.has(MultiReturn, c.clMeta);
		case TType(c, _):
			Meta.has(MultiReturn, c.tMeta);
		case _:
			false;
	}

	static function checkMultireturnParam(ctx:LuaCtx, t:T, pos:Pos):Void {
		switch t {
			case TAbstract(_, p) | TInst(_, p):
				if (p.exists(ttypeMultireturn)) raiseTypingError("MultiReturns must not be type parameters", pos) else {}
			case _:
		}
	}

	/* for declaring identifiers in values/blocks */
	static function luaIdentName(a:TVar):String {
		return switch a.vName {
			case "this": "self";
			case _: ident(a.vName);
		}
	}

	/* for declaring arguments in function defintions */
	static function luaArgName(arg:{variable:TVar, defaultValue:Null<TExpr>}):String {
		var a = arg.variable;
		return switch [a.vName, a.vType] {
			case ["this", _]: "self";
			case [_, TAbstract({aPath: {pack: ["haxe"], name: "Rest"}}, _)]: "...";
			case [_, _]: ident(a.vName);
		}
	}

	static function genFuncBlock(ctx:LuaCtx, retExpr:TExpr, el:Vector<TExpr>):Void {
		function loop(i:Int) {
			if (i >= el.length) return;
			var hd = el[i];
			if (i == el.length - 1) {
				switch hd.eexpr {
					case TReturn(eo):
						newline(ctx);
						genReturn(ctx, retExpr, eo, false);
					case _:
						genBlockElement(ctx, hd);
				}
			} else {
				genBlockElement(ctx, hd);
				loop(i + 1);
			}
		}
		var bend = openBlock(ctx);
		loop(0);
		bend();
		newline(ctx);
	}

	static function withFunctionScope(ctx:LuaCtx, f:Void->Void):Void {
		var oldInValue = ctx.inValue;
		var oldLoopCtx = ctx.loopCtx;
		ctx.inValue = null;
		ctx.loopCtx = defaultLoopContext;
		f();
		ctx.inValue = oldInValue;
		ctx.loopCtx = oldLoopCtx;
	}

	static function genAssignWrapped(ctx:LuaCtx, op:Binop, e1:TExpr, e2:TExpr, wrapper:String):Void {
		genValue(ctx, e1);
		print(ctx, " " + Ast.sBinop(op) + " ");
		addFeature(ctx, "use." + wrapper);
		spr(ctx, wrapper + "(");
		genValue(ctx, e2);
		spr(ctx, ")");
	}

	static function genCast(ctx:LuaCtx, genInner:LuaCtx->TExpr->Void, e1:TExpr, t:ModuleType):Void {
		print(ctx, ctx.typeAccessor(bootClass) + ".__cast(");
		genInner(ctx, e1);
		spr(ctx, " , ");
		spr(ctx, ctx.typeAccessor(t));
		spr(ctx, ")");
	}

	static function genFieldAccessName(ctx:LuaCtx, fa:TFieldAccess):Void {
		switch fa {
			case FInstance(_, _, fld) | FStatic(_, fld) | FAnon(fld) | FClosure(_, fld):
				print(ctx, "'" + fld.cfName + "'");
			case FDynamic(name):
				print(ctx, "'" + name + "'");
			case FEnum(_, efld):
				print(ctx, "'" + efld.efName + "'");
		}
	}

	static function genExprDefault(ctx:LuaCtx, e:TExpr):Void genExpr(ctx, e, true);

	static function genExpr(ctx:LuaCtx, e:TExpr, local = true):Void {
		var clearMapping = JsSourcemap.addMapping(ctx.smap, e);
		switch e.eexpr {
			case TConst(c):
				genConstant(ctx, e.epos, c);
			case TLocal(v):
				spr(ctx, luaIdentName(v));
			case TArray(e1, {eexpr: TConst(TString(s))}) if (validLuaIdent(s) && (switch e1.eexpr {
					case TConst(TInt(_) | TFloat(_)): false;
					case _: true;
				})):
				genValue(ctx, e1);
				spr(ctx, field(s));
			case TArray(e1, e2):
				genValue(ctx, e1);
				spr(ctx, "[");
				genValue(ctx, e2);
				spr(ctx, "]");
			case TBinop(op, e1, e2):
				genTbinop(ctx, op, e1, e2);
			case TField(x, FClosure(_, f)):
				addFeature(ctx, "use._hx_bind");
				var fname = if (Meta.has(SelfCall, f.cfMeta)) "" else (field(f.cfName));
				if (isStringExpr(x)) {
					addFeature(ctx, "use.string");
					switch x.eexpr {
						case TConst(_) | TLocal(_):
							print(ctx, "_hx_bind(");
							genValue(ctx, x);
							print(ctx, ",String.prototype" + fname + ")");
						case _:
							print(ctx, "(function() local __=");
							genValue(ctx, x);
							print(ctx, "; return _hx_bind(__,String.prototype" + fname + ") end)()");
					}
				} else switch x.eexpr {
					case TConst(_) | TLocal(_):
						print(ctx, "_hx_bind(");
						genValue(ctx, x);
						print(ctx, ",");
						genValue(ctx, x);
						print(ctx, fname + ")");
					case _:
						print(ctx, "(function() local __=");
						genValue(ctx, x);
						print(ctx, "; return _hx_bind(__,__" + fname + ") end)()");
				}
			case TEnumParameter(x, _, i):
				genValue(ctx, x);
				print(ctx, "[" + (i + 2) + "]");
			case TEnumIndex(x):
				genValue(ctx, x);
				print(ctx, "[1]");
			case TField(e, ef) if (isStringExpr(e) && fieldName(ef) == "length"):
				if (ctx.luaVanilla) {
					spr(ctx, "#");
					genValue(ctx, e);
				} else {
					print(ctx, sPath(ctx, {pack: ["lua", "lib", "luautf8"], name: "Utf8"}) + ".len(");
					genValue(ctx, e);
					spr(ctx, ", nil, nil, true)");
				}
			case TField(e, ef) if (isPossibleStringField(e, fieldName(ef))):
				addFeature(ctx, "use._hx_wrap_if_string_field_closure");
				addFeature(ctx, "use._hx_bind");
				addFeature(ctx, "use.string");
				spr(ctx, "_hx_wrap_if_string_field_closure(");
				genValue(ctx, e);
				print(ctx, ",'" + fieldName(ef) + "')");
			case TField(x, (FInstance(_, _, f) | FStatic(_, f) | FAnon(f))) if (Meta.has(SelfCall, f.cfMeta)):
				genValue(ctx, x);
			case TField(e = {eexpr: TConst(TInt(_) | TFloat(_) | TString(_) | TBool(_))}, ef = (FInstance(_) | FAnon(_))):
				genParen(ctx, vector(e));
				print(ctx, "." + fieldName(ef));
			case TField(x = {eexpr: TConst(TInt(_) | TFloat(_))}, f):
				genExpr(ctx, {eexpr: TField(mk(TParenthesis(x), x.etype, x.epos), f), etype: e.etype, epos: e.epos});
			case TField({eexpr: TObjectDecl(fields)}, ef):
				spr(ctx, "(function(x) return x.");
				print(ctx, fieldName(ef));
				spr(ctx, " end )({");
				concat(ctx, ", ", function(fe) {
					print(ctx, anonField(fe.key.name) + " = ");
					genValue(ctx, fe.expr);
				}, fields);
				spr(ctx, "})");
			case TField({eexpr: TLocal(v)}, f) if (Meta.has(MultiReturn, v.vMeta)):
				/* field of a multireturn local var is actually just a local var */
				var m = Meta.get(core.MetaList.StrictMeta.Custom(":lua_mr_id"), v.vMeta);
				switch m.exprs {
					case [{expr: EConst(String(id, _))}]:
						spr(ctx, id + "_" + (ident(v.vName)) + "_" + (fieldName(f)));
					case _:
						Globals.die("", "genlua.ml");
				}
			case TField(_, f = FStatic({clPath: {pack: [], name: ""}}, _)):
				spr(ctx, ident(fieldName(f)));
			case TField(x, f):
				genValue(ctx, x);
				var name = fieldName(f);
				spr(ctx, switch f {
					case FStatic(_) | FEnum(_) | FInstance(_) | FAnon(_) | FDynamic(_) | FClosure(_): field(name);
				});
			case TTypeExpr(t):
				spr(ctx, ctx.typeAccessor(t));
			case TParenthesis(e):
				genParen(ctx, vector(e));
			case TMeta(_, e):
				genExpr(ctx, e);
			case TReturn(eo):
				genReturn(ctx, e, eo, ctx.inPcall);
			case TBreak:
				if (!ctx.loopCtx.inLoop) unsupported(e.epos);
				if (ctx.loopCtx.useGotoContinue) {
					if (ctx.loopCtx.inLoopTry) print(ctx, "_G.error(\"_hx_pcall_break\", 0)") else spr(ctx, "break");
				} else {
					if (ctx.loopCtx.handleContinue) print(ctx, '_hx_continue_${ctx.loopCtx.breakDepth} = true;');
					if (ctx.loopCtx.inLoopTry) print(ctx, "_G.error(\"_hx_pcall_break\", 0)") else spr(ctx, "break");
				}
			case TContinue:
				if (!ctx.loopCtx.inLoop) unsupported(e.epos);
				if (ctx.loopCtx.useGotoContinue) {
					if (ctx.loopCtx.inLoopTry) print(ctx, "_G.error(\"_hx_pcall_continue\", 0)") else
						print(ctx, 'goto _hx_continue_${ctx.loopCtx.breakDepth}');
				} else if (ctx.loopCtx.inLoopTry) print(ctx, "_G.error(\"_hx_pcall_break\", 0)") else spr(ctx, "break");
			case TBlock(el):
				var bend = openBlock(ctx);
				for (e in el) genBlockElement(ctx, e);
				bend();
				newline(ctx);
			case TFunction(f):
				var oldDeclaredLocals = ctx.declaredLocals;
				ctx.declaredLocals = new StringMap();
				withFunctionScope(ctx, function() {
					print(ctx, "function(" + f.tfArgs.map(luaArgName).join(",") + ") ");
					var fblock = funBlock(ctx, f, e.epos);
					switch fblock.eexpr {
						case TBlock(el):
							genFuncBlock(ctx, e, el);
						case _:
					}
					spr(ctx, "end");
				});
				ctx.declaredLocals = oldDeclaredLocals;
				ctx.separator = true;
			case TCall(e, el):
				genCall(ctx, e, el);
			case TArrayDecl(el):
				spr(ctx, "_hx_tab_array({");
				var count = 0;
				for (i in 0...el.length) {
					var e = el[i];
					count++;
					if (i == 0) spr(ctx, "[0]=") else spr(ctx, ", ");
					genValue(ctx, e);
				}
				print(ctx, "}, " + count + ")");
			case TThrow(e):
				spr(ctx, "_G.error(");
				genValue(ctx, e);
				spr(ctx, ",0)");
			case TVar(v, eo):
				/* Check if this variable name is already declared in current function scope.
					If so, we can reuse it instead of declaring a new local, avoiding Lua's
					200 local variable limit. See issue #10090.
					Only apply this optimization to compiler-generated temps (VGenerated/VInlined)
					to avoid incorrectly merging user variables that happen to have the same name. */
				var varName = ident(v.vName);
				var isCompilerTemp = switch v.vKind {
					case VGenerated | VInlined | VInlinedConstructorVariable(_): true;
					case VUser(_) | VExtractorVariable | VAbstractThis: false;
				}
				var isAlreadyDeclared = isCompilerTemp && ctx.declaredLocals.exists(varName);
				var useLocal = local && !isAlreadyDeclared;
				if (local && isCompilerTemp && !isAlreadyDeclared) ctx.declaredLocals.set(varName, true);
				switch eo {
					case null:
						/* Declaration without initialization - always use local keyword
							because bare variable reference is not valid Lua syntax */
						if (local) spr(ctx, "local ");
						spr(ctx, varName);
					case e:
						switch e.eexpr {
							case TBinop(OpAssign, e1, e2):
								genTbinop(ctx, OpAssign, e1, e2);
								if (useLocal) spr(ctx, " local ") else {
									semicolon(ctx);
									newline(ctx);
								}
								spr(ctx, varName);
								spr(ctx, " = ");
								genValue(ctx, e1);
							case _ if (Meta.has(MultiReturn, v.vMeta)):
								/* multi-return var is generated as several vars for unpacking */
								var id = temp(ctx);
								var tempExpr:Expr = {expr: EConst(core.Ast.Constant.String(id, SDoubleQuotes)), pos: Globals.nullPos};
								v.vMeta = [({meta: core.MetaList.StrictMeta.Custom(":lua_mr_id"), exprs: vector(tempExpr), pos: v.vPos} : MetadataEntry)].concat(v.vMeta);
								var name = varName;
								var names = switch follow(v.vType) {
									case TInst(c, _):
										c.clOrderedFields.map(f -> id + "_" + name + "_" + f.cfName);
									case _:
										Globals.die("", "genlua.ml");
								}
								/* For multi-return, we still need local for the unpacked vars */
								spr(ctx, "local ");
								spr(ctx, names.join(", "));
								spr(ctx, " = ");
								genValue(ctx, e);
							case _:
								if (useLocal) spr(ctx, "local ");
								spr(ctx, varName);
								spr(ctx, " = ");

								/* if it was a multi-return var but it was used as a value itself, */
								/* we have to box it in an object conforming to a multi-return extern class */
								var isBoxedMultireturn = Meta.has(core.MetaList.StrictMeta.Custom(":lua_mr_box"), v.vMeta);
								var e = if (isBoxedMultireturn) mkMrBox(ctx, e) else e;
								switch e.eexpr {
									case TCast(e1 = {eexpr: TTypeExpr(mt)}, null) if (switch mt {
											case TClassDecl({clPath: {pack: [], name: "Array"}}): false;
											case _: true;
										}):
										addFeature(ctx, "use._hx_staticToInstance");
										spr(ctx, "_hx_staticToInstance(");
										genExpr(ctx, e1);
										spr(ctx, ")");
									case TField(_, FAnon(f)) if (isFunctionType(f.cfType)):
										/* Unwrap function from anon object when storing in local variable.
											Anon functions are wrapped with function(_,...) return f(...) end to work with colon syntax.
											Local variables are called with dot syntax, so we need to add a dummy self argument. */
										addFeature(ctx, "use._hx_anonToField");
										spr(ctx, "_hx_anonToField(");
										genValue(ctx, e);
										spr(ctx, ")");
									case _:
										genValue(ctx, e);
								}
						}
				}
			case TNew(c, _, el):
				switch c.clConstructor {
					case cf if (cf != null && Meta.has(SelfCall, cf.cfMeta)):
						print(ctx, ctx.typeAccessor(TClassDecl(c)));
					case cf if (cf != null && Meta.has(Native, cf.cfMeta)):
						var m = Meta.get(Native, cf.cfMeta);
						switch m.exprs {
							case [{expr: EConst(String(s, _))}]:
								print(ctx, ctx.typeAccessor(TClassDecl(c)) + "." + s);
							case _:
								print(ctx, ctx.typeAccessor(TClassDecl(c)) + ".new");
						}
					case _:
						print(ctx, ctx.typeAccessor(TClassDecl(c)) + ".new");
				}
				genParen(ctx, el);
			case TIf(cond, e, eelse):
				ctx.iifeAssign = true;
				spr(ctx, "if ");
				genCond(ctx, cond);
				spr(ctx, " then ");
				var bend = openBlock(ctx);
				genBlockElement(ctx, e);
				bend();
				newline(ctx);
				switch eelse {
					case null:
					case e2:
						switch e.eexpr {
							case TObjectDecl(_):
								ctx.separator = false;
							case _:
						}
						spr(ctx, "else");
						var bend = openBlock(ctx);
						genBlockElement(ctx, e2);
						bend();
						newline(ctx);
				}
				spr(ctx, "end");
				ctx.iifeAssign = false;
			case TUnop(op = (Increment | Decrement), unopFlag, e):
				/* Uses IIFE to handle pre/post increment on arrays and fields correctly */
				println(ctx, "(function() ");
				switch [e.eexpr, unopFlag] {
					case [TArray(e1, e2), _]:
						spr(ctx, "local _hx_idx = ");
						genValue(ctx, e2);
						semicolon(ctx);
						newline(ctx);
						spr(ctx, "local _hx_arr =");
						genValue(ctx, e1);
						semicolon(ctx);
						newline(ctx);
						switch unopFlag {
							case Postfix:
								spr(ctx, "local _ = _hx_arr[_hx_idx]");
								semicolon(ctx);
								newline(ctx);
							case _:
						}
						spr(ctx, "_hx_arr[_hx_idx] = _hx_arr[_hx_idx]");
					case [TField(e1, e2), _]:
						spr(ctx, "local _hx_obj = ");
						genValue(ctx, e1);
						semicolon(ctx);
						newline(ctx);
						spr(ctx, "local _hx_fld = ");
						genFieldAccessName(ctx, e2);
						semicolon(ctx);
						newline(ctx);
						switch unopFlag {
							case Postfix:
								spr(ctx, "local _ = _hx_obj[_hx_fld]");
								semicolon(ctx);
								newline(ctx);
							case _:
						}
						spr(ctx, "_hx_obj[_hx_fld] = _hx_obj[_hx_fld] ");
					case [_, Prefix]:
						genValue(ctx, e);
						spr(ctx, " = ");
						genValue(ctx, e);
					case [_, Postfix]:
						spr(ctx, "local _ = ");
						genValue(ctx, e);
						semicolon(ctx);
						genValue(ctx, e);
						spr(ctx, " = ");
						genValue(ctx, e);
				}
				switch op {
					case Increment:
						spr(ctx, " + 1;");
					case Decrement:
						spr(ctx, " - 1;");
					case _:
						print(ctx, " " + Ast.sUnop(op) + " 1;");
				}
				newline(ctx);
				spr(ctx, " return ");
				switch [unopFlag, e.eexpr] {
					case [Postfix, _]:
						spr(ctx, "_");
					case [_, TArray(e1, e2)]:
						spr(ctx, "_hx_arr[_hx_idx]");
					case [_, TField(e1, e2)]:
						spr(ctx, "_hx_obj[_hx_fld]");
					case [_, _]:
						genValue(ctx, e);
				}
				semicolon(ctx);
				newline(ctx);
				spr(ctx, " end)()");
			case TUnop(Not, unopFlag, e):
				spr(ctx, "not ");
				genValue(ctx, e);
			case TUnop(NegBits, unopFlag, e):
				addFeature(ctx, "use._bitop");
				spr(ctx, "_hx_bit.bnot(");
				genValue(ctx, e);
				spr(ctx, ")");
			case TUnop(Spread, Prefix, e):
				addFeature(ctx, "use._hx_table");
				spr(ctx, "_hx_table.unpack(");
				genValue(ctx, e);
				spr(ctx, ")");
			case TUnop(op, Prefix, e):
				spr(ctx, Ast.sUnop(op));
				genValue(ctx, e);
			case TUnop(op, Postfix, e):
				genValue(ctx, e);
				spr(ctx, Ast.sUnop(op));
			case TWhile(cond, e, NormalWhile):
				genLoop(ctx, cond, false, e);
			case TWhile(cond, e, DoWhile):
				genLoop(ctx, cond, true, e);
			case TObjectDecl([]):
				spr(ctx, "_hx_e()");
				ctx.separator = true;
			case TObjectDecl(fields):
				spr(ctx, "_hx_o({__fields__={");
				concat(ctx, ",", function(fe) {
					print(ctx, anonField(fe.key.name) + "=");
					spr(ctx, "true");
				}, fields);
				spr(ctx, "},");
				concat(ctx, ",", function(fe) {
					print(ctx, anonField(fe.key.name) + "=");
					genAnonValue(ctx, fe.expr);
				}, fields);
				spr(ctx, "})");
				ctx.separator = true;
			case TTry(e, catchs):
				var oldInLoopTry = ctx.loopCtx.inLoopTry;
				if (ctx.loopCtx.inLoop) ctx.loopCtx = withInLoopTry(ctx.loopCtx, true);
				println(ctx, "local _hx_status, _hx_result = pcall(function() ");
				var b = openBlock(ctx);
				var oldInPcall = ctx.inPcall;
				ctx.inPcall = true;
				genExpr(ctx, e);
				ctx.inPcall = oldInPcall;
				b();
				println(ctx, "return _hx_pcall_default");
				println(ctx, "end)");
				ctx.loopCtx = withInLoopTry(ctx.loopCtx, oldInLoopTry);
				if (ctx.loopCtx.inLoop) {
					if (ctx.loopCtx.useGotoContinue) {
						println(ctx, "if not _hx_status and _hx_result == \"_hx_pcall_continue\" then");
						if (oldInLoopTry) println(ctx, "  _G.error(_hx_result,0);") else {
							print(ctx, '  goto _hx_continue_${ctx.loopCtx.breakDepth}');
							newline(ctx);
						}
						println(ctx, "elseif not _hx_status and _hx_result == \"_hx_pcall_break\" then");
						if (oldInLoopTry) println(ctx, "  _G.error(_hx_result,0);") else println(ctx, "  break");
						println(ctx, "elseif not _hx_status then ");
					} else {
						println(ctx, "if not _hx_status and _hx_result == \"_hx_pcall_break\" then");
						if (oldInLoopTry) println(ctx, "  _G.error(_hx_result,0);") else println(ctx, "  break");
						println(ctx, "elseif not _hx_status then ");
					}
				} else println(ctx, "if not _hx_status then ");
				var bend = openBlock(ctx);
				switch catchs {
					case [{variable: v, expr: e}]:
						print(ctx, '  local ${v.vName} = _hx_result;');
						genBlockElement(ctx, e);
					case _:
						Globals.die("", "genlua.ml");
				}
				bend();
				newline(ctx);
				println(ctx, "elseif _hx_result ~= _hx_pcall_default then");
				println(ctx, "  return _hx_result");
				print(ctx, "end");
			case TSwitch({switchSubject: e, switchCases: cases, switchDefault: def}):
				for (cnt in 0...cases.length) {
					var el = cases[cnt].casePatterns, e2 = cases[cnt].caseExpr;
					if (cnt == 0) spr(ctx, "if ") else {
						newline(ctx);
						spr(ctx, "elseif ");
					}
					for (ccnt in 0...el.length) {
						var e3 = el[ccnt];
						if (ccnt > 0) spr(ctx, " or ");
						genValue(ctx, e);
						spr(ctx, " == ");
						genValue(ctx, e3);
					}
					print(ctx, " then ");
					var bend = openBlock(ctx);
					genBlockElement(ctx, e2);
					bend();
				}
				switch def {
					case null:
						newline(ctx);
						spr(ctx, "end");
					case e:
						if (cases.length > 0) {
							newline(ctx);
							spr(ctx, "else");
						}
						var bend = openBlock(ctx);
						bend();
						genBlockElement(ctx, e);
						if (cases.length > 0) spr(ctx, " end");
				}
			case TCast(e1, t) if (t != null):
				genCast(ctx, genExprDefault, e1, t);
			case TCast(e1, _):
				genValue(ctx, e1);
			case TIdent(s):
				spr(ctx, s);

				clearMapping();
		}
	}

	static function withInLoopTry(l:LoopContext, inLoopTry:Bool):LoopContext return {
		inLoop: l.inLoop,
		inLoopTry: inLoopTry,
		breakDepth: l.breakDepth,
		handleContinue: l.handleContinue,
		useGotoContinue: l.useGotoContinue,
	};

	/* gen_block_element handles expressions that map to "statements" in lua. */
	/* It handles no-op situations, and ensures that expressions are formatted with newlines */
	static function genBlockElement(ctx:LuaCtx, e:TExpr):Void {
		ctx.iifeAssign = false;
		var clearMapping = JsSourcemap.addMapping(ctx.smap, e);
		switch e.eexpr {
			case TTypeExpr(_) | TConst(_) | TLocal(_) | TFunction(_):
			case TCast(e1, t) if (t != null):
				genCast(ctx, genExprDefault, e1, t);
			case TCast(e_, null) | TParenthesis(e_) | TMeta(_, e_):
				genBlockElement(ctx, e_);
			case TArray(e1, e2):
				genBlockElement(ctx, e1);
				genBlockElement(ctx, e2);
			case TArrayDecl(el) | TBlock(el):
				for (e in el) genBlockElement(ctx, e);
			/* For plain lua table instantiations, just capture argument operations */
			case TCall({eexpr: TIdent("__lua_table__")}, el):
				for (x in el) genBlockElement(ctx, x);
			/* make a no-op __define_feature__ expression possible */
			case TCall({eexpr: TIdent("__define_feature__")}, [_, e]):
				genBlockElement(ctx, e);
			case TObjectDecl(fl):
				for (f in fl) genBlockElement(ctx, f.expr);
			case TBinop(op, e1, e2) if (!op.match(OpAssign)):
				newline(ctx);
				function f() genTbinop(ctx, op, e1, e2);
				genIifeAssign(ctx, f);
				semicolon(ctx);
			case TUnop(op = (Increment | Decrement), _, e):
				newline(ctx);
				genExpr(ctx, e);
				print(ctx, " = ");
				genExpr(ctx, e);
				switch op {
					case Increment:
						print(ctx, " + 1;");
					case _:
						print(ctx, " - 1;");
				}
			case TSwitch({switchSubject: subj, switchCases: [], switchDefault: def}):
				/* Evaluate the subject for side effects even when there are no cases */
				newline(ctx);
				genExpr(ctx, subj);
				semicolon(ctx);
				switch def {
					case null:
					case e:
						genBlockElement(ctx, e);
				}
			case TField(_):
				newline(ctx);
				function f() genExpr(ctx, e);
				genIifeAssign(ctx, f);
				semicolon(ctx);
			case TCall({eexpr: TIdent("__feature__")}, el) if (el.length >= 2 && el[0].eexpr.match(TConst(TString(_)))):
				var f = switch el[0].eexpr {
					case TConst(TString(s)): s;
					case _: throw "unreachable";
				}
				var eif = el[1], eelse = el.slice(2);
				if (hasFeature(ctx, f)) genBlockElement(ctx, eif) else switch eelse {
					case []:
					case [e]: genBlockElement(ctx, e);
					case _: Globals.die("", "genlua.ml");
				}
			case TReturn(eo):
				newline(ctx);
				genReturn(ctx, e, eo, ctx.inPcall);
				semicolon(ctx);
			case _:
				newline(ctx);
				genExpr(ctx, e);
				semicolon(ctx);
		}
		clearMapping();
	}

	/* values generated in anon structures can get modified.  Functions are bind-ed */
	/* and include a dummy "self" leading variable so they can be called like normal */
	/* instance methods */
	static function genAnonValue(ctx:LuaCtx, e:TExpr):Void {
		switch e {
			case {eexpr: TFunction(f)}:
				withFunctionScope(ctx, function() {
					print(ctx, "function(" + ["self"].concat(f.tfArgs.mapToArray(luaArgName)).join(",") + ") ");
					var fblock = funBlock(ctx, f, e.epos);
					switch fblock.eexpr {
						case TBlock(el):
							genFuncBlock(ctx, e, el);
						case _:
					}
					spr(ctx, "end");
				});
				ctx.separator = true;
			case _ if ((isFunctionType(e.etype)) && !e.eexpr.match(TConst(TNull))):
				spr(ctx, "function(_,...) return (");
				genValue(ctx, e);
				spr(ctx, ")(...) end");
			case _:
				genValue(ctx, e);
		}
	}

	static function genValue(ctx:LuaCtx, e:TExpr):Void {
		var clearMapping = JsSourcemap.addMapping(ctx.smap, e);
		function assign(e:TExpr):TExpr {
			return mk(TBinop(OpAssign, mk(TLocal(switch ctx.inValue {
				case null: Globals.die("", "genlua.ml");
				case v: v;
			}), tDynamic, e.epos), e), e.etype, e.epos);
		}
		function value():Void->Void {
			var oldInValue = ctx.inValue;
			var oldLoopCtx = ctx.loopCtx;
			var rId = temp(ctx);
			var r = allocVar(VGenerated, rId, tDynamic, e.epos);
			ctx.inValue = r;
			ctx.loopCtx = defaultLoopContext;
			spr(ctx, "(function() ");
			var b = openBlock(ctx);
			newline(ctx);
			println(ctx, 'local $rId');
			return function() {
				newline(ctx);
				spr(ctx, ("return " + rId));
				b();
				newline(ctx);
				ctx.inValue = oldInValue;
				ctx.loopCtx = oldLoopCtx;
				spr(ctx, "end )()");
			}
		}
		switch e.eexpr {
			case TBinop(OpAssign, e1, e2):
				spr(ctx, "(function() ");
				genBlockElement(ctx, e);
				spr(ctx, " return ");
				genValue(ctx, e1);
				spr(ctx, " end)()");
			case TConst(_) | TLocal(_) | TArray(_) | TBinop(_) | TField(_) | TEnumParameter(_) | TEnumIndex(_) | TTypeExpr(_) | TParenthesis(_) |
				TObjectDecl(_) | TArrayDecl(_) | TNew(_) | TUnop(_) | TFunction(_) | TIdent(_):
				genExpr(ctx, e);
			case TMeta(_, e1):
				genValue(ctx, e1);
			case TCall({eexpr: (TField(e, s = FInstance(_)))}, el) if (isStringExpr(e)):
				spr(ctx, ("String.prototype." + (fieldName(s))));
				genParenArguments(ctx, VectorTools.cons(e, el));
			case TCall(e, el):
				genCall(ctx, e, el);
			case TReturn(_) | TBreak | TContinue:
				unsupported(e.epos);
			case TCast(e1, t) if (t != null):
				genCast(ctx, genValue, e1, t);
			case TCast(e1, _):
				genValue(ctx, e1);
			case TVar(_) | TWhile(_) | TThrow(_):
				/* value is discarded anyway */
				var v = value();
				genExpr(ctx, e);
				v();
			case TBlock([e]):
				genValue(ctx, e);
			case TBlock(el):
				var v = value();
				function loop(i:Int) {
					if (i >= el.length) spr(ctx, "return nil"); else if (i == el.length - 1) genBlockElement(ctx, assign(el[i])); else {
						genBlockElement(ctx, el[i]);
						newline(ctx);
						loop(i + 1);
					}
				}
				loop(0);
				v();
			case TIf(cond, e, eo):
				var v = value();
				spr(ctx, "if ");
				genCond(ctx, cond);
				spr(ctx, " then ");
				genBlockElement(ctx, assign(e));
				function genElseif(ctx:LuaCtx, e:Null<TExpr>) {
					switch e {
						case null:
						case e2:
							switch e2.eexpr {
								case TIf(cond3, e3, eo3):
									spr(ctx, " elseif ");
									genCond(ctx, cond3);
									spr(ctx, " then ");
									genBlockElement(ctx, assign(e3));
									genElseif(ctx, eo3);
								case _:
									spr(ctx, " else ");
									genBlockElement(ctx, assign(e2));
							}
					}
				}
				genElseif(ctx, eo);
				spr(ctx, " end");
				v();
			case TSwitch(sw):
				var v = value();
				var sw = new TSwitch(sw.switchSubject, sw.switchCases.map(c -> new TSwitchCase(c.casePatterns, assign(c.caseExpr))),
					sw.switchDefault == null ? null : assign(sw.switchDefault), sw.switchExhaustive);
				genExpr(ctx, mk(TSwitch(sw), e.etype, e.epos));
				v();
			case TTry(b, catchs):
				var v = value();
				function block(e:TExpr):TExpr return mk(TBlock(vector(e)), e.etype, e.epos);
				genBlockElement(ctx, mk(TTry(block(assign(b)), catchs.map(c -> {variable: c.variable, expr: block(assign(c.expr))})), e.etype, e.epos));
				v();
				clearMapping();
		}
	}

	static function genTbinop(ctx:LuaCtx, op:Binop, e1:TExpr, e2:TExpr):Void {
		switch [op, e1.eexpr, e2.eexpr] {
			case [OpAssign, TField(e3, ci = FInstance(_)), TFunction(f)]:
				withFunctionScope(ctx, function() {
					genExpr(ctx, e1);
					spr(ctx, " = ");
					var fnArgs = f.tfArgs.mapToArray(argName).map(ident);
					print(ctx, "function(" + (if (isDotAccess(e3, ci)) fnArgs else ["self"].concat(fnArgs)).join(",") + ") ");
					var fblock = funBlock(ctx, f, e1.epos);
					switch fblock.eexpr {
						case TBlock(el):
							genFuncBlock(ctx, e1, el);
						case _:
							genValue(ctx, e2);
					}
					spr(ctx, " end");
				});
			case [OpAssign, _, _]:
				var iifeAssign = ctx.iifeAssign;
				if (iifeAssign) spr(ctx, "(function() ");
				switch [e1.eexpr, e2.eexpr] {
					case [_, TBinop(op = OpAssign, e3, e4)]:
						genTbinop(ctx, op, e3, e4);
						newline(ctx);
						genValue(ctx, e1);
						spr(ctx, " = ");
						genValue(ctx, e3);
					case [TField(e3, (FClosure(_) | FAnon(_))), TField(e4, (FClosure(_) | FStatic(_)))] if (isFunctionType(e2.etype)):
						genAssignWrapped(ctx, op, e1, e2, "_hx_funcToField");
					case [TField(e3, lhs = FInstance(_)), TField(e4, rhs = FInstance(_))] if (isFunctionType(e2.etype)
						&& !(isDotAccess(e3, lhs))
						&& (isDotAccess(e4, rhs))):
						genAssignWrapped(ctx, op, e1, e2, "_hx_funcToField");
					case [TField(e3, ci = FInstance(_)), TField(e4, (FClosure(_) | FStatic(_)))] if (isFunctionType(e2.etype) && !(isDotAccess(e3, ci))):
						genAssignWrapped(ctx, op, e1, e2, "_hx_funcToField");
					case [TField(e3, ci = FInstance(_, _, icf)), TField(e4, FAnon(_))] if (isFunctionType(e2.etype) && (switch icf.cfKind {
							case Var(_): true;
							case _: false;
						}) && isDotAccess(e3, ci)):
						genAssignWrapped(ctx, op, e1, e2, "_hx_anonToField");
					case [TField(e3, ci = FInstance(_, _, icf)), TField(e4, FDynamic(_))] if (isFunctionType(icf.cfType) && (switch icf.cfKind {
							case Var(_): true;
							case _: false;
						}) && isDotAccess(e3, ci)):
						genAssignWrapped(ctx, op, e1, e2, "_hx_anonToField");
					case [TField(e3, ci = FInstance(_)), TLocal(t)] if ((isFunctionType(t.vType)) && (!(isDotAccess(e3, ci)))):
						genAssignWrapped(ctx, op, e1, e2, "_hx_funcToField");
					case [_, TCast(e1 = {eexpr: TTypeExpr(mt)}, null)] if (switch mt {
							case TClassDecl({clPath: {pack: [], name: "Array"}}): false;
							case _: true;
						}):
						addFeature(ctx, "use._hx_staticToInstance");
						genValue(ctx, e1);
						print(ctx, " " + Ast.sBinop(op) + " ");
						spr(ctx, "_hx_staticToInstance(");
						genExpr(ctx, e2);
						spr(ctx, ")");
					case [TField(e3, ef), _] if (isPossibleStringField(e3, fieldName(ef))):
						/* Assignment target can never be a string, so skip _hx_wrap_if_string_field */
						genValue(ctx, e3);
						spr(ctx, field(fieldName(ef)));
						print(ctx, " " + Ast.sBinop(op) + " ");
						genValue(ctx, e2);
					case _:
						genValue(ctx, e1);
						print(ctx, " " + Ast.sBinop(op) + " ");
						genValue(ctx, e2);
				}
				if (iifeAssign) {
					spr(ctx, " return ");
					genValue(ctx, e1);
					spr(ctx, " end)()");
				}
			case [OpAssignOp(op2), TArray(e3, e4), _]:
				/* IIFE ensures array index is evaluated once for compound assignment like arr[i] += 1 */
				println(ctx, "(function() ");
				var idx = allocVar(VGenerated, "idx", e4.etype, e4.epos);
				var idxVar = mk(TVar(idx, e4), e4.etype, e4.epos);
				genExpr(ctx, idxVar);
				var arr = allocVar(VGenerated, "arr", e3.etype, e3.epos);
				var arrVar = mk(TVar(arr, e3), e3.etype, e3.epos);
				genExpr(ctx, arrVar);
				newline(ctx);
				var arrExpr = (mk(TArray((mk(TLocal(arr), e3.etype, e3.epos)), (mk(TLocal(idx), e4.etype, e4.epos))), e3.etype, e3.epos));
				spr(ctx, "arr[idx] = ");
				genTbinop(ctx, op2, arrExpr, e2);
				semicolon(ctx);
				newline(ctx);
				spr(ctx, "return arr[idx]");
				spr(ctx, " end)()");
			case [OpAssignOp(op2), TField(e3, e4), _]:
				/* IIFE ensures field target is evaluated once for compound assignment like obj.x += 1 */
				println(ctx, "(function() ");
				var obj = allocVar(VGenerated, "obj", e3.etype, e3.epos);
				spr(ctx, "local fld = ");
				genFieldAccessName(ctx, e4);
				semicolon(ctx);
				newline(ctx);
				var objVar = mk(TVar(obj, e3), e3.etype, e3.epos);
				genExpr(ctx, objVar);
				newline(ctx);
				var objExpr = (mk(TField((mk(TLocal(obj), e3.etype, e3.epos)), e4), e3.etype, e3.epos));
				spr(ctx, "obj[fld] = ");
				genTbinop(ctx, op2, objExpr, e2);
				semicolon(ctx);
				newline(ctx);
				spr(ctx, "return obj[fld]");
				spr(ctx, " end)()");
			case [OpAssignOp(op2), _, _]:
				/* IIFE for compound assignment to return the new value */
				spr(ctx, "(function() ");
				genValue(ctx, e1);
				spr(ctx, " = ");
				genTbinop(ctx, op2, e1, e2);
				spr(ctx, " return ");
				genValue(ctx, e1);
				spr(ctx, " end)()");
			case [OpXor, _, _] | [OpAnd, _, _] | [OpShl, _, _] | [OpShr, _, _] | [OpUShr, _, _] | [OpOr, _, _]:
				genBitop(ctx, op, e1, e2);
			case [OpMod, _, _]:
				spr(ctx, "_G.math.fmod(");
				genExpr(ctx, e1);
				spr(ctx, ", ");
				genExpr(ctx, e2);
				spr(ctx, ")");
			case [OpAdd, _, _] if ((isDynamicExpr(e1) && isDynamicExpr(e2))):
				addFeature(ctx, "use._hx_dyn_add");
				spr(ctx, "_hx_dyn_add(");
				genValue(ctx, e1);
				spr(ctx, ",");
				genValue(ctx, e2);
				spr(ctx, ")");
			case [OpAdd, _, _] if ((isStringExpr(e1) || isStringExpr(e2))):
				spr(ctx, "Std.string(");
				genValue(ctx, e1);
				spr(ctx, ") .. Std.string(");
				genValue(ctx, e2);
				spr(ctx, ")");
			case _:
				/* wrap expressions used in comparisons for lua */
				genParenTbinop(ctx, e1);
				switch op {
					case OpNotEq:
						print(ctx, " ~= ");
					case OpBoolAnd:
						print(ctx, " and ");
					case OpBoolOr:
						print(ctx, " or ");
					case _:
						print(ctx, " " + Ast.sBinop(op) + " ");
				}
				genParenTbinop(ctx, e2);
		}
	}

	static function genParenTbinop(ctx:LuaCtx, e:TExpr):Void {
		var ee = extractExpr(e);
		switch ee.eexpr {
			case TBinop(_):
				genParen(ctx, vector(ee));
			case _:
				genValue(ctx, ee);
		}
	}

	static function genBitop(ctx:LuaCtx, op:Binop, e1:TExpr, e2:TExpr):Void {
		addFeature(ctx, "use._bitop");
		print(ctx, "_hx_bit." + (switch op {
			case OpXor: "bxor";
			case OpAnd: "band";
			case OpShl: "lshift";
			case OpShr: "arshift";
			case OpUShr: "rshift";
			case OpOr: "bor";
			case _: "";
		}) + "(");
		genValue(ctx, e1);
		spr(ctx, ",");
		genValue(ctx, e2);
		spr(ctx, ")");
	}

	static function genReturn(ctx:LuaCtx, e:TExpr, eo:Null<TExpr>, wrap:Bool):Void {
		if (ctx.inValue != null) unsupported(e.epos);
		function openRet() if (wrap) spr(ctx, "do return ") else spr(ctx, "return ");
		function closeRet() if (wrap) spr(ctx, " end");
		switch eo {
			case null:
				if (wrap) spr(ctx, "do return end") else spr(ctx, "return");
			case e:
				switch e.eexpr {
					case TField(e2, t = (FAnon(tcf) | FInstance(_, _, tcf))) if ((isFunctionType(tcf.cfType)) && (!(isDotAccess(e2, t)))):
						/* See issue #6259 */
						addFeature(ctx, "use._hx_bind");
						openRet();
						print(ctx, "_hx_bind(");
						genValue(ctx, e2);
						spr(ctx, ",");
						genValue(ctx, e);
						spr(ctx, ")");
						closeRet();
					case TBinop(OpAssign, e1, e2):
						genExpr(ctx, e);
						if (wrap) spr(ctx, " do return ") else spr(ctx, " return ");
						genValue(ctx, e1);
						closeRet();
					case _:
						openRet();
						genValue(ctx, e);
						closeRet();
				}
		}
	}

	static function genIifeAssign(ctx:LuaCtx, f:Void->Void):Void {
		spr(ctx, "local _ = ");
		f();
	}

	static function hasClass(ctx:LuaCtx, c:TClass):Bool
		return hasFeature(ctx, "lua.Boot.getClass")
			&& (c.clSuper != null || c.clOrderedFields.length > 0 || c.clConstructor != null);

	static function hasPrototype(ctx:LuaCtx, c:TClass):Bool
		return c.clSuper != null || (hasClass(ctx, c)) || Lambda.exists(c.clOrderedFields, canGenClassField.bind(ctx, _));

	static function canGenClassField(ctx:LuaCtx, f:TClassField):Bool {
		return switch f {
			case {cfExpr: (null | {eexpr: TConst(TNull)})} if (!(hasFeature(ctx, "Type.getInstanceFields"))):
				false;
			case f:
				isPhysicalField(f);
		}
	}

	static function checkMultireturn(ctx:LuaCtx, c:TClass):Void {
		switch c {
			case _ if (Meta.has(MultiReturn, c.clMeta)):
				if (!(hasClassFlag(c, CExtern))) raiseTypingError("MultiReturns must be externs",
					c.clPos) else if (c.clOrderedStatics.length > 0) raiseTypingError("MultiReturns must not contain static fields",
					c.clPos) else if ((Lambda.exists(c.clOrderedFields, cf -> switch cf.cfKind {
					case Method(_): true;
					case _: false;
				}))) raiseTypingError("MultiReturns must not contain methods", c.clPos);
			case {clSuper: {cls: csup}} if (Meta.has(MultiReturn, csup.clMeta)):
				raiseTypingError("Cannot extend a MultiReturn", c.clPos);
			case _:
		}
	}

	static function checkFieldName(c:TClass, f:TClassField):Void {
		switch f.cfName {
			case "prototype" | "__proto__" | "constructor" | "__mt__":
				raiseTypingError("The field name '" + f.cfName + "'  is not allowed in Lua", (switch f.cfExpr {
					case null: c.clPos;
					case e: e.epos;
				}));
			case _:
		}
	}

	/* convert a.b.c to ["a"]["b"]["c"] */
	static function pathToBrackets(path:String):String {
		var parts = path.split(".");
		return "[\"" + (parts.join("\"][\"")) + "\"]";
	}

	static function genClassStaticField(ctx:LuaCtx, c:TClass, f:TClassField):Void {
		switch f.cfExpr {
			case null | {eexpr: TConst(TNull)} if (!(hasFeature(ctx, "Type.getClassFields"))):
			case null if (!(isPhysicalField(f))):
			case null:
				println(ctx, sPath(ctx, c.clPath) + field(f.cfName) + " = nil");
			case e:
				switch e.eexpr {
					case TFunction(_):
						var path = (sPath(ctx, c.clPath)) + (field(f.cfName));
						var dotPath = (dotPath(c.clPath)) + (staticField(c, f.cfName));
						ctx.idCounter = 0;
						print(ctx, path + " = ");
						genValue(ctx, e);
						newline(ctx);
						switch (getExposed(ctx, dotPath, f.cfMeta)) {
							case [s]:
								print(ctx, "_hx_exports" + pathToBrackets(s) + " = " + path);
								newline(ctx);
							case _:
						}
					case _:
						ctx.statics.unshift({c: c, f: f, e: e});
				}
		}
	}

	static function genClassField(ctx:LuaCtx, c:TClass, f:TClassField):Void {
		var p = sPath(ctx, c.clPath);
		checkFieldName(c, f);
		print(ctx, p + ".prototype" + field(f.cfName));
		switch f.cfExpr {
			case null:
				println(ctx, "= nil;");
			case e:
				ctx.idCounter = 0;
				switch e.eexpr {
					case TFunction(f2):
						withFunctionScope(ctx, function() {
							print(ctx, " = function");
							print(ctx, "(" + ["self"].concat(f2.tfArgs.mapToArray(luaArgName)).join(",") + ") ");
							var fblock = funBlock(ctx, f2, e.epos);
							switch fblock.eexpr {
								case TBlock(el):
									genFuncBlock(ctx, e, el);
								case _:
							}
							println(ctx, "end");
						});
						ctx.separator = true;
					case _:
						genValue(ctx, e);
						newline(ctx);
				}
		}
	}

	static function generateClass__name__(ctx:LuaCtx, c:TClass):Void {
		if (hasFeature(ctx, "lua.Boot.isClass")) {
			var flatPath = sPath(ctx, c.clPath);
			var dotPath = c.clPath.pack.concat([c.clPath.name]).map(s -> sEscapeLua(s)).join(".");
			println(ctx, flatPath + ".__name__ = \"" + dotPath + "\"");
		}
	}

	static function generateClass(ctx:LuaCtx, c:TClass):Void {
		ctx.current = c;
		ctx.idCounter = 0;
		switch c.clPath {
			case {pack: [], name: "Function"}:
				raiseTypingError("This class redefines a native one", c.clPos);
			case _:
		}
		var p = sPath(ctx, c.clPath);
		var hxClasses = hasFeature(ctx, "Type.resolveClass");
		newline(ctx);
		print(ctx, p + ".new = ");
		switch c.clKind {
			case KAbstractImpl(_):
				/* abstract implementations only contain static members and don't need to have constructor functions */
				print(ctx, "{}");
				ctx.separator = true;
			case _:
				switch c.clConstructor {
					case {cfExpr: e} if (e != null):
						switch e.eexpr {
							case TFunction(f):
								withFunctionScope(ctx, function() {
									var args = f.tfArgs.mapToArray(luaArgName);
									print(ctx, "function(" + args.join(",") + ") ");
									var fblock = funBlock(ctx, f, e.epos);
									switch fblock.eexpr {
										case TBlock(el):
											var bend = openBlock(ctx);
											newline(ctx);
											if (!(hasPrototype(ctx, c))) println(ctx, "local self = _hx_new()") else
												println(ctx, 'local self = _hx_nsh($p.__mt__)');
											println(ctx, p + ".super(" + ["self"].concat(args).join(",") + ")");
											if (p == "String") println(ctx, "self = string");
											spr(ctx, "return self");
											bend();
											newline(ctx);
											spr(ctx, "end");
											newline(ctx);
											var bend = openBlock(ctx);
											print(ctx, p + ".super = function(" + ["self"].concat(args).join(",") + ") ");
											for (e in el) genBlockElement(ctx, e);
											bend();
											newline(ctx);
											spr(ctx, "end");
										case _:
									}
								});
								ctx.separator = true;
							case _:
								genExpr(ctx, e);
						}
					case _:
						(print(ctx, "{}"));
						ctx.separator = true;
				}
		}
		newline(ctx);

		switch (getExposed(ctx, (dotPath(c.clPath)), c.clMeta)) {
			case [s]:
				print(ctx, "_hx_exports" + pathToBrackets(s) + " = " + p);
				newline(ctx);
			case _:
		}

		if (hxClasses) println(ctx, "_hxClasses[\"" + dotPath(c.clPath) + "\"] = " + p);
		generateClass__name__(ctx, c);
		switch c.clImplements {
			case []:
			case l:
				println(ctx, p + ".__interfaces__ = {" + l.map(i -> ctx.typeAccessor(TClassDecl(i.cls))).join(",") + "}");
		}

		function genProps(props:Array<{name:String, field:String}>):String
			return props.map(pv -> pv.name + "=\"" + pv.field + "\"").join(",");
		var hasPropertyReflection = (hasFeature(ctx, "Reflect.getProperty")) || (hasFeature(ctx, "Reflect.setProperty"));

		if (hasPropertyReflection) {
			switch codegen.Codegen.getProperties(c.clOrderedStatics) {
				case []:
				case props:
					println(ctx, p + ".__properties__ = {" + genProps(props) + "}");
			}
		}

		for (f in c.clOrderedStatics) genClassStaticField(ctx, c, f);

		if ((hasPrototype(ctx, c))) {
			println(ctx, p + ".prototype = _hx_e();");
			for (f in c.clOrderedFields) if (canGenClassField(ctx, f)) (genClassField(ctx, c, f));
			if ((hasClass(ctx, c))) {
				newline(ctx);
				println(ctx, p + ".prototype.__class__ =  " + p);
			}

			if (hasPropertyReflection) {
				var props = codegen.Codegen.getProperties(c.clOrderedFields);
				switch c.clSuper {
					case _ if (props.length == 0):
					case _:
						newline(ctx);
						println(ctx, p + ".prototype.__properties__ =  {" + genProps(props) + "}");
				}
			}
			switch c.clSuper {
				case null:
				case {cls: csup}:
					var psup = ctx.typeAccessor(TClassDecl(csup));
					println(ctx, p + ".__super__ = " + psup);
					println(ctx, 'setmetatable($p.prototype,{__index=$psup.prototype})');
					/* Also use the __properties__  from the super class as the __index metatable */
					if (hasPropertyReflection && codegen.Codegen.hasProperties(csup))
						println(ctx, 'setmetatable($p.prototype.__properties__,{__index=$psup.prototype.__properties__})');
			}

			/* Create a metatable specific for this class */
			println(ctx, '$p.__mt__ = _hx_mmt($p.prototype)');
		}
	}

	static function generateEnum(ctx:LuaCtx, e:TEnum):Void {
		var p = sPath(ctx, e.ePath);
		var ename = e.ePath.pack.concat([e.ePath.name]).map(s -> sEscapeLua(s));

		/* Register enum in _hxClasses for reflection - different features need different metadata */
		if (hasFeature(ctx, "Type.resolveEnum")) {
			print(ctx, "_hxClasses[\"" + dotPath(e.ePath) + "\"] = " + p);
			semicolon(ctx);
			newline(ctx);
		}
		if (hasFeature(ctx, "lua.Boot.isEnum")) {
			print(ctx, "_hxClasses[\"" + dotPath(e.ePath) + "\"] = {");
			print(ctx, " __ename__ = " + (if (hasFeature(ctx, "Type.getEnumName")) "\"" + ename.join(".") + "\"" else "true") + ",");
			spr(ctx, " __constructs__ = _hx_tab_array({");
			if (e.eNames.length > 0) {
				spr(ctx, "[0]=");
				spr(ctx, e.eNames.map(s -> '"$s"').join(","));
			}
			print(ctx, "}," + e.eNames.length + ")}");
			ctx.separator = true;
			newline(ctx);
		}

		if (hasFeature(ctx, "Type.resolveEnum") || hasFeature(ctx, "lua.Boot.isEnum"))
			print(ctx, p + " = _hxClasses[\"" + dotPath(e.ePath) + "\"];");

		newline(ctx);
		for (n in e.eNames) {
			var f = e.eConstrs.get(n);
			if (f == null) throw core.ds.NotFound.raise();
			print(ctx, p + field(f.efName) + " = ");
			switch f.efType {
				case TFun(sig):
					var count = sig.args.length;
					var sargs = sig.args.map(a -> ident(a.name)).join(",");
					print(ctx,
						'function($sargs) local _x = _hx_tab_array({[0]="${f.efName}",${f.efIndex},$sargs,__enum__=$p}, ${count + 2});');
					if (hasFeature(ctx, "may_print_enum"))
						/* _estr is the enum toString helper defined in the runtime */
						spr(ctx, " rawset(_x, 'toString', _estr);");
					spr(ctx, " return _x; end ");
					ctx.separator = true;
				case _:
					println(ctx, '_hx_tab_array({[0]="${f.efName}",${f.efIndex},__enum__ = $p},2)');
					if (hasFeature(ctx, "may_print_enum")) {
						println(ctx, "rawset(" + p + field(f.efName) + ", 'toString', _estr)");
					}
			}
			newline(ctx);
		}
		if (hasFeature(ctx, "Type.allEnums")) {
			var ctorsWithoutArgs = e.eNames.filter(function(s) {
				var ef = e.eConstrs.get(s);
				if (ef == null) throw core.ds.NotFound.raise();
				return switch follow(ef.efType) {
					case TFun(_): false;
					case _: true;
				}
			});
			print(ctx, p + ".__empty_constructs__ = ");
			spr(ctx, "_hx_tab_array({");
			if (ctorsWithoutArgs.length > 0) {
				spr(ctx, "[0] = ");
				print(ctx, ctorsWithoutArgs.map(s -> '$p.$s').join(","));
			}
			println(ctx, "}, " + ctorsWithoutArgs.length + ")");
		}
	}

	static function generateStatic(ctx:LuaCtx, s:{c:TClass, f:TClassField, e:TExpr}):Void {
		var c = s.c, f = s.f, e = s.e;
		var dotPath = (dotPath(c.clPath)) + (staticField(c, f.cfName));
		var path = (sPath(ctx, c.clPath)) + (field(f.cfName));
		print(ctx, path + " = ");
		genValue(ctx, e);
		semicolon(ctx);
		newline(ctx);
		switch (getExposed(ctx, dotPath, f.cfMeta)) {
			case [s]:
				print(ctx, "_hx_exports" + pathToBrackets(s) + " = " + path);
				semicolon(ctx);
			case _:
		}
		newline(ctx);
	}

	static function generateEnumMetaFields(ctx:LuaCtx, t:ModuleType):Void {
		switch t {
			case TEnumDecl(e):
				var p = sPath(ctx, e.ePath);
				switch Texpr.buildMetadata(ctx.com.basic, TEnumDecl(e)) {
					case null:
					case e:
						print(ctx, p + ".__meta__ = ");
						genExpr(ctx, e);
						newline(ctx);
				}
			case _:
		}
	}

	static function generateRequire(ctx:LuaCtx, path:GlobalTypePath, meta:Metadata):Void {
		var m = Meta.get(LuaRequire, meta);
		var p = (sPath(ctx, path));

		switch m.exprs {
			case [{expr: EConst(String(moduleName, _))}]:
				print(ctx, p + " = _G.require(\"" + moduleName + "\")");
			case [{expr: EConst(String(moduleName, _))}, {expr: EConst(String(objectPath, _))}]:
				print(ctx, p + " = _G.require(\"" + moduleName + "\")." + objectPath);
			case _:
				raiseTypingError("Unsupported @:luaRequire format", m.pos);
		}

		newline(ctx);
	}

	static function generateType(ctx:LuaCtx, t:ModuleType):Void {
		switch t {
			case TClassDecl(c):
				switch TClassTools.getClInit(c) {
					case null:
					case e:
						ctx.inits.unshift(e);
				}
				var p = sPath(ctx, c.clPath);
				/* A special case for Std because we do not want to generate it if it's empty. */
				if (p == "Std" && c.clOrderedStatics.length == 0) {} else if ((!(hasClassFlag(c, CExtern))) && Meta.has(LuaDotMethod, c.clMeta))
					raiseTypingError("LuaDotMethod is valid for externs only", c.clPos)
				else if (!(hasClassFlag(c, CExtern))) generateClass(ctx, c);
				checkMultireturn(ctx, c);
			case TEnumDecl(e):
				if (!(hasEnumFlag(e, EnExtern))) generateEnum(ctx, e) else {};
			case TTypeDecl(_) | TAbstractDecl(_):
		}
	}

	static function genTypeForwardDecl(ctx:LuaCtx, path:GlobalTypePath):Void {
		var p = sPath(ctx, path);
		if (path.pack.length == 0) spr(ctx, "local ");
		println(ctx, p + " = _hx_e()");
	}

	static function generateTypeForward(ctx:LuaCtx, t:ModuleType):Void {
		switch t {
			case TClassDecl(c):
				if (!(hasClassFlag(c, CExtern))) genTypeForwardDecl(ctx, c.clPath) else if (Meta.has(LuaRequire, c.clMeta)
					&& Gctx.isDirectlyUsed(ctx.com, c.clMeta))
					generateRequire(ctx, c.clPath, c.clMeta);
			case TEnumDecl(e) if (hasEnumFlag(e, EnExtern)):
				if (Meta.has(LuaRequire, e.eMeta) && Gctx.isDirectlyUsed(ctx.com, e.eMeta)) generateRequire(ctx, e.ePath, e.eMeta);
			case TEnumDecl(e):
				genTypeForwardDecl(ctx, e.ePath);
			case TTypeDecl(_) | TAbstractDecl(_):
		}
	}

	static function allocCtx(com:Gctx):LuaCtx {
		var smap:Null<Sourcemap> = if (com.debug || Gctx.defined(com, Define.SourceMap)) ({
			sourceLastPos: {file: 0, line: 0, col: 0},
			printComma: false,
			outputLastCol: 0,
			outputCurrentCol: 0,
			sources: [],
			sourcesHash: new StringMap(),
			mappings: new StringBuf(),
			currentExpr: null,
		} : Sourcemap) else null;
		var ctx = new LuaCtx();
		ctx.com = com;
		ctx.buf = new StringBuf();
		ctx.bufLast = -1;
		ctx.smap = smap;
		ctx.statics = [];
		ctx.inits = [];
		ctx.current = nullClass;
		ctx.tabs = "";
		ctx.inValue = null;
		ctx.loopCtx = defaultLoopContext;
		ctx.iifeAssign = false;
		ctx.idCounter = 0;
		ctx.typeAccessor = _ -> Globals.die("", "genlua.ml");
		ctx.separator = false;
		ctx.luaJit = Gctx.defined(com, Define.LuaJit);
		ctx.luaVanilla = Gctx.defined(com, Define.LuaVanilla);
		ctx.luaVer = try core.ds.OcamlFloat.ofString(Gctx.definedValue(com, Define.LuaVer)) catch (_:core.ds.NotFound) 5.2;
		ctx.declaredLocals = new StringMap();
		ctx.inPcall = false;
		ctx.needsSep = false;
		ctx.typeAccessor = function(t) {
			var p = tPath(t);
			return switch t {
				case TClassDecl(c) if ((hasClassFlag(c, CExtern)) && !(Meta.has(LuaRequire, c.clMeta))):
					dotPath(p);
				case TEnumDecl(e) if (hasEnumFlag(e, EnExtern)):
					dotPath(p);
				case _: sPath(ctx, p);
			}
		};
		return ctx;
	}

	static function transformMultireturn(ctx:LuaCtx, t:ModuleType):Void {
		switch t {
			case TClassDecl(c):
				function isMultireturn(t:T):Bool {
					return switch follow(t) {
						case TInst(c, _) if (Meta.has(MultiReturn, c.clMeta)): true;
						case _: false;
					}
				}
				function loop(e:TExpr):TExpr {
					return switch e.eexpr {
						/*
							if we found a var declaration initialized by a multi-return call, mark it with @:multiReturn meta,
							so it will later be generated as multiple locals unpacking the value
						 */
						case TVar(v, ecall = {eexpr: TCall(_)}) if (isMultireturn(v.vType)):
							v.vMeta = [({meta: core.MetaList.StrictMeta.MultiReturn, exprs: vector(), pos: v.vPos} : MetadataEntry)].concat(v.vMeta);
							var ecall = Texpr.mapExpr(loop, ecall);
							{eexpr: TVar(v, ecall), etype: e.etype, epos: e.epos};

						/* if we found a field access for the multi-return call, generate select call */
						case TField(ecall = {eexpr: TCall(_)}, f) if (isMultireturn(ecall.etype)):
							var ecall = Texpr.mapExpr(loop, ecall);
							mkMrSelect(ctx.com.basic, e, ecall, fieldName(f));

						/* if we found a multi-return call used as a value, box it */
						case TCall(_) if (isMultireturn(e.etype)):
							var e = Texpr.mapExpr(loop, e);
							mkMrBox(ctx, e);

						/* Don't bother wrapping multireturn function results if we don't use the return values */
						case TBlock(el):
							var el2 = el.map(function(x) return switch x.eexpr {
								case TCall(e2, el) if (isMultireturn(x.etype)):
									mk(TCall(e2, el.map(x -> Texpr.mapExpr(loop, x))), x.etype, x.epos);
								case _: loop(x);
							});
							mk(TBlock(el2), e.etype, e.epos);

						/* if we found a field access for a multi-return local - that's fine, because it'll be generated as a local var */
						case TField({eexpr: TLocal(v)}, _) if (Meta.has(MultiReturn, v.vMeta)):
							e;
						case TReturn(e2) if (e2 != null):
							if (isMultireturn(e2.etype)) raiseTypingError("You cannot return a multireturn type from a haxe function",
								e2.epos) else Texpr.mapExpr(loop, e);
						/*
							if we found usage of local var we previously marked with @:multiReturn as a value itself,
							remove the @:multiReturn meta and add "box me" meta so it'll be boxed on var initialization
						 */
						case TLocal(v) if (Meta.has(MultiReturn, v.vMeta)):
							v.vMeta = v.vMeta.filter(m -> !Meta.metaEq(core.MetaList.StrictMeta.MultiReturn, m.meta));
							v.vMeta = [({meta: core.MetaList.StrictMeta.Custom(":lua_mr_box"), exprs: vector(), pos: v.vPos} : MetadataEntry)].concat(v.vMeta);
							e;

						case _:
							Texpr.mapExpr(loop, e);
					}
				}
				function transformField(f:TClassField) {
					checkMultireturnParam(ctx, f.cfType, f.cfPos);
					switch f.cfExpr {
						case null:
						case e:
							f.cfExpr = (loop(e));
					}
				}
				for (f in c.clOrderedFields) transformField(f);
				for (f in c.clOrderedStatics) transformField(f);
				if (c.clConstructor != null) transformField(c.clConstructor);
				/* Also transform __init__ expressions */
				switch TClassTools.getClInit(c) {
					case null:
					case e:
						TClassTools.setClInit(c, (loop(e)));
				}
			case _:
		}
	}

	public static function generate(com:Gctx):Void {
		var ctx = allocCtx(com);

		Gctx.mapSourceHeader(com.defines, s -> print(ctx, '-- $s\n'));

		if (hasFeature(ctx, "Class") || hasFeature(ctx, "Type.getClassName")) addFeature(ctx, "lua.Boot.isClass");
		if (hasFeature(ctx, "Enum") || hasFeature(ctx, "Type.getEnumName")) addFeature(ctx, "lua.Boot.isEnum");
		if (hasFeature(ctx, "lua.Lib.getModuleVarargs")) addFeature(ctx, "use._hx_module_varargs");

		function printFile(path:String) {
			var fileContent = sys.io.File.getContent(path);
			print(ctx, fileContent + "\n");
		}

		function findFile(f:String):String return com.classPaths.findFile(f).file;

		/* pre-declare base runtime globals as locals */
		/* NOTE: _hx_array_mt must remain global — hx-lua-simdjson reads it from _G */
		println(ctx, "local _hx_is_array, _hx_tab_array, _hx_print_class, _hx_print_enum, _hx_tostring, _hx_field_arr");

		/* base table-to-array helpers and metatables */
		if (ctx.luaJit) printFile(findFile("lua/_lua/_hx_tab_array_jit.lua")) else printFile(findFile("lua/_lua/_hx_tab_array.lua"));

		/* base lua "toString" functionality for haxe objects*/
		printFile(findFile("lua/_lua/_hx_tostring.lua"));

		/* base lua metatables for prototypes, inheritance, etc. */
		printFile(findFile("lua/_lua/_hx_anon.lua"));

		/* Helpers for creating metatables from prototypes */
		printFile(findFile("lua/_lua/_hx_objects.lua"));

		/* base runtime class stubs for haxe value types (Int, Float, etc) */
		printFile(findFile("lua/_lua/_hx_classes.lua"));

		var includeFiles = com.includeFiles.copy();
		includeFiles.reverse();
		for (file in includeFiles) {
			switch file {
				case {file: path, position: "top"}: printFile(path);
				case _:
			}
		}

		var varExports = {name: "_hx_exports", value: "_hx_exports or {}"};

		var exposed:Array<String> = [];
		for (t in com.types) {
			switch t {
				case TClassDecl(c):
					var path = dotPath(c.clPath);
					var classExposed = getExposed(ctx, path, c.clMeta);
					var staticExposed = c.clOrderedStatics.map(f -> getExposed(ctx, path + staticField(c, f.cfName), f.cfMeta));
					exposed = exposed.concat(classExposed);
					for (l in staticExposed) exposed = exposed.concat(l);
				case _:
			}
		}
		var anyExposed = exposed.length > 0;
		var exportMap = new StringMap<ObjectStore>();
		var exposedObject = new ObjectStore("", []);
		var toplevelExposed = [];
		for (path in exposed) {
			var parts = path.split(".");
			function loop(p:Array<String>, pre:String) {
				switch p {
					case _ if (p.length >= 2):
						var f = p[0];
						var path = switch pre {
							case "": f;
							case pre: (pre + "." + f);
						}
						if (!(exportMap.exists(path))) {
							var elts = new ObjectStore(f, []);
							exportMap.set(path, elts);
							var cobject = switch pre {
								case "": exposedObject;
								case pre:
									var o = exportMap.get(pre);
									if (o == null) throw core.ds.NotFound.raise();
									o;
							}
							cobject.osFields.unshift(elts);
						}
						loop(p.slice(1), path);
					case [f] if (pre == ""):
						toplevelExposed.unshift(f);
					case _:
				}
			}
			loop(parts, "");
		}

		if ((anyExposed)) {
			print(ctx, "local " + varExports.name + " = " + varExports.value);
			ctx.separator = true;
			newline(ctx);
		}

		function printObj(f:ObjectStore, root:String) {
			var path = root + (pathToBrackets(f.osName));
			print(ctx, '$path = $path or _hx_e()');
			ctx.separator = true;
			newline(ctx);
			concat(ctx, ";", g -> printObj(g, path), f.osFields);
		}
		for (f in exposedObject.osFields) printObj(f, "_hx_exports");

		var vars = [];
		/* let vars = (if has_feature ctx "Type.resolveClass" || has_feature ctx "Type.resolveEnum" then ("_hxClasses = " ^ "{}") :: vars else vars) in */
		if (hasFeature(ctx, "may_print_enum"))
			vars.unshift("_estr = function(self) return " + (ctx.typeAccessor(bootClass)) + ".__string_rec(self,''); end");
		var vl = vars.copy();
		vl.reverse();
		switch vl {
			case []:
			case vl:
				print(ctx, "local " + vl.join(";"));
				ctx.separator = true;
				newline(ctx);
		}

		println(ctx, "local _hx_c = {}");
		for (t in com.types) generateTypeForward(ctx, t);
		newline(ctx);

		/* Generate some dummy placeholders for utility libs that may be required*/
		println(ctx,
			"local _hx_bind, _hx_bit, _hx_staticToInstance, _hx_funcToField, _hx_anonToField, _hx_print, _hx_apply_self, _hx_box_mr, _hx_bit_clamp, _hx_table, _hx_bit_raw, _hx_dyn_add, _hx_wrap_if_string_field, _hx_handle_error, _hx_luv");
		println(ctx, "local _hx_pcall_default = {};");
		println(ctx, "local _hx_pcall_break = {};");

		for (t in com.types) transformMultireturn(ctx, t);
		for (t in com.types) generateType(ctx, t);

		/* If bit ops are manually imported include the haxe wrapper for them */
		if (hasFeature(ctx, "use._bitop")) {
			printFile(findFile("lua/_lua/_hx_bit.lua"));
		}

		/* integer clamping is always required, and will use bit ops if available */
		printFile(findFile("lua/_lua/_hx_bit_clamp.lua"));

		/* Array is required, always patch it */
		println(ctx, "_hx_array_mt.__index = Array.prototype");
		newline(ctx);

		/* Functions to support auto-run of libuv loop - skip in vanilla mode */
		if (!ctx.luaVanilla) printFile(findFile("lua/_lua/_hx_luv.lua"));

		var b = openBlock(ctx);
		/* Localize init variables inside a do-block */
		println(ctx, "local _hx_static_init = function()");
		/* Generate static inits */
		var inits = ctx.inits.copy();
		inits.reverse();
		for (e in inits) genBlockElement(ctx, e);
		/* Generate statics */
		var statics = ctx.statics.copy();
		statics.reverse();
		for (s in statics) generateStatic(ctx, s);
		b();
		newline(ctx);
		println(ctx, "end");
		newline(ctx);

		for (fp in [
			{feature: "use._hx_bind", path: "lua/_lua/_hx_bind.lua"},
			{feature: "use._hx_staticToInstance", path: "lua/_lua/_hx_static_to_instance.lua"},
			{feature: "use._hx_funcToField", path: "lua/_lua/_hx_func_to_field.lua"},
			{feature: "use._hx_anonToField", path: "lua/_lua/_hx_anon_to_field.lua"},
			{feature: "Math.random", path: "lua/_lua/_hx_random_init.lua"},
			{feature: "use._hx_print", path: "lua/_lua/_hx_print.lua"},
			{feature: "use._hx_apply_self", path: "lua/_lua/_hx_apply_self.lua"},
			{feature: "use._hx_box_mr", path: "lua/_lua/_hx_box_mr.lua"},
			{feature: "use._hx_table", path: "lua/_lua/_hx_table.lua"},
			{feature: "use._hx_wrap_if_string_field", path: "lua/_lua/_hx_wrap_if_string_field.lua"},
			{feature: "use._hx_wrap_if_string_field_closure", path: "lua/_lua/_hx_wrap_if_string_field_closure.lua"},
			{feature: "use._hx_dyn_add", path: "lua/_lua/_hx_dyn_add.lua"},
			{feature: "use._hx_module_varargs", path: "lua/_lua/_hx_module_varargs.lua"},
		]) {
			if (hasFeature(ctx, fp.feature)) printFile(findFile(fp.path));
		}

		printFile(findFile("lua/_lua/_hx_handle_error.lua"));

		println(ctx, "_hx_static_init();");

		for (t in com.types) generateEnumMetaFields(ctx, t);

		switch com.main.mainExpr {
			case null:
			case e:
				spr(ctx, "local success, err = _G.xpcall(");
				var mainBlock = if (ctx.luaVanilla) vector(e) else {
					var luvRun =
						/* Runs libuv loop if needed */
						mkLuaCode(ctx.com.basic, "_hx_luv.run()", vector(), ctx.com.basic.tvoid, Globals.nullPos);
					vector(e, luvRun);
				}
				var fn:TFunc = {
					tfArgs: vector(),
					tfType: com.basic.tvoid,
					tfExpr: mk(TBlock(mainBlock), com.basic.tvoid, e.epos),
				};
				genValue(ctx, {eexpr: TFunction(fn), etype: TFun({args: vector(), ret: com.basic.tvoid}), epos: e.epos});
				println(ctx, ", _hx_handle_error)");
				println(ctx, "if not success then _G.error(err) end");
		}

		if (anyExposed) println(ctx, "return _hx_exports");

		switch ctx.smap {
			case null:
				try sys.FileSystem.deleteFile(com.file + ".map") catch (_:Dynamic) {}
			case smap:
				JsSourcemap.writeMappings(ctx.com, smap, "");
		}

		sys.io.File.saveContent(com.file, ctx.buf.toString());
	}
}
