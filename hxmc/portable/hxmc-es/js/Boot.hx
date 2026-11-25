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

package js;

import js.Syntax; // import it here so it's always available in the compiler

// hxmc: upstream's std/js/Boot.hx for -D hxmc.js=es. Reflection's data is on the classes, under the runtime's
// symbols (`$hx.name`, `$hx.interfaces`, `$hx.properties`, `$hx.staticProperties`); a class's super class is its
// prototype, an object's class its constructor; an interface's value checks `instanceof` itself; an enum is
// an object of its constructors ($hx.declareEnum), a value an instance of one, which knows its enum.
@:dox(hide)
class Boot {
	@:noCompletion public static function __meta(c:Dynamic):Dynamic {
		var t = js.Syntax.typeof(c);
		if (c == null || (t != "function" && t != "object"))
			return null;
		var name:Dynamic = js.Hx.own(c, js.Hx.name);
		if (name == null)
			name = c == js.Syntax.code("String") ? "String" : c == js.Syntax.code("Array") ? "Array" : c == js.Syntax.code("Date") ? "Date" : c == js.Syntax.code("Math") ? "Math" : null;
		var isInterface = js.Hx.own(c, js.Hx.isInterface);
		var interfaces = js.Hx.own(c, js.Hx.interfaces);
		var properties = js.Hx.own(c, js.Hx.properties);
		var statics = js.Hx.own(c, js.Hx.staticProperties);
		if (name == null && isInterface == null && interfaces == null && properties == null && statics == null)
			return null;
		return {name: name, isInterface: isInterface, interfaces: interfaces, properties: properties, statics: statics};
	}

	@:noCompletion public static function __super(c:Dynamic):Dynamic {
		if (js.Syntax.typeof(c) != "function")
			return null;
		var s = js.lib.Object.getPrototypeOf(c);
		return s == js.Syntax.code("Function.prototype") ? null : s;
	}

	@:noCompletion public static function __className(c:Dynamic):Null<String> {
		var m = __meta(c);
		return m == null ? null : m.name;
	}

	@:noCompletion public static function __isInterface(c:Dynamic):Bool {
		return c != null && js.Syntax.typeof(c) == "object" && js.Syntax.strictEq(js.Hx.get(c, js.Hx.isInterface), true);
	}

	@:noCompletion public static inline function __isEnumValue(o:Dynamic):Bool {
		return js.Syntax.instanceof(o, js.Hx.EnumValue);
	}

	// a value's enum (on its constructor's prototype)
	@:noCompletion public static function __enumOf(o:Dynamic):Dynamic {
		return __isEnumValue(o) ? js.Hx.get(o, js.Hx.enumOf) : null;
	}

	// (a `class`: its prototype read-only, where a function's, an enum constructor's too, is writable, and an arrow has none)
	@:noCompletion public static function __isClass(o:Dynamic):Bool {
		if (js.Syntax.typeof(o) != "function")
			return false;
		var d = js.lib.Object.getOwnPropertyDescriptor(o, "prototype");
		return d != null && d.writable == false;
	}

	static inline function isClass(o:Dynamic):Bool {
		return __isClass(o);
	}

	static inline function isInterface(o:Class<Dynamic>):Bool {
		return __isInterface(o);
	}

	// (an enum: an object of its constructors, which lists them)
	static inline function isEnum(e:Dynamic):Bool {
		return e != null && js.Syntax.typeof(e) == "object" && js.Hx.own(e, js.Hx.constructs) != null;
	}

	@:pure static function getClass(o:Null<Dynamic>):Null<Dynamic> {
		if (o == null) {
			return null;
		} else if (Std.isOfType(o, Array)) {
			return Array;
		} else {
			// (not an object's own `constructor`, nor a structure's or Math's and JSON's Object)
			if (__isEnumValue(o))
				return null;
			var cl:Dynamic = o.constructor;
			return js.Syntax.typeof(cl) == "function" && cl != js.lib.Object && cl != js.Syntax.code("Function") ? cl : null;
		}
	}

