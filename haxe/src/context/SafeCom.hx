package context;

import core.Globals;
import core.TType;
import core.Message;
import context.PlatformConfig;
import context.DumpConfig;
import core.TFunctions as TypeOps;
import core.TOther.TClassTools;
import core.Warning as WarningTools;
import context.Typecore;
import core.Error;
import filters.FilterContext;
import sys.thread.Mutex;

@:structInit class SavedWarning {
	public var wModule:ModuleDef;
	public var wWarning:WarningCode;
	public var wOptions:Array<Array<WarningOption>>;
	public var wMsg:String;
	public var wPos:core.Globals.Pos;

	public inline function new(wModule:ModuleDef, wWarning:WarningCode, wOptions:Array<Array<WarningOption>>, wMsg:String,
			wPos:core.Globals.Pos) {
		this.wModule = wModule;
		this.wWarning = wWarning;
		this.wOptions = wOptions;
		this.wMsg = wMsg;
		this.wPos = wPos;
	}

	public inline function clone():SavedWarning return new SavedWarning(wModule, wWarning, wOptions, wMsg, wPos);
}

@:structInit class SafeContext {
	public var basic:BasicTypes;
	public var platform:core.Globals.Platform;
	public var defines:core.Define.DefineContext;
	public var platformConfig:PlatformConfig;
	public var debug:Bool;
	public var isMacroContext:Bool;
	public var foptimize:Bool;
	public var doinline:Bool;
	public var dumpConfig:DumpConfiguration;
	public var exceptions:{value:Array<Dynamic>};
	public var exceptionsMutex:Mutex;
	public var warnings:{value:Array<SavedWarning>};
	public var warningsMutex:Mutex;
	public var errors:{value:Array<core.Error.CompilerError>};
	public var errorsMutex:Mutex;
	public var timerCtx:core.Timer.TimerContext;
	public var findModule:core.Globals.GlobalTypePath->ModuleDef;
	public var findModuleByType:core.Globals.GlobalTypePath->ModuleDef;
	public var curclass:TClass;
	public var curfield:TClassField;

	public inline function new(basic:BasicTypes, platform:core.Globals.Platform, defines:core.Define.DefineContext,
			platformConfig:PlatformConfig, debug:Bool, isMacroContext:Bool, foptimize:Bool, doinline:Bool, dumpConfig:DumpConfiguration,
			exceptions:{
			value:Array<Dynamic>
		},
			exceptionsMutex:Mutex, warnings:{value:Array<SavedWarning>}, warningsMutex:Mutex,
			errors:{value:Array<core.Error.CompilerError>}, errorsMutex:Mutex, timerCtx:core.Timer.TimerContext,
			findModule:core.Globals.GlobalTypePath->ModuleDef, findModuleByType:core.Globals.GlobalTypePath->ModuleDef, curclass:TClass,
			curfield:TClassField) {
		this.basic = basic;
		this.platform = platform;
		this.defines = defines;
		this.platformConfig = platformConfig;
		this.debug = debug;
		this.isMacroContext = isMacroContext;
		this.foptimize = foptimize;
		this.doinline = doinline;
		this.dumpConfig = dumpConfig;
		this.exceptions = exceptions;
		this.exceptionsMutex = exceptionsMutex;
		this.warnings = warnings;
		this.warningsMutex = warningsMutex;
		this.errors = errors;
		this.errorsMutex = errorsMutex;
		this.timerCtx = timerCtx;
		this.findModule = findModule;
		this.findModuleByType = findModuleByType;
		this.curclass = curclass;
		this.curfield = curfield;
	}

	public inline function clone():SafeContext return new SafeContext(basic, platform, defines, platformConfig, debug, isMacroContext,
		foptimize, doinline, dumpConfig, exceptions, exceptionsMutex, warnings, warningsMutex, errors, errorsMutex, timerCtx, findModule,
		findModuleByType, curclass, curfield);
}

class SafeCom {
	public static function ofCom(com:context.Common.CommonContext):SafeContext {
		// port: typed so the method values are bound closures (read through Dynamic they are unbound on JS).
		var moduleLut:context.Common.ModuleLut = com.moduleLut;
		return {
			basic: com.basic,
			platform: com.platform,
			defines: com.defines,
			platformConfig: com.config,
			debug: com.debug,
			isMacroContext: com.isMacroContext,
			foptimize: com.foptimize,
			doinline: com.doinline,
			dumpConfig: com.partScope.dumpConfig,
			exceptions: {
				value: []
			},
			exceptionsMutex: new Mutex(),
			warnings: {value: []},
			warningsMutex: new Mutex(),
			errors: {value: []},
			errorsMutex: new Mutex(),
			timerCtx: com.timerCtx,
			findModule: moduleLut.find,
			findModuleByType: moduleLut.findByType,
			curclass: TypeOps.nullClass,
			curfield: TypeOps.nullField
		};
	}

	public static function ofTyper(ctx:context.Typecore.Typer):SafeContext {
		var out = ofCom(ctx.com);
		out.curclass = ctx.c.curclass;
		out.curfield = ctx.f.curfield;
		return out;
	}

