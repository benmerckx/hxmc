package unit;

import context.Common.CommonContext;
import core.TType.ModuleDef;
import core.TType.ModuleType;
import core.TType.T;
import core.TType.TClass;

/** Types the `unit.moduleload` fixtures with the translated pipeline (`haxe.Main`) and inspects the filtered modules. */
class TypeloadModuleTest {
	public static final accepted = [
		"Accessors", "ArrayComprehension", "Documentation", "Expressions", "GenericMethodInference", "Inheritance", "InlineLocalFunction",
		"Int64Basic", "KeyValueLoop", "LocalStatics", "MacroField", "Metadata", "MetadataFunction", "ModuleFields", "Overloads", "Property",
		"ResolverHelper", "Structural", "TryCatch", "ValueSwitch"
	];

	/** Runs the translated compiler in-process and returns the context its generation stage saw, or null if it failed. */
	public static function compile(args:Array<String>):{code:Int, com:Null<CommonContext>} {
		var com:Null<CommonContext> = null;
		var previous = compiler.Compiler.generateHook;
		compiler.Compiler.generateHook = function(c) com = c;
		var code = try haxe.Main.run(args) catch (e:Dynamic) {
			compiler.Compiler.generateHook = previous;
			throw e;
		}
		compiler.Compiler.generateHook = previous;
		return {code: code, com: com};
	}

