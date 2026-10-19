package context.display;

import core.Globals;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.Json.JsonValue;
import core.Json.JsonField;
import core.TFunctions.*;
import core.ds.OcamlHash;
import core.ds.OcamlHashtbl;
import context.Common;
import core.MetaList.StrictMeta as MetaTag;
import core.Meta;
import core.DisplayTypes;
import core.TType;

enum Relation {
	Implemented;
	Extended;
	Overridden;
	Referenced;
}

enum StatisticsFilter {
	SFNone;
	SFPos(p:Pos);
	SFFile(s:String);
}

typedef StatisticsResult = {
	symbols:OcamlHashtbl<Pos, Symbol>,
	relations:OcamlHashtbl<Pos, Array<{r:Relation, p:Pos}>>
};

class Statistics {
	public static inline function posEq(a:Pos, b:Pos):Bool return a.pfile == b.pfile && a.pmin == b.pmin && a.pmax == b.pmax;

	public static function posTable<V>():OcamlHashtbl<Pos, V> return new OcamlHashtbl(OcamlHash.hashPos, posEq, 0);

	public static function collectStatistics(com:CommonContext, posFilters:Array<StatisticsFilter>, withExpressions:Bool):StatisticsResult {
		var relations:OcamlHashtbl<Pos, Array<{r:Relation, p:Pos}>> = posTable();
		var symbols:OcamlHashtbl<Pos, Symbol> = posTable();
		var handledModules = new haxe.ds.StringMap<Bool>();
		var paths = new haxe.ds.StringMap<String>();
		function pathKey(path:String):String {
			var k = paths.get(path);
			if (k != null) return k;
			var unique = com.partScope.fileKeys.get(path);
			paths.set(path, unique);
			return unique;
		}
		function checkPos(p:Pos):Bool {
			return core.ds.ArrayTools.exists(posFilters, function(pfilter) return switch pfilter {
				case SFNone: !posEq(p, Globals.nullPos);
				case SFPos(p1): p1.pmin == p.pmin && p1.pmax == p.pmax && pathKey(p1.pfile) == pathKey(p.pfile);
				case SFFile(s): pathKey(p.pfile) == pathKey(s);
			});
		}
		function relEq(a:{r:Relation, p:Pos}, b:{r:Relation, p:Pos}):Bool return a.r == b.r && posEq(a.p, b.p);
		function addRelation(p:Pos, r:{r:Relation, p:Pos}):Void {
			if (checkPos(p)) {
				var l = relations.findOpt(p);
				if (l != null) {
					if (!core.ds.ArrayTools.exists(l, x -> relEq(x, r))) relations.replace(p, [r].concat(l));
				} else relations.add(p, [r]);
			}
		}
		function declare(kind:Symbol, p:Pos):Void {
			if (checkPos(p)) {
				if (!relations.mem(p)) relations.add(p, []);
				symbols.replace(p, kind);
			}
		}
		function checkOverride(c:TClass, cf:TClassField):Void {
			var c = c;
			while (c.clSuper != null) {
				c = c.clSuper.cls;
				var cf_ = c.clFields.get(cf.cfName);
				if (cf_ != null) addRelation(cf_.cfNamePos, {r: Overridden, p: cf.cfNamePos});
			}
		}
		function collectImplementations(c:TClass):Void {
			var memo = new haxe.ds.StringMap<Bool>();
			function loop(c1:TClass):Void {
				var key = Globals.sTypePath(c1.clPath);
				if (!memo.exists(key)) {
					memo.set(key, true);
					if (hasClassFlag(c1, CInterface)) addRelation(c.clNamePos, {r: Extended, p: c1.clNamePos})
					else {
						addRelation(c.clNamePos, {r: Implemented, p: c1.clNamePos});
						for (cf in c.clOrderedFields) {
							var cf_ = c1.clFields.get(cf.cfName);
							if (cf_ != null) addRelation(cf.cfNamePos, {r: Implemented, p: cf_.cfNamePos});
						}
					}
					for (c2 in c1.clDescendants) loop(c2);
				}
			}
			for (c2 in c.clDescendants) loop(c2);
		}
		function findRealConstructor(c:TClass):TClassField {
			// The pos comparison might be a bit weak, not sure...
			if (c.clConstructor != null
				&& !Meta.has(MetaTag.CompilerGenerated, c.clConstructor.cfMeta)
				&& !posEq(c.clPos, c.clConstructor.cfPos)) return c.clConstructor;
			if (c.clSuper != null) return findRealConstructor(c.clSuper.cls);
			throw core.ds.NotFound.raise();
		}
		function varDecl(v:TVar):Void declare(SKVariable(v), v.vPos);
		var relatedFields = new haxe.ds.StringMap<Array<TClassField>>();
		function fieldReference(co:Null<TClass>, cf:TClassField, p:Pos):Void {
			var p1 = Globals.patchStringPos(p, cf.cfName);
			addRelation(cf.cfNamePos, {r: Referenced, p: p1});
			// extend to related classes for instance fields
			if (checkPos(cf.cfNamePos)) if (co != null) {
				var c = co;
				var id = Globals.sTypePath(c.clPath) + "#" + cf.cfName;
				var cfl = relatedFields.get(id);
				if (cfl != null) {
					for (cf in cfl) addRelation(cf.cfNamePos, {r: Referenced, p: p1});
				} else {
					var cfl = [];
					function check(c:TClass):Void {
						var cf = c.clFields.get(cf.cfName);
						if (cf != null) {
							addRelation(cf.cfNamePos, {r: Referenced, p: p1});
							cfl.unshift(cf);
						}
					}
					// to children
					function loop(c:TClass):Void {
						for (c in c.clDescendants) {
							check(c);
							loop(c);
						}
					}
					loop(c);
					// to parents
					function loop2(c:TClass):Void {
						function f(r:{cls:TClass, params:TParams}):Void {
							check(r.cls);
							loop2(r.cls);
						}
						for (i in c.clImplements) f(i);
						if (c.clSuper != null) f(c.clSuper);
					}
					loop2(c);
					relatedFields.set(id, cfl);
				}
			}
		}
		function collectReferences(c:TClass, e:TExpr):Void {
			function loop(e:TExpr):Void {
				switch e.eexpr {
					case TField(e1, fa):
						// Check if the sub-expression is actually shorter than the whole one. This should
						// detect cases where it was automatically generated.
						if (e1.epos.pmin == e.epos.pmin && e1.epos.pmax != e.epos.pmax) loop(e1);
						switch fa {
							case FStatic(_, cf) | FClosure(null, cf):
								fieldReference(null, cf, e.epos);
							case FInstance(c, _, cf) | FClosure({cls: c}, cf):
								fieldReference(c, cf, e.epos);
							case FAnon(cf):
								declare(SKField(cf, null), cf.cfNamePos);
								fieldReference(null, cf, e.epos);
							case FEnum(_, ef):
								addRelation(ef.efNamePos, {r: Referenced, p: Globals.patchStringPos(e.epos, ef.efName)});
							case FDynamic(_):
						}
					case TTypeExpr(mt):
						var tinfos = tInfos(mt);
						addRelation(tinfos.mtNamePos, {r: Referenced, p: Globals.patchStringPos(e.epos, tinfos.mtPath.name)});
					case TNew(c, _, el):
						for (e in el) loop(e);
						try addRelation(findRealConstructor(c).cfNamePos, {r: Referenced, p: e.epos})
						catch (_:core.ds.NotFound) {}
					case TCall({eexpr: TConst(TSuper)}, el):
						for (e in el) loop(e);
						if (c.clSuper != null) {
							try addRelation(findRealConstructor(c.clSuper.cls).cfNamePos, {r: Referenced, p: e.epos})
							catch (_:core.ds.NotFound) {}
						}
					case TVar(v, eo):
						if (eo != null) loop(eo);
						varDecl(v);
					case TFunction(tf):
						for (a in tf.tfArgs) varDecl(a.variable);
						loop(tf.tfExpr);
					case TLocal(v) if (e.epos.pmax - e.epos.pmin == haxe.io.Bytes.ofString(v.vName).length):
						addRelation(v.vPos, {r: Referenced, p: e.epos});
					case _:
						core.Texpr.iter(loop, e);
				}
			}
			loop(e);
		}
		function checkModule(m:ModuleDef):Void {
			var key = Globals.sTypePath(m.mPath);
			if (!handledModules.exists(key)) {
				handledModules.set(key, true);
				// port: both in push order (ModuleDefDisplay)
				var calls = m.mExtra.mDisplay.mInlineCalls, i = calls.length;
				while (i > 0) {
					var ic = calls[--i];
					addRelation(ic.definitionPos, {r: Referenced, p: ic.callPos});
				}
				var hints = m.mExtra.mDisplay.mTypeHints, i = hints.length;
				while (i > 0) {
					var th = hints[--i];
					addRelation(th.typePos, {r: Referenced, p: th.hintPos});
				}
			}
		}
		// set up descendants
		function f1(mt:ModuleType):Void {
			switch mt {
				case TClassDecl(c):
					for (i in c.clImplements) addDescendant(i.cls, c);
					if (c.clSuper != null) addDescendant(c.clSuper.cls, c);
				case _:
			}
		}
		function loop1(com:CommonContext):Void {
			for (t in com.types) f1(t);
			var m = com.getMacros();
			if (m != null) loop1(m);
		}
		loop1(com);
		// find things
		function f2(mt:ModuleType):Void {
			switch mt {
				case TClassDecl(c):
					checkModule(c.clModule);
					declare(hasClassFlag(c, CInterface) ? SKInterface(c) : SKClass(c), c.clNamePos);
					if (c.clSuper != null) {
						var c_ = c.clSuper.cls;
						function loop(c_:TClass):Void {
							addRelation(c_.clNamePos, {r: Extended, p: c.clNamePos});
							if (c_.clSuper != null) loop(c_.clSuper.cls);
						}
						loop(c_);
					}
					if (hasClassFlag(c, CInterface)) collectImplementations(c);
					function field(cf:TClassField):Void {
						if (cf.cfPos.pmin > c.clNamePos.pmin) declare(SKField(cf, c), cf.cfNamePos);
						if (withExpressions) {
							follow(cf.cfType);
							if (cf.cfExpr != null) collectReferences(c, cf.cfExpr);
						}
					}
					if (c.clConstructor != null) field(c.clConstructor);
					for (cf in c.clOrderedFields) {
						if (hasClassFieldFlag(cf, CfOverride)) checkOverride(c, cf);
						field(cf);
					}
					for (cf in c.clOrderedStatics) field(cf);
				case TEnumDecl(en):
					checkModule(en.eModule);
					declare(SKEnum(en), en.eNamePos);
					core.ds.PMap.iter(function(_, ef:TEnumField) declare(SKEnumField(ef), ef.efNamePos), en.eConstrs);
				case TTypeDecl(td):
					checkModule(td.tModule);
					declare(SKTypedef(td), td.tNamePos);
				case TAbstractDecl(a):
					checkModule(a.aModule);
					declare(SKAbstract(a), a.aNamePos);
			}
		}
		function loop2(com:CommonContext):Void {
			for (t in com.types) f2(t);
			var m = com.getMacros();
			if (m != null) loop2(m);
		}
		loop2(com);
		// TODO: Using syntax-exploration here is technically fine, but I worry about performance in real codebases.
		/* let find_symbols = Hashtbl.fold (fun _ kind acc ->
			let name = string_of_symbol kind in
			(name,kind) :: acc
		) symbols [] in
		let additional_modules = SyntaxExplorer.explore_uncached_modules ctx (CompilationServer.force()) find_symbols in
		List.iter (fun md ->
			List.iter f md.m_types
		) additional_modules; */
		/* let deal_with_imports paths =
			let check_subtype m s p =
				try
					let mt = List.find (fun mt -> snd (t_infos mt).mt_path = s) m.m_types in
					add_relation (t_infos mt).mt_name_pos (Referenced,p);
					Some mt
				with Not_found ->
					None
			in
			let check_module path p =
				let m = ctx.g.do_load_module ctx path p in
				m
			in
			let check_field c s p =
				let cf = PMap.find s c.cl_statics in
				add_relation cf.cf_name_pos (Referenced,p)
			in
			let check_subtype_field m ssub psub sfield pfield = match check_subtype m ssub psub with
				| Some (TClassDecl c) -> check_field c sfield pfield
				| _ -> ()
			in
			PMap.iter (fun p (_,path) ->
				match ImportHandling.convert_import_to_something_usable { p with pmin = p.pmax - 1; pmax = p.pmax - 1 } path,List.rev path with
				| (IDKSubType(sl,s1,s2),_),(_,psubtype) :: (_,pmodule) :: _ ->
					let m = check_module (sl,s1) pmodule in
					(*ignore(check_subtype m s1 pmodule);*)
					ignore(check_subtype m s2 psubtype)
				| (IDKModuleField(sl,s1,s2),_),(_,pfield) :: (_,pmodule) :: _ ->
					let m = check_module (sl,s1) pmodule in
					check_subtype_field m s1 pmodule s2 pfield
				| (IDKSubTypeField(sl,s1,s2,s3),_),(_,pfield) :: (_,psubtype) :: (_,pmodule) :: _ ->
					let m = check_module (sl,s1) pmodule in
					check_subtype_field m s2 psubtype s3 pfield
				| (IDKModule(sl,s),_),(_,pmodule) :: _ ->
					let m = check_module (sl,s) pmodule in
					ignore(check_subtype m s pmodule);
				| _ ->
					()
			) paths
		in
		if false then deal_with_imports ctx.com.shared.shared_display_information.import_positions; */
		return {symbols: symbols, relations: relations};
	}
}

