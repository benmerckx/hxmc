package hxmc.esm;

import core.Ast;
import core.MetaList.StrictMeta;
import core.TFunctions.*;
import core.TType;
import core.TType.TClass;
import core.TType.TClassField;

// Optional @:esm.hot.* metadata; default hot policy when -D esm.hot (docs/esm.md).
class EsmHotMeta {
	public static final PREFIX = ":esm.hot";
	public static final SYNTHETIC_HOT_ID = ":hxmc.esm.syntheticHotId";

	public static function metaKey(entry:MetadataEntry):String {
		return switch entry.meta {
			case StrictMeta.Custom(s): s;
			default: "";
		}
	}

	static function hotLeaf(k:String, leaf:String):Bool {
		if (k == PREFIX + "." + leaf) return true;
		if (k == "esm.hot." + leaf) return true;
		return false;
	}

	public static function isHotMeta(entry:MetadataEntry):Bool {
		var k = metaKey(entry);
		return k == PREFIX || StringTools.startsWith(k, PREFIX + ".");
	}

	// Keyed callee: hot cells plus another method in the same type calls this field.
	public static function isKeyed(c:TClass, cf:TClassField):Bool {
		if (cf.cfExpr == null) return false;
		if (!exprContainsHotCell(cf.cfExpr)) return false;
		return countSameTypeCallers(c, cf.cfName) > 0;
	}

	public static function isSwappable(cf:TClassField, ?c:TClass):Bool {
		if (isHotDisabled(cf.cfMeta) || (c != null && isHotDisabled(c.clMeta))) return false;
		if (cf.cfExpr == null) return false;
		return switch cf.cfExpr.eexpr {
			case TFunction(_): true;
			default: false;
		};
	}

	public static function isHotDisabled(meta:Metadata):Bool {
		for (m in meta) {
			var k = metaKey(m);
			if (k == PREFIX || k == "esm.hot")
				for (a in m.exprs) switch a.expr {
					case EConst(Ident("false")): return true;
					default:
				}
		}
		return false;
	}

	static function exprContainsHotCell(e:TExpr):Bool {
		var found = false;
		HotExprMap.mapTransform(function(cur:TExpr):TExpr {
			if (found) return cur;
			switch cur.eexpr {
				case TVar(v, _) if (isCell(v.vMeta)):
					found = true;
				case TMeta(m, _) if (isCellMetaEntry(m) || isCellPending(m)):
					found = true;
				default:
			}
			return cur;
		}, e);
		return found;
	}

	static function countSameTypeCallers(c:TClass, target:String):Int {
		var n = 0;
		function scanField(cf:TClassField):Void {
			if (cf.cfExpr == null || cf.cfName == target) return;
			HotExprMap.mapTransform(function(cur:TExpr):TExpr {
				switch cur.eexpr {
					case TCall(callee, _):
						var hit = switch callee.eexpr {
							case TField(_, FStatic(cls, callee)) if (cls == c && callee.cfName == target): true;
							case TField(_, FInstance(cls, _, callee)) if (cls == c && callee.cfName == target): true;
							case TIdent(name): name == target;
							default: false;
						};
						if (hit) n++;
					default:
				}
				return cur;
			}, cf.cfExpr);
		}
		for (cf in c.clFields) scanField(cf);
		for (cf in c.clStatics) scanField(cf);
		return n;
	}

	static function cellMetaEntry(m:MetadataEntry):Bool {
		var k = metaKey(m);
		if (k != "" && (hotLeaf(k, "cell") || StringTools.endsWith(k, ".cell") || StringTools.contains(k, "hot.cell"))) return true;
		if (k == PREFIX || k == "esm.hot")
			for (a in m.exprs) switch a.expr {
				case EConst(Ident("cell")): return true;
				default:
			}
		return false;
	}

	public static function isCell(meta:Metadata):Bool {
		for (m in meta)
			if (cellMetaEntry(m)) return true;
		return false;
	}

	public static function isCellMetaEntry(m:MetadataEntry):Bool return cellMetaEntry(m);

	public static function isScope(meta:Metadata):Bool {
		for (m in meta) {
			if (hotLeaf(metaKey(m), "scope")) return true;
			if (metaKey(m) == PREFIX) for (a in m.exprs) switch a.expr {
				case EConst(Ident("scope")): return true;
				default:
			}
		}
		return false;
	}

	public static final CLOSURE_META = PREFIX + ".closure";
	// Survives RenameVars; lowered after filters when esm.hot.Cell is on com.types.
	public static final CELL_PENDING = ":hxmc.esm.hot.cell";

	public static function isCellPending(m:MetadataEntry):Bool return metaKey(m) == CELL_PENDING;

	public static function closureIdFromEntry(m:MetadataEntry):Null<String> {
		for (a in m.exprs) switch a.expr {
			case EConst(String(s, _)): return s;
			default:
		}
		return null;
	}

	public static function closureCapHashFromEntry(m:MetadataEntry):Null<String> {
		var i = 0;
		for (a in m.exprs) {
			i++;
			if (i != 2) continue;
			switch a.expr {
				case EConst(String(s, _)): return s;
				default:
			}
		}
		return null;
	}

	public static function closureCapturesFromEntry(m:MetadataEntry):Array<String> {
		var out:Array<String> = [];
		var i = 0;
		for (a in m.exprs) {
			i++;
			if (i < 3) continue;
			switch a.expr {
				case EConst(String(s, _)): out.push(s);
				default:
			}
		}
		return out;
	}

	public static function isClosureMeta(m:MetadataEntry):Bool return metaKey(m) == CLOSURE_META;

	public static function policy(meta:Metadata):String {
		for (m in meta) {
			var k = metaKey(m);
			if (k == PREFIX || k == "esm.hot") {
				for (a in m.exprs) switch a.expr {
					case EConst(Ident("false")): continue;
					case EConst(Ident(name)): return name;
					default:
				}
			}
			if (k == PREFIX + ".keep") return "keep";
			if (k == PREFIX + ".reset") return "reset";
		}
		return "reset";
	}
}