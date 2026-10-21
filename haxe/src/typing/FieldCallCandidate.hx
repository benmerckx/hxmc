package typing;

import core.TType;
import core.TPrinting;

// This record holds transient information about an (attempted) call on a field. It is created when resolving
// field calls and is passed to overload filters.
@:structInit class FieldCallCandidateData<A> {
	// The argument expressions for this call and whether or not the argument is optional on the
	// target function.
	public var fcArgs:haxe.ds.Vector<TExpr>;
	// The applied return type.
	public var fcRet:T;
	// The applied function type.
	public var fcType:T;
	// The class field being called.
	public var fcField:TClassField;
	// The field monomorphs that were created for this call.
	public var fcMonos:core.TType.TParams;
	// The custom data associated with this call.
	public var fcData:A;

	public inline function new(fcArgs:haxe.ds.Vector<TExpr>, fcRet:T, fcType:T, fcField:TClassField, fcMonos:core.TType.TParams, fcData:A) {
		this.fcArgs = fcArgs;
		this.fcRet = fcRet;
		this.fcType = fcType;
		this.fcField = fcField;
		this.fcMonos = fcMonos;
		this.fcData = fcData;
	}

	public inline function clone():FieldCallCandidateData<A> return new FieldCallCandidateData(fcArgs, fcRet, fcType, fcField, fcMonos,
		fcData);
}

class FieldCallCandidate {
	public static function makeFieldCallCandidate<A>(args:haxe.ds.Vector<TExpr>, ret:T, monos:core.TType.TParams, t:T, cf:TClassField,
			data:A):FieldCallCandidateData<A> {
		return {
			fcArgs: args,
			fcType: t,
			fcField: cf,
			fcData: data,
			fcRet: ret,
			fcMonos: monos
		};
	}

	public static function sFieldCallCandidate<A>(fcc:FieldCallCandidateData<A>):String {
		var pctx = TPrinting.printContext();
		var se = function(e) return TPrinting.sExprPretty(false, "", false, function(t) return TPrinting.sType(pctx, t), e);
		return Printer.sRecordFields("", [
			{name: "fc_args", value: fcc.fcArgs.map(se).join(", ")},
			{name: "fc_type", value: TPrinting.sType(pctx, fcc.fcType)},
			{name: "fc_field", value: fcc.fcField.cfName + ": " + TPrinting.sType(pctx, fcc.fcField.cfType)}
		]);
	}
}
