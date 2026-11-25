package hxmc.es;

import core.Globals;
import core.Globals.*;
import core.TType;
import core.TFunctions.*;
import core.Meta;
import core.Error;
import generators.Gctx;
import haxe.ds.StringMap;

using core.ds.VectorTools;

// The split points of a program (`js.Bundle.split(name, init)`, hxmc's std,
// hxmc/portable/js/Bundle.hx) and the chunks they make: which types each
// output file defines.
//
// The splits of one name make one chunk, with an initializer per call. A
// chunk's code is its initializers and the types they reach (through the
// code of types, not through other splits); main's is the main expression
// and the types it reaches, the types the generated code always uses
// (js.Boot, HxOverrides, ...) and the exposed ones. Chunk B is loaded by A
// when A's code calls a split of B. The chunks form a tree, by dominance:
// a chunk's parent is the chunk that every way of loading it loads before
// it (main, if nothing else). A type goes into the nearest common ancestor
// of the chunks whose code reaches it: when any of them runs, that one has
// run, so each type is defined once, and a chunk finds what it uses in
// itself or in the chunks above it (shared types are pulled up, rather than
// into a common chunk of their own). A type no code reaches (kept, or used
// by reflection only) goes into main.
class Splits {
	public final main:SplitChunk;
	public final chunks:Array<SplitChunk> = [];
	public final splits:Array<SplitPoint> = [];
	public final types:Array<TypeInfo> = [];

	final byKey = new StringMap<TypeInfo>();
	final byName = new StringMap<SplitChunk>();
	final com:Gctx;

	// the types the generated code refers to by name without the typed tree
	// naming them (Genjs's helpers, the casts and iterators)
	static final ALWAYS_MAIN = [
		"js.Bundle", "js.Boot", "HxOverrides", "Std", "haxe.iterators.ArrayIterator", "haxe.iterators.ArrayKeyValueIterator", "js._Boot.HaxeError",
		"haxe.Exception", "haxe.ValueException", "haxe.NativeStackTrace", "String", "Array", "Math"
	];

	public function new(com:Gctx) {
		this.com = com;
		main = new SplitChunk(0, null);
		chunks.push(main);
		for (t in com.types) {
			var info = new TypeInfo(t, types.length);
			types.push(info);
			byKey.set(info.key, info);
		}
		for (info in types) scanType(info);
		if (com.main.mainExpr != null) scan(com.main.mainExpr, main.roots, main.calls, com.main.mainExpr);
		if (splits.length == 0) return;
		for (k in ALWAYS_MAIN) if (byKey.exists(k)) main.roots.push(byKey.get(k));
		// (and the types whose `__init__` runs code the references do not show: raw JS, untyped
		// names; it runs at startup, unsplit, and may set up anything)
		// (and @:jsRequire externs: `require` is the main file's, a classic script's, not a split file's, a module's)
		for (t in types) if (exposed(t) || t.opaqueInit || required(t)) main.roots.push(t);
		for (c in chunks) reach(c);
		// (a type no code reaches is main's, with what it uses)
		var orphans = [for (t in types) if (t.users.length == 0) t];
		if (orphans.length > 0) {
			for (t in orphans) main.roots.push(t);
			reach(main);
		}
		dominators();
		place();
		settle();
	}

	public inline function hasSplits():Bool return splits.length > 0;

	public function info(t:ModuleType):Null<TypeInfo> return byKey.get(keyOf(t));

	static function keyOf(t:ModuleType):String return sTypePath(tPath(t));

	// --- the references of the code ---

	function scanType(info:TypeInfo) {
		switch info.t {
			case TClassDecl(c):
				if (c.clSuper != null) addRef(info.refs, c.clSuper.cls);
				for (i in c.clImplements) addRef(info.refs, i.cls);
				function field(f:TClassField) {
					if (f.cfExpr != null) scan(f.cfExpr, info.refs, info.calls, f.cfExpr);
					for (o in f.cfOverloads) field(o);
				}
				if (c.clConstructor != null) field(c.clConstructor);
				if (c.clInit != null && c.clInit.cfExpr != null) {
					var e = c.clInit.cfExpr;
					scan(e, info.refs, info.calls, e);
					touched(e, info);
					info.opaqueInit = opaque(e);
				}
				for (f in c.clFields) field(f);
				for (f in c.clStatics) field(f);
			case TEnumDecl(_) | TTypeDecl(_) | TAbstractDecl(_):
		}
	}

