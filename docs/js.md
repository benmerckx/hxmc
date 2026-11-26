# JavaScript output

hxmc has its own JavaScript generator (`hxmc/src/hxmc/es`), beside the port's
(Genjs, upstream's `genjs.ml`). A `--js` build selects it with `-D hxmc.js=<mode>`:

| Mode | Output |
| --- | --- |
| `es` | the program in one file, plus a file per split point (`js.Bundle.split`), loaded when the split is called |
| `es-modules` | an ES module per Haxe module, the runtime (`_hx.js`) and the entry; with an output named `.ts`, TypeScript |

Without the define, `--js` is the port's generator, byte-identical to the
reference. A custom generator set by a macro
(`haxe.macro.Compiler.setCustomJSGenerator`) replaces both.

The output is ES2022 (classes with static fields and `static {}` blocks,
`#private`, `??`, `?.`, arrows, `const`/`let`) and nothing older: `-D js-es`
below 6 is raised to 6 before typing, so the std's `#if (js_es >= 6)` code is
the one generated. The generator has its own `js.Boot`, `Type`, `Reflect` and
`Std` (`hxmc/portable/hxmc-es`), which replace the std's; they read what the
generator writes ([Reflection](#reflection)).

## Defines

| Define | Effect |
| --- | --- |
| `hxmc.js=es` / `es-modules` | the generator and its mode |
| `hxmc.js.minify` | minified output: short names for types, module fields and locals, no whitespace the code does without ([Minifying](#minifying)) |
| `hxmc.js.minify=aside` | (`es`) the program as it is, and beside it the minified one: `<output>.min.js`, its splits `<name>_<hash>.min.js` |
| `hxmc.js.minify.fields` | (`es`, with `hxmc.js.minify`) the fields get short names too ([Fields' names](#fields-names)); an error with `es-modules` |
| `hxmc.js.minify.fields=debug` | the fields renamed readably (`x` to `x_`, in a family's namespace `x_<n>`), with or without `hxmc.js.minify` |
| `hxmc.js.minify.fields_report` | prints the names kept and why (`=names`: each name) |
| `hxmc.js.hash-length=<n>` | the digits of the hash in a split file's name (8) |
| `hxmc.js.chunk-base=<expression>` | the address split files are loaded relative to, as a JavaScript expression (default: the main file's) |
| `hxmc.js.order_report` | prints the statics and `__init__`s that run after the types, the modules the entry runs first, the lazy statics and the classes moved to files of their own |
| `hxmc.js.properties=off` | properties stay their accessor methods ([Properties](#properties)) |
| `hxmc.js.properties_report` | prints what became of each property |
| `dts` | (`es`) `<output>.d.ts`, declaring what `@:expose` puts on the global object ([Modules](#modules)) |
| `js-source-map`, `source-map`, `--debug` | a source map beside each file ([Source maps](#source-maps)) |
| `source-map=inline` | the source map in the file, as a `data:` URL |
| `source-map-content` | the sources' text in the maps |
| `js-enums-as-arrays` | ignored: an enum's values are objects ([Enums](#enums)) |

Defines are spelled with `-` or `_` alike.

## Splitting

```haxe
final a = 1, b = 2;
js.Bundle.split("something", () -> {
	ClassB.someMethod(a);
	return new ClassA(b);
}).then(x -> trace(x));
```

`js.Bundle.split(name, init)` returns a `js.lib.Promise` of what `init`
returns. With `es`, `init` and the types that only it needs (here `ClassA` and
`ClassB`, unless the rest of the program uses them too) go into a file of their
own, `something_<hash>.js`, which the call loads with `import()`. With
`es-modules` a split is no file of its own: its call `import()`s the modules
its code needs. With any other generator `js.Bundle` (hxmc's std for the other
targets, `hxmc/portable/js/Bundle.hx`) runs `init` itself a microtask later,
so the program behaves the same, split or not:

- `init` must be a function literal without arguments, and the name a
  constant string;
- `init` may capture `this` and locals that never change once initialized
  (finals, and locals never assigned after their declaration): the split
  file gets copies of their values.

Splits of one name share their file, with an initializer per call. Splits
nest: an initializer, or a type a split's file holds, may call other splits.

Which file a type goes into (`Splits`):

- the main file holds the types the main expression reaches (through code,
  not through initializers), the types the generated code always uses
  (`js.Boot`, `HxOverrides`, `Std`, `haxe.Exception`, ...), the exposed ones
  (`@:expose`), the externs a `@:jsRequire` loads, the ones whose `__init__`
  runs raw JavaScript (`js.Syntax.code`, untyped names: what it touches is
  unknown), and those that no code reaches (kept ones, or ones only used by
  reflection);
- a split's file holds the types its initializers reach that the main file
  does not hold;
- a type that the code of several files reaches goes into the nearest file
  that every way of loading them loads first (main, if nothing else): shared
  types are pulled up, rather than into a common file of their own;
- a type with an `__init__` goes no lower than the files of the types its
  `__init__` acts on: those it takes as values (`Target` in `patch(Target)`, a
  class whose prototype it changes, or that it reflects on) and those whose
  statics it assigns. Its `__init__` then runs before their code does, e.g. it
  intercepts their methods before any are bound. The types it only calls
  functions of do not count.

A type's `__init__` and static initialization run when its file is loaded.
`Type.resolveClass` finds a split file's classes once it is loaded.

The main file is `"use strict";` and a block (nothing in it is a global), so a
page may load it as a classic script or as a module; a split file is an ES
module, so the main file needs a browser or node that has `import()`. A split
file's default export takes the bindings it uses from the files loaded before
it (`$hx.scope`), defines its types, adds those that later files use to the
scope, and returns its initializers; `$hx.load(name)` loads it once.

Split files are loaded relative to `js.Bundle.base` when the program sets it,
else relative to the main file: the running script's address
(`document.currentScript`), `__filename` on node, or the address in the stack
of its first line, when another script wraps it in a function;
`-D hxmc.js.chunk-base` gives that address as an expression instead. They are
loaded through `js.Bundle.import` (`importModule` in Haxe, where `import` is a
keyword; a dynamic function), `import()` by default: a program may replace it,
e.g. to retry a failed load with another address, as a browser caches a failed
`import()`. A split file's name changes with its code (the hash), and the main
file maps each name to its file. A build removes the split files of these
names, and their maps, that an earlier build left.

## Classes

A class is a `class`, its statics static fields in its body and its `__init__`
a `static {}` block, where the code that initializes them can run there: the
types it reaches are declared and initialized before. Statics and `__init__`s
that cannot (a cycle) run after the types, in their order. `-D
hxmc.js.order_report` lists them.

```js
class Circle {
	static count = 0;
	static UNIT = new Circle(1);
	constructor(r) {
		this.r = r;
		Circle.count++;
	}
	area() {
		return Math.PI * this.r * this.r;
	}
}
```

ES6 wants `super()` before `this`. A constructor that uses `this` before
`super(...)` (field initializers, which Haxe puts first, do) is reordered
where that cannot be told apart (`SuperFirst`): from the first statement with
`this` on, when those use `this` only for the class's own variables, `super`'s
arguments have no effects and use none of their locals, and the ancestors'
constructors only assign fields values without effects (an extern's is trusted
to, as JavaScript's class fields have it). The others construct in two steps,
as Genjs does (`_hx_constructor`, `filters.ES6Ctors`).

A method taken as a value (`var f = c.area`) is `$hx.bind(c, "area")`: the
same function each time for the same object and method, cached on the object
in a `Map` under a symbol (`$hx.closures`), which `JSON`, `Object.keys` and
`for...in` skip. Local functions are arrows, but those that use their own
`this`, `super` or `arguments`.

## Properties

A property whose read and write are each `get`, `set`, `never` or `null` (at
least one of them a call) is a JavaScript accessor of its name: `get x() {...}`
and `set x(v) {...}` hold the accessors' code, and `o.get_x()` and
`o.set_x(v)` are `o.x` and `o.x = v`, so JavaScript code reads and writes the
property as Haxe code does. A static one is a static accessor
(`Settings.mode`). With storage (`@:isVar`, or `null`: `(get, null)`), its
storage is the class's #private field (`#x`, `this.#x` in the class's code; a
static's `static #x = <value>`).

A property, the ones that override it and the interfaces' declarations it
implements change together, or not at all: not when one of them is an
extern's, is redeclared or shadowed, or is implemented by a field of another
kind, nor when the class extends an extern (whose members of the name the
extern may not declare: `haxe.Exception`'s `message`). A subclass that
overrides one accessor gets the other through `super` (`set x(v) { super.x =
v; }`).

`#x` is its class body's: a property with storage changes only where nothing
else uses the storage as Haxe has it, a field of the instance. Not where code
outside the class uses it (a subclass's accessor, an `__init__`, a split's
code), where a static's value is set after its class (`hxmc.js.order_report`),
where reflection reads the fields of the class's instances or its own (a value
of the class's type, an ancestor's or an interface's, or the class itself,
given to `Reflect.field`, `Reflect.fields`, `Reflect.setField`,
`JSON.stringify`, `Type.getInstanceFields`, `Type.getClass`, ...), nor where
untyped code names it. Reading it otherwise by name (`Reflect.getProperty`, a
`Dynamic`'s field, a structure's) calls the getter, as hxcpp's
`@:nativeProperty` does.

The accessors stay methods too (`get_x()`, which the JS accessor calls) when
something needs them as such: a setter call whose value is used (`a = o.x = v`:
JavaScript's value is `v`, the setter may return another), an accessor taken
as a value, one named through a structure, `Dynamic`, untyped code or a string
(`"get_x"`), or one that is `dynamic`, `@:keep` or `@:expose`. A call through
`super` of a kept accessor stays a call.

Which properties change is decided from the whole program once its code is
lowered: what each lowering finds (the calls of accessors, whether their values
are used, the storage's uses and by which class's code, the names read
dynamically, what reflection is given) it notes with the rest of what it uses,
and the printer writes a call as the property or as the call, the storage as
`#x` or `x`, as its family is.

Where the program reflects on properties (`Reflect.getProperty`,
`setProperty`), each class lists the accessor methods of the properties that
stay methods under `$hx.properties` (its instances') and
`$hx.staticProperties` (its own); those find a JS accessor by the property's
name. Elsewhere a class lists nothing.

In TypeScript's output the accessors have their types (`get x(): number`,
`set x(v: number)`, a setter returning nothing), and an interface declares a
property that is a JS accessor (`x: number`; `readonly`, without a setter), not
its accessor methods. A variable only its class's constructor writes (`final`,
`(default, null)`, `(default, never)`) is `readonly`; where the Haxe code writes
it elsewhere (a method, a subclass, a constructor in two steps), it writes it as
`(o as any).x = v`, as TypeScript lets it.
`-D hxmc.js.properties=off` keeps every property as it is;
`-D hxmc.js.properties_report` prints what became of each.

## Reflection

What reflection reads of a type is on the type, under symbols of the runtime
(`$hx`), never under names a program's own fields could have, and only what the
program reads:

| Symbol | On | Written where |
| --- | --- | --- |
| `$hx.name` | a class, an enum: its path | the program reads a class's name (`Type.getClassName`); an enum's also with `Type.getEnumName` |
| `$hx.interfaces` | a class: the interfaces it implements (a getter) | the program checks for an interface |
| `$hx.isInterface`, `$hx.fields` | an interface's value | the program checks for it |
| `$hx.fields` | a class: its variables | `Type.getInstanceFields` |
| `$hx.properties`, `$hx.staticProperties` | a class: its properties' accessors | `Reflect.getProperty`, `setProperty` |
| `$hx.index`, `$hx.enumOf` | an enum constructor's prototype | always |
| `$hx.constructs` | an enum: its constructors' names | always |
| `$hx.closures` | an object: its bound methods | a method taken as a value |

The symbols are `Symbol.for("haxe.<name>")`, so two Haxe programs on one page
read each other's values. The runtime `$hx` holds them and the helpers the
code uses (`bind`, `declareEnum`, `interface`, `load`, `expose`, the
iterators), and only those: it is source, one function per helper.

The rest of reflection reads JavaScript itself:

- an object's class is its `constructor` (`Type.getClass`: none for a
  structure, an enum value, `Math` or `JSON`'s `Object`); a class's super class
  its prototype (`Object.getPrototypeOf`);
- a value is a class if it is a function whose `prototype` is read-only, which
  `class` makes it (a function's or an arrow's is not);
- `Type.resolveClass` and `resolveEnum` look in `$hx.classes` and `$hx.enums`,
  which the program fills where it calls them;
- `Type.getInstanceFields` lists the methods on the prototypes and the
  variables in `$hx.fields`; `Type.getClassFields` a class's own static fields;
- `Reflect.fields` is `Object.keys`: an object's own fields, but none of the
  runtime's, which are symbols.

### Type checks

`Std.isOfType(v, t)` (and casts, `Std.downcast`, `catch` by type):

| `t` | Check |
| --- | --- |
| `Int` | `typeof v == "number" && (v \| 0) === v` |
| `Float`, `Bool`, `String` | `typeof` |
| `Array` | `instanceof Array` |
| `Dynamic` | not null |
| a class | `v instanceof t` |
| an interface | `v instanceof t`: its value's `Symbol.hasInstance` walks `v`'s classes and their `$hx.interfaces` |
| an enum | `v`'s enum is `t` |
| `Class`, `Enum` | a class ([Reflection](#reflection)), an enum |
| a native class (`js.html.Element`) | `instanceof` |

An interface has a value (`$hx.interface("pack.I")`) only where the program
checks for it (or resolves classes by name); otherwise it is no value at all,
and its implementations list none.

### `Std.string`

As Genjs prints, but for what reflection does not keep: a class is
`<function>` (Genjs: `{ __name__ : Point }`), an enum the object of its
constructors, an enum value `Rgb(1,2,3)` (from its enum's constructor names).

## Enums

An enum is an object of its constructors, made by the runtime:

```js
const Color = $hx.declareEnum({
	Red: null,
	Rgb: function(r, g, b) {
		this.r = r;
		this.g = g;
		this.b = b;
	},
	[$hx.name]: "Color"
});
```

- a constructor with arguments is a function that `new` constructs
  (`new Color.Rgb(1, 2, 3)`, `v instanceof Color.Rgb`); one without is the
  enum's value of it (`Color.Red`), made once;
- every value is an instance of the runtime's `EnumValue`: its index and its
  enum are on its constructor's prototype (`$hx.index`, `$hx.enumOf`), its
  arguments are its own fields, in their order (`v.r`). `Reflect.fields`,
  `Object.keys` and `JSON.stringify` see only the arguments (Genjs: also
  `_hx_index`, `__enum__`, `__params__`, `toString`);
- `$hx.constructs` lists the constructors' names in order:
  `Type.enumConstructor`, `getEnumConstructs`, `createEnum` and
  `createEnumIndex` go by index, so they hold when the keys are renamed
  ([Fields' names](#fields-names));
- `Type.enumParameters` is `Object.values(v)`, `enumIndex` `v[$hx.index]`;
- `v instanceof Color` is whether `v` is a value of it (its `Symbol.hasInstance`:
  `v[$hx.enumOf]`), which TypeScript narrows `v` by, to the enum's union;
- an enum value's `toString` is `Std.string`'s.

In TypeScript ([TypeScript](#typescript)) `declareEnum`'s type argument is the
enum as Haxe declares it, its constructors in order (`readonly Red: Color`,
`readonly Rgb: new (r: number, ...) => Color`, a GADT's result); the enum's type
is the union of its constructors' interfaces (`export declare namespace Color {
interface Rgb extends EnumValue { readonly [index]: 2; readonly r: number; ... }
}`), generic as the enum is. A match narrows on `v[index]` (`index` a binding
of its own, `_hx.ts`'s: TypeScript narrows by an identifier's unique symbol
only), reads the arguments by name where it narrowed (else `(v as any).r`), and
a `switch` over them is exhaustive. Why this shape: `new` of a plain function is
as fast as of a class (a runtime building values from their parameters' names
was 15 times slower), the declaration reads as Haxe's enum, and TypeScript's
own `enum` has no arguments and is not erasable.

## Minifying

With `-D hxmc.js.minify` the types, module fields and locals get short names,
the most used the shortest, and the generator writes no whitespace the code
does without (a line break only where a semicolon could be inserted at it) and
no `;` before a `}`. `true` and `false` are `!0` and `!1`, consecutive `let`s
one. Untyped code (`js.Syntax.code`, included files) is written as it is, and
may name anything: a type or a global whose name appears in it keeps its name,
and so does a local whose name appears in its function's. The names of types
reflection finds (`$hx.name`) are their Haxe paths, whatever their bindings'.

### Fields' names

With `-D hxmc.js.minify.fields` too (`es` only: the modules of `es-modules` are
imported by others, who read their fields by name), the fields get short names
as well, classes' and structures' alike, the most used the shortest
(`hxmc/src/hxmc/es/FieldNames.hx`). The analysis runs as the code is lowered; the
names are given when it is printed.

- **Namespaces.** A class's instances' fields are named in its family's
  namespace (the classes that `extends` and `implements` join: dynamic dispatch
  stays within it), its statics in another of the family (an ES class inherits
  its ancestors' statics); each starts again at `a`. An enum's constructors
  (its object's keys) and its values' arguments (their fields) are named in
  namespaces of their own. Structures' fields, a field of a name the typer
  unified with a structure's (`CfMaybeUsed`), and one the code reads as a
  structure's anywhere (`(untyped x).name` too), are named in the global
  namespace: a name there is renamed alike everywhere, so whatever unifies with
  what, the names agree. A family's names avoid the global ones.
- **Kept names.** A name stays as it is where the code shows that something
  outside the program reads it: an extern's field (an extern ancestor's too), a
  field read off `Dynamic`, the structure an unchecked cast makes from an
  extern's value (a type check, `(literal : Attributes)`, is a cast too, and
  not one), a string constant (a name passed to reflection), the words of
  untyped code, of the runtime and of the included files, rtti's metadata,
  `@:native` names, an `@:expose`d class's public API, and what JavaScript reads
  by name (`toString`, `then`).
- **Shared types.** A type is shared, its fields' names kept:
  - a value out of `Dynamic` into a typed place (a variable, an assignment, a
    cast, an argument, a returned value, each branch it may come from:
    `c ? json.x : {...}`), and a structure into `Dynamic`
    (`interpolate({rank: 7})`): its data, a class's instance not;
  - what a program gives an extern, or takes from one, but where the extern's
    signature has a type parameter there (`push(x:T)`, `resolve(value:T)`: it
    hands the value on), and of its structures only the fields they declare; a
    class's instance not (the outside calls the methods its extern declares),
    what it holds neither;
  - what reflection reads by name: its own keys (`Reflect.fields`,
    `Object.keys`, `Type.getInstanceFields`), or all the way down
    (`haxe.Json.stringify`, `JSON.stringify`, `haxe.Serializer`,
    `haxe.Template`), a class's instances included;
  - what generic code lets out that way, at the type parameter's place in a
    call or an instance (`makeState<T>(v:T):State<T>`, a `State<Float>`: the
    `Float`);
  - a type marked `@:shared` (a class, a typedef, an enum, an abstract), for
    what the code cannot show: a value of it that goes into `Dynamic` and is
    read by name otherwise.
- **Enums.** Where the program reads the constructors' names
  (`Std.string`, `Type.enumConstructor`), `declareEnum` gets them apart (its
  `names`): the keys are short, the names not.

`-D hxmc.js.minify.fields=debug` renames `x` to `x_` (in a family's namespace
`x_<n>`), the output readable, to find a name that should have been kept;
`-D hxmc.js.minify.fields_report` prints what was kept and why.

## Source maps

With `-D js-source-map` (or `--debug`, or `-D source-map`), each file has its
map beside it (`<file>.map`, a `//# sourceMappingURL` at its end): the main
file, each split file, the minified files of `=aside`, each module of
`es-modules`. `-D source-map=inline` puts the map in the file, `-D
source-map-content` the sources' text in the map. An expression or a statement
maps to where it starts in the Haxe source.

A name the output has renamed (a minified local, type or field) maps to its
own name: its place in the map names it (the map's `names`), so stack traces
and the debugger show the Haxe names. Names are per place: fields minified to
the same short name in different namespaces map to their own names apart.
Maps do not change the code: a file's text is the same with them as without,
its hash and name too.

## Modules

With `-D hxmc.js=es-modules`, each Haxe module becomes an ES module at its path
under the output's directory (`pack/Module.js`), which declares its types and
exports them by their own names:

```js
import { $hx } from "../_hx.js";
import { Model } from "../coconut/data/Model.js";

export class SiteInfo {
	static [$hx.name] = "memberapplet.SiteInfo";
	static DEFAULT = new SiteInfo({ product: "LJ", imagePath: "" });
	constructor(init) { ... }
}
```

- a class's statics are its own static fields, its `__init__` a static block;
  an enum is `export const E = $hx.declareEnum(...)`; an interface, where the
  program checks it, `export const I = $hx.interface(...)`;
- a module's fields are its functions and variables (`export function f`,
  `export let x = ...`); an extern's `__init__` is its module's code;
- the runtime is `_hx.js`, which every module imports `$hx` from;
- the names in a file are the types' own, but where two would be the same, or
  the code refers to a global of that name (an extern's); a local of a type's
  name is renamed.

The entry (the output's file) imports the modules that always run first (the
std's runtime), those nothing imports (an `__init__`'s, reflection's), the main
class's, and runs the main expression.

The entry may be a module's file (`--js out/Main.js`, of `Main`): one file. A
name that is a module's file's but for case (`--js out/main.js`, of `Main`) is
an error, wherever file names are case-insensitive or not: at the module's type
of its name, else at `main`.

Modules run in their imports' order: a module after those it imports, but those
already running (a cycle). What runs as a module loads must find what it needs:
a class its super class, a static's initialization and an `__init__` the types
they reach. The generator follows Haxe's order of initialization for that,
simulates the order the modules run in, and makes it work:

- each file imports the modules of more derived classes first, which run their
  super classes' first; a class whose super class's module has still not run
  when its module does has the entry import its module first;
- modules whose classes extend each other's (`Left`'s `LeftChild` extends
  `Right`'s `Right`, which extends `Left`) have no such order: a class of such
  a cycle moves to a file of its own, `<module>.<Class>.js` (`Left.LeftChild.js`),
  which the code that uses it imports, until no cycle is left; a module's
  secondary classes move first;
- a module whose statics or `__init__` reach a module that would run after it
  is imported by the entry first: what it imports runs before it (`Celsius`'s
  `freezing = Scale.zero()`, where `Scale` imports `Celsius`);
- a static that reaches a class its file declares later, or its own class
  through another class's code (which has the class's binding only once its
  body has run), is assigned after its file's classes;
- a static no order makes ready (statics of two modules, each calling the
  other's module) is lazy: initialized when first read, or when set, its value
  in a `#private` field.

```js
static #reporter;
static #reporter_ready = false;
static get reporter() {
	if (!CompactLogger.#reporter_ready) {
		CompactLogger.#reporter_ready = true;
		CompactLogger.#reporter = new Reporter();
	}
	return CompactLogger.#reporter;
}
```

An abstract's implementation is an object of its functions, not a class
(`export const A = { toKm(this1) {...}, ... }`), its statics' values but
constants assigned after it, in order, as a class's static initializers run;
TypeScript's output has the abstract as a type of the same name beside it
([TypeScript](#typescript)). One an object cannot hold (#private storage, lazy
statics, a static block) stays a class, its type `A.Self`.

So statics run as their modules load, in the order of the modules, rather than
all of them after all `__init__`s as in a single file; where Haxe's order puts
one after another it reaches, the module order does too. `-D
hxmc.js.order_report` prints the modules the entry runs first, the statics
assigned after their file's classes and the lazy ones (with what they wait for),
and the classes moved.

Included files (`--macro includeFile`) run first, as they are, in `_hx_include.js`,
which the entry imports before anything else; what they declare at their top
level is made global. An extern's `@:jsRequire` is an import of its module (a
`require` in `es`). `@:expose` puts the path on the global object
(`$hx.expose`). A module's variable assigned from another module fails: an
import is read-only.

### TypeScript

An output named `.ts` (`--js out/main.ts`, `es-modules`) makes the modules
TypeScript (`hxmc/src/hxmc/es/Ts.hx`), which node runs as it is (type
stripping) and which `tsc` checks with `strict` but `strictNullChecks` (Haxe
lets a `Null<T>` be a `T` without a check):

- the files are `.ts` and import `.ts`; `_hx.ts` is typed;
- a class has its type parameters (with their constraints) and declares its
  fields (`declare`: nothing at run time), its statics' types, and the
  interfaces it `implements`; an abstract class is `abstract`, an interface
  TypeScript's `interface` (with the interfaces it `extends`); an enum is its
  constructors' declared classes and their union ([Enums](#enums));
- functions have their arguments' and return's types (`?` from the first
  optional argument), method type parameters, and a function that names `this`
  a `this: any`; locals have their Haxe types; calls of generic methods and
  enum constructors, and `new` of generic classes, have their type arguments,
  as Haxe inferred them;
- the externs the program names by a global path are declared in
  `_externs.d.ts` from the externs themselves (`declare class React {...}`,
  `declare namespace a.b {...}`), the program's types they name by
  `import("./pack/A.ts")`; a path several externs have is `any`, one of
  `window`'s a property of `Window`; the std's externs are TypeScript's own;
- where Haxe accepted what TypeScript would not (`untyped` code, `cast`, a
  GADT's type parameter, a structure's extra fields, dynamic access, an
  extern's signature), the value is `(e as any)`; raw code (`js.Syntax.code`)
  is unchecked, a `// @ts-ignore` per line, its value `any`;
- an abstract is a type of its own, its module's (`export type A`), beside its
  implementation of the same name: one `import { A }` brings both. It is
  branded by a symbol only TypeScript has (`declare const $brand: unique
  symbol`; the brand `B` below is `{ readonly [$brand]: { readonly "pack.A": V
  } }`, of the abstract's path and its underlying type, which tells `A<Int>`
  from `A<String>`), as Haxe lets values go: `A(V) from V to V` is `V`;
  `A(V) to V` is `V & B` (an A is a V, no V an A); `A(V) from V` is `B | V` (a
  V is an A, no A a V); `A(V)` is `B` (neither); its other `from` types' values
  are A's too. An enum abstract is the union of its values' types, each a unit
  type, so that a `switch` over them (`case Color.Red:`) is exhaustive, in
  authored code as in Haxe's: where it is `to` V, a declared enum's members
  (`declare enum $Level { Low = 0, ... }`, ambient: no code; a number as
  TypeScript's enums are, which takes any `number` too, but no other literal);
  where not, unique symbols (`declare const $Color: { readonly Red: unique
  symbol; ... }`, `typeof $Color.Red | ...`: nothing else, though the values
  are numbers); `| V` where it is `from` V; `V` where it is `from` and `to` it;
  `U & B`, of its literals, where it is `to` V of values an enum cannot have
  (`Bool`'s). Its values are constants of its object of those types (`Low: 0 as
  $Level.Low`, `Red: 0 as unknown as typeof $Color.Red`), all of them, the
  ones Haxe has inline only too; `as const` where nothing assigns its
  statics. One whose functions are all inline has its values' object still
  (`export const Level = { ... }`, in JavaScript too). A `switch` on another
  branded value is on it as `any`, which its cases (literals) compare with. Not the std's core types, a
  multi-type's (`Map`), an extern's, one over `Dynamic`, `haxe.Rest`. Its
  constructor is `A.new(...)` (es-modules; the typer's `_hx_new` in the bundle), a
  generic abstract's functions of its type parameters (`first<T>(this1$: Pair<T>):
  T`), which calls pass as Haxe has them. Its
  methods take their `this` as the abstract (`next(this1$: Id)`), their code
  the underlying value (`let this1: number = (this1$ as any)`). Where Haxe
  converts without a cast (in the abstract's own code above all), the value is
  `(e as any)`, and what JavaScript does with an opaque abstract's value (index
  it, call it, compute with it) is of it as `any`. A module whose names an
  import has imports it as another (`import { A as A$1 }`); a type it imports
  only, of a name it has or another export has, it names by its module
  (`import("./a/B.ts").B`);
- a class itself as a value (its statics) is `typeof` it;
- a class still constructed in two steps (`_hx_constructor`) takes its
  constructors' arguments as optional `any`.

TypeScript code written against the output, importing its modules, checks them
under its own `tsconfig`, and `strictNullChecks` is one for the whole program:
no file or function has its own. The output has `string` where Haxe means a
string or `null`, so under `strictNullChecks` its code fails and its values are
taken as never `null`. Strict code checks the output apart instead: as a project
of its own (`strictNullChecks: false`, `composite`) that it references (project
references: it sees the declarations only), or compiled once to `.js` and
`.d.ts`, as a library is. A `switch` over an enum abstract's values (`case
Color.Red:`) leaves `never` once it has them all, under any options; a
function falling out of a partial one fails (`Function lacks ending return
statement`) under `strictNullChecks` only, `noImplicitReturns` or a `default:
const x: never = c;` catching it without.

`-D dts` in `es` (the bundle) writes `<output>.d.ts`: what `@:expose` puts on
the global object, declared under its path (`declare namespace a.b { class C
{...} }`, `declare function f(...)`, `let v`): an exposed class's public API
(constructor, methods, variables, properties as JavaScript has them, an
ancestor's that is not exposed itself), `readonly` for what only the class
writes (`final`, `(default, null)`, a property without a setter); the types it
names by the paths they are exposed at, an abstract as its type (branded, as in
TypeScript's output) under `HxTypes` at its path (`HxTypes.pack.A`), the others
`any`. Not in `es-modules`
(TypeScript's output is its declarations).

## Differences from Genjs at run time

What a program can see of the generator, besides the output's shape:

- reflection's data is under symbols, not `__name__`, `__interfaces__`,
  `__properties__`, `__ename__`, `__constructs__`, `_hx_index`, `__enum__`,
  `__params__`: none of these exist, and `Reflect.fields` and `JSON.stringify`
  do not see the runtime's data;
- a class's name, interfaces and properties exist only where the program
  reads them ([Reflection](#reflection));
- `Std.string` of a class is `<function>`, of an enum the object of its
  constructors;
- an enum value is an object of its arguments, not an array
  (`js-enums-as-arrays` is ignored);
- bound methods are cached in a `Map` under a symbol: no `hx__closures__`, no
  `__id__`, no `$haxeUID`;
- `Type.getInstanceFields` lists the methods before the variables;
- a property is a JavaScript accessor where it can be ([Properties](#properties)):
  its accessor methods, as Genjs has them, may not exist; `Reflect.getProperty`
  finds those that do only through `$hx.properties`, which exists only where it
  is used;
- a property with storage (`@:isVar`) whose storage is a #private field
  ([Properties](#properties)) is no field to reflection on a value of no type
  the program knows: `Reflect.field` of its name calls its getter, `Reflect.setField`
  its setter (and throws without one), `Reflect.fields` and `JSON.stringify` do not
  list it;
- `$hxClasses`, `$hxEnums`, `$global`, `$estr` and `HxOverrides.iter` are not
  there: `Type.resolveClass` reads `$hx.classes`, the program's scope is a
  block, iterators of arrays come from `$hx`.

## Development

`make jsgen` builds `bin/jsgen/haxe`, the port's command line with the
generator (seconds after an edit; it adds hxmc/portable and the checkout's std
itself). `make jsgen-check` builds the cases of `hxmc/test/jsgen/cases` with
the port's generator and with hxmc's (`es`: plain, asked for ES5, minified,
with fields renamed, `=aside`, with source maps, run from inside a function as
a wrapping page runs it, with `--dce full`; `es-modules`: plain, with source
maps, with `--dce full`), runs them under node and compares what they print;
it also checks the split files and their maps. `Regressions` holds, each in its
smallest form, the breakages splitting a large program turned up. `make
jsgen-suites` runs upstream's `tests/unit` by it as `es`, `es-modules` and
TypeScript ([testing.md](testing.md)). The `haxe` of the npm package
(`hxmc.HaxeMain`) has the generator too.
