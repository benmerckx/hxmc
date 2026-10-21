package core.json;

import core.Globals;
import core.Globals.Pos;
import core.Json.JsonValue;
import core.Json.JsonField;
import core.TFunctions.*;
import core.Ast;
import core.Meta;
import core.TType;

// port: from haxe/src/core/json/genjson.ml
@:structInit class GenjsonContext {
	public var generateAbstractImpl:Bool;
	public var generateMemberBodies:Bool;
	public var generateDocs:Bool;
	public var generateExprs:Bool;
	public var generateOrigins:Bool;

	public inline function new(generateAbstractImpl:Bool, generateMemberBodies:Bool, generateDocs:Bool, generateExprs:Bool,
			generateOrigins:Bool) {
		this.generateAbstractImpl = generateAbstractImpl;
		this.generateMemberBodies = generateMemberBodies;
		this.generateDocs = generateDocs;
		this.generateExprs = generateExprs;
		this.generateOrigins = generateOrigins;
	}

	public inline function clone():GenjsonContext return new GenjsonContext(generateAbstractImpl, generateMemberBodies, generateDocs,
		generateExprs, generateOrigins);
}

class Genjson {
	public static final jnull:JsonValue = JNull;

	public static inline function jstring(s:String):JsonValue return JString(s);

	public static inline function jint(i:Int):JsonValue return JInt(i);

	public static inline function jfloat(f:Float):JsonValue return JFloat(f);

	public static inline function jbool(b:Bool):JsonValue return JBool(b);

	public static inline function jarray(l:Array<JsonValue>):JsonValue return JArray(l);

	public static inline function jobject(l:Array<JsonField>):JsonValue return JObject(l);

	// port: a `(name,value)` pair of an object.
	public static inline function kv(name:String, value:JsonValue):JsonField return {name: name, value: value};

	public static final jtodo:JsonValue = JNull;

	public static function jopt<T>(f:T->JsonValue, o:Null<T>):JsonValue return o == null ? JNull : f(o);

	extern overload public static inline function jlist<T>(f:T->JsonValue, o:Array<T>):JsonValue return jarray([for (x in o) f(x)]);

	// port: a list kept as a Vector
	extern overload public static inline function jlist<T>(f:T->JsonValue, o:haxe.ds.Vector<T>):JsonValue return jarray([for (x in o) f(x)]);

	public static function generatePackagePath_(pack:Array<String>):Array<JsonField> return [kv("pack", jarray(pack.map(jstring)))];

	public static function generatePackagePath(pack:Array<String>):JsonValue return jobject(generatePackagePath_(pack));

	public static function generateModulePath_(mpath:GlobalTypePath):Array<JsonField> return [kv("moduleName",
		jstring(mpath.name))].concat(generatePackagePath_(mpath.pack));

	public static function generateModulePath(mpath:GlobalTypePath):JsonValue return jobject(generateModulePath_(mpath));

	public static function generateTypePath_(mpath:GlobalTypePath, tpath:GlobalTypePath,
			meta:Metadata):Array<JsonField> return [kv("typeName", jstring(tpath.name))].concat(generateModulePath_(mpath));

	public static function generateTypePath(mpath:GlobalTypePath, tpath:GlobalTypePath, meta:Metadata):JsonValue {
		function loop(l:Metadata, i:Int):GlobalTypePath {
			if (i >= l.length) return tpath;
			var m = l[i];
			if (Meta.metaEq(core.MetaList.StrictMeta.RealPath, m.meta) && m.exprs.length == 1) switch m.exprs[0].expr {
				case EConst(String(s, _)):
					return Ast.parsePath(s);
				case _:
			}
			return loop(l, i + 1);
		}
		var tpath = loop(meta, 0);
		return jobject(generateTypePath_(mpath, tpath, meta));
	}

	public static function generateAdt(ctx:GenjsonContext, tpath:Null<GlobalTypePath>, name:String, args:Null<JsonValue>):JsonValue {
		var field = kv("kind", jstring(name));
		var fields = args == null ? [field] : [field, kv("args", args)];
		return jobject(fields);
	}

