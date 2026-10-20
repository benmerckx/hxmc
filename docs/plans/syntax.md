# A syntax for components and styles (idea, to be decided)

An idea, not a decision: what writing UI in hxmc could look like if
`@hxmc/ui` shipped its own syntax, with the compiler, formatter and editor
support that come with it in one library. Nothing here is built; the open
questions are at the end.

## Why

Today a component is a static function in a class that `implements
Markup`, with JSX-like literals ([view.md](view.md)):

```haxe
class App implements Markup {
	static function Counter(props:{label:String, ?step:Int}):View {
		var step = props.step ?? 1;
		var count = signal(0);
		return <view direction="row" column-gap={8}>
			<text>{props.label}: {count}</text>
			<view onClick={_ -> count.value += step}>+{step}</view>
			<Show when={() -> count.value > 10}><text>big</text></Show>
			<For each={items} render={(item:Item) -> <Row item={item}/>}></For>
		</view>;
	}
}
```

What costs: `.value` on every read and write, lambdas around handlers and
conditions, control flow as components (`For`, `Show`) with a typed
lambda, props as a structure, the class and `View` boilerplate, and the
lexer's rule that a root whose attribute holds markup cannot close with
`/>`. Styles are a separate world (Tailwind class lists through `Tw`,
`style={_ -> {...}}`, sheets as JSON).

## What others do

The model has converged on signals (Solid, Svelte 5, Vue Vapor, Angular,
Leptos, Dioxus, the TC39 proposal); the difference is syntax.

- **Code builders** (SwiftUI, Jetpack Compose): trailing closures, named
  arguments, plain `if`/`for`, state as plain variables (`@State var`,
  `by remember`). The nicest as code, but their bodies re-run on a change;
  ours run once and bind, so their look suggests semantics we do not have.
