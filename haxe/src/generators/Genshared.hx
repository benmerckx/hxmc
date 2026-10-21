package generators;

import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions.*;
import core.TUnification.Unify_error;
import core.MetaList;
import core.ds.OcamlHash;
import core.ds.OcamlHash.OcamlValue;
import core.ds.OcamlHashtbl;
import typing.TanonIdentification;
import typing.OverloadResolution;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

private typedef MetaTag = core.MetaList.StrictMeta;

enum MethodType {
	MStatic;
	MInstance;
	MConstructor;
}

@:structInit class FieldGenerationInfo {
	public var hasThisBeforeSuper:Bool;
	/* This is an ordered list of fields that are targets of super() calls which is determined during
		 pre-processing. The generator can pop from this list assuming that it processes the expression
		 in the same order (which it should). */
	public var superCallFields:Array<{c:TClass, cf:TClassField}>;
}

// port: an entry of `implicit_ctors : ((path * 'a),(tclass * tclass_field)) PMap.t`.
typedef ImplicitCtor<A> = {path:GlobalTypePath, sig:A, c:TClass, cf:TClassField};

@:structInit class TClassInfo<A> {
	public var typedefImplements:Null<Array<TClass>>;
	// port: a PMap with OCaml's polymorphic `compare` on the keys; kept sorted by `keyValue`.
	public var implicitCtors:Array<ImplicitCtor<A>>;
}

class InfoContext<A> {
	final classInfos:Array<TClassInfo<A>> = [];

	public function new() {}

	public function getClassInfo(c:TClass):TClassInfo<A> {
		for (m in c.clMeta) {
			if (core.Meta.metaEq(MetaTag.Custom(":jvm.classInfo"), m.meta)) switch m.exprs {
				case [{expr: EConst(Int(s, _))}]:
					return classInfos[Std.parseInt(s)];
				case _:
			}
		}
		var index = classInfos.length;
		var infos:TClassInfo<A> = {
			typedefImplements: null,
			implicitCtors: [],
		};
		classInfos.push(infos);
		c.clMeta = [
			({meta: MetaTag.Custom(":jvm.classInfo"), exprs: vector({expr: EConst(Int(Std.string(index), null)), pos: nullPos}), pos: nullPos} : MetadataEntry)
		].concat(c.clMeta);
		return infos;
	}
}

class Genshared {
	public static function isExternAbstract(a:TAbstract):Bool {
		return switch a.aImpl {
			case null:
				switch a.aPath {
					case {pack: [], name: "Void" | "Float" | "Int" | "Single" | "Bool" | "Null"}: true;
					case _: false;
				}
			case c: hasClassFlag(c, CExtern);
		}
	}

	public static function patchOptional(basic:BasicTypes, cf:TClassField):Void {
		for (cf in cf.cfOverloads) patchOptional(basic, cf);
		function patchArgs(args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>):haxe.ds.Vector<{name:String, optional:Bool, type:T}> {
			return args.map(function(a) {
				var o = a.optional, t = a.type;
				if (o && !isNullable(t)) t = basic.tnull(t);
				return {name: a.name, optional: o, type: t};
			});
		}
		switch follow(cf.cfType) {
			case TFun(s):
				var args = patchArgs(s.args);
				cf.cfType = TFun({args: args, ret: s.ret});
			case TAbstract(a = {aPath: {pack: ["haxe", "coro"], name: "Coroutine"}}, [t]):
				switch follow(t) {
					case TFun(s):
						var args = patchArgs(s.args);
						cf.cfType = TAbstract(a, vector(TFun({args: args, ret: s.ret})));
					case t:
				}
			case _:
		}
	}

