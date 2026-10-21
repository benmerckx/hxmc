package optimization;

import String as StdString;
import context.SafeCom.SafeContext;
import core.Globals;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.TFunctions.NotFound;
import core.TFunctions.TypeExit;
import core.TUnification.*;
import core.Texpr;
import core.Texpr.*;
import core.Meta;
import core.Error;
import optimization.OptimizerTexpr.*;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

@:structInit class InlineContext {
	public var scom:SafeContext;
	public var typer:Null<context.Typecore.Typer>;

	public inline function new(scom:SafeContext, typer:Null<context.Typecore.Typer>) {
		this.scom = scom;
		this.typer = typer;
	}

	public inline function clone():InlineContext return new InlineContext(scom, typer);
}

@:structInit class InLocal {
	public var iVar:TVar;
	public var iSubst:TVar;
	public var iOutside:Bool;
	public var iAbstractThis:Bool;
	public var iCaptured:Bool;
	public var iWrite:Bool;
	public var iRead:Int;
	public var iCalled:Int;
	public var iForceTemp:Bool;
	public var iDefaultValue:Null<TExpr>;

	public inline function new(iVar:TVar, iSubst:TVar, iOutside:Bool, iAbstractThis:Bool, iCaptured:Bool, iWrite:Bool, iRead:Int,
			iCalled:Int, iForceTemp:Bool, iDefaultValue:Null<TExpr>) {
		this.iVar = iVar;
		this.iSubst = iSubst;
		this.iOutside = iOutside;
		this.iAbstractThis = iAbstractThis;
		this.iCaptured = iCaptured;
		this.iWrite = iWrite;
		this.iRead = iRead;
		this.iCalled = iCalled;
		this.iForceTemp = iForceTemp;
		this.iDefaultValue = iDefaultValue;
	}

	public inline function clone():InLocal return new InLocal(iVar, iSubst, iOutside, iAbstractThis, iCaptured, iWrite, iRead, iCalled,
		iForceTemp, iDefaultValue);
}

enum VarInlineKind {
	VIInline;
	VIInlineIfCalled;
	VIDoNotInline;
}

@:structInit class InlineConfig {
	public var hasParams:Bool;
	public var mapType:T->T;

	public inline function new(hasParams:Bool, mapType:T->T) {
		this.hasParams = hasParams;
		this.mapType = mapType;
	}

	public inline function clone():InlineConfig return new InlineConfig(hasParams, mapType);
}

class Inline {
	// port: hxmc's struct values (@:hxmc.struct, hxmc/src/hxmc/ir/CInterop.hx) are copied on assignment, so an
	// ... inline function writing through a struct parameter must not write the caller's variable: true here
	// ... forces a temporary for the argument (v the parameter's substitute in the mapped body); always null
	// ... in the compiler itself.
	public static var copyArgumentHook:Null<(v:TVar, arg:TExpr, body:TExpr) -> Bool> = null;

	public static function mkUntypedCall(name:String, p:Pos,
			params:Vector<TExpr>):TExpr return mk(TCall(mk(TIdent(name), tDynamic, p), params), tDynamic, p);

	public static function apiInline2(b:BasicTypes, platform:core.Globals.Platform, c:TClass, field:String, params:Vector<TExpr>,
			p:Pos):Null<TExpr> {
		var path = Globals.sTypePath(c.clPath);
		return switch [path, field, params] {
			case ["Type", "enumIndex", [{eexpr: TField(_, FEnum(_, f))}]]: mk(TConst(TInt(f.efIndex)), b.tint, p);
			case [
				"Type",
				"enumIndex",
				[
					{
						eexpr: TCall({eexpr: TField(_, FEnum(_, f))}, pl)
					}
				]
			] if (all(e -> !hasSideEffect(e), pl)): mk(TConst(TInt(f.efIndex)), b.tint, p);
			case ["Std", "int", [e = {eexpr: TConst(TInt(_))}]]: {eexpr: e.eexpr, etype: e.etype, epos: p};
			case ["String", "fromCharCode", [{eexpr: TConst(TInt(i))}]] if (i > 0 && i < 128): mk(TConst(TString(StdString.fromCharCode(i))),
					b.tstring, p);
			case [
				"Std",
				"string",
				[
					{
						eexpr: TCast(e = {eexpr: TConst(ct)}, null)
					}
				]
			] | ["Std", "string", [e = {eexpr: TConst(ct)}]]: switch ct {
				case TString(_): {eexpr: e.eexpr, etype: e.etype, epos: p};
				case TInt(i): mk(TConst(TString(Std.string(i))), b.tstring, p);
				case TBool(v): mk(TConst(TString(v ? "true" : "false")), b.tstring, p);
				case _: null;
			}
			case [
				"Std",
				"string",
				[e = {eexpr: TIf(_, {eexpr: TConst(TString(_))}, {eexpr: TConst(TString(_))})}]
			]: e;
			case ["Std", "string", [ev = {eexpr: TLocal(v) | TField({eexpr: TLocal(v)}, _)}]]
				if ((platform == Js || platform == Flash) && switch v.vKind {
						case VUser(_): true;
						case _: false;
					}):
					inline function stringv():TExpr {
						var pos = ev.epos;
						var str = mk(TBinop(OpAdd, mk(TConst(TString("")), b.tstring, pos), ev), b.tstring, pos);
						if (platform == Js || isNullable(ev.etype)) {
							var cond = mk(TBinop(OpEq, ev, mk(TConst(TNull), tDynamic, pos)), b.tbool, pos);
							return mk(TIf(cond, mk(TConst(TString("null")), b.tstring, pos), str), b.tstring, pos);
						}
						return str;
					}
					switch follow(ev.etype) {
						case TInst({clPath: {pack: [], name: "String"}}, []) |
							TAbstract({aPath: {pack: [], name: "Float" | "Int" | "UInt" | "Bool"}}, []): stringv();
						case _: null;
					}
			case ["Std", "int", [{eexpr: TConst(TFloat(s))}]]:
				var f = core.ds.OcamlFloat.ofString(s);
				!Math.isFinite(f)
				|| Math.isNaN(f)
				|| f <= -2147483649.0
				|| f >= 2147483648.0 ? null /* out range, keep platform-specific behavior */ : mk(TConst(TInt(Std.int(f))), b.tint, p);
			case ["Math", "ceil", [{eexpr: TConst(TFloat(s))}]]:
				var f = core.ds.OcamlFloat.ofString(s);
				!Math.isFinite(f)
				|| Math.isNaN(f)
				|| f <= -2147483649.0
				|| f >= 2147483647.0 ? null /* out range, keep platform-specific behavior */ : mk(TConst(TInt(Math.ceil(f))), b.tint, p);
			case ["Math", "floor", [{eexpr: TConst(TFloat(s))}]]:
				var f = core.ds.OcamlFloat.ofString(s);
				!Math.isFinite(f)
				|| Math.isNaN(f)
				|| f <= -2147483648.0
				|| f >= 2147483648.0 ? null /* out range, keep platform-specific behavior */ : mk(TConst(TInt(Math.floor(f))), b.tint, p);
			case ["java.Lib", "lock", [obj, block]]: mkUntypedCall("__lock__", p, vector(obj, mkBlock(block)));
			case _: null;
		};
	}

