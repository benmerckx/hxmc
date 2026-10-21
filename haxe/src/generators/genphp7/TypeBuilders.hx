package generators.genphp7;

// port: the type_builder, enum_builder and class_builder classes of haxe/src/generators/genphp7.ml.
import core.Ast;
import core.Ast as AstTools;
import core.Globals;
import core.Globals.Pos;
import core.TType;
import core.TFunctions;
import core.TFunctions.*;
import core.Meta as MetadataTools;
import core.MetaList.StrictMeta;
import core.StringHelper;
import core.Texpr;
import context.Sourcemaps;
import generators.Gctx;
import generators.Genphp7;
import generators.genphp7.TypeWrappers;
import generators.Genphp7.*;
import core.ds.VectorTools.vector;

/**
	Base class for type builders
*/
class TypeBuilder {
	/** PHP code writer */
	final writer:CodeWriter;

	/** This is required to make wrapper accessible by extending classes */
	final wrapper:TypeWrapper;

	/** This is required to make conext accessible by extending classes */
	final ctx:PhpGeneratorContext;

	/** Cache for generated conent */
	var contents = "";

	public function new(ctx:PhpGeneratorContext, wrapper:TypeWrapper) {
		writer = new CodeWriter(ctx, wrapper.getTypePath(), getRealName(wrapper.getName()));
		this.wrapper = wrapper;
		this.ctx = ctx;
	}

	/**
		Get PHP namespace path
	*/
	public function getNamespace():Array<String> {
		return switch ctx.pgcPrefix {
			case []: getRealPath(wrapper.getNamespace());
			case prefix: getRealPath(prefix.concat(wrapper.getNamespace()));
		}
	}

	/**
		Get type name
	*/
	public function getName():String return writer.getName();

	/**
		Get full type path
	*/
	public function getTypePath():GlobalTypePath {
		var tp = wrapper.getTypePath();
		return {pack: getRealPath(tp.pack), name: getRealName(tp.name)};
	}

	/**
		Returns hx source file name where this type was declared
	*/
	public function getSourceFile():String return wrapper.getSourceFile();

	/**
		Get amount of arguments of a parent method.
		Returns (mandatory_args_count * total_args_count)
		Returns `None` if no such parent method exists.
	*/
	function getParentMethodArgsCount(name:String, isStatic:Bool):Null<{mandatory:Int, total:Int}> return null;

	/**
		Writes type declaration line to output buffer.
		E.g. "class SomeClass extends Another implements IFace"
	*/
	function writeDeclaration():Void throw "abstract";

	/**
		Writes type body to output buffer.
		E.g. for "class SomeClass { <BODY> }" writes <BODY> part.
	*/
	function writeBody():Void throw "abstract";

	/**
		Writes expressions for `__hx__init` method
	*/
	function writeHxInitBody():Void throw "abstract";

	/**
		Writes additional initialization code, which should be called before `__hx__init()`
	*/
	function writePreHxInit():Void throw "abstract";

	/**
		Writes initialization code for type instances
	*/
	function writeInstanceInitialization():Void throw "abstract";

	/**
		Indicates if type should be declared as `final`
	*/
	public function isFinal():Bool return false;

	/**
		Indicates if `field` should be declared as `final`
	*/
	public function isFinalField(field:TClassField):Bool return false;

	/**
		Indicates if class has user-defined static __init__ method
		@see http://old.haxe.org/doc/advanced/magic#initialization-magic
	*/
	public function hasMagicInit():Bool return wrapper.getMagicInit() != null;

	/**
		Returns generated file contents
	*/
	public function getContents():String {
		if ((contents.length) == 0) {
			writeDeclaration();
			writer.writeLine(" {"); /** opening bracket for a class */
			writeBody();
			if (wrapper.needsInitialization()) writeHxInit();
			writer.indent(0);
			writer.writeLine("}"); /** closing bracket for a class */
			var body = writer.getContents();
			writer.clearContents();
			var footer = {
				writer.write("\n");
				var bootClass = writer.use(bootTypePath);
				/* Boot initialization */
				if (pathEq(bootTypePath, getTypePath())) {
					writer.writeStatement("require_once __DIR__.'/" + polyfillsFile + "'");
					writer.writeStatement(bootClass + "::__hx__init()");
				}
				var haxeClass = {
					var tp = wrapper.getTypePath();
					tp.pack.concat([tp.name]).join(".");
				}
				writer.writeStatement(bootClass + "::registerClass(" + (getName()) + "::class, '" + haxeClass + "')");
				writeRttiMeta();
				writePreHxInit();
				/* Current class initialization */
				if (wrapper.needsInitialization() && !pathEq(bootTypePath, getTypePath())) writer.writeStatement(getName() + "::__hx__init()");
				writer.getContents();
			}
			switch getSourcemapGenerator() {
				case null:
				case smap: smap.rewind();
			}
			writer.clearContents();
			writeHeader();
			writer.write("\n");
			var header = writer.getContents();
			contents = header + body + (ctx.pgcBottomBuffer.toString()) + footer;
		}
		return contents;
	}

