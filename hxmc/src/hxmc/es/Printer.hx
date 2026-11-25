package hxmc.es;

import core.TType;
import hxmc.es.Es;

using StringTools;

// Es to text: parentheses by precedence, layout (plain: indented, a statement a line; tight: no whitespace the code
// does without, no comments), TypeScript's types where it has them (`types`). It decides nothing about the program.
class Printer {
	static inline final SEQ = 1;
	static inline final ASSIGN = 2;
	static inline final COND = 3;
	static inline final NULLISH = 4;
	static inline final OR = 5;
	static inline final AND = 6;
	static inline final BOR = 7;
	static inline final BXOR = 8;
	static inline final BAND = 9;
	static inline final EQ = 10;
	static inline final REL = 11;
	static inline final SHIFT = 12;
	static inline final ADD = 13;
	static inline final MUL = 14;
	static inline final EXP = 15;
	static inline final UNARY = 16;
	static inline final POSTFIX = 17;
	static inline final CALL = 19;
	static inline final PRIMARY = 20;

	// objects and arrays up to this width stay on one line
	static inline final INLINE_WIDTH = 80;

	// Untyped code's shapes the printer recognizes, by hand: printers run in parallel, and an EReg's match is its state.
	// (`\x01` stands for a value; as `^...$` would, a line break may end the text)

	// `a.b.c`
	static function isPath(s:String):Bool return atEnd(s, path(s, 0));

	// `\x01.f(\x01, \x01)`: a call of a method of the first value
	static function isMethodCall(s:String):Bool {
		if (s.length == 0 || StringTools.fastCodeAt(s, 0) != 1) return false;
		var i = 1, members = 0;
		while (i < s.length && StringTools.fastCodeAt(s, i) == ".".code) {
			i = ident(s, i + 1);
			if (i < 0) return false;
			members++;
		}
		return members > 0 && atEnd(s, args(s, i));
	}

	// `a.b.c`, `a.b(\x01, \x01)`: what TypeScript checks as it does any other code
	static function isPlainCall(s:String):Bool {
		var i = path(s, 0);
		if (i < 0) return false;
		return atEnd(s, i) || atEnd(s, args(s, i));
	}

	static function atEnd(s:String, i:Int):Bool return i >= 0 && (i == s.length || i == s.length - 1 && StringTools.fastCodeAt(s, i) == "\n".code);

	// (the end of an identifier at i, of identifiers joined by `.`, of `(...)` at i; -1: none)
	static function ident(s:String, i:Int):Int {
		if (i >= s.length || !EsTools.identStart(StringTools.fastCodeAt(s, i))) return -1;
		i++;
		while (i < s.length && EsTools.identPart(StringTools.fastCodeAt(s, i))) i++;
		return i;
	}

	static function path(s:String, i:Int):Int {
		i = ident(s, i);
		while (i >= 0 && i < s.length && StringTools.fastCodeAt(s, i) == ".".code) i = ident(s, i + 1);
		return i;
	}

	static function args(s:String, i:Int):Int {
		inline function at(k:Int) return k < s.length ? StringTools.fastCodeAt(s, k) : -1;
		if (i < 0 || at(i) != "(".code) return -1;
		i++;
		if (at(i) == 1) {
			i++;
			while (at(i) == ",".code) {
				i++;
				if (at(i) == " ".code) i++;
				if (at(i) != 1) return -1;
				i++;
			}
		}
		return at(i) == ")".code ? i + 1 : -1;
	}


	final buf = new StringBuf();
	final tight:Bool;
	var indent = 0;
	// (TypeScript) the types of the declarations, `as any`, `// @ts-ignore` before untyped code
	public var types:Null<Ts.Types> = null;
	// (modules) a split's call: its imports, the pattern of what its code takes of them (Chunk.splitImport)
	public var splitImport:Null<Int->{load:String, pattern:String}> = null;
	// (minified) a Haxe field's name as printed (FieldNames)
	public var fieldName:Null<String->Ns->String> = null;
	// a reference as the output has it (Chunk.refEx)
	public var ref:Null<(Ref, Null<core.Globals.Pos>)->Ex> = null;
	// an accessor's call as its property's family has it (Chunk.accessorEx)
	public var accessor:Null<(TClassField, Ex, Bool)->Ex> = null;
	// (-D js-source-map) the map the printed text is marked for (SourceMap)
	public var smap:Null<SourceMap> = null;

