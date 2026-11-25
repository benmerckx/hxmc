# Plans: an ES generator

A JavaScript generator of hxmc's own, beside the port of `genjs.ml`. It
replaced the first hxmc modes (`-D hxmc.js=bundled|modules`), which grew out
of Genjs and still made its decisions in its order, and are gone. What it
is now: [docs/js.md](../js.md); this is how it came to be, and what is open.

## Why

The hxmc modes were built as refactors of Genjs that had to keep its output.
The result:

- The tree is Genjs's call graph as data, not JavaScript: nodes for
  features (`JFeature`), traces, binds and helpers. It has layout hints
  for repeating Genjs's text (`JFlatParen`, `JMark`, `bare`), and Haxe
  objects (`TVar`, `TClassField`) where JavaScript has bindings.
- The printer decides what the tree should have decided: arrow or
  `function` (only when minifying), `_gthis` or `this`, names, imports,
  TypeScript types (`ctx.types`, 25 times in `Print`), features.
- `Modules` builds files from strings and finds the helpers a file uses
  by scanning its text.
- The output carries Genjs's runtime as it was: `$hxMeta` records,
  `__name__`, `_hx_index`, `hx__closures__` with `$haxeUID`, lazy statics
  through `$hxLazy`, an IIFE with `$global`, chunks that receive the types
  as `$hxTypes[14]`.

## Goals

In order:

1. **Bundled output first.** One `haxe` call builds a program like arma
   for release: the main file, its splits, source maps, `.d.ts`, minified
   or not. No tool after it.
2. **It runs as it is**, in a browser (`<script type="module">`) and in
   node, without a bundler. Bundlers (esbuild, Rollup, Vite) can take it
   as well, but are never needed.
3. **TypeScript output passes `tsc --strict`.** `// @ts-ignore` is an
   acceptable stop-gap: it is easy to find in the output, and each one is
   a bug to remove.
4. **Output a person would write.** Classes with their statics, arrows,
   `const`, `for...of`, symbols instead of `__magic__` names, `#private`
   for the generator's own state.
5. **Modules output** that is as good, then (not now) as a publishable npm
   package. Until modules prove themselves, bundled output plus `.d.ts` is
   the more realistic way to publish.

What the projects around Genjs solve, and what of it is in scope:

| Use case | Prior art | Here |
| --- | --- | --- |
| lazy loading of parts of a program | haxe-modular (`load(C)`), genes (`dynamicImport`) | `js.Bundle.split` → `import()` (now) |
| one file for a page, no bundler | Genjs, haxe-modular | bundled (now) |
| TypeScript definitions | genes (`-D dts`), hxtsdgen | `.d.ts` (now) |
| TypeScript source | – | `.ts` (now) |
| native accessors for properties | genes | built (`Properties`), kept |
| source maps per file | genes, haxe-modular | now |
| an ES module per Haxe module | genes, hxgenjs (CommonJS, archived) | after bundled |
| untouched files not rewritten | genes (`unchanged_no_rewrite`) | with modules |
| npm packages from Haxe | genes | later, once modules are good |
| hot reload | haxe-modular (`hot`), haxe-loader | later; the design must not rule it out (classes keep their identity) |

## Decided

- **Genjs stays as it is**: the port, compared with upstream. The new
  generator shares nothing with it but the typed AST and `Gctx`.
- **ES2022 and later**: class fields, static fields, `static {}` blocks,
  `#private`, `??`, `?.`. No ES5 shapes, no CommonJS output, no IIFE
  wrapper.
- **No output matching**: Genjs's output is not a reference. What a
  program does is (the tests below); what the output looks like is a goal
  of its own, reviewed as output.
- **Two output units, one AST**: `EsModule` (a Haxe module as an ES
  module) and `EsChunk` (many Haxe modules in one scope: the bundled main
  file, a split). A chunk is built from the lowered modules but is not a
  concatenation of module files: one scope has its own, easier order of
  initialization (see Statics).
- **Lowering is cached per Haxe module**, the compilation server's unit:
  a module's lowered code depends on that module's post-filter types and
  the build's options, nothing else.

## Pipeline

```
TExpr ──Lower──▶ Es, per Haxe module (cached) ──Link──▶ EsChunk / EsModule ──Print──▶ .js / .ts / .d.ts / maps
```

### The AST (`Es`)

JavaScript, nothing else:

- **Declarations**: `import` (named, default, namespace, side effect),
  `export`, `class` (fields, `#private` fields, methods, accessors,
  `static {}`), `function`, `let` and `const`.
- **Statements and expressions**: ESTree's subset that ES2022 needs,
  arrows with an expression or a block body, `import()`, and raw code
  (`js.Syntax.code`: its text with expressions between the parts).
- **Bindings are symbols**: a local, a Haxe type or field (by path), a
  runtime value, a global. Never a string. Names are chosen at link.
- **Types**: Haxe's own types on declarations, parameters and returns
  (a local's symbol, a function, a class member), `as any` where Haxe
  accepted what TypeScript would not, a generic call's type arguments.
  The printer writes them in TypeScript's syntax through `Ts` (the
  mapping is `Dts`'s, a type's name link's, which notes an `import type`);
  which casts and annotations there are is Lower's decision. JavaScript
  output ignores them.
- **Positions**: line and column, resolved when lowering, so the printer's
  source maps are cheap and cached with the tree.

No features, no layout hints, no Haxe constructs.

### Lower

Per Haxe module: its classes, enums and their fields, post-filter, to `Es`.
Everything that depends on the code alone is decided here:

- **Functions**: an arrow unless the function uses its own `this`,
  `super` or `arguments`. `_gthis` is `this` where only arrows use it.
- **Locals**: `const` unless assigned after their declaration.
- **Loops**: the filters' `while` over an array or an `IntIterator` back
  to `for...of` and `for (let i = a; i < b; i++)`, where the loop's body
  does not depend on the difference.
- **Temporaries**: the analyzer's single-use `tmp` and `_g` folded back
  into the expression, where order of evaluation allows.
- **Statements in value position**: in place where they are assigned,
  declared or returned, otherwise temporaries before the expression,
  and an IIFE only as a last resort.
- **Enums**: construction, matching (a `switch` on the index, the
  constructor's name as a comment, parameters destructured), casts,
  binds, `Std.isOfType` to `instanceof` where the type allows it.
- **Summaries**: per field, what link needs, so link never walks trees.
  This covers the symbols it references and how: as a value, as a type
  only, or run at load (called, constructed, read as a static).

### Link

Per build, over the summaries and the typed classes:

- **Placement**: which chunk or module each type goes in, the entry,
  the exports a split needs from the main file.
- **Statics**: where each initializer can go (see Statics).
- **Names**: one table per output. A type is its own name (`Boot`, not
  `js_Boot`), with a fallback only where two names collide in a scope.
  Locals that shadow a type are renamed. Minified names come from the
  same table.
- **Imports**: from the symbols each file references; type-only ones as
  `import type` in `.ts`.
- **Properties, features, reflection**: from the summaries.

### Print

Tree to text, deciding nothing: parentheses by precedence, plain or tight
layout, source maps from the nodes' positions, type annotations when
writing `.ts`.

## Statics

Haxe defines more than the output needs. Its order (`sort_types`) runs a
type after the types its statics' initializers and `__init__` use, and every
`__init__` before every static initializer. Every Genjs program relies on
the first part. Few rely on the second, but some do (`__init__` patching
a class's prototype before anything runs).

The aim is that a static is a static field with its initializer, in its
class. Laziness, or an assignment after the class, is a fallback for a real
cycle and never the default.

- **What "safe" means**: an initializer is safe at a point if the code it
  runs at load only touches types already initialized there. "Runs at
  load" is precise:
  - calls, `new` with the constructor's code and its instance field
    initializers, getters, and reads of other statics;
  - not function literals it only creates;
  - not types it only names as values, which merely need to be declared.

  An instance of the class's own type (`static DEFAULT = new SiteInfo(...)`)
  is safe unless its constructor runs something that isn't initialized.
  Today's analysis walks into closures and makes such statics lazy for
  nothing.
- **`__init__`** is the class's `static {}` block, placed by the same
  rule. An `__init__` that acts on a type (patches its prototype, assigns
  its statics) runs before that type's statics run code.
- **In a chunk** (one scope), link orders the class declarations: supers
  first, then by what initializers run. With nothing else in the way, the
  order is source order. A static that is part of a real cycle is assigned
  after the classes involved. A chunk never needs lazy statics.
- **In modules**, the order between modules is the ES order of the
  imports, which link chooses: in each file, the order of its import
  statements; in the entry, imports placed first. A static still in a
  cycle becomes lazy, backed by a `#private` field with no runtime helper:

  ```js
  static #reporter;
  static #reporterSet = false;
  static get reporter() {
  	if (!CompactLogger.#reporterSet) CompactLogger.reporter = new Reporter();
  	return CompactLogger.#reporter;
  }
  static set reporter(v) {
  	CompactLogger.#reporterSet = true;
  	CompactLogger.#reporter = v;
  }
  ```

  Where the initializer cannot be null (`new`, a literal, a function),
  `#reporter ??= ...` without the flag.
- **Constants**: inline `final` statics with constant values are not
  fields at all where nothing reflects on them.
- **Reports**: `-D hxmc.js.order_report` lists every lazy static, every
  post-class assignment and the cycle that caused it. Each one in arma
  should be explainable.

## Runtime and reflection

- **Symbols, not names**: reflection's data is behind symbols, imported
  from the runtime: `static [$hx.name] = "memberapplet.SiteInfo"`, and
  likewise interfaces, properties, an enum's index and constructor names.
  They are created with `Symbol.for("haxe.…")`, so two Haxe programs on one
  page understand each other's values. The data exists only where the
  program reflects: a type's name only where it reads one (`Type.getClassName`,
  `getEnumName`), not to tell a class from a function, which `Boot.isClass` does
  by its prototype (a `class`'s is read-only), and `Std.string` doesn't ask
  (a class is `<function>`).
- **Closures**: `$bind`'s cache is on the object under a symbol key,
  which `JSON`, `Object.keys` and `for...in` skip, keyed by the method
  itself (a `Map`). There is no `__id__`, `hx__closures__` or `$haxeUID`.
  A `WeakMap` is 2.5–3× slower ([haxe#13124](https://github.com/HaxeFoundation/haxe/issues/13124)).
  Later, where analysis proves it (never overridden, bound on a concrete
  class), a method can be an arrow field instead.
- **The runtime is source**: `_hx.js` (or, when bundled, the top of the
  main file) is written as readable code, one function or class per
  helper, with only what the program uses.
- **Interfaces**: a TypeScript `interface` always. At run time, only
  where the program checks it, a value with `Symbol.hasInstance`, so that
  `instanceof` works.
- **`js.Boot`'s baggage** (`__string_rec` printing classes as structures,
  IE workarounds, `HxOverrides`) is revisited in hxmc's std; what the
  output needs moves into the runtime.

## Private fields

Haxe's `private` works like `protected`: subclasses use it, `@:privateAccess`
and `@:access` open it, and reflection by name reaches it. So a Haxe private
field is `protected` in TypeScript and a plain field in JavaScript.

`#private` is only for state the generator adds itself (lazy statics'
backing fields and flags), which no Haxe code can name.

## Outputs

- **Bundled**: the main file is an ES module (the program's runtime, its
  types, the entry), and each split is an ES module that imports what it
  needs from the main file by name. `import.meta.url` replaces
  `$hxChunkBase`'s guessing. A split is loaded by `import()` of its own
  path, so a bundler can follow it too, through `js.Bundle.import` where
  the program replaces it.
- **Modules**: an ES module per Haxe module, the entry, the runtime. A
  split is no file: its call imports the modules its code needs, by
  their paths (`import()`, which a bundler follows and chunks as it
  does), and runs the code there, of the bindings it takes of them:
  `Promise.all([import("./pkg/A.js"), import("../B.js")]).then(([{ A }, { B }]) => …)`
  (not those the module has already, nor itself). A module the program has
  run already (the entry's imports) is imported for its bindings only. Of
  those the split runs first, where two are of a cycle, one after the
  other, in the order the module of a super class runs first in (as the
  entry's): `import(a).then((m0) => import(b).then((m1) => [m0, m1]))`.
  `js.Bundle.import` and `js.Bundle.base` are the bundled output's:
  whatever loads the modules (the browser, node, a bundler) loads these.
- **TypeScript**: an output named `.ts` (es-modules): each module `.ts`,
  importing `.ts` (node runs them as they are; `tsc
  --rewriteRelativeImportExtensions` compiles them), the runtime `_hx.ts`
  (unchecked, its type declared: unique symbols, `EnumValue` (exported, as a type, to the files that name it), `declareEnum`;
  `index` exported on its own, which matches narrow by: esgen-enums.md),
  `_externs.d.ts` for the externs the program names by a global path.
  Checked with `strict` but `strictNullChecks` (Haxe lets a `Null<T>` be a
  `T`), TypeScript 5.7 or later (its typed arrays generic: std's are
  `Int32Array<ArrayBuffer>`); upstream's unit suite passes `tsc` and runs
  (`make jsgen-suites`, docs/testing.md). Where Haxe accepts what TypeScript
  does not (a comparison it finds of no overlap, `null` as an object, an
  array as a structure, a static of an ancestor's name with another
  signature), the value is `any` (or the line `// @ts-ignore`d). `.d.ts`
  beside `.js`, and bundled `.ts`, later.

## Target output

`hxmc/test/jsgen/cases/Basic.hx`, bundled, as it should look. These are
the reviewed snapshots' first entries. Main file:

```js
import { trace } from "./_hx.js";   // (or the runtime inline, when bundled)

export class Shared {
	constructor(name) {
		this.name = name;
	}
	describe() {
		return "Shared(" + this.name + ")";
	}
}

class Basic {
	label = "instance";
	run() {
		return import("./method_58c10d2b.js").then(m => m.run(this));
	}
	static main() {
		const a = 1, b = 2, c = 3;
		const shared = new Shared("main");
		trace("Basic.hx:7", shared.describe());
		import("./something_afdad0c2.js")
			.then(m => m.something(a, c, b))
			.then(v => {
				trace("Basic.hx:23", "split returned " + Std.string(v));
				return new Basic().run();
			})
			.then(v => trace("Basic.hx:25", "method returned " + v));
	}
}

Basic.main();
```

Split `something`:

```js
import { Shared, trace } from "./Basic.js";

class ClassA extends Shared {
	static created = 0;
	constructor(v) {
		super("A");
		this.value = v * 10;
		ClassA.created++;
	}
}

class ClassB {
	static calls = [];
	static someMethod(n) {
		ClassB.calls.push(n);
		trace("Basic.hx:69", "ClassB.someMethod " + n + " " + ClassB.calls.length);
	}
}

export function something(a, c, b) { … }
```

An enum (`Color`):

```js
const Color = $hx.declareEnum({
	Red: null,
	Rgb: function (r, g, b) {
		this.r = r;
		this.g = g;
		this.b = b;
	},
	[$hx.name]: "Color", // where the program reads it
});
// use: Color.Red, new Color.Rgb(1, 2, 3)
```

In TypeScript the declaration is its type argument, followed by its type and
its constructors' (docs/plans/esgen-enums.md).

Not settled by these sketches:

- **Instance field initializers**: whether they are class fields or
  assignments in the constructor. Class fields define the property
  (`[[Define]]`), which bypasses a setter of the same name in a super
  class. Properties make that real, so link decides per field.
- **`trace`'s position**: Haxe's `fileName:line` stays, shortened to the
  path below the class path.

## Steps

1. `Es`, the printer, and lowering, per module. A bundled `EsChunk`
   without splits, reflection or TypeScript, run against upstream's unit
   suite as `-D hxmc.js=es`.
2. Link: placement, names, statics, imports.
3. Splits as ES modules importing from the main file; source maps;
   minifying.
4. Reflection with symbols, properties, `@:expose`, `@:jsRequire`; the
   runtime as source.
5. TypeScript: `.ts` from es-modules (done: the cases clean, arma's too);
   `.d.ts` beside `.js` and bundled `.ts` (open).
6. arma's release builds in one call (done); the first modes deleted (done).
7. `EsModule`: the modules output (done: upstream's suite, the cases; classes of
   modules extending each other's in files of their own).
8. Caching of lowered modules in the server (open).

Steps 1 to 4 are done, with source maps (names too: renamed locals, types
and fields map to their own).

## Tests

- **Behavior**: jsgen-check's cases in every output shape, upstream's unit
  suite, arma's integration suites on desktop and mobile.
- **TypeScript**: `tsc --strict` over the `.ts` of the unit suite and arma.
  The count of `@ts-ignore` is tracked and only goes down.
- **Output**: reviewed snapshots per construct (a class, an interface, an
  enum, a cycle, a split, a lazy static). They check shape, not bytes, and
  change only on purpose.
- **Without tools**: the cases run in node and in a browser straight from
  the output directory.

## Open

1. **Hot reload**: later. Its constraint for now: classes keep their
   identity, so a reload can patch prototypes and statics in place.
