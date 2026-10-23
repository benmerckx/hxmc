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

import core.Globals;
import core.Globals.Pos;
import core.Globals.GlobalTypePath;
import core.Ast;
import core.Ast.*;
import core.TType;
import core.TFunctions.*;
import core.TUnification;
import core.TUnification.Unify_error;
import core.Error;
import core.Error.CompilerError;
import core.Error.TypingError;
import core.Error.FatalError;
import core.Define;
import core.Meta.Meta as MetaTools;
import core.Ast.Ast as AstTools;
import core.MetaList.StrictMeta as MetaTag;
import core.Timer;
import core.WithType as WithTypeTools;
import core.ds.NotFound;
import core.ds.Exit;
import context.Common;
import context.Common.CommonContext;
import context.Common.CompilerStage;
import context.Typecore;
import context.Typecore.Typer as TyperContext;
import context.Typecore.TyperManager;
import context.Typecore.MacroMode;
import context.Typecore.MacroResult;
import context.Typecore.WithTypeError;
import context.TyperPass;
import syntax.Parser.Parser;
import syntax.Parser.ParseResult;
import syntax.ParserEntry;
import syntax.ParserConfig;
import typing.Typeload.LoadInstanceParamMode;
import typing.Typeload.LoadInstanceMode;
import macros.MacroApi.CompilerApi;
import macros.MacroApi.MacroApiImpl;
import macros.MacroApi.InvalidExpr;
import macros.eval.EvalValue.Value;
import macros.eval.EvalContext.RunTimeException;
import core.ds.VectorTools;
import core.ds.VectorTools.vector;
import haxe.ds.Vector;

using core.ds.VectorTools;

// port: upstream's `Interp` module is `include InterpImpl (= Eval, (* Hlmacro *)) include BuiltApi (MacroApiImpl)`;
// here `Interp.f` is the Eval module that defines `f` upstream (EvalContext, EvalMain,
// EvalEncode, EvalDecode, EvalPrinting) or `macros.MacroApi.MacroApiImpl` for functions
// defined in macroApi.ml.
// `HxbWriterConfigReaderEval`/`HxbWriterConfigWriterEval` are HxbWriterConfig's reader/writer
// applied to EvalDataApi's readers/writers.
// port: the macro context's engine calls (create, init, addTypes, callPath, doReuse,
// setError) go through macros.MacroEngine.engine, Eval unless a host installs another.
typedef MacroMethod = {args:haxe.ds.Vector<{name:String, optional:Bool, type:T}>, ret:T, cls:TClass, field:TClassField};

typedef LoadedMacro = {meth:MacroMethod, module:ModuleDef};

enum MacroArgType {
	MAExpr;
	MAFunction;
	MAOther;
}

class MacroContext {
	// port: hook (not upstream): whether a type's module was processed in an
	// earlier compilation and comes back so (the tool's module cache restores
	// the macros' modules as processed): its constructors are not patched
	// again (SaveStacks.patchConstructors adds a call each time)
	public static var processedTypeHook:Null<ModuleType->Bool> = null;

	public static var macroInterpCache:Null<macros.eval.EvalContext.Context> = null;

	// port: hook (not upstream): the macro context's platform when its code is not
	// Eval's (hxmc's -D hxmc.mir-macros): called instead of adding Eval's _std and
	// setting the platform to Eval, once the macro context's defines are adapted
	public static var macroPlatformHook:Null<CommonContext->Void> = null;

	// port: ExtString.String.nsplit; an empty string has no parts.
	static function nsplit(s:String, sep:String):Array<String>
		return s == "" ? [] : s.split(sep);

	// port: through MacroApiImpl (its values: Eval's, or the compiler's own, nativeValues)
	static function isVNull(v:Value):Bool
		return MacroApiImpl.isNull(v);

	public static function safeDecode<A>(com:CommonContext, v:Value, expected:String, t:T, p:Pos, f:Void->A):A {
		inline function raiseDecodeError(s:String):Dynamic {
			var path = [com.partScope.dumpConfig.dumpPath, "decoding_error"];
			var ch = core.Path.createFile(false, ".txt", [], path.copy());
			ch.writeString(core.TPrinting.Printer.sPos(p) + ": " + s + "\n");
			// port: the native values have no line-by-line account (MacroApiImpl.nativeValues)
			var errors = MacroApiImpl.nativeValues ? [] : macros.eval.EvalMain.handleDecodingError(function(s:String) ch.writeString(s), v, t);
			var errors = errors.copy();
			errors.reverse();
			for (e in errors)
				ch.writeString("\nline " + e.line + ": " + e.msg);
			ch.close();
			return Error.raiseTypingError(s + " (see " + path.join("/") + ".txt for details)", p);
		}

		try {
			return f();
		} catch (e:RunTimeException) {
			switch e.value {
				case VString(emsg):
					return raiseDecodeError("Eval runtime exception: " + emsg.sstring);
				case _:
					throw e;
			}
		} catch (e:InvalidExpr) {
			return raiseDecodeError("Expected " + expected + " but got " + MacroApiImpl.valueString(v));
		} catch (e:String) {
			// port: the native values' runtime exception (MacroApiImpl.excString)
			if (!MacroApiImpl.nativeValues) throw e;
			return raiseDecodeError("Eval runtime exception: " + e);
		}
	}

	public static function macroTimer<A, R>(timerCtx:core.Timer.TimerContext, level:Int, s:Array<String>, identifier:Null<String>, f:A->R,
			arg:A):R {
		var id = Timer.determineId(level, ["macro"], s, identifier);
		return Timer.time(timerCtx, id, f, arg);
	}

	public static function typingTimer<A>(ctx:TyperContext, needType:Bool, f:TyperContext->A):A {
		var t = Timer.startTimer(ctx.com.timerCtx, ["typing"]);
		var ctx = if (needType && Typecore.passIndex(ctx.pass) < Typecore.passIndex(PTypeField)) {
			Typecore.enterFieldTypingPass(ctx.g, {name: "typing_timer", args: []});
			TyperManager.cloneForExpr(ctx, ctx.e.curfun, FunFunction);
		} else ctx;

		var old = ctx.com.errorExt;
		var restoreReportMode = Common.disableReportMode(ctx.com);
		var restoreFieldState = TypeloadFunction.saveFieldState(ctx);
		ctx.com.errorExt = function(err) Error.raiseError(err);

		inline function exit() {
			t();
			ctx.com.errorExt = old;
			restoreFieldState();
			restoreReportMode();
		}
		try {
			var r = f(ctx);
			exit();
			return r;
		} catch (err:TypingError) {
			exit();
			return MacroApiImpl.compilerError(err.error);
		} catch (err:WithTypeError) {
			exit();
			return MacroApiImpl.compilerError(err.error);
		} catch (e:Dynamic) {
			exit();
			throw e;
		}
	}

	static function parseErrorCallback<A>(msg:String, p:Pos):ParseResult<A>
		return Error.raiseTypingError(msg, p);

