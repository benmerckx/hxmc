# ml2hx: OCaml (typed trees) to Haxe

`ml2hx` turns the typed trees of an OCaml project (the pinned Haxe compiler in
`haxe/upstream`) into Haxe. Spec: `docs/plans/haxe-versions.md`.

```
 dune build @check (.cmt)  -->  frontend (OCaml, compiler-libs)  -->  JSON IR
                                                                       |
                                     emit.mjs + generate.mjs  <--------+
                                              |
                     bin/ml2hx/generated  (Haxe; calls ml2hx.rt.* and ml2hx.std.*)
```

Unsupported constructs are errors, never `Dynamic` or stubs. A library
function the runtime does not provide is reported, not stubbed.

## Ownership

| Path | Owner |
| --- | --- |
| `frontend/`, `emit.mjs`, `generate.mjs`, `test/` | the emitter (branch `hv-emit`) |
| `runtime/ml2hx/rt/` (core representations: the types below, `Exn`, structural equality/compare/hash) | the emitter |
| `runtime/ml2hx/std/` (the OCaml library: Stdlib modules, Str, Unix, Extlib, sha, ...) | the runtime (branch `hv-rt`) |

## The naming contract (emitter <-> runtime)

### Library modules

A *library module* is any module not compiled from the converted tree:
OCaml's `Stdlib` and its submodules, and libraries (Str, Unix, Extlib's
`ExtString`/`ExtList`/`IO`/`DynArray`/`PMap`/..., `Sha1`, `Sedlexing`, ...).

| OCaml | Haxe |
| --- | --- |
| module `M` (also `Stdlib.M`) | class `ml2hx.std.M` in `ml2hx/std/M.hx` |
| submodule `M.N` | class `ml2hx.std.M_N` in `ml2hx/std/M_N.hx` |
| a value of `Stdlib` itself (`print_endline`, `max_int`) | `ml2hx.std.Stdlib.printEndline`, `ml2hx.std.Stdlib.maxInt` |
| value `M.f` | static `ml2hx.std.M.f`, name mapped as below |
| type `M.t`, `M.foo_bar` | module-level type `ml2hx.std.M.T`, `ml2hx.std.M.FooBar` (in `M.hx`) |
| exception `M.E` | class `ml2hx.std.M.EExn extends ml2hx.rt.Exn` (in `M.hx`) |
| functor `M.F` | class `ml2hx.std.M.F` (in `M.hx`); see Functors |

Value names: `snake_case` becomes `camelCase` (`find_opt` -> `findOpt`), a
trailing or inner `'` becomes `_` (`x'` -> `x_`), and a Haxe keyword gets the
suffix `Value` (`new` -> `newValue`, `in` -> `inValue`). Operators are named
`op` followed by the names of their characters: `!` Bang, `$` Dollar,
`%` Percent, `&` Amp, `*` Star, `+` Plus, `-` Minus, `.` Dot, `/` Slash,
`:` Colon, `<` Lt, `=` Eq, `>` Gt, `?` Qmark, `@` At, `^` Caret, `|` Bar,
`~` Tilde, `#` Hash (`( @ )` -> `opAt`, `( ^^ )` -> `opCaretCaret`). The
emitter inlines the arithmetic, comparison, boolean, string-concatenation,
reference and application operators, so only the rest reach `ml2hx.std`.

Type names: the same mapping, capitalised (`t` -> `T`, `in_channel` -> `InChannel`).

### Calling convention

- A library value whose declared type (the `val` in the `.mli`, type
  abbreviations not expanded) has `n` top-level arrows is a static function
  with `n` parameters, called fully applied as `M.f(a1, ..., an)`. The emitter
  makes closures for partial applications and applies extra arguments to the
  result. A value with no arrow (`max_int`, `stdout`, or a type abbreviation
  of a function) is a static variable.
- Labelled `~x` parameters are positional, in declaration order. Optional
  `?x:t` parameters are positional too, typed `ml2hx.rt.MlOption<T>`; the
  emitter passes `None` when the caller omits them.
