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

package generators;

import haxe.io.Bytes;
import core.Globals;
import core.Globals.*;
import core.Ast;
import core.TType;
import core.TFunctions;
import core.TFunctions.*;
import core.TUnification;
import core.TUnification.Unify_error;
import core.TUnification.Monomorph;
import core.TOther.ExtType;
import core.TOther.TClassTools;
import core.Texpr;
import core.Texpr.Builder as TexprBuilder;
import core.Abstract;
import core.Define;
import core.Timer;
import core.MetaList;
import core.ds.Failure;
import core.ds.NotFound;
import core.ds.OcamlHash;
import core.ds.OcamlHash.OcamlValue;
import core.ds.OcamlHashtbl;
import generators.Gctx;
import generators.Genshared;
import generators.jvm.JvmGlobals;
import generators.jvm.JvmData;
import generators.jvm.JvmAttribute;
import generators.jvm.JvmSignature;
import generators.jvm.JvmSignature.NativeSignatures.*;
import generators.jvm.JvmBuilder;
import generators.jvm.JvmCode;
import generators.jvm.JvmConstantPool;
import generators.jvm.JvmClass;
import generators.jvm.JvmMethod;
import generators.jvm.JvmFunctions;
import typing.TanonIdentification;
import typing.OverloadResolution;
import filters.exception.ExceptionFunctions;

private typedef MetaTag = core.MetaList.StrictMeta;

/* Note: This module is the bridge between Haxe structures and JVM structures. No module in generators/jvm should reference any
	 Haxe-specific type. */
/* Haxe */
@:structInit class Mutexes {
	public final writeClass:sys.thread.Mutex;
	public final unify:sys.thread.Mutex;
	public final closureLookup:sys.thread.Mutex;
}

/* One shared top-level closure class per (path_this, name). Codegen sites
	 register their signature(s) here; materialization (constructor / invoke
	 methods / equals / write_class) happens in generate_closures at the end
	 of the build, after all sites have contributed their invokes and FI
	 associations. */
@:structInit class ClosureRecord {
	public final crPath:JPath;
	public final crWf:TypedFunction;
	public final crPendingSigs:OcamlHashtbl<JSignature, Bool>;
}

// port: `(path * string)`, the key of `closure_paths`.
@:structInit class ClosureKey {
	public final path:GlobalTypePath;
	public final name:String;
}

// port: Zip_output.any_output, with binary entries.
class JvmOutput {
	public function addEntry(content:Bytes, name:String):Void throw new Failure("Not implemented");

	// port: add_entry in two steps, for write_class: what leaves the output untouched (a jar
	// ... entry's CRC and compression) is done here, outside the write_class lock; the function
	// ... returned adds the entry, under it.
	public function prepareEntry(content:Bytes, name:String):Void->Void return function() addEntry(content, name);

	public function close():Void throw new Failure("Not implemented");
}

class JarOutput extends JvmOutput {
	final zip:core.ZipOutput;

	public function new(path:String, compressionLevel:Int) {
		zip = new core.ZipOutput(path, compressionLevel);
	}

	override public function addEntry(content:Bytes, name:String):Void zip.addBytesEntry(content, name);

	override public function prepareEntry(content:Bytes, name:String):Void->Void {
		var entry = zip.makeEntry(content, name);
		return function() zip.addPreparedEntry(entry);
	}

	override public function close():Void zip.close();
}

class FileOutput extends JvmOutput {
	final basePath:String;

	public function new(basePath:String) {
		this.basePath = basePath;
	}

	override public function addEntry(content:Bytes, name:String):Void {
		var path = basePath + name;
		core.Path.mkdirFromPath(path);
		sys.io.File.saveBytes(path, content);
	}

	override public function close():Void {}
}

@:structInit class GenerationContext {
	public final gctx:Gctx;
	public final out:JvmOutput;
	public final tRuntimeException:T;
	public final entryPoint:Null<{cls:TClass, expr:TExpr}>;
	public final tException:T;
	public final tThrowable:T;
	public final anonIdentification:TanonIdentification<JSignature>; /* guards itself */
	public var functionalInterfaces:Array<{c:TClass, cf:TClassField, jfi:JavaFunctionalInterface}>; /* final after preprocessing */
	public var preprocessor:Preprocessor<JSignature>; /* final after preprocessing */
	public final defaultExportConfig:ExportConfig;
	public final typedFunctions:TypedFunctions; /* guards itself */
	public final closurePaths:OcamlHashtbl<ClosureKey, ClosureRecord>; /* guarded by mutexes.closure_lookup */
	// port: only used for lookups (keyed by path, name and JvmSignature.jsigKey).
	public final staticClosurePaths:haxe.ds.StringMap<JPath>; /* guarded by mutexes.closure_lookup */
	// port: only used for lookups.
	public final enumPaths:haxe.ds.StringMap<Bool>; /* final after preprocessing */
	public final detailTimes:Bool;
	public var typedefInterfaces:TypedefInterfaces<JSignature>; /* final after preprocessing */
	public final jarCompressionLevel:Int;
	public final dynamicLevel:Int;
	public final mutexes:Mutexes;
}

enum Ret {
	RValue(jsig:Null<JSignature>, name:Null<String>);
	RVoid;
	RReturn;
}

enum AccessKind {
	AKPost;
	AKPre;
	AKNone;
}

enum CompareKind {
	CmpNormal(op:JCmp, jsig:JSignature);
	CmpSpecial(f:JBranchOffsetRef->Void);
}

enum BlockExit {
	ExitExecute(f:Void->Void);
	ExitLoop;
}

@:structInit class TransformedArg {
	public final aId:Int;
	public final aName:String;
	public final aJsigArg:JSignature;
	public final aJsigLocal:Null<JSignature>;
	public final aTexpr:Null<TExpr>;
}

enum SuperCtorMode {
	SCNone;
	SCJava;
	SCHaxe;
}

class Genjvm {
	/* hacks */
	public static function isReallyInt(t:T):Bool {
		return !isNullable(t) && ExtType.isInt(TFunctions.follow(t));
	}

	/* Due to @:native, the usual String path doesn't match */
	public static function isString(t:T):Bool return switch t {
		case TInst({clPath: {pack: [], name: "String"} | {pack: ["java", "lang"], name: "String"}}, _): true;
		case _: false;
	}

	public static function getConstructionMode(c:TClass, cf:TClassField):ConstructionKind {
		return if (core.Meta.has(MetaTag.HxGen, cf.cfMeta)) ConstructInitPlusNew else ConstructInit;
	}

	/* DEX (pre-040) SimpleName grammar: Java-identifier-ish. We use a conservative
		 ASCII subset so the predicate is stable across DEX versions and so we don't
		 need to track which extra Unicode code points each release allows. */
	public static function isDexSafeSimpleName(name:String):Bool {
		var b = Bytes.ofString(name);
		var len = b.length;
		if (len == 0) return false;
		inline function isStart(c:Int):Bool return (c >= "A".code && c <= "Z".code) || (c >= "a".code && c <= "z".code) || c == "_".code
			|| c == "$".code;
		inline function isCont(c:Int):Bool return isStart(c) || (c >= "0".code && c <= "9".code);
		if (!isStart(b.get(0))) return false;
		for (i in 1...len) if (!isCont(b.get(i))) return false;
		return true;
	}

	public static function needVal(r:Ret):Bool return switch r {
		case RValue(_): true;
		case _: false;
	}

	public static function runTimed<R>(gctx:GenerationContext, detail:Bool, name:String, f:Void->R):R {
		if (detail && !gctx.detailTimes) return f() else {
			var timerCtx = gctx.gctx.timerCtx;
			return Timer.time(timerCtx, timerCtx.current.id.concat([name]), function(_:Null<Bool>) return f(), null);
		}
	}

	public static function pathKey(p:GlobalTypePath):String return p.pack.join(".") + ":" + p.name;

	public static inline function isPathOf(p:GlobalTypePath, pack:Array<String>, name:String):Bool return isPath(p, pack, name);

	static function isPath(p:GlobalTypePath, pack:Array<String>, name:String):Bool {
		if (p.name != name || p.pack.length != pack.length) return false;
		for (i in 0...pack.length) if (p.pack[i] != pack[i]) return false;
		return true;
	}

	public static function jsignatureOfPath(path:GlobalTypePath):JSignature {
		return switch [path.pack, path.name] {
			case [[], "Bool"]: JBool;
			case [["jvm"], "Int8"]: JByte;
			case [["jvm"], "Int16"]: JShort;
			case [[], "Int"]: JInt;
			case [["haxe"], "Int32"]: JInt;
			case [["haxe"], "Int64"]: JLong;
			case [["jvm"], "Int64"]: JLong;
			case [["jvm"], "Char16"]: JChar;
			case [[], "Single"]: JFloat;
			case [[], "Float"]: JDouble;
			case [[], "Dynamic"]: objectSig;
			case _: throw core.ds.Exit.raise();
		}
	}

	static function jsignatureOfType0(gctx:GenerationContext, stack:Array<T>, t:T):JSignature {
		if (Lambda.exists(stack, function(t2) return TUnification.fastEq(t, t2))) return objectSig;
		var stack2 = [t].concat(stack);
		inline function jsignatureOfType(t:T):JSignature return jsignatureOfType0(gctx, stack2, t);
		inline function jtypeArgumentOfType(t:T):JTypeArgument return jtypeArgumentOfType0(gctx, stack, t);
		return switch t {
			case TAbstract(a, tl):
				try {
					jsignatureOfPath(a.aPath);
				} catch (_:core.ds.Exit) {
					switch [a.aPath.pack, a.aPath.name] {
						case [[], "Void"]: voidSig;
						case [[], "Null"]:
							switch tl {
								case [t]: getBoxedType(jsignatureOfType(t));
								case _: die("", "generators/genjvm.ml");
							}
						case [["haxe", "ds"], "Vector"]:
							switch tl {
								case [t]: JArray(jsignatureOfType(t), null);
								case _: die("", "generators/genjvm.ml");
							}
						case [[], ("Class" | "Enum")]:
							switch tl {
								case [t]: JObject(javaClassPath, [JTType(WNone, jsignatureOfType(t))]);
								case _: javaClassSig;
							}
						case [[], "EnumValue"]:
							javaEnumSig(objectSig);
						case [["haxe", "coro"], "Coroutine"]:
							switch tl {
								case [TFun(s)]:
									var s = context.Common.expandCoroType(gctx.gctx.basic, s.args, s.ret);
									jsignatureOfType(TFun(s));
								case _:
									die("", "generators/genjvm.ml");
							}
						case _:
							if (core.Meta.has(MetaTag.CoreType, a.aMeta)) JObject(a.aPath, tl.map(function(t) return jtypeArgumentOfType(t))) else
								jsignatureOfType(Abstract.getUnderlyingType(a, tl));
					}
				}
			case TDynamic(_): objectSig;
			case TMono(r):
				switch r.tmType {
					case null: objectSig;
					case t: jsignatureOfType(t);
				}
			case TInst({clPath: {pack: ["haxe", "root"], name: "String"}}, []): stringSig;
			case TInst({clPath: {pack: ["haxe", "root"], name: "Array"}}, [t]):
				var t = getBoxedType(jsignatureOfType(t));
				JObject({pack: ["haxe", "root"], name: "Array"}, [JTType(WNone, t)]);
			case TInst({clPath: {pack: ["jvm"], name: "NativeArray"}}, [t]):
				JArray(jsignatureOfType(t), null);
			case TInst({clKind: KTypeParameter(ttp), clPath: {name: name}}, _):
				switch getConstraints(ttp) {
					case [t] if (t != tDynamic): jsignatureOfType(t);
					case _: JTypeParameter(name);
				}
			case TInst({clPath: {pack: ["_Class"], name: "Class_Impl_"}}, _): javaClassSig;
			case TInst({clPath: {pack: ["_Enum"], name: "Enum_Impl_"}}, _): javaClassSig;
			case TInst(c, tl): JObject(c.clPath, tl.map(function(t) return jtypeArgumentOfType(t)));
			case TEnum(en, tl):
				JObject(en.ePath, tl.map(function(t) return jtypeArgumentOfType(t)));
			case TFun(s):
				methodSig(s.args.map(function(a) {
					var jsig = jsignatureOfType(a.type);
					var jsig = if (a.optional) getBoxedType(jsig) else jsig;
					return jsig;
				}), returnOfType0(gctx, stack, s.ret));
			case TAnon(an): objectSig;
			case TType(td, tl):
				switch gctx.typedefInterfaces.getInterfaceClass(td.tPath) {
					case null: jsignatureOfType(applyTypedef(td, tl));
					case c: JObject(c.clPath, []);
				}
			case TLazy(f): jsignatureOfType(lazyType(f));
		}
	}

	static function jtypeArgumentOfType0(gctx:GenerationContext, stack:Array<T>, t:T):JTypeArgument {
		var jsig = jsignatureOfType0(gctx, stack, t);
		var jsig = getBoxedType(jsig);
		return JTType(WNone, jsig);
	}

	static function returnOfType0(gctx:GenerationContext, stack:Array<T>, t:T):Null<JSignature> {
		return if (ExtType.isVoid(TFunctions.follow(t))) null else jsignatureOfType0(gctx, stack, t);
	}

	public static function jsignatureOfType(gctx:GenerationContext, t:T):JSignature return jsignatureOfType0(gctx, [], t);

	public static function jtypeArgumentOfType(gctx:GenerationContext, stack:Array<T>, t:T):JTypeArgument return jtypeArgumentOfType0(gctx,
		stack, t);

	public static function returnOfType(gctx:GenerationContext, t:T):Null<JSignature> return returnOfType0(gctx, [], t);

	public static function convertFields(gctx:GenerationContext, pfm:PathFieldMapping<JSignature>):Array<{name:String, value:JSignature}> {
		return switch pfm.pfmConverted {
			case null:
				var names = [for (n in pfm.pfmFields.keys()) n];
				names.sort(TypedefInterfaces.compareStrings);
				var l = names.map(function(s) return {name: s, value: jsignatureOfType(gctx, pfm.pfmFields.get(s).cfType)});
				pfm.pfmConverted = l;
				l;
			case l:
				l;
		}
	}

	public static function enumCtorSig():JSignature {
		var ta = JArray(objectSig, null);
		return methodSig([JInt, ta], null);
	}

	public static function convertCmpOp(op:Binop):JCmp return switch op {
		case OpEq: CmpEq;
		case OpNotEq: CmpNe;
		case OpLt: CmpLt;
		case OpLte: CmpLe;
		case OpGt: CmpGt;
		case OpGte: CmpGe;
		case _: die("", "generators/genjvm.ml");
	}

	public static function flipCmpOp(op:JCmp):JCmp return switch op {
		case CmpEq: CmpNe;
		case CmpNe: CmpEq;
		case CmpLt: CmpGe;
		case CmpLe: CmpGt;
		case CmpGt: CmpLe;
		case CmpGe: CmpLt;
	}

	public static function resolveClass(com:Gctx, path:GlobalTypePath):TClass {
		for (t in com.types) switch t {
			case TClassDecl(c) if (context.Common.samePath(c.clPath, path)):
				return c;
			case _:
		}
		return JvmGlobals.jerror("No such type: " + sTypePath(path));
	}

	// port: upstream guards only associate_functional_interfaces' unification with mutexes.unify.
	// ... The others of code generation (does_unify, overload resolution) can bind monomorphs that
	// ... the typed AST shares between types, and add constraints to them: Haxe arrays, which the port
	// ... cannot mutate from several threads at once. They take the mutex too.
	public static function guardUnify<R>(gctx:GenerationContext, f:Void->R):R {
		gctx.mutexes.unify.acquire();
		var r = try f() catch (e:Dynamic) {
			gctx.mutexes.unify.release();
			throw e;
		}
		gctx.mutexes.unify.release();
		return r;
	}

	public static function writeClass(gctx:GenerationContext, path:JPath, jc:JvmClassData):Void {
		var dir = switch path.pack {
			case []: path.name;
			case sl: sl.join("/") + "/" + path.name;
		}
		var path = dir + ".class";
		Timer.time(gctx.gctx.timerCtx, ["generate", "jvm", "write"], function(_:Null<Bool>) {
			var ch = new OutputBytes();
			generators.jvm.JvmWriter.writeJvmClass(ch, jc);
			var bytes = ch.closeOut();
			var addEntry = gctx.out.prepareEntry(bytes, path);
			gctx.mutexes.writeClass.acquire();
			try
				addEntry()
			catch (e:Dynamic) {
				gctx.mutexes.writeClass.release();
				throw e;
			}
			gctx.mutexes.writeClass.release();
			return null;
		}, null);
	}

	public static function isConstIntPattern(c:TSwitchCase):Bool {
		return Lambda.foreach(c.casePatterns, function(e) return switch e.eexpr {
			case TConst(TInt(_)): true;
			case _: false;
		});
	}

	public static function isConstStringPattern(c:TSwitchCase):Bool {
		return Lambda.foreach(c.casePatterns, function(e) return switch e.eexpr {
			case TConst(TString(_)): true;
			case _: false;
		});
	}

	public static function isInterfaceVarAccess(c:TClass, cf:TClassField):Bool {
		return hasClassFlag(c, CInterface) && switch cf.cfKind {
			case Var(_) | Method(MethDynamic): true;
			case _: false;
		}
	}

	public static function dynamicFieldOwner(c:TClass, cf:TClassField):TClass {
		return switch c.clSuper {
			case sup if (sup != null && cf.cfKind.match(Method(MethDynamic)) && hasClassFieldFlag(cf, CfOverride)):
				var csup = sup.cls;
				dynamicFieldOwner(csup, switch csup.clFields.get(cf.cfName) {
					case null: cf;
					case cf2: cf2;
				});
			case _:
				c;
		}
	}

	// port: `let follow = Abstract.follow_with_abstracts` shadows Type.follow from here on.
	static inline function followA(t:T):T return Abstract.followWithAbstracts(t);

	public static function generateEqualsFunction(jc:JvmClassBuilder, jsigArg:JSignature):{jm:JvmMethodBuilder, load:Void->Void} {
		var jmEquals = jc.spawnMethod("equals", methodSig([jsigArg], JBool), [MPublic]);
		var code = jmEquals.getCode();
		var load = jmEquals.addLocal("other", jsigArg, VarArgument).load;
		jmEquals.finalizeArguments();
		load();
		code.instanceof(jc.getThisPath());
		jmEquals.ifThen(function(r) code.if_(CmpNe, r), function() {
			code.bconst(false);
			jmEquals.return_();
		});
		load();
		var l = jmEquals.addLocal("other", jc.getJsig(), VarWillInit);
		jmEquals.cast_(jc.getJsig());
		l.store();
		return {jm: jmEquals, load: l.load};
	}

	public static function associateFunctionalInterfaces(gctx:GenerationContext, f:TypedFunction, t:T):Void {
		if (!hasMono(t)) {
			for (e in gctx.functionalInterfaces) {
				var c = e.c, cf = e.cf, jfi = e.jfi;
				var cMonos = Monomorph.spawnConstrainedMonos(function(t) return t, c.clParams);
				function map(t:T):T return applyParams(c.clParams, cMonos, t);
				var cfMonos = Monomorph.spawnConstrainedMonos(map, cf.cfParams);
				try {
					gctx.mutexes.unify.acquire();
					try {
						TUnification.unifyCustom(TUnification.nativeUnificationContext, t, applyParams(cf.cfParams, cfMonos, map(cf.cfType)));
						cfMonos.map(followA);
						f.addFunctionalInterface(jfi, cMonos.map(jsignatureOfType.bind(gctx)));
					} catch (e:Dynamic) {
						gctx.mutexes.unify.release();
						throw e;
					}
					gctx.mutexes.unify.release();
				} catch (_:Unify_error) {}
			}
		}
	}

	public static function createTypedFunction(gctx:GenerationContext, kind:TypedFunctionKind, jc:JvmClassBuilder, jm:JvmMethodBuilder,
			context:Array<{name:String, jsig:JSignature}>):TypedFunction {
		return new TypedFunction(gctx.typedFunctions, kind, THostInner(jc), jm, context);
	}

	/* Mangle a (target_class_path, method_name) into the simple class name used
		 for its shared closure. The synthetic package `jvm.$Closure` segregates
		 them from user code; the leading `$` in the package segment makes both
		 the package and any sibling class name unreachable from Haxe source
		 (Haxe identifiers disallow `$`), so user code cannot define a class that
		 collides with — or shadows — one of these. */
	public static function closureClassName(pathThis:GlobalTypePath, name:String):String {
		var prefix = switch pathThis.pack {
			case []: pathThis.name;
			case pkg: pkg.join("_") + "_" + pathThis.name;
		}
		return 'Closure_${prefix}_${JvmGlobals.patchName(name)}';
	}

	public static final closureClassPackage = ["jvm", "$Closure"];

