package hxmc;

import core.Ast;

// The interface of a parsed module, as a hash (the module cache's early
// cutoff, ModuleCache.hx): its declarations as parsed (the conditions
// evaluated) without what its users cannot see of them, the bodies of the
// functions whose type is written out: not inline, not a macro, not
// @:generic (nor in a @:generic class: an instance copies the bodies), the
// arguments and the return type given (a constructor returns Void), in a
// class without build macros (@:build, @:autoBuild, @:genericBuild, which
// may read them). Everything else is in it: names, access, metadata, types,
// the other bodies (inline functions are copied into their callers), the
// initial values of variables and properties, the arguments' default
// values. Positions are not, except those of the expressions it keeps: an
// inlined body keeps its positions in the caller (an edit before it that
// changes its offsets changes the interface). Documentation is not.
class ModuleInterface {
	final b = new StringBuf();
	var keepPos = false;

	function new() {}

	public static function hash(decls:haxe.ds.Vector<TypeDecl>):String {
		var w = new ModuleInterface();
		for (d in decls)
			w.decl(d);
		// (two 64-bit hashes of the text)
		var text = w.b.toString();
		return Fingerprint.hash(text) + Fingerprint.hash("i" + text);
	}

	static function hasMeta(meta:Metadata, names:Array<core.MetaList.StrictMeta>):Bool {
		for (n in names)
			if (core.Meta.has(n, meta)) return true;
		return false;
	}

	static final BUILD:Array<core.MetaList.StrictMeta> = [Build, AutoBuild, GenericBuild, Generic, MultiType, Remove];

	function decl(d:TypeDecl) {
		switch d.definition {
			case EClass(c):
				b.add("C");
				typeHead(c.name, c.params, c.meta);
				b.add("[");
				for (f in c.flags)
					switch f {
						case HExtends(p):
							b.add("x");
							placedTypePath(p);
						case HImplements(p):
							b.add("m");
							placedTypePath(p);
						case _:
							index(f);
					}
				b.add("]");
				var strip = !hasMeta(c.meta, BUILD);
				for (f in c.data)
					field(f.cffName.name, [for (a in f.cffAccess) a.access], f.cffMeta, f.cffKind, strip);
			case EAbstract(a):
				b.add("A");
				typeHead(a.name, a.params, a.meta);
				b.add("[");
				for (f in a.flags)
					switch f {
						case AbFrom(t):
							b.add("f");
							typeHint(t);
						case AbTo(t):
							b.add("t");
							typeHint(t);
						case AbOver(t):
							b.add("o");
							typeHint(t);
						case _:
							index(f);
					}
				b.add("]");
				var strip = !hasMeta(a.meta, BUILD);
				for (f in a.data)
					field(f.cffName.name, [for (x in f.cffAccess) x.access], f.cffMeta, f.cffKind, strip);
			case EStatic(s):
				b.add("S");
				typeHead(s.name, s.params, s.meta);
				field(s.name.name, [for (x in s.flags) x.access], s.meta, s.data, true);
			case EEnum(e):
				// (enums, typedefs, imports, usings: all of it)
				b.add("E");
				placedName(e.name);
				typeParams(e.params);
				metadata(e.meta);
				b.add("[");
				for (f in e.flags)
					index(f);
				b.add("]");
				for (c in e.data) {
					b.add("\n|");
					placedName(c.ecName);
					metadata(c.ecMeta);
					b.add("(");
					for (a in c.ecArgs) {
						str(a.name);
						bool(a.optional);
						typeHint(a.type);
					}
					b.add(")");
					pos(c.ecPos);
					typeParams(c.ecParams);
					typeHint(c.ecType);
				}
			case ETypedef(t):
				b.add("T");
				placedName(t.name);
				typeParams(t.params);
				metadata(t.meta);
				b.add("[");
				for (f in t.flags)
					index(f);
				b.add("]");
				typeHint(t.data);
			case EImport(i):
				b.add("I");
				placedNames(i.path);
				switch i.mode {
					case INormal:
						b.add("n");
					case IAsName(n):
						b.add("a");
						placedName(n);
					case IAll:
						b.add("*");
				}
			case EUsing(path):
				b.add("U");
				placedNames(path);
		}
		b.add(";\n");
	}

	function typeHead(name:PlacedName, params:haxe.ds.Vector<TypeParam>, meta:Metadata) {
		b.add(name.name);
		typeParams(params);
		metadata(meta);
	}

