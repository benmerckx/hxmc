package hxmc.esm;

import context.Common.CommonContext;
import core.Ast;
import core.Ast.Binop;
import core.Ast.UnopFlag;
import core.TType.BasicTypes;
import core.Define.DefineContext;
import core.Globals;
import core.MetaList.StrictMeta;
import core.TType;
import core.TFunctions.*;
import core.Texpr;
import core.Texpr.Builder;
import core.ds.VectorTools;
import haxe.crypto.Md5;
import haxe.ds.Vector;

// M2: lower @:esm.hot.cell / scope; assign closure IDs and env-lowering (esm.md §4–§6).
class HotLowering {
	static var cellClass:TClass;
	static var scopeClass:TClass;
	static var cellIdByVar = new Map<String, TExpr>();

	// After typing, before RenameVars: keyed call sites, closure IDs, pending cell marks.
	public static function runEarly(com:CommonContext):Void {
		if (!core.Define.rawDefined(com.defines, "esm.hot")) return;
		visitAll(com, visitFieldEarly);
	}

	// After filters / before ESM codegen: lower cells/scopes.
	public static function runLate(com:CommonContext):Void {
		runLateOn(com.defines, com.basic, com.types);
	}

	// Per swappable field at ESM emit.
	public static function prepareFieldCells(g:generators.Gctx, c:TClass, f:TClassField):Void {
		if (f.cfExpr == null) return;
		var uid = HotIds.unitId(c, f.cfName);
		var keyed = EsmHotMeta.isKeyed(f.cfMeta);
		f.cfExpr = mapCellMark(uid, keyed, hotIdVar(f), f.cfExpr);
		visitFieldLate(g.basic, c, f);
	}

	static function mapCellMark(uid:String, keyed:Bool, hotId:Null<TVar>, expr:TExpr):TExpr {
		var root = expr;
		return HotExprMap.mapTransform(function(cur:TExpr):TExpr {
			switch cur.eexpr {
				case TMeta(m, {eexpr: TVar(v, eo)}) if (EsmHotMeta.isCellMetaEntry(m) && eo != null):
					return markCellPending(v, eo, cur);
				case TVar(v, eo) if (EsmHotMeta.isCell(v.vMeta) && eo != null):
					return markCellPending(v, eo, cur);
				case TVar(v, eo) if (eo != null && isM2CellInit(v, eo, root)):
					return markCellPending(v, eo, cur);
				case TVar(v, eo) if (keyed && eo != null && zeroLiteral(eo)):
					return markCellPending(v, eo, cur);
				default:
					return cur;
			}
		}, expr);
	}

	static function isM2CellInit(v:TVar, eo:TExpr, root:TExpr):Bool {
		if (!zeroLiteral(eo)) return false;
		var inc = false;
		HotExprMap.mapTransform(function(cur:TExpr):TExpr {
			if (inc) return cur;
			switch cur.eexpr {
				case TUnop(Increment, _, {eexpr: TLocal(l)}) if (l.vName == v.vName):
					inc = true;
				default:
			}
			return cur;
		}, root);
		return inc;
	}

	static function zeroLiteral(e:TExpr):Bool return switch e.eexpr {
		case TConst(TInt(i)) if (i == 0): true;
		case TConst(TNull): true;
		default: false;
	}

	static function runLateOn(defines:DefineContext, basic:BasicTypes, types:Array<ModuleType>):Void {
		if (!core.Define.rawDefined(defines, "esm.hot")) return;
		if (!hasCellLowerWorkTypes(types)) return;
		cellClass = resolveClassTypes(types, ["esm", "hot", "Cell"]);
		scopeClass = resolveClassTypes(types, ["esm", "hot", "Scope"]);
		visitAllTypes(types, basic, visitFieldLate);
	}

