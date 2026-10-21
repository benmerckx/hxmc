package generators.genphp7;

// port: the local_vars and code_writer classes of haxe/src/generators/genphp7.ml.
import core.Ast;
import core.Ast as AstTools;
import core.Globals;
import core.Globals.Pos;
import core.TType;
import core.TFunctions;
import core.TFunctions.*;
import core.TOther.ExtType;
import core.Meta as MetadataTools;
import core.StringHelper;
import core.ds.NotFound;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import context.Sourcemaps;
import generators.Genphp7;
import generators.genphp7.TypeWrappers;
import generators.Genphp7.*;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

/**
	Class to simplify collecting lists of declared and used local vars.
	Collected data is needed to generate closures correctly.
*/
class LocalVars {
	static function newTbl(size:Int):OcamlHashtbl<String, String> return new OcamlHashtbl(OcamlHash.hashString, (a, b) -> a == b, size);

	/** Hashtbl to collect local var used in current scope */
	var usedLocals = [newTbl(100)];

	/** Hashtbl to collect local vars declared in current scope */
	var declaredLocals = [newTbl(100)];

	/** Local vars which were captured in closures (passed via `use` directive in php) */
	final capturedLocals = newTbl(0);

	public function new() {}

	/**
		Clear collected data
	*/
	public function clear():Void {
		usedLocals = [newTbl(100)];
		declaredLocals = [newTbl(100)];
		capturedLocals.clear();
	}

	/**
		This method should be called upone entering deeper scope.
		E.g. right before processing a closure. Just before closure arguments handling.
	*/
	public function dive():Void {
		usedLocals.unshift(newTbl(100));
		declaredLocals.unshift(newTbl(100));
	}

	/**
		This method should be called right after leaving a scope.
		@return List of vars names used in finished scope, but declared in higher scopes.
				And list of vars names declared in finished scope.
				And list of vars names declared in finished scope and captured by closures via `use` directive
	*/
	public function pop():{higherVars:Array<String>, declaredVars:Array<String>, capturedVars:Array<String>} {
		if (usedLocals.length == 0) Globals.die("", "genphp7.local_vars#pop");
		if (declaredLocals.length == 0) Globals.die("", "genphp7.local_vars#pop");
		var used = usedLocals[0], declared = declaredLocals[0];
		var higherVars = diffLists(hashtblKeys(used), hashtblKeys(declared));
		var declaredVars = hashtblKeys(declared);
		usedLocals.shift();
		declaredLocals.shift();
		for (name in higherVars) this.used(name);
		var capturedVars = intersectLists(declaredVars, hashtblKeys(capturedLocals));
		for (name in declaredVars) capturedLocals.remove(name);
		return {higherVars: higherVars, declaredVars: declaredVars, capturedVars: capturedVars};
	}

	/**
		This method should be called right after leaving a scope.
		@return List of vars names used in finished scope, but declared in higher scopes
	*/
	public function popUsed():Array<String> return pop().higherVars;

	/**
		This method should be called right after leaving a scope.
		@return List of vars names declared in finished scope
	*/
	public function popDeclared():Array<String> return pop().declaredVars;

	/**
		Get current list of captured variables.
		After leaving a scope all vars declared in that scope get removed from a list of captured variables.
	*/
	public function popCaptured():Array<String> return pop().capturedVars;

	/**
		Specify local var name declared in current scope
	*/
	public function declared(name:String):Void {
		if (declaredLocals.length == 0) Globals.die("", "genphp7.local_vars#declared");
		declaredLocals[0].replace(name, name);
	}

	/**
		Specify local var name used in current scope
	*/
	public function used(name:String):Void {
		if (usedLocals.length == 0) Globals.die("", "genphp7.local_vars#used");
		usedLocals[0].replace(name, name);
	}

	/**
		Mark specified vars as captured by closures.
	*/
	public function captured(varNames:Array<String>):Void {
		for (name in varNames) capturedLocals.replace(name, name);
	}
}

/**
	Consumes expressions and generates php code to output buffer.
*/
class CodeWriter {
	final ctx:PhpGeneratorContext;
	final hxTypePath:GlobalTypePath;
	final phpName:String;

	/** Namespace path. E.g. ["some"; "pack"] for "some.pack.MyType" */
	final namespace:Array<String>;

	/** List of types for "use" section */
	final useTable:OcamlHashtbl<String, UsedType> = new OcamlHashtbl(OcamlHash.hashString, (a, b) -> a == b, 50);

	/** Output buffer */
	var buffer = new StringBuf();

	/** Intendation used for each line written */
	var indentation = "";

	/** Expressions nesting. E.g. "if(callFn(ident))" will be represented as [ident, callFn, if] */
	var exprHierarchy:Array<TExpr> = [];

	/** Object to collect local vars declarations and usage as we iterate through methods' expressions */
	final vars = new LocalVars();

	/** Sourcemap generator */
	var sourcemap:Null<SourcemapBuilder> = null;

	/** Indicates if `super()` expressions should be generated if spotted. */
	var hasSuperConstructor = true;

	/** The latest string written to the output buffer via `self#write_pos` method */
	var lastWrittenPos = "";

	public function new(ctx:PhpGeneratorContext, hxTypePath:GlobalTypePath, phpName:String) {
		this.ctx = ctx;
		this.hxTypePath = hxTypePath;
		this.phpName = phpName;
		namespace = getModulePath(hxTypePath);
	}

	// port: the hierarchy is a list upstream (head = innermost); here the innermost is the last element.
	inline function hierarchyAt(i:Int):Null<TExpr> return exprHierarchy[exprHierarchy.length - 1 - i];

	function parentsFrom(i:Int):Array<TExpr> {
		var result = [];
		var k = exprHierarchy.length - 1 - i;
		while (k >= 0) result.push(exprHierarchy[k--]);
		return result;
	}

	/**
		Get php name of current type
	*/
	public function getName():String return phpName;

	/**
		Returns generated file contents
	*/
	public function getContents():String return buffer.toString();

	/**
		Clears current generated content
	*/
	public function clearContents():Void buffer = new StringBuf();

	/**
		Reset current state (expr hierarchy, indentation, local vars)
	*/
	public function reset():Void {
		vars.clear();
		indent(0);
		exprHierarchy = [];
	}

	/**
		Set sourcemap generator
	*/
	public function setSourcemapGenerator(generator:SourcemapBuilder):Void sourcemap = generator;

	/**
		Get sourcemap generator
	*/
	public function getSourcemapGenerator():Null<SourcemapBuilder> return sourcemap;

	/**
		Make this writer skip generation of `super()` expression if spotted.
	*/
	public function extendsNoConstructor():Void hasSuperConstructor = false;

	/**
		Increase indentation by one level
	*/
	public function indentMore():Void indentation = indentation + "\t";

	/**
		Decrease indentation by one level
	*/
	public function indentLess():Void indentation = StringTools.rpad("", "\t", indentation.length - 1);

	/**
		Set indentation level (starting from zero for no indentation)
	*/
	public function indent(level:Int):Void indentation = StringTools.rpad("", "\t", level);

	/**
		Get indentation level (starting from zero for no indentation)
	*/
	public function getIndentation():Int return indentation.length;

	/**
		Set indentation level (starting from zero for no indentation)
	*/
	public function setIndentation(level:Int):Void indentation = StringTools.rpad("", "\t", level);

	/**
		Specify local var name declared in current scope
	*/
	public function declaredLocalVar(name:String):Void vars.declared(name);

	/**
		Adds type to "use" section if not added yet.
		If it's a top-level type then type name returned without adding to "use" section.
		@return Unique alias for specified type.
	*/
	public function use(?prefix:Null<Bool>, typePath:GlobalTypePath):String {
		if (pathEq(typePath, hxTypePath)) return phpName;
		if (getTypeName(typePath) == "") {
			return switch getModulePath(typePath) {
				case []: "\\";
				case modulePath: "\\" + (getRealPath(modulePath).join("\\")) + "\\";
			}
		}
		var origTypePath = typePath;
		var typePath:GlobalTypePath = {pack: typePath.pack, name: getRealName(typePath.name)};
		var typePath = if (prefix == false) typePath else addPhpPrefix(ctx, typePath);
		var modulePath = getModulePath(typePath);
		switch typePath {
			case {pack: [], name: typeName}:
				return "\\" + typeName;
			case _:
		}
		var aliasSource = modulePath.copy();
		aliasSource.reverse();
		function getAliasNextPart():String {
			return switch aliasSource {
				case []: fail("Failed to find already used type: " + getFullTypeName(typePath), pos(), "genphp7.code_writer#use");
				case _:
					var name = aliasSource[0];
					var rest = aliasSource.slice(1);
					aliasSource = (switch rest {
						case []: [name];
						case _: rest;
					});
					StringHelper.capitalize(name);
			}
		}
		var added = false;
		var alias = getTypeName(typePath);
		var aliasUpper = StringHelper.uppercase(alias);
		function prependAlias(prefix:String):Void {
			alias = prefix + alias;
			aliasUpper = StringHelper.uppercase(alias);
		}
		if (aliasUpper == (StringHelper.uppercase(phpName))) prependAlias(getAliasNextPart());
		while (!added) {
			try {
				if (!packEq(getModulePath(typePath), namespace) && typeNameUsedInNamespace(ctx, origTypePath, alias, namespace))
					prependAlias(getAliasNextPart())
				else {
					var usedType = useTable.find(aliasUpper);
					if (pathEq(usedType.utTypePath, typePath)) added = true else prependAlias(getAliasNextPart());
				}
			} catch (_:NotFound) {
				useTable.add(aliasUpper, {utAlias: alias, utTypePath: typePath});
				added = true;
			} catch (_:Dynamic) {
				fail(pos(), "genphp7.code_writer#use");
			}
		}
		return alias;
	}