	inline function fname(n:String, ns:Ns):String return fieldName == null ? n : fieldName(n, ns);

	// a source map's marker of pos (and of the name printed after it, renamed), or nothing
	inline function mark(pos:Null<core.Globals.Pos>, ?name:String):String return smap == null ? "" : smap.mark(pos, name);

	public function new(tight = false) {
		this.tight = tight;
	}

	public function toString() return buf.toString();

	// a printer of a part of this one's output
	function sub(tight:Bool):Printer {
		var p = new Printer(tight);
		p.types = types;
		p.splitImport = splitImport;
		p.fieldName = fieldName;
		p.ref = ref;
		p.accessor = accessor;
		p.smap = smap;
		return p;
	}

	// a separator with the spaces around it, or without them (tight)
	inline function sp(s:String):String return tight ? s.trim() : s;

	inline function nl():String return tight ? "" : "\n";

	function tabs(n:Int):String {
		if (tight) return "";
		var s = "";
		for (_ in 0...n) s += "\t";
		return s;
	}

	function line(s:String) {
		buf.add(tabs(indent));
		buf.add(s);
		buf.add(nl());
	}

	public function statements(body:Array<St>) {
		if (!tight) {
			for (s in body) statement(s);
			return;
		}
		// (tight: consecutive declarations as one, `let a=1,b=2;`)
		var i = 0;
		while (i < body.length) switch body[i].def {
			case SVar(_, d):
				var all = d.copy();
				i++;
				while (i < body.length) switch body[i].def {
					case SVar(_, d2):
						for (x in d2) all.push(x);
						i++;
					case _: break;
				}
				line(decls(VLet, all) + ";");
			case _:
				statement(body[i]);
				i++;
		}
	}

	public function blank() if (!tight) buf.add("\n");

	function decls(kind:VarKind, decls:Array<Decl>):String
		return (kind == VConst && !tight ? "const " : "let ") + [for (d in decls) d.name.name + typeOf(d.name) + (d.init == null ? "" : sp(" = ") + expr(d.init, ASSIGN))].join(sp(", "));

	// (TypeScript) a name's declared type
	function typeOf(s:Sym):String return types == null || s.type == null ? "" : ": " + types.type(s.type);

	public function statement(s:St):Void {
		// (TypeScript: a statement with untyped code unchecked, each of its lines; not where a line may be in a
		// template literal's)
		if (types != null && s.def.match(SExpr(_) | SVar(_) | SReturn(_) | SThrow(_)) && hasRaw(s)) {
			var p = sub(tight);
			p.indent = indent;
			p.statementOnly(s);
			var code = p.toString();
			if (code.indexOf("`") < 0) {
				var t = tabs(indent);
				for (l in code.split("\n")) if (l != "") buf.add(t + "// @ts-ignore\n" + l + "\n");
				return;
			}
			buf.add(code);
			return;
		}
		statementOnly(s);
	}

	static function hasRaw(s:St):Bool {
		var found = false;
		function walk(e:Ex) {
			if (found || e == null) return;
			switch e.def {
				// (but a name, a path, a call of one: what TypeScript checks as it does any other)
				case ERaw(parts) if (isPlainCall([for (p in parts) switch p {
						case RText(s): s;
						case RValue(_): "\x01";
					}].join(""))):
					for (p in parts) switch p {
						case RValue(v): walk(v);
						case _:
					}
				case ERaw(_): found = true;
				case EArray(a) | ESeq(a): for (x in a) walk(x);
				case EObject(props): for (p in props) walk(p.value);
				case EFriend(o, _): walk(o);
				case EAccessor(_, c, _): walk(c);
				case EMember(o, _) | EField(o, _, _) | EPrivate(o, _) | EUnary(_, o) | EUpdate(_, _, o) | ESpread(o) | EImport(o) | EAs(o) | ETypeArgs(o, _): walk(o);
				case EIndex(a, b) | EBinary(_, a, b) | EAssign(_, a, b): walk(a); walk(b);
				case ECall(f, args) | ENew(f, args): walk(f); for (x in args) walk(x);
				case ECond(c, a, b): walk(c); walk(a); walk(b);
				// (a function's statements: each its own)
				case _:
			}
		}
		switch s.def {
			case SExpr(e) | SThrow(e) | SReturn(e): walk(e);
			case SVar(_, d): for (x in d) walk(x.init);
			case _:
		}
		return found;
	}

