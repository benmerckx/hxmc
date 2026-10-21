package coro;

import core.TType;
import core.ds.VectorTools.vector;

@:structInit class ContinuationApi {
	public var baseContinuationClass:TClass;
	public var suspensionState:T;
	public var suspensionResult:T->T;
	public var suspensionResultClass:TClass;
	public var continuation:T;
	public var state:TClassField;
	public var result:TClassField;
	public var error:TClassField;
	public var completion:TClassField;
	public var context:TClassField;
	public var gotoLabel:TClassField;
	public var suspended:TClassField;

	public inline function new(baseContinuationClass:TClass, suspensionState:T, suspensionResult:T->T, suspensionResultClass:TClass,
			continuation:T, state:TClassField, result:TClassField, error:TClassField, completion:TClassField, context:TClassField,
			gotoLabel:TClassField, suspended:TClassField) {
		this.baseContinuationClass = baseContinuationClass;
		this.suspensionState = suspensionState;
		this.suspensionResult = suspensionResult;
		this.suspensionResultClass = suspensionResultClass;
		this.continuation = continuation;
		this.state = state;
		this.result = result;
		this.error = error;
		this.completion = completion;
		this.context = context;
		this.gotoLabel = gotoLabel;
		this.suspended = suspended;
	}

	public inline function clone():ContinuationApi return new ContinuationApi(baseContinuationClass, suspensionState, suspensionResult,
		suspensionResultClass, continuation, state, result, error, completion, context, gotoLabel, suspended);
}

class ContTypes {
	public static function createContinuationApi(baseContinuationClass:TClass, suspensionState:T, suspensionResultClass:TClass,
			continuation:T, suspended:TClassField, state:TClassField, result:TClassField, error:TClassField, completion:TClassField,
			context:TClassField, gotoLabel:TClassField):ContinuationApi return {
			baseContinuationClass: baseContinuationClass,
			suspensionState: suspensionState,
			suspensionResult: function(t) return TInst(suspensionResultClass, vector(t)),
			suspensionResultClass: suspensionResultClass,
			continuation: continuation,
			suspended: suspended,
			state: state,
			result: result,
			error: error,
			completion: completion,
			context: context,
			gotoLabel: gotoLabel
		};
}
