/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

package filters;

import core.Ast;
import core.TType;
import core.TFunctions as TypeOps;
import core.Globals;
import core.Meta;
import core.Define;
import core.Timer;
import core.Texpr;
import context.Common;
import context.DumpConfig.DumpStage;
import context.SafeCom;
import core.ds.TaskPool;
import context.Parallel;
import core.Error;
import core.TUnification.Monomorph;
import context.AbstractCast;
import typing.Finalization;
import context.display.DeprecationCheck;
import typing.NullSafety;
import core.Native;
import codegen.Genxml;
import codegen.Dump;
import filters.safe.AddFieldInits;
import filters.safe.AddFinalReturn;
import filters.safe.CapturedVars;
import filters.safe.CheckVarInit;
import filters.safe.LocalStatic;
import filters.safe.SafeFilters;
import filters.safe.Sanitize;
import filters.exception.Exceptions;
import filters.exception.SaveStacks;
import optimization.Analyzer;
import optimization.Dce;
import optimization.Optimizer;
import optimization.InlineConstructors;
import haxe.ds.StringMap;
import core.ds.VectorTools.vector;

// port: save_class_state: the saved fields of one class field (mk_field_restore)
private typedef FieldRestoreState = {name:String, kind:FieldKind, expr:Null<TExpr>, type:T, meta:Metadata, params:TypeParams};
private typedef FieldRestore = {field:TClassField, state:FieldRestoreState, overloads:Array<{field:TClassField, state:FieldRestoreState}>};

class Filters {
	public static function getNativeName(meta:Metadata):{name:String, pos:Pos}
		return Native.getNativeName(meta);

	// PASS 2 begin

	// Applies exclude macro (which turns types into externs)
	public static function applyMacroExclude(t:ModuleType):Void switch t {
		case TClassDecl(c) if (TypeOps.hasClassFlag(c, CExcluded)):
			TypeOps.addClassFlag(c, CExtern);
		case TEnumDecl(e) if (TypeOps.hasEnumFlag(e, EnExcluded)):
			TypeOps.addEnumFlag(e, EnExtern);
		case _:
	}

	// Removes extern and macro fields, also checks for Void fields
	public static function removeExternFields(scom:SafeContext, t:ModuleType):Void switch t {
		case TClassDecl(c):
			if (!Define.defined(scom.defines, Define.DocGen)) {
				c.clOrderedFields = c.clOrderedFields.filter(function(f) {
					var b = FilterContext.isRemovableField(scom.isMacroContext, f);
					if (b) c.clFields.remove(f.cfName);
					return !b;
				});
				c.clOrderedStatics = c.clOrderedStatics.filter(function(f) {
					var b = FilterContext.isRemovableField(scom.isMacroContext, f);
					if (b) c.clStatics.remove(f.cfName);
					return !b;
				});
			}
		case _:
	}

	// PASS 2 end

	// PASS 3 begin

	// Checks if a private class' path clashes with another path
	public static function checkPrivatePath(com:CommonContext, t:ModuleType):Void switch t {
		case TClassDecl(c) if (c.clPrivate):
			var rpath:core.Globals.GlobalTypePath = {pack: c.clModule.mPath.pack, name: "_" + c.clModule.mPath.name};
			if (com.moduleLut.getTypeLut()
				.mem(rpath)) Error.raiseTypingError("This private class name will clash with " + Globals.sTypePath(rpath), c.clPos);
		case _:
	}

	// Adds the __rtti field if required
	public static function addRtti(scom:SafeContext, t:ModuleType):Void {
		function hasRtti(c:TClass):Bool return Meta.has(Rtti, c.clMeta) || c.clSuper != null && hasRtti(c.clSuper.cls);
		switch t {
			case TClassDecl(c) if (hasRtti(c) && !c.clStatics.exists("__rtti")):
				var f = TypeOps.mkField("__rtti", scom.basic.tstring, c.clPos, Globals.nullPos, true, true);
				var str = Genxml.genTypeString(t);
				f.cfExpr = TypeOps.mk(TConst(TString(str)), f.cfType, c.clPos);
				c.clOrderedStatics.unshift(f);
				c.clStatics.set(f.cfName, f);
			case _:
		}
	}