	public static function contextOfTyper(typer:context.Typecore.Typer):InlineContext return {
		scom: context.SafeCom.ofTyper(typer),
		typer: typer
	};

	public static function contextOfScom(scom:SafeContext):InlineContext return {scom: scom, typer: null};

	public static function apiInline(scom:SafeContext, c:TClass, field:String, params:Vector<TExpr>, p:Pos):Null<TExpr> {
		function mkTypeexpr(path:GlobalTypePath):TExpr {
			var m:ModuleDef = try scom.findModule(path) catch (_:NotFound) {
				throw "Inline.mkTypeexpr";
			};
			addDependency(scom.curclass.clModule, m, MDepFromTyping);
			for (mt in m.mTypes) switch mt {
				case TClassDecl(cl) if (Globals.sTypePath(cl.clPath) == Globals.sTypePath(path)):
					return Texpr.Builder.makeStaticThis(cl, p);
				case _:
			}
			throw "Invalid_argument: Option.get";
		}
		inline function jsSyntax():TExpr return mkTypeexpr({pack: ["js"], name: "Syntax"});
		inline function jsBoot():TExpr return mkTypeexpr({pack: ["js"], name: "Boot"});
		var b = scom.basic;
		return switch [Globals.sTypePath(c.clPath), field, params] {
			case ["Std", "isOfType", [o, t]] | ["js.Boot", "__instanceof", [o, t]] if (scom.platform == Js):
				inline function trivial(e:TExpr):Bool return switch e.eexpr {
					case TConst(_) | TLocal(_): true;
					case _: false;
				};
				function typeof(name:String):TExpr return mk(TBinop(OpEq, Texpr.Builder.fcall(jsSyntax(), "typeof", vector(o), b.tstring, p),
					mk(TConst(TString(name)), b.tstring, p)),
					b.tbool, p);
				function skipCast(e:TExpr):TExpr return switch e.eexpr {
					case TCast(inner, null): skipCast(inner);
					case _: e;
				};
				switch skipCast(t).eexpr {
					// generate simple typeof checks for basic types
					case TTypeExpr(TClassDecl({clPath: {pack: [], name: "String"}})): typeof("string");
					case TTypeExpr(TAbstractDecl({aPath: {pack: [], name: "Bool"}})): typeof("boolean");
					case TTypeExpr(TAbstractDecl({aPath: {pack: [], name: "Float"}})): typeof("number");
					case TTypeExpr(TAbstractDecl({aPath: {pack: [], name: "Int"}})) if (trivial(o)):
						// generate typeof(o) == "number" && (o|0) === o check
						var lhs = mk(TBinop(OpOr, o, mk(TConst(TInt(0)), b.tint, p)), b.tint, p);
						var check = Texpr.Builder.fcall(jsSyntax(), "strictEq", vector(lhs, o), b.tbool, p);
						mk(TBinop(OpBoolAnd, typeof("number"), check), b.tbool, p);
					case TTypeExpr(TClassDecl({clPath: {pack: [], name: "Array"}})):
						// generate (o instanceof Array) && o.__enum__ == null check
						var iof = Texpr.Builder.fcall(jsSyntax(), "instanceof", vector(o, t), b.tbool, p);
						if (!core.Define.defined(scom.defines, core.Define.JsEnumsAsArrays)) iof; else {
							var en = mk(TField(o, FDynamic("__enum__")), tDynamic, p);
							var notEnum = mk(TBinop(OpEq, en, mk(TConst(TNull), tDynamic, p)), b.tbool, p);
							mk(TBinop(OpBoolAnd, iof, notEnum), b.tbool, p);
						}
					case TTypeExpr(TClassDecl(cls)): hasClassFlag(cls,
							CInterface) ? Texpr.Builder.fcall(jsBoot(), "__implements", vector(o, t), b.tbool,
							p) : Texpr.Builder.fcall(jsSyntax(), "instanceof", vector(o, t), b.tbool, p);
					case _: null;
				}
			case ["js.Boot", "__downcastCheck", [o, t = {eexpr: TTypeExpr(TClassDecl(cls))}]] if (scom.platform == Js): hasClassFlag(cls,
					CInterface) ? Texpr.Builder.fcall(Texpr.Builder.makeStaticThis(c, p), "__implements", vector(o, t), b.tbool,
					p) : Texpr.Builder.fcall(jsSyntax(), "instanceof", vector(o, t), b.tbool, p);
			case [
				"haxe.ds._Vector.Vector_Impl_",
				"fromArrayCopy",
				[edecl = {eexpr: TArrayDecl(args)}]
			]:
				if (scom.platform != Jvm) null; else {
					var mpath:GlobalTypePath = field == "fromArrayCopy" ? {pack: ["haxe", "ds"], name: "Vector"} : {
						pack: ["jvm"],
						name: "NativeArray"
					};
					var m:ModuleDef = scom.findModule(mpath);
					var main:ModuleType = null;
					for (mt in m.mTypes) switch mt {
						case TClassDecl(_) | TAbstractDecl(_):
							main = mt;
							break;
						case _:
					}
					if (main == null) throw NotFound.raise();
					var t = switch [follow(edecl.etype), main] {
						case [TInst({clPath: {pack: [], name: "Array"}}, [t]), TClassDecl(cl)]: TInst(cl, vector(t));
						case [TInst({clPath: {pack: [], name: "Array"}}, [t]), TAbstractDecl(a)]: TAbstract(a, vector(t));
						case _: throw "Inline.vector";
					};
					var call = mkUntypedCall("__array__", p, args);
					{eexpr: call.eexpr, etype: t, epos: call.epos};
				}
			case _: apiInline2(b, scom.platform, c, field, params, p);
		};
	}