	/**
		Indicates if there is no constructor in inheritance chain of this type.
		Own constructor is ignored.
	*/
	function extendsNoConstructor():Bool return true;

	/**
		Build file header (<?php, namespace and file doc block)
	*/
	function writeHeader():Void {
		writer.indent(0);
		writer.writeLine("<?php");
		writer.writeLine("/**");
		Gctx.mapSourceHeader(ctx.pgcCommon.defines, s -> writer.writeLine(" * " + s));
		if (ctx.pgcCommon.debug) writer.writeLine(" * Haxe source file: " + getSourceFile());
		writer.writeLine(" */");
		writer.write("\n");
		var namespace = getNamespace();
		if (namespace.length > 0) writer.writeLine("namespace " + (namespace.join("\\")) + ";\n");
		writer.writeUse();
	}

	/**
		Generates PHP docblock and attributes to output buffer.
	*/
	function writeDoc(docBlock:DocType, meta:Metadata):Void {
		switch docBlock {
			case DocVar(typeName, doc):
				writer.writeLine("/**");
				writer.writeLine(" * @var " + typeName);
				switch doc {
					case null:
					case txt: writeDocDescription(txt);
				}
				writer.writeLine(" */");
			case DocClass(doc):
				switch doc {
					case null:
					case txt:
						writer.writeLine("/**");
						writeDocDescription(txt);
						writer.writeLine(" */");
				}
			case DocMethod(args, ret, doc):
				writeMethodDocblock(args, ret, doc);
		}
		writeAttributes(meta);
	}

	/**
		Writes description section of docblocks
	*/
	public function writeDocDescription(doc:String):Void {
		var lines = strSplit(ocamlTrim(doc), c -> c == "\n".code);
		function writeLine(line:String):Void {
			var trimmed = ocamlTrim(line);
			if (trimmed.length > 0) {
				if (trimmed.charAt(0) == "*") writer.writeLine(" " + trimmed) else writer.writeLine(" * " + trimmed);
			}
		}
		for (line in lines) writeLine(line);
	}

	/**
		Generates docblock for a method and writes it to output buffer
	*/
	public function writeMethodDocblock(args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>, returnType:T, doc:Null<String>):Void {
		writer.writeLine("/**");
		switch doc {
			case null:
			case txt:
				writeDocDescription(txt);
				writer.writeLine(" * ");
		}
		function writeArg(arg:{name:String, optional:Bool, type:T}):Void {
			writer.writeLine(" * @param " + (writer.useT(true, arg.type)) + " $" + arg.name);
		}
		for (arg in args) writeArg(arg);
		if (args.length > 0) writer.writeLine(" * ");
		writer.writeLine(" * @return " + (writer.useT(true, returnType)));
		writer.writeLine(" */");
	}

	/**
		Writes rtti meta to output buffer
	*/
	public function writeRttiMeta():Void {
		switch Texpr.buildMetadata(ctx.pgcCommon.basic, wrapper.getModuleType()) {
			case null:
			case metaExpr:
				var bootClass = writer.use(bootTypePath);
				writer.write(bootClass + "::registerMeta(" + (getName()) + "::class, ");
				writer.writeExpr(metaExpr);
				writer.write(");\n");
		}
	}

	/**
		Writes type initialization method.
	*/
	function writeHxInit():Void {
		writer.writeEmptyLines();
		writer.indent(1);
		writer.writeLine("/**");
		writer.writeLine(" * @internal");
		writer.writeLine(" * @access private");
		writer.writeLine(" */");
		writer.writeLine("static public function __hx__init ()");
		writer.writeLine("{");
		writer.indentMore();
		writer.writeStatement("static $called = false");
		writer.writeStatement("if ($called) return");
		writer.writeStatement("$called = true");
		writer.write("\n");
		writer.reset();
		writer.indent(2);
		switch wrapper.getMagicInit() {
			case null:
			case expr: writer.writeFakeBlock(expr);
		}
		writer.write("\n");
		writer.reset();
		writer.indent(2);
		writeHxInitBody();
		writer.indent(1);
		writer.writeLine("}");
	}

	/**
		Writes method to output buffer
	*/
	function writeMethod(name:String, func:TFunc, isStatic:Bool, isAbstract:Bool):Void {
		switch name {
			case "__construct": writeConstructorDeclaration(func);
			case _: writeMethodDeclaration(name, func, isStatic, isAbstract);
		}
	}

	/**
		Writes constructor declaration (except visibility and `static` keywords) to output buffer
	*/
	function writeConstructorDeclaration(func:TFunc):Void {
		if (extendsNoConstructor()) writer.extendsNoConstructor();
		writer.write("function __construct (");
		writeArgs(writer.write, writer.writeFunctionArg, fixTfuncArgs(func.tfArgs));
		writer.write(") {\n");
		writer.indentMore();
		writeInstanceInitialization();
		var func = injectDefaults(ctx, func);
		writer.writeFakeBlock(func);
		writer.indentLess();
		writer.writeWithIndentation("}");
	}

