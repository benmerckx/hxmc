package typing;

import core.Ast.*;
import core.Error;
import core.Error.*;
import core.Texpr;
import core.TPrinting.Printer;
import core.TUnification.TUnification.linkDynamic;
import core.ds.AtomicLazy;
import core.ds.NotFound;
import core.ds.Exit;
import context.Common;
import context.TyperPass;
import typing.FieldCallCandidate.FieldCallCandidateData;

using Lambda;
using core.ds.ArrayTools;

import core.WithType as WithTypeTools;
import core.WithType.WithTypeValue;
import core.MetaList.StrictMeta as MetaTag;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.TType;
import core.Ast;
import core.Globals.*;
import core.TFunctions.*;
import core.TOther.*;
import core.TOther;
import core.WithType;
import context.Typecore.*;
import context.Typecore;

typedef GenericSubst = {var cls:TClass; var t:T; var expr:Null<TExpr>;}
typedef GenericContext = {var ctx:Typer; var subst:Array<GenericSubst>; var name:String; var p:Pos; var mg:Null<ModuleDef>; var genericDebug:Bool;}

class Generic {
	public static function makeGeneric(ctx:Typer, ps:TypeParams, pt:Array<T>, debug:Bool, p:Pos):GenericContext {
		inline function identSafe(s:String):String {
			var b = new StringBuf();
			for (i in 0...s.length) {
				var c = s.charCodeAt(i);
				b.add(c >= 65 && c <= 90 || c >= 97 && c <= 122 || c >= 48 && c <= 57 || c == 95 ? s.charAt(i) : '_${c}_');
			}
			return b.toString();
		}
		inline function pathName(p:GlobalTypePath):String return p.pack.length == 0 ? p.name : p.pack.join("_") + "_" + p.name;
		inline function process(t:T):{name:String, t:T, expr:Null<TExpr>} {
			function loop(top:Bool, t:T):{name:String, t:T, expr:Null<TExpr>} {
				inline function result(name:String, expr:Null<TExpr> = null):{name:String, t:T, expr:Null<TExpr>}
					return {name: name, t: t, expr: expr};
				inline function tlName(tl:Array<T>):String return tl.length == 0 ? "" : "_"
					+ tl.map(function(t) return loop(top, t).name).join("_");
				inline function deep(t:T):String return loop(false, t).name;
				return switch t {
					case TInst(c, tl): switch c.clKind {
							case KExpr(e):
								var name = identSafe(core.AstPrinter.sExpr(e));
								var cloned = TyperManager.cloneForTypeParameterExpression(ctx);
								result(name, typeExpr(cloned, e, WithTypeTools.value));
							case _: result(identSafe(pathName(c.clPath)) + tlName(tl));
						}
					case TType(td, tl): result(pathName(td.tPath) + tlName(tl));
					case TEnum(en, tl): result(pathName(en.ePath) + tlName(tl));
					case TAnon(a):
						var names = [for (n in a.aFields.keys()) n];
						names.sort(core.ds.Key.compareStrings);
						var fields = [];
						for (n in names) fields.unshift(n + "_" + deep(follow(a.aFields.get(n).cfType)));
						result("anon_" + fields.join("_"));
					case TFun(s): result("func_" + s.args.map(function(a) return deep(a.type)).join("_") + "_" + deep(s.ret));
					case TAbstract(a, tl): result(pathName(a.aPath) + tlName(tl));
					case TDynamic(_): result("Dynamic");
					case TMono({tmType: null}):
						if (top) throw Exit.raise();
						result("_");
					case TMono({tmType: t}): loop(top, t);
					case TLazy(f): loop(top, lazyType(f));
				};
			}
			return loop(true, t);
		}
		if (ps.length != pt.length) throw "assert";
		var names = [];
		var subst = [];
		for (i in 0...ps.length) {
			var r;
			try {
				r = process(pt[i]);
			} catch (ex:Exit) {
				return Error.raiseTypingError("Could not determine type for parameter " + ps[i].ttpName, p);
			}
			names.push(r.name);
			subst.unshift({cls: ps[i].ttpClass, t: r.t, expr: r.expr});
		}
		return {
			ctx: ctx,
			subst: subst,
			name: names.join("_"),
			p: p,
			mg: null,
			genericDebug: debug
		};
	}