	/* Register N invoke signatures for the shared closure of (path_this, name),
		 creating its class builder on first hit. Each caller site invokes this
		 while emitting its own bytecode; the actual closure-class body is only
		 materialized later by generate_closures (after every caller has had a
		 chance to contribute its signatures and functional-interface bindings).

		 The site must still emit a NEW + invokespecial of the closure ctor at the
		 call point — we do that here, given the closure path is known up-front. */
	public static function registerFieldClosure(gctx:GenerationContext, jc:JvmClassBuilder, pathThis:GlobalTypePath, jm:JvmMethodBuilder,
			name:String, overloads:Array<JSignature>, f:Void->Void, t:Null<T>):Void {
		var jsigThis = objectPathSig(pathThis);
		var context = [{name: "this", jsig: jsigThis}];
		gctx.mutexes.closureLookup.acquire();
		var key:ClosureKey = {path: pathThis, name: name};
		var record = switch gctx.closurePaths.findOpt(key) {
			case null:
				var closurePath:JPath = {pack: closureClassPackage, name: closureClassName(pathThis, name)};
				var wf = new TypedFunction(gctx.typedFunctions, FuncMember(pathThis, name), THostStandalone(closurePath), jm, context);
				var r:ClosureRecord = {
					crPath: closurePath,
					crWf: wf,
					crPendingSigs: new OcamlHashtbl(function(s:JSignature) return OcamlHash.hash(JvmSignature.ocamlValueOfJsig(s)),
						JvmSignature.jsigEq, 2),
				};
				gctx.closurePaths.add(key, r);
				r;
			case r:
				r;
		}
		for (jsig in overloads) {
			if (!record.crPendingSigs.mem(jsig)) record.crPendingSigs.add(jsig, true);
		}
		gctx.mutexes.closureLookup.release();
		/* FI association is additive across sites — each caller contributes the
			 SAM types it expected. Later, generate_invoke materializes them all. */
		switch t {
			case null:
			case t: associateFunctionalInterfaces(gctx, record.crWf, t);
		}
		/* host class no longer used; kept in the signature to ease the call-site diff */
		jm.construct(ConstructInit, record.crPath, function() {
			f();
			return [jsigThis];
		});
	}

	/* Materialize all shared closure classes registered during codegen. Emits
		 each one's constructor, the accumulated invoke methods (one per unique
		 signature collected from caller sites), and an equals method. Called
		 from generate () after every type-level codegen pass has completed.

		 This always runs end-to-end every build — there's no per-class caching
		 to invalidate. JVM codegen re-walks gctx.types from scratch on every
		 compilation-server cycle, so the cache is fresh and complete each time. */
	public static function generateClosures(gctx:GenerationContext):Void {
		gctx.closurePaths.iter(function(key:ClosureKey, record:ClosureRecord) {
			var pathThis = key.path, name = key.name;
			var jcClosure = record.crWf.getClass();
			var jsigThis = objectPathSig(pathThis);
			record.crWf.generateConstructor(true);
			record.crPendingSigs.iter(function(jsig, _) switch jsig {
				case JMethod(args, ret):
					var argsNamed = [for (i in 0...args.length) {name: 'arg$i', jsig: args[i]}];
					var jmInvoke = record.crWf.generateInvoke(argsNamed, ret, []);
					var vars = argsNamed.map(function(a) return jmInvoke.addLocal(a.name, a.jsig, VarArgument));
					jmInvoke.finalizeArguments();
					jmInvoke.loadThis();
					jmInvoke.getfield(jcClosure.getThisPath(), "this", jsigThis);
					for (v in vars) v.load();
					jmInvoke.invokevirtual(pathThis, name, methodSig(args, ret));
					jmInvoke.return_();
				case _:
					die("", "generators/genjvm.ml");
			});
			var eq = generateEqualsFunction(jcClosure, objectSig);
			var jmEquals = eq.jm, load = eq.load;
			var code = jmEquals.getCode();
			jmEquals.loadThis();
			jmEquals.getfield(jcClosure.getThisPath(), "this", jsigThis);
			load();
			jmEquals.getfield(jcClosure.getThisPath(), "this", jsigThis);
			jmEquals.ifThen(function(r) code.ifAcmpEq(jcClosure.getJsig(), jcClosure.getJsig(), r), function() {
				code.bconst(false);
				jmEquals.return_();
			});
			code.bconst(true);
			jmEquals.return_();
			writeClass(gctx, jcClosure.getThisPath(), jcClosure.exportClass(gctx.defaultExportConfig));
		});
	}

	public static final rvalueAny = RValue(null, null);

	public static function rvalueSig(jsig:JSignature):Ret return RValue(jsig, null);

	public static function rvalueType(gctx:GenerationContext, t:T, name:Null<String>):Ret return RValue(jsignatureOfType(gctx, t), name);

	public static function generateDynamicAccess(gctx:GenerationContext, jc:JvmClassBuilder,
			fields:Array<{name:String, jsig:JSignature, kind:core.TType.FieldKind}>, isAnon:Bool):Void {
		/* In anon classes, unsafe-named entries aren't typed fields — they live
			 in DynamicObject's _hx_fields. Drop them from the switches so the
			 default branch (super) handles them via the map. */
		var fields = if (isAnon) fields.filter(function(f) return isDexSafeSimpleName(f.name)) else fields;
		switch fields {
			case []:
			case _:
				var jsig = methodSig([stringSig], objectSig);
				var jm = jc.spawnMethod("_hx_getField", jsig, [MPublic, MSynthetic]);
				var load = jm.addLocal("name", stringSig, VarArgument).load;
				jm.finalizeArguments();
				/* Group fields by name. When `@:overload @:native(X)` or similar makes
					 several Haxe fields share a JVM name, they end up in the same group
					 and produce a single switch case + a single merged closure class. */
				var grouped = {
					var h = new haxe.ds.StringMap<Array<{jsig:JSignature, kind:core.TType.FieldKind}>>();
					var order = [];
					for (f in fields) {
						if (!h.exists(f.name)) order.unshift(f.name);
						var prev = h.exists(f.name) ? h.get(f.name) : [];
						h.set(f.name, [{jsig: f.jsig, kind: f.kind}].concat(prev));
					}
					// port: List.rev_map over the reversed order list
					var r = [];
					for (name in order) {
						var l = h.get(name).copy();
						l.reverse();
						r.unshift({name: name, entries: l});
					}
					r;
				}
				var cases = grouped.map(function(g) {
					var name = g.name, entries = g.entries;
					return {
						sl: [name],
						f: function() {
							function emitField(jsig:JSignature) {
								jm.loadThis();
								jm.getfield(jc.getThisPath(), name, jsig);
								jm.expectReferenceType();
							}
							function emitDynamicClosure(args:Array<JSignature>) {
								jm.loadThis();
								jm.string(name);
								jm.newNativeArray(javaClassSig, args.map(function(jsig) return function() jm.getClass(jsig)));
								jm.invokestatic(haxeJvmPath, "readFieldClosure", methodSig([objectSig, stringSig, arraySig(javaClassSig)], objectSig));
							}
							function isMethod(k:core.TType.FieldKind):Bool return switch k {
								case Method(MethNormal | MethInline): true;
								case _: false;
							}
							switch entries {
								case [e]:
									switch [e.kind, e.jsig] {
										case [Method(MethNormal | MethInline), JMethod(args, _)]:
											emitDynamicClosure(args);
										case _:
											emitField(e.jsig);
									}
								case _ if (Lambda.foreach(entries, function(e) return isMethod(e.kind))):
									/* Reflection-based dispatch; readFieldClosure's parameterTypes
										 only narrows to one overload, so pick the first deterministically. */
									var args = switch entries[0].jsig {
										case JMethod(args, _): args;
										case _: die("", "generators/genjvm.ml");
									}
									emitDynamicClosure(args);
								case _ if (entries.length > 0):
									/* Mixed kinds for the same name shouldn't occur in well-formed
										 Haxe (JVM forbids it for fields, and field+method sharing a
										 name is a Haxe-level error). Fall back to the first entry. */
									emitField(entries[0].jsig);
								case _:
									die("", "generators/genjvm.ml");
							}
							jm.replaceTop(objectSig);
						}
					};
				});
				var def = function() {
					jm.loadThis();
					load();
					jm.invokespecial(jc.getSuperPath(), "_hx_getField", jsig);
				};
				jm.stringSwitch(true, load, cases, def);
				jm.return_();
		}
		var fields = fields.filter(function(f) return switch f.kind {
			case Method(MethNormal | MethInline): false;
			case Var({vWrite: AccNever}): false;
			case _: true;
		});
		switch fields {
			case []:
			case _:
				var jsig = methodSig([stringSig, objectSig], null);
				var jm = jc.spawnMethod("_hx_setField", jsig, [MPublic, MSynthetic]);
				var load1 = jm.addLocal("name", stringSig, VarArgument).load;
				var load2 = jm.addLocal("value", objectSig, VarArgument).load;
				jm.finalizeArguments();
				load1();
				jm.invokevirtual(stringPath, "hashCode", methodSig([], JInt));
				var def = function() {
					jm.loadThis();
					load1();
					load2();
					jm.invokespecial(jc.getSuperPath(), "_hx_setField", jsig);
				};
				var cases = fields.map(function(f) {
					var name = f.name, jsig = f.jsig;
					var hash = JvmMethod.javaHash(name);
					return {
						il: [hash],
						f: function() {
							jm.loadThis();
							load2();
							jm.cast_(jsig);
							jm.putfield(jc.getThisPath(), name, jsig);
							/* Have to deal with Reflect.deleteField crap here... */
							if (isAnon) {
								jm.loadThis();
								jm.getfield(jc.getThisPath(), "_hx_deletedAField", booleanSig);
								jm.ifThen(function(r) jm.getCode().ifNull(booleanSig, r), function() {
									def();
								});
							}
						}
					};
				});
				jm.intSwitch(false, cases, def);
				jm.return_();
		}
	}

	public static function generateClass(gctx:GenerationContext, c:TClass):Void {
		var conv = new TclassToJvm(gctx, c);
		conv.generate();
	}

	public static function generateEnumEquals(gctx:GenerationContext, jcCtor:JvmClassBuilder):{jm:JvmMethodBuilder, compareField:String->JSignature->Void} {
		var eq = generateEqualsFunction(jcCtor, haxeEnumSig(objectSig));
		var jmEquals = eq.jm, load = eq.load;
		var code = jmEquals.getCode();
		var jmEqualsHandler = new TexprToJvm(gctx, null, jcCtor, jmEquals, JBool);
		function isHaxeEnum(jsig:JSignature):Bool return switch jsig {
			case JObject(path, _):
				gctx.enumPaths.exists(pathKey(path));
			case _:
				false;
		}
		function compareWhatever(jsig:JSignature) {
			jmEquals.invokestatic(haxeJvmPath, "maybeEnumEq", methodSig([objectSig, objectSig], JBool));
			jmEquals.ifThen(function(r) code.if_(CmpNe, r), function() {
				code.bconst(false);
				jmEquals.return_();
			});
		}
		function compareHaxeEnum(jsig:JSignature) {
			jmEquals.invokestatic(haxeTypePath, "enumEq", methodSig([objectSig, objectSig], JBool));
			jmEquals.ifThen(function(r) code.if_(CmpNe, r), function() {
				code.bconst(false);
				jmEquals.return_();
			});
		}
		function compareStandard(jsig:JSignature) {
			jmEquals.ifThen(jmEqualsHandler.applyCmp(jmEqualsHandler.doCompare(CmpNe)), function() {
				code.bconst(false);
				jmEquals.return_();
			});
		}
		function compare(jsig:JSignature) {
			if (NativeSignatures.isDynamicAtRuntime(jsig)) compareWhatever(jsig) else if (isHaxeEnum(jsig)) compareHaxeEnum(jsig) else
				compareStandard(jsig);
		}
		function compareField(n:String, jsig:JSignature) {
			load();
			jmEquals.getfield(jcCtor.getThisPath(), n, jsig);
			jmEquals.loadThis();
			jmEquals.getfield(jcCtor.getThisPath(), n, jsig);
			compare(jsig);
		}
		return {jm: jmEquals, compareField: compareField};
	}

	public static function generateEnum(gctx:GenerationContext, en:TEnum):Void {
		var jcEnum = new JvmClassBuilder(en.ePath, haxeEnumPath);
		jcEnum.addAccessFlag(0x1); /* public */
		jcEnum.addAccessFlag(0x400); /* abstract */
		if (core.Meta.has(MetaTag.JvmSynthetic, en.eMeta)) jcEnum.addAccessFlag(0x1000); /* synthetic */
		var jsigEnumCtor = methodSig([JInt, stringSig], null);
		/* Create base constructor */
		{
			var jmCtor = jcEnum.spawnMethod("<init>", jsigEnumCtor, [MProtected]);
			jmCtor.loadThis();
			var load1 = jmCtor.addLocal("index", JInt, VarArgument).load;
			var load2 = jmCtor.addLocal("name", stringSig, VarArgument).load;
			load1();
			load2();
			jmCtor.callSuperCtor(ConstructInit, jsigEnumCtor);
			jmCtor.return_();
		}
		var inits:Array<{jmStatic:JvmMethodBuilder, jcCtor:JvmClassBuilder}> = [];
		var names = en.eNames.map(function(name) {
			var ef = en.eConstrs.get(name);
			if (ef == null) throw NotFound.raise();
			var args = switch TFunctions.follow(ef.efType) {
				case TFun(s): s.args.map(function(a) return {name: a.name, jsig: jsignatureOfType(gctx, a.type)});
				case _: [];
			}
			var jsigs = args.map(function(a) return a.jsig);
			/* Create class for constructor */
			var jcCtor = {
				var jcCtor = jcEnum.spawnInnerClass(null, jcEnum.getThisPath(), ef.efName);
				jcCtor.addAccessFlag(0x10); /* final */
				var jsigMethod = methodSig(jsigs, null);
				var jmCtor = jcCtor.spawnMethod("<init>", jsigMethod, [MPublic]);
				jmCtor.loadThis();
				jmCtor.getCode().iconst(ef.efIndex);
				jmCtor.string(ef.efName);
				jmCtor.callSuperCtor(ConstructInit, jsigEnumCtor);
				for (a in args) jmCtor.addArgumentAndField(a.name, a.jsig, [FdPublic, FdFinal]);
				jmCtor.return_();
				jcCtor.addAnnotation({pack: ["haxe", "jvm", "annotation"], name: "EnumValueReflectionInformation"}, [
					{name: "argumentNames", kind: AArray(args.map(function(a) return AnnotationKind.AString(a.name)))}
				], true);
				if (args.length > 0) {
					var jmParams = jcCtor.spawnMethod("_hx_getParameters", methodSig([], arraySig(objectSig)), [MPublic, MSynthetic]);
					var eq = generateEnumEquals(gctx, jcCtor);
					var jmEquals = eq.jm, compareField = eq.compareField;
					var fl = args.map(function(a) {
						compareField(a.name, a.jsig);
						return function() {
							jmParams.loadThis();
							jmParams.getfield(jcCtor.getThisPath(), a.name, a.jsig);
							jmParams.cast_(objectSig);
						};
					});
					jmEquals.getCode().bconst(true);
					jmEquals.return_();
					jmParams.newNativeArray(objectSig, fl);
					jmParams.return_();
				}
				jcCtor;
			}
			writeClass(gctx, jcCtor.getThisPath(), jcCtor.exportClass(gctx.defaultExportConfig));
			switch args {
				case []:
					/* Create static field for ctor without args */
					var jmStatic = jcEnum.spawnField(ef.efName, jcEnum.getJsig(), [FdPublic, FdStatic, FdFinal, FdEnum]);
					inits.push({jmStatic: jmStatic, jcCtor: jcCtor});
				case _:
					/* Create static function for ctor with args */
					var jsigStatic = methodSig(jsigs, jcEnum.getJsig());
					var jmStatic = jcEnum.spawnMethod(ef.efName, jsigStatic, [MPublic, MethodAccessFlags.MStatic]);
					jmStatic.construct(ConstructInit, jcCtor.getThisPath(), function() {
						for (a in args) {
							var load = jmStatic.addLocal(a.name, a.jsig, VarArgument).load;
							load();
						}
						return jsigs;
					});
					jmStatic.return_();
			}
			return AnnotationKind.AString(name);
		});
		if (inits.length > 0) {
			/* Assign static fields for ctors without args */
			var jmClinit = jcEnum.spawnMethod("<clinit>", methodSig([], null), [MethodAccessFlags.MStatic]);
			var jmValues = jcEnum.spawnMethod("values", methodSig([], arraySig(objectPathSig(jcEnum.getThisPath()))),
				[MPublic, MethodAccessFlags.MStatic]);
			var inits = inits.copy();
			var fl = inits.map(function(i) {
				jmClinit.construct(ConstructInit, i.jcCtor.getThisPath(), function() return []);
				jmClinit.putstatic(jcEnum.getThisPath(), i.jmStatic.getName(), i.jmStatic.getJsig());
				return function() {
					jmValues.getstatic(jcEnum.getThisPath(), i.jmStatic.getName(), i.jmStatic.getJsig());
				};
			});
			jmValues.newNativeArray(objectPathSig(jcEnum.getThisPath()), fl);
			jmValues.return_();
			/* Add __meta__ TODO: do this via annotations instead? */
			switch Texpr.buildMetadata(gctx.gctx.basic, TEnumDecl(en)) {
				case null:
				case e:
					jcEnum.spawnField("__meta__", objectSig, [FdStatic, FdPublic]);
					var handler = new TexprToJvm(gctx, null, jcEnum, jmClinit, null);
					handler.texpr(rvalueAny, e);
					jmClinit.putstatic(jcEnum.getThisPath(), "__meta__", objectSig);
			}
			jmClinit.return_();
		}
		AnnotationHandler.generateAnnotations(jcEnum, en.eMeta);
		jcEnum.addAnnotation({pack: ["haxe", "jvm", "annotation"], name: "EnumReflectionInformation"}, [
			{name: "constructorNames", kind: AArray(names)}
		], true);
		writeClass(gctx, en.ePath, jcEnum.exportClass(gctx.defaultExportConfig));
	}

	public static function generateModuleType(ctx:GenerationContext, mt:ModuleType):Void {
		switch mt {
			case TClassDecl(c) if (!hasClassFlag(c, CExtern)): generateClass(ctx, c);
			case TEnumDecl(en) if (!hasEnumFlag(en, EnExtern)): generateEnum(ctx, en);
			case _:
		}
	}