	/**
		Writes method declaration (except visibility keywords) to output buffer
	*/
	function writeMethodDeclaration(name:String, func:TFunc, isStatic:Bool, isAbstract:Bool):Void {
		if (isAbstract) writer.write("abstract ");
		if (isStatic) writer.write("static ");
		var byRef = if (isRef(func.tfType)) "&" else "";
		writer.write("function " + byRef + name + " (");
		var args = if (isStatic) alignArgsToParentStaticMethod(func.tfArgs, name) else func.tfArgs;
		writeArgs(writer.write, writer.writeFunctionArg, fixTfuncArgs(args));
		writer.write(") ");
		if (!(writeBodyIfSpecialMethod(name))) writer.writeExpr(injectDefaults(ctx, func));
	}

	/**
	*/
	function alignArgsToParentStaticMethod(args:haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}>,
			methodName:String):haxe.ds.Vector<{variable:TVar, defaultValue:Null<TExpr>}> {
		return switch getParentMethodArgsCount(methodName, true) {
			case null: args;
			case {mandatory: mandatory, total: total}:
				function defaultValue():Null<TExpr> return mk(TConst(TNull), tDynamic, Globals.nullPos);
				function next(value:Int):Int return value - 1 > 0 ? value - 1 : 0;
				function loop(args:Array<{variable:TVar, defaultValue:Null<TExpr>}>, mandatory:Int, total:Int):Array<{variable:TVar, defaultValue:Null<TExpr>}> {
					return switch args {
						case [] if (total == 0): [];
						case []:
							var argVar = allocVar(VGenerated, "_" + (Std.string(total)), tDynamic, Globals.nullPos);
							var first = {variable: argVar, defaultValue: defaultValue()};
							[first].concat(loop(args, next(mandatory), next(total)));
						case _ if (args[0].defaultValue == null && mandatory == 0):
							[{variable: args[0].variable, defaultValue: defaultValue()}].concat(loop(args.slice(1), 0, next(total)));
						case _:
							[args[0]].concat(loop(args.slice(1), next(mandatory), next(total)));
					}
				}
				haxe.ds.Vector.fromArrayCopy(loop(args.toArray(), mandatory, total));
		}
	}

	/**
		Writes a body for a special method if `field` represents one.
		Returns `true` if `field` is such a method.
	*/
	function writeBodyIfSpecialMethod(name:String):Bool {
		/* php.Boot.isPhpKeyword(str:String) */
		if (pathEq(getTypePath(), bootTypePath) && name == "isPhpKeyword") {
			writer.write("{\n");
			writer.indentMore();
			writer.writeLine("switch(strtolower($str)) {");
			writer.indentMore();
			writer.writeIndentation();
			var cnt = 0;
			for (kwd in phpKeywordsList) {
				if (cnt <= 5) cnt++ else {
					cnt = 0;
					writer.write("\n");
					writer.writeIndentation();
				}
				writer.write("case '" + kwd + "': ");
			}
			writer.write("\n");
			writer.indentMore();
			writer.writeStatement("return true");
			writer.indentLess();
			writer.writeLine("default:");
			writer.indentMore();
			writer.writeStatement("return false");
			writer.indentLess();
			writer.indentLess();
			writer.writeLine("}");
			writer.indentLess();
			writer.writeWithIndentation("}");
			return true;
		} else
			return false;
	}

	/**
		Generates PHP attributes to output buffer based on `@:php.attribute` metas.
	*/
	function writeAttributes(meta:Metadata):Void {
		var found = false;
		for (entry in meta) {
			var m = entry.meta, el = entry.exprs, p = entry.pos;
			found = if (m == StrictMeta.PhpAttribute) {
				writer.writeIndentation();
				writer.write("#[");
				switch el {
					case [{expr: EConst(String(s, _))}]:
						writer.write(s);
					case _:
						ctx.pgcCommon.error(("@:php.attribute meta expects a single string constant as an argument."), p);
				}
				writer.write("]\n");
				true;
			} else found;
		}
	}

	/**
		Set sourcemap generator
	*/
	public function setSourcemapGenerator(generator:SourcemapBuilder):Void writer.setSourcemapGenerator(generator);

	/**
		Get sourcemap generator
	*/
	public function getSourcemapGenerator():Null<SourcemapBuilder> return writer.getSourcemapGenerator();
}

/**
	Builds enum contents
*/
class EnumBuilder extends TypeBuilder {
	final enm:TEnum;

	public function new(ctx:PhpGeneratorContext, enm:TEnum) {
		super(ctx, getWrapper(TEnumDecl(enm)));
		this.enm = enm;
	}