	// Adds the __meta__ field if required
	public static function addMetaField(com:CommonContext, t:ModuleType):Void switch t {
		case TClassDecl(c):
			var e = Texpr.buildMetadata(com.basic, t);
			if (e != null) {
				Common.addFeature(com, "has_metadata");
				var cf = TypeOps.mkField("__meta__", e.etype, e.epos, Globals.nullPos, true, true);
				cf.cfExpr = e;
				if (TypeOps.hasClassFlag(c, CInterface) && com.platform == Jvm) {
					// borrowed from gencommon, but I did wash my hands afterwards
					var path:core.Globals.GlobalTypePath = {pack: c.clPath.pack, name: c.clPath.name + "_HxMeta"};
					var ncls = TypeOps.mkClass(c.clModule, path, c.clPos, Globals.nullPos);
					ncls.clOrderedStatics.unshift(cf);
					ncls.clStatics.set(cf.cfName, cf);
					com.types = (cast com.types : Array<ModuleType>).concat([TClassDecl(ncls)]);
					c.clMeta = ([{meta: Custom(":hasMetadata"), exprs: vector(), pos: e.epos}] : Array<core.Ast.MetadataEntry>).concat(c.clMeta);
				} else {
					c.clOrderedStatics.unshift(cf);
					c.clStatics.set(cf.cfName, cf);
				}
			}
		case _:
	}

	// Removes interfaces tagged with @:remove metadata
	public static function checkRemoveMetadata(t:ModuleType):Void switch t {
		case TClassDecl(c):
			c.clImplements = c.clImplements.filter(c -> !Meta.has(Remove, c.cls.clMeta));
		case _:
	}

	// Checks for Void class fields
	public static function checkVoidField(t:ModuleType):Void {
		inline function check(f:TClassField):Void switch TypeOps.follow(f.cfType) {
			case TAbstract({aPath: {pack: [], name: "Void"}}, _):
				Error.raiseTypingError("Fields of type Void are not allowed", f.cfPos);
			case _:
		}
		switch t {
			case TClassDecl(c):
				for (f in c.clOrderedFields) check(f);
				for (f in c.clOrderedStatics) check(f);
			case _:
		}
	}

	// Interfaces have no 'super', but can extend many other interfaces.
	// This makes the first extended (implemented) interface the super for efficiency reasons (you can get one for 'free')
	// and leaves the remaining ones as 'implemented'
	public static function promoteFirstInterfaceToSuper(t:ModuleType):Void switch t {
		case TClassDecl(c) if (TypeOps.hasClassFlag(c, CInterface)):
			if (c.clImplements.length > 0) switch c.clImplements[0].cls.clPath {
				case {pack: ["cpp", "rtti"]}:
				case _:
					c.clSuper = c.clImplements[0];
					c.clImplements = c.clImplements.slice(1);
			}
		case _:
	}

	public static function commitFeatures(com:CommonContext, t:ModuleType):Void {
		for (k in TypeOps.tModule(t).mExtra.mFeatures.keys()) Common.addFeature(com, k);
	}

	public static function checkReservedTypePaths(scom:SafeContext, t:ModuleType):Void {
		inline function check(path:GlobalTypePath, pos:Pos):Void {
			var paths:Array<GlobalTypePath> = scom.platformConfig.pfReservedTypePaths;
			if (core.ds.ArrayTools.exists(paths, p -> p.name == path.name && p.pack.join(".") == path.pack.join(".")))
				SafeCom.addWarning(scom, WReservedTypePath, "Type path " + Globals.sTypePath(path) + " is reserved on this target", pos);
		}
		switch t {
			case TClassDecl(c) if (!TypeOps.hasClassFlag(c, CExtern)):
				check(c.clPath, c.clPos);
			case TEnumDecl(e) if (!TypeOps.hasEnumFlag(e, EnExtern)):
				check(e.ePath, e.ePos);
			case _:
		}
	}