	/**
		Extracts type path from Type.t value and execute self#use on it
		@return Unique alias for specified type.
	*/
	public function useT(forDoc:Bool = false, tInst:T):String {
		return switch follow(tInst) {
			case TEnum(tenum, _): use(tenum.ePath);
			case TInst(tcls, params):
				switch tcls.clKind {
					case KTypeParameter(_): "mixed";
					case _:
						switch [tcls.clPath, params] {
							case [{pack: [], name: "String"}, _]: "string";
							case [{pack: [], name: "Array"}, [param]] if (forDoc):
								// port: OCaml evaluates the right operand of `^` first: `use` runs before `use_t`.
								var arrayAlias = use(tcls.clPath);
								(useT(param)) + "[]|" + arrayAlias;
							case _: use(!(hasClassFlag(tcls, CExtern)), tcls.clPath);
						}
				}
			case TFun(_): use(false, {pack: [], name: "Closure"});
			case TAnon(_): "object";
			case TDynamic(_): "mixed";
			case TLazy(_): fail("TLazy not implemented", pos(), "genphp7.code_writer#use_t");
			case TMono(mono):
				switch mono.tmType {
					case null: "mixed";
					case t: useT(t);
				}
			case TType(_): fail("TType not implemented", pos(), "genphp7.code_writer#use_t");
			case TAbstract(abstr, _):
				switch abstr.aPath {
					case {pack: [], name: "Int"}: "int";
					case {pack: [], name: "Float"}: "float";
					case {pack: [], name: "Bool"}: "bool";
					case {pack: [], name: "Void"}: "void";
					case {pack: [], name: "Enum"}: "Enum";
					case {pack: [], name: "Class"}: "Class";
					case {pack: ["php"], name: "NativeArray"} if (forDoc):
						switch TFunctions.follow(tInst) {
							case TAbstract({aPath: {pack: ["php"], name: "NativeIndexedArray"}}, [param]): (useT(param)) + "[]";
							case _: "array";
						}
					case {pack: ["php"], name: "NativeArray"}: "array";
					case _ if (MetadataTools.has(CoreType, abstr.aMeta)): "mixed";
					case _: useT(abstr.aThis);
				}
		}
	}

	/**
		Position of currently generated code in source hx files
	*/
	public function pos():Pos {
		return switch hierarchyAt(0) {
			case null: Globals.nullPos;
			case e: e.epos;
		}
	}

	/**
		Indicates whether current expression nesting level is a top level of a block
	*/
	public function parentExprIsBlock(singleExprIsNotBlock:Bool):Bool {
		function exprIsBlock(expr:TExpr, parents:Array<TExpr>, noParentIsBlock:Bool):Bool {
			return switch expr.eexpr {
				case TBlock([_]) if (singleExprIsNotBlock):
					switch parents {
						case []: noParentIsBlock;
						case _:
							switch parents[0].eexpr {
								case TBlock(_): true;
								case TFunction(_): true;
								case _: false;
							}
					}
				case TBlock(_): true;
				case TIf(_, ifExpr, elseExpr) if (elseExpr != null):
					if ((exprIsBlock(ifExpr, [], false)) || (exprIsBlock(elseExpr, [], false))) true else switch parents {
						case []: false;
						case _: exprIsBlock(parents[0], parents.slice(1), true);
					}
				case TIf(_, _, null): true;
				case TTry(_): true;
				case TWhile(_): true;
				case TSwitch(_): true;
				case _: false;
			}
		}
		return if (exprHierarchy.length >= 2) exprIsBlock(hierarchyAt(1), parentsFrom(2), true) else false;
	}

	/**
		Returns parent expression  (bypasses casts and metas)
	*/
	public function parentExpr():Null<TExpr> {
		var k = exprHierarchy.length - 2;
		if (k < 0) return null;
		while (true) {
			var expr = exprHierarchy[k];
			switch expr.eexpr {
				case TCast(_, null) | TMeta(_):
					k--;
					if (k < 0) return null;
				case _:
					return expr;
			}
		}
	}

	/**
		Indicates if parent expression is a call (bypasses casts and metas)
	*/
	public function parentExprIsCall():Bool return switch parentExpr() {
		case null: false;
		case {eexpr: TCall(_)}: true;
		case _: false;
	}

	/**
		Indicates if current expression is passed to `php.Ref<T>`
	*/
	public function currentExprIsForRef():Bool {
		if (exprHierarchy.length == 0) return false;
		var current = hierarchyAt(0);
		return switch parentExpr() {
			case null: false;
			case {eexpr: TCall(target, params)} if (current != (revealExpr(target))):
				var args = switch followWithCoro(target.etype) {
					case Coro(sig): context.Common.expandCoroType(ctx.pgcCommon.basic, sig.args, sig.ret).args;
					case NotCoro(TFun(sig)): sig.args;
					case _: null;
				}
				switch args {
					case null: false;
					case args:
						var i = 0;
						while (true) {
							if (i >= args.length || i >= params.length) break;
							if (current == (revealExpr(params[i]))) return isRef(args[i].type);
							i++;
						}
						false;
				}
			case _: false;
		}
	}

	/**
		Check if currently generated expression is located in a left part of assignment.
	*/
	public function isInWriteContext():Bool {
		function isInRefArg(current:TExpr, types:Vector<{name:String, optional:Bool, type:T}>, args:Vector<TExpr>):Bool {
			// port: List.exists2; the Invalid_argument of different lengths gives false
			var n = types.length < args.length ? types.length : args.length;
			for (i in 0...n) if (args[i] == current && isRef(types[i].type)) return true;
			return false;
		}
		if (exprHierarchy.length == 0) return false;
		var current = hierarchyAt(0);
		var k = exprHierarchy.length - 2;
		while (k >= 0) {
			var parent = exprHierarchy[k];
			switch parent.eexpr {
				case TBinop(OpAssign, leftExpr, _) | TBinop(OpAssignOp(_), leftExpr, _):
					return leftExpr == current;
				case TUnop(op, _, _):
					return isModifyingUnop(op);
				case TCall({etype: TFun(sig)}, args) if (isInRefArg(current, sig.args, args)):
					return true;
				case _:
			}
			current = parent;
			k--;
		}
		return false;
	}

	/**
		Add a function call to "dereference" part of expression to avoid "Cannot use temporary expression in write context"
		erro in expressions like:
		```
		new MyClass().fieldName = 'value';
		```
	*/
	public function dereference(expr:TExpr):TExpr {
		function deref(expr:TExpr):TExpr {
			return {
				eexpr: TCall({
					eexpr: TField({eexpr: TTypeExpr(TClassDecl(ctx.pgcBoot)), etype: expr.etype, epos: expr.epos},
						FStatic(ctx.pgcBoot, core.ds.PMap.find("deref", ctx.pgcBoot.clStatics))),
					etype: expr.etype,
					epos: expr.epos
				}, vector(expr)),
				etype: expr.etype,
				epos: expr.epos
			};
		}
		return switch expr.eexpr {
			case TField(targetExpr, access):
				{eexpr: TField(deref(targetExpr), access), etype: expr.etype, epos: expr.epos};
			case TArray(targetExpr, accessExpr):
				{eexpr: TArray(deref(targetExpr), accessExpr), etype: expr.etype, epos: expr.epos};
			case _: fail(pos(), "genphp7.code_writer#dereference");
		}
	}

	/**
		Writes specified string to output buffer
	*/
	public function write(str:String):Void {
		buffer.add(str);
		if (sourcemap != null) sourcemap.insert(SMStr(str));
	}

	/**
		Writes specified string to output buffer without affecting sourcemap generator
	*/
	public function writeBypassingSourcemap(str:String):Void {
		buffer.add(str);
	}

	/**
		Writes constant double-quoted string to output buffer
	*/
	public function writeConstString(str:String):Void {
		write("\"" + (escapeBin(str)) + "\"");
	}

	/**
		Writes fixed amount of empty lines (E.g. between methods)
	*/
	public function writeEmptyLines():Void {
		write("\n");
	}

