package context.display;

import core.ds.VectorTools.vector;

import core.Ast;
import core.Globals.Pos;
import core.TType;
import core.Meta as MetadataTools;
import core.MetaList.StrictMeta;
import core.Message.WarningCode;
import context.Common;

@:structInit class DeprecationContext {
	public var com:CommonContext;
	public var classMeta:Metadata;
	public var fieldMeta:Metadata;
	public var curmod:ModuleDef;

	public inline function new(com:CommonContext, classMeta:Metadata, fieldMeta:Metadata, curmod:ModuleDef) {
		this.com = com;
		this.classMeta = classMeta;
		this.fieldMeta = fieldMeta;
		this.curmod = curmod;
	}

	public inline function clone():DeprecationContext return new DeprecationContext(com, classMeta, fieldMeta, curmod);
}

// port: deprecation warnings are needed outside display services as well.
class DeprecationCheck {
	public static function createContext(com:CommonContext):DeprecationContext
		return {
			com: com,
			classMeta: vector(),
			fieldMeta: vector(),
			curmod: core.TFunctions.nullModule
		};

	public static function warnDeprecation(ctx:DeprecationContext, s:String, p:Pos):Void {
		var key = {file: p.pfile, offset: p.pmin};
		if (!ctx.com.partScope.warnedPositions.mem(key)) {
			var options = core.Warning.fromMeta(core.ds.VectorTools.concat(ctx.classMeta, ctx.fieldMeta));
			ctx.com.partScope.warnedPositions.add(key, {message: s, pos: p, options: options});
			Common.moduleWarning(ctx.com, ctx.curmod, WDeprecated, options, s, p);
		}
	}

	public static function printDeprecationMessage(ctx:DeprecationContext, meta:MetadataEntry, s:String, p:Pos):Void {
		var message = switch meta.exprs {
			case [{expr: EConst(String(s, _))}]: s;
			case _: 'Usage of this $s is deprecated';
		};
		warnDeprecation(ctx, message, p);
	}

	public static function checkMeta(ctx:DeprecationContext, meta:Metadata, s:String, p:Pos):Void {
		for (entry in meta) if (entry.meta == StrictMeta.Deprecated) {
			printDeprecationMessage(ctx, entry, s, p);
			return;
		}
	}

	public static function checkCf(ctx:DeprecationContext, cf:TClassField, p:Pos):Void checkMeta(ctx, cf.cfMeta, "field", p);

	public static function checkClass(ctx:DeprecationContext, c:TClass, p:Pos):Void checkMeta(ctx, c.clMeta, "class", p);

	public static function checkEnum(ctx:DeprecationContext, e:TEnum, p:Pos):Void checkMeta(ctx, e.eMeta, "enum", p);

	public static function checkEf(ctx:DeprecationContext, e:TEnumField, p:Pos):Void checkMeta(ctx, e.efMeta, "enum field", p);

	public static function checkTypedef(ctx:DeprecationContext, t:TDef, p:Pos):Void checkMeta(ctx, t.tMeta, "typedef", p);

	public static function checkModuleType(ctx:DeprecationContext, t:ModuleType, p:Pos):Void switch t {
		case TClassDecl(c):
			checkClass(ctx, c, p);
		case TEnumDecl(e):
			checkEnum(ctx, e, p);
		case _:
	}

	public static function runOnExpr(ctx:DeprecationContext, e:TExpr):Void {
		function loop(e:TExpr):Void switch e.eexpr {
			case TField(e1, fa):
				loop(e1);
				switch fa {
					case FStatic(c, cf) | FInstance(c, _, cf):
						checkClass(ctx, c, e.epos);
						checkCf(ctx, cf, e.epos);
					case FAnon(cf): checkCf(ctx, cf, e.epos);
					case FClosure(co, cf):
						if (co != null) checkClass(ctx, co.cls, e.epos);
						checkCf(ctx, cf, e.epos);
					case FEnum(en, ef):
						checkEnum(ctx, en, e.epos);
						checkEf(ctx, ef, e.epos);
					case _:
				}
			case TNew(c, _, el):
				for (arg in el) loop(arg);
				checkClass(ctx, c, e.epos);
				// The AST doesn't carry the correct overload for TNew, so let's ignore this case... (#8557).
				if (c.clConstructor != null && c.clConstructor.cfOverloads.length == 0) checkCf(ctx, c.clConstructor, e.epos);
			case TTypeExpr(mt) | TCast(_, mt) if (mt != null):
				checkModuleType(ctx, mt, e.epos);
			case TMeta(meta, e1) if (meta.meta == StrictMeta.Deprecated):
				printDeprecationMessage(ctx, meta, "field", e1.epos);
				loop(e1);
			case _:
				core.Texpr.iter(loop, e);
		}
		loop(e);
	}

	public static function runOnField(ctx:DeprecationContext, cf:TClassField):Void {
		if (cf.cfExpr != null && !MetadataTools.has(StrictMeta.Deprecated, cf.cfMeta))
			runOnExpr({
				com: ctx.com,
				classMeta: ctx.classMeta,
				fieldMeta: cf.cfMeta,
				curmod: ctx.curmod
			}, cf.cfExpr);
	}

	public static function run(com:CommonContext, types:Array<ModuleType>):Void {
		for (type in types) switch type {
			case TClassDecl(c) if (!MetadataTools.has(StrictMeta.Deprecated, c.clMeta)):
				var ctx:DeprecationContext = {
					com: com,
					classMeta: c.clMeta,
					fieldMeta: vector(),
					curmod: c.clModule
				};
				if (c.clConstructor != null) runOnField(ctx, c.clConstructor);
				var init = core.TOther.TClassTools.getClInit(c);
				if (init != null) runOnExpr(ctx, init);
				for (cf in c.clOrderedStatics) runOnField(ctx, cf);
				for (cf in c.clOrderedFields) runOnField(ctx, cf);
			case _:
		}
	}

	public static function checkIs(com:CommonContext, m:ModuleDef, clMeta:Metadata, cfMeta:Metadata, name:String, meta:Metadata,
			p:Pos):Void {
		if (Common.isNext(com) && name == "is" && !MetadataTools.has(StrictMeta.Deprecated, meta))
			warnDeprecation({
				com: com,
				classMeta: clMeta,
				fieldMeta: cfMeta,
				curmod: m
			}, 'Using "is" as an identifier is deprecated', p);
	}
}
