package core;

import Type as StdType;
import core.Globals;
import core.Ast;
import core.TType;
import core.MetaList.StrictMeta;
import core.Meta as MetadataTools;
import core.Ast as AstTools;
import core.ds.AtomicLazy;
import haxe.ds.StringMap;
import haxe.ds.IntMap;
import sys.thread.Mutex;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

// port: from haxe/src/core/tFunctions.ml.
typedef NotFound = core.ds.NotFound;
typedef Exit = core.ds.Exit;

class TypeExit {
	public function new() {}
}

class ApplyParamsRecursion {
	public function new() {}
}

class ApplyParamsMismatch {
	public function new() {}
}

enum MaybeCoro {
	Coro(signature:TSignature);
	NotCoro(type:T);
}

@:structInit class ApplyParamsStack {
	public var value:Array<{subject:T, params:TParams}>;

	public inline function new(value:Array<{subject:T, params:TParams}>) {
		this.value = value;
	}

	public inline function clone():ApplyParamsStack return new ApplyParamsStack(value);
}

@:structInit class RawClassField {
	public var owner:Null<{cls:TClass, params:TParams}>;
	public var type:T;
	public var field:TClassField;

	public inline function new(owner:Null<{cls:TClass, params:TParams}>, type:T, field:TClassField) {
		this.owner = owner;
		this.type = type;
		this.field = field;
	}

	public inline function clone():RawClassField return new RawClassField(owner, type, field);
}

class TFunctions {
	public static var monomorphCreateRef:Void->TMono = function() throw "monomorphCreateRef is uninitialized";
	public static var monomorphBindRef:TMono->T->Void = function(_, _) throw "monomorphBindRef is uninitialized";
	public static var monomorphClassifyConstraintsRef:TMono->TMonoConstraintKind = function(_)
		throw "monomorphClassifyConstraintsRef is uninitialized";

	public static function hasMeta(m:StrictMeta, ml:Metadata):Bool return MetadataTools.has(m, ml);

	public static function getMeta(m:StrictMeta, ml:Metadata):MetadataEntry return MetadataTools.get(m, ml);

	// Flags

	public static function hasFlag(flags:Int, flag:Int):Bool return flags & (1 << flag) > 0;

	public static function setFlag(flags:Int, flag:Int):Int return flags | (1 << flag);

	public static function unsetFlag(flags:Int, flag:Int):Int return flags & ~(1 << flag);

	public static function intOfClassFlag(flag:FlagTClass):Int return StdType.enumIndex(flag);

	public static function addClassFlag(c:TClass, flag:FlagTClass):Void c.clFlags = setFlag(c.clFlags, intOfClassFlag(flag));

	public static function removeClassFlag(c:TClass, flag:FlagTClass):Void c.clFlags = unsetFlag(c.clFlags, intOfClassFlag(flag));

	public static function hasClassFlag(c:TClass, flag:FlagTClass):Bool return hasFlag(c.clFlags, intOfClassFlag(flag));

	public static function intOfClassFieldFlag(flag:FlagTClassField):Int return StdType.enumIndex(flag);

	public static function addClassFieldFlag(cf:TClassField,
			flag:FlagTClassField):Void cf.cfFlags = setFlag(cf.cfFlags, intOfClassFieldFlag(flag));

	public static function removeClassFieldFlag(cf:TClassField,
			flag:FlagTClassField):Void cf.cfFlags = unsetFlag(cf.cfFlags, intOfClassFieldFlag(flag));

	public static function hasClassFieldFlag(cf:TClassField,
			flag:FlagTClassField):Bool return hasFlag(cf.cfFlags, intOfClassFieldFlag(flag));

	public static function intOfEnumFlag(flag:FlagTEnum):Int return StdType.enumIndex(flag);

	public static function addEnumFlag(e:TEnum, flag:FlagTEnum):Void e.eFlags = setFlag(e.eFlags, intOfEnumFlag(flag));

	public static function removeEnumFlag(e:TEnum, flag:FlagTEnum):Void e.eFlags = unsetFlag(e.eFlags, intOfEnumFlag(flag));

	public static function hasEnumFlag(e:TEnum, flag:FlagTEnum):Bool return hasFlag(e.eFlags, intOfEnumFlag(flag));

	public static function intOfVarFlag(flag:FlagTVar):Int return StdType.enumIndex(flag);

	public static function addVarFlag(v:TVar, flag:FlagTVar):Void v.vFlags = setFlag(v.vFlags, intOfVarFlag(flag));

	public static function removeVarFlag(v:TVar, flag:FlagTVar):Void v.vFlags = unsetFlag(v.vFlags, intOfVarFlag(flag));

	public static function hasVarFlag(v:TVar, flag:FlagTVar):Bool return hasFlag(v.vFlags, intOfVarFlag(flag));

	public static function fieldKindEq(a:FieldKind, b:FieldKind):Bool return switch [a, b] {
		case [Var(a), Var(b)]: StdType.enumEq(a.vRead, b.vRead) && StdType.enumEq(a.vWrite, b.vWrite);
		case [Method(a), Method(b)]: StdType.enumEq(a, b);
		case _: false;
	}

	// ======= General utility =======

	// port: Atomic.fetch_and_add counters, as upstream.
	static final varUid = new haxe.atomic.AtomicInt(0);
	static final moduleUid = new haxe.atomic.AtomicInt(0);