	public static function generateAnons(gctx:GenerationContext, pool:Null<core.ds.TaskPool>):Void {
		function run(pfm:PathFieldMapping<JSignature>):Void {
			var path = pfm.pfmPath;
			var fields = convertFields(gctx, pfm);
			var jc = new JvmClassBuilder(path, haxeDynamicObjectPath);
			jc.addAccessFlag(0x1);
			function isTypedField(name:String):Bool return isDexSafeSimpleName(name);
			{
				var jmCtor = jc.spawnMethod("<init>", methodSig(fields.map(function(f) return f.value), null), [MPublic]);
				jmCtor.loadThis();
				jmCtor.getCode().aconstNull(haxeEmptyConstructorSig);
				jmCtor.callSuperCtor(ConstructInit, methodSig([haxeEmptyConstructorSig], null));
				/* Two-pass: first initialize typed fields (so _hx_getKnownFields can
					 read them when _hx_setField triggers _hx_initReflection), then
					 write the map-backed unsafe ones via super._hx_setField. */
				var argLoaders = fields.map(function(f) {
					var load = jmCtor.addLocal(f.name, f.value, VarArgument).load;
					return {name: f.name, jsig: f.value, load: load};
				});
				for (a in argLoaders) {
					if (isTypedField(a.name)) {
						jc.spawnField(a.name, a.jsig, [FdPublic]);
						jmCtor.loadThis();
						a.load();
						jmCtor.putfield(jc.getThisPath(), a.name, a.jsig);
					}
				}
				for (a in argLoaders) {
					if (!isTypedField(a.name)) {
						jmCtor.loadThis();
						jmCtor.string(a.name);
						a.load();
						jmCtor.expectReferenceType();
						jmCtor.invokevirtual(haxeDynamicObjectPath, "_hx_setField", methodSig([stringSig, objectSig], null));
					}
				}
				jmCtor.return_();
			}
			{
				var stringMapPath:JPath = {pack: ["haxe", "ds"], name: "StringMap"};
				var stringMapSig = objectPathSig(stringMapPath);
				var jmFields = jc.spawnMethod("_hx_getKnownFields", methodSig([], stringMapSig), [MProtected, MSynthetic]);
				var l = jmFields.addLocal("tmp", stringMapSig, VarWillInit);
				var load = l.load, save = l.store;
				jmFields.construct(ConstructInit, stringMapPath, function() return []);
				save();
				for (f in fields) {
					var name = f.name, jsig = f.value;
					/* Unsafe-named fields live in DynamicObject._hx_fields directly
						 (written from the constructor), so they're merged into the
						 reflection map elsewhere — skip them here. */
					if (isTypedField(name)) {
						load();
						var offset = jc.getPool().addConstString(name);
						jmFields.getCode().sconst(stringSig, offset);
						jmFields.loadThis();
						jmFields.getfield(jc.getThisPath(), name, jsig);
						jmFields.expectReferenceType();
						jmFields.invokevirtual(stringMapPath, "set", methodSig([stringSig, objectSig], null));
					}
				}
				load();
				jmFields.return_();
			}
			/* This has to run even with dynamic_level = 0 because the entire DynamicObject logic depends on it. */
			generateDynamicAccess(gctx, jc, fields.map(function(f) return {
				name: f.name,
				jsig: f.value,
				kind: Var({vWrite: AccNormal, vRead: AccNormal})
			}), true);
			switch gctx.typedefInterfaces.getInterfaceClass(path) {
				case null:
				case c:
					jc.addInterface(c.clPath, []);
					for (cf in c.clOrderedFields) {
						var jsigCf = jsignatureOfType(gctx, cf.cfType);
						var jm = jc.spawnMethod(cf.cfName, jsigCf, [MPublic]);
						var sig = switch followWithCoro(cf.cfType) {
							case NotCoro(TFun(s)):
								s;
							case Coro(s):
								context.Common.expandCoroType(gctx.gctx.basic, s.args, s.ret);
							case _: die("", "generators/genjvm.ml");
						}
						var tl = sig.args, tr = sig.ret;
						var locals = tl.map(function(a) {
							var jsig = jsignatureOfType(gctx, a.type);
							return {l: jm.addLocal(a.name, jsig, VarArgument), jsig: jsig};
						});
						jm.finalizeArguments();
						jm.loadThis();
						jm.getfield(path, cf.cfName, jsigCf);
						for (l in locals) l.l.load();
						var jret = returnOfType(gctx, tr);
						var meth = gctx.typedFunctions.registerSignature(locals.map(function(l) return l.jsig), jret);
						jm.invokevirtual(haxeFunctionPath, meth.name, methodSig(meth.dargs, meth.dret));
						if (jret != null) jm.cast_(jret);
						jm.return_();
					}
			}
			writeClass(gctx, path, jc.exportClass(gctx.defaultExportConfig));
		}
		// port: Hashtbl.to_seq order.
		var seq = [];
		gctx.anonIdentification.getPfms().iter(function(_, pfm) seq.push(pfm));
		context.Parallel.ParallelSeq.iter(pool, run, seq.iterator());
	}

	public static function generateTypedFunctions(gctx:GenerationContext):Void {
		var jcFunction = gctx.typedFunctions.generate();
		writeClass(gctx, jcFunction.getThisPath(), jcFunction.exportClass(gctx.defaultExportConfig));
		var jcVarargs = gctx.typedFunctions.generateVarArgs();
		writeClass(gctx, jcVarargs.getThisPath(), jcVarargs.exportClass(gctx.defaultExportConfig));
		var jcClosureDispatch = gctx.typedFunctions.generateClosureDispatch();
		writeClass(gctx, jcClosureDispatch.getThisPath(), jcClosureDispatch.exportClass(gctx.defaultExportConfig));
	}

	public static function generate(jvmFlag:Bool, gctx0:Gctx):Void {
		var path = core.Path.FilePath.parse(gctx0.file);
		var jarName, entryPoint;
		switch Gctx.getEntryPoint(gctx0) {
			case null:
				jarName = "jar";
				entryPoint = null;
			case ep:
				jarName = ep.name;
				entryPoint = {cls: ep.cls, expr: ep.expr};
		}
		var compressionLevel = try core.ds.OcamlInt.ofString(Define.definedValue(gctx0.defines, Define.JvmCompressionLevel)) catch (_:Dynamic) 6;
		if (compressionLevel < 0 || compressionLevel > 9) throw new Failure("Invalid value for -D jvm.compression-level: Must be >=0 and <= 9");
		function createJar(path:String):JvmOutput {
			return new JarOutput(path, compressionLevel);
		}
		var outDir, out;
		if (jvmFlag) {
			switch path.fileName {
				case null:
					switch path.directory {
						case null:
							throw new Failure("Please specify an output file name");
						case dir:
							var dir = core.Path.addTrailingSlash(dir);
							outDir = dir;
							out = (new FileOutput(dir) : JvmOutput);
					}
				case _:
					switch path.directory {
						case null:
							outDir = "./";
							out = createJar("./" + gctx0.file);
						case dir:
							core.Path.mkdirFromPath(dir);
							outDir = core.Path.addTrailingSlash(dir);
							out = createJar(gctx0.file);
					}
			}
		} else {
			var jarName = if (gctx0.debug) jarName + "-Debug" else jarName;
			var jarDir = core.Path.addTrailingSlash(gctx0.file);
			var jarPath = '$jarDir$jarName.jar';
			outDir = jarDir;
			out = createJar(jarPath);
		}
		var anonIdentification = new TanonIdentification<JSignature>();
		var dynamicLevel = try core.ds.OcamlInt.ofString(Define.definedValue(gctx0.defines, Define.JvmDynamicLevel)) catch (_:Dynamic) 1;
		if (dynamicLevel < 0 || dynamicLevel > 1) throw new Failure("Invalid value for -D jvm.dynamic-level: Must be 0 or 1");
		var gctx:GenerationContext = {
			gctx: gctx0,
			out: out,
			tRuntimeException: TInst(resolveClass(gctx0, {pack: ["java", "lang"], name: "RuntimeException"}), []),
			entryPoint: entryPoint,
			tException: TInst(resolveClass(gctx0, {pack: ["java", "lang"], name: "Exception"}), []),
			tThrowable: TInst(resolveClass(gctx0, {pack: ["java", "lang"], name: "Throwable"}), []),
			anonIdentification: anonIdentification,
			preprocessor: null,
			typedefInterfaces: null,
			typedFunctions: new TypedFunctions(),
			closurePaths: new OcamlHashtbl(function(k:ClosureKey) return OcamlHash.hash(OBlock(0, [OcamlHash.ofPath(k.path.pack, k.path.name), OString(k.name)])),
				function(a:ClosureKey, b:ClosureKey) return context.Common.samePath(a.path, b.path) && a.name == b.name),
			staticClosurePaths: new haxe.ds.StringMap(),
			enumPaths: new haxe.ds.StringMap(),
			defaultExportConfig: {
				exportDebug: true,
			},
			detailTimes: Gctx.rawDefined(gctx0, "jvm_times"),
			jarCompressionLevel: compressionLevel,
			dynamicLevel: dynamicLevel,
			functionalInterfaces: [],
			mutexes: {
				writeClass: new sys.thread.Mutex(),
				unify: new sys.thread.Mutex(),
				closureLookup: new sys.thread.Mutex(),
			}
		};
		gctx.preprocessor = new Preprocessor(gctx.gctx.basic, jsignatureOfType.bind(gctx), JvmSignature.ocamlValueOfJsig);
		gctx.typedefInterfaces = new TypedefInterfaces(gctx.preprocessor.getInfos(), anonIdentification);
		gctx.typedefInterfaces.addInterfaceRewrite({pack: ["haxe", "root"], name: "Iterator"}, {pack: ["java", "util"], name: "Iterator"}, true);
		var classPaths = [];
		for (javaLib in gctx.gctx.nativeLibs) {
			if (javaLib.hasFlag(FlagIsStd) || javaLib.hasFlag(FlagIsExtern)) {} else {
				var dir = outDir + "lib/";
				core.Path.mkdirFromPath(dir);
				var name = core.Path.FilePath.nameAndExtension(core.Path.FilePath.parse(javaLib.getFilePath()));
				var b = sys.io.File.getBytes(javaLib.getFilePath());
				sys.io.File.saveBytes(dir + name, b);
				classPaths.push("lib/" + name + " \n");
			}
		}
		gctx.gctx.resources.iter(function(name, v) {
			var filename = core.StringHelper.escapeResName(name, ["/", "-"]);
			gctx.out.addEntry(v, filename);
		});

		function generate():Void {
			context.Parallel.runWithPool(gctx.gctx.pool, function(pool) {
				function generateRealTypes():Void {
					context.Parallel.ParallelArray.iter(pool, generateModuleType.bind(gctx), gctx.gctx.types.copy());
				}
				function generateTypedInterfaces():Void {
					// port: Hashtbl.to_seq order.
					var seq = [];
					gctx.typedefInterfaces.getInterfaces().iter(function(_, c) seq.push(c));
					context.Parallel.ParallelSeq.iter(pool, function(c) generateModuleType(gctx, TClassDecl(c)), seq.iterator());
				}
				runTimed(gctx, false, "preprocess", function() {
					JvmPreprocessor.preprocess(gctx);
					return null;
				});
				runTimed(gctx, false, "real types", function() {
					generateRealTypes();
					return null;
				});
				runTimed(gctx, false, "typed interfaces", function() {
					generateTypedInterfaces();
					return null;
				});
				runTimed(gctx, false, "anons", function() {
					generateAnons(gctx, pool);
					return null;
				});
				runTimed(gctx, false, "typed_functions", function() {
					generateTypedFunctions(gctx);
					return null;
				});
				runTimed(gctx, false, "closures", function() {
					generateClosures(gctx);
					return null;
				});
				return null;
			});
		}
		generate();

		var manifestContent = "Manifest-Version: 1.0\n" + "Created-By: Haxe (Haxe Foundation)"
			+ (entryPoint == null ? "" : "\nMain-Class: " + sTypePath(entryPoint.cls.clPath))
			+ (switch classPaths {
				case []: "";
				case _: "\nClass-Path: " + classPaths.join(" ");
			})
			+ "\n\n";
		gctx.out.addEntry(Bytes.ofString(manifestContent), "META-INF/MANIFEST.MF");
		gctx.out.close();
	}
}

class AnnotationHandler {
	static function parsePath(e:Expr):JPath {
			var sl:Array<String> = try core.Ast.Ast.stringListOfExprPathRaise(e) catch (_:core.ds.Exit) core.Error.raiseTypingError("Field expression expected", e.pos);
			var path:JPath = switch sl {
				case _ if (sl.length > 0):
					var rest = sl.slice(1);
					rest.reverse();
					{pack: rest, name: sl[0]};
				case _: core.Error.raiseTypingError("Field expression expected", e.pos);
			}
			return path;
		}

	static function parseValue(e:Expr):AnnotationKind {
			return switch e.expr {
				case EConst(Int(s, _)): AInt(core.ds.OcamlInt32.ofString(s));
				case EConst(Float(s, _)): ADouble(core.ds.OcamlFloat.ofString(s));
				case EConst(String(s, _)): AnnotationKind.AString(s);
				case EConst(Ident("true")): ABool(true);
				case EConst(Ident("false")): ABool(false);
				case EArrayDecl(el): AArray(el.map(parseValue));
				case EField(e1, "class", _):
					var path = parsePath(e1);
					var jsig = try {
						Genjvm.jsignatureOfPath(path);
					} catch (_:core.ds.Exit) {
						switch path {
							case {pack: [], name: "Void"}:
								null;
							case {pack: [], name: name}:
								JObject({pack: ["haxe", "root"], name: name}, []);
							case _:
								JObject(path, []);
						}
					}
					AClass(jsig);
				case EField(e1, s, _):
					var path = parsePath(e1);
					AnnotationKind.AEnum(objectPathSig(path), s);
				case ECall(e1, el):
					var path = parsePath(e1);
					var name = StringTools.replace(path.name, ".", "$");
					var path:JPath = {pack: path.pack, name: name};
					var values = el.map(parseValuePair);
					AAnnotation(JObject(path, []), values);
				case _:
					core.Error.raiseTypingError("Expected value expression", e.pos);
			}
		}

	static function parseValuePair(e:Expr):{name:String, kind:AnnotationKind} {
			return switch e.expr {
				case EBinop(OpAssign, {expr: EConst(Ident(s))}, e1):
					{name: s, kind: parseValue(e1)};
				case _:
					core.Error.raiseTypingError("Assignment expression expected", e.pos);
			}
		}

	static function parseExpr(e:Expr):{path:JPath, values:Annotation} {
			return switch e.expr {
				case ECall(e1, el):
					var path = parsePath(e1);
					var name = StringTools.replace(path.name, ".", "$");
					var path:JPath = {pack: path.pack, name: name};
					var values = el.map(parseValuePair);
					{path: path, values: values};
				case _:
					core.Error.raiseTypingError("Call expression expected", e.pos);
			}
		}

	public static function convertAnnotations(meta:Metadata):Array<{path:JPath, annotation:Annotation, isRuntimeVisible:Bool}> {
		var r = [];
		for (m in meta) {
			if (core.Meta.metaEq(MetaTag.Meta, m.meta) && m.exprs.length > 0) {
				var e1 = m.exprs[0], el = m.exprs.slice(1);
				var pe = parseExpr(e1);
				var path = switch pe.path.pack {
					case []: ({pack: ["haxe", "root"], name: pe.path.name} : JPath);
					case _: pe.path;
				}
				/* If there's no value this was an untyped @:meta. Let's assume RUNTIME retention. */
				var isRuntimeVisible = switch el {
					case [{expr: EConst(String("CLASS", _))}]: false;
					case _: true;
				}
				r.push({path: path, annotation: pe.values, isRuntimeVisible: isRuntimeVisible});
			}
		}
		return r;
	}

	public static function generateAnnotations(builder:BaseBuilder, meta:Metadata):Void {
		for (a in convertAnnotations(meta)) builder.addAnnotation(a.path, a.annotation, a.isRuntimeVisible);
	}
}

class HaxeException {
	final gctx:GenerationContext;
	final t:T;
	final isHaxeException_:Bool;
	final nativeType:JSignature;
	final nativePath:JPath;

	public function new(gctx:GenerationContext, t:T) {
		this.gctx = gctx;
		this.t = t;
		// port: `let ... and ...` in the class header
		isHaxeException_ = ExceptionFunctions.isHaxeException(t);
		nativeType = Genjvm.jsignatureOfType(gctx, t);
		nativePath = switch nativeType {
			case JObject(path, _): path;
			case _: die("", "generators/genjvm.ml");
		}
	}

	public function isAssignableTo(exc2:HaxeException):Bool {
		return switch [isHaxeException(), exc2.isHaxeException()] {
			case [true, true] | [false, false]:
				// port: guarded (see Genjvm.guardUnify)
				Genjvm.guardUnify(gctx, function() return TUnification.doesUnify(t, exc2.getType()));
			/* `haxe.Exception` is assignable to java.lang.RuntimeException/Exception/Throwable */
			case [false, true]:
				Lambda.exists([throwableSig, exceptionSig, runtimeExceptionSig], function(s) return JvmSignature.jsigEq(exc2.getNativeType(), s));
			case _:
				false;
		}
	}

	public function isHaxeException():Bool return isHaxeException_;

	public function getNativeType():JSignature return nativeType;

	public function getNativePath():JPath return nativePath;

	public function getType():T return t;
}

class TexprToJvm {
	final gctx:GenerationContext;
	final fieldInfo:Null<FieldGenerationInfo>;
	final jc:JvmClassBuilder;
	final jm:JvmMethodBuilder;
	final returnType:Null<JSignature>;
	final code:JvmCodeBuilder;
	final pool:JvmConstantPool;

	// port: Hashtbl.add/find: the latest binding of an id wins.
	var localLookup:haxe.ds.IntMap<LocalRef> = new haxe.ds.IntMap();
	var lastLine = 0;

	var break_:Null<JvmLabel> = null;
	var continue_:Null<JvmLabel> = null;
	var caughtExceptions:Array<HaxeException> = [];
	var blockExits:Array<BlockExit> = [];
	var env:Null<Array<{id:Int, name:String, jsig:JSignature}>> = null;

	public function new(gctx:GenerationContext, fieldInfo:Null<FieldGenerationInfo>, jc:JvmClassBuilder, jm:JvmMethodBuilder,
			returnType:Null<JSignature>) {
		this.gctx = gctx;
		this.fieldInfo = fieldInfo;
		this.jc = jc;
		this.jm = jm;
		this.returnType = returnType;
		code = jm.getCode();
		pool = jc.getPool();
	}

	static inline function followA(t:T):T return Abstract.followWithAbstracts(t);

	static function isPath(p:GlobalTypePath, pack:Array<String>, name:String):Bool {
		if (p.name != name || p.pack.length != pack.length) return false;
		for (i in 0...pack.length) if (p.pack[i] != pack[i]) return false;
		return true;
	}

	public function vtype(t:T):JSignature {
		return Genjvm.jsignatureOfType(gctx, t);
	}

	public function mknull(t:T):T return gctx.gctx.basic.tnull(followA(t));

	/* locals */
	public function addNamedLocal(name:String, jsig:JSignature):LocalRef {
		return jm.addLocal(name, jsig, VarArgument);
	}

	public function addLocal2(id:Int, name:String, jsig:JSignature, initState:VarInitState):LocalRef {
		var l = jm.addLocal(name, jsig, initState);
		localLookup.set(id, l);
		return l;
	}

	public function addLocal(v:TVar, initState:VarInitState):LocalRef {
		return addLocal2(v.vId, v.vName, vtype(v.vType), initState);
	}

	public function getLocalById(vid:Int, vname:String):LocalRef {
		if (vid == 0 && env == null) return {slot: 0, load: function() jm.loadThis(), store: function() die("", "generators/genjvm.ml")};
		var l = localLookup.get(vid);
		if (l != null) return l;
		switch env {
			case null:
			case env:
				for (e in env) if (e.id == vid) {
					var name = e.name, jsig = e.jsig;
					return {
						slot: -1,
						load: function() {
							jm.loadThis();
							jm.getfield(jc.getThisPath(), name, jsig);
						},
						store: function() {
							jm.loadThis();
							jm.putfield(jc.getThisPath(), name, jsig);
						}
					};
				}
		}
		throw new Failure("Unbound local: " + vname);
	}

	public function getLocal(v:TVar):LocalRef {
		return getLocalById(v.vId, v.vName);
	}

	public function setEnv(env2:Array<{id:Int, name:String, jsig:JSignature}>):Void {
		env = env2;
	}

	/* casting */
	public function expectReferenceType():Void jm.expectReferenceType();

	public function cast_(t:T):Void {
		var vt = vtype(t);
		jm.cast_(vt);
	}

	public function castExpect(ret:Ret, t:T):Void {
		switch ret {
			case RValue(jsig, _) if (jsig != null): jm.cast_(jsig);
			case _: cast_(t);
		}
	}

	public function makeStaticClosureField(name:String, jcClosure:JvmClassBuilder):Void {
		var jmInit = jcClosure.getStaticInitMethod();
		var jfClosure = jcClosure.spawnField(name, jcClosure.getJsig(), [FdStatic, FdPublic, FdFinal]);
		jmInit.construct(ConstructInit, jcClosure.getThisPath(), function() return []);
		jmInit.putstatic(jcClosure.getThisPath(), jfClosure.getName(), jfClosure.getJsig());
	}

	public function transformArg(v:TVar, eo:Null<TExpr>):TransformedArg {
		var jsigLocal = vtype(v.vType);
		var dualVars = eo != null && isUnboxed(jsigLocal);
		var jsigArg = if (dualVars) getBoxedType(jsigLocal) else jsigLocal;
		return {
			aId: v.vId,
			aName: v.vName,
			aJsigArg: jsigArg,
			aJsigLocal: if (dualVars) jsigLocal else null,
			aTexpr: eo,
		};
	}

	public function handleArgInits(jm:JvmMethodBuilder, handler:TexprToJvm, actualArgs:Array<LocalRef>, args:Array<TransformedArg>):Void {
		if (actualArgs.length != args.length) throw new core.ds.InvalidArgument("List.iter2");
		for (i in 0...actualArgs.length) {
			var load = actualArgs[i].load, store = actualArgs[i].store;
			var arg = args[i];
			switch arg.aTexpr {
				case e if (e != null && !e.eexpr.match(TConst(TNull))):
					switch arg.aJsigLocal {
						case jsigLocal if (jsigLocal != null):
							load();
							jm.ifThenElse(function(r) jm.getCode().ifNonnull(arg.aJsigArg, r), function() {
								handler.texpr(Genjvm.rvalueSig(jsigLocal), e);
							}, function() {
								load();
								jm.cast_(jsigLocal);
							});
							var store = handler.addLocal2(arg.aId, arg.aName, jsigLocal, VarWillInit).store;
							store();
						case _:
							load();
							jm.ifThen(function(r) jm.getCode().ifNonnull(arg.aJsigArg, r), function() {
								handler.texpr(Genjvm.rvalueSig(arg.aJsigArg), e);
								jm.cast_(arg.aJsigArg);
								store();
							});
					}
				case _:
			}
		}
	}