	/**
		Writes current indentation to output buffer
	*/
	public function writeIndentation():Void {
		write(indentation);
	}

	/**
		Writes current indentation followed by `str` to output buffer
	*/
	public function writeWithIndentation(str:String):Void {
		write(indentation);
		write(str);
	}

	/**
		Writes specified line to output buffer and appends \n
	*/
	public function writeLine(line:String):Void {
		write(indentation + line + "\n");
	}

	/**
		Writes specified statement to output buffer and appends ";\n"
	*/
	public function writeStatement(statement:String):Void {
		write(indentation + statement + ";\n");
	}

	/**
		Build "use" statements
	*/
	public function writeUse():Void {
		indent(0);
		function write(_:String, usedType:UsedType):Void {
			var namespace = if (pathEq(hxTypePath, {pack: [], name: ""})) namespace /* ([],"") is for index.php */
			else ctx.pgcPrefix.concat(namespace);
			if (!packEq(getModulePath(usedType.utTypePath), namespace)) {
				if (getTypeName(usedType.utTypePath) == usedType.utAlias)
					writeStatement("use " + (getFullTypeName(usedType.utTypePath)))
				else {
					var fullName = getFullTypeName(usedType.utTypePath);
					writeStatement("use " + fullName + " as " + usedType.utAlias);
				}
			}
		}
		useTable.iter(write);
	}

	/**
		Writes array item declaration to output buffer and appends ",\n"
		Adds indentation and ",\n" if `separate_line` is `true`.
	*/
	public function writeArrayItem(?separateLine:Bool, ?key:String, valueExpr:TExpr):Void {
		var separateLine = separateLine == true;
		if (separateLine) writeIndentation();
		switch key {
			case null:
				writeExpr(valueExpr);
			case keyStr:
				write((quoteString(keyStr)) + " => ");
				writeExpr(valueExpr);
		}
		if (separateLine) write(",\n");
	}

	/**
		Writes expression to output buffer
	*/
	public function writeExpr(expr:TExpr):Void {
		exprHierarchy.push(expr);
		if (sourcemap != null) sourcemap.insert(SMPos(expr.epos));
		switch expr.eexpr {
			case TConst(const): writeExprConst(const);
			case TLocal(v):
				vars.used(vname(v.vName));
				write("$" + (vname(v.vName)));
			case TArray(target, index): writeExprArrayAccess(target, index);
			case TBinop(OpAssign, {eexpr: TArray(target, index)}, value) if (isArrayType(target.etype)):
				writeExprSetArrayItem(target, index, value);
			case TBinop(operation, expr1, expr2) if (needsDereferencing(isAssignmentBinop(operation), expr1)):
				writeExpr({eexpr: TBinop(operation, dereference(expr1), expr2), etype: expr.etype, epos: expr.epos});
			case TBinop(operation, expr1, expr2): writeExprBinop(operation, expr1, expr2);
			case TField({eexpr: TArrayDecl(exprs)}, faccess) if (isArrayArr(faccess) && !currentExprIsForRef()):
				writeNativeArrayDecl(exprs);
			case TField(fexpr, access) if (isPhpGlobal(expr)): writeExprPhpGlobal(expr);
			case TField(fexpr, access) if (isPhpClassConst(expr)): writeExprPhpClassConst(expr);
			case TField(fexpr, access) if (needsDereferencing((isInWriteContext()), expr)): writeExpr(dereference(expr));
			case TField(fexpr, access): writeExprField(fexpr, access);
			case TTypeExpr(mtype): writeExprType(mtype);
			case TParenthesis(expr):
				write("(");
				writeExpr(expr);
				write(")");
			case TObjectDecl(fields): writeExprObjectDeclaration(fields);
			case TArrayDecl(exprs): writeExprArrayDecl(exprs);
			case TCall(target, [arg1, arg2]) if (isStdIs(target)): writeExprStdIs(target, arg1, arg2);
			case TCall(_, [arg]) if (isNativeStructArrayCast(expr) && isObjectDeclaration(arg)):
				switch (revealExpr(arg)).eexpr {
					case TObjectDecl(fields): writeAssocArrayDecl(fields);
					case _: fail(pos(), "genphp7.code_writer#write_expr");
				}
			case TCall({eexpr: TIdent(name)}, args) if (isMagic(expr)): writeExprMagic(name, args);
			case TCall({eexpr: TField(expr, access)}, args) if (isString(expr)): writeExprCallString(expr, access, args);
			case TCall(expr, args) if (isSyntaxExtern(expr)): writeExprCallSyntaxExtern(expr, args);
			case TCall(target, args): writeExprCall(target, args);
			case TNew(_, _, args) if (isString(expr)): writeArgs(write, writeExpr, args);
			case TNew(tcls, _, args): writeExprNew(tcls, args);
			case TUnop(operation, flag, targetExpr) if (needsDereferencing((isModifyingUnop(operation)), targetExpr)):
				writeExpr({eexpr: TUnop(operation, flag, dereference(targetExpr)), etype: expr.etype, epos: expr.epos});
			case TUnop(operation, flag, expr): writeExprUnop(operation, flag, expr);
			case TFunction(fn): writeExprFunction(fn);
			case TVar(v, expr): writeExprVar(v, expr);
			case TBlock(exprs): writeExprBlock(expr);
			case TIf(condition, ifExpr, elseExpr): writeExprIf(condition, ifExpr, elseExpr);
			case TWhile(condition, expr, whileFlag):
				switch (revealExprWithParenthesis(condition)).eexpr {
					case TField(_, FStatic({clPath: path}, {cfName: "foreachCondition"})) if (pathEq(path, syntaxTypePath)):
						writeExprSyntaxForeach(expr);
					case _:
						writeExprWhile(condition, expr, whileFlag);
				}
			case TSwitch(switch_): writeExprSwitch(switch_.switchSubject, switch_.switchCases, switch_.switchDefault);
			case TTry(tryExpr, catches): writeExprTryCatch(tryExpr, catches);
			case TReturn(expr): writeExprReturn(expr);
			case TBreak: write("break");
			case TContinue: write("continue");
			case TThrow(expr): writeExprThrow(expr);
			case TCast(expr, mtype): writeExprCast(expr, mtype);
			case TMeta(_, expr): writeExpr(expr);
			case TEnumParameter(expr, constructor, index): writeExprEnumParameter(expr, constructor, index);
			case TEnumIndex(expr): writeExprEnumIndex(expr);
			case TIdent(s): write(s);
		}
		exprHierarchy.pop();
	}

	/**
		Writes TConst to output buffer
	*/
	public function writeExprConst(const:TConstant):Void {
		switch const {
			case TFloat(str): write(str);
			case TString(str): writeConstString(str);
			case TBool(value): write(if (value) "true" else "false");
			case TNull: write("null");
			case TThis: write("$this");
			case TSuper: write("parent");
			case TInt(value):
				/* See https://github.com/HaxeFoundation/haxe/issues/5289 */
				if (value == -2147483648) write("((int)-2147483648)") else write(Std.string(value));
		}
	}

	/**
		Writes TArrayDecl to output buffer
	*/
	public function writeExprArrayDecl(exprs:Vector<TExpr>):Void {
		switch exprs {
			case []:
				function decl() write("new " + (use(arrayTypePath)) + "()");
				/* Wrap into parentheses if trying to access items of empty array declaration */
				switch parentExpr() {
					case null: decl();
					case {eexpr: TArray(_)}:
						write("(");
						decl();
						write(")");
					case _:
						decl();
				}
			case _:
				write((use(arrayTypePath)) + "::wrap(");
				writeNativeArrayDecl(exprs);
				write(")");
		}
	}

	/**
		Writes native array declaration to output buffer
	*/
	public function writeNativeArrayDecl(exprs:Vector<TExpr>):Void {
		switch exprs {
			case []:
				write("[]");
			case [expr]:
				write("[");
				writeExpr(expr);
				write("]");
			case _:
				write("[\n");
				indentMore();
				for (expr in exprs) writeArrayItem(true, expr);
				indentLess();
				writeWithIndentation("]");
		}
	}

	/**
		Write associative array declaration
	*/
	public function writeAssocArrayDecl(fields:Vector<{key:{name:String, pos:Pos, quote:QuoteStatus}, expr:TExpr}>):Void {
		switch fields {
			case []: write("[]");
			case [{key: {name: key}, expr: value}]:
				write("[");
				writeArrayItem(key, value);
				write("]");
			case _:
				write("[\n");
				indentMore();
				function writeField(f:{key:{name:String, pos:Pos, quote:QuoteStatus}, expr:TExpr}) writeArrayItem(true, f.key.name, f.expr);
				for (f in fields) writeField(f);
				indentLess();
				writeWithIndentation("]");
		}
	}

