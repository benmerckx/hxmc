# Plans: Objective-C

Open work on Objective-C interop. What is built:
[interop.md](../interop.md#objective-c). The decisions behind it come
first, with what was weighed against them: a change to the design should
answer them.

## Decisions

- **In the compiler, not macros over C calls.** Typed messages need the
  call's C types at each site (structs by value, x86-64's `_stret`), clang's
  selector and class references in the Mach-O, entries for Haxe methods
  that find their Haxe object, and stores that know an `id` from an
  integer: all are the compiler's. helder's `Sender` shapes (one
  `@:hxmc.indirect` extern per signature) did messages from a macro; the
  rest cannot be.
- **The GC for Haxe objects, reference counting only where references
  cross.** ARC for every Haxe object was weighed: Haxe code assumes a
  tracing collector (cycles: parent pointers, closures capturing `this`),
  libobjc exists only on Apple's systems, and every reference copy would
  pay an atomic. The hybrid keeps Haxe code as it is and pays only where
  an `id` is stored.
- **Toggle references for Haxe classes extending Objective-C ones**
  (Xamarin's): the Haxe object is a root exactly while Objective-C retains
  its object beyond the Haxe object's own reference, read from the retain
  count during a collection. lowlevel.md's `Handle` is a stable token for
  C, which says nothing of who keeps whom alive; the peers' table holds
  what a handle would.
- **`id` is its own IR type (`TId`), not an abstract.** An abstract over
  `Int64` has no hook where ownership happens: a store to another class's
  field, a store inside generic code (`Map.set`, where the type is `T`),
  an object's death. The typed AST still knows `NSView`; `Ty` lost it,
  so `coerce`, element types and layout could not. `TId` is `TBool`'s
  pattern: an `i64` everywhere below the lowering, kept apart above it.
  `Lower.boxed(TId)` is a reference, which makes every generic position an
  owning box at once.
- **Borrowed values, owning storage.** Every `id` value is borrowed (results
  that come retained are autoreleased at once); fields, statics and boxes
  retain. Simpler than ARC's tracking of +1 values in locals, at the cost
  of an autorelease per `new`; ARC's optimizations can come later.
- **clang's references, not lookups.** `__objc_classrefs` bound by the
  loader also loads the framework (no `objc_getClass`, no framework
  listed anywhere else); `__objc_selrefs` are made unique by libobjc. A
  class nothing declares a library for is still looked up by name.
- **Classes registered at run time first.** `objc_allocateClassPair` at
  the first construction, as helder's view controller does; static class
  metadata (`__objc_classlist`, `class_ro_t`) can replace it without
  changing the language.
- **Initializers stay `alloc().initX(...)`, not `new`.** `new` with
  overloads by type could not tell `initWithString:` from
  `initWithContentsOfFile:` (both an `NSString`), could not express a
  failable initializer (`new` cannot be null), and would make a generator
  redeclare every inherited initializer as a constructor (Haxe inherits a
  constructor only into a class that declares none). Swift has the same
  problem and solves it by argument labels (`init(string:)`,
  `init(contentsOfFile:)`), which Haxe lacks; as methods, initializers keep
  their names, return `Null<C>` when failable and are inherited. The cost:
  `C.alloc().initWithFrame(r)` is longer, and a subclass redeclares
  inherited initializers for `instancetype`'s result type. Ownership
  follows ARC's families: `alloc`'s +1 is consumed by the initializer, whose
  +1 is autoreleased. A Haxe class extending an Objective-C one has a Haxe
  constructor, which calls `super.initX(...)` as `self = [super initX:...]`.
- **Selectors derived from parameter names**, so declarations read like
  Objective-C's and a generator can emit them without metadata in the
  common case; `@:selector` for the rest. Swift's renaming (omit needless
  words) was not followed: it is a rule set of its own.
- **A block holds an index into the runtime's table of closures, not the
  closure.** The other design built (the closure in the heap block, its
  slot registered by the copy helper as a root, unregistered by dispose)
  made and called blocks as fast (1M made and freed: ~80 ms both; 10M
  calls: ~150 ms both, arm64), but every minor collection walked every
  live block (2.6 ms at 1M), and the collector wrote into libclosure's
  memory. With the table, a minor collection scans only the entries made
  since the last one (0.3 µs at 1M live blocks), and an invoke reads its
  closure with no lock, as entries never move. The cost: a table that
  never shrinks and a ceiling of 4M live blocks; both take a lock as a
  block is made and as it is freed.

