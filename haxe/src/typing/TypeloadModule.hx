/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

package typing;

/* Initial typing of modules and their types. */
import core.Ast;
import core.Ast as AstTools;
import core.Ast.*;
import core.Globals;
import core.Globals.*;
import core.Globals.GlobalTypePath;
import core.Globals.Pos;
import core.Globals.Platform;
import core.TType;
import core.TFunctions.*;
import core.TOther.*;
import core.TPrinting.*;
import core.Meta as MetadataTools;
import core.MetaList.StrictMeta as MetaTag;
import core.Define;
import core.Warning;
import core.Message.WarningCode;
import core.Error;
import core.Error.*;
import core.Naming;
import core.InheritDoc;
import core.TUnification.Monomorph;
import core.TUnification.Unify_error;
import core.ds.NotFound;
import context.Common;
import context.Common.*;
import context.Typecore;
import context.Typecore.*;
import context.Typecore.Typer as TyperContext;
import context.TyperPass;
import context.display.DeprecationCheck;
import typing.Typeload.*;
import typing.TypeloadCheck.BuildCanceled;

using Lambda;
using core.ds.ArrayTools;

@:structInit class TypedDeclaration {
	public var declaration:TypeDecl;
	public var type:ModuleType;

	public inline function new(declaration:TypeDecl, type:ModuleType) {
		this.declaration = declaration;
		this.type = type;
	}

	public inline function clone():TypedDeclaration return new TypedDeclaration(declaration, type);
}

class TypeloadModule {
	public static function getPolicy(g:TyperGlobals, path:GlobalTypePath):Array<ModuleCheckPolicy> {
		var parts = AstTools.fullDotPath2(path, path), out = [];
		for (entry in g.moduleCheckPolicies) if (AstTools.matchPath(entry.recursive, parts, entry.pack)) out = entry.policies.concat(out);
		return out;
	}

	public static function makeModule(com:CommonContext, g:TyperGlobals, path:GlobalTypePath, file:String, p:Pos):ModuleDef return {
		mId: allocMid(),
		mPath: path,
		mTypes: [],
		mStatics: null,
		mExtra: moduleExtra(core.Path.getFullPath(file), Define.getSignature(com.defines), Common.fileTime(file),
			com.isMacroContext ? MMacro : MCode, com.partScope.compilationStep, getPolicy(g, path))
	};

	public static function fieldOfStaticDefinition(d:StaticDefinition, p:Pos):ClassField return {
		cffName: d.name,
		cffDoc: d.doc,
		cffPos: p,
		cffMeta: d.meta,
		cffAccess: ([{access: AStatic, pos: nullPos}] : Array<core.Ast.PlacedAccess>).concat(d.flags),
		cffKind: d.data
	};