	function statementOnly(s:St):Void {
		// (its mapping: where its text starts, past the indentation)
		if (smap != null) buf.add(mark(s.pos));
		switch s.def {
			case SExpr(e = {def: ERaw(_)}):
				// (untyped code: a line of its own, it may end in a comment or rely on one)
				var code = exprStatement(e);
				var end = code.endsWith("}") || code.endsWith("{") || code.endsWith(";") ? "" : ";";
				buf.add(tabs(indent) + code + end + "\n");
			case SExpr(e):
				line(exprStatement(e) + ";");
			case SVar(kind, d):
				line(decls(kind, d) + ";");
			case SReturn(null):
				line("return;");
			case SReturn(e):
				line("return " + expr(e, SEQ) + ";");
			case SIf(c, a, b):
				buf.add(tabs(indent) + sp("if (") + expr(c, SEQ) + sp(") "));
				ifRest(a, b);
			case SBlock(body):
				line("{");
				nested(body);
				line("}");
			case SWhile(c, body):
				buf.add(tabs(indent) + sp("while (") + expr(c, SEQ) + sp(") "));
				block(body);
				buf.add(nl());
			case SDoWhile(body, c):
				buf.add(tabs(indent) + sp("do "));
				block(body);
				buf.add(sp(" while (") + expr(c, SEQ) + ");" + nl());
			case SFor(init, test, update, body):
				var i = switch init {
					case null: "";
					case {def: SVar(kind, d)}: decls(kind, d);
					case {def: SExpr(e)}: expr(e, SEQ);
					case _: throw "assert";
				}
				buf.add(tabs(indent) + sp("for (") + i + sp("; ") + (test == null ? "" : expr(test, SEQ)) + sp("; ") + (update == null ? "" : expr(update, SEQ)) + sp(") "));
				block(body);
				buf.add(nl());
			case SForOf(kind, v, of, body):
				buf.add(tabs(indent) + sp("for (") + (kind == VConst ? "const " : "let ") + v.name + " of " + expr(of, ASSIGN) + sp(") "));
				block(body);
				buf.add(nl());
			case SBreak(l):
				line("break" + (l == null ? "" : " " + l) + ";");
			case SContinue(l):
				line("continue" + (l == null ? "" : " " + l) + ";");
			case SThrow(e):
				line("throw " + expr(e, SEQ) + ";");
			case STry(body, param, handler):
				buf.add(tabs(indent) + sp("try "));
				block(body);
				buf.add(sp(" catch") + (param == null ? sp(" ") : sp(" (") + param.name + (types == null ? "" : ": any") + sp(") ")));
				block(handler);
				buf.add(nl());
			case SSwitch(on, cases):
				line(sp("switch (") + expr(on, SEQ) + sp(") {"));
				for (c in cases) {
					var head = switch c.tests {
						case null: [tabs(indent) + "default:"];
						case tests: [for (t in tests) tabs(indent) + "case " + expr(t, SEQ) + ":"];
					}
					inline function comment(i:Int) return tight || c.comments == null || c.comments[i] == null ? "" : " // " + c.comments[i];
					var last = head.length - 1;
					for (i in 0...last) head[i] += comment(i);
					switch c.body {
						// (a block: `case 0: {`)
						case [{def: SBlock(b)}]:
							buf.add(head.join(nl()) + sp(" {") + comment(last) + nl());
							nested(b);
							line("}");
						case body:
							head[last] += comment(last);
							buf.add(head.join(nl()) + nl());
							nested(body);
					}
				}
				line("}");
			case SLabel(label, body):
				buf.add(tabs(indent) + label + ":" + nl());
				statement(body);
			case SClass(c):
				buf.add(tabs(indent));
				buf.add(classDecl(c));
				buf.add(nl());
			case SFunction(f):
				buf.add(tabs(indent) + "function " + f.name.name + withParams(f.tparams, () -> signature(f, true) + sp(" ") + blockString(f.body)) + nl());
			case SExport({def: SInterface(_)}) | SInterface(_) if (types == null):
			case SInterface(name, c):
				buf.add(tabs(indent) + types.interfaceDecl(c, name.name, tabs(indent)) + nl());
			case SExport({def: SEnum(name, call, en, index)}):
				enumDecl(name, call, en, index, true);
			case SEnum(name, call, en, index):
				enumDecl(name, call, en, index, false);
			case SExport(inner):
				buf.add(tabs(indent) + "export ");
				var old = indent;
				indent = 0;
				statement(inner);
				indent = old;
			case SComment(text):
				if (!tight) for (l in text.split("\n")) line("// " + l);
			case SRaw(code):
				for (l in code.split("\n")) buf.add(tabs(indent) + l + "\n");
		}
	}