	// PASS 3 end

	public static function iterExpressions(fl:Array<TExpr->Void>, mt:ModuleType):Void switch mt {
		case TClassDecl(c):
			inline function field(cf:TClassField):Void {
				if (cf.cfExpr != null) for (f in fl) f(cf.cfExpr);
			}
			for (cf in c.clOrderedStatics) field(cf);
			for (cf in c.clOrderedFields) field(cf);
			if (c.clConstructor != null) field(c.clConstructor);
		case _:
	}

	public static function destructionBeforeDce(pool:Null<TaskPool>, scom:SafeContext, allTypes:Array<ModuleType>):Void {
		var filters:Array<ModuleType->Void> = [
			FiltersCommon.removeGenericBase,
			scom.platform == Hl ? function(_) {} : applyMacroExclude,
			t -> removeExternFields(scom, t),
			// check @:remove metadata before DCE so it is ignored there (issue #2923)
			checkRemoveMetadata
		];
		Parallel.ParallelArray.iter(pool, function(mt) {
			for (f in filters) f(mt);
		}, allTypes);
	}

	public static function destructionOnScom(pool:Null<TaskPool>, scom:SafeContext, ectx:Null<ExceptionContext>,
			rename:RenameVars.RenameInit, allTypes:Array<ModuleType>):Void {
		Parallel.ParallelArray.iter(pool, function(mt) {
			var scom = SafeCom.adaptScomToMt(scom, mt);
			SaveStacks.patchConstructors(ectx, scom)(mt);
			Native.applyNativePaths(mt);
		}, allTypes);
		Parallel.ParallelArray.iter(pool, function(mt) {
			var scom = SafeCom.adaptScomToMt(scom, mt);
			if (scom.platform != Jvm) AddFieldInits.addFieldInits(scom.curclass.clPath, rename, scom, mt);
			checkVoidField(mt);
			if (scom.platform == Cpp) promoteFirstInterfaceToSuper(mt); // accesses cl_super, cl_implements
			if (scom.platformConfig.pfReservedTypePaths.length != 0) checkReservedTypePaths(scom, mt);
		}, allTypes);
	}

	public static function destructionOnCom(scom:SafeContext, com:CommonContext, types:Array<ModuleType>):Void {
		var filters:Array<SafeContext->ModuleType->Void> = [
			(_, mt) -> addRtti(scom, mt), // accesses cl_super
			(_, mt) -> checkPrivatePath(com, mt),
			(_, mt) -> {
				if (com.platform != Hl) addMetaField(com, mt);
			},
			(_, mt) -> commitFeatures(com, mt)
		];
		// These aren't actually safe. The logic works fine regardless, we just can't parallelize this at the moment.
		SafeCom.runTypeFiltersSafe(scom, filters, types);
	}

