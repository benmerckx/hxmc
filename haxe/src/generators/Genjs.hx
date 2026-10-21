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

import haxe.ds.StringMap;
import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.TOther.ExtType;
import core.TOther.TClassTools;
import core.Meta;
import core.Define;
import core.Error;
import core.Texpr;
import core.Texpr.Builder;
import core.ds.NotFound;
import generators.JsSourcemap;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

// port: Buffer.t; only the last character is ever inspected (`Buffer.nth buf (length-1)`).
class JsBuffer {
	var buf:StringBuf = new StringBuf();
	var last:Int = -1;

	public function new() {}

	public function addString(s:String):Void {
		if (s.length > 0) {
			buf.add(s);
			last = StringTools.fastCodeAt(s, s.length - 1);
		}
	}

	// port: Buffer.nth raises Invalid_argument "Buffer.nth" on an empty buffer.
	public function lastChar():Int {
		if (last < 0) throw new core.ds.InvalidArgument("Buffer.nth");
		return last;
	}

	public function contents():String return buf.toString();

	public function clear():Void {
		buf = new StringBuf();
		last = -1;
	}
}

// port: the `ctx` record (renamed: the generators package is shared by every target).
class JsCtx {
	public var com:Gctx;
	public var buf:JsBuffer;
	public var chan:Null<haxe.io.Output>;
	// port: (string list,unit) Hashtbl.t; only membership is tested.
	public var packages:StringMap<Bool>;
	public var smap:Null<Sourcemap>;
	public var jsModern:Bool;
	public var jsFlatten:Bool;
	public var hasResolveClass:Bool;
	public var hasInterfaceCheck:Bool;
	public var esVersion:Int;
	public var current:TClass;
	public var statics:Array<{c:TClass, f:TClassField, e:TExpr}>; // port: OCaml list, head at index 0
	public var inits:Array<TExpr>; // port: OCaml list, head at index 0
	public var tabs:String;
	public var inValue:Null<TVar>;
	public var inLoop:Bool;
	public var idCounter:Int;
	public var typeAccessor:ModuleType->String;
	public var separator:Bool;
	public var foundExpose:Bool;
	public var catchVars:Array<TExpr>; // port: OCaml list, head at index 0

	public function new() {}
}

// port: the `object_store` record (renamed like JsCtx).
class JsObjectStore {
	public var osName:String;
	public var osFields:Array<JsObjectStore>; // port: OCaml list, head at index 0

	public function new(osName:String, osFields:Array<JsObjectStore>) {
		this.osName = osName;
		this.osFields = osFields;
	}
}

class Genjs {
	public static function processExpose(meta:Metadata, fDefault:Void->String, f:String->Void):Void {
		var entry = Meta.getOpt(Meta.Expose, meta);
		if (entry == null) return;
		switch entry.exprs {
			case [{expr: EConst(String(s, _))}]:
				f(s);
			case []:
				f(fDefault());
			case _:
				Error.abort("Invalid @:expose parameters", entry.pos);
		}
	}

	public static function dotPath(p:GlobalTypePath):String return sTypePath(p);

	public static function sPath(ctx:JsCtx, p:GlobalTypePath):String return if (ctx.jsFlatten) core.Path.flatPath(p) else dotPath(p);

	static final kwds:StringMap<Bool> = new StringMap();

	static final es5kwds = [
		"arguments", "await", "break", "case", "catch", "class", "const", "continue",
		"debugger", "default", "delete", "do", "else", "enum", "eval", "export", "extends", "false",
		"finally", "for", "function", "if", "implements", "import", "in", "instanceof",
		"interface", "let", "new", "null", "package", "private", "protected",
		"public", "return", "static", "super", "switch", "this", "throw",
		"true", "try", "typeof", "var", "void", "while", "with", "yield"
	];

	// port: `Hashtbl.mem Genjs.kwds` in macroApi.ml (the table itself stays private).
	public static function isKeyword(s:String):Bool return kwds.exists(s);

	public static function setupKwds(com:Gctx):Void {
		kwds.clear();
		for (s in es5kwds) kwds.set(s, true);
	}

	/* Identifiers Haxe reserves to make the JS output cleaner. These can still be used in untyped code (TLocal),
		but are escaped upon declaration. */
	static final kwds2:StringMap<Bool> = {
		var h = new StringMap();
		for (s in [
			/* https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects */
			"Infinity", "NaN", "decodeURI", "decodeURIComponent", "encodeURI", "encodeURIComponent",
			"escape", "eval", "isFinite", "isNaN", "parseFloat", "parseInt", "undefined", "unescape",

			"JSON", "Number", "Object", "console", "window", "require",
		]) h.set(s, true);
		h;
	};

	public static function validJsIdent(s:String):Bool {
		if (s.length == 0) return false;
		// port: OCaml inspects bytes; any non-ASCII code unit is invalid either way.
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if ((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "$".code || c == "_".code) {} else if (c >= "0".code
				&& c <= "9".code
				&& i > 0) {} else return false;
		}
		return true;
	}

	public static function field(s:String):String return if (!validJsIdent(s)) "[\"" + s + "\"]" else "." + s;

	public static function ident(s:String):String return if (kwds.exists(s)) "$" + s else s;

	public static function checkVarDeclaration(v:TVar):Void if (kwds2.exists(v.vName)) v.vName = "$" + v.vName;

	public static function anonField(s:String):String return if (kwds.exists(s) || !validJsIdent(s)) "'" + s + "'" else s;

	public static function staticField(ctx:JsCtx, c:TClass, f:TClassField):String {
		var s = f.cfName;
		return switch s {
			case "length" | "name" if (!hasClassFlag(c, CExtern) || Meta.has(Meta.HxGen, c.clMeta)):
				switch f.cfKind {
					case Method(_) if (ctx.esVersion >= 6):
						"." + s;
					case _:
						".$" + s;
				}
			case s:
				field(s);
		}
	}

	public static function moduleField(m:ModuleDef, f:TClassField):String {
		try {
			return core.Native.getNativeName(f.cfMeta).name;
		} catch (_:NotFound) {
			return core.Path.flatPath(m.mPath) + "_" + f.cfName;
		}
	}

	public static function moduleFieldExposePath(mpath:GlobalTypePath, f:TClassField):String {
		try {
			return core.Native.getNativeName(f.cfMeta).name;
		} catch (_:NotFound) {
			return (dotPath(mpath)) + "." + f.cfName;
		}
	}

	static inline function hasFeature(ctx:JsCtx, f:String):Bool return Gctx.hasFeature(ctx.com, f);

	static inline function addFeature(ctx:JsCtx, f:String):Void Gctx.addFeature(ctx.com, f);

	static function unsupported(p:Pos):Dynamic return Error.abort("This expression cannot be compiled to Javascript", p);

	public static function flush(ctx:JsCtx):Void {
		var chan = switch ctx.chan {
			case null:
				var chan = sys.io.File.write(ctx.com.file, true);
				ctx.chan = chan;
				chan;
			case chan: chan;
		}
		chan.writeString(ctx.buf.contents());
		ctx.buf.clear();
	}

	public static function spr(ctx:JsCtx, s:String):Void {
		ctx.separator = false;
		JsSourcemap.handleNewlines(ctx.smap, s);
		ctx.buf.addString(s);
	}

	// port: Printf.kprintf; callers format the string themselves.
	public static function print(ctx:JsCtx, s:String):Void {
		ctx.separator = false;
		JsSourcemap.handleNewlines(ctx.smap, s);
		ctx.buf.addString(s);
	}

	public static function newline(ctx:JsCtx):Void {
		switch ctx.buf.lastChar() {
			case "}".code | "{".code | ":".code | ";".code if (!ctx.separator):
				print(ctx, "\n" + ctx.tabs);
			case _:
				print(ctx, ";\n" + ctx.tabs);
		}
	}

	public static function newprop(ctx:JsCtx):Void {
		switch ctx.buf.lastChar() {
			case "{".code:
				print(ctx, "\n" + ctx.tabs);
			case _:
				print(ctx, "\n" + ctx.tabs + ",");
		}
	}

	public static function semicolon(ctx:JsCtx):Void {
		switch ctx.buf.lastChar() {
			case "}".code if (!ctx.separator):
			case _:
				spr(ctx, ";");
		}
	}

	extern overload public static inline function concat<A>(ctx:JsCtx, s:String, f:A->Void, l:Array<A>):Void {
		for (i in 0...l.length) {
			if (i > 0) spr(ctx, s);
			f(l[i]);
		}
	}

	extern overload public static inline function concat<A>(ctx:JsCtx, s:String, f:A->Void, l:Vector<A>):Void {
		for (i in 0...l.length) {
			if (i > 0) spr(ctx, s);
			f(l[i]);
		}
	}

	/**
		Produce expressions to declare arguments of a function with `Rest<T>` trailing argument.
		Used for ES5 and older standards, which don't support "rest parameters" syntax.
		`args` is a list of explicitly defined arguments.
		`rest_arg` is the argument of `Rest<T>` type.

		This implementation copies rest arguments into a new array in a loop.
		It's the only way to avoid disabling javascript VM optimizations of functions
		with rest arguments.
	**/
	public static function declareRestArgsLegacy(com:Gctx, offset:Int, restArg:TVar):Vector<TExpr> {
		var i = Std.string(offset);
		var newArray = mk(TIdent("new Array($l>" + i + "?$l-" + i + ":0)"), tDynamic, restArg.vPos);
		var populate = mk(TIdent("for(var $i=" + i + ";$i<$l;++$i){" + (ident(restArg.vName)) + "[$i-" + i + "]=arguments[$i];}"),
			com.basic.tvoid, restArg.vPos);
		return vector(
			mk(TIdent("var $l=arguments.length"), com.basic.tvoid, restArg.vPos),
			mk(TVar(restArg, newArray), com.basic.tvoid, restArg.vPos),
			populate
		);
	}