- **Objects of Haxe classes Objective-C makes are made by the
  constructor's initializer.** A nib, a document controller or a factory
  sends `[[C alloc] initX:...]`: the initializer the constructor calls on
  super is the class's own, which runs the constructor on the object
  Objective-C allocated (pairing it before the superclass's initializer
  runs, so methods it sends find the Haxe object). Weighed: making
  `+alloc` create the Haxe object with initializers as plain methods (no
  constructors), closer to Objective-C, but every Haxe subclass would
  change and `new` is how Haxe makes objects; and one object instead of
  two (Swift's), which needs the collector to scan Objective-C objects and
  toggle references per object anyway (a view's closure capturing the
  view). The cost: one initializer per class.
- **`dealloc` is a finaliser.** Objective-C's `dealloc` runs after the Haxe
  object is gone (its peer entry freed), so an override runs as
  `Gc.finalise` does, when the pair is unreachable from both sides, and
  Objective-C's own runs afterwards, as ARC's.
- **C's objects (Core Foundation's types) are extern classes implementing
  `Id` without `@:hxmc.objc`**: ids, retained by Haxe's storage as any
  (every CF object is an Objective-C object, `__NSCFType`), without a class
  object (no messages, type tests or Haxe subclasses); `@:hxmc.retained`
  marks a C function's owned result (the Create rule). No marker of its
  own: `implements Id` says what the values are, `@:hxmc.objc` that a class
  object exists.

## Open, in order

1. **Objective-C exceptions.** They unwind through hxmc's frames, which
   have unwind tables but no personality routine, so one ends the
   program. Planned: a personality routine of the runtime's in the CIE,
   which claims an Objective-C exception at the first hxmc frame when a
   Haxe `try` is active and turns it into a Haxe exception (the runtime's
   throw, a longjmp to the handler): no cost per message (a `try` around
   every message would be ~2.5 ns, setjmp's). Apple's frameworks are not
   exception-safe: for reporting and the few APIs that raise for
   expected conditions.
2. **Cheaper messages.** A message is ~8.5 ns on Apple Silicon, ~6 of them
   the safe region (two runtime calls, the thread's record, publishing it);
   `@:hxmc.fast` ones ~2.3. Next: the region's fast path inlined into
   generated code; asymmetric barriers (membarrier, FlushProcessWriteBuffers,
   thread_get_register_pointer_values) for x86-64, whose seq_cst store is
   an XCHG; a list of selectors the extern generator marks `@:hxmc.fast`.
3. **More than one initializer per Haxe class** for Objective-C to make
   objects with (a view in a nib and made with a frame).
4. **Key-value coding for Haxe properties** (Cocoa Bindings, sort
   descriptors, KVO of Haxe objects): registered as Objective-C
   properties, stores notifying.
5. **Release on death by layout**: a constructor registers its class's own
   `id` fields, a closure its captured `id`s, a captured variable's box its
   own (`rt_objc_own`: an entry per slot, appended under a lock; every
   collection walks them all). A layout flag (Facts) and a list of such
   objects, their slots read from a table per type, would make it an
   entry per object: worth it when a program makes many objects with
   several `id`s each.
6. **x86-64 on hardware**: messages with struct results go to
   `objc_msgSend_stret`; CI's Intel Mac runs the corpus once this branch
   is pushed.
7. **Smaller gaps**: an Objective-C method as a value (`o.description`
   without a call: rejected); `Std.isOfType` against a C object's type
   (its `...GetTypeID`); variadic messages of other than objects; reading
   retain counts while another thread is stopped inside libobjc holding
   its lock.

Declarations from the SDK's headers are generated by
[hxmc-objc-extern-gen](https://github.com/back2dos/hxmc-objc-extern-gen)
(Foundation, AppKit, Core Graphics, Core Text, Core Animation, Uniform
Type Identifiers: classes, protocols, lightweight generics, enums, structs,
C functions, constants and objects; what it leaves out, with why, in its
`skipped.txt`).

## Considered, not decided

- **Delegates as object literals**: a protocol as a structural type of
  optional functions, `panel.delegate = {windowDidResignKey: _ -> hide()}`,
  each literal's shape an Objective-C class implementing exactly its
  fields, kept alive as an associated object of its owner (Cocoa's
  delegates are weak). Or methods assigned one by one, as event handlers.
  To be judged on real code first.