	public static function fieldName(name:String, meta:Metadata):String {
		var m = Meta.getOpt(core.MetaList.StrictMeta.RealPath, meta);
		if (m == null) return name;
		if (m.exprs.length == 1) switch m.exprs[0].expr {
			case EConst(String(s, _)):
				return s;
			case _:
		}
		return name;
	}

	public static function classRef(ctx:GenjsonContext, c:TClass):JsonValue return generateTypePath(c.clModule.mPath, c.clPath, c.clMeta);

	public static function enumRef(ctx:GenjsonContext, en:TEnum):JsonValue return generateTypePath(en.eModule.mPath, en.ePath, en.eMeta);

	public static function typedefRef(ctx:GenjsonContext, td:TDef):JsonValue return generateTypePath(td.tModule.mPath, td.tPath, td.tMeta);

	public static function abstractRef(ctx:GenjsonContext,
			a:TAbstract):JsonValue return generateTypePath(a.aModule.mPath, a.aPath, a.aMeta);

	public static function moduletypeRef(ctx:GenjsonContext, mt:ModuleType):JsonValue {
		var infos = tInfos(mt);
		return generateTypePath(infos.mtModule.mPath, infos.mtPath, infos.mtMeta);
	}

	public static function classfieldRef(ctx:GenjsonContext, cf:TClassField):JsonValue return jstring(fieldName(cf.cfName, cf.cfMeta));

	public static function enumfieldRef(ctx:GenjsonContext, ef:TEnumField):JsonValue return jstring(fieldName(ef.efName, ef.efMeta));

	public static function localRef(ctx:GenjsonContext, v:TVar):JsonValue return jint(v.vId);

	public static function generatePos(ctx:GenjsonContext,
			p:Pos):JsonValue return jobject([kv("file", jstring(p.pfile)), kv("min", jint(p.pmin)), kv("max", jint(p.pmax))]);

	public static function generateExprPos(ctx:GenjsonContext, p:Pos):JsonValue return jtodo;

	public static function generateDoc(ctx:GenjsonContext,
			d:Documentation):JsonValue return ctx.generateDocs ? jopt(jstring, Ast.genDocTextOpt(d)) : jnull;

	/**
		return a range JSON structure for given position
		positions are 0-based and the result object looks like this:
		{
			start: {line: 0, character: 0},
			end: {line: 3, character: 42},
		}
	**/
	public static function posToRange(p:Pos):Array<JsonField> {
		var c = syntax.Lexer.getPosCoords(p);
		function toJson(l:Int, c:Int):JsonValue return jobject([kv("line", jint(l - 1)), kv("character", jint(c - 1))]);
		return [
			kv("start", toJson(c.lineStart, c.columnStart)),
			kv("end", toJson(c.lineEnd, c.columnEnd))
		];
	}

	public static function generatePosAsRange(p:Pos):JsonValue return p.pmin == -1 ? jnull : jobject(posToRange(p));

	public static function generatePosAsLocation(p:Pos):JsonValue {
		if (p.pmin == -1) return jnull;
		return jobject([
			kv("file", jstring(core.Path.getRealPath(p.pfile))),
			kv("range", generatePosAsRange(p))
		]);
	}

	// AST expr

