/*
	The Haxe Compiler
	Copyright (C) 2005-2019  Haxe Foundation

	This program is free software; you can redistribute it and/or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version 2
	of the License, or (at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program; if not, write to the Free Software
	Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

package macros.eval;

import core.ds.NotFound;
import macros.eval.EvalValue;
import macros.eval.EvalContext;

using macros.eval.EvalValue.EvalValueTools;

class EvalField {
	public static final noField:Value = VNull;

	public static function protoFieldDirect(proto:Vprototype,
			name:Int):Value return proto.pfields[EvalContext.getProtoFieldIndexRaise(proto, name)];

	// port: the lookups below test for the name instead of catching Not_found
	// (an exception per miss: a method looked up on an instance misses its fields)
	public static function protoFieldRaise(proto:Vprototype, name:Int):Value {
		var proto = proto;
		while (true) {
			var i = proto.pnames.findOpt(name);
			if (i != null) return proto.pfields[i];
			proto = proto.pparent;
			if (proto == null) throw NotFound.raise();
		}
	}

	public static function instanceField(vi:Vinstance,
			name:Int):Value return vi.ifields[EvalContext.getInstanceFieldIndexRaise(vi.iproto, name)];

	public static function objectFieldRaise(o:Vobject, name:Int):Value {
		return switch o.oproto {
			case OProto(proto):
				var i = proto.pinstanceNames.findOpt(name);
				if (i == null) throw NotFound.raise();
				o.ofields[i];
			case ODictionary(l):
				l.find(name);
		}
	}

	public static function objectField(o:Vobject, name:Int):Value {
		return switch o.oproto {
			case OProto(proto):
				var i = proto.pinstanceNames.findOpt(name);
				i == null ? VNull : o.ofields[i];
			case ODictionary(_):
				try objectFieldRaise(o, name) catch (_:NotFound) VNull;
		}
	}

	public static function fieldRaise(v:Value, f:Int):Value {
		return switch v.vresolve() {
			case VObject(o): objectFieldRaise(o, f);
			case VInstance({ikind: IBytes(s)}) if (f == EvalHash.key_length): VInt(s.length);
			case VPrototype(proto): protoFieldRaise(proto, f);
			case VArray(va):
				if (f == EvalHash.key_length) VInt(va.alength) else protoFieldDirect(EvalContext.getCtx().arrayPrototype, f);
			case VVector(vv):
				if (f == EvalHash.key_length) VInt(vv.length) else protoFieldDirect(EvalContext.getCtx().vectorPrototype, f);
			case VString(s):
				if (f == EvalHash.key_length) VInt(s.slength) else protoFieldDirect(EvalContext.getCtx().stringPrototype, f);
			case VInstance(vi):
				var i = vi.iproto.pinstanceNames.findOpt(f);
				if (i != null) vi.ifields[i] else protoFieldRaise(vi.iproto, f);
			case _: throw NotFound.raise();
		}
	}

	public static function field(v:Value, f:Int):Value {
		try
			return fieldRaise(v, f)
		catch (_:NotFound)
			return noField;
	}

	public static function dynamicField(v:Value, name:Int):Value {
		return switch field(v, name) {
			case VFunction(f, false): VFieldClosure(v, f);
			case v: v;
		}
	}
}