	// port: OCaml's polymorphic `compare` on runtime values (compare.c): immediates before
	// blocks, then tags, sizes and fields in order; strings compare bytewise.
	public static function ocamlCompare(a:OcamlValue, b:OcamlValue):Int {
		return switch [a, b] {
			case [OInt(i1), OInt(i2)]: i1 < i2 ? -1 : (i1 > i2 ? 1 : 0);
			case [OInt(_), _]: -1;
			case [_, OInt(_)]: 1;
			case [OString(s1), OString(s2)]:
				var b1 = haxe.io.Bytes.ofString(s1), b2 = haxe.io.Bytes.ofString(s2);
				var c = b1.compare(b2);
				c < 0 ? -1 : (c > 0 ? 1 : 0);
			case [OString(_), OBlock(_)]: 1;
			case [OBlock(_), OString(_)]: -1;
			case [OBlock(t1, f1), OBlock(t2, f2)]:
				if (t1 != t2) t1 < t2 ? -1 : 1 else if (f1.length != f2.length) f1.length < f2.length ? -1 : 1 else {
					var r = 0;
					for (i in 0...f1.length) {
						r = ocamlCompare(f1[i], f2[i]);
						if (r != 0) break;
					}
					r;
				}
		}
	}
}

class Preprocessor<A> {
	final basic:BasicTypes;
	final convert:T->A;
	final keyValue:A->OcamlValue;
	final infos = new InfoContext<A>();
	final fieldInfos:Array<FieldGenerationInfo> = [];

	// port: `keyValue` gives the OCaml runtime value of a converted type, for the
	// polymorphic compare ordering `implicit_ctors`.
	public function new(basic:BasicTypes, convert:T->A, keyValue:A->OcamlValue) {
		this.basic = basic;
		this.convert = convert;
		this.keyValue = keyValue;
	}

	static function makeNative(cf:TClassField):Void {
		cf.cfMeta = [({meta: MetaTag.NativeGen, exprs: vector(), pos: nullPos} : MetadataEntry)].concat(cf.cfMeta);
	}

	static function makeHaxe(cf:TClassField):Void {
		cf.cfMeta = [({meta: MetaTag.HxGen, exprs: vector(), pos: nullPos} : MetadataEntry)].concat(cf.cfMeta);
	}

	static function getConstructor(c:TClass):TClassField {
		return switch [c.clConstructor, c.clSuper] {
			case [cf, _] if (cf != null): cf;
			case [null, null]: throw core.ds.NotFound.raise();
			case [null, sup]: getConstructor(sup.cls);
			case _: throw core.ds.NotFound.raise();
		}
	}

	public function getInfos():InfoContext<A> return infos;

	public function getImplicitCtor(c:TClass):Array<ImplicitCtor<A>> {
		return infos.getClassInfo(c).implicitCtors;
	}

	public function getFieldInfo(ml:Metadata):Null<FieldGenerationInfo> {
		for (m in ml) {
			if (core.Meta.metaEq(MetaTag.Custom(":jvm.fieldInfo"), m.meta)) switch m.exprs {
				case [{expr: EConst(Int(s, _))}]:
					return fieldInfos[Std.parseInt(s)];
				case _:
			}
		}
		return null;
	}

	public function addImplicitCtor(c:TClass, c2:TClass, cf:TClassField):Void {
		var jsig = convert(cf.cfType);
		var info = infos.getClassInfo(c);
		// port: PMap.add on a key compared with OCaml's `compare`
		var key = OBlock(0, [OcamlHash.ofPath(c2.clPath.pack, c2.clPath.name), keyValue(jsig)]);
		var l = info.implicitCtors.copy();
		var entry:ImplicitCtor<A> = {path: c2.clPath, sig: jsig, c: c2, cf: cf};
		var i = 0;
		while (i < l.length) {
			var k = OBlock(0, [OcamlHash.ofPath(l[i].path.pack, l[i].path.name), keyValue(l[i].sig)]);
			var r = Genshared.ocamlCompare(key, k);
			if (r == 0) {
				l[i] = entry;
				break;
			}
			if (r < 0) {
				l.insert(i, entry);
				break;
			}
			i++;
		}
		if (i == l.length) l.push(entry);
		info.implicitCtors = l;
	}