	public static function makeMacroComApi(com:CommonContext, mcom:CommonContext, p:Pos):CompilerApi {
		var timerLevel = Timer.levelFromDefine(com.defines, Define.MacroTimes);
		inline function parseMetadata(s:String, p:Pos):Metadata {
			try {
				return switch ParserEntry.parseString(ParserConfig.defaultConfig(com.defines), @:privateAccess syntax.Grammar.parseMeta, s,
					Globals.nullPos, parseErrorCallback, false) {
					case ParseSuccess(meta, _): meta;
					case ParseError(_, _, _): Error.raiseTypingError("Malformed metadata string", p);
				}
			} catch (_:Dynamic) {
				return Error.raiseTypingError("Malformed metadata string", p);
			}
		}
		inline function badStage():Dynamic {
			if (Type.enumIndex(com.stage) < Type.enumIndex(CInitMacrosDone))
				return MacroApiImpl.excString("This API cannot be used in initialization macros");
			else
				return MacroApiImpl.excString("This API cannot be used in the interpreter run-time");
		}
		return {
			pos: p,
			getCom: () -> com,
			getMacroCom: () -> mcom,
			getMacroStack: function() {
				// port: the native values' engine keeps no positions of its frames
				if (MacroApiImpl.nativeValues) Error.raiseTypingError("Context.getMacroStack is not available with -D hxmc.mir-macros", p);
				// port: -D hih_no_eval (not upstream): no Eval frames
				#if hih_no_eval
				return [];
				#else
				var envs = macros.eval.EvalContext.callStack(macros.eval.EvalContext.getEval(macros.eval.EvalContext.getCtx()));
				var envs = envs.length > 0 ? envs.slice(1) : envs; // Skip call to getMacroStack()
				return envs.map(function(env:macros.eval.EvalContext.Env):Pos return
					{pfile: macros.eval.EvalHash.revHash(env.envInfo.pfile), pmin: env.envLeavePmin, pmax: env.envLeavePmax});
				#end
			},
			initMacrosDone: () -> Type.enumIndex(com.stage) >= Type.enumIndex(CInitMacrosDone),
			getType: function(s) return badStage(),
			resolveType: function(t, p) return badStage(),
			resolveComplexType: function(t) return badStage(),
			getModule: function(s) return badStage(),
			includeModule: function(s) badStage(),
			afterInitMacros: function(f) {
				com.callbacks.addAfterInitMacros(function() {
					macroTimer(com.timerCtx, timerLevel, ["afterInitMacros"], null, function(_:Null<Bool>) {
						f();
						return null;
					}, null);
				});
			},
			afterTyping: function(f) {
				com.callbacks.addAfterTyping(function(tl) {
					macroTimer(com.timerCtx, timerLevel, ["afterTyping"], null, function(tl) {
						f(tl);
						return null;
					}, tl);
				});
			},
			onGenerate: function(f, b) {
				(b ? com.callbacks.addBeforeSave : com.callbacks.addAfterSave)(function() {
					macroTimer(com.timerCtx, timerLevel, ["onGenerate"], null, function(tl) {
						f(tl);
						return null;
					}, com.types.map(typeOfModuleType));
				});
			},
			afterGenerate: function(f) {
				com.callbacks.addAfterGeneration(function() {
					macroTimer(com.timerCtx, timerLevel, ["afterGenerate"], null, function(_:Null<Bool>) {
						f();
						return null;
					}, null);
				});
			},
			onTypeNotFound: function(f) {
				com.loadExternType = com.loadExternType.concat([
					{
						name: "onTypeNotFound",
						load: function(path:GlobalTypePath, p:Pos):Null<Package> {
							var td = f(Globals.sTypePath(path));
							if (isVNull(td))
								return null;
							else {
								var d = MacroApiImpl.decodeTypeDef(td);
								return {pack: d.path.pack, declarations: vector({definition: d.def, pos: d.pos})};
							}
						}
					}
				]);
			},
			parseString: function(s, p, inl) {
				var old = com.errorExt;
				com.errorExt = function(err) Error.raiseError(err);
				inline function exit() com.errorExt = old;

				try {
					var r = switch ParserEntry.parseExprString(ParserConfig.fileParserConfig(com, p.pfile), s, p, parseErrorCallback, inl) {
						case ParseSuccess(data,
							{pdWasDisplayFile: true}) if (inl): data; // ignore errors when inline-parsing in display file
						case ParseSuccess(data, _): data;
						case ParseError(_): MacroApiImpl.excString("Invalid expression");
					};
					exit();
					return r;
				} catch (err:TypingError) {
					exit();
					return MacroApiImpl.compilerError(err.error);
				} catch (err:WithTypeError) {
					exit();
					return MacroApiImpl.compilerError(err.error);
				} catch (e:Dynamic) {
					exit();
					throw e;
				}
			},
			parse: function(entry, s) {
				return switch ParserEntry.parseString(ParserConfig.defaultConfig(com.defines), entry, s, Globals.nullPos,
					parseErrorCallback, false) {
					case ParseSuccess(r, _): r;
					case ParseError(_, info, _): Parser.error(info.message, info.pos);
				};
			},
			registerFileContents: function(file, content) {
				var f = syntax.Lexer.resolveFileContentPos(file, content);
				@:privateAccess syntax.Lexer.allFiles.set(file, f);
			},
			typeExpr: function(e) return badStage(),
			storeTypedExpr: function(te) {
				var p = te.epos;
				return Typecore.storeTypedExpr(com, te, p).expr;
			},
			allowPackage: function(v) Common.allowPackage(com, v),
			getLocalType: function() return badStage(),
			getExpectedType: function() return badStage(),
			getCallArguments: function() return badStage(),
			getLocalMethod: function() return badStage(),
			getLocalUsing: function() return badStage(),
			getLocalImports: function() return badStage(),
			getLocalVars: function() return badStage(),
			getBuildFields: function() return badStage(),
			defineType: function(v, mdep) badStage(),
			defineModule: function(m, types, imports, usings) badStage(),
			moduleDependency: function(mpath, file) badStage(),
			currentModule: function() return nullModule,
			formatString: function(s, p) {
				return context.FormatString.formatString(ParserConfig.fileParserConfig(com, p.pfile), s, p,
					function(e:ExprDef, p:Pos):Expr return {
						expr: e,
						pos: p
					});
			},
			castOrUnify: function(t, e, p) return badStage(),
			addGlobalMetadata: function(s1, s2, config, p) {
				var meta = parseMetadata(s2, p);
				for (entry in meta) {
					var m:MetadataEntry = {meta: entry.meta, exprs: entry.exprs, pos: p};
					com.globalMetadata.unshift({
						path: nsplit(s1, "."),
						meta: m,
						recursive: config.a,
						toTypes: config.b,
						toFields: config.c
					});
				}
			},
			addModuleCheckPolicy: function(sl, il, b) badStage(),
			registerDefine: function(s, data) Define.registerUserDefine(com.userDefines, s, data),
			registerMetadata: function(s, data) MetaTools.registerUserMeta(com.userMetas, s, data),
			decodeExpr: MacroApiImpl.decodeExpr,
			encodeExpr: MacroApiImpl.encodeExpr,
			encodeCtype: MacroApiImpl.encodeCtype,
			decodeType: MacroApiImpl.decodeType,
			displayError: function(msg, p, sub) Common.displayError(com, msg, p, sub),
			withImports: function(imports, usings, f) return badStage(),
			withOptions: function(opts, f) return badStage(),
			info: function(msg, p, depth) com.info(msg, p, depth),
			warning: function(w, msg, p, depth) com.warning(w, [], msg, p, depth),
			excString: MacroApiImpl.excString,
			getHxbWriterConfig: function() {
				return switch com.hxbWriterConfig {
					case null:
						MacroApiImpl.vnull;
					case config:
						#if hih_no_eval
						Error.raiseTypingError("Context.getHxbWriterConfig needs Eval (-D hih_no_eval)", p);
						#else
						compiler.hxb.HxbWriterConfig.writeWriterConfig(macros.eval.EvalDataApi.EvalWriterApi.api(), config);
						#end
				}
			},
			setHxbWriterConfig: function(v) {
				if (isVNull(v))
					com.hxbWriterConfig = null;
				else {
					var config = switch com.hxbWriterConfig {
						case null:
							var config = new compiler.hxb.HxbWriterConfig();
							com.hxbWriterConfig = config;
							config;
						case config:
							config;
					}
					#if hih_no_eval
					Error.raiseTypingError("Context.setHxbWriterConfig needs Eval (-D hih_no_eval)", p);
					#else
					compiler.hxb.HxbWriterConfig.readWriterConfig(macros.eval.EvalDataApi.EvalReaderApi.api(), config, v);
					#end
				}
			}
		};
	}