	public static function allocVar(kind:TVarKind, n:String, t:T, p:Pos):TVar {
		var id = varUid.add(1) + 1;
		return {
			vKind: kind,
			vName: n,
			vType: t,
			vId: id,
			vExtra: null,
			vMeta: [],
			vPos: p,
			vFlags: switch kind {
				case VUser(TVOLocalFunction): intOfVarFlag(VFinal);
				case _: 0;
			}
		};
	}

	// port: `let uid = fst alloc_var' in Atomic.fetch_and_add uid 1 + 1` (hxb_reader_api_typeload#get_var_id).
	public static function allocVarId():Int return varUid.add(1) + 1;

	public static function allocMid():Int return moduleUid.add(1) + 1;

	public static function mk(e:TExprDef, t:T, p:Pos):TExpr {
		core.ds.GcPolicy.tick();
		return {eexpr: e, etype: t, epos: p};
	}

	public static function mkBlock(e:TExpr):TExpr return switch e.eexpr {
		case TBlock(_): e;
		case _: mk(TBlock(vector(e)), e.etype, e.epos);
	};

	public static function mkCast(e:TExpr, t:T, p:Pos):TExpr return mk(TCast(e, null), t, p);

	// port: `null` is a Haxe keyword.
	public static function nullExpr(t:T, p:Pos):TExpr return mk(TConst(TNull), t, p);

	public static function mkMono():T return TMono(monomorphCreateRef());

	public static final tDynamic:T = TDynamic(null);

	public static function mkAnon(status:AnonStatus,
			?fields:TypeMap<TClassField>):T return TAnon({aFields: fields == null ? new StringMap() : fields, aStatus: status});

	public static function tfun(pl:TParams, r:T):T return TFun({args: pl.map(t -> {name: "", optional: false, type: t}), ret: r});

	public static function funArgs(l:Array<{name:String, defaultValue:Null<TExpr>, type:T}>):Array<{name:String, optional:Bool, type:T}>
		return [for (a in l) {name: a.name, optional: a.defaultValue != null, type: a.type}];

	public static function mkTypedef(m:ModuleDef, path:GlobalTypePath, pos:Pos, namePos:Pos, t:T):TDef return {
		tPath: path,
		tModule: m,
		tPos: pos,
		tNamePos: namePos,
		tPrivate: false,
		tDoc: null,
		tMeta: [],
		tParams: vector(),
		tUsing: [],
		tType: t,
		tRestore: function() {}
	};

	public static function classModuleType(c:TClass):TDef {
		var path:core.Globals.GlobalTypePath = {pack: [], name: "Class<" + Globals.sTypePath(c.clPath) + ">"};
		var t = mkAnon(ClassStatics(c), c.clStatics);
		var def = mkTypedef(c.clModule, path, c.clPos, Globals.nullPos, t);
		def.tPrivate = true;
		return def;
	}

	public static function mkClass(m:ModuleDef, path:GlobalTypePath, pos:Pos, namePos:Pos):TClass {
		var c:TClass = {
			clPath: path,
			clModule: m,
			clPos: pos,
			clNamePos: namePos,
			clDoc: null,
			clMeta: [],
			clPrivate: false,
			clKind: KNormal,
			clFlags: 0,
			clType: tDynamic,
			clParams: vector(),
			clUsing: [],
			clSuper: null,
			clImplements: [],
			clFields: new StringMap(),
			clOrderedStatics: [],
			clOrderedFields: [],
			clStatics: new StringMap(),
			clDynamic: null,
			clArrayAccess: null,
			clConstructor: null,
			clInit: null,
			clBuild: function() return Built,
			clRestore: function() {},
			clDescendants: []
		};
		c.clType = TType(classModuleType(c), vector());
		return c;
	}

	public static function moduleExtra(file:String, sign:String, time:Float, kind:ModuleKind, added:Int,
			policy:Array<ModuleCheckPolicy>):ModuleDefExtra return {
			mFile: core.Path.UniqueKey.createLazy(file),
			mSign: sign,
			mDisplay: {mInlineCalls: [], mTypeHints: [], mImportPositions: new Map()},
			mCacheState: MSGood,
			mAdded: added,
			mChecked: 0,
			mTime: time,
			mProcessed: 0,
			mDeps: new IntMap(),
			mDisplayDeps: null,
			mKind: kind,
			mCacheBoundObjects: [],
			mFeatures: new Map(),
			mCheckPolicy: policy
		};

	public static function mkClassFieldRef(c:TClass, cf:TClassField, kind:ClassFieldRefKind, isMacro:Bool):ClassFieldRef return {
		cfrSign: c.clModule.mExtra.mSign,
		cfrPath: c.clPath,
		cfrField: cf.cfName,
		cfrKind: kind,
		cfrIsMacro: isMacro
	};

	public static function mkField(name:String, t:T, p:Pos, namePos:Pos, isPublic:Bool = true, isStatic:Bool = false):TClassField {
		var flags = isStatic ? setFlag(0, intOfClassFieldFlag(CfStatic)) : 0;
		if (isPublic) flags = setFlag(flags, intOfClassFieldFlag(CfPublic));
		return {
			cfName: name,
			cfType: t,
			cfPos: p,
			cfNamePos: namePos,
			cfDoc: null,
			cfMeta: [],
			cfKind: Var({vRead: AccNormal, vWrite: AccNormal}),
			cfExpr: null,
			cfExprUnoptimized: null,
			cfParams: vector(),
			cfOverloads: [],
			cfFlags: flags
		};
	}

