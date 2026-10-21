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

package optimization;

import core.Ast;
import core.Globals;
import core.TType;
import core.TFunctions.*;
import core.TUnification.*;
import core.Texpr;
import core.Texpr.*;
import core.TFunctions.NotFound;
import core.Meta;
import context.SafeCom;
import core.ds.VectorTools.vector;

using core.ds.VectorTools;

enum DceMode {
	DceNo;
	DceStd;
	DceFull;
}

@:structInit class DceData {
	public var scom:SafeContext;
	public var mscom:Null<SafeContext>;
	public var full:Bool;
	public var stdDirs:Array<String>;
	public var debug:Bool;
	public var followExpr:DceData->TExpr->Void;
	public var curclass:TClass;
	public var addedFields:Array<{cls:TClass, field:TClassField, kind:ClassFieldRefKind}>;
	public var markedFields:{value:Array<TClassField>};
	public var features:haxe.ds.StringMap<Array<ClassFieldRef>>;
	public var checkedFeatures:haxe.ds.StringMap<Bool>;
	public var mergeMutex:sys.thread.Mutex;
	public var fieldMarkerMutex:sys.thread.Mutex;
	public var usedMutex:sys.thread.Mutex;
	public var featureMutex:sys.thread.Mutex;
	public var addFeatureManager:core.ds.NowOrLater;
	// port: `expr dce` as a closure, created once per record (clone() leaves it null).
	public var visit:Null<TExpr->Void> = null;
	// port: markT's type stack, reused across calls; a nested markT only scans its own part.
	public var typeStack:Array<T> = [];

	public inline function new(scom:SafeContext, mscom:Null<SafeContext>, full:Bool, stdDirs:Array<String>, debug:Bool,
			followExpr:DceData->TExpr->Void, curclass:TClass, addedFields:Array<{
			cls:TClass,
			field:TClassField,
			kind:ClassFieldRefKind
		}>,
			markedFields:{value:Array<TClassField>}, features:haxe.ds.StringMap<Array<ClassFieldRef>>,
			checkedFeatures:haxe.ds.StringMap<Bool>, mergeMutex:sys.thread.Mutex, fieldMarkerMutex:sys.thread.Mutex,
			usedMutex:sys.thread.Mutex, featureMutex:sys.thread.Mutex, addFeatureManager:core.ds.NowOrLater) {
		this.scom = scom;
		this.mscom = mscom;
		this.full = full;
		this.stdDirs = stdDirs;
		this.debug = debug;
		this.followExpr = followExpr;
		this.curclass = curclass;
		this.addedFields = addedFields;
		this.markedFields = markedFields;
		this.features = features;
		this.checkedFeatures = checkedFeatures;
		this.mergeMutex = mergeMutex;
		this.fieldMarkerMutex = fieldMarkerMutex;
		this.usedMutex = usedMutex;
		this.featureMutex = featureMutex;
		this.addFeatureManager = addFeatureManager;
	}

	public inline function clone():DceData return new DceData(scom, mscom, full, stdDirs, debug, followExpr, curclass, addedFields,
		markedFields, features, checkedFeatures, mergeMutex, fieldMarkerMutex, usedMutex, featureMutex, addFeatureManager);
}

class Dce {
	public static function pushClass(dce:DceData, c:TClass):DceData {
		var copy:DceData = core.ds.Record.copy(dce);
		copy.curclass = c;
		return copy;
	}

	public static function resolveClassFieldRef(dce:DceData, cfr:ClassFieldRef):{cls:TClass, field:TClassField} {
		var scom = cfr.cfrIsMacro && !dce.scom.isMacroContext ? dce.mscom : dce.scom;
		if (scom == null) throw "Invalid_argument: Option.get";
		var m:ModuleDef = scom.findModuleByType(cfr.cfrPath);
		for (mt in m.mTypes) switch mt {
			case TClassDecl(c) if (Globals.sTypePath(c.clPath) == Globals.sTypePath(cfr.cfrPath)):
				return {cls: c, field: findField(c, cfr.cfrField, cfr.cfrKind)};
			case _:
		}
		throw "Invalid_argument: Option.get";
	}

	// checking

	// check for @:keepSub metadata, which forces @:keep on child classes
	public static function superForcesKeep(c:TClass):Bool return Meta.has(KeepSub, c.clMeta)
		|| exists(ct -> superForcesKeep(ct.cls), c.clImplements)
		|| c.clSuper != null
		&& superForcesKeep(c.clSuper.cls);

	public static function overridesExternField(cf:TClassField, c:TClass):Bool {
		if (c.clSuper == null) return false;
		var sup = c.clSuper.cls;
		var field = sup.clFields.get(cf.cfName);
		if (field == null) return false;
		return hasClassFlag(sup, CExtern) && field.cfExpr == null || overridesExternField(field, sup);
	}

	public static function isStdFile(dce:DceData, file:String):Bool return exists(dir -> StringTools.startsWith(file, dir), dce.stdDirs);

	public static var keepMetas:Array<core.MetaList.StrictMeta> = [Keep, Expose];

	// check if a class is kept entirely
	public static function keepWholeClass(dce:DceData,
			c:TClass):Bool return Meta.hasOneOf(keepMetas, c.clMeta)
			|| !(dce.full || isStdFile(dce, core.Path.UniqueKey.lazyPath(c.clModule.mExtra.mFile)) || Meta.has(Dce, c.clMeta))
			|| superForcesKeep(c)
			|| switch c.clPath {
				case {pack: [], name: "Math" | "Array"} if (dce.scom.platform == Js): false;
				case {pack: ["flash", "_Boot"], name: "RealBoot"}: true;
				case _ if (hasClassFlag(c, CExtern)): true;
				case {pack: [], name: "String" | "Array"}: dce.scom.platform != Js;
				case _: false;
			};

	public static function keepWholeEnum(dce:DceData,
			en:TEnum):Bool return Meta.hasOneOf(keepMetas, en.eMeta)
			|| !(dce.full || isStdFile(dce, core.Path.UniqueKey.lazyPath(en.eModule.mExtra.mFile)) || Meta.has(Dce, en.eMeta));