	function ifRest(a:Array<St>, b:Null<Array<St>>) {
		block(a);
		switch b {
			case null:
				buf.add(nl());
			case [{def: SIf(c2, a2, b2)}]:
				buf.add(sp(" else if (") + expr(c2, SEQ) + sp(") "));
				ifRest(a2, b2);
			case b:
				buf.add(sp(" else "));
				block(b);
				buf.add(nl());
		}
	}

	function nested(body:Array<St>) {
		indent++;
		statements(body);
		indent--;
	}

	// `{ ... }` from the current position to its closing brace (no line break after it)
	function block(body:Array<St>) {
		if (body.length == 0) {
			buf.add("{}");
			return;
		}
		if (tight) {
			// (no `;` before `}`)
			var p = sub(true);
			p.statements(body);
			var s = p.toString();
			buf.add("{" + (s.endsWith(";") ? s.substr(0, s.length - 1) : s) + "}");
			return;
		}
		buf.add("{" + nl());
		nested(body);
		buf.add(tabs(indent) + "}");
	}

	// a block as a string, at the current indentation
	function blockString(body:Array<St>):String {
		var p = sub(tight);
		p.indent = indent;
		p.block(body);
		return p.toString();
	}

	function exprStatement(e:Ex):String {
		var s = expr(e, SEQ);
		return startsAmbiguous(e) ? "(" + s + ")" : s;
	}

	// whether an expression statement would start with `{`, `function` or `class`
	static function startsAmbiguous(e:Ex):Bool {
		return switch e.def {
			case EObject(_) | EClass(_): true;
			case EFn(f): !f.arrow;
			case EMember(o, _) | EField(o, _, _) | EPrivate(o, _) | EIndex(o, _) | ECall(o, _) | EAs(o) | ETypeArgs(o, _): startsAmbiguous(o);
			case EFriend(o, _): startsAmbiguous(o);
			case EAccessor(_, c, _): startsAmbiguous(c);
			case EBinary(_, a, _) | EAssign(_, a, _) | ECond(a, _, _): startsAmbiguous(a);
			case EUpdate(_, false, x): startsAmbiguous(x);
			case ESeq(items) if (items.length > 0): startsAmbiguous(items[0]);
			case _: false;
		}
	}

	static function binaryPrec(op:String):Int {
		return switch op {
			case "??": NULLISH;
			case "||": OR;
			case "&&": AND;
			case "|": BOR;
			case "^": BXOR;
			case "&": BAND;
			case "==" | "!=" | "===" | "!==": EQ;
			case "<" | ">" | "<=" | ">=" | "instanceof" | "in": REL;
			case "<<" | ">>" | ">>>": SHIFT;
			case "+" | "-": ADD;
			case "*" | "/" | "%": MUL;
			case "**": EXP;
			case _: throw 'unknown operator $op';
		}
	}