	public function preprocessConstructorExpr(c:TClass, cf:TClassField, e:TExpr):FieldGenerationInfo {
		var usedThis = false;
		var thisBeforeSuper = false;
		var superCallFields:Array<{c:TClass, cf:TClassField}> = [];
		function isOnCurrentClass(cf:TClassField):Bool return c.clFields.exists(cf.cfName);
		function findSuperCtor0(el:Vector<TExpr>):{c:TClass, cf:TClassField} {
			var csup:TClass = null, mapType:T->T = null;
			switch c.clSuper {
				case null:
					die("", "generators/genshared.ml");
				case sup:
					csup = sup.cls;
					mapType = function(t) return applyParams(sup.cls.clParams, sup.params, t);
			}
			return switch OverloadResolution.resolveInstanceOverload(true, mapType, csup, "new", el) {
				case null:
					core.Error.raiseTypingError("Could not find overload constructor", e.epos);
				case r:
					var c = r.cls, cf = r.field;
					function loop(csup:TClass):Void {
						if (c != csup) {
							switch csup.clSuper {
								case null:
									die("", "generators/genshared.ml");
								case sup:
									addImplicitCtor(csup, sup.cls, cf);
									loop(sup.cls);
							}
						}
					}
					loop(csup);
					{c: c, cf: cf};
			}
		}
		function findSuperCtor(el:Vector<TExpr>):{c:TClass, cf:TClassField} {
			var cf = findSuperCtor0(el).cf;
			/* This is a bit hacky: We always want the direct super class, not the one that actually holds
				 the ctor. It will be implicitly copied to it anyway. */
			return switch c.clSuper {
				case null: die("", "generators/genshared.ml");
				case sup: {c: sup.cls, cf: cf};
			}
		}
		function promoteThisBeforeSuper(c:TClass, cf:TClassField, p:Pos):Void {
			switch getFieldInfo(cf.cfMeta) {
				case null:
					core.Error.raiseTypingError('Could not determine field information for ${cf.cfName} in a this-before-super case, please report this', p);
				case info:
					if (!info.hasThisBeforeSuper) {
						makeHaxe(cf);
						/* print_endline (Printf.sprintf "promoted this_before_super to %s.new : %s" (s_type_path c.cl_path) (s_type (print_context()) cf.cf_type)); */
						info.hasThisBeforeSuper = true;
						for (e in info.superCallFields) promoteThisBeforeSuper(e.c, e.cf, p);
					}
			}
		}
		function loop(e:TExpr):Void {
			switch e.eexpr {
				case TBinop(OpAssign, {eexpr: TField({eexpr: TConst(TThis)}, FInstance(_, _, cf))}, e2) if (isOnCurrentClass(cf)):
					/* Assigning this.field = value is fine if field is declared on our current class */
					loop(e2);
				case TConst(TThis):
					usedThis = true;
				case TCall({eexpr: TConst(TSuper)}, el):
					for (e in el) loop(e);
					if (usedThis) {
						thisBeforeSuper = true;
						makeHaxe(cf);
						/* print_endline (Printf.sprintf "inferred this_before_super on %s.new : %s" (s_type_path c.cl_path) (s_type (print_context()) cf.cf_type)); */
					}
					var r = findSuperCtor(el);
					if (thisBeforeSuper) promoteThisBeforeSuper(r.c, r.cf, e.epos);
					superCallFields.push(r);
				case _:
					core.Texpr.iter(loop, e);
			}
		}
		loop(e);
		return {
			hasThisBeforeSuper: thisBeforeSuper,
			superCallFields: superCallFields.copy(),
		};
	}