	/**
		Writes type declaration line to output buffer.
		E.g. "class SomeClass extends Another implements IFace"
	*/
	override function writeDeclaration():Void {
		writeDoc(DocClass(AstTools.genDocTextOpt(enm.eDoc)), enm.eMeta);
		writer.write("class " + getName() + " extends " + (writer.use(hxenumTypePath)));
	}

	/**
		Writes type body to output buffer.
		E.g. for "class SomeClass { <BODY> }" writes <BODY> part.
	*/
	override function writeBody():Void {
		var writeEmptyLines = false;
		core.ds.PMap.iter((name:String, field:TEnumField) -> {
			if (writeEmptyLines) writer.writeEmptyLines() else writeEmptyLines = true;
			writeConstructor(name, field);
		}, enm.eConstrs);
		writeReflection();
	}

	/**
		Writes constructor declaration to output buffer
	*/
	function writeConstructor(name:String, field:TEnumField):Void {
		var args = switch follow(field.efType) {
			case TFun(sig): sig.args;
			case TEnum(_): vector();
			case _: fail(field.efPos, "genphp7.enum_builder#write_constructor");
		}
		writer.indent(1);
		writeDoc(DocMethod(args, TEnum(enm, vector()), (AstTools.genDocTextOpt(field.efDoc))), field.efMeta);
		writer.writeWithIndentation("static public function " + name + " (");
		writeArgs(writer.write, writer.writeArg.bind(true), fixTsignatureArgs(args));
		writer.write(") {\n");
		writer.indentMore();
		var indexStr = Std.string(field.efIndex);
		function writeConstruction(args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>):Void {
			writer.write("new " + getName() + "('" + name + "', " + indexStr + ", [");
			writeArgs(writer.write, (a:{name:String, optional:Bool, type:T}) -> writer.write("$" + a.name), args);
			writer.write("])");
		}
		switch args {
			case []:
				/* writer#write ((writer#use hxenum_type_path) ^ "::singleton(static::class, '" ^ name ^ "', " ^ index_str ^")") */
				writer.writeLine("static $inst = null;");
				writer.writeWithIndentation("if (!$inst) $inst = ");
				writeConstruction(vector());
				writer.write(";\n");
				writer.writeLine("return $inst;");
			case args:
				writer.writeWithIndentation("return ");
				writeConstruction(args);
				writer.write(";\n");
		}
		writer.indentLess();
		writer.writeLine("}");
	}

	/**
		Writes special methods for reflection
	*/
	function writeReflection():Void {
		/* __hx__list */
		writer.writeEmptyLines();
		writer.indent(1);
		writer.writeLine("/**");
		writer.writeLine(" * Returns array of (constructorIndex => constructorName)");
		writer.writeLine(" *");
		writer.writeLine(" * @return string[]");
		writer.writeLine(" */");
		writer.writeLine("static public function __hx__list () {");
		writer.indentMore();
		writer.writeLine("return [");
		writer.indentMore();
		core.ds.PMap.iter((name:String, field:TEnumField) -> writer.writeLine((Std.string(field.efIndex)) + " => '" + name + "',"), enm.eConstrs);
		writer.indentLess();
		writer.writeStatement("]");
		writer.indentLess();
		writer.writeLine("}");
		/* __hx__paramsCount */
		writer.writeEmptyLines();
		writer.indent(1);
		writer.writeLine("/**");
		writer.writeLine(" * Returns array of (constructorName => parametersCount)");
		writer.writeLine(" *");
		writer.writeLine(" * @return int[]");
		writer.writeLine(" */");
		writer.writeLine("static public function __hx__paramsCount () {");
		writer.indentMore();
		writer.writeLine("return [");
		writer.indentMore();
		core.ds.PMap.iter((name:String, field:TEnumField) -> {
			var count = switch follow(field.efType) {
				case TFun(sig): sig.args.length;
				case TEnum(_): 0;
				case _: fail(field.efPos, "genphp7.enum_builder#write_reflection");
			}
			writer.writeLine("'" + name + "' => " + (Std.string(count)) + ",");
		}, enm.eConstrs);
		writer.indentLess();
		writer.writeStatement("]");
		writer.indentLess();
		writer.writeLine("}");
	}

	/**
		Method `__hx__init` is not needed for enums
	**/
	override function writeHxInitBody():Void {}

	/**
		No need for additional initialization of enum instances
	*/
	override function writeInstanceInitialization():Void {}

	/**
		No need for additional type initialization for enums
	*/
	override function writePreHxInit():Void {}
}

/**
	Builds class contents
*/
class ClassBuilder extends TypeBuilder {
	final cls:TClass;

	/**
		List of methods names uppercased.
		Used to check for methods with similar names because PHP function names are case-insensitive.
	*/
	var usedMethodNames:Array<String> = [];

	public function new(ctx:PhpGeneratorContext, cls:TClass) {
		super(ctx, getWrapper(TClassDecl(cls)));
		this.cls = cls;
	}

