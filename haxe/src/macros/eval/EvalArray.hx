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

import macros.eval.EvalValue;
import haxe.ds.Vector;

// port: `avalues` is a Vector, the OCaml array: its length is the capacity,
// `alength` the array's length. Reallocation sizes follow upstream.
class EvalArray {
	public static function create(values:Vector<Value>):Varray return new Varray(values, values.length);

	// port: `create (Array.of_list l)`
	public static function ofList(values:Array<Value>):Varray return create(Vector.fromArrayCopy(values));

	public static function arrayJoin(a:Vector<Value>, f:Value->Vstring, sep:Vstring):Vstring {
		var l = [for (i in 0...a.length) f(a[i])];
		return EvalString.join(sep, l);
	}

	public static function toList(a:Varray):Array<Value> return [for (i in 0...a.alength) a.avalues[i]];

	public static function make(len:Int):Vector<Value> {
		if (len < 0 || len > 0x3FFFFFFF) return EvalContext.errorMessage("Array allocation is too large");
		return new Vector(len, VNull);
	}

	static inline function blit(src:Vector<Value>, srcPos:Int, dst:Vector<Value>, dstPos:Int, len:Int):Void {
		if (len < 0 || srcPos < 0 || dstPos < 0 || srcPos + len > src.length || dstPos
			+ len > dst.length) throw new haxe.Exception("Invalid_argument(\"Array.blit\")");
		Vector.blit(src, srcPos, dst, dstPos, len);
	}

	static inline function sub(a:Vector<Value>, pos:Int, len:Int):Vector<Value> {
		if (pos < 0 || len < 0 || pos + len > a.length) throw new haxe.Exception("Invalid_argument(\"Array.sub\")");
		var r = new Vector<Value>(len);
		Vector.blit(a, pos, r, 0, len);
		return r;
	}

	public static function setLength(a:Varray, l:Int):Void {
		a.alength = l;
		if (a.alength > a.avalues.length) {
			var values2 = make(a.alength * 2);
			blit(a.avalues, 0, values2, 0, a.avalues.length);
			a.avalues = values2;
		}
	}

	public static inline function unsafeGet(a:Varray, i:Int):Value return a.avalues[i];

	public static inline function unsafeSet(a:Varray, i:Int, v:Value):Void a.avalues[i] = v;

	public static function concat(a:Varray, a2:Varray):Varray {
		var values2 = make(a.alength + a2.alength);
		blit(a.avalues, 0, values2, 0, a.alength);
		var values3 = a2.avalues;
		blit(values3, 0, values2, a.alength, a2.alength);
		return create(values2);
	}

	public static function copy(a:Varray):Varray return create(sub(a.avalues, 0, a.alength));

	public static function filter(a:Varray, f:Value->Bool):Varray {
		var values = sub(a.avalues, 0, a.alength);
		return ofList([for (i in 0...values.length) if (f(values[i])) values[i]]);
	}

	public static function get(a:Varray, i:Int):Value {
		if (i < 0 || i >= a.alength) return VNull;
		return a.avalues[i];
	}

	public static function indexOf(a:Varray, equals:Value->Value->Bool, x:Value, fromIndex:Int):Int {
		while (true) {
			if (fromIndex >= a.alength) return -1;
			if (fromIndex < 0) throw new haxe.Exception("Invalid_argument(\"index out of bounds\")");
			if (equals(x, a.avalues[fromIndex])) return fromIndex;
			fromIndex++;
		}
	}

	public static function insert(a:Varray, pos:Int, x:Value):Void {
		if (a.alength + 1 >= a.avalues.length) {
			var values2 = make(a.avalues.length * 2 + 5);
			blit(a.avalues, 0, values2, 0, a.alength);
			a.avalues = values2;
		}
		blit(a.avalues, pos, a.avalues, pos + 1, a.alength - pos);
		if (pos < 0 || pos >= a.avalues.length) throw new haxe.Exception("Invalid_argument(\"index out of bounds\")");
		a.avalues[pos] = x;
		a.alength = a.alength + 1;
	}

	public static function iterator(a:Varray):{hasNext:Void->Bool, next:Void->Value} {
		var i = 0;
		var a = sub(a.avalues, 0, a.alength);
		var length = a.length;
		return {
			hasNext: () -> i < length,
			next: () -> {
				if (i >= length) VNull
				else {
					var v = a[i];
					i++;
					v;
				}
			}
		};
	}

	public static function join(a:Varray, f:Value->Vstring, sep:Vstring):Vstring return arrayJoin(sub(a.avalues, 0, a.alength), f, sep);

	public static function lastIndexOf(a:Varray, equals:Value->Value->Bool, x:Value, fromIndex:Int):Int {
		function loop(i:Int):Int {
			while (true) {
				if (i < 0) return -1;
				if (i >= a.avalues.length) throw new haxe.Exception("Invalid_argument(\"index out of bounds\")");
				if (equals(x, a.avalues[i])) return i;
				i--;
			}
		}
		return a.alength == 0 ? -1 : loop(fromIndex);
	}

	public static function map(a:Varray, f:Value->Value):Varray return create(sub(a.avalues, 0, a.alength).map(f));

	public static function pop(a:Varray):Value {
		if (a.alength == 0) return VNull;
		var v = get(a, a.alength - 1);
		unsafeSet(a, a.alength - 1, VNull);
		a.alength = a.alength - 1;
		return v;
	}

	public static function push(a:Varray, v:Value):Int {
		if (a.alength + 1 >= a.avalues.length) {
			var values2 = make(a.avalues.length * 2 + 5);
			blit(a.avalues, 0, values2, 0, a.alength);
			values2[a.alength] = v;
			a.avalues = values2;
		} else {
			a.avalues[a.alength] = v;
		}
		a.alength = a.alength + 1;
		return a.alength;
	}