	static function previouslyDefinedError(m:ModuleDef, mpath:GlobalTypePath, p:Pos):Dynamic {
		var pos:Pos = {pfile: core.Path.UniqueKey.lazyPath(m.mExtra.mFile), pmin: 0, pmax: 0};
		return MacroApiImpl.compilerError(Error.makeError(Custom("Cannot redefine module " + Globals.sTypePath(mpath)), p,
			[Error.makeError(Custom("Previously defined here"), pos)]));
	}

	public static function makeMacroApi(ctx:TyperContext, mctx:TyperContext, p:Pos):CompilerApi {
		inline function parseMetadata(s:String, p:Pos):Metadata {
			try {
				return switch ParserEntry.parseString(ParserConfig.defaultConfig(mctx.com.defines),
					@:privateAccess syntax.Grammar.parseMeta, s,
					Globals.nullPos, parseErrorCallback, false) {
					case ParseSuccess(meta, _): meta;
					case ParseError(_, _, _): Error.raiseTypingError("Malformed metadata string", p);
				}
			} catch (_:Dynamic) {
				return Error.raiseTypingError("Malformed metadata string", p);
			}
		}
		var comApi = makeMacroComApi(ctx.com, mctx.com, p);
		inline function mkTypePath(path:GlobalTypePath, ?sub:String):TypePath {
			try
				return AstTools.mkTypePath(path.pack, path.name, null, sub)
			catch (e:core.ds.InvalidArgument)
				return comApi.excString(e.message);
		}
		var api = macros.MacroApi.CompilerApiTools.clone(comApi);
		api.getType = function(s) {
			return typingTimer(ctx, false, function(ctx) {
				var path = AstTools.parsePath(s);
				var rpack = path.pack.copy();
				rpack.reverse();
				var tp = if (rpack.length > 0 && rpack[0].length > 0 && rpack[0].charCodeAt(0) >= 'A'.code
					&& rpack[0].charCodeAt(0) <= 'Z'.code) {
					var sl = rpack.slice(1);
					sl.reverse();
					mkTypePath({pack: sl, name: rpack[0]}, path.name);
				} else mkTypePath(path);
				try {
					var m:Null<T> = Typeload.loadInstance(ctx, makePtp(tp, p), ParamSpawnMonos, LoadAny);
					return m;
				} catch (e:TypingError) {
					switch e.error.errMessage {
						case ModuleNotFound(_) if (e.error.errPos == p):
							return null;
						case _:
							throw e;
					}
				}
			});
		};
		api.resolveType = function(t, p) {
			return typingTimer(ctx, false, function(ctx) return Typeload.loadComplexType(ctx, false, LoadAny, {type: t, pos: p}));
		};
		api.resolveComplexType = function(t) {
			return typingTimer(ctx, false, function(ctx) {
				var load:TypeHint->TypeHint = null;
				var loadCf:ClassField->ClassField = null;
				var loadTparam:TypeParam->TypeParam = null;
				var loadPath:PlacedTypePath->PlacedTypePath = null;
				inline function loadOpt(t:Null<TypeHint>):Null<TypeHint> return t == null ? null : load(t);
				load = function(th:TypeHint):TypeHint {
					var ct = switch th.type {
						case CTPath(ptp):
							CTPath(loadPath(ptp));
						case CTFunction(args, ret):
							CTFunction(args.map(load), load(ret));
						case CTAnonymous(fl):
							CTAnonymous(fl.map(loadCf));
						case CTParent(t):
							CTParent(load(t));
						case CTExtend(pl, fl):
							CTExtend(pl.map(function(ptp) return loadPath(ptp)), fl.map(loadCf));
						case CTOptional(t):
							CTOptional(t);
						case CTNamed(n, t):
							CTNamed(n, load(t));
						case CTIntersection(tl):
							CTIntersection(tl.map(load));
					};
					return {type: ct, pos: p};
				};
				loadCf = function(f:ClassField):ClassField {
					var k = switch f.cffKind {
						case FVar(t, e): FVar(loadOpt(t), e);
						case FProp(n1, n2, t, e): FProp(n1, n2, loadOpt(t), e);
						case FFun(f):
							FFun({
								fParams: f.fParams.map(loadTparam),
								fArgs: f.fArgs.map(function(a:FuncArg):FuncArg return {
									name: a.name,
									optional: a.optional,
									meta: a.meta,
									type: loadOpt(a.type),
									expr: a.expr
								}),
								fType: loadOpt(f.fType),
								fExpr: f.fExpr
							});
					};
					var f = f.clone();
					f.cffKind = k;
					return f;
				};
				loadTparam = function(ft:TypeParam):TypeParam {
					var ft2 = ft.clone();
					ft2.tpParams = ft.tpParams.map(loadTparam);
					ft2.tpConstraints = loadOpt(ft.tpConstraints);
					ft2.tpDefault = loadOpt(ft.tpDefault);
					return ft2;
				};
				loadPath = function(ptp:PlacedTypePath):PlacedTypePath {
					var t = tInfos(Typeload.loadTypeDef(ctx, ptp.posPath, ptp.path));
					var isSub = !Common.samePath(t.mtModule.mPath, t.mtPath);
					return makePtp({
						tpackage: t.mtPath.pack,
						tname: isSub ? t.mtModule.mPath.name : t.mtPath.name,
						tparams: ptp.path.tparams.map(function(ct) return switch ct {
							case TPType(t): TPType(load(t));
							case TPExpr(_): ct;
						}),
						tsub: isSub ? t.mtPath.name : null
					}, ptp.posFull);
				};
				return load(t);
			});
		};
		api.getModule = function(s) {
			return typingTimer(ctx, false, function(ctx) {
				var path = AstTools.parsePath(s);
				var m = TypeloadModule.loadModule(ctx, path, p, MDepFromMacro).mTypes.map(typeOfModuleType);
				return m;
			});
		};
		api.includeModule = function(s) {
			typingTimer(ctx, false, function(ctx) {
				var path = AstTools.parsePath(s);
				TypeloadModule.loadModule(ctx, path, p, MDepFromMacroInclude);
				return null;
			});
		};
		api.typeExpr = function(e) {
			return typingTimer(ctx, true, function(ctx) return Typecore.typeExpr(ctx, e, WithTypeTools.value));
		};
		api.getLocalType = function() {
			var infos = ctx.c.getBuildInfos();
			if (infos != null) {
				var tl = infos.params;
				return switch infos.type {
					case TClassDecl(c): TInst(c, tl);
					case TEnumDecl(e): TEnum(e, tl);
					case TTypeDecl(t): TType(t, tl);
					case TAbstractDecl(a): TAbstract(a, tl);
				};
			} else {
				if (ctx.c.curclass == nullClass)
					return null;
				else
					return TInst(ctx.c.curclass, vector());
			}
		};
		api.getExpectedType = function() {
			return if (ctx.e.withTypeStack.length > 0) switch (ctx.e.withTypeStack[0] : core.WithType.WithTypeValue) {
				case WithType(t, _): t;
				case _: null;
			} else null;
		};
		api.getCallArguments = function() {
			return ctx.e.callArgumentStack.length == 0 ? null : ctx.e.callArgumentStack[0];
		};
		api.getLocalMethod = function() {
			return ctx.f.curfield.cfName;
		};
		api.getLocalUsing = function() {
			return ctx.m.moduleUsing.map(function(u) return u.cls);
		};
		api.getLocalImports = function() {
			return ctx.m.importStatements;
		};
		api.getLocalVars = function() {
			var out = new haxe.ds.StringMap<TVar>();
			ctx.f.locals.iter(function(k, v) out.set(k, v));
			return out;
		};
		api.getBuildFields = function() {
			var infos = ctx.c.getBuildInfos();
			return infos == null ? MacroApiImpl.vnull : MacroApiImpl.encodeArray(infos.fields.map(MacroApiImpl.encodeField));
		};
		api.defineType = function(v, mdep) {
			var cttype = mkTypePath({pack: ["haxe", "macro"], name: "Expr"}, "TypeDefinition");
			var mctx = ctx.g.macros == null ? Globals.die("", "typing/MacroContext.hx") : ctx.g.macros.typer;
			var ttype = Typeload.loadInstance(mctx, makePtp(cttype, p), ParamNormal, LoadNormal);
			function f() return MacroApiImpl.decodeTypeDef(v);
			var decoded = safeDecode(ctx.com, v, "TypeDefinition", ttype, p, f);
			var mpath = decoded.path, tdef = decoded.def, pos = decoded.pos;
			var hasNativeMeta = switch tdef {
				case EClass(d): MetaTools.has(MetaTag.Native, d.meta);
				case EEnum(d): MetaTools.has(MetaTag.Native, d.meta);
				case ETypedef(d): MetaTools.has(MetaTag.Native, d.meta);
				case EAbstract(d): MetaTools.has(MetaTag.Native, d.meta);
				case _: false;
			};
			function add(isMacro:Bool, ctx:TyperContext) {
				try {
					var m = ctx.com.moduleLut.find(mpath);
					previouslyDefinedError(m, mpath, p);
				} catch (_:NotFound) {
					ctx.com.cs.taintModule(mpath, DefineType);
					var mdep = mdep == null ? ctx.m.curmod : TypeloadModule.loadModule(ctx, AstTools.parsePath(mdep), pos, MDepFromMacro);
					var mnew = TypeloadModule.typeModule(ctx.com, ctx.g, mpath,
						ctx.com.partScope.fileKeys.generateVirtual(mpath, ctx.com.partScope.compilationStep), vector(
						{
							definition: tdef,
							pos: pos
						}
					), pos, hasNativeMeta);
					mnew.mExtra.mKind = isMacro ? MMacro : MFake;
					addDependency(mnew, mdep, MDepFromMacro);
					addDependency(mdep, mnew, MDepFromMacroDefine);
					ctx.com.moduleNonexistentLut.clear();
				}
			}
			add(false, ctx);
			// if we are adding a class which has a macro field, we also have to add it to the macro context (issue #1497)
			if (!ctx.com.isMacroContext)
				switch tdef {
					case EClass(c)
						if (VectorTools.exists(c.data,
							function(cff) return Lambda.exists(cff.cffAccess, function(a) return a.access == AMacro))):
						add(true, mctx);
					case _:
				}
		};
		api.defineModule = function(m, types, imports, usings) {
			var types:Array<TypeDecl> = types.map(function(v):TypeDecl {
				var d = try MacroApiImpl.decodeTypeDef(v) catch (_:InvalidExpr)
					MacroApiImpl.excString("Invalid type definition");
				return {definition: d.def, pos: d.pos};
			});
			var pos = types.length == 0 ? Globals.nullPos : types[0].pos;
			var imports:Array<TypeDecl> = imports.map(function(i):TypeDecl return {
				definition: EImport({path: i.path, mode: i.mode}),
				pos: pos
			});
			var usings:Array<TypeDecl> = usings.map(function(tp):TypeDecl {
				var sl = tp.tpackage.concat([tp.tname]).concat(tp.tsub == null ? [] : [tp.tsub]);
				return {definition: EUsing(sl.mapToVector(function(s):PlacedName return {name: s, pos: Globals.nullPos})), pos: pos};
			});
			var types = Vector.fromArrayCopy(imports.concat(usings).concat(types));
			var mpath = AstTools.parsePath(m);
			try {
				var m = ctx.com.moduleLut.find(mpath);
				if (m != ctx.m.curmod) {
					previouslyDefinedError(m, mpath, p);
				} else
					TypeloadModule.typeTypesIntoModule(ctx.com, ctx.g, ctx.m.curmod, types, pos);
			} catch (_:NotFound) {
				ctx.com.cs.taintModule(mpath, DefineModule);
				var mnew = TypeloadModule.typeModule(ctx.com, ctx.g, mpath,
					ctx.com.partScope.fileKeys.generateVirtual(mpath, ctx.com.partScope.compilationStep), types, pos);
				mnew.mExtra.mKind = MFake;
				addDependency(mnew, ctx.m.curmod, MDepFromMacro);
				addDependency(ctx.m.curmod, mnew, MDepFromMacroDefine);
				ctx.com.moduleNonexistentLut.clear();
			}
		};
		api.moduleDependency = function(mpath, file) {
			var m = typingTimer(ctx, false, function(ctx) {
				var oldDeps = ctx.m.curmod.mExtra.mDeps.copy(); // port: m_deps is a persistent map upstream
				var m = TypeloadModule.loadModule(ctx, AstTools.parsePath(mpath), p, MDepFromMacro);
				ctx.m.curmod.mExtra.mDeps = oldDeps;
				return m;
			});
			addDependency(m, TypeloadCacheHook.createFakeModule(ctx.com, file), MDepFromMacro);
		};
		api.currentModule = function() {
			return ctx.m.curmod;
		};
		api.castOrUnify = function(t, e, p) {
			return typingTimer(ctx, true, function(ctx) {
				try {
					context.AbstractCast.castOrUnifyRaise(ctx, t, e, p);
					return true;
				} catch (err:TypingError) {
					switch err.error.errMessage {
						case Unify(_):
							return false;
						case _:
							throw err;
					}
				}
			});
		};
		api.addGlobalMetadata = function(s1, s2, config, p) {
			var meta = parseMetadata(s2, p);
			for (entry in meta) {
				var m:MetadataEntry = {meta: entry.meta, exprs: entry.exprs, pos: p};
				ctx.com.globalMetadata.unshift({
					path: nsplit(s1, "."),
					meta: m,
					recursive: config.a,
					toTypes: config.b,
					toFields: config.c
				});
			}
		};
		api.addModuleCheckPolicy = function(sl, il, b) {
			function add(ctx:TyperContext) {
				for (s in sl)
					ctx.g.moduleCheckPolicies.unshift({
						pack: nsplit(s, "."),
						policies: il.map(function(i) return Type.createEnumIndex(ModuleCheckPolicy, i)),
						recursive: b
					});
				ctx.com.moduleLut.iter(function(_, m) m.mExtra.mCheckPolicy = TypeloadModule.getPolicy(ctx.g, m.mPath));
			}
			add(ctx);
			if (ctx.g.macros != null)
				add(ctx.g.macros.typer);
		};
		api.withImports = function(imports, usings, f) {
			var restoreResolution = ctx.m.importResolution.save();
			var oldUsing = ctx.m.moduleUsing;
			inline function run() {
				for (i in imports)
					context.display.ImportHandling.initImport(ctx, i.path, i.mode, Globals.nullPos);
				for (path in usings)
					context.display.ImportHandling.initUsing(ctx, path, Globals.nullPos);
				Typecore.flushPass(ctx.g, PConnectField, {name: "with_imports", args: [] /* TODO: ? */});
				return f();
			}
			function restore() {
				restoreResolution();
				ctx.m.moduleUsing = oldUsing;
			}
			var r = try run() catch (e:Dynamic) {
				restore();
				throw e;
			};
			restore();
			return r;
		};
		api.withOptions = function(opts, f) {
			var oldInline = ctx.allowInline;
			var oldTransform = ctx.allowTransform;
			if (opts.optInlining != null)
				ctx.allowInline = opts.optInlining;
			if (opts.optTransform != null)
				ctx.allowTransform = opts.optTransform;
			function restore() {
				ctx.allowInline = oldInline;
				ctx.allowTransform = oldTransform;
			}
			var r = try f() catch (e:Dynamic) {
				restore();
				throw e;
			};
			restore();
			return r;
		};
		api.warning = function(w, msg, p, ?depth) {
			Typecore.warning(ctx, w, msg, p, depth == null ? 0 : depth);
		};
		return api;
	}

