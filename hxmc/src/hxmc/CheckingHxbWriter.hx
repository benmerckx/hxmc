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

// the server's HXB writer, keeping what HXB does not of the module's unbound
// monomorphs: their modifiers (a Null<Unknown> read back would be a plain
// monomorph, and the program after it could differ). Per monomorph with
// modifiers: its index in the module's table, then the modifiers (0
// MNullable, 1 MOpenStructure, 2 MDynamic).
class CheckingHxbWriter extends compiler.hxb.HxbWriter {
	public function monoModifiers():Bytes {
		var o = new BytesOutput();
		var items = @:privateAccess tmonos.toList();
		var n = 0;
		for (it in items)
			if (it.key.tmModifiers.length > 0) n++;
		o.writeInt32(n);
		for (i in 0...items.length) {
			var mods = items[i].key.tmModifiers;
			if (mods.length == 0) continue;
			o.writeInt32(i);
			o.writeByte(mods.length);
			for (m in mods)
				o.writeByte(switch m {
					case MNullable(_): 0;
					case MOpenStructure: 1;
					case MDynamic: 2;
				});
		}
		return o.getBytes();
	}

	// the modifiers back on the monomorphs a reader made (after it read the module)
	public static function restore(com:CommonContext, reader:compiler.hxb.HxbReader, b:Bytes) {
		var i = new BytesInput(b);
		var monos:haxe.ds.Vector<T> = @:privateAccess reader.tmonos;
		for (_ in 0...i.readInt32()) {
			var index = i.readInt32();
			var mods = [
				for (_ in 0...i.readByte()) switch i.readByte() {
					case 0: MNullable(com.basic.tnull);
					case 1: MOpenStructure;
					case _: MDynamic;
				}
			];
			switch index < monos.length ? monos[index] : null {
				case TMono(r):
					r.tmModifiers = mods;
				case _:
			}
		}
	}
}