	public static function remove(a:Varray, equals:Value->Value->Bool, x:Value):Bool {
		var i = indexOf(a, equals, x, 0);
		if (i < 0) return false;
		blit(a.avalues, i + 1, a.avalues, i, a.alength - i - 1);
		a.alength = a.alength - 1;
		return true;
	}

	public static function contains(a:Varray, equals:Value->Value->Bool, x:Value):Bool {
		var i = indexOf(a, equals, x, 0);
		return i >= 0;
	}

	public static function reverse(a:Varray):Void {
		var r = sub(a.avalues, 0, a.alength);
		var i = 0, j = a.alength - 1;
		while (i < j) {
			var v = r[i];
			r[i] = r[j];
			r[j] = v;
			i++;
			j--;
		}
		a.avalues = r;
	}

	public static function set(a:Varray, i:Int, v:Value):Void {
		if (i >= a.alength) {
			if (i >= a.avalues.length) {
				var n1 = i + 5, n2 = a.avalues.length * 2 + 5;
				var values2 = make(n1 > n2 ? n1 : n2);
				blit(a.avalues, 0, values2, 0, a.alength);
				a.avalues = values2;
			}
			a.alength = i + 1;
		}
		a.avalues[i] = v;
	}

	public static function shift(a:Varray):Value {
		if (a.alength == 0) return VNull;
		var v = get(a, 0);
		a.alength = a.alength - 1;
		blit(a.avalues, 1, a.avalues, 0, a.alength);
		return v;
	}

	public static function slice(a:Varray, pos:Int, end:Int):Varray {
		if (pos > a.alength || pos >= end) return create(new Vector(0));
		return create(sub(a.avalues, pos, end - pos));
	}

	// port: OCaml's Array.sort is a heap sort (not stable); the order of equal elements follows it.
	public static function sort(a:Varray, f:Value->Value->Int):Void {
		a.avalues = sub(a.avalues, 0, a.alength);
		ocamlArraySort(f, a.avalues);
	}

	// port: stdlib/array.ml `sort` (heap sort with bottom-up sift), translated directly.
	static function ocamlArraySort(cmp:Value->Value->Int, a:Vector<Value>):Void {
		inline function maxson(l:Int, i:Int):Int {
			var i31 = i + i + i + 1;
			var x = i31;
			if (i31 + 2 < l) {
				if (cmp(a[i31], a[i31 + 1]) < 0) x = i31 + 1;
				if (cmp(a[x], a[i31 + 2]) < 0) x = i31 + 2;
				return x;
			} else if (i31 + 1 < l && cmp(a[i31], a[i31 + 1]) < 0) {
				return i31 + 1;
			} else if (i31 < l) {
				return i31;
			} else {
				throw core.ds.FastThrow.of(new BottomException(i));
			}
		}
		function trickle(l:Int, i:Int, e:Value):Void {
			try {
				while (true) {
					var j = maxson(l, i);
					if (cmp(a[j], e) > 0) {
						a[i] = a[j];
						i = j;
					} else {
						a[i] = e;
						return;
					}
				}
			} catch (b:BottomException) {
				a[b.i] = e;
			}
		}
		function bubble(l:Int, i:Int):Int {
			try {
				while (true) {
					var j = maxson(l, i);
					a[i] = a[j];
					i = j;
				}
			} catch (b:BottomException) {
				return b.i;
			}
			return -1;
		}
		function trickleup(i:Int, e:Value):Void {
			while (true) {
				var father = Std.int((i - 1) / 3);
				if (i == father) throw new haxe.Exception("Assert_failure");
				if (cmp(a[father], e) < 0) {
					a[i] = a[father];
					if (father > 0) {
						i = father;
					} else {
						a[0] = e;
						return;
					}
				} else {
					a[i] = e;
					return;
				}
			}
		}
		var l = a.length;
		var i = Std.int((l + 1) / 3) - 1;
		while (i >= 0) {
			trickle(l, i, a[i]);
			i--;
		}
		var i = l - 1;
		while (i >= 2) {
			var e = a[i];
			a[i] = a[0];
			trickleup(bubble(i, 0), e);
			i--;
		}
		if (l > 1) {
			var e = a[1];
			a[1] = a[0];
			a[0] = e;
		}
	}

	public static function splice(a:Varray, pos:Int, len:Int, end:Int):Varray {
		var values2 = new Vector<Value>(len);
		for (i in 0...len) {
			var j = pos + i;
			if (j < 0 || j >= a.avalues.length) throw new haxe.Exception("Invalid_argument(\"index out of bounds\")");
			values2[i] = a.avalues[j];
		}
		blit(a.avalues, pos + len, a.avalues, pos, a.alength - end);
		a.alength = a.alength - len;
		return create(values2);
	}

	public static function unshift(a:Varray, v:Value):Void {
		if (a.alength + 1 >= a.avalues.length) {
			var values2 = make(a.avalues.length * 2 + 5);
			blit(a.avalues, 0, values2, 1, a.alength);
			a.avalues = values2;
		} else {
			blit(a.avalues, 0, a.avalues, 1, a.alength);
		}
		a.avalues[0] = v;
		a.alength = a.alength + 1;
	}

	public static function resize(a:Varray, l:Int):Void {
		if (a.alength < l) {
			set(a, l - 1, VNull);
		} else if (a.alength > l) {
			for (i in l...a.alength) a.avalues[i] = VNull;
			a.alength = l;
		}
	}
}

private class BottomException extends haxe.Exception {
	public final i:Int;

	public function new(i:Int) {
		super("Bottom");
		this.i = i;
	}
}