- **Declarative element blocks** (QML, Slint, Dioxus's `rsx!`): an element
  is a block of `property: value`, handlers and children, with `if` and
  `for` built in, and every property expression a live binding. Their
  semantics are ours: run once, bind what changes.
- **HTML-first templates** (Svelte, Vue): best for content and familiar,
  weaker for deep component trees and typing.
- **JSX**: familiar, but no control flow of its own (`&&`, ternaries,
  `.map`) and closing tags everywhere.

## The idea

### `.hxv` files

Extended Haxe in its own extension: a module `pack.Counter` is
`pack/Counter.hx` or `pack/Counter.hxv` (both: an error). Plain `.hx` stays
plain Haxe, untouched by any of this; editors, highlighters and the
formatter pick the language by the extension. The syntax a `.hxv` file
gets is the plugins of the libraries the project uses (`hxmc.ui`'s, later
others), so the extension means "extended Haxe", not "UI".

### Syntax plugins, desugared to plain Haxe

Every new form has a canonical plain-Haxe form (metadata and calls), and
the parser produces exactly that, so nothing after the parser (typer,
macros, HXB, the module cache, the back ends, the generated compilers of
other Haxe versions) knows about plugins:

| syntax | plain Haxe |
| --- | --- |
| `state count = 0;` | `@:state var count = 0;` |
| `derived double = count * 2;` | `@:derived final double = count * 2;` |
| `Row { gap: 8px; Text { "hi" } }` | `Row({style: ..., children: ...})` |
| `async function load() {...}` | `@:async function load() {...}` (a Haxe 5 coroutine) |
| `await fetch(url)` | `@:await fetch(url)` |

The meaning lives in ordinary macros on those forms, which work with stock
Haxe too. `hxmc desugar` prints a `.hxv` file as plain `.hx`: to publish a
library that upstream Haxe compiles, to see what a construct became, and
as the way out if the syntax is ever dropped.

A plugin is a grammar file in the library, declarative rather than code
run while parsing:

```
statement  state    := "state" name:ident (":" type:type)? "=" value:expr ";"
           => @:state var $name : $type = $value;
statement  derived  := "derived" name:ident "=" value:expr ";"
           => @:derived final $name = $value;
modifier   async    := "async" function
expr       await    := "await" e:expr(prefix)
```

- Slots are Haxe's own nonterminals (`expr`, `type`, `ident`, `block`):
  everything inside is ordinary Haxe, with ordinary completion.
- Keywords are contextual (`state` only where a statement starts and a
  name follows), so `var state = ...` keeps working.
- A rule may only take what is a parse error today; the compiler checks
  this when a plugin loads, and two plugins claiming the same form is a
  configuration error naming both.
- Desugared nodes keep their source positions: errors, hover,
  go-to-definition and the debugger point at what was written.

Two candidate surfaces share that mechanism: **A**, element blocks and
CSS (below), and **B**, Haxe that reads like TypeScript with JSX
([further down](#candidate-b-typescript-flavoured-haxe-with-jsx)). The
prototype screen is written in both to decide.

### Candidate A: components as element blocks

```haxe
component Counter(label: String, step = 1) {
	state count = 0;
	derived double = count * 2;
	effect trace(count);

	Row {
		gap: 8px;
		Text { "$label: $count (x2 = $double)" }
		Button { "+$step"; onClick: count += step; }
		if (count > 10) Text { "big" }
		for (item in items) ItemRow { item: item; }
	}
}
```

- `component` declares a function whose arguments are its props (defaults
  and optionals as Haxe's); Haxe checks them at each use. Inside, props
  read as plain values and stay reactive.
- `state` and `derived` make reactivity explicit, so nothing is inferred:
  reads and writes are plain (`count`, `count += step`); a `derived` is a
  memo.
- An element block holds:
  - `name: value;`: a property, always a live binding;
  - `onX: statement;`: a handler, wrapped into a function;
  - a string: a text child, its interpolation bound;
  - an element: a child;
  - `if`, `for`, `switch`: reactive control flow (`Show`, keyed `For`,
    `Switch`); `for` keys by the item's `key` or `id` when it has one.
- Passing state to a component passes the signal (the child stays live);
  passing it to a plain function passes its value; `ref(count)` is the
  escape hatch for a function that writes it.
- Prose: `P { "Hello "; B { name } ", you have $n items" }`, acceptable,
  not as good as markup.

### Candidate A: styles as CSS

Inside an element block, a name the engine knows as a CSS property takes a
CSS value; any other name is a widget property and takes Haxe:

```haxe
component PlanCard(plan: Plan, selected: Bool, onPick: Plan -> Void) {
	Card {
		variant: {selected ? outline : default};
		width: 18rem;
		padding: 20px;
		gap: 12px;
		border-radius: var(--radius-xl);
		border-color: {selected ? var(--primary) : var(--border)};
		opacity: {plan.soldOut ? 0.5 : 1};
		transition: transform 150ms ease-out, box-shadow 150ms;

		&:hover { box-shadow: var(--shadow-lg); transform: translateY(-2px); }
		&:focus-visible { outline: 2px solid var(--ring); }
		@media (prefers-color-scheme: dark) { background-color: var(--muted); }

		Row {
			align-items: baseline; justify-content: space-between;
			Text { font-size: 1.125rem; font-weight: 600; "${plan.name}" }
			if (plan.popular) Badge { variant: secondary; "Popular" }
		}
		Button {
			size: lg; width: 100%;
			onClick: onPick(plan);
			if (selected) "Selected" else "Choose"
		}
	}
}
```

- Values are CSS (units, `calc()`, `var(--token)`, colour functions,
  shorthands); `{expr}` embeds Haxe, a live binding, the same hole as
  markup's. Without braces a value is CSS, so `red` or `auto` are never
  Haxe names.
- States by CSS nesting (`&:hover`, `&:disabled`, `&[data-state=open]`),
  `@media` for dark, breakpoints and reduced motion; a widget's parts as
  pseudo-elements (`Slider { &::thumb { background: red; } }`).
- Tokens are custom properties (`var(--primary)`), as shadcn's.
- `class: "rounded-full px-3"` stays as shorthand: Tailwind classes
  compiled by `Tw` into the same rules.
- An instance's own declarations win over the theme's rules (the theme
  README's promise, which `width` on Slider breaks today).

Themes become CSS too, in a `.hxv` file or a `.css` file a theme loads:

```css
theme Brand extends Shadcn {
	:root { --primary: oklch(0.55 0.2 260); --radius: 0.75rem; }
	.dark { --primary: oklch(0.7 0.16 260); }
	Button.danger { background-color: var(--destructive); color: white; }
	Button.danger:hover { background-color: color-mix(in oklch, var(--destructive) 90%, black); }
	Card { box-shadow: none; }
}
```

Selectors there are widgets, variants as classes (a new variant then
type-checks wherever the widget is used), parts as pseudo-elements and
states; nothing reaches across components. Everything compiles to the
rules and instance styles there are today, so drawn, native and DOM
rendering keep working, the DOM renderer emitting it as real CSS, and the
dev loop's live styles ([dev-loop.md](dev-loop.md)) apply to it as data.

"CSS" means its syntax and the subset the engine implements (flex, grid,
the box model, borders, shadows, transforms, transitions, text, what the
Tailwind subset covers). A property outside it (`float`, inline text
flow, `position: sticky`) is a compile error naming it, not silently
ignored; descendant and sibling selectors and `!important` are out. The
cascade is CSS's for what is supported: specificity, then order, the
instance's own last.

### Candidate B: TypeScript-flavoured Haxe with JSX

For familiarity: what a TypeScript, React or Solid developer expects to
type works, while the language underneath stays Haxe. Haxe's semantics
are kept where they are better than JavaScript's: everything is an
expression, `switch` is Haxe's pattern matcher, the types are Haxe's.
Full TypeScript (union narrowing, `number`, `any`, structural
interfaces, npm imports) is out: a surface promising semantics Haxe does
not have turns every gap into a confusing error.

```tsx
import { Row, Text, Button, Badge } from "hxmc/ui"
import { fetchPlans } from "./api"

type Props = { label: String, ?step: Int }

export function Counter({ label, step = 1 }: Props) {
	let count = $state(0)
	const double = $derived(count * 2)
	$effect(() => trace(count))

	const tone = switch count {
		case 0: "idle"
		case n if (n > 10): "big"
		case _: "counting"
	}

	return <Row gap={8} class="items-baseline">
		<Text>{label}: {count} (x2 = {double}, {tone})</Text>
		<Button onClick={() => count += step}>+{step}</Button>
		{count > 10 && <Text class="text-destructive">big</Text>}
		{items.map(item => <ItemRow key={item.id} {...item}/>)}
		<>
			<Badge variant="secondary">a fragment's child</Badge>
			{/* a comment */}
		</>
	</Row>
}

export async function load(id: String) {
	const plans = await fetchPlans(id)
	return plans.filter(p => !p.soldOut)
}
```

What JavaScript developers get:

- **Automatic semicolon insertion.** A line ends a statement where the
  next line cannot continue it, by JavaScript's rules where they apply.
  Everything being an expression makes ASI harder than in JavaScript, and
  the hazards need explicit rules:
  - a line starting with `(`, `[`, `` ` ``, `+`, `-`, `/` or `<`
    continues the previous one only if the previous line ends in an
    operator or an open bracket; otherwise it is a new statement (so
    `foo()` then `(a, b) => ...` on the next line is two statements,
    where JavaScript would call `foo()`'s result: JavaScript's own trap,
    resolved the other way, with a warning on the ambiguous shape);
  - `return`, `throw`, `break`, `continue` end at the line's end
    (`return` alone on a line returns nothing);
  - a block-bodied `if`/`switch`/`try` used as a value ends where its
    block ends;
  - semicolons stay allowed everywhere; `hxmc fmt` writes none.
- **Imports and exports as ES modules:**
  - `import { A, B as C } from "pack/Mod"` imports fields or types from a
    module; `import * as M from "pack/Mod"` names the module;
    `import Mod from "pack/Mod"` imports its main type;
  - paths are module paths (`"hxmc/ui"` is `hxmc.ui`), `"./x"` relative
    to the file's package; no npm resolution;
  - `export` marks what other modules see; anything not exported is
    `private`, the inverse of Haxe's default.
- **Declarations:** `const` is `final`, `let` is `var`; `function` at
  module level is a module-level function; `type X = {...}` is a
  typedef; `enum` stays Haxe's (algebraic, with arguments).
- **Expressions:**
  - arrow functions `(a, b) => expr` and `x => { ... }` beside Haxe's
    `->`;
  - template literals `` `Hello ${name}` `` (Haxe's interpolation, also in
    double quotes);
  - `===` and `!==` as `==` and `!=` (Haxe's equality has no coercion to
    guard against), `?.`, `?.()`, `??`, `??=`, `**`;
  - spreads in arrays, objects and calls (`[...a, x]`, `{...o, k: v}`,
    `f(...args)`), object shorthand (`{ label, step }`), destructuring in
    `const`/`let` and parameters, with defaults;
  - `for (const x of xs)` beside `for (x in xs)`; `async`/`await` (Haxe
    5's coroutines); `typeof`-free: Haxe's `is` and `switch` patterns.
- **Kept from Haxe:** everything is an expression (`const x = if (a) 1
  else 2`, blocks as values), `switch` with patterns, guards, extractors
  and exhaustiveness, `enum` with arguments, abstracts, macros, `untyped`.
- **Full JSX**, parsed as JSX, not captured as text the way Haxe's inline
  markup is: closing tags, self-closing tags, fragments `<>…</>`,
  `{...spread}`, `{/* comments */}`, markup nested anywhere, attributes in
  JSX's forms. Generic type parameters and JSX are told apart as TSX does
  (`<T,>(x: T) => x` for a generic arrow).
- **State as Svelte 5's runes:** `$state`, `$derived`, `$effect`; reads and
  writes are plain (`count += step`), no `.value`, no getter calls.
- **React's idioms are reactive:** `{cond && <X/>}`, `{c ? <A/> : <B/>}`
  and a `switch` in a hole become `Show`/`Switch`;
  `{items.map(i => <Row key={...}/>)}` becomes a keyed `For` (only inside
  JSX: `.map` elsewhere is an array's map).
- **Styles:** `class="..."` (Tailwind compiled at build time, so shadcn's
  and React code's classes paste in), `style={{backgroundColor: ...,
  width: 300}}` (React's camelCase object, typed against the engine's
  properties, bound when it reads state), and a component's own CSS in a
  `.css` file beside it, scoped to it as CSS modules are (candidate A's
  CSS rules apply to it).

What needs tinkering:

- ASI with everything-is-an-expression: the continuation rules above are
  a starting point; they need a corpus of real code (the port's sources
  run through `hxmc fmt` with semicolons removed, then parsed back to the
  same AST) before they are trusted.
- JSX against Haxe: `<` as comparison, generics, and markup; `{` as a
  block, an object literal, or a JSX hole; arrow functions against
  parenthesised expressions.
- The run-once trap is sharper here, since the code looks like React:
  `if (count > 10) return <A/>` at a component's top does not update.
  The compiler rejects reads of state outside reactive positions, with a
  message naming `&&`, a ternary or `Show`.
- `export` against Haxe's public by default: inside `.hxv` files the
  default flips; a `.hx` module importing from a `.hxv` one sees only
  what it exports.
- Two arrow syntaxes and two loop forms: accepted, with `hxmc fmt`
  normalising to one per project.

### Tooling, from the same grammar files

- The parser: one hook in `Grammar.hx` at the statement, call, modifier
  and prefix-expression entry points, trying the enabled rules before
  "unexpected token"; errors named by the rule.
- A VS Code extension in the library: highlighting generated from the
  grammar files, and a language server of ours (the compiler's display
  through its own parser). vshaxe parses files itself for outlines and
  folding, so it cannot serve `.hxv`; ours should serve `.hx` too, so a
  project runs one compilation server, not two.
- `hxmc fmt` on our parser (haxe-formatter has its own and cannot be
  extended); the parser keeps comments and blank lines for it.
- Completion for CSS property names and values (the engine's list),
  Tailwind classes (`Tw`'s), widget properties (the component's argument
  type) and variants (the widget's or the theme's).
- Everything that finds sources by extension learns `.hxv`: `hxmc dev`'s
  watcher, the module cache's file checks, the compilation server,
  `-cp` scanning, the doc generator.

## Order, if taken

1. The plain-Haxe forms and their macros (`@:state`, `@:derived`,
   arguments as props, `if`/`for` in holes), working with stock Haxe:
   needed whatever the surface, and they prove the semantics.
2. The parser hook, grammar files, `.hxv` and `hxmc desugar`.
3. Both candidate surfaces as plugins, enough to write one screen (a
   form, the Counter, a gallery widget, a list with async loading) in
   each, and in today's markup, to compare; B's ASI and JSX rules checked
   against a corpus of real code first. Pick one.
4. Tooling: highlighting, our language server, `hxmc fmt`, completion.
5. Themes as CSS; the widgets and examples moved over (mechanically, with
   a converter from markup); markup retired, one implementation.
6. The async plugin on Haxe 5's coroutines.

## Open questions

- Candidate A or B: A's element blocks tool and format better and match
  the run-once semantics; B is familiar to most developers, takes React,
  Solid and shadcn code nearly as is, and is better for prose. Decide on
  step 3's comparison.
- For B: how much of TypeScript to take (each item has to map onto a
  Haxe meaning, not just parse), and whether ASI's rules hold on real
  code.
- Whether to keep Tailwind's `class:` beside CSS (one engine, two ways to
  say a thing) or CSS only.
- The cost of owning a language server and a formatter next to the
  compiler; without them the syntax is worse than plain Haxe.
- Third-party tools (dox, haxelib packaging, other test runners) do not
  read `.hxv`: libraries ship `hxmc desugar`'s output.
- Grammar discipline: every rule must take only what is an error today
  and earn its place, or the language drifts.
- Names: `component`, `state`, `derived`, `effect`, the `.hxv` extension.
