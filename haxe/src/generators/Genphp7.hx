/**
	Compatible with PHP 7.0+
*/

package generators;

import core.Ast;
import core.Ast as AstTools;
import core.Globals;
import core.Globals.Pos;
import core.TType;
import core.TFunctions;
import core.TFunctions.*;
import core.TOther.ExtType;
import core.TOther.TClassTools;
import core.Meta as MetadataTools;
import core.MetaList.StrictMeta;
import core.Define;
import core.StringHelper;
import core.Texpr;
import core.Abstract;
import core.ds.NotFound;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import context.Sourcemaps;
import generators.Gctx;
import generators.genphp7.TypeWrappers;
import generators.genphp7.CodeWriter;
import generators.genphp7.TypeBuilders;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

typedef UsedType = {
	var utAlias:String;
	var utTypePath:GlobalTypePath;
}

class PhpGeneratorContext {
	public final pgcCommon:Gctx;

	/** Do not add comments with Haxe positions before each line of generated php code */
	public final pgcSkipLineDirectives:Bool;

	/** The value of `-D php-prefix=value` split by dots */
	public final pgcPrefix:Array<String>;

	/** php.Boot */
	public final pgcBoot:TClass;

	/** see type_name_used_in_namespace */
	// port: (string list, string) Hashtbl.t; only Hashtbl.find_all and Hashtbl.add are used, the key is
	// the namespace joined with dots (its parts never contain dots).
	public final pgcNamespacesTypesCache:haxe.ds.StringMap<Array<String>>;

	/**
		List of anon structures declarations found during generating current php file.
		The key is a list of fields names.
		The value is an auto-generated name for the class representing that anon.
	*/
	public final pgcAnons:haxe.ds.StringMap<String>;

	/** a buffer to write to the bottom of the current php file (but before "Boot::registerClass()" and "::_hx_init()" calls) */
	public var pgcBottomBuffer:StringBuf;

	public function new(pgcCommon, pgcSkipLineDirectives, pgcPrefix, pgcBoot, pgcNamespacesTypesCache, pgcAnons, pgcBottomBuffer) {
		this.pgcCommon = pgcCommon;
		this.pgcSkipLineDirectives = pgcSkipLineDirectives;
		this.pgcPrefix = pgcPrefix;
		this.pgcBoot = pgcBoot;
		this.pgcNamespacesTypesCache = pgcNamespacesTypesCache;
		this.pgcAnons = pgcAnons;
		this.pgcBottomBuffer = pgcBottomBuffer;
	}
}

/**
	PHP DocBlock types
*/
enum DocType {
	DocVar(typeName:String, description:Null<String>); /* (type name, description) */
	DocMethod(args:Vector<{name:String, optional:Bool, type:T}>, ret:T, description:Null<String>); /* (arguments, return type, description) */
	DocClass(description:Null<String>);
}