	public static function destruction(com:CommonContext, scom:SafeContext, ectx:Null<ExceptionContext>, detailTimes:Int,
			rename:RenameVars.RenameInit, allTypes:Array<ModuleType>, allTypesArray:Array<ModuleType>):Void {
		allTypes = Parallel.runWithPool(com.sctx.pool, function(pool) {
			FilterContext.withTimer(scom.timerCtx, detailTimes, "type 2", null, function() {
				SafeCom.runWithScom(com, scom, function() {
					destructionBeforeDce(pool, scom, allTypesArray);
				});
			});
			Common.enterStage(com, CDceStart);
			var allTypes = FilterContext.withTimer(scom.timerCtx, detailTimes, "dce", null, function() {
				// DCE
				var mode:String;
				try mode = Define.definedValue(scom.defines, Define.Dce)
				catch (_:Dynamic) mode = "no";
				var mode = switch mode {
					case "full": Define.defined(scom.defines, Define.Interp) ? DceNo : DceFull;
					case "std": DceStd;
					case "no": DceNo;
					case _: throw "Unknown DCE mode " + mode;
				};
				var stdPaths = com.classPaths.getStdPaths();
				var macros = com.getMacros();
				var mscom = macros == null ? null : SafeCom.ofCom(macros);
				return Dce.run(pool, scom, mscom, com.main.mainExpr, mode, stdPaths, allTypes);
			});
			var allTypesArray = allTypes.copy();
			Common.enterStage(com, CDceDone);
			Finalization.maybeAddEntrypoint(com);
			// This has to run after DCE, or otherwise its condition always holds.
			if (ectx != null && Common.hasFeature(com, "haxe.NativeStackTrace.exceptionStack"))
				Parallel.ParallelArray.iter(pool, mt -> SafeCom.runExpressionFiltersSafe(scom, detailTimes, [
					{name: "insert_save_stacks", run: (scom, e) -> SaveStacks.insertSaveStacks(ectx, scom)(e)}
				], mt, true), allTypesArray);
			FilterContext.withTimer(scom.timerCtx, detailTimes, "type 3", null, function() {
				SafeCom.runWithScom(com, scom, function() {
					destructionOnScom(pool, scom, ectx, rename, allTypesArray);
				});
			});
			return allTypes;
		});
		com.types = allTypes;
		FilterContext.withTimer(scom.timerCtx, detailTimes, "type 4", null, function() {
			SafeCom.runWithScom(com, scom, function() {
				destructionOnCom(scom, com, allTypes);
			});
		});
		com.callbacks.run(com.errorExt, com.callbacks.getAfterFilters());
		Common.enterStage(com, CFilteringDone);
	}

	public static function updateCacheDependencies(closeMonomorphs:Bool, scom:SafeContext, t:ModuleType):Void {
		var visitedAnons:Array<TAnon> = [];
		function checkT(m:ModuleDef, t:T):Void switch t {
			case TInst(c, tl):
				TypeOps.addDependency(m, c.clModule, MDepFromTyping);
				for (t in tl) checkT(m, t);
			case TEnum(en, tl):
				TypeOps.addDependency(m, en.eModule, MDepFromTyping);
				for (t in tl) checkT(m, t);
			case TType(td, tl):
				TypeOps.addDependency(m, td.tModule, MDepFromTyping);
				for (t in tl) checkT(m, t);
			case TAbstract(a, tl):
				TypeOps.addDependency(m, a.aModule, MDepFromTyping);
				for (t in tl) checkT(m, t);
			case TFun(sig):
				for (a in sig.args) checkT(m, a.type);
				checkT(m, sig.ret);
			case TAnon(an):
				if (!visitedAnons.contains(an)) {
					visitedAnons.unshift(an);
					// port: sorted like PMap.iter
					var keys = [for (k in an.aFields.keys()) k];
					keys.sort(core.ds.Key.compareStrings);
					for (k in keys) checkT(m, an.aFields.get(k).cfType);
				}
			case TMono(r):
				if (r.tmType != null) checkT(m, r.tmType);
				// Bind any still open monomorph that's part of a signature to Any now (issue #10653)
				else if (closeMonomorphs) Monomorph.doBind(r, scom.basic.tany);
			case TLazy(f):
				checkT(m, TypeOps.lazyType(f));
			case TDynamic(null):
			case TDynamic(t):
				checkT(m, t);
		}
		function checkField(m:ModuleDef, cf:TClassField):Void {
			checkT(m, cf.cfType);
			for (f in cf.cfOverloads) checkField(m, f);
		}
		switch t {
			case TClassDecl(c):
				for (cf in c.clOrderedStatics) checkField(c.clModule, cf);
				for (cf in c.clOrderedFields) checkField(c.clModule, cf);
				if (c.clConstructor != null) checkField(c.clModule, c.clConstructor);
			case _:
		}
	}

