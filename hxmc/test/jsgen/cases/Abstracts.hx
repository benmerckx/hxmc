// abstracts (abstracts/Units.hx): what they do, and what TypeScript's output types them as (docs/js.md, TypeScript): an
// abstract a type of its own, its module's, beside its functions of the same name; branded as Haxe lets values go
// ts: import { Meters, Celsius, Token, Id, Color, Level, Code, Pair } from "./abstracts/Units.ts";
// ts: // (from and to Float: a number)
// ts: const m: Meters = 3;
// ts: const n: number = m;
// ts: // (to Float only)
// ts: declare const c: Celsius;
// ts: const f: number = c;
// ts: // @ts-expect-error
// ts: const c2: Celsius = 3;
// ts: const c3: Celsius = Celsius.warmer(c, 1);
// ts: // (from String only)
// ts: const t: Token = "a";
// ts: declare const t2: Token;
// ts: // @ts-expect-error
// ts: const s: string = t2;
// ts: // (neither)
// ts: declare const i: Id;
// ts: // @ts-expect-error
// ts: const i2: Id = 1;
// ts: // @ts-expect-error
// ts: const k: number = i;
// ts: const i3: Id = Id.next(i);
// ts: // @ts-expect-error
// ts: const i4: Id = c;
// ts: // (an enum abstract, neither: its values, each a type of its own, no number)
// ts: const red: Color = Color.Red;
// ts: // @ts-expect-error
// ts: const zero: Color = 0;
// ts: // @ts-expect-error
// ts: const g: typeof Color.Green = Color.Red;
// ts: // @ts-expect-error
// ts: const rn: number = Color.Red;
// ts: const rs: string = Color.name(Color.Blue);
// ts: // (to Int: a number, its own; a value of it narrowed by its literal)
// ts: const low: number = Level.Low;
// ts: // @ts-expect-error
// ts: const l0: Level = 0;
// ts: declare const lv: Level;
// ts: const hi: 2 = lv === 2 ? lv : 2;
// ts: // (from Int to Int: a number)
// ts: const ok: Code = 7;
// ts: const okn: number = Code.Ok;
// ts: // (generic)
// ts: declare const p: Pair<string>;
// ts: // @ts-expect-error
// ts: const q: Pair<number> = p;
// ts: export { n, f, c3, t, s, k, i2, i3, i4, red, zero, g, rn, rs, low, l0, hi, ok, okn, q };
// ts output has: abstracts/Units.ts: Red: 0 as unknown as { readonly [$brand]: { readonly "abstracts.Color": 0 } },
// ts output has: abstracts/Units.ts: export type Color = { readonly [$brand]: { readonly "abstracts.Color": 0 | 1 | 2 } };
// ts output has: abstracts/Units.ts: Low: 0 as Level & 0,
// ts output has: abstracts/Units.ts: export type Code = number;
// ts output lacks: abstracts/Units.ts: Color.Red =
import abstracts.Units;

class Abstracts {
	static function main() {
		var m:Meters = 1500;
		var c = new Celsius(20).warmer(1.5);
		var t:Token = "abc";
		var i = new Id(41).next();
		var col = Color.Green;
		var lv:Int = Level.High;
		var code:Code = 3;
		var p = new Pair("a", "b");
		var f:Float = c;
		trace(m.km(), f, t.upper(), i.toInt(), col.name(), p.first(), lv, code == Code.Ok);
	}
}