	// check if a field carries @:dce, forcing it to be DCE-eligible even if its class is kept
	public static function fieldForcesDce(cf:TClassField):Bool return Meta.has(Dce, cf.cfMeta);

	// check if a class has any field marked with @:dce
	public static function classHasDceField(c:TClass):Bool return exists(fieldForcesDce, c.clOrderedFields)
		|| exists(fieldForcesDce, c.clOrderedStatics)
		|| c.clConstructor != null
		&& fieldForcesDce(c.clConstructor);

	public static function mkUsedMeta(p:Pos):MetadataEntry return {
		meta: core.MetaList.StrictMeta.Used,
		exprs: vector(),
		pos: Globals.mkZeroRangePos(p)
	};

	public static function mkKeepMeta(p:Pos):MetadataEntry return {
		meta: core.MetaList.StrictMeta.Keep,
		exprs: vector(),
		pos: Globals.mkZeroRangePos(p)
	};

	/*
		Check if a field is kept.
		`keep_field` is checked to determine the DCE entry points, i.e. all fields that have `@:keep` or kept for other reasons.
		And then it is used at the end to check which fields can be filtered from their classes.
	*/
	public static function keepField(dce:DceData, cf:TClassField, c:TClass, kind:ClassFieldRefKind):Bool {
		var stat = kind == CfrStatic;
		if (Meta.hasOneOf(keepMetas, cf.cfMeta) || hasClassFieldFlag(cf, CfUsed) || cf.cfName == "__init__"
			|| hasClassFieldFlag(cf, CfExtern) || !stat && overridesExternField(cf, c)) return true;
		// parent class kept constructor
		if (kind == CfrConstructor
			&& c.clSuper != null
			&& c.clSuper.cls.clConstructor != null
			&& keepField(dce, c.clSuper.cls.clConstructor, c.clSuper.cls, CfrConstructor)) return true;
		inline function accessor(prefix:String):Bool {
			var field = (stat ? c.clStatics : c.clFields).get(prefix + cf.cfName);
			return field != null && keepField(dce, field, c, kind);
		}
		return switch cf.cfKind {
			case Var({vRead: AccCall | AccPrivateCall, vWrite: _}): accessor("get_");
			case Var({vRead: _, vWrite: AccCall | AccPrivateCall}): accessor("set_");
			case _: false;
		};
	}

	// marking

	public static function checkFeature(dce:DceData, s:String):Void {
		try {
			var refs = dce.features.get(s);
			if (refs == null) throw NotFound.raise();
			dce.featureMutex.acquire();
			if (!dce.checkedFeatures.exists(s)) {
				dce.checkedFeatures.set(s, true);
				dce.featureMutex.release();
				for (ref in refs) {
					var resolved = resolveClassFieldRef(dce, ref);
					markField(dce, resolved.cls, resolved.field, ref.cfrKind);
				}
			} else dce.featureMutex.release();
		} catch (_:NotFound) {}
	}

	public static function checkAndAddFeature(dce:DceData, s:String):Void {
		checkFeature(dce, s);
		var c = dce.curclass;
		if (c == nullClass) throw "assert: missing DCE class";
		dce.addFeatureManager.tryNow(function() c.clModule.mExtra.mFeatures.set(s, true));
	}

	// mark a field as kept
	public static function markField(dce:DceData, c:TClass, cf:TClassField, kind:ClassFieldRefKind):Void {
		inline function add(owner:TClass, cf:TClassField):Void if (!hasClassFieldFlag(cf, CfUsed)) {
			dce.fieldMarkerMutex.acquire();
			if (!hasClassFieldFlag(cf, CfUsed)) {
				addClassFieldFlag(cf, CfUsed);
				dce.addedFields.push({cls: owner, field: cf, kind: kind});
				// port: appended (upstream conses): only cleared again, one by one, in any order
				dce.markedFields.value.push(cf);
				dce.fieldMarkerMutex.release();
				checkFeature(dce, Globals.sTypePath(c.clPath) + "." + cf.cfName);
			} else dce.fieldMarkerMutex.release();
		}
		switch kind {
			case CfrConstructor:
				var owner = c;
				while (true) {
					if (owner.clConstructor != null) add(owner, owner.clConstructor);
					if (owner.clSuper == null) break;
					owner = owner.clSuper.cls;
				}
			case CfrInit:
				if (c.clInit != null) add(c, c.clInit);
			case CfrStatic | CfrMember:
				var stat = kind == CfrStatic;
				if (!(stat ? c.clStatics : c.clFields).exists(cf.cfName)) {
					if (c.clSuper == null) add(c, cf);
					else markField(dce, c.clSuper.cls, cf, kind);
				} else add(c, cf);
				if (!stat && isPhysicalField(cf) && c.clConstructor != null) markField(dce, c, c.clConstructor, CfrConstructor);
		}
	}

	public static function updateMarkedClassFields(dce:DceData, c:TClass):Void {
		dce = pushClass(dce, c);
		// mark all :?used fields as surely :used now
		for (cf in c.clOrderedStatics) if (hasClassFieldFlag(cf, CfMaybeUsed)) markField(dce, c, cf, CfrStatic);
		for (cf in c.clOrderedFields) if (hasClassFieldFlag(cf, CfMaybeUsed)) markField(dce, c, cf, CfrMember);
		// we always have to keep super classes and implemented interfaces
		var init = core.TOther.TClassTools.getClInit(c);
		if (init != null) dce.followExpr(dce, init);
		for (ct in c.clImplements) markClass(dce, ct.cls);
		if (c.clSuper != null) markClass(dce, c.clSuper.cls);
	}

	// mark a class as kept. If the class has fields marked as @:?keep, make sure to keep them
	public static function markClass(dce:DceData, c:TClass):Void if (!hasClassFlag(c, CUsed)) {
		dce.usedMutex.acquire();
		if (!hasClassFlag(c, CUsed)) {
			addClassFlag(c, CUsed);
			dce.usedMutex.release();
			checkFeature(dce, Globals.sTypePath(c.clPath) + ".*");
			updateMarkedClassFields(dce, c);
		} else dce.usedMutex.release();
	}

	static function sortedKeys<V>(map:haxe.ds.StringMap<V>):Array<String> {
		var keys = [for (key in map.keys()) key];
		keys.sort(core.ds.Key.compareStrings);
		return keys;
	}

