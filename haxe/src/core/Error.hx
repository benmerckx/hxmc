package core;

import Type as StdType;
import core.Globals;
import core.TType;
import core.TFunctions;
import core.TFunctions.*;
import core.TPrinting;
import core.TPrinting.*;
import core.TUnification.UnifyError;
import core.TOther.TClassTools;
import core.ds.VectorTools.vector;

// port: from haxe/src/core/error.ml.
enum CallError {
	NotEnoughArguments(args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>);
	TooManyArguments;
	CouldNotUnify(message:ErrorMsg);
	CannotSkipNonNullable(name:String);
}

enum ErrorMsg {
	ModuleNotFound(path:GlobalTypePath);
	TypeNotFound(path:GlobalTypePath, name:String, reason:TypeNotFoundReason);
	Unify(errors:Array<UnifyError>);
	Custom(message:String);
	UnknownIdent(name:String);
	CallError(error:CallError);
	NoConstructor(type:ModuleType);
	AbstractClass(type:ModuleType);
}

enum TypeNotFoundReason {
	PrivateType;
	NotDefined;
}

@:structInit class CompilerError {
	public var errMessage:ErrorMsg;
	public var errPos:Pos;
	// Reverse list of sub errors. Use Error.recurse_error to handle an error and its sub errors with depth.
	public var errSub:Array<CompilerError>;

	public inline function new(errMessage:ErrorMsg, errPos:Pos, errSub:Array<CompilerError>) {
		this.errMessage = errMessage;
		this.errPos = errPos;
		this.errSub = errSub;
	}

	public inline function clone():CompilerError return new CompilerError(errMessage, errPos, errSub);
}

@:structInit class MacroError {
	public var msg:String;
	public var pos:Pos;
	public var sub:Array<MacroError>;

	public inline function new(msg:String, pos:Pos, sub:Array<MacroError>) {
		this.msg = msg;
		this.pos = pos;
		this.sub = sub;
	}

	public inline function clone():MacroError return new MacroError(msg, pos, sub);
}

class FatalError {
	public var error:CompilerError;

	public function new(error:CompilerError) this.error = error;
}

class TypingError {
	public var error:CompilerError;

	public function new(error:CompilerError) this.error = error;
}

class Error {
	public static function makeError(msg:ErrorMsg, p:Pos,
			?sub:Array<CompilerError>):CompilerError return {errMessage: msg, errPos: p, errSub: sub == null ? [] : sub};

	public static function convertError(err:MacroError):CompilerError {
		var sub = err.sub.map(convertError);
		sub.reverse();
		return makeError(Custom(err.msg), err.pos, sub);
	}

	public static function recurseError(cb:Int->CompilerError->Void, err:CompilerError):Void {
		function loop(depth:Int, err:CompilerError):Void {
			cb(depth, err);
			var children = err.errSub.copy();
			children.reverse();
			for (err in children) loop(depth + 1, err);
		}
		loop(0, err);
	}

	public static function abort(msg:String, p:Pos):Dynamic throw new FatalError(makeError(Custom(msg), p));

	public static function stringSource(t:T):Array<String> return switch follow(t) {
		case TInst(c, tl):
			var names = [for (s in TClassTools.getAllFields(c, tl).keys()) s];
			names.sort(core.ds.Key.compareStrings);
			names.reverse();
			names;
		case TAnon(a):
			var names = [for (s in a.aFields.keys()) s];
			names.sort(core.ds.Key.compareStrings);
			names.reverse();
			[for (s in names) a.aFields.get(s).cfName];
		case TAbstract(a, _) if (a.aImpl != null): [for (cf in a.aImpl.clOrderedStatics) cf.cfName];
		case _: [];
	};

	public static function shortType(ctx:PrintContext, t:T):String {
		var str = sType(ctx, t);
		return str.length > 150 ? str.substr(0, 147) + "..." : str;
	}

	/**
		Should be called for each complementary error message.
	**/
	public static function complMsg(s:String):String return "... " + s;