	function precOf(e:Ex):Int {
		return switch e.def {
			case EAs(x): types == null ? precOf(x) : PRIMARY;
			case ETypeArgs(x, _): types == null ? precOf(x) : CALL;
			case ESeq(_): SEQ;
			case EAssign(_) | ESpread(_): ASSIGN;
			case EFn(f) if (f.arrow): ASSIGN;
			case ECond(_): COND;
			case EBinary(op, _, _): binaryPrec(op);
			case EUnary(_): UNARY;
			case EUpdate(_, prefix, _): prefix ? UNARY : POSTFIX;
			case ENew(_) | ECall(_) | EMember(_) | EField(_) | EPrivate(_) | EFriend(_) | EIndex(_) | EImport(_): CALL;
			case ENum(s) if (s.startsWith("-")): UNARY;
			// (untyped code: its precedence unknown, but for a name or a path)
			case ERaw([RText(s)]) if (isPath(s)): PRIMARY;
			// (a call of a method of its first value: `{0}.charCodeAt({1})`)
			case ERaw(parts) if (isMethodCall([for (p in parts) switch p {
					case RText(s): s;
					case RValue(_): "\x01";
				}].join(""))): CALL;
			case ERaw(_): SEQ;
			case _: PRIMARY;
		}
	}

	// a reference as what it is (Chunk.refEx)
	function deref(e:Ex):Ex return switch e.def {
		case ERef(r): ref(r, e.pos);
		case EAccessor(a, c, d): deref(accessor == null ? c : accessor(a, c, d));
		case _: e;
	}

	function paren(e:Ex, min:Int):String {
		e = deref(e);
		var s = exprRaw(e);
		// (a renamed binding: its own name)
		var m = smap == null ? "" : switch e.def {
			case EId(sym) if (sym.name != sym.hint): mark(e.pos, sym.hint);
			case _: mark(e.pos);
		}
		return (tight && e.def.match(EBool(_)) ? UNARY : precOf(e)) < min ? "(" + m + s + ")" : m + s;
	}

	// e where an expression of at least precedence `min` may stand
	public function expr(e:Ex, min:Int):String return paren(e, min);

	static inline function word(c:String):Bool return c.length == 1 && EsTools.identPart(StringTools.fastCodeAt(c, 0));

	// a binary operator between its operands: spaced, or (tight) where tokens would merge (`a - -b`, `x in y`)
	function binary(sa:String, op:String, sb:String):String {
		if (!tight) return sa + " " + op + " " + sb;
		var l = SourceMap.last(sa), r = SourceMap.first(sb);
		var before = word(op.charAt(0)) && word(l) || (op.charAt(0) == "+" || op.charAt(0) == "-") && l == op.charAt(0);
		var after = word(op.charAt(op.length - 1)) && word(r) || (op.charAt(op.length - 1) == "+" || op.charAt(op.length - 1) == "-") && r == op.charAt(op.length - 1);
		// (`<!--` would start a comment in a classic script)
		if (op == "<" && r == "!") after = true;
		return sa + (before ? " " : "") + op + (after ? " " : "") + sb;
	}