	// port: metadata is replaced, never changed in place: marking runs in parallel and readers
	// don't lock (upstream conses onto immutable lists).
	public static function markEnum(dce:DceData, en:TEnum):Void if (!Meta.has(Used, en.eMeta)) {
		dce.usedMutex.acquire();
		if (!Meta.has(Used, en.eMeta)) {
			en.eMeta = [mkUsedMeta(en.ePos)].concat(en.eMeta);
			dce.usedMutex.release();
			checkAndAddFeature(dce, "has_enum");
			checkFeature(dce, Globals.sTypePath(en.ePath) + ".*");
			for (key in sortedKeys(en.eConstrs)) {
				var ef = en.eConstrs.get(key);
				markT(dce, ef.efPos, ef.efType);
			}
		} else dce.usedMutex.release();
	}

	public static function markAbstract(dce:DceData, a:TAbstract):Void if (!Meta.has(Used, a.aMeta)) {
		dce.usedMutex.acquire();
		if (!Meta.has(Used, a.aMeta)) {
			a.aMeta = [mkUsedMeta(a.aPos)].concat(a.aMeta);
			dce.usedMutex.release();
			checkFeature(dce, Globals.sTypePath(a.aPath) + ".*");
		} else dce.usedMutex.release();
	}

	// mark a type as kept
	// port: the stack is pushed and popped instead of rebuilt per level (upstream conses onto a list).
	public static function markT(dce:DceData, p:Pos, t:T):Void {
		var stack = dce.typeStack;
		markTLoop(dce, p, stack, stack.length, t);
	}

	static function markTLoop(dce:DceData, p:Pos, stack:Array<T>, base:Int, t:T):Void {
		for (i in base...stack.length) if (fastEq(t, stack[i])) return;
		stack.push(t);
		switch follow(t) {
			case TInst(c = {clKind: KTypeParameter(ttp)}, pl):
				if (!hasClassFlag(c, CUsed)) {
					addClassFlag(c, CUsed);
					for (t in getConstraints(ttp)) markTLoop(dce, p, stack, base, t);
				}
				for (t in pl) markTLoop(dce, p, stack, base, t);
			case TInst(c, pl):
				markClass(dce, c);
				for (t in pl) markTLoop(dce, p, stack, base, t);
			case TFun(sig):
				for (a in sig.args) markTLoop(dce, p, stack, base, a.type);
				markTLoop(dce, p, stack, base, sig.ret);
			case TEnum(en, pl):
				markEnum(dce, en);
				for (t in pl) markTLoop(dce, p, stack, base, t);
			case TAbstract(a, pl) if (Meta.has(MultiType, a.aMeta)):
				var depth = stack.length;
				try markTLoop(dce, p, stack, base, context.AbstractCast.findMultitypeSpecialization(dce.scom.platform, a, pl, p).type)
				catch (_:core.Error.TypingError) {
					stack.resize(depth);
				}
			case TAbstract(a, pl):
				markAbstract(dce, a);
				for (t in pl) markTLoop(dce, p, stack, base, t);
				if (!Meta.has(CoreType, a.aMeta)) markTLoop(dce, p, stack, base, core.Abstract.getUnderlyingType(a, pl));
			case TLazy(_) | TDynamic(_) | TType(_, _) | TAnon(_) | TMono(_):
		}
		stack.pop();
	}

	public static function markMt(dce:DceData, mt:ModuleType):Void switch mt {
		case TClassDecl(c):
			markClass(dce, c);
		case TEnumDecl(en):
			markEnum(dce, en);
		case TAbstractDecl(a):
			// abstract 'feature' is defined as the abstract type beeing used as a value, not as a type
			if (!Meta.has(ValueUsed, a.aMeta)) a.aMeta = [
				({meta: core.MetaList.StrictMeta.ValueUsed, exprs: vector(), pos: Globals.mkZeroRangePos(a.aPos)} : core.Ast.MetadataEntry)
			].concat(a.aMeta);
			markAbstract(dce, a);
		case TTypeDecl(_):
	}

	// find all dependent fields by checking implementing/subclassing types
	public static function markDependentFields(dce:DceData, sup:TClass, name:String, kind:ClassFieldRefKind):Void {
		function loop(c:TClass):Void {
			var cf = (kind == CfrStatic ? c.clStatics : c.clFields).get(name);
			if (cf == null) {
				// if the field is not present on current class, it might come from a base class
				if (c.clSuper != null) loop(c.clSuper.cls);
				return;
			}
			// if it's clear that the class is kept, the field has to be kept as well. This is also true for
			// extern interfaces because we cannot remove fields from them
			if (hasClassFlag(c,
				CUsed) || hasClassFlag(sup, CInterface) && hasClassFlag(sup, CExtern)) markField(pushClass(dce, c), c, cf, kind);
			// otherwise it might be kept if the class is kept later, so mark it as :?used
			else if (!hasClassFieldFlag(cf, CfMaybeUsed)) {
				dce.fieldMarkerMutex.acquire();
				if (hasClassFlag(c, CUsed)) {
					// Lost the race against CUsed
					dce.fieldMarkerMutex.release();
					markField(pushClass(dce, c), c, cf, kind);
				} else {
					if (!hasClassFieldFlag(cf, CfMaybeUsed)) addClassFieldFlag(cf, CfMaybeUsed);
					dce.fieldMarkerMutex.release();
				}
			}
		}
		function inheritance(c:TClass):Void {
			loop(c);
			for (d in c.clDescendants) inheritance(d);
		}
		inheritance(sup);
	}

	// expr and field evaluation

	public static function opt<A>(f:A->Void, e:Null<A>):Void if (e != null) f(e);