- Function *values* (callbacks, closures in data) are curried single-argument
  Haxe functions: OCaml `'a -> 'b -> 'c` is Haxe `(A) -> ((B) -> C)`. So
  `List.fold_left` is
  `static function foldLeft<A, B>(f:(A) -> ((B) -> A), init:A, l:MlList<B>):A`.
- Type parameters are the OCaml type variables of the declared type, in order
  of first occurrence, named freely.

### Representations (owned by the emitter, in `ml2hx.rt`)

| OCaml | Haxe |
| --- | --- |
| `int` | `Int` (Haxe `Int`; `ml2hx.rt.Int63` only where a config marks 63-bit semantics as observable; library functions always use `Int`) |
| `char` | `Int` (0..255) |
| `string` | `String` whose code units are bytes 0..255 (no UTF-8 decoding) |
| `bytes` | `haxe.io.Bytes` |
| `float`, `bool` | `Float`, `Bool` |
| `unit` | `ml2hx.rt.Unit`, the value `ml2hx.rt.Unit.value` |
| `'a list` | `ml2hx.rt.MlList<A>` (`Nil`, `Cons(head, tail)`) |
| `'a option` | `ml2hx.rt.MlOption<A>` (`None`, `Some(value)`) |
| `'a ref` | `ml2hx.rt.Ref<A>` (`value` field) |
| `'a array` | `Array<A>` |
| `a * b * ...` | `ml2hx.rt.TupleN<A, B, ...>` (fields `v0`, `v1`, ...; constructor in order), N = 2..12 |
| `int32`, `int64`, `nativeint` | `haxe.Int32`, `haxe.Int64`, `Int` |
| `exn` | `ml2hx.rt.Exn` (extends `haxe.Exception`) |
| `'a Lazy.t` | `ml2hx.rt.Lazy<A>` |
| records | classes: fields camelCased, `new` takes the fields in declaration order, mutable fields `var`, others `final` |
| variants | enums with the OCaml constructor names, positional arguments `v0`, `v1`, ... |

Predefined exceptions are in `ml2hx.rt`: `NotFoundExn`, `FailureExn(v0:String)`,
`InvalidArgumentExn(v0:String)`, `EndOfFileExn`, `DivisionByZeroExn`,
`SysErrorExn(v0:String)`, `MatchFailureExn`, `AssertFailureExn`,
`StackOverflowExn`, `OutOfMemoryExn`, `SysBlockedIoExn`,
`UndefinedRecursiveModuleExn`. Payloads are fields `v0`, `v1`, ...; the
constructor takes them in order. `Stdlib.Exit` is `ml2hx.std.Stdlib.ExitExn`.

Structural operations: `ml2hx.rt.Runtime.equal(a, b):Bool`,
`ml2hx.rt.Runtime.compare(a, b):Int`, `ml2hx.rt.Runtime.hash(a):Int`, with
OCaml's semantics over the representations above (`Hashtbl.hash` is
`Runtime.hash`).

### Functors

A library functor `M.F` applied to a module `X`, `M.F(X)`, is
`new ml2hx.std.M.F<T1, ..., Tk>(v1, ..., vn)`: `T1..Tk` are the abstract types
of the parameter signature as `X` instantiates them, `v1..vn` are `X`'s values
in the order of the parameter signature (curried closures). The result's
values are instance methods (same naming and arity rules); its type `t` is
`ml2hx.std.M.F_T<T1, ..., Tk, params...>` (a typedef is fine), and types the
result defines as equal to the parameter's (`key`, `elt`) are expanded by the
emitter. Example: `module SMap = Map.Make(String)` is
`new ml2hx.std.Map.Make<String>(compare)`, `'a SMap.t` is
`ml2hx.std.Map.Make_T<String, A>`, `SMap.add k v m` is `sMap.add(k, v, m)`.

### Converted modules

The converted tree's own modules: `src/dir/foo.ml` is class
`upstream.dir.FooModule` (`upstream.dir.FooModule.T` for its type `t`;
submodules flattened as `FooModule_Sub`). This side is internal to the
emitter.