	public static function unifyErrorMsg(ctx:PrintContext, err:UnifyError):String return switch err {
		case CannotUnify(t1, t2): sType(ctx, t1) + " should be " + sType(ctx, t2);
		case CannotUnifyImplementation(tImpl, tParent): sType(ctx, tImpl) + " should be " + sType(ctx, tParent);
		case InvalidFieldType(s): "Invalid type for field " + s + " :";
		case HasNoField(t, n): StringError.stringError(n, stringSource(t), shortType(ctx, t) + " has no field " + n);
		case HasNoRuntimeField(t, n): sType(ctx, t) + "." + n + " is not accessible at runtime";
		case HasExtraField(t, n): shortType(ctx, t) + " has extra field " + n;
		case InvalidKind(f, a, b): switch [a, b] {
				case [Var(va), Var(vb)]:
					var name, stra, strb;
					if (StdType.enumEq(va.vRead, vb.vRead)) {
						name = "setter";
						stra = sAccess(false, va.vWrite);
						strb = sAccess(false, vb.vWrite);
					} else if (StdType.enumEq(va.vWrite, vb.vWrite)) {
						name = "getter";
						stra = sAccess(true, va.vRead);
						strb = sAccess(true, vb.vRead);
					} else {
						name = "access";
						stra = "(" + sAccess(true, va.vRead) + "," + sAccess(false, va.vWrite) + ")";
						strb = "(" + sAccess(true, vb.vRead) + "," + sAccess(false, vb.vWrite) + ")";
					}
					"Inconsistent " + name + " for field " + f + " : " + stra + " should be " + strb;
				case _: "Field " + f + " is " + sKind(a) + " but should be " + sKind(b);
			}
		case InvalidVisibility(n): "The field " + n + " is not public";
		case NotMatchingOptional(_, _, n): "Optional attribute of argument " + n + " differs";
		case InvariantParameter(_): "Type parameters are invariant";
		case ConstraintFailure(name): "Constraint check failure for " + name;
		case MissingOverload(cf, t): cf.cfName + " has no overload for " + sType(ctx, t);
		case FinalInvariance(_, _): "Cannot unify final and non-final fields";
		case InvalidFunctionArgument(i, _): "Cannot unify argument " + i;
		case InvalidReturnType: "Cannot unify return types";
		case UnifyCustom(msg): msg;
	};

	public static function errorMsg(msg:ErrorMsg):String return switch msg {
		case ModuleNotFound(m): "Type not found : " + Globals.sTypePath(m);
		case TypeNotFound(m, t, PrivateType): "Cannot access private type " + t + " in module " + Globals.sTypePath(m);
		case TypeNotFound(m, t, NotDefined): "Module " + Globals.sTypePath(m) + " does not define type " + t;
		case Unify(l): BetterErrors.betterErrorMessage(l);
		case UnknownIdent(s): "Unknown identifier : " + s;
		case Custom(s): s;
		case CallError(err): sCallError(err);
		case NoConstructor(mt): Globals.sTypePath(tPath(mt)) + " does not have a constructor";
		case AbstractClass(mt): Globals.sTypePath(tPath(mt)) + " is abstract and cannot be constructed";
	};

	public static function sCallError(err:CallError):String return switch err {
		case NotEnoughArguments(tl):
			var ctx = printContext();
			"Not enough arguments, expected " + [for (a in tl) a.name + ":" + shortType(ctx, a.type)].join(", ");
		case TooManyArguments: "Too many arguments";
		case CouldNotUnify(err): errorMsg(err);
		case CannotSkipNonNullable(s): "Cannot skip non-nullable argument " + s;
	};

	// Global error helpers
	public static function raiseError(err:CompilerError):Dynamic throw new TypingError(err);

	public static function raiseErrorMsg(msg:ErrorMsg, p:Pos):Dynamic return raiseError(makeError(msg, p));

	public static function raiseMsg(msg:String, p:Pos):Dynamic return raiseErrorMsg(Custom(msg), p);

	public static function raiseTypingError(msg:String, p:Pos):Dynamic return raiseMsg(msg, p);

	public static function raiseTypingErrorExt(err:CompilerError):Dynamic return raiseError(err);

	public static function raiseStdNotFound():Dynamic {
		var path = Sys.getEnv("HAXE_STD_PATH");
		if (path != null) return
			raiseTypingError('Standard library not found. Please check your `HAXE_STD_PATH` environment variable (current value: "'
			+ path
			+ '")',
			Globals.nullPos);
		return raiseTypingError("Standard library not found. You may need to set your `HAXE_STD_PATH` environment variable",
			Globals.nullPos);
	}

	public static function errorRequire(r:String, p:Pos):Dynamic {
		if (r == "") return raiseTypingError("This field is not available with the current compilation flags", p);
		var requirement = if (r == "sys") "a system platform (php,neko,cpp,etc.)"; else if (StringTools.startsWith(r, "flash")) {
			var v = StringTools.replace(r.substr(5), "_", ".");
			"flash version " + v + " (use -swf-version " + v + ")";
		} else "'" + r + "' to be enabled";
		return raiseTypingError("Accessing this field requires " + requirement, p);
	}

	public static function invalidAssign(p:Pos):Dynamic return raiseTypingError("Invalid assign", p);
}

@:structInit class AccessKindInfo {
	public var isOptional:Bool;
	public var isFinal:Bool;

	public inline function new(isOptional:Bool, isFinal:Bool) {
		this.isOptional = isOptional;
		this.isFinal = isFinal;
	}

	public inline function clone():AccessKindInfo return new AccessKindInfo(isOptional, isFinal);
}