	public function tfunction(ret:Ret, e:TExpr, tf:TFunc):Void {
		var captured = Texpr.collectCapturedVars(e);
		var outside = captured.vars, accessesThis = captured.accessesThis;
		var env = outside.map(function(v) return {id: v.vId, name: v.vName, jsig: vtype(v.vType)});
		var env = if (accessesThis) [{id: 0, name: "this", jsig: jc.getJsig()}].concat(env) else env;
		var context = env.map(function(e) return {name: e.name, jsig: e.jsig});
		var name = switch ret {
			case RValue(_, s) if (s != null): s;
			case _: null;
		}
		var wf = Genjvm.createTypedFunction(gctx, FuncLocal(name), jc, jm, context);
		Genjvm.associateFunctionalInterfaces(gctx, wf, e.etype);
		var jcClosure = wf.getClass();
		wf.generateConstructor(env.length > 0);
		var filter = switch ret {
			case RValue(JObject(path, _), _): [path];
			case _: [];
		}
		var args = tf.tfArgs.map(function(a) return transformArg(a.variable, a.defaultValue));
		var ret = Genjvm.returnOfType(gctx, tf.tfType);
		var jmInvoke = wf.generateInvoke(args.map(function(arg) return {name: arg.aName, jsig: arg.aJsigArg}), ret, filter);
		var handler = new TexprToJvm(gctx, fieldInfo, jcClosure, jmInvoke, ret);
		handler.setEnv(env);
		var actualArgs = args.map(function(arg) return handler.addLocal2(arg.aId, arg.aName, arg.aJsigArg, VarArgument));
		jmInvoke.finalizeArguments();
		handleArgInits(jmInvoke, handler, actualArgs, args);
		handler.texpr(RReturn, tf.tfExpr);
		switch env {
			case []:
				var name = jcClosure.getThisPath().name;
				makeStaticClosureField(name, jcClosure);
				jm.getstatic(jcClosure.getThisPath(), name, objectPathSig(jcClosure.getThisPath()));
			case _:
				jm.construct(ConstructInit, jcClosure.getThisPath(), function() {
					return env.map(function(e) {
						var load = getLocalById(e.id, e.name).load;
						load();
						return e.jsig;
					});
				});
		}
		Genjvm.writeClass(gctx, jcClosure.getThisPath(), jcClosure.exportClass(gctx.defaultExportConfig));
	}

	/* access */
	public function readNativeArray(vta:JSignature, vte:JSignature):Void {
		NativeArray.read(code, vta, vte);
	}

	public function writeNativeArray(vta:JSignature, vte:JSignature):Void {
		NativeArray.write(code, vta, vte);
	}

	public function readAnonField(castFn:Void->Void, t:T, cf:TClassField):Void {
		function default_() {
			jm.string(cf.cfName);
			jm.invokestatic(haxeJvmPath, "readField", methodSig([objectSig, stringSig], objectSig));
			castFn();
		}
		switch gctx.anonIdentification.identify(AnonIdMode.defaultMode, true, t) {
			case pfm if (pfm != null && Genjvm.isDexSafeSimpleName(cf.cfName)):
				var cf = pfm.pfmFields.get(cf.cfName);
				if (cf == null) throw NotFound.raise();
				var path = pfm.pfmPath;
				code.dup();
				code.instanceof(path);
				jm.ifThenElse(function(r) code.if_(CmpEq, r), function() {
					jm.cast_(objectPathSig(path));
					jm.getfield(path, cf.cfName, vtype(cf.cfType));
					castFn();
				}, function() default_());
			case _:
				default_();
		}
	}

	public function readStaticClosure(path:GlobalTypePath, name:String, args:Array<{name:String, jsig:JSignature}>, ret:Null<JSignature>, t:T):Void {
		var jsig = methodSig(args.map(function(a) return a.jsig), ret);
		gctx.mutexes.closureLookup.acquire();
		var key = path.pack.join(".") + ":" + path.name + ":" + name + ":" + JvmSignature.jsigKey(jsig);
		var closurePath = switch gctx.staticClosurePaths.get(key) {
			case null:
				var wf = Genjvm.createTypedFunction(gctx, FuncStatic(path, name), jc, jm, []);
				var jcClosure = wf.getClass();
				gctx.staticClosurePaths.set(key, jcClosure.getThisPath());
				gctx.mutexes.closureLookup.release();
				Genjvm.associateFunctionalInterfaces(gctx, wf, t);
				wf.generateConstructor(false);
				var jmInvoke = wf.generateInvoke(args, ret, []);
				var vars = args.map(function(a) return jmInvoke.addLocal(a.name, a.jsig, VarArgument));
				jmInvoke.finalizeArguments();
				for (v in vars) v.load();
				jmInvoke.invokestatic(path, name, methodSig(args.map(function(a) return a.jsig), ret));
				jmInvoke.return_();
				/* Static init */
				makeStaticClosureField(name, jcClosure);
				Genjvm.writeClass(gctx, jcClosure.getThisPath(), jcClosure.exportClass(gctx.defaultExportConfig));
				jcClosure.getThisPath();
			case r:
				gctx.mutexes.closureLookup.release();
				r;
		}
		jm.getstatic(closurePath, name, objectPathSig(closurePath));
	}

	public function read(castFn:Void->Void, e1:TExpr, fa:TFieldAccess):Void {
		function readStaticClosure(path:GlobalTypePath, cf:TClassField) {
			var args:Array<{name:String, jsig:JSignature}> = null, ret:Null<JSignature> = null;
			switch followWithCoro(cf.cfType) {
				case NotCoro(TFun(s)):
					args = s.args.map(function(a) return {name: a.name, jsig: vtype(a.type)});
					ret = Genjvm.returnOfType(gctx, s.ret);
				case Coro(s):
					var s = context.Common.expandCoroType(gctx.gctx.basic, s.args, s.ret);
					args = s.args.map(function(a) return {name: a.name, jsig: vtype(a.type)});
					ret = Genjvm.returnOfType(gctx, s.ret);
				case _:
					die("", "generators/genjvm.ml");
			}
			this.readStaticClosure(path, cf.cfName, args, ret, cf.cfType);
		}
		function dynamicRead(s:String) {
			texpr(Genjvm.rvalueAny, e1);
			jm.string(s);
			jm.invokestatic(haxeJvmPath, "readField", methodSig([objectSig, stringSig], objectSig));
			castFn();
		}
		switch fa {
			case FStatic(c, cf) if (isPath(c.clPath, ["java", "lang"], "Math")
				&& (cf.cfName == "NaN" || cf.cfName == "POSITIVE_INFINITY" || cf.cfName == "NEGATIVE_INFINITY")):
				jm.getstatic(doublePath, cf.cfName, JDouble);
			case FStatic(c, cf) if (isPath(c.clPath, ["java", "lang"], "Math") && (cf.cfName == "isNaN" || cf.cfName == "isFinite")):
				readStaticClosure(doublePath, cf);
			case FStatic(c, cf) if (isPath(c.clPath, ["java", "lang"], "String") && cf.cfName == "fromCharCode"):
				readStaticClosure({pack: ["haxe", "jvm"], name: "StringExt"}, cf);
			case FStatic(c, cf = {cfKind: Method(MethNormal | MethInline)}):
				readStaticClosure(c.clPath, cf);
			case FStatic(c, cf):
				jm.getstatic(c.clPath, cf.cfName, vtype(cf.cfType));
				castFn();
			case FInstance(c, _, cf) if (isPath(c.clPath, ["java", "lang"], "String") && cf.cfName == "length"):
				texpr(Genjvm.rvalueAny, e1);
				jm.invokevirtual(stringPath, "length", methodSig([], JInt));
			case FInstance(c, _, cf) if (isPath(c.clPath, ["jvm"], "NativeArray") && cf.cfName == "length"):
				texpr(Genjvm.rvalueAny, e1);
				var vtobj = vtype(e1.etype);
				code.arraylength(vtobj);
			case FInstance(c, tl, cf) if (!Genjvm.isInterfaceVarAccess(c, cf)):
				var c = Genjvm.dynamicFieldOwner(c, cf);
				texpr(Genjvm.rvalueAny, e1);
				jm.getfield(c.clPath, cf.cfName, vtype(cf.cfType));
				castFn();
			case FClosure(ct, cf = {cfKind: Method(MethDynamic)}) if (ct != null && !Genjvm.isInterfaceVarAccess(ct.cls, cf)):
				var c = Genjvm.dynamicFieldOwner(ct.cls, cf);
				texpr(Genjvm.rvalueAny, e1);
				jm.getfield(c.clPath, cf.cfName, vtype(cf.cfType));
				castFn();
			case FEnum(en, ef) if (!(switch followA(ef.efType) {
				case TFun(_): true;
				case _: false;
			})):
				var jsig = vtype(ef.efType);
				var offset = pool.addField(en.ePath, ef.efName, jsig, FKField);
				code.getstatic(offset, jsig);
				castFn();
			case FAnon(cf):
				texpr(Genjvm.rvalueAny, e1);
				readAnonField(castFn, e1.etype, cf);
			case FDynamic(s) | FInstance(_, _, {cfName: s}) | FEnum(_, {efName: s}) | FClosure(null, {cfName: s}):
				dynamicRead(s);
			case FClosure(ct, cf) if (JvmSignature.pathEq(ct.cls.clPath, stringPath)):
				/* String instance methods need JVM-compatible wrappers (e.g. charAt returns char not
					 String in Java). Redirect the closure creation through Jvm.readField which already
					 handles all string methods correctly via StringExt. */
				dynamicRead(cf.cfName);
			case FClosure(ct, cf):
				var c = ct.cls;
				if (hasClassFlag(c, CInterface)) dynamicRead(cf.cfName) else
					Genjvm.registerFieldClosure(gctx, jc, c.clPath, jm, cf.cfName, [vtype(cf.cfType)], function() {
						texpr(Genjvm.rvalueAny, e1);
					}, cf.cfType);
		}
	}

	public function readWrite(ret:Ret, ak:AccessKind, e:TExpr, f:Void->Void):Void {
		function apply(dup:Void->Void) {
			if (Genjvm.needVal(ret) && ak == AKPost) dup();
			f();
			if (Genjvm.needVal(ret) && ak != AKPost) dup();
		}
		function default_(s:String, t:T) {
			if (ak != AKNone) code.dup();
			jm.string(s);
			if (ak != AKNone) {
				code.dupX1();
				jm.invokestatic(haxeJvmPath, "readField", methodSig([objectSig, stringSig], objectSig));
				castExpect(ret, t);
			}
			apply(function() code.dupX2());
			cast_(mknull(t));
			jm.invokestatic(haxeJvmPath, "writeField", methodSig([objectSig, stringSig, objectSig], null));
		}
		switch Texpr.skip(e).eexpr {
			case TLocal(v):
				var l = getLocal(v);
				if (ak != AKNone) l.load();
				apply(function() code.dup());
				cast_(v.vType);
				l.store();
			case TField(_, FStatic(c, cf)):
				var jsigCf = vtype(cf.cfType);
				if (ak != AKNone) jm.getstatic(c.clPath, cf.cfName, jsigCf);
				apply(function() code.dup());
				jm.cast_(jsigCf);
				jm.putstatic(c.clPath, cf.cfName, jsigCf);
			case TField(e1, FInstance(c, tl, cf)) if (!Genjvm.isInterfaceVarAccess(c, cf)):
				var c = Genjvm.dynamicFieldOwner(c, cf);
				texpr(Genjvm.rvalueAny, e1);
				var jsigCf = vtype(cf.cfType);
				if (ak != AKNone) {
					code.dup();
					jm.getfield(c.clPath, cf.cfName, jsigCf);
				}
				apply(function() code.dupX1());
				cast_(cf.cfType);
				jm.putfield(c.clPath, cf.cfName, jsigCf);
			case TField(e1, FAnon(cf)):
				texpr(Genjvm.rvalueAny, e1);
				switch gctx.anonIdentification.identify(AnonIdMode.defaultMode, true, e1.etype) {
					case pfm if (pfm != null && Genjvm.isDexSafeSimpleName(cf.cfName)):
						var cf = pfm.pfmFields.get(cf.cfName);
						if (cf == null) throw NotFound.raise();
						var path = pfm.pfmPath;
						code.dup();
						code.instanceof(path);
						var jsigCf = vtype(cf.cfType);
						jm.ifThenElse(function(r) code.if_(CmpEq, r), function() {
							jm.cast_(objectPathSig(path));
							if (ak != AKNone) {
								code.dup();
								jm.getfield(path, cf.cfName, jsigCf);
							}
							apply(function() code.dupX1());
							jm.cast_(jsigCf);
							jm.putfield(path, cf.cfName, jsigCf);
						}, function() {
							default_(cf.cfName, cf.cfType);
							if (Genjvm.needVal(ret)) jm.cast_(jsigCf);
						});
					case _:
						default_(cf.cfName, cf.cfType);
				}
			case TField(e1, (FDynamic(s) | FInstance(_, _, {cfName: s}))):
				texpr(Genjvm.rvalueAny, e1);
				default_(s, e.etype);
			case TArray(e1, e2):
				switch followA(e1.etype) {
					case TInst(c = {clPath: {pack: ["haxe", "root"], name: "Array"}}, [t]):
						texpr(Genjvm.rvalueAny, e1);
						if (ak != AKNone) code.dup();
						texpr(Genjvm.rvalueAny, e2);
						jm.cast_(JInt);
						if (ak != AKNone) {
							code.dupX1();
							jm.invokevirtual(c.clPath, "__get", methodSig([JInt], objectSig));
							castExpect(ret, e.etype);
						}
						apply(function() code.dupX2());
						jm.expectReferenceType();
						jm.invokevirtual(c.clPath, "__set", methodSig([JInt, objectSig], null));
					case TInst({clPath: {pack: ["jvm"], name: "NativeArray"}}, [t]):
						var vte = vtype(t);
						var vta = vtype(e1.etype);
						texpr(Genjvm.rvalueAny, e1);
						if (ak != AKNone) code.dup();
						texpr(Genjvm.rvalueAny, e2);
						if (ak != AKNone) {
							code.dupX1();
							readNativeArray(vta, vte);
						}
						apply(function() code.dupX2());
						cast_(t);
						writeNativeArray(vta, vte);
					case _:
						texpr(Genjvm.rvalueAny, e1);
						if (ak != AKNone) code.dup();
						texpr(Genjvm.rvalueAny, e2);
						jm.cast_(JInt);
						if (ak != AKNone) {
							code.dupX1();
							jm.invokestatic(haxeJvmPath, "arrayRead", methodSig([objectSig, JInt], objectSig));
						}
						apply(function() code.dupX2());
						cast_(e.etype);
						expectReferenceType();
						jm.invokestatic(haxeJvmPath, "arrayWrite", methodSig([objectSig, JInt, objectSig], null));
				}
			case _:
				Sys.println(core.TPrinting.sExprAst(false, "", function(t) return core.TPrinting.sType(core.TPrinting.printContext(), t), e));
				die("", "generators/genjvm.ml");
		}
	}

	/* branching */
	public function applyCmp(c:CompareKind):JBranchOffsetRef->Void {
		return switch c {
			case CmpNormal(op, _): function(r) code.if_(op, r);
			case CmpSpecial(f): f;
		}
	}

	public function condition(flip:Bool, e:TExpr, labelThen:JvmLabel, labelElse:JvmLabel):Void {
		var stack = jm.getCode().getStack();
		var before = stack.save().size;
		function boolAnd(flip:Bool, e1:TExpr, e2:TExpr) {
			var labelThen2 = jm.spawnLabel("then2");
			condition(flip, e1, labelThen2, labelElse);
			labelThen2.here();
			condition(flip, e2, labelThen, labelElse);
		}
		function boolOr(flip:Bool, e1:TExpr, e2:TExpr) {
			var labelElse2 = jm.spawnLabel("else2");
			condition(!flip, e1, labelElse2, labelThen);
			labelElse2.here();
			condition(flip, e2, labelThen, labelElse);
		}
		function involvesFloatCompare(e:TExpr):Bool {
			function loop(e:TExpr):Void {
				switch e.eexpr {
					case TBinop((OpEq | OpNotEq | OpLt | OpGt | OpLte | OpGte), e1, e2):
						if (ExtType.isFloat(followA(e1.etype)) || ExtType.isFloat(followA(e2.etype))) throw core.ds.Exit.raise();
						loop(e1);
						loop(e2);
					case _:
						Texpr.iter(loop, e);
				}
			}
			return try {
				loop(e);
				false;
			} catch (_:core.ds.Exit) {
				true;
			}
		}
		switch Texpr.skip(e).eexpr {
			case TBinop(op = (OpEq | OpNotEq | OpLt | OpGt | OpLte | OpGte), e1, e2):
				var op = Genjvm.convertCmpOp(op);
				var op = if (flip) Genjvm.flipCmpOp(op) else op;
				labelElse.apply(applyCmp(binopCompare(op, e1, e2)));
			case TBinop(OpBoolAnd, e1, e2) if (!flip):
				boolAnd(false, e1, e2);
			case TBinop(OpBoolAnd, e1, e2) if (!involvesFloatCompare(e1)):
				boolOr(true, e1, e2);
			case TBinop(OpBoolOr, e1, e2) if (flip):
				boolAnd(true, e1, e2);
			case TBinop(OpBoolOr, e1, e2) if (!involvesFloatCompare(e1)):
				boolOr(false, e1, e2);
			case TUnop(Not, _, e1) if (!involvesFloatCompare(e1)):
				condition(!flip, e1, labelThen, labelElse);
			case _:
				texpr(Genjvm.rvalueSig(JBool), e);
		}
		var after = stack.save().size;
		if (after > before) {
			jm.cast_(JBool);
			labelElse.if_(if (flip) CmpNe else CmpEq);
		}
	}

	public function switch_(ret:Ret, sw:TSwitch):Void {
		var e1 = sw.switchSubject, cases = sw.switchCases, def = sw.switchDefault;
		var needVal = switch ret {
			case RValue(_): true;
			case RReturn: returnType != null;
			case _: false;
		}
		/* TODO: this seems to be missing the default, though in that case there probably wouldn't be a TSwitch in the AST */
		if (cases.length == 0)
			texpr(ret, e1)
		else if (Lambda.foreach(cases, Genjvm.isConstIntPattern)) {
			var cases = cases.map(function(c) {
				var il = c.casePatterns.map(function(e) return switch e.eexpr {
					case TConst(TInt(i32)): i32;
					case _: die("", "generators/genjvm.ml");
				});
				return {il: il, f: function() texpr(ret, c.caseExpr)};
			});
			var def = switch def {
				case null: null;
				case e: function() texpr(ret, e);
			}
			texpr(Genjvm.rvalueAny, e1);
			jm.cast_(JInt);
			jm.intSwitch(needVal, cases, def);
		} else if (Lambda.foreach(cases, Genjvm.isConstStringPattern)) {
			var cases = cases.map(function(c) {
				var sl = c.casePatterns.map(function(e) return switch e.eexpr {
					case TConst(TString(s)): s;
					case _: die("", "generators/genjvm.ml");
				});
				return {sl: sl, f: function() texpr(ret, c.caseExpr)};
			});
			var def = switch def {
				case null: null;
				case e: function() texpr(ret, e);
			}
			texpr(Genjvm.rvalueAny, e1);
			jm.cast_(stringSig);
			var l = jm.addLocal("_hx_tmp", stringSig, VarWillInit);
			l.store();
			jm.stringSwitch(needVal, l.load, cases, def);
		} else {
			/* TODO: rewriting this is stupid */
			var popScope = jm.pushScope();
			texpr(Genjvm.rvalueAny, e1);
			var v = allocVar(VGenerated, "tmp", e1.etype, nullPos);
			var store = addLocal(v, VarWillInit).store;
			cast_(v.vType);
			store();
			var ev = mk(TLocal(v), v.vType, nullPos);
			// port: List.rev_map
			var el = [];
			for (c in cases) {
				function f(e2:TExpr):TExpr return mk(TBinop(OpEq, ev, e2), gctx.gctx.basic.tbool, e2.epos);
				var eCond = switch c.casePatterns {
					case []: die("", "generators/genjvm.ml");
					case [e]: f(e);
					case _:
						var eacc = f(c.casePatterns[0]);
						for (i in 1...c.casePatterns.length) {
							var e = c.casePatterns[i];
							eacc = mk(TBinop(OpBoolOr, eacc, f(e)), gctx.gctx.basic.tbool, e.epos);
						}
						eacc;
				}
				el.unshift({cond: eCond, expr: c.caseExpr});
			}
			/* If we rewrite an exhaustive switch that has no default value, treat the last case as the default case to satisfy control flow. */
			var def = def;
			if (needVal && def == null) {
				if (cases.length == 0) die("", "generators/genjvm.ml");
				def = cases[cases.length - 1].caseExpr;
			}
			var e:Null<TExpr> = def;
			for (c in el) e = mk(TIf(c.cond, c.expr, e), c.expr.etype, c.expr.epos);
			texpr(ret, e);
			popScope();
		}
	}