	public static function funBlock(ctx:JsCtx, f:TFunc, p:Pos):TExpr {
		var e = f.tfExpr;
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

	public static function openBlock(ctx:JsCtx):Void->Void {
		var oldt = ctx.tabs;
		ctx.tabs = "\t" + ctx.tabs;
		return function() ctx.tabs = oldt;
	}

	public static function needsSwitchBreak(e:TExpr):Bool {
		return switch e.eexpr {
			case TBlock([]): true;
			case TBlock(el): needsSwitchBreak(el[el.length - 1]);
			case TMeta(m, {eexpr: TBreak}) if ((m.meta : core.MetaList.StrictMeta) == LoopLabel): false;
			case TContinue | TReturn(_) | TThrow(_): false;
			case _: true;
		}
	}

	public static function this_(ctx:JsCtx):String return switch ctx.inValue {
		case null: "this";
		case _: "$this";
	}

	public static function isIteratorFieldAccess(fa:TFieldAccess):Bool return switch fieldName(fa) {
		case "iterator" | "keyValueIterator": true;
		case _: false;
	}

	public static function isDynamicIterator(ctx:JsCtx, e:TExpr):Bool {
		function check(x:TExpr):Bool {
			function loop(t:T):Bool {
				return switch follow(t) {
					case TInst({clPath: {pack: [], name: "Array"}}, _) | TInst({clKind: KTypeParameter(_)}, _) | TAnon(_) | TDynamic(_) | TMono(_):
						true;
					case TAbstract(a, tl) if (!Meta.has(Meta.CoreType, a.aMeta)):
						loop(core.Abstract.getUnderlyingType(a, tl));
					case _: false;
				}
			}
			return hasFeature(ctx, "haxe.iterators.ArrayIterator.*") && loop(x.etype);
		}
		return switch e.eexpr {
			case TField(x, f) if (isIteratorFieldAccess(f)): check(x);
			case _: false;
		}
	}

	public static function genConstant(ctx:JsCtx, p:Pos, c:TConstant):Void {
		switch c {
			case TInt(i):
				print(ctx, Std.string(i));
			case TFloat(s):
				spr(ctx, s);
			case TString(s):
				print(ctx, "\"" + core.StringHelper.sEscape(s) + "\"");
			case TBool(b):
				spr(ctx, if (b) "true" else "false");
			case TNull:
				spr(ctx, "null");
			case TThis:
				spr(ctx, this_(ctx));
			case TSuper:
				if (!(ctx.esVersion >= 6)) throw new core.ds.Failure("assert");
				spr(ctx, "super");
		}
	}

	public static function isCodeInjectionFunction(e:TExpr):Bool {
		return switch e.eexpr {
			case TIdent("__js__"): true;
			case TField(_, FStatic({clPath: {pack: ["js"], name: "Syntax"}}, {cfName: "code" | "plainCode"})): true;
			case _: false;
		}
	}

	public static function var_(ctx:JsCtx):String return if (ctx.esVersion >= 6) "let" else "var";

	/**
		Returns `(needs_apply,element_list)` tuple where `needs_apply` indicates if
		a call should be generated as `<function>.apply(<this>, element_list)` instead
		of `<function>(el)`.

		If `add_null_context` is provided then `element_list` will have `null` as the
		first expr if needed.
	**/
	public static function applyArgs(addNullContext:Bool = false, ctx:JsCtx, el:Vector<TExpr>):{apply:Bool, el:Vector<TExpr>} {
		if (ctx.esVersion < 6) {
			var n = el.length;
			if (n == 1 && !addNullContext) switch el[0].eexpr {
				case TUnop(Spread, Prefix, rest):
					return {apply: true, el: vector(rest)};
				case _:
			}
			if (n > 0) switch el[n - 1].eexpr {
				case TUnop(Spread, Prefix, rest):
					/* [arg1, arg2, ..., argN].concat(rest) */
					var args = if (addNullContext) VectorTools.cons(Builder.makeNull(tDynamic, nullPos), el.slice(0, n - 1)) else el.slice(0, n - 1);
					var arr = mk(TArrayDecl(args), tDynamic, nullPos);
					var concat = mk(TField(arr, FDynamic("concat")), tDynamic, nullPos);
					return {apply: true, el: vector(mk(TCall(concat, vector(rest)), tDynamic, nullPos))};
				case _:
			}
			return {apply: false, el: el};
		} else return {apply: false, el: el};
	}

	public static function genCall(ctx:JsCtx, e:TExpr, el:Vector<TExpr>, inValue:Bool):Void {
		var r = applyArgs(ctx, el);
		var apply = r.apply, el = r.el;
		switch [e.eexpr, el] {
			case [TConst(TSuper), params] if (ctx.esVersion < 6):
				switch ctx.current.clSuper {
					case null:
						Error.abort("Missing api.setCurrentClass", e.epos);
					case {cls: c}:
						var call = if (apply) "apply" else "call";
						print(ctx, ctx.typeAccessor(TClassDecl(c)) + "." + call + "(" + this_(ctx));
						for (p in params) {
							print(ctx, ",");
							genValue(ctx, p);
						}
						spr(ctx, ")");
				}
			case [TField({eexpr: TConst(TSuper)}, f), params] if (ctx.esVersion < 6):
				switch ctx.current.clSuper {
					case null:
						Error.abort("Missing api.setCurrentClass", e.epos);
					case {cls: c}:
						var name = fieldName(f);
						var call = if (apply) "apply" else "call";
						print(ctx, ctx.typeAccessor(TClassDecl(c)) + ".prototype" + (field(name)) + "." + call + "(" + this_(ctx));
						for (p in params) {
							print(ctx, ",");
							genValue(ctx, p);
						}
						spr(ctx, ")");
				}
			case [TCall(x, _), el] if (!isCodeInjectionFunction(x)):
				if (apply) genCallWithApply(ctx, e, el) else {
					spr(ctx, "(");
					genValue(ctx, e);
					spr(ctx, ")");
					spr(ctx, "(");
					concat(ctx, ",", genValue.bind(ctx), el);
					spr(ctx, ")");
				}
			case [TField(_, FStatic({clPath: {pack: ["js"], name: "Syntax"}}, {cfName: meth})), args]:
				genSyntax(ctx, meth, args, e.epos);
			case [TField(_, FStatic({clPath: {pack: ["js"], name: "Lib"}}, {cfName: "rethrow"})), []]:
				if (ctx.catchVars.length > 0) {
					spr(ctx, "throw ");
					genValue(ctx, ctx.catchVars[0]);
				} else Error.abort("js.Lib.rethrow can only be called inside a catch block", e.epos);
			case [TField(_, FStatic({clPath: {pack: ["js"], name: "Lib"}}, {cfName: "getOriginalException"})), []]:
				if (ctx.catchVars.length > 0) {
					genValue(ctx, ctx.catchVars[0]);
				} else Error.abort("js.Lib.getOriginalException can only be called inside a catch block", e.epos);
			case [TIdent("__define_feature__"), [_, e]]:
				genExpr(ctx, e);
			case [TIdent("__feature__"), el] if (el.length >= 2 && el[0].eexpr.match(TConst(TString(_)))):
				var f = switch el[0].eexpr {
					case TConst(TString(f)): f;
					case _: throw "assert";
				};
				var eif = el[1], eelse = el.slice(2);
				if (hasFeature(ctx, f)) genValue(ctx, eif) else switch eelse {
					case []:
					case _: genValue(ctx, eelse[0]);
				}
			case [TIdent("__resources__"), []]:
				spr(ctx, "[");
				concat(ctx, ",", function(r:{name:String, data:haxe.io.Bytes}) {
					spr(ctx, "{ ");
					spr(ctx, "name : ");
					genConstant(ctx, e.epos, TString(r.name));
					spr(ctx, ", data : ");
					genConstant(ctx, e.epos, TString(codegen.Codegen.bytesSerialize(r.data)));
					spr(ctx, "}");
				}, resourcesFold(ctx.com));
				spr(ctx, "]");
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
					if (t == null) die("", "genjs.ml");
					spr(ctx, ctx.typeAccessor(t));
					spr(ctx, ".trace(");
					genValue(ctx, e);
					spr(ctx, ",");
					genValue(ctx, infos);
					spr(ctx, ")");
				} else {
					spr(ctx, "console.log(");
					switch infos.eexpr {
						case TObjectDecl(fields) if (fields.length >= 2
							&& fields[0].key.name == "fileName"
							&& fields[0].expr.eexpr.match(TConst(TString(_)))
							&& fields[1].key.name == "lineNumber"
							&& fields[1].expr.eexpr.match(TConst(TInt(_)))):
							var file = switch fields[0].expr.eexpr {
								case TConst(TString(s)): s;
								case _: throw "assert";
							}
							var line = switch fields[1].expr.eexpr {
								case TConst(TInt(i)): i;
								case _: throw "assert";
							}
							print(ctx, "\"" + file + ":" + line + ":\",");
						case _:
					}
					genValue(ctx, e);
					spr(ctx, ")");
				}
			case [TField(x, f), []] if (fieldName(f) == "iterator" && isDynamicIterator(ctx, e)):
				addFeature(ctx, "use.$getIterator");
				print(ctx, "$getIterator(");
				genValue(ctx, x);
				print(ctx, ")");
			case [TField(x, f), []] if (fieldName(f) == "keyValueIterator" && isDynamicIterator(ctx, e)):
				addFeature(ctx, "use.$getKeyValueIterator");
				print(ctx, "$getKeyValueIterator(");
				genValue(ctx, x);
				print(ctx, ")");
			case _:
				if (apply) genCallWithApply(ctx, e, el) else {
					genValue(ctx, e);
					spr(ctx, "(");
					concat(ctx, ",", genValue.bind(ctx), el);
					spr(ctx, ")");
				}
		}
	}

	// port: `Hashtbl.fold (fun name data acc -> (name,data) :: acc) ctx.com.resources []`.
	static function resourcesFold(com:Gctx):Array<{name:String, data:haxe.io.Bytes}> {
		return com.resources.fold(function(name, data, acc:Array<{name:String, data:haxe.io.Bytes}>) {
			return [{name: name, data: data}].concat(acc);
		}, []);
	}

	public static function genCallWithApply(ctx:JsCtx, target:TExpr, args:Vector<TExpr>):Void {
		if (args.length != 1) die("`args` for `gen_call_with_apply` must contain exactly one item", "genjs.ml", target.epos);
		switch target.eexpr {
			case TField(this_, FInstance(_, _, {cfName: field}) | FAnon({cfName: field}) | FDynamic(field) | FClosure(_, {cfName: field})):
				addFeature(ctx, "thisForCallWithRestArgs");
				spr(ctx, "($_=");
				genValue(ctx, this_);
				spr(ctx, (",$_." + field + ".apply($_,"));
				concat(ctx, ",", genValue.bind(ctx), args);
				spr(ctx, "))");
			case _:
				genValue(ctx, target);
				spr(ctx, ".apply(null,");
				concat(ctx, ",", genValue.bind(ctx), args);
				spr(ctx, ")");
		}
	}

	/*
		this wraps {} in parenthesis which is required to produce valid js code for field and array access to it.
		the case itself is very rare and most probably comes from redundant code fused by the analyzer,
		but we still have to support it.
	 */
	public static function addObjectdeclParens(e:TExpr):TExpr {
		function loop(e:TExpr):TExpr {
			return switch e.eexpr {
				case TCast(e1, null) | TMeta(_, e1): loop(e1); /* TODO: do we really want to lose these? */
				case TObjectDecl(_): {eexpr: TParenthesis(e), etype: e.etype, epos: e.epos};
				case _: e;
			}
		}
		return loop(e);
	}