	function exprRaw(e:Ex):String {
		return switch e.def {
			case EId(s): s.name;
			case ERef(_) | EAccessor(_): exprRaw(deref(e));
			case EThis: "this";
			case ESuper: "super";
			case ENull: "null";
			case EUndefined: "undefined";
			case EBool(b): tight ? (b ? "!0" : "!1") : b ? "true" : "false";
			case ENum(s): s;
			case EStr(s): quote(s);
			case EArray(items):
				var parts = [for (i in items) expr(i, ASSIGN)];
				var one = "[" + parts.join(sp(", ")) + "]";
				if (tight || SourceMap.width(one) <= INLINE_WIDTH && one.indexOf("\n") < 0) one else {
					var t = tabs(indent + 1);
					indent++;
					var parts = [for (i in items) t + expr(i, ASSIGN)];
					indent--;
					"[\n" + parts.join(",\n") + "\n" + tabs(indent) + "]";
				}
			case EObject([]): "{}";
			case EObject(props):
				var parts = [for (p in props) prop(p)];
				var one = sp("{ ") + parts.join(sp(", ")) + sp(" }");
				if (tight || SourceMap.width(one) <= INLINE_WIDTH && one.indexOf("\n") < 0) one else {
					indent++;
					var t = tabs(indent);
					var parts = [for (p in props) t + prop(p)];
					indent--;
					"{\n" + parts.join(",\n") + "\n" + tabs(indent) + "}";
				}
			case EFn(f): fn(f);
			case EClass(c): classDecl(c);
			case EMember(o, name): object(o) + "." + name;
			case EField(o, name, ns):
				var n = fname(name, ns);
				object(o) + "." + (n != name ? mark(e.pos, name) : "") + n;
			case EFieldName(name, ns): quote(fname(name, ns));
			case EPrivate(o, name): object(o) + ".#" + name;
			case EFriend(o, name): types == null && EsTools.validIdent(name) ? object(o) + "." + name : object(o) + "[" + quote(name) + "]";
			case EIndex(o, k): object(o) + "[" + expr(k, SEQ) + "]";
			case ECall(f, args): callee(f) + "(" + [for (a in args) expr(a, ASSIGN)].join(sp(", ")) + ")";
			case ENew(c, args): "new " + newCallee(c) + "(" + [for (a in args) expr(a, ASSIGN)].join(sp(", ")) + ")";
			// (TypeScript: `!null`, which it rejects however cast, is true)
			case EUnary("!", {def: ENull}) if (types != null): "true";
			case EUnary(op, x):
				var s = paren(x, UNARY);
				var isWord = op == "typeof" || op == "void" || op == "delete";
				op + (isWord || (SourceMap.first(s) == op.charAt(op.length - 1) && (op == "-" || op == "+")) ? " " : "") + s;
			case EUpdate(op, true, x): op + paren(x, UNARY);
			case EUpdate(op, false, x): paren(x, POSTFIX) + op;
			case EBinary(op, a, b):
				var p = binaryPrec(op);
				var sa = op == "**" ? paren(a, p + 1) : paren(a, p);
				var sb = op == "**" ? paren(b, p) : paren(b, p + 1);
				// (`??` with `||` or `&&` beside it: parentheses, which JavaScript requires)
				if (op == "??" || op == "||" || op == "&&") {
					inline function mixes(x:Ex) return switch x.def {
						case EBinary(o, _, _): (op == "??") != (o == "??") && (o == "??" || o == "||" || o == "&&");
						case _: false;
					}
					if (mixes(a) && SourceMap.first(sa) != "(") sa = "(" + sa + ")";
					if (mixes(b) && SourceMap.first(sb) != "(") sb = "(" + sb + ")";
				}
				binary(sa, op, sb);
			case EAssign(op, a, b): binary(paren(a, POSTFIX), op, paren(b, ASSIGN));
			case ECond(c, a, b): paren(c, NULLISH) + sp(" ? ") + paren(a, ASSIGN) + sp(" : ") + paren(b, ASSIGN);
			case ESeq(items): [for (i in items) paren(i, ASSIGN)].join(sp(", "));
			case ESpread(x): "..." + paren(x, ASSIGN);
			case EAs(x): types == null ? exprRaw(x) : "(" + paren(x, UNARY) + " as any)";
			case ETypeArgs(x, a): types == null ? exprRaw(x) : paren(x, CALL) + "<" + [for (t in a) types.type(t)].join(", ") + ">";
			case EImport(p): "import(" + expr(p, ASSIGN) + ")";
			case ESplit(file, f):
				var s = splitImport(file);
				var params = s.pattern == "" ? [] : [new Sym(SLocal, s.pattern)];
				s.load + ".then(" + fn({params: params, rest: false, arrow: true, body: f.body, contextual: true}) + ")";
			// (TypeScript: untyped code's path, its members unchecked, as Haxe has them: `Error.prepareStackTrace`, V8's)
			case ERaw([RText(s)]) if (types != null && s.indexOf(".") > 0 && isPath(s) && !StringTools.startsWith(s, "$hx.")):
				var i = s.indexOf(".");
				"(" + s.substr(0, i) + " as any)" + s.substr(i);
			case ERaw(parts):
				var b = new StringBuf();
				for (i in 0...parts.length) switch parts[i] {
					case RText(s): b.add(s);
					// (before `.`, `[` or `(`: what a member or a call takes)
					case RValue(e):
						var next = i + 1 < parts.length ? switch parts[i + 1] {
							case RText(s): s.charAt(0);
							case _: "";
						} : "";
						b.add(next == "." || next == "[" || next == "(" ? object(e) : expr(e, SEQ));
				}
				b.toString();
		}
	}

