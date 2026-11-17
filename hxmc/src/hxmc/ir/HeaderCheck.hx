package hxmc.ir;

import core.TType;
import hxmc.ir.CInterop;

using core.TFunctions;

// The header check (docs/interop.md, "Checking declarations against the
// headers"): -D hxmc.header-check=<file> writes the program's C declarations
// that name their headers (@:hxmc.header on the field or its class) and the
// @:hxmc.struct classes with a C name (@:hxmc.cname) as C++ assertions over
// the target's real headers: each function's arity, each parameter's and
// the result's kind and size (an integer of 4 bytes, a pointer, a span's
// element, a struct by its name), each struct's size and its fields'
// offsets and sizes. `zig c++ -target <triple> -fsyntax-only` compiles
// it (make native-check NATIVE=header, hxmc/test/HeaderCheck.hx): a declaration that
// disagrees with C fails there. C++ only for its type traits (clang's
// builtins, -nostdinc++: no C++ library wraps the C headers); the
// declarations are C's.
class HeaderCheck {
	public static var on = false;

	static var headers:Array<String> = [];
	static var funcs:Array<String> = [];
	static var structs = new Map<String, TClass>();
	static var seen = new Map<String, Bool>();

	public static function start(path:Null<String>) {
		on = path != null;
		headers = [];
		funcs = [];
		structs = new Map();
		seen = new Map();
	}

	static function strings(name:String, ml:core.Ast.Metadata):Array<String> {
		var r = [];
		for (m in ml)
			if (core.Meta.metaEq(Custom(name), m.meta))
				for (e in m.exprs)
					switch e.expr {
						case EConst(core.Ast.Constant.String(s, _)): r.push(s);
						case _:
					}
		return r;
	}

	// the C name of a struct, or null (@:hxmc.cname("struct timespec"))
	public static function cname(c:TClass):Null<String> {
		var n = strings(":hxmc.cname", c.clMeta);
		return n.length > 0 ? n[0] : null;
	}