	function addRef(refs:Array<TypeInfo>, c:TClass) {
		var i = byKey.get(sTypePath(c.clPath));
		if (i != null && i.t.match(TClassDecl(_)) && refs.indexOf(i) < 0) refs.push(i);
	}

	function addRefT(refs:Array<TypeInfo>, t:ModuleType) {
		var i = byKey.get(keyOf(t));
		if (i != null && refs.indexOf(i) < 0) refs.push(i);
	}

	// the types e refers to, into refs, and the splits it calls, into calls
	// (root: the expression of the field, where captured locals must stay
	// unassigned)
	function scan(e:TExpr, refs:Array<TypeInfo>, calls:Array<SplitPoint>, root:TExpr) {
		function loop(e:TExpr) {
			switch e.eexpr {
				case TCall({eexpr: TField(_, FStatic({clPath: {pack: ["js"], name: "Bundle"}}, {cfName: "split"}))}, args):
					calls.push(makeSplit(e, args, root));
					return;
				case TField(_, FStatic({clPath: {pack: ["js"], name: "Bundle"}}, {cfName: "split"})):
					Error.abort("js.Bundle.split can only be called directly", e.epos);
				case TTypeExpr(t):
					addRefT(refs, t);
				case TNew(c, _, _):
					addRef(refs, c);
				case TField(_, FStatic(c, _)):
					addRef(refs, c);
				case TField(_, FEnum(en, _)):
					addRefT(refs, TEnumDecl(en));
				case TCast(_, t) if (t != null):
					addRefT(refs, t);
				// (Genjs's trace: haxe.Log.trace when the program sets it)
				case TIdent("`trace"):
					var log = byKey.get("haxe.Log");
					if (log != null && refs.indexOf(log) < 0) refs.push(log);
				case _:
			}
			core.Texpr.iter(loop, e);
		}
		loop(e);
	}

	function makeSplit(e:TExpr, args:haxe.ds.Vector<TExpr>, root:TExpr):SplitPoint {
		if (args.length != 2) Error.abort("js.Bundle.split: two arguments expected", e.epos);
		var name = switch unwrap(args[0]).eexpr {
			case TConst(TString(s)): s;
			case _: Error.abort("js.Bundle.split: the name must be a constant string", args[0].epos);
		}
		var fn = switch unwrap(args[1]).eexpr {
			case TFunction(f): f;
			case _: Error.abort("js.Bundle.split: the initializer must be a function literal", args[1].epos);
		}
		if (fn.tfArgs.length != 0) Error.abort("js.Bundle.split: the initializer takes no arguments", args[1].epos);
		var chunk = byName.get(name);
		if (chunk == null) {
			chunk = new SplitChunk(chunks.length, name);
			chunks.push(chunk);
			byName.set(name, chunk);
		}
		var s = new SplitPoint(splits.length, chunk.splits.length, name, e, fn, chunk);
		splits.push(s);
		chunk.splits.push(s);
		s.captures = captures(fn, root);
		scan(fn.tfExpr, chunk.roots, chunk.calls, root);
		return s;
	}

	static function unwrap(e:TExpr):TExpr return switch e.eexpr {
		case TParenthesis(e) | TMeta(_, e) | TCast(e, null): unwrap(e);
		case _: e;
	}