	/**
		Writes `target[index] = value` assuming `target` is of `Array` type
	*/
	public function writeExprSetArrayItem(target:TExpr, index:TExpr, value:TExpr):Void {
		writeExpr(target);
		write("->offsetSet(");
		writeArgs(write, writeExpr, [index, value]);
		write(")");
	}

	/**
		Writes TArray to output buffer
	*/
	public function writeExprArrayAccess(target:TExpr, index:TExpr):Void {
		function writeIndex(leftBracket:String, rightBracket:String):Void {
			write(leftBracket);
			writeExpr(index);
			write(rightBracket);
		}
		function writeFastAccess():Void {
			write("(");
			writeExpr(target);
			write("->arr");
			writeIndex("[", "] ?? null)");
		}
		function writeNormalAccess():Void {
			writeExpr(target);
			writeIndex("[", "]");
		}
		switch follow(target.etype) {
			case TInst({clPath: path}, _) if (pathEq(path, arrayTypePath)):
				if (isInWriteContext()) writeNormalAccess() else writeFastAccess();
			case _:
				writeNormalAccess();
		}
	}

	/**
		Writes TVar to output buffer
	*/
	public function writeExprVar(v:TVar, expr:Null<TExpr>):Void {
		vars.declared(vname(v.vName));
		write("$" + (vname(v.vName)) + " = ");
		switch expr {
			case null: write("null");
			case expr: writeExpr(expr);
		}
	}

	/**
		Writes TFunction to output buffer
	*/
	public function writeExprFunction(func:TFunc):Void {
		writeClosureDeclaration(func, writeFunctionArg);
	}

	/**
		Writes closure declaration to output buffer
	*/
	public function writeClosureDeclaration(func:TFunc, writeArg:{variable:TVar, defaultValue:Null<TExpr>}->Void):Void {
		vars.dive();
		write("function (");
		writeArgs(write, writeArg, fixTfuncArgs(func.tfArgs));
		write(")");
		/* Generate closure body to separate buffer */
		var originalBuffer = buffer;
		var smPointerBeforeBody = Sourcemaps.getSourcemapPointer(sourcemap);
		buffer = new StringBuf();
		writeExpr(injectDefaults(ctx, func));
		var body = buffer.toString();
		buffer = originalBuffer;
		Sourcemaps.setSourcemapPointer(sourcemap, smPointerBeforeBody);
		/* Capture local vars used in closures */
		var usedVars = vars.popUsed();
		vars.captured(usedVars);
		write(" ");
		if (usedVars.length > 0) {
			write("use (");
			writeArgs(write, (name:String) -> write("&$" + name), usedVars);
			write(") ");
		}
		writeBypassingSourcemap(body);
		if (sourcemap != null) sourcemap.fastForward();
	}

	/**
		Writes TBlock to output buffer
	*/
	public function writeExprBlock(blockExpr:TExpr):Void {
		/* Check if parent expr could not contain blocks in PHP, and this block needs to be wrapped in a closure. */
		var needsClosure = switch parentExpr() {
			case null: false;
			case e:
				switch e.eexpr {
					case TIf(_, _, _): false;
					case TWhile(_, _, _): false;
					case TTry(_, _): false;
					case TFunction(_): false;
					case TBlock(_): false;
					case TSwitch(_): false;
					case _: true;
				}
		}
		if (needsClosure) {
			write("(");
			writeExpr({
				eexpr: TFunction({
					tfArgs: vector(),
					tfType: blockExpr.etype,
					tfExpr: ensureReturnInBlock(blockExpr),
				}),
				etype: blockExpr.etype,
				epos: blockExpr.epos
			});
			write(")()");
		} else {
			var inlineBlock = parentExprIsBlock(false);
			writeAsBlock(inlineBlock, blockExpr);
		}
	}

	/**
		Emulates TBlock for parent expression and writes `expr` as inlined block
	*/
	public function writeFakeBlock(expr:TExpr):Void {
		switch expr.eexpr {
			case TBlock([]):
			case _:
				writeIndentation();
				var fakeBlock:TExpr = {eexpr: TBlock(vector(expr)), etype: expr.etype, epos: expr.epos};
				exprHierarchy.push(fakeBlock);
				writeAsBlock(true, expr);
				exprHierarchy.pop();
		}
	}

	/**
		Write position of specified expression to output buffer
	*/
	public function writePos(expr:TExpr):Bool {
		var pos = ("#" + (stringifyPos(expr.epos)) + "\n");
		if (pos == lastWrittenPos) return false;
		lastWrittenPos = pos;
		write(pos);
		return true;
	}

	/**
		Writes "{ <expressions> }" to output buffer
	*/
	public function writeAsBlock(?inline_:Bool, ?unsetLocals:Bool, expr:TExpr):Void {
		var unsetLocals = unsetLocals == true;
		var exprs = switch expr.eexpr {
			case TBlock(exprs): exprs;
			case _: vector(expr);
		}
		function writeBody():Void {
			function writeExpr_(expr:TExpr):Void {
				if (!ctx.pgcSkipLineDirectives && !(isBlock(expr)) && !posEq(expr.epos, Globals.nullPos))
					if (writePos(expr)) writeIndentation();
				switch expr.eexpr {
					case TBlock(_):
						writeAsBlock(true, expr);
					case _:
						writeExpr(expr);
						switch expr.eexpr {
							case TBlock(_) | TIf(_) | TTry(_) | TSwitch(_) | TWhile(_, _, NormalWhile): write("\n");
							case _: write(";\n");
						}
				}
			}
			function writeExprWithIndent(expr:TExpr):Void {
				writeIndentation();
				writeExpr_(expr);
			}
			function writeExprs():Void {
				switch exprs {
					case []:
					case _:
						writeExpr_(exprs[0]); /* write first expression without indentation in case of block inlining */
						for (i in 1...exprs.length) writeExprWithIndent(exprs[i]);
				}
			}
			if (unsetLocals) {
				var originalBuffer = buffer;
				var smPointerBeforeBody = Sourcemaps.getSourcemapPointer(sourcemap);
				buffer = new StringBuf();
				vars.dive();
				writeExprs();
				var body = buffer.toString();
				buffer = originalBuffer;
				Sourcemaps.setSourcemapPointer(sourcemap, smPointerBeforeBody);
				var locals = vars.popCaptured();
				if (locals.length > 0) {
					write("unset($" + (locals.join(", $")) + ");\n");
					writeIndentation();
				}
				writeBypassingSourcemap(body);
				if (sourcemap != null) sourcemap.fastForward();
			} else
				writeExprs();
		}
		if (inline_ == true) writeBody() else {
			write("{\n");
			indentMore();
			switch exprs {
				case []:
				case _:
					writeIndentation(); /* indentation for the first expression in block */
					writeBody();
			}
			indentLess();
			writeWithIndentation("}");
		}
	}

	/**
		Writes TReturn to output buffer
	*/
	public function writeExprReturn(expr:Null<TExpr>):Void {
		switch expr {
			case null: write("return");
			case expr:
				write("return ");
				writeExpr(expr);
		}
	}

	/**
		Writes TThrow to output buffer
	*/
	public function writeExprThrow(expr:TExpr):Void {
		write("throw ");
		writeExpr(expr);
	}

	/**
		Writes try...catch to output buffer
	*/
	public function writeExprTryCatch(tryExpr:TExpr, catches:Vector<{variable:TVar, expr:TExpr}>):Void {
		write("try ");
		writeAsBlock(tryExpr);
		for (c in catches) {
			var v = c.variable, body = c.expr;
			write(" catch(" + (useT(v.vType)) + " $" + (vname(v.vName)) + ") ");
			vars.declared(vname(v.vName));
			writeAsBlock(body);
		}
	}

	/**
		Writes TCast to output buffer
	*/
	public function writeExprCast(expr:TExpr, mtype:Null<ModuleType>):Void {
		switch mtype {
			case null: writeExpr(expr);
			case mtype:
				write((use(bootTypePath)) + "::typedCast(");
				writeExprType(mtype);
				write(", ");
				writeExpr(expr);
				write(")");
		}
	}