	// a C function declared (CInterop.declare): its assertions, when it names its headers
	public static function declare(sym:String, c:TClass, cf:TClassField, s:TSignature, sig:CSig, p:CPlan) {
		var hs = strings(":hxmc.header", c.clMeta).concat(strings(":hxmc.header", cf.cfMeta));
		if (hs.length == 0 || StringTools.startsWith(sym, CInterop.INDIRECT)) return;
		var name = CInterop.cName(c, cf);
		// (an assembler name, stat$INODE64: no C identifier)
		if (name == null || name.indexOf("$") >= 0) return;
		for (h in hs)
			if (headers.indexOf(h) < 0) headers.push(h);
		var conds = strings(":hxmc.cif", c.clMeta).concat(strings(":hxmc.cif", cf.cfMeta));
		var what = CInterop.posOf(cf.cfPos) + ": " + name;
		var F = 'hxmc_check::fn<decltype(::$name)>';
		var out = [];
		if (conds.length > 0) out.push("#if " + [for (k in conds) "(" + k + ")"].join(" && "));
		var va = FnLower.C_VARIADIC.get(sym);
		var fixed = va != null ? va : sig.args.length;
		out.push('static_assert($F::n == $fixed && $F::va == ${va != null}, "$what: ${fixed} parameters${va != null ? " and ..." : ""}");');
		// the C arguments, in order, with what the Haxe declaration says of each
		var k = 0;
		for (i in 0...s.args.length) {
			var pn = s.args[i].name;
			inline function arg(test:String, says:String) {
				if (k < fixed) out.push('static_assert($test, "$what: parameter ${k + 1} ($pn) is $says");');
				k++;
			}
			inline function A():String
				return '$F::template arg<$k>';
			switch p.args[i] {
				case ASpan | ASpanPtr(_):
					var sp = KernelCheck.spanOf(s.args[i].type);
					var et = CInterop.ctype(sp.elem);
					// (a minimum length: C's type fits in it)
					switch p.args[i] {
						case ASpanPtr(_, min) if (min > 0):
							var bytes = min * CInterop.sizeOf(et);
							out.push('static_assert(hxmc_check::fits<${A()}, ' + bytes + '>(), "$what: ' + pn + ' (' + bytes + ' bytes) holds what C writes there");');
						case _:
					}
					// (C reads a struct per element the length counts: of the element's
					// size; a constant minimum holds one, as fits checks)
					var exact = !p.args[i].match(ASpanPtr(-1, _ > 0 => true));
					arg('hxmc_check::span<${A()}, ${element(et, exact)}>()', "a pointer to " + described(et));
					switch p.args[i] {
						case ASpan: arg('hxmc_check::word<${A()}>()', "a size_t (the length of " + pn + ")");
						case _:
					}
				case ACallback:
					arg('hxmc_check::pointer<${A()}>()', "a function pointer");
				case AOut(_):
					arg('hxmc_check::pointer<${A()}>()', "a pointer (a T ** of an hxmc.Out)");
				case AIface(_):
					arg('hxmc_check::pointer<${A()}>()', "a pointer (an IFoo *)");
				case AString:
					arg('hxmc_check::cstring<${A()}>()', "a C string (char *)");
				case _ if (CInterop.isSize(s.args[i].type)):
					arg('hxmc_check::word<${A()}>()', "a size_t");
				case _:
					var ct = sig.args[k];
					arg(test(A(), ct), described(ct));
			}
		}
		var R = '$F::ret';
		if (p.str)
			out.push('static_assert(hxmc_check::cstring<$R>(), "$what: the result is a C string (char *)");');
		else if (p.ret >= 0) {
			var et = CInterop.ctype(KernelCheck.spanOf(s.ret).elem);
			out.push('static_assert(hxmc_check::span<$R, ${element(et, true)}>(), "$what: the result is a pointer to ${described(et)}");');
		} else
			out.push('static_assert(${test(R, sig.ret)}, "$what: the result is ${described(sig.ret)}");');
		if (conds.length > 0) out.push("#endif");
		// (each declaration of a symbol checked: two classes may declare it differently)
		var text = out.join("\n");
		if (seen.exists(text)) return;
		seen.set(text, true);
		funcs.push(text);
		for (ct in sig.args.concat([sig.ret]))
			note(ct);
		for (a in s.args) {
			var sp = KernelCheck.spanOf(a.type);
			if (sp != null) note(CInterop.ctype(sp.elem));
		}
	}

	// a struct named in a checked declaration: its layout checked too
	static function note(ct:CTy)
		switch ct {
			case CStruct(c) if (cname(c) != null && !structs.exists(cname(c))):
				structs.set(cname(c), c);
				for (f in CInterop.layout(c).fields)
					note(f.ty);
			case _:
		}

	// exact: a struct pointee has the scalar's size (C reads the span's count
	// of them), or is a struct sockaddr of a span of bytes
	static function element(ct:CTy, exact:Bool):String
		return switch ct {
			case CStruct(c) if (cname(c) != null): cname(c);
			case _: 'hxmc_check::scalar<${CInterop.sizeOf(ct)}, ${exact}>';
		}

	static function described(ct:CTy):String
		return switch ct {
			case CStruct(c): cname(c) != null ? cname(c) + " by value" : "a struct of " + CInterop.sizeOf(ct) + " bytes";
			case CPtr: "a pointer";
			case CF32 | CF64: "a float of " + CInterop.sizeOf(ct) + " bytes";
			case CVoid: "void";
			case _: "an integer of " + CInterop.sizeOf(ct) + " bytes";
		}

	static function test(t:String, ct:CTy):String
		return switch ct {
			case CVoid: '__is_void($t)';
			case CPtr: 'hxmc_check::pointer<$t>()';
			case CF32 | CF64: 'hxmc_check::floating<$t, ${CInterop.sizeOf(ct)}>()';
			case CStruct(c) if (cname(c) != null): '__is_same(__remove_cv($t), ${cname(c)})';
			case CStruct(_): 'hxmc_check::size<$t>() == ${CInterop.sizeOf(ct)}';
			case _: 'hxmc_check::integer<$t, ${CInterop.sizeOf(ct)}>()';
		}

