# OCaml library runtime: inventory and state

What the compiler's OCaml (haxe/upstream at fef284737, `dune build @check`)
uses of OCaml's libraries, and where the Haxe runtime (`ml2hx/rt`, `ml2hx/std`)
stands. Handed over mid-work (step 2 of docs/plans/haxe-versions.md).

## How the inventory is made

`inventory/inventory.ml` walks the typed trees (.cmt) and counts every
identifier, constructor, record label, exception and functor application
declared outside the compiled sources (a declaration is the project's when its
file exists under the checkout or its `_build/default`):

```
eval $(opam env)
ocamlfind ocamlc -package compiler-libs.common -linkpkg inventory.ml -o inventory
B=bin/ml2hx/checkouts/<sha>   # generate.mjs's prepare(): clone + dune build @check
./inventory -root $B -root $B/_build/default $(find $B/_build/default -name '*.cmt' | grep -v prebuild) > inventory.tsv
```

`inventory/inventory.tsv` (committed): kind, declaring file, name, uses, first site.

## Size

1505 distinct library items: 1205 values, 84 constructors (most are
CamlinternalFormatBasics: the format literals), 131 record fields (Unix,
Gc, luv), 21 exceptions, 4 functors (Hashtbl.Make 6, Map.Make 4, Set.Make 2,
Ephemeron.K1.Make 1), 60 `external` primitives declared in upstream's own
libs (extc, objsize, ...). Functor instances' values are counted under the
instance (`Globals.IntMap.add`...).

Values by module (distinct, total uses):

| module | values | uses | | module | values | uses |
|---|---|---|---|---|---|---|
| Stdlib | 119 | 23633 | | Unix | 58 | 216 |
| List | 43 | 4392 | | Obj | 10 | 194 |
| Array | 23 | 1446 | | ExtList.List | 19 | 163 |
| String | 20 | 1332 | | Int64 | 25 | 126 |
| Sedlexing | 12 | 1280 | | Mutex | 5 | 112 |
| Printf | 7 | 1127 | | Sys | 21 | 105 |
| IO (extlib) | 57 | 1102 | | Str | 15 | 75 |
| Hashtbl | 26 | 1085 | | Atomic | 6 | 61 |
| PMap (extlib) | 13 | 816 | | Filename | 6 | 42 |
| DynArray (extlib) | 19 | 558 | | Std (extlib) | 4 | 41 |
| Int32 | 29 | 530 | | Digest | 4 | 41 |
| Stream (camlp-streams) | 5 | 521 | | Signed/Unsigned (integers) | 55 | 75 |
| Buffer | 13 | 418 | | Printexc | 10 | 39 |
| Luv | 313 | 343 | | Gc | 14 | 26 |
| ExtString.String | 28 | 288 | | Thread/Event/Condition/Semaphore/Domain | 27 | 74 |
| Option (extlib) | 6 | 287 | | Pcre2, Ipaddr, Sha1, Xml, Dynlink, Effect, Marshal, Scanf, Format, Random, Queue, Stack, ... | small | |
| Bytes | 18 | 277 | | | | |
| Char | 6 | 273 | | | | |

Exceptions used: Not_found 1056, Exit 372, Stream.Failure 337, Stream.Error
224, Invalid_argument 38, Failure 30, Unix.Unix_error 26, Sys_error 21,
Arg.Bad 14, End_of_file 12, IO.No_more_input 8, ExtString.Invalid_string 5,
Stack_overflow, Out_of_memory, IO.Overflow, Sedlexing.MalFormed,
Pcre2.Error, Sys.Break, Option.No_value, Dynlink.Error, Division_by_zero.

Format conversions in literals: %s 2646, %d 453, %i 194, %ld 24, %b 20,
%S 13, %.2X 12, %X 10, padded/zero-padded ints, %c 5, a few %f/%.Ng; no %a,
%t, ^^, Format boxes (Format: pp_print_string only), Scanf: one sscanf "%d.%d.%d.%d".

## Contract (my side; reconcile with tools/ml2hx/README.md)

- Value `M.f` -> `ml2hx.std.M.f`, emit.mjs's `camel` (keywords get `Value`:
  extlib `Option.default` -> `defaultValue`, `Seq.return` -> `returnValue`;
  `get_utf_8_uchar` -> `getUtf_8Uchar`). Operators: `( + )` opAdd, `-` opSub,
  `*` opMul, `/` opDiv, `~-` opNeg, `+.` opAddF ... `**` opPow, `=` opEq,
  `<>` opNe, `==` opPhysEq, `!=` opPhysNe, `<` opLt, `>` opGt, `<=` opLe,
  `>=` opGe, `&&` opAnd, `||` opOr, `^` opConcat, `@` opAppend, `!` opDeref,
  `:=` opAssign, `|>` opPipe, `@@` opApply. `mod land lor lxor lnot lsl lsr asr` as named.
- Library functions are plain static Haxe functions taking all arguments;
  function parameters are *uncurried* to the arity of the library's .mli
  (`List.fold_left f`: `(A, B) -> A`). Optional args go last as Haxe optional args.
- Types: Haxe types are named per package, so OCaml type `M.t` -> `ml2hx.std.M.MT`
  style: `Hashtbl.t` -> `HashtblT`, `Buffer.t` -> `BufferT`, `Seq.t`/`node` ->
  `SeqT`/`SeqNode`, `Stdlib.out_channel` -> `StdlibOutChannel`, `result` -> `StdlibResult`.
  Exceptions likewise (`Option.No_value` -> `OptionNoValue`); predefined ones
  are `ml2hx.rt.NotFound`, `Failure`, `InvalidArgument`, `Exit`, `EndOfFile`,
  `DivisionByZero`, `SysError`, `MatchFailure`, `AssertFailure`, ... (all
  extend `ml2hx.rt.MlException`, constant ones raised as `.instance`).