	/**
		Write Haxe->PHP magic function call
		@see http://old.haxe.org/doc/advanced/magic#php-magic
	*/
	public function writeExprMagic(name:String, args:Vector<TExpr>):Void {
		var error = ("Invalid arguments for " + name + " magic call");
		switch args {
			case []: fail(error, pos(), "genphp7.code_writer#write_expr_magic");
			case _ if (args[0].eexpr.match(TConst(TString(_)))):
				var expr = args[0];
				var code = switch expr.eexpr {
					case TConst(TString(code)): code;
					case _: throw "unreachable";
				}
				var args = args.slice(1);
				switch name {
					case "__php__":
						switch expr.eexpr {
							case TConst(TString(php)):
								codegen.Codegen.interpolateCode(ctx.pgcCommon.error, php, args.toArray(), write, writeExpr, pos());
							case _: fail(pos(), "genphp7.code_writer#write_expr_magic");
						}
					case "__call__":
						write(code + "(");
						writeArgs(write, writeExpr, args);
						write(")");
					case "__physeq__":
						switch args {
							case [expr2]: writeExprBinop(OpEq, expr, expr2);
							case _: fail(error, pos(), "genphp7.code_writer#write_expr_magic");
						}
					case "__var__":
						switch args {
							case []:
								write("$" + code);
							case [expr2]:
								write("$" + code + "[");
								writeExpr(expr2);
								write("]");
							case _: fail(error, pos(), "genphp7.code_writer#write_expr_magic");
						}
					case _: fail(error, pos(), "genphp7.code_writer#write_expr_magic");
				}
			case [expr1, expr2]:
				switch name {
					case "__physeq__":
						switch args {
							case [expr1, expr2]: writeExprBinop(OpEq, expr1, expr2);
							case _: fail(error, pos(), "genphp7.code_writer#write_expr_magic");
						}
					case _: fail(error, pos(), "genphp7.code_writer#write_expr_magic");
				}
			case _: fail(error, pos(), "genphp7.code_writer#write_expr_magic");
		}
	}

	/**
		Writes TTypeExpr to output buffer
	*/
	public function writeExprType(mtype:ModuleType):Void {
		var ttype = typeOfModuleType(mtype);
		switch parentExpr() {
			/* When type is used to access type fields. E.g. `TypeExpr.someField` */
			case p if (p != null && p.eexpr.match(TField(_, FStatic(_)) | TField(_, FEnum(_)))):
				write(useT(ttype));
			/* Other cases */
			case _:
				var className = switch useT(ttype) {
					case "int": "'Int'";
					case "float": "'Float'";
					case "bool": "'Bool'";
					case "string": "'String'";
					case "array": "'array'";
					case "mixed": "'Dynamic'";
					case "Enum": "'Enum'";
					case "Class": "'Class'";
					case name: name + "::class";
				}
				write((use(bootTypePath)) + "::getClass(" + className + ")");
		}
	}

	/**
		Writes binary operation to output buffer
	*/
	public function writeExprBinop(operation:Binop, expr1:TExpr, expr2:TExpr):Void {
		function writeMethod(methodName:String):Void {
			write(methodName + "(");
			writeExpr(expr1);
			write(", ");
			writeExpr(expr2);
			write(")");
		}
		function writeForConcat(expr:TExpr):Void {
			if (((isConstant(expr)) && !(isConstantNull(expr))) || (isConcatenation(expr)) || isPhpGlobal(expr) || isPhpClassConst(expr))
				writeExpr(expr)
			else switch (revealExpr(expr)).eexpr {
				case TConst(TNull): write("'null'");
				case TBinop(_) | TUnop(_): writeExpr(parenthesis(expr));
				case TParenthesis({eexpr: (TBinop(_) | TUnop(_))}) | TCall({
					eexpr: TField(_, FStatic({clPath: {pack: [], name: "Std"}}, {cfName: "string"}))
				}, [_]):
					writeExpr(expr);
				case _:
					write("(");
					writeExpr(expr);
					write("??'null')");
			}
		}
		function writeBinop(?writer:TExpr->Void, ?rightWriter:TExpr->Void, str:String):Void {
			var writeLeft = switch writer {
				case null: writeExpr;
				case writer: writer;
			}
			var writeRight = switch rightWriter {
				case null: writeLeft;
				case writer: writer;
			}
			var needParenthesis = switch parentExpr() {
				case null: false;
				case {eexpr: TBinop(parent, _, _)}: needParenthesisForBinop(operation, parent);
				case _: false;
			}
			if (needParenthesis) write("(");
			writeLeft(expr1);
			write(str);
			writeRight(expr2);
			if (needParenthesis) write(")");
		}
		function compareStrings(op:String):Void {
			writeMethod("strcmp");
			write(op + "0");
		}
		function compare(op:String):Void {
			if (isString(expr1) && isString(expr2)) compareStrings(op) else writeBinop(op);
		}
		switch operation {
			case OpAdd:
				if ((isString(expr1)) || (isString(expr2))) writeBinop(writeForConcat, " . ") else if ((isUnknownType(expr1.etype))
					&& (isUnknownType(expr2.etype))) writeMethod((use(bootTypePath)) + "::addOrConcat") else writeBinop(" + ");
			case OpEq:
				if (needBootEqual(expr1, expr2)) writeMethod((use(bootTypePath)) + "::equal") else writeBinop(" === ");
			case OpNotEq:
				if (needBootEqual(expr1, expr2)) {
					write("!");
					writeMethod((use(bootTypePath)) + "::equal");
				} else
					writeBinop(" !== ");
			case OpMod:
				if (isInt(expr1) && isInt(expr2)) writeBinop(" % ") else writeMethod("fmod");
			case OpUShr: writeMethod((use(bootTypePath)) + "::shiftRightUnsigned");
			case OpAssignOp(OpAdd):
				if ((isString(expr1))) {
					writeExpr(expr1);
					write(" = ");
					writeBinop(writeForConcat, " . ");
				} else if ((isUnknownType(expr1.etype)) && (isUnknownType(expr2.etype))) {
					writeExpr(expr1);
					write(" = ");
					writeMethod((use(bootTypePath)) + "::addOrConcat");
				} else
					writeBinop(" += ");
			case OpAssignOp(OpMod):
				if (isInt(expr1) && isInt(expr2)) writeBinop(" %= ") else {
					writeExpr(expr1);
					write(" = ");
					writeMethod("fmod");
				}
			case OpAssignOp(OpUShr):
				writeExpr(expr1);
				write(" = ");
				writeMethod((use(bootTypePath)) + "::shiftRightUnsigned");
			case OpGt | OpGte | OpLt | OpLte:
				compare(" " + (AstTools.sBinop(operation)) + " ");
			case OpDiv if (isConstantZero(revealExprWithParenthesis(expr2))):
				writeMethod((use(bootTypePath)) + "::divByZero");
			case _:
				writeBinop(" " + (AstTools.sBinop(operation)) + " ");
		}
	}

	/**
		Writes TUnOp to output buffer
	*/
	public function writeExprUnop(operation:Unop, flag:UnopFlag, expr:TExpr):Void {
		switch flag {
			case Prefix:
				write(AstTools.sUnop(operation));
				writeExpr(expr);
			case Postfix:
				writeExpr(expr);
				write(AstTools.sUnop(operation));
		}
	}

	function writeExprForFieldAccess(expr:TExpr, accessStr:String, fieldStr:String):Void {
		var accessStr = accessStr;
		switch (revealExpr(expr)).eexpr {
			case TNew(_) | TArrayDecl(_) | TObjectDecl(_): writeExpr(parenthesis(expr));
			case TConst(TSuper):
				write("parent");
				accessStr = "::";
			case _: writeExpr(expr);
		}
		write(accessStr + fieldStr);
	}

	/**
		Writes TField to output buffer
	*/
	public function writeExprField(expr:TExpr, access:TFieldAccess):Void {
		switch access {
			case FInstance({clPath: {pack: [], name: "String"}}, _, {cfName: "length", cfKind: Var(_)}):
				write("mb_strlen(");
				writeExpr(expr);
				write(")");
			case FInstance(_, _, field): writeExprForFieldAccess(expr, "->", (fieldName(field)));
			case FStatic(_, field = {cfKind: Var(_)}):
				switch (revealExpr(expr)).eexpr {
					case TTypeExpr(_): writeExprForFieldAccess(expr, "::", ("$" + (fieldName(field))));
					case _: writeExprForFieldAccess(expr, "->", (fieldName(field)));
				}
			case FStatic(_, field = {cfKind: Method(MethDynamic)}):
				switch parentExpr() {
					case p if (p != null && switch p.eexpr {
						case TCall({eexpr: TField(e, a)}, _): a == access;
						case _: false;
					}):
						write("(");
						writeExprForFieldAccess(expr, "::", ("$" + (fieldName(field))));
						write(")");
					case _:
						writeExprForFieldAccess(expr, "::", ("$" + (fieldName(field))));
				}
			case FStatic(_, field = {cfKind: Method(_)}): writeExprFieldStatic(expr, field);
			case FAnon(field):
				var writtenAsProbableString = writeExprFieldIfString(expr, (fieldName(field)));
				if (!writtenAsProbableString) writeExprForFieldAccess(expr, "->", (fieldName(field)));
			case FDynamic(fieldName): writeExprFieldDynamic(expr, fieldName);
			case FClosure(tcls, field): writeExprFieldClosure(tcls, field, expr);
			case FEnum(_, field):
				writeExprFieldEnum(expr, field);
		}
	}

