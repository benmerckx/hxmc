package hxmc.esm;

import core.Ast;
import core.MetaList.StrictMeta;

// Parse @:esm.hot.* metadata (phase 2). M0: recognition only; lowering in later milestones.
class EsmHotMeta {
	public static final PREFIX = ":esm.hot";

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

	public static function hasHot(meta:Metadata):Bool {
		for (m in meta)
			if (isHotMeta(m)) return true;
		return false;
	}

	public static function isKeyed(meta:Metadata):Bool {
		for (m in meta)
			if (hotLeaf(metaKey(m), "keyed")) return true;
		return false;
	}

	public static function isSwappable(cf:{cfMeta:Metadata}):Bool {
		for (m in cf.cfMeta)
			if (hotLeaf(metaKey(m), "function")) return true;
		return false;
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
			var k = metaKey(m);
			if (k == PREFIX + ".scope") return true;
			if (k == PREFIX) for (a in m.exprs) switch a.expr {
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

	public static function closureId(meta:Metadata):Null<String> {
		for (m in meta) {
			if (metaKey(m) != CLOSURE_META) continue;
			for (a in m.exprs) switch a.expr {
				case EConst(String(s, _)): return s;
				default:
			}
		}
		return null;
	}

	public static function closureCapHash(meta:Metadata):Null<String> {
		for (m in meta) {
			if (metaKey(m) != CLOSURE_META) continue;
			var i = 0;
			for (a in m.exprs) {
				i++;
				if (i != 2) continue;
				switch a.expr {
					case EConst(String(s, _)): return s;
					default:
				}
			}
		}
		return null;
	}

	public static function closureCaptures(meta:Metadata):Array<String> {
		var out:Array<String> = [];
		for (m in meta) {
			if (metaKey(m) != CLOSURE_META) continue;
			var i = 0;
			for (a in m.exprs) {
				i++;
				if (i < 3) continue;
				switch a.expr {
					case EConst(String(s, _)): out.push(s);
					default:
				}
			}
		}
		return out;
	}

	public static function policy(meta:Metadata):String {
		for (m in meta) {
			var k = metaKey(m);
			if (k == PREFIX) {
				for (a in m.exprs) switch a.expr {
					case EConst(Ident(name)): return name;
					default:
				}
			}
			if (k == PREFIX + ".keep") return "keep";
			if (k == PREFIX + ".reset") return "reset";
		}
		return "reset";
	}

	public static function wasName(meta:Metadata):Null<String> {
		for (m in meta)
			if (metaKey(m) == PREFIX + ".was")
				for (a in m.exprs) switch a.expr {
					case EConst(String(s, _)): return s;
					default:
				}
		return null;
	}
}