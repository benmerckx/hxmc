package unit;

import core.Ast;

// port: markup literals, whose braces -D hxmc.markup-braces reads as JSX's (Lexer.markupEnd's divergence)
class MarkupTest {
	public static function main():Void {
		for (xml in [
			"<x />",
			"<x y={a < b} />",
			"<x y={a < x} />",
			"<x y={a<b} z={c <= d} />",
			"<x y={a > b} />",
			"<x y={() -> <y />} />",
			"<x y={{a: 1}} />",
			"<x y=\"a > b\" />",
			"<x a=\" </x>",
			"<x y={a < b}>{a < b}</x>",
			"<x>{a < x}</x>",
			"<x>{\n\tfor (i in 0...n) <li>{i}</li>\n}</x>",
			"<x><x /><x>a</x></x>",
			"<ul>{items.map(i -> <li key={i}>{i < 3 ? <b>{i}</b> : <i>{i}</i>}</li>)}</ul>",
			"<x>a < b</x>",
			"<></>",
			"<><x /><>a</></>",
			"<style>a { color: red }</style>",
			"<x y={f(\"}\", <b title=\"}{\">a } b</b>)} />",
			"<x y={f(<i>it's</i>)} />",
			"<x y={'a${\"'\"}b'} />",
			"<x y={/* } */ 1} z={1 // }\n} />",
			"<x y={i -> i < 1 ? <b /> : <i>{i<2 ? 1 : 2}</i>} />",
			"<x y={if (a < b) <i>it's</i> else <b />} />",
			"<x y={new Array<Int>().length} z={1 << i} />",
			"<x y={i -> {var v = <b>{i}</b>; v;}} />",
			"<x y={function(i) return <b>{i}</b>} />",
			"<x>{'}'}</x>",
			"<x>{\"</x>\"}</x>",
			"<x if(a < b) />",
			"<x(a < b, [c]) if (d < e) y=\"see (a\" />",
			"<x>\n\tfor (y in ys) {\n\t\t<c(y < 2)/>\n\t}\n\t${ for (i in 0...n) <b src={i}/> }\n</x>"
		]) equal(markup(xml), xml);
		for (xml in ["<x y={a} ", "<x>{</x>", "<x><x></x>", "<x y={'a} />", "<x y={/* a} />"])
			equal(try markup(xml) catch (_:Dynamic) null, null);
		// without the define, as upstream: the `<` in braces leaves the opening tag
		equal(try markup("<x y={a < b} />", false) catch (_:Dynamic) null, null);
		equal(markup("<x y={a < b} /></x>", false), "<x y={a < b} /></x>");
	}

	static function markup(xml:String, braces = true):String {
		var source = "class M { function f() return " + xml + "; }";
		var defines = core.Define.emptyDefines();
		if (braces) core.Define.rawDefine(defines, "hxmc.markup_braces");
		return switch GrammarTest.parse(source, defines).declarations[0].definition {
			case EClass({data: [{cffKind: FFun({fExpr: e})}]}): find(e);
			case _: throw "No function in: " + source;
		}
	}

	static function find(e:Expr):String return switch e.expr {
		case EMeta({meta: core.Meta.Markup}, {expr: EConst(String(s, _))}): s;
		case EReturn(e) | EMeta(_, e): find(e);
		case _: throw "No markup";
	}

	static function equal<T>(a:T, b:T):Void if (a != b) throw 'Expected $b, got $a';
}