	public static function generateBinop(ctx:GenjsonContext, op:Binop):JsonValue {
		var name:String, args:Null<JsonValue> = null;
		switch op {
			case OpAdd:
				name = "OpAdd";
			case OpMult:
				name = "OpMult";
			case OpDiv:
				name = "OpDiv";
			case OpSub:
				name = "OpSub";
			case OpAssign:
				name = "OpAssign";
			case OpEq:
				name = "OpEq";
			case OpNotEq:
				name = "OpNotEq";
			case OpGt:
				name = "OpGt";
			case OpGte:
				name = "OpGte";
			case OpLt:
				name = "OpLt";
			case OpLte:
				name = "OpLte";
			case OpAnd:
				name = "OpAnd";
			case OpOr:
				name = "OpOr";
			case OpXor:
				name = "OpXor";
			case OpBoolAnd:
				name = "OpBoolAnd";
			case OpBoolOr:
				name = "OpBoolOr";
			case OpShl:
				name = "OpShl";
			case OpShr:
				name = "OpShr";
			case OpUShr:
				name = "OpUShr";
			case OpMod:
				name = "OpMod";
			case OpAssignOp(op):
				name = "OpAssignOp";
				args = generateBinop(ctx, op);
			case OpInterval:
				name = "OpInterval";
			case OpArrow:
				name = "OpArrow";
			case OpIn:
				name = "OpIn";
			case OpNullCoal:
				name = "OpNullCoal";
		}
		return generateAdt(ctx, {pack: ["haxe", "macro"], name: "Binop"}, name, args);
	}

	public static function generateUnop(ctx:GenjsonContext, op:Unop):JsonValue {
		var name = switch op {
			case Increment: "OpIncrement";
			case Decrement: "OpDecrement";
			case Not: "OpNot";
			case Neg: "OpNeg";
			case NegBits: "OpNegBits";
			case Spread: "OpSpread";
		};
		return jstring(name);
	}

	public static function generateExpr(ctx:GenjsonContext, e:Expr):JsonValue return jtodo;

	// metadata

	public static function generateMetadataEntry(ctx:GenjsonContext, m:MetadataEntry):JsonValue {
		return jobject([
			kv("name", jstring(Meta.toString(m.meta))),
			kv("args", jlist(generateExpr.bind(ctx), m.exprs)),
			kv("pos", generatePos(ctx, m.pos))
		]);
	}

	public static function generateMetadata(ctx:GenjsonContext, ml:Metadata):JsonValue {
		var ml = ml.filter(function(m) return !Meta.getInfo(m.meta).info.mInternal);
		return jlist(generateMetadataEntry.bind(ctx), ml);
	}

	// AST.ml structures

	public static function generateAstTypeParam(ctx:GenjsonContext, tp:TypeParam):JsonValue {
		return jobject([
			kv("name", jstring(tp.tpName.name)),
			kv("params", jlist(generateAstTypeParam.bind(ctx), tp.tpParams)),
			kv("constraints", jtodo),
			kv("metadata", generateMetadata(ctx, tp.tpMeta))
		]);
	}

	// type instance

	public static function generateType(ctx:GenjsonContext, t:T):JsonValue {
		function loop(t:T):{name:String, args:Null<JsonValue>} {
			return switch t {
				case TMono(r):
					if (r.tmType == null) {name: "TMono", args: null} else loop(r.tmType);
				case TLazy(f):
					var t = lazyType(f);
					loop(t);
				case TDynamic(null): {name: "TDynamic", args: jnull};
				case TDynamic(t): {name: "TDynamic", args: generateType(ctx, t)};
				case TInst(c, tl): {name: "TInst", args: generateTypePathWithParams(ctx, c.clModule.mPath, c.clPath, tl, c.clMeta)};
				case TEnum(en, tl): {name: "TEnum", args: generateTypePathWithParams(ctx, en.eModule.mPath, en.ePath, tl, en.eMeta)};
				case TType(td, tl): {name: "TType", args: generateTypePathWithParams(ctx, td.tModule.mPath, td.tPath, tl, td.tMeta)};
				case TAbstract(a, tl): {name: "TAbstract", args: generateTypePathWithParams(ctx, a.aModule.mPath, a.aPath, tl, a.aMeta)};
				case TAnon(an): {name: "TAnonymous", args: generateAnon(ctx, an)};
				case TFun(s): {name: "TFun", args: jobject(generateFunctionSignature(ctx, s.args, s.ret))};
			};
		}
		var r = loop(t);
		return generateAdt(ctx, null, r.name, r.args);
	}