	/**
		Indicates if type should be declared as `final`
	*/
	override public function isFinal():Bool {
		if (!(hasClassFlag(cls, CFinal))) return false;
		var hacked = false;
		for (comType in ctx.pgcCommon.types) {
			if (!hacked) switch comType {
				case TClassDecl(tcls):
					if (extendedBy(tcls)) hacked = MetadataTools.has(Hack, tcls.clMeta);
				case _:
			}
		}
		return !hacked;
	}

	/**
		Get amount of arguments of a parent method.
		Returns `None` if no such parent method exists.
	*/
	override function getParentMethodArgsCount(name:String, isStatic:Bool):Null<{mandatory:Int, total:Int}> {
		return switch cls.clSuper {
			case null: null;
			case {cls: cls}:
				var fields = if (isStatic) cls.clStatics else cls.clFields;
				var field = fields.get(name);
				if (field == null) return null;
				var args = switch followWithCoro(field.cfType) {
					case Coro(sig): context.Common.expandCoroType(ctx.pgcCommon.basic, sig.args, sig.ret).args;
					case NotCoro(TFun(sig)): sig.args;
					case _: null;
				}
				switch args {
					case null: null;
					case args:
						var mandatory = 0, total = 0;
						var result = null;
						for (i in 0...args.length) {
							if (args[i].optional) {
								var leftCount = args.length - i;
								result = {mandatory: mandatory, total: total + leftCount};
								break;
							}
							mandatory++;
							total++;
						}
						result != null ? result : {mandatory: mandatory, total: total};
				}
		}
	}

	/**
		Indicates if `field` should be declared as `final`
	*/
	override public function isFinalField(field:TClassField):Bool return hasClassFieldFlag(field, CfFinal);

	/**
		Check if there is no native php constructor in inheritance chain of this class.
		E.g. `StdClass` does have a constructor while still can be called with `new StdClass()`.
		So this method will return true for `MyClass` if `MyClass extends StdClass`.
	*/
	override function extendsNoConstructor():Bool {
		function extendsNoConstructor(tcls:TClass):Bool {
			return switch tcls.clSuper {
				case null: true;
				case {cls: parent}:
					if (MetadataTools.has(PhpNoConstructor, parent.clMeta)) true else switch parent.clConstructor {
						case null: extendsNoConstructor(parent);
						case _: false;
					}
			}
		}
		return extendsNoConstructor(cls);
	}

	/**
		Recursively check if current class is a parent class for a `child`
	*/
	function extendedBy(child:TClass):Bool {
		var result = if (child == cls) false else {
			function check(current:TClass):Bool {
				return switch current.clSuper {
					case null: false;
					case {cls: scls}: if (scls == cls) true else check(scls);
				}
			}
			check(child);
		}
		return result;
	}

	/**
		Writes type declaration line to output buffer.
		E.g. "class SomeClass extends Another implements IFace"
	*/
	override function writeDeclaration():Void {
		writeDoc(DocClass(AstTools.genDocTextOpt(cls.clDoc)), cls.clMeta);
		if (isFinal()) writer.write("final ");
		if (hasClassFlag(cls, CAbstract)) writer.write("abstract ");
		writer.write(if ((hasClassFlag(cls, CInterface))) "interface " else "class ");
		writer.write(getName());
		switch cls.clSuper {
			case null:
			case {cls: superClass, params: params}:
				var superName = writer.useT(TInst(superClass, params));
				writer.write(" extends " + superName);
		}
		if (cls.clImplements.length > 0) {
			writer.write(if ((hasClassFlag(cls, CInterface))) " extends " else " implements ");
			function useInterface(iface:{cls:TClass, params:TParams}):String return writer.useT(TInst(iface.cls, iface.params));
			/* Do not add interfaces which are implemented through other interfaces inheritance */
			var unique = cls.clImplements.filter(i -> {
				var iface = i.cls;
				!(Lambda.exists(cls.clImplements, p -> {
					var probablyDescendant = p.cls;
					if (probablyDescendant == iface) false else extendsClass(probablyDescendant, iface);
				}));
			});
			var interfaces = unique.map(useInterface);
			writer.write(interfaces.join(", "));
		}
	}

	/**
		Returns either user-defined constructor or creates empty constructor if instance initialization is required.
	*/
	function getConstructor():Null<TClassField> {
		return switch cls.clConstructor {
			case null:
				if (!constructorIsRequired()) null else {
					var basic = ctx.pgcCommon.basic;
					var f = mkField("new", TFun({args: vector(), ret: basic.tvoid}), cls.clPos, cls.clPos);
					f.cfKind = Method(MethNormal);
					f.cfExpr = {
						eexpr: TFunction({
							tfArgs: vector(),
							tfType: basic.tvoid,
							tfExpr: {eexpr: TBlock(vector()), epos: cls.clPos, etype: basic.tvoid},
						}),
						epos: cls.clPos,
						etype: basic.tvoid,
					};
					f;
				}
			case field: field;
		}
	}