	/* binops */
	public function binopExprs(castType:JSignature, f1:Ret->Void, f2:Ret->Void):Void {
		f1(Genjvm.rvalueSig(castType));
		jm.cast_(castType);
		f2(Genjvm.rvalueSig(castType));
		jm.cast_(castType);
	}

	static function isJavaLangObj(s:JSignature, name:String):Bool return switch s {
		case JObject(p, _): isPath(p, ["java", "lang"], name);
		case _: false;
	}

	public function getBinopTypeSig(jsig1:JSignature, jsig2:JSignature):JSignature {
		var u1 = getUnboxedType(jsig1), u2 = getUnboxedType(jsig2);
		if (isJavaLangObj(u1, "String") || isJavaLangObj(u2, "String")) return stringSig;
		if (u1.match(JLong) || u2.match(JLong)) return JLong;
		if (u1.match(JDouble) || u2.match(JDouble)) return JDouble;
		if (u1.match(JFloat) || u2.match(JFloat)) return JFloat;
		if (u1.match(JInt) || u2.match(JInt)) return JInt;
		if (u1.match(JShort) || u2.match(JShort)) return JShort;
		if (u1.match(JChar) || u2.match(JChar)) return JChar;
		if (u1.match(JByte) || u2.match(JByte)) return JByte;
		if (u1.match(JBool) || u2.match(JBool)) return JBool;
		return if (JvmSignature.jsigEq(u1, stringSig) || JvmSignature.jsigEq(u2, stringSig)) stringSig else objectSig;
	}

	public function getBinopType(t1:T, t2:T):JSignature return getBinopTypeSig(Genjvm.jsignatureOfType(gctx, t1), Genjvm.jsignatureOfType(gctx, t2));

	public function doCompare(op:JCmp):CompareKind {
		function funCompare(path1:JPath, sig2:JSignature):CompareKind {
			return switch sig2 {
				case JObject(path2, _) if (JvmSignature.pathEq(path1, path2)):
					jm.invokevirtual(path2, "equals", methodSig([objectSig], JBool));
					CmpNormal(op, JBool);
				case _:
					jm.invokestatic(haxeJvmPath, "compare", methodSig([objectSig, objectSig], JInt));
					var op = Genjvm.flipCmpOp(op);
					CmpNormal(op, JBool);
			}
		}
		inline function isIntLike(s:JSignature):Bool return s.match(JInt | JByte | JChar | JShort | JBool);
		inline function isStringNoParams(s:JSignature):Bool return switch s {
			case JObject(p, []): isPath(p, ["java", "lang"], "String");
			case _: false;
		}
		inline function isObjectNoParamsOrTp(s:JSignature):Bool return switch s {
			case JObject(p, []): isPath(p, ["java", "lang"], "Object");
			case JTypeParameter(_): true;
			case _: false;
		}
		var items = code.getStack().getStackItems(2);
		var a = items[0], b = items[1];
		return if (isIntLike(a) && isIntLike(b)) {
			var op = Genjvm.flipCmpOp(op);
			CmpSpecial(function(r) code.ifIcmp(op, r));
		} else if (isStringNoParams(a) && isStringNoParams(b)) {
			jm.invokestatic(haxeJvmPath, "stringCompare", methodSig([stringSig, stringSig], JInt));
			var op = Genjvm.flipCmpOp(op);
			CmpNormal(op, JBool);
		} else if (isObjectNoParamsOrTp(a) || isObjectNoParamsOrTp(b)) {
			jm.invokestatic(haxeJvmPath, "compare", methodSig([objectSig, objectSig], JInt));
			var op = Genjvm.flipCmpOp(op);
			CmpNormal(op, JBool);
		} else switch [a, b] {
			case [sig2, JObject(path1, _)] if (jc.hasTypedFunction(path1) || JvmSignature.pathEq(path1, haxeFunctionPath)):
				funCompare(path1, sig2);
			case [JObject(path1, _), sig2] if (jc.hasTypedFunction(path1) || JvmSignature.pathEq(path1, haxeFunctionPath)):
				code.swap();
				funCompare(path1, sig2);
			case [JMethod(_), _] | [_, JMethod(_)]:
				jm.invokestatic(haxeJvmPath, "compareFunctions", methodSig([objectSig, objectSig], JBool));
				CmpNormal(op, JBool);
			case [t1 = (JObject(_) | JArray(_)), t2 = (JObject(_) | JArray(_))]:
				CmpSpecial(function(r) (if (op == CmpEq) code.ifAcmpNe else code.ifAcmpEq)(t1, t2, r));
			case [JDouble, JDouble]:
				var op = Genjvm.flipCmpOp(op);
				switch op {
					case CmpGe | CmpGt: code.dcmpg();
					case _: code.dcmpl();
				}
				CmpNormal(op, JDouble);
			case [JFloat, JFloat]:
				var op = Genjvm.flipCmpOp(op);
				switch op {
					case CmpGe | CmpGt: code.fcmpg();
					case _: code.fcmpl();
				}
				CmpNormal(op, JFloat);
			case [JLong, JLong]:
				var op = Genjvm.flipCmpOp(op);
				code.lcmpl();
				CmpNormal(op, JLong);
			case [t1, t2]:
				JvmGlobals.jerror('Can\'t compare ${JvmSignature.generateSignature(false, t1)} and ${JvmSignature.generateSignature(false, t2)}');
		}
	}

	public function binopCompare(op:JCmp, e1:TExpr, e2:TExpr):CompareKind {
		var sig1 = Genjvm.jsignatureOfType(gctx, e1.etype);
		var sig2 = Genjvm.jsignatureOfType(gctx, e2.etype);
		var isEqOp = switch op {
			case CmpEq | CmpGe | CmpLe: true;
			case _: false;
		}
		var s1 = Texpr.skip(e1), s2 = Texpr.skip(e2);
		return switch [s1, s2] {
			case [{eexpr: TConst(TNull)}, _] if (!isUnboxed(sig2)):
				texpr(Genjvm.rvalueAny, e2);
				CmpSpecial(function(r) (if (isEqOp) jm.getCode().ifNonnull else jm.getCode().ifNull)(sig2, r));
			case [_, {eexpr: TConst(TNull)}] if (!isUnboxed(sig1)):
				texpr(Genjvm.rvalueAny, e1);
				CmpSpecial(function(r) (if (isEqOp) jm.getCode().ifNonnull else jm.getCode().ifNull)(sig1, r));
			case [{eexpr: TConst(TInt(i32)), etype: t2}, e1] if (i32 == 0 && sig2.match(JInt)):
				var op = switch op {
					case CmpGt: CmpGe;
					case CmpLt: CmpLe;
					case CmpLe: CmpLt;
					case CmpGe: CmpGt;
					case CmpEq: CmpNe;
					case CmpNe: CmpEq;
				}
				texpr(Genjvm.rvalueAny, e1);
				cast_(t2);
				CmpNormal(op, JInt);
			case [e1, {eexpr: TConst(TInt(i32)), etype: t2}] if (i32 == 0 && sig1.match(JInt)):
				var op = Genjvm.flipCmpOp(op);
				texpr(Genjvm.rvalueAny, e1);
				cast_(t2);
				CmpNormal(op, JInt);
			case _:
				switch [isUnboxed(sig1), isUnboxed(sig2)] {
					case [true, true]:
						function f(e:TExpr) return function(ret:Ret) texpr(ret, e);
						binopExprs(getBinopType(e1.etype, e2.etype), f(e1), f(e2));
						doCompare(op);
					case [false, false]:
						var sigUnboxed1 = getUnboxedType(sig1);
						var sigUnboxed2 = getUnboxedType(sig2);
						if (JvmSignature.jsigEq(sig1, sigUnboxed1) && JvmSignature.jsigEq(sig2, sigUnboxed2)) {
							/* No basic types involved, do normal comparison */
							texpr(Genjvm.rvalueAny, e1);
							texpr(Genjvm.rvalueAny, e2);
							doCompare(op);
						} else {
							/* At least one of the types is a wrapped numeric one */
							var castType = getBinopTypeSig(sigUnboxed1, sigUnboxed2);
							texpr(Genjvm.rvalueAny, e1);
							jm.getCode().dup();
							jm.ifThenElse(function(r) jm.getCode().ifNonnull(sig1, r), function() {
								jm.getCode().pop();
								texpr(Genjvm.rvalueAny, e2);
								switch op {
									case CmpEq | CmpGe | CmpLe:
										boolop(CmpSpecial(function(r) jm.getCode().ifNonnull(sig2, r)));
									case CmpNe:
										boolop(CmpSpecial(function(r) jm.getCode().ifNull(sig2, r)));
									case _:
										jm.getCode().pop();
										jm.getCode().bconst(false);
								}
							}, function() {
								jm.cast_(true, castType);
								texpr(Genjvm.rvalueAny, e2);
								jm.getCode().dup();
								jm.ifThenElse(function(r) jm.getCode().ifNonnull(sig2, r), function() {
									jm.getCode().pop();
									jm.getCode().pop();
									jm.getCode().bconst(op == CmpNe);
								}, function() {
									jm.cast_(true, castType);
									boolop(doCompare(op));
								});
							});
							CmpNormal(CmpEq, JBool);
						}
					case [false, true]:
						texpr(Genjvm.rvalueAny, e1);
						jm.getCode().dup();
						jm.ifThenElse(function(r) jm.getCode().ifNonnull(sig1, r), function() {
							jm.getCode().pop();
							jm.getCode().bconst(op == CmpNe);
						}, function() {
							switch [getUnboxedType(sig1), sig2] {
								case [unboxedSig1 = (JFloat | JDouble), JInt]:
									jm.cast_(true, unboxedSig1);
									texpr(Genjvm.rvalueAny, e2);
									jm.cast_(true, unboxedSig1);
								case _:
									jm.cast_(true, sig2);
									texpr(Genjvm.rvalueAny, e2);
							}
							boolop(doCompare(op));
						});
						CmpNormal(CmpEq, JBool);
					case [true, false]:
						texpr(Genjvm.rvalueAny, e1);
						var castF = switch [sig1, getUnboxedType(sig2)] {
							case [JInt, unboxedSig2 = (JFloat | JDouble)]:
								jm.cast_(true, unboxedSig2);
								texpr(Genjvm.rvalueAny, e2);
								function() jm.cast_(true, unboxedSig2);
							case _:
								texpr(Genjvm.rvalueAny, e2);
								function() jm.cast_(true, sig1);
						}
						jm.getCode().dup();
						jm.ifThenElse(function(r) jm.getCode().ifNonnull(sig2, r), function() {
							jm.getCode().pop();
							jm.getCode().pop();
							jm.getCode().bconst(op == CmpNe);
						}, function() {
							castF();
							boolop(doCompare(op));
						});
						CmpNormal(CmpEq, JBool);
				}
		}
	}

	public function binopBasic(ret:Ret, op:Binop, castType:JSignature, f1:Ret->Void, f2:Ret->Void):Void {
		function emitExprs() binopExprs(castType, f1, f2);
		function methodName():String return switch op {
			case OpAdd: "opAdd";
			case OpSub: "opSub";
			case OpMult: "opMul";
			case OpDiv: "opDiv";
			case OpMod: "opMod";
			case OpAnd: "opAnd";
			case OpOr: "opOr";
			case OpXor: "opXor";
			case OpShl: "opShl";
			case OpShr: "opShr";
			case OpUShr: "opUshr";
			case _: die("", "generators/genjvm.ml");
		}
		switch castType {
			case JByte | JShort | JInt:
				switch op {
					case OpAdd:
						emitExprs();
						code.iadd();
					case OpSub:
						emitExprs();
						code.isub();
					case OpMult:
						emitExprs();
						code.imul();
					case OpDiv:
						f1(Genjvm.rvalueSig(JDouble));
						jm.cast_(JDouble);
						f2(Genjvm.rvalueSig(JDouble));
						jm.cast_(JDouble);
						code.ddiv();
					case OpAnd:
						emitExprs();
						code.iand();
					case OpOr:
						emitExprs();
						code.ior();
					case OpXor:
						emitExprs();
						code.ixor();
					case OpShl:
						emitExprs();
						code.ishl();
					case OpShr:
						emitExprs();
						code.ishr();
					case OpUShr:
						emitExprs();
						code.iushr();
					case OpMod:
						emitExprs();
						code.irem();
					case _:
						JvmGlobals.jerror('Unsupported binop on TInt: ${core.Ast.Ast.sBinop(op)}');
				}
			case JFloat:
				emitExprs();
				switch op {
					case OpAdd: code.fadd();
					case OpSub: code.fsub();
					case OpMult: code.fmul();
					case OpDiv: code.fdiv();
					case OpMod: code.frem();
					case _: JvmGlobals.jerror('Unsupported binop on TFloat: ${core.Ast.Ast.sBinop(op)}');
				}
			case JDouble:
				emitExprs();
				switch op {
					case OpAdd: code.dadd();
					case OpSub: code.dsub();
					case OpMult: code.dmul();
					case OpDiv: code.ddiv();
					case OpMod: code.drem();
					case _: JvmGlobals.jerror('Unsupported binop on TDouble: ${core.Ast.Ast.sBinop(op)}');
				}
			case JLong:
				switch op {
					case OpAdd:
						emitExprs();
						code.ladd();
					case OpSub:
						emitExprs();
						code.lsub();
					case OpMult:
						emitExprs();
						code.lmul();
					case OpDiv:
						emitExprs();
						code.ldiv();
					case OpAnd:
						emitExprs();
						code.land_();
					case OpOr:
						emitExprs();
						code.lor_();
					case OpXor:
						emitExprs();
						code.lxor_();
					case OpShl:
						f1(Genjvm.rvalueSig(JLong));
						jm.cast_(JLong);
						f2(Genjvm.rvalueSig(JLong));
						jm.cast_(JInt);
						code.lshl();
					case OpShr:
						f1(Genjvm.rvalueSig(JLong));
						jm.cast_(JLong);
						f2(Genjvm.rvalueSig(JInt));
						jm.cast_(JInt);
						code.lshr();
					case OpUShr:
						f1(Genjvm.rvalueSig(JLong));
						jm.cast_(JLong);
						f2(Genjvm.rvalueSig(JInt));
						jm.cast_(JInt);
						code.lushr();
					case OpMod:
						emitExprs();
						code.lrem();
					case _:
						JvmGlobals.jerror('Unsupported binop on TInt: ${core.Ast.Ast.sBinop(op)}');
				}
			case JBool | JTypeParameter(_):
				binopBasicObject(op, f1, f2, emitExprs, methodName);
			case JObject(p, _) if (isPath(p, ["java", "lang"], "Object")):
				binopBasicObject(op, f1, f2, emitExprs, methodName);
			case JObject(path, _):
				if (JvmSignature.pathEq(path, stringPath)) {
					f1(Genjvm.rvalueAny);
					jm.cast_(false, true, castType);
					f2(Genjvm.rvalueAny);
					jm.cast_(false, true, castType);
					jm.invokestatic(haxeJvmPath, "stringConcat", methodSig([objectSig, objectSig], stringSig));
				} else {
					emitExprs();
					var name = methodName();
					jm.invokestatic(haxeJvmPath, name, methodSig([objectSig, objectSig], objectSig));
				}
			case _:
				JvmGlobals.jerror('Unsupported operation ${core.Ast.Ast.sBinop(op)} on ${JvmSignature.generateSignature(false, castType)}');
		}
	}

	// port: the `TBool | TObject((["java";"lang"],"Object"),_) | TTypeParameter _` branch of binop_basic.
	function binopBasicObject(op:Binop, f1:Ret->Void, f2:Ret->Void, emitExprs:Void->Void, methodName:Void->String):Void {
		switch op {
			case OpBoolAnd:
				function operand(f:Ret->Void) {
					f(Genjvm.rvalueSig(JBool));
					jm.cast_(JBool);
				}
				operand(f1);
				jm.ifThenElse(function(r) code.if_(CmpEq, r), function() operand(f2), function() code.bconst(false));
			case OpBoolOr:
				function operand(f:Ret->Void) {
					f(Genjvm.rvalueSig(JBool));
					jm.cast_(JBool);
				}
				operand(f1);
				jm.ifThenElse(function(r) code.if_(CmpEq, r), function() code.bconst(true), function() operand(f2));
			case _:
				emitExprs();
				var name = methodName();
				jm.invokestatic(haxeJvmPath, name, methodSig([objectSig, objectSig], objectSig));
		}
	}

	public function boolop(cmp:CompareKind):Void {
		jm.ifThenElse(applyCmp(cmp), function() code.bconst(true), function() code.bconst(false));
	}

	public function varSlotIsInInt8Range(v:TVar):Bool {
		var slot = getLocal(v).slot;
		return JvmGlobals.inRange(true, Int8Range, slot);
	}

	public function binop(ret:Ret, op:Binop, e1:TExpr, e2:TExpr):Void {
		switch op {
			case OpEq | OpNotEq | OpLt | OpGt | OpLte | OpGte:
				var op = Genjvm.convertCmpOp(op);
				boolop(binopCompare(op, e1, e2));
			case OpAssign:
				function f() {
					texpr(Genjvm.rvalueType(gctx, e1.etype, null), e2);
					cast_(e1.etype);
				}
				readWrite(ret, AKNone, e1, f);
			case OpAssignOp(op):
				var jsig1 = Genjvm.jsignatureOfType(gctx, e1.etype);
				switch [op, Texpr.skip(e1).eexpr, Texpr.skip(e2).eexpr] {
					case [OpAdd, TLocal(v), TConst(TInt(i32))] if (Genjvm.isReallyInt(v.vType) && JvmGlobals.inRange(false, Int8Range, i32)
						&& varSlotIsInInt8Range(v)):
						var l = getLocal(v);
						var i = i32;
						code.iinc(l.slot, i);
						if (Genjvm.needVal(ret)) l.load();
					case [OpSub, TLocal(v), TConst(TInt(i32))] if (Genjvm.isReallyInt(v.vType) && JvmGlobals.inRange(false, Int8Range, -i32)
						&& varSlotIsInInt8Range(v)):
						var l = getLocal(v);
						var i = -i32;
						code.iinc(l.slot, i);
						if (Genjvm.needVal(ret)) l.load();
					case _:
						function f() {
							binopBasic(ret, op, getBinopType(e1.etype, e2.etype), function(_) {}, function(ret) texpr(ret, e2));
							jm.cast_(jsig1);
						}
						readWrite(ret, AKPre, e1, f);
				}
			case _:
				function f(e:TExpr) return function(ret:Ret) texpr(ret, e);
				binopBasic(ret, op, getBinopType(e1.etype, e2.etype), f(e1), f(e2));
		}
	}

	public function unop(ret:Ret, op:Unop, flag:UnopFlag, e:TExpr):Void {
		switch [op, Texpr.skip(e).eexpr] {
			case [(Increment | Decrement), TLocal(v)] if (Genjvm.isReallyInt(v.vType) && varSlotIsInInt8Range(v)):
				var l = getLocal(v);
				if (flag == Postfix && Genjvm.needVal(ret)) l.load();
				code.iinc(l.slot, if (op == Increment) 1 else -1);
				if (flag == Prefix && Genjvm.needVal(ret)) l.load();
			case [(Increment | Decrement), _]:
				var isNull = isNull(e.etype);
				function f() {
					switch jm.getCode().getStack().top() {
						case JLong:
							code.lconst(haxe.Int64.ofInt(1));
							if (op == Increment) code.ladd() else code.lsub();
						case JDouble:
							code.dconst(1.);
							if (op == Increment) code.dadd() else code.dsub();
						case JFloat:
							code.fconst(1.);
							if (op == Increment) code.fadd() else code.fsub();
						case JByte | JShort | JInt:
							code.iconst(1);
							if (op == Increment) code.iadd() else code.isub();
							if (isNull) expectReferenceType();
						case _:
							jm.invokestatic(haxeJvmPath, if (op == Increment) "opIncrement" else "opDecrement", methodSig([objectSig], objectSig));
					}
				}
				readWrite(ret, if (flag == Prefix) AKPre else AKPost, e, f);
			case [Neg, _]:
				texpr(Genjvm.rvalueAny, e);
				var jsig = Genjvm.jsignatureOfType(gctx, followA(e.etype));
				jm.cast_(jsig);
				switch jsig {
					case JLong: code.lneg();
					case JDouble: code.dneg();
					case JFloat: code.fneg();
					case JByte | JShort | JInt: code.ineg();
					case _: jm.invokestatic(haxeJvmPath, "opNeg", methodSig([objectSig], objectSig));
				}
				cast_(e.etype);
			case [Not, _]:
				jm.ifThenElseLabeled(function(lt, le) condition(false, e, lt, le), function() code.bconst(false), function() code.bconst(true));
			case [Spread, _]:
				texpr(Genjvm.rvalueType(gctx, e.etype, null), e);
			case [NegBits, _]:
				var jsig = Genjvm.jsignatureOfType(gctx, followA(e.etype));
				texpr(Genjvm.rvalueAny, e);
				jm.cast_(jsig);
				switch jsig {
					case JByte | JShort | JInt:
						code.iconst(-1);
						code.ixor();
					case JLong:
						code.lconst(haxe.Int64.ofInt(-1));
						code.lxor_();
					case _:
						jm.invokestatic(haxeJvmPath, "opNegBits", methodSig([objectSig], objectSig));
				}
				cast_(e.etype);
		}
	}