	public static function initMacroInterp(mctx:TyperContext, mint:macros.eval.EvalContext.Context):Void {
		var p = Globals.nullPos;
		TypeloadModule.loadModule(mctx, {pack: ["haxe", "macro"], name: "Expr"}, p, MDepFromMacro);
		TypeloadModule.loadModule(mctx, {pack: ["haxe", "macro"], name: "Type"}, p, MDepFromMacro);
		macros.MacroEngine.engine.init(mint);
		macroInterpCache = mint;
	}

	public static function flushMacroContext(mint:macros.eval.EvalContext.Context, mctx:TyperContext):Void {
		function f(_:Null<Bool>):Null<Bool> {
			var mctx = mctx.g.macros == null ? Globals.die("", "typing/MacroContext.hx") : mctx.g.macros.typer;
			var mainModule = Finalization.maybeLoadMain(mctx);
			Finalization.finalize(mctx);
			var generated = Finalization.generate(mctx, mainModule);
			var types = generated.types;
			var modules = generated.modules;
			mctx.com.types = types;
			mctx.com.modules = modules;
			var ectx = filters.exception.ExceptionInit.createExceptionContext(mctx);
			/*
				some filters here might cause side effects that would break compilation server.
				let's save the minimal amount of information we need
			 */
			inline function minimalRestore(t:ModuleType):Void {
				if (tModule(t).mExtra.mProcessed == 0)
					tModule(t).mExtra.mProcessed = mctx.com.partScope.compilationStep;

				switch t {
					case TClassDecl(c):
						function mkFieldRestore(f:TClassField):Void->Void {
							var e = f.cfExpr;
							return function() f.cfExpr = e;
						}
						var meta = c.clMeta;
						var path = c.clPath;
						var fieldRestores = c.clOrderedFields.map(mkFieldRestore);
						var staticRestores = c.clOrderedStatics.map(mkFieldRestore);
						var ctorRestore = c.clConstructor == null ? null : mkFieldRestore(c.clConstructor);
						c.clRestore = function() {
							c.clMeta = meta;
							c.clPath = path;
							c.clDescendants = [];
							if (ctorRestore != null)
								ctorRestore();
							for (fn in fieldRestores)
								fn();
							for (fn in staticRestores)
								fn();
						};
					case _:
				}
			}
			// Apply native paths for externs only
			inline function maybeApplyNativePaths(t:ModuleType):Void {
				var applyNative = switch t {
					case TClassDecl({clKind: KAbstractImpl(a)}): a.aExtern && a.aEnum;
					case TEnumDecl(e): hasEnumFlag(e, EnExtern);
					case _: false;
				};
				if (applyNative)
					core.Native.applyNativePaths(t);
			}
			var scom = context.SafeCom.ofTyper(mctx);
			var exprFilters:Array<{name:String, run:context.SafeCom.SafeContext->TExpr->TExpr}> = [
				{name: "handle_abstract_casts", run: context.AbstractCast.handleAbstractCasts},
				{name: "local_statics", run: filters.safe.LocalStatic.run},
				{name: "Exceptions", run: function(scom, e) return filters.exception.Exceptions.filter(ectx, scom)(e)},
				{
					name: "captured_vars",
					run: function(scom, e) return filters.safe.CapturedVars.capturedVars(scom, mctx.com.localWrapper, false, e)
				},
			];
			var typeFilters:Array<context.SafeCom.SafeContext->ModuleType->Void> = [
				function(_, mt) filters.FiltersCommon.removeGenericBase(mt),
				function(scom, mt) if (processedTypeHook == null || !processedTypeHook(mt)) filters.exception.SaveStacks.patchConstructors(ectx, scom)(mt),
				function(_,
						mt) filters.safe.AddFieldInits.addFieldInits(mctx.c.curclass.clPath,
						filters.RenameVars.init(mctx.com.config, mctx.com.types), scom, mt),
				function(_, mt) filters.Filters.updateCacheDependencies(false, scom, mt),
				function(_, mt) minimalRestore(mt),
				function(_, mt) maybeApplyNativePaths(mt),
			];
			function ready(t:ModuleType):Void {
				var scom = context.SafeCom.adaptScomToMt(scom, t);
				filters.FiltersCommon.applyFiltersOnce(mctx, scom, exprFilters, t);
				for (f in typeFilters)
					f(scom, t);
			}
			try
				macros.MacroEngine.engine.addTypes(mint, types, ready)
			catch (err:TypingError)
				throw new FatalError(err.error);
			return null;
		}
		var timerLevel = Timer.levelFromDefine(mctx.com.defines, Define.MacroTimes);
		macroTimer(mctx.com.timerCtx, timerLevel, ["flush"], null, f, null);
	}