	/**
		Generate EField for enum constructor.
	*/
	public function writeExprFieldEnum(expr:TExpr, field:TEnumField):Void {
		function writeField():Void {
			writeExpr(expr);
			var accessOperator = switch (revealExpr(expr)).eexpr {
				case TTypeExpr(_): "::";
				case _: "->";
			}
			write(accessOperator + field.efName);
		}
		if (isEnumConstructorWithArgs(field)) {
			switch parentExpr() {
				case null: writeStaticMethodClosure(expr, field.efName);
				/* Invoking this enum field */
				case {eexpr: TCall({eexpr: TField(targetExpr, FEnum(_, targetField))}, _)} if (targetExpr == expr && targetField == field):
					writeField();
				/* Passing this enum field somewhere */
				case _:
					writeStaticMethodClosure(expr, field.efName);
			}
		} else {
			writeField();
			write("()");
		}
	}

	/**
		Writes field access on Dynamic expression to output buffer.
		Returns `true` if requested field is most likely belongs to String (and field resolution will be handled at runtime).
		Otherwise returns `false`
	*/
	public function writeExprFieldIfString(expr:TExpr, fieldName:String):Bool {
		/* Special case for String fields */
		return switch fieldName {
			case "length" | "toUpperCase" | "toLowerCase" | "charAt" | "indexOf" | "lastIndexOf" | "split" | "toString" | "substring" | "substr" |
				"charCodeAt":
				write((use(hxdynamicstrTypePath)) + "::wrap(");
				writeExpr(expr);
				write(")->" + fieldName);
				true;
			case _:
				false;
		}
	}

	/**
		Convert field access expressions for strings to native PHP string functions and write to output buffer
	*/
	public function writeExprCallString(expr:TExpr, access:TFieldAccess, args:Vector<TExpr>):Void {
		switch access {
			case FInstance(_, _, field = {cfKind: Method(_)}) | FClosure(_, field = {cfKind: Method(_)}):
				write((use(hxstringTypePath)) + "::" + (fieldName(field)) + "(");
				writeArgs(write, writeExpr, (fixCallArgs(ctx.pgcCommon.basic, field.cfType, VectorTools.cons(expr, args))));
				write(")");
			case _:
				var msg = "Unexpected field access " + (core.TPrinting.sFieldAccess(t -> core.TPrinting.sType(core.TPrinting.printContext(), t), access));
				fail(msg, pos(), "genphp7.code_writer#write_expr_call_string");
		}
	}

	/**
		Writes FStatic field access for methods to output buffer
	*/
	public function writeExprFieldStatic(expr:TExpr, field:TClassField):Void {
		function writeExpr_():Void {
			switch expr.eexpr {
				case TTypeExpr(TClassDecl({clPath: {pack: [], name: "String"}})): write(use(hxstringTypePath));
				case _: writeExpr(expr);
			}
		}
		var operator_ = switch (revealExpr(expr)).eexpr {
			case TTypeExpr(TClassDecl(c = {clPath: {name: ""}})) if (hasClassFlag(c, CExtern)): "";
			case TTypeExpr(_): "::";
			case _: "->";
		}
		switch parentExpr() {
			case null: writeStaticMethodClosure(expr, field.cfName);
			case {eexpr: TCall({eexpr: TField(e, FStatic(_, f))}, _)} if (e == expr && f == field):
				writeExpr_();
				write(operator_ + (fieldName(field)));
			case _:
				writeStaticMethodClosure(expr, field.cfName);
		}
	}

	/**
		Generates a closure of a static method. `expr` should contain a `HxClass` instance or a string name of a class.
	*/
	public function writeStaticMethodClosure(expr:TExpr, fieldName:String):Void {
		var expr = revealExpr(expr);
		write((use(bootTypePath)) + "::getStaticClosure(");
		switch (revealExpr(expr)).eexpr {
			case TTypeExpr(TClassDecl({clPath: {pack: [], name: "String"}})):
				write((use(hxstringTypePath)) + "::class");
			case TTypeExpr(_):
				writeExpr(expr);
				write("::class");
			case _:
				writeExpr(expr);
				write("->phpClassName");
		}
		write(", '" + fieldName + "')");
	}

	/**
		Writes FClosure field access to output buffer
	*/
	public function writeExprFieldClosure(tcls:Null<{cls:TClass, params:TParams}>, field:TClassField, expr:TExpr):Void {
		if (isDynamicMethod(field)) {
			switch expr.eexpr {
				case TTypeExpr(mtype):
					var className = useT(typeOfModuleType(mtype));
					write(className + "::$" + (fieldName(field)) + "'");
				case _:
					writeExpr(expr);
					write("->" + (fieldName(field)));
			}
		} else {
			var newClosure = ((use(bootTypePath)) + "::getInstanceClosure");
			switch expr.eexpr {
				case TTypeExpr(mtype):
					var className = useT(typeOfModuleType(mtype));
					write(newClosure + "(" + className + "::class, '" + (fieldName(field)) + "')");
				case _:
					switch follow(expr.etype) {
						case TInst({clPath: {pack: [], name: "String"}}, []):
							write("(new " + (use(hxdynamicstrTypePath)) + "(");
							writeExpr(expr);
							write("))->" + (fieldName(field)));
						case _:
							write(newClosure + "(");
							writeExpr(expr);
							write(", '" + (fieldName(field)) + "')");
					}
			}
		}
	}

	/**
		Write anonymous object declaration to output buffer
	*/
	public function writeExprObjectDeclaration(fields:Vector<{key:{name:String, pos:Pos, quote:QuoteStatus}, expr:TExpr}>):Void {
		switch fields {
			case []: write("new " + (use(hxanonTypePath)) + "()");
			case _:
				write("new " + (use(hxanonTypePath)) + "(");
				writeAssocArrayDecl(fields);
				write(")");
		}
	}

	/**
		Writes specified type to output buffer depending on type of expression.
	*/
	public function writeType(typeExpr:TExpr):Void {
		switch typeExpr.eexpr {
			case TTypeExpr(TClassDecl(tcls)):
				write(useT(TInst(tcls, vector())));
			case _:
				if (isString(revealExpr(typeExpr))) writeExpr(typeExpr) else {
					write("(");
					writeExpr(typeExpr);
					write("->phpClassName)");
				}
		}
	}

	/**
		Write language specific expression declared in `php.Syntax` extern
	*/
	public function writeExprCallSyntaxExtern(expr:TExpr, args:Vector<TExpr>):Void {
		var name = switch expr.eexpr {
			case TField(_, FStatic(_, field)): fieldName(field);
			case _: fail(pos(), "genphp7.code_writer#write_expr_call_syntax_extern");
		}
		switch name {
			case "code" | "codeDeref": writeExprSyntaxCode(args);
			case "coalesce": writeExprSyntaxCoalesce(args);
			case "instanceof": writeExprSyntaxInstanceof(args);
			case "nativeClassName": writeExprSyntaxNativeClassName(args);
			case "construct": writeExprSyntaxConstruct(args);
			case "field" | "getField": writeExprSyntaxGetField(args);
			case "setField": writeExprSyntaxSetField(args);
			case "getStaticField": writeExprSyntaxGetStaticField(args);
			case "setStaticField": writeExprSyntaxSetStaticField(args);
			case "call": writeExprSyntaxCall(args);
			case "staticCall": writeExprSyntaxStaticCall(args);
			case "arrayDecl": writeExprSyntaxArrayDecl(args);
			case "assocDecl": writeExprSyntaxAssocDecl(args);
			case "suppress": writeExprSyntaxSuppress(args);
			case "keepVar":
			case _: ctx.pgcCommon.error("php.Syntax." + name + "() is not supported.", pos());
		}
	}

	/**
		Writes plain php code (for `php.Syntax.code()`)
	*/
	public function writeExprSyntaxCode(args:Vector<TExpr>):Void {
		switch args {
			case []: fail(pos(), "genphp7.code_writer#write_expr_syntax_code");
			case _ if (args[0].eexpr.match(TConst(TString(_)))):
				var php = switch args[0].eexpr {
					case TConst(TString(php)): php;
					case _: throw "unreachable";
				}
				var args = args.slice(1).mapToArray(arg -> switch (revealExpr(arg)).eexpr {
					case TBinop(_) | TUnop(_): parenthesis(arg);
					case _: arg;
				});
				codegen.Codegen.interpolateCode(ctx.pgcCommon.error, php, args, write, writeExpr, pos());
			case _: ctx.pgcCommon.error("First argument of php.Syntax.code() must be a constant string.", pos());
		}
	}

	/**
		Writes error suppression operator (for `php.Syntax.suppress()`)
	*/
	public function writeExprSyntaxSuppress(args:Vector<TExpr>):Void {
		switch args {
			case [argsExpr]:
				write("@");
				writeExpr(argsExpr);
			case _: fail(pos(), "genphp7.code_writer#write_expr_syntax_suppress");
		}
	}

	/**
		Writes native array declaration (for `php.Syntax.arrayDecl()`)
	*/
	public function writeExprSyntaxArrayDecl(args:Vector<TExpr>):Void {
		write("[");
		writeArgs(write, (e:TExpr) -> writeExpr(e), args);
		write("]");
	}

