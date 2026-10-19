package filters;

import context.PlatformConfig;
import core.Ast;
import core.TType;
import core.TFunctions as TypeOps;
import core.Globals;
import core.Meta;
import core.Path;
import core.Native;
import haxe.ds.IntMap;
import haxe.ds.StringMap;

@:structInit class RenameInit {
	public var riScope:context.PlatformConfig.VarScope;
	public var riHoisting:Bool;
	public var riNoShadowing:Bool;
	public var riNoCatchVarShadowing:Bool;
	public var riSwitchCasesNoBlocks:Bool;
	public var riReserved:StringMap<Bool>;
	public var riReserveCurrentTopLevelSymbol:Bool;

	public inline function new(riScope:context.PlatformConfig.VarScope, riHoisting:Bool, riNoShadowing:Bool, riNoCatchVarShadowing:Bool,
			riSwitchCasesNoBlocks:Bool, riReserved:StringMap<Bool>, riReserveCurrentTopLevelSymbol:Bool) {
		this.riScope = riScope;
		this.riHoisting = riHoisting;
		this.riNoShadowing = riNoShadowing;
		this.riNoCatchVarShadowing = riNoCatchVarShadowing;
		this.riSwitchCasesNoBlocks = riSwitchCasesNoBlocks;
		this.riReserved = riReserved;
		this.riReserveCurrentTopLevelSymbol = riReserveCurrentTopLevelSymbol;
	}

	public inline function clone():RenameInit return new RenameInit(riScope, riHoisting, riNoShadowing, riNoCatchVarShadowing,
		riSwitchCasesNoBlocks, riReserved, riReserveCurrentTopLevelSymbol);
}

@:structInit class RenameScope {
	/** Parent scope **/
	public var parent:Null<RenameScope>;
	/** Child scopes **/
	public var children:Array<RenameScope>;
	/**
		Pairs of "variable declared => the list of variables it overlaps with".
		That list contains variables, which were declared _before_ the current one, but
		used _after_ the current one was declared.
		Example:
		```
		var a = 123;
		var b = 324;
		trace(a);
		```
		in this example `b` overlaps with `a`.
	**/
	public var ownVars:Array<{variable:TVar, overlaps:Overlaps}>;
	/** Variables declared outside of this scope, but used inside of it **/
	public var foreignVars:Overlaps;
	/** List of variables used in current loop **/
	public var loopVars:Overlaps;
	/** Current loops depth **/
	public var loopCount:Int;

	public inline function new(parent:Null<RenameScope>, children:Array<RenameScope>, ownVars:Array<{variable:TVar, overlaps:Overlaps}>,
			foreignVars:Overlaps, loopVars:Overlaps, loopCount:Int) {
		this.parent = parent;
		this.children = children;
		this.ownVars = ownVars;
		this.foreignVars = foreignVars;
		this.loopVars = loopVars;
		this.loopCount = loopCount;
	}

	public inline function clone():RenameScope return new RenameScope(parent, children, ownVars, foreignVars, loopVars, loopCount);
}

// port: a `bool StringMap.t` extended from another one. OCaml's StringMap.add shares the
// map it extends; copying a haxe.ds.StringMap instead made every scope copy all reserved
// names (with ReserveAllTypesFlat, every type of the program). Names added here are
// looked up before the base, which is not modified while this set is in use.
class ReservedNames {
	final base:Null<ReservedNames>;
	final baseMap:Null<StringMap<Bool>>;
	final own = new StringMap<Bool>();

	public function new(base:Null<ReservedNames>, baseMap:Null<StringMap<Bool>>) {
		this.base = base;
		this.baseMap = baseMap;
	}

	public function exists(name:String):Bool
		return own.exists(name) || (baseMap != null && baseMap.exists(name)) || (base != null && base.exists(name));

	public function set(name:String, value:Bool):Void own.set(name, value);
}