	// Saves a class state so it can be restored later, e.g. after DCE or native path rewrite
	public static function saveClassState(compilationStep:Int, t:ModuleType):Void {
		// Update m_processed here. This means that nothing should add a dependency afterwards because
		// then the module is immediately considered uncached again
		TypeOps.tModule(t).mExtra.mProcessed = compilationStep;
		switch t {
			case TClassDecl(c):
				var vars:Array<{variable:TVar, type:T}> = [];
				function saveVars(e:TExpr):Void {
					// port: push, not unshift (quadratic): entries only restore each var's type, so order is irrelevant
					inline function add(v:TVar):Void vars.push({variable: v, type: v.vType});
					switch e.eexpr {
						case TFunction(fn):
							for (a in fn.tfArgs) add(a.variable);
							saveVars(fn.tfExpr);
						case TVar(v, eo):
							add(v);
							if (eo != null) saveVars(eo);
						case _:
							core.Texpr.iter(saveVars, e);
					}
				}
				inline function mkOverloadRestore(f:TClassField):FieldRestoreState {
					TypeOps.addClassFieldFlag(f, CfPostProcessed);
					// port: cf_meta and cf_params are immutable lists upstream; the port's arrays are
					// modified in place, so the saved state holds copies.
					return {
						name: f.cfName,
						kind: f.cfKind,
						expr: f.cfExpr,
						type: f.cfType,
						meta: f.cfMeta.copy(),
						params: f.cfParams.copy()
					};
				}
				function mkFieldRestore(f:TClassField):FieldRestore {
					if (f.cfExpr != null) saveVars(f.cfExpr);
					return {
						field: f,
						state: mkOverloadRestore(f),
						overloads: f.cfOverloads.map(f -> {
							field: f,
							state: mkOverloadRestore(f)
						})
					};
				}
				inline function restoreOne(f:TClassField, s:FieldRestoreState):TClassField {
					f.cfName = s.name;
					f.cfKind = s.kind;
					f.cfExpr = s.expr;
					f.cfType = s.type;
					f.cfMeta = s.meta.copy();
					f.cfParams = s.params.copy();
					return f;
				}
				function restoreField(saved:FieldRestore):TClassField {
					var f = restoreOne(saved.field, saved.state);
					f.cfOverloads = [for (o in saved.overloads) restoreOne(o.field, o.state)];
					return f;
				}
				inline function mkPmap(lst:Array<TClassField>):StringMap<TClassField> {
					var map = new StringMap();
					for (f in lst) map.set(f.cfName, f);
					return map;
				}
				var meta = c.clMeta.copy();
				var path = c.clPath;
				var ext = TypeOps.hasClassFlag(c, CExtern);
				var sup = c.clSuper;
				var impl = c.clImplements.copy();
				var csr = c.clConstructor == null ? null : mkFieldRestore(c.clConstructor);
				var ofr = c.clOrderedFields.map(mkFieldRestore);
				var osr = c.clOrderedStatics.map(mkFieldRestore);
				var init = c.clInit == null ? null : mkFieldRestore(c.clInit);
				c.clRestore = function() {
					c.clSuper = sup;
					c.clImplements = impl.copy();
					c.clMeta = meta.copy();
					if (ext) TypeOps.addClassFlag(c, CExtern);
					else TypeOps.removeClassFlag(c, CExtern);
					c.clPath = path;
					c.clInit = init == null ? null : restoreField(init);
					c.clOrderedFields = ofr.map(restoreField);
					c.clOrderedStatics = osr.map(restoreField);
					c.clFields = mkPmap(c.clOrderedFields);
					c.clStatics = mkPmap(c.clOrderedStatics);
					c.clConstructor = csr == null ? null : restoreField(csr);
					c.clDescendants = [];
					for (v in vars) v.variable.vType = v.type;
				};
			case TEnumDecl(en):
				var path = en.ePath;
				en.eRestore = function() {
					for (i in 0...en.eMeta.length) switch en.eMeta[i] {
						case {meta: core.MetaList.StrictMeta.RealPath, exprs: [{expr: EConst(String(path, _))}]}:
							en.ePath = Ast.parsePath(path);
							en.eMeta = en.eMeta.slice(0, i).concat(en.eMeta.slice(i + 1));
							return;
						case _:
					}
					en.ePath = path;
				};
			case TTypeDecl(td):
				var path = td.tPath;
				td.tRestore = function() {
					td.tPath = path;
				};
			case TAbstractDecl(a):
				var path = a.aPath;
				a.aRestore = function() {
					a.aPath = path;
					a.aMeta = a.aMeta.filter(m -> m.meta != core.MetaList.StrictMeta.ValueUsed);
				};
		}
	}