	/* calls */
	public function callArguments(?doCast:Bool = true, t:T, el:Array<TExpr>):{tl:Array<JSignature>, tr:Null<JSignature>} {
		var tl, tr;
		switch followWithCoro(t) {
			case NotCoro(TFun(s)):
				tl = s.args;
				tr = Genjvm.returnOfType(gctx, s.ret);
			case Coro(s):
				var s = context.Common.expandCoroType(gctx.gctx.basic, s.args, s.ret);
				tl = s.args;
				tr = Genjvm.returnOfType(gctx, s.ret);
			case _:
				tl = el.map(function(e) return {name: "", optional: false, type: e.etype});
				tr = objectSig;
		}
		var acc:Array<JSignature> = [];
		var ti = 0, ei = 0;
		while (true) {
			if (ti < tl.length && ei < el.length) {
				var t = tl[ti].type, e = el[ei];
				var jsig = Genjvm.jsignatureOfType(gctx, t);
				switch [ti == tl.length - 1, TFunctions.follow(t)] {
					case [true, TAbstract({aPath: {pack: ["haxe"], name: "Rest"}}, [t1])]:
						switch e.eexpr {
							case TUnop(Spread, _, e):
								texpr(Genjvm.rvalueSig(jsig), e);
							case _:
								newNativeArray(Genjvm.jsignatureOfType(gctx, t1), el.slice(ei));
						}
						acc.push(jsig);
						break;
					case _:
						texpr(Genjvm.rvalueSig(jsig), e);
						if (doCast) {
							jm.cast_(jsig);
							acc.push(jsig);
						} else
							acc.push(code.getStack().top());
						ti++;
						ei++;
				}
			} else if (ti == tl.length - 1 && ei >= el.length) {
				var t = tl[ti].type;
				switch TFunctions.follow(t) {
					case TAbstract({aPath: {pack: ["haxe"], name: "Rest"}}, [t1]):
						var jsig = Genjvm.jsignatureOfType(gctx, t);
						newNativeArray(Genjvm.jsignatureOfType(gctx, t1), []);
						acc.push(jsig);
					case _:
				}
				break;
			} else if (ei >= el.length) {
				break;
			} else {
				/* TODO: this sucks */
				var e = el[ei];
				texpr(Genjvm.rvalueAny, e);
				acc.push(vtype(e.etype));
				ti = tl.length;
				ei++;
			}
		}
		return {tl: acc, tr: tr};
	}

	public function call(ret:Ret, tr:T, e1:TExpr, el:Array<TExpr>):Void {
		function invoke(t:T):Null<JSignature> {
			jm.cast_(haxeFunctionSig);
			/* We don't want to cast because typed functions handle that for us. */
			var r = callArguments(false, t, el);
			var meth = gctx.typedFunctions.registerSignature(r.tl, r.tr);
			jm.invokevirtual(haxeFunctionPath, meth.name, methodSig(meth.dargs, meth.dret));
			return r.tr;
		}
		var tro:Null<JSignature>;
		var hasTro:Bool = true;
		switch Texpr.skip(e1).eexpr {
			case TField(_, FStatic({clPath: {pack: ["haxe", "jvm"], name: "Jvm"}}, cf = {cfName: "referenceEquals"})):
				var r = callArguments(cf.cfType, el);
				switch r.tl {
					case [t1, t2]: boolop(CmpSpecial(function(r) code.ifAcmpNe(t1, t2, r)));
					case _: die("", "generators/genjvm.ml");
				}
				tro = r.tr;
			case TField(_, FStatic({clPath: {pack: ["haxe", "jvm"], name: "Jvm"}}, {cfName: "instanceof"})):
				switch el {
					case [e1, {eexpr: TTypeExpr(mt), epos: pe}]:
						texpr(Genjvm.rvalueAny, e1);
						expectReferenceType();
						var path = switch Genjvm.jsignatureOfType(gctx, typeOfModuleType(mt)) {
							case JObject(path, _): path;
							case _: core.Error.raiseTypingError("Class expected", pe);
						}
						code.instanceof(path);
						tro = JBool;
					case _:
						tro = core.Error.raiseTypingError("Type expression expected", e1.epos);
				}
			case TField(_, FStatic(c, cf)) if (isPath(c.clPath, ["java", "lang"], "Math") && (cf.cfName == "isNaN" || cf.cfName == "isFinite")):
				var name = cf.cfName;
				switch el {
					case [e1]:
						texpr(Genjvm.rvalueAny, e1);
						jm.cast_(JDouble);
						jm.invokestatic({pack: ["java", "lang"], name: "Double"}, name, methodSig([JDouble], JBool));
						tro = JBool;
					case _:
						tro = die("", "generators/genjvm.ml");
				}
			case TField(_, FStatic(c, cf)) if (isPath(c.clPath, ["java", "lang"], "Math")
				&& (cf.cfName == "floor" || cf.cfName == "ceil" || cf.cfName == "round")):
				var name = cf.cfName;
				switch el {
					case [e1]:
						texpr(Genjvm.rvalueAny, e1);
						jm.cast_(JDouble);
						var rsig = if (name == "round") JLong else JDouble;
						jm.invokestatic({pack: ["java", "lang"], name: "Math"}, name, methodSig([JDouble], rsig));
						jm.cast_(JInt);
						tro = JInt;
					case _:
						tro = die("", "generators/genjvm.ml");
				}
			case TField(_, FStatic(c, cf)) if (isPath(c.clPath, ["java", "lang"], "Math") && (cf.cfName == "ffloor" || cf.cfName == "fceil")):
				var r = callArguments(cf.cfType, el);
				jm.invokestatic(c.clPath, cf.cfName.substr(1, cf.cfName.length - 1), methodSig(r.tl, r.tr));
				tro = r.tr;
			case TField(_, FStatic({clPath: {pack: ["haxe"], name: "Int64$Int64_Impl_"}}, {cfName: "make"})):
				switch el {
					case [{eexpr: TConst(TInt(i1))}, {eexpr: TConst(TInt(i2))}]:
						var i = haxe.Int64.make(i1, i2);
						jm.getCode().lconst(i);
						tro = JLong;
					case [e1, e2]:
						texpr(Genjvm.rvalueSig(JLong), e1);
						jm.cast_(JLong);
						jm.getCode().iconst(32);
						jm.getCode().lshl();
						texpr(Genjvm.rvalueSig(JLong), e2);
						jm.cast_(JLong);
						jm.getCode().lconst(haxe.Int64.make(0, 0xFFFFFFFF));
						jm.getCode().land_();
						jm.getCode().lor_();
						tro = JLong;
					case _:
						tro = die("", "generators/genjvm.ml");
				}
			case TIdent("__array__") | TField(_, FStatic({clPath: {pack: ["jvm"], name: "NativeArray"}}, {cfName: "make"})):
				switch followA(tr) {
					case TInst({clPath: {pack: ["jvm"], name: "NativeArray"}}, [t]):
						var jsig = vtype(t);
						newNativeArray(jsig, el);
						tro = arraySig(jsig);
					case _:
						tro = core.Error.raiseTypingError('Bad __array__ type: ${core.TPrinting.sType(core.TPrinting.printContext(), tr)}', e1.epos);
				}
			case TField(_, FStatic({clPath: {pack: ["haxe"], name: "EnumTools"}}, {cfName: "values"})):
				switch el {
					case [e1]:
						var jsigRet = arraySig(objectPathSig(objectPath));
						var meth = gctx.typedFunctions.registerSignature([], jsigRet);
						var jsigMeth = methodSig(meth.dargs, meth.dret);
						read(function() jm.cast_(jsigMeth), e1, FDynamic("values"));
						jm.invokevirtual(haxeFunctionPath, meth.name, jsigMeth);
						tro = jsigRet;
					case _:
						tro = die("", "generators/genjvm.ml");
				}
			case TField(e1, FStatic(c, cf = {cfKind: Method(MethNormal | MethInline)})):
				var r = callArguments(cf.cfType, el);
				var kind = if (hasClassFlag(c, CInterface)) FKInterfaceMethod else FKMethod;
				jm.invokestatic(c.clPath, cf.cfName, kind, methodSig(r.tl, r.tr));
				tro = r.tr;
			case TField(e1, FInstance(c = {clPath: {pack: ["haxe", "root"], name: "StringBuf"}, clDescendants: []}, _, cf = {cfName: "add"})):
				texpr(Genjvm.rvalueAny, e1);
				var jsig = switch el {
					case [ea1]:
						texpr(Genjvm.rvalueAny, ea1);
						switch code.getStack().top() {
							case jsig = (JBool | JChar | JDouble | JFloat | JInt | JLong):
								jsig;
							case jsig = JObject(p, _) if (isPath(p, ["java", "lang"], "String")):
								jsig;
							case JByte | JShort:
								jm.cast_(JInt);
								JInt;
							case _:
								jm.cast_(objectSig);
								objectSig;
						}
					case _:
						callArguments(cf.cfType, el);
						objectSig;
				}
				jm.invokevirtual(c.clPath, "add", methodSig([jsig], null));
				tro = null;
				hasTro = false;
			case TField(e1, FInstance(c, tl, cf = {cfKind: Method(MethNormal | MethInline)})):
				var isSuper = switch e1.eexpr {
					case TConst(TSuper):
						code.aload(jc.getJsig(), 0);
						true;
					case _:
						texpr(Genjvm.rvalueAny, e1);
						false;
				}
				var r = callArguments(cf.cfType, el);
				(if (isSuper) jm.invokespecial else if (hasClassFlag(c, CInterface)) jm.invokeinterface else jm.invokevirtual)(c.clPath, cf.cfName,
					methodSig(r.tl, r.tr));
				tro = r.tr;
			case TField(_, FEnum(en, ef)):
				var r = callArguments(ef.efType, el);
				var tr = vtype(tr);
				jm.invokestatic(en.ePath, ef.efName, methodSig(r.tl, tr));
				tro = tr;
			case TField(e11, FAnon(cf)):
				switch gctx.anonIdentification.identify(AnonIdMode.defaultMode, false, e11.etype) {
					case null:
						texpr(Genjvm.rvalueAny, e1);
						tro = invoke(e1.etype);
					case {pfmPath: pathAnon}:
						switch gctx.typedefInterfaces.getInterfaceClass(pathAnon) {
							case null:
								texpr(Genjvm.rvalueAny, e1);
								tro = invoke(e1.etype);
							case c:
								var rcf = rawClassField(function(cf) return cf.cfType, c, [], cf.cfName);
								var cf = rcf.field;
								var pathInner = switch rcf.owner {
									case null: die("", "generators/genjvm.ml");
									case ct: ct.cls.clPath;
								}
								texpr(Genjvm.rvalueAny, e11);
								var r = callArguments(cf.cfType, el);
								jm.invokeinterface(pathInner, cf.cfName, vtype(cf.cfType));
								if (r.tr != null) jm.cast_(r.tr);
								tro = r.tr;
						}
				}
			case TConst(TSuper):
				var sc = switch fieldInfo {
					case info if (info != null && info.superCallFields.length > 0):
						var hd = info.superCallFields[0];
						info.superCallFields = info.superCallFields.slice(1);
						hd;
					case _:
						core.Error.raiseTypingError("Could not find field information for super call, please report this", e1.epos);
				}
				var c = sc.c, cf = sc.cf;
				var kind = Genjvm.getConstructionMode(c, cf);
				switch kind {
					case ConstructInitPlusNew if (jm.getName() == "<init>"):
						jm.loadThis();
						jm.getCode().aconstNull(haxeEmptyConstructorSig);
						jm.callSuperCtor(ConstructInit, methodSig([haxeEmptyConstructorSig], null));
					case _:
				}
				jm.loadThis();
				var r = callArguments(cf.cfType, el);
				jm.callSuperCtor(kind, methodSig(r.tl, null));
				tro = null;
				hasTro = false;
			case TIdent("__lock__"):
				switch el {
					case [e1, e2]:
						texpr(Genjvm.rvalueAny, e1);
						jm.getCode().dup();
						var l = jm.addLocal("tmp", vtype(e1.etype), VarWillInit);
						var load = l.load;
						l.store();
						jm.getCode().monitorenter();
						function fExit() {
							load();
							jm.getCode().monitorexit();
						}
						blockExits = [ExitExecute(fExit)].concat(blockExits);
						var fpFrom = jm.getCode().getFp();
						texpr(RVoid, e2);
						var termTry = jm.isTerminated();
						if (!jm.isTerminated()) fExit();
						var fpTo = jm.getCode().getFp();
						var rTry = jm.maybeMakeJump();
						var fpTarget = jm.getCode().getFp();
						var popScope = jm.pushScope();
						code.getStack().push(throwableSig);
						jm.addStackFrame();
						jm.addException({
							excStartPc: fpFrom,
							excEndPc: fpTo,
							excHandlerPc: fpTarget,
							excCatchType: null,
						});
						{
							var l = jm.addLocal("tmp", throwableSig, VarWillInit);
							l.store();
							fExit();
							jm.addException({
								excStartPc: fpTarget,
								excEndPc: jm.getCode().getFp(),
								excHandlerPc: fpTarget,
								excCatchType: null,
							});
							l.load();
							jm.getCode().athrow();
						}
						popScope();
						blockExits = blockExits.slice(1);
						if (!termTry) jm.addStackFrame();
						jm.closeJumps(true, [{term: termTry, r: rTry}]);
						tro = null;
						hasTro = false;
					case _:
						tro = die("", "generators/genjvm.ml");
				}
			case _:
				texpr(Genjvm.rvalueAny, e1);
				var t = switch e1.eexpr {
					case TLocal(v = {vExtra: {vParams: l}}) if (l.length > 0):
						/* If we call a local variable with type parameters, we want to use the general (unapplied)
							 type, which is the variable type itself. This is necessary for some special situations
							 like the Rest<T> case in issue #10906. */
						v.vType;
					case _:
						e1.etype;
				}
				tro = invoke(t);
		}
		if (tro == null) hasTro = false;
		switch [Genjvm.needVal(ret), hasTro] {
			case [false, true]: code.pop();
			case [false, false]:
			case [true, true]: cast_(tr);
			case [true, false]: die("", "generators/genjvm.ml");
		}
	}

	/* exceptions */
	public function tryCatch(ret:Ret, e1:TExpr, catches:Array<{variable:TVar, expr:TExpr}>):Void {
		var restore = jm.startBranch();
		var fpFrom = code.getFp();
		var oldExceptions = caughtExceptions;
		var excl = catches.map(function(c) {
			var exc = new HaxeException(gctx, c.variable.vType);
			caughtExceptions = [exc].concat(caughtExceptions);
			return {exc: exc, v: c.variable, e: c.expr};
		});
		texpr(ret, e1);
		caughtExceptions = oldExceptions;
		var termTry = jm.isTerminated();
		var rTry = jm.maybeMakeJump();
		var fpTo = code.getFp();
		function startExceptionBlock(path:JPath, jsig:JSignature) {
			restore();
			var fpTarget = code.getFp();
			var offset = pool.addPath(path);
			jm.addException({
				excStartPc: fpFrom,
				excEndPc: fpTo,
				excHandlerPc: fpTarget,
				excCatchType: offset,
			});
			code.getStack().push(jsig);
			jm.addStackFrame();
		}
		function runCatchExpr(v:TVar, e:TExpr):Bool {
			var popScope = jm.pushScope();
			var store = addLocal(v, VarWillInit).store;
			store();
			texpr(ret, e);
			popScope();
			return jm.isTerminated();
		}
		function addCatch(c:{exc:HaxeException, v:TVar, e:TExpr}):{term:Bool, r:JBranchOffsetRef} {
			startExceptionBlock(c.exc.getNativePath(), c.exc.getNativeType());
			var term = runCatchExpr(c.v, c.e);
			var r = jm.maybeMakeJump();
			return {term: term, r: r};
		}
		var rl = [];
		for (c in excl) {
			var res = addCatch(c);
			rl.unshift(res);
		}
		jm.closeJumps(true, [{term: termTry, r: rTry}].concat(rl));
	}

	public function emitBlockExits(isLoopExit:Bool):Void {
		for (b in blockExits) switch b {
			case ExitLoop:
				if (isLoopExit) break;
			case ExitExecute(f):
				f();
		}
	}

	/* texpr */
	public function const(ret:Ret, t:T, ct:TConstant):Void {
		switch ct {
			case TInt(i32):
				switch ret {
					case RValue(JLong, _): code.lconst(haxe.Int64.ofInt(i32));
					case RValue(JObject(p, _), _) if (isPath(p, ["java", "lang"], "Long")): code.lconst(haxe.Int64.ofInt(i32));
					case RValue(JDouble, _): code.dconst(i32);
					case RValue(JObject(p, _), _) if (isPath(p, ["java", "lang"], "Double")): code.dconst(i32);
					case _: code.iconst(i32);
				}
			case TFloat(f):
				switch ret {
					case RValue(JFloat, _): code.fconst(core.ds.OcamlFloat.ofString(f));
					case RValue(JObject(p, _), _) if (isPath(p, ["java", "lang"], "Float")): code.fconst(core.ds.OcamlFloat.ofString(f));
					case _: code.dconst(core.ds.OcamlFloat.ofString(f));
				}
			case TBool(true): code.bconst(true);
			case TBool(false): code.bconst(false);
			case TNull: jm.loadDefaultValue(vtype(t));
			case TThis:
				var load = getLocalById(0, "this").load;
				load();
			case TString(s): jm.string(s);
			case TSuper: throw new Failure("Invalid super access");
		}
	}

	public function newNativeArray(jsig:JSignature, el:Array<TExpr>):Void {
		jm.newNativeArray(jsig, el.map(function(e) return function() texpr(Genjvm.rvalueSig(jsig), e)));
	}

	public function spawnCompiledPatternField(s1:String, s2:String):JvmMethodBuilder {
		var name = '_hx_pattern_${JvmGlobals.patchName(jm.getName())}_${jm.getNextRegexId()}';
		var jf = jc.spawnField(name, NativeSignatures.haxeCompiledPatternSig, [FdStatic, FdPrivate, FdFinal]);
		var jm = jc.getStaticInitMethod();
		jm.string(s1);
		jm.string(s2);
		jm.invokestatic(NativeSignatures.haxeEregPath, "compilePattern", methodSig([stringSig, stringSig], NativeSignatures.haxeCompiledPatternSig));
		jm.putstatic(jc.getThisPath(), jf.getName(), jf.getJsig());
		return jf;
	}

	public function texpr(ret:Ret, e:TExpr):Void {
		if (!jm.isTerminated()) texpr2(ret, e);
	}