@:structInit class RenameContext {
	public var rcHoisting:Bool;
	public var rcNoShadowing:Bool;
	public var rcNoCatchVarShadowing:Bool;
	public var rcSwitchCasesNoBlocks:Bool;
	public var rcScope:context.PlatformConfig.VarScope;
	public var rcReserved:ReservedNames;
	/** Scope a variable is declared in **/
	public var rcVarOrigins:IntMap<RenameScope>;

	public inline function new(rcHoisting:Bool, rcNoShadowing:Bool, rcNoCatchVarShadowing:Bool, rcSwitchCasesNoBlocks:Bool,
			rcScope:context.PlatformConfig.VarScope, rcReserved:ReservedNames, rcVarOrigins:IntMap<RenameScope>) {
		this.rcHoisting = rcHoisting;
		this.rcNoShadowing = rcNoShadowing;
		this.rcNoCatchVarShadowing = rcNoCatchVarShadowing;
		this.rcSwitchCasesNoBlocks = rcSwitchCasesNoBlocks;
		this.rcScope = rcScope;
		this.rcReserved = rcReserved;
		this.rcVarOrigins = rcVarOrigins;
	}

	public inline function clone():RenameContext return new RenameContext(rcHoisting, rcNoShadowing, rcNoCatchVarShadowing,
		rcSwitchCasesNoBlocks, rcScope, rcReserved, rcVarOrigins);
}

// port: persistent map/list snapshots are explicitly copied where mutation would change sharing semantics.
// ... ovVars is in push order (`v :: ov.ov_vars` as a push): read from the end.
class Overlaps {
	public var ovVars:Array<TVar> = [];
	public var ovLut:IntMap<Bool> = new IntMap();
	public var ovNameCache:Null<StringMap<Bool>> = null;

	public function new() {}

	public static function create():Overlaps return new Overlaps();

	public function copy():Overlaps {
		var ov = new Overlaps();
		ov.ovVars = ovVars.copy();
		ov.ovLut = ovLut.copy();
		ov.ovNameCache = ovNameCache;
		return ov;
	}

	public function add(v:TVar):Void {
		ovVars.push(v);
		ovLut.set(v.vId, true);
		ovNameCache = null;
	}

	public function getCache():StringMap<Bool> {
		if (ovNameCache == null) {
			ovNameCache = new StringMap();
			for (v in ovVars) ovNameCache.set(v.vName, true);
		}
		return ovNameCache;
	}

	public function hasName(name:String):Bool return getCache().exists(name);

	public function iter(f:TVar->Void):Void {
		var i = ovVars.length;
		while (i > 0) f(ovVars[--i]);
	}

	public function mem(id:Int):Bool return ovLut.exists(id);

	public function reset():Void {
		ovVars = [];
		ovLut.clear();
		ovNameCache = null;
	}

	public function isEmpty():Bool return ovVars.length == 0;
}

class RenameVars {
	/**
		For initialization.
		Make the `name` a reserved word.
		No local variable will be allowed to have such name.
	**/
	public static function reserveInit(ri:RenameInit, name:String):Void ri.riReserved.set(name, true);

	/**
		Make all module-level names reserved.
		No local variable will have a name matching a module-level declaration.
	**/
	public static function reserveAllTypes(ri:RenameInit, types:Array<ModuleType>, pathToName:GlobalTypePath->String):Void {
		for (mt in types) {
			var infos = TypeOps.tInfos(mt);
			var nativeName:String;
			try nativeName = Native.getNativeName(infos.mtMeta).name
			catch (_:Dynamic) nativeName = pathToName(infos.mtPath);
			switch mt {
				case TClassDecl(c) if (nativeName == ""):
					for (cf in c.clOrderedStatics) {
						var name:String;
						try name = Native.getNativeName(cf.cfMeta).name
						catch (_:Dynamic) name = cf.cfName;
						reserveInit(ri, name);
					}
				case TClassDecl({clKind: KModuleFields(m), clOrderedStatics: fl}):
					var prefix = Path.flatPath(m.mPath) + "_";
					for (cf in fl) {
						var name:String;
						try name = Native.getNativeName(cf.cfMeta).name
						catch (_:Dynamic) name = prefix + cf.cfName;
						reserveInit(ri, name);
					}
				case _:
					reserveInit(ri, nativeName);
			}
		}
	}