	public function preprocessClass(c:TClass):Void {
		var hasDynamicInstanceMethod = false;
		var hasFieldInit = false;
		function field(mtype:MethodType, cf:TClassField):Void {
			Genshared.patchOptional(basic, cf);
			switch mtype {
				case MConstructor:
				case MInstance:
					switch cf.cfKind {
						case Method(MethDynamic):
							hasDynamicInstanceMethod = true;
						case Var(_) if (cf.cfExpr != null && !hasFieldInit && c.clConstructor == null && c.clSuper == null):
							hasFieldInit = true;
							addImplicitCtor(c, c, mkField("new", tfun(vector(), basic.tvoid), nullPos, nullPos));
						case _:
					}
				case MStatic:
			}
		}
		for (cf in c.clOrderedStatics) field(MStatic, cf);
		for (cf in c.clOrderedFields) field(MInstance, cf);
		switch c.clConstructor {
			case null:
				try {
					var cf = getConstructor(c);
					var csup = switch c.clSuper {
						case null: die("", "generators/genshared.ml");
						case sup: sup.cls;
					}
					for (cf in [cf].concat(cf.cfOverloads)) addImplicitCtor(c, csup, cf);
				} catch (_:core.ds.NotFound) {}
			case cf:
				Genshared.patchOptional(basic, cf);
				function field(cf:TClassField):Void {
					if (hasDynamicInstanceMethod) makeHaxe(cf);
					switch cf.cfExpr {
						case null:
						case e:
							var info = preprocessConstructorExpr(c, cf, e);
							var index = fieldInfos.length;
							fieldInfos.push(info);
							cf.cfMeta = [
								({
									meta: MetaTag.Custom(":jvm.fieldInfo"),
									exprs: vector({expr: EConst(Int(Std.string(index), null)), pos: nullPos}),
									pos: nullPos
								} : MetadataEntry)
							].concat(cf.cfMeta);
							if (!core.Meta.has(MetaTag.HxGen, cf.cfMeta)) {
								function loop(next:TClass->Void, c:TClass):Void {
									if (hasClassFlag(c, CExtern)) makeNative(cf) else switch c.clConstructor {
										case cf2 if (cf2 != null && core.Meta.has(MetaTag.HxGen, cf2.cfMeta)): makeHaxe(cf);
										case cf2 if (cf2 != null && core.Meta.has(MetaTag.NativeGen, cf2.cfMeta)): makeNative(cf);
										case _: next(c);
									}
								}
								function up(c:TClass):Void {
									switch c.clSuper {
										case null:
										case sup: loop(up, sup.cls);
									}
								}
								function down(c:TClass):Void {
									for (c in c.clDescendants) loop(down, c);
								}
								loop(up, c);
								loop(down, c);
							}
					}
				}
				for (cf in [cf].concat(cf.cfOverloads)) field(cf);
		}
	}
}

class TypedefInterfaces<A> {
	final infos:InfoContext<A>;
	final anonIdentification:TanonIdentification<A>;
	final interfaces:OcamlHashtbl<GlobalTypePath, TClass> = new OcamlHashtbl(OcamlHash.hashPath, pathEq);
	// port: only used for lookups.
	final interfaceRewrites:haxe.ds.StringMap<{path:GlobalTypePath, isExtern:Bool}> = new haxe.ds.StringMap();

	static function pathEq(a:GlobalTypePath, b:GlobalTypePath):Bool return context.Common.samePath(a, b);

	static function pathKey(p:GlobalTypePath):String return p.pack.join(".") + ":" + p.name;

	public function new(infos:InfoContext<A>, anonIdentification:TanonIdentification<A>) {
		this.infos = infos;
		this.anonIdentification = anonIdentification;
	}

	public function addInterfaceRewrite(pathFrom:GlobalTypePath, pathTo:GlobalTypePath, isExtern:Bool):Void {
		interfaceRewrites.set(pathKey(pathFrom), {path: pathTo, isExtern: isExtern});
	}

	public function getInterfaceClass(path:GlobalTypePath):Null<TClass> {
		return interfaces.findOpt(path);
	}

	public function getInterfaces():OcamlHashtbl<GlobalTypePath, TClass> return interfaces;