	public static function inlineDefaultConfig(cf:TClassField, t:T):InlineConfig {
		// type substitution on both class and function type parameters
		function getParams(c:TClass, pl:TParams):{params:TypeParams, types:TParams} {
			if (c.clSuper == null) return {params: c.clParams, types: pl};
			var sup = c.clSuper;
			var spl = switch applyParams(c.clParams, pl, TInst(sup.cls, sup.params)) {
				case TInst(_, pl): pl;
				case _: throw "Inline.getParams";
			};
			var ct = getParams(sup.cls, spl);
			return {params: c.clParams.concat(ct.params), types: pl.concat(ct.types)};
		}
		function loop(t:T):{params:TypeParams, types:TParams}
			return switch follow(t) {
				case TInst({clKind: KTypeParameter(ttp)}, _):
					var acc:{params:TypeParams, types:TParams} = {params: vector(), types: vector()};
					for (t in getConstraints(ttp)) {
						var r = loop(t);
						acc = {params: r.params.concat(acc.params), types: r.types.concat(acc.types)};
					}
					acc;
				case TInst(c, pl): getParams(c, pl);
				case _: {params: vector(), types: vector()};
			};
		var config = loop(t);
		var monos = config.types.concat(cf.cfParams.map(_ -> mkMono()));
		var params = config.params.concat(cf.cfParams);
		return {hasParams: params.length > 0, mapType: t -> applyParams(params, monos, t)};
	}

	public static function inlineConfig(cls:Null<TClass>, cf:TClassField, args:Vector<TExpr>, ret:T):Null<InlineConfig> {
		if (cls == null) return null;
		return switch cls.clKind {
			case KAbstractImpl(_) if (hasClassFieldFlag(cf, CfImpl)):
				var t = if (hasClassFieldFlag(cf,
					CfAbstractConstructor)) ret; else if (args.length == 0)
					Error.raiseTypingError("Invalid abstract implementation function", cf.cfPos); else follow(args[0].etype);
				switch t {
					case TAbstract(a, pl):
						var monos = cf.cfParams.map(_ -> mkMono());
						{
							hasParams: a.aParams.length > 0 || cf.cfParams.length > 0,
							mapType: t -> applyParams(a.aParams, pl, applyParams(cf.cfParams, monos, t))
						};
					case _: null;
				}
			case _: null;
		};
	}

	public static function inlineMetadata(e:TExpr, meta:Metadata):TExpr {
		for (m in meta) switch m {
			case {meta: core.MetaList.StrictMeta.Pure, exprs: [{expr: EConst(Ident("inferredPure"))}]}:
			case {meta: core.MetaList.StrictMeta.Deprecated | core.MetaList.StrictMeta.Pure | core.MetaList.StrictMeta.NullSafety}:
				e = mk(TMeta(m, e), e.etype, e.epos);
			case _:
		}
		return e;
	}