	static function hasCellLowerWorkTypes(types:Array<ModuleType>):Bool {
		var pending = false;
		function scan(e:TExpr):Void {
			if (pending) return;
			// Texpr.iter does not invoke f on TMeta nodes; cells are wrapped in TMeta.
			HotExprMap.mapTransform(function(cur:TExpr):TExpr {
				if (!pending) switch cur.eexpr {
					case TMeta(m, _) if (EsmHotMeta.isCellPending(m) || EsmHotMeta.isCellMetaEntry(m)):
						pending = true;
					case TVar(v, _) if (EsmHotMeta.isCell(v.vMeta)):
						pending = true;
					default:
				}
				return cur;
			}, e);
		}
		for (t in types) switch t {
			case TClassDecl(c) if (!hasClassFlag(c, CExtern)):
				for (cf in c.clFields) if (cf.cfExpr != null) scan(cf.cfExpr);
				for (cf in c.clStatics) if (cf.cfExpr != null) scan(cf.cfExpr);
				var ctor = c.clConstructor;
				if (ctor != null && ctor.cfExpr != null) scan(ctor.cfExpr);
			default:
		}
		return pending;
	}

	static function visitAll(com:CommonContext, visit:(CommonContext, TClass, TClassField) -> Void):Void {
		for (t in com.types) switch t {
			case TClassDecl(c) if (!hasClassFlag(c, CExtern)):
				for (cf in c.clFields) visit(com, c, cf);
				for (cf in c.clStatics) visit(com, c, cf);
				var ctor = c.clConstructor;
				if (ctor != null) visit(com, c, ctor);
			case _:
		}
	}

	static function visitAllTypes(types:Array<ModuleType>, basic:BasicTypes,
			visit:(BasicTypes, TClass, TClassField) -> Void):Void {
		for (t in types) switch t {
			case TClassDecl(c) if (!hasClassFlag(c, CExtern)):
				for (cf in c.clFields) visit(basic, c, cf);
				for (cf in c.clStatics) visit(basic, c, cf);
				var ctor = c.clConstructor;
				if (ctor != null) visit(basic, c, ctor);
			case _:
		}
	}

	static function resolveClassTypes(types:Array<ModuleType>, path:Array<String>):TClass {
		for (mt in types) switch mt {
			case TClassDecl(c) if (typePath(c) == path.join(".")):
				return c;
			default:
		}
		throw 'hxmc: missing esm type ${path.join(".")} (add -cp hxmc/std/esm)';
	}

	static function typePath(c:TClass):String return c.clPath.pack.concat([c.clPath.name]).join(".");

	static function visitFieldEarly(com:CommonContext, c:TClass, cf:TClassField):Void {
		if (cf.cfExpr == null) return;
		var uid = HotIds.unitId(c, cf.cfName);
		var keyed = EsmHotMeta.isKeyed(cf.cfMeta);
		var st = {lambdaN: 0, skipRootFn: false, fieldLocals: (null : Null<Map<String, Bool>>)};
		switch cf.cfExpr.eexpr {
			case TFunction(f):
				st.fieldLocals = collectShallowVarNames(f);
				f.tfExpr = mapUnitEarly(com, uid, keyed, hotIdVar(cf), st, f.tfExpr);
			default:
				cf.cfExpr = mapUnitEarly(com, uid, keyed, hotIdVar(cf), st, cf.cfExpr);
		}
	}

	static function collectShallowVarNames(f:TFunc):Map<String, Bool> {
		var m = new Map<String, Bool>();
		function scan(e:TExpr, inNested:Bool):Void switch e.eexpr {
			case TFunction(_): return;
			case TVar(v, _): m.set(v.vName, true);
			case _: Texpr.iter(x -> scan(x, inNested), e);
		}
		scan(f.tfExpr, false);
		return m;
	}

	static function visitFieldLate(basic:BasicTypes, c:TClass, cf:TClassField):Void {
		if (cf.cfExpr == null) return;
		cellIdByVar = new Map();
		var uid = HotIds.unitId(c, cf.cfName);
		var keyed = EsmHotMeta.isKeyed(cf.cfMeta);
		var e = mapUnitLate(basic, uid, keyed, hotIdVar(cf), cf.cfExpr);
		e = rewriteCellIncrements(basic, e);
		if (EsmHotMeta.isScope(cf.cfMeta)) e = wrapScope(basic, uid, e, cf.cfExpr.epos);
		cf.cfExpr = e;
	}