	public static function createMacroInterp(api:CompilerApi, mctx:TyperContext):{select:Void->Void, mint:macros.eval.EvalContext.Context} {
		var com2 = mctx.com;
		var mint:macros.eval.EvalContext.Context;
		var init:Void->Void;
		if (macroInterpCache == null) {
			mint = macros.MacroEngine.engine.create(com2, api, true, compiler.Args.toRawArgs(com2.parsedArgs));
			macros.eval.EvalContext.select(mint);
			var m = mint;
			init = function() initMacroInterp(mctx, m);
		} else {
			mint = macroInterpCache;
			macros.MacroEngine.engine.doReuse(mint, api, compiler.Args.toRawArgs(com2.parsedArgs));
			init = function() {};
		}
		var onError = compiler.io.CompilerMessage.defaultErrorHandler(com2);
		com2.errorExt = function(err) {
			macros.MacroEngine.engine.setError(macros.eval.EvalContext.getCtx(), true);
			macroInterpCache = null;
			onError(err);
		};
		com2.warning = compiler.io.CompilerMessage.defaultWarningHandler(com2);
		com2.info = compiler.io.CompilerMessage.defaultInfoHandler(com2);
		// mctx.g.core_api <- ctx.g.core_api; // causes some issues because of optional args and Null type in Flash9
		init();
		var m = mint;
		var init = function() macros.eval.EvalContext.select(m);
		mctx.g.macros = {finalize: init, typer: mctx};
		return {select: init, mint: mint};
	}

	public static function createMacroContext(com:CommonContext):TyperContext {
		var com2 = Common.clone(com, true);
		Common.enterStage(com2, CInitMacrosDone);
		com.getMacros = function() return com2;
		com2.packageRules = new haxe.ds.StringMap();
		// Inherit most display settings, but require normal typing.
		com2.display = core.ds.Record.withFields(com.display, {
			dmsKind: DMNone,
			dmsFullTyping: true,
			dmsForceMacroTyping: true,
			dmsInline: true
		});
		com2.classPaths.lockContext(com2.customExt, "macro", false);
		var name = Globals.platformName(core.Globals.Platform.Eval);
		var evalStd:Null<core.ClassPath.IClassPath> = null;
		(com2.classPaths : core.ClassPaths).modify(function(cp:core.ClassPath.IClassPath):Array<core.ClassPath.IClassPath> {
			return switch cp.scope {
				case StdTarget:
					[];
				case Std:
					evalStd = new core.ClassPath.DirectoryClassPath(cp.path + name + "/_std/", StdTarget);
					[cp.clone()];
				case _:
					[cp.clone()];
			};
		}, (com.classPaths : core.ClassPaths).asList());
		// Eval _std must be in front so we don't look into hxnodejs or something.
		// This can run before `TyperEntry.create`, so in order to display nice error when std is not found, this needs to be checked here too
		if (macroPlatformHook != null) {} else if (evalStd != null)
			(com2.classPaths : core.ClassPaths).add(evalStd);
		else
			Error.raiseStdNotFound();
		var defines = Common.adaptDefinesToMacroContext(com2.defines);
		com2.defines.values = defines.values;
		com2.defines.definesSignature = null;
		if (macroPlatformHook != null) macroPlatformHook(com2) else {
			com2.platform = core.Globals.Platform.Eval;
			Common.initPlatform(com2);
		}
		var mctx:TyperContext = Typecore.createContextRef(com2, null);
		mctx.m.isDisplayFile = false;
		context.CommonCache.lockSignature(com2, "get_macro_context");
		return mctx;
	}

