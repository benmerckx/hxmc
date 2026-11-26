# Plans: the ES generator

hxmc's own JavaScript generator (`-D hxmc.js=es|es-modules`), beside the
port of `genjs.ml`. It replaced the first hxmc modes, which were refactors of
Genjs bound to its output and its runtime. What it is and does:
[docs/js.md](../js.md). Open:

- **Importing one module on its own.** Statics run in an order the entry
  sets up (its imports first, docs/js.md, Modules). Code that imports a
  module directly, without the entry, can hit a binding before its
  initialization in a cycle (`Cannot access 'Exception' before
  initialization`). Approach: each module imports first what its statics
  need run, so that any module is an entry.
- **`.d.ts` beside es-modules' `.js`**, for JavaScript consumers with
  types: the TypeScript output's declarations, without the code.
- **`strictNullChecks`.** The output is checked without it: Haxe lets a
  `Null<T>` be a `T`. With it, `Null<T>` is `T | null`, and a cast where Haxe
  takes one as the other. Until then, strict code checks the output apart
  (docs/js.md, TypeScript).
- **`// @ts-ignore`**: raw code (`js.Syntax.code`) is unchecked by design;
  a static of an ancestor's name with another signature is the remaining
  case to remove.
- **Caching lowered modules in the compilation server.** A module's
  lowering depends on its post-filter types and the build's options only.
- **npm packages** from es-modules: later, once modules have proven
  themselves (bundled output plus `-D dts` is the way to publish until then).
- **Hot reload** (`-D hxmc.js.hot`, docs/js.md, Hot reload): classes'
  methods, constructors, variables, statics and super classes, enums'
  constructors added, abstracts' and modules' functions are patched. Open: a
  driver (`haxe --dev`: watch, build, push the patch over a WebSocket); a
  class added to a module the program has (the patch declaring it, later
  patches importing it from there); lambdas the old code created running the
  new code (their captured variables kept shared: not #206's copies).