	/*
		Build module structure : should be atomic - no type loading is possible
	*/
	public static function createModuleTypes(ctx:TyperContext, m:ModuleDef, decls:Array<TypeDecl>,
			loadp:Pos):{imports:Array<TypeDecl>, declarations:Array<TypedDeclaration>} {
		var com:CommonContext = ctx.com;
		var imports:Array<TypeDecl> = [],
			types:Array<ModuleType> = [],
			declarations:Array<TypedDeclaration> = [],
			statics:Array<{definition:StaticDefinition, pos:Pos}> = [],
			hasDeclaration = false;
		inline function add(decl:TypeDecl, t:ModuleType):Void {
			declarations.push({declaration: decl, type: t});
			com.moduleLut.addModuleType(m, t);
			types.push(t);
		}
		inline function checkName(name:String, meta:Metadata, alsoStatics:Bool, p:Pos):Void {
			DeprecationCheck.checkIs(com, ctx.m.curmod, meta, [], name, meta, p);
			inline function duplicate(previous:Pos):Void Error.raiseTypingErrorExt(Error.makeError(Custom("Name " + name
				+ " is already defined in this module"), p,
				[Error.makeError(Custom(complMsg("Previous declaration here")), previous)]));
			for (t in types) if (tName(t) == name) duplicate(tInfos(t).mtNamePos);
			if (alsoStatics) for (d in statics) if (d.definition.name.name == name) duplicate(d.definition.name.pos);
		}
		inline function makePath(name:String, priv:Bool, meta:Metadata, p:Pos):GlobalTypePath {
			checkName(name, meta, true, p);
			return {pack: priv ? m.mPath.pack.concat(["_" + m.mPath.name]) : m.mPath.pack, name: name};
		}
		inline function checkTypeName(name:String, meta:Metadata,
				p:Pos):Void if (name != m.mPath.name
				&& !MetadataTools.has(MetaTag.Native, meta)) Naming.checkUppercaseIdentifierName(com, name, "type", p);
		inline function makeClass(d:ClassDefinition, p:Pos):TClass {
			hasDeclaration = true;
			var priv = d.flags.contains(HPrivate),
				path = makePath(d.name.name, priv, d.meta, d.name.pos),
				c = mkClass(m, path, p, d.name.pos);
			// we shouldn't load any other type until we propertly set cl_build
			c.clBuild = function() return Error.raiseTypingError(sTypePath(c.clPath)
				+ " is not ready to be accessed, separate your type declarations in several files", p);
			c.clPrivate = priv;
			c.clDoc = d.doc;
			c.clMeta = d.meta.copy();
			for (flag in d.flags) switch flag {
				case HAbstract:
					addClassFlag(c, CAbstract);
				case HExtern:
					addClassFlag(c, CExtern);
				case HInterface:
					addClassFlag(c, CInterface);
				case HFinal:
					addClassFlag(c, CFinal);
				case _:
			}
			if (!hasClassFlag(c, CExtern)) checkTypeName(d.name.name, d.meta, p);
			if (hasClassFlag(c, CAbstract)) {
				if (hasClassFlag(c, CInterface)) Common.displayError(com, "An interface may not be abstract", c.clNamePos);
				if (hasClassFlag(c, CFinal)) Common.displayError(com, "An abstract class may not be final", c.clNamePos);
			}
			return c;
		}
		for (decl in decls) {
			var p = decl.pos;
			switch decl.definition {
				case EImport(_) | EUsing(_):
					if (hasDeclaration) Error.raiseTypingError("import and using may not appear after a declaration", p);
					imports.push(decl);
				case EStatic(d):
					checkName(d.name.name, d.meta, false, d.name.pos);
					hasDeclaration = true;
					statics.unshift({definition: d, pos: p});
				case EClass(d):
					add(decl, TClassDecl(makeClass(d, p)));
				case EEnum(d):
					hasDeclaration = true;
					var priv = d.flags.contains(EPrivate),
						en = mkEnum(m, makePath(d.name.name, priv, d.meta, p), p, d.name.pos);
					en.eDoc = d.doc;
					en.eMeta = d.meta.copy();
					en.ePrivate = priv;
					if (d.flags.contains(EExtern)) addEnumFlag(en, EnExtern);
					else checkTypeName(d.name.name, d.meta, p);
					add(decl, TEnumDecl(en));
				case ETypedef(d):
					checkTypeName(d.name.name, d.meta, p);
					hasDeclaration = true;
					var priv = d.flags.contains(TDPrivate),
						td = mkTypedef(m, makePath(d.name.name, priv, d.meta, p), p, d.name.pos, mkMono());
					td.tDoc = d.doc;
					td.tPrivate = priv;
					td.tMeta = d.meta.copy();
					// failsafe in case the typedef is not initialized (see #3933)
					delay(ctx.g, PBuildModule, function() {
						switch td.tType {
							case TMono(r) if (r.tmType == null):
								Monomorph.bind(r, com.basic.tvoid);
							case _:
						}
					});
					add(decl, TTypeDecl(td));
				case EAbstract(d):
					checkTypeName(d.name.name, d.meta, p);
					var priv = d.flags.contains(AbPrivate),
						path = makePath(d.name.name, priv, d.meta, p),
						enumPos = MetadataTools.maybeGetPos(MetaTag.Enum, d.meta);
					var a:TAbstract = {
						aPath: path,
						aPrivate: priv,
						aModule: m,
						aPos: p,
						aNamePos: d.name.pos,
						aDoc: d.doc,
						aParams: [],
						aUsing: [],
						aRestore: function() {},
						aMeta: d.meta.copy(),
						aFrom: [],
						aTo: [],
						aFromField: [],
						aToField: [],
						aOps: [],
						aUnops: [],
						aImpl: null,
						aArray: [],
						aThis: mkMono(),
						aRead: null,
						aWrite: null,
						aCall: null,
						aConstructor: null,
						aExtern: d.flags.contains(AbExtern),
						aEnum: d.flags.contains(AbEnum) || enumPos != null};
					if (enumPos == null) {
						if (a.aEnum) a.aMeta.unshift({meta: MetaTag.Enum, exprs: [], pos: nullPos}); // HAXE5: remove
					} else Common.moduleWarning(com, ctx.m.curmod, WDeprecatedEnumAbstract, Warning.fromMeta(d.meta),
						"`@:enum abstract` is deprecated in favor of `enum abstract`", enumPos);
					add(decl, TAbstractDecl(a));
					if (d.data.length == 0 && MetadataTools.has(MetaTag.CoreType, a.aMeta)) a.aThis = tDynamic;
					else {
						var params = [
							for (tp in d.params) TPType(AstTools.makePtpTh(AstTools.mkTypePath([], tp.tpName.name), nullPos))
						], aType = AstTools.makePtpTh(AstTools.mkTypePath([], d.name.name, params), nullPos), thisType = aType;
						for (flag in d.flags) switch flag {
							case AbOver(t):
								thisType = t;
								break;
							case _:
						}
						var fields = d.data.map(function(f) return TypeloadFields.transformAbstractField(com, thisType, aType, a, f)),
							meta:Metadata = [];
						if (MetadataTools.has(MetaTag.Dce, a.aMeta)) meta.unshift({meta: MetaTag.Dce, exprs: [], pos: nullPos});
						var cd:ClassDefinition = {
							name: {name: d.name.name + "_Impl_", pos: d.name.pos},
							flags: [HPrivate],
							data: fields,
							doc: null,
							params: [],
							meta: meta
						}, c = makeClass(cd, p);
						a.aImpl = c;
						c.clKind = KAbstractImpl(a);
						addClassFlag(c, CFinal);
						add({definition: EClass(cd), pos: p}, TClassDecl(c));
					}
			}
		}
		if (statics.length > 0) {
			var first = nullPos, fields = [];
			for (d in statics) {
				first = d.pos;
				fields.push(fieldOfStaticDefinition(d.definition, d.pos));
			}
			fields.reverse();
			var p:core.Globals.Pos = {pfile: first.pfile, pmin: first.pmin, pmax: first.pmin},
				d:ClassDefinition = {
					name: {name: m.mPath.name + "_Fields_", pos: nullPos},
					flags: [HPrivate],
					data: fields,
					doc: null,
					params: [],
					meta: []
				},
				c = makeClass(d, p);
			if (m.mStatics != null) throw "Module statics already initialized";
			m.mStatics = c;
			c.clKind = KModuleFields(m);
			addClassFlag(c, CFinal);
			add({definition: EClass(d), pos: p}, TClassDecl(c));
		}
		// During the initial module_lut#add in type_module, m has no m_types yet by design.
		// We manually add them here. This and module_lut#add itself should be the only places
		// in the compiler that call add_module_type.
		m.mTypes = m.mTypes.concat(types);
		return {imports: imports, declarations: declarations};
	}