	public static function getMacroContext(ctx:TyperContext):TyperContext {
		if (ctx.g.macros != null) {
			ctx.g.macros.finalize();
			return ctx.g.macros.typer;
		} else {
			var mctx = createMacroContext(ctx.com);
			var api = makeMacroApi(ctx, mctx, Globals.nullPos);
			var init = createMacroInterp(api, mctx).select;
			ctx.g.macros = {finalize: init, typer: mctx};
			mctx.g.macros = {finalize: init, typer: mctx};
			return mctx;
		}
	}

	public static function loadMacroModule(mctx:TyperContext, com:CommonContext, cpath:GlobalTypePath, display:Bool,
			p:Pos):{module:ModuleDef, restore:Void->Void} {
		var m = try com.moduleLut.getTypeLut().find(cpath) catch (_:NotFound) cpath;
		// Temporarily enter display mode while typing the macro.
		var old = mctx.com.display;
		if (display)
			mctx.com.display = com.display;
		var mloaded = TypeloadModule.loadModule(mctx, m, p, MDepFromMacro);
		/* mctx.m <- {
			curmod = mloaded;
			import_resolution = new resolution_list ["import";s_type_path cpath];
			own_resolution = None;
			enum_with_type = None;
			module_using = [];
			import_statements = [];
			is_display_file = (com.display.dms_kind <> DMNone && DisplayPosition.display_position#is_in_file (Path.UniqueKey.lazy_key mloaded.m_extra.m_file));
		}; */
		return {module: mloaded, restore: function() mctx.com.display = old};
	}

	public static function loadMacroPrimePrime(com:CommonContext, mctx:TyperContext, display:Bool, cpath:GlobalTypePath, fname:String,
			p:Pos):LoadedMacro {
		var mint = macros.eval.EvalContext.getCtx();
		var timerLevel = Timer.levelFromDefine(com.defines, Define.MacroTimes);
		try {
			return mctx.com.partScope.cachedMacros.find({path: cpath, name: fname});
		} catch (_:NotFound) {
			function f(_:Null<Bool>):LoadedMacro {
				var rpack = cpath.pack.copy();
				rpack.reverse();
				var mpath:GlobalTypePath, sub:Null<String>;
				if (rpack.length > 0 && rpack[0].charCodeAt(0) >= 'A'.code && rpack[0].charCodeAt(0) <= 'Z'.code) {
					var pack = rpack.slice(1);
					pack.reverse();
					mpath = {pack: pack, name: rpack[0]};
					sub = cpath.name;
				} else {
					mpath = cpath;
					sub = null;
				}
				var loaded = loadMacroModule(mctx, com, mpath, display, p);
				var mloaded = loaded.module, restore = loaded.restore;
				var cl:TClass = null, meth:TClassField = null;
				try {
					if (sub != null || !Common.samePath(mloaded.mPath, cpath))
						throw NotFound.raise();
					var c = mloaded.mStatics;
					if (c == null)
						throw NotFound.raise();
					Finalization.finalize(mctx);
					if (!c.clStatics.exists(fname))
						throw NotFound.raise();
					cl = c;
					meth = c.clStatics.get(fname);
				} catch (_:NotFound) {
					var name = sub == null ? mpath.name : sub;
					var path:GlobalTypePath = {pack: mpath.pack, name: name};
					var mt:Null<ModuleType> = null;
					for (t2 in mloaded.mTypes)
						if (Common.samePath(tPath(t2), path)) {
							mt = t2;
							break;
						}
					if (mt == null)
						Error.raiseTypingErrorExt(Error.makeError(TypeNotFound(mloaded.mPath, name, NotDefined), p));
					switch mt {
						case TClassDecl(c):
							Finalization.finalize(mctx);
							cl = c;
							meth = c.clStatics.exists(fname) ? c.clStatics.get(fname) : Error.raiseTypingError("Method " + fname
								+ " not found on class " + Globals.sTypePath(cpath), p);
						case _:
							Error.raiseTypingError("Macro should be called on a class", p);
					}
				}
				var meth:LoadedMacro = switch follow(meth.cfType) {
					case TFun(sig): {
							meth: {
								args: sig.args,
								ret: sig.ret,
								cls: cl,
								field: meth
							},
							module: mloaded
						};
					case _: Error.raiseTypingError("Macro call should be a method", p);
				};
				restore();
				if (!com.isMacroContext)
					flushMacroContext(mint, mctx);
				mctx.com.partScope.cachedMacros.add({path: cpath, name: fname}, meth);
				return meth;
			}
			return macroTimer(com.timerCtx, timerLevel, ["typing", Globals.sTypePath(cpath) + "." + fname], null, f, null);
		}
	}

	public static function loadMacroPrime(ctx:TyperContext, display:Bool, cpath:GlobalTypePath, f:String, p:Pos):MacroMethod {
		/* TODO: The only reason this nonsense is here is because this is the signature
			that typer.di_load_macro wants, and the only reason THAT exists is the stupid
			voodoo stuff in displayToplevel.ml */
		return loadMacroPrimePrime(ctx.com, getMacroContext(ctx), display, cpath, f, p).meth;
	}

	public static function doCallMacro(com:CommonContext, api:CompilerApi, cpath:GlobalTypePath, name:String, args:Array<Value>,
			p:Pos):haxe.ds.Option<Value> {
		if (com.verbose)
			Common.log(com,
				"Calling macro "
				+ Globals.sTypePath(cpath)
				+ "."
				+ name
				+ " ("
				+ p.pfile
				+ ":"
				+ syntax.Lexer.getErrorLine(p)
				+ ")");
		com.requestScope.stats.sMacrosCalled++;
		var timerLevel = Timer.levelFromDefine(com.defines, Define.MacroTimes);
		var ictx = macros.eval.EvalContext.getCtx();
		var path = cpath.pack.concat([cpath.name]);
		var f = function(api:CompilerApi):haxe.ds.Option<Value> return macros.MacroEngine.engine.callPath(ictx, path, name, args, api);
		var r = macroTimer(com.timerCtx, timerLevel, ["execution", Globals.sTypePath(cpath) + "." + name], null, f, api);
		if (com.verbose)
			Common.log(com, "Exiting macro " + Globals.sTypePath(cpath) + "." + name);
		return r;
	}

	public static function loadMacro(ctx:TyperContext, com:CommonContext, mctx:TyperContext, api:CompilerApi, display:Bool,
			cpath:GlobalTypePath, f:String, p:Pos):{
		mctx:TyperContext,
		meth:MacroMethod,
		call:Array<Value>->haxe.ds.Option<Value>
	} {
		var loaded = loadMacroPrimePrime(com, mctx, display, cpath, f, p);
		var meth = loaded.meth, mloaded = loaded.module;
		var cpath = meth.cls.clPath;
		function call(args:Array<Value>):haxe.ds.Option<Value> {
			addDependency(ctx.m.curmod, mloaded, MDepFromMacro);
			return doCallMacro(ctx.com, api, cpath, f, args, p);
		}
		return {mctx: mctx, meth: meth, call: call};
	}

