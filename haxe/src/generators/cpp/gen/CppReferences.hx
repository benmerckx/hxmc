package generators.cpp.gen;

import core.Globals;
import core.TType;
import core.TFunctions.*;
import core.TFunctions.MaybeCoro;
import core.Meta;
import generators.cpp.CppAst;
import generators.cpp.CppStrings.*;
import generators.cpp.CppTypeUtils.*;
import generators.cpp.CppAstTools.*;
import generators.cpp.CppContext;
import generators.cpp.CppMarshalling.*;

// port: `(path, bool) PMap.t`: keys compared with OCaml's polymorphic compare on `(string list * string)`.
private class PathFlags {
	final entries = new haxe.ds.StringMap<{path:GlobalTypePath, flag:Bool}>();

	public function new() {}

	static function key(p:GlobalTypePath):String return p.pack.join("\x00") + "\x01" + p.name;

	public function mem(p:GlobalTypePath):Bool return entries.exists(key(p));

	public function add(p:GlobalTypePath, flag:Bool):Void entries.set(key(p), {path: p, flag: flag});

	public function find(p:GlobalTypePath):Bool {
		var e = entries.get(key(p));
		if (e == null) throw core.ds.NotFound.raise();
		return e.flag;
	}

	// port: OCaml compare on paths: the package lists first ([] < x :: _, then element by element), then the names.
	static function pathCompare(a:GlobalTypePath, b:GlobalTypePath):Int {
		var i = 0;
		while (true) {
			if (i == a.pack.length && i == b.pack.length) break;
			if (i == a.pack.length) return -1;
			if (i == b.pack.length) return 1;
			var c = stringCompare(a.pack[i], b.pack[i]);
			if (c != 0) return c;
			i++;
		}
		return stringCompare(a.name, b.name);
	}

	// port: pmap_keys: the keys in decreasing order.
	public function keys():Array<GlobalTypePath> {
		var l = [for (e in entries) e.path];
		l.sort(pathCompare);
		l.reverse();
		return l;
	}
}

