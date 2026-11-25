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
// hxmc: upstream's std/js/_std/Type.hx for -D hxmc.js=es: reflection's data under the runtime's symbols ($hx), enums as classes
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

@:coreApi class Type {
	public static inline function getClass<T>(o:T):Null<Class<T>> {
		return @:privateAccess js.Boot.getClass(o);
	}

	public static function getEnum(o:EnumValue):Null<Enum<Dynamic>>
		untyped {
			if (o == null)
				return null;
			return js.Boot.__enumOf(o);
		}

	public static inline function getSuperClass(c:Class<Dynamic>):Null<Class<Dynamic>> {
		return js.Boot.__super(c);
	}

	public static inline function getClassName(c:Class<Dynamic>):String {
		return js.Boot.__className(c);
	}

	public static inline function getEnumName(e:Enum<Dynamic>):String {
		return js.Hx.get(e, js.Hx.name);
	}

	public static inline function resolveClass(name:String):Null<Class<Dynamic>> {
		return untyped __define_feature__("Type.resolveClass", js.Hx.classes[name]);
	}

	// (a function: the program registers its enums in `$hx.enums` where it refers to it)
	public static function resolveEnum(name:String):Null<Enum<Dynamic>> {
		return js.Hx.enums[name];
	}

	public static function createInstance<T>(cl:Class<T>, args:Array<Dynamic>):T {
		return js.Syntax.code("new {0}(...{1})", cl, args);
	}

	public static inline function createEmptyInstance<T>(cl:Class<T>):T {
		return js.lib.Object.create((cast cl).prototype);
	}

	// (an enum's constructor: a value (none of arguments) or a function, which `new` constructs)
	// (by its index: the constructors are the enum's first values, in order; their keys may be renamed, the names not)
	public static function createEnum<T>(e:Enum<T>, constr:String, ?params:Array<Dynamic>):T {
		var i = (js.Hx.get(e, js.Hx.constructs) : Array<String>).indexOf(constr);
		var f:Dynamic = i < 0 ? null : js.lib.Object.values(cast e)[i];
		if (f == null)
			throw "No such constructor " + constr;
		if (js.Syntax.typeof(f) == "function") {
			if (params == null)
				throw "Constructor " + constr + " need parameters";
			return js.Syntax.code("new {0}(...{1})", f, params);
		}
		if (params != null && params.length != 0)
			throw "Constructor " + constr + " does not need parameters";
		return f;
	}

	public static function createEnumIndex<T>(e:Enum<T>, index:Int, ?params:Array<Dynamic>):T {
		var c:String = js.Hx.get(e, js.Hx.constructs)[index];
		if (c == null)
			throw index + " is not a valid enum constructor index";
		return createEnum(e, c, params);
	}

	// (the methods on the prototypes, the variables the classes list: js.Hx.fields; an interface's value lists all)
	public static function getInstanceFields(c:Class<Dynamic>):Array<String> {
		var result = [];
		if (js.Boot.__isInterface(c))
			return (js.Hx.own(c, js.Hx.fields) : Array<String>) ?? [];
		while (c != null) {
			var vars:Array<String> = js.Hx.own(c, js.Hx.fields);
			if (vars != null)
				for (name in vars)
					if (result.indexOf(name) == -1)
						result.push(name);
			var proto = (cast c).prototype;
			for (name in js.lib.Object.getOwnPropertyNames(proto)) {
				switch name {
					case "constructor":
					// skip special names
					case _ if (accessor(proto, name)):
					// (a property that is a JavaScript accessor: no field)
					case _:
						if (result.indexOf(name) == -1)
							result.push(name);
				}
			}
			c = getSuperClass(c);
		}
		return result;
	}

	public static function getClassFields(c:Class<Dynamic>):Array<String> {
		var a = js.lib.Object.getOwnPropertyNames(cast c);
		a.remove("__meta__");
		a.remove("prototype");
		a.remove("name");
		a.remove("length");
		return a.filter(n -> !accessor(c, n));
	}

	static function accessor(o:Dynamic, name:String):Bool {
		var d = js.lib.Object.getOwnPropertyDescriptor(o, name);
		return d != null && (d.get != null || d.set != null);
	}

	public static inline function getEnumConstructs(e:Enum<Dynamic>):Array<String> {
		return (js.Hx.get(e, js.Hx.constructs) : Array<String>).copy();
	}

	@:access(js.Boot)
	public static function typeof(v:Dynamic):ValueType {
		switch (js.Syntax.typeof(v)) {
			case "boolean":
				return TBool;
			case "string":
				return TClass(String);
			case "number":
				// this should handle all cases : NaN, +/-Inf and Floats outside range
				if (Math.ceil(v) == v % 2147483648.0)
					return TInt;
				return TFloat;
			case "object":
				if (v == null)
					return TNull;
				if (js.Boot.__isEnumValue(v))
					return TEnum(js.Boot.__enumOf(v));
				var c = js.Boot.getClass(v);
				if( c == @:privateAccess haxe.Int64.IMPL )
					return TInt64;
				if (c != null)
					return TClass(c);
				return TObject;
			case "function":
				if (js.Boot.isClass(v) || js.Boot.isEnum(v))
					return TObject;
				return TFunction;
			case "undefined":
				return TNull;
			default:
				return TUnknown;
		}
	}

	public static function enumEq<T:EnumValue>(a:T, b:T):Bool {
		if (a == b)
			return true;
		try {
			var e = js.Boot.__enumOf(a);
			if (e == null || e != js.Boot.__enumOf(b))
				return false;
			if (enumIndex(cast a) != enumIndex(cast b))
				return false;
			var aparams = enumParameters(cast a);
			var bparams = enumParameters(cast b);
			for (i in 0...aparams.length) {
				if (!enumEq(aparams[i], bparams[i])) {
					return false;
				}
			}
		} catch (e:Dynamic) {
			return false;
		}
		return true;
	}

	public static function enumConstructor(e:EnumValue):String {
		return js.Hx.get(js.Boot.__enumOf(e), js.Hx.constructs)[enumIndex(e)];
	}

	// (its arguments: its own fields, in their order)
	public static inline function enumParameters(e:EnumValue):Array<Dynamic> {
		return js.lib.Object.values(cast e);
	}

	public inline static function enumIndex(e:EnumValue):Int {
		return js.Hx.get(e, js.Hx.index);
	}

	public inline static function allEnums<T>(e:Enum<T>):Array<T> {
		return cast js.lib.Object.values(cast e).slice(0, (js.Hx.get(e, js.Hx.constructs) : Array<String>).length).filter(v -> js.Boot.__isEnumValue(v));
	}
}