	/**
		Initialize the context for local variables renaming
	**/
	public static function init(config:context.PlatformConfig, types:Array<ModuleType>):RenameInit {
		var ri:RenameInit = {
			riScope: config.pfScoping.vsScope,
			riReserved: new StringMap(),
			riHoisting: false,
			riNoShadowing: false,
			riNoCatchVarShadowing: false,
			riSwitchCasesNoBlocks: false,
			riReserveCurrentTopLevelSymbol: false
		};
		reserveInit(ri, "this");
		for (flag in config.pfScoping.vsFlags) switch flag {
			case VarHoisting:
				ri.riHoisting = true;
			case NoShadowing:
				ri.riNoShadowing = true;
			case NoCatchVarShadowing:
				ri.riNoCatchVarShadowing = true;
			case SwitchCasesNoBlocks:
				ri.riSwitchCasesNoBlocks = true;
			case ReserveNames(names):
				for (name in names) reserveInit(ri, name);
			case ReserveAllTopLevelSymbols:
				reserveAllTypes(ri, types, p -> p.pack.length == 0 ? p.name : p.pack[0]);
			case ReserveAllTypesFlat:
				reserveAllTypes(ri, types, Path.flatPath);
			case ReserveCurrentTopLevelSymbol:
				ri.riReserveCurrentTopLevelSymbol = true;
		}
		return ri;
	}

	/**
		Make `name` a reserved word.
		No local variable will be allowed to have such name.
	**/
	public static function reserveCtx(rc:RenameContext, name:String):Void rc.rcReserved.set(name, true);

	/**
		Make `name` a reserved word.
		No local variable will be allowed to have such name.
	**/
	public static function reserve(reserved:ReservedNames, name:String):Void reserved.set(name, true);

	public static function createScope(parent:Null<RenameScope>):RenameScope {
		var scope:RenameScope = {
			parent: parent,
			children: [],
			ownVars: [],
			foreignVars: Overlaps.create(),
			loopVars: Overlaps.create(),
			loopCount: 0
		};
		// port: `scope :: p.children` as a push: children are read from the end
		if (parent != null) parent.children.push(scope);
		return scope;
	}

	/**
		Invoked for each `TVar v` texpr_expr
	**/
	public static function declareVar(rc:RenameContext, scope:RenameScope, v:TVar):Void {
		var overlaps:Overlaps;
		if (!rc.rcHoisting || scope.foreignVars.isEmpty()) overlaps = scope.loopCount == 0 ? Overlaps.create() : scope.loopVars.copy();
		else if (scope.loopCount == 0) overlaps = scope.foreignVars.copy();
		else {
			overlaps = scope.loopVars.copy();
			scope.foreignVars.iter(o -> overlaps.add(o));
		}
		// port: `(v, overlaps) :: scope.own_vars` as a push: ownVars is read from the end
		scope.ownVars.push({variable: v, overlaps: overlaps});
		rc.rcVarOrigins.set(v.vId, scope);
		if (scope.loopCount > 0) scope.loopVars.add(v);
	}

	public static function willBeReserved(rc:RenameContext,
			v:TVar):Bool return rc.rcNoShadowing || TypeOps.hasVarFlag(v, VCaptured) && rc.rcHoisting;

	public static function unboundVariable(v:TVar):Dynamic throw new core.ds.Failure("Unbound variable: " + v.vName + "<" + v.vId + ">");