	// the locals of the enclosing code that fn uses (in the order they are
	// first used); each must never be assigned once declared, as the
	// initializer may run later, in another file, with copies of their values
	static function captures(fn:TFunc, root:TExpr):Array<TVar> {
		var declared = new Map<Int, Bool>(), used:Array<TVar> = [], seen = new Map<Int, Bool>();
		function declare(v:TVar) declared.set(v.vId, true);
		function loop(e:TExpr) {
			switch e.eexpr {
				case TVar(v, _):
					declare(v);
				case TFunction(f):
					for (a in f.tfArgs) declare(a.variable);
				case TTry(_, catches):
					for (c in catches) declare(c.variable);
				case TLocal(v) if (!declared.exists(v.vId) && !seen.exists(v.vId)):
					seen.set(v.vId, true);
					used.push(v);
				case _:
			}
			core.Texpr.iter(loop, e);
		}
		loop(fn.tfExpr);
		// (a local of fn used before its declaration, in a loop: not a capture)
		used = used.filter(v -> !declared.exists(v.vId));
		// (a final is assigned once, before any use: the typer checks it)
		var checked = used.filter(v -> !hasVarFlag(v, VFinal));
		if (checked.length > 0) {
			var ids = new Map<Int, TVar>();
			for (v in checked) ids.set(v.vId, v);
			function assigned(e:TExpr) {
				switch e.eexpr {
					case TBinop(OpAssign | OpAssignOp(_), {eexpr: TLocal(v)}, _) | TUnop(Increment | Decrement, _, {eexpr: TLocal(v)}) if (ids.exists(v.vId)):
						Error.abort("js.Bundle.split: the initializer captures " + v.vName + ", which is assigned here: it may only capture locals that never change", e.epos);
					case TVar(v, null) if (ids.exists(v.vId)):
						Error.abort("js.Bundle.split: the initializer captures " + v.vName + ", which is declared without a value: it may only capture locals that never change", e.epos);
					case _:
				}
				core.Texpr.iter(assigned, e);
			}
			assigned(root);
		}
		return used;
	}

	static function required(t:TypeInfo):Bool return switch t.t {
		case TClassDecl(c): hasClassFlag(c, CExtern) && Meta.has(Meta.JsRequire, c.clMeta);
		case TEnumDecl(e): hasEnumFlag(e, EnExtern) && Meta.has(Meta.JsRequire, e.eMeta);
		case _: false;
	};

	// the types an `__init__` acts on, into info.initRefs: those it takes as values (a class
	// whose prototype it patches, which it reflects on or registers) and those whose statics it
	// assigns; not those whose functions it only calls (helpers)
	function touched(e:TExpr, info:TypeInfo) {
		function add(t:ModuleType) {
			var i = byKey.get(keyOf(t));
			if (i != null && i != info && info.initRefs.indexOf(i) < 0) info.initRefs.push(i);
		}
		function loop(e:TExpr) {
			switch e.eexpr {
				case TTypeExpr(t):
					add(t);
				case TBinop(OpAssign | OpAssignOp(_), {eexpr: TField(_, FStatic(c, _))}, v):
					add(TClassDecl(c));
					loop(v);
					return;
				// (a static's class as the receiver of its access: not a value)
				case TField({eexpr: TTypeExpr(_)}, FStatic(_, _) | FEnum(_, _)):
					return;
				case _:
			}
			core.Texpr.iter(loop, e);
		}
		loop(e);
	}

	// whether an `__init__` runs code whose dependencies its references do not show
	static function opaque(e:TExpr):Bool {
		var found = false;
		function loop(e:TExpr) {
			switch e.eexpr {
				case TIdent(s) if (s != "`trace"):
					found = true;
				case TCall({eexpr: TField(_, FStatic({clPath: {pack: ["js"], name: "Syntax"}}, {cfName: "code" | "plainCode"}))}, _):
					found = true;
				case _:
			}
			if (!found) core.Texpr.iter(loop, e);
		}
		loop(e);
		return found;
	}

	function exposed(t:TypeInfo):Bool return switch t.t {
		case TClassDecl(c):
			Meta.has(Meta.Expose, c.clMeta) || Lambda.exists(c.clStatics, f -> Meta.has(Meta.Expose, f.cfMeta));
		case _: false;
	};

	// --- the chunks ---