	public static function typeInline(ictx:InlineContext, cf:TClassField, f:TFunc, ethis:TExpr, params:Vector<TExpr>, tret:T,
			config:Null<InlineConfig>, p:Pos, force:Bool, selfCallingClosure:Bool = false):TExpr {
		var scom:SafeContext = ictx.scom;
		try {
			var c = switch follow(ethis.etype) {
				case TInst(c, _): c;
				case TAnon(a): switch a.aStatus {
						case ClassStatics(c): c;
						case _: throw new TypeExit();
					}
				case _: throw new TypeExit();
			};
			var result = apiInline(scom, c, cf.cfName, params, p);
			if (result == null) throw new TypeExit();
			return result;
		} catch (_:TypeExit) {}
		if (config == null) config = inlineDefaultConfig(cf, ethis.etype);
		var hasParams = config.hasParams;
		var mapType = config.mapType;
		if (ictx.typer != null) params = inlineRestParams(ictx.typer, f, params, mapType, p);
		var state = new InlineState(ictx, ethis, params, cf, f, p);
		var vthis = state.initialize();
		var inLoop = false;
		inline function returnType(t:T, el:Vector<TExpr>):T {
			// If the function return is Dynamic or Void, stick to it.
			if (follow(f.tfType) == tDynamic || core.TOther.ExtType.isVoid(follow(f.tfType))) return f.tfType;
			// If the expression is Void, find common type of its branches.
			if (core.TOther.ExtType.isVoid(t)) return typing.UnifyMin.unifyMinRaise(scom.basic, el);
			return t;
		}
		inline function mapPos(e:TExpr):TExpr return selfCallingClosure
			|| core.Define.defined(scom.defines, core.Define.KeepInlinePositions) ? e : {
				eexpr: e.eexpr,
				etype: e.etype,
				epos: p
			};
		inline function saveLocals():Void->Void return ictx.typer == null ? function() {} : context.Typecore.saveLocals(ictx.typer);
		function hasTermReturn(e:TExpr):Bool {
			function loop(e:TExpr):Void {
				var r = switch e.eexpr {
					case TReturn(_): true;
					case TFunction(_): false;
					case TIf(_, _, null) | TSwitch({switchDefault: null}) | TWhile(_, _, NormalWhile): false; // we might not enter this code at all
					case TTry(a, catches): hasTermReturn(a) && catches.foreach(c -> hasTermReturn(c.expr));
					case TIf(cond, a, b): hasTermReturn(cond) || hasTermReturn(a) && hasTermReturn(b);
					case TSwitch(s): hasTermReturn(s.switchSubject) || hasTermReturn(s.switchDefault) && s.switchCases.foreach(c -> hasTermReturn(c.caseExpr));
					case TBinop(OpBoolAnd, a, b): hasTermReturn(a) && hasTermReturn(b);
					case _:
						iter(loop, e);
						false;
				};
				if (r) throw new TypeExit();
			}
			try {
				loop(e);
				return false;
			} catch (_:TypeExit) return true;
		}
		function map(term:Bool, inCall:Bool, e:TExpr):TExpr {
			var po = e.epos;
			e = mapPos(e);
			return switch e.eexpr {
				case TLocal(v):
					var l = state.read(v);
					var i = inLoop ? 2 : 1;
					if (inCall) l.iCalled += i;
					else l.iRead += i;
					var e = withExpr(e, TLocal(l.iSubst));
					l.iAbstractThis ? mk(TCast(e, null), v.vType, e.epos) : e;
				case TConst(TThis): if (vthis == null) Error.raiseTypingError("Could not inline `this` outside of an instance context",
						po); else {
						var l = state.read(vthis);
						l.iRead += inLoop ? 2 : 1;
						withExpr(e, TLocal(l.iSubst));
					}
				case TVar(v, eo):
					if (hasVarFlag(v,
						VStatic)) Error.raiseTypingError("Inline functions cannot have static locals",
							v.vPos);
					// port: OCaml evaluates the constructor arguments right-to-left: map eo before declaring v
					var eo = eo == null ? null : map(false,
						false, eo);
					var v = state.declare(v).iSubst;
					withExpr(e, TVar(v, eo));
				case TReturn(eo) if (!state.inLocalFun):
					if (!term) {
						switch cf.cfKind {
							case Method(MethInline): Error.raiseTypingError("Cannot inline a not final return", po);
							case _: Error.raiseTypingError("Function "
									+ cf.cfName
									+ " cannot be inlined because of a not final return", p);
						}
					}
					if (eo == null) mk(TConst(TNull), f.tfType, p); else {
						state.hasReturnValue = true;
						map(term, false, eo);
					}
				case TWhile(cond, body, flag):
					var cond = map(false, false, cond);
					var old = inLoop;
					inLoop = true;
					var body = map(false, false, body);
					inLoop = old;
					withExpr(e, TWhile(cond, body, flag));
				case TSwitch(s) if (term):
					var innerTerm = term && isExhaustive(s);
					var cases = s.switchCases.map(c -> ({
						casePatterns: c.casePatterns.map(e -> map(false, false, e)),
						caseExpr: map(innerTerm, false, c.caseExpr)
					} : core.TType.TSwitchCase));
					var def = s.switchDefault == null ? null : map(innerTerm, false, s.switchDefault);
					var t = returnType(e.etype, def == null ? cases.map(c -> c.caseExpr) : cases.map(c -> c.caseExpr).snoc(def));
					{eexpr: TSwitch(mkSwitch(map(false, false, s.switchSubject), cases, def, s.switchExhaustive)), etype: t, epos: e.epos};
				case TTry(e1, catches):
					var t = !term ? e.etype : returnType(e.etype,
						VectorTools.cons(e1, catches.map(c ->
							c.expr)));
					// port: right-to-left constructor arguments: catches before the body
					var catches = catches.map(c -> {
						variable: state.declare(c.variable).iSubst,
						expr: map(term, false, c.expr)
					});
					var body = map(term, false, e1);
					{eexpr: TTry(body, catches), etype: t, epos: e.epos};
				case TBlock(el):
					var restore = saveLocals();
					var t = e.etype;
					// port: the list walked by index (upstream: loop on its tail), the
					// statements mapped in order into a Vector of the block's length
					function block(el:Vector<TExpr>):Vector<TExpr> {
						if (el.length == 0) return if (term) {
							t = mkMono();
							vector(mk(TConst(TNull), t, p));
						} else vector();
						var r = new Vector<TExpr>(el.length), n = 0;
						inline function last(a:TExpr):Vector<TExpr> {
							var a = map(term, false, a);
							if (term) t = a.etype;
							r[n++] = a;
							return n == el.length ? r : r.slice(0, n);
						}
						while (true) {
							var first = el[n];
							if (n == el.length - 1) return last(first);
							switch first.eexpr {
								case TIf(cond, a, null) if (term && hasTermReturn(a)):
									var rest = el.slice(n + 1);
									return last({
										eexpr: TIf(cond, a, mk(TBlock(rest), first.etype, first.epos)),
										etype: first.etype,
										epos: core.Ast.punion(first.epos, rest[rest.length - 1].epos)
									});
								case _:
									r[n++] = map(false, false, first);
							}
						}
					};
					var result = block(el);
					restore();
					{eexpr: TBlock(result), etype: t, epos: e.epos};
				case TIf(cond, a, b) if (term && b != null):
					var cond = map(false, false, cond);
					var a = map(term, false, a);
					var b = map(term, false, b);
					{eexpr: TIf(cond, a, b), etype: returnType(e.etype, vector(a, b)), epos: e.epos};
				case TParenthesis(a):
					var a = map(term, inCall, a);
					mk(TParenthesis(a), a.etype, e.epos);
				case TUnop(op = Increment | Decrement, flag, e1 = {eexpr: TLocal(v)}):
					state.hadSideEffect = true;
					var l = state.read(v);
					l.iWrite = true;
					withExpr(e, TUnop(op, flag, withExpr(e1, TLocal(l.iSubst))));
				case TBinop(op = OpAssign | OpAssignOp(_), e1 = {eexpr: TLocal(v)}, e2):
					state.hadSideEffect = true;
					var l = state.read(v);
					l.iWrite = true;
					var e2 = map(false, false, e2);
					withExpr(e, TBinop(op, withExpr(e1, TLocal(l.iSubst)), e2));
				case TObjectDecl(fl):
					var fl = fl.map(f -> {key: f.key, expr: map(false, false, f.expr)});
					switch follow(e.etype) {
						case TAnon(an) if (an.aStatus == Const): {
								eexpr: TObjectDecl(fl),
								etype: TAnon({
									aFields: an.aFields,
									aStatus: Closed
								}),
								epos: e.epos
							};
						case _: withExpr(e, TObjectDecl(fl));
					}
				case TFunction(f):
					var old = saveLocals();
					var args = f.tfArgs.map(a -> {variable: state.declare(a.variable).iSubst, defaultValue: a.defaultValue});
					var restore = state.enterLocalFun();
					var body = map(false, false, f.tfExpr);
					restore();
					old();
					withExpr(e, TFunction({tfArgs: args, tfExpr: body, tfType: f.tfType}));
				case TCall({eexpr: TConst(TSuper), etype: t}, el):
					state.hadSideEffect = true;
					switch follow(t) {
						case TInst(c = {clConstructor: cf = {cfKind: Method(MethInline), cfExpr: {eexpr: TFunction(tf)}}},
							_): map(term, false, typeInlineCtor(ictx, c, cf, tf, ethis, el, po));
						case _: Error.raiseTypingError("Cannot inline function containing super", po);
					}
				case TCall(e1, el):
					state.hadSideEffect = true;
					var e1 = map(false, true, e1);
					withExpr(e, TCall(e1, el.map(e -> map(false, false, e))));
				case TConst(TSuper): Error.raiseTypingError("Cannot inline function containing super", po);
				// Special case for @:ast-wrapped TSwitch nodes: If the recursion alters the type of the TSwitch node, we also want
				// to alter the type of the TMeta node.
				case TMeta(m = {meta: core.MetaList.StrictMeta.Ast}, e1) if (term):
					var e1 = map(term, inCall, e1);
					{eexpr: TMeta(m, e1), etype: e1.etype, epos: e.epos};
				case TMeta(m, e1): withExpr(e, TMeta(m, map(term, inCall, e1)));
				case TNew(_, _, _) | TBinop(OpAssignOp(_) | OpAssign, _, _) | TUnop(Increment | Decrement, _, _):
					state.hadSideEffect = true;
					mapExpr(e -> map(false, false, e), e);
				case _: mapExpr(e -> map(false, false, e), e);
			};
		}
		var e = map(true, false, f.tfExpr);
		// port: the arguments with a param or a default value, up to the first without
		var n = 0;
		while (n < f.tfArgs.length && (n < params.length || f.tfArgs[n].defaultValue != null)) n++;
		var tl = new Vector(n);
		for (i in 0...n) tl[i] = i < params.length ? {name: "", optional: false, type: params[i].etype} : {name: "", optional: true, type: mkMono()};
		e = state.finalize(e, tl, tret, hasParams, mapType, p);
		if (ictx.typer != null && Meta.has(Custom(":debug.inline"), ictx.typer.f.meta)) {
			function se(tabs:String,
					e:TExpr):String return core.TPrinting.sExprAst(true, tabs, core.TPrinting.sType.bind(core.TPrinting.printContext()), e);
			var args = state.inlinedVars.map(item -> '\n\t\t${item.local.iSubst.vName}<${item.local.iSubst.vId}> = '
				+ se("\t\t", item.expr))
				.join("");
			Sys.println('Inline ${cf.cfName}:\n\tArgs: $args\n\tExpr: ' + se("\t", f.tfExpr) + "\n\tResult: " + se("\t", e));
		}
		return e;
	}