	public static function typeMacro(ctx:TyperContext, mode:MacroMode, cpath:GlobalTypePath, f:String, el:Vector<Expr>, p:Pos):MacroResult {
		var mctx = getMacroContext(ctx);
		var api = makeMacroApi(ctx, mctx, p);
		var loaded = loadMacro(ctx, ctx.com, mctx, api, mode == MDisplay, cpath, f, p);
		var mctx = loaded.mctx,
			mret = loaded.meth.ret,
			mfield = loaded.meth.field,
			callMacro = loaded.call;
		var margs = loaded.meth.args;
		var margs = {
			/*
				Replace "rest:haxe.Rest<Expr>" in macro signatures with "rest:Array<Expr>".
				This allows to avoid handling special cases for rest args in macros during typing.
			 */
			if (margs.length > 0) {
				var last = margs[margs.length - 1];
				switch follow(last.type) {
					case TAbstract({aPath: {pack: ["haxe"], name: "Rest"}}, [t1]):
						VectorTools.withLast(margs, {name: last.name, optional: last.optional, type: mctx.t.tarray(t1)});
					case _:
						margs;
				}
			} else margs;
		};
		var mpos = mfield.cfPos;
		var ctexpr = AstTools.mkTypePath(["haxe", "macro"], "Expr");
		var expr = Typeload.loadInstance(mctx, makePtp(ctexpr, p), ParamNormal, LoadNormal);
		switch mode {
			case MDisplay:
				throw Exit.raise(); // We don't have to actually call the macro.
			case MExpr:
				Typecore.unify(mctx, mret, expr, mpos);
			case MBuild:
				var params = vector(
					TPType(makePtpTh(AstTools.mkTypePath(["haxe", "macro"], "Expr", null, "Field"), Globals.nullPos))
				);
				var ctfields = AstTools.mkTypePath([], "Array", params);
				var tfields = Typeload.loadInstance(mctx, makePtp(ctfields, p), ParamNormal, LoadNormal);
				Typecore.unify(mctx, mret, tfields, mpos);
			case MMacroType:
				var cttype = AstTools.mkTypePath(["haxe", "macro"], "Type");
				var ttype = Typeload.loadInstance(mctx, makePtp(cttype, p), ParamNormal, LoadNormal);
				try {
					Typecore.unifyRaise(mret, ttype, mpos);
					// TODO: enable this again in the future
					// warning ctx WDeprecated "Returning Type from @:genericBuild macros is deprecated, consider returning ComplexType instead" p;
				} catch (err:TypingError) {
					switch err.error.errMessage {
						case Unify(_):
							var cttype = AstTools.mkTypePath(["haxe", "macro"], "Expr", null, "ComplexType");
							var ttype = Typeload.loadInstance(mctx, makePtp(cttype, p), ParamNormal, LoadNormal);
							Typecore.unifyRaise(mret, ttype, mpos);
						case _:
							throw err;
					}
				}
		}
		/*
			if the function's last argument is of Array<Expr>, split the argument list and use [] for unify_call_args
		 */
		var split = {
			var lastIsExprArray = margs.length > 0 && switch margs[margs.length - 1].type {
				case TInst({clPath: {pack: [], name: "Array"}}, [e]):
					try {
						TUnification.typeEq(EqStrict, e, expr);
						true;
					} catch (_:Unify_error) false;
				case _: false;
			};
			if (lastIsExprArray) {
				var acc1:Array<Expr> = [], acc2:Array<Expr> = [];
				var i = 0, j = 0;
				var result:{el:Vector<Expr>, el2:Vector<Expr>} = null;
				while (result == null) {
					var n1 = el.length - i, n2 = margs.length - j;
					if (n1 == 0 && n2 == 0) {
						result = {el: Vector.fromArrayCopy(acc1), el2: Vector.fromArrayCopy(acc2)};
					} else if (n1 == 0 && n2 == 1) {
						acc1.push({expr: EArrayDecl(vector()), pos: p});
						result = {el: Vector.fromArrayCopy(acc1), el2: vector()};
					} else if (n1 == 0) {
						// not enough arguments, will be handled by unify_call_args
						result = {el: Vector.fromArrayCopy(acc1), el2: Vector.fromArrayCopy(acc2)};
					} else if (n2 == 1) {
						var e1 = el[i++];
						acc1.push({expr: EArrayDecl(vector()), pos: p});
						acc2 = [e1];
						j++;
					} else if (n2 == 0) {
						acc2.push(el[i++]);
					} else {
						acc1.push(el[i++]);
						j++;
					}
				}
				result;
			} else {el: el, el2: vector()};
		};
		var el = split.el, el2 = split.el2;
		var args = {
			/*
				force default parameter types to haxe.macro.Expr, and if success allow to pass any value type since it will be encoded
			 */
			var eargs:Vector<{arg:{name:String, optional:Bool, type:T}, kind:MacroArgType}> = margs.map(function(a):{arg:{name:String, optional:Bool, type:T}, kind:MacroArgType} {
				try {
					Typecore.unifyRaise(a.type, expr, p);
					return {arg: {name: a.name, optional: a.optional, type: tDynamic}, kind: MAExpr};
				} catch (err:TypingError) {
					switch err.error.errMessage {
						case Unify(_):
							return switch follow(a.type) {
								case TFun(_):
									{arg: a, kind: MAFunction};
								case _:
									{arg: a, kind: MAOther};
							};
						case _:
							throw err;
					}
				}
				return null;
			});
			/*
				this is quite tricky here : we want to use unify_call_args which will type our AST expr
				but we want to be able to get it back after it's been padded with nulls
			 */
			var index = -1;
			var constants = el.map(function(e:Expr):Expr {
				var p = e.pos;
				var e = {
					function isFunction(e:Expr):Bool
						return switch e.expr {
							case EFunction(_): true;
							case EParenthesis(e1) | ECast(e1, _) | EMeta(_, e1): isFunction(e1);
							case _: false;
						};
					if (core.Texpr.isConstantValue(ctx.com.basic, e)) {
						// temporarily disable format strings processing for macro call argument typing since we want to pass raw constants
						function loop(e:Expr):Expr
							return switch e.expr {
								case EConst(String(s, SSingleQuotes)): {expr: EConst(String(s, SDoubleQuotes)), pos: e.pos};
								case _: AstTools.mapExpr(loop, e);
							};
						loop(e);
					} else if (isFunction(e))
						/* If we pass a function expression we don't want to type it as part of `unify_call_args` because that result just gets
							discarded. Use null here so it passes, then do the actual typing in the MAFunction part below. */
						({expr: EConst(Ident("null")), pos: p} : Expr);
					else
						// if it's not a constant, let's make something that is typed as haxe.macro.Expr - for nice error reporting
						({expr: ECheckType({expr: EConst(Ident("null")), pos: p}, makePtpTh(ctexpr, p)), pos: p} : Expr);
				};
				// let's track the index by doing [e][index] (we will keep the expression type this way)
				index++;
				return {expr: EArray({expr: EArrayDecl(vector(e)), pos: p}, {expr: EConst(Int(Std.string(index), null)), pos: p}), pos: p};
			});
			var elt = CallUnification.unifyCallArgs(mctx, constants, eargs.map(function(a) return a.arg), tDynamic, p, false, false, false);
			if (eargs.length != elt.length)
				throw "Invalid_argument: List.map2";
			[
				for (i in 0...eargs.length) {
					var n = eargs[i].arg.name, t = eargs[i].arg.type, mct = eargs[i].kind;
					var e = elt[i];
					var pair:{e:Expr, et:TExpr} = switch e.eexpr {
						// get back our index and real expression
						case TArray({eexpr: TArrayDecl([e])}, {eexpr: TConst(TInt(index))}): {e: el[cast index], et: e};
						// added by unify_call_args
						case TConst(TNull): {e: {expr: EConst(Ident("null")), pos: e.epos}, et: e};
						case _: Globals.die("", "typing/MacroContext.hx");
					};
					var e = pair.e, et = pair.et;
					var ictx = macros.eval.EvalContext.getCtx();
					switch mct {
						case MAExpr:
							MacroApiImpl.encodeExpr(e);
						case MAFunction if (MacroApiImpl.nativeValues):
							// port: not with the native values' engine yet
							Error.raiseTypingError("Function arguments of macros are not available with -D hxmc.mir-macros", e.pos);
						// port: -D hih_no_eval (not upstream): Eval evaluates these arguments
						#if !hih_no_eval
						case MAFunction:
							var e = Typecore.typeExpr(mctx, e, WithTypeTools.withArgument(t, n));
							Typecore.unify(mctx, e.etype, t, e.epos);
							var v = macros.eval.EvalMain.evalExpr(ictx, e);
							v == null ? MacroApiImpl.vnull : v;
						#end
						case MAOther if (MacroApiImpl.nativeValues):
							// port: the native values' constant (as Eval evaluates it)
							macros.MacroApi.MacroNativeValues.evalConstant(et);
						#if !hih_no_eval
						case MAOther:
							var v = macros.eval.EvalMain.evalExpr(ictx, et);
							v == null ? MacroApiImpl.vnull : v;
						#else
						case _: Globals.die("", "typing/MacroContext.hx");
						#end
					}
				}
			];
		};
		var args = el2.length == 0 ? args : args.slice(0, args.length == 0 ? 0 : args.length - 1)
			.concat([MacroApiImpl.encodeArrayV(el2.map(MacroApiImpl.encodeExpr))]);
		function call():MacroResult {
			var v = switch callMacro(args) {
				case None: return MError;
				case Some(v): v;
			};
			var expected:String, process:Void->MacroResult;
			switch mode {
				case MExpr | MDisplay:
					expected = "Expr";
					process = function() return MSuccess(MacroApiImpl.decodeExpr(v));
				case MBuild:
					expected = "Array<Field>";
					process = function() {
						var fields = if (isVNull(v)) {
							var infos = ctx.c.getBuildInfos();
							infos == null ? Globals.die("", "typing/MacroContext.hx") : infos.fields;
						} else {
							var ct = makePtpTh(AstTools.mkTypePath(["haxe", "macro"], "Expr", null, "Field"), Globals.nullPos);
							var t = Typeload.loadComplexType(mctx, false, LoadNormal, ct);
							MacroApiImpl.decodeArray(v)
								.map(function(f) return safeDecode(ctx.com, f, "Field", t, p,
									function() return MacroApiImpl.decodeField(f)));
						};
						return MSuccess({
							expr: EVars(vector(
								mkEvar({name: "fields", pos: Globals.nullPos}, {type: CTAnonymous(haxe.ds.Vector.fromArrayCopy(fields)), pos: p})
							)),
							pos: p
						});
					};
				case MMacroType:
					expected = "ComplexType";
					process = function() {
						var t = if (isVNull(v)) Typecore.spawnMonomorph(ctx, p) else try {
							var ct = MacroApiImpl.decodeCtype(v);
							Typeload.loadComplexType(ctx, false, LoadNormal, ct);
						} catch (_:InvalidExpr) {
							MacroApiImpl.decodeType(v);
						} catch (_:RunTimeException) {
							MacroApiImpl.decodeType(v);
						};
						ctx.e.ret = t;
						return MSuccess({expr: EBlock(vector()), pos: p});
					};
			}
			return safeDecode(ctx.com, v, expected, mret, p, process);
		}
		var e = if (ctx.com.isMacroContext) MMacroInMacro else call();
		return e;
	}