enum ErrorAccessKind {
	Field(name:String);
	FunctionArgument(index:Int, total:Int);
	FunctionReturn;
	TypeParameter(index:Int);
	Root;
}

@:structInit class ErrorAccess {
	public var accKind:ErrorAccessKind;
	public var accExpected:T;
	public var accActual:T;
	public var accMessages:Array<UnifyError>;
	public var accExtra:Array<UnifyError>;
	public var accNext:Null<ErrorAccess>;
	public var accExpectedInfo:AccessKindInfo;
	public var accActualInfo:AccessKindInfo;

	public inline function new(accKind:ErrorAccessKind, accExpected:T, accActual:T, accMessages:Array<UnifyError>,
			accExtra:Array<UnifyError>, accNext:Null<ErrorAccess>, accExpectedInfo:AccessKindInfo, accActualInfo:AccessKindInfo) {
		this.accKind = accKind;
		this.accExpected = accExpected;
		this.accActual = accActual;
		this.accMessages = accMessages;
		this.accExtra = accExtra;
		this.accNext = accNext;
		this.accExpectedInfo = accExpectedInfo;
		this.accActualInfo = accActualInfo;
	}

	public inline function clone():ErrorAccess return new ErrorAccess(accKind, accExpected, accActual, accMessages, accExtra, accNext,
		accExpectedInfo, accActualInfo);
}

class BetterErrors {
	public static function sAccessKind(kind:ErrorAccessKind):String return switch kind {
		case Field(s): "Field " + s;
		case FunctionArgument(i, l): 'FunctionArgument($i, $l)';
		case FunctionReturn: "FunctionReturn";
		case TypeParameter(i): "TypeParameter " + i;
		case Root: "Root";
	};

	public static function getAccessChain(ctx:PrintContext, l:Array<UnifyError>):ErrorAccess {
		inline function makeAcc(kind:ErrorAccessKind, actual:T, expected:T):ErrorAccess return {
			accKind: kind,
			accExpected: expected,
			accActual: actual,
			accMessages: [],
			accExtra: [],
			accNext: null,
			accExpectedInfo: {isOptional: false, isFinal: false},
			accActualInfo: {isOptional: false, isFinal: false}
		};
		var root = makeAcc(Root, tDynamic, tDynamic), current = root;
		inline function addMessage(msg:UnifyError):Void current.accMessages.unshift(msg);
		inline function addAccess(kind:ErrorAccessKind):Void {
			var acc = makeAcc(kind, tDynamic, tDynamic);
			current.accNext = acc;
			current = acc;
		}
		for (err in l) switch err {
			case CannotUnify(t1, t2):
				current.accActual = t1;
				current.accExpected = t2;
				addMessage(err);
			case CannotUnifyImplementation(t2, t1):
				current.accActual = t1;
				current.accExpected = t2;
				addMessage(err);
			case NotMatchingOptional(o1, o2, _):
				current.accActualInfo.isOptional = o1;
				current.accExpectedInfo.isOptional = o2;
				addMessage(err);
			case InvalidFieldType(s):
				addAccess(Field(s));
			case FinalInvariance(f1, f2):
				current.accActualInfo.isFinal = f1;
				current.accExpectedInfo.isFinal = f2;
				addMessage(err);
			case InvalidFunctionArgument(i, l):
				addAccess(FunctionArgument(i, l));
			case InvalidReturnType:
				addAccess(FunctionReturn);
			case InvariantParameter(i):
				addAccess(TypeParameter(i));
			case UnifyCustom(_):
				current.accExtra.unshift(err);
			case _:
				addMessage(err);
		}
		return root;
	}