	// Same as type_inline, but modifies the function body to add field inits
	public static function typeInlineCtor(ictx:InlineContext, c:TClass, cf:TClassField, tf:TFunc, ethis:TExpr, el:Vector<TExpr>,
			po:Pos):TExpr {
		var cparams = extractParamTypes(c.clParams);
		var thisExpr = mk(TConst(TThis), TInst(c, cparams), c.clPos);
		var inits = [];
		for (cf in c.clOrderedFields) switch [cf.cfKind, cf.cfExpr] {
			case [Var({vRead: _, vWrite: _}), e] if (e != null):
				var lhs = mk(TField(thisExpr, FInstance(c, cparams, cf)), cf.cfType, e.epos);
				inits.push(mk(TBinop(OpAssign, lhs, e), cf.cfType, e.epos));
			case _:
		}
		if (inits.length > 0) {
			var body = switch tf.tfExpr.eexpr {
				case TBlock(el): el;
				case _: vector(tf.tfExpr);
			};
			tf = {tfArgs: tf.tfArgs, tfType: tf.tfType, tfExpr: mk(TBlock(body.prependArray(inits)), ictx.scom.basic.tvoid, c.clPos)};
		}
		return typeInline(ictx, cf, tf, ethis, el, ictx.scom.basic.tvoid, null, po, true);
	}