	public static function genericSubstituteTypeAllowExpr(g:GenericContext, allowExpr:Bool, t:T):T return switch t {
		case TInst(c = {clKind: KGeneric}, tl):
			// maybe loop, or generate cascading generics
			var info = g.ctx.g.getBuildInfo(g.ctx, TClassDecl(c), g.p);
			var t = info.buildApply(tl.map(function(t) return genericSubstituteTypeAllowExpr(g, true, t)));
			switch [follow(t), g.mg] {
				case [TInst(c, _), m] if (m != null): addDependency(m, c.clModule, MDepFromTyping);
				case _:
			}
			t;
		case TInst(c = {clKind: KTypeParameter(_)}, _):
			var subst = null;
			for (s in g.subst) if (s.cls == c) {
				subst = s;
				break;
			}
			if (subst == null) map(function(t) return genericSubstituteTypeAllowExpr(g, allowExpr, t),
				t); else
				// Somewhat awkward: If we allow expression types, use the original KExpr one. This is so
				// recursing into further KGeneric expands correctly.
				if (subst.expr != null && !allowExpr) subst.expr.etype; else genericSubstituteTypeAllowExpr(g, false, subst.t);
		case _: map(function(t) return genericSubstituteTypeAllowExpr(g, allowExpr, t), t);
	};

	public static function genericSubstituteType(g:GenericContext, t:T):T return genericSubstituteTypeAllowExpr(g, false, t);

	public static function genericSubstituteExpr(g:GenericContext, e:TExpr):TExpr {
		var vars:Map<Int, TVar> = [];
		function buildVar(v:TVar):TVar {
			var n = vars.get(v.vId);
			if (n != null) return n;
			n = allocVar(v.vKind, v.vName, genericSubstituteType(g, v.vType), v.vPos);
			n.vMeta = v.vMeta;
			vars.set(v.vId, n);
			return n;
		}
		function build(e:TExpr):TExpr {
			var e = switch e.eexpr {
				case TField(e1, orig = FInstance(c = {clKind: KGeneric}, tl, cf)) |
					TField(e1, orig = FClosure({cls: c = {clKind: KGeneric}, params: tl}, cf)):
					var info = g.ctx.g.getBuildInfo(g.ctx, TClassDecl(c), g.p);
					var t = info.buildApply(tl.map(function(t) return genericSubstituteTypeAllowExpr(g, true, t)));
					var same = switch follow(t) {
						case TInst(c2, _) if (c == c2): true;
						case _: false;
					};
					if (same)
						// The @:generic class wasn't expanded, let's not recurse to avoid infinite loop (#6430)
						Texpr.mapExprType(build, function(t) return genericSubstituteType(g, t), buildVar, e); else {
						var fa;
						try {
							fa = quickField(t, cf.cfName);
						} catch (ex:NotFound) {
							return
								Error.raiseTypingError('Type ${core.TPrinting.sType(core.TPrinting.printContext(), t)} has no field ${cf.cfName} (possible typing order issue)',
								e.epos);
						}
						// preserve FClosure
						fa = switch [orig, fa] {
							case [FClosure(_, _), FInstance(c, tl, cf)]: FClosure({cls: c, params: tl}, cf);
							case _: fa;
						};
						build(core.ds.Record.withFields(e, {eexpr: TField(e1, fa)}));
					}
				case TTypeExpr(TClassDecl(c = {clKind: KTypeParameter(_)})) if (core.Meta.has(MetaTag.Const, c.clMeta)):
					var found = false;
					var replacement = e;
					for (s in g.subst) if (s.cls == c) {
						found = true;
						if (s.expr == null) return Error.raiseTypingError("Only Const type parameters can be used as value", e.epos);
						replacement = s.expr;
						break;
					}
					replacement;
				case _: Texpr.mapExprType(build, function(t) return genericSubstituteType(g, t), buildVar, e);
			};
			return OverloadResolution.maybeReapplyOverloadCall(e);
		}
		return build(e);
	}

