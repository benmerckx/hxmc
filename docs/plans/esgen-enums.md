# Enums in the ES generator's TypeScript

Status: B3 is implemented, for JavaScript and TypeScript (see "As implemented"). The designs below were
prototyped first; each compiles with `tsc --strict` (no null checks, `erasableSyntaxOnly`) and runs under
node's type stripping.

## Goals

1. **Type safe.** A match narrows: `switch (e[index])` with `case 2:` gives `e.r` its type, with no
   `as any`. An impossible case or a read before narrowing is a type error. Construction checks
   arity and arguments, including type arguments and a GADT's result type.
2. **Declarative.** The enum is written once, in a form a TypeScript-to-Haxe parser could turn back
   into `enum Color { Red; Green; Rgb(r:Int, g:Int, b:Int); }`: the constructors in order, their
   parameters' names and types, and a GADT constructor's result.

## What the output had before

```ts
export class Color extends $hx.EnumValue {
	static Red = new class Red extends Color {}();
	static Rgb = $hx.ctor(class Rgb extends Color { declare r: number; …; constructor(r: number, …) { super(); this.r = r; … } });
	static { $hx.defineEnum(Color, ["Red", "Green", "Rgb"]); }
}
```

The type `Color` is the base class. A match reads parameters as `(e as any).r`, and TypeScript
doesn't narrow. `$hx.ctor` makes a constructor callable without `new`, at about twice the cost of
`new`, and it loses a generic constructor's type arguments (`Some(x)` is a `Some<unknown>`).

## What TypeScript needs (found by probing)

- **A discriminant per constructor and a union type.** Each constructor's type declares
  `readonly [index]: 2`, and the enum's type is the union of those types.
- **The index key must be a plain identifier.** TypeScript narrows on `e[index]` only where `index`
  is an identifier bound to a `unique symbol`. `e[$hx.index]` doesn't narrow, and
  `const k = $hx.index` widens to plain `symbol`. So the runtime exports
  `export const index: unique symbol = Symbol.for("haxe.index")`, and TypeScript output imports it.
  JavaScript output can keep `$hx.index`.