	public static function generateAnonStatus(ctx:GenjsonContext, status:AnonStatus):JsonValue {
		var name:String, args:Null<JsonValue> = null;
		switch status {
			case Closed:
				name = "AClosed";
			case Const:
				name = "AConst";
			case Extend(tl):
				name = "AExtend";
				args = generateTypes(ctx, tl);
			case ClassStatics(c):
				name = "AClassStatics";
				args = classRef(ctx, c);
			case EnumStatics(en):
				name = "AEnumStatics";
				args = enumRef(ctx, en);
			case AbstractStatics(a):
				name = "AAbstractStatics";
				args = abstractRef(ctx, a);
		}
		return generateAdt(ctx, null, name, args);
	}

	public static function generateAnon(ctx:GenjsonContext, an:TAnon):JsonValue {
		function generateAnonFields():JsonValue {
			// port: PMap.fold conses in key order: the result is in reverse key order
			var fields = core.ds.PMap.fold(function(cf:TClassField, acc:Array<JsonValue>) {
				acc.unshift(generateClassField(ctx, CFSMember, cf));
				return acc;
			}, an.aFields, []);
			return jarray(fields);
		}
		return jobject([
			kv("fields", generateAnonFields()),
			kv("status", generateAnonStatus(ctx, an.aStatus))
		]);
	}

	public static function generateFunctionArgument(ctx:GenjsonContext, a:{name:String, optional:Bool, type:T}):JsonValue {
		return jobject([
			kv("name", jstring(a.name)),
			kv("opt", jbool(a.optional)),
			kv("t", generateType(ctx, a.type))
		]);
	}

	public static function generateFunctionSignature(ctx:GenjsonContext, tl:haxe.ds.Vector<{name:String, optional:Bool, type:T}>,
			tr:T):Array<JsonField> {
		return [
			kv("args", jlist(generateFunctionArgument.bind(ctx), tl)),
			kv("ret", generateType(ctx, tr))
		];
	}

	public static function generateTypes(ctx:GenjsonContext, tl:core.TType.TParams):JsonValue return jlist(generateType.bind(ctx), tl);

	public static function generateTypePathWithParams(ctx:GenjsonContext, mpath:GlobalTypePath, tpath:GlobalTypePath, tl:core.TType.TParams,
			meta:Metadata):JsonValue {
		return jobject([
			kv("path", generateTypePath(mpath, tpath, meta)),
			kv("params", generateTypes(ctx, tl))
		]);
	}

	// type parameter

	public static function generateTypeParameter(ctx:GenjsonContext, ttp:TypedTypeParam):JsonValue {
		return jobject([
			kv("name", jstring(ttp.ttpName)),
			kv("constraints", generateTypes(ctx, getConstraints(ttp))),
			kv("defaultType", jopt(generateType.bind(ctx), ttp.ttpDefault))
		]);
	}

	// texpr

	public static function generateTvar(ctx:GenjsonContext, v:TVar):JsonValue {
		function generateExtra(ve:TVarExtra):JsonValue {
			var fields = [kv("params", jlist(generateTypeParameter.bind(ctx), ve.vParams))];
			if (ve.vExpr != null) fields.push(kv("expr", jobject([
				kv("string",
					jstring(core.TPrinting.sExprPretty(false, "", false, core.TPrinting.sType.bind(core.TPrinting.printContext()),
						ve.vExpr)))
			])));
			return jobject(fields);
		}
		var fields = [
			kv("id", jint(v.vId)),
			kv("name", jstring(v.vName)),
			kv("type", generateType(ctx, v.vType)),
			kv("capture", jbool(hasVarFlag(v, VCaptured))),
			kv("extra", jopt(generateExtra, v.vExtra)),
			kv("meta", generateMetadata(ctx, v.vMeta)),
			kv("pos", generatePos(ctx, v.vPos)),
			kv("isFinal", jbool(hasVarFlag(v, VFinal))),
			kv("isInline", jbool(v.vExtra != null && v.vExtra.vExpr != null))
		];
		function originToInt(o:TVarOrigin):Int return switch o {
			case TVOLocalVariable: 0;
			case TVOArgument: 1;
			case TVOForVariable: 2;
			case TVOPatternVariable: 3;
			case TVOCatchVariable: 4;
			case TVOLocalFunction: 5;
		};
		switch v.vKind {
			case VUser(origin):
				fields.unshift(kv("origin", jint(originToInt(origin))));
			case _:
		}
		return jobject(fields);
	}