	public static function genExpr(ctx:JsCtx, e:TExpr):Void {
		var clearMapping = JsSourcemap.addMapping(ctx.smap, e);
		switch e.eexpr {
			case TConst(c):
				genConstant(ctx, e.epos, c);
			case TLocal(v):
				spr(ctx, ident(v.vName));
			/*| TArray (e1,{ eexpr = TConst (TString s) }) when valid_js_ident s && (match e1.eexpr with TConst (TInt _|TFloat _) -> false | _ -> true) ->
				gen_value ctx (add_objectdecl_parens e1);
				spr ctx (field s) */
			case TArray(e1, e2):
				genValue(ctx, addObjectdeclParens(e1));
				spr(ctx, "[");
				genValue(ctx, e2);
				spr(ctx, "]");
			case TBinop(op, {eexpr: TField(x, f)}, e2) if (isIteratorFieldAccess(f)):
				genValue(ctx, x);
				spr(ctx, field(fieldName(f)));
				print(ctx, " " + Ast.sBinop(op) + " ");
				genValue(ctx, e2);
			case TBinop(op = OpEq | OpNotEq, {eexpr: TField(x, f = FClosure(_))}, {eexpr: TConst(TNull)}):
				genValue(ctx, x);
				spr(ctx, field(fieldName(f)));
				print(ctx, " " + Ast.sBinop(op) + " null");
			case TBinop(op = OpEq | OpNotEq, {eexpr: TConst(TNull)}, {eexpr: TField(x, f = FClosure(_))}):
				print(ctx, "null " + Ast.sBinop(op) + " ");
				genValue(ctx, x);
				spr(ctx, field(fieldName(f)));
			case TBinop(op, e1, e2):
				genValue(ctx, e1);
				print(ctx, " " + Ast.sBinop(op) + " ");
				genValue(ctx, e2);
			case TField(x, f) if (fieldName(f) == "iterator" && isDynamicIterator(ctx, e)):
				addFeature(ctx, "use.$iterator");
				print(ctx, "$iterator(");
				genValue(ctx, x);
				print(ctx, ")");
			case TField(x, f) if (fieldName(f) == "keyValueIterator" && isDynamicIterator(ctx, e)):
				addFeature(ctx, "use.$keyValueIterator");
				print(ctx, "$keyValueIterator(");
				genValue(ctx, x);
				print(ctx, ")");
			/* Don't generate `$iterator(value)` for exprs like `value.iterator--` */
			case TUnop(op, flag, fe = {eexpr: TField(x, f)}) if (isIteratorFieldAccess(f) && isDynamicIterator(ctx, fe)):
				switch flag {
					case Prefix:
						spr(ctx, Ast.sUnop(op));
						genValue(ctx, x);
						print(ctx, "." + fieldName(f));
					case Postfix:
						genValue(ctx, x);
						print(ctx, "." + fieldName(f));
						spr(ctx, Ast.sUnop(op));
				}
			case TField(x, FClosure(cp, {cfName: "push"})) if (cp != null && cp.cls.clPath.pack.length == 0 && cp.cls.clPath.name == "Array"):
				/* see https://github.com/HaxeFoundation/haxe/issues/1997 */
				addFeature(ctx, "use.$arrayPush");
				addFeature(ctx, "use.$bind");
				print(ctx, "$bind(");
				genValue(ctx, x);
				print(ctx, ",$arrayPush)");
			case TField(x, FClosure(_, f)):
				addFeature(ctx, "use.$bind");
				switch x.eexpr {
					case TConst(_) | TLocal(_):
						print(ctx, "$bind(");
						genValue(ctx, x);
						print(ctx, ",");
						genValue(ctx, x);
						print(ctx, (if (Meta.has(Meta.SelfCall, f.cfMeta)) "" else (field(f.cfName))) + ")");
					case _:
						print(ctx, "($_=");
						genValue(ctx, x);
						print(ctx, ",$bind($_,$_" + (if (Meta.has(Meta.SelfCall, f.cfMeta)) "" else (field(f.cfName))) + "))");
				}
			case TEnumIndex(x):
				genValue(ctx, x);
				if (!Gctx.defined(ctx.com, Define.JsEnumsAsArrays)) print(ctx, "._hx_index") else print(ctx, "[1]");
			case TEnumParameter(x, f, i):
				genValue(ctx, x);
				if (!Gctx.defined(ctx.com, Define.JsEnumsAsArrays)) {
					var fname = switch f.efType {
						case TFun(sig): sig.args[i].name;
						case _: die("", "genjs.ml");
					};
					print(ctx, "." + ident(fname));
				} else print(ctx, "[" + (i + 2) + "]");
			case TField(_, FStatic({clPath: {pack: [], name: ""}}, f)):
				spr(ctx, f.cfName);
			case TField(x, FInstance(_, _, f) | FStatic(_, f) | FAnon(f)) if (Meta.has(Meta.SelfCall, f.cfMeta)):
				genValue(ctx, x);
			case TField(_, FStatic({clKind: KModuleFields(m)}, f)):
				spr(ctx, moduleField(m, f));
			case TField(x, f):
				function skip(e:TExpr):TExpr {
					return switch e.eexpr {
						case TCast(e1, null) | TMeta(_, e1): skip(e1);
						case TConst(TInt(_) | TFloat(_)) | TObjectDecl(_): {eexpr: TParenthesis(e), etype: e.etype, epos: e.epos};
						case _: e;
					}
				}
				var x = skip(x);
				genValue(ctx, x);
				spr(ctx, switch f {
					case FStatic(c, f): staticField(ctx, c, f);
					case FEnum(_) | FInstance(_) | FAnon(_) | FDynamic(_) | FClosure(_): field(fieldName(f));
				});
			case TTypeExpr(t):
				spr(ctx, ctx.typeAccessor(t));
			case TParenthesis(e):
				spr(ctx, "(");
				genValue(ctx, e);
				spr(ctx, ")");
			case TMeta(m = {exprs: [{expr: EConst(Int(n, _))}]}, e) if ((m.meta : core.MetaList.StrictMeta) == LoopLabel):
				switch e.eexpr {
					case TWhile(_):
						print(ctx, "_hx_loop" + n + ": ");
						genExpr(ctx, e);
					case TBreak:
						print(ctx, "break _hx_loop" + n);
					case _:
						die("", "genjs.ml");
				}
			case TMeta(_, e):
				genExpr(ctx, e);
			case TReturn(eo):
				if (ctx.inValue != null) unsupported(e.epos);
				switch eo {
					case null:
						spr(ctx, "return");
					case e:
						spr(ctx, "return ");
						genValue(ctx, e);
				}
			case TBreak:
				if (!ctx.inLoop) unsupported(e.epos);
				spr(ctx, "break");
			case TContinue:
				if (!ctx.inLoop) unsupported(e.epos);
				spr(ctx, "continue");
			case TBlock(el):
				print(ctx, "{");
				var bend = openBlock(ctx);
				for (e in el) genBlockElement(ctx, e);
				bend();
				newline(ctx);
				print(ctx, "}");
			case TFunction(f):
				genFunction(ctx, f, e.epos);
			case TCall(e, el):
				genCall(ctx, e, el, false);
			case TArrayDecl(el):
				spr(ctx, "[");
				concat(ctx, ",", genValue.bind(ctx), el);
				spr(ctx, "]");
			case TThrow(e):
				spr(ctx, "throw ");
				genValue(ctx, e);
			case TVar(v, eo):
				spr(ctx, (var_(ctx)) + " ");
				checkVarDeclaration(v);
				spr(ctx, ident(v.vName));
				switch eo {
					case null:
					case e:
						spr(ctx, " = ");
						genValue(ctx, e);
				}
			case TNew({clPath: {pack: [], name: "Array"}}, _, []):
				print(ctx, "[]");
			case TNew(c, _, el):
				var r = applyArgs(true, ctx, el);
				var apply = r.apply, el = r.el;
				switch c.clConstructor {
					case cf if (cf != null && Meta.has(Meta.SelfCall, cf.cfMeta)):
					case _:
						print(ctx, if (apply) "(new" else "new ");
				}
				var cls = ctx.typeAccessor(TClassDecl(c));
				if (apply) {
					print(ctx, "(Function.prototype.bind.apply(" + cls + ",");
					concat(ctx, ",", genValue.bind(ctx), el);
					print(ctx, ")))");
				} else {
					print(ctx, cls + "(");
					concat(ctx, ",", genValue.bind(ctx), el);
					spr(ctx, ")");
				}
			case TIf(cond, e, eelse):
				spr(ctx, "if");
				genValue(ctx, cond);
				spr(ctx, " ");
				genExpr(ctx, mkBlock(e));
				switch eelse {
					case null:
					case e2:
						switch e.eexpr {
							case TObjectDecl(_):
								ctx.separator = false;
							case _:
						}
						semicolon(ctx);
						spr(ctx, " else ");
						genExpr(ctx, switch e2.eexpr {
							case TIf(_): e2;
							case _: mkBlock(e2);
						});
				}
			case TUnop(op, Prefix, e):
				spr(ctx, Ast.sUnop(op));
				genValue(ctx, e);
			case TUnop(op, Postfix, e):
				genValue(ctx, e);
				spr(ctx, Ast.sUnop(op));
			case TWhile(cond, e, NormalWhile):
				var oldInLoop = ctx.inLoop;
				ctx.inLoop = true;
				spr(ctx, "while");
				genValue(ctx, cond);
				spr(ctx, " ");
				genExpr(ctx, e);
				ctx.inLoop = oldInLoop;
			case TWhile(cond, e, DoWhile):
				var oldInLoop = ctx.inLoop;
				ctx.inLoop = true;
				spr(ctx, "do ");
				genExpr(ctx, e);
				semicolon(ctx);
				spr(ctx, " while");
				genValue(ctx, cond);
				ctx.inLoop = oldInLoop;
			case TObjectDecl(fields):
				spr(ctx, "{ ");
				concat(ctx, ", ", function(fe:{key:{name:String, pos:Pos, quote:QuoteStatus}, expr:TExpr}) {
					switch fe.key.quote {
						case DoubleQuotes:
							print(ctx, "\"" + core.StringHelper.sEscape(fe.key.name) + "\" : ");
						case NoQuotes:
							print(ctx, anonField(fe.key.name) + " : ");
					}
					genValue(ctx, fe.expr);
				}, fields);
				spr(ctx, "}");
				ctx.separator = true;
			case TTry(etry, [{variable: v, expr: ecatch}]):
				spr(ctx, "try ");
				genExpr(ctx, etry);
				checkVarDeclaration(v);
				print(ctx, " catch( " + v.vName + " ) ");
				ctx.catchVars.unshift(mk(TLocal(v), v.vType, v.vPos));
				genExpr(ctx, ecatch);
				ctx.catchVars.shift();
			case TTry(_):
				Error.abort("Unhandled try/catch, please report", e.epos);
			case TSwitch({switchSubject: e, switchCases: cases, switchDefault: def}):
				spr(ctx, "switch");
				genValue(ctx, e);
				spr(ctx, " {");
				newline(ctx);
				for (c in cases) {
					var el = c.casePatterns, e2 = c.caseExpr;
					for (e in el) {
						switch e.eexpr {
							case TConst(TNull):
								spr(ctx, "case null: case undefined:");
							case _:
								spr(ctx, "case ");
								genValue(ctx, e);
								spr(ctx, ":");
						}
					}
					var bend = openBlock(ctx);
					genBlockElement(ctx, e2);
					if (needsSwitchBreak(e2)) {
						newline(ctx);
						print(ctx, "break");
					}
					bend();
					newline(ctx);
				}
				switch def {
					case null:
					case e:
						spr(ctx, "default:");
						var bend = openBlock(ctx);
						genBlockElement(ctx, e);
						bend();
						newline(ctx);
				}
				spr(ctx, "}");
			case TCast(e, null):
				genExpr(ctx, e);
			case TCast(e1, t):
				print(ctx, ctx.typeAccessor(TClassDecl(jsBootClass())) + ".__cast(");
				genValue(ctx, e1);
				spr(ctx, " , ");
				spr(ctx, ctx.typeAccessor(t));
				spr(ctx, ")");
			case TIdent(s):
				spr(ctx, s);
		}
		clearMapping();
	}