	/**
		Writes type body to output buffer.
		E.g. for "class SomeClass { <BODY> }" writes <BODY> part.
	*/
	override function writeBody():Void {
		var atLeastOneFieldWritten = false;
		function writeIfConstant(_:String, field:TClassField):Void {
			switch field.cfKind {
				case Var({vRead: AccInline, vWrite: AccNever}):
					atLeastOneFieldWritten = true;
					writeField(true, field);
				case _:
			}
		}
		function writeIfMethod(isStatic:Bool, _:String, field:TClassField):Void {
			switch field.cfKind {
				case Var(_):
				case Method(MethDynamic) if (isStatic):
				case Method(_):
					if (atLeastOneFieldWritten) writer.writeEmptyLines();
					atLeastOneFieldWritten = true;
					writeField(isStatic, field);
			}
		}
		function writeIfVar(isStatic:Bool, _:String, field:TClassField):Void {
			switch field.cfKind {
				case Var({vRead: AccInline, vWrite: AccNever}):
				case Method(MethDynamic):
					atLeastOneFieldWritten = true;
					var kind = Var({vRead: AccNormal, vWrite: AccNormal});
					var f = core.ds.Record.copy(field);
					f.cfKind = kind;
					writeField(isStatic, f);
				case Var(_):
					atLeastOneFieldWritten = true;
					writeField(isStatic, field);
				case Method(_):
			}
		}
		if (pathEq(bootTypePath, getTypePath())) {
			writePhpPrefix();
			atLeastOneFieldWritten = true;
		}
		if (!(hasClassFlag(cls, CInterface))) {
			/* Inlined statc vars (constants) */
			core.ds.PMap.iter(writeIfConstant, cls.clStatics);
			if (atLeastOneFieldWritten) writer.writeEmptyLines();
			atLeastOneFieldWritten = false;
			/* Statc vars */
			core.ds.PMap.iter(writeIfVar.bind(true), cls.clStatics);
			if (atLeastOneFieldWritten) writer.writeEmptyLines();
			atLeastOneFieldWritten = false;
			/* instance vars */
			core.ds.PMap.iter(writeIfVar.bind(false), cls.clFields);
		}
		/* Statc methods */
		core.ds.PMap.iter(writeIfMethod.bind(true), cls.clStatics);
		/* Constructor */
		switch getConstructor() {
			case null:
			case field: writeIfMethod(false, "new", field);
		}
		/* Instance methods */
		core.ds.PMap.iter(writeIfMethod.bind(false), cls.clFields);
		/* Generate `__toString()` if not defined by user, but has `toString()` */
		writeToStringIfRequired();
	}

	function writeToStringIfRequired():Void {
		var toString = cls.clFields.get("toString");
		if (toString == null) return;
		if ((!(hasClassFlag(cls, CInterface))) && (!(cls.clStatics.exists("__toString"))) && (!(cls.clFields.exists("__toString")))) {
			writer.writeEmptyLines();
			writer.indent(1);
			writer.writeLine("public function __toString() {");
			writer.indentMore();
			var calleeStr = switch toString.cfKind {
				case Var(_): "($this->toString)";
				case Method(_): "$this->toString";
			}
			writer.writeLine("return " + calleeStr + "();");
			writer.indentLess();
			writer.writeLine("}");
		}
	}

	/**
		Check if this class requires constructor to be generated even if there is no user-defined one
	*/
	function constructorIsRequired():Bool {
		if ((hasClassFlag(cls, CInterface)) || getNamespace().length > 0) return false;
		var required = false;
		for (field in cls.clOrderedStatics.concat(cls.clOrderedFields)) {
			if (!required) required = (asciiLowercase(field.cfName) == asciiLowercase(getName()));
		}
		return required;
	}

	/**
		Writes `-D php-prefix` value as class constant PHP_PREFIX
	*/
	function writePhpPrefix():Void {
		var prefix = ctx.pgcPrefix.join("\\");
		var indentation = writer.getIndentation();
		writer.indent(1);
		writer.writeStatement("const PHP_PREFIX = \"" + (ocamlEscaped(prefix)) + "\"");
		writer.indent(indentation);
	}