	public static function initTypeParams(ctx:TyperContext,
			decls:Array<TypedDeclaration>):Void
		// here is an additional PASS 1 phase, which define the type parameters for all module types.
		// Constraints are handled lazily (no other type is loaded) because they might be recursive anyway
		for (entry in decls) switch [entry.declaration.definition, entry.type] {
			case [EClass(d), TClassDecl(c)]:
				c.clParams = Typeload.typeTypeParams(ctx, TPHType, c.clPath, d.params);
				if (MetadataTools.has(MetaTag.Generic, c.clMeta) && c.clParams.length > 0) c.clKind = KGeneric;
				if (MetadataTools.has(MetaTag.FunctionalInterface, c.clMeta)) {
					if (!hasClassFlag(c,
						CInterface)) Error.raiseTypingError("@:functionalInterface is only allowed on interfaces, as the name implies",
							c.clNamePos);
					else addClassFlag(c, CFunctionalInterface);
				}
				if (MetadataTools.has(MetaTag.GenericBuild, c.clMeta)) {
					if (ctx.com.isMacroContext) Error.raiseTypingError("@:genericBuild cannot be used in macros", c.clPos);
					c.clKind = KGenericBuild(d.data);
				}
				if (c.clPath.pack.join(".") == "haxe.macro" && c.clPath.name == "MacroType") c.clKind = KMacroType;
			case [EEnum(d), TEnumDecl(e)]:
				e.eParams = Typeload.typeTypeParams(ctx, TPHType, e.ePath, d.params);
			case [ETypedef(d), TTypeDecl(t)]:
				t.tParams = Typeload.typeTypeParams(ctx, TPHType, t.tPath, d.params);
			case [EAbstract(d), TAbstractDecl(a)]:
				a.aParams = Typeload.typeTypeParams(ctx, TPHType, a.aPath, d.params);
			case _:
				throw "Inconsistent module declaration";
		};

	public static function initClass(ctx:TyperContext, c:TClass, d:ClassDefinition, p:Pos):Void {
		if (ctx.m.isDisplayFile
			&& core.display.DisplayPosition.displayPosition.enclosedIn(d.name.pos)) context.display.DisplayEmitter.displayModuleType(ctx,
				switch c.clKind {
					case KAbstractImpl(a): TAbstractDecl(a);
					case _: TClassDecl(c);
				}, d.name.pos);
		switch c.clKind {
			case KAbstractImpl(_):
			case _:
				TypeloadCheck.checkGlobalMetadata(ctx, c.clMeta, function(meta) c.clMeta = [meta].concat(c.clMeta), c.clModule.mPath,
					c.clPath, null);
		}
		for (meta in d.meta) if (Type.enumEq(meta.meta, MetaTag.Final)) addClassFlag(c, CFinal);
		var previous = ctx.g.buildCount - 1,
			cctx = TypeloadFields.createClassContext(c, p),
			local = TypeloadFields.createTyperContextForClass(ctx, cctx, p);
		function build():BuildState {
			c.clBuild = function() return Building([c]);
			var inheritance = TypeloadCheck.Inheritance.setHeritance(local, c, d.flags, p);
			function perform():BuildState {
				c.clBuild = function() return Building([c]);
				if (buildClassHook != null) buildClassHook(c, true);
				try {
					for (f in inheritance) f();
					TypeloadFields.initClass(local, cctx, c, p, d.flags, d.data);
					if (buildClassHook != null) buildClassHook(c, false);
					c.clBuild = function() return Built;
					local.g.buildCount++;
					for (tp in c.clParams) follow(tp.ttpType);
					return Built;
				} catch (e:BuildCanceled) {
					if (buildClassHook != null) buildClassHook(c, false);
					c.clBuild = makePass(local, perform);
					function rebuild():Void delayLate(local.g, PBuildClass, function() {
						c.clBuild();
					});
					var state:BuildState = e.state;
					return switch state {
						case Built: throw "Unexpected built cancellation";
						case Building(classes):
							if (local.g.buildCount == previous)
								Error.raiseTypingError("Loop in class building prevent compiler termination ("
									+ classes.map(function(c) return sTypePath(c.clPath)).join(",")
									+ ")",
									c.clPos);
							previous = local.g.buildCount;
							rebuild();
							Building([c].concat(classes));
						case BuildMacro(callbacks):
							callbacks.unshift(rebuild);
							state;
					};
				} catch (e:haxe.Exception) {
					if (buildClassHook != null) buildClassHook(c, false);
					c.clBuild = function() return Built;
					throw e;
				}
			}
			return perform();
		}
		c.clBuild = makePass(ctx, build);
		delay(ctx.g, PBuildClass, function() {
			c.clBuild();
		});
		if (MetadataTools.has(MetaTag.InheritDoc, c.clMeta)) delay(ctx.g, PConnectField, function() InheritDoc.buildClassDoc(ctx, c));
		if (ctx.com.platform == Jvm && !hasClassFlag(c, CExtern)) delay(ctx.g, PTypeField, function() {
			c.clMeta = StrictMeta.checkStrictMeta(ctx, c.clMeta).concat(c.clMeta);
			function field(cf:TClassField):Void {
				cf.cfMeta = StrictMeta.checkStrictMeta(ctx, cf.cfMeta).concat(cf.cfMeta);
				for (f in cf.cfOverloads) field(f);
			}
			for (cf in c.clOrderedStatics) field(cf);
			for (cf in c.clOrderedFields) field(cf);
			if (c.clConstructor != null) field(c.clConstructor);
		});
	}