	public static function finalize(scom:SafeContext, com:context.Common.CommonContext):Void {
		var warnings = scom.warnings.value;
		var errors = scom.errors.value;
		var exns = scom.exceptions.value;
		scom.warnings.value = [];
		scom.errors.value = [];
		scom.exceptions.value = [];
		for (warning in warnings) Common.moduleWarning(com, warning.wModule, warning.wWarning, warning.wOptions, warning.wMsg,
			warning.wPos);
		for (err in errors) Common.displayErrorExt(com, err);
		if (exns.length > 0) throw exns[0];
	}

	public static function runWithScom<T>(com:context.Common.CommonContext, scom:SafeContext, f:Void->T):T {
		var result:T;
		try result = f()
		catch (exn:haxe.Exception) {
			finalize(scom, com);
			throw exn;
		}
		finalize(scom, com);
		return result;
	}

	static function protect<T>(mutex:Mutex, f:Void->T):T {
		mutex.acquire();
		var result:T;
		try result = f()
		catch (exn:haxe.Exception) {
			mutex.release();
			throw exn;
		}
		mutex.release();
		return result;
	}

	public static function addError(scom:SafeContext, err:core.Error.CompilerError):Void {
		protect(scom.errorsMutex, function() {
			scom.errors.value.unshift(err);
			return null;
		});
	}

	public static function addExn(scom:SafeContext, exn:Dynamic):Void {
		if (Std.isOfType(exn, core.Error.TypingError)) addError(scom, (cast exn : core.Error.TypingError).error);
		else protect(scom.exceptionsMutex, function() {
			scom.exceptions.value.unshift(exn);
			return null;
		});
	}

	public static function addWarning(scom:SafeContext, w:WarningCode, msg:String, p:core.Globals.Pos):Void {
		var options = WarningTools.fromMeta(scom.curfield.cfMeta).concat(WarningTools.fromMeta(scom.curclass.clMeta));
		switch WarningTools.getMode(w, options) {
			case WMEnable:
				protect(scom.warningsMutex, function() {
					scom.warnings.value.unshift({
						wModule: scom.curclass.clModule,
						wWarning: w,
						wOptions: options,
						wMsg: msg,
						wPos: p
					});
					return null;
				});
			case WMDisable:
		}
	}

	public static function runExpressionFiltersSafe(scom:SafeContext, detailTimes:Int,
			filters:Array<{name:String, run:SafeContext->TExpr->TExpr}>, t:ModuleType, ignoreProcessedStatus:Bool = false):Void {
		function run(local:SafeContext, identifier:Null<String>, e:TExpr):TExpr {
			try {
				var next = e;
				for (filter in filters) {
					try next = FilterContext.withTimer(local.timerCtx, detailTimes, filter.name, identifier,
						function() return filter.run(local, next))
					catch (failure:core.ds.Failure) Error.raiseTypingError(failure.message, next.epos);
				}
				return next;
			} catch (exc:Dynamic) {
				addExn(local, exc);
				return e;
			}
		}
		switch t {
			case TClassDecl(c) if (FilterContext.isRemovableClass(c)):
			case TClassDecl(c):
				var local:SafeContext = core.ds.Record.copy(scom);
				local.curclass = c;
				function processField(cf:TClassField):Void {
					// port: (hxmc) a body not typed yet (TypeBinding.lazyBodies) of the program: filtered once typed
					if (!local.isMacroContext && typing.TypeloadFields.TypeBinding.lazyBodies.exists(cf)) return;
					if (ignoreProcessedStatus || !TypeOps.hasClassFieldFlag(cf, CfPostProcessed)) {
						var fieldContext:SafeContext = core.ds.Record.copy(local);
						fieldContext.curfield = cf;
						if (cf.cfExpr != null && !FilterContext.isRemovableField(fieldContext.isMacroContext, cf))
							cf.cfExpr = run(fieldContext, Globals.sTypePath(c.clPath) + "." + cf.cfName, cf.cfExpr);
					}
					for (overloadField in cf.cfOverloads) processField(overloadField);
				}
				// port: upstream iterates immutable lists; filters such as local_statics add fields while we iterate.
				for (cf in c.clOrderedFields.copy()) processField(cf);
				for (cf in c.clOrderedStatics.copy()) processField(cf);
				if (c.clConstructor != null) processField(c.clConstructor);
				var init = TClassTools.getClInit(c);
				if (init != null) TClassTools.setClInit(c, run(local, Globals.sTypePath(c.clPath) + ".__init__", init));
			case TEnumDecl(_), TTypeDecl(_), TAbstractDecl(_):
		}
	}

	public static function adaptScomToMt(scom:SafeContext, mt:ModuleType):SafeContext return switch mt {
		case TClassDecl(c):
			var out:SafeContext = core.ds.Record.copy(scom);
			out.curclass = c;
			out;
		case _: scom;
	};

	public static function runTypeFiltersSafe(scom:SafeContext, filters:Array<SafeContext->ModuleType->Void>,
			types:Array<ModuleType>):Void {
		for (t in types) {
			var local = adaptScomToMt(scom, t);
			for (f in filters) f(local, t);
		}
	}

	public static function needsInline(scom:SafeContext, c:TClass, cf:TClassField):Bool return switch cf.cfKind {
		case Method(MethInline): scom.doinline || Typecore.isForcedInline(c, cf);
		case _: false;
	};
}
