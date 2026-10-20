// Eval's string natives past a string's ends (-D probe=<name>, build.hxml):
// where upstream's read OCaml's bounds-checked strings, Invalid_argument
// ("index out of bounds", String.sub's, Pcre2's), which Eval code cannot
// catch and the compiler reports; elsewhere null, false or nothing.
class Main {
	static function main() {
		var ascii = "abcdef";
		var astral = "hé\u{1F600}xyz";
		var sb = new StringBuf();
		var r = ~/b/;
		var v:Dynamic = try switch haxe.macro.Compiler.getDefine("probe") {
			case "unsafe-end": StringTools.unsafeCodeAt(ascii, 6);
			case "unsafe-negative": StringTools.unsafeCodeAt(ascii, -1);
			case "unsafe-astral": StringTools.unsafeCodeAt(astral, 6);
			case "addsub-past": sb.addSub(ascii, 2, 100); sb.toString();
			case "addsub-start-past": sb.addSub(ascii, 6, 1); sb.toString();
			case "addsub-negative": sb.addSub(astral, -1, 2); sb.toString();
			case "matchsub-negative": r.matchSub(ascii, -1);
			case "matchsub-past": r.matchSub(ascii, 100);
			case "matchsub-negative-end": r.matchSub(ascii, -10, 5);
			case _:
				sb.addSub(ascii, 0, -1);
				sb.addSub(ascii, 6, 0);
				sb.addSub(astral, 3, null);
				sb.addSub(astral, 1, 2);
				[
					StringTools.fastCodeAt(ascii, 6), StringTools.fastCodeAt(ascii, -1), StringTools.fastCodeAt(astral, 6),
					StringTools.unsafeCodeAt(astral, 5), ascii.charCodeAt(6), ascii.substr(-10, 3), ascii.substr(10), ascii.substring(-3, 100),
					r.matchSub(ascii, 0, 100), sb.toString()
				];
		} catch (e:Dynamic) "caught " + e;
		Sys.println(v);
	}
}
