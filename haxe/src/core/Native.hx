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
						cf.cfMeta.unshift(r.meta);
						for (overloadField in cf.cfOverloads) overloadField.cfName = r.name;
						changed = true;
					} catch (_:NotFound) {}
				}
				inline function fields(cfs:Array<TClassField>, old:haxe.ds.StringMap<TClassField>):haxe.ds.StringMap<TClassField> {
					changed = false;
					for (cf in cfs) field(cf);
					if (!changed) return old;
					var result = new haxe.ds.StringMap<TClassField>();
					for (cf in cfs) result.set(cf.cfName, cf);
					return result;
				}
				c.clFields = fields(c.clOrderedFields, c.clFields);
				c.clStatics = fields(c.clOrderedStatics, c.clStatics);
				var r = real(c.clMeta, Globals.sTypePath(c.clPath));
				c.clMeta.unshift(r.meta);
				c.clPath = Ast.parsePath(r.name);
			case TEnumDecl(e):
				var changed = false;
				var keys = [for (k in e.eConstrs.keys()) k];
				keys.sort(core.ds.Key.compareStrings);
				for (k in keys) {
					var ef = e.eConstrs.get(k);
					try {
						var r = real(ef.efMeta, ef.efName);
						ef.efName = r.name;
						ef.efMeta.unshift(r.meta);
						changed = true;
					} catch (_:NotFound) {}
				}
				if (changed) {
					var names = [];
					var result = new haxe.ds.StringMap<TEnumField>();
					for (k in keys) {
						var ef = e.eConstrs.get(k);
						names.unshift(ef.efName);
						result.set(ef.efName, ef);
					}
					e.eConstrs = result;
					e.eNames = names;
				}
				var r = real(e.eMeta, Globals.sTypePath(e.ePath));
				e.eMeta.unshift(r.meta);
				e.ePath = Ast.parsePath(r.name);
			case _:
		} catch (_:NotFound) {}
	}
}