// port: Statistics.Printer
class StatisticsPrinter {
	static inline function kv(n:String, v:JsonValue):JsonField return {name: n, value: v};

	public static function relationToString(r:Relation):String return switch r {
		case Implemented: "implementers";
		case Extended: "subclasses";
		case Overridden: "overrides";
		case Referenced: "references";
	};

	public static function symbolToString(s:Symbol):String return switch s {
		case SKClass(_): "class type";
		case SKInterface(_): "interface type";
		case SKEnum(_): "enum type";
		case SKTypedef(_): "typedef";
		case SKAbstract(_): "abstract";
		case SKField(_): "class field";
		case SKConstructor(_): "constructor";
		case SKEnumField(_): "enum field";
		case SKVariable(_): "variable";
		case SKOther: "other";
	};

	public static function jsonOfStatistics(r:StatisticsResult):JsonValue {
		var kinds = r.symbols, relations = r.relations;
		var files = new OcamlHashtbl<String, Array<{p:Pos, rl:Array<{r:Relation, p:Pos}>}>>(OcamlHash.hashString, (a, b) -> a == b, 0);
		relations.iter(function(p, rl) {
			var file = core.Path.getRealPath(p.pfile);
			var l = files.findOpt(file);
			if (l != null) files.replace(file, [{p: p, rl: rl}].concat(l))
			else files.add(file, [{p: p, rl: rl}]);
		});
		var ja = files.fold(function(file, relations:Array<{p:Pos, rl:Array<{r:Relation, p:Pos}>}>, acc:Array<JsonValue>) {
			var l = relations.map(function(e) {
				var h = new OcamlHashtbl<String, Array<JsonValue>>(OcamlHash.hashString, (a, b) -> a == b, 0);
				for (x in e.rl) {
					var s = relationToString(x.r);
					var jo = JObject([
						kv("range", core.json.Genjson.generatePosAsRange(x.p)),
						kv("file", JString(core.Path.getRealPath(x.p.pfile)))
					]);
					var cur = h.findOpt(s);
					if (cur != null) h.replace(s, [jo].concat(cur))
					else h.add(s, [jo]);
				}
				var l = h.fold(function(s, js, acc:Array<JsonField>) {
					acc.unshift(kv(s, JArray(js)));
					return acc;
				}, []);
				l.unshift(kv("range", core.json.Genjson.generatePosAsRange(e.p)));
				var k = kinds.findOpt(e.p);
				if (k != null) l.unshift(kv("kind", JString(symbolToString(k))));
				return JObject(l);
			});
			acc.unshift(JObject([kv("file", JString(file)), kv("statistics", JArray(l))]));
			return acc;
		}, []);
		return JArray(ja);
	}
}