	/**
		Writes native array declaration (for `php.Syntax.arrayDecl()`)
	*/
	public function writeExprSyntaxAssocDecl(args:Vector<TExpr>):Void {
		switch args {
			case []: writeAssocArrayDecl(vector());
			case [{eexpr: TObjectDecl(fields)}]: writeAssocArrayDecl(fields);
			case _: ctx.pgcCommon.error("php.Syntax.assocDecl() accepts object declaration only.", pos());
		}
	}

	/**
		Writes `e` to be used as a field access.
		If `e` is a constant string, writes the constant without quotes.
		Otherwise writes `{e}`
	*/
	public function writeSyntaxFieldExpr(fieldExpr:TExpr):Void {
		switch revealExpr(fieldExpr) {
			case {eexpr: TConst(TString(methodName))}:
				write(methodName);
			case _:
				write("{");
				writeExpr(fieldExpr);
				write("}");
		}
	}

	/**
		Writes a call to instance method (for `php.Syntax.call()`)
	*/
	public function writeExprSyntaxCall(args:Vector<TExpr>):Void {
		if (args.length >= 2) {
			var objExpr = args[0], methodExpr = args[1], args = args.slice(2);
			writeExpr(objExpr);
			write("->");
			writeSyntaxFieldExpr(methodExpr);
			write("(");
			writeArgs(write, (e:TExpr) -> writeExpr(e), args);
			write(")");
		} else
			fail(pos(), "genphp7.code_writer#write_expr_syntax_call");
	}

	/**
		Writes a call to a static method (for `php.Syntax.staticCall()`)
	*/
	public function writeExprSyntaxStaticCall(args:Vector<TExpr>):Void {
		if (args.length >= 2) {
			var typeExpr = args[0], methodExpr = args[1], args = args.slice(2);
			writeType(typeExpr);
			write("::");
			writeSyntaxFieldExpr(methodExpr);
			write("(");
			writeArgs(write, (e:TExpr) -> writeExpr(e), args);
			write(")");
		} else
			fail(pos(), "genphp7.code_writer#write_expr_syntax_static_call");
	}

	/**
		Writes field access for reading (for `php.Syntax.getField()`)
	*/
	public function writeExprSyntaxGetField(args:Vector<TExpr>):Void {
		switch args {
			case [objExpr, fieldExpr]:
				writeExpr(objExpr);
				write("->");
				writeSyntaxFieldExpr(fieldExpr);
			case _: fail(pos(), "genphp7.code_writer#write_expr_syntax_get_field");
		}
	}

	/**
		Writes field access for writing (for `php.Syntax.setField()`)
	*/
	public function writeExprSyntaxSetField(args:Vector<TExpr>):Void {
		switch args {
			case [objExpr, fieldExpr, valueExpr]:
				writeExpr(objExpr);
				write("->{");
				writeExpr(fieldExpr);
				write("}");
				write(" = ");
				writeExpr(valueExpr);
			case _: fail(pos(), "genphp7.code_writer#write_expr_syntax_set_field");
		}
	}

	/**
		Writes static field access for reading (for `php.Syntax.getStaticField()`)
	*/
	public function writeExprSyntaxGetStaticField(args:Vector<TExpr>):Void {
		switch args {
			case [typeExpr, fieldExpr]:
				writeType(typeExpr);
				write("::${");
				writeExpr(fieldExpr);
				write("}");
			case _: fail(pos(), "genphp7.code_writer#write_expr_syntax_get_static_field");
		}
	}

	/**
		Writes static field access for writing (for `php.Syntax.setField()`)
	*/
	public function writeExprSyntaxSetStaticField(args:Vector<TExpr>):Void {
		switch args {
			case [typeExpr, fieldExpr, valueExpr]:
				writeExpr(typeExpr);
				write("::${");
				writeExpr(fieldExpr);
				write("}");
				write(" = ");
				writeExpr(valueExpr);
			case _: fail(pos(), "genphp7.code_writer#write_expr_syntax_set_static_field");
		}
	}

	/**
		Writes `new` expression with class name taken local variable (for `php.Syntax.construct()`)
	*/
	public function writeExprSyntaxConstruct(args:Vector<TExpr>):Void {
		if (args.length == 0) fail(pos(), "genphp7.code_writer#write_expr_syntax_construct");
		var classExpr = args[0], args = args.slice(1);
		write("new ");
		writeExpr(classExpr);
		switch follow(classExpr.etype) {
			case TInst({clPath: {pack: [], name: "String"}}, _):
			case _: write("->phpClassName");
		}
		write("(");
		writeArgs(write, (e:TExpr) -> writeExpr(e), args);
		write(")");
	}

	/**
		Writes `$left ?? $right` expression to output buffer (for `php.Syntax.coalesce()`)
	*/
	public function writeExprSyntaxCoalesce(args:Vector<TExpr>):Void {
		switch args {
			case [left, right]:
				write("(");
				writeExpr(left);
				write(" ?? ");
				writeExpr(right);
				write(")");
			case _: fail(pos(), "genphp7.code_writer#write_expr_syntax_coalesce");
		}
	}

	/**
		Writes `instanceof` expression to output buffer (for `php.Syntax.instanceof()`)
	*/
	public function writeExprSyntaxInstanceof(args:Vector<TExpr>):Void {
		switch args {
			case [valExpr, typeExpr]:
				write("(");
				writeExpr(valExpr);
				write(" instanceof ");
				switch (revealExpr(typeExpr)).eexpr {
					case TTypeExpr(TClassDecl(tcls)):
						write(useT(TInst(tcls, vector())));
					case _:
						writeExpr(typeExpr);
						if (!(isString(typeExpr))) write("->phpClassName");
				}
				write(")");
			case _: fail(pos(), "genphp7.code_writer#write_expr_syntax_instanceof");
		}
	}

	/**
		Writes either a "Cls::class" expression (if class is passed directly) or a `$cls->phpClassName` expression
		(if class is passed as a variable) to output buffer (for `php.Syntax.nativeClassName()`)
	*/
	public function writeExprSyntaxNativeClassName(args:Vector<TExpr>):Void {
		switch args {
			case [clsExpr]:
				switch (revealExpr(clsExpr)).eexpr {
					case TTypeExpr(mtype):
						write(useT(typeOfModuleType(mtype)));
						write("::class");
					case _:
						writeExpr(clsExpr);
						write("->phpClassName");
				}
			case _: fail(pos(), "genphp7.code_writer#write_expr_syntax_native_class_name");
		}
	}

	/**
		Writes `foreach` expression to output buffer (for `php.Syntax.foreach()`)
	*/
	public function writeExprSyntaxForeach(body:TExpr):Void {
		switch body.eexpr {
			case TBlock(exprs) if (exprs.length >= 4 && exprs[0].eexpr.match(TCall(_, [_])) && exprs[1].eexpr.match(TVar(_, _))
				&& exprs[2].eexpr.match(TVar(_, _))):
				var collection = switch exprs[0].eexpr {
					case TCall(_, [collection]): collection;
					case _: throw "unreachable";
				}
				var key = switch exprs[1].eexpr {
					case TVar(key, _): key;
					case _: throw "unreachable";
				}
				var value = switch exprs[2].eexpr {
					case TVar(value, _): value;
					case _: throw "unreachable";
				}
				var bodyExprs = exprs.slice(4);
				var addParentheses = switch collection.eexpr {
					case TLocal(_) | TField(_) | TArray(_): false;
					case _: true;
				}
				write("foreach (");
				if (addParentheses) write("(");
				writeExpr(collection);
				if (addParentheses) write(")");
				write(" as $" + (vname(key.vName)) + " => $" + (vname(value.vName)) + ") ");
				writeAsBlock(null, true, {eexpr: TBlock(bodyExprs), etype: body.etype, epos: body.epos});
			case _:
				fail(pos(), "genphp7.code_writer#write_expr_syntax_foreach");
		}
	}

	/**
		Writes TCall to output buffer
	*/
	public function writeExprCall(targetExpr:TExpr, args:Vector<TExpr>):Void {
		var noCall = false;
		switch revealExpr(targetExpr) {
			case {eexpr: TConst(TSuper)}:
				noCall = !hasSuperConstructor;
				if (!noCall) write("parent::__construct");
			case e if (needsParenthesisToCall(e)):
				writeExpr(parenthesis(e));
			case e:
				writeExpr(e);
		}
		if (!noCall) {
			write("(");
			writeArgs(write, writeExpr, (fixCallArgs(ctx.pgcCommon.basic, targetExpr.etype, args)));
			write(")");
		}
	}