	public static function mightNeedCfUnoptimized(c:TClass, cf:TClassField):Bool return switch [cf.cfKind, c.clKind] {
		case [Method(MethInline), _] | [_, KGeneric]: true;
		case _: TypeOps.hasClassFieldFlag(cf, CfGeneric);
	};

	public static function runSafeFilters(ectx:Null<ExceptionContext>, com:CommonContext, scom:SafeContext, allTypes:Array<ModuleType>,
			newTypes:Array<ModuleType>, rename:RenameVars.RenameInit):Void {
		var detailTimes = Timer.levelFromDefine(scom.defines, Define.FilterTimes);
		var wrapper = com.localWrapper;
		var beforeInlining:Array<{name:String, run:SafeContext->TExpr->TExpr}> = [
			{
				name: "handle_abstract_casts",
				run: AbstractCast.handleAbstractCasts
			}
		];
		var beforeParallel:Array<{name:String, run:SafeContext->TExpr->TExpr}> = [
			{name: "local_statics", run: LocalStatic.run},
			{name: "fix_return_dynamic_from_void_function", run: SafeFilters.fixReturnDynamicFromVoidFunction},
			// port: not for hxmc's native macros, whose compile runs these filters in macro mode
			// (hxmc/src/hxmc/macro/Guest.hx): the macro context does not check this
			// (MacroContext.flushMacroContext); upstream never runs them in macro mode
			{name: "check_local_vars_init", run: (scom, e) -> scom.isMacroContext ? e : CheckVarInit.checkLocalVarsInit(scom, e)},
			{name: "check_abstract_as_value", run: SafeFilters.checkAbstractAsValue},
			{name: "Tre", run: (scom, e) -> Define.defined(scom.defines, Define.AnalyzerOptimize) ? Tre.run(scom)(e) : e}
		];
		var beforeAnalyzer:Array<{name:String, run:SafeContext->TExpr->TExpr}> = [
			{name: "reduce_expression", run: Optimizer.reduceExpression},
			{name: "inline_constructors", run: InlineConstructors.inlineConstructors},
			{
				name: "Exceptions_filter",
				run: (scom, e) -> Exceptions.filter(ectx, scom)(e)
			},
			{name: "captured_vars", run: (scom, e) -> CapturedVars.capturedVars(scom, wrapper, false, e)}
		];
		var afterAnalyzer:Array<{name:String, run:SafeContext->TExpr->TExpr}> = [
			{name: "sanitize", run: Sanitize.sanitize},
			{
				name: "add_final_return",
				run: (_, e) -> scom.platformConfig.pfAddFinalReturn ? AddFinalReturn.addFinalReturn(e) : e
			},
			{
				name: "RenameVars",
				run: (scom, e) -> scom.platform == Eval ? e : RenameVars.run(scom.curclass.clPath, rename, e)
			},
			{
				name: "mark_switch_break_loops",
				run: SafeFilters.markSwitchBreakLoops
			}
		];
		Parallel.runWithPool(com.sctx.pool, function(pool) {
			var castPool = Common.defined(com, Define.EnableParallelAbstractCast) ? pool : null;
			Parallel.ParallelArray.iter(castPool, mt -> SafeCom.runExpressionFiltersSafe(scom, detailTimes, beforeInlining, mt), newTypes);
			Parallel.ParallelArray.iter(pool, mt -> SafeCom.runExpressionFiltersSafe(scom, detailTimes, beforeParallel, mt), newTypes);
			Dump.maybeGenerateDump(com, AfterCasting);
			Parallel.ParallelArray.iter(pool, mt -> SafeCom.runExpressionFiltersSafe(scom, detailTimes, beforeAnalyzer, mt), newTypes);
			Dump.maybeGenerateDump(com, AfterInlining);
			Common.enterStage(com, CAnalyzerStart);
			if (scom.platform != Cross) Analyzer.Run.runOnTypes(scom, pool, allTypes, newTypes);
			Dump.maybeGenerateDump(com, AfterAnalyzing);
			Common.enterStage(com, CAnalyzerDone);
			Parallel.ParallelArray.iter(pool, mt -> SafeCom.runExpressionFiltersSafe(scom, detailTimes, afterAnalyzer, mt), newTypes);
			Dump.maybeGenerateDump(com, AfterSanitizing);
		});
	}

