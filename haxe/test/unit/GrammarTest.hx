package unit;

import core.Ast;

using core.ds.VectorTools;

class GrammarTest {
	public static function main():Void {
		var parsed = parse('package example; import foo.Bar; class Main extends Base { public static var count:Int = 1 + 2; public function new(x:Int) { var y = x; trace(y); } }', null, "Main.hx");
		assert(parsed.pack.join(".") == "example");
		assert(parsed.declarations.length == 2);
		assert(switch parsed.declarations[0].definition { case EImport(value): value.path[1].name == "Bar"; case _: false; });
		assert(switch parsed.declarations[1].definition { case EClass(c): c.name.name == "Main" && c.data.length == 2 && switch c.data[0].cffKind { case FVar(type, value): type != null && value != null; case _: false; }; case _: false; });
		var expr = parse('class Main { function f() { return foo(1, 2).bar; } }').declarations[0];
		assert(switch expr.definition { case EClass(c): switch c.data[0].cffKind { case FFun(f): f.fExpr != null; case _: false; }; case _: false; });
		var structural = parse('typedef Cursor<T> = { function hasNext():Bool; function next():T; }').declarations[0];
		assert(switch structural.definition { case ETypedef(value): switch value.data.type { case CTAnonymous(fields): fields.length == 2; case _: false; }; case _: false; });
		var structuralExtension = parse('typedef Base = { var id:Int; } typedef Child = { > Base, var name:String; }').declarations[1];
		assert(switch structuralExtension.definition { case ETypedef(value): switch value.data.type { case CTExtend(paths, fields): paths.length == 1 && paths[0].path.tname == "Base" && fields.length == 1; case _: false; }; case _: false; });
		var property = parse('extern class Value { var length(default, null):Int; }').declarations[0];
		assert(switch property.definition { case EClass(value): switch value.data[0].cffKind { case FProp(get, set, _, _): get.name == "default" && set.name == "null"; case _: false; }; case _: false; });
		var structuralProperty = parse('typedef Value = { var length(default, null):Int; }').declarations[0];
		assert(switch structuralProperty.definition { case ETypedef(value): switch value.data.type { case CTAnonymous([{cffKind:FProp(get, set, _, _)}]): get.name == "default" && set.name == "null"; case _: false; }; case _: false; });
		var optionalStructuralField = parse('typedef Value = { var ?label:String; }').declarations[0];
		assert(switch optionalStructuralField.definition { case ETypedef(value): switch value.data.type { case CTAnonymous([{cffKind:FVar({type:CTPath(_)}, _), cffMeta:[entry]}]): Type.enumEq(entry.meta, core.MetaList.StrictMeta.Optional); case _: false; }; case _: false; });
		var qualifiedSubtype = parse('class Value implements haxe.Constraints.IMap<String, Int> {}').declarations[0];
		assert(switch qualifiedSubtype.definition { case EClass({flags:[HImplements({path:path})]}): path.tpackage.join(".") == "haxe" && path.tname == "Constraints" && path.tsub == "IMap" && path.tparams.length == 2; case _: false; });
		var functionType = parse('class Mapper { function map(f:Int->String):Void; }').declarations[0];
		assert(switch functionType.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fArgs[0].type.type { case CTFunction(_, _): true; case _: false; }; case _: false; }; case _: false; });
		var zeroArgFunctionType = parse('class Mapper { var callback:() -> Void; }').declarations[0];
		assert(switch zeroArgFunctionType.definition { case EClass(value): switch value.data[0].cffKind { case FVar({type:CTFunction(args, _)}, _): args.length == 0; case _: false; }; case _: false; });
		var namedFunctionType = parse('class Mapper { var callback:(value:Int) -> Void; }').declarations[0];
		assert(switch namedFunctionType.definition { case EClass(value): switch value.data[0].cffKind { case FVar({type:CTFunction([{type:CTNamed(name, _)}], _)}, _): name.name == "value"; case _: false; }; case _: false; });
		parse('class Mapper { var callback:(?value:Int) -> Void; }');
		var expressionBody = parse('abstract Any(Dynamic) { extern inline function promote<T>():T return this; }').declarations[0];
		assert(switch expressionBody.definition { case EAbstract(value): switch value.data[0].cffKind { case FFun(func): func.fExpr != null; case _: false; }; case _: false; });
		var controlBlock = parse('class Main { function run(items:Array<Int>) { for (item in items) { trace(item); } } }').declarations[0];
		assert(switch controlBlock.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): func.fExpr != null; case _: false; }; case _: false; });
		var unaryNegative = parse('class Main { static var value = -1; }').declarations[0];
		assert(switch unaryNegative.definition { case EClass(value): switch value.data[0].cffKind { case FVar(_, {expr:EConst(Int("-1", _))}): true; case _: false; }; case _: false; });
		var interval = parse('class Main { static function run(items:Array<Int>) { for (i in 0...items.length) {} } }').declarations[0];
		assert(switch interval.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): func.fExpr != null; case _: false; }; case _: false; });
		var variableInterval = parse('class Main { static function run(pos:Int, len:Int) { for (i in pos...pos + len) {} } }').declarations[0];
		assert(switch variableInterval.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): func.fExpr != null; case _: false; }; case _: false; });
		var switched = parse('class Main { static function run(value:Int):Bool { return switch (value) { case 0: true; default: false; } } }').declarations[0];
		assert(switch switched.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): func.fExpr != null; case _: false; }; case _: false; });
		parse('class Main { function run(value:Dynamic) return switch (value : String) { case value: value; } }');
		parse('class Main { function run(value:Bool) return if (value) {field: 1} else {field: 2}; }');
		var boundSwitch = parse('class Main { function run(value:Null<Int>) return switch value { case var bound if (bound > 0): bound; case null: 0; } }').declarations[0];
		assert(switch boundSwitch.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:ESwitch(_, cases, _)}): cases.length == 2 && switch cases[0] { case {values:[{expr:EVars(_)}], guard:guard}: guard != null; case _: false; }; case _: false; }; case _: false; }; case _: false; });
		var finalField = parse('class Holder { final value:Int; }').declarations[0];
		assert(switch finalField.definition { case EClass(value): switch value.data[0].cffKind { case FVar(type, _): type != null; case _: false; }; case _: false; });
		var switchStatements = parse('class Main { static function run(value:Int) { switch (value) { case 0: trace(value); trace("zero"); default: trace("other"); } } }').declarations[0];
		assert(switch switchStatements.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EBlock([{expr: ESwitch(_, cases, _)}]): switch cases[0].expr.expr { case EBlock(values): values.length == 2; case _: false; }; case _: false; }; case _: false; }; case _: false; });
		var nestedBlock = parse('class Main { function run() { { var value = 1; } /** local note */ trace("done"); } }').declarations[0];
		assert(switch nestedBlock.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EBlock([{expr:EBlock(_)}, {expr:ECall(_, _)}]): true; case _: false; }; case _: false; }; case _: false; });
		var braceTerminatedVariables = parse('class Main { function run(value:Int) { var object = { field: value } trace(object); var selected = switch value { case 0: false; default: true; } trace(selected); } }').declarations[0];
		assert(switch braceTerminatedVariables.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EBlock(values): values.length == 4; case _: false; }; case _: false; }; case _: false; });
		var braceTerminatedFields = parse('final moduleValue = { field: 1 } class Main { final field = { nested: true } }');
		assert(braceTerminatedFields.declarations.length == 2);
		var localStatics = parse('class Main { function run() { static var count = 0; static final label = "ok"; } }').declarations[0];
		assert(switch localStatics.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EBlock([{expr:EVars([first])}, {expr:EVars([second])}]): first.evStatic && !first.evFinal && second.evStatic && second.evFinal; case _: false; }; case _: false; }; case _: false; });
		var privateAccess = parse('class Main { function run(value:Dynamic) return @:privateAccess value.hidden; }').declarations[0];
		assert(switch privateAccess.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr: EMeta(entry, _)}): Type.enumEq(entry.meta, core.MetaList.StrictMeta.PrivateAccess); case _: false; }; case _: false; }; case _: false; });
		var spacedMetadata = parse('class Main { function run(value:Dynamic) return @:privateAccess (value : String); }').declarations[0];
		assert(switch spacedMetadata.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:EMeta(entry, {expr:EParenthesis({expr:ECheckType(_, _)})})}): entry.exprs.length == 0; case _: false; }; case _: false; }; case _: false; });
		var metadataArguments = parse('class Main { function run(value:Dynamic) return @:custom("one",) value; }').declarations[0];
		assert(switch metadataArguments.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:EMeta(entry, _)}): entry.exprs.length == 1; case _: false; }; case _: false; }; case _: false; });
		var legacyMetadata = parse('@legacy class Main {}').declarations[0];
		assert(switch legacyMetadata.definition { case EClass(value): Type.enumEq(value.meta[0].meta, core.MetaList.StrictMeta.Custom("legacy")); case _: false; });
		var interpolation = parse("class Main { function render(value:String) return 'before $value after'; }").declarations[0];
		assert(switch interpolation.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:EConst(String("before $value after", SSingleQuotes))}): true; case _: false; }; case _: false; }; case _: false; });
		parse("class Main { function render() return 'value: ${/* note */ 1}'; }");
		var arrows = parse('class Main { function map(values:Array<Int>) { values.map(value -> value + 1); values.map((value:Int) -> value + 1); } }').declarations[0];
		assert(switch arrows.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EBlock([{expr:ECall(_, [{expr:EFunction(FKArrow, first)}])}, {expr:ECall(_, [{expr:EFunction(FKArrow, second)}])}]): first.fArgs.length == 1 && first.fArgs[0].type == null && second.fArgs.length == 1 && second.fArgs[0].type != null; case _: false; }; case _: false; }; case _: false; });
		var assignedArrow = parse('class Main { function run() callback = value -> value; }').declarations[0];
		assert(switch assignedArrow.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EBinop(OpAssign, _, {expr:EFunction(FKArrow, _)}): true; case _: false; }; case _: false; }; case _: false; });
		var assignedFunctions = parse('class Main { function run() { callback = function() return 1; callback = value -> { return value; } next(); } }').declarations[0];
		assert(switch assignedFunctions.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EBlock(values): values.length == 3; case _: false; }; case _: false; }; case _: false; });
		var nullCoalescing = parse('class Main { function run(value:Null<Int>) return value ?? 1; }').declarations[0];
		assert(switch nullCoalescing.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:EBinop(OpNullCoal, _, _)}): true; case _: false; }; case _: false; }; case _: false; });
		parse('class Main { function run(value:Null<Int>) consume(value ?? return); }');
		var coalescedArrow = parse('class Main { function run(f:Dynamic) return f ?? value -> value; }').declarations[0];
		assert(switch coalescedArrow.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:EBinop(OpNullCoal, _, {expr:EFunction(FKArrow, _)})}): true; case _: false; }; case _: false; }; case _: false; });
		var restArgument = parse('class Main { function rest(...values:Int) return call(...values); }').declarations[0];
		assert(switch restArgument.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch [func.fArgs[0].type.type, func.fExpr.expr] { case [CTPath(path), EReturn({expr:ECall(_, [{expr:EUnop(Spread, Prefix, _)}])})]: path.path.tpackage.join(".") == "haxe" && path.path.tname == "Rest"; case _: false; }; case _: false; }; case _: false; });
		parse('class Main { var callback:(...values:Int) -> Void; }');
		var moduleFields = parse('final values = new Array<Int>(); var enabled:Bool = true; function main() {}');
		assert(moduleFields.declarations.length == 3 && switch moduleFields.declarations[0].definition { case EStatic({data:FVar(_, _), flags:flags}): flags[0].access == AFinal; case _: false; });
		var moduleProperty = parse('var value(get, set):String; function get_value() return value; function set_value(next) return value = next;');
		assert(switch moduleProperty.declarations[0].definition { case EStatic({data:FProp(get, set, _, _)}): get.name == "get" && set.name == "set"; case _: false; });
		var trailingArrayComma = parse('class Main { var values = [1, 2,]; }').declarations[0];
		assert(switch trailingArrayComma.definition { case EClass(value): switch value.data[0].cffKind { case FVar(_, {expr:EArrayDecl(values)}): values.length == 2; case _: false; }; case _: false; });
		var trailingCommas = parse('class Main { static function call(a:Int, b:Int,) { call(1, 2,); var arrow = (a:Int, b:Int,) -> a; var typed:(a:Int, b:Int,) -> Int; } } enum Pair { Value(a:Int, b:Int,); }');
		assert(trailingCommas.declarations.length == 2);
		var quotedObjectField = parse('class Main { var value = { "new": 1 }; }').declarations[0];
		assert(switch quotedObjectField.definition { case EClass(value): switch value.data[0].cffKind { case FVar(_, {expr:EObjectDecl([{key:key, expr:_}])}): key.name == "new" && key.quote == DoubleQuotes; case _: false; }; case _: false; });
		var mapLiteral = parse('class Main { var values = [1 => "one"]; }').declarations[0];
		assert(switch mapLiteral.definition { case EClass(value): switch value.data[0].cffKind { case FVar(_, {expr:EArrayDecl([{expr:EBinop(OpArrow, _, _)}])}): true; case _: false; }; case _: false; });
		var functionVariableWithoutSemicolon = parse('class Main { function run() { var callback = function() {} var next = 1; } }').declarations[0];
		assert(switch functionVariableWithoutSemicolon.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EBlock(values): values.length == 2; case _: false; }; case _: false; }; case _: false; });
		parse('class Main { function run() { var callback = function<T>(value:T):T return value; } }');
		var functionFieldWithSemicolon = parse('class Main { function new() {}; function run() {}; }').declarations[0];
		assert(switch functionFieldWithSemicolon.definition { case EClass(value): value.data.length == 2; case _: false; });
		var localFunctionWithoutSemicolon = parse('class Main { function run() { function local() {} local(); } }').declarations[0];
		assert(switch localFunctionWithoutSemicolon.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EBlock(values): values.length == 2; case _: false; }; case _: false; }; case _: false; });
		var prefixAfterBlock = parse('class Main { function run() { if (ready) { reset(); } ++index; } }').declarations[0];
		assert(switch prefixAfterBlock.definition {case EClass(value): switch value.data[0].cffKind {case FFun(func): switch func.fExpr.expr {case EBlock([{expr:EIf(_, {expr:EBlock(_)}, _)}, {expr:EUnop(Increment, Prefix, {expr:EConst(Ident("index"))})}]): true; case _: false;}; case _: false;}; case _: false;});
		parse('class Main { function run() { function local() {} ++value.x; var selected = if (value) 1; var next = 2; } }');
		var macroPrefixedExpression = parse('class Main { macro static function build(value) return macro new Result($$value); }').declarations[0];
		assert(switch macroPrefixedExpression.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:ECheckType(_, _)}): true; case _: false; }; case _: false; }; case _: false; });
		var unparenthesizedSwitch = parse('class Main { function run(value:Int) return switch value { case 1: true; default: false; } }').declarations[0];
		assert(switch unparenthesizedSwitch.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:ESwitch(_, _, _)}): true; case _: false; }; case _: false; }; case _: false; });
		var checkedExpression = parse('class Main { function run(value:Dynamic) return (value : String); }').declarations[0];
		assert(switch checkedExpression.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:EParenthesis({expr:ECheckType(_, _)})}): true; case _: false; }; case _: false; }; case _: false; });
		var isExpression = parse('class Main { function run(value:Dynamic) return value is String; }').declarations[0];
		assert(switch isExpression.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:EIs(_, _)}): true; case _: false; }; case _: false; }; case _: false; });
		parse('abstract Contains(Int) { @:op(a in b) static function contains(a:Int, b:Int):Bool; @:op(A!) function suffix():Int; }');
		var arrowBlock = parse('package; class Main { function run() return () -> { return 1; }; }').declarations[0];
		assert(switch arrowBlock.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:EFunction(FKArrow, {fExpr:{expr:EMeta(_, {expr:EReturn({expr:EBlock(_)})})}})}): true; case _: false; }; case _: false; }; case _: false; });
		var dollarCall = parse("class Main { function run(value:Dynamic) $type(value); }").declarations[0];
		assert(switch dollarCall.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case ECall({expr:EConst(Ident("$type"))}, _): true; case _: false; }; case _: false; }; case _: false; });
		var dollarReification = parse('class Main { macro static function run(value:Dynamic) return macro $' + 'v{value}; }').declarations[0];
		assert(switch dollarReification.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:ECheckType(_, _)}): true; case _: false; }; case _: false; }; case _: false; });
		parse('class Main { macro static function run() return macro $' + 'typePath.$' + 'fieldName; }');
		var enumAbstract = parse('enum abstract Status(Int) from Int to Int { var Ready = 1; }').declarations[0];
		assert(switch enumAbstract.definition { case EAbstract(value): value.flags.indexOf(AbEnum) != -1 && value.data.length == 1; case _: false; });
		var abstractClass = parse('abstract class Input { public function read():Int; }').declarations[0];
		assert(switch abstractClass.definition { case EClass(value): value.flags.indexOf(HAbstract) != -1; case _: false; });
		var privateAbstractClass = parse('private abstract class Input { public function read():Int; }').declarations[0];
		assert(switch privateAbstractClass.definition { case EClass(value): value.flags.indexOf(HPrivate) != -1 && value.flags.indexOf(HAbstract) != -1; case _: false; });
		var reorderedAbstractClass = parse('abstract private class Input { public function read():Int; }').declarations[0];
		assert(switch reorderedAbstractClass.definition { case EClass(value): value.flags.indexOf(HPrivate) != -1 && value.flags.indexOf(HAbstract) != -1; case _: false; });
		var abstractField = parse('abstract class Input { abstract public function read():Int; }').declarations[0];
		assert(switch abstractField.definition { case EClass(value): value.data[0].cffAccess.filter(function(access) return access.access == AAbstract).length == 1; case _: false; });
		var intersectionConstraint = parse('class Input<T:Readable & { function close():Void; }> {}').declarations[0];
		assert(switch intersectionConstraint.definition { case EClass(value): switch value.params[0].tpConstraints.type { case CTIntersection(types): types.length == 2; case _: false; }; case _: false; });
		var structuralFunctionType = parse('typedef Callback = { value:String } -> String;').declarations[0];
		assert(switch structuralFunctionType.definition { case ETypedef(value): switch value.data.type { case CTFunction([{type:CTAnonymous(_)}], _): true; case _: false; }; case _: false; });
		var overloadedConstructor = parse('abstract Vector<T>(Array<T>) { extern overload public inline function new(length:Int) {} }').declarations[0];
		assert(switch overloadedConstructor.definition { case EAbstract(value): value.data[0].cffAccess.filter(function(access) return access.access == AOverload).length == 1; case _: false; });
		var constantTypeArguments = parse('class Main { var one:Const<10>; var negative:Const<-3>; var values:Const<["test", 1]>; var pattern:Const<~/foo/i>; }').declarations[0];
		assert(switch constantTypeArguments.definition { case EClass(value): value.data.foreach(function(field) return switch field.cffKind { case FVar({type:CTPath({path:{tparams:[TPExpr(_)]}})}, _): true; case _: false; }); case _: false; });
		parse('class Main<T> { var values:Array<T>=[]; var nested:Array<Array<T>>=[]; }');
		parse('class Main { function run() { try { return; } value(); } }');
		var unparenthesizedCast = parse('class Main { function run() return cast readByte(); }').declarations[0];
		assert(switch unparenthesizedCast.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:ECast({expr:ECall(_, [])}, null)}): true; case _: false; }; case _: false; }; case _: false; });
		var checkedCast = parse('class Main { function run() return cast (value : String); }').declarations[0];
		assert(switch checkedCast.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:ECast({expr:EParenthesis({expr:ECheckType(_, _)})}, null)}): true; case _: false; }; case _: false; }; case _: false; });
		var castField = parse('class Main { function run(value:Base) return cast(value, Child).field; }').declarations[0];
		assert(switch castField.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EReturn({expr:EField({expr:ECast(_, _)}, "field", _)}): true; case _: false; }; case _: false; }; case _: false; });
		var inlineLoop = parse('class Main { function run() inline for (i in 0...3) trace(i); }').declarations[0];
		assert(switch inlineLoop.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EMeta(entry, {expr:EFor(_, _)}): Type.enumEq(entry.meta, core.MetaList.StrictMeta.Inline); case _: false; }; case _: false; }; case _: false; });
		var untypedBlock = parse('class Main { function run():Void untyped { value(); } }').declarations[0];
		assert(switch untypedBlock.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EUntyped({expr:EBlock(_)}): true; case _: false; }; case _: false; }; case _: false; });
		var terminatedIfBranch = parse('class Main { function run(v:Int) { if (v < 0) first(); else if (v > 0) second(); else third(); } }').declarations[0];
		assert(switch terminatedIfBranch.definition { case EClass(value): switch value.data[0].cffKind { case FFun(func): switch func.fExpr.expr { case EBlock([{expr:EIf(_, _, {expr:EIf(_, _, _)})}]): true; case _: false; }; case _: false; }; case _: false; });
		var literalDollar = parse("class Main { var value = 'cost: $'; }").declarations[0];
		assert(switch literalDollar.definition { case EClass(value): switch value.data[0].cffKind { case FVar(_, {expr:EConst(String(text, _))}): text == "cost: $"; case _: false; }; case _: false; });
		var streamResult = syntax.ParserEntry.parseString(syntax.ParserConfig.defaultConfig(core.Define.emptyDefines()), syntax.Grammar.parseFileStream,
			'@:coreType @coreType @:custom.flag class Metadata { function f() inline call(); }', core.Globals.nullPos,
			function(message, _) {throw message;}, false);
		var streamPackage = switch streamResult {case ParseSuccess(value, _): value; case _: throw "Expected successful stream parse";};
		assert(switch streamPackage.declarations[0].definition {
			case EClass(value): core.Meta.has(core.MetaList.StrictMeta.CoreType, value.meta)
				&& Type.enumEq(value.meta[1].meta, core.MetaList.StrictMeta.Custom("coreType"))
				&& Type.enumEq(value.meta[2].meta, core.MetaList.StrictMeta.Custom(":custom.flag"))
				&& switch value.data[0].cffKind {case FFun({fExpr:{expr:EMeta(entry, _)}}): Type.enumEq(entry.meta, core.MetaList.StrictMeta.Inline); case _: false;};
			case _: false;
		});
		var callStack = parse(sys.io.File.getContent("haxe/upstream/std/haxe/CallStack.hx"), core.Define.emptyDefines(), "haxe/upstream/std/haxe/CallStack.hx");
		assert(callStack.declarations.length == 2);
	}

	/** Parses a file with the translated parser (`parser.ml`, `grammar.ml`). */
	public static function parse(source:String, ?defines:core.Define.DefineContext, file = "?"):Package {
		var config = syntax.ParserConfig.defaultConfig(defines == null ? core.Define.emptyDefines() : defines);
		return switch syntax.ParserEntry.parseString(config, syntax.Grammar.parseFileStream, source, {pfile: file, pmin: 0, pmax: 0},
			function(message, _) throw message + " in: " + source, false) {
			case ParseSuccess(data, _): data;
			case ParseError(_, error, _): throw syntax.Parser.errorMsg(error.message) + " in: " + source;
		}
	}

	static function assert(value:Bool):Void if (!value) throw "Grammar assertion failed";
}