	static function hotIdVar(cf:TClassField):Null<TVar> {
		return switch cf.cfExpr.eexpr {
			case TFunction(f):
				for (a in f.tfArgs)
					if (a.variable.vName == "__hotId") return a.variable;
				return null;
			default:
				null;
		}
	}

	static function mapUnitEarly(com:CommonContext, uid:String, keyed:Bool, hotId:Null<TVar>,
			st:{lambdaN:Int, skipRootFn:Bool, fieldLocals:Null<Map<String, Bool>>}, expr:TExpr):TExpr {
		return HotExprMap.mapTransform(function(cur:TExpr):TExpr {
			switch cur.eexpr {
				case TMeta(m, {eexpr: TVar(v, eo)}) if (EsmHotMeta.isCellMetaEntry(m) && eo != null):
					return markCellPending(v, eo, cur);
				case TVar(v, eo) if (EsmHotMeta.isCell(v.vMeta) && eo != null):
					return markCellPending(v, eo, cur);
				case TFunction(f):
					if (st.skipRootFn) {
						st.skipRootFn = false;
						return cur;
					}
					// Resident-server rebuilds re-run early lowering; skip lambdas already env-wrapped.
					if (f.tfArgs.length > 0 && f.tfArgs[0].variable.vName == "$env") return cur;
					st.lambdaN++;
					var lid = uid + "/λ" + st.lambdaN;
					return wrapClosure(com, lid, f, cur, st.fieldLocals);
				default:
					return cur;
			}
		}, expr);
	}

	static function mapUnitLate(basic:BasicTypes, uid:String, keyed:Bool, hotId:Null<TVar>, expr:TExpr):TExpr {
		return HotExprMap.mapTransform(function(cur:TExpr):TExpr {
			switch cur.eexpr {
				case TMeta(m, {eexpr: TVar(v, eo)}) if (EsmHotMeta.isCellPending(m) && eo != null):
					return lowerCell(basic, uid, keyed, hotId, v, eo, cur);
				case TMeta(m, {eexpr: TVar(v, eo)}) if (EsmHotMeta.isCellMetaEntry(m) && eo != null):
					return lowerCell(basic, uid, keyed, hotId, v, eo, cur);
				case TVar(v, eo) if (EsmHotMeta.isCell(v.vMeta) && eo != null):
					return lowerCell(basic, uid, keyed, hotId, v, eo, cur);
				default:
					return cur;
			}
		}, expr);
	}

	static function markCellPending(v:TVar, eo:TExpr, cur:TExpr):TExpr {
		var inner:TExpr = {eexpr: TVar(v, eo), etype: cur.etype, epos: cur.epos};
		var meta:MetadataEntry = {meta: StrictMeta.Custom(EsmHotMeta.CELL_PENDING), exprs: vector(), pos: cur.epos};
		return {eexpr: TMeta(meta, inner), etype: cur.etype, epos: cur.epos};
	}

	static function wrapScope(basic:BasicTypes, uid:String, e:TExpr, pos:Pos):TExpr {
		var sid = uid + "#scope";
		var enter = Builder.resolveAndMakeStaticCall(scopeClass, "enter", VectorTools.vector(Builder.makeString(basic, sid, pos)), pos);
		var exit = Builder.resolveAndMakeStaticCall(scopeClass, "exit", VectorTools.vector(), pos);
		return {eexpr: TBlock(VectorTools.vector(enter, e, exit)), etype: e.etype, epos: pos};
	}