	// port: `{ null_class with cl_path = ["js"],"Boot" }`.
	static function jsBootClass():TClass {
		var c = nullClass.clone();
		c.clPath = {pack: ["js"], name: "Boot"};
		return c;
	}

	public static function genFunction(keyword:String = "function", ctx:JsCtx, f:TFunc, pos:Pos):Void {
		var oldInValue = ctx.inValue, oldInLoop = ctx.inLoop;
		ctx.inValue = null;
		ctx.inLoop = false;
		function mkNonRestArgNames(args:haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}>):Array<String> {
			return [
				for (a in args) {
					checkVarDeclaration(a.variable);
					ident(a.variable.vName);
				}
			];
		}
		var n = f.tfArgs.length;
		var last = n > 0 ? f.tfArgs[n - 1] : null;
		var f2:TFunc, args:Array<String>;
		if (last != null && last.defaultValue == null && ExtType.isRest(follow(last.variable.vType))) {
			var v = last.variable;
			/* Use ES6 rest args syntax: `...arg` */
			if (ctx.esVersion >= 6) {
				f2 = f;
				args = [
					for (a in f.tfArgs) {
						checkVarDeclaration(a.variable);
						if (a.variable == v) ("..." + ident(a.variable.vName)) else ident(a.variable.vName);
					}
				];
			}
			/* Resort to `arguments` special object for ES < 6 */
			else {
				checkVarDeclaration(v);
				var nonRestArgs = f.tfArgs.slice(0, n - 1);
				var argsDecl = declareRestArgsLegacy(ctx.com, nonRestArgs.length, v);
				var body = {
					var el = switch f.tfExpr.eexpr {
						case TBlock(el): argsDecl.concat(el);
						case _: argsDecl.snoc(f.tfExpr);
					}
					mk(TBlock(el), f.tfExpr.etype, f.tfExpr.epos);
				}
				f2 = {tfArgs: nonRestArgs, tfType: f.tfType, tfExpr: body};
				args = mkNonRestArgNames(nonRestArgs);
			}
		} else {
			f2 = f;
			args = mkNonRestArgNames(f.tfArgs);
		}
		print(ctx, keyword + "(" + args.join(",") + ") ");
		genExpr(ctx, funBlock(ctx, f2, pos));
		ctx.inValue = oldInValue;
		ctx.inLoop = oldInLoop;
		ctx.separator = true;
	}

	public static function genBlockElement(newlineAfter:Bool = false, keepBlocks:Bool = false, ctx:JsCtx, e:TExpr):Void {
		switch e.eexpr {
			case TBlock(el) if (!keepBlocks):
				for (e in el) genBlockElement(newlineAfter, ctx, e);
			case TCall({eexpr: TIdent("__feature__")}, el) if (el.length >= 2 && el[0].eexpr.match(TConst(TString(_)))):
				var f = switch el[0].eexpr {
					case TConst(TString(f)): f;
					case _: throw "assert";
				};
				var eif = el[1], eelse = el.slice(2);
				if (hasFeature(ctx, f)) genBlockElement(newlineAfter, ctx, eif) else switch eelse {
					case []:
					case [e]: genBlockElement(newlineAfter, ctx, e);
					case _: die("", "genjs.ml");
				}
			case TFunction(_):
				genBlockElement(newlineAfter, ctx, mk(TParenthesis(e), e.etype, e.epos));
			case TObjectDecl(fl):
				for (f in fl) genBlockElement(newlineAfter, ctx, f.expr);
			case _:
				if (!newlineAfter) newline(ctx);
				genExpr(ctx, e);
				if (newlineAfter) newline(ctx);
		}
	}

	public static function genValue(ctx:JsCtx, e:TExpr):Void {
		var clearMapping = JsSourcemap.addMapping(ctx.smap, e);
		function assign(e:TExpr):TExpr {
			return mk(TBinop(OpAssign, mk(TLocal(switch ctx.inValue {
				case null: die("", "genjs.ml");
				case v: v;
			}), tDynamic, e.epos), e), e.etype, e.epos);
		}
		function value():Void->Void {
			var oldInValue = ctx.inValue, oldInLoop = ctx.inLoop;
			var r = allocVar(VGenerated, "$r", tDynamic, e.epos);
			ctx.inValue = r;
			ctx.inLoop = false;
			spr(ctx, "(function($this) ");
			spr(ctx, "{");
			var b = openBlock(ctx);
			newline(ctx);
			spr(ctx, "var $r");
			newline(ctx);
			return function() {
				newline(ctx);
				spr(ctx, "return $r");
				b();
				newline(ctx);
				spr(ctx, "}");
				ctx.inValue = oldInValue;
				ctx.inLoop = oldInLoop;
				print(ctx, "(" + this_(ctx) + "))");
			}
		}
		switch e.eexpr {
			case TConst(_) | TLocal(_) | TArray(_) | TBinop(_) | TField(_) | TEnumParameter(_) | TEnumIndex(_) | TTypeExpr(_) | TParenthesis(_) |
				TObjectDecl(_) | TArrayDecl(_) | TNew(_) | TUnop(_) | TFunction(_) | TIdent(_):
				genExpr(ctx, e);
			case TMeta(_, e1):
				genValue(ctx, e1);
			case TCall(e, el):
				genCall(ctx, e, el, true);
			case TReturn(_) | TBreak | TContinue:
				unsupported(e.epos);
			case TCast(e1, null):
				genValue(ctx, e1);
			case TCast(e1, t):
				print(ctx, ctx.typeAccessor(TClassDecl(jsBootClass())) + ".__cast(");
				genValue(ctx, e1);
				spr(ctx, " , ");
				spr(ctx, ctx.typeAccessor(t));
				spr(ctx, ")");
			case TVar(_) | TWhile(_) | TThrow(_):
				/* value is discarded anyway */
				var v = value();
				genExpr(ctx, e);
				v();
			case TBlock([e]):
				genValue(ctx, e);
			case TBlock(el):
				var v = value();
				function loop(i:Int):Void {
					if (i >= el.length) spr(ctx, "return null");
					else if (i == el.length - 1) genExpr(ctx, assign(el[i]));
					else {
						genExpr(ctx, el[i]);
						newline(ctx);
						loop(i + 1);
					}
				}
				loop(0);
				v();
			case TIf(cond, e, eo):
				/* remove parenthesis unless it's an operation with higher precedence than ?: */
				var cond = switch cond.eexpr {
					case TParenthesis({eexpr: TBinop(OpAssign | OpAssignOp(_), _, _) | TIf(_)}): cond;
					case TParenthesis(e): e;
					case _: cond;
				}
				genValue(ctx, cond);
				spr(ctx, " ? ");
				genValue(ctx, e);
				spr(ctx, " : ");
				switch eo {
					case null: spr(ctx, "null");
					case e: genValue(ctx, e);
				}
			case TSwitch(sw):
				var v = value();
				var sw2:TSwitch = {
					switchSubject: sw.switchSubject,
					switchCases: sw.switchCases.map(c -> ({casePatterns: c.casePatterns, caseExpr: assign(c.caseExpr)} : TSwitchCase)),
					switchDefault: sw.switchDefault == null ? null : assign(sw.switchDefault),
					switchExhaustive: sw.switchExhaustive
				};
				genExpr(ctx, mk(TSwitch(sw2), e.etype, e.epos));
				v();
			case TTry(b, catchs):
				var v = value();
				function block(e:TExpr):TExpr return mk(TBlock(vector(e)), e.etype, e.epos);
				genExpr(ctx, mk(TTry(block(assign(b)), catchs.map(c -> {variable: c.variable, expr: block(assign(c.expr))})), e.etype, e.epos));
				v();
		}
		clearMapping();
	}

	public static function genSyntax(ctx:JsCtx, meth:String, args:Vector<TExpr>, pos:Pos):Void {
		switch [meth, args] {
			case ["construct", _] if (args.length >= 1):
				var cl = args[0], params = args.slice(1);
				spr(ctx, "new ");
				switch cl.eexpr {
					case TConst(TString(cl)):
						spr(ctx, cl);
					case _:
						genValue(ctx, cl);
				}
				spr(ctx, "(");
				concat(ctx, ",", genValue.bind(ctx), params);
				spr(ctx, ")");
			case ["instanceof", [o, t]]:
				spr(ctx, "((");
				genValue(ctx, o);
				print(ctx, ") instanceof ");
				genValue(ctx, t);
				spr(ctx, ")");
			case ["typeof", [o]]:
				spr(ctx, "typeof(");
				genValue(ctx, o);
				spr(ctx, ")");
			case ["strictEq", [x, y]]:
				/* add extra parenthesis here because of operator precedence */
				spr(ctx, "((");
				genValue(ctx, x);
				spr(ctx, ") === ");
				genValue(ctx, y);
				spr(ctx, ")");
			case ["strictNeq", [x, y]]:
				/* add extra parenthesis here because of operator precedence */
				spr(ctx, "((");
				genValue(ctx, x);
				spr(ctx, ") !== ");
				genValue(ctx, y);
				spr(ctx, ")");
			case ["delete", [o, f]]:
				spr(ctx, "delete(");
				genValue(ctx, o);
				spr(ctx, "[");
				genValue(ctx, f);
				spr(ctx, "]");
				spr(ctx, ")");
			case ["code", _] if (args.length >= 1):
				var code = args[0], args = args.slice(1);
				var codeStr, codePos;
				switch code.eexpr {
					case TConst(TString(s)):
						codeStr = s;
						codePos = code.epos;
					case _:
						Error.abort("The `code` argument for js.Syntax.code must be a string constant", code.epos);
						throw "unreachable";
				}
				switch args {
					case [] if (codeStr == "this"):
						spr(ctx, this_(ctx));
					case _:
						function revealExpr(expr:TExpr):TExpr {
							return switch expr.eexpr {
								case TCast(e, _) | TMeta(_, e): revealExpr(e);
								case _: expr;
							}
						}
						var args:Array<TExpr> = [
							for (arg in args)
								switch (revealExpr(arg)).eexpr {
									case TIf(_) | TBinop(_) | TUnop(_): ({eexpr: TParenthesis(arg), etype: arg.etype, epos: arg.epos} : TExpr);
									case _: arg;
								}
						];
						codegen.Codegen.interpolateCode(ctx.com.error, codeStr, args, spr.bind(ctx), genValue.bind(ctx), codePos);
				}
			case ["plainCode", [code]]:
				var code = switch code.eexpr {
					case TConst(TString(s)): s;
					case _:
						Error.abort("The `code` argument for js.Syntax.plainCode must be a string constant", code.epos);
						throw "unreachable";
				}
				spr(ctx, code.split("\r\n").join("\n"));
			case ["field", [eobj, efield]]:
				genValue(ctx, eobj);
				switch Texpr.skip(efield) {
					case {eexpr: TConst(TString(s))} if (validJsIdent(s)):
						spr(ctx, ".");
						spr(ctx, s);
					case _:
						spr(ctx, "[");
						genValue(ctx, efield);
						spr(ctx, "]");
				}
			case _:
				Error.abort('Unknown js.Syntax method `$meth` with ${args.length} arguments', pos);
		}
	}

	public static function generatePackageCreate(ctx:JsCtx, path:GlobalTypePath):Void {
		var p = path.pack;
		// port: `acc` is the reversed package prefix, as in upstream; the Hashtbl key is its join.
		function loop(acc:Array<String>, l:Array<String>, i:Int):Void {
			if (i >= l.length) return;
			var p = l[i];
			var key = [p].concat(acc);
			var keyS = key.join(".");
			if (ctx.packages.exists(keyS)) loop(key, l, i + 1) else {
				ctx.packages.set(keyS, true);
				switch acc {
					case []:
						if (ctx.jsModern) print(ctx, "var " + p + " = {}") else print(ctx, "var " + p + " = " + p + " || {}");
					case _:
						var racc = acc.copy();
						racc.reverse();
						var p = racc.join(".") + (field(p));
						if (ctx.jsModern) print(ctx, p + " = {}") else print(ctx, "if(!" + p + ") " + p + " = {}");
				}
				ctx.separator = true;
				newline(ctx);
				loop(key, l, i + 1);
			}
		}
		switch p {
			case []: print(ctx, "var ");
			case _: loop([], p, 0);
		}
	}

	public static function checkFieldName(c:TClass, f:TClassField):Void {
		switch f.cfName {
			case "prototype" | "__proto__" | "constructor":
				Error.abort("The field name '" + f.cfName + "'  is not allowed in JS", switch f.cfExpr {
					case null: c.clPos;
					case e: e.epos;
				});
			case _:
		}
	}

	/* convert a.b.c to ["a"]["b"]["c"] */
	public static function pathToBrackets(path:String):String {
		var parts = path.split(".");
		return "[\"" + (parts.join("\"][\"")) + "\"]";
	}

	public static function genModuleFields(ctx:JsCtx, m:ModuleDef, c:TClass, fl:Array<TClassField>):Void {
		for (f in fl) {
			var name = moduleField(m, f);
			switch f.cfExpr {
				case null if (!isPhysicalField(f)):
				case null:
					print(ctx, "var " + name + " = null");
					newline(ctx);
				case e:
					switch e.eexpr {
						case TFunction(fn):
							ctx.idCounter = 0;
							print(ctx, "function " + name);
							genFunction("", ctx, fn, e.epos);
							ctx.separator = false;
							newline(ctx);
							processExpose(f.cfMeta, () -> moduleFieldExposePath(m.mPath, f), function(s) {
								print(ctx, "$hx_exports" + pathToBrackets(s) + " = " + name);
								newline(ctx);
							});
						case _:
							ctx.statics.unshift({c: c, f: f, e: e});
					}
			}
		}
	}

	public static function genClassStaticField(ctx:JsCtx, c:TClass, clPath:GlobalTypePath, f:TClassField):Void {
		switch f.cfExpr {
			case null | {eexpr: TConst(TNull)} if (!hasFeature(ctx, "Type.getClassFields")):
			case null if (!isPhysicalField(f)):
			case null:
				print(ctx, sPath(ctx, clPath) + staticField(ctx, c, f) + " = null");
				newline(ctx);
			case e:
				switch e.eexpr {
					case TFunction(_):
						var path = (sPath(ctx, clPath)) + (staticField(ctx, c, f));
						ctx.idCounter = 0;
						print(ctx, path + " = ");
						processExpose(f.cfMeta, () -> (dotPath(clPath)) + "." + f.cfName, s -> print(ctx, "$hx_exports" + pathToBrackets(s) + " = "));
						genValue(ctx, e);
						newline(ctx);
					case _:
						ctx.statics.unshift({c: c, f: f, e: e});
				}
		}
	}

	public static function canGenClassField(ctx:JsCtx, f:TClassField):Bool {
		return switch f {
			case {cfExpr: null | {eexpr: TConst(TNull)}} if (!hasFeature(ctx, "Type.getInstanceFields")):
				false;
			case f if (hasClassFieldFlag(f, CfExtern)):
				false;
			case f:
				isPhysicalField(f);
		}
	}

	public static function genClassField(ctx:JsCtx, c:TClass, f:TClassField):Void {
		checkFieldName(c, f);
		switch f.cfExpr {
			case null:
				newprop(ctx);
				print(ctx, anonField(f.cfName) + ": ");
				print(ctx, "null");
			case e:
				newprop(ctx);
				print(ctx, anonField(f.cfName) + ": ");
				ctx.idCounter = 0;
				genValue(ctx, e);
				ctx.separator = false;
		}
	}

	public static function generateClass__name__(ctx:JsCtx, clPath:GlobalTypePath):Void {
		if (hasFeature(ctx, "js.Boot.isClass")) {
			var p = sPath(ctx, clPath);
			print(ctx, p + ".__name__ = ");
			print(ctx, "\"" + dotPath(clPath) + "\"");
			newline(ctx);
		}
	}

	public static function generateClass__isInterface__(ctx:JsCtx, c:TClass):Void {
		if ((hasClassFlag(c, CInterface)) && hasFeature(ctx, "js.Boot.isInterface")) {
			var p = sPath(ctx, c.clPath);
			print(ctx, p + ".__isInterface__ = true");
			newline(ctx);
		}
	}

	public static function getGeneratedClassPath(c:TClass):GlobalTypePath {
		return switch c {
			/* we want to generate abstract implementations with the path of the abstract itself, unless there is @:native involved */
			case {clKind: KAbstractImpl(a), clMeta: m} if (!Meta.has(Meta.Native, m)):
				a.aPath;
			case {clPath: p}:
				p;
		}
	}

	public static function isAbstractImpl(c:TClass):Bool return switch c.clKind {
		case KAbstractImpl(_): true;
		case _: false;
	}

	// port: the local `gen_props` of generate_class_es5 (sep ":") and generate_class_es6 (sep ": ").
	static function genProps(props:Array<{name:String, field:String}>, sep:String):String {
		return [for (p in props) p.name + sep + "\"" + p.field + "\""].join(",");
	}

	public static function generateClassEs5(ctx:JsCtx, c:TClass):Void {
		var clPath = getGeneratedClassPath(c);
		var isAbstractImpl = isAbstractImpl(c);

		if (ctx.jsFlatten) print(ctx, "var ") else generatePackageCreate(ctx, clPath);

		var p = sPath(ctx, clPath);
		var dotp = dotPath(clPath);
		var addedToHxClasses = ctx.hasResolveClass && !isAbstractImpl;

		/* Do not add to $hxClasses on same line as declaration to make sure not to trip js debugger */
		/* when it tries to get a string representation of a class. Will be added below */
		if (ctx.com.debug || ctx.jsModern || !addedToHxClasses) print(ctx, p + " = ") else print(ctx, p + " = $hxClasses[\"" + dotp + "\"] = ");

		if (!ctx.com.debug) processExpose(c.clMeta, () -> dotp, s -> print(ctx, "$hx_exports" + pathToBrackets(s) + " = "));

		if (isAbstractImpl) {
			/* abstract implementations only contain static members and don't need to have constructor functions */
			print(ctx, "{}");
			ctx.separator = true;
		} else {
			switch c.clConstructor {
				case cf if (cf != null && cf.cfExpr != null): genExpr(ctx, cf.cfExpr);
				case _:
					(print(ctx, "function() { }"));
					ctx.separator = true;
			}
		}

		newline(ctx);

		if ((ctx.jsModern || ctx.com.debug) && addedToHxClasses) {
			print(ctx, "$hxClasses[\"" + dotp + "\"] = " + p);
			newline(ctx);
		}

		if (ctx.com.debug) processExpose(c.clMeta, () -> dotp, function(s) {
			print(ctx, "$hx_exports" + pathToBrackets(s) + " = " + p);
			newline(ctx);
		});

		if (!isAbstractImpl) {
			generateClass__name__(ctx, clPath);
			generateClass__isInterface__(ctx, c);
		}

		if (ctx.hasInterfaceCheck) switch c.clImplements {
			case []:
			case l:
				print(ctx, p + ".__interfaces__ = [" + ([for (i in l) ctx.typeAccessor(TClassDecl(i.cls))].join(",")) + "]");
				newline(ctx);
		}

		var hasPropertyReflection = (hasFeature(ctx, "Reflect.getProperty")) || (hasFeature(ctx, "Reflect.setProperty"));

		if (hasPropertyReflection) {
			switch codegen.Codegen.getProperties(c.clOrderedStatics) {
				case []:
				case props:
					print(ctx, p + ".__properties__ = {" + genProps(props, ":") + "}");
					ctx.separator = true;
					newline(ctx);
			}
		}

		for (f in c.clOrderedStatics) genClassStaticField(ctx, c, clPath, f);

		var hasClass = hasFeature(ctx, "js.Boot.getClass")
			&& (c.clSuper != null || c.clOrderedFields.length > 0 || c.clConstructor != null);
		var hasPrototype = c.clSuper != null || hasClass || Lambda.exists(c.clOrderedFields, f -> canGenClassField(ctx, f));
		if (hasPrototype) {
			switch c.clSuper {
				case null:
					print(ctx, p + ".prototype = {");
				case {cls: csup}:
					var psup = ctx.typeAccessor(TClassDecl(csup));
					print(ctx, p + ".__super__ = " + psup);
					newline(ctx);
					print(ctx, p + ".prototype = $extend(" + psup + ".prototype,{");
			}

			var bend = openBlock(ctx);
			for (f in c.clOrderedFields) if (canGenClassField(ctx, f)) genClassField(ctx, c, f);
			if (hasClass) {
				newprop(ctx);
				print(ctx, "__class__: " + p);
			}

			if (hasPropertyReflection) {
				var props = codegen.Codegen.getProperties(c.clOrderedFields);
				switch c.clSuper {
					case _ if (props.length == 0):
					case sup if (sup != null && codegen.Codegen.hasProperties(sup.cls)):
						newprop(ctx);
						var psup = ctx.typeAccessor(TClassDecl(sup.cls));
						print(ctx, "__properties__: $extend(" + psup + ".prototype.__properties__,{" + genProps(props, ":") + "})");
					case _:
						newprop(ctx);
						print(ctx, "__properties__: {" + genProps(props, ":") + "}");
				}
			}

			bend();
			print(ctx, "\n}");
			switch c.clSuper {
				case null: ctx.separator = true;
				case _: print(ctx, ")");
			}
			newline(ctx);
		}
		flush(ctx);
	}

	public static function generateClassEs6(ctx:JsCtx, c:TClass):Void {
		var clPath = getGeneratedClassPath(c);
		var p = sPath(ctx, clPath);
		var dotp = dotPath(clPath);

		var clsName = if (!ctx.jsFlatten && clPath.pack.length > 0) {
			generatePackageCreate(ctx, clPath);
			print(ctx, p + " = ");
			core.Path.flatPath(clPath);
		} else p;
		print(ctx, "class " + clsName);

		if (c.clSuper != null) {
			var psup = ctx.typeAccessor(TClassDecl(c.clSuper.cls));
			print(ctx, " extends " + psup);
		}

		spr(ctx, " {");
		var closeBlock = openBlock(ctx);

		switch c.clConstructor == null ? null : c.clConstructor.cfExpr {
			case {eexpr: TFunction(f), epos: p}:
				newline(ctx);
				genFunction("constructor", ctx, f, p);
				ctx.separator = false;
			case _:
		}

		function methodDefName(cf:TClassField):String return if (validJsIdent(cf.cfName)) cf.cfName else "\"" + cf.cfName + "\"";

		var nonmethodFields = c.clOrderedFields.filter(function(cf) {
			return switch [cf.cfKind, cf.cfExpr] {
				case [Method(_), {eexpr: TFunction(f), epos: pos}]:
					checkFieldName(c, cf);
					newline(ctx);
					genFunction(methodDefName(cf), ctx, f, pos);
					ctx.separator = false;
					false;
				case _:
					true;
			}
		});

		var exposedStaticMethods:Array<{path:String, name:String}> = [];
		var nonmethodStatics = c.clOrderedStatics.filter(function(cf) {
			return switch [cf.cfKind, cf.cfExpr] {
				case [Method(_), {eexpr: TFunction(f), epos: pos}]:
					checkFieldName(c, cf);
					newline(ctx);
					genFunction("static " + (methodDefName(cf)), ctx, f, pos);
					ctx.separator = false;

					processExpose(cf.cfMeta, () -> dotp + "." + cf.cfName, s -> exposedStaticMethods.unshift({path: s, name: cf.cfName}));

					false;
				case _: true;
			}
		});

		closeBlock();
		newline(ctx);
		spr(ctx, "}");
		newline(ctx);

		for (e in exposedStaticMethods) {
			print(ctx, "$hx_exports" + pathToBrackets(e.path) + " = " + p + "." + e.name + ";");
			newline(ctx);
		}

		for (f in nonmethodStatics) genClassStaticField(ctx, c, clPath, f);

		var isAbstractImpl = isAbstractImpl(c);

		{
			var added = false;
			if (ctx.hasResolveClass && !isAbstractImpl) {
				added = true;
				print(ctx, "$hxClasses[\"" + dotp + "\"] = ");
			}
			processExpose(c.clMeta, () -> dotp, function(s) {
				added = true;
				print(ctx, "$hx_exports" + pathToBrackets(s) + " = ");
			});
			if (added) {
				spr(ctx, p);
				newline(ctx);
			}
		}

		if (!isAbstractImpl) {
			generateClass__name__(ctx, clPath);
			generateClass__isInterface__(ctx, c);
		}

		if (ctx.hasInterfaceCheck) switch c.clImplements {
			case []:
			case l:
				print(ctx, p + ".__interfaces__ = [" + ([for (i in l) ctx.typeAccessor(TClassDecl(i.cls))].join(",")) + "]");
				newline(ctx);
		}

		var hasPropertyReflection = (hasFeature(ctx, "Reflect.getProperty")) || (hasFeature(ctx, "Reflect.setProperty"));

		if (hasPropertyReflection) {
			switch codegen.Codegen.getProperties(nonmethodStatics) {
				case []:
				case props:
					print(ctx, p + ".__properties__ = {" + genProps(props, ": ") + "}");
					ctx.separator = true;
					newline(ctx);
			}
		}

		switch c.clSuper {
			case null:
			case {cls: csup}:
				if (ctx.hasInterfaceCheck || hasFeature(ctx, "Type.getSuperClass")) {
					var psup = ctx.typeAccessor(TClassDecl(csup));
					print(ctx, p + ".__super__ = " + psup);
					newline(ctx);
				}
				}
				
				var hasClass = hasFeature(ctx, "js.Boot.getClass")
			&& (c.clSuper != null || c.clOrderedFields.length > 0 || c.clConstructor != null);
		var propsToGenerate = if (hasPropertyReflection) codegen.Codegen.getProperties(c.clOrderedFields) else [];
		var fieldsToGenerate = if (hasFeature(ctx, "Type.getInstanceFields")) {
			if ((hasClassFlag(c, CInterface))) c.clOrderedFields.filter(isPhysicalField) else nonmethodFields.filter(isPhysicalVarField);
		} else [];

		if (hasClass || propsToGenerate.length > 0 || fieldsToGenerate.length > 0) {
			print(ctx, "Object.assign(" + p + ".prototype, {");
			var bend = openBlock(ctx);

			if (hasClass) {
				newprop(ctx);
				print(ctx, "__class__: " + p);
			}

			if (fieldsToGenerate.length > 0) {
				for (f in fieldsToGenerate) genClassField(ctx, c, f);
			}

			if (propsToGenerate.length > 0) {
				newprop(ctx);
				switch c.clSuper {
					case sup if (sup != null && codegen.Codegen.hasProperties(sup.cls)):
						var psup = ctx.typeAccessor(TClassDecl(sup.cls));
						print(ctx, "__properties__: Object.assign({}, " + psup + ".prototype.__properties__, {" + genProps(propsToGenerate, ": ") + "})");
					case _:
						print(ctx, "__properties__: {" + genProps(propsToGenerate, ": ") + "}");
				}
			}

			bend();
			print(ctx, "\n})");
			newline(ctx);
		}

		flush(ctx);
	}

	public static function generateClass(ctx:JsCtx, c:TClass):Void {
		ctx.current = c;
		ctx.idCounter = 0;
		switch c.clPath {
			case {pack: [], name: "Function"}: Error.abort("This class redefine a native one", c.clPos);
			case _:
		}
		switch c.clKind {
			case KModuleFields(m):
				genModuleFields(ctx, m, c, c.clOrderedStatics);
			case _:
				if (ctx.esVersion >= 6) generateClassEs6(ctx, c) else generateClassEs5(ctx, c);
		}
	}

	public static function generateEnum(ctx:JsCtx, e:TEnum):Void {
		var p = sPath(ctx, e.ePath);
		var dotp = dotPath(e.ePath);
		var hasEnumFeature = hasFeature(ctx, "has_enum");
		if (ctx.jsFlatten) print(ctx, "var ") else generatePackageCreate(ctx, e.ePath);
		print(ctx, p + " = ");
		var asObjects = !(Gctx.defined(ctx.com, Define.JsEnumsAsArrays));
		(if (asObjects) print(ctx, "$hxEnums[\"" + dotp + "\"] = ") else if (hasFeature(ctx, "Type.resolveEnum")) print(ctx,
			"$hxClasses[\"" + dotp + "\"] = "));
		spr(ctx, "{");
		if (hasFeature(ctx, "js.Boot.isEnum")) print(ctx, " __ename__:" + (if (hasFeature(ctx, "Type.getEnumName")) "\"" + dotp + "\"" else "true") + ",");
		if (asObjects) print(ctx, "__constructs__:null") else print(ctx, "__constructs__:[" + ([for (s in e.eNames) '"$s"'].join(",")) + "]");
		var bend = if (!asObjects) {
			spr(ctx, " }");
			ctx.separator = true;
			newline(ctx);
			function() {};
		} else {
			openBlock(ctx);
		};
		for (n in e.eNames) {
			var f = core.ds.PMap.find(n, e.eConstrs);
			if (asObjects) {
				newprop(ctx);
				print(ctx, anonField(f.efName) + ": ");
			} else print(ctx, p + field(f.efName) + " = ");
			switch f.efType {
				case TFun(sig):
					var args = sig.args;
					var sargs = [for (a in args) ident(a.name)].join(",");
					if (asObjects) {
						var sfields = [for (a in args) (ident(a.name)) + ":" + (ident(a.name))].join(",");
						var sparams = [for (a in args) "this." + (ident(a.name))].join(",");
						print(ctx, "($_=function(" + sargs + ") { return {_hx_index:" + f.efIndex + "," + sfields + ",__enum__:\"" + dotp + "\"");
						if (hasEnumFeature) spr(ctx, ",toString:$estr");
						print(ctx, ",__params__:function(){ return [" + sparams + "];}}; },$_._hx_name=\"" + f.efName + "\",$_)");
					} else {
						print(ctx, "function(" + sargs + ") { var $x = [\"" + f.efName + "\"," + f.efIndex + "," + sargs + "]; $x.__enum__ = " + p + ";");
						if (hasEnumFeature) spr(ctx, " $x.toString = $estr;");
						spr(ctx, " return $x; }");
					}
				case _:
					if (asObjects) print(ctx,
						"{_hx_name:\"" + f.efName + "\",_hx_index:" + f.efIndex + ",__enum__:\"" + dotp + "\"" + (if (hasEnumFeature) ",toString:$estr" else "") + "}") else {
						print(ctx, "[\"" + f.efName + "\"," + f.efIndex + "]");
						newline(ctx);
						if (hasFeature(ctx, "has_enum")) {
							print(ctx, p + field(f.efName) + ".toString = $estr");
							newline(ctx);
						}
						print(ctx, p + field(f.efName) + ".__enum__ = " + p);
					}
			}
			if (!asObjects) newline(ctx);
		}
		bend();
		if (asObjects) {
			spr(ctx, "\n}");
			ctx.separator = true;
			newline(ctx);
			print(ctx, p + ".__constructs__ = [" + ([for (s in e.eNames) p + field(s)].join(",")) + "]");
			newline(ctx);
		}
		if (hasFeature(ctx, "Type.allEnums")) {
			var ctorsWithoutArgs = e.eNames.filter(function(s) {
				var ef = core.ds.PMap.find(s, e.eConstrs);
				return switch follow(ef.efType) {
					case TFun(_): false;
					case _: true;
				}
			});
			print(ctx, p + ".__empty_constructs__ = [" + ([for (s in ctorsWithoutArgs) p + "." + s].join(",")) + "]");
			newline(ctx);
		}
		switch Texpr.buildMetadata(ctx.com.basic, TEnumDecl(e)) {
			case null:
			case e:
				print(ctx, p + ".__meta__ = ");
				genExpr(ctx, e);
				newline(ctx);
		}
		flush(ctx);
	}

	public static function generateStatic(ctx:JsCtx, s:{c:TClass, f:TClassField, e:TExpr}):Void {
		var c = s.c, f = s.f, e = s.e;
		switch c.clKind {
			case KModuleFields(m):
				print(ctx, "var " + moduleField(m, f) + " = ");
				processExpose(f.cfMeta, () -> moduleFieldExposePath(m.mPath, f), s -> print(ctx, "$hx_exports" + pathToBrackets(s) + " = "));
			case _:
				var clPath = getGeneratedClassPath(c);
				processExpose(f.cfMeta, () -> (dotPath(clPath)) + "." + f.cfName, s -> print(ctx, "$hx_exports" + pathToBrackets(s) + " = "));
				print(ctx, sPath(ctx, clPath) + staticField(ctx, c, f) + " = ");
		}
		genValue(ctx, e);
		newline(ctx);
	}

	public static function generateRequire(ctx:JsCtx, path:GlobalTypePath, meta:Metadata):Void {
		var m = Meta.get(Meta.JsRequire, meta);
		var args = m.exprs, mp = m.pos;
		var p = (sPath(ctx, path));

		if (ctx.jsFlatten) spr(ctx, "var ") else generatePackageCreate(ctx, path);

		switch args {
			case [{expr: EConst(String(moduleName, _))}]:
				print(ctx, p + " = require(\"" + moduleName + "\")");
			case [{expr: EConst(String(moduleName, _))}, {expr: EConst(String(objectPath, _))}]:
				print(ctx, p + " = require(\"" + moduleName + "\")." + objectPath);
			case _:
				Error.abort("Unsupported @:jsRequire format", mp);
		}

		newline(ctx);
	}

	public static function needToGenerateInterface(ctx:JsCtx, clIface:TClass):Bool {
		return ctx.hasResolveClass /* generate so we can resolve it for whatever reason */
			|| ctx.hasInterfaceCheck /* generate because we need __interfaces__ for run-time type checks */
			|| Gctx.isDirectlyUsed(ctx.com, clIface.clMeta) /* generate because it's just directly accessed in code */;
	}

	public static function generateType(ctx:JsCtx, t:ModuleType):Void {
		switch t {
			case TClassDecl(c):
				switch TClassTools.getClInit(c) {
					case null:
					case e:
						ctx.inits.unshift(e);
				}
				/* Special case, want to add Math.__name__ only when required, handle here since Math is extern */
				var p = sPath(ctx, c.clPath);
				if (p == "Math") generateClass__name__(ctx, c.clPath);
				/* Another special case for Std because we do not want to generate it if it's empty. */
				if (p == "Std" && c.clOrderedStatics.length == 0) {} else if (!(hasClassFlag(c, CExtern))) {
					if ((!(hasClassFlag(c, CInterface))) || (needToGenerateInterface(ctx, c))) generateClass(ctx, c);
				} else if (Meta.has(Meta.JsRequire, c.clMeta) && Gctx.isDirectlyUsed(ctx.com, c.clMeta)) generateRequire(ctx,
					getGeneratedClassPath(c), c.clMeta);
				else if (!ctx.jsFlatten && Meta.has(Meta.InitPackage, c.clMeta)) switch c.clPath {
					case {pack: []}:
					case _: generatePackageCreate(ctx, c.clPath);
				}
			case TEnumDecl(e) if (hasEnumFlag(e, EnExtern)):
				if (Meta.has(Meta.JsRequire, e.eMeta) && Gctx.isDirectlyUsed(ctx.com, e.eMeta)) generateRequire(ctx, e.ePath, e.eMeta);
			case TEnumDecl(e):
				generateEnum(ctx, e);
			case TTypeDecl(_) | TAbstractDecl(_):
		}
	}

	public static function setCurrentClass(ctx:JsCtx, c:TClass):Void {
		ctx.current = c;
	}

	public static function allocCtx(com:Gctx, esVersion:Int):JsCtx {
		var smap:Null<Sourcemap> = if (com.debug || Gctx.defined(com, Define.JsSourceMap) || Gctx.defined(com, Define.SourceMap)) {
			sourceLastPos: {file: 0, line: 0, col: 0},
			printComma: false,
			outputLastCol: 0,
			outputCurrentCol: 0,
			sources: [],
			sourcesHash: new StringMap(),
			mappings: new StringBuf(),
			currentExpr: null,
		} else null;
		var ctx = new JsCtx();
		ctx.com = com;
		ctx.buf = new JsBuffer();
		ctx.chan = null;
		ctx.packages = new StringMap();
		ctx.smap = smap;
		ctx.jsModern = !(Gctx.defined(com, Define.JsClassic));
		ctx.jsFlatten = !(Gctx.defined(com, Define.JsUnflatten));
		ctx.hasResolveClass = Gctx.hasFeature(com, "Type.resolveClass");
		ctx.hasInterfaceCheck = Gctx.hasFeature(com, "js.Boot.__interfLoop");
		ctx.esVersion = esVersion;
		ctx.statics = [];
		ctx.inits = [];
		ctx.current = nullClass;
		ctx.tabs = "";
		ctx.inValue = null;
		ctx.inLoop = false;
		ctx.idCounter = 0;
		ctx.typeAccessor = function(_) return die("", "genjs.ml");
		ctx.separator = false;
		ctx.foundExpose = false;
		ctx.catchVars = [];

		ctx.typeAccessor = function(t:ModuleType):String {
			return switch t {
				case TEnumDecl(e) if ((hasEnumFlag(e, EnExtern)) && !(Meta.has(Meta.JsRequire, e.eMeta))):
					dotPath(e.ePath);
				case TClassDecl(c):
					var p = getGeneratedClassPath(c);
					if ((hasClassFlag(c, CExtern)) && !(Meta.has(Meta.JsRequire, c.clMeta))) dotPath(p) else sPath(ctx, p);
				case _:
					sPath(ctx, tPath(t));
			}
		};
		return ctx;
	}

	public static function genSingleExpr(ctx:JsCtx, e:TExpr, expr:Bool):String {
		if (expr) genExpr(ctx, e) else genValue(ctx, e);
		var str = ctx.buf.contents();
		ctx.buf.clear();
		ctx.idCounter = 0;
		return str;
	}

	// port: Std.input_file ~bin:true.
	static function inputFile(path:String):String return sys.io.File.getBytes(path).toString();

	public static function generate(jsGen:Null<Void->Void>, com:Gctx):Void {
		switch jsGen {
			case g if (g != null):
				g();
			case _:
				var esVersion = Gctx.getEsVersion(com.defines);

				if (esVersion >= 6) filters.ES6Ctors.rewriteCtors(com);

				var ctx = allocCtx(com, esVersion);
				Gctx.mapSourceHeader(com.defines, s -> print(ctx, "// " + s + "\n"));

				var importStatements:Array<String> = []; // port: OCaml list, head at index 0
				for (mt in com.types) switch mt {
					case TClassDecl(c) if ((hasClassFlag(c, CExtern)) && Meta.has(Meta.JsImport, c.clMeta)
						&& Gctx.isDirectlyUsed(ctx.com, c.clMeta)):
						var m = Meta.get(Meta.JsImport, c.clMeta);
						var args = m.exprs, mp = m.pos;
						var id = c.clPath.name;
						var flatPath = core.Path.flatPath(getGeneratedClassPath(c));
						var alias = try {
							core.Native.getNativeName(c.clMeta).name;
						} catch (_:NotFound) {
							c.clMeta = [
								({meta: Meta.Native, exprs: vector({expr: EConst(String(flatPath, SDoubleQuotes)), pos: nullPos}), pos: nullPos} : MetadataEntry)
							].concat(c.clMeta);
							core.Native.applyNativePaths(mt);
							flatPath;
						}
						function err():Dynamic {
							return Error.abort("Unsupported @:js.import format. Use:\n"
								+ "	@:js.import('mylib.js')\n"
								+ "	@:js.import('mylib.js', 'name')\n"
								+ "	@:js.import(@default 'mylib.js')\n"
								+ "	@:js.import(@star 'mylib.js')\n"
								+ "'mylib.js' can also be replaced with mylibjs_path custom define,\nif you set it as -D mylibjs_path=\"mylib.js\"",
								mp);
						}
						function getModuleName(expr:Expr):String {
							return switch expr.expr {
								case EConst(String(moduleName, _)): moduleName;
								case EConst(Ident(define)):
									try {
										var s = Define.rawDefinedValue(com.defines, define);
										compiler.Helper.unquote(s);
									} catch (_:NotFound) {
										Error.abort("Define " + define + " with js library path is not specified", mp);
									}
								case _: err();
							}
						}
						switch args {
							/* @:js.import(@star "module") - namespace import */
							case [{expr: EMeta(sm, ename)}] if (isCustomMeta(sm, "star")):
								var moduleName = getModuleName(ename);
								importStatements.unshift('import * as $alias from "$moduleName";');
							/* @:js.import(@default "module") - default import */
							case [{expr: EMeta(sm, ename)}] if (isCustomMeta(sm, "default")):
								var moduleName = getModuleName(ename);
								importStatements.unshift('import $alias from "$moduleName";');
							/* @:js.import("module") - named import using class name */
							case [ename]:
								var moduleName = getModuleName(ename);
								importStatements.unshift('import { $id as $alias } from "$moduleName";');
							/* @:js.import("module", "exportName") - named import with alias */
							case [ename, {expr: EConst(String(exportName, _))}]:
								var moduleName = getModuleName(ename);
								importStatements.unshift('import { $exportName as $alias } from "$moduleName";');
							case exprs:
								err();
						}
					case _:
				}
				switch importStatements {
					case []:
					case lines:
						var l = lines.copy();
						l.reverse();
						for (line in l) print(ctx, line + "\n");
				}

				if (hasFeature(ctx, "Class") || hasFeature(ctx, "Type.getClassName")) addFeature(ctx, "js.Boot.isClass");
				if (hasFeature(ctx, "Enum") || hasFeature(ctx, "Type.getEnumName")) addFeature(ctx, "js.Boot.isEnum");

				var nodejs = Gctx.rawDefined(com, "nodejs");

				setupKwds(com);

				var exposed = {
					var r:Array<String> = [];
					for (t in com.types) switch t {
						case TClassDecl(c):
							function add(s:String) r.unshift(s);
							var getExposePath = switch c.clKind {
								case KModuleFields(m):
									moduleFieldExposePath.bind(m.mPath);
								case _:
									var path = dotPath(c.clPath);
									processExpose(c.clMeta, () -> path, add);
									function(f:TClassField) return path + "." + f.cfName;
							}
							for (f in c.clOrderedStatics) processExpose(f.cfMeta, () -> getExposePath(f), add);
						case _:
					}
					r;
				}
				var anyExposed = exposed.length > 0;
				var exposedObject = new JsObjectStore("", []);
				var toplevelExposed:Array<String> = [];
				if (anyExposed) {
					var exportMap = new StringMap<JsObjectStore>();
					for (path in exposed) {
						var parts = path.split(".");
						function loop(p:Array<String>, i:Int, pre:String):Void {
							var rest = p.length - i;
							if (rest >= 2) {
								var f = p[i];
								var path = switch pre {
									case "": f;
									case pre: (pre + "." + f);
								}
								if (!exportMap.exists(path)) {
									var elts = new JsObjectStore(f, []);
									exportMap.set(path, elts);
									var cobject = switch pre {
										case "": exposedObject;
										case pre:
											var o = exportMap.get(pre);
											if (o == null) throw NotFound.raise();
											o;
									}
									cobject.osFields.unshift(elts);
								}
								loop(p, i + 1, path);
							} else if (rest == 1 && pre == "") {
								toplevelExposed.unshift(p[i]);
							}
						}
						loop(parts, 0, "");
					}
				}

				var includeFiles = com.includeFiles.copy();
				includeFiles.reverse();

				for (file in includeFiles) switch file.position {
					case "top":
						var fileContent = inputFile(file.file);
						print(ctx, fileContent + "\n;");
					case _:
				}

				var definedGlobalValue = Gctx.definedValueSafe(com, Define.JsGlobal);

				var definedGlobal = definedGlobalValue != "";

				function typeofJoin(l:Array<String>, i:Int):String {
					var rest = l.length - i;
					return if (rest == 1) l[i] else if (rest > 1) "typeof " + l[i] + " != \"undefined\" ? " + l[i] + " : " + (typeofJoin(l, i + 1)) else "";
				}

				var varExports = {
					name: "$hx_exports",
					value: typeofJoin(if (definedGlobal) ["exports", definedGlobalValue] else ["exports", "window", "self", "this"], 0)
				};

				var varGlobal = {
					name: "$global",
					value: typeofJoin(if (definedGlobal) [definedGlobalValue] else ["window", "global", "self", "this"], 0)
				};

				var closureArgs = [varGlobal];
				var closureArgs = if (anyExposed && !(Gctx.defined(com, Define.ShallowExpose))) [varExports].concat(closureArgs) else closureArgs;
				if (nodejs)
					/* Add node globals to pseudo-keywords, so they are not shadowed by local vars */
					for (s in ["global", "process", "__filename", "__dirname", "module"]) kwds2.set(s, true);

				if (anyExposed && ((Gctx.defined(com, Define.ShallowExpose)) || !ctx.jsModern)) {
					print(ctx, "var " + varExports.name + " = " + varExports.value);
					ctx.separator = true;
					newline(ctx);
				}

				if (ctx.jsModern) {
					/* Wrap output in a closure */
					print(ctx, "(function (" + ([for (a in closureArgs) a.name].join(", ")) + ") { \"use strict\"");
					newline(ctx);
				}

				function printObj(f:JsObjectStore, root:String):Void {
					var path = root + (pathToBrackets(f.osName));
					print(ctx, path + " = " + path + " || {}");
					ctx.separator = true;
					newline(ctx);
					concat(ctx, ";", g -> printObj(g, path), f.osFields);
				}
				for (f in exposedObject.osFields) printObj(f, "$hx_exports");

				for (file in includeFiles) switch file.position {
					case "closure":
						var fileContent = inputFile(file.file);
						print(ctx, fileContent + "\n;");
					case _:
				}

				if (!ctx.jsModern) print(ctx, "var " + varGlobal.name + " = " + varGlobal.value + ";\n");

				var enumsAsObjects = !(Gctx.defined(com, Define.JsEnumsAsArrays));

				/* TODO: fix $estr */
				var vars:Array<String> = []; // port: OCaml list, head at index 0
				if (ctx.hasResolveClass || (!enumsAsObjects && hasFeature(ctx, "Type.resolveEnum")))
					vars.unshift("$hxClasses = " + (if (ctx.jsModern) "{}" else "$hxClasses || {}"));
				if (hasFeature(ctx, "has_enum"))
					vars.unshift("$estr = function() { return " + (ctx.typeAccessor(TClassDecl(jsBootClass()))) + ".__string_rec(this,''); }");
				if (enumsAsObjects && (hasFeature(ctx, "has_enum") || hasFeature(ctx, "Type.resolveEnum"))) vars.unshift("$hxEnums = $hxEnums || {}");
				var hasDollarUnderscore = if (Lambda.exists(com.types, t -> switch t {
					case TEnumDecl(e) if (!(hasEnumFlag(e, EnExtern))): true;
					case _: false;
				})) {
					vars.unshift("$_");
					true;
				} else false;
				switch vars {
					case []:
					case vl:
						var l = vl.copy();
						l.reverse();
						print(ctx, "var " + l.join(","));
						ctx.separator = true;
						newline(ctx);
				}
				if (ctx.esVersion < 6 && Lambda.exists(com.types, t -> switch t {
					case TClassDecl(c) if (c.clSuper != null): !(hasClassFlag(c, CExtern));
					case _: false;
				})) {
					var extendCode = "function $extend(from, fields) {\n"
						+ "	var proto = Object.create(from);\n"
						+ "	for (var name in fields) proto[name] = fields[name];\n"
						+ "	if( fields.toString !== Object.prototype.toString ) proto.toString = fields.toString;\n"
						+ "	return proto;\n"
						+ "}\n";
					spr(ctx, extendCode);
				}
				for (t in com.types) generateType(ctx, t);
				function chkFeatures(e:TExpr):Void {
					if (isDynamicIterator(ctx, e)) addFeature(ctx, "use.$iterator");
					switch e.eexpr {
						case TField(_, FClosure(_)):
							addFeature(ctx, "use.$bind");
						case TCall(ef = {eexpr: TField(_, f)}, []) if (fieldName(f) == "iterator" && isDynamicIterator(ctx, ef)):
							addFeature(ctx, "use.$getIterator");
						case _:
							Texpr.iter(chkFeatures, e);
					}
				}
				for (e in ctx.inits) chkFeatures(e);
				for (s in ctx.statics) chkFeatures(s.e);
				if (hasFeature(ctx, "use.$iterator")) {
					addFeature(ctx, "use.$bind");
					var arrayIterator = sPath(ctx, {pack: ["haxe", "iterators"], name: "ArrayIterator"});
					print(ctx,
						"function $iterator(o) { if( o instanceof Array ) return function() { return new "
						+ arrayIterator
						+ "(o); }; return typeof(o.iterator) == 'function' ? $bind(o,o.iterator) : o.iterator; }");
					newline(ctx);
				}
				if (hasFeature(ctx, "use.$keyValueIterator")) {
					addFeature(ctx, "use.$bind");
					print(ctx,
						"function $keyValueIterator(o) { if( o instanceof Array ) return function() { return HxOverrides.keyValueIter(o); }; return typeof(o.keyValueIterator) == 'function' ? $bind(o,o.keyValueIterator) : o.keyValueIterator; }");
					newline(ctx);
				}
				if (hasFeature(ctx, "use.$getIterator")) {
					var arrayIterator = sPath(ctx, {pack: ["haxe", "iterators"], name: "ArrayIterator"});
					print(ctx, "function $getIterator(o) { if( o instanceof Array ) return new " + arrayIterator + "(o); else return o.iterator(); }");
					newline(ctx);
				}
				if (hasFeature(ctx, "use.$getKeyValueIterator")) {
					print(ctx,
						"function $getKeyValueIterator(o) { if( o instanceof Array ) return HxOverrides.keyValueIter(o); else return o.keyValueIterator(); }");
					newline(ctx);
				}
				if (hasFeature(ctx, "use.$bind")) {
					addFeature(ctx, "$global.$haxeUID");
					if (!hasDollarUnderscore) {
						print(ctx, "var $_");
						newline(ctx);
						hasDollarUnderscore = true;
					}
					print(ctx,
						"function $bind(o,m) { if( m == null ) return null; if( m.__id__ == null ) m.__id__ = $global.$haxeUID++; var f; if( o.hx__closures__ == null ) o.hx__closures__ = {}; else f = o.hx__closures__[m.__id__]; if( f == null ) { f = m.bind(o); o.hx__closures__[m.__id__] = f; } return f; }");
					newline(ctx);
				}
				if (hasFeature(ctx, "use.$arrayPush")) {
					print(ctx, "function $arrayPush(x) { return this.push(x); }");
					newline(ctx);
				}
				if (hasFeature(ctx, "$global.$haxeUID")) {
					addFeature(ctx, "js.Lib.global");
					print(ctx, "$global.$haxeUID |= 0;\n");
				}
				if (!hasDollarUnderscore && hasFeature(ctx, "thisForCallWithRestArgs")) {
					print(ctx, "var $_");
					newline(ctx);
					hasDollarUnderscore = true;
				}
				{
					var l = ctx.inits.copy();
					l.reverse();
					for (e in l) genBlockElement(true, (ctx.esVersion >= 6), ctx, e);
				}
				{
					var l = ctx.statics.copy();
					l.reverse();
					for (s in l) generateStatic(ctx, s);
				}
				switch com.main.mainExpr {
					case null:
					case e:
						genExpr(ctx, e);
						newline(ctx);
				}
				if (ctx.jsModern) {
					var closureArgs = if (hasFeature(ctx, "js.Lib.global") || definedGlobal) closureArgs else {
						/* no need for `typeof window != "undefined" ? window : typeof global != "undefined" ? <...>` */
						if (closureArgs.length > 0) {
							var l = closureArgs.copy();
							var last = l[l.length - 1];
							l[l.length - 1] = {name: last.name, value: "{}"};
							l;
						} else closureArgs;
					}
					print(ctx, "})(" + ([for (a in closureArgs) a.value].join(", ")) + ")");
					newline(ctx);
				}

				if (anyExposed && (Gctx.defined(com, Define.ShallowExpose))) {
					for (f in exposedObject.osFields) {
						print(ctx, "var " + f.osName + " = $hx_exports" + pathToBrackets(f.osName));
						ctx.separator = true;
						newline(ctx);
					}
					for (f in toplevelExposed) {
						print(ctx, "var " + f + " = $hx_exports" + pathToBrackets(f));
						ctx.separator = true;
						newline(ctx);
					}
				}

				switch ctx.smap {
					case null:
						try sys.FileSystem.deleteFile(com.file + ".map") catch (_:Dynamic) {}
					case smap if (Gctx.definedValueSafe(com, Define.SourceMap) == "inline"):
						/* the map inside the output: no .map file, and none left from an earlier build */
						try sys.FileSystem.deleteFile(com.file + ".map") catch (_:Dynamic) {}
						print(ctx, "\n//# sourceMappingURL=" + JsSourcemap.mappingsDataUrl(ctx.com, smap, "file:///"));
					case smap:
						JsSourcemap.writeMappings(ctx.com, smap, "file:///");
						var basefile = core.OcamlFilename.basename(com.file);
						print(ctx, "\n//# sourceMappingURL=" + core.StringHelper.urlEncodeString(basefile) + ".map");
				}
				flush(ctx);
				if (ctx.chan != null) ctx.chan.close();
		}
	}

	// port: matches the `(Meta.Custom name,[],_)` patterns of the @:js.import arguments.
	static function isCustomMeta(m:MetadataEntry, name:String):Bool {
		return m.exprs.length == 0 && switch (m.meta : core.MetaList.StrictMeta) {
			case Custom(s): s == name;
			case _: false;
		}
	}
}
