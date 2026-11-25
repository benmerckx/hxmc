/*
	Stale reference checker.

	Every reference from a module of the compilation to a type or a field must
	point to the object that its module currently holds: a reference to an
	object of an older version of a module is stale. Enabled with
	`-D incremental-check-refs`; each stale reference is reported as an error.
*/

package compiler;

import core.Globals;
import core.Globals.Pos;
import core.TType;
import core.TFunctions.*;
import context.Common;
import core.ds.NotFound;

class RefCheck {
	static function checkImpl(com:CommonContext):Void {
		// port: `Hashtbl` of (what, p): only looked up
		var reported = new Map<String, Bool>();
		var count = 0;
		function report(what:String, p:Pos) {
			var key = what + "\x00" + p.pfile + "\x00" + p.pmin + "\x00" + p.pmax;
			if (!reported.exists(key)) {
				reported.set(key, true);
				count++;
				if (count <= 20) com.errorExt(core.Error.makeError(Custom("Stale reference: " + what), p));
			}
		}
		function currentModule(m:ModuleDef):Null<ModuleDef> {
			return try com.moduleLut.find(m.mPath) catch (_:NotFound) null;
		}
		/* A module type is valid if its module is the current module of its path
			and it is one of that module's types (or its implementation class). */
		function owns(m:ModuleDef, mt:ModuleType):Bool {
			for (mt2 in m.mTypes) {
				var same = switch [mt2, mt] {
					case [TClassDecl(c1), TClassDecl(c2)]: c1 == c2;
					case [TEnumDecl(e1), TEnumDecl(e2)]: e1 == e2;
					case [TTypeDecl(t1), TTypeDecl(t2)]: t1 == t2;
					case [TAbstractDecl(a1), TAbstractDecl(a2)]: a1 == a2;
					case [TAbstractDecl(a), TClassDecl(c)]: a.aImpl != null && c == a.aImpl;
					case _: false;
				}
				if (same) return true;
			}
			return switch [m.mStatics, mt] {
				case [c, TClassDecl(c2)] if (c != null): c == c2;
				case _: false;
			}
		}
		function checkModuleType(mt:ModuleType, p:Pos) {
			var infos = tInfos(mt);
			var m = infos.mtModule;
			switch mt {
				case TClassDecl({clKind: KTypeParameter(ttp)}) if (m != nullModule):
					/* a type parameter belongs to the module of its host */
					switch currentModule(m) {
						case m2 if (m2 != null && m2 != m):
							report('type parameter ${ttp.ttpName} refers to an older version of module ${Globals.sTypePath(m.mPath)}', p);
						case _:
					}
				case TClassDecl({clKind: KTypeParameter(_) | KGenericInstance(_) | KExpr(_)}):
				case _ if (m == nullModule):
				case TTypeDecl({tPath: {name: name}}) if (name.indexOf("<") >= 0):
					/* Synthetic typedefs such as `Class<T>` and `Enum<T>`, created for
						static accesses, are not types of their module. */
				case _:
					switch currentModule(m) {
						case null:
						case m2 if (m2 != m):
							report('${Globals.sTypePath(infos.mtPath)} refers to an older version of module ${Globals.sTypePath(m.mPath)}', p);
						case m2:
							if (!owns(m2, mt))
								report('${Globals.sTypePath(infos.mtPath)} is not a type of module ${Globals.sTypePath(m.mPath)}', p);
					}
			}
		}
		function checkClassField(c:TClass, cf:TClassField, p:Pos) {
			function inList(l:Iterable<TClassField>):Bool {
				for (cf2 in l) if (cf2 == cf || inList(cf2.cfOverloads)) return true;
				return false;
			}
			if (!(inList(c.clFields) || inList(c.clStatics) || (switch c.clConstructor {
				case null: false;
				case cf2: cf2 == cf || inList(cf2.cfOverloads);
			}) || c.clKind.match(KTypeParameter(_) | KGenericInstance(_) | KExpr(_))))
				report('field ${cf.cfName} is not a field of ${Globals.sTypePath(c.clPath)}', p);
		}
		var visitedAnons = new haxe.ds.ObjectMap<TAnon, Bool>();
		function checkT(p:Pos, t:T) {
			switch t {
				case TInst(c, tl):
					checkModuleType(TClassDecl(c), p);
					for (t in tl) checkT(p, t);
				case TEnum(e, tl):
					checkModuleType(TEnumDecl(e), p);
					for (t in tl) checkT(p, t);
				case TType(td, tl):
					checkModuleType(TTypeDecl(td), p);
					for (t in tl) checkT(p, t);
				case TAbstract(a, tl):
					checkModuleType(TAbstractDecl(a), p);
					for (t in tl) checkT(p, t);
				case TFun(s):
					for (a in s.args) checkT(p, a.type);
					checkT(p, s.ret);
				case TAnon(an):
					if (!visitedAnons.exists(an)) {
						visitedAnons.set(an, true);
						for (cf in an.aFields) checkT(p, cf.cfType);
					}
				case TMono(r):
					if (r.tmType != null) checkT(p, r.tmType);
				case TDynamic(t) if (t != null):
					checkT(p, t);
				case TDynamic(_) | TLazy(_):
			}
		}
		function checkExpr(e:TExpr) {
			switch e.eexpr {
				case TTypeExpr(mt):
					checkModuleType(mt, e.epos);
				case TNew(c, _, _):
					checkModuleType(TClassDecl(c), e.epos);
				case TField(_, FInstance(c, _, cf) | FStatic(c, cf)):
					checkModuleType(TClassDecl(c), e.epos);
					checkClassField(c, cf, e.epos);
				case TField(_, FClosure(cl, cf)) if (cl != null):
					checkModuleType(TClassDecl(cl.cls), e.epos);
					checkClassField(cl.cls, cf, e.epos);
				case TField({etype: TType(td, _)}, FAnon(cf)) if (td.tParams.length == 0):
					/* a field of the structure a typedef declares */
					function declared(t:T):T {
						return switch t {
							case TMono({tmType: t}) if (t != null): declared(t);
							case TLazy(r): switch r.value {
									case LAvailable(t): declared(t);
									case _: t;
								}
							case _: t;
						}
					}
					/* the typedef of the current version of its module */
					var td = switch currentModule(td.tModule) {
						case null: td;
						case m2:
							var found = null;
							for (mt in m2.mTypes) switch mt {
								case TTypeDecl(td2) if (td2.tPath.hashKey() == td.tPath.hashKey()):
									found = td2;
									break;
								case _:
							}
							found == null ? td : found;
					}
					switch declared(td.tType) {
						case TAnon(an) if (an.aFields.exists(cf.cfName) && an.aFields.find(cf.cfName) != cf):
							report('field ${cf.cfName} is not a field of the structure of ${Globals.sTypePath(td.tPath)}', e.epos);
						case _:
					}
				case TField(_, FEnum(en, ef)):
					checkModuleType(TEnumDecl(en), e.epos);
					if (!(en.eConstrs.get(ef.efName) == ef))
						report('constructor ${ef.efName} is not a constructor of ${Globals.sTypePath(en.ePath)}', e.epos);
				case _:
			}
			core.Texpr.iter(checkExpr, e);
		}
		function checkField(cf:TClassField) {
			checkT(cf.cfPos, cf.cfType);
			if (cf.cfExpr != null) checkExpr(cf.cfExpr);
			for (cf in cf.cfOverloads) checkT(cf.cfPos, cf.cfType);
		}
		for (m in com.modules) for (mt in m.mTypes) switch mt {
			case TClassDecl(c):
				if (c.clSuper != null) {
					checkModuleType(TClassDecl(c.clSuper.cls), c.clPos);
					for (t in c.clSuper.params) checkT(c.clPos, t);
				}
				for (ci in c.clImplements) {
					checkModuleType(TClassDecl(ci.cls), c.clPos);
					for (t in ci.params) checkT(c.clPos, t);
				}
				for (cf in c.clFields) checkField(cf);
				for (cf in c.clStatics) checkField(cf);
				if (c.clConstructor != null) checkField(c.clConstructor);
				var init = core.TOther.TClassTools.getClInit(c);
				if (init != null) checkExpr(init);
			case TEnumDecl(en):
				// port: PMap.iter, in key order
				for (ef in en.eConstrs.byName) checkT(ef.efPos, ef.efType);
			case TTypeDecl(td):
				checkT(td.tPos, td.tType);
			case TAbstractDecl(a):
				checkT(a.aPos, a.aThis);
		}
		if (count > 20) com.errorExt(core.Error.makeError(Custom('Stale reference: ${count - 20} more'), Globals.nullPos));
	}

	public static function check(com:CommonContext):Void {
		if (Common.defined(com, core.Define.IncrementalCheckRefs))
			core.Timer.time(com.timerCtx, ["incremental", "check refs"], function(com) {
				checkImpl(com);
				return null;
			}, com);
	}
}