	public static function generateTconstant(ctx:GenjsonContext, ct:TConstant):JsonValue {
		var name:String, args:Null<JsonValue> = null;
		switch ct {
			case TInt(i32):
				name = "TInt";
				args = jstring(Std.string(i32));
			case TFloat(s):
				name = "TFloat";
				args = jstring(s);
			case TString(s):
				name = "TString";
				args = jstring(s);
			case TBool(b):
				name = "TBool";
				args = jbool(b);
			case TNull:
				name = "TNull";
			case TThis:
				name = "TThis";
			case TSuper:
				name = "TSuper";
		}
		return generateAdt(ctx, null, name, args);
	}

	public static function generateTfunction(ctx:GenjsonContext, tf:TFunc):JsonValue {
		function generateArg(a:{variable:TVar, defaultValue:Null<TExpr>}):JsonValue return jobject([
			kv("v", generateTvar(ctx, a.variable)),
			kv("value", jopt(generateTexpr.bind(ctx), a.defaultValue))
		]);
		return jobject([
			kv("args", jlist(generateArg, tf.tfArgs)),
			kv("ret", generateType(ctx, tf.tfType)),
			kv("expr", generateTexpr(ctx, tf.tfExpr))
		]);
	}

	// port: upstream keeps the full texpr serializer commented out and returns jtodo.
	public static function generateTexpr(ctx:GenjsonContext, e:TExpr):JsonValue return jtodo;

	// fields

	public static function generateClassField_(ctx:GenjsonContext, cfs:ClassFieldScope, cf:TClassField):Array<JsonField> {
		function generateClassKind():JsonValue {
			function generateVarAccess(va:VarAccess):JsonValue {
				var name:String, args:Null<JsonValue> = null;
				switch va {
					case AccNormal:
						name = "AccNormal";
					case AccNo:
						name = "AccNo";
					case AccNever:
						name = "AccNever";
					case AccCtor:
						name = "AccCtor";
					case AccCall:
						name = "AccCall";
					case AccPrivateCall:
						name = "AccPrivateCall";
					case AccInline:
						name = "AccInline";
					case AccRequire(s, so):
						name = "AccRequire";
						args = jobject([kv("require", jstring(s)), kv("message", jopt(jstring, so))]);
				}
				return generateAdt(ctx, null, name, args);
			}
			function generateMethodKind(m:MethodKind):JsonValue {
				var name = switch m {
					case MethNormal: "MethNormal";
					case MethInline: "MethInline";
					case MethDynamic: "MethDynamic";
					case MethMacro: "MethMacro";
				};
				return jstring(name);
			}
			return switch cf.cfKind {
				case Var(vk): generateAdt(ctx, null, "FVar", jobject([
						kv("read", generateVarAccess(vk.vRead)),
						kv("write", generateVarAccess(vk.vWrite))
					]));
				case Method(m): generateAdt(ctx, null, "FMethod", generateMethodKind(m));
			};
		}
		var expr = if (ctx.generateExprs) {
			var value:Null<Expr> = switch cf.cfKind {
				case Method(_): null;
				case Var(_): var m = Meta.getOpt(core.MetaList.StrictMeta.Value,
						cf.cfMeta); m != null && m.exprs.length == 1 ? m.exprs[0] : null;
			};
			if (value == null) {
				if (Meta.has(core.MetaList.StrictMeta.Custom(":testHack"), cf.cfMeta)) {
					if (cf.cfExpr != null) jobject([
						kv("testHack", // TODO: haha
							jstring(core.TPrinting.sExprPretty(false, "", false, core.TPrinting.sType.bind(core.TPrinting.printContext()),
								cf.cfExpr)))
					])
					else jnull;
				} else jnull;
			} else jobject([kv("string", jstring(AstPrinter.sExpr(value)))]);
		} else jnull;
		return [
			kv("name", jstring(fieldName(cf.cfName, cf.cfMeta))),
			kv("type", generateType(ctx, cf.cfType)),
			kv("isPublic", jbool(hasClassFieldFlag(cf, CfPublic))),
			kv("isFinal", jbool(hasClassFieldFlag(cf, CfFinal))),
			kv("isAbstract", jbool(hasClassFieldFlag(cf, CfAbstract))),
			kv("params", jlist(generateTypeParameter.bind(ctx), cf.cfParams)),
			kv("meta", generateMetadata(ctx, cf.cfMeta)),
			kv("kind", generateClassKind()),
			kv("expr", expr),
			kv("pos", generatePos(ctx, cf.cfPos)),
			kv("doc", generateDoc(ctx, cf.cfDoc)),
			kv("overloads", jlist(generateClassField.bind(ctx, cfs), cf.cfOverloads)),
			kv("scope", jint(std.Type.enumIndex(cfs)))
		];
	}