	public function texpr2(ret:Ret, e:TExpr):Void {
		if (e.epos.pmin >= 0) code.setLine(syntax.Lexer.getErrorLine(e.epos));
		switch e.eexpr {
			case TVar(v, e1) if (e1 != null):
				texpr(Genjvm.rvalueType(gctx, v.vType, v.vName), e1);
				cast_(v.vType);
				var store = addLocal(v, VarWillInit).store;
				store();
			case TVar(v, _):
				addLocal(v, VarNeedDefault);
			case TLocal(_) | TConst(_) | TTypeExpr(_) if (!Genjvm.needVal(ret)):
			case TLocal(v):
				var load = getLocal(v).load;
				load();
			case TTypeExpr(mt):
				var t = typeOfModuleType(mt);
				if (ExtType.isVoid(followA(t))) jm.getBasicTypeClass("Void") else jm.getClass(Genjvm.jsignatureOfType(gctx, t));
			case TUnop(op, flag, e1):
				switch op {
					case Not | Neg | NegBits if (!Genjvm.needVal(ret)): texpr(ret, e1);
					case _: unop(ret, op, flag, e1);
				}
			case TBinop(OpAdd, e1, e2) if (Genjvm.isString(followA(e.etype))):
				var stringBuilderPath:JPath = {pack: ["java", "lang"], name: "StringBuilder"};
				var stringBuilderSig = objectPathSig(stringBuilderPath);
				jm.construct(ConstructInit, stringBuilderPath, function() return []);
				function loop(e:TExpr):Void {
					switch e.eexpr {
						case TBinop(OpAdd, e1, e2) if (Genjvm.isString(followA(e.etype))):
							loop(e1);
							loop(e2);
						case _:
							texpr(Genjvm.rvalueAny, e);
							var jsig = jm.getCode().getStack().top();
							var jsig = switch jsig {
								case JByte | JBool | JChar | JShort | JInt | JLong:
									jsig;
								case JFloat | JDouble:
									/* Haxe mandates 2.0 be printed as 2, so we have to wrap here... */
									jm.expectReferenceType();
									jm.invokestatic(haxeJvmPath, "toString", methodSig([objectSig], stringSig));
									stringSig;
								case _:
									objectSig;
							}
							jm.invokevirtual(stringBuilderPath, "append", methodSig([jsig], stringBuilderSig));
					}
				}
				loop(e1);
				loop(e2);
				jm.invokevirtual(stringBuilderPath, "toString", methodSig([], stringSig));
			case TBinop(op, e1, e2):
				switch op {
					case OpAssign | OpAssignOp(_): binop(ret, op, e1, e2);
					case _ if (!Genjvm.needVal(ret)):
						texpr(ret, e1);
						texpr(ret, e2);
					case _:
						binop(ret, op, e1, e2);
				}
			case TConst(ct):
				const(ret, e.etype, ct);
			case TIf(e1, e2, null):
				jm.ifThenLabeled(function(lt, le) condition(false, e1, lt, le), function() texpr(RVoid, mkBlock(e2)));
			case TIf(e1, e2, e3):
				jm.ifThenElseLabeled(function(lt, le) condition(false, e1, lt, le), function() {
					texpr(ret, mkBlock(e2));
					if (Genjvm.needVal(ret)) cast_(e.etype);
				}, function() {
					texpr(ret, mkBlock(e3));
					if (Genjvm.needVal(ret)) cast_(e.etype);
				});
			case TSwitch(sw):
				switch_(ret, sw);
			case TWhile(e1, e2, flag):
				blockExits = [ExitLoop].concat(blockExits);
				var isTrueLoop = switch Texpr.skip(e1).eexpr {
					case TConst(TBool(true)): true;
					case _: false;
				}
				var continueLabel = jm.spawnLabel("continue");
				var breakLabel = jm.spawnLabel("break");
				var bodyLabel = jm.spawnLabel("body");
				var restore = jm.startBranch();
				if (flag == DoWhile) {
					bodyLabel.goto();
					restore();
				}
				var oldContinue = continue_;
				continue_ = continueLabel;
				var oldBreak = break_;
				break_ = breakLabel;
				continueLabel.here();
				if (!isTrueLoop) condition(false, e1, bodyLabel, breakLabel);
				var popScope = jm.pushScope();
				bodyLabel.here();
				texpr(RVoid, e2);
				if (!jm.isTerminated()) continueLabel.goto();
				popScope();
				restore();
				if (breakLabel.wasJumpedTo() || !isTrueLoop) breakLabel.here() else jm.setTerminated(true);
				continue_ = oldContinue;
				break_ = oldBreak;
				blockExits = blockExits.slice(1);
			case TBreak:
				emitBlockExits(true);
				switch break_ {
					case null:
						JvmGlobals.jerror("break outside loop");
					case label:
						label.goto();
				}
			case TContinue:
				emitBlockExits(true);
				switch continue_ {
					case null:
						JvmGlobals.jerror("continue outside loop");
					case label:
						label.goto();
				}
			case TTry(e1, catches):
				tryCatch(ret, e1, catches);
			case TField(e1, fa):
				if (!Genjvm.needVal(ret)) texpr(ret, e1) else read(function() castExpect(ret, e.etype), e1, fa);
			case TCall(e1, el):
				call(ret, e.etype, e1, el);
			case TNew({clPath: {pack: ["jvm"], name: "NativeArray"}}, [t], [e1]):
				texpr(if (Genjvm.needVal(ret)) Genjvm.rvalueAny else RVoid, e1);
				/* Technically this could throw... but whatever */
				if (Genjvm.needVal(ret)) NativeArray.create(jm.getCode(), jc.getPool(), Genjvm.jsignatureOfType(gctx, t));
			case TNew({clPath: ereg = {pack: ["haxe", "root"], name: "EReg"}}, [], [{eexpr: TConst(TString(s1))}, {eexpr: TConst(TString(s2))}]) if (jm != jc.getStaticInitMethod()):
				var jf = spawnCompiledPatternField(s1, s2);
				jm.construct(ConstructInit, ereg, function() {
					jm.getstatic(jc.getThisPath(), jf.getName(), jf.getJsig());
					return [jf.getJsig()];
				});
			case TNew(c, tl, el):
				// port: guarded (see Genjvm.guardUnify)
				switch Genjvm.guardUnify(gctx, function() return OverloadResolution.maybeResolveConstructorOverload(c, tl, el)) {
					case null:
						core.Error.raiseTypingError("Could not find overload", e.epos);
					case r:
						var c2 = r.cls, cf = r.field;
						function f() {
							return callArguments(cf.cfType, el).tl;
						}
						jm.construct(if (!Genjvm.needVal(ret)) true else false, Genjvm.getConstructionMode(c2, cf), c.clPath, f);
				}
			case TReturn(null):
				emitBlockExits(false);
				jm.return_();
			case TReturn(e1):
				texpr(Genjvm.rvalueAny, e1);
				if (!jm.isTerminated()) {
					var jsig = returnType;
					if (jsig == null) throw new Failure("Option.get");
					jm.cast_(jsig);
					emitBlockExits(false);
					jm.return_();
				}
			case TFunction(tf):
				tfunction(ret, e, tf);
			case TArrayDecl(el) if (!Genjvm.needVal(ret)):
				for (e in el) texpr(ret, e);
			case TArrayDecl(el):
				switch followA(e.etype) {
					case TInst({clPath: {pack: ["haxe", "root"], name: "Array"}}, [t]):
						newNativeArray(Genjvm.jsignatureOfType(gctx, mknull(t)), el);
						jm.invokestatic({pack: ["haxe", "root"], name: "Array"}, "ofNative",
							methodSig([arraySig(objectSig)], objectPathSig({pack: ["haxe", "root"], name: "Array"})));
						cast_(e.etype);
					case _:
						die("", "generators/genjvm.ml");
				}
			case TArray(e1, e2) if (!Genjvm.needVal(ret)):
				/* Array access never throws so this should be fine... */
				texpr(ret, e1);
				texpr(ret, e2);
			case TArray(e1, e2):
				switch followA(e1.etype) {
					case TInst(c = {clPath: {pack: ["haxe", "root"], name: "Array"}}, [t]):
						texpr(Genjvm.rvalueAny, e1);
						texpr(Genjvm.rvalueSig(JInt), e2);
						jm.cast_(JInt);
						jm.invokevirtual(c.clPath, "__get", methodSig([JInt], objectSig));
						cast_(e.etype);
					case TInst({clPath: {pack: ["jvm"], name: "NativeArray"}}, [t]):
						texpr(Genjvm.rvalueAny, e1);
						var vt = vtype(e1.etype);
						var vte = vtype(t);
						texpr(Genjvm.rvalueAny, e2);
						readNativeArray(vt, vte);
					case t:
						texpr(Genjvm.rvalueAny, e1);
						texpr(Genjvm.rvalueAny, e2);
						jm.cast_(JInt);
						jm.invokestatic({pack: ["haxe", "jvm"], name: "Jvm"}, "arrayRead", methodSig([objectSig, JInt], objectSig));
						cast_(e.etype);
				}
			case TBlock([]):
				if (ret.match(RReturn) && !jm.isTerminated()) jm.return_();
			case TBlock(el):
				function loop(i:Int):Void {
					if (i == el.length - 1) {
						texpr(ret, el[i]);
						if (ret.match(RReturn) && !jm.isTerminated()) jm.return_();
					} else {
						texpr(RVoid, el[i]);
						loop(i + 1);
					}
				}
				var popScope = jm.pushScope();
				loop(0);
				popScope();
			case TCast(e1, null):
				texpr(ret, e1);
				if (Genjvm.needVal(ret)) cast_(e.etype);
			case TCast(e1, mt):
				texpr(Genjvm.rvalueAny, e1);
				var jsig = Genjvm.jsignatureOfType(gctx, typeOfModuleType(mt));
				if (isUnboxed(jsig) || isUnboxed(jm.getCode().getStack().top())) jm.cast_(jsig) else code.checkcast(tInfos(mt).mtPath);
				if (!Genjvm.needVal(ret)) code.pop();
			case TParenthesis(e1) | TMeta(_, e1):
				texpr(ret, e1);
			case TEnumIndex(e1):
				texpr(Genjvm.rvalueAny, e1);
				jm.invokevirtual(javaEnumPath, "ordinal", methodSig([], JInt));
			case TEnumParameter(e1, ef, i):
				texpr(Genjvm.rvalueAny, e1);
				var path, name, jsigArg;
				switch followA(ef.efType) {
					case TFun(s):
						var en = switch followA(s.ret) {
							case TEnum(en, _): en;
							case _: die("", "generators/genjvm.ml");
						}
						var a = s.args[i];
						if (a == null) throw new Failure("nth");
						path = en.ePath;
						name = a.name;
						jsigArg = vtype(a.type);
					case _:
						die("", "generators/genjvm.ml");
						return;
				}
				var cpath:JPath = {pack: path.pack, name: path.name + "$" + ef.efName};
				var jsig = objectPathSig(cpath);
				jm.cast_(jsig);
				jm.getfield(cpath, name, jsigArg);
				cast_(e.etype);
			case TThrow(e1):
				texpr(Genjvm.rvalueAny, e1);
				/* There could be something like `throw throw`, so we should only throw if we aren't terminated (issue #10363) */
				if (!jm.isTerminated()) {
					// port: guarded (see Genjvm.guardUnify)
					if (!ExceptionFunctions.isHaxeException(e1.etype)
						&& !Genjvm.guardUnify(gctx, function() return TUnification.doesUnify(e1.etype, gctx.tRuntimeException))) {
						var exc = new HaxeException(gctx, e1.etype);
						if (!Lambda.exists(caughtExceptions, function(exc2) return exc.isAssignableTo(exc2))) jm.addThrownException(exc.getNativePath());
					}
					code.athrow();
					jm.setTerminated(true);
				}
			case TObjectDecl(fl):
				var hadInvalidFieldName = false;
				/* We cannot rely on e.etype because it might have optional field shit, so we need to build a concrete type from the fields... */
				var fields = new haxe.ds.StringMap<TClassField>();
				for (f in fl) {
					var name = f.key.name, e = f.expr;
					var cf = mkField(name, e.etype, e.epos, e.epos);
					if (!syntax.Lexer.isValidIdentifier(name)) hadInvalidFieldName = true;
					fields.set(name, cf);
				}
				var t = mkAnon(Closed, fields);
				var td = gctx.anonIdentification.identify(AnonIdMode.defaultMode, true, t);
				switch td {
					case pfm if (pfm != null && !hadInvalidFieldName):
						var lut = new haxe.ds.StringMap<Void->Void>();
						jm.construct(ConstructInit, pfm.pfmPath, function() {
							/* Step 1: Expressions in order with temp vars */
							for (f in fl) {
								var name = f.key.name, e = f.expr;
								var jsig = vtype(e.etype);
								var load = switch Texpr.skip(e).eexpr {
									case TConst(_) | TTypeExpr(_) | TFunction(_):
										function() texpr(Genjvm.rvalueAny, e);
									case _:
										var l = jm.addLocal('_hx_tmp_$name', jsig, VarWillInit);
										texpr(Genjvm.rvalueAny, e);
										l.store();
										l.load;
								}
								// port: Hashtbl.add: the latest binding wins on lookup
								lut.set(name, load);
							}
							/* Step 2: Fields in order of constructor arguments */
							var order = fl.copy();
							haxe.ds.ArraySort.sort(order, function(a, b) return TypedefInterfaces.compareStrings(a.key.name, b.key.name));
							return order.map(function(f) {
								var name = f.key.name;
								var load = lut.get(name);
								load();
								var cf = pfm.pfmFields.get(name);
								if (cf == null) throw NotFound.raise();
								var jsig = vtype(cf.cfType);
								jm.cast_(jsig);
								return jsig;
							});
						});
					case _:
						jm.construct(ConstructInit, haxeDynamicObjectPath, function() return []);
						for (f in fl) {
							var name = f.key.name, e = f.expr;
							code.dup();
							jm.string(name);
							texpr(Genjvm.rvalueAny, e);
							expectReferenceType();
							jm.invokevirtual(haxeDynamicObjectPath, "_hx_setField", methodSig([stringSig, objectSig], null));
						}
				}
			case TIdent(_):
				core.Error.raiseTypingError(core.TPrinting.sExprAst(false, "", function(t) return core.TPrinting.sType(core.TPrinting.printContext(), t), e),
					e.epos);
		}
	}

	/* api */
	public function objectConstructor():Void {
		var path = jc.getSuperPath();
		var offset = pool.addField(path, "<init>", methodSig([], null), FKMethod);
		jm.loadThis();
		code.invokespecial(offset, jc.getJsig(), [], []);
		jm.setThisInitialized();
	}
}

class TclassToJvm {
	final gctx:GenerationContext;
	final c:TClass;
	final isAnnotation:Bool;
	final fieldInits:Array<TExpr> = [];
	final delayedFieldInits:Array<TExpr> = [];
	final jc:JvmClassBuilder;

	public function new(gctx:GenerationContext, c:TClass) {
		this.gctx = gctx;
		this.c = c;
		isAnnotation = core.Meta.has(MetaTag.Annotation, c.clMeta);
		jc = new JvmClassBuilder(c.clPath, switch c.clSuper {
			case null:
				if (hasClassFlag(c, CInterface) || core.Meta.has(MetaTag.NativeGen, c.clMeta)) objectPath else haxeObjectPath;
			case sup:
				sup.cls.clPath;
		});
	}

	function setAccessFlags():Void {
		jc.addAccessFlag(1); /* public */
		if (hasClassFlag(c, CFinal)) jc.addAccessFlag(0x10);
		if (hasClassFlag(c, CInterface)) {
			jc.addAccessFlag(0x200);
			jc.addAccessFlag(0x400);
		}
		if (isAnnotation) {
			jc.addAccessFlag(0x2000);
			jc.addInterface({pack: ["java", "lang", "annotation"], name: "Annotation"}, []);
			var value = switch core.Ast.Ast.getMetaString(c.clMeta, MetaTag.Annotation) {
				case null: "CLASS";
				case value: value;
			}
			jc.addAnnotation(retentionPath, [{name: "value", kind: AnnotationKind.AEnum(retentionPolicySig, value)}], true);
		}
		if (hasClassFlag(c, CAbstract)) jc.addAccessFlag(0x0400); /* abstract */
		if (core.Meta.has(MetaTag.JvmSynthetic, c.clMeta)) jc.addAccessFlag(0x1000); /* synthetic */
	}

	function buildBridges():Void {
		function makeBridge(name:String, jsigFrom:JSignature, jsigTo:JSignature) {
			var argsFrom, retFrom;
			switch jsigFrom {
				case JMethod(jsigs, jsig):
					argsFrom = jsigs;
					retFrom = jsig;
				case _:
					die("", "generators/genjvm.ml");
					return;
			}
			var argsTo, retTo;
			switch jsigTo {
				case JMethod(jsigs, jsig):
					argsTo = jsigs;
					retTo = jsig;
				case _:
					die("", "generators/genjvm.ml");
					return;
			}
			var jm = jc.spawnMethod(name, jsigFrom, [MPublic, MSynthetic, MBridge]);
			gctx.typedFunctions.makeForwardMethodJsig(jc, jm, name, argsFrom, retFrom, argsTo, retTo);
		}
		function maybeMakeBridge(name:String, jsigFrom:JSignature, jsigTo:JSignature) {
			if (!jc.hasMethod(name, jsigFrom)) makeBridge(name, jsigFrom, jsigTo);
		}
		function compareFields(cfImpl:TClassField, cfSuper:TClassField) {
			var jsigSuper = Genjvm.jsignatureOfType(gctx, cfSuper.cfType);
			var jsigImpl = Genjvm.jsignatureOfType(gctx, cfImpl.cfType);
			if (!JvmSignature.jsigEq(jsigSuper, jsigImpl)) maybeMakeBridge(cfImpl.cfName, jsigSuper, jsigImpl);
		}
		function findOverload(mapType:T->T, c:TClass, cf:TClassField):Null<ResolvedOverload> {
			var tl = switch followWithCoro(mapType(cf.cfType)) {
				case Coro(s): s.args;
				case NotCoro(TFun(s)): s.args;
				case _: die("", "generators/genjvm.ml");
			}
			// port: guarded (see Genjvm.guardUnify)
			return Genjvm.guardUnify(gctx, function() return OverloadResolution.resolveInstanceOverload(false, mapType, c, cf.cfName,
				tl.map(function(a) return TexprBuilder.makeNull(a.type, nullPos))));
		}
		function ifMethod(f:TClassField->Void, cf:TClassField) {
			switch cf.cfKind {
				case Method(MethDynamic):
				case Method(_):
					f(cf);
					for (cf in cf.cfOverloads) f(cf);
				case _:
			}
		}
		switch c.clSuper {
			case null:
			case sup:
				var cSup = sup.cls, tl = sup.params;
				function mapType(t:T):T return applyParams(cSup.clParams, tl, t);
				function checkOverride(cf:TClassField) {
					if (hasClassFieldFlag(cf, CfOverload)) {
						switch findOverload(mapType, cSup, cf) {
							case null:
							case r:
								compareFields(cf, r.field);
						}
					} else {
						var cfSuper = rawClassField(function(cf) return cf.cfType, cSup, extractParamTypes(cSup.clParams), cf.cfName).field;
						compareFields(cf, cfSuper);
					}
				}
				function check(cf:TClassField) {
					if (hasClassFieldFlag(cf, CfOverride)) checkOverride(cf);
				}
				for (cf in c.clOrderedFields) ifMethod(check, cf);
		}
		function checkInterface(mapType0:T->T, ci:ClassAndParams):Void {
			var cInt = ci.cls, tl = ci.params;
			function mapType(t:T):T return mapType0(applyParams(cInt.clParams, tl, t));
			function check(cf:TClassField) {
				switch findOverload(mapType, c, cf) {
					case null:
					case r:
						compareFields(r.field, cf);
				}
			}
			for (cf in cInt.clOrderedFields) ifMethod(check, cf);
			for (i in cInt.clImplements) checkInterface(mapType, i);
		}
		for (i in c.clImplements) checkInterface(function(t) return t, i);
	}

	function setInterfaces():Void {
		for (ci in c.clImplements) {
			if (isAnnotation && Genjvm.isPathOf(ci.cls.clPath, ["java", "lang", "annotation"], "Annotation")) {} else {
				jc.addInterface(ci.cls.clPath, ci.params.map(function(t) return Genjvm.jtypeArgumentOfType(gctx, [], t)));
			}
		}
	}

	function generateEmptyCtor():Void {
		var jsigEmpty = methodSig([haxeEmptyConstructorSig], null);
		var jmEmptyCtor = jc.spawnMethod("<init>", jsigEmpty, [MPublic, MSynthetic]);
		var load = jmEmptyCtor.addLocal("_", haxeEmptyConstructorSig, VarArgument).load;
		jmEmptyCtor.finalizeArguments();
		jmEmptyCtor.loadThis();
		if (c.clConstructor == null) {
			var handler = new TexprToJvm(gctx, null, jc, jmEmptyCtor, null);
			for (e in fieldInits) handler.texpr(RVoid, e);
		}
		switch c.clSuper {
			case null:
				/* Haxe type with no parent class, call Object.<init>() */
				jmEmptyCtor.callSuperCtor(ConstructInit, methodSig([], null));
			case _:
				/* Parent class exists, call SuperClass.<init>(EmptyConstructor) */
				load();
				jmEmptyCtor.callSuperCtor(ConstructInit, jsigEmpty);
		}
		{
			var handler = new TexprToJvm(gctx, null, jc, jmEmptyCtor, null);
			for (e in delayedFieldInits) handler.texpr(RVoid, e);
		}
		jmEmptyCtor.return_();
	}