	public static function inlineRestParams(ctx:context.Typecore.Typer, f:TFunc, params:Vector<TExpr>, mapType:T->T, p:Pos):Vector<TExpr> {
		if (!ctx.com.config.pfSupportsRestArgs) return params;
		// port: the rest argument's expression for the remaining params
		function restParam(v:TVar, params:Vector<TExpr>):TExpr {
			switch params {
				// In case of `...rest` just use `rest`
				case [{eexpr: TUnop(Spread, Prefix, e)}]:
					return e;
				case _:
			}
			// In other cases: `haxe.Rest.of([param1, param2, ...])`
			return switch follow(mapType(v.vType)) {
				case TAbstract(a = {aPath: {pack: ["haxe"], name: "Rest"}, aImpl: c}, [t]) if (c != null):
					var cf = c.clStatics.get("of");
					if (cf == null) throw "Can't find haxe.Rest.of function";
					var pos = punionEl(p, params);
					// [param1, param2, ...]
					// If we don't know the type (e.g. the rest argument is a field type parameter) then we need
					// to find a common type via unify_min.
					var paramType = switch follow(t) {
						case TMono(_): context.Typecore.unifyMin(ctx, params);
						case _: t;
					};
					var array = mk(TArrayDecl(params), ctx.t.tarray(paramType), pos);
					// haxe.Rest.of(array)
					typing.CallUnification.makeStaticCallBetter(ctx, c, cf, vector(t), vector(array), TAbstract(a, vector(paramType)), pos);
				case _: throw "Unexpected rest arguments type";
			};
		}
		// port: the list walk as a loop: params pass through, up to a last argument that expects rest parameters
		var args = f.tfArgs;
		for (i in 0...args.length) {
			// last argument expects rest parameters
			if (i == args.length - 1 && core.TOther.ExtType.isRest(follow(args[i].variable.vType))) {
				var r = new Vector<TExpr>(i + 1);
				Vector.blit(params, 0, r, 0, i);
				r[i] = restParam(args[i].variable, i == 0 ? params : params.slice(i));
				return r;
			}
			if (i >= params.length) return params;
		}
		return params;
	}
}

class InlineState {
	// port: upstream conses onto md.m_inline_calls (`x :: l`, then an assignment), which
	// is memory safe when parallel filter workers inline into classes of the same module; the
	// port's list is a shared Haxe array mutated in place, so concurrent pushes are serialized.
	static final inlineCallsMutex = new sys.thread.Mutex();

	var ictx:InlineContext;
	var scom:SafeContext;
	var ethis:TExpr;
	var params:Vector<TExpr>;
	var cf:TClassField;
	var f:TFunc;
	var p:Pos;
	var locals = new haxe.ds.IntMap<InLocal>();
	var checker:{mightBeAffected:TExpr->Bool, collectModifiedLocals:TExpr->Void};

	public var inlinedVars:Array<{local:InLocal, expr:TExpr}> = [];
	public var inLocalFun = false;
	public var hadSideEffect = false;
	public var hasReturnValue = false;

	public function new(ictx:InlineContext, ethis:TExpr, params:Vector<TExpr>, cf:TClassField, f:TFunc, p:Pos) {
		this.ictx = ictx;
		scom = ictx.scom;
		this.ethis = ethis;
		this.params = params;
		this.cf = cf;
		this.f = f;
		this.p = p;
		checker = createAffectionChecker();
	}

	public function enterLocalFun():Void->Void {
		var old = inLocalFun;
		inLocalFun = true;
		return function() inLocalFun = old;
	}

	function collectModifiedLocals(e:TExpr):Void checker.collectModifiedLocals(e);

	public function mightBeAffected(e:TExpr):Bool return checker.mightBeAffected(e);

	function local(v:TVar, subst:TVar, outside:Bool):InLocal return {
		iVar: v,
		iSubst: subst,
		iOutside: outside,
		iAbstractThis: Meta.has(This, v.vMeta),
		iCaptured: false,
		iWrite: false,
		iCalled: 0,
		iForceTemp: false,
		iRead: 0,
		iDefaultValue: null
	};

	public function declare(v:TVar):InLocal {
		if (locals.exists(v.vId)) return locals.get(v.vId);
		var name = core.Ast.getMetaString(v.vMeta, core.MetaList.StrictMeta.RealPath);
		if (name == null) name = v.vName;
		var w = allocVar(switch v.vKind {
			case VUser(_): VInlined;
			case k: k;
		}, name, v.vType, v.vPos);
		w.vExtra = v.vExtra;
		var i = local(v, w, false);
		w.vMeta = v.vMeta.filter(m -> m.meta != core.MetaList.StrictMeta.This);
		locals.set(v.vId, i);
		locals.set(w.vId, i);
		return i;
	}

	public function read(v:TVar):InLocal {
		var l = locals.exists(v.vId) ? locals.get(v.vId) : local(v, v, true);
		if (inLocalFun) l.iCaptured = true;
		return l;
	}

	function getSubstitutions(p:Pos):{vars:Array<{variable:TVar, expr:Null<TExpr>}>, subst:haxe.ds.IntMap<{kind:VarInlineKind, expr:TExpr}>} {
		/*
			if variables are not written and used with a const value, let's substitute
			with the actual value, either create a temp var
		*/
		var subst = new haxe.ds.IntMap<{kind:VarInlineKind, expr:TExpr}>();
		function constant(e:TExpr):Bool return switch e.eexpr {
			case TLocal(_)
				| TConst(TThis) // not really, but should not be move inside a function body
				| TObjectDecl(_) | TArrayDecl(_): false;
			case TFunction(_) | TField(_, FEnum(_, _)) | TTypeExpr(_) | TConst(_): true;
			case _: !checkExpr(e -> !constant(e), e);
		};
		function checkWrite(e:TExpr):Void switch e.eexpr {
			case TLocal(v) if (hasVarFlag(v, VFinal)):
				Error.raiseTypingError("Cannot modify abstract value of final local", p);
			case TField(_, fa):
				var cf = extractField(fa);
				if (cf != null && hasClassFieldFlag(cf, CfFinal)) Error.raiseTypingError("Cannot modify abstract value of final field", p);
			case TLocal(_) | TEnumParameter(_, _, _) | TArray(_, _):
			case TCast(e1, null):
				checkWrite(e1);
			case _:
				Error.raiseTypingError("Cannot modify the abstract value, store it into a local first", p);
		}
		var vars = [];
		for (item in inlinedVars) {
			var i = item.local;
			var e = item.expr;
			inline function accept(kind:VarInlineKind) subst.set(i.iSubst.vId, {kind: kind, expr: e});
			inline function reject():Void {
				// mark the replacement local for the analyzer
				if (i.iRead + i.iCalled <= 1 && !i.iWrite) i.iSubst.vKind = VGenerated;
				vars.unshift({variable: i.iSubst, expr: e});
			}
			if (i.iAbstractThis && i.iWrite) {
				checkWrite(e);
				accept(VIInline);
			} else if (i.iForceTemp || i.iCaptured && !constant(e)) reject();
			else {
				var kind = switch e.eexpr {
					case TLocal(_) if (i.iAbstractThis): VIInline;
					case TConst(TNull): VIDoNotInline;
					case TLocal(_) | TConst(_): !i.iWrite ? VIInline : VIDoNotInline;
					case TFunction(_):
						if (i.iWrite) Error.raiseTypingError("Cannot modify a closure parameter inside inline method", p);
						i.iRead <= 1 ? VIInline : VIInlineIfCalled;
					case _: !i.iWrite && i.iRead + i.iCalled <= 1 ? VIInline : VIDoNotInline;
				};
				switch kind {
					case VIInline:
						accept(kind);
					case VIDoNotInline:
						reject();
					case VIInlineIfCalled:
						// "Accept" it so it is added to the substitutions.
						accept(kind);
						// If it is read more than once, we still have to reject because we need a local.
						if (i.iRead > 1) reject();
						// Otherwise we don't!
				}
			}
		}
		return {vars: vars, subst: subst};
	}