	/**
		Writes `Std.isOfType(value, type)` to output buffer
	*/
	public function writeExprStdIs(targetExpr:TExpr, valueExpr:TExpr, typeExpr:TExpr):Void {
		if (instanceofCompatible(valueExpr, typeExpr)) writeExprSyntaxInstanceof(vector(valueExpr, typeExpr)) else {
			function noOptimisation():Void {
				writeExprCall(targetExpr, vector(valueExpr, typeExpr));
			}
			switch (revealExpr(typeExpr)).eexpr {
				case TTypeExpr(mtype):
					var t = follow(typeOfModuleType(mtype));
					if (ExtType.isString(t)) {
						write("is_string(");
						writeExpr(valueExpr);
						write(")");
					} else if (ExtType.isBool(t)) {
						write("is_bool(");
						writeExpr(valueExpr);
						write(")");
					} else if (ExtType.isFloat(t) && !(needsTempVar(valueExpr))) {
						write("(is_float(");
						writeExpr(valueExpr);
						write(") || is_int(");
						writeExpr(valueExpr);
						write("))");
					} else
						noOptimisation();
				case _:
					noOptimisation();
			}
		}
	}

	/**
		Writes a name of a function or a constant from global php namespace
	*/
	public function writeExprPhpGlobal(targetExpr:TExpr):Void {
		switch targetExpr.eexpr {
			case TField(_, FStatic(_, field)):
				var name = fieldName(field);
				if (namespace.length > 0 && !(isKeyword(name))) write("\\");
				write(name);
			case _: fail(pos(), "genphp7.code_writer#write_expr_php_global");
		}
	}

	/**
		Writes access to PHP class constant
	*/
	public function writeExprPhpClassConst(targetExpr:TExpr):Void {
		switch targetExpr.eexpr {
			case TField(_, FStatic(ecls, field)):
				write((useT(TInst(ecls, vector()))) + "::" + (fieldName(field)));
			case _: fail(pos(), "genphp7.code_writer#write_expr_php_class_const");
		}
	}

	/**
		Writes TNew to output buffer
	*/
	public function writeExprNew(instClass:TClass, args:Vector<TExpr>):Void {
		var needsPhpPrefix = !(hasClassFlag(instClass, CExtern));
		write("new " + (use(needsPhpPrefix, instClass.clPath)) + "(");
		var args = switch instClass.clConstructor {
			case null: args;
			case field: fixCallArgs(ctx.pgcCommon.basic, field.cfType, args);
		}
		writeArgs(write, writeExpr, args);
		write(")");
	}

	/**
		Writes ternary operator expressions to output buffer
	*/
	public function writeExprTernary(condition:TExpr, ifExpr:TExpr, elseExpr:TExpr, pos:Pos):Void {
		var ifExpr = unpackSingleExprBlock(ifExpr), elseExpr = unpackSingleExprBlock(elseExpr);
		write("(");
		switch condition.eexpr {
			case TParenthesis(expr): writeExpr(expr);
			case _: writeExpr(elseExpr);
		}
		write(" ? ");
		writeExpr(ifExpr);
		write(" : ");
		writeExpr(elseExpr);
		write(")");
	}

	/**
		Writes "if...else..." expression to output buffer
	*/
	public function writeExprIf(condition:TExpr, ifExpr:TExpr, elseExpr:Null<TExpr>):Void {
		var isTernary = if (parentExprIsBlock(true)) false else switch [ifExpr.eexpr, elseExpr] {
			case [TBlock(exprs), _] if ((exprs.length) > 1): false;
			// port: `(_, None)` is tested before `(_, Some TBlock _)` (both give false) so that no null is matched.
			case [_, null]: false;
			case [_, {eexpr: TBlock(exprs)}] if ((exprs.length) > 1): false;
			case _: true;
		}
		if (isTernary) {
			switch elseExpr {
				case null: fail(pos(), "genphp7.code_writer#write_expr_if");
				case expr:
					writeExprTernary(condition, ifExpr, expr, pos());
			}
		} else {
			write("if ");
			writeExpr(condition);
			write(" ");
			writeAsBlock(ifExpr);
			switch elseExpr {
				case null:
				case expr:
					write(" else ");
					switch expr.eexpr {
						case TIf(_): writeExpr(expr);
						case _: writeAsBlock(expr);
					}
			}
		}
	}

	/**
		Writes TWhile ("while..." or "do...while") to output buffer
	*/
	public function writeExprWhile(condition:TExpr, expr:TExpr, doWhile:WhileFlag):Void {
		switch doWhile {
			case NormalWhile:
				write("while ");
				writeExpr(condition);
				write(" ");
				writeAsBlock(null, true, expr);
			case DoWhile:
				write("do ");
				writeAsBlock(null, true, expr);
				write(" while ");
				writeExpr(condition);
		}
	}

	/**
		Writes TSwitch to output buffer
	*/
	public function writeExprSwitch(switch_:TExpr, cases:Vector<TSwitchCase>, default_:Null<TExpr>):Void {
		var writeSwitch = switch switch_.eexpr {
			case TLocal(_):
				(() -> writeExpr(switch_));
			case TParenthesis(e = {eexpr: TLocal(_)}):
				(() -> writeExpr(e));
			case _:
				write("$__hx__switch = ");
				writeExpr(switch_);
				write(";\n");
				writeIndentation();
				(() -> write("$__hx__switch"));
		}
		function writeConditions(conditions:Vector<TExpr>):Void {
			for (i in 0...conditions.length) {
				var condition = conditions[i];
				if (needBootEqual(switch_, condition)) {
					write((use(bootTypePath)) + "::equal(");
					writeSwitch();
					write(", ");
					writeExpr(condition);
					write(")");
				} else {
					writeSwitch();
					write(" === ");
					writeExpr(condition);
				}
				if (i < conditions.length - 1) write(" || ");
			}
		}
		function writeCases(cases:Vector<TSwitchCase>):Void {
			for (i in 0...cases.length) {
				var conditions = cases[i].casePatterns, expr = cases[i].caseExpr;
				write("if (");
				writeConditions(conditions);
				write(") ");
				writeAsBlock(expr);
				if (i < cases.length - 1) write(" else ");
			}
		}
		writeCases(cases);
		switch default_ {
			case null:
			case expr:
				write(" else ");
				writeAsBlock(expr);
		}
	}

	/**
		Write TEnumParameter expression to output buffer
	*/
	public function writeExprEnumParameter(expr:TExpr, constructor:TEnumField, index:Int):Void {
		switch expr.eexpr {
			case TConst(TNull): write("(null)");
			case _: writeExpr(expr);
		}
		write("->params[" + (Std.string(index)) + "]");
	}

	/**
		Write TEnumIndex expression to output buffer
	*/
	public function writeExprEnumIndex(expr:TExpr):Void {
		switch expr.eexpr {
			case TConst(TNull): write("(null)");
			case _: writeExpr(expr);
		}
		write("->index");
	}

	/**
		Writes argument for function declarations or calls
	*/
	public function writeArg(withOptionals:Bool, arg:{name:String, optional:Bool, type:T}):Void {
		var rest = if (isRestType(arg.type)) "..." else "";
		var opt = if (withOptionals && arg.optional) " = null" else "";
		write(rest + "$" + arg.name + opt);
	}

	/**
		Writes argument with optional value for function declarations
	*/
	public function writeFunctionArg(arg:{variable:TVar, defaultValue:Null<TExpr>}):Void {
		var argName = arg.variable.vName, argType = arg.variable.vType, defaultValue = arg.defaultValue;
		vars.declared(vname(argName));
		if (isRestType(argType)) write("...");
		if (isRef(argType)) write("&");
		write("$" + (vname(argName)));
		switch defaultValue {
			case null:
			case expr:
				write(" = ");
				switch expr.eexpr {
					case TConst(_): writeExpr(expr);
					case _: write("null");
				}
		}
	}

	/**
		Write an access to a field of dynamic value
	*/
	function writeExprFieldDynamic(expr:TExpr, fieldName:String):Void {
		function writeDirectAccess():Void {
			var writtenAsProbableString = writeExprFieldIfString(expr, fieldName);
			if (!writtenAsProbableString) writeExprForFieldAccess(expr, "->", fieldName);
		}
		function writeWrappedAccess():Void {
			write((use(bootTypePath)) + "::dynamicField(");
			writeExpr(expr);
			write(", '" + fieldName + "')");
		}
		function checkAndWrite(checkedExpr:TExpr):Void {
			switch (revealExpr(checkedExpr)).eexpr {
				case TField(target, _) if (target == expr): writeDirectAccess();
				case _: writeWrappedAccess();
			}
		}
		switch parentExpr() {
			case null: writeWrappedAccess();
			case {eexpr: TCall(callee, _)}: checkAndWrite(callee);
			case {eexpr: TUnop(op, _, target)} if (isModifyingUnop(op)): checkAndWrite(target);
			case {eexpr: TBinop(op, left, _)} if (isAssignmentBinop(op)): checkAndWrite(left);
			case _: writeWrappedAccess();
		}
	}
}