	public static function toString(dce:DceData, stack:Array<T>, t:T):Void switch t {
		case TInst(c, _):
			keepToString(dce, c);
		case TType(tt, tl):
			if (!exists(t2 -> fastEq(t, t2), stack)) toString(dce, [t].concat(stack), applyTypedef(tt, tl));
		case TAbstract(a = {aImpl: c}, tl) if (c != null):
			if (Meta.has(CoreType, a.aMeta)) keepToString(dce, c);
			else toString(dce, stack, core.Abstract.getUnderlyingType(a, tl));
		case TMono(r):
			if (r.tmType != null) toString(dce, stack, r.tmType);
		case TLazy(f):
			toString(dce, stack, lazyType(f));
		case TDynamic(t) if (t != null):
			toString(dce, stack, t);
		case TEnum(_, _) | TFun(_) | TAnon(_) | TAbstract(_, _) | TDynamic(_):
			// if we to_string these it does not imply that we need all its sub-types
	}

	// resolve a field by name across the class, its super classes, implemented interfaces and type
	// parameter constraints, returning the class that actually defines it. Raises Not_found if absent.
	public static function resolveField(dce:DceData, c:TClass, name:String, kind:ClassFieldRefKind):{cls:TClass, field:TClassField} {
		try return {cls: c, field: findField(c, name, kind)} catch (_:NotFound) {}
		try {
			if (hasClassFlag(c, CInterface)) {
				for (ct in c.clImplements) {
					// port: HashLink 2.0 JIT: an early exit through two nested try blocks restores only the innermost trap, leaving a dangling handler
					var r = try
					resolveField(dce, ct.cls, name, kind) catch (_:NotFound) null;
					if (r != null) return r;
				}
				throw NotFound.raise();
			} else if (c.clSuper != null) return resolveField(dce, c.clSuper.cls, name, kind);
			else throw NotFound.raise();
		} catch (_:NotFound) {}
		switch c.clKind {
			case KTypeParameter(ttp):
				for (t in getConstraints(ttp)) switch t {
					case TInst(c, _): try return resolveField(dce, c, name, kind) catch (_:NotFound) {}
					case _:
				}
			case _:
		}
		throw NotFound.raise();
	}

	public static function field(dce:DceData, c:TClass, name:String, kind:ClassFieldRefKind):Void {
		try {
			var r = resolveField(dce, c, name, kind);
			markField(dce, r.cls, r.field, kind);
		} catch (_:NotFound) {
			if (dce.debug) Sys.stderr().writeString("[DCE] Field " + name + " not found on " + Globals.sTypePath(c.clPath) + "\n");
		}
	}

	// keep a type's toString, unless that field opts out of being implicitly kept with @:dce
	// (it is only pulled in by Std.string/trace/Array.join, never by an explicit call)
	public static function keepToString(dce:DceData, c:TClass):Void {
		try {
			var r = resolveField(dce, c, "toString", CfrMember);
			if (!fieldForcesDce(r.field)) markField(dce, r.cls, r.field, CfrMember);
		} catch (_:NotFound) {}
	}

	static function protect(mutex:sys.thread.Mutex, f:Void->Void):Void {
		mutex.acquire();
		try f()
		catch (e:haxe.Exception) {
			mutex.release();
			throw e;
		}
		mutex.release();
	}

	// don't add @:directlyUsed if it's used within the class itself. this can happen with extern inline methods
	public static function markDirectlyUsedClass(dce:DceData,
			c:TClass):Void if (c != dce.curclass && !Meta.has(DirectlyUsed, c.clMeta)) protect(dce.usedMutex, function() {
			if (!Meta.has(DirectlyUsed, c.clMeta)) c.clMeta = [
				({meta: core.MetaList.StrictMeta.DirectlyUsed, exprs: vector(), pos: Globals.mkZeroRangePos(c.clPos)} : core.Ast.MetadataEntry)
			].concat(c.clMeta);
		});

	public static function markDirectlyUsedEnum(dce:DceData,
			en:TEnum):Void if (!Meta.has(DirectlyUsed, en.eMeta)) protect(dce.usedMutex, function() {
			if (!Meta.has(DirectlyUsed, en.eMeta)) en.eMeta = [
				({meta: core.MetaList.StrictMeta.DirectlyUsed, exprs: vector(), pos: Globals.mkZeroRangePos(en.ePos)} : core.Ast.MetadataEntry)
			].concat(en.eMeta);
		});

	public static function markDirectlyUsedMt(dce:DceData, mt:ModuleType):Void switch mt {
		case TClassDecl(c):
			markDirectlyUsedClass(dce, c);
		case TEnumDecl(en):
			markDirectlyUsedEnum(dce, en);
		case _:
	}

	public static function markDirectlyUsedT(dce:DceData, p:Pos, t:T):Void switch follow(t) {
		case TInst(c = {clKind: KNormal}, pl):
			markDirectlyUsedClass(dce, c);
			for (t in pl) markDirectlyUsedT(dce, p, t);
		case TEnum(en, pl):
			markDirectlyUsedEnum(dce, en);
			for (t in pl) markDirectlyUsedT(dce, p, t);
		case TAbstract(a, pl) if (Meta.has(MultiType, a.aMeta)):
			// this is copy-pasted from mark_t
			try markDirectlyUsedT(dce, p, context.AbstractCast.findMultitypeSpecialization(dce.scom.platform, a, pl, p).type)
			catch (_:core.Error.TypingError) {}
		case TAbstract(a, pl):
			for (t in pl) markDirectlyUsedT(dce, p, t);
			if (!Meta.has(CoreType, a.aMeta)) markDirectlyUsedT(dce, p, core.Abstract.getUnderlyingType(a, pl));
		case _:
	}

	public static function checkDynamicWrite(dce:DceData, fa:TFieldAccess):Void {
		var n = fieldName(fa);
		checkAndAddFeature(dce, "dynamic_write");
		checkAndAddFeature(dce, "dynamic_write." + n);
	}

	public static function checkAnonOptionalWrite(dce:DceData, fa:TFieldAccess):Void {
		var n = fieldName(fa);
		checkAndAddFeature(dce, "anon_optional_write");
		checkAndAddFeature(dce, "anon_optional_write." + n);
	}

	public static function checkAnonWrite(dce:DceData, fa:TFieldAccess):Void {
		var n = fieldName(fa);
		checkAndAddFeature(dce, "anon_write");
		checkAndAddFeature(dce, "anon_write." + n);
	}