	static var shortNameId = -1;

	public static function getShortName():String return 'Hx___short___hx_type_${++shortNameId}';

	static function missingModule(ex:Dynamic, path:GlobalTypePath):Bool return switch ex {
		case(core.ds.ExceptionTools.typing(_) =>
			Some({errMessage: ModuleNotFound(p)})): p.name == path.name && p.pack.length == path.pack.length && [for (i in 0...p.pack.length) p.pack[i] == path.pack[i]].indexOf(false) < 0;
		case _: false;
	};

	static function makeModule(g:GenericContext, c:TClass, path:GlobalTypePath):ModuleDef {
		var m = c.clModule;
		return {
			mId: allocMid(),
			mPath: path,
			mTypes: [],
			mStatics: null,
			mExtra: moduleExtra(sTypePath(path), m.mExtra.mSign, 0., MFake, g.ctx.com.partScope.compilationStep, m.mExtra.mCheckPolicy)
		};
	}

	public static function staticMethodContainer(g:GenericContext, c:TClass, cf:TClassField, p:Pos):TClass {
		var ctx = g.ctx;
		var path:core.Globals.GlobalTypePath = {pack: c.clPath.pack, name: c.clPath.name + "_" + cf.cfName + "_" + g.name};
		try {
			var t = Typeload.loadInstance(ctx, makePtp(mkTypePath(path.pack, path.name), p), ParamSpawnMonos, LoadNormal);
			return switch t {
				case TInst(cg, _): cg;
				case _: Error.raiseTypingError("Cannot specialize @:generic static method because the generated type name is already used: "
						+ path.name, p);
			};
		} catch (ex:Dynamic) {
			if (!missingModule(ex, path)) throw ex;
		}
		var mg = makeModule(g, c, path);
		g.mg = mg;
		var cg = mkClass(mg, path, c.clPos, c.clNamePos);
		mg.mTypes = [TClassDecl(cg)];
		ctx.com.moduleLut.add(mg.mPath, mg);
		addDependency(mg, c.clModule, MDepFromTyping);
		addDependency(ctx.m.curmod, mg, MDepFromTyping);
		return cg;
	}

	public static function setTypeParameterDependencies(mg:ModuleDef, tl:Array<T>):Void {
		// ensure that type parameters are set in dependencies
		var stack = [];
		function loop(t:T):Void {
			if (stack.indexOf(t) >= 0) return;
			stack.unshift(t);
			inline function dep(m:ModuleDef, tl:Array<T>):Void {
				addDependency(mg, m, MDepFromTyping);
				for (t in tl) loop(t);
			}
			switch t {
				case TInst(c, tl):
					dep(c.clModule, tl);
				case TEnum(e, tl):
					dep(e.eModule, tl);
				case TType(t, tl):
					dep(t.tModule, tl);
				case TAbstract(a, tl):
					dep(a.aModule, tl);
				case TMono(r):
					if (r.tmType != null) loop(r.tmType);
				case TLazy(f):
					loop(lazyType(f));
				case TDynamic(t):
					if (t != null) loop(t);
				case TAnon(a):
					var names = [for (n in a.aFields.keys()) n];
					names.sort(core.ds.Key.compareStrings);
					for (n in names) loop(a.aFields.get(n).cfType);
				case TFun(s):
					for (a in s.args) loop(a.type);
					loop(s.ret);
			}
		}
		for (t in tl) loop(t);
	}