	public static function generateClassField(ctx:GenjsonContext, cfs:ClassFieldScope,
			cf:TClassField):JsonValue return jobject(generateClassField_(ctx, cfs, cf));

	public static function generateEnumField(ctx:GenjsonContext, ef:TEnumField):JsonValue {
		return jobject([
			kv("name", jstring(fieldName(ef.efName, ef.efMeta))),
			kv("type", generateType(ctx, ef.efType)),
			kv("pos", generatePos(ctx, ef.efPos)),
			kv("meta", generateMetadata(ctx, ef.efMeta)),
			kv("index", jint(ef.efIndex)),
			kv("doc", generateDoc(ctx, ef.efDoc)),
			kv("params", jlist(generateTypeParameter.bind(ctx), ef.efParams))
		]);
	}

	// module type

	public static function generateModuleTypeFields(ctx:GenjsonContext, inf:TInfos):Array<JsonField> {
		return [
			kv("pack", jlist(jstring, inf.mtPath.pack)),
			kv("name", jstring(inf.mtPath.name)),
			kv("moduleName", jstring(inf.mtModule.mPath.name)),
			kv("pos", generatePos(ctx, inf.mtPos)),
			kv("isPrivate", jbool(inf.mtPrivate)),
			kv("params", jlist(generateTypeParameter.bind(ctx), inf.mtParams)),
			kv("meta", generateMetadata(ctx, inf.mtMeta)),
			kv("doc", generateDoc(ctx, inf.mtDoc))
		];
	}

