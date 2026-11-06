package core;

import core.TType.T;

// port: from haxe/src/core/withType.ml.
@:structInit class WithTypeSourceInformation {
	public var siName:String;
	public var siDoc:Null<String>;

	public inline function new(siName:String, siDoc:Null<String>) {
		this.siName = siName;
		this.siDoc = siDoc;
	}

	public inline function clone():WithTypeSourceInformation return new WithTypeSourceInformation(siName, siDoc);
}

enum WithTypeSource {
	FunctionArgument(info:WithTypeSourceInformation);
	StructureField(info:WithTypeSourceInformation);
	LocalVariable(info:WithTypeSourceInformation);
	ImplicitReturn;
}

enum WithTypeValue {
	NoValue;
	Value(source:Null<WithTypeSource>);
	WithType(type:T, source:Null<WithTypeSource>);
}

class WithType {
	public static function makeWithTypeSourceInformation(name:String,
			doc:Null<String>):WithTypeSourceInformation return {siName: name, siDoc: doc};

	public static function withType(t:T):WithTypeValue return WithType(t, null);

	public static function ofImplicitReturn(t:T):WithTypeValue return WithType(t, ImplicitReturn);

	public static function withArgument(t:T,
			name:String):WithTypeValue return WithType(t, FunctionArgument(makeWithTypeSourceInformation(name, null)));

	public static function withArgumentAndDoc(t:T, name:String,
			doc:String):WithTypeValue return WithType(t, FunctionArgument(makeWithTypeSourceInformation(name, doc)));

	public static function withStructureField(t:T,
			name:String):WithTypeValue return WithType(t, StructureField(makeWithTypeSourceInformation(name, null)));

	public static function withLocalVariable(t:T,
			name:String):WithTypeValue return WithType(t, LocalVariable(makeWithTypeSourceInformation(name, null)));

	public static final value:WithTypeValue = Value(null);

	public static function namedArgument(name:String):WithTypeValue return Value(FunctionArgument(makeWithTypeSourceInformation(name,
		null)));

	public static function namedStructureField(name:String):WithTypeValue return Value(StructureField(makeWithTypeSourceInformation(name,
		null)));

	public static final noValue:WithTypeValue = NoValue;

	public static function getSourceInfoName(source:WithTypeSource):Null<String> return switch source {
		case FunctionArgument(si) | StructureField(si) | LocalVariable(si): si.siName;
		case ImplicitReturn: null;
	};

	public static function stringOfWithTypeSource(source:WithTypeSource):String return switch source {
		case FunctionArgument(si): 'FunctionArgument(${si.siName})';
		case StructureField(si): 'StructureField(${si.siName})';
		case LocalVariable(si): 'LocalVariable(${si.siName})';
		case ImplicitReturn: 'ImplicitReturn';
	};

	/** Can return empty or invalid identifier name when type source is `StructureField`. */
	public static function getExpectedName(value:WithTypeValue):Null<String> return switch value {
		case Value(source) | WithType(_, source): source == null ? null : getSourceInfoName(source);
		case _: null;
	};

	public static function toString(value:WithTypeValue):String return switch value {
		case NoValue: 'NoValue';
		case Value(null): 'Value(None)';
		case Value(source): 'Value(Some(${stringOfWithTypeSource(source)}))';
		case WithType(t,
			source): 'WithType(${TPrinting.sType(TPrinting.printContext(), t)}, ${source == null ? "None" : "Some(" + stringOfWithTypeSource(source) + ")"})';
	};
}