	public static function run(com:CommonContext, ectx:Null<ExceptionContext>, beforeDestruction:Void->Void):Void {
		var scom = SafeCom.ofCom(com);
		var detailTimes = Timer.levelFromDefine(com.defines, Define.FilterTimes);
		var newTypes = (cast com.types : Array<ModuleType>).filter(function(t) {
			var cached = FiltersCommon.isCached(com, t);
			switch t {
				case TClassDecl(cls):
					for (iface in cls.clImplements) TypeOps.addDescendant(iface.cls, cls);
					if (cls.clSuper != null) TypeOps.addDescendant(cls.clSuper.cls, cls);
					// Save cf_expr_unoptimized early: We want to inline with the original expression
					// on the next compilation.
					if (!cached) {
						inline function field(cf:TClassField):Void {
							if (cf.cfExpr != null && cf.cfExprUnoptimized == null && mightNeedCfUnoptimized(cls,
								cf)) cf.cfExprUnoptimized = cf.cfExpr;
						}
						for (cf in cls.clOrderedFields) field(cf);
						for (cf in cls.clOrderedStatics) field(cf);
						if (cls.clConstructor != null) field(cls.clConstructor);
					}
				case _:
			}
			return !cached;
		});
		var newTypesArray = newTypes.copy();
		var allTypesArray:Array<ModuleType> = com.types.copy();
		/* IMPORTANT:
			There may be types in new_types which have already been post-processed, but then had their m_processed flag unset
			because they received an additional dependency. This could happen in cases such as @:generic methods in #10635.
			It is important that all filters from here up to save_class_state only process fields which do not have the
			CfPostProcessed flag set.

			This is mostly covered by run_expression_filters_safe already, but any new additions which don't utilize that have
			to be aware of this.
		*/
		DeprecationCheck.run(com, newTypes);
		NullSafety.run(com, newTypes);
		var rename = RenameVars.init(scom.platformConfig, com.types);
		SafeCom.runWithScom(com, scom, function() {
			runSafeFilters(ectx, com, scom, allTypesArray, newTypesArray, rename);
		});
		FilterContext.withTimer(com.timerCtx, detailTimes, "callbacks", null, function() {
			com.callbacks.run(com.errorExt, com.callbacks.getBeforeSave());
		});
		Common.enterStage(com, CSaveStart);
		FilterContext.withTimer(com.timerCtx, detailTimes, "save state", null, function() {
			for (mt in newTypes) updateCacheDependencies(true, scom, mt);
		});
		Parallel.runWithPool(com.sctx.pool, function(pool) {
			Parallel.ParallelArray.iter(pool, mt -> saveClassState(com.partScope.compilationStep, mt), newTypesArray);
		});
		Common.enterStage(com, CSaveDone);
		FilterContext.withTimer(com.timerCtx, detailTimes, "callbacks", null, function() {
			com.callbacks.run(com.errorExt, com.callbacks.getAfterSave());
		});
		beforeDestruction();
		destruction(com, scom, ectx, detailTimes, rename, com.types, allTypesArray);
	}
}