	public static function loadEnumField(ctx:TyperContext, e:TEnum, et:T, isFlat:{value:Bool}, index:Int, c:EnumConstructor):TEnumField {
		var params = Typeload.typeTypeParams(ctx, TPHEnumConstructor, {pack: [], name: c.ecName.name}, c.ecParams),
			local = TyperManager.cloneForEnumField(ctx, params.concat(ctx.typeParams));
		var ret = c.ecType == null ? et : Typeload.loadComplexType(local, true, LoadReturn, c.ecType);
		if (c.ecType != null) switch follow(ret) {
			case TEnum(te, _) if (te == e):
			case _:
				Error.raiseTypingError("Explicit enum type must be of the same enum type", c.ecType.pos);
		}
		var type = ret;
		if (c.ecArgs.length > 0) {
			isFlat.value = false;
			var names = new haxe.ds.StringMap<Bool>();
			var args = [
				for (arg in c.ecArgs) {
					switch arg.type.type {
						case CTPath({path: {tpackage: [], tname: "Void"}}):
							Error.raiseTypingError("Arguments of type Void are not allowed in enum constructors", arg.type.pos);
						case _:
					}
					if (names.exists(arg.name)) Error.raiseTypingError("Duplicate argument `"
						+ arg.name
						+ "` in enum constructor "
						+ c.ecName.name, c.ecPos);
					names.set(arg.name, true);
					{
						name: arg.name,
						optional: arg.optional,
						type: Typeload.loadTypeHint(local, c.ecPos, LoadNormal, arg.type, arg.optional)
					};
				}
			];
			type = TFun({args: args, ret: ret});
		}
		var f:TEnumField = {
			efName: c.ecName.name,
			efType: type,
			efPos: c.ecPos,
			efNamePos: c.ecName.pos,
			efDoc: c.ecDoc,
			efIndex: index,
			efParams: params,
			efMeta: c.ecMeta
		};
		DeprecationCheck.checkIs(local.com, local.m.curmod, e.eMeta, f.efMeta, f.efName, f.efMeta, f.efNamePos);
		if (local.m.isDisplayFile
			&& core.display.DisplayPosition.displayPosition.enclosedIn(f.efNamePos)) context.display.DisplayEmitter.displayEnumField(local,
				e, f, c.ecPos);
		return f;
	}