	public static function isArray(t:T):Bool return switch follow(t) {
		case TAbstract(a, tl) if (!Meta.has(CoreType, a.aMeta)): isArray(core.Abstract.getUnderlyingType(a, tl));
		case TInst({clPath: {pack: [], name: "Array"}}, _): true;
		case _: false;
	};

	public static function isDynamic(t:T):Bool return switch follow(t) {
		case TAbstract(a, tl) if (!Meta.has(CoreType, a.aMeta)): isDynamic(core.Abstract.getUnderlyingType(a, tl));
		case TDynamic(_): true;
		case _: false;
	};

	public static function isString(t:T):Bool return switch follow(t) {
		case TAbstract(a, tl) if (!Meta.has(CoreType, a.aMeta)): isString(core.Abstract.getUnderlyingType(a, tl));
		case TInst({clPath: {pack: [], name: "String"}}, _): true;
		case _: false;
	};

	public static function isConstString(e:TExpr):Bool return switch e.eexpr {
		case TConst(TString(_)): true;
		case _: false;
	};

	static function exprFieldDefault(dce:DceData, e:TExpr, fa:TFieldAccess):Void {
		var n = fieldName(fa);
		switch fa {
			case FAnon(cf):
				if (Meta.has(Optional, cf.cfMeta)) {
					checkAndAddFeature(dce, "anon_optional_read");
					checkAndAddFeature(dce, "anon_optional_read." + n);
				} else {
					checkAndAddFeature(dce, "anon_read");
					checkAndAddFeature(dce, "anon_read." + n);
				}
			case FDynamic(_):
				checkAndAddFeature(dce, "dynamic_read");
				checkAndAddFeature(dce, "dynamic_read." + n);
			case FClosure(_, _):
				checkAndAddFeature(dce, "closure_read");
				checkAndAddFeature(dce, "closure_read." + n);
			case _:
		}
		switch [follow(e.etype), fa] {
			case [TInst(c, _), _]:
				markClass(dce, c);
				field(dce, c, n, CfrMember);
			case [_, FClosure(ct, _)] if (ct != null):
				markClass(dce, ct.cls);
				field(dce, ct.cls, n, CfrMember);
			case [TAnon(a), _]:
				switch a.aStatus {
					case ClassStatics(c):
						markClass(dce, c);
						field(dce, c, n, CfrStatic);
					case _:
				}
			case _:
		}
	}

	static function markInstanceFieldAccess(dce:DceData, isCallExpr:Bool, c:TClass,
			cf:TClassField):Void if (!isCallExpr && dce.scom.platform == Python) switch c.clPath {
			case {pack: [], name: "Array"}:
				checkAndAddFeature(dce, "closure_Array");
				checkAndAddFeature(dce, "python.internal.ArrayImpl." + cf.cfName);
				checkAndAddFeature(dce, "python.internal.ArrayImpl");
			case {pack: [], name: "String"}:
				checkAndAddFeature(dce, "closure_String");
				checkAndAddFeature(dce, "python.internal.StringImpl." + cf.cfName);
				checkAndAddFeature(dce, "python.internal.StringImpl");
			case _:
		}

	public static function exprField(dce:DceData, e:TExpr, fa:TFieldAccess, isCallExpr:Bool):Void {
		switch fa {
			case FStatic(c, cf):
				markClass(dce, c);
				markField(dce, c, cf, CfrStatic);
			case FInstance(c, _, cf):
				// mark_instance_field_access c cf;
				markClass(dce, c);
				markField(dce, c, cf, CfrMember);
			case FClosure(ct, cf) if (ct != null):
				markInstanceFieldAccess(dce, isCallExpr, ct.cls, cf);
				exprFieldDefault(dce, e, fa);
			case _:
				exprFieldDefault(dce, e, fa);
		}
		expr(dce, e);
	}

	public static function checkOp(dce:DceData, op:Binop):Void switch op {
		case OpMod:
			checkAndAddFeature(dce, "binop_%");
		case OpUShr:
			checkAndAddFeature(dce, "binop_>>>");
		case OpAssignOp(op):
			checkOp(dce, op);
		case _:
	}