	function field(name:String, access:Array<Access>, meta:Metadata, kind:ClassFieldKind, strip:Bool) {
		b.add("\n.");
		b.add(name);
		accesses(access);
		metadata(meta);
		switch kind {
			case FFun(f) if (f.fExpr != null && strip && strippable(name, access, meta, f)):
				b.add("F");
				typeParams(f.fParams);
				funcArgs(f.fArgs);
				typeHint(f.fType);
				b.add("{}");
			case FFun(f):
				b.add("F");
				typeParams(f.fParams);
				funcArgs(f.fArgs);
				typeHint(f.fType);
				kept(f.fExpr);
			case FVar(t, e):
				b.add("V");
				typeHint(t);
				kept(e);
			case FProp(get, set, t, e):
				b.add("P");
				placedName(get);
				placedName(set);
				typeHint(t);
				kept(e);
		}
	}

	static final KEEPS_BODY:Array<core.MetaList.StrictMeta> = [Generic, Extern, Build];

	static function strippable(name:String, access:Array<Access>, meta:Metadata, f:Func):Bool {
		if (access.indexOf(AInline) >= 0 || access.indexOf(AMacro) >= 0 || access.indexOf(AExtern) >= 0) return false;
		if (hasMeta(meta, KEEPS_BODY)) return false;
		if (f.fType == null && name != "new") return false;
		for (a in f.fArgs)
			if (a.type == null) return false;
		return true;
	}

	// an expression it keeps: with its positions
	function kept(e:Null<Expr>) {
		var k = keepPos;
		keepPos = true;
		expr(e);
		keepPos = k;
	}

	// the syntax tree, positions only where they are kept, no documentation

	inline function index(e:EnumValue) {
		b.add("e");
		b.add(e.getIndex());
	}

	inline function bool(x:Bool)
		b.add(x ? "t" : "f");

	function str(s:String) {
		b.add("s");
		b.add(s.length);
		b.add(":");
		b.add(s);
	}

	function optStr(s:Null<String>)
		if (s == null) b.add("n") else str(s);

	function pos(p:core.Globals.Pos)
		if (keepPos) {
			b.add("@");
			b.add(p.pmin);
			b.add("-");
			b.add(p.pmax);
		}

	function placedName(n:PlacedName) {
		str(n.name);
		pos(n.pos);
	}

	function placedNames(l:haxe.ds.Vector<PlacedName>) {
		b.add("[");
		for (n in l)
			placedName(n);
		b.add("]");
	}

	function accesses(l:Array<Access>) {
		b.add("[");
		for (a in l)
			index(a);
		b.add("]");
	}

	function placedAccesses(l:Array<PlacedAccess>) {
		b.add("[");
		for (a in l) {
			index(a.access);
			pos(a.pos);
		}
		b.add("]");
	}

	function metadata(ml:Metadata) {
		b.add("[");
		for (m in ml) {
			b.add("#");
			switch (m.meta : core.MetaList.StrictMeta) {
				case Custom(s):
					str(s);
				case x:
					index(x);
			}
			exprs(m.exprs);
			pos(m.pos);
		}
		b.add("]");
	}

	function typePath(t:TypePath) {
		b.add("[");
		for (p in t.tpackage)
			str(p);
		b.add("]");
		str(t.tname);
		b.add("<");
		for (p in t.tparams)
			switch p {
				case TPType(t):
					b.add("t");
					typeHint(t);
				case TPExpr(e):
					b.add("x");
					expr(e);
			}
		b.add(">");
		optStr(t.tsub);
	}

	function placedTypePath(p:PlacedTypePath) {
		typePath(p.path);
		pos(p.posFull);
		pos(p.posPath);
	}

	function typeHint(t:Null<TypeHint>) {
		if (t == null) {
			b.add("n");
			return;
		}
		complexType(t.type);
		pos(t.pos);
	}

	function typeHints(l:haxe.ds.Vector<TypeHint>) {
		b.add("[");
		for (t in l)
			typeHint(t);
		b.add("]");
	}

	function complexType(ct:ComplexType) {
		switch ct {
			case CTPath(p):
				b.add("P");
				placedTypePath(p);
			case CTFunction(args, ret):
				b.add("F");
				typeHints(args);
				typeHint(ret);
			case CTAnonymous(fields):
				b.add("A");
				classFields(fields);
			case CTParent(t):
				b.add("(");
				typeHint(t);
			case CTExtend(paths, fields):
				b.add("X[");
				for (p in paths)
					placedTypePath(p);
				b.add("]");
				classFields(fields);
			case CTOptional(t):
				b.add("?");
				typeHint(t);
			case CTNamed(n, t):
				b.add("N");
				placedName(n);
				typeHint(t);
			case CTIntersection(l):
				b.add("&");
				typeHints(l);
		}
	}

	// (a structure's fields: all of them)
	function classFields(l:haxe.ds.Vector<ClassField>) {
		b.add("{");
		for (f in l) {
			placedName(f.cffName);
			pos(f.cffPos);
			metadata(f.cffMeta);
			placedAccesses(f.cffAccess);
			switch f.cffKind {
				case FFun(fn):
					b.add("F");
					func(fn);
				case FVar(t, e):
					b.add("V");
					typeHint(t);
					expr(e);
				case FProp(get, set, t, e):
					b.add("P");
					placedName(get);
					placedName(set);
					typeHint(t);
					expr(e);
			}
		}
		b.add("}");
	}