	public static function initEnum(ctx:TyperContext, e:TEnum, d:EnumDefinition, p:Pos):Void {
		if (ctx.m.isDisplayFile
			&& core.display.DisplayPosition.displayPosition.enclosedIn(d.name.pos)) context.display.DisplayEmitter.displayModuleType(ctx,
				TEnumDecl(e), d.name.pos);
		var local = TyperManager.cloneForEnum(ctx, e);
		TypeloadCheck.checkGlobalMetadata(local, e.eMeta, function(meta) e.eMeta = [meta].concat(e.eMeta), e.eModule.mPath, e.ePath, null);
		var constructs = d.data;
		function getConstructs():Array<ClassField> return [
			for (c in constructs) {
				var kind:ClassFieldKind = c.ecArgs.length == 0 && c.ecParams.length == 0 ? FVar(c.ecType, null) : FFun({
					fParams: c.ecParams,
					fType: c.ecType,
					fExpr: null,
					fArgs: [
						for (arg in c.ecArgs) {
							name: {name: arg.name, pos: nullPos},
							optional: arg.optional,
							meta: [],
							type: arg.type,
							expr: null
						}
					]
				});
				{
					cffName: c.ecName,
					cffDoc: c.ecDoc,
					cffMeta: c.ecMeta,
					cffPos: c.ecPos,
					cffAccess: [],
					cffKind: kind
				};
			}
		];
		TypeloadFields.buildModuleDef(local, TEnumDecl(e), e.eMeta, getConstructs, function(expression:Expr) {
			switch expression.expr {
				case EVars([{evType: {type: CTAnonymous(fields)}, evExpr: null}]):
					constructs = [
						for (f in fields) {
							var args:Array<EnumConstructorArg> = [],
								params:Array<TypeParam> = [],
								type:Null<TypeHint> = null;
							switch f.cffKind {
								case FVar(t, null):
									type = t;
								case FFun(fn) if (fn.fExpr == null || (switch fn.fExpr.expr {
									case EBlock([]): true;
									case _: false;
								})):
									type = fn.fType;
									params = fn.fParams;
									args = [
										for (arg in fn.fArgs) {
											if (arg.type == null) Error.raiseTypingError("Missing function parameter type", f.cffPos);
											{name: arg.name.name, optional: arg.optional, type: arg.type};
										}
									];
								case _:
									Error.raiseTypingError("Invalid enum constructor in @:build result", expression.pos);
							}
							{
								ecName: f.cffName,
								ecDoc: f.cffDoc,
								ecMeta: f.cffMeta,
								ecPos: f.cffPos,
								ecArgs: args,
								ecParams: params,
								ecType: type
							};
						}
					];
				case _:
					Error.raiseTypingError("Enum build macro must return a single variable with anonymous object fields", expression.pos);
			}
		});
		var et = TEnum(e, extractParamTypes(e.eParams)), flat = {value: true}, names = [];
		var index = 0;
		for (c in constructs) {
			if (e.eConstrs.exists(c.ecName.name)) Error.raiseTypingError("Duplicate constructor " + c.ecName.name, c.ecName.pos);
			var f = loadEnumField(local, e, et, flat, index++, c);
			e.eConstrs.set(f.efName, f);
			names.push(c.ecName.name);
			if (MetadataTools.has(MetaTag.InheritDoc,
				f.efMeta)) delay(local.g, PConnectField, function() InheritDoc.buildEnumFieldDoc(local, f));
		}
		e.eNames = names;
		Typecore.unify(local, TType(enumModuleType(e), []), e.eType, p);
		if (flat.value) e.eMeta = [({meta: MetaTag.FlatEnum, exprs: [], pos: nullPos} : MetadataEntry)].concat(e.eMeta);
		if (MetadataTools.has(MetaTag.InheritDoc, e.eMeta)) delay(local.g, PConnectField, function() InheritDoc.buildEnumDoc(local, e));
		if (local.com.platform == Jvm && !hasEnumFlag(e, EnExtern)) delay(local.g, PTypeField, function() {
			e.eMeta = StrictMeta.checkStrictMeta(local, e.eMeta).concat(e.eMeta);
			var keys = [for (k in e.eConstrs.keys()) k];
			keys.sort(core.ds.Key.compareStrings);
			for (k in keys) {
				var f = e.eConstrs.get(k);
				f.efMeta = StrictMeta.checkStrictMeta(local, f.efMeta).concat(f.efMeta);
			}
		});
	}

	public static function initTypedef(ctx:TyperContext, t:TDef, d:TypedefDefinition, p:Pos):Void {
		if (ctx.m.isDisplayFile
			&& core.display.DisplayPosition.displayPosition.enclosedIn(d.name.pos)) context.display.DisplayEmitter.displayModuleType(ctx,
				TTypeDecl(t), d.name.pos);
		TypeloadCheck.checkGlobalMetadata(ctx, t.tMeta, function(meta) t.tMeta = [meta].concat(t.tMeta), t.tModule.mPath, t.tPath, null);
		var local = TyperManager.cloneForTypedef(ctx, t),
			type = Typeload.loadComplexType(local, true, LoadNormal, d.data);
		var result = switch d.data.type {
			case CTExtend(_, _): type;
			case CTPath({path: {tpackage: ["haxe", "macro"], tname: "MacroType"}}):
				// we need to follow MacroType immediately since it might define other module types that we will load afterwards
				if (t.tType == follow(type)) Error.raiseTypingError("Recursive typedef is not allowed", p);
				type;
			case _:
				if (MetadataTools.has(MetaTag.Eager, d.meta)) follow(type); else {
					function recursive(tt:T):Void {
						if (tt == t.tType) Error.raiseTypingError("Recursive typedef is not allowed", p);
						switch tt {
							case TMono(r):
								if (r.tmType != null) recursive(r.tmType);
							case TLazy(f):
								recursive(lazyType(f));
							case TType(td, tl):
								if (td == t) Error.raiseTypingError("Recursive typedef is not allowed", p);
								recursive(applyTypedef(td, tl));
							case _:
						}
					}
					TLazy(makeLazy(local.g, type, function() {
						recursive(type);
						return type;
					}, "typedef_rec_check"));
				}
		};
		switch t.tType {
			case TMono(r) if (r.tmType == null):
				Monomorph.bind(r, result);
			case TMono(r):
				throw "typedef " + sTypePath(t.tPath) + " is already initialized to " + sTypeKind(r.tmType) + ", but new init to "
					+ sTypeKind(result) + " was attempted";
			case _:
				throw "Invalid initial typedef type";
		}
		TypeloadFields.buildModuleDef(local, TTypeDecl(t), t.tMeta, function() return [], function(_) {});
	}

