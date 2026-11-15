package generators.genphp7;

// port: the type_wrapper classes of haxe/src/generators/genphp7.ml.
import core.Ast;
import core.Globals;
import core.TType;
import core.TFunctions.*;
import core.TOther.TClassTools;
import generators.Genphp7;

/**
	Common interface for module_type instances
*/
class TypeWrapper {
	final typePath:GlobalTypePath;
	final meta:Metadata;

	/**
		Indicates if this type should be rendered to corresponding php file
	*/
	public final needsGeneration:Bool;

	public function new(typePath:GlobalTypePath, meta:Metadata, needsGeneration:Bool) {
		this.typePath = typePath;
		this.meta = meta;
		this.needsGeneration = needsGeneration;
	}

	/**
		Indicates if class initialization method should be executed upon class loaded
	*/
	public function needsInitialization():Bool throw "abstract";

	/**
		Returns hx source file name where this type was declared
	*/
	public function getSourceFile():String throw "abstract";

	/**
		Returns `Type.module_type` instance for this type
	*/
	public function getModuleType():ModuleType throw "abstract";

	/**
		Returns expression of a user-defined static __init__ method
		@see http://old.haxe.org/doc/advanced/magic#initialization-magic
	*/
	public function getMagicInit():Null<TExpr> return null;

	/**
		Namespace path. E.g. ["some"; "pack"] for "some.pack.MyType"
	*/
	public function getNamespace():Array<String> return Genphp7.getModulePath(typePath);

	/**
		Short type name. E.g. `SomeType` for `pack.SomeType`
	*/
	public function getName():String return Genphp7.getTypeName(typePath);

	/**
		Full type path
	*/
	public function getTypePath():GlobalTypePath return typePath;

	/**
		If current type requires some additional type to be generated
	*/
	public function getServiceType():Null<ModuleType> return null;
}

/**
	TClassDecl
*/
class ClassWrapper extends TypeWrapper {
	final cls:TClass;

	public function new(cls:TClass) {
		super(cls.clPath, cls.clMeta, !(hasClassFlag(cls, CExtern)));
		this.cls = cls;
	}

	/**
		Indicates if class initialization method should be executed upon class loaded
	*/
	override public function needsInitialization():Bool {
		/* Interfaces may need initialization only for RTTI meta data.
			But that meta is written in `class_wrapper#write_rtti_meta` */
		if (hasClassFlag(cls, CInterface)) return false;
		return switch TClassTools.getClInit(cls) {
			case null:
				Lambda.exists(cls.clStatics, field -> {
					/* Skip `inline var` fields */
					!(Genphp7.isInlineVar(field)) && switch [field.cfKind, field.cfExpr] {
						case [Var(_), null]: false;
						case [Var(_), {eexpr: TConst(TInt(value))}]: value == -2147483648;
						case [Var(_), {eexpr: TConst(_)}]: false;
						case [Var(_), _]: true;
						case [Method(MethDynamic), _]: true;
						case _: false;
					}
				});
			case _: true;
		}
	}

	/**
		Returns expression of a user-defined static __init__ method
		@see http://old.haxe.org/doc/advanced/magic#initialization-magic
	*/
	override public function getMagicInit():Null<TExpr> return TClassTools.getClInit(cls);

	/**
		Returns hx source file name where this type was declared
	*/
	override public function getSourceFile():String return cls.clPos.pfile;

	/**
		Returns `Type.module_type` instance for this type
	*/
	override public function getModuleType():ModuleType return TClassDecl(cls);

	/**
		If current type requires some additional type to be generated
	*/
	override public function getServiceType():Null<ModuleType> {
		if (!(hasClassFlag(cls, CExtern))) return null;
		return switch TClassTools.getClInit(cls) {
			case null: null;
			case body:
				var path:GlobalTypePath = {pack: cls.clPath.pack, name: "_extern_" + cls.clPath.name};
				var additionalCls = core.ds.Record.copy(cls);
				additionalCls.clPath = path;
				additionalCls.clFields = core.ds.SeqMap.empty();
				additionalCls.clStatics = core.ds.SeqMap.empty();
				additionalCls.clConstructor = null;
				// port: `{ cls with ... }` shares cl_init's field; set_cl_init then replaces its cf_expr in place
				// (the same body), which this copy reproduces.
				TClassTools.setClInit(additionalCls, body);
				removeClassFlag(additionalCls, CExtern);
				TClassDecl(additionalCls);
		}
	}
}

/**
	TEnumDecl
*/
class EnumWrapper extends TypeWrapper {
	final enm:TEnum;

	public function new(enm:TEnum) {
		super(enm.ePath, enm.eMeta, !(hasEnumFlag(enm, EnExtern)));
		this.enm = enm;
	}

	/**
		Indicates if class initialization method should be executed upon class loaded
	*/
	override public function needsInitialization():Bool return false;

	/**
		Returns hx source file name where this type was declared
	*/
	override public function getSourceFile():String return enm.ePos.pfile;

	/**
		Returns `Type.module_type` instance for this type
	*/
	override public function getModuleType():ModuleType return TEnumDecl(enm);
}

/**
	TTypeDecl
*/
class TypedefWrapper extends TypeWrapper {
	final tdef:TDef;

	public function new(tdef:TDef) {
		super(tdef.tPath, tdef.tMeta, false);
		this.tdef = tdef;
	}

	/**
		Indicates if class initialization method should be executed upon class loaded
	*/
	override public function needsInitialization():Bool return false;

	/**
		Returns hx source file name where this type was declared
	*/
	override public function getSourceFile():String return tdef.tPos.pfile;

	/**
		Returns `Type.module_type` instance for this type
	*/
	override public function getModuleType():ModuleType return TTypeDecl(tdef);
}

/**
	TAbstractDecl
*/
class AbstractWrapper extends TypeWrapper {
	final abstr:TAbstract;

	public function new(abstr:TAbstract) {
		super(abstr.aPath, abstr.aMeta, false);
		this.abstr = abstr;
	}

	/**
		Indicates if class initialization method should be executed upon class loaded
	*/
	override public function needsInitialization():Bool return false;

	/**
		Returns hx source file name where this type was declared
	*/
	override public function getSourceFile():String return abstr.aPos.pfile;

	/**
		Returns `Type.module_type` instance for this type
	*/
	override public function getModuleType():ModuleType return TAbstractDecl(abstr);
}