class Genphp7 {
	/**
		Escape string for constant strings generation.
		Copy-pasted from genphp.
	*/
	public static function escapeBin(s:String):String {
		// port: iterates characters; the characters >= 128 are copied like their UTF-8 bytes upstream.
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if (c == '\\'.code || c == '"'.code || c == '$'.code) {
				b.add("\\");
				b.addChar(c);
			} else if (c < 32) {
				b.add("\\x" + StringTools.hex(c, 2));
			} else {
				b.addChar(c);
			}
		}
		return b.toString();
	}

	/**
		Write resources passed to compiler via `-resource` flag
		Copy-pasted from genphp
	*/
	public static function writeResource(dir:String, name:String, data:haxe.io.Bytes):Void {
		var rdir = dir + "/res";
		if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
		if (!sys.FileSystem.exists(rdir)) sys.FileSystem.createDirectory(rdir);
		var name = StringHelper.escapeResName(name, []);
		sys.io.File.saveBytes(rdir + "/" + name, data);
	}

	/**
		Copy file from `src` to `dst`.
		If `dst` exists it will be overwritten.
	*/
	public static function copyFile(src:String, dst:String):Void {
		sys.io.File.saveBytes(dst, sys.io.File.getBytes(src));
	}

	/**
		Splits `"path/to/file"` into `["path"; "to"; "file"]`
	*/
	public static function splitFilePath(path:String):Array<String> {
		return if (Globals.isWindows) strSplit(path, c -> c == "/".code || c == "\\".code) else strSplit(path, c -> c == "/".code);
	}

	// port: OCaml `Str.split` with a single-character delimiter regexp: a delimiter at the
	// start is skipped, the end stops the scan (no trailing empty part), inner empty parts stay.
	public static function strSplit(s:String, isDelim:Int->Bool):Array<String> {
		var result = [];
		var len = s.length;
		var start = (len > 0 && isDelim(StringTools.fastCodeAt(s, 0))) ? 1 : 0;
		while (start < len) {
			var pos = start;
			while (pos < len && !isDelim(StringTools.fastCodeAt(s, pos))) pos++;
			if (pos >= len) {
				result.push(s.substr(start));
				break;
			}
			result.push(s.substring(start, pos));
			start = pos + 1;
		}
		return result;
	}

	// port: OCaml `String.escaped` (on the UTF-8 bytes of `s`).
	public static function ocamlEscaped(s:String):String {
		var plain = true;
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			if (c < 32 || c > 126 || c == '"'.code || c == '\\'.code) {
				plain = false;
				break;
			}
		}
		if (plain) return s;
		var bytes = haxe.io.Bytes.ofString(s);
		var b = new StringBuf();
		for (i in 0...bytes.length) {
			var c = bytes.get(i);
			switch c {
				case '"'.code | '\\'.code:
					b.addChar('\\'.code);
					b.addChar(c);
				case '\n'.code:
					b.add("\\n");
				case '\t'.code:
					b.add("\\t");
				case '\r'.code:
					b.add("\\r");
				case 8:
					b.add("\\b");
				case c if (c >= 32 && c <= 126):
					b.addChar(c);
				case c:
					b.addChar('\\'.code);
					b.addChar(48 + Std.int(c / 100));
					b.addChar(48 + Std.int(c / 10) % 10);
					b.addChar(48 + c % 10);
			}
		}
		return b.toString();
	}

	// port: OCaml `String.trim` (ExtString.String.trim): ' ', '\012', '\n', '\r', '\t'.
	public static function ocamlTrim(s:String):String {
		inline function isSpace(c:Int):Bool return c == ' '.code || c == 12 || c == '\n'.code || c == '\r'.code || c == '\t'.code;
		var i = 0, j = s.length - 1;
		while (i <= j && isSpace(StringTools.fastCodeAt(s, i))) i++;
		while (j >= i && isSpace(StringTools.fastCodeAt(s, j))) j--;
		return s.substring(i, j + 1);
	}

	// port: ASCII-only `String.lowercase` (ExtString.String.lowercase).
	public static function asciiLowercase(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = StringTools.fastCodeAt(s, i);
			b.addChar(c >= 'A'.code && c <= 'Z'.code ? c + 32 : c);
		}
		return b.toString();
	}

	// port: structural equality of `string list`
	public static function packEq(a:Array<String>, b:Array<String>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (a[i] != b[i]) return false;
		return true;
	}

	// port: structural equality of `path` (string list * string)
	public static function pathEq(a:GlobalTypePath, b:GlobalTypePath):Bool return a.name == b.name && packEq(a.pack, b.pack);

	static inline function mkPath(pack:Array<String>, name:String):GlobalTypePath return {pack: pack, name: name};

	// port: structural equality of `pos`
	public static function posEq(a:Pos, b:Pos):Bool return a.pfile == b.pfile && a.pmin == b.pmin && a.pmax == b.pmax;

	/**
		Reset the state of the context between before a generating a php file.
	*/
	public static function resetContext(ctx:PhpGeneratorContext):Void {
		ctx.pgcBottomBuffer = new StringBuf();
		ctx.pgcAnons.clear();
	}

	/**
		Get list of keys in Hashtbl
	*/
	public static function hashtblKeys<V>(tbl:OcamlHashtbl<String, V>):Array<String> {
		var lst = [];
		tbl.iter((key, _) -> lst.unshift(key));
		return lst;
	}

	/**
		@return List of items in `list1` which `list2` does not contain
	*/
	public static function diffLists(list1:Array<String>, list2:Array<String>):Array<String> return list1.filter(x -> list2.indexOf(x) < 0);

	/**
		@return List of items in `list1` which `list2` does contain too
	*/
	public static function intersectLists(list1:Array<String>, list2:Array<String>):Array<String> return list1.filter(x -> list2.indexOf(x) >= 0);

	/**
		Type path of `php.Boot`
	*/
	public static final bootTypePath = mkPath(["php"], "Boot");

	/**
		Type path of the base class for all enums: `php.Boot.HxEnum`
	*/
	public static final hxenumTypePath = mkPath(["php", "_Boot"], "HxEnum");

	/**
		Type path of the implementation class for `Class<Dynamic>`
	*/
	public static final hxclassTypePath = mkPath(["php", "_Boot"], "HxClass");

	/**
		Type path of the implementation class for `String`
	*/
	public static final hxstringTypePath = mkPath(["php", "_Boot"], "HxString");

	/**
		Type path of the special implementation class for `String`
		which is used when Dynamic value is suspected to be a string
	*/
	public static final hxdynamicstrTypePath = mkPath(["php", "_Boot"], "HxDynamicStr");

	/**
		Type path of the implementation class for anonymous objects
	*/
	public static final hxanonTypePath = mkPath(["php", "_Boot"], "HxAnon");

	/**
		Type path of the implementation class for closures
	*/
	public static final hxclosureTypePath = mkPath(["php", "_Boot"], "HxClosure");

	/**
		Type path for special PHP extern class to support specific language expressions
	*/
	public static final syntaxTypePath = mkPath(["php"], "Syntax");

	/**
		Special abstract which enables passing function arguments and return value by reference
	*/
	public static final refTypePath = mkPath(["php"], "Ref");

	/**
		Type path of the implementation class for `Array<T>`
	*/
	public static final arrayTypePath = mkPath([], "Array");

	/**
		Type path of the implementation class for `Array<T>`
	*/
	public static final nativeArrayTypePath = mkPath(["php"], "NativeArray");

	/**
		Type path of the `Void`
	*/
	public static final voidTypePath = mkPath([], "Void");

	/**
		Type path of the `Bool`
	*/
	public static final boolTypePath = mkPath([], "Bool");

	/**
		Type path of the `Std`
	*/
	public static final stdTypePath = mkPath([], "Std");

	/**
		The name of a file with polyfills for some functions which are not available in PHP 7.0
	*/
	public static final polyfillsFile = "_polyfills.php";

	public static final phpKeywordsList = [
		"__halt_compiler", "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
		"clone", "const", "continue", "declare", "default", "die", "do", "echo", "else", "elseif", "empty",
		"enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile", "eval", "exit", "extends", "final",
		"finally", "for", "foreach", "function", "global", "goto", "if", "implements", "include", "include_once",
		"instanceof", "insteadof", "interface", "isset", "list", "namespace", "new", "or", "print", "private",
		"protected", "public", "require", "require_once", "return", "static", "switch", "throw", "trait", "try",
		"unset", "use", "var", "while", "xor", "yield", "__class__", "__dir__", "__file__", "__function__", "__line__",
		"__method__", "__trait__", "__namespace__", "int", "float", "bool", "string", "true", "false", "null", "parent",
		"void", "iterable", "object", "fn"
	];

	public static final phpKeywordsTbl = {
		var tbl = new haxe.ds.StringMap<Bool>();
		for (kwd in phpKeywordsList) tbl.set(kwd, true);
		tbl;
	}

	/**
		Check if specified string is a reserved word in PHP
	*/
	public static function isKeyword(str:String):Bool return phpKeywordsTbl.exists(asciiLowercase(str));

	/**
		Check if specified type is php.NativeArray
	*/
	public static function isNativeArrayType(t:T):Bool return switch TFunctions.follow(t) {
		case TAbstract({aPath: tp}, _): pathEq(tp, nativeArrayTypePath);
		case _: false;
	}

	/**
		If `name` is not a reserved word in PHP then `name` is returned as-is.
		Otherwise this method returns another string, which can be used instead of `name`
	*/
	public static function getRealName(name:String):String return if (isKeyword(name)) name + "_hx" else name;

	/**
		Returns local variable name free of risk to collide with superglobals like $_SERVER or $_GET
	*/
	public static function vname(name:String):String {
		return switch name {
			case "GLOBALS" | "_SERVER" | "_GET" | "_POST" | "_FILES" | "_COOKIE" | "_SESSION" | "_REQUEST" | "_ENV": name + "_hx_";
			case _: name;
		}
	}

	/**
		If `path` contains some reserved in PHP words, they will be replaced with allowed words.
	*/
	public static function getRealPath(path:Array<String>):Array<String> return path.map(getRealName);

	/**
		Resolve real type (bypass abstracts and typedefs)
	*/
	public static function follow(t:T):T return Abstract.followWithAbstracts(t);

	/**
		Adds packages specified by `-D php-prefix` to `type_path`.
		E.g. if `-D php-prefix=some.sub` and `type_path` is `(["pack"], "MyClass")`, then this function
		will return `(["some", "sub", "pack"], "MyClass")`
	*/
	public static function addPhpPrefix(ctx:PhpGeneratorContext, typePath:GlobalTypePath):GlobalTypePath {
		return mkPath(ctx.pgcPrefix.concat(typePath.pack), typePath.name);
	}

	/**
		If `expr` is a TCast or TMeta, then returns underlying expression (recursively bypassing nested casts).
		Otherwise returns `expr` as is.
	*/
	public static function revealExpr(expr:TExpr):TExpr {
		return switch expr.eexpr {
			case TCast(e, _): revealExpr(e);
			case TMeta(_, e): revealExpr(e);
			case _: expr;
		}
	}

	/**
		If `expr` is a TCast or TMeta or TParenthesis, then returns underlying expression (recursively bypassing nested casts and parenthesis).
		Otherwise returns `expr` as is.
	*/
	public static function revealExprWithParenthesis(expr:TExpr):TExpr {
		return switch expr.eexpr {
			case TCast(e, _): revealExprWithParenthesis(e);
			case TMeta(_, e): revealExprWithParenthesis(e);
			case TParenthesis(e): revealExprWithParenthesis(e);
			case _: expr;
		}
	}

	/**
		Get string representation of specified position in Haxe code.
	*/
	public static function stringifyPos(pos:Pos):String return syntax.Lexer.getErrorPos((f, l) -> f + ":" + l + ":", pos);

	/**
		@return Error message with position information
	*/
	public static function errorMessage(pos:Pos, message:String):String return (stringifyPos(pos)) + ": " + message;

	/**
		Terminates compiler process and prints user-friendly instructions about filing an issue in compiler repo.
	*/
	public static function fail(?msg:String, p:Pos, loc:String):Dynamic return Globals.die(msg == null ? "" : msg, loc, p);

	/**
		Check if `target` is a `Dynamic` type
	*/
	public static function isDynamicType(target:T):Bool return follow(target).match(TDynamic(_));

	/**
		Check if `target` is `php.Ref`
	*/
	public static function isRef(target:T):Bool return switch followWithoutType(target) {
		case TType({tPath: typePath}, _): pathEq(typePath, refTypePath);
		case _: false;
	}

	/**
		Check if `field` is a `dynamic function`
	*/
	public static function isDynamicMethod(field:TClassField):Bool return field.cfKind.match(Method(MethDynamic));

	/**
		Check if specified expression is of `Dynamic` type
	*/
	public static function isDynamic(expr:TExpr):Bool return isDynamicType(expr.etype);

	/**
		Check if specified expression is of `Int` type
	*/
	public static function isInt(expr:TExpr):Bool return switch follow(expr.etype) {
		case TAbstract({aPath: {pack: [], name: "Int"}}, _): true;
		case _: false;
	}

	/**
		Check if specified expression is of `Float` type
	*/
	public static function isFloat(expr:TExpr):Bool return ExtType.isFloat(follow(expr.etype));

	/**
		Check if specified expression is of String type
	*/
	public static function isString(expr:TExpr):Bool return ExtType.isString(follow(expr.etype));

	/**
		Check if specified type is Array
	*/
	public static function isArrayType(t:T):Bool return switch follow(t) {
		case TInst({clPath: {pack: [], name: "Array"}}, _): true;
		case _: false;
	}

	/**
		Check if specified type is haxe.Rest
	*/
	public static function isRestType(t:T):Bool return ExtType.isRest(TFunctions.follow(t));

	/**
		Check if specified type represents a function
	*/
	public static function isFunctionType(t:T):Bool return follow(t).match(TFun(_));

	/**
		Check if `expr` is an access to a method of special `php.PHP` class
	*/
	public static function isSyntaxExtern(expr:TExpr):Bool return switch expr.eexpr {
		case TField({eexpr: TTypeExpr(TClassDecl({clPath: path}))}, _): pathEq(path, syntaxTypePath);
		case _: false;
	}

	/**
		Check if specified type is actually a generic parameter
	*/
	public static function isGenericParameter(target:T):Bool return switch follow(target) {
		case TInst({clKind: KTypeParameter(_)}, _): true;
		case _: false;
	}

	/**
		Check if `target` type cannot be clarified on compilation
	*/
	public static function isUnknownType(target:T):Bool return isDynamicType(target) || isGenericParameter(target);

	/**
		@return `expr` wrapped in parenthesis
	*/
	public static function parenthesis(expr:TExpr):TExpr return {eexpr: TParenthesis(expr), etype: expr.etype, epos: expr.epos};

	/**
		Check if `current` binary should be surrounded with parenthesis
	*/
	public static function needParenthesisForBinop(current:Binop, parent:Binop):Bool {
		// port: `current = parent` is structural, `!=` physical (constant constructors compare as values)
		if (std.Type.enumEq(current, parent) && !current.match(OpNotEq) && !current.match(OpEq)) return false;
		return switch [current, parent] {
			case [_, OpAssign]: false;
			case [_, OpAssignOp(_)]: false;
			case [OpAdd, OpSub]: false;
			case [OpSub, OpAdd]: false;
			case [OpMult, OpDiv]: false;
			case [OpDiv, OpMult]: false;
			case [OpMult, OpAdd]: false;
			case [OpMult, OpSub]: false;
			case [OpDiv, OpAdd]: false;
			case [OpDiv, OpSub]: false;
			case _: true;
		}
	}

	/**
		Check if specified expression may require dereferencing if used as "temporary expression"
	*/
	public static function needsDereferencing(forAssignment:Bool, expr:TExpr):Bool {
		function isCreate(targetExpr:TExpr):Bool {
			return switch (revealExprWithParenthesis(targetExpr)).eexpr {
				case TNew(_): forAssignment;
				case TArrayDecl(_): forAssignment;
				case TObjectDecl(_): forAssignment;
				case TConst(TNull): true;
				case TIf(_): true;
				/* some of `php.Syntax` methods */
				// port: upstream's `{ cl_path = syntax_type_path }` binds a new name (any class matches)
				case TCall({eexpr: TField(_, FStatic(_, {cfName: name}))}, _):
					switch name {
						case "codeDeref" | "coalesce" | "assocDecl" | "arrayDecl": forAssignment;
						case _: false;
					}
				case _: false;
			}
		}
		return switch (revealExpr(expr)).eexpr {
			case TField(targetExpr, _): isCreate(targetExpr);
			case TArray(targetExpr, _): isCreate(targetExpr);
			case _: false;
		}
	}

	/**
		Check if the value of `expr` needs to be stored to a temporary variable to be
		reused.
	*/
	public static function needsTempVar(expr:TExpr):Bool {
		return switch (revealExprWithParenthesis(expr)).eexpr {
			case TConst(_) | TLocal(_): false;
			case TField(target, FInstance(_)) | TField(target, FStatic(_)): needsTempVar(target);
			case TArray(target, index): needsTempVar(target) || needsTempVar(index);
			case _: true;
		}
	}

	/**
		@return (arguments_list, return_type)
	*/
	public static function getFunctionSignature(basic:BasicTypes, field:TClassField):TSignature {
		return switch followWithCoro(field.cfType) {
			case Coro(sig): context.Common.expandCoroType(basic, sig.args, sig.ret);
			case NotCoro(TFun(sig)): sig;
			case _: fail(field.cfPos, "genphp7.get_function_signature");
		}
	}

	/**
		Check if `target` is 100% guaranteed to be a scalar type in PHP.
		Inversion of `is_sure_scalar` does not guarantee `target` is not scalar.
	*/
	public static function isSureScalar(target:T):Bool return switch follow(target) {
		case TInst({clPath: {pack: [], name: "String"}}, _): true;
		case TAbstract({aPath: {pack: [], name: "Int" | "Float" | "Bool"}}, _): true;
		case _: false;
	}

	/**
		Indicates if `expr` has to be wrapped into parentheses to be called.
	*/
	public static function needsParenthesisToCall(expr:TExpr):Bool {
		return switch expr.eexpr {
			case TParenthesis(_): false;
			case TCast(e, null) | TMeta(_, e): needsParenthesisToCall(e);
			case TNew(_) | TObjectDecl(_) | TArrayDecl(_) | TField(_, FClosure(_, _)) | TField(_, FStatic(_, {cfKind: Var(_)})) | TField(_,
				FInstance(_, _, {cfKind: Var(_)})): true;
			/* | TField (_, FAnon { cf_kind = Var _ }) -> true *) (* Sometimes we get anon access to non-anonymous objects */
			case _: false;
		}
	}

	/**
		Check if specified unary operation modifies value in place
	*/
	public static function isModifyingUnop(op:Unop):Bool return switch op {
		case Increment | Decrement: true;
		case _: false;
	}

	/**
		Check if specified binary operation contains assignment
	*/
	public static function isAssignmentBinop(op:Binop):Bool return switch op {
		case OpAssign | OpAssignOp(_): true;
		case _: false;
	}

	/**
		Indicates whether `expr` is a field access which should be generated as global namespace function
	*/
	public static function isPhpGlobal(expr:TExpr):Bool return switch expr.eexpr {
		case TField(_, FStatic(c, _)) if (hasClassFlag(c, CExtern)): pathEq(c.clPath, mkPath([], "")) || MetadataTools.has(PhpGlobal, c.clMeta);
		case _: false;
	}

	/**
		Indicates whether `expr` is a field access which should be generated as class constant access
	*/
	public static function isPhpClassConst(expr:TExpr):Bool return switch expr.eexpr {
		case TField(_, FStatic(c, {cfMeta: meta, cfKind: Var(_)})) if (hasClassFlag(c, CExtern)): MetadataTools.has(PhpClassConst, meta);
		case _: false;
	}

	/**
		Check if specified enum constructor has arguments
	*/
	public static function isEnumConstructorWithArgs(constructor:TEnumField):Bool return follow(constructor.efType).match(TFun(_));

	/**
		Check if `target` is 100% guaranteed to be or extend an extern class.
		Inversion of `sure_extends_extern` does not guarantee `target` does not extend an extern class.
	*/
	public static function sureExtendsExtern(target:T):Bool return switch follow(target) {
		case TInst({clPath: {pack: [], name: "String"}}, _): false;
		case TInst(c, _) if (hasClassFlag(c, CExtern)): true;
		case TInst({clSuper: sup}, _) if (sup != null): sureExtendsExtern(TInst(sup.cls, sup.params));
		case _: false;
	}

	/**
		@param path Something like [ "/some/path/first_dir_to_create"; "nested_level1"; "nested_level2" ]
		@return String representation of created path (E.g. "/some/path/first_dir_to_create/nested_level1/nested_level2")
	*/
	public static function createDirRecursive(path:Array<String>):String {
		function create(dir:String, nestedDirs:Array<String>):String {
			var dir = core.Path.removeTrailingSlash(dir);
			if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
			return switch nestedDirs {
				case []: dir;
				case _: create(dir + "/" + nestedDirs[0], nestedDirs.slice(1));
			}
		}
		return switch path {
			case []: "";
			case _: create(path[0], path.slice(1));
		}
	}

	/**
		@return String representation of specified type path. E.g. returns "\example\Test" for (["example"], "Test")
	*/
	public static function getFullTypeName(escape:Bool = false, omitFirstSlash:Bool = false, typePath:GlobalTypePath):String {
		var name = switch typePath {
			case {pack: [], name: typeName}:
				if (omitFirstSlash) typeName else "\\" + typeName;
			case {pack: modulePath, name: typeName}:
				var parts = if (omitFirstSlash) getRealPath(modulePath) else [""].concat(getRealPath(modulePath));
				parts.join("\\") + "\\" + typeName;
		}
		return if (escape) ocamlEscaped(name) else name;
	}

	/**
		@return Short type name. E.g. returns "Test" for (["example"], "Test")
	*/
	public static function getTypeName(typePath:GlobalTypePath):String return typePath.name;

	/**
		@return E.g. returns ["example"] for (["example"], "Test")
	*/
	public static function getModulePath(typePath:GlobalTypePath):Array<String> return typePath.pack;

	/**
		@return PHP visibility keyword.
	*/
	public static function getVisibility(meta:Metadata):String return if (MetadataTools.has(Protected, meta)) "protected" else "public";

	/**
		Writes arguments list to output buffer
	*/
	extern overload public static inline function writeArgs<A>(strWriter:String->Void, argWriter:A->Void, args:Array<A>):Void {
		for (i in 0...args.length) {
			if (i > 0) strWriter(", ");
			argWriter(args[i]);
		}
	}

	extern overload public static inline function writeArgs<A>(strWriter:String->Void, argWriter:A->Void, args:Vector<A>):Void {
		for (i in 0...args.length) {
			if (i > 0) strWriter(", ");
			argWriter(args[i]);
		}
	}

	/**
		PHP 8 doesn't allow mandatory arguments after optional arguments.
		This function makes optional arguments mandatory from left to right
		unless there are no more mandatory arguments left to the end of args list.

		E.g `(a:String = null, b:Int, c:Bool = false)` is changed into `(a:String, b:Int, c:Bool = false)`
	*/
	public static function fixOptionalArgs<A>(isOptional:A->Bool, toMandatory:A->A, args:Vector<A>):Vector<A> {
		var lastMandatory = -1;
		for (i in 0...args.length) if (!isOptional(args[i])) lastMandatory = i;
		return VectorTools.init(args.length, i -> if (i <= lastMandatory && isOptional(args[i])) toMandatory(args[i]) else args[i]);
	}

	public static function fixTfuncArgs(args:Vector<{variable:TVar, defaultValue:Null<TExpr>}>):Vector<{variable:TVar, defaultValue:Null<TExpr>}> {
		return fixOptionalArgs((a:{variable:TVar, defaultValue:Null<TExpr>}) -> a.defaultValue != null, (a:{variable:TVar, defaultValue:Null<TExpr>}) -> ({variable: a.variable, defaultValue: null}:{variable:TVar, defaultValue:Null<TExpr>}), args);
	}

	public static function fixTsignatureArgs(args:Vector<{name:String, optional:Bool, type:T}>):Vector<{name:String, optional:Bool, type:T}> {
		return fixOptionalArgs((a:{name:String, optional:Bool, type:T}) -> a.optional, (a:{name:String, optional:Bool, type:T}) -> ({name: a.name, optional: false, type: a.type}:{name:String, optional:Bool, type:T}), args);
	}

	/**
		Inserts `null`s if there are missing optional args before empty rest arguments.
	*/
	public static function fixCallArgs(basic:BasicTypes, calleeType:T, exprs:Vector<TExpr>):Vector<TExpr> {
		var args = switch followWithCoro(calleeType) {
			case Coro(sig): context.Common.expandCoroType(basic, sig.args, sig.ret).args;
			case NotCoro(TFun(sig)): sig.args;
			case _: null;
		}
		return switch args {
			case null: exprs;
			case args:
				var argsRev = args.copy();
				argsRev.reverse();
				if (argsRev.length > 0 && isRestType(argsRev[0].type) && argsRev.length - 1 > exprs.length) {
					var result = [];
					var ai = 0, ei = 0;
					while (true) {
						if (args.length - ai <= 1) {
							for (j in ei...exprs.length) result.push(exprs[j]);
							break;
						}
						if (ei >= exprs.length) {
							result.push(mk(TConst(TNull), args[ai].type, Globals.nullPos));
							ai++;
						} else {
							result.push(exprs[ei]);
							ai++;
							ei++;
						}
					}
					Vector.fromArrayCopy(result);
				} else exprs;
		}
	}

	/**
		Escapes all "$" chars and encloses `str` into double quotes
	*/
	public static function quoteString(str:String):String return "\"" + ocamlEscaped(str).split("$").join("\\$") + "\"";

	/**
		Check if specified field is a var with non-constant expression
	*/
	public static function isVarWithNonconstantExpr(field:TClassField):Bool {
		return switch field.cfKind {
			case Var(_):
				switch field.cfExpr {
					case null: false;
					case {eexpr: TConst(_)}: false;
					case _: true;
				}
			case Method(_): false;
		}
	}

	/**
		Check if specified field is an `inline var` field.
	*/
	public static function isInlineVar(field:TClassField):Bool return switch field.cfKind {
		case Var({vRead: AccInline, vWrite: AccNever}): true;
		case _: false;
	}

	/**
		@return New TBlock expression which is composed of setting default values for optional arguments and function body.
	*/
	public static function injectDefaults(ctx:PhpGeneratorContext, func:TFunc):TExpr {
		function inject(args:Vector<{variable:TVar, defaultValue:Null<TExpr>}>, bodyExprs:Vector<TExpr>):Vector<TExpr> {
			var result = [];
			for (a in args) switch a.defaultValue {
				case null:
				case {eexpr: TConst(TNull)}:
				case const:
					result.push(Texpr.setDefault(ctx.pgcCommon.basic, a.variable, const, func.tfExpr.epos));
			}
			for (e in bodyExprs) result.push(e);
			return Vector.fromArrayCopy(result);
		}
		var exprs = switch func.tfExpr.eexpr {
			case TBlock(exprs): inject(func.tfArgs, exprs);
			case _: inject(func.tfArgs, vector(func.tfExpr));
		}
		return {
			eexpr: TBlock(exprs),
			etype: follow(func.tfExpr.etype),
			epos: func.tfExpr.epos,
		};
	}

	/**
		Check if `expr` is a constant string
	*/
	public static function isConstantString(expr:TExpr):Bool return expr.eexpr.match(TConst(TString(_)));

	/**
		Check if `expr` is a constant null
	*/
	public static function isConstantNull(expr:TExpr):Bool return expr.eexpr.match(TConst(TNull));

	/**
		Check if `expr` is a constant
	*/
	public static function isConstant(expr:TExpr):Bool return expr.eexpr.match(TConst(_));

	/**
		Check if `expr` is a constant zero
	*/
	public static function isConstantZero(expr:TExpr):Bool {
		try {
			return switch expr.eexpr {
				case TConst(TInt(i)) if (i == 0): true;
				case TConst(TFloat(s)) if (core.ds.OcamlFloat.ofString(s) == 0.0): true;
				case _: false;
			}
		} catch (_:Dynamic) {
			return false;
		}
	}

	/**
		Check if `expr` is a concatenation
	*/
	public static function isConcatenation(expr:TExpr):Bool return switch expr.eexpr {
		case TBinop(OpAdd, expr1, expr2): (isString(expr1)) || (isString(expr2));
		case _: false;
	}

	/**
		Check if provided expression is a block of expressions
	*/
	public static function isBlock(expr:TExpr):Bool return expr.eexpr.match(TBlock(_));

	/**
		Check if provided expression is a binary operation
	*/
	public static function isBinop(expr:TExpr):Bool return expr.eexpr.match(TBinop(_));

	/**
		Check if provided expression is an assignment binary operation
	*/
	public static function isBinopAssign(expr:TExpr):Bool return expr.eexpr.match(TBinop(OpAssign | OpAssignOp(_), _, _));

	/**
		Check if specified expression is field access or array access
	*/
	public static function isAccess(expr:TExpr):Bool return expr.eexpr.match(TField(_) | TArray(_));

	/**
		Check if specified field access is an access to the field `Array.arr`
		It's a private field of the php-specific implementation of Haxe Array.
	*/
	public static function isArrayArr(faccess:TFieldAccess):Bool return switch faccess {
		case FInstance({clPath: {pack: [], name: "Array"}}, _, {cfName: "arr"}): true;
		case _: false;
	}

	/**
		Indicates if `expr` is actually a call to Haxe->PHP magic function
		@see http://old.haxe.org/doc/advanced/magic#php-magic
	*/
	public static function isMagic(expr:TExpr):Bool return switch expr.eexpr {
		case TCall({eexpr: TIdent(name)}, _):
			switch name {
				case "__php__": true;
				case "__call__": true;
				case "__physeq__": true;
				case "__var__": true;
				case _: false;
			}
		case _: false;
	}

	/**
		Check if `expr1` and `expr2` can be reliably checked for equality only with `Boot.equal()`
	*/
	public static function needBootEqual(expr1:TExpr, expr2:TExpr):Bool {
		if (isConstantNull(expr1) || isConstantNull(expr2)) return false;
		var unknown1 = isUnknownType(expr1.etype), unknown2 = isUnknownType(expr2.etype);
		if (unknown1 && unknown2) return true;
		if (isFunctionType(expr1.etype) || isFunctionType(expr2.etype)) return true;
		var int1 = isInt(expr1), int2 = isInt(expr2), float1 = isFloat(expr1), float2 = isFloat(expr2);
		return (int1 && float2) || (float1 && (float2 || int2)) || (unknown1 && (int2 || float2)) || ((int1 || float1) && unknown2);
	}

	/**
		Adds `return` expression to block if it does not have one already
	*/
	public static function ensureReturnInBlock(blockExpr:TExpr):TExpr {
		return switch blockExpr.eexpr {
			case TBlock([]): fail(blockExpr.epos, "genphp7.ensure_return_in_block");
			case TBlock(exprs):
				var lastExpr = exprs[exprs.length - 1];
				var returnExpr:TExpr = {eexpr: TReturn(lastExpr), etype: lastExpr.etype, epos: lastExpr.epos};
				var exprs = exprs.copy();
				exprs[exprs.length - 1] = returnExpr;
				{eexpr: TBlock(exprs), etype: blockExpr.etype, epos: blockExpr.epos};
			case _: fail(blockExpr.epos, "genphp7.ensure_return_in_block");
		}
	}

	/**
		If `expr` is a block, then return list of expressions in that block.
		Otherwise returns a list with `expr` as a single item.
	*/
	public static function unpackBlock(expr:TExpr):Vector<TExpr> return switch expr.eexpr {
		case TBlock(exprs): exprs;
		case _: vector(expr);
	}

	/**
		If `expr` is a block of a single expression, then return that single expression.
		If `expr` is a block with multiple expressions, fail compilation.
		Otherwise return `expr` as-is.
	*/
	public static function unpackSingleExprBlock(expr:TExpr):TExpr return switch expr.eexpr {
		case TBlock([e]): e;
		case TBlock(_): fail(expr.epos, "genphp7.unpack_single_expr_block");
		case _: expr;
	}

	/**
		Check if specified type has rtti meta
	*/
	public static function hasRttiMeta(ctx:Gctx, mtype:ModuleType):Bool return Texpr.buildMetadata(ctx.basic, mtype) != null;

	/**
		Check if user-defined field has the same name as one of php magic methods, but with not compatible signature.
	*/
	public static function fieldNeedsRename(field:TClassField):Bool {
		return switch field.cfKind {
			case Var(_): false;
			case Method(_):
				switch field.cfName {
					case "__construct" | "__destruct" | "__call" | "__callStatic" | "__get" | "__set" | "__isset" | "__unset" | "__sleep" | "__wakeup" |
						"__toString" | "__invoke" | "__set_state" | "__clone" | "__debugInfo": !(MetadataTools.has(PhpMagic, field.cfMeta));
					case _: false;
				}
		}
	}

	/**
		Get valid `field` name.
	*/
	public static function fieldName(field:TClassField):String return if (fieldNeedsRename(field)) "__hx__renamed" + field.cfName else field.cfName;

	/**
		Check if `expr` is `Std.is`
	*/
	public static function isStdIs(expr:TExpr):Bool return switch expr.eexpr {
		case TField(_, FStatic({clPath: path}, {cfName: "is" | "isOfType"})): pathEq(path, bootTypePath) || pathEq(path, stdTypePath);
		case _: false;
	}

	/**
		Check if provided expression is actually a casting to NativeStructArray
	*/
	public static function isNativeStructArrayCast(expr:TExpr):Bool {
		return switch expr.eexpr {
			case TCall({eexpr: TField(_, field)}, _):
				switch field {
					case FStatic({clPath: {pack: ["php", "_NativeStructArray"], name: "NativeStructArray_Impl_"}}, {cfName: "__fromObject"}): true;
					case _: false;
				}
			case _: false;
		}
	}

	/**
		Check if `expr` is an anonymous object declaration
	*/
	public static function isObjectDeclaration(expr:TExpr):Bool return (revealExpr(expr)).eexpr.match(TObjectDecl(_));

	/**
		Check if `subject_arg` and `type_arg` can be generated as `$subject instanceof Type` expression.
	*/
	public static function instanceofCompatible(subjectArg:TExpr, typeArg:TExpr):Bool {
		function isRealClass(path:GlobalTypePath):Bool {
			return switch path {
				case {pack: [], name: "String"} | {pack: [], name: "Class"} | {pack: ["php", "_NativeArray"], name: "NativeArray_Impl_"}: false;
				case _: true;
			}
		}
		return switch (revealExprWithParenthesis(typeArg)).eexpr {
			case TTypeExpr(TClassDecl({clPath: path})) if (isRealClass(path)):
				var subjectArg = revealExprWithParenthesis(subjectArg);
				switch subjectArg.eexpr {
					case TLocal(_) | TField(_) | TCall(_) | TArray(_) | TConst(TThis): !(isMagic(subjectArg));
					case _: false;
				}
			case _: false;
		}
	}

	/**
		type_wrapper for classes
	*/
	public static final classes = new haxe.ds.ObjectMap<TClass, TypeWrapper>();

	public static function getClassWrapper(cls:TClass):TypeWrapper {
		var w = classes.get(cls);
		if (w == null) {
			w = new ClassWrapper(cls);
			classes.set(cls, w);
		}
		return w;
	}

	/**
		type_wrapper for enums
	*/
	public static final enums = new haxe.ds.ObjectMap<TEnum, TypeWrapper>();

	public static function getEnumWrapper(enm:TEnum):TypeWrapper {
		var w = enums.get(enm);
		if (w == null) {
			w = new EnumWrapper(enm);
			enums.set(enm, w);
		}
		return w;
	}

	/**
		type_wrapper for typedefs
	*/
	public static final typedefs = new haxe.ds.ObjectMap<TDef, TypeWrapper>();

	public static function getTypedefWrapper(tdef:TDef):TypeWrapper {
		var w = typedefs.get(tdef);
		if (w == null) {
			w = new TypedefWrapper(tdef);
			typedefs.set(tdef, w);
		}
		return w;
	}

	/**
		type_wrapper for abstracts
	*/
	public static final abstracts = new haxe.ds.ObjectMap<TAbstract, TypeWrapper>();

	public static function getAbstractWrapper(abstr:TAbstract):TypeWrapper {
		var w = abstracts.get(abstr);
		if (w == null) {
			w = new AbstractWrapper(abstr);
			abstracts.set(abstr, w);
		}
		return w;
	}

	/**
		Returns wrapper for module_type.
		Caches wrappers so that each type will always return the same wrapper instance.
	*/
	public static function getWrapper(mtype:ModuleType):TypeWrapper {
		return switch mtype {
			case TClassDecl(cls): getClassWrapper(cls);
			case TEnumDecl(enm): getEnumWrapper(enm);
			case TTypeDecl(tdef): getTypedefWrapper(tdef);
			case TAbstractDecl(abstr): getAbstractWrapper(abstr);
		}
	}

	/**
		Drop cached instances of type_wrapper
	*/
	public static function clearWrappers():Void {
		classes.clear();
		enums.clear();
		typedefs.clear();
		abstracts.clear();
	}

	/**
		Check if specified type name is used in specified namespace
	*/
	public static function typeNameUsedInNamespace(ctx:PhpGeneratorContext, typePath:GlobalTypePath, asName:String, namespace:Array<String>):Bool {
		var cache = ctx.pgcNamespacesTypesCache;
		function findAll(ns:Array<String>):Array<String> {
			var l = cache.get(ns.join("."));
			return l == null ? [] : l;
		}
		var types = switch findAll(namespace) {
			case []:
				for (ctxType in ctx.pgcCommon.types) {
					var wrapper = getWrapper(ctxType);
					var key = wrapper.getNamespace().join(".");
					var l = cache.get(key);
					if (l == null) {
						l = [];
						cache.set(key, l);
					}
					l.unshift(StringHelper.uppercase(wrapper.getName()));
				}
				findAll(namespace);
			case types: types;
		}
		return types.indexOf(StringHelper.uppercase(asName)) >= 0 && !(packEq(namespace, typePath.pack) && asName == typePath.name);
	}

	/**
		@return `tclass` instance for `php.Boot`
	*/
	public static function getBoot(com:Gctx):TClass {
		for (comType in com.types) switch comType {
			case TClassDecl(cls) if (pathEq(cls.clPath, bootTypePath)): return cls;
			case _:
		}
		return fail("php.Boot not found", Globals.nullPos, "genphp7.get_boot");
	}

	/**
		Entry point to Genphp7
	*/
	public static function generate(com:Gctx):Void {
		var ctx = new PhpGeneratorContext(com, Gctx.defined(com, Define.RealPosition),
			strSplit(Gctx.definedValueSafe(com, Define.PhpPrefix), c -> c == ".".code), getBoot(com), new haxe.ds.StringMap(),
			new haxe.ds.StringMap(), new StringBuf());
		var gen = new PhpGenerator(ctx);
		gen.initialize();
		function generate(comType:ModuleType):Void {
			var wrapper = getWrapper(comType);
			if (wrapper.needsGeneration) switch comType {
				case TClassDecl(cls): gen.generate(new ClassBuilder(ctx, cls));
				case TEnumDecl(enm): gen.generate(new EnumBuilder(ctx, enm));
				case TTypeDecl(tdef):
				case TAbstractDecl(abstr):
			}
			switch wrapper.getServiceType() {
				case null:
				case serviceType: generate(serviceType);
			}
		}
		for (t in com.types) generate(t);
		gen.finalize();
		com.resources.iter((name, data) -> writeResource(com.file, name, data));
		clearWrappers();
	}
}