	// non-recursive s_type
	public static function sType(ctx:PrintContext, t:T):String return switch t {
		case TMono(r): core.TPrinting.MonomorphPrinting.sMono(sType, ctx, false, r);
		case TEnum(e, tl): Globals.sTypePath(e.ePath) + sTypeParams(ctx, tl);
		case TInst(c, tl): switch c.clKind {
				case KExpr(e): core.AstPrinter.sExpr(e);
				case _: Globals.sTypePath(c.clPath) + sTypeParams(ctx, tl);
			}
		case TType(t, tl): Globals.sTypePath(t.tPath) + sTypeParams(ctx, tl);
		case TAbstract(a, tl): Globals.sTypePath(a.aPath)
			// show next scope of type parameter instead of Null<...>
			+ (a.aPath.pack.length == 0 && a.aPath.name == "Null" ? sTypeParamsExpanded(ctx, tl) : sTypeParams(ctx, tl));
		case TFun({args: []}): "() -> ...";
		case TFun(s):
			var args = switch s.args {
				case [{name: ""}]: "...";
				case l: "(" + [for (a in l) (a.optional ? "?" : "") + "..."].join(", ") + ")";
			};
			args + " -> ...";
		case TAnon(a): switch a.aStatus {
				case ClassStatics(c): "{ ClassStatics " + Globals.sTypePath(c.clPath) + " }";
				case EnumStatics(e): "{ EnumStatics " + Globals.sTypePath(e.ePath) + " }";
				case AbstractStatics(a): "{ AbstractStatics " + Globals.sTypePath(a.aPath) + " }";
				case _:
					var names = [for (n in a.aFields.keys()) n];
					names.sort(core.ds.Key.compareStrings);
					names.reverse();
					"{" + [
						for (n in names) {
							var f = a.aFields.get(n);
							(Meta.has(Meta.Optional, f.cfMeta) ? " ?" : " ") + f.cfName;
						}
					].join(",") + " }";
			}
		case TDynamic(null): "Dynamic";
		case TDynamic(t2): "Dynamic" + sTypeParams(ctx, vector(t2));
		case TLazy(f): sType(ctx, lazyType(f));
	};

	public static function sTypeParams(ctx:PrintContext,
			l:TParams):String return l.length == 0 ? "" : "<" + [for (_ in l) "..."].join(", ") + ">";

	public static function sTypeParamsExpanded(ctx:PrintContext,
			l:TParams):String return l.length == 0 ? "" : "<" + [for (t in l) sType(ctx, t)].join(", ") + ">";

	public static function betterErrorMessage(l:Array<UnifyError>):String {
		var ctx = printContext();
		var filtered:Array<UnifyError> = [];
		var i = 0;
		while (i < l.length) {
			var err = l[i++];
			if (err.match(CannotUnify(_, _))) while (i < l.length && l[i].match(CannotUnify(_, _))) i++;
			filtered.push(err);
		}
		var access = getAccessChain(ctx, filtered);
		var message = new StringBuf();
		inline function fill(s:String, i:Int, total:Int):Array<String> return [for (k in 1...total + 1) k == i ? s : "..."];
		function loop(access:ErrorAccess, previous:ErrorAccess):{actual:String, expected:String} {
			inline function next():{actual:String, expected:String} {
				if (access.accNext != null) return loop(access.accNext, access);
				if (access.accMessages.length > 0) message.add(Error.unifyErrorMsg(ctx, access.accMessages[0]));
				inline function withInfo(t:T,
						info:AccessKindInfo):String return (info.isOptional ? "?" : "")
						// remove Null<...> if optional
						+ sType(ctx, info.isOptional ? followWithoutType(t) : t);
				return {
					actual: withInfo(access.accActual, access.accActualInfo),
					expected: withInfo(access.accExpected, access.accExpectedInfo)
				};
			}
			return switch access.accKind {
				case Field(s):
					var pair = next();
					{actual: "{ " + (access.accActualInfo.isFinal ? "final " : "") + s + ": " + pair.actual + " }",
						expected: "{ "
						+ (access.accExpectedInfo.isFinal ? "final " : "")
						+ s
						+ ": "
						+ pair.expected
						+ " }"};
				case FunctionArgument(i, l):
					var pair = next();
					{
						actual: "(" + fill(pair.expected, i, l).join(", ") + ") -> ...",
						expected: "(" + fill(pair.actual, i, l).join(", ") + ") -> ..."
					};
				case FunctionReturn:
					var pair = next();
					{actual: "(...) -> " + pair.actual, expected: "(...) -> " + pair.expected};
				case TypeParameter(i):
					inline function getParams(t:T):{path:GlobalTypePath, params:TParams}
						return switch t {
							case TInst(c, params): {path: c.clPath, params: params};
							case TEnum(e, params): {path: e.ePath, params: params};
							case TAbstract(a, params): {path: a.aPath, params: params};
							case TType(t, params): {path: t.tPath, params: params};
							case _: throw "Invalid type parameter access";
						};
					var pair = next(), p1 = getParams(previous.accActual), p2 = getParams(previous.accExpected);
					{actual: Globals.sTypePath(p1.path) + "<" + fill(pair.actual, i, p1.params.length).join(", ") + ">",
						expected: Globals.sTypePath(p2.path)
						+ "<"
						+ fill(pair.expected, i, p2.params.length).join(", ")
						+ ">"};
				case Root: next();
			};
		}
		if (access.accNext == null) {
			var messages = access.accExtra.concat(access.accMessages).map(function(err) return Error.unifyErrorMsg(ctx, err));
			messages.reverse();
			return messages.join("\n");
		}
		var result = loop(access.accNext, access);
		return 'error: ${message.toString()}\nhave: ${result.actual}\nwant: ${result.expected}';
	}
}
