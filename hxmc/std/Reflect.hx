// hxmc: haxe/upstream/std/Reflect.hx over runtime type information (hxmc.Native)

import hxmc.Native;

/**
	The Reflect API is a way to manipulate values dynamically through an
	abstract interface in an untyped manner. Use with care.

	@see https://haxe.org/manual/std-reflection.html
**/
class Reflect {
	/**
		Tells if structure `o` has a field named `field`.

		This is only guaranteed to work for anonymous structures. Refer to
		`Type.getInstanceFields` for a function supporting class instances.

		If `o` or `field` are null, the result is unspecified.
	**/
	public static function hasField(o:Dynamic, field:String):Bool
		return Native.hasField(o, field);

	/**
		Returns the value of the field named `field` on object `o`.

		If `o` is not an object or has no field named `field`, the result is
		null.

		If the field is defined as a property, its accessors are ignored. Refer
		to `Reflect.getProperty` for a function supporting property accessors.

		If `field` is null, the result is unspecified.
	**/
	public static function field(o:Dynamic, field:String):Dynamic
		return Native.getField(o, field);

	/**
		Sets the field named `field` of object `o` to value `value`.

		If `o` has no field named `field`, this function is only guaranteed to
		work for anonymous structures.

		If `o` or `field` are null, the result is unspecified.
	**/
	public static function setField(o:Dynamic, field:String, value:Dynamic):Void
		Native.setField(o, field, value);

	/**
		Returns the value of the field named `field` on object `o`, taking
		property getter functions into account.

		If the field is not a property, this function behaves like
		`Reflect.field`, but might be slower.

		If `o` or `field` are null, the result is unspecified.
	**/
	public static function getProperty(o:Dynamic, field:String):Dynamic {
		var getter = Native.getField(o, "get_" + field);
		return getter != null && isFunction(getter) ? Native.callMethod(getter, []) : Native.getField(o, field);
	}

	/**
		Sets the field named `field` of object `o` to value `value`, taking
		property setter functions into account.

		If the field is not a property, this function behaves like
		`Reflect.setField`, but might be slower.

		If `field` is null, the result is unspecified.
	**/
	public static function setProperty(o:Dynamic, field:String, value:Dynamic):Void {
		var setter = Native.getField(o, "set_" + field);
		if (setter != null && isFunction(setter)) Native.callMethod(setter, [value]) else Native.setField(o, field, value);
	}

	/**
		Call a method `func` with the given arguments `args`.

		The object `o` is ignored in most cases. It serves as the `this`-context in the following
		situations:

		* (neko) Allows switching the context to `o` in all cases.
		* (macro) Same as neko for Haxe 3. No context switching in Haxe 4.
		* (js, lua) Require the `o` argument if `func` does not, but should have a context.
			This can occur by accessing a function field natively, e.g. through `Reflect.field`
			or by using `(object : Dynamic).field`. However, if `func` has a context, `o` is
			ignored like on other targets.
	**/
	public static function callMethod(o:Dynamic, func:haxe.Constraints.Function, args:Array<Dynamic>):Dynamic
		return Native.callMethod(func, args);

	/**
		Returns the fields of structure `o`.

		This method is only guaranteed to work on anonymous structures. Refer to
		`Type.getInstanceFields` for a function supporting class instances.

		If `o` is null, the result is unspecified.
	**/
	public static function fields(o:Dynamic):Array<String> {
		// (code that runs as Eval's: interpreted, the macro context's, or a Mir host's, EvalCompat)
		#if (hxmc.interp || macro)
		if (hxmc.rt.EvalCompat.on) return hxmc.rt.EvalCompat.fields(Native.fields(o));
		#else
		if (hxmc.unsafe.Mem.mirHost() == 1) {
			if (hxmc.rt.EvalCompat.on) return hxmc.rt.EvalCompat.fields(Native.fields(o));
		}
		#end
		return Native.fields(o);
	}

	/**
		Returns true if `f` is a function, false otherwise.

		If `f` is null, the result is false.
	**/
	public static function isFunction(f:Dynamic):Bool
		return Native.typeKind(f) == 5 || Std.isOfType(f, hxmc.rt.VarArgs);

	/**
		Compares `a` and `b`.

		If `a` is less than `b`, the result is negative. If `b` is less than
		`a`, the result is positive. If `a` and `b` are equal, the result is 0.

		This function is only defined if `a` and `b` are of the same type.

		If that type is a function, the result is unspecified and
		`Reflect.compareMethods` should be used instead.

		For all other types, the result is 0 if `a` and `b` are equal. If they
		are not equal, the result depends on the type and is negative if:

		- Numeric types: a is less than b
		- String: a is lexicographically less than b
		- Other: unspecified

		If `a` and `b` are null, the result is 0. If only one of them is null,
		the result is unspecified.
	**/
	public static function compare<T>(a:T, b:T):Int
		return Native.compare(a, b);

	/**
		Compares the functions `f1` and `f2`.

		If `f1` or `f2` are null, the result is false.
		If `f1` or `f2` are not functions, the result is unspecified.

		Otherwise the result is true if `f1` and the `f2` are physically equal,
		false otherwise.

		If `f1` or `f2` are member method closures, the result is true if they
		are closures of the same method on the same object value, false otherwise.
	**/
	public static function compareMethods(f1:Dynamic, f2:Dynamic):Bool
		return Native.compareMethods(f1, f2);

	/**
		Tells if `v` is an object.

		The result is true if `v` is one of the following:

		- class instance
		- structure
		- `Class<T>`
		- `Enum<T>`

		Otherwise, including if `v` is null, the result is false.
	**/
	public static function isObject(v:Dynamic):Bool {
		var k = Native.typeKind(v);
		return k == 4 || k == 6 || k == 8 || k == 9 || k == 10;
	}

	/**
		Tells if `v` is an enum value.

		The result is true if `v` is of type EnumValue, i.e. an enum
		constructor.

		Otherwise, including if `v` is null, the result is false.
	**/
	public static function isEnumValue(v:Dynamic):Bool
		return Native.typeKind(v) == 7;

	/**
		Removes the field named `field` from structure `o`.

		This method is only guaranteed to work on anonymous structures.

		If `o` or `field` are null, the result is unspecified.
	**/
	public static function deleteField(o:Dynamic, field:String):Bool
		return Native.deleteField(o, field);

	/**
		Copies the fields of structure `o`.

		This is only guaranteed to work on anonymous structures.

		If `o` is null, the result is `null`.
	**/
	public static function copy<T>(o:Null<T>):Null<T>
		return o == null ? null : Native.copyObject(o);

	/**
		Transform a function taking an array of arguments into a function that can
		be called with any number of arguments.
	**/
	@:overload(function(f:Array<Dynamic>->Void):Dynamic {})
	public static function makeVarArgs<T>(f:Array<Dynamic>->T):Dynamic {
		// (hxmc: called by Dyn.dynCall)
		return new hxmc.rt.VarArgs(cast f);
	}
}