	/**
		Writes expressions for `__hx__init` method
	*/
	override function writeHxInitBody():Void {
		/* `static dynamic function` initialization */
		function writeDynamicMethodInitialization(field:TClassField):Void {
			var fieldAccess = "self::$" + (fieldName(field));
			writer.writeWithIndentation(fieldAccess + " = ");
			switch field.cfExpr {
				case null: fail(field.cfPos, "genphp7.class_builder#write_hx_init_body");
				case expr: writer.writeExpr(expr);
			}
			writer.write(";\n");
		}
		for (field in cls.clOrderedStatics) {
			switch field.cfKind {
				case Method(MethDynamic): writeDynamicMethodInitialization(field);
				case _:
			}
		}
		/* `static var` initialization */
		function writeVarInitialization(field:TClassField):Void {
			function writeAssign(expr:TExpr):Void {
				writer.writeWithIndentation("self::$" + (fieldName(field)) + " = ");
				writer.writeExpr(expr);
			}
			/*
				Do not generate fields for RTTI meta, because this generator uses another way to store it.
				Also skip initialization for `inline var` fields as those are generated as PHP class constants.
			*/
			function isAutoMetaVar():Bool return field.cfName == "__meta__" && (hasRttiMeta(ctx.pgcCommon, wrapper.getModuleType()));
			if ((isVarWithNonconstantExpr(field)) && (!(isAutoMetaVar())) && (!(isInlineVar(field)))) {
				switch field.cfExpr {
					case null:
					/* There can be not-inlined blocks when compiling with `-debug` */
					case {eexpr: TBlock(exprs)}:
						for (i in 0...exprs.length) {
							var expr = exprs[i];
							if (i == exprs.length - 1) writeAssign(expr) else {
								writer.writeIndentation();
								writer.writeExpr(expr);
								writer.write(";\n");
							}
						}
					case expr: writeAssign(expr);
				}
				writer.write(";\n");
			} else switch field.cfExpr {
				case null:
				case expr = {eexpr: TConst(TInt(value))} if (value == -2147483648):
					writeAssign(expr);
					writer.write(";\n");
				case _:
			}
		}
		for (field in cls.clOrderedStatics) writeVarInitialization(field);
	}

	/**
		Writes single field to output buffer.
	*/
	function writeField(isStatic:Bool, field:TClassField):Void {
		switch field.cfKind {
			case Var({vRead: AccInline, vWrite: AccNever}): writeConst(field);
			case Var(_) if (isPhysicalField(field)):
				/* Do not generate fields for RTTI meta, because this generator uses another way to store it */
				var isAutoMetaVar = isStatic && field.cfName == "__meta__" && (hasRttiMeta(ctx.pgcCommon, wrapper.getModuleType()));
				if (!isAutoMetaVar) writeVar(field, isStatic);
			case Var(_):
			case Method(MethMacro):
			case Method(MethDynamic) if (isStatic):
			case Method(MethDynamic): writeDynamicMethod(field);
			case Method(_): writeClassMethod(field, isStatic);
		}
	}

	/**
		Writes var-field to output buffer
	*/
	function writeVar(field:TClassField, isStatic:Bool):Void {
		writer.indent(1);
		writeDoc(DocVar(writer.useT(true, field.cfType), (AstTools.genDocTextOpt(field.cfDoc))), field.cfMeta);
		writer.writeIndentation();
		if (isStatic) writer.write("static ");
		var visibility = getVisibility(field.cfMeta);
		writer.write(visibility + " $" + (fieldName(field)));
		switch field.cfExpr {
			case null:
				writer.write(";\n");
			case {eexpr: TConst(TInt(value))} if (value == -2147483648):
				writer.write(";\n");
			case expr:
				switch expr.eexpr {
					case TConst(_):
						writer.write(" = ");
						writer.writeExpr(expr);
						writer.write(";\n");
					case _: writer.write(";\n");
				}
		}
	}

	/**
		Writes "inline var" to output buffer as constant
	*/
	function writeConst(field:TClassField):Void {
		switch field.cfExpr {
			case null: fail(writer.pos(), "genphp7.class_builder#write_const");
			/* Do not generate a PHP constant of `inline var` field if expression is not compatible with PHP const */
			case expr if (!(isConstant(expr))):
			case expr:
				writer.indent(1);
				writeDoc(DocVar(writer.useT(field.cfType), (AstTools.genDocTextOpt(field.cfDoc))), field.cfMeta);
				writer.writeWithIndentation("const " + (fieldName(field)) + " = ");
				writer.writeExpr(expr);
				writer.write(";\n");
		}
	}

	/**
		Writes method to output buffer
	*/
	function writeClassMethod(field:TClassField, isStatic:Bool):Void {
		validateMethodName(field);
		writer.reset();
		writer.indent(1);
		var sig = getFunctionSignature(ctx.pgcCommon.basic, field);
		var args = sig.args, returnType = sig.ret;
		for (a in args) writer.declaredLocalVar(a.name);
		writeDoc(DocMethod(args, returnType, (AstTools.genDocTextOpt(field.cfDoc))), field.cfMeta);
		writer.writeIndentation();
		if (isFinalField(field)) writer.write("final ");
		if (hasClassFieldFlag(field, CfAbstract)) writer.write("abstract ");
		writer.write((getVisibility(field.cfMeta)) + " ");
		switch field.cfExpr {
			case null:
				if (isStatic) writer.write("static ");
				writer.write("function " + (fieldName(field)) + " (");
				writeArgs(writer.write, writer.writeArg.bind(true), fixTsignatureArgs(args));
				writer.write(")");
				writer.write(" ;\n");
			case {eexpr: TFunction(fn)}:
				var name = if (field.cfName == "new") "__construct" else (fieldName(field));
				writeMethod(name, fn, isStatic, (hasClassFieldFlag(field, CfAbstract)));
				writer.write("\n");
			case _: fail(field.cfPos, "genphp7.class_builder#write_class_method");
		}
	}

