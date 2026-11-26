package hxmc.es;

import core.Globals.Pos;
import core.TType;

// JavaScript (ES2022), nothing else: what the generator decides is in the tree, the printer only writes it
// (docs/plans/esgen.md). Bindings are symbols (Sym), named once the whole output is known (Chunk). What a lowering
// cannot know from its own code (which binding a type has in the output, which renaming a field's name takes) it leaves
// to the program as a whole: a reference (Ref), a namespace (Ns), which Chunk resolves as it prints.

// a binding: a local, a type, a module-level field, the runtime's, a global
class Sym {
	public final kind:SymKind;
	// the name it would like (a local's, a type's own)
	public final hint:String;
	// the name it has in the output (Chunk), the hint until then
	public var name:String;
	// (a local's) its Haxe type, which TypeScript's output declares it with
	public var type:Null<T> = null;

	public function new(kind, hint) {
		this.kind = kind;
		this.hint = hint;
		this.name = hint;
	}

	public function toString() return name;
}

enum SymKind {
	SLocal;
	SType(t:ModuleType);
	// a module-level field (Haxe 5's module fields)
	SModuleField(m:ModuleDef, f:TClassField);
	// a name of the runtime (`$hx`), fixed
	SRuntime;
	// a global (an extern's native path, an untyped name), fixed
	SGlobal;
}

@:structInit class Ex {
	public var def:ExDef;
	public var pos:Null<Pos>;

	public inline function new(def, ?pos) {
		this.def = def;
		this.pos = pos;
	}
}

// what a reference names, as the program as a whole has it (Chunk.refEx): a binding, a global path, the runtime's
enum Ref {
	// a type as a value: its binding, an npm module's (@:jsRequire), an extern's native path, the runtime's (`$hx.Int`)
	RType(t:ModuleType);
	// a type of the program by its path (js.Boot)
	RPath(path:String);
	// an untyped name: a type by Genjs's name for it (flat), else a global path
	RIdent(name:String);
	RModuleField(m:ModuleDef, f:TClassField);
	// a split's key in the runtime's table (its name, its number minified)
	RSplitKey(name:String);
	// (TypeScript) the binding of `$hx.index`
	RIndex;
}

// the namespace a field's name is renamed in (FieldNames, -D hxmc.js.minify.fields): a class family's instances', its
// statics', an enum's constructors', their parameters'; NGlobal: the global one
enum Ns {
	NGlobal;
	NInstance(c:TClass);
	NStatic(c:TClass);
	NStaticPath(path:String);
	NEnumCtor(e:TEnum);
	NEnumParam(e:TEnum);
	// (the parameters' of the enum a constructor is of)
	NCtorParam(ef:TEnumField);
}

enum ExDef {
	EId(s:Sym);
	// a binding the program as a whole decides (Ref)
	ERef(r:Ref);
	EThis;
	ESuper;
	ENull;
	EUndefined;
	EBool(b:Bool);
	ENum(s:String);
	EStr(s:String);
	EArray(items:Array<Ex>);
	EObject(props:Array<Prop>);
	EFn(f:Fn);
	EClass(c:ClassDecl);
	// o.name (name a valid identifier: Lower makes others EIndex)
	EMember(o:Ex, name:String);
	// a Haxe field's (its name minified in its namespace: FieldNames)
	EField(o:Ex, name:String, ns:Ns);
	// a Haxe field's name as a string (`$hx.bind`'s)
	EFieldName(name:String, ns:Ns);
	EPrivate(o:Ex, name:String);
	// o.name past TypeScript's `protected` (Haxe's `@:privateAccess`, `@:access`, `@:allow`): `o["name"]` in TypeScript, which
	// it checks as any other member but for access
	EFriend(o:Ex, name:String);
	EIndex(o:Ex, key:Ex);
	ECall(f:Ex, args:Array<Ex>);
	ENew(c:Ex, args:Array<Ex>);
	EUnary(op:String, x:Ex);
	EUpdate(op:String, prefix:Bool, x:Ex);
	EBinary(op:String, a:Ex, b:Ex);
	EAssign(op:String, a:Ex, b:Ex);
	ECond(c:Ex, a:Ex, b:Ex);
	ESeq(items:Array<Ex>);
	ESpread(x:Ex);
	// (TypeScript) the value as `any`, where Haxe accepted what TypeScript would not
	EAs(x:Ex);
	// (TypeScript) a generic function or class with its type arguments, as Haxe inferred them (`f<A>`)
	ETypeArgs(f:Ex, args:Array<T>);
	EImport(path:Ex);
	// (modules) a split's call: the modules its code needs imported (`import()`, as a bundler finds them), then the code, of
	// the split's file (Chunk: what it imports, its bindings), as the printer has it
	ESplit(file:Int, fn:Fn);
	// untyped code: text with expressions between its parts
	ERaw(parts:Array<RawPart>);
	// a call of a method of an accessor's name (Properties): as the call, or as the property (`o.x`, `o.x = v` where nothing
	// uses its value), as its family is (Chunk.accessorEx)
	EAccessor(a:TClassField, call:Ex, discarded:Bool);
	// a property's storage (@:isVar): the field (`o.x`), or the class's #private field (`o.#x`) where its family is JavaScript's
	// (Chunk.backedEx)
	EBacked(p:TClassField, field:Ex);
}

enum RawPart {
	RText(s:String);
	RValue(e:Ex);
}