	public static function generateClass(ctx:GenjsonContext, c:TClass):Array<JsonField> {
		function generateClassKind(ck:TClassKind):JsonValue {
			var ctor:String, args:Null<JsonValue> = null;
			switch ck {
				case KNormal:
					ctor = "KNormal";
				case KTypeParameter(ttp):
					ctor = "KTypeParameter";
					args = generateTypes(ctx, getConstraints(ttp));
				case KExpr(e):
					ctor = "KExpr";
					args = generateExpr(ctx, e);
				case KGeneric:
					ctor = "KGeneric";
				case KGenericInstance(c, tl):
					ctor = "KGenericInstance";
					args = generateTypePathWithParams(ctx, c.clModule.mPath, c.clPath, tl, c.clMeta);
				case KMacroType:
					ctor = "KMacroType";
				case KGenericBuild(_):
					ctor = "KGenericBuild";
				case KAbstractImpl(a):
					ctor = "KAbstractImpl";
					args = abstractRef(ctx, a);
				case KModuleFields(m):
					ctor = "KModuleFields";
					args = generateModulePath(m.mPath);
			}
			return generateAdt(ctx, {pack: ["haxe", "macro"], name: "ClassKind"}, ctor, args);
		}
		function generateClassRelation(r:{cls:TClass, params:TParams}):JsonValue return jobject([kv("path",
			classRef(ctx, r.cls)), kv("params", generateTypes(ctx, r.params))]);
		return [
			kv("kind", generateClassKind(c.clKind)),
			kv("isInterface", jbool(hasClassFlag(c, CInterface))),
			kv("superClass", jopt(generateClassRelation, c.clSuper)),
			kv("interfaces", jlist(generateClassRelation, c.clImplements)),
			kv("fields", ctx.generateMemberBodies ? jlist(generateClassField.bind(ctx, CFSMember), c.clOrderedFields) : jarray([])),
			kv("statics", ctx.generateMemberBodies ? jlist(generateClassField.bind(ctx, CFSStatic), c.clOrderedStatics) : jarray([])),
			kv("constructor", ctx.generateMemberBodies ? jopt(generateClassField.bind(ctx, CFSConstructor), c.clConstructor) : jnull),
			kv("init", ctx.generateMemberBodies ? jopt(generateTexpr.bind(ctx), core.TOther.TClassTools.getClInit(c)) : jnull),
			kv("overrides",
				ctx.generateMemberBodies ? jlist(classfieldRef.bind(ctx),
					c.clOrderedFields.filter(cf -> hasClassFieldFlag(cf, CfOverride))) : jarray([])),
			kv("isExtern", jbool(hasClassFlag(c, CExtern))),
			kv("isFinal", jbool(hasClassFlag(c, CFinal))),
			kv("isAbstract", jbool(hasClassFlag(c, CAbstract)))
		];
	}

	public static function generateEnum(ctx:GenjsonContext, e:TEnum):Array<JsonField> {
		function generateEnumConstructors():JsonValue return jarray(e.eNames.map(function(s) {
			var ef = core.ds.PMap.find(s, e.eConstrs);
			return generateEnumField(ctx, ef);
		}));
		return [
			kv("constructors", ctx.generateMemberBodies ? generateEnumConstructors() : jarray([])),
			kv("isExtern", jbool(hasEnumFlag(e, EnExtern)))
		];
	}

	public static function generateTypedef(ctx:GenjsonContext, td:TDef):Array<JsonField> return [kv("type", generateType(ctx, td.tType))];

	public static function generateAbstract(ctx:GenjsonContext, a:TAbstract):Array<JsonField> {
		function generateCastRelation(t:T,
				cfo:Null<TClassField>):JsonValue return jobject([kv("t",
				generateType(ctx, t)), kv("field", jopt(classfieldRef.bind(ctx), cfo))]);
		function generateCasts(fields:Array<{type:T, field:TClassField}>, casts:Array<T>):JsonValue {
			var l1 = fields.map(f -> generateCastRelation(f.type, f.field));
			var l2 = casts.map(t -> generateCastRelation(t, null));
			return jarray(l1.concat(l2));
		}
		function generateBinop_(o:{op:Binop, field:TClassField}):JsonValue return jobject([kv("op",
			generateBinop(ctx, o.op)), kv("field", classfieldRef(ctx, o.field))]);
		function generateUnop_(o:{op:Unop, flag:UnopFlag, field:TClassField}):JsonValue return jobject([
			kv("op", generateUnop(ctx, o.op)),
			kv("postFix", jbool(o.flag == Postfix)),
			kv("field", classfieldRef(ctx, o.field))
		]);
		var impl = if (a.aImpl == null) jnull else if (ctx.generateAbstractImpl) jobject(generateClass(ctx,
			a.aImpl)) else classRef(ctx, a.aImpl);
		return [
			kv("type", generateType(ctx, a.aThis)),
			kv("impl", impl),
			kv("binops", jlist(generateBinop_, a.aOps)),
			kv("unops", jlist(generateUnop_, a.aUnops)),
			kv("from", generateCasts(a.aFromField, a.aFrom)),
			kv("to", generateCasts(a.aToField, a.aTo)),
			kv("array", jlist(classfieldRef.bind(ctx), a.aArray)),
			kv("read", jopt(classfieldRef.bind(ctx), a.aRead)),
			kv("write", jopt(classfieldRef.bind(ctx), a.aWrite))
		];
	}