	public static function expr(dce:DceData, e:TExpr):Void {
		markT(dce, e.epos, e.etype);
		var visit = dce.visit;
		if (visit == null) {
			visit = expr.bind(dce);
			dce.visit = visit;
		}
		inline function pair(a:TExpr, b:TExpr):Void {
			expr(dce, a);
			expr(dce, b);
		}
		switch e.eexpr {
			case TNew(c, pl, el):
				markClass(dce, c);
				markDirectlyUsedClass(dce, c);
				field(dce, c, "new", CfrConstructor);
				for (e in el) visit(e);
				for (t in pl) markT(dce, e.epos, t);
			case TVar(v, e1):
				if (e1 != null) expr(dce, e1);
				markT(dce, e.epos, v.vType);
			case TCast(inner, mt) if (mt != null):
				checkFeature(dce, "typed_cast");
				markMt(dce, mt);
				markDirectlyUsedMt(dce, mt);
				visit(inner);
			case TObjectDecl(vl):
				checkAndAddFeature(dce, "has_anon");
				for (v in vl) visit(v.expr);
			case TTypeExpr(mt):
				markMt(dce, mt);
				markDirectlyUsedMt(dce, mt);
			case TTry(inner, vl):
				visit(inner);
				for (v in vl) {
					if (v.variable.vType != tDynamic) {
						checkFeature(dce, "typed_catch");
						markDirectlyUsedT(dce, v.variable.vPos, v.variable.vType);
					}
					visit(v.expr);
					markT(dce, v.expr.epos, v.variable.vType);
				}
			case TCall({eexpr: TIdent("`trace")}, [p, {eexpr: TObjectDecl(v)}]):
				checkAndAddFeature(dce, "has_anon_trace");
				for (f in v) visit(f.expr);
				visit(p);
			case TCall({eexpr: TIdent("__define_feature__")}, [{eexpr: TConst(TString(ft))}, inner]):
				// port: under the lock of the writes through addFeatureManager (NowOrLater.runNow)
				var m = dce.curclass.clModule;
				dce.addFeatureManager.runNow(function() m.mExtra.mFeatures.set(ft, true));
				checkFeature(dce, ft);
				visit(inner);
			// keep toString method of T when array<T>.join() or array<T>.toString() is called
			case TCall(ef = {eexpr: TField(_, FInstance({clPath: {pack: [], name: "Array"}}, pl, {cfName: "join" | "toString"}))}, args):
				for (t in pl) toString(dce, [], t);
				visit(ef);
				for (a in args) visit(a);
			// keep toString method when the class is argument to Std.string or haxe.Log.trace
			case TCall(ef = {eexpr: TField({eexpr: TTypeExpr(TClassDecl(c))}, FStatic(_, {cfName: name}))}, args)
				if (args.length > 0
					&& (Globals.sTypePath(c.clPath) == "haxe.Log"
						&& name == "trace"
						|| Globals.sTypePath(c.clPath) == "Std"
						&& name == "string")):
				markClass(dce, c);
				toString(dce, [], args[0].etype);
				switch args.slice(1) {
					case [{eexpr: TObjectDecl(fl)}]: for (f in fl) if (f.key.name == "customParams") {
							switch f.expr.eexpr {
								case TArrayDecl(el): for (a in el) toString(dce, [], a.etype);
								case _:
							}
							break;
						}
					case _:
				}
				visit(ef);
				for (a in args) visit(a);
			case TCall(inner = {eexpr: TConst(TSuper)}, el):
				markT(dce, inner.epos, inner.etype);
				for (a in el) visit(a);
			case TUnop(Increment | Decrement, _, e1 = {eexpr: TArray(_, _)}):
				checkAndAddFeature(dce, "array_write");
				checkAndAddFeature(dce, "array_read");
				visit(e1);
			case TBinop(OpAdd | OpAssignOp(OpAdd), e1, e2) if (isDynamic(e1.etype) || isDynamic(e2.etype)):
				checkAndAddFeature(dce, "add_dynamic");
				pair(e1, e2);
			case TBinop(op = OpAdd | OpAssignOp(OpAdd), e1, e2)
				if ((isString(e1.etype) || isString(e2.etype)) && !(isConstString(e1) && isConstString(e2))):
				// add array_write if we're doing += to an array element, since this pattern comes before the array_write one
				switch [op, e1.eexpr] {
					case [OpAssignOp(_), TArray({etype: t}, _)] if (isArray(t)): checkAndAddFeature(dce, "array_write");
					case _:
				}
				checkAndAddFeature(dce, "unsafe_string_concat");
				pair(e1, e2);
			case TArray(e1 = {etype: TDynamic(null)}, e2):
				checkAndAddFeature(dce, "dynamic_array_read");
				pair(e1, e2);
			case TBinop(OpAssign, e1 = {eexpr: TArray({etype: TDynamic(null)}, _)}, e2):
				checkAndAddFeature(dce, "dynamic_array_write");
				pair(e1, e2);
			case TBinop(OpAssignOp(op), e1 = {eexpr: TArray({etype: TDynamic(null)}, _)}, e2):
				checkOp(dce, op);
				checkAndAddFeature(dce, "dynamic_array_write");
				pair(e1, e2);
			case TArray(e1, e2) if (isArray(e1.etype)):
				checkAndAddFeature(dce, "array_read");
				pair(e1, e2);
			case TBinop(OpAssign | OpAssignOp(_), e1 = {eexpr: TArray({etype: t}, _)}, e2) if (isArray(t)):
				checkAndAddFeature(dce, "array_write");
				pair(e1, e2);
			case TBinop(OpAssign, e1 = {eexpr: TField(_, fa = FDynamic(_))}, e2):
				checkDynamicWrite(dce, fa);
				pair(e1, e2);
			case TBinop(OpAssign, e1 = {eexpr: TField(_, fa = FAnon(cf))}, e2):
				if (Meta.has(Optional, cf.cfMeta)) checkAnonOptionalWrite(dce, fa);
				else checkAnonWrite(dce, fa);
				pair(e1, e2);
			case TBinop(OpAssignOp(op), e1 = {eexpr: TField(_, fa = FDynamic(_))}, e2):
				checkOp(dce, op);
				checkDynamicWrite(dce, fa);
				pair(e1, e2);
			case TBinop(OpAssignOp(op), e1 = {eexpr: TField(_, fa = FAnon(cf))}, e2):
				checkOp(dce, op);
				if (Meta.has(Optional, cf.cfMeta)) checkAnonOptionalWrite(dce, fa);
				else checkAnonWrite(dce, fa);
				pair(e1, e2);
			case TBinop(OpEq, e1, e2) if (isDynamic(e1.etype) || isDynamic(e2.etype)):
				checkAndAddFeature(dce, "dynamic_binop_==");
				pair(e1, e2);
			case TBinop(OpEq, e1, e2)
				if (core.TOther.ExtType.isTypeParam(follow(e1.etype)) || core.TOther.ExtType.isTypeParam(follow(e2.etype))):
				checkAndAddFeature(dce, "type_param_binop_==");
				pair(e1, e2);
			case TBinop(OpNotEq, e1, e2) if (isDynamic(e1.etype) || isDynamic(e2.etype)):
				checkAndAddFeature(dce, "dynamic_binop_!=");
				pair(e1, e2);
			case TBinop(OpNotEq, e1, e2)
				if (core.TOther.ExtType.isTypeParam(follow(e1.etype)) || core.TOther.ExtType.isTypeParam(follow(e2.etype))):
				checkAndAddFeature(dce, "type_param_binop_!=");
				pair(e1, e2);
			case TBinop(op, e1, e2):
				checkOp(dce, op);
				pair(e1, e2);
			case TCall(e2 = {eexpr: TField(ef, fa)}, el):
				markT(dce, e2.epos, e2.etype);
				exprField(dce, ef, fa, true);
				for (a in el) visit(a);
			case TField(inner, fa):
				exprField(dce, inner, fa, false);
			case TThrow(inner):
				checkAndAddFeature(dce, "has_throw");
				visit(inner);
				function strings(e:TExpr):Void {
					toString(dce, [], e.etype);
					iter(strings, e);
				}
				strings(inner);
			case _:
				iter(visit, e);
		}
	}