	static function wrapClosure(com:CommonContext, id:String, f:TFunc, orig:TExpr, ?fieldLocals:Null<Map<String, Bool>>):TExpr {
		var caps = captureNames(f);
		var paramNames = new Map<String, Bool>();
		for (a in f.tfArgs) paramNames.set(a.variable.vName, true);
		caps = caps.filter(n -> !paramNames.exists(n) && !isParamName(f, n)
			&& (fieldLocals == null || !fieldLocals.exists(n)));
		var capHash = caps.length == 0 ? "" : Md5.encode(caps.join(","));
		var f2 = rewriteCaptures(com, f, caps);
		HotIds.units.set(id, {id: id, kind: "closure", codeHash: HotIds.bodyHash(f2.tfExpr), policy: "reset", capHash: capHash});
		var metaExprs:Vector<Expr> = new Vector(2 + caps.length);
		metaExprs.set(0, {expr: EConst(String(id, SDoubleQuotes)), pos: orig.epos});
		metaExprs.set(1, {expr: EConst(String(capHash, SDoubleQuotes)), pos: orig.epos});
		for (i in 0...caps.length)
			metaExprs.set(2 + i, {expr: EConst(String(caps[i], SDoubleQuotes)), pos: orig.epos});
		var meta:MetadataEntry = {
			meta: StrictMeta.Custom(EsmHotMeta.CLOSURE_META),
			exprs: metaExprs,
			pos: orig.epos,
		};
		var inner:TExpr = {eexpr: TFunction(f2), etype: orig.etype, epos: orig.epos};
		return {eexpr: TMeta(meta, inner), etype: orig.etype, epos: orig.epos};
	}

	static function isParamVar(f:TFunc, v:TVar):Bool {
		for (a in f.tfArgs)
			if (a.variable == v || a.variable.vName == v.vName) return true;
		return false;
	}

	static function isParamName(f:TFunc, name:String):Bool {
		for (a in f.tfArgs)
			if (a.variable.vName == name) return true;
		return false;
	}

	static function captureNames(f:TFunc):Array<String> {
		var declared = new Map<Int, Bool>();
		var declaredNames = new Map<String, Bool>();
		var used = new Map<String, Bool>();
		for (a in f.tfArgs) {
			declared.set(Std.int(a.variable.vId), true);
			declaredNames.set(a.variable.vName, true);
		}
		function declLocals(e:TExpr):Void switch e.eexpr {
			case TVar(v, _):
				declared.set(Std.int(v.vId), true);
				declaredNames.set(v.vName, true);
			case _: Texpr.iter(declLocals, e);
		}
		declLocals(f.tfExpr);
		function useLocalsInScope(e:TExpr, ids:Map<Int, Bool>, names:Map<String, Bool>):Void switch e.eexpr {
			case TFunction(inner):
				var ids2 = new Map<Int, Bool>();
				var names2 = new Map<String, Bool>();
				for (k in ids.keys()) ids2.set(k, ids.get(k));
				for (k in names.keys()) names2.set(k, names.get(k));
				for (a in inner.tfArgs) {
					ids2.set(Std.int(a.variable.vId), true);
					names2.set(a.variable.vName, true);
				}
				function declIn(expr:TExpr):Void switch expr.eexpr {
					case TVar(v, _):
						ids2.set(Std.int(v.vId), true);
						names2.set(v.vName, true);
					case _: Texpr.iter(declIn, expr);
				}
				declIn(inner.tfExpr);
				useLocalsInScope(inner.tfExpr, ids2, names2);
			case TLocal(v) if (!ids.exists(Std.int(v.vId)) && !names.exists(v.vName)):
				if (!isParamVar(f, v)) used.set(v.vName, true);
			case _: Texpr.iter(x -> useLocalsInScope(x, ids, names), e);
		}
		useLocalsInScope(f.tfExpr, declared, declaredNames);
		var paramNames = new Map<String, Bool>();
		for (a in f.tfArgs) paramNames.set(a.variable.vName, true);
		return [for (k in used.keys()) if (!paramNames.exists(k)) k];
	}

	static function rewriteCaptures(com:CommonContext, f:TFunc, caps:Array<String>):TFunc {
		if (caps.length == 0) return f;
		if (f.tfArgs.length > 0 && f.tfArgs[0].variable.vName == "$env") return f;
		var capSet = new Map<String, Bool>();
		for (n in caps) capSet.set(n, true);
		var env = allocVar(VGenerated, "$env", com.basic.tany, f.tfExpr.epos);
		var args = VectorTools.cons({variable: env, defaultValue: null}, f.tfArgs);
		var body = Texpr.mapExpr(function(e:TExpr):TExpr {
			return switch e.eexpr {
				case TLocal(v) if (capSet.exists(v.vName)):
					{
						eexpr: TField(Builder.makeLocal(env, e.epos), FDynamic(v.vName)),
						etype: e.etype,
						epos: e.epos,
					};
				default:
					e;
			};
		}, f.tfExpr);
		return {tfArgs: args, tfType: f.tfType, tfExpr: body};
	}