	public static function initAbstract(ctx:TyperContext, a:TAbstract, d:AbstractDefinition, p:Pos):Void {
		if (ctx.m.isDisplayFile
			&& core.display.DisplayPosition.displayPosition.enclosedIn(d.name.pos)) context.display.DisplayEmitter.displayModuleType(ctx,
				TAbstractDecl(a), d.name.pos);
		TypeloadCheck.checkGlobalMetadata(ctx, a.aMeta, function(meta) a.aMeta = [meta].concat(a.aMeta), a.aModule.mPath, a.aPath, null);
		if (a.aImpl != null) for (meta in a.aMeta) switch (meta.meta : MetaTag) {
			case Using | Build | CoreApi | Allow | Access | Enum | Dce | Native | HlNative | JsRequire | PythonImport | Expose |
				Deprecated | PhpGlobal | PublicFields:
				a.aImpl.clMeta.unshift(meta);
			case _:
		}
		var local = TyperManager.cloneForAbstract(ctx, a), isType = false;
		inline function load(hint:TypeHint, from:Bool):T {
			var type = Typeload.loadComplexType(local, true, LoadNormal, hint);
			if (!MetadataTools.has(MetaTag.CoreType, a.aMeta)) {
				if (!isType) return Error.raiseTypingError("Missing underlying type declaration or @:coreType declaration", p);
				return TLazy(makeLazy(local.g, type, function() {
					try {
						if (from) core.TUnification.unify(type, a.aThis);
						else core.TUnification.unify(a.aThis, type);
					} catch (_:Unify_error) {
						Error.raiseTypingError("You can only declare from/to with compatible types", hint.pos);
					}
					return type;
				}, "constraint"));
			}
			if (MetadataTools.has(MetaTag.Callable, a.aMeta)) Error.raiseTypingError("@:coreType abstracts cannot be @:callable", p);
			return type;
		}
		for (flag in d.flags) switch flag {
			case AbFrom(t):
				a.aFrom.unshift(load(t, true));
			case AbTo(t):
				a.aTo.unshift(load(t, false));
			case AbOver(t):
				if (a.aImpl == null) Error.raiseTypingError("Abstracts with underlying type must have an implementation", a.aPos);
				if (MetadataTools.has(MetaTag.CoreType,
					a.aMeta)) Error.raiseTypingError("@:coreType abstracts cannot have an underlying type", p);
				var type = Typeload.loadComplexType(local, true, LoadNormal, t);
				delay(local.g, PForce, function() {
					function loop(stack:Array<TAbstract>, t:T):Void switch follow(t) {
						case TAbstract(ab, _) if (!MetadataTools.has(MetaTag.CoreType, ab.aMeta)):
							if (stack.contains(ab)) Error.raiseTypingError("Abstract underlying type cannot be recursive", ab.aPos);
							else loop([ab].concat(stack), ab.aThis);
						case _:
					};
					loop([], type);
				});
				a.aThis = type;
				isType = true;
			case AbExtern:
				if (a.aImpl != null) addClassFlag(a.aImpl, CExtern); // Hmmmm....
			case AbPrivate | AbEnum:
		}
		a.aFrom.reverse();
		a.aTo.reverse();
		if (!isType) {
			if (MetadataTools.has(MetaTag.CoreType, a.aMeta)) a.aThis = TAbstract(a, extractParamTypes(a.aParams));
			else Error.raiseTypingError("Abstract is missing underlying type declaration", a.aPos);
		}
		if (MetadataTools.has(MetaTag.InheritDoc, a.aMeta)) delay(local.g, PConnectField, function() InheritDoc.buildAbstractDoc(local, a));
	}

	/*
		In this pass, we can access load and access other modules types, but we cannot follow them or access their structure
		since they have not been setup. We also build a list that will be evaluated the first time we evaluate
		an expression into the context
	*/
	public static function initModuleType(ctx:TyperContext, entry:TypedDeclaration):Void {
		var p = entry.declaration.pos;
		switch [entry.declaration.definition, entry.type] {
			case [EClass(d), TClassDecl(c)]:
				initClass(ctx, c, d, p);
			case [EEnum(d), TEnumDecl(e)]:
				initEnum(ctx, e, d, p);
			case [ETypedef(d), TTypeDecl(t)]:
				initTypedef(ctx, t, d, p);
			case [EAbstract(d), TAbstractDecl(a)]:
				initAbstract(ctx, a, d, p);
			case _:
				throw "Inconsistent module declaration";
		}
	}

	public static function initImportsOrUsing(ctx:TyperContext, decl:TypeDecl):Void {
		var com = ctx.com;
		function checkPathDisplay(path:Array<PlacedName>,
				p:Pos):Void if (core.display.DisplayPosition.displayPosition.isInFile(com.partScope.fileKeys.get(p.pfile)))
				context.display.DisplayPath.handlePathDisplay(ctx, path, p);
		switch decl.definition {
			case EImport(i):
				try {
					checkPathDisplay(i.path, decl.pos);
					context.display.ImportHandling.initImport(ctx, i.path, i.mode, decl.pos);
					context.display.ImportHandling.commitImport(ctx, i.path, i.mode, decl.pos);
				} catch (e:TypingError) {
					Common.displayErrorExt(ctx.com, e.error);
				}
			case EUsing(path):
				checkPathDisplay(path, decl.pos);
				context.display.ImportHandling.initUsing(ctx, path, decl.pos);
			case _:
				throw "Expected import or using";
		}
	}

	public static function makeCurmod(com:CommonContext, g:TyperGlobals, m:ModuleDef):TyperModule {
		var rl = g.rootTyper.m.importResolution.cloneAs(["import", Globals.sTypePath(m.mPath)]);
		return {
			curmod: m,
			importResolution: rl,
			ownResolution: null,
			enumWithType: null,
			moduleUsing: [],
			importStatements: [],
			isDisplayFile: com.display.dmsKind != core.DisplayTypes.DisplayModeValue.DMNone
			&& core.display.DisplayPosition.displayPosition.isInFile(core.Path.UniqueKey.lazyKey(m.mExtra.mFile))
		};
	}