/**
	Handles generation process
*/
// port: `generator` upstream; renamed because another generator module declares generators.Generator.
class PhpGenerator {
	final ctx:PhpGeneratorContext;
	var buildDir = "";
	final rootDir:String;
	var initTypes:Array<String> = [];
	var boot:Null<{builder:TypeBuilder, filename:String}> = null;
	var polyfillsSourcePath:Null<String> = null;
	var polyfillsDestPath:Null<String> = null;

	public function new(ctx:PhpGeneratorContext) {
		this.ctx = ctx;
		rootDir = core.Path.removeTrailingSlash(ctx.pgcCommon.file);
	}

	/**
		Perform required actions before actual php files generation
	*/
	public function initialize():Void {
		createOutputDirs();
	}

	/**
		Generates php file for specified type
	*/
	public function generate(builder:TypeBuilder):Void {
		Genphp7.resetContext(ctx);
		var namespace = builder.getNamespace();
		var name = builder.getName();
		var filename = (Genphp7.createDirRecursive([buildDir].concat(namespace))) + "/" + name + ".php";
		if (Gctx.defined(ctx.pgcCommon, Define.SourceMap)) builder.setSourcemapGenerator(new SourcemapBuilder(filename));
		sys.io.File.saveContent(filename, builder.getContents());
		switch builder.getSourcemapGenerator() {
			case null:
			case smap: smap.generate(ctx.pgcCommon);
		}
		if (Genphp7.pathEq(builder.getTypePath(), Genphp7.bootTypePath)) {
			boot = {builder: builder, filename: filename};
			var sourceDir = core.OcamlFilename.dirname(builder.getSourceFile());
			polyfillsSourcePath = core.OcamlFilename.concat(sourceDir, Genphp7.polyfillsFile);
			var destDir = core.OcamlFilename.dirname(filename);
			polyfillsDestPath = core.OcamlFilename.concat(destDir, Genphp7.polyfillsFile);
		} else if (builder.hasMagicInit()) {
			initTypes.unshift(Genphp7.getFullTypeName({pack: namespace, name: name}));
		}
	}