	function object(o:Ex):String {
		o = deref(o);
		return switch o.def {
			// (TypeScript: `null` used as an object, which Haxe types and TypeScript rejects)
			case ENull if (types != null): "(null as any)";
			// (and `{}`, whose fields Haxe's optional ones are)
			case EObject([]) if (types != null): "({} as any)";
			case ENum(_): "(" + exprRaw(o) + ")";
			case EFn(_) | EClass(_) | EObject(_): "(" + exprRaw(o) + ")";
			case _: paren(o, CALL);
		}
	}

	function callee(f:Ex):String {
		f = deref(f);
		return switch f.def {
			case ENull if (types != null): "(null as any)";
			case EFn(_) | EClass(_): "(" + exprRaw(f) + ")";
			case _: paren(f, CALL);
		}
	}

	// (a callee with a call in it: parenthesized, or `new` would take that call's arguments)
	function newCallee(c:Ex):String {
		c = deref(c);
		function plain(e:Ex):Bool return switch e.def {
			case EId(_) | ERef(_) | EThis: true;
			case EMember(o, _) | EField(o, _, _) | EPrivate(o, _) | ETypeArgs(o, _) | EFriend(o, _): plain(o);
			case EIndex(o, _): plain(o);
			case EClass(_): true;
			case _: false;
		}
		return plain(c) ? exprRaw(c) : "(" + exprRaw(c) + ")";
	}

	function prop(p:Prop):String {
		return switch [p.key, p.value.def] {
			case [KName(n), EId(s)] if (s.name == n): n;
			case [k, EFn(f)] if (!f.arrow && f.ctor != true): key(k, f.pos) + withParams(f.tparams, () -> signature(f, true) + sp(" ") + blockString(f.body));
			case [k, _]: key(k, p.value.pos) + sp(": ") + expr(p.value, ASSIGN);
		}
	}

	// (pos: where a renamed field's name maps to, its own name, SourceMap)
	function key(k:Key, ?pos:core.Globals.Pos):String {
		return switch k {
			case KName(s): s;
			case KField(s, ns):
				var n = fname(s, ns);
				(n != s ? mark(pos, s) : "") + n;
			case KString(s): quote(s);
			case KPrivate(s): "#" + s;
			case KComputed(e): "[" + expr(e, ASSIGN) + "]";
		}
	}

	// (TypeScript) f's type parameters in scope while it prints
	function withParams<R>(tparams:Null<core.TType.TypeParams>, print:Void->R):R {
		if (types == null || tparams == null || tparams.length == 0) return print();
		var outer = types.scope;
		types.scope = outer.concat([for (p in tparams) p.ttpName]);
		var r = print();
		types.scope = outer;
		return r;
	}

	// `(a, b)`; TypeScript: `<T>(this: any, a: A, b?: B): R` (ret: with its return type)
	function signature(f:Fn, ret:Bool):String {
		var ps = [for (i in 0...f.params.length) {
			var rest = f.rest && i == f.params.length - 1;
			(rest ? "..." : "") + f.params[i].name + (types == null ? "" : paramType(f, i, rest));
		}];
		if (types == null) return "(" + ps.join(sp(", ")) + ")";
		if (f.thisAny == true) ps.unshift("this: any");
		var tps = f.tparams == null ? "" : types.params(f.tparams);
		return tps + "(" + ps.join(", ") + ")" + (ret && f.ret != null ? ": " + types.type(f.ret) : "");
	}

	function paramType(f:Fn, i:Int, rest:Bool):String {
		var t = f.params[i].type;
		if (f.contextual == true) return "";
		if (t == null) return ": any";
		if (rest) return switch core.TFunctions.follow(t) {
			case TAbstract(_, [x]) | TInst(_, [x]): ": Array<" + types.type(x) + ">";
			case _: ": any[]";
		}
		return (f.optFrom != null && i >= f.optFrom ? "?" : "") + ": " + types.type(t);
	}

	function fn(f:Fn):String return withParams(f.tparams, () -> {
		if (!f.arrow) return "function" + (f.name == null ? "" : " " + f.name.name) + signature(f, true) + sp(" ") + blockString(f.body);
		return switch f.body {
			case [{def: SReturn(v)}] if (v != null):
				var s = paren(v, ASSIGN);
				signature(f, true) + sp(" => ") + (switch v.def {
					case EObject(_): "(" + s + ")";
					case _: s;
				});
			case _:
				signature(f, true) + sp(" => ") + blockString(f.body);
		}
	});