	/*
		Creates a module context for [m] and types [tdecls] using it.
	*/
	public static function typeTypesIntoModule(com:CommonContext, g:TyperGlobals, m:ModuleDef, decls:Array<TypeDecl>, p:Pos):TyperContext {
		var ctx = TyperManager.cloneForModule(g.rootTyper, makeCurmod(com, g, m)),
			created = createModuleTypes(ctx, m, decls, p);
		initTypeParams(ctx, created.declarations);
		for (decl in created.imports) initImportsOrUsing(ctx, decl);
		// setup module types
		for (decl in created.declarations) initModuleType(ctx, decl);
		// Make sure that we actually init the context at some point (issue #9012)
		delay(ctx.g, PConnectField, function() ctx.m.importResolution.resolveLazies());
		return ctx;
	}

	public static function handleImportHx(com:CommonContext, g:TyperGlobals, m:ModuleDef, decls:Array<TypeDecl>, p:Pos):Array<TypeDecl> {
		var pathSplit = core.Path.getPathParts(core.Path.UniqueKey.lazyPath(m.mExtra.mFile));
		pathSplit.reverse();
		if (pathSplit.length > 0) pathSplit.shift();
		function join(l:Array<String>):String {
			var parts = ["import.hx"].concat(l);
			parts.reverse();
			return parts.join(core.Path.pathSep);
		}
		var candidates = [];
		var path = pathSplit, pack = m.mPath.pack;
		while (true) {
			if (pack.length == 0) {
				candidates.push(join(path));
				break;
			}
			if (path.length == 0) break;
			candidates.push(join(path));
			path = path.slice(1);
			pack = pack.slice(1);
		}
		for (file in candidates) {
			var imported:Array<TypeDecl>;
			try {
				imported = com.parserCache.find(file);
				var im:ModuleDef = com.moduleLut.find({pack: [], name: file});
				if (im.mExtra.mKind != MFake) addDependency(m, im, MDepFromImport);
			} catch (_:NotFound) {
				imported = [];
				var warnings:Array<syntax.Parser.ParseWarning> = [];
				var exists = sys.FileSystem.exists(file);
				if (exists) {
					var parsed = TypeloadParse.parseModuleFile(com, {file: file, classPath: com.emptyClassPath}, p);
					imported = parsed.data.declarations;
					warnings = parsed.warnings;
					for (decl in imported) switch decl.definition {
						case EImport(_) | EUsing(_):
						case _:
							Error.raiseTypingError("Only import and using is allowed in import.hx files", decl.pos);
					}
				}
				com.parserCache.add(file, imported);
				// We use the file path as module name to make it unique. This may or may not be a good idea...
				var im = makeModule(com, g, {pack: [], name: file}, file, p);
				// Add empty decls so we don't check the file system all the time.
				im.mExtra.mKind = exists ? MImport : MFake;
				if (exists) {
					com.moduleLut.add(im.mPath, im);
					addDependency(m, im, MDepFromImport);
					for (w in warnings) Common.moduleWarning(com, m, WIfDisplay, [], core.WarningList.warningObj(WIfDisplay).wDoc, w.pos);
				}
			}
			decls = imported.concat(decls);
		}
		return decls;
	}

	/*
		Creates a new module and types [tdecls] into it.
	*/
	public static function typeModule(com:CommonContext, g:TyperGlobals, path:GlobalTypePath, file:String, decls:Array<TypeDecl>, p:Pos,
			dontCheckPath:Bool = false, isExtern:Bool = false):ModuleDef {
		var m = makeModule(com, g, path, file, p);
		com.moduleLut.add(path, m);
		var all = handleImportHx(com, g, m, decls, p);
		typeTypesIntoModule(com, g, m, all, p);
		if (isExtern) m.mExtra.mKind = MExtern;
		else if (!dontCheckPath) Naming.checkModulePath(com, m.mPath, p);
		com.requestScope.stats.sModulesTyped++;
		return m;
	}

	public static function loadHxbModule(com:CommonContext, g:TyperGlobals, path:GlobalTypePath, p:Pos):ModuleDef {
		function read(file:String, bytes:haxe.io.Bytes):ModuleDef {
			try {
				var api:compiler.hxb.HxbReaderApi = new HxbReaderApiTypeload(com, g, loadModulePrime, p);
				var reader = new compiler.hxb.HxbReader(path, com.hxbReaderStats,
					Common.defined(com, Define.HxbTimes) ? com.timerCtx : null);
				var read = reader.read(api, bytes);
				var m = read(EOT);
				delay(g, PConnectField, function() {
					read(EOM);
				});
				return m;
			} catch (e:Dynamic) {
				var stack = haxe.CallStack.toString(haxe.CallStack.exceptionStack());
				Sys.stderr().writeString("\x1b[30;41mError loading " + path.name + " from " + file + "\x1b[0m\n");
				Sys.stderr().writeString(" => " + Std.string(e) + "\n" + stack + "\n");
				#if hl hl.Api.rethrow(e); #end
				throw e;
			}
		}
		var target = Common.platformNameMacro(com);
		for (hxbLib in com.hxbLibs) {
			var bytes = hxbLib.getBytes(target, path);
			if (bytes != null) return read(hxbLib.getFilePath(), bytes);
		}
		throw NotFound.raise();
	}