	/**
		Perform actions which should be executed after all classes were processed
	*/
	public function finalize():Void {
		generateMagicInit();
		generateEntryPoint();
		switch [polyfillsSourcePath, polyfillsDestPath] {
			case [src, dst] if (src != null && dst != null): Genphp7.copyFile(src, dst);
			case _: Genphp7.fail(Globals.nullPos, "genphp7.finalize");
		}
	}

	/**
		Generates calls to static __init__ methods in Boot.php
	*/
	public function generateMagicInit():Void {
		switch initTypes {
			case []:
			case _:
				switch boot {
					case null: Genphp7.fail(Globals.nullPos, "genphp7.generate_magic_init");
					case {filename: filename}:
						var channel = sys.io.File.append(filename, false);
						for (className in initTypes) channel.writeString(className + "::__hx__init();\n");
						channel.close();
				}
		}
	}

	/**
		Creates `index.php` which can be used as entry-point for standalone Haxe->PHP app
	*/
	public function generateEntryPoint():Void {
		switch getEntryPoint() {
			case null:
			case {uses: uses, code: entryPoint}:
				var filename = Gctx.definedValueSafe(ctx.pgcCommon, Define.PhpFront, "index.php");
				var frontDirs = Genphp7.splitFilePath(core.OcamlFilename.dirname(filename));
				if (frontDirs.length > 0) Genphp7.createDirRecursive([rootDir].concat(frontDirs));
				var libPath = [for (s in frontDirs) if (s != ".") "../"].join("") + getLibPath().join("/");
				var channel = new StringBuf();
				channel.add("<?php\n");
				channel.add(uses);
				channel.add("\n");
				channel.add("set_include_path(get_include_path().PATH_SEPARATOR.__DIR__.'/" + libPath + "');\n");
				channel.add("spl_autoload_register(\n");
				channel.add("	function($class){\n");
				channel.add("		$file = stream_resolve_include_path(str_replace('\\\\', '/', $class) .'.php');\n");
				channel.add("		if ($file) {\n");
				channel.add("			include_once $file;\n");
				channel.add("		}\n");
				channel.add("	}\n");
				channel.add(");\n");
				switch boot {
					case null: Genphp7.fail(Globals.nullPos, "genphp7.generate_entry_point");
					case {builder: builder}:
						var bootClass = Genphp7.getFullTypeName(Genphp7.addPhpPrefix(ctx, builder.getTypePath()));
						channel.add(bootClass + "::__hx__init();\n");
				}
				channel.add(entryPoint);
				sys.io.File.saveContent(rootDir + "/" + filename, channel.toString());
		}
	}

	/**
		Create necessary directories  before processing types
	*/
	function createOutputDirs():Void {
		var buildPath = [rootDir].concat(getLibPath());
		buildDir = Genphp7.createDirRecursive(buildPath);
	}

	/**
		Returns path from `index.php` to directory which will contain all generated classes
	*/
	function getLibPath():Array<String> {
		var path = Gctx.definedValueSafe(ctx.pgcCommon, Define.PhpLib, "lib");
		return Genphp7.splitFilePath(path);
	}

	/**
		Returns PHP code for entry point
	*/
	function getEntryPoint():Null<{uses:String, code:String}> {
		return switch ctx.pgcCommon.main.mainExpr {
			case null: null;
			case expr:
				var writer = new CodeWriter(ctx, {pack: [], name: ""}, "");
				writer.writeAsBlock(true, expr);
				var code = writer.getContents();
				writer.clearContents();
				writer.writeUse();
				var uses = writer.getContents();
				{uses: uses, code: code};
		}
	}
}