- Functors: `M.F(A)` -> `ml2hx.std.M.F(a)` (static function), the argument an
  anonymous structure of uncurried functions (`{equal, hash}`, `{compare}`),
  the result an instance (`HashtblMake<K>`, `MapMake<K>`, `SetMake<E>`) whose
  methods are the result signature's values; polymorphic constants are
  zero-argument generic methods (`IntMap.empty()`).
- Representations: int = `ml2hx.rt.Int63` (as emit.mjs), char = Int, string =
  Haxe String with one unit per byte (hxmc strings are UTF-16 internally;
  units 0-255 are the bytes; `ml2hx.rt.ByteString` converts at the host
  boundary, as UTF-8), bytes = `haxe.io.Bytes`, records/tuples/refs implement
  `ml2hx.rt.Block` (for polymorphic compare/hash), empty runtime trees are null.
- Printf: format literal -> `ml2hx.rt.Fmt.of("...")` (cached parse), args as
  `Array<Dynamic>`: `Printf.sprintf(fmt, [a, b])`; %a/%t printers uncurried.
- Extlib's `Option` shadows Stdlib's in the compiler: `ml2hx.std.Option` has
  extlib's semantics (get raises Option.No_value) plus Stdlib's other values.

## Done (compiles on hxmc with `--macro include("ml2hx")`; only a smoke test run)

- rt: Int63 (extended: bit ops, shifts incl. 63-bit lsr, float conversions),
  Float64, MlException + predefined exceptions, Block, Tuple2..8, Ref,
  ByteString, Poly (caml_compare incl. nan/total, caml_hash exactly:
  MurmurHash3 mixing, BFS queue, limits 10/100, enum ranks for
  constant/non-constant constructors), FloatFormat (exact %f/%e/%g by big
  decimal, round-half-even; string_of_float; float_of_string syntax incl.
  hex/inf/nan/_), Fmt (format parser, int/float/string conversions,
  fix_padding/fix_int_precision/'#' grouping as CamlinternalFormat).
- std: Stdlib (operators, ints incl. parse_intnat, floats, channels,
  at_exit/exit), List (all of list.ml; stable_sort ported comparison for
  comparison), Array (heap sort and merge sort ported), String, Bytes,
  Buffer, Char, Uchar, Seq, Option, Hashtbl (generic + Make/MakeSeeded:
  OCaml's buckets, head insertion, in-place order-preserving resize,
  traversal flag), Map.Make, Set.Make (AVL ported), Printf, Printexc.

## In progress

- Tests against OCaml: harness started (`test/RtTest.hx`, built by
  `bin/hxmc/hxmc bin/ml2hx/rt/rttest -cp tools/ml2hx/runtime -cp tools/ml2hx/runtime/test -main RtTest -cp bin/hxmc/std --custom-target hxmc`).
  `test/printf.cases` (1951 cases) + `test/printf.ml` exist; OCaml runs them
  (output not committed yet: generate `printf.expected` with
  `ocamlfind ocamlopt -package str -linkpkg printf.ml && ./a.out tools/ml2hx/runtime/test`).
  The Haxe side of printf (RtTest "printf") is not written.
- Fmt still lacks OCaml's legacy format rules found from that run:
  `%x`/`%u`/`%o` of an int print its 63 bits unsigned (-1 -> 7fffffffffffffff,
  not 64-bit); for %s/%S a precision without width is the width (`%.3s` =
  `%3s`, `%-.3s` left); '0' with '-' is Left; '0' with a precision on ints is
  Right (spaces); '0' on %s/%B is Right; '#' is ignored for f/e/g (only %#F
  is special); widths on %c are ignored; '.' with no digits is .0.
- List.sort_uniq keeps the first of equal runs (OCaml's merge picks h1: same
  elements for equal-under-cmp, may differ physically): port exactly.

## Next

1. Finish Fmt legacy rules, printf.expected, Haxe printf test; tests for
   Hashtbl order (LCG workloads, generic string/int/tuple keys and Make),
   Hashtbl.hash values, compare, float_of_string/string_of_float/int_of_string,
   List/Array sorts with counting comparators, Map/Set, String/Bytes/Buffer.
2. `test/run.mjs` + `make ml2hx-rt-check` (build rttest with the tool, diff
   each test against `<name>.expected`; with OCaml present, also check the
   expected files against OCaml), wired into .github/workflows/ml2hx.yml.
3. Remaining modules by uses: Sedlexing, IO, PMap, DynArray, Int32, Stream,
   ExtString/ExtList/ExtArray, Int64, Sys, Filename, Unix subset, Str,
   Obj (magic/repr), Digest (MD5), Sha1, Std (extlib), Mutex/Thread/Atomic
   (single-threaded), Gc (stats), Queue/Stack/Random/Lazy, Signed/Unsigned.
   Gaps by design for now: Luv (313 values, eval's async API), Pcre2, Dynlink,
   Effect, Marshal, Domainslib.
4. Benchmarks (Hashtbl, Buffer, Printf, List) against OCaml native.

Known approximations: int32 values hash as immediates (OCaml: custom block),
int64 values hash as ints; backtraces are empty.