	function typeParams(l:haxe.ds.Vector<TypeParam>) {
		b.add("<");
		for (p in l) {
			placedName(p.tpName);
			typeParams(p.tpParams);
			typeHint(p.tpConstraints);
			typeHint(p.tpDefault);
			metadata(p.tpMeta);
		}
		b.add(">");
	}

	function funcArgs(l:haxe.ds.Vector<FuncArg>) {
		b.add("(");
		for (a in l) {
			placedName(a.name);
			bool(a.optional);
			metadata(a.meta);
			typeHint(a.type);
			expr(a.expr);
		}
		b.add(")");
	}

	function func(f:Func) {
		typeParams(f.fParams);
		funcArgs(f.fArgs);
		typeHint(f.fType);
		expr(f.fExpr);
	}

	function constant(c:Constant) {
		switch c {
			case Int(v, s):
				b.add("I");
				str(v);
				optStr(s);
			case Float(v, s):
				b.add("F");
				str(v);
				optStr(s);
			case String(v, k):
				b.add("S");
				str(v);
				index(k);
			case Ident(v):
				b.add("D");
				str(v);
			case Regexp(r, o):
				b.add("R");
				str(r);
				str(o);
		}
	}

	function exprs(l:haxe.ds.Vector<Expr>) {
		b.add("[");
		for (e in l)
			expr(e);
		b.add("]");
	}

	function expr(e:Null<Expr>) {
		if (e == null) {
			b.add("n");
			return;
		}
		b.add("(");
		var d = e.expr;
		b.add(d.getIndex());
		switch d {
			case EConst(c):
				constant(c);
			case EArray(a, i):
				expr(a);
				expr(i);
			case EBinop(op, l, r):
				binop(op);
				expr(l);
				expr(r);
			case EField(x, f, k):
				expr(x);
				str(f);
				index(k);
			case EParenthesis(x) | EUntyped(x) | EThrow(x):
				expr(x);
			case EObjectDecl(fields):
				b.add("{");
				for (f in fields) {
					str(f.key.name);
					pos(f.key.pos);
					index(f.key.quote);
					expr(f.expr);
				}
				b.add("}");
			case EArrayDecl(l) | EBlock(l):
				exprs(l);
			case ECall(x, args):
				expr(x);
				exprs(args);
			case ENew(p, args):
				placedTypePath(p);
				exprs(args);
			case EUnop(op, flag, x):
				index(op);
				index(flag);
				expr(x);
			case EVars(vars):
				b.add("[");
				for (v in vars) {
					placedName(v.evName);
					bool(v.evFinal);
					bool(v.evStatic);
					typeHint(v.evType);
					expr(v.evExpr);
					metadata(v.evMeta);
				}
				b.add("]");
			case EFunction(kind, f):
				switch kind {
					case FKAnonymous:
						b.add("a");
					case FKNamed(n, inl):
						b.add("n");
						placedName(n);
						bool(inl);
					case FKArrow:
						b.add("r");
				}
				func(f);
			case EFor(it, body):
				expr(it);
				expr(body);
			case EIf(c, t, el):
				expr(c);
				expr(t);
				expr(el);
			case EWhile(c, body, flag):
				expr(c);
				expr(body);
				index(flag);
			case ESwitch(x, cases, def):
				expr(x);
				b.add("[");
				for (c in cases) {
					exprs(c.values);
					expr(c.guard);
					expr(c.expr);
					pos(c.pos);
				}
				b.add("]");
				if (def == null) b.add("n") else {
					b.add("d");
					expr(def.expr);
					pos(def.pos);
				}
			case ETry(x, catches):
				expr(x);
				b.add("[");
				for (c in catches) {
					placedName(c.name);
					typeHint(c.type);
					expr(c.expr);
					pos(c.pos);
				}
				b.add("]");
			case EReturn(x):
				expr(x);
			case EBreak | EContinue:
			case ECast(x, t):
				expr(x);
				typeHint(t);
			case EIs(x, t) | ECheckType(x, t):
				expr(x);
				typeHint(t);
			case EDisplay(x, k):
				expr(x);
				switch k {
					case DKPattern(o):
						b.add("p");
						bool(o);
					case _:
						index(k);
				}
			case ETernary(c, t, el):
				expr(c);
				expr(t);
				expr(el);
			case EMeta(m, x):
				metadata([m]);
				expr(x);
		}
		pos(e.pos);
		b.add(")");
	}

	function binop(op:Binop)
		switch op {
			case OpAssignOp(o):
				b.add("=");
				binop(o);
			case _:
				index(op);
		}
}