	public static function buildInstances(ctx:Typer, t:T, p:Pos):T {
		function loop(t:T):T return map(loop, Typeload.maybeBuildInstance(ctx, t, ParamNormal, p));
		return loop(t);
	}

	public static function cloneTypeParameterMap(mapper:T->T, path:GlobalTypePath, ttp:TypedTypeParam):TypedTypeParam {
		var c = core.ds.Record.withFields(ttp.ttpClass, {clPath: path});
		var def = ttp.ttpDefault == null ? null : mapper(ttp.ttpDefault);
		var constraints = ttp.ttpConstraints == null ? null : AtomicLazy.fromFun(function() return ttp.ttpConstraints.force().map(mapper));
		return mkTypeParam(c, ttp.ttpHost, def, constraints);
	}

	public static function cloneTypeParameter(g:GenericContext, mg:ModuleDef, path:GlobalTypePath, ttp:TypedTypeParam):TypedTypeParam {
		var result = cloneTypeParameterMap(function(t) return genericSubstituteType(g, t), path, ttp);
		result.ttpClass.clModule = mg;
		return result;
	}

	public static function buildGenericClass(ctx:Typer, c:TClass, p:Pos, tl:Array<T>):T {
		var recurse = false;
		function checkRecursive(t:T):Void switch follow(t) {
			case TInst(c, tl):
				switch c.clKind {
					case KTypeParameter(_):
						// TPTODO
						// if not (TypeloadCheck.is_generic_parameter ctx c2) && has_ctor_constraint c2 then
						//	raise_typing_error "Type parameters with a constructor cannot be used non-generically" p;
						recurse = true;
					case _:
				}
				for (t in tl) checkRecursive(t);
			case _:
		};
		for (t in tl) checkRecursive(t);
		if (recurse || !ctx.com.display.dmsFullTyping) return TInst(c, tl); // build a normal instance
		var g = makeGeneric(ctx, c.clParams, tl, core.Meta.has(MetaTag.Custom(":debug.generic"), c.clMeta), p);
		var path:core.Globals.GlobalTypePath = {pack: c.clPath.pack, name: c.clPath.name + "_" + g.name};
		try {
			var t = Typeload.loadInstance(ctx, makePtp(mkTypePath(path.pack, path.name), p), ParamNormal, LoadNormal);
			return switch t {
				case TInst({clKind: KGenericInstance(base, _)}, _) if (c == base): t;
				case _: Error.raiseTypingError("Cannot specialize @:generic because the generated type name is already used: "
						+ path.name, p);
			};
		} catch (ex:Dynamic) {
			if (!missingModule(ex, path)) throw ex;
		}
		if (g.genericDebug) {
			Sys.println('[GENERIC] Building @:generic class ${sTypePath(c.clPath)} as ${path.name} with:');
			for (s in g.subst) Sys.println('[GENERIC]   ${s.cls.clPath.name}: ${core.TPrinting.sTypeKind(s.t)}'
				+ (s.expr == null ? "" : " (expr: " + core.TPrinting.sExprDebug(s.expr) + ")"));
		}
		c.clBuild(); // make sure the super class is already setup
		var mg = makeModule(g, c, path);
		var ctx = TyperManager.cloneForModule(ctx.g.rootTyper, TypeloadModule.makeCurmod(ctx.com, ctx.g, mg));
		g.mg = mg;
		var cg = mkClass(mg, path, c.clPos, c.clNamePos);
		ctx = TyperManager.cloneForClass(ctx, c);
		cg.clMeta = c.clMeta.filter(function(m) return switch (m.meta : MetaTag) {
			case MetaTag.Access | Allow | Final | Hack | Keep | KeepSub | NoClosure | NullSafety | Pure | Struct | StructInit | Using | AutoBuild | Unreflective: true;
			case _: false;
		});
		cg.clMeta.unshift({meta: MetaTag.NoDoc, exprs: [], pos: nullPos});
		mg.mTypes = [TClassDecl(cg)];
		ctx.com.moduleLut.add(mg.mPath, mg);
		addDependency(mg, c.clModule, MDepFromTyping);
		addDependency(ctx.m.curmod, mg, MDepFromTyping);
		setTypeParameterDependencies(mg, tl);
		inline function buildField(old:TClassField):TClassField {
			var params = old.cfParams.map(function(ttp) return {
				original: ttp.ttpClass,
				param: cloneTypeParameter(g, mg, {pack: [old.cfName], name: ttp.ttpName}, ttp)
			});
			var localG:GenericContext = core.ds.Record.withFields(g,
				{subst: params.map(function(s) return {cls: s.original, t: s.param.ttpType, expr: null}).concat(g.subst)});
			var field:TClassField = core.ds.Record.withFields(old, {cfExprUnoptimized: null}); // copy
			field.cfParams = params.map(function(s) return s.param);
			inline function f():T {
				follow(old.cfType);
				// We update here because the follow could resolve some TLazy things that end up modifying flags, such as
				// the inferred CfOverride from #11010.
				field.cfFlags = old.cfFlags;
				removeClassFieldFlag(field, CfPostProcessed);
				if (localG.genericDebug) Sys.println("[GENERIC] expanding " + old.cfName);
				var t = genericSubstituteType(localG, old.cfType);
				inline function update(e:TExpr):Void field.cfExpr = genericSubstituteExpr(localG, e);
				if (old.cfExpr != null) update(old.cfExpr);
				else
					// There can be cases like #11152 where cf_expr isn't ready yet. It should be safe to delay this to the end
					// of the PTypeField pass.
					delayLate(ctx.g, PTypeField, function() {
					if (old.cfExpr != null) update(old.cfExpr);
					else switch old.cfKind {
						case Method(_)
							if (!hasClassFlag(c, CInterface) && !hasClassFlag(c, CExtern) && !hasClassFieldFlag(old, CfAbstract)):
							Common.displayErrorExt(ctx.com,
								Error.makeError(Custom('Field ${field.cfName} has no expression (possible typing order issue)'),
									field.cfPos, [Error.makeError(Custom(complMsg("While building " + sTypePath(cg.clPath))), p)]));
						case _:
					}
				});
				if (localG.genericDebug) Sys.println("[GENERIC] " + Printer.sTclassField("  ", field));
				return t;
			}
			var mono = spawnMonomorph(ctx, p);
			var lazy = makeLazy(ctx.g, mono, function() {
				var t = f();
				unifyRaise(t, mono, p);
				linkDynamic(t, mono);
				return mono;
			}, "build_generic_class");
			field.cfType = TLazy(lazy);
			return field;
		}
		if (core.TOther.TClassTools.getClInit(c) != null) Error.raiseTypingError("This class can't be generic", p);
		for (cf in c.clOrderedStatics) switch cf.cfKind {
			case Method(MethMacro) if (!ctx.com.isMacroContext):
			case _:
				Error.raiseTypingError("A generic class can't have static fields", cf.cfPos);
		}
		if (c.clSuper != null) {
			var superType = buildInstances(ctx, follow(applyParams(c.clParams, tl, TInst(c.clSuper.cls, c.clSuper.params))), p);
			cg.clSuper = TypeloadCheck.Inheritance.checkExtends(ctx, c, superType, p);
		} else cg.clSuper = null;
		TypeloadFunction.addConstructor(ctx, cg, false, p);
		cg.clKind = KGenericInstance(c, tl);
		if (hasClassFlag(c, CInterface)) addClassFlag(cg, CInterface);
		if (hasClassFlag(c, CAbstract)) addClassFlag(cg, CAbstract);
		if (c.clConstructor != null) cg.clConstructor = buildField(c.clConstructor);
		else if (cg.clConstructor == null && c.clSuper != null)
			Error.raiseTypingError("Please define a constructor for this class in order to use it as generic", c.clPos);
		cg.clImplements = c.clImplements.map(function(i) return switch follow(genericSubstituteType(g,
			TInst(i.cls, i.params.map(function(t) return genericSubstituteType(g, t))))) {
			case TInst(c, tl): {cls: c, params: tl};
			case _: throw "assert";
		});
		cg.clOrderedFields = c.clOrderedFields.map(function(f) {
			var f = buildField(f);
			cg.clFields.set(f.cfName, f);
			return f;
		});
		// In rare cases the class name can become too long, so let's shorten it (issue #3090).
		if (cg.clPath.name.length > 254) {
			var name = getShortName();
			cg.clMeta.unshift({meta: MetaTag.Native, exprs: [{expr: EConst(String(name, SDoubleQuotes)), pos: p}], pos: nullPos});
		}
		cg.clUsing = c.clUsing;
		if (g.genericDebug) Sys.println("[GENERIC] " + Printer.sTclass("  ", cg));
		return TInst(cg, []);
	}

