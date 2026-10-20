// hxmc: haxe/upstream/std/Type.hx over runtime type information (hxmc.Native)

import hxmc.Native;

/**
	The different possible runtime types of a value.
**/
enum ValueType {
	TNull;
	TInt;
	TInt64;
	TFloat;
	TBool;
	TObject;
	TFunction;
	TClass(c:Class<Dynamic>);
	TEnum(e:Enum<Dynamic>);
	TUnknown;
}

/**
	The Haxe Reflection API allows retrieval of type information at runtime.

	This class complements the more lightweight Reflect class, with a focus on
	class and enum instances.

	@see https://haxe.org/manual/types.html
	@see https://haxe.org/manual/std-reflection.html
**/
class Type {
	/**
		Returns the class of `o`, if `o` is a class instance.

		If `o` is null or of a different type, null is returned.

		In general, type parameter information cannot be obtained at runtime.
	**/
	public static function getClass<T>(o:T):Null<Class<T>>
		return Native.getClass(o);

	/**
		Returns the enum of enum instance `o`.

		An enum instance is the result of using an enum constructor. Given an
		`enum Color { Red; }`, `getEnum(Red)` returns `Enum<Color>`.

		If `o` is null, null is returned.

		In general, type parameter information cannot be obtained at runtime.
	**/
	public static function getEnum(o:EnumValue):Null<Enum<Dynamic>>
		return Native.getEnum(o);

	/**
		Returns the super-class of class `c`.

		If `c` has no super class, null is returned.

		If `c` is null, the result is unspecified.

		In general, type parameter information cannot be obtained at runtime.
	**/
	public static function getSuperClass(c:Class<Dynamic>):Null<Class<Dynamic>>
		return Native.superClass(c);

	/**
		Returns the name of class `c`, including its path.

		If `c` is inside a package, the package structure is returned dot-
		separated, with another dot separating the class name:
		`pack1.pack2.(...).packN.ClassName`
		If `c` is a sub-type of a Haxe module, that module is not part of the
		package structure.

		If `c` has no package, the class name is returned.

		If `c` is null, the result is unspecified.

		The class name does not include any type parameters.
	**/
	public static function getClassName(c:Class<Dynamic>):String
		return Native.typeName(c);

	/**
		Returns the name of enum `e`, including its path.

		If `e` is inside a package, the package structure is returned dot-
		separated, with another dot separating the enum name:
		`pack1.pack2.(...).packN.EnumName`
		If `e` is a sub-type of a Haxe module, that module is not part of the
		package structure.

		If `e` has no package, the enum name is returned.

		If `e` is null, the result is unspecified.

		The enum name does not include any type parameters.
	**/
	public static function getEnumName(e:Enum<Dynamic>):String
		return Native.typeName(e);

	/**
		Resolves a class by name.

		If `name` is the path of an existing class, that class is returned.

		Otherwise null is returned.

		If `name` is null or the path to a different type, the result is
		unspecified.

		The class name must not include any type parameters.
	**/
	public static function resolveClass(name:String):Null<Class<Dynamic>> {
		var t = Native.resolveType(name);
		return t != null && Native.enumCtorNames(t) == null ? t : null;
	}

	/**
		Resolves an enum by name.

		If `name` is the path of an existing enum, that enum is returned.

		Otherwise null is returned.

		If `name` is null the result is unspecified.

		If `name` is the path to a different type, null is returned.

		The enum name must not include any type parameters.
	**/
	public static function resolveEnum(name:String):Null<Enum<Dynamic>> {
		var t = Native.resolveType(name);
		return t != null && Native.enumCtorNames(t) != null ? t : null;
	}

	/**
		Creates an instance of class `cl`, using `args` as arguments to the
		class constructor.

		This function guarantees that the class constructor is called.

		Default values of constructors arguments are not guaranteed to be
		taken into account.

		If `cl` or `args` are null, or if the number of elements in `args` does
		not match the expected number of constructor arguments, or if any
		argument has an invalid type,  or if `cl` has no own constructor, the
		result is unspecified.

		In particular, default values of constructor arguments are not
		guaranteed to be taken into account.
	**/
	public static function createInstance<T>(cl:Class<T>, args:Array<Dynamic>):T
		throw "Type.createInstance is not supported on hxmc";

	/**
		Creates an instance of class `cl`.

		This function guarantees that the class constructor is not called.

		If `cl` is null, the result is unspecified.
	**/
	public static function createEmptyInstance<T>(cl:Class<T>):T
		return Native.createEmpty(cl);

	/**
		Creates an instance of enum `e` by calling its constructor `constr` with
		arguments `params`.

		If `e` or `constr` is null, or if enum `e` has no constructor named
		`constr`, or if the number of elements in `params` does not match the
		expected number of constructor arguments, or if any argument has an
		invalid type, the result is unspecified.
	**/
	public static function createEnum<T>(e:Enum<T>, constr:String, ?params:Array<Dynamic>):T {
		var names = Native.enumCtorNames(e);
		var i = names.indexOf(constr);
		if (i < 0) throw "No such constructor " + constr;
		return Native.enumCreate(e, i, params);
	}