	public static function callMacro(mctx:TyperContext, args:Vector<Expr>, margs:Vector<{name:String, optional:Bool, type:T}>,
			call:Array<Value>->haxe.ds.Option<Value>, p:Pos):haxe.ds.Option<Value> {
		var el = CallUnification.unifyCallArgs(mctx, args, margs, tDynamic, p, false, false, false);
		return call(el.mapToArray(function(e) return try MacroApiImpl.makeConst(e) catch (_:Exit)
			Error.raiseTypingError("Argument should be a constant", e.epos)));
	}

	public static function resolveInitMacro(com:CommonContext, e:String):{
		path:GlobalTypePath,
		meth:String,
		args:Vector<Expr>,
		pos:Pos
	} {
		var p = Globals.fakePos("--macro " + e);
		var e = try {
			if (e.length == 0)
				throw "index out of bounds"; // port: String.get raises Invalid_argument
			if (e.charAt(e.length - 1) == ";")
				Error.raiseTypingError("Unexpected ;", p);
			switch ParserEntry.parseExprString(ParserConfig.defaultConfig(com.defines), e, p, parseErrorCallback, false) {
				case ParseSuccess(data, _): data;
				case ParseError(_, info, _): Parser.error(info.message, info.pos);
			}
		} catch (err:Dynamic) {
			Common.displayError(com, "Could not parse `" + e + "`", p);
			throw err;
		};
		switch e.expr {
			case ECall(e, args):
				function loop(e:Expr):Array<String>
					return switch e.expr {
						case EField(e, f, _): [f].concat(loop(e));
						case EConst(Ident(i)): [i];
						case _: Error.raiseTypingError("Invalid macro call", p);
					};
				var l = loop(e);
				var path:GlobalTypePath, meth:String;
				if (l.length == 1) {
					path = {pack: ["haxe", "macro"], name: "Compiler"};
					meth = l[0];
				} else if (l.length == 2 && l[1] == "server") {
					path = {pack: ["haxe", "macro"], name: "CompilationServer"};
					meth = l[0];
				} else if (l.length >= 2) {
					var pack = l.slice(2);
					pack.reverse();
					path = {pack: pack, name: l[1]};
					meth = l[0];
				} else
					return Error.raiseTypingError("Invalid macro call", p);
				return {
					path: path,
					meth: meth,
					args: args,
					pos: p
				};
			case _:
				return Error.raiseTypingError("Invalid macro call", p);
		}
	}

	public static function callInitMacro(com:CommonContext, mctx:Null<TyperContext>, e:String):TyperContext {
		var r = resolveInitMacro(com, e);
		var path = r.path, meth = r.meth, args = r.args, p = r.pos;
		var api:CompilerApi;
		if (mctx != null) {
			api = makeMacroComApi(com, mctx.com, p);
		} else {
			mctx = createMacroContext(com);
			api = makeMacroComApi(com, mctx.com, p);
			var init = createMacroInterp(api, mctx).select;
			mctx.g.macros = {finalize: init, typer: mctx};
		}

		var loaded = loadMacro(mctx, com, mctx, api, false, path, meth, p);
		var mctx = loaded.mctx;
		callMacro(mctx, args, loaded.meth.args, loaded.call, p);
		return mctx;
	}

	public static function finalizeMacroApi(tctx:TyperContext, mctx:TyperContext):Void {
		var api = makeMacroApi(tctx, mctx, Globals.nullPos);
		if (macroInterpCache == null)
			createMacroInterp(api, mctx);
		else
			macros.MacroEngine.engine.setApi(macroInterpCache, api);
	}

	// port: Eval-target execution (`--interp`/`--eval`); not reachable from the HXB driver.
	public static function interpret(ctx:TyperContext, args:Array<String>):Void {
		context.Parallel.ManagedPool.release(ctx.com.sctx.pool);
		// port: -D hih_no_eval (not upstream): no Eval to run the program
		#if hih_no_eval
		Error.raiseTypingError("--interp needs Eval (-D hih_no_eval)", Globals.nullPos);
		#else
		var mctx = getMacroContext(ctx);
		var mctx = macros.eval.EvalMain.create(ctx.com, makeMacroComApi(ctx.com, mctx.com, Globals.nullPos), false, args);
		macros.eval.EvalMain.addTypes(mctx, ctx.com.types, function(t) {});
		if (ctx.com.main.mainExpr != null)
			macros.eval.EvalMain.evalExpr(mctx, ctx.com.main.mainExpr);
		#end
	}

	public static function setup():Void {
		#if !hih_no_eval
		macros.eval.EvalMain.setup(MacroApiImpl.macroApi);
		#end
	}
}