	/**
		Invoked for each `TLocal v` texr_expr
	**/
	public static function determineOverlaps(rc:RenameContext, scope:RenameScope, v:TVar):Void {
		var i = scope.ownVars.length;
		while (i > 0) {
			var decl = scope.ownVars[--i];
			// If we find a declaration that already knows us, we don't have to keep
			// looping because we can be sure that we've been here before.
			if (decl.variable == v || decl.overlaps.mem(v.vId)) return;
			decl.overlaps.add(v);
		}
		if (rc.rcNoShadowing || rc.rcHoisting) scope.foreignVars.add(v);
		if (scope.parent != null) determineOverlaps(rc, scope.parent, v);
		else unboundVariable(v);
	}

	public static function useVar(rc:RenameContext, scope:RenameScope, v:TVar):Void {
		if (!willBeReserved(rc, v)) determineOverlaps(rc, scope, v);
		else {
			if (!rc.rcVarOrigins.exists(v.vId)) throw core.ds.NotFound.raise();
			var origin = rc.rcVarOrigins.get(v.vId);
			function loop(scope:RenameScope):Void {
				if (scope == origin) return;
				if (rc.rcNoShadowing || rc.rcHoisting) scope.foreignVars.add(v);
				if (scope.parent != null) loop(scope.parent);
				else unboundVariable(v);
			}
			loop(scope);
		}
		if (scope.loopCount > 0) scope.loopVars.add(v);
	}

	public static function collectLoop(scope:RenameScope, fn:Void->Void):Void {
		++scope.loopCount;
		fn();
		--scope.loopCount;
		if (scope.loopCount < 0) throw new core.ds.Failure("Unexpected loop count");
		if (scope.loopCount == 0) scope.loopVars.reset();
	}

	/**
		Collect all the variables declared and used in `e` expression.
	**/
	public static function collectVars(rc:RenameContext, scope:RenameScope, e:TExpr, inBlock:Bool = false):Void {
		var childInBlock = switch e.eexpr {
			case TBlock(_) | TFunction(_): true;
			case _: false;
		};
		function collect(scope:RenameScope, e:TExpr):Void collectVars(rc, scope, e, childInBlock);
		switch e.eexpr {
			case TVar(v, eo):
				var fn = eo != null && switch eo.eexpr {
					case TFunction(_): true;
					case _: false;
				};
				if (rc.rcHoisting || fn) {
					declareVar(rc, scope, v);
					if (eo != null) collect(scope, eo);
				} else {
					if (eo != null) collect(scope, eo);
					declareVar(rc, scope, v);
				}
			case TLocal(v):
				useVar(rc, scope, v);
			case TFunction(fn):
				var scope = createScope(scope);
				for (a in fn.tfArgs) declareVar(rc, scope, a.variable);
				for (a in fn.tfArgs) useVar(rc, scope, a.variable);
				for (a in fn.tfArgs) if (a.defaultValue != null) collect(scope, a.defaultValue);
				switch fn.tfExpr.eexpr {
					case TBlock(exprs): for (e in exprs) collect(scope, e);
					case _: collect(scope, fn.tfExpr);
				}
			case TTry(tryExpr, catches):
				collect(scope, tryExpr);
				for (c in catches) {
					var vExpr = TypeOps.mk(TVar(c.variable, null), TypeOps.tDynamic, c.variable.vPos);
					var exprs = switch c.expr.eexpr {
						case TBlock(exprs): [vExpr].concat(exprs);
						case _: [vExpr, c.expr];
					};
					collect(scope, TypeOps.mk(TBlock(exprs), c.expr.etype, c.expr.epos));
					if (rc.rcNoCatchVarShadowing) useVar(rc, scope, c.variable);
				}
			case TSwitch(sw) if (rc.rcSwitchCasesNoBlocks):
				collect(scope, sw.switchSubject);
				for (c in sw.switchCases) {
					for (e in c.casePatterns) collect(scope, e);
					collectIgnoreBlock(rc, scope, c.caseExpr, true);
				}
				if (sw.switchDefault != null) collectIgnoreBlock(rc, scope, sw.switchDefault, true);
			case TBlock(exprs) if (rc.rcScope == BlockScope && !inBlock):
				var scope = createScope(scope);
				for (e in exprs) collect(scope, e);
			case TWhile(condition, body, flag):
				collectLoop(scope, function() {
					if (flag == NormalWhile) collect(scope, condition);
					collect(scope, body);
					if (flag == DoWhile) collect(scope, condition);
				});
			case _:
				core.Texpr.iterWith(collect, scope, e);
		}
	}