	// (TypeScript: the call with the enum's declaration as its type argument, then its types)
	function enumDecl(name:Sym, call:Ex, en:TEnum, index:Sym, exported:Bool) {
		var exp = exported ? "export " : "";
		if (types == null) {
			line(exp + "const " + name.name + sp(" = ") + expr(call, ASSIGN) + ";");
			return;
		}
		switch call.def {
			case ECall(f, args):
				var t = types.enumTypes(en, name.name, index.name, tabs(indent), exported);
				line(exp + "const " + name.name + " = " + callee(f) + "<" + t.decl + ">(" + [for (a in args) expr(a, ASSIGN)].join(", ") + ");");
				buf.add(t.after);
			case _:
				throw "assert";
		}
	}

	public function classDecl(c:ClassDecl):String {
		var b = new StringBuf();
		var tps = types != null && c.tparams != null ? c.tparams : null;
		// (a static's: without the class's type parameters, which TypeScript does not let it name)
		var outer = types == null ? null : types.scope;
		return withParams(tps, () -> {
			b.add((types != null && c.isAbstract == true ? "abstract " : "") + "class " + c.name.name);
			if (tps != null) b.add(types.params(tps));
			if (c.superClass != null) {
				b.add(" extends " + paren(c.superClass, CALL));
				if (types != null && c.superArgs != null && c.superArgs.length > 0) b.add("<" + [for (t in c.superArgs) types.type(t)].join(", ") + ">");
			}
			if (c.members.length == 0) {
				b.add(sp(" {}"));
				return b.toString();
			}
			b.add(sp(" {") + nl());
			indent++;
			var t = tabs(indent);
			for (m in c.members) {
				var inner = types == null ? null : types.scope;
				if (types != null && isStatic(m)) types.scope = outer;
				member(b, m, t, "");
				if (types != null) types.scope = inner;
			}
			indent--;
			b.add(tabs(indent) + "}");
			return b.toString();
		});
	}

	static function isStatic(m:Member):Bool return switch m {
		case MField(_, _, s, _) | MMethod(_, _, s, _) | MDeclare(_, _, s): s;
		case MStaticBlock(_): true;
		case MProtected(m): isStatic(m);
		case _: false;
	}

	function member(b:StringBuf, m:Member, t:String, mods:String) {
		switch m {
			case MField(k, v, isStatic, type):
				var ty = types == null || type == null ? "" : ": " + types.type(type);
				b.add(t + mods + (isStatic ? "static " : "") + key(k, v == null ? null : v.pos) + ty + (v == null ? "" : sp(" = ") + expr(v, ASSIGN)) + ";" + nl());
			case MMethod(k, f, isStatic, kind):
				var head = (isStatic ? "static " : "") + switch kind {
					case MkConstructor: "constructor";
					case MkGet: "get " + key(k, f.pos);
					case MkSet: "set " + key(k, f.pos);
					case MkMethod: key(k, f.pos);
				}
				b.add(t + mods + head + withParams(f.tparams, () -> signature(f, kind != MkConstructor && kind != MkSet) + sp(" ") + blockString(f.body)) + nl());
			case MStaticBlock(body):
				b.add(t + "static" + sp(" ") + blockString(body) + nl());
			case MComment(text):
				if (!tight) for (l in text.split("\n")) b.add(t + "// " + l + "\n");
			case MDeclare(k, type, isStatic):
				if (types != null) b.add(t + mods + "declare " + (isStatic ? "static " : "") + key(k) + ": " + types.type(type) + ";" + nl());
			case MAbstract(k, type, tparams):
				if (types != null) b.add(t + mods + "abstract " + key(k) + withParams(tparams, () -> types.params(tparams) + types.signature(type)) + ";" + nl());
			case MProtected(inner):
				member(b, inner, t, types == null ? mods : mods + "protected ");
		}
	}

	public static function quote(s:String):String return "\"" + core.StringHelper.sEscape(s) + "\"";
}