	/**
		Creates an instance of enum `e` by calling its constructor number
		`index` with arguments `params`.

		The constructor indices are preserved from Haxe syntax, so the first
		declared is index 0, the next index 1 etc.

		If `e` or `constr` is null, or if enum `e` has no constructor named
		`constr`, or if the number of elements in `params` does not match the
		expected number of constructor arguments, or if any argument has an
		invalid type, the result is unspecified.
	**/
	public static function createEnumIndex<T>(e:Enum<T>, index:Int, ?params:Array<Dynamic>):T
		return Native.enumCreate(e, index, params);

	/**
		Returns a list of the instance fields of class `c`, including
		inherited fields.

		This only includes fields which are known at compile-time. In
		particular, using `getInstanceFields(getClass(obj))` will not include
		any fields which were added to `obj` at runtime.

		The order of the fields in the returned Array is unspecified.

		If `c` is null, the result is unspecified.
	**/
	public static function getInstanceFields(c:Class<Dynamic>):Array<String>
		return Native.instanceFields(c);

	/**
		Returns a list of static fields of class `c`.

		This does not include static fields of parent classes.

		The order of the fields in the returned Array is unspecified.

		If `c` is null, the result is unspecified.
	**/
	public static function getClassFields(c:Class<Dynamic>):Array<String>
		return Native.classFields(c);

	/**
		Returns a list of the names of all constructors of enum `e`.

		The order of the constructor names in the returned Array is preserved
		from the original syntax.

		If `e` is null, the result is unspecified.
	**/
	public static function getEnumConstructs(e:Enum<Dynamic>):Array<String>
		return Native.enumCtorNames(e).copy();

	/**
		Returns the runtime type of value `v`.

		The result corresponds to the type `v` has at runtime, which may vary
		per platform. Assumptions regarding this should be minimized to avoid
		surprises.
	**/
	public static function typeof(v:Dynamic):ValueType {
		return switch Native.typeKind(v) {
			case 0: TNull;
			case 1: TInt;
			case 2: TFloat;
			case 3: TBool;
			case 4 | 10: TObject;
			case 5: TFunction;
			case 6: TClass(Native.getClass(v));
			case 7: TEnum(Native.getEnum(v));
			case 8: TClass(String);
			case 9: TClass(Array);
			case _: TUnknown;
		}
	}

	/**
		Recursively compares two enum instances `a` and `b` by value.

		Unlike `a == b`, this function performs a deep equality check on the
		arguments of the constructors, if exists.

		If `a` or `b` are null, the result is unspecified.
	**/
	public static function enumEq<T:EnumValue>(a:T, b:T):Bool
		return Native.enumEq(a, b);

	// (hxmc: null throws "Null Access", as Eval and an enum switch do; the
	// runtime reads the value untested: WebAssembly tests it here unless
	// -D hxmc.null-checks=0, the native targets fault there, hxmc.rt.Faults)
	static inline function nullAccess(e:EnumValue) {
		#if (hxmc.null_checks != "0")
		if (hxmc.unsafe.Mem.os() == 3) if (e == null) throw "Null Access";
		#end
	}

	/**
		Returns the constructor name of enum instance `e`.

		The result String does not contain any constructor arguments.

		If `e` is null, the result is unspecified.
	**/
	public static function enumConstructor(e:EnumValue):String {
		nullAccess(e);
		return Native.enumCtorName(e);
	}

	/**
		Returns a list of the constructor arguments of enum instance `e`.

		If `e` has no arguments, the result is [].

		Otherwise the result are the values that were used as arguments to `e`,
		in the order of their declaration.

		If `e` is null, the result is unspecified.
	**/
	public static function enumParameters(e:EnumValue):Array<Dynamic> {
		nullAccess(e);
		return Native.enumParams(e);
	}

	/**
		Returns the index of enum instance `e`.

		This corresponds to the original syntactic position of `e`. The index of
		the first declared constructor is 0, the next one is 1 etc.

		If `e` is null, the result is unspecified.
	**/
	public static function enumIndex(e:EnumValue):Int {
		nullAccess(e);
		return Native.enumIndex(e);
	}

	/**
		Returns a list of all constructors of enum `e` that require no
		arguments.

		This may return the empty Array `[]` if all constructors of `e` require
		arguments.

		Otherwise an instance of `e` constructed through each of its non-
		argument constructors is returned, in the order of the constructor
		declaration.

		If `e` is null, the result is unspecified.
	**/
	public static function allEnums<T>(e:Enum<T>):Array<T> {
		var r = [];
		var names = Native.enumCtorNames(e);
		for (i in 0...names.length) {
			var v:Dynamic = try Native.enumCreate(e, i, null) catch (_:Dynamic) null;
			if (v != null && Native.enumParams(v).length == 0) r.push(v);
		}
		return r;
	}
}