	public function initialize():Null<TVar> {
		// use default values for null/unset arguments
		/*
			Build the expr/var subst list
		*/
		inline function setVars(pl:Vector<TExpr>, al:Vector<{variable:TVar, defaultValue:Null<TExpr>}>):Void {
			var acc = [];
			var index = 0;
			for (arg in al) {
				var v = arg.variable;
				var opt = arg.defaultValue;
				var l = declare(v);
				var e:TExpr;
				if (index < pl.length) {
					e = pl[index++];
					/*
						if we pass a Null<T> var to an inlined method that needs a T.
						we need to force a local var to be created on some platforms.
					*/
					if (scom.platformConfig.pfStatic && !isNullable(v.vType) && isNull(e.etype)) l.iForceTemp = true;
					/*
						if we cast from Dynamic, create a local var as well to do the cast
						once and allow DCE to perform properly.
					*/
					if ((follow(v.vType) == tDynamic) != (follow(e.etype) == tDynamic)) e = mk(TCast(e, null), v.vType, e.epos);
					switch [e.eexpr, opt] {
						case [TConst(TNull), c] if (c != null):
							// issue #9357
							e = {eexpr: c.eexpr, etype: c.etype, epos: e.epos};
						case [_, c] if (c != null && (switch c.eexpr {
							case TConst(TNull): false;
							case _: true;
						}) && (!scom.platformConfig.pfStatic || isNullable(v.vType))):
							l.iForceTemp = true;
							l.iDefaultValue = {eexpr: c.eexpr, etype: c.etype, epos: e.epos};
						case _:
					}
					if (hasSideEffect(e)) {
						collectModifiedLocals(e);
						hadSideEffect = true;
						l.iForceTemp = true;
					}
					// We use a null expression because we only care about the type (for abstract casts).
					if (l.iAbstractThis) l.iSubst.vExtra = varExtra(vector(), withExpr(e, TConst(TNull)));
				} else e = opt == null ? mk(TConst(TNull), v.vType, v.vPos) : opt;
				// port: `(l, e) :: acc` as a push, the accumulator reversed once at the end
				acc.push({local: l, expr: e});
			}
			acc.reverse();
			inlinedVars = acc; // Order is reversed due to tail-recursion
		}
		return switch ethis.eexpr {
			case TConst(TNull):
				setVars(params, f.tfArgs);
				null;
			case _:
				var self = switch ethis.eexpr {
					case TConst(TSuper): withExpr(ethis, TConst(TThis));
					case _: ethis;
				};
				var v = allocVar(VInlined, "_this", self.etype, self.epos);
				setVars(VectorTools.cons(self, params), VectorTools.cons({variable: v, defaultValue: (null : Null<TExpr>)}, f.tfArgs));
				v;
		};
	}