	public static function fixAccessors(types:Array<ModuleType>):Void for (mt in types) switch mt {
		// filter empty abstract implementation classes (issue #1885).
		case TClassDecl(c = {clKind: KAbstractImpl(_)})
			if (c.clOrderedStatics.length == 0 && c.clOrderedFields.length == 0 && !hasClassFlag(c, CUsed)):
			addClassFlag(c, CExtern);
		case TClassDecl(c = {clKind: KAbstractImpl(a)}) if (a.aEnum):
			// also filter abstract implementation classes that have only @:enum fields (issue #2858)
			if (!exists(cf -> !hasClassFieldFlag(cf, CfEnum), c.clOrderedStatics)) addClassFlag(c, CExtern);
		case TClassDecl(c):
			function hasAccessor(c:TClass, name:String,
					stat:Bool):Bool return (stat ? c.clStatics : c.clFields).exists(name) || c.clSuper != null
					&& hasAccessor(c.clSuper.cls, name, stat);
			inline function checkProp(stat:Bool, cf:TClassField):Void {
				switch cf.cfKind {
					case Var({vRead: read = AccCall | AccPrivateCall, vWrite: write}):
						cf.cfKind = Var({vRead: hasAccessor(c, "get_" + cf.cfName, stat) ? read : AccNever, vWrite: write});
					case _:
				}
				switch cf.cfKind {
					case Var({vRead: read, vWrite: write = AccCall | AccPrivateCall}):
						cf.cfKind = Var({vRead: read, vWrite: hasAccessor(c, "set_" + cf.cfName, stat) ? write : AccNever});
					case _:
				}
			}
			for (cf in c.clOrderedStatics) checkProp(true, cf);
			for (cf in c.clOrderedFields) checkProp(false, cf);
		case _:
	}

	public static function extractIfFeature(meta:Metadata):Array<String> {
		for (m in meta) if (m.meta == core.MetaList.StrictMeta.IfFeature) return m.exprs.mapToArray(e -> switch e.expr {
			case EConst(String(s, _)): s;
			case _: core.Error.raiseTypingError("String expected", e.pos);
		});
		return [];
	}

	public static function collectEntryPoints(dce:DceData, types:Array<ModuleType>):Void {
		// port: `f :: !delayed` as a push, run from the end
		var delayed:Array<Void->Void> = [];
		inline function feature(ref:ClassFieldRef, names:Array<String>):Void for (s in names) {
			if (dce.features.exists(s)) dce.features.get(s).unshift(ref);
			else dce.features.set(s, [ref]);
		}
		for (t in types) switch t {
			case TClassDecl(c):
				removeClassFlag(c, CUsed);
				var classFeatures = extractIfFeature(c.clMeta);
				var keepClass = keepWholeClass(dce, c) && (!hasClassFlag(c, CExtern) || hasClassFlag(c, CInterface));
				var isStruct = dce.scom.platform == Hl && Meta.has(Struct, c.clMeta);
				inline function loop(kind:ClassFieldRefKind, cf:TClassField):Void {
					var ref = mkClassFieldRef(c, cf, kind, dce.scom.isMacroContext);
					feature(ref, classFeatures.concat(extractIfFeature(cf.cfMeta)));
					// Have to delay mark_field so that we see all @:ifFeature
					// a @:dce field is not kept just because its class is: it must be reached like in full DCE
					if (keepClass && !fieldForcesDce(cf) || isStruct || keepField(dce, cf, c,
						kind)) delayed.push(function() markField(dce, c, cf, kind));
				}
				for (cf in c.clOrderedStatics) loop(CfrStatic, cf);
				for (cf in c.clOrderedFields) loop(CfrMember, cf);
				if (c.clConstructor != null) loop(CfrConstructor, c.clConstructor);
				if (c.clInit != null && (keepClass || Meta.has(KeepInit, c.clMeta))) loop(CfrInit, c.clInit);
			case TEnumDecl(en) if (keepWholeEnum(dce, en)):
				en.eMeta = Meta.remove(Used, en.eMeta);
				delayed.push(function() {
					var c:TClass = core.ds.Record.copy(nullClass);
					c.clModule = en.eModule;
					markEnum(pushClass(dce, c), en);
				});
			case _:
		}
		var i = delayed.length;
		while (i > 0) delayed[--i]();
		if (dce.debug) for (item in dce.addedFields) if (item.field.cfExpr != null) Sys.println("[DCE] Entry point: "
			+ Globals.sTypePath(item.cls.clPath) + "." + item.field.cfName);
	}

	public static function mark(pool:Null<core.ds.TaskPool>, dce:DceData):Void while (dce.addedFields.length > 0) {
		var cfl = dce.addedFields.copy();
		dce.addedFields.resize(0);
		for (k in dce.checkedFeatures.keys()) dce.features.remove(k);
		dce.checkedFeatures.clear();
		dce.addFeatureManager.handleLater();
		// extend to dependent (= overriding/implementing) class fields
		context.Parallel.ParallelArray.iter(pool, function(item) {
			var c:TClass = item.cls;
			var cf:TClassField = item.field;
			var kind:ClassFieldRefKind = item.kind;
			markDependentFields(dce, c, cf.cfName, kind);
			var local = pushClass(dce, c);
			if (isPhysicalField(cf)) markClass(local, c);
			markField(local, c, cf, kind);
			markT(local, cf.cfPos, cf.cfType);
			if (!hasClassFlag(c, CExtern)) {
				opt(expr.bind(local), cf.cfExpr);
				for (overloadedField in cf.cfOverloads) if (overloadedField.cfExpr != null) opt(expr.bind(local), overloadedField.cfExpr);
			}
		}, cfl);
	}

