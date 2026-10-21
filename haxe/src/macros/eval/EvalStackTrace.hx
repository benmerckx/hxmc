package macros.eval;

import core.Globals.Pos;
import macros.eval.EvalValue;
import macros.eval.EvalContext;
import macros.eval.EvalEncode;
import core.ds.VectorTools.vector;

class EvalStackTrace {
	public static function makeStack(envs:Array<{pos:Pos, kind:EnvKind}>):Value {
		var l:Array<Value> = [];
		for (e in envs) {
			var pos = e.pos;
			inline function filePos(s:Value):Value {
				var c = syntax.Lexer.getPosCoords(pos);
				return EvalEncode.encodeEnumValue(EvalHash.key_haxe_StackItem, 2, vector(
					s,
					EvalString.createUnknown(pos.pfile),
					VInt32(c.lineStart),
					VInt32(c.columnStart)
				), pos);
			}
			switch e.kind {
				case EKLocalFunction(i):
					var localFunction = EvalEncode.encodeEnumValue(EvalHash.key_haxe_StackItem, 4, vector(VInt32(i)), pos);
					l.push(filePos(localFunction));
				case EKMethod(st, sf):
					var localFunction = EvalEncode.encodeEnumValue(EvalHash.key_haxe_StackItem, 3, vector(
						EvalString.createUnknown(EvalHash.revHash(st)),
						EvalString.createUnknown(EvalHash.revHash(sf))
					), pos);
					l.push(filePos(localFunction));
				case EKMacro(st, sf):
				case EKEntrypoint:
			}
		}
		return EvalEncode.encodeArray(l);
	}

	public static function makeStackValue(envs:Array<Env>):Value {
		return makeStack(envs.map(env -> {
			pos: new Pos(EvalHash.revHash(env.envInfo.pfile), env.envLeavePmin, env.envLeavePmax),
			kind: env.envInfo.kind
		}));
	}

	public static final getCallStack:Value = EvalEncode.vfun0(() -> {
		var ctx = EvalContext.getCtx();
		var envs = EvalContext.callStack(EvalContext.getEval(ctx));
		var envs = if (envs.length >= 2) envs.slice(2) else envs; // Skip calls to callStack() and getCallStack()
		makeStackValue(envs);
	});

	public static final getExceptionStack:Value = EvalEncode.vfun0(() -> {
		var ctx = EvalContext.getCtx();
		var envs = EvalContext.getEval(ctx).exceptionStack.copy();
		envs.reverse();
		makeStack(envs);
	});
}