	static function lowerCell(basic:BasicTypes, uid:String, keyed:Bool, hotId:Null<TVar>, v:TVar, eo:TExpr, cur:TExpr):TExpr {
		var idExpr = cellIdExpr(basic, uid, keyed, hotId, v.vName, v.vPos);
		cellIdByVar.set(v.vName, idExpr);
		var initHash = HotIds.bodyHash(eo);
		var init = mkThunk(basic, eo);
		var call = cellRuntimeCall(basic, idExpr, initHash, init, v.vPos);
		return {eexpr: TVar(v, call), etype: cur.etype, epos: cur.epos};
	}

	static function cellRuntimeCall(basic:BasicTypes, idExpr:TExpr, initHash:String, init:TExpr, pos:Pos):TExpr {
		var h:TExpr = {eexpr: TIdent("$h"), etype: basic.tany, epos: pos};
		var callee:TExpr = {eexpr: TField(h, FDynamic("cell")), etype: basic.tany, epos: pos};
		var args = VectorTools.vector(idExpr, Builder.makeString(basic, initHash, pos), init);
		return {eexpr: TCall(callee, args), etype: basic.tany, epos: pos};
	}

	static function cellIdExpr(basic:BasicTypes, uid:String, keyed:Bool, hotId:Null<TVar>, name:String, pos:Pos):TExpr {
		var tail = "#cell." + name;
		if (keyed && hotId != null) {
			var base:TExpr = {
				eexpr: TBinop(OpNullCoal, Builder.makeLocal(hotId, pos), Builder.makeString(basic, uid, pos)),
				etype: basic.tstring,
				epos: pos,
			};
			return {
				eexpr: TBinop(OpAdd, base, Builder.makeString(basic, tail, pos)),
				etype: basic.tstring,
				epos: pos,
			};
		}
		return Builder.makeString(basic, uid + tail, pos);
	}

	static function rewriteCellIncrements(basic:BasicTypes, expr:TExpr):TExpr {
		var any = false;
		for (_ in cellIdByVar.keys()) {
			any = true;
			break;
		}
		if (!any) return expr;
		return HotExprMap.mapTransform(function(cur:TExpr):TExpr {
			switch cur.eexpr {
				case TUnop(Increment, _, {eexpr: TLocal(v)}) if (cellIdByVar.exists(v.vName)):
					return {eexpr: TUnop(Increment, Prefix, cellSlotField(basic, cellIdByVar.get(v.vName), "v", cur.epos)), etype: cur.etype, epos: cur.epos};
				default:
					return cur;
			}
		}, expr);
	}

	static function cellSlotField(basic:BasicTypes, idExpr:TExpr, field:String, pos:Pos):TExpr {
		var h:TExpr = {eexpr: TIdent("$h"), etype: basic.tany, epos: pos};
		var cells:TExpr = {eexpr: TField(h, FDynamic("cells")), etype: basic.tany, epos: pos};
		var slot:TExpr = {eexpr: TArray(cells, idExpr), etype: basic.tany, epos: pos};
		return {eexpr: TField(slot, FDynamic(field)), etype: basic.tany, epos: pos};
	}

	static function mkThunk(basic:BasicTypes, e:TExpr):TExpr {
		var ret:TExpr = {eexpr: TReturn(e), etype: basic.tvoid, epos: e.epos};
		var f:TFunc = {
			tfArgs: VectorTools.vector(),
			tfType: basic.tvoid,
			tfExpr: {eexpr: TBlock(VectorTools.vector(ret)), etype: basic.tvoid, epos: e.epos},
		};
		var ft = tfun(new Vector(0), e.etype);
		return {eexpr: TFunction(f), etype: ft, epos: e.epos};
	}
}