	public static function findMap<V>(map:StringMap<V>, name:String):V {
		if (!map.exists(name)) throw NotFound.raise();
		return map.get(name);
	}

	public static function findField(c:TClass, name:String, kind:ClassFieldRefKind):TClassField {
		var f = switch kind {
			case CfrConstructor: c.clConstructor;
			case CfrStatic: findMap(c.clStatics, name);
			case CfrMember: findMap(c.clFields, name);
			case CfrInit: c.clInit;
		};
		if (f == null) throw NotFound.raise();
		return f;
	}

	// port: digest values use hexadecimal strings in this port (see Define.getSignature).
	public static final nullModule:ModuleDef = {
		mId: allocMid(),
		mPath: {pack: [], name: ""},
		mTypes: [],
		mStatics: null,
		mExtra: moduleExtra("", haxe.crypto.Md5.encode(""), 0, MFake, 0, [])
	};
	public static final nullClass:TClass = makeNullClass();

	static function makeNullClass():TClass {
		var c = mkClass(nullModule, {pack: [], name: ""}, Globals.nullPos, Globals.nullPos);
		c.clPrivate = true;
		return c;
	}

	public static final nullTypedef:TDef = makeNullTypedef();

	static function makeNullTypedef():TDef {
		var t = mkTypedef(nullModule, {pack: [], name: ""}, Globals.nullPos, Globals.nullPos, TDynamic(null));
		t.tPrivate = true;
		return t;
	}

	public static final nullTanon:TAnon = {aFields: new StringMap(), aStatus: Closed};
	public static final nullEnum:TEnum = {
		ePath: {pack: [], name: ""},
		eModule: nullModule,
		ePos: Globals.nullPos,
		eNamePos: Globals.nullPos,
		ePrivate: true,
		eDoc: null,
		eMeta: [],
		eParams: vector(),
		eUsing: [],
		eRestore: function() {},
		eType: tDynamic,
		eFlags: 0,
		eConstrs: new StringMap(),
		eNames: []
	};
	public static final nullField:TClassField = mkField("", tDynamic, Globals.nullPos, Globals.nullPos);
	public static final nullEnumField:TEnumField = {
		efName: "",
		efType: TEnum(nullEnum, vector()),
		efPos: Globals.nullPos,
		efNamePos: Globals.nullPos,
		efDoc: null,
		efIndex: 0,
		efParams: vector(),
		efMeta: []
	};
	public static final nullAbstract:TAbstract = {
		aPath: {pack: [], name: ""},
		aModule: nullModule,
		aPos: Globals.nullPos,
		aNamePos: Globals.nullPos,
		aPrivate: true,
		aDoc: null,
		aMeta: [],
		aParams: vector(),
		aUsing: [],
		aRestore: function() {},
		aOps: [],
		aUnops: [],
		aImpl: null,
		aThis: tDynamic,
		aFrom: [],
		aFromField: [],
		aTo: [],
		aToField: [],
		aArray: [],
		aRead: null,
		aWrite: null,
		aCall: null,
		aConstructor: null,
		aExtern: false,
		aEnum: false
	};

	public static function createDependency(mdep:ModuleDef, origin:ModuleDepOrigin):ModuleDep return {
		mdSign: mdep.mExtra.mSign,
		mdPath: mdep.mPath,
		mdKind: mdep.mExtra.mKind,
		mdOrigin: origin
	};

	public static final addDependencyMutex = new Mutex();

	public static function addDependency(m:ModuleDef, mdep:ModuleDef, origin:ModuleDepOrigin, skipPostprocess:Bool = false):Void {
		switch origin {
			// These module dependency origins should not add as a dependency
			case MDepFromMacroInclude:
				return;
			case _:
		}
		if (m != nullModule && mdep != nullModule && (m.mPath != mdep.mPath || m.mExtra.mSign != mdep.mExtra.mSign)) {
			addDependencyMutex.acquire();
			try {
				m.mExtra.mDeps.set(mdep.mId, createDependency(mdep, origin));
				// In case the module is cached, we'll have to run post-processing on it again (issue #10635)
				if (!skipPostprocess) m.mExtra.mProcessed = 0;
			} catch (e:haxe.Exception) {
				addDependencyMutex.release();
				throw e;
			}
			addDependencyMutex.release();
		}
	}

	public static function argName(a:{variable:TVar, defaultValue:Null<TExpr>}):String return a.variable.vName;