	static function structChecks(name:String, c:TClass):String {
		var l = CInterop.layout(c);
		var at = CInterop.posOf(c.clPos) + ": " + c.clPath.name;
		var out = ['static_assert(sizeof($name) == ${l.size}, "$at: $name has ${l.size} bytes");'];
		for (f in l.fields) {
			var cf = c.clFields.get(f.name);
			if (cf != null && Lower.hasMeta(":hxmc.pad", cf.cfMeta)) continue;
			var cn = cf != null ? strings(":hxmc.cname", cf.cfMeta) : [];
			var fn = cn.length > 0 ? cn[0] : f.name;
			out.push('static_assert(offsetof($name, $fn) == ${f.off}, "$at.${f.name}: $fn at offset ${f.off}");');
			out.push('static_assert(${test('decltype((($name *)0)->$fn)', f.ty)}, "$at.${f.name}: $fn is ${described(f.ty)}");');
		}
		return out.join("\n");
	}

	static final PRELUDE = "
struct sockaddr;
namespace hxmc_check {
template<class F> struct fn;
template<class R, class... A> struct fn<R(A...)> {
	using ret = R;
	static constexpr int n = sizeof...(A);
	static constexpr bool va = false;
	template<int i> using arg = __type_pack_element<i, A...>;
};
template<class R, class... A> struct fn<R(A..., ...)> : fn<R(A...)> { static constexpr bool va = true; };
template<class R, class... A> struct fn<R(A...) noexcept> : fn<R(A...)> {};
template<class R, class... A> struct fn<R(A..., ...) noexcept> : fn<R(A..., ...)> {};
template<class T, class = void> struct sized { static constexpr int v = -1; };
template<class T> struct sized<T, decltype(void(sizeof(T)))> { static constexpr int v = sizeof(T); };
template<class T> constexpr int size() { return sized<T>::v; }
template<class T, int N> constexpr bool integer() { return (__is_integral(T) || __is_enum(T)) && size<T>() == N; }
template<class T, int N> constexpr bool floating() { return __is_floating_point(T) && size<T>() == N; }
template<class T> constexpr bool pointer() { return __is_pointer(T) || __is_same(__remove_cv(T), decltype(nullptr)); }
template<class T> constexpr bool word() { return __is_integral(T) && size<T>() == sizeof(void *); }
template<int N, bool exact> struct scalar {};
template<class P, class E> struct pointee { static constexpr bool ok = __is_void(P) || __is_same(P, E); };
template<class P, int N, bool exact> struct pointee<P, scalar<N, exact>> {
	static constexpr bool ok = __is_void(P) || ((__is_class(P) || __is_union(P)) && (!exact || size<P>() == N || size<P>() < 0 || N == 1 && __is_same(P, ::sockaddr)))
		|| ((__is_arithmetic(P) || __is_enum(P) || __is_pointer(P)) && size<P>() == N);
};
template<class T, class E> constexpr bool span() { return __is_pointer(T) && pointee<__remove_cv(__remove_pointer(T)), E>::ok; }
template<class T, int N> constexpr bool fits() { return size<__remove_cv(__remove_pointer(T))>() <= N; }
template<class T> constexpr bool cstring() { return __is_pointer(T) && __is_same(__remove_cv(__remove_pointer(T)), char); }
}
";

	// the assertions, written to path
	public static function write(path:String, target:String) {
		var b = new StringBuf();
		b.add("// hxmc's C declarations for " + target + ", checked against the headers (-D hxmc.header-check)\n");
		b.add("#include <stddef.h>\n");
		for (h in headers)
			b.add(StringTools.startsWith(h, "#") ? h + "\n" : "#include <" + h + ">\n");
		b.add(PRELUDE);
		var names = [for (n in structs.keys()) n];
		names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		for (n in names)
			b.add(structChecks(n, structs.get(n)) + "\n");
		for (f in funcs)
			b.add(f + "\n");
		sys.io.File.saveContent(path, b.toString());
	}
}
