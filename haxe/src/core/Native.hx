package core;

import core.Ast;
import core.TType;
import core.Globals;
import core.Globals.Pos;
import core.ds.NotFound;
import core.ds.VectorTools.vector;

// port: from haxe/src/core/native.ml.
class Native {
	/** retrieve string from @:native metadata or raise Not_found **/
	public static function getNativeName(meta:Metadata):{name:String, pos:Pos} {
		for (entry in meta) if (entry.meta == Meta.Native && entry.exprs.length == 1) {
			return switch entry.exprs {
				case [{expr: EConst(String(name, _)), pos: p}]: {name: name, pos: p};
				case _: Error.raiseTypingError("String expected", entry.pos);
			};
		}
		throw NotFound.raise();
	}

	// Rewrites class or enum paths if @:native metadata is set
	public static function applyNativePaths(t:ModuleType):Void {
		inline function real(meta:Metadata, name:String):{meta:MetadataEntry, name:String} {
			var native = getNativeName(meta);
			return {
				meta: {
					meta: Meta.RealPath,
					exprs: vector(
						{
							expr: EConst(String(name, SDoubleQuotes)),
							pos: native.pos
						}
					),
					pos: native.pos
				},
				name: native.name
			};
		}
		try switch t {
			case TClassDecl(c):
				var changed = false;
				inline function field(cf:TClassField):Void {
					try {
						var r = real(cf.cfMeta, cf.cfName);
						cf.cfName = r.name;
						cf.cfMeta = core.ds.VectorTools.cons(r.meta, cf.cfMeta);
						for (overloadField in cf.cfOverloads) overloadField.cfName = r.name;
						changed = true;
					} catch (_:NotFound) {}
				}
				// port: renamed fields are mapped under their new names, from the list
				inline function fields(old:core.ds.SeqMap<TClassField>):core.ds.SeqMap<TClassField> {
					changed = false;
					for (cf in old) field(cf);
					return changed ? core.TFunctions.classFieldsOf(old.toArray()) : old;
				}
				c.clFields = fields(c.clFields);
				c.clStatics = fields(c.clStatics);
				var r = real(c.clMeta, Globals.sTypePath(c.clPath));
				c.clMeta = core.ds.VectorTools.cons(r.meta, c.clMeta);
				c.clPath = Ast.parsePath(r.name);
			case TEnumDecl(e):
				var changed = false;
				for (ef in e.eConstrs.byName) {
					try {
						var r = real(ef.efMeta, ef.efName);
						ef.efName = r.name;
						ef.efMeta = core.ds.VectorTools.cons(r.meta, ef.efMeta);
						changed = true;
					} catch (_:NotFound) {}
				}
				if (changed) {
					// port: upstream rebuilds the map under the new names, consing them in the old
					// key order: e_names in reverse key order (not the declaration's any more).
					var efs = e.eConstrs.byName.foldCons(ef -> ef);
					e.eConstrs = core.ds.SeqMap.ofArray([for (ef in efs) ef.efName], efs);
				}
				var r = real(e.eMeta, Globals.sTypePath(e.ePath));
				e.eMeta = core.ds.VectorTools.cons(r.meta, e.eMeta);
				e.ePath = Ast.parsePath(r.name);
			case _:
		} catch (_:NotFound) {}
	}
}