	// port: OCaml overlays the common leading record fields. Haxe needs explicit projections.
	public static function tInfos(t:ModuleType):TInfos return switch t {
		case TClassDecl(c): {
				mtPath: c.clPath,
				mtModule: c.clModule,
				mtPos: c.clPos,
				mtNamePos: c.clNamePos,
				mtPrivate: c.clPrivate,
				mtDoc: c.clDoc,
				mtMeta: c.clMeta,
				mtParams: c.clParams,
				mtUsing: c.clUsing,
				mtRestore: c.clRestore
			};
		case TEnumDecl(e): {
				mtPath: e.ePath,
				mtModule: e.eModule,
				mtPos: e.ePos,
				mtNamePos: e.eNamePos,
				mtPrivate: e.ePrivate,
				mtDoc: e.eDoc,
				mtMeta: e.eMeta,
				mtParams: e.eParams,
				mtUsing: e.eUsing,
				mtRestore: e.eRestore
			};
		case TTypeDecl(t): {
				mtPath: t.tPath,
				mtModule: t.tModule,
				mtPos: t.tPos,
				mtNamePos: t.tNamePos,
				mtPrivate: t.tPrivate,
				mtDoc: t.tDoc,
				mtMeta: t.tMeta,
				mtParams: t.tParams,
				mtUsing: t.tUsing,
				mtRestore: t.tRestore
			};
		case TAbstractDecl(a): {
				mtPath: a.aPath,
				mtModule: a.aModule,
				mtPos: a.aPos,
				mtNamePos: a.aNamePos,
				mtPrivate: a.aPrivate,
				mtDoc: a.aDoc,
				mtMeta: a.aMeta,
				mtParams: a.aParams,
				mtUsing: a.aUsing,
				mtRestore: a.aRestore
			};
	};

	// port: direct switch: tInfos allocates its record on every call.
	public static function tPath(t:ModuleType):GlobalTypePath return switch t {
		case TClassDecl(c): c.clPath;
		case TEnumDecl(e): e.ePath;
		case TTypeDecl(t): t.tPath;
		case TAbstractDecl(a): a.aPath;
	};

	public static function tModule(t:ModuleType):ModuleDef return switch t {
		case TClassDecl(c): c.clModule;
		case TEnumDecl(e): e.eModule;
		case TTypeDecl(t): t.tModule;
		case TAbstractDecl(a): a.aModule;
	};

	public static function tPrivate(t:ModuleType):Bool return switch t {
		case TClassDecl(c): c.clPrivate;
		case TEnumDecl(e): e.ePrivate;
		case TTypeDecl(t): t.tPrivate;
		case TAbstractDecl(a): a.aPrivate;
	};

	public static function tName(t:ModuleType):String return tPath(t).name;

	public static function extendsClass(c:TClass, csup:TClass):Bool {
		if (c == csup) return true;
		for (i in c.clImplements) if (extendsClass(i.cls, csup)) return true;
		return c.clSuper != null && extendsClass(c.clSuper.cls, csup);
	}

	public static function addDescendant(c:TClass, descendant:TClass):Void c.clDescendants.unshift(descendant);

	public static var lazyForceHook:(Void->T) -> T = function(f) return f();

	public static function lazyType(f:TLazy):T return switch f.value {
		case LAvailable(t) | LProcessing(t): t;
		case LWait(f): lazyForceHook(f);
	};

	public static function lazyAvailable(t:T):TLazyState return LAvailable(t);

	public static function lazyProcessing(t:T):TLazyState return LProcessing(t);

	public static function lazyWait(f:Void->T):TLazyState return LWait(f);

	public static function map(loop:T->T, t:T):T return switch t {
		case TMono(r): r.tmType == null ? t : loop(r.tmType); // erase
		case TEnum(_, []) | TInst(_, []) | TType(_, []) | TAbstract(_, []): t;
		case TEnum(e, tl): TEnum(e, tl.map(loop));
		case TInst(c, tl): TInst(c, tl.map(loop));
		case TType(td, tl): TType(td, tl.map(loop));
		case TAbstract(a, tl): TAbstract(a, tl.map(loop));
		case TFun(s): TFun({args: s.args.map(a -> {name: a.name, optional: a.optional, type: loop(a.type)}), ret: loop(s.ret)});
		case TAnon(a):
			var fields = new StringMap<TClassField>();
			for (name => f in a.aFields) {
				var copy:TClassField = core.ds.Record.copy(f);
				copy.cfType = loop(f.cfType);
				fields.set(name, copy);
			}
			TAnon(core.TType.TAnon.withStatusRef(fields, a.aStatusRef));
		case TLazy(f):
			var ft = lazyType(f);
			var ft2 = loop(ft);
			ft == ft2 ? t : ft2;
		case TDynamic(null): t;
		case TDynamic(t2): TDynamic(loop(t2));
	};

	public static function iter(loop:T->Void, t:T):Void switch t {
		case TMono(r):
			if (r.tmType != null) loop(r.tmType);
		case TEnum(_, tl) | TInst(_, tl) | TType(_, tl) | TAbstract(_, tl):
			for (t in tl) loop(t);
		case TFun(s):
			for (a in s.args) loop(a.type);
			loop(s.ret);
		case TAnon(a):
			for (f in a.aFields) loop(f.cfType);
		case TLazy(f):
			loop(lazyType(f));
		case TDynamic(null):
		case TDynamic(t):
			loop(t);
	};

	public static function duplicate(t:T):T {
		var monos:Array<{old:T, replacement:T}> = [];
		function loop(t:T):T return switch t {
			case TMono({tmType: null}):
				var found:Null<T> = null;
				for (p in monos) if (p.old == t) {
					found = p.replacement;
					break;
				}
				if (found != null) found else {
					var m = mkMono();
					monos.unshift({old: t, replacement: m});
					m;
				}
			case _: map(loop, t);
		};
		return loop(t);
	}

	public static function dynamifyMonos(t:T):T {
		function loop(t:T):T return switch t {
			case TMono({tmType: null}): tDynamic;
			case _: map(loop, t);
		};
		return loop(t);
	}

	// substitute parameters with other types
	public static function applyParams(cparams:TypeParams, params:TParams, t:T, ?stack:ApplyParamsStack):T {
		if (cparams.length == 0) return t;
		if (cparams.length != params.length) throw new ApplyParamsMismatch();
		var subst = [for (i in 0...cparams.length) {cls: cparams[i].ttpClass, type: params[i]}];
		function loop(t:T):T return switch t {
			case TMono(r): r.tmType == null ? t : loop(r.tmType);
			case TEnum(_, []) | TType(_, []) | TAbstract(_, []): t;
			case TEnum(e, tl): TEnum(e, tl.map(loop));
			case TType(td, tl):
				var applied = tl.map(loop);
				if (stack != null) {
					// E.g.:
					// ```
					// typedef Rec<T> = { function method():Rec<Array<T>> }
					// ```
					// We need to make sure that we are not applying the result of previous
					// application to the same place, which would mean the result of current
					// application would go into `apply_params` again and then again and so on.
					//
					// Argument `stack` holds all previous results of `apply_params` to typedefs in current
					// unification process.
					//
					// Imagine we are trying to unify `Rec<Int>` with something.
					//
					// Once `apply_params Array<T> Int Rec<Array<T>>` is called for the first time the result
					// will be `Rec< Array<Int> >`. Store `Array<Int>` into `stack`
					//
					// Then the next params application looks like this:
					// 	`apply_params Array<T> Array<Int> Rec<Array<T>>`
					// Notice the second argument is actually the result of a previous `apply_params` call.
					// And the result of the current call is `Rec< Array<Array<Int>> >`.
					//
					// The third call would be:
					// 	`apply_params Array<T> Array<Array<Int>> Rec<Array<T>>`
					// and so on.
					//
					// To stop infinite params application we need to check that we are trying to apply params
					// produced by the previous `apply_params Array<Int> _ Rec<Array<T>>` to the same `Rec<Array<T>>`
					//
					// `old.subject == t`: Check the place that we're applying to is the same `Rec<Array<T>>`
					// `old.params == params`: Check that params we're applying are the same params
					// produced by the previous call to `apply_params Array<T> _ Rec<Array<T>>`
					for (old in stack.value) if (old.subject == t && old.params == params) throw new ApplyParamsRecursion();
					stack.value.unshift({subject: t, params: applied});
				}
				TType(td, applied);
			case TAbstract(a, tl): TAbstract(a, tl.map(loop));
			case TInst(c, []) if (c.clKind.match(KTypeParameter(_))):
				var result = t;
				for (s in subst) if (s.cls == c) {
					result = s.type;
					break;
				}
				result;
			case TInst(_, []): t;
			case TInst(c, [TMono(r)]) if (r.tmType != null && t == r.tmType):
				// for dynamic
				var pt = mkMono();
				var result = TInst(c, vector(pt));
				switch pt {
					case TMono(r): monomorphBindRef(r, result);
					case _: throw "Expected monomorph";
				}
				result;
			case TInst(c, tl): TInst(c, tl.map(loop));
			case _: map(loop, t);
		};
		return loop(t);
	}

	public static function applyTypedef(td:TDef, tl:TParams):T return applyParams(td.tParams, tl, td.tType);

	public static function monomorphs(eparams:TypeParams, t:T):T return applyParams(eparams, eparams.map(_ -> mkMono()), t);

	public static function tryApplyParamsRec(stack:ApplyParamsStack, cparams:TypeParams, params:TParams, t:T, success:T->Void):Void {
		var oldStack = stack.value;
		stack.value = oldStack.copy();
		try success(applyParams(cparams, params, t, stack))
		catch (_:ApplyParamsRecursion) {
			stack.value = oldStack;
			return;
		} catch (e:haxe.Exception) {
			stack.value = oldStack;
			throw e;
		}
		stack.value = oldStack;
	}

	static function isNullPath(a:TAbstract):Bool return a.aPath.pack.length == 0 && a.aPath.name == "Null";

	public static function follow(t:T):T return switch t {
		case TMono(r): r.tmType == null ? t : follow(r.tmType);
		case TLazy(f): follow(lazyType(f));
		case TType(td, tl): follow(applyTypedef(td, tl));
		case TAbstract(a, [t]) if (isNullPath(a)): follow(t);
		case _: t;
	};

	public static function followLazy(t:T):T return switch t {
		case TLazy(f): followLazy(lazyType(f));
		case _: t;
	};

	public static function followOnce(t:T):T return switch t {
		case TMono(r): r.tmType == null ? t : r.tmType;
		case TType(td, tl): applyTypedef(td, tl);
		case TLazy(f): lazyType(f);
		case _: t;
	};

	public static function followWithoutNull(t:T):T return switch t {
		case TMono(r): r.tmType == null ? t : followWithoutNull(r.tmType);
		case TLazy(f): followWithoutNull(lazyType(f));
		case TType(td, tl): followWithoutNull(applyTypedef(td, tl));
		case _: t;
	};

	public static function followWithoutType(t:T):T return switch t {
		case TMono(r): r.tmType == null ? t : followWithoutType(r.tmType);
		case TLazy(f): followWithoutType(lazyType(f));
		case TAbstract(a, [t]) if (isNullPath(a)): followWithoutType(t);
		case _: t;
	};

	public static function followLazyAndMono(t:T):T return switch t {
		case TMono({tmType: t}) if (t != null): followLazyAndMono(t);
		case TLazy(f): followLazyAndMono(lazyType(f));
		case _: t;
	};

	public static function followWithCoro(t:T):MaybeCoro return switch follow(t) {
		case TAbstract(a, [t]) if (a.aPath.pack.join(".") == "haxe.coro" && a.aPath.name == "Coroutine"):
			switch follow(t) {
				case TFun(s): Coro(s);
				case t: NotCoro(t);
			}
		case t: NotCoro(t);
	};

	public static function ambiguateFuns(t:T):T return switch follow(t) {
		case TFun(_): TFun({args: vector(), ret: tDynamic});
		case _: map(ambiguateFuns, t);
	};

	public static function isNullableMono(m:TMono):Bool {
		for (modifier in m.tmModifiers) if (modifier.match(MNullable(_))) return true;
		return false;
	}

	public static function isNullable(t:T, noLazy:Bool = false):Bool return switch t {
		case TMono(r): r.tmType == null ? isNullableMono(r) : isNullable(r.tmType, noLazy);
		case TAbstract(a, [_]) if (isNullPath(a)): true;
		case TLazy(f): switch f.value {
				case LAvailable(t): isNullable(t, noLazy);
				case _ if (noLazy): throw new TypeExit();
				case _: isNullable(lazyType(f));
			}
		case TType(td, tl): isNullable(applyTypedef(td, tl), noLazy);
		case TFun(_): false;
		// Type parameters will most of the time be nullable objects, so we don't want to make it hard for users
		// to have to specify Null<T> all over the place, so while they could be a basic type, let's assume they will not.
		//
		// This will still cause issues with inlining and haxe.rtti.Generic. In that case proper explicit Null<T> is required to
		// work correctly with basic types. This could still be fixed by redoing a nullability inference on the typed AST.
		//
		// | TInst ({ cl_kind = KTypeParameter },_) -> false
		case TAbstract(a, _) if (MetadataTools.has(MetadataTools.CoreType, a.aMeta)): !MetadataTools.has(MetadataTools.NotNull, a.aMeta);
		case TAbstract(a, tl): !MetadataTools.has(MetadataTools.NotNull, a.aMeta) && isNullable(applyParams(a.aParams, tl, a.aThis));
		case _: true;
	};

	public static function isNull(t:T, noLazy:Bool = false):Bool return switch t {
		case TMono(r): r.tmType == null ? isNullableMono(r) : isNull(r.tmType, noLazy);
		case TAbstract(a, [t]) if (isNullPath(a)): !isNullable(follow(t), noLazy);
		case TLazy(f): switch f.value {
				case LAvailable(t): isNull(t, noLazy);
				case _ if (noLazy): throw new TypeExit();
				case _: isNull(lazyType(f));
			}
		case TType(td, tl): isNull(applyTypedef(td, tl), noLazy);
		case _: false;
	};

	// Determines if we have a Null<T>. Unlike is_null, this returns true even if the wrapped type is nullable itself.
	public static function isExplicitNull(t:T):Bool return switch t {
		case TMono(r): r.tmType == null ? isNullableMono(r) : isExplicitNull(r.tmType);
		case TAbstract(a, [_]) if (isNullPath(a)): true;
		case TLazy(f): isExplicitNull(lazyType(f));
		case TType(td, tl): isExplicitNull(applyTypedef(td, tl));
		case _: false;
	};

	public static function hasMono(t:T):Bool return switch t {
		case TMono(r): r.tmType == null || hasMono(r.tmType);
		case TInst(_, pl) | TEnum(_, pl) | TAbstract(_, pl) | TType(_, pl): core.ds.ArrayTools.exists(pl, hasMono);
		case TDynamic(_): false;
		case TFun(s): hasMono(s.ret) || core.ds.ArrayTools.exists(s.args, function(a) return hasMono(a.type));
		case TAnon(a):
			var result = false;
			for (cf in a.aFields) result = hasMono(cf.cfType) || result;
			result;
		case TLazy(f): hasMono(lazyType(f));
	};

	public static function concat(e1:TExpr, e2:TExpr):TExpr {
		var e = switch [e1.eexpr, e2.eexpr] {
			case [TBlock(el1), TBlock(el2)]: TBlock(el1.concat(el2));
			case [TBlock(el), _]: TBlock(el.snoc(e2));
			case [_, TBlock(el)]: TBlock(VectorTools.cons(e1, el));
			case _: TBlock(vector(e1, e2));
		};
		return mk(e, e2.etype, AstTools.punion(e1.epos, e2.epos));
	}

	public static function extractParamType(tp:TypedTypeParam):T return tp.ttpType;

	public static function extractParamTypes(params:TypeParams):TParams return params.map(extractParamType);

	public static function extractParamName(tp:TypedTypeParam):String return tp.ttpName;

	public static function lookupParam(n:String, l:TypeParams):T {
		for (tp in l) if (n == tp.ttpName) return tp.ttpType;
		throw NotFound.raise();
	}

	public static function mkTypeParam(c:TClass, host:TypeParamHost, def:Null<T>, constraints:Null<AtomicLazy<TParams>>):TypedTypeParam {
		var ttp:TypedTypeParam = {
			ttpName: c.clPath.name,
			ttpType: TInst(c, vector()),
			ttpClass: c,
			ttpHost: host,
			ttpConstraints: constraints,
			ttpDefault: def
		};
		c.clKind = KTypeParameter(ttp);
		return ttp;
	}

	public static function typeOfModuleType(t:ModuleType):T return switch t {
		case TClassDecl(c): TInst(c, extractParamTypes(c.clParams));
		case TEnumDecl(e): TEnum(e, extractParamTypes(e.eParams));
		case TTypeDecl(t): TType(t, extractParamTypes(t.tParams));
		case TAbstractDecl(a): TAbstract(a, extractParamTypes(a.aParams));
	};

	public static function moduleTypeOfType(t:T):ModuleType return switch t {
		case TInst(c, _): TClassDecl(c);
		case TEnum(e, _): TEnumDecl(e);
		case TType(t, _): TTypeDecl(t);
		case TAbstract(a, _): TAbstractDecl(a);
		case TLazy(f): moduleTypeOfType(lazyType(f));
		// port: upstream raises Exit (not TypeExit) here; callers convert it to Not_found.
		case TMono(r):
			if (r.tmType == null) throw Exit.raise();
			moduleTypeOfType(r.tmType);
		case TAnon(a): switch a.aStatus {
				case ClassStatics(c): TClassDecl(c);
				case EnumStatics(e): TEnumDecl(e);
				case AbstractStatics(a): TAbstractDecl(a);
				case _: throw Exit.raise();
			}
		case _: throw Exit.raise();
	};

	public static function tconstToConst(c:TConstant):Constant return switch c {
		case TInt(i): Int(Std.string(i), null);
		case TFloat(s): Float(s, null);
		case TString(s): String(s, SDoubleQuotes);
		case TBool(b): Ident(b ? "true" : "false");
		case TNull: Ident("null");
		case TThis: Ident("this");
		case TSuper: Ident("super");
	};

	public static function getConstraints(ttp:TypedTypeParam):TParams return ttp.ttpConstraints == null ? vector() : ttp.ttpConstraints.force();

	public static function hasCtorConstraint(c:TClass):Bool return switch c.clKind {
		case KTypeParameter(ttp): core.ds.ArrayTools.exists(getConstraints(ttp), function(t) return switch follow(t) {
				case TAnon(a) if (a.aFields.exists("new")): true;
				case TAbstract(a, _) if (a.aPath.pack.join(".") == "haxe" && a.aPath.name == "Constructible"): true;
				case _: false;
			});
		case _: false;
	};

	// ======= Field utility =======

	public static function fieldName(f:TFieldAccess):String return switch f {
		case FAnon(f) | FInstance(_, _, f) | FStatic(_, f) | FClosure(_, f): f.cfName;
		case FEnum(_, f): f.efName;
		case FDynamic(n): n;
	};

	public static function extractField(f:TFieldAccess):Null<TClassField> return switch f {
		case FAnon(f) | FInstance(_, _, f) | FStatic(_, f) | FClosure(_, f): f;
		case _: null;
	};

	public static function isPhysicalVarField(f:TClassField):Bool return switch f.cfKind {
		case Var(v): switch [v.vRead, v.vWrite] {
				case [AccNormal | AccInline | AccNo, _] | [_, AccNormal | AccNo]: true;
				case _: MetadataTools.has(MetadataTools.IsVar, f.cfMeta);
			}
		case _: false;
	};

	public static function isPhysicalField(f:TClassField):Bool return f.cfKind.match(Method(_)) || isPhysicalVarField(f);

	public static function fieldType(f:TClassField):T return f.cfParams.length == 0 ? f.cfType : monomorphs(f.cfParams, f.cfType);

	public static function rawClassField(buildType:TClassField->T, c:TClass, tl:TParams, i:String):RawClassField {
		var apply = function(t) return applyParams(c.clParams, tl, t);
		try {
			var f = findMap(c.clFields, i);
			return {owner: {cls: c, params: tl}, type: buildType(f), field: f};
		} catch (_:NotFound) {}
		try {
			if (c.clConstructor == null || i != "new") throw NotFound.raise();
			return {owner: {cls: c, params: tl}, type: buildType(c.clConstructor), field: c.clConstructor};
		} catch (_:NotFound) {}
		try {
			if (c.clSuper == null) throw NotFound.raise();
			var sup = c.clSuper;
			var result = rawClassField(buildType, sup.cls, sup.params.map(apply), i);
			return {owner: result.owner, type: applyParams(sup.cls.clParams, sup.params, result.type), field: result.field};
		} catch (_:NotFound) {}
		switch c.clKind {
			case KTypeParameter(ttp):
				for (t in getConstraints(ttp)) switch follow(t) {
					case TAnon(a): try {
							var f = findMap(a.aFields, i);
							return {owner: null, type: buildType(f), field: f};
						} catch (_:NotFound) {}
					case TInst(c, tl): try {
							var result = rawClassField(buildType, c, tl.map(apply), i);
							return {owner: result.owner, type: applyParams(c.clParams, tl, result.type), field: result.field};
						} catch (_:NotFound) {}
					case _:
				}
			case _:
				if (!hasClassFlag(c, CInterface)) throw NotFound.raise();
				// an interface can implements other interfaces without
				// having to redeclare its fields
				for (impl in c.clImplements) try {
					var result = rawClassField(buildType, impl.cls, impl.params.map(apply), i);
					return {owner: result.owner, type: applyParams(impl.cls.clParams, impl.params, result.type), field: result.field};
				} catch (_:NotFound) {}
		}
		throw NotFound.raise();
	}

	public static function classField(c:TClass, tl:TParams, i:String):RawClassField return rawClassField(fieldType, c, tl, i);

	public static function quickField(t:T, n:String):TFieldAccess return switch follow(t) {
		case TInst(c, tl):
			var result = rawClassField(function(f) return f.cfType, c, tl, n);
			result.owner == null ? FAnon(result.field) : FInstance(result.owner.cls, result.owner.params, result.field);
		case TAnon(a): switch a.aStatus {
				case EnumStatics(e): FEnum(e, findMap(e.eConstrs, n));
				case ClassStatics(c): FStatic(c, findMap(c.clStatics, n));
				case AbstractStatics(a):
					if (a.aImpl == null) throw NotFound.raise();
					FStatic(a.aImpl, findMap(a.aImpl.clStatics, n)); // is that right?
				case _: FAnon(findMap(a.aFields, n));
			}
		case TDynamic(_): FDynamic(n);
		case TEnum(_) | TMono(_) | TAbstract(_, _) | TFun(_): throw NotFound.raise();
		case TLazy(_) | TType(_, _): throw "Unexpected unresolved field type";
	};

	public static function quickFieldDynamic(t:T, s:String):TFieldAccess {
		try return quickField(t, s)
		catch (_:NotFound) return FDynamic(s);
	}

	public static function getConstructorClass(c:TClass, tl:TParams):{field:TClassField, cls:TClass, params:TParams} {
		if (c.clConstructor != null) return {field: c.clConstructor, cls: c, params: tl};
		if (c.clSuper == null) throw NotFound.raise();
		return getConstructorClass(c.clSuper.cls, c.clSuper.params.map(function(t) return applyParams(c.clParams, tl, t)));
	}

	public static function getConstructor(c:TClass):TClassField {
		if (c.clConstructor != null) return c.clConstructor;
		if (c.clSuper == null) throw NotFound.raise();
		return getConstructor(c.clSuper.cls);
	}

	public static function hasConstructor(c:TClass):Bool {
		try {
			getConstructor(c);
			return true;
		} catch (_:NotFound) return false;
	}

	public static function isModuleFieldsClass(c:TClass):Bool return c.clKind.match(KModuleFields(_));

	public static function isPosOutsideClass(c:TClass,
			p:Pos):Bool return p.pfile != c.clPos.pfile || p.pmax < c.clPos.pmin || p.pmin > c.clPos.pmax;

	public static function resolveTypedef(t:ModuleType):ModuleType return switch t {
		case TTypeDecl(td): switch follow(td.tType) {
				case TEnum(e, _): TEnumDecl(e);
				case TInst(c, _): TClassDecl(c);
				case TAbstract(a, _): TAbstractDecl(a);
				case _: t;
			}
		case _: t;
	};

	/**
		Check if type `t` has meta `m`.
		Does not follow typedefs, monomorphs etc.
	**/
	public static function typeHasMeta(t:T, m:StrictMeta):Bool return switch t {
		case TEnum(e, _): hasMeta(m, e.eMeta);
		case TInst(c, _): hasMeta(m, c.clMeta);
		case TType(td, _): hasMeta(m, td.tMeta);
		case TAbstract(a, _): hasMeta(m, a.aMeta);
		case _: false;
	};

	// tvar

	public static function varExtra(params:TypeParams, e:Null<TExpr>):TVarExtra return {vParams: params, vExpr: e};

	public static function enumModuleType(en:TEnum):TDef {
		var t = mkTypedef(en.eModule, {pack: [], name: "Enum<" + Globals.sTypePath(en.ePath) + ">"}, en.ePos, Globals.nullPos,
			mkAnon(EnumStatics(en)));
		t.tPrivate = true;
		return t;
	}

	public static function abstractModuleType(a:TAbstract, tl:TParams):TDef {
		var t = mkTypedef(a.aModule, {pack: [], name: "Abstract<" + Globals.sTypePath(a.aPath) + ">"}, a.aPos, Globals.nullPos,
			mkAnon(AbstractStatics(a)));
		t.tPrivate = true;
		return t;
	}

	public static function classFieldOfEnumField(ef:TEnumField):TClassField {
		var cf = mkField(ef.efName, ef.efType, ef.efPos, ef.efNamePos);
		cf.cfKind = switch follow(ef.efType) {
			case TFun(_): Method(MethNormal);
			case _: Var({vRead: AccNormal, vWrite: AccNo});
		};
		cf.cfDoc = ef.efDoc;
		cf.cfParams = ef.efParams;
		return cf;
	}
}