	public function processClass(c:TClass):Void {
		var info = infos.getClassInfo(c);
		switch info.typedefImplements {
			case null:
				doProcessClass(c, info);
			case _:
		}
	}

	function implements_(c:TClass, pathInterface:GlobalTypePath):Bool {
		var info = infos.getClassInfo(c);
		return Lambda.exists(c.clImplements, function(i) return context.Common.samePath(i.cls.clPath, pathInterface)) || switch info.typedefImplements {
			case null:
				false;
			case l:
				Lambda.exists(l, function(c) return context.Common.samePath(c.clPath, pathInterface));
		}
	}

	function implementsRecursively(c:TClass, path:GlobalTypePath):Bool {
		return implements_(c, path) || switch c.clSuper {
			case null: false;
			case sup: implementsRecursively(sup.cls, path);
		}
	}

	function makeInterfaceClass(pfm:PathFieldMapping<A>, path:GlobalTypePath, isExtern:Bool):TClass {
		var pathInner:GlobalTypePath = {pack: pfm.pfmPath.pack, name: pfm.pfmPath.name + "$Interface"};
		var found = interfaces.findOpt(pathInner);
		if (found != null) return found;
		// port: PMap.foldi visits the keys in increasing order
		var names = [for (n in pfm.pfmFields.keys()) n];
		names.sort(compareStrings);
		var fields = new haxe.ds.StringMap<TClassField>();
		var sortedNames = [];
		for (name in names) {
			var cf = pfm.pfmFields.get(name);
			switch cf.cfKind {
				case Method(MethNormal | MethInline):
					fields.set(name, cf);
					sortedNames.push(name);
				case _:
			}
		}
		if (sortedNames.length == 0) throw new Unify_error([UnifyCustom("no fields")]);
		var c = mkClass(nullModule, path, nullPos, nullPos);
		addClassFlag(c, CInterface);
		c.clFields = fields;
		// port: PMap.fold (fun cf acc -> cf :: acc): the fields in decreasing key order
		var ordered = [for (n in sortedNames) fields.get(n)];
		ordered.reverse();
		c.clOrderedFields = ordered;
		if (isExtern) addClassFlag(c, CExtern);
		interfaces.replace(pfm.pfmPath, c);
		return c;
	}

	// port: OCaml's string compare (bytewise).
	public static function compareStrings(a:String, b:String):Int return core.ds.Key.compareStrings(a, b);

	function doProcessClass(c:TClass, info:TClassInfo<A>):Void {
		switch c.clSuper {
			case null:
			case sup: processClass(sup.cls);
		}
		var tc = TInst(c, extractParamTypes(c.clParams));
		/* TODO: this entire architecture looks slightly retarded because typedef_implements is only modified at the end of the
			 loop, which I think could cause items to be missed. */
		var l = anonIdentification.getPfms().fold(function(_, pfm:PathFieldMapping<A>, acc:Array<TClass>) {
			var path = pfm.pfmPath;
			var pathInner:GlobalTypePath = {pack: path.pack, name: path.name + "$Interface"};
			try {
				var rw = interfaceRewrites.get(pathKey(pfm.pfmPath));
				var pathInner = rw != null ? rw.path : pathInner;
				var isExtern = rw != null ? rw.isExtern : false;
				if (implementsRecursively(c, pathInner)) throw new Unify_error([UnifyCustom("already implemented")]);
				anonIdentification.unify(AnonIdMode.defaultMode, tc, pfm);
				var ci = makeInterfaceClass(pfm, pathInner, isExtern);
				c.clImplements = [({cls: ci, params: vector()} : ClassAndParams)].concat(c.clImplements);
				/* print_endline (Printf.sprintf "%s IMPLEMENTS %s" (s_type_path c.cl_path) (s_type_path path_inner)); */
				acc.unshift(ci);
				return acc;
			} catch (_:Unify_error) {
				return acc;
			}
		}, []);
		info.typedefImplements = l;
	}
}