	public static function sweep(dce:DceData, types:Array<ModuleType>):Array<ModuleType> {
		// port: `mt :: acc` as a push, the accumulator reversed once at the end
		var acc = [];
		var reverse = types.copy();
		reverse.reverse();
		for (mt in reverse) switch mt {
			case TClassDecl(c) if (keepWholeClass(dce, c) && !classHasDceField(c)):
				acc.push(mt);
			case TClassDecl(c):
				inline function checkProperty(cf:TClassField, stat:Bool):Void {
					inline function addAccessor(name:String):Void {
						var cf = (stat ? c.clStatics : c.clFields).get(name);
						if (cf != null && !Meta.has(Accessor, cf.cfMeta)) cf.cfMeta.unshift({
							meta: core.MetaList.StrictMeta.Accessor,
							exprs: vector(),
							pos: Globals.mkZeroRangePos(c.clPos)
						});
					}
					switch cf.cfKind {
						case Var({vRead: AccCall | AccPrivateCall, vWrite: _}):
							addAccessor("get_" + cf.cfName);
						case _:
					}
					switch cf.cfKind {
						case Var({vRead: _, vWrite: AccCall | AccPrivateCall}):
							addAccessor("set_" + cf.cfName);
						case _:
					}
				}
				// a kept-whole class only reaches this branch because of @:dce fields:
				// keep all of its fields except the @:dce ones that DCE did not reach
				var classKept = keepWholeClass(dce, c);
				inline function keep(cf:TClassField,
						kind:ClassFieldRefKind):Bool return classKept && !fieldForcesDce(cf) || keepField(dce, cf, c, kind);
				// add :keep so subsequent filter calls do not process class fields again
				c.clMeta.unshift(mkKeepMeta(c.clPos));
				inline function filter(cf:TClassField, kind:ClassFieldRefKind):Bool {
					var b = keep(cf, kind);
					if (!b) {
						if (dce.debug) Sys.println("[DCE] Removed field " + Globals.sTypePath(c.clPath) + "." + cf.cfName);
						var stat = kind == CfrStatic;
						checkProperty(cf, stat);
						(stat ? c.clStatics : c.clFields).remove(cf.cfName);
					}
					return b;
				}
				c.clOrderedStatics = c.clOrderedStatics.filter(cf -> filter(cf, CfrStatic));
				c.clOrderedFields = c.clOrderedFields.filter(cf -> filter(cf, CfrMember));
				if (c.clConstructor != null && !keep(c.clConstructor, CfrConstructor)) c.clConstructor = null;
				var nonExtern = exists(isPhysicalField, c.clOrderedFields) || exists(isPhysicalField, c.clOrderedStatics);
				// we keep a class if it is kept whole, was used or has a used field
				if (classKept || hasClassFlag(c, CUsed) || nonExtern) acc.push(mt);
				else if (core.TOther.TClassTools.getClInit(c) != null && Meta.has(KeepInit, c.clMeta)) {
					// it means that we only need the __init__ block
					addClassFlag(c, CExtern);
					acc.push(mt);
				} else if (dce.debug) Sys.println("[DCE] Removed class " + Globals.sTypePath(c.clPath));
			case TEnumDecl(en) if (Meta.has(Used, en.eMeta) || hasEnumFlag(en, EnExtern) || keepWholeEnum(dce, en)):
				acc.push(mt);
			case TEnumDecl(en):
				if (dce.debug) Sys.println("[DCE] Removed enum " + Globals.sTypePath(en.ePath));
			case _:
				acc.push(mt);
		}
		acc.reverse();
		return acc;
	}

	public static function run(pool:Null<core.ds.TaskPool>, scom:SafeContext, mscom:Null<SafeContext>, main:Null<TExpr>, mode:DceMode,
			stdPaths:Array<core.ClassPath.IClassPath>, types:Array<ModuleType>):Array<ModuleType> {
		var full = mode == DceFull;
		var dce:DceData = {
			scom: scom,
			mscom: mscom,
			full: full,
			stdDirs: full ? [] : stdPaths.map(path -> core.Path.getFullPath(path.path)),
			debug: core.Define.defined(scom.defines, core.Define.DceDebug),
			addedFields: [],
			followExpr: expr,
			markedFields: {
				value: []
			},
			features: new haxe.ds.StringMap(),
			checkedFeatures: new haxe.ds.StringMap(),
			curclass: nullClass,
			mergeMutex: new sys.thread.Mutex(),
			fieldMarkerMutex: new sys.thread.Mutex(),
			usedMutex: new sys.thread.Mutex(),
			featureMutex: new sys.thread.Mutex(),
			addFeatureManager: new core.ds.NowOrLater()
		};
		// first step: get all entry points, which is the main method and all class methods which are marked with @:keep
		core.Timer.time(scom.timerCtx, ["filters", "dce", "collect"], function(_:Null<Bool>) collectEntryPoints(dce, types), null);
		// second step: initiate DCE passes and keep going until no new fields were added
		core.Timer.time(scom.timerCtx, ["filters", "dce", "mark"], function(_:Null<Bool>) mark(pool, dce), null);
		// third step: filter types
		if (mode != DceNo) types = core.Timer.time(scom.timerCtx, ["filters", "dce", "sweep"],
			function(_:Null<Bool>) return sweep(dce, types), null);
		core.Timer.time(scom.timerCtx, ["filters", "dce", "cleanup"], function(_:Null<Bool>) {
			// extra step to adjust properties that had accessors removed (required for Php and Cpp)
			fixAccessors(types);
			// remove "override" from fields that do not override anything anymore
			for (mt in types) switch mt {
				case TClassDecl(c):
					for (cf in c.clOrderedFields) if (hasClassFieldFlag(cf, CfOverride)) {
						var cur = c;
						var found = false;
						while (cur.clSuper != null) {
							cur = cur.clSuper.cls;
							if (cur.clFields.exists(cf.cfName)) {
								found = true;
								break;
							}
						}
						if (!found) removeClassFieldFlag(cf, CfOverride);
					}
				case _:
			}
			/*
				Mark extern classes as really used if they are extended by non-extern ones.
			*/
			for (mt in types) switch mt {
				case TClassDecl(c) if (c.clSuper != null && !hasClassFlag(c, CExtern) && hasClassFlag(c.clSuper.cls, CExtern)):
					markDirectlyUsedClass(dce, c.clSuper.cls);
				case TClassDecl(c) if (!hasClassFlag(c, CExtern) && c.clImplements.length > 0):
					for (ct in c.clImplements) if (hasClassFlag(ct.cls, CExtern)) markDirectlyUsedClass(dce, ct.cls);
				case _:
			}
			// cleanup added fields metadata - compatibility with compilation server
			for (cf in dce.markedFields.value) removeClassFieldFlag(cf, CfUsed);
		}, null);
		return types;
	}
}
