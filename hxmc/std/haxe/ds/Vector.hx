/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package haxe.ds;

private typedef VectorData<T> = hxmc.NativeArray<T>;

/**
	A fixed-size vector backed by specialized native storage on hxmc.

	Int, Float, Int64, Bool and hxmc.Byte (one byte) elements are unboxed. Indices must be in
	0...length; out of bounds, `-D hxmc.native-array-outofbounds` decides:
	not tested when not defined, `throws` (haxe.exceptions.ArgumentException),
	`silent` (a read gives the default value, a write does nothing).
	Vector<Dynamic> (and Vector<Any>) sees any vector; a vector taken as a
	typed one from Dynamic or from generic code must have that element type,
	or an error is thrown there (as on HL and the JVM). A vector made in
	generic code takes the type of its first typed view (hxmc.NativeArray).
	Empty vectors are shared, one per element type.
**/
abstract Vector<T>(VectorData<T>) {
	/** Creates a vector initialized with zero, false or null elements. **/
	extern overload public inline function new(length:Int) {
		this = new hxmc.NativeArray<T>(length);
	}

	/** Creates a vector filled with `defaultValue`. **/
	extern overload public inline function new(length:Int, defaultValue:T):Vector<T> {
		this = new hxmc.NativeArray<T>(length);
		this.fill(defaultValue);
	}

	/** Returns the element at `index`; out of bounds: `-D hxmc.native-array-outofbounds`. **/
	@:op([]) public inline function get(index:Int):T
		return this[index];

	/** Sets the element at `index`; out of bounds: `-D hxmc.native-array-outofbounds`. **/
	@:op([]) public inline function set(index:Int, val:T):T
		return this[index] = val;

	public var length(get, never):Int;
	inline function get_length():Int return this.length;

	/** Sets every element to `value`. **/
	public inline function fill(value:T):Void
		this.fill(value);

	/** Copies `len` elements, supporting overlapping ranges (hxmc.NativeArray.blit). **/
	public static inline function blit<T>(src:Vector<T>, srcPos:Int, dest:Vector<T>, destPos:Int, len:Int):Void
		hxmc.NativeArray.blit(src.toData(), srcPos, dest.toData(), destPos, len);

	/** Returns a shallow Array copy; it does not share this vector's storage. **/
	public inline function toArray():Array<T>
		return this.toArray();

	/** Returns the underlying NativeArray without copying. **/
	public inline function toData():VectorData<T>
		return this;

	/** Wraps a NativeArray without copying; null remains null. **/
	public static inline function fromData<T>(data:VectorData<T>):Vector<T>
		return cast data;

	/** Creates a vector with a shallow copy of `array`. **/
	public static inline function fromArrayCopy<T>(array:Array<T>):Vector<T>
		return fromData(hxmc.NativeArray.fromArray(array));

	/** Returns a shallow vector copy with the same element layout. **/
	extern public inline function copy():Vector<T>
		return fromData(this.copy());

	public inline function join(sep:String):String {
		var b = new StringBuf();
		for (i in 0...length) {
			b.add(Std.string(this.unsafeGet(i)));
			if (i < length - 1) b.add(sep);
		}
		return b.toString();
	}

	/** Creates a vector by applying `f` to each element in order. **/
	extern public inline function map<S>(f:T->S):Vector<S> {
		var result = new hxmc.NativeArray<S>(length);
		for (i in 0...length) result.unsafeSet(i, f(this.unsafeGet(i)));
		return fromData(result);
	}

	/** Sorts the elements in place, preserving aliases of the native storage. **/
	public inline function sort(f:T->T->Int):Void {
		var array = this.toArray();
		array.sort(f);
		for (i in 0...length) this.unsafeSet(i, array[i]);
	}
}