class CppReferences {
	/*
		Get a list of all classes referred to by the class/enum definition
		These are used for "#include"ing the appropriate header files,
		or for building the dependencies in the Build.xml file
	 */
	public static function findReferencedTypesFlags(ctx:Context, obj:ModuleType, filter:Null<String>, superDeps:PathMap<Array<GlobalTypePath>>,
			constructorDeps:PathMap<TClassField>, headerOnly:Bool, forDepends:Bool, includeSuperArgs:Bool):{deps:Array<GlobalTypePath>, flags:Array<Bool>} {
		function allVirtualFunctions(clazz:TClass):Array<{field:TClassField, args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>, ret:T}> {
			function currentVirtualFunctionsRev(clazz:TClass, baseFunctions:Array<{field:TClassField, args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>, ret:T}>) {
				var result = baseFunctions;
				for (elem in clazz.clOrderedFields) {
					result = switch [follow(elem.cfType), elem.cfKind] {
						case [_, Method(MethDynamic)]: result;
						case [TFun(sig), Method(_)]:
							if (isOverride(elem)) {
								if (Lambda.exists(result, function(e) return e.field.cfName == elem.cfName)) result else
									[{field: elem, args: sig.args, ret: sig.ret}].concat(result);
							} else [{field: elem, args: sig.args, ret: sig.ret}].concat(result);
						case [_, _]: result;
					}
				}
				return result;
			}

			function allVirtualFunctionsRec(clazz:TClass) {
				var initial = switch clazz.clSuper {
					case null: [];
					case {cls: def}: allVirtualFunctionsRec(def);
				}
				return currentVirtualFunctionsRev(clazz, initial);
			}

			return allVirtualFunctionsRec(clazz);
		}

		var types = new PathFlags();
		if (forDepends) {
			var includeFiles = getAllMetaStringPath(tInfos(obj).mtMeta, Meta.Depend);
			function includeAdder(inc:String) types.add(pathOfString(inc), true);
			for (inc in includeFiles) includeAdder(inc);
		}
		function addTypeFlag(isNative:Bool, inPath:GlobalTypePath):Void {
			if (!types.mem(inPath)) {
				types.add(inPath, isNative);
				try for (p in superDeps.find(inPath)) addTypeFlag(isNative, p) catch (_:core.ds.NotFound) {}
			}
		}
		function addType(inPath:GlobalTypePath) addTypeFlag(false, inPath);
		function addExternType(decl:ModuleType):Void {
			var tinfo = tInfos(decl);
			var includeFiles = getAllMetaStringPath(tinfo.mtMeta, if (forDepends) Meta.Depend else Meta.Include);
			if (includeFiles.length > 0) for (inc in includeFiles) addType(pathOfString(inc)) else
				if ((!forDepends) && Meta.has(Meta.Include, tinfo.mtMeta)) addType(tinfo.mtPath);
		}

		function addExternClass(klass:TClass) addExternType(TClassDecl(klass));
		function addExternEnum(enumDef:TEnum) addExternType(TEnumDecl(enumDef));
		function addExternAbstract(abs:TAbstract) addExternType(TAbstractDecl(abs));
		function addNativeGenClass(klass:TClass):Void {
			var includeFiles = getAllMetaStringPath(klass.clMeta, if (forDepends) Meta.Depend else Meta.Include);
			if (includeFiles.length > 0) for (inc in includeFiles) addType(pathOfString(inc)) else if (forDepends) addType(klass.clPath) else {
				var path = klass.clPath;
				if (!hasClassFlag(klass, CInterface))
					/* Always include native struct headers directly ... */
					addType(pathOfString(joinClassPath(path, "/") + ".h")) else addTypeFlag(true, klass.clPath);
			}
		}
		var visited:Array<T> = [];
		function visitType(inType:T):Void {
			function findBase(t:T):T {
				return switch core.TFunctions.follow(t) {
					case t = TAbstract(a, _) if (isScalarAbstract(a)):
						t;
					case t = TAbstract(a = {aExtern: true}, _) if (isMarshallingNativeEnum(a)):
						t;
					case TAbstract(a, tl):
						findBase(core.Abstract.getUnderlyingType(a, tl));
					case other:
						follow(other);
				}
			}
			// port: visited is a stack with its head last (pushed and popped in place
			// instead of copied); only searched as a whole
			if (!core.ds.ArrayTools.exists(visited, function(t2) return core.TUnification.fastEq(inType, t2))) {
				visited.push(inType);
				switch followWithCoro(inType) {
					case Coro(sig):
						var expanded = context.Common.expandCoroType(ctx.ctxCommon.basic, sig.args, sig.ret);
						visitType(expanded.ret);
						for (a in expanded.args) visitType(a.type);
					case NotCoro(t):
						switch findBase(inType) {
							case TMono(r):
								if (r.tmType != null) visitType(r.tmType);
							case TEnum(enumDef, _):
								switch isExternEnum(enumDef) {
									case true: addExternEnum(enumDef);
									case false: addType(enumDef.ePath);
								}
							/* If a class has a template parameter, then we treat it as dynamic - except
								for the Array, Class, FastIterator or Pointer classes, for which we do a fully typed object */
							case TInst(klass, params):
								switch klass.clPath {
									case {pack: [], name: "Array"} | {pack: [], name: "Class"} | {pack: ["cpp"], name: "FastIterator"} |
										{pack: ["cpp"], name: "Pointer"} | {pack: ["cpp"], name: "ConstPointer"} | {pack: ["cpp"], name: "Function"} |
										{pack: ["cpp"], name: "RawPointer"} | {pack: ["cpp"], name: "RawConstPointer"}:
										for (p in params) visitType(p);
									case _ if (isNativeGenClass(klass)): addNativeGenClass(klass);
									case _ if (isExternClass(klass)):
										addExternClass(klass);
										for (p in params) visitType(p);
									case _:
										switch klass.clKind {
											case KTypeParameter(_):
											case _: addType(klass.clPath);
										}
								}
							case TAbstract(a, _) if (isScalarAbstract(a)):
								addExternAbstract(a);
							case TAbstract(a = {aExtern: true}, _) if (isMarshallingNativeEnum(a)):
								addExternAbstract(a);
							case TFun(sig):
								visitType(sig.ret);
								for (a in sig.args) visitType(a.type);
							case _:
						}
				}
				// port: List.tl raises Failure "tl" on an empty list.
				if (visited.length == 0) throw new core.ds.Failure("tl");
				visited.pop();
			}
		}
		function visitParams(expression:TExpr):Void {
			function visitExpression(expression:TExpr):Void {
				/* Expand out TTypeExpr (ie, the name of a class, as used for static access etc ... */
				switch expression.eexpr {
					case TTypeExpr(typeDef):
						switch typeDef {
							case TClassDecl(classDef) if (isNativeGenClass(classDef)):
								addNativeGenClass(classDef);
							case TClassDecl(classDef) if (isExternClass(classDef)):
								addExternClass(classDef);
							case TEnumDecl(enumDef) if (isExternEnum(enumDef)):
								addExternEnum(enumDef);
							case _: addType(tPath(typeDef));
						}
					/* Must visit the types, Type.iter will visit the expressions ... */
					case TTry(e, catches):
						for (c in catches) visitType(c.variable.vType);
					/* Must visit type too, Type.iter will visit the expressions ... */
					case TNew(klass, params, _):
						visitType(TInst(klass, params));
						try {
							var constructType = constructorDeps.find(klass.clPath);
							visitType(constructType.cfType);
						} catch (_:core.ds.NotFound) {}
					/* Must visit type too, Type.iter will visit the expressions ... */
					case TVar(v, _): visitType(v.vType);
					/* Must visit enum type too, Type.iter will visit the expressions ... */
					case TEnumParameter(_, ef, _): visitType(follow(ef.efType));
					/* Must visit args too, Type.iter will visit the expressions ... */
					case TFunction(funcDef):
						for (a in funcDef.tfArgs) visitType(a.variable.vType);
					case TField(obj, field):
						switch field {
							case FInstance(clazz, params, _):
								visitType(TInst(clazz, params));
							case FClosure(c, _) if (c != null):
								visitType(TInst(c.cls, c.params));
							case _:
						}
					case TConst(TSuper):
						switch follow(expression.etype) {
							case TInst(klass, params):
								try {
									var constructType = constructorDeps.find(klass.clPath);
									visitType(constructType.cfType);
								} catch (_:core.ds.NotFound) {}
							case _:
								printEndline("TSuper : Odd etype ?"
									+ tcppToString(CppRetyper.cppTypeOf(ctx.ctxCommon.basic, CppRetyper.withReferenceValueType, expression.etype)));
						}
					case _:
				}
				core.Texpr.iter(visitExpression, expression);
				visitType(follow(expression.etype));
			}
			visitExpression(expression);
		}
		function visitField(field:TClassField):Void {
			/* Add the type of the expression ... */
			visitType(field.cfType);
			if (!headerOnly) switch field.cfExpr {
				case null:
				case expression: visitParams(expression);
			}
		}
		function visitClass(classDef:TClass):Void {
			var fields = classDef.clOrderedFields.concat(classDef.clOrderedStatics);
			var fieldsAndConstructor = fields.concat(switch classDef.clConstructor {
				case null: [];
				case expr: [expr];
			});
			var fieldsAndConstructor = switch filter {
				case null:
					fieldsAndConstructor;
				case fieldName:
					fieldsAndConstructor.filter(function(f) return f.cfName == fieldName);
			}
			for (f in fieldsAndConstructor) visitField(f);
			if (includeSuperArgs) for (f in allVirtualFunctions(classDef).map(function(a) return a.field)) visitField(f);

			/* Add super & interfaces */
			if (isNativeGenClass(classDef)) addNativeGenClass(classDef) else addType(classDef.clPath);
		}
		function visitEnum(enumDef:TEnum):Void {
			addType(enumDef.ePath);
			for (name in core.ds.PMap.keys(enumDef.eConstrs)) {
				var constructor = enumDef.eConstrs.get(name);
				switch constructor.efType {
					case TFun(sig): for (a in sig.args) visitType(a.type);
					case _:
				}
			}
			if (!headerOnly) {
				var meta = core.Texpr.buildMetadata(ctx.ctxCommon.basic, TEnumDecl(enumDef));
				switch meta {
					case null:
					case expr: visitParams(expr);
				}
			}
		}
		function incCmp(i1:GlobalTypePath, i2:GlobalTypePath):Int return stringCompare(joinClassPath(i1, "."), joinClassPath(i2, "."));

		/* Body of main function */
		switch obj {
			case TClassDecl(classDef):
				visitClass(classDef);
				switch core.TOther.TClassTools.getClInit(classDef) {
					case null:
					case expression: visitParams(expression);
				}
			case TEnumDecl(enumDef): visitEnum(enumDef);
			case TTypeDecl(_) | TAbstractDecl(_): /* These are expanded */
		}

		/*
			The internal header files are also defined in the hx/Object.h file, so you do
			#include them separately. However, Math classes has its
			own header file (under the hxcpp tree) so these should be included
		 */
		function includeClassHeader(path:GlobalTypePath):Bool {
			return switch path {
				case {pack: [], name: "@Main"}: false;
				case {pack: [], name: "Math"}: true;
				case path: !isInternalClass(path);
			}
		}
		var deps = listSort(incCmp, types.keys().filter(includeClassHeader));
		var flags = deps.map(function(dep) return types.find(dep));
		return {deps: deps, flags: flags};
	}

	public static function findReferencedTypes(ctx:Context, obj:ModuleType, superDeps:PathMap<Array<GlobalTypePath>>, constructorDeps:PathMap<TClassField>,
			headerOnly:Bool, forDepends:Bool, includeSuperArgs:Bool):Array<GlobalTypePath> {
		return findReferencedTypesFlags(ctx, obj, null, superDeps, constructorDeps, headerOnly, forDepends, includeSuperArgs).deps;
	}
}