	public static function generateModuleType(ctx:GenjsonContext, mt:ModuleType):JsonValue {
		var fields1 = generateModuleTypeFields(ctx, tInfos(mt));
		var kind:String, fields2:Array<JsonField>;
		switch mt {
			case TClassDecl(c):
				kind = "class";
				fields2 = generateClass(ctx, c);
			case TEnumDecl(e):
				kind = "enum";
				fields2 = generateEnum(ctx, e);
			case TTypeDecl(t):
				kind = "typedef";
				fields2 = generateTypedef(ctx, t);
			case TAbstractDecl(a):
				kind = "abstract";
				fields2 = generateAbstract(ctx, a);
		}
		var fields1 = [kv("kind", jstring(kind))].concat(fields1).concat([kv("args", jobject(fields2))]);
		return jobject(fields1);
	}

	// module

	public static function generateModule(modules:core.ds.OcamlHashtbl<GlobalTypePath, compiler.hxb.HxbData.ModuleCache>,
			findModule:GlobalTypePath->ModuleDef, m:ModuleDef):JsonValue {
		// port: PMap.fold visits m_deps in increasing key order and conses: decreasing key order
		var depIds = [for (k in m.mExtra.mDeps.keys()) k];
		depIds.sort((a, b) -> a < b ? 1 : (a > b ? -1 : 0));
		return jobject([
			kv("id", jint(m.mId)),
			kv("path", generateModulePath(m.mPath)),
			kv("types", jlist(mt -> generateTypePath(m.mPath, tInfos(mt).mtPath, tInfos(mt).mtMeta), m.mTypes)),
			kv("file", jstring(core.Path.UniqueKey.lazyPath(m.mExtra.mFile))),
			kv("sign", jstring(m.mExtra.mSign)),
			kv("cacheState", jstring(switch m.mExtra.mCacheState {
				case MSGood: "Good";
				case MSBad(reason): core.TPrinting.Printer.sModuleSkipReason(reason);
				case MSUnknown: "Unknown";
			})),
			kv("dependencies", jarray([
				for (id in depIds) {
					var mdep = m.mExtra.mDeps.get(id);
					jobject([
						kv("path", jstring(Globals.sTypePath(mdep.mdPath))),
						kv("sign", jstring(findModule(mdep.mdPath).mExtra.mSign))
					]);
				}
			])),
			kv("dependents", jarray(modules.fold(function(_, m_:compiler.hxb.HxbData.ModuleCache, acc:Array<{path:GlobalTypePath, sign:String}>) {
				if (m_.mcExtra.mDeps.exists(m.mId)) acc.unshift({path: m_.mcPath, sign: m_.mcExtra.mSign});
				return acc;
			}, []).map(function(ps) return jobject([kv("path", jstring(Globals.sTypePath(ps.path))), kv("sign", jstring(ps.sign))]))))
		]);
	}

	public static function createFullConfig():GenjsonContext return {
		generateAbstractImpl: false,
		generateMemberBodies: true,
		generateDocs: true,
		generateExprs: true,
		generateOrigins: true
	};

	public static function createMinimalConfig():GenjsonContext {
		var c = createFullConfig();
		c.generateDocs = false;
		c.generateExprs = false;
		c.generateOrigins = false;
		return c;
	}

	public static function generate(timerCtx:core.Timer.TimerContext, types:Array<ModuleType>, file:String):Void {
		var json = core.Timer.time(timerCtx, ["generate", "json", "construct"], function(_:Null<Bool>) {
			var ctx = createFullConfig();
			return jarray(types.map(generateModuleType.bind(ctx)));
		}, null);
		core.Timer.time(timerCtx, ["generate", "json", "write"], function(_:Null<Bool>) {
			var ch = sys.io.File.write(file, true);
			core.Json.writeJson(function(s) ch.writeString(s), json);
			ch.close();
			return null;
		}, null);
	}
}
