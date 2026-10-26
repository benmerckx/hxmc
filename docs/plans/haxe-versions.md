# Plans: any Haxe version (parked)

**Parked** ([#10](https://github.com/benmerckx/hxmc/issues/10)). The port
stays hand-written and follows upstream forward, one pinned commit at a
time (now Haxe 5.0.0-preview.1 at `066bd83`, with about 1,960 `// port:`
comments where it differs from upstream).

The parked idea: generate the compiler from upstream's OCaml (ml2hx) for
any release from 4.0, chosen per project, with hxmc's changes kept as
overlays and a stable compiler API facade for the back end. It was set
aside because generation takes a lot of work and would tune the target
towards OCaml's semantics to reach upstream's speed. The draft PRs #5
(ml2hx) and #9 hold where it got to.

Revisit only if following upstream by hand stops scaling. A generated
compiler would need to pass the same conformance lanes per version and
stay within 5% of the hand-written port's speed.