	function generateImplicitCtors():Void {
		try {
			var sm = gctx.preprocessor.getImplicitCtor(c);
			for (entry in sm) {
				var c = entry.c, cf = entry.cf;
				var cmode = Genjvm.getConstructionMode(c, cf);
				var jm = jc.spawnMethod(if (cmode == ConstructInit) "<init>" else "new", Genjvm.jsignatureOfType(gctx, cf.cfType), [MPublic]);
				var handler = new TexprToJvm(gctx, null, jc, jm, null);
				jm.loadThis();
				for (e in fieldInits) handler.texpr(RVoid, e);
				var tl = switch TFunctions.follow(cf.cfType) {
					case TFun(s): s.args;
					case _: die("", "generators/genjvm.ml");
				}
				for (a in tl) {
					var load = jm.addLocal(a.name, Genjvm.jsignatureOfType(gctx, a.type), VarArgument).load;
					load();
				}
				jm.finalizeArguments();
				jm.callSuperCtor(cmode, jm.getJsig());
				for (e in delayedFieldInits) handler.texpr(RVoid, e);
				jm.return_();
			}
		} catch (_:NotFound) {}
	}

	public function generateExpr(gctx:GenerationContext, fieldInfo:Null<FieldGenerationInfo>, jc:JvmClassBuilder, jm:JvmMethodBuilder, e:TExpr,
			scmode:SuperCtorMode, mtype:MethodType):Void {
		var args, tr;
		switch e.eexpr {
			case TFunction(tf):
				e = tf.tfExpr;
				args = tf.tfArgs;
				tr = Genjvm.returnOfType(gctx, tf.tfType);
			case _:
				args = [];
				tr = null;
		}
		var handler = new TexprToJvm(gctx, fieldInfo, jc, jm, tr);
		var argPairs = args.map(function(a) {
			var v = a.variable, eo = a.defaultValue;
			var arg = handler.transformArg(v, eo);
			var l = handler.addLocal2(arg.aId, arg.aName, arg.aJsigArg, VarArgument);
			var anns = AnnotationHandler.convertAnnotations(v.vMeta);
			for (ann in anns) jm.addArgumentAnnotation(l.slot, ann.path, ann.annotation, ann.isRuntimeVisible);
			return {arg: arg, l: l};
		});
		jm.finalizeArguments();
		var args = argPairs.map(function(p) return p.arg);
		var actualArgs = argPairs.map(function(p) return p.l);
		handler.handleArgInits(jm, handler, actualArgs, args);
		switch mtype {
			case MConstructor:
				for (e in fieldInits) handler.texpr(RVoid, e);
				switch scmode {
					case SCJava:
						handler.objectConstructor();
					case SCHaxe:
						jm.loadThis();
						jm.getCode().aconstNull(jc.getJsig());
						jm.callSuperCtor(ConstructInit, methodSig([haxeEmptyConstructorSig], null));
					case SCNone:
				}
			case _:
		}
		handler.texpr(RReturn, e);
	}

	public function generateMethod(gctx:GenerationContext, jc:JvmClassBuilder, c:TClass, mtype:MethodType, cf:TClassField):Void {
		var jsig = Genjvm.jsignatureOfType(gctx, cf.cfType);
		var flags = if (core.Meta.has(MetaTag.Private, cf.cfMeta)) [MPrivate] else if (core.Meta.has(MetaTag.Protected, cf.cfMeta)) [MProtected] else [MPublic];
		var flags = if (hasClassFlag(c, CInterface)) [MAbstract].concat(flags) else flags;
		var flags = if (mtype == MethodType.MStatic) [MethodAccessFlags.MStatic].concat(flags) else flags;
		var flags = if (hasClassFieldFlag(cf, CfFinal)) [MFinal].concat(flags) else flags;
		var flags = if (core.Meta.has(MetaTag.JvmSynthetic, cf.cfMeta)) [MSynthetic].concat(flags) else flags;
		var flags = if (core.Meta.has(MetaTag.NativeJni, cf.cfMeta)) [MNative].concat(flags) else flags;
		var flags = if (hasClassFieldFlag(cf, CfAbstract)) [MAbstract].concat(flags) else flags;
		var name, scmode;
		switch mtype {
			case MConstructor:
				function hasSuperCtor(c:TClass):Bool return switch c.clSuper {
					case null: false;
					case sup: sup.cls.clConstructor != null || hasSuperCtor(sup.cls);
				}
				function getScmode():SuperCtorMode return if (c.clSuper == null) SCJava else if (!hasSuperCtor(c)) SCHaxe else SCNone;
				if (Genjvm.getConstructionMode(c, cf) == ConstructInit) {
					name = "<init>";
					scmode = getScmode();
				} else {
					name = cf.cfName;
					scmode = SCNone;
				}
			case _:
				name = cf.cfName;
				scmode = SCNone;
		}
		var jm = jc.spawnMethod(name, jsig, flags);
		switch cf.cfExpr {
			case null:
			case e:
				var fieldInfo = gctx.preprocessor.getFieldInfo(cf.cfMeta);
				generateExpr(gctx, fieldInfo, jc, jm, e, scmode, mtype);
		}
		var ssig = JvmSignature.generateMethodSignature(true, jsig);
		var ssig = switch cf.cfParams {
			case []:
				ssig;
			case _:
				var stl = cf.cfParams.map(function(tp) return '${tp.ttpName}:Ljava/lang/Object;').join("");
				'<$stl>$ssig';
		}
		if (ssig != jm.getDescriptor()) {
			var offset = jc.getPool().addString(ssig);
			jm.addAttribute(AttributeSignature(offset));
		}
		AnnotationHandler.generateAnnotations(jm, cf.cfMeta);
	}

	function addFieldInit(c:TClass, cf:TClassField, e:TExpr):Void {
		var tl = extractParamTypes(c.clParams);
		var ethis = mk(TConst(TThis), TInst(c, tl), nullPos);
		var efield = mk(TField(ethis, FInstance(c, tl, cf)), cf.cfType, nullPos);
		var eop = mk(TBinop(OpAssign, efield, e), cf.cfType, nullPos);
		switch cf.cfKind {
			/* a dynamic method default goes to <init>, where the most derived class assigns last */
			case Method(MethDynamic): delayedFieldInits.push(eop);
			case _: fieldInits.push(eop);
		}
	}

	public function generateField(gctx:GenerationContext, jc:JvmClassBuilder, c:TClass, mtype:MethodType, cf:TClassField):Void {
		var jsig = Genjvm.jsignatureOfType(gctx, cf.cfType);
		var flags = if (core.Meta.has(MetaTag.Private, cf.cfMeta)) [FdPrivate] else if (core.Meta.has(MetaTag.Protected, cf.cfMeta)) [FdProtected] else [FdPublic];
		var flags = if (mtype == MethodType.MStatic) [FdStatic].concat(flags) else flags;
		var flags = if (core.Meta.has(MetaTag.JvmSynthetic, cf.cfMeta)) [FdSynthetic].concat(flags) else flags;
		var flags = if (core.Meta.has(MetaTag.Volatile, cf.cfMeta)) [FdVolatile].concat(flags) else flags;
		var jm = jc.spawnField(cf.cfName, jsig, flags);
		function default_(e:TExpr) {
			var p = nullPos;
			var efield = TexprBuilder.makeStaticField(c, cf, p);
			var eop = mk(TBinop(OpAssign, efield, e), cf.cfType, p);
			TClassTools.addClInit(c, eop);
		}
		switch cf.cfExpr {
			case null:
				if (Genjvm.isPathOf(c.clPath, ["haxe"], "Resource") && cf.cfName == "content") {
					var el = gctx.gctx.resources.fold(function(name, _, acc:Array<TExpr>) {
						acc.unshift(TexprBuilder.makeString(gctx.gctx.basic, name, nullPos));
						return acc;
					}, []);
					var e = mk(TArrayDecl(el), gctx.gctx.basic.tarray(gctx.gctx.basic.tstring), nullPos);
					default_(e);
				}
			case e if (mtype != MethodType.MStatic):
				addFieldInit(c, cf, e);
			case e:
				switch e.eexpr {
					case TConst(ct):
						switch ct {
							case TInt(i32) if (!isNullable(cf.cfType)):
								var offset = jc.getPool().add(ConstInt(i32));
								jm.addAttribute(AttributeConstantValue(offset));
							case TString(s):
								var offset = jc.getPool().addConstString(s);
								jm.addAttribute(AttributeConstantValue(offset));
							case _:
								default_(e);
						}
					case _:
						default_(e);
				}
		}
		var jsig = Genjvm.jsignatureOfType(gctx, cf.cfType);
		/* see https://docs.oracle.com/javase/specs/jvms/se7/html/jvms-4.html#jvms-4.3.4 */
		switch jsig {
			case JObject(_) | JArray(_) | JTypeParameter(_):
				var ssig = JvmSignature.generateSignature(true, jsig);
				var offset = jc.getPool().addString(ssig);
				jm.addAttribute(AttributeSignature(offset));
			case _:
		}
		AnnotationHandler.generateAnnotations(jm, cf.cfMeta);
	}

	public function generateMain(e:TExpr):Void {
		var jsig = methodSig([arraySig(stringSig)], null);
		var jm = jc.spawnMethod("main", jsig, [MPublic, MethodAccessFlags.MStatic]);
		var load = jm.addLocal("args", JArray(stringSig, null), VarArgument).load;
		if (Gctx.hasFeature(gctx.gctx, "haxe.root.Sys.args")) {
			load();
			jm.putstatic({pack: ["haxe", "root"], name: "Sys"}, "_args", JArray(stringSig, null));
		}
		jm.invokestatic({pack: ["haxe", "jvm"], name: "Jvm"}, "init", methodSig([], null));
		generateExpr(gctx, null, jc, jm, e, SCNone, MethodType.MStatic);
		if (!jm.isTerminated()) jm.return_();
	}

	function generateFields():Void {
		function field0(mtype:MethodType, cf:TClassField):Void {
			switch cf.cfKind {
				case Method(MethNormal | MethInline):
					for (cf in [cf].concat(cf.cfOverloads.filter(function(cf) return hasClassFieldFlag(cf, CfOverload)))) {
						var isWeirdAbstractFieldWithoutExpression = switch [cf.cfExpr, c.clKind] {
							case [null, KAbstractImpl(_)]:
								true;
							case _:
								false;
						}
						if (!hasClassFieldFlag(cf, CfExtern) && !(isWeirdAbstractFieldWithoutExpression)) generateMethod(gctx, jc, c, mtype, cf);
					}
				case _:
					/* an overriding dynamic method has no field of its own, only a default value to install */
					if (!hasClassFlag(c, CInterface) && isPhysicalField(cf)) {
						if (Genjvm.dynamicFieldOwner(c, cf) == c) generateField(gctx, jc, c, mtype, cf) else if (cf.cfExpr != null) addFieldInit(c, cf, cf.cfExpr);
					}
			}
		}
		function field(mtype:MethodType, cf:TClassField):Void {
			Genjvm.runTimed(gctx, true, cf.cfName, function() {
				field0(mtype, cf);
				return null;
			});
		}
		switch gctx.entryPoint {
			case null:
			case ep:
				if (ep.cls == c) generateMain(ep.expr);
		}
		for (cf in c.clOrderedStatics) field(MethodType.MStatic, cf);
		for (cf in c.clOrderedFields) field(MInstance, cf);
		switch [c.clConstructor, c.clSuper] {
			case [cf, _] if (cf != null): field(MConstructor, cf);
			case _:
		}
		switch TClassTools.getClInit(c) {
			case null:
			case e:
				var jm = jc.getStaticInitMethod();
				var handler = new TexprToJvm(gctx, null, jc, jm, null);
				handler.texpr(RReturn, mkBlock(e));
		}
	}

	function generateSignature():Void {
		jc.setTypeParameters(c.clParams.map(function(ttp) {
			var jsigs = getConstraints(ttp).map(function(t) return getBoxedType(Genjvm.jsignatureOfType(gctx, t)));
			return {name: ttp.ttpName, jsigs: jsigs};
		}));
		switch c.clSuper {
			case null:
			case sup: jc.setSuperParameters(sup.params.map(function(t) return Genjvm.jtypeArgumentOfType(gctx, [], t)));
		}
	}

	public function generateAnnotations():Void {
		AnnotationHandler.generateAnnotations(jc, c.clMeta);
		jc.addAnnotation({pack: ["haxe", "jvm", "annotation"], name: "ClassReflectionInformation"}, [
			{name: "hasSuperClass", kind: ABool(c.clSuper != null)}
		], true);
	}

	function doGenerate():Void {
		setAccessFlags();
		jc.setSourceFile(c.clPos.pfile);
		Genjvm.runTimed(gctx, true, "fields", function() {
			generateFields();
			return null;
		});
		setInterfaces();
		if (!hasClassFlag(c, CInterface)) {
			generateEmptyCtor();
			generateImplicitCtors();
			buildBridges();
		}
		generateSignature();
		if (gctx.dynamicLevel > 0 && !core.Meta.has(MetaTag.NativeGen, c.clMeta) && !hasClassFlag(c, CInterface))
			Genjvm.generateDynamicAccess(gctx, jc, c.clOrderedFields.filter(function(cf) return Genjvm.dynamicFieldOwner(c, cf) == c).map(function(cf) return {
				name: cf.cfName,
				jsig: Genjvm.jsignatureOfType(gctx, cf.cfType),
				kind: cf.cfKind
			}), false);
		generateAnnotations();
		var jc = jc.exportClass(gctx.defaultExportConfig);
		Genjvm.writeClass(gctx, c.clPath, jc);
	}

	public function generate():Void {
		Genjvm.runTimed(gctx, true, sTypePath(c.clPath), function() {
			doGenerate();
			return null;
		});
	}
}

class JvmPreprocessor {
	public static function makeRoot(path:GlobalTypePath):GlobalTypePath return {pack: ["haxe", "root"], name: path.name};

	public static function hasPrimaryType(m:ModuleDef):Bool {
		return Lambda.exists(m.mTypes, function(mt) return tInfos(mt).mtPath.name == m.mPath.name);
	}

	// port: `mt.mt_path <- path` on the infos shared by the module type.
	static function setPath(mt:ModuleType, path:GlobalTypePath):Void {
		switch mt {
			case TClassDecl(c): c.clPath = path;
			case TEnumDecl(e): e.ePath = path;
			case TTypeDecl(t): t.tPath = path;
			case TAbstractDecl(a): a.aPath = path;
		}
	}

	public static function checkPath(mt0:ModuleType):Void {
		var mt = tInfos(mt0);
		if (mt.mtPrivate && hasPrimaryType(mt.mtModule) && !core.Meta.has(MetaTag.Native, mt.mtMeta)) {
			var m = mt.mtModule;
			var pack = switch m.mPath.pack {
				case []: ["haxe", "root"];
				case pack: pack;
			}
			setPath(mt0, {pack: pack, name: '${m.mPath.name}$$${mt.mtPath.name}'});
		} else if (mt.mtPath.pack.length == 0)
			setPath(mt0, makeRoot(mt.mtPath));
	}

	public static function checkFunctionalInterface(gctx:GenerationContext, c:TClass):Void {
		switch TClassTools.getSingularInterfaceField(c.clOrderedFields) {
			case null:
			case cf:
				switch Genjvm.jsignatureOfType(gctx, cf.cfType) {
					case JMethod(args, ret):
						var jfi = JavaFunctionalInterface.create(args, ret, c.clPath, cf.cfName, c.clParams.concat(cf.cfParams).map(extractParamName));
						gctx.functionalInterfaces = [{c: c, cf: cf, jfi: jfi}].concat(gctx.functionalInterfaces);
					case _:
				}
		}
	}

	/* Collect the functional interfaces actually referenced by user code, so
		 closures only implement SAMs the program demands. Without this filter a
		 closure would bind to every structurally-matching interface on the
		 --java-lib classpath — including incidental ones from a higher API level
		 than the runtime, which hard-fails class linking. An interface counts as
		 used iff some non-extern type, field signature, or sub-expression names
		 it; scanning non-extern code only keeps classpath noise out. */
	public static function collectUsedFunctionalInterfaces(gctx:GenerationContext):haxe.ds.StringMap<Bool> {
		var used = new haxe.ds.StringMap<Bool>();
		/* `seen` guards against recursive types (e.g. a recursive abstract whose
			 underlying references itself through several fields): without it the walk
			 branches exponentially and the compiler hangs. depth is a coarse backstop. */
		// port: seen as a cons list (SeenTypes), as in OCaml: copying an
		// array on each step and searching it through Lambda.exists made this walk
		// the larger part of the JVM preprocessing.
		function seenExists(t:T, l:Null<SeenTypes>):Bool {
			while (l != null) {
				if (TUnification.fastEq(t, l.t)) return true;
				l = l.next;
			}
			return false;
		}
		function noteFiInType(seen:Null<SeenTypes>, depth:Int, t:T):Void {
			if (depth < 32 && !seenExists(t, seen)) {
				var seen = new SeenTypes(t, seen);
				switch TFunctions.follow(t) {
					case TInst(c, tl):
						if (hasClassFlag(c, CFunctionalInterface)) used.set(Genjvm.pathKey(c.clPath), true);
						for (t in tl) noteFiInType(seen, depth + 1, t);
					case TFun(s):
						for (a in s.args) noteFiInType(seen, depth + 1, a.type);
						noteFiInType(seen, depth + 1, s.ret);
					case TAbstract(_, tl) | TEnum(_, tl) | TType(_, tl):
						for (t in tl) noteFiInType(seen, depth + 1, t);
					case TAnon(an):
						for (cf in an.aFields) noteFiInType(seen, depth + 1, cf.cfType);
					case TDynamic(t) if (t != null):
						noteFiInType(seen, depth + 1, t);
					case _:
				}
			}
		}
		function noteFiInExpr(e:TExpr):Void {
			noteFiInType(null, 0, e.etype);
			Texpr.iter(noteFiInExpr, e);
		}
		function scanClass(c:TClass):Void {
			if (!hasClassFlag(c, CExtern)) {
				function scan(cf:TClassField):Void {
					noteFiInType(null, 0, cf.cfType);
					if (cf.cfExpr != null) noteFiInExpr(cf.cfExpr);
					for (cf in cf.cfOverloads) scan(cf);
				}
				for (cf in c.clOrderedFields) scan(cf);
				for (cf in c.clOrderedStatics) scan(cf);
				if (c.clConstructor != null) scan(c.clConstructor);
			}
		}
		/* go through com.modules so we can also pick up private typedefs */
		for (m in gctx.gctx.modules) {
			for (mt in m.mTypes) switch mt {
				case TClassDecl(c): scanClass(c);
				case _:
			}
		}
		return used;
	}

	public static function preprocess(gctx:GenerationContext):Void {
		function hasRuntimeMeta(l:Metadata):Bool {
			for (m in l) switch (m.meta : MetaTag) {
				case Custom(s) if (s.length > 0 && s.charAt(0) != ":"):
					return true;
				case _:
			}
			return false;
		}
		for (m in gctx.gctx.modules) {
			for (mt in m.mTypes) {
				switch mt {
					case TClassDecl(c) if (hasRuntimeMeta(c.clMeta) && hasClassFlag(c, CInterface)):
						/* TODO: run-time interface metadata is a problem (issue #2042) */
					case TClassDecl(_):
						checkPath(mt);
					case TEnumDecl(en):
						checkPath(mt);
						gctx.enumPaths.set(Genjvm.pathKey(en.ePath), true);
					case TTypeDecl(td):
						checkPath(mt);
						gctx.anonIdentification.identifyTypedef(td);
					case _:
				}
			}
		}
		/* After check_path: cl_paths are stable, so we can key the used-SAM
			 set by cl_path without worrying about private-type rewrites. */
		var fiUsed = collectUsedFunctionalInterfaces(gctx);
		/* preprocess classes */
		function patchOptional(c:TClass) {
			function apply(cf:TClassField) {
				Genshared.patchOptional(gctx.gctx.basic, cf);
			}
			for (cf in c.clOrderedFields) apply(cf);
			for (cf in c.clOrderedStatics) apply(cf);
			if (c.clConstructor != null) apply(c.clConstructor);
		}
		for (mt in gctx.gctx.types) switch mt {
			case TClassDecl(c):
				if (!hasClassFlag(c, CInterface))
					gctx.preprocessor.preprocessClass(c)
				else {
					patchOptional(c);
					if (fiUsed.exists(Genjvm.pathKey(c.clPath))) checkFunctionalInterface(gctx, c);
				}
			case _:
		}
		/* find typedef-interface implementations */
		for (mt in gctx.gctx.types) switch mt {
			case TClassDecl(c) if (!hasClassFlag(c, CInterface) && !hasClassFlag(c, CExtern)):
				gctx.typedefInterfaces.processClass(c);
			case _:
		}
	}
}

// port: an immutable cons cell of types (the seen list of collectUsedFunctionalInterfaces)
private class SeenTypes {
	public final t:T;
	public final next:Null<SeenTypes>;

	public function new(t:T, next:Null<SeenTypes>) {
		this.t = t;
		this.next = next;
	}
}
