package hxmc.esm;

import context.Common.CommonContext;
import core.ds.VectorTools;
import core.Globals;
import core.TType;
import core.TFunctions.*;
import core.Texpr;
import haxe.crypto.Md5;

// Hot-ID filter: stable unit and call-site IDs for -D esm.hot (esm.md §4.1, §13.11).
//
// Ordinal walk (frozen M0.3): depth-first over the enclosing unit's expression tree;
// one counter per enclosing unit for every call to an @:esm.hot.keyed callee (all
// keyed calls share the counter, not per-callee-name).
//
// Call-site ID: enclosingUnitId#<ordinal> (ordinal starts at 1).
// Magic inject param name (frozen M0.4): __hotId (last argument at emit; JS extra arg).
// Unit ID (frozen M0.3): pack.Type#field for methods/statics; pack.Type#λ<n> for lambdas in unit.
class HotIds {
	public static var units = new Map<String, HotUnit>();

	public static function reset():Void {
		units = new Map();
	}

	public static function run(com:CommonContext):Void {
		if (!core.Define.rawDefined(com.defines, "esm.hot")) return;
		reset();
		for (t in com.types) switch t {
			case TClassDecl(c) if (!hasClassFlag(c, CExtern)):
				registerClassUnit(c);
				for (cf in c.clFields) visitField(com, c, cf, false);
				for (cf in c.clStatics) visitField(com, c, cf, true);
				var ctor = c.clConstructor;
				if (ctor != null) visitField(com, c, ctor, false);
			case TEnumDecl(e) if (!hasEnumFlag(e, EnExtern)):
				registerEnumUnit(e);
			case _:
		}
	}

	static function registerClassUnit(c:TClass):Void {
		if (hasClassFlag(c, CInterface)) return;
		var id = Globals.sTypePath(c.clPath);
		var layout = layoutHash(c);
		var superId = superTypeId(c);
		var policy = EsmHotMeta.policy(c.clMeta);
		var structureHash = Md5.encode(layout + "|" + superId);
		units.set(id, {
			id: id,
			kind: "class",
			codeHash: structureHash,
			policy: policy,
			layoutHash: layout,
			superId: superId,
			structureHash: structureHash,
		});
	}

	static function registerEnumUnit(e:TEnum):Void {
		var id = Globals.sTypePath(e.ePath);
		var table = enumTableHash(e);
		units.set(id, {
			id: id,
			kind: "enum",
			codeHash: table,
			policy: EsmHotMeta.policy(e.eMeta),
			enumTableHash: table,
			structureHash: table,
		});
	}

	// Raw ordered layout signature (manifest + runtime append-only migration).
	static function layoutHash(c:TClass):String {
		var buf = new StringBuf();
		var fields = [for (cf in c.clFields) cf];
		fields.sort((a, b) -> Reflect.compare(a.cfName, b.cfName));
		for (cf in fields) {
			if (hasClassFieldFlag(cf, CfStatic)) continue;
			buf.add(cf.cfName);
			buf.add(":");
			buf.add(typeSig(cf.cfType));
			if (fieldHasDefault(cf)) buf.add("?");
			buf.add(";");
		}
		return buf.toString();
	}

	static function fieldHasDefault(cf:TClassField):Bool {
		return cf.cfExpr != null;
	}

	static function typeSig(t:T):String {
		var t2 = follow(t);
		return switch t2 {
			case TInst(c, _): Globals.sTypePath(c.clPath);
			default: "?";
		}
	}

	static function superTypeId(c:TClass):String {
		if (c.clSuper == null) return "";
		return Globals.sTypePath(c.clSuper.cls.clPath);
	}

	static function enumTableHash(e:TEnum):String {
		var buf = new StringBuf();
		for (n in e.eConstrs.names()) {
			buf.add(n);
			buf.add(",");
		}
		return Md5.encode(buf.toString());
	}

	static function visitField(com:CommonContext, c:TClass, cf:TClassField, isStatic:Bool):Void {
		var uid = unitId(c, cf.cfName);
		if (EsmHotMeta.isSwappable(cf) && cf.cfExpr != null) {
			var hash = bodyHash(cf.cfExpr);
			units.set(uid, {id: uid, kind: "function", codeHash: hash, policy: EsmHotMeta.policy(cf.cfMeta)});
		}
		if (cf.cfExpr != null) cf.cfExpr = injectKeyedCalls(com.basic, uid, cf.cfExpr);
	}

	public static function unitId(c:TClass, fieldName:String):String
		return Globals.sTypePath(c.clPath) + "#" + fieldName;

	// Ordinal walk (frozen M0.3): see class doc.
	static function injectKeyedCalls(basic:BasicTypes, enclosingId:String, expr:TExpr):TExpr {
		var ordinal = 0;
		return HotExprMap.mapTransform(function(cur:TExpr):TExpr {
			switch cur.eexpr {
				case TCall(callee, args) if (keyedCallee(callee)):
					ordinal++;
					var siteId = enclosingId + "#" + ordinal;
					var hotArg:TExpr = {eexpr: TConst(TString(siteId)), etype: basic.tstring, epos: cur.epos};
					var nargs = VectorTools.snoc(args, hotArg);
					return {eexpr: TCall(callee, nargs), etype: cur.etype, epos: cur.epos};
				default:
					return cur;
			}
		}, expr);
	}

	static function keyedCallee(e:TExpr):Bool switch e.eexpr {
		case TField(_, access):
			switch access {
				case FStatic(_, cf) | FInstance(_, _, cf):
					return EsmHotMeta.isKeyed(cf.cfMeta);
				default:
					return false;
			}
		default:
			return false;
	}

	public static function bodyHash(e:TExpr):String {
		var buf = new StringBuf();
		hashExpr(e, buf);
		return Md5.encode(buf.toString());
	}

	static function hashExpr(e:TExpr, buf:StringBuf):Void switch e.eexpr {
		case TConst(c): buf.add(Std.string(c));
		case TLocal(v): buf.add(v.vName);
		case TCall(callee, args):
			buf.add("call(");
			hashExpr(callee, buf);
			for (a in args) {
				buf.add(",");
				hashExpr(a, buf);
			}
			buf.add(")");
		case TBinop(op, e1, e2):
			buf.add("binop");
			hashExpr(e1, buf);
			hashExpr(e2, buf);
		case TReturn(eo):
			buf.add("return");
			if (eo != null) hashExpr(eo, buf);
		case TBlock(el):
			for (x in el) hashExpr(x, buf);
		case TFunction(tf):
			buf.add("fn");
			hashExpr(tf.tfExpr, buf);
		case TField(e1, _):
			hashExpr(e1, buf);
			buf.add(".f");
		case TMeta(_, e1):
			hashExpr(e1, buf);
		default:
			buf.add("?");
	}
}

typedef HotUnit = {
	id: String,
	kind: String,
	codeHash: String,
	?emitHash: String,
	policy: String,
	?capHash: String,
	?layoutHash: String,
	?superId: String,
	?enumTableHash: String,
	?structureHash: String,
};