	public static function extractTypeParameters(tl:Array<T>):TypeParams {
		var params = [];
		function loop(t:T):Void switch follow(t) {
			case TInst({clKind: KTypeParameter(ttp)}, []):
				params.push(ttp);
			case _:
				iter(loop, t);
		};
		for (t in tl) loop(t);
		return params;
	}

	public static function typeGenericFunction(ctx:Typer, fa:context.Typecore.FieldAccess, fcc:FieldCallCandidateData<Void->TExpr>,
			withType:WithTypeValue, p:Pos):TExpr {
		var c:TClass;
		var stat:Bool;
		switch fa.faHost {
			case FHInstance(cls, _):
				c = cls;
				stat = false;
			case FHStatic(cls):
				c = cls;
				stat = true;
			case FHAbstract(_, _, cls):
				c = cls;
				stat = true;
			case _:
				throw "assert";
		}
		var cf:TClassField = fcc.fcField;
		if (cf.cfParams.length == 0) Error.raiseTypingError("Function has no type parameters and cannot be generic", p);
		switch withType {
			case WithType(t, _):
				// In cases like #5482, we might have a return type that still needs expansion.
				unify(ctx, buildInstances(ctx, fcc.fcRet, p), t, p);
			case _:
		}
		var monos:Array<T> = fcc.fcMonos;
		for (t in monos) switch follow(t) {
			case TMono(m):
				safeMonoClose(ctx, m, p);
			case _:
		}
		var args = fcc.fcArgs;
		var g = makeGeneric(ctx, cf.cfParams, monos, core.Meta.has(MetaTag.Custom(":debug.generic"), cf.cfMeta), p);
		var type = buildInstances(ctx, fcc.fcType, p);
		var name = cf.cfName + "_" + g.name;
		var params = extractTypeParameters(monos);
		inline function unifyExisting(t:T, pcf:Pos):Void {
			try {
				unifyRaise(t, type, p);
			} catch (ex:Dynamic) {
				switch ex {
					case(core.ds.ExceptionTools.typing(_) => Some(err = {errMessage: Unify(_)})):
						throw new core.Error.TypingError(core.ds.Record.withFields(err, {
							errSub: [
								Error.makeError(Custom("Cannot create field " + name + " due to type mismatch"), p,
									[Error.makeError(Custom(complMsg("Conflicting field was defined here")), pcf)])
							].concat(err.errSub)
						}));
					case _:
						throw ex;
				}
			}
		}
		var found:Null<TClassField> = (stat ? c.clStatics : c.clFields).get(name);
		if (found != null) {
			unifyExisting(found.cfType, found.cfPos);
			fa = core.ds.Record.withFields(fa, {faField: found});
			/*
				java.Lib.array() relies on the ability to shadow @:generic function for certain types
				see https://github.com/HaxeFoundation/haxe/issues/8393#issuecomment-508685760
			*/
			// if cf.cf_name_pos = cf2.cf_name_pos then
			//	cf2
			// else
			//	error ("Cannot specialize @:generic because the generated function name is already used: " ^ name) p
		} else {
			inline function finalize(cls:TClass, field:TClassField):Void {
				follow(cf.cfType);
				function check(e:TExpr):Void switch e.eexpr {
					case TNew(c = {clKind: KTypeParameter(_)}, _, _) if (!TypeloadCheck.isGenericParameter(ctx, c)):
						Common.displayErrorExt(ctx.com,
							Error.makeError(Custom("Only generic type parameters can be constructed"), e.epos,
								[Error.makeError(Custom(complMsg("While specializing this call")), p)]));
					case _:
						Texpr.iter(check, e);
				};
				if (cf.cfExpr == null) {
					var mappings = [
						for (i in 0...cf.cfParams.length) cf.cfParams[i].ttpName
							+ " = "
							+ core.TPrinting.sType(core.TPrinting.printContext(), monos[i])];
					Common.displayErrorExt(ctx.com, Error.makeError(Custom("Recursive @:generic function"), p, [
						Error.makeError(Custom("Mapping: " + mappings.join(", ")), p),
						Error.makeError(Custom("For function " + sTypePath(cls.clPath) + "." + cf.cfName), p)
					]));
					field.cfExpr = null;
				} else {
					var e = genericSubstituteExpr(g, cf.cfExpr);
					check(e);
					field.cfExpr = e;
				}
				field.cfKind = cf.cfKind;
				if (!hasClassFieldFlag(cf, CfPublic)) removeClassFieldFlag(field, CfPublic);
				var meta = cf.cfMeta.filter(function(m) return !Type.enumEq(m.meta, MetaTag.Generic));
				var zero = mkZeroRangePos(p);
				field.cfMeta = ([
					{meta: MetaTag.NoCompletion, exprs: [], pos: zero},
					{meta: MetaTag.NoUsing, exprs: [], pos: zero},
					{meta: MetaTag.GenericInstance, exprs: [], pos: zero}
				] : Array<core.Ast.MetadataEntry>).concat(meta);
				field.cfParams = params;
			}
			inline function makeField(name:String):TClassField return mkField(name, type, cf.cfPos, cf.cfNamePos, true, stat);
			if (stat && core.Meta.has(MetaTag.GenericClassPerMethod, c.clMeta)) {
				var container = staticMethodContainer(g, c, cf, p);
				setTypeParameterDependencies(container.clModule, monos);
				var field = container.clStatics.get(cf.cfName);
				if (field != null) unifyExisting(field.cfType, field.cfPos);
				else {
					field = makeField(cf.cfName);
					container.clStatics.set(field.cfName, field);
					container.clOrderedStatics.unshift(field);
					finalize(container, field);
				}
				fa = core.ds.Record.withFields(fa,
					{faHost: FHStatic(container), faField: field, faOn: Texpr.Builder.makeStaticThis(container, p)});
			} else if (stat) {
				setTypeParameterDependencies(c.clModule, monos);
				var field = makeField(name);
				c.clStatics.set(field.cfName, field);
				c.clOrderedStatics.unshift(field);
				finalize(c, field);
				fa = core.ds.Record.withFields(fa, {faField: field});
			} else {
				setTypeParameterDependencies(c.clModule, monos);
				var field = makeField(name);
				if (hasClassFieldFlag(cf, CfOverride)) addClassFieldFlag(field, CfOverride);
				c.clFields.set(field.cfName, field);
				c.clOrderedFields.unshift(field);
				finalize(c, field);
				fa = core.ds.Record.withFields(fa, {faField: field});
			}
		}
		return new CallUnification.CallDispatcher(ctx, MCall([]), withType, p).fieldCall(fa, args, []);
	}

	public static function initHooks():Void context.Typecore.typeGenericFunctionRef = typeGenericFunction;

	static function __init__():Void initHooks();
}