	// port: hxmc's persistent module cache (hxmc/src/hxmc/ModuleCache.hx) learns here when a module is typed
	// ... from its source (start, then end); always null in the compiler itself.
	public static var typeFromSourceHook:Null<(com:CommonContext, path:GlobalTypePath, start:Bool) -> Void> = null;

	// port: and when a class of such a module is built (its fields made: start, then end, also when the build
	// ... fails or is canceled); always null in the compiler itself.
	public static var buildClassHook:Null<(c:TClass, start:Bool) -> Void> = null;

	public static function loadModulePrime(com:CommonContext, g:TyperGlobals, path:GlobalTypePath, p:Pos):ModuleDef {
		Common.checkCancellation(com);
		try {
			// Check current context
			return com.moduleLut.find(path);
		} catch (_:NotFound) {}
		// Check cache
		switch TypeloadCacheHook.typeModuleHook(com, function(pass, f) delay(g, pass, f), path, p) {
			case GoodModule(m):
				return m;
			case BinaryModule(_):
				return Globals.die("", "typeloadModule.ml load_module'"); // The server builds those
			case NoModule | BadModule(_) | BadBinaryModule(_, _):
		}
		try {
			return loadHxbModule(com, g, path, p);
		} catch (_:NotFound) {}
		inline function missing():Dynamic return Error.raiseErrorMsg(ModuleNotFound(path), p);
		if (com.moduleNonexistentLut.mem(path) || g.loadOnlyCachedModules) return missing();
		var isExtern = false, file:String, decls:Array<TypeDecl>, warnings:Array<syntax.Parser.ParseWarning>;
		try {
			// Try parsing
			var parsed = TypeloadParse.parseModule(com, path, p);
			file = parsed.file.file;
			decls = parsed.declarations;
			warnings = parsed.warnings;
		} catch (_:NotFound) {
			// Nothing to parse, try loading extern type
			// port: entries are {name, load:(path,pos)->Null<core.Ast.Package>}
			isExtern = true;
			var found:Null<{file:String, decls:Array<TypeDecl>}> = null;
			for (entry in com.loadExternType) {
				var a:Null<core.Ast.Package> = entry.load(path, p);
				if (a != null) {
					found = {file: entry.name, decls: a.declarations};
					break;
				}
			}
			if (found == null) {
				com.moduleNonexistentLut.add(path, true);
				return missing();
			}
			file = found.file;
			decls = found.decls;
			warnings = [];
		}
		if (typeFromSourceHook != null) typeFromSourceHook(com, path, true);
		var m = try typeModule(com, g, path, file, decls, p, false, isExtern) catch (e:Dynamic) {
			if (typeFromSourceHook != null) typeFromSourceHook(com, path, false);
			throw e;
		}
		if (typeFromSourceHook != null) typeFromSourceHook(com, path, false);
		for (w in warnings) Common.moduleWarning(com, m, WIfDisplay, [], core.WarningList.warningObj(WIfDisplay).wDoc, w.pos);
		return m;
	}

	public static function loadModule(ctx:TyperContext, path:GlobalTypePath, p:Pos, origin:ModuleDepOrigin = MDepFromTyping):ModuleDef {
		var m = loadModulePrime(ctx.com, ctx.g, path, p);
		addDependency(ctx.m.curmod, m, origin, true);
		if (ctx.pass == PTypeField) flushPass(ctx.g, PConnectField, {name: "load_module", args: path.pack.concat([path.name])});
		return m;
	}
}

class HxbReaderApiTypeload implements compiler.hxb.HxbReaderApi {
	final com:CommonContext;
	final g:TyperGlobals;
	final loadModule:(CommonContext, TyperGlobals, GlobalTypePath, Pos) -> ModuleDef;
	final p:Pos;

	public function new(com:CommonContext, g:TyperGlobals, loadModule:(CommonContext, TyperGlobals, GlobalTypePath, Pos) -> ModuleDef,
			p:Pos) {
		this.com = com;
		this.g = g;
		this.loadModule = loadModule;
		this.p = p;
	}

	public function makeModule(path:GlobalTypePath, file:String):ModuleDef {
		var m = TypeloadModule.makeModule(com, g, path, file, p);
		m.mExtra.mProcessed = 1;
		return m;
	}

	public function addModule(m:ModuleDef):Void com.moduleLut.add(m.mPath, m);

	public function resolveType(pack:Array<String>, mname:String, tname:String, _:compiler.hxb.HxbData.TypingMode):ModuleType {
		var m = loadModule(com, g, {pack: pack, name: mname}, p);
		for (t in m.mTypes) if (tPath(t).name == tname) return t;
		throw NotFound.raise();
	}

	public function resolveModule(path:GlobalTypePath, _:compiler.hxb.HxbData.TypingMode):ModuleDef return loadModule(com, g, path, p);

	public function basicTypes():BasicTypes return com.basic;

	// The v_id in .hxb has no relation to this context, make a new one.
	public function getVarId(i:Int):Int return allocVarId();

	public function readExpressionEagerly(cf:TClassField):Bool {
		return com.isMacroContext || switch cf.cfKind {
			case Var(_): true;
			case Method(_):
				delay(g, PTypeField, function() {
					follow(cf.cfType);
				});
				false;
		}}

	public function makeLazyType(t:T, f:Void->T):T return TLazy(makeLazy(g, t, f, "typeload-api"));
}
