package hxmc;

import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import sys.FileSystem;
import sys.io.File;
import core.Globals.GlobalTypePath;
import core.TType;
import compiler.hxb.HxbData;
import compiler.server.ServerCache;
import context.Common;
import core.Message.CompilerMessageKind;
import core.Message.WarningMode;
import hxmc.ModuleStore;
import core.ds.VectorTools.vector;
import hxmc.ModuleCache;
import hxmc.ModuleCacheState;
using core.ds.VectorTools;

// the compiler's callbacks, telling when a macro registers one before
// typing is done (while a module is typed: a module restored later would not
// register it)
class WatchedCallbacks extends CompilerCallbacks {
	final com:CommonContext;
	final onEarly:String->Void;

	public function new(old:CompilerCallbacks, com:CommonContext, onEarly:String->Void) {
		super();
		this.com = com;
		this.onEarly = onEarly;
		@:privateAccess {
			beforeTyperCreate = old.beforeTyperCreate;
			afterInitMacros = old.afterInitMacros;
			afterTyping = old.afterTyping;
			beforeSave = old.beforeSave;
			afterSave = old.afterSave;
			afterFilters = old.afterFilters;
			afterGeneration = old.afterGeneration;
			nullSafetyReport = old.nullSafetyReport;
		}
	}

	function early(what:String)
		if (com.stage.getIndex() < CTypingDone.getIndex() && fromMacroApi()) onEarly(what);

	static var apiNames:Null<Array<Int>> = null;

	// whether Eval is running haxe.macro.Context's onGenerate, onAfterTyping
	// or onAfterGenerate (the compiler registers callbacks of its own while
	// typing, also in a macro: a forced inline call's check)
	static function fromMacroApi():Bool {
		var env = try macros.eval.EvalContext.getEval(null).env catch (_:Dynamic) null;
		if (env == null) return false;
		if (apiNames == null) {
			var h = macros.eval.EvalHash.hash;
			apiNames = [h("haxe.macro.Context"), h("onGenerate"), h("onAfterTyping"), h("onAfterGenerate")];
		}
		while (env != null) {
			switch env.envInfo.kind {
				case EKMethod(t, f) if (t == apiNames[0] && (f == apiNames[1] || f == apiNames[2] || f == apiNames[3])):
					return true;
				case _:
			}
			env = env.envParent;
		}
		return false;
	}

	override public function addAfterTyping(f:Array<ModuleType>->Void) {
		early("onAfterTyping");
		super.addAfterTyping(f);
	}

	override public function addBeforeSave(f:Void->Void) {
		early("onGenerate");
		super.addBeforeSave(f);
	}

	override public function addAfterSave(f:Void->Void) {
		early("onGenerate");
		super.addAfterSave(f);
	}

	override public function addAfterFilters(f:Void->Void) {
		early("afterFilters");
		super.addAfterFilters(f);
	}

	override public function addAfterGeneration(f:Void->Void) {
		early("onAfterGenerate");
		super.addAfterGeneration(f);
	}

	override public function addNullSafetyReport(f:NullSafetyReportCallback) {
		early("nullSafetyReport");
		super.addNullSafetyReport(f);
	}
}
