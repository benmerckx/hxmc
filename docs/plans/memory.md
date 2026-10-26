# Memory: where hxmc allocates

What the scoped-memory branches (PRs #63 and #64) measured about
the compiler's and the runtime's allocations, kept where it stands
without them. Scoped memory itself (regions and views checked by the
compiler) is a library now: universe's `packages/scoped`
(<https://github.com/benmerckx/universe>). Measured on one 4-core Linux
VM; wall times are within that VM's noise unless the gap is large.

## The self-build's heap

The census build (`-D hxmc.census`, `RT_CENSUS=1`; docs/hxmc.md) also
counts what minor collections promote, by type. The tool building itself
(cold module cache):

| | |
| --- | ---: |
| allocated | 12.0 GB, 309 M objects |
| promoted by minor collections | 1.24 GB (10.4%) |
| live at exit | 570 MB |

Promoted: NativeArrays 363 MB, the typed AST (`TExpr` and its
`TExprDef`s, `Pos`, `Expr`) about 280 MB (live until lowered), the back
end's own objects (`MIns` 89 MB, `LIns` 34 MB, `Reloc` 23 MB) about 150
MB; most of the back end's 1.4 GB of `MIns` and `LIns` dies young. So
the back end's per-function graphs cost their allocation, not copies or
peak memory: moving them out of the collected heap would save little.

## The old generation's limits

A copying major collection peaks at what the old space holds plus what
is live. `RT_OLD_MB` is the old space's first limit, `RT_OLD_GROWTH` the
next ones, in percent of what a major collection left live (300
natively, 200 on wasm32).

The tool's build, the self-build with a cold module cache, three
interleaved runs each:

| first limit | peak RSS | wall | major collections |
| --- | ---: | ---: | --- |
| 3072 MB (before) | 1.45-1.50 GB | 13.6-15.4 s | none |
| 768 MB (now) | 1.18-1.19 GB | 13.6-14.4 s | one, 0.7-1.3 s |
| 1024 MB | 1.58-1.71 GB | 16.2-19.2 s | one, 2.5-4.2 s |
| 512 MB | 1.89-1.90 GB | 17.5-20.3 s | two |

The compilation server (`hxmc --server`), the self-build sent twelve
times, a module edited before each (it holds about 1.4 GB live, each
warm build promotes about 600 MB):

| first limit / growth | major collections | old space's limit | peak RSS |
| --- | --- | ---: | ---: |
| 4096 MB / 300% (before) | builds 6 and 12 | 4.9 GB | 6.66 GB |
| 4096 MB / 150% (now) | builds 6, 8, 11 | 2.9-3.1 GB | 5.79 GB |
| 2048 MB / 150% | five | 2.6-3.2 GB | 4.78 GB |

The growth bounds the server: at 300% its old space grows toward three
times what is live. At 150% the peak is the first major collection's, at
the first limit; a first limit of 2 GB would lower it to 4.8 GB (open).

## Runtime hot spots

| | before | after |
| --- | ---: | ---: |
| `Array<P>.indexOf`, 1M elements x100, misses (identity: Repr.identityEq) | 1277 ms | 70 ms |
| the same, `lastIndexOf` / `contains` | 1251 / 1308 ms | 57 / 68 ms |
| 1M `Std.string(Float)` (FloatText: no scan past the rounding digit) | 3.77-3.90 s | 2.49-2.51 s |
| 2M `+` chains of 5-7 Strings (`hx_str_concat3`/`4`) | 147-162 ms | 93-107 ms |
| JSON: 4000 objects stringified and parsed, 20 times (`Str.jsonRun`, `StringBuf.addJsonString`) | 530-572 ms | 440-452 ms |

The chains also shrink the tool's text by 0.7%. `Array<Int>` and
`Array<String>` searches are unchanged.

## Tried, not kept

- Array growth from 4 elements instead of 2: -0.3% instructions on the
  formatter's build, +0.5% allocated.
- The passes' per-function tables outside the collected heap: 0.16% of
  the self-build's instructions.
- Opt folding `(x & m) & m`, `x * 1` and the mask of a byte stored, and
  `Ptr<T>[i]` as an indexed access: the tool's text 4.7 KB larger, no
  gain measured outside scoped code.
- Inflate with its state in locals: natively 12% faster, on WasmGC
  slower; a cold path (the compiler's ZIP reader).