	/**
		Writes dynamic method to output buffer.
		Only for non-static methods. Static methods are created as static vars in `__hx__init`.
	*/
	function writeDynamicMethod(field:TClassField):Void {
		validateMethodName(field);
		writer.reset();
		writer.indent(1);
		var sig = getFunctionSignature(ctx.pgcCommon.basic, field);
		var args = sig.args, returnType = sig.ret;
		for (a in args) writer.declaredLocalVar(a.name);
		writeDoc(DocMethod(args, returnType, (AstTools.genDocTextOpt(field.cfDoc))), field.cfMeta);
		var visibilityKwd = getVisibility(field.cfMeta);
		writer.writeWithIndentation(visibilityKwd + " function " + (fieldName(field)));
		switch field.cfExpr {
			case null: /* interface */
				/* let args, _ = Common.expand_coro_type ctx.pgc_common.basic args return_type in */
				writer.write(" (");
				writeArgs(writer.write, writer.writeArg.bind(true), fixTsignatureArgs(args));
				writer.write(");\n");
			case {eexpr: TFunction(fn)}: /* normal class */
				function writeArgs_():Void {
					writer.write(" (");
					writeArgs(writer.write, writer.writeFunctionArg, fixTfuncArgs(fn.tfArgs));
					writer.write(")\n");
				}
				writeArgs_();
				writer.writeLine("{");
				writer.indentMore();
				writer.writeIndentation();
				var fieldAccess = "$this->" + (fieldName(field));
				writer.write("return call_user_func_array(" + fieldAccess + ", func_get_args());\n");
				writer.indentLess();
				writer.writeLine("}");
				/* Don't forget to create a field for default value */
				writer.writeIndentation();
				writer.write(visibilityKwd + " function __hx__default__" + (fieldName(field)));
				writeArgs_();
				writer.writeLine("{");
				writer.indentMore();
				writer.writeFakeBlock(fn.tfExpr);
				writer.indentLess();
				writer.writeLine("}");
			case _: fail(field.cfPos, "genphp7.class_builder#write_dynamic_method");
		}
	}

	/**
		Since PHP function names are case-insensitive we must check for method names clashes.
	*/
	function validateMethodName(field:TClassField):Void {
		var uppercasedName = StringHelper.uppercase(field.cfName);
		if (usedMethodNames.indexOf(uppercasedName) >= 0)
			ctx.pgcCommon.error("Methods names are case-insensitive in PHP runtime. Cannot redeclare \"" + field.cfName + "\".", field.cfNamePos)
		else
			usedMethodNames.unshift(uppercasedName);
	}

	/**
		Writes initialization code for instances of this class
	*/
	override function writeInstanceInitialization():Void {
		function initDynamicMethod(field:TClassField):Void {
			var fieldName = fieldName(field);
			var hxClosure = writer.use(hxclosureTypePath);
			writer.writeStatement("if ($this->" + fieldName + " === null) $this->" + fieldName + " = new " + hxClosure + "($this, '__hx__default__"
				+ fieldName + "')");
		}
		for (field in cls.clOrderedFields) {
			switch field.cfKind {
				case Method(MethDynamic): initDynamicMethod(field);
				case _:
			}
		}
	}

	/**
		Writes additional initialization code, which should be called before `__hx__init()`
	*/
	override function writePreHxInit():Void {
		var getters = [], setters = [];
		function collect(field:TClassField):Void {
			switch field.cfKind {
				case Var({vRead: read, vWrite: write}):
					if (read.match(AccCall)) getters.unshift(field.cfName);
					if (write.match(AccCall)) setters.unshift(field.cfName);
					if (read.match(AccPrivateCall)) getters.unshift(field.cfName);
					if (write.match(AccPrivateCall)) setters.unshift(field.cfName);
				case _:
			}
		}
		for (f in cls.clOrderedFields) collect(f);
		for (f in cls.clOrderedStatics) collect(f);
		function write(lst:Array<String>):Void {
			for (i in 0...lst.length) {
				if (i == lst.length - 1) writer.writeLine("'" + lst[i] + "' => true") else writer.writeLine("'" + lst[i] + "' => true,");
			}
		}
		var typeName = getFullTypeName(true, true, (addPhpPrefix(ctx, wrapper.getTypePath())));
		function writeRegister(registerMethod:String, lst:Array<String>):Void {
			writer.writeLine((writer.use(bootTypePath)) + "::" + registerMethod + "('" + typeName + "', [");
			writer.indentMore();
			write(lst);
			writer.indentLess();
			writer.writeStatement("])");
		}
		if (getters.length > 0) writeRegister("registerGetters", getters);
		if (setters.length > 0) writeRegister("registerSetters", setters);
	}
}
