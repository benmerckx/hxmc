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

## Open, in order

1. **Declarations from the SDK's headers.** clang's AST
   (`clang -fsyntax-only -Xclang -ast-dump=json`, 4.5 s and 400 MB for
   AppKit with what it imports) read by a tool in Haxe, emitting
   declarations in the syntax above: categories merged per class,
   `NS_ENUM` and `NS_OPTIONS` as enum abstracts, nullability, availability
   (`@:deprecated`), `instancetype` as each class's own type (`alloc` per
   class, inherited initializers and other `instancetype` methods
   redeclared with `override`), `NS_UNAVAILABLE` left out. Properties as
   `var x(get, set)` with extern accessors (selectors derived: `get_x` is
   `x`, `set_x` `setX:`; `@:selector` for `getter=` and `setter=`), so a
   Haxe subclass can override them (`isFlipped` is a property). A member a
   category of another framework declares (Foundation's `-description` on
   NSObject) loads that framework: a classref loads only the class's own,
   so the member needs one too. Open: protocols as types, lightweight
   generics. A class method and an instance method of one name are fine
   (Haxe allows both on an extern). Only declarations, never the headers'
   comments (Apple's SDK terms); clang is needed when generating only.
2. **Blocks** from closures: a block whose invoke function finds the
   closure, copy and dispose helpers that keep it alive while Objective-C
   holds the block, and `id`s a closure captures holding references.
3. **Release on death for every object with `TId` slots**: today a
   constructor registers its class's own `id` fields (`rt_objc_own`);
   closures and anonymous objects need the same. A layout flag (Facts)
   and a list of such objects walked after each collection would replace
   the registration.
4. **x86-64**: `objc_msgSend_stret` for struct results over 16 bytes and
   `objc_msgSend_fpret` (targets.md lists them for Metal and the x86-64 iOS
   simulator).
5. **Smaller gaps**: `dealloc` (its peer entry is gone when it runs); registration from two
   threads at once; a pool around `main` (nothing gained: it drains at exit); `hx_dyn_eq` on two boxes of one `id`; reading retain
   counts while another thread is stopped inside libobjc holding its
   lock.

## Considered, not decided

- **Delegates as object literals**: a protocol as a structural type of
  optional functions, `panel.delegate = {windowDidResignKey: _ -> hide()}`,
  each literal's shape an Objective-C class implementing exactly its
  fields, kept alive as an associated object of its owner (Cocoa's
  delegates are weak). Or methods assigned one by one, as event handlers.
  To be judged on real code first.