- **One name can carry three declarations.** A `const` (the value), a `type` (the union) and a
  type-only `declare namespace` (the constructors' types) can all be called `Color`. This compiles,
  and node strips all of it.
- **Constructor types can't come from the value.** A constructor class can't use the enum's union
  in its own fields (`Add(a:Expr<Int>, …)`) when that union is derived from the class's value
  (`InstanceType<typeof Expr.Add>`): the types become circular. So the constructors' types are
  either class declarations or interfaces.
- **Parameter names don't exist at the type level.** No type operator turns a signature's parameter
  names into object keys. So what a match reads by name (`e.r`) has to be declared by name,
  separately from the constructor's signature.
- **Speed** (5M constructions plus a match, each design on its own):

  | Construction | Time |
  | --- | --- |
  | `new` of a class, or of a plain `function` | 11 ms |
  | `$hx.ctor` wrapper (today's call form) | 25 ms |
  | Arity-specialized runtime constructors (keys in closures) | 45 ms |
  | A generic runtime loop over the parameter names (design B) | 161 ms |
  | Object literals with `__proto__` | 298 ms |

  So a constructor's code has to be written out by the generator, and construction uses `new`.
  The generator can still do that for a constructor used as a value: `xs.map(Some)` becomes
  `xs.map((v) => new Option.Some(v))`.

## Designs tried

The same test runs against each design: matches as Haxe's matcher writes them, an exhaustive
`never` default, `Option<T>` mapping, a GADT evaluator, and five constructs that must not compile.
Designs A2, B, B2 and B3 pass it. A as written fails `tsc`, for the circularity and generics reasons
above.

### A2: constructor classes at the top level

```ts
export class Color$Rgb extends EnumValue {
	declare readonly [index]: 2;
	declare readonly r: Int; declare readonly g: Int; declare readonly b: Int;
	constructor(r: Int, g: Int, b: Int) { super(); this.r = r; this.g = g; this.b = b; }
}
export type Color = Color$Red | Color$Green | Color$Rgb;
export const Color = enumOf("Color", { Red: new Color$Red(), Green: new Color$Green(), Rgb: Color$Rgb });
```

- **Good:** real classes, as fast as it gets. `new` infers type arguments, and the types are the
  classes themselves, so nothing is written twice.
- **Bad:** the enum is spread over several declarations. A GADT's result types exist only in the
  union alias. The constructor classes take module-level names (`Color$Rgb`), so the runtime has
  to rename them.

### B and B2: types are the declaration, the runtime builds the values

```ts
export const Color: {
	readonly Red: Color;
	readonly Green: Color;
	Rgb(r: Int, g: Int, b: Int): Color;
} = makeEnum("Color", { Red: [], Green: [], Rgb: ["r", "g", "b"] });
```

B2's annotation is Haxe's enum as written. B differs only in that its constructors return the
constructor's own type. Either way, the runtime builds every value by looping over the parameter
names, which makes construction about 15 times slower. Rejected for that, but B3 builds on it.

### B3: the declaration as a type argument, constructors written out (recommended)

```ts
export const Color = declareEnum<{
	readonly Red: Color;
	readonly Green: Color;
	readonly Rgb: new (r: Int, g: Int, b: Int) => Color;
}>("Color", {
	Red: null,
	Green: null,
	Rgb: function (r, g, b) {
		this.r = r;
		this.g = g;
		this.b = b;
	},
});
export type Color = Color.Red | Color.Green | Color.Rgb;
export declare namespace Color {
	interface Red extends EnumValue { readonly [index]: 0 }
	interface Green extends EnumValue { readonly [index]: 1 }
	interface Rgb extends EnumValue { readonly [index]: 2; readonly r: Int; readonly g: Int; readonly b: Int }
}

export const Expr = declareEnum<{
	readonly IntLit: new (i: Int) => Expr<Int>;
	readonly BoolLit: new (b: Bool) => Expr<Bool>;
	readonly Add: new (a: Expr<Int>, b: Expr<Int>) => Expr<Int>;
	readonly If: new <T>(c: Expr<Bool>, a: Expr<T>, b: Expr<T>) => Expr<T>;
}>("Expr", { IntLit: function (i) { this.i = i; }, … });
export type Expr<T> = (T extends Int ? Expr.IntLit | Expr.Add : never) | (T extends Bool ? Expr.BoolLit : never) | Expr.If<T>;
```

- **Declarative:** the type argument *is* the enum. Its members are the constructors in order: a
  value for a nullary one, a construct signature with named, typed parameters for the others, and
  the result type a GADT needs. The other two pieces (the union, the namespace of interfaces) are
  derived from it mechanically, so a parser would read only the type argument.
  - `Int` and `Float` are aliases of `number` from the runtime, to keep Haxe's distinction.
- **Type safe:** each constructor function's parameters are typed from the declaration, so their
  types aren't repeated. Matches narrow. `new Option.Some(x)` infers `T`. A GADT constructor makes
  the right `Expr<…>`. Wrong arity, wrong type arguments, impossible cases and un-narrowed reads
  are all type errors.
- **Fast:** each constructor is a plain `function` used with `new`, as fast as a class: 11 ms.
- **Readable at run time:** the constructors keep their own names (`Rgb`), and
  `instanceof EnumValue` works.
- **Its JavaScript (types stripped) is shorter than today's:**
  `export const Color = declareEnum({ Red: null, Green: null, Rgb: function (r, g, b) { this.r = r; this.g = g; this.b = b; } });`.
  So the JavaScript output could take this form too: no class per constructor, no `$hx.ctor`
  wrapper, and `$hx.defineEnum` folds into `declareEnum`.
- **Costs:**
  - Each constructor's fields appear twice: in the declaration's signature and in its interface.
    Both are generated.
  - The constructors must be `function` expressions (methods and arrows can't be constructed),
    with `this: any`, which is harmless since they only assign.
  - Construction is always `new`; a constructor used as a value becomes an arrow at the use site.

## As implemented

- **Runtime:** `$hx.declareEnum(spec, meta)` replaces `$hx.ctor` and `$hx.defineEnum`. An enum is
  an object of its constructors. Each constructor's prototype holds its index and its enum (`$hx.enumOf`),
  and the object lists its constructors (`$hx.constructs`), and its path, under `$hx.name` in the spec, where the program reads it. A nullary constructor's value is made by
  the runtime. `_hx.ts` exports `index` as a binding of its own (`typeof Hx.index`), and a module that
  matches or declares an enum imports it. JavaScript keeps `$hx.index`.
- **Construction:** `new E.C(args)`. A constructor used as a value becomes an arrow that constructs
  (`(v) => new Option.Some(v)`). Reflection: `Reflect.field` and `Reflect.getProperty` return such
  an arrow for a constructor, `Reflect.callMethod` and `Type.createEnum` use `new`.
- **TypeScript types** (`Ts.enumTypes`):
  - the declaration (the type argument): a nullary constructor's value type, the others' construct
    signatures, with the enum's type parameters (only those it names) and the constructor's own;
  - the union alias, `null` for an empty enum (its only value);
  - the namespace of interfaces, one per constructor, with `readonly [index]: N` and the arguments by name.
    An interface takes the enum's type parameters and those of its own that its result doesn't fix (`If<T>(…):Expr<T>`
    is the enum's `T`). An interface is renamed with `$` where a type its fields name would
    otherwise resolve to it (`Array`, a sibling constructor).
  - GADT: a constructor whose result has other arguments is in the union as
    `([T] extends [Int] ? E.IntLit<T> : never)`.
- **Narrowing** (Lower): an argument is read as `e.r` where a test on the index of a local (`if`,
  `switch`, `&&`, or a copy of such a local) established the constructor, the way TypeScript tracks it.
  Elsewhere it is read as `(e as any).r`. That covers a value Haxe knows through a GADT's type, which
  TypeScript doesn't narrow. Haxe's matcher sometimes repeats a test that an enclosing one has already
  decided. TypeScript rejects that as "no overlap" or "not comparable", so such a test reads the index
  of `(e as any)`. A GADT's value whose type a match refined (`Expr<C>` known as `Expr<Float>`) is
  read as `any`, and so are the results a match returns (`i as T`).
- **Results:**
  - the jsgen cases: `tsc` 0 errors, the same output under node;
  - arma desktop: the 4 errors it had before;
  - JavaScript (es, es-modules): the cases and the unit suite pass as before.

## Deriving the declaration from the types

The interfaces aren't derived from the declaration, or the other way round. An interface needs the
arguments' names, and a type has no access to a signature's parameter names. A construct signature
needs them in order, and an object type's keys have none. A pair encoding
(`Rgb: [["r", Int], ["g", Int], ["b", Int]]`) could produce both. It loses a constructor's own type parameters
(`If<T>`), though, and it reads less like Haxe's enum. So both are written out, from the same Haxe
constructors.

## Open questions

- **Equality and `Type.enumEq`** are untouched by this.
- **Reflection** (`Type.getEnum`, `Type.createEnum`, `Type.enumParameters`) reads the
  constructor's link on the prototype (`declareEnum` sets it) and its parameters by
  `Object.keys`, as now.
- **`Type.createEnum` with `null` arguments** under construct-only constructors: the same, through
  `new`.
- **TypeScript's own `enum` syntax** is not an option: it isn't erasable, and it has no payloads.