	@:ifFeature("has_enum")
	private static function __string_rec(o:Dynamic, s:String):String {
		untyped {
			if (o == null)
				return "null";
			if (s.length >= 5)
				return "<...>"; // too much deep recursion
			// (a class too `<function>`)
			var t = js.Syntax.typeof(o);
			switch (t) {
				case "object":
					if (__isEnumValue(o)) {
						var n:String = js.Hx.get(__enumOf(o), js.Hx.constructs)[js.Hx.get(o, js.Hx.index)];
						var params:Array<Dynamic> = js.lib.Object.values(o);
						if (params.length == 0)
							return n;
						s += "\t";
						for (i in 0...params.length)
							params[i] = __string_rec(params[i], s);
						return n + "(" + params.join(",") + ")";
					}
					if (js.Syntax.instanceof(o, Array)) {
						var str = "[";
						s += "\t";
						for (i in 0...o.length)
							str += (if (i > 0) "," else "") + __string_rec(o[i], s);
						str += "]";
						return str;
					}
					var tostr;
					try {
						tostr = untyped o.toString;
					} catch (e:Dynamic) {
						// strange error on IE
						return "???";
					}
					if (tostr != null && tostr != js.Syntax.code("Object.toString") && js.Syntax.typeof(tostr) == "function") {
						var s2 = o.toString();
						if (s2 != "[object Object]")
							return s2;
					}
					var str = "{\n";
					s += "\t";
					for (k in js.lib.Object.keys(o)) {
						if (k == "prototype")
							continue;
						if (str.length != 2)
							str += ", \n";
						str += s + k + " : " + __string_rec(o[k], s);
					}
					s = s.substring(1);
					str += "\n" + s + "}";
					return str;
				case "function":
					return "<function>";
				case "string":
					return o;
				default:
					return String(o);
			}
		}
	}

	@:pure private static function __instanceof(o:Dynamic, cl:Dynamic) {
		if (cl == null)
			return false;
		switch (cl) {
			case Int:
				return js.Syntax.typeof(o) == "number" && js.Syntax.strictEq(o | 0, o);
			case Float:
				return js.Syntax.typeof(o) == "number";
			case Bool:
				return js.Syntax.typeof(o) == "boolean";
			case String:
				return js.Syntax.typeof(o) == "string";
			case Array:
				return js.Syntax.instanceof(o, Array) ;
			case Dynamic:
				return o != null;
			default:
				if (o != null) {
					// Check if o is an instance of a Haxe class or a native JS object
					if (js.Syntax.typeof(cl) == "function" || __isInterface(cl)) {
						if (__downcastCheck(o, cl))
							return true;
					} else if (js.Syntax.typeof(cl) == "object" && __isNativeObj(cl)) {
						if (js.Syntax.instanceof(o, cl))
							return true;
					}
				} else {
					return false;
				}
				untyped __feature__("Class.*", if (cl == Class && __isClass(o)) return true);
				untyped __feature__("Enum.*", if (cl == Enum && isEnum(o)) return true);
				return __enumOf(o) == cl;
		}
	}

	// (an interface's value checks `instanceof` itself)
	static inline function __downcastCheck(o:Dynamic, cl:Class<Dynamic>):Bool {
		return js.Syntax.instanceof(o, cl);
	}

	static inline function __implements(o:Dynamic, iface:Class<Dynamic>):Bool {
		return js.Syntax.instanceof(o, iface);
	}

	@:ifFeature("typed_cast") private static function __cast(o:Dynamic, t:Dynamic) {
		if (o == null || __instanceof(o, t))
			return o;
		else
			throw "Cannot cast " + Std.string(o) + " to " + Std.string(t);
	}

	static final __toStr:js.lib.Function = js.Syntax.code("Object.prototype.toString");

	// get native JS [[Class]]
	static function __nativeClassName(o:Dynamic):String {
		var name:String = __toStr.call(o).slice(8, -1);
		// exclude general Object and Function
		// also exclude Math and JSON, because instanceof cannot be called on them
		if (name == "Object" || name == "Function" || name == "Math" || name == "JSON")
			return null;
		return name;
	}

	// check for usable native JS object
	static function __isNativeObj(o:Dynamic):Bool {
		return __nativeClassName(o) != null;
	}

	// resolve native JS class in the global scope:
	static function __resolveNativeClass(name:String) {
		return js.Lib.global[cast name];
	}
}