	public static function collectIgnoreBlock(rc:RenameContext, scope:RenameScope, e:TExpr, inBlock:Bool = false):Void {
		switch e.eexpr {
			case TBlock(el):
				for (e in el) collectVars(rc, scope, e, inBlock);
			case _:
				collectVars(rc, scope, e, inBlock);
		}
	}

	// port: a fresh EReg per use; an EReg keeps its last match, and this
	// runs on several threads at once (upstream's Str.regexp is immutable)
	static inline function trailingNumbers():EReg return ~/[0-9]+$/;

	/**
		Rename `v` if needed
	**/
	public static function maybeRenameVar(rc:RenameContext, reserved:ReservedNames, entry:{variable:TVar, overlaps:Overlaps}):Void {
		var v = entry.variable;
		inline function commit(name:String):Void {
			v.vMeta = ([
				{
					meta: core.MetaList.StrictMeta.RealPath,
					exprs: [
						{
							expr: EConst(String(v.vName, SDoubleQuotes)),
							pos: Globals.nullPos
						}
					],
					pos: Globals.nullPos
				}
			] : core.Ast.Metadata).concat(v.vMeta);
			v.vName = name;
		}
		// chop escape char for all local variables generated
		if (v.vName.charAt(0) == core.Globals.genLocalPrefix.charAt(0)) commit("_g" + trailingNumbers().replace(v.vName.substr(1), ""));
		var name = v.vName;
		var count = 0;
		while (reserved.exists(name) || entry.overlaps.hasName(name)) {
			++count;
			name = v.vName + count;
		}
		commit(name);
		if (willBeReserved(rc, v)) reserve(reserved, v.vName);
	}

	/**
		Rename variables found in `scope`
	**/
	public static function renameVars(rc:RenameContext, scope:RenameScope):Void {
		var reserved = new ReservedNames(rc.rcReserved, null);
		if ((rc.rcHoisting || rc.rcNoShadowing) && !scope.foreignVars.isEmpty()) scope.foreignVars.iter(v -> reserve(reserved, v.vName));
		// port: ownVars in push order is `List.rev scope.own_vars`
		for (entry in scope.ownVars) maybeRenameVar(rc, reserved, entry);
		var i = scope.children.length;
		while (i > 0) renameVars(rc, scope.children[--i]);
	}

	/**
		Rename local variables in `e` expression if needed.
	**/
	public static function run(clPath:GlobalTypePath, ri:RenameInit, e:TExpr):TExpr {
		var rc:RenameContext = {
			rcScope: ri.riScope,
			rcHoisting: ri.riHoisting,
			rcNoShadowing: ri.riNoShadowing,
			rcNoCatchVarShadowing: ri.riNoCatchVarShadowing,
			rcSwitchCasesNoBlocks: ri.riSwitchCasesNoBlocks,
			rcReserved: new ReservedNames(null, ri.riReserved),
			rcVarOrigins: new IntMap()
		};
		if (ri.riReserveCurrentTopLevelSymbol) reserveCtx(rc, clPath.pack.length == 0 ? clPath.name : clPath.pack[0]);
		var scope = createScope(null);
		collectVars(rc, scope, e);
		renameVars(rc, scope);
		return e;
	}
}
