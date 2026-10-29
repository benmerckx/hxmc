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
- **Selectors derived from parameter names**, so declarations read like
  Objective-C's and a generator can emit them without metadata in the
  common case; `@:selector` for the rest. Swift's renaming (omit needless
  words) was not followed: it is a rule set of its own.

## Open, in order

1. **Corpus cases** for what the scratch tests checked (messages, structs
   by value, properties, constructors and overloads, classrefs and
   selrefs, Haxe subclasses called by AppKit, toggle references, ownership
   in fields, statics, boxes and through collections), macOS only; `make
   check`, `fixpoint` and `crosshost` before any of it lands.
2. **`LowerQueries`**: `ClassInfo.objc` and `idFields` are computed by
   `Lower` and read by `FnLower` outside the logged queries, so the
   compilation server could replay a body against changed declarations.
3. **Declarations from the SDK's headers.** clang's AST
   (`clang -fsyntax-only -Xclang -ast-dump=json`, 4.5 s and 400 MB for
   AppKit with what it imports) read by a tool in Haxe, emitting
   declarations in the syntax above: categories merged per class,
   `NS_ENUM` and `NS_OPTIONS` as enum abstracts, nullability, availability
   (`@:deprecated`), `instancetype` as each class's own type. Open: names
   of class and instance methods that collide (`+description`,
   `-description`), initializers with the same parameter types, protocols
   as types, lightweight generics. Only declarations, never the headers'
   comments (Apple's SDK terms); clang is needed when generating only.
4. **Blocks** from closures: a block whose invoke function finds the
   closure, copy and dispose helpers that keep it alive while Objective-C
   holds the block, and `id`s a closure captures holding references.
5. **Release on death for every object with `TId` slots**: today a
   constructor registers its class's own `id` fields (`rt_objc_own`);
   closures and anonymous objects need the same. A layout flag (Facts)
   and a list of such objects walked after each collection would replace
   the registration.
6. **`super.f()`** to an Objective-C method (`objc_msgSendSuper`), and Haxe
   classes extending Haxe classes that extend Objective-C ones (the class
   to allocate is the instance's own, registered with its superclass's).
7. **Pools**: one around `main` and the threads hxmc starts, and an
   `autoreleasepool(() -> ...)` for long loops.
8. **x86-64**: `objc_msgSend_stret` for struct results over 16 bytes and
   `objc_msgSend_fpret` (targets.md lists them for Metal and the x86-64 iOS
   simulator).
9. **Smaller gaps**: struct results of Haxe methods Objective-C calls;
   `dealloc` (its peer entry is gone when it runs); registration from two
   threads at once; `hx_dyn_eq` on two boxes of one `id`; reading retain
   counts while another thread is stopped inside libobjc holding its
   lock.

## Considered, not decided

- **Delegates as object literals**: a protocol as a structural type of
  optional functions, `panel.delegate = {windowDidResignKey: _ -> hide()}`,
  each literal's shape an Objective-C class implementing exactly its
  fields, kept alive as an associated object of its owner (Cocoa's
  delegates are weak). Or methods assigned one by one, as event handlers.
  To be judged on real code first.