	public static function main():Void {
		var args = ["-cp", "haxe/test", "--dce", "no"];
		for (name in accepted) args.push("unit.moduleload." + name);
		args = args.concat(["haxe.ds.BalancedTree", "haxe.CallStack", "--hxb", "bin/test/unit-moduleload.hxb"]);
		var result = compile(args);
		if (result.code != 0 || result.com == null) throw 'Typing the moduleload fixtures failed with exit code ${result.code}';
		var com = result.com;
		function load(pack:Array<String>, name:String):ModuleDef {
			for (m in com.modules) if (m.mPath.name == name && m.mPath.pack.join(".") == pack.join(".")) return m;
			throw 'Module ${pack.concat([name]).join(".")} was not typed';
		}
		function fixture(name:String):ModuleDef return load(["unit", "moduleload"], name);
		function firstClass(m:ModuleDef):TClass return switch m.mTypes[0] { case TClassDecl(value): value; case _: throw 'Expected a class in ${m.mPath.name}'; };

		// Fixtures the reference compiler rejects are rejected as well.
		Sys.println("TypeloadModuleTest: the next three compiler errors are expected");
		for (name in ["Example", "Resolver", "BuildMetadata"]) {
			var rejected = compile(["-cp", "haxe/test", "unit.moduleload." + name, "--hxb", "bin/test/unit-rejected.hxb"]);
			if (rejected.code == 0) throw 'unit.moduleload.$name must be rejected';
		}

		var expressionClass = firstClass(fixture("Expressions"));
		switch expressionClass.clStatics.get("initial").cfExpr.eexpr { case TConst(TInt(3)): case _: throw "Constant field initializer was not folded"; }
		if (expressionClass.clFields.get("unchecked").cfExpr == null) throw "Untyped expression body was not typed";
		switch expressionClass.clFields.get("typeTest").cfExpr.eexpr {
			case TFunction({tfExpr: {eexpr: TBlock([{eexpr: TReturn({eexpr: TCall({eexpr: TField(_, FStatic(_, field))}, [_, {eexpr: TTypeExpr(_)}])})}])}}):
				if (field.cfName != "isOfType") throw "Type test did not call Std.isOfType";
			case _: throw "Type test expression was not typed";
		}
		switch expressionClass.clFields.get("regexp").cfExpr.eexpr {
			case TFunction({tfExpr: {eexpr: TBlock([{eexpr: TReturn({eexpr: TNew(target, [], [{eexpr: TConst(TString("value"))}, {eexpr: TConst(TString("gi"))}])})}])}}):
				if (target.clPath.pack.length != 0 || target.clPath.name != "EReg") throw "Regex literal selected the wrong class";
			case _: throw "Regex literal was not lowered to EReg construction";
		}
		switch expressionClass.clFields.get("guarded").cfExpr.eexpr {
			case TFunction({tfExpr: {eexpr: TBlock([{eexpr: TTry(_, [{variable: variable, expr: _}])}])}}):
				if (variable.vName != "error") throw "Catch variable was not typed";
			case _: throw "Try/catch expression was not typed";
		}
		switch expressionClass.clFields.get("conditions").cfExpr.eexpr {
			case TFunction({tfExpr: {eexpr: TBlock([{eexpr: TWhile({eexpr: TParenthesis(_)}, _, _)}, {eexpr: TIf({eexpr: TParenthesis(_)}, _, _)}])}}):
			case _: throw "Control-flow conditions were not parenthesized";
		}
		switch expressionClass.clFields.get("run").cfExpr.eexpr {
			case TFunction({tfExpr: {eexpr: TBlock(values)}}):
				switch values[0].eexpr {
					case TVar(variable, _):
						if (values[0].epos.pmax <= variable.vPos.pmax) throw "Local declaration position does not include its initializer";
					case _: throw "Local variable was not typed";
				}
				switch values[1].eexpr {
					case TReturn({eexpr: TCall(_, _)}):
					case _: throw "Direct call was not typed";
				}
			case _: throw "Function body was not typed";
		}

		var helper = firstClass(fixture("ResolverHelper"));
		if (helper.clPath.name != "ResolverHelper") throw "Module type was not resolved";

		var inheritance = fixture("Inheritance");
		var base = switch inheritance.mTypes[0] { case TClassDecl(value): value; case _: throw "Expected base class"; };
		var iface = switch inheritance.mTypes[1] { case TClassDecl(value): value; case _: throw "Expected interface"; };
		var derived = switch inheritance.mTypes[2] { case TClassDecl(value): value; case _: throw "Expected derived class"; };
		switch derived.clSuper {
			case {cls: value}: if (value != base) throw "Superclass was not resolved";
			case null: throw "Superclass was not installed";
		}
		if (derived.clImplements.length != 1 || derived.clImplements[0].cls != iface) throw "Implemented interface was not resolved";
		if ((iface.clFlags & classFlag("CInterface")) == 0) throw "Interface class flag was not installed";

		var accessorClass = firstClass(fixture("Accessors"));
		switch accessorClass.clStatics.get("read").cfExpr.eexpr {
			case TFunction({tfExpr: {eexpr: TBlock([{eexpr: TReturn({eexpr: TCall({eexpr: TField(_, FInstance(_, _, field))}, [])})}])}}):
				if (field.cfName != "get_message") throw "Property getter was not selected";
			case _: throw "Nullable property access was not typed as a getter call";
		}

		var moduleFields = fixture("ModuleFields");
		if (moduleFields.mStatics == null) throw "Module fields class was not created";
		var hasModuleFieldsType = false;
		for (type in moduleFields.mTypes) switch type { case TClassDecl(value) if (value == moduleFields.mStatics): hasModuleFieldsType = true; case _: }
		if (!hasModuleFieldsType) throw "Module fields class was not added to module types";
		if (!moduleFields.mStatics.clStatics.exists("initial") || !moduleFields.mStatics.clStatics.exists("answer")) throw "Module fields were not populated";

		var localStaticsClass = firstClass(fixture("LocalStatics"));
		// Local statics become class statics named after their function.
		if (localStaticsClass.clStatics.get("run_count") == null || localStaticsClass.clStatics.get("run_increment") == null) throw "Local statics were not hoisted";

		var arrayComprehensionClass = firstClass(fixture("ArrayComprehension"));
		if (arrayComprehensionClass.clStatics.get("collect").cfExpr == null) throw "Array comprehension was not typed";

		var overloadClass = firstClass(fixture("Overloads"));
		// Extern overloads are typed, then dropped by the extern-field filter before generation.
		if (overloadClass.clStatics.length != 0) throw "Extern overload fields were not removed";

		var keyValueLoopClass = firstClass(fixture("KeyValueLoop"));
		if (keyValueLoopClass.clStatics.get("visit").cfExpr == null) throw "Key/value loop was not typed";
		if (keyValueLoopClass.clStatics.get("visitMap").cfExpr == null) throw "Map value loop was not typed";

		var inlineLocalClass = firstClass(fixture("InlineLocalFunction"));
		if (inlineLocalClass.clStatics.get("value").cfExpr == null) throw "Inline local function was not typed";

		var valueSwitchClass = firstClass(fixture("ValueSwitch"));
		// The inline constant pattern is matched by value: the switch becomes a comparison with 1.
		switch valueSwitchClass.clStatics.get("select").cfExpr.eexpr {
			case TFunction({tfExpr: {eexpr: TBlock([{eexpr: TReturn({eexpr: TMeta(_, {eexpr: TIf({eexpr: TParenthesis({eexpr: TBinop(OpEq, _, {eexpr: TConst(TInt(1))})})}, _, _)})})}])}}):
			case _: throw "Value switch was not typed as a constant comparison";
		}

		var documentationClass = firstClass(fixture("Documentation"));
		if (documentationClass.clDoc == null || documentationClass.clDoc.docOwn != " Module type documentation. ") throw "Module documentation was not parsed";

		var balancedTreeClass = firstClass(load(["haxe", "ds"], "BalancedTree"));
		if (balancedTreeClass.clImplements.length != 1 || balancedTreeClass.clImplements[0].cls.clModule.mPath.name != "Constraints"
			|| balancedTreeClass.clImplements[0].cls.clPath.name != "IMap") throw "Qualified secondary type was not resolved";
		switch balancedTreeClass.clImplements[0].params[0] {
			case TInst(typeParam, []) if (typeParam == balancedTreeClass.clParams[0].ttpClass):
			case _: throw "Class inheritance captured the wrong type-parameter scope";
		}
		var callStackAbstract:core.TType.TAbstract = null;
		for (type in load(["haxe"], "CallStack").mTypes) switch type { case TAbstractDecl(value) if (value.aPath.name == "CallStack"): callStackAbstract = value; case _: }
		if (callStackAbstract == null) throw "Expected CallStack abstract";
		switch callStackAbstract.aImpl.clStatics.get("exceptionStack").cfType {
			case TFun({args: [{type: argType}]}): switch core.TFunctions.follow(argType) {
					case TAbstract(type, []) if (type.aPath.name == "Bool"):
					case _: throw "Default argument type was not inferred";
				}
			case _: throw "CallStack default argument was not typed as Bool";
		}
	}

	static function classFlag(name:String):Int return 1 << core.TType.TType.flagTClassNames.indexOf(name);
}