@:structInit class Prop {
	public var key:Key;
	public var value:Ex;
}

enum Key {
	KName(s:String);
	// a Haxe field's (its name minified: FieldNames)
	KField(s:String, ns:Ns);
	KString(s:String);
	KPrivate(s:String);
	KComputed(e:Ex);
}

@:structInit class Fn {
	public var params:Array<Sym>;
	// the last parameter collects the rest
	public var rest:Bool;
	public var body:Array<St>;
	public var arrow:Bool;
	@:optional public var name:Null<Sym>;
	// (TypeScript) its return type, its type parameters, the first optional parameter, `this: any` (a function
	// expression that names `this`)
	@:optional public var ret:Null<T>;
	@:optional public var tparams:Null<TypeParams>;
	@:optional public var optFrom:Null<Int>;
	@:optional public var thisAny:Null<Bool>;
	// an enum's constructor: a `function` (which `new` constructs), not a method
	@:optional public var ctor:Null<Bool>;
	// where it is in the source (a method's name's mapping, SourceMap)
	@:optional public var pos:Null<Pos>;
	// (TypeScript) its parameters without types, which the context gives them (an enum constructor's declaration, a
	// split's `import()`s)
	@:optional public var contextual:Null<Bool>;
}

@:structInit class St {
	public var def:StDef;
	public var pos:Null<Pos>;

	public inline function new(def, ?pos) {
		this.def = def;
		this.pos = pos;
	}
}

enum StDef {
	SExpr(e:Ex);
	SVar(kind:VarKind, decls:Array<Decl>);
	SReturn(e:Null<Ex>);
	SIf(c:Ex, a:Array<St>, b:Null<Array<St>>);
	SBlock(body:Array<St>);
	SWhile(c:Ex, body:Array<St>);
	SDoWhile(body:Array<St>, c:Ex);
	SFor(init:Null<St>, test:Null<Ex>, update:Null<Ex>, body:Array<St>);
	SForOf(kind:VarKind, v:Sym, of:Ex, body:Array<St>);
	SBreak(label:Null<String>);
	SContinue(label:Null<String>);
	SThrow(e:Ex);
	STry(body:Array<St>, param:Null<Sym>, handler:Array<St>);
	SSwitch(on:Ex, cases:Array<Case>);
	SLabel(label:String, body:St);
	SClass(c:ClassDecl);
	SFunction(f:Fn);
	SExport(s:St);
	// (TypeScript) an interface's declaration
	SInterface(name:Sym, c:TClass);
	// `const name = $hx.declareEnum(...)` (call), its constructors' types in TypeScript (index: the binding of `$hx.index`)
	SEnum(name:Sym, call:Ex, en:TEnum, index:Sym);
	SComment(text:String);
	SRaw(code:String);
}

enum VarKind {
	VConst;
	VLet;
}

@:structInit class Decl {
	public var name:Sym;
	public var init:Null<Ex>;
}

@:structInit class Case {
	// null: `default`
	public var tests:Null<Array<Ex>>;
	public var body:Array<St>;
	// written after the tests, one each (`case 0: // Leaf`)
	@:optional public var comments:Null<Array<String>>;
}

@:structInit class ClassDecl {
	public var name:Sym;
	public var superClass:Null<Ex>;
	public var members:Array<Member>;
	// (TypeScript) its type parameters, its super class's type arguments, `abstract`
	@:optional public var tparams:Null<TypeParams>;
	@:optional public var superArgs:Null<Array<T>>;
	@:optional public var isAbstract:Null<Bool>;
}

enum Member {
	MMethod(key:Key, f:Fn, isStatic:Bool, kind:MethodKind);
	// (type: TypeScript's declared type)
	MField(key:Key, value:Null<Ex>, isStatic:Bool, type:Null<T>);
	// (TypeScript) a field's declaration (nothing at run time), an abstract method's, a member `protected`
	MDeclare(key:Key, type:T, isStatic:Bool);
	MAbstract(key:Key, type:T, tparams:TypeParams);
	MProtected(m:Member);
	// (TypeScript) a field written only in its class's constructor, or not at all (`final`, `(default, null)`)
	MReadonly(m:Member);
	MStaticBlock(body:Array<St>);
	MComment(text:String);
}

enum MethodKind {
	MkMethod;
	MkGet;
	MkSet;
	MkConstructor;
}

class EsTools {
	public static inline function ex(def:ExDef, ?pos:Pos):Ex return new Ex(def, pos);

	public static inline function st(def:StDef, ?pos:Pos):St return new St(def, pos);

	public static inline function identStart(c:Int):Bool return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || c == "_".code || c == "$".code;

	public static inline function identPart(c:Int):Bool return identStart(c) || (c >= "0".code && c <= "9".code);

	// (no regular expression: lowerings and printers run in parallel, an EReg's state is its own)
	public static function validIdent(s:String):Bool {
		if (s.length == 0 || !identStart(StringTools.fastCodeAt(s, 0))) return false;
		for (i in 1...s.length) if (!identPart(StringTools.fastCodeAt(s, i))) return false;
		return true;
	}

	// the reserved words of ES2022 a binding may not be (strict mode, modules)
	public static final RESERVED = [
		for (k in [
			"await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export",
			"extends", "false", "finally", "for", "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null",
			"package", "private", "protected", "public", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "var",
			"void", "while", "with", "yield", "arguments", "eval", "undefined", "NaN", "Infinity"
		])
			k => true
	];
}