	// the types c's code reaches, and the chunks it loads
	function reach(c:SplitChunk) {
		var seen = new Map<Int, Bool>(), stack = c.roots.copy();
		while (stack.length > 0) {
			var t = stack.pop();
			if (seen.exists(t.index)) continue;
			seen.set(t.index, true);
			if (t.users.indexOf(c) < 0) t.users.push(c);
			for (r in t.refs) stack.push(r);
			for (s in t.calls) if (c.loads.indexOf(s.chunk) < 0) c.loads.push(s.chunk);
		}
		for (s in c.calls) if (c.loads.indexOf(s.chunk) < 0) c.loads.push(s.chunk);
	}

	// each chunk's parent: its immediate dominator in the graph of loads
	// from main (Cooper, Harvey and Kennedy's iteration over the reverse
	// postorder); a chunk main does not reach (its calls are in code that
	// never runs) under main
	function dominators() {
		var order = [], visited = new Map<Int, Bool>();
		function dfs(c:SplitChunk) {
			visited.set(c.id, true);
			for (k in c.loads) if (!visited.exists(k.id)) dfs(k);
			order.push(c);
		}
		dfs(main);
		order.reverse();
		var rpo = new Map<Int, Int>();
		for (i in 0...order.length) rpo.set(order[i].id, i);
		var preds = new Map<Int, Array<SplitChunk>>();
		for (c in order) for (k in c.loads) {
			if (!preds.exists(k.id)) preds.set(k.id, []);
			preds.get(k.id).push(c);
		}
		var idom = new Map<Int, SplitChunk>();
		idom.set(main.id, main);
		function intersect(a:SplitChunk, b:SplitChunk):SplitChunk {
			while (a != b) {
				while (rpo.get(a.id) > rpo.get(b.id)) a = idom.get(a.id);
				while (rpo.get(b.id) > rpo.get(a.id)) b = idom.get(b.id);
			}
			return a;
		}
		var changed = true;
		while (changed) {
			changed = false;
			for (c in order) {
				if (c == main) continue;
				var d:Null<SplitChunk> = null;
				for (p in preds.get(c.id)) if (idom.exists(p.id)) d = d == null ? p : intersect(p, d);
				if (idom.get(c.id) != d) {
					idom.set(c.id, d);
					changed = true;
				}
			}
		}
		for (c in chunks) {
			if (c == main) continue;
			c.parent = idom.exists(c.id) ? idom.get(c.id) : main;
			c.parent.children.push(c);
		}
		function depth(c:SplitChunk, d:Int) {
			c.depth = d;
			for (k in c.children) depth(k, d + 1);
		}
		depth(main, 0);
	}

	static function lca(a:SplitChunk, b:SplitChunk):SplitChunk {
		while (a.depth > b.depth) a = a.parent;
		while (b.depth > a.depth) b = b.parent;
		while (a != b) {
			a = a.parent;
			b = b.parent;
		}
		return a;
	}

	function place() {
		for (c in chunks) c.types.resize(0);
		for (t in types) {
			var c = t.users.length == 0 ? main : t.users[0];
			for (u in t.users) c = lca(c, u);
			t.chunk = c;
			c.types.push(t);
		}
	}

	// A type's `__init__` runs when its chunk loads, before the chunk's code: it must be a chunk
	// that is loaded no later than those of the types the `__init__` acts on (touched), so that it runs
	// before their code does (e.g. it intercepts their methods before they are bound). A type
	// whose chunk is below one of theirs moves up to their common ancestor, as reached from
	// there, with what it uses; until nothing moves (types only move up).
	function settle() {
		var moved = true;
		while (moved) {
			moved = false;
			for (t in types) if (t.initRefs.length > 0) {
				var k = t.chunk;
				for (r in t.initRefs) k = lca(k, r.chunk);
				if (k == t.chunk) continue;
				k.roots.push(t);
				reach(k);
				moved = true;
			}
			if (!moved) break;
			// (the moved code may call splits from higher up: the tree may change)
			for (c in chunks) {
				c.parent = null;
				c.children.resize(0);
			}
			dominators();
			place();
		}
	}