	public function finalize(e:TExpr, tl:Vector<{name:String, optional:Bool, type:T}>, tret:T, hasParams:Bool, mapType:T->T, p:Pos):TExpr {
		if (hadSideEffect) for (item in inlinedVars) if (mightBeAffected(item.expr)
			&& !core.TOther.ExtType.hasValueSemantics(item.expr.etype)) item.local.iForceTemp = true;
		// port: hxmc's struct values (Inline.copyArgumentHook): the temporary is a copy, not one the analyzer
		// ... fuses back into the argument as a compiler-generated variable (VGenerated, VAbstractThis)
		var copies = [];
		if (Inline.copyArgumentHook != null) for (item in inlinedVars) if (!item.local.iForceTemp
			&& Inline.copyArgumentHook(item.local.iSubst, item.expr, e)) {
			item.local.iForceTemp = true;
			copies.push(item.local.iSubst);
		}
		var substitutions = getSubstitutions(p);
		for (v in copies) v.vKind = VInlined;
		var vars = substitutions.vars;
		var subst = substitutions.subst;
		function inlineParams(inCall:Bool, inAssignment:Bool, e:TExpr):TExpr return switch e.eexpr {
			case TLocal(v):
				var sub = subst.get(v.vId);
				if (sub == null) e; else switch sub.kind {
					case VIInline: switch sub.expr.eexpr {
							// If we inline a function expression, we have to duplicate its locals.
							case TFunction(_): duplicateTvars(eIdentity, sub.expr);
							case TCast(e1, null) if (inAssignment): e1;
							case _: sub.expr;
						}
					// We allow inlining function expressions into call-places. However, we have to substitute
					// their locals to avoid duplicate declarations.
					case VIInlineIfCalled if (inCall): duplicateTvars(eIdentity, sub.expr);
					case _: e;
				}
			/*
				This case is a hack for https://github.com/HaxeFoundation/haxe/issues/9355
				on top of a hack for https://github.com/HaxeFoundation/haxe/issues/2401
			*/
			case TCall(e1 = {eexpr: TField(_, FStatic({clPath: {pack: [], name: "Std"}}, {cfName: "string"}))}, [e2]):
				var mapped = inlineParams(true, false, e2);
				if (!fastEq(follow(e2.etype), follow(mapped.etype))) mapped = withExpr(e2, TCast(mapped, null));
				withExpr(e, TCall(e1, vector(mapped)));
			case TCall(e1, el):
				var e1 = inlineParams(true, false, e1);
				withExpr(e, TCall(e1, el.map(e -> inlineParams(false, false, e))));
			case TBinop(op = OpAssign | OpAssignOp(_), e1, e2):
				var e1 = inlineParams(false, true, e1);
				withExpr(e, TBinop(op, e1, inlineParams(false, false, e2)));
			case TUnop(op = Increment | Decrement, flag, e1): withExpr(e, TUnop(op, flag, inlineParams(false, true, e1)));
			case _: mapExpr(e -> inlineParams(false, false, e), e);
		};
		if (subst.iterator().hasNext()) e = inlineParams(false, false, e);
		var md = scom.curclass.clModule.mExtra.mDisplay;
		var endPos:Pos = core.ds.Record.copy(p);
		endPos.pmax = p.pmin + cf.cfName.length;
		inlineCallsMutex.acquire();
		md.mInlineCalls.push({definitionPos: cf.cfNamePos, callPos: endPos});
		inlineCallsMutex.release();
		inline function wrap(e:TExpr):TExpr {
			// we can't mute the type of the expression because it is not correct to do so
			var etype = hasParams ? mapType(e.etype) : e.etype;
			// if the expression is "untyped" and we don't want to unify it accidentally !
			try {
				switch follow(e.etype) {
					case TMono(_) | TInst({clKind: KTypeParameter(_)}, _):
						switch follow(tret) {
							case TAbstract({aPath: {pack: [], name: "Void"}}, _):
							case _: throw new core.TUnification.Unify_error([]);
						}
					case _:
						var uctx = defaultUnificationContext();
						uctx.equalityKind = EqStrict;
						uctx.nullFollowMode = scom.platformConfig.pfStatic ? NeverFollow : AlwaysFollow;
						typeEqCustom(uctx, etype, tret);
				}
				return e;
			} catch (_:core.TUnification.Unify_error) return mk(TCast(e, null), tret, e.epos);
		}
		if (vars.length == 0 && !hasReturnValue) e = switch e.eexpr {
			case TBlock(_): {eexpr: e.eexpr, etype: tret, epos: e.epos};
			case _: mk(TBlock(vector(e)), tret, e.epos);
		};
		else if (vars.length == 0) e = switch e.eexpr {
			case TBlock([inner]): wrap(inner);
			case _: wrap(e);
		};
		else {
			var el = [];
			for (v in vars) el.push(mk(TVar(v.variable, v.expr), scom.basic.tvoid, e.epos));
			for (item in inlinedVars) {
				var l = item.local;
				if (l.iDefaultValue != null && l.iRead > 0) {
					var de = l.iDefaultValue;
					el.push(setDefault(scom.basic, l.iSubst, duplicateTvars(eIdentity, de), de.epos));
				}
			}
			switch e.eexpr {
				case TBlock(body):
					for (x in body) el.push(x);
				case _:
					el.push(e);
			}
			e = mk(TBlock(Vector.fromArrayCopy(el)), tret, e.epos);
		}
		e = Inline.inlineMetadata(e, cf.cfMeta);
		if (hasParams) {
			var mt = mapType(cf.cfType);
			inline function unifyFunc():Void context.Typecore.unifyRaise(mt, TFun({args: tl, ret: tret}), p);
			switch follow(ethis.etype) {
				case TAnon(a):
					switch a.aStatus {
						case ClassStatics({clKind: KAbstractImpl(a)}) if (hasClassFieldFlag(cf,
							CfImpl)): if (!hasClassFieldFlag(cf, CfAbstractConstructor)) {
								// the first argument must unify with a_this for abstract implementation functions
								if (tl.length == 0) throw "Failure: tl";
								var args = VectorTools.withFirst(tl, {name: "", optional: false, type: mapType(a.aThis)});
								context.Typecore.unifyRaise(mt, TFun({args: args, ret: tret}), p);
							}
						case _: unifyFunc();
					}
				case _:
					unifyFunc();
			}
		}
		var mappedVars = new haxe.ds.IntMap<Bool>();
		var mapExpression:T->T->TExpr;
		var mapExprTypeLocal:(T->T) -> TExpr -> TExpr = null;
		inline function mapVar(mapType:T->T, v:TVar):TVar {
			if (!mappedVars.exists(v.vId)) {
				mappedVars.set(v.vId, true);
				if (!read(v).iOutside) {
					v.vType = mapType(v.vType);
					if (v.vExtra != null && v.vExtra.vExpr != null) v.vExtra = varExtra(v.vExtra.vParams,
						mapExprTypeLocal(mapType, v.vExtra.vExpr));
				}
			}
			return v;
		}
		mapExprTypeLocal = function(mapType:T->T, e:TExpr):TExpr {
			/*
				No need to change typing of arguments of inlined call
				because they were already properly typed prior to inlining.
			*/
			var mapper = params.has(e) ? t->t : mapType;
			var e = Texpr.mapExprType(e -> mapExprTypeLocal(mapper, e), mapper, v -> mapVar(mapper, v), e);
			return typing.OverloadResolution.maybeReapplyOverloadCall(e);
		};
		e = mapExprTypeLocal(mapType, e);
		function dropUnused(e:TExpr):TExpr return switch e.eexpr {
			case TVar(v, {eexpr: TConst(_)}):
				var data = locals.get(v.vId);
				if (data != null && data.iRead == 0 && data.iCalled == 0 && !data.iWrite) mk(TBlock(vector()), e.etype,
					e.epos); else mapExpr(dropUnused, e);
			case _: mapExpr(dropUnused, e);
		};
		return dropUnused(e);
	}
}