	// each chunk's imports (the names, in the generated code, of the types of
	// the chunks above it that its code uses) and exports (those of its own
	// types that the chunks below it use); namesOf: the names a type's code
	// defines (none for a type that generates nothing)
	public function link(namesOf:ModuleType->Array<String>) {
		// (anew: a build may link twice, its names differing, as -D hxmc.js.minify=aside does)
		for (c in chunks) {
			c.imports.resize(0);
			c.exports.resize(0);
			c.exported.clear();
			c.used.clear();
		}
		var always = [for (k in ALWAYS_MAIN) if (byKey.exists(k)) byKey.get(k)];
		for (c in chunks) {
			if (c == main) continue;
			var uses = c.roots.copy(), seen = new Map<Int, Bool>();
			for (t in c.types) for (r in t.refs) uses.push(r);
			for (a in always) uses.push(a);
			for (u in uses) {
				if (u.chunk == c || seen.exists(u.index)) continue;
				seen.set(u.index, true);
				if (namesOf(u.t).length == 0) continue;
				if (!c.sees(u.chunk)) throw 'hxmc.js: ${u.key} is used in chunk ${c.name} but defined in one that does not load it';
				u.chunk.exported.set(u.index, u);
				for (n in namesOf(u.t)) c.used.set(n, true);
			}
		}
		for (c in chunks) {
			var ts = [for (t in c.exported) t];
			ts.sort((a, b) -> a.index - b.index);
			for (t in ts) for (n in namesOf(t.t)) c.exports.push(n);
		}
		// (a chunk imports every name above it: the scope its code had,
		// unsplit; unused ones cost an assignment each)
		for (c in chunks) {
			if (c == main) continue;
			var k = c.parent, above = [];
			while (k != null) {
				above.unshift(k);
				k = k.parent;
			}
			for (a in above) for (n in a.exports) c.imports.push(n);
		}
	}
}

class TypeInfo {
	public final t:ModuleType;
	public final index:Int;
	public final key:String;
	public final refs:Array<TypeInfo> = [];
	// the types its `__init__` acts on (touched), and whether it runs code its references do not show
	public final initRefs:Array<TypeInfo> = [];
	public var opaqueInit = false;
	// the splits its code calls
	public final calls:Array<SplitPoint> = [];
	// the chunks whose code reaches it
	public final users:Array<SplitChunk> = [];
	public var chunk:Null<SplitChunk>;

	public function new(t:ModuleType, index:Int) {
		this.t = t;
		this.index = index;
		key = sTypePath(tPath(t));
	}
}

class SplitPoint {
	public final id:Int;
	// its index among its chunk's initializers
	public final index:Int;
	public final name:String;
	public final call:TExpr;
	public final fn:TFunc;
	public final chunk:SplitChunk;
	public var captures:Array<TVar> = [];

	public function new(id, index, name, call, fn, chunk) {
		this.id = id;
		this.index = index;
		this.name = name;
		this.call = call;
		this.fn = fn;
		this.chunk = chunk;
	}
}

class SplitChunk {
	public final id:Int;
	// its splits' name (main: null)
	public final name:Null<String>;
	public final splits:Array<SplitPoint> = [];
	// the types its initializers (main: the main expression and the types main
	// always has) refer to, and the splits they call
	public final roots:Array<TypeInfo> = [];
	public final calls:Array<SplitPoint> = [];
	// the chunks its code loads
	public final loads:Array<SplitChunk> = [];
	public var parent:Null<SplitChunk>;
	public final children:Array<SplitChunk> = [];
	public var depth = 0;
	public final types:Array<TypeInfo> = [];
	// the names it takes from the chunks above it, and gives the ones below
	public final imports:Array<String> = [];
	public final exports:Array<String> = [];
	public final exported = new Map<Int, TypeInfo>();
	// the names of the chunks above it that its own code uses (of all it could take)
	public final used = new Map<String, Bool>();
	// its code, its calls of splits as placeholders (Bundled), and its file
	public var code:Null<String>;
	public var file:Null<String>;

	public function new(id, name) {
		this.id = id;
		this.name = name;
	}

	// whether c is this chunk or one above it
	public function sees(c:SplitChunk):Bool {
		var k = this;
		while (k != null) {
			if (k == c) return true;
			k = k.parent;
		}
		return false;
	}
}
