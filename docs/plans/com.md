# Plans: COM

Open work on COM interop. What is built:
[interop.md](../interop.md#com). The decisions behind it come first, with
what was weighed against them: a change to the design should answer them.

## Decisions

- **In the compiler, as Objective-C is** ([objc.md](objc.md)). A call is a
  C call of the vtable's slot with the receiver first, in the C types of
  the method at each site (struct arguments by value, MSVC's struct results
  of C++ methods through a pointer after `this`), each signature an
  indirect C function of its own; a Haxe class's vtables point at thunks the
  compiler makes from the class's methods. A macro over C calls could do the
  calls, not the thunks or the conversions at both ends.
- **Values are Haxe references, not a type of their own.** A COM value is
  a foreign object's box (`hxmc.rt.Foreign`: one per interface pointer,
  holding a reference, released once collected) or a Haxe object
  implementing the interface. Objective-C's `TId` (an `id` in every
  position, owned by fields, borrowed by locals, autoreleased results) was
  weighed: it saves an allocation per object result, but it needs
  ownership at every store (fields, captures, boxes), which COM's
  `AddRef`/`Release` would make an indirect call each, and COM has no
  autorelease pool to make results borrowed. With references, Haxe's
  storage is Haxe's: nothing changes in fields, closures, arrays, maps,
  `Dynamic` or type parameters.
- **One value per interface pointer, identity by `QueryInterface(IID_IUnknown)`.**
  A box calls through its own pointer's vtable, so two interfaces of one
  object are two boxes; the kind's identity key (the canonical IUnknown)
  and its `same` test (the pointer) keep a box per pointer while the boxes
  of one object share their key. `==` compares values; `Com.same` objects.
- **`HRESULT`s are exceptions by default**, as .NET's interop and C++/WinRT
  have them (`PreserveSig = false`, `check_hresult`): the `[out, retval]`
  parameter is the result. `@:hxmc.com.hresult` keeps the HRESULT (S_FALSE
  and other success codes matter for some methods), `@:hxmc.com.direct`
  is a method that returns no HRESULT at all (DirectWrite's getters).
- **The toggle is TOGGLE_RELEASE on the runtime's own counts.** IUnknown
  has no count query, so a Haxe object's COM object keeps its count in the
  runtime's memory (its block), and the toggle's AddRef and Release, made
  with the world stopped, are the runtime's functions: no foreign code runs
  in the stop.
- **Releases on the maker's thread** (RELEASE_ON_MAKER), for every COM
  value: an apartment-threaded object's Release belongs to its apartment,
  and the runtime does not know an object's threading model (a proxy, an
  in-process STA object, a free-threaded one look the same). A blocked
  message loop is woken with a thread message (`Com.WM_DEFERRED`, the
  kind's wake hook); an ended thread's go to any thread (its proxies were
  disconnected by its `CoUninitialize`).
- **Apartments are the program's**: `Com.init(apartment)` on each thread,
  as C++ calls `CoInitializeEx`. An implicit call (at a thread's first COM
  call, or at start) was weighed: the apartment's kind is the program's
  choice (a UI thread's STA, a worker's MTA) and a thread already in the
  other kind fails (RPC_E_CHANGED_MODE); a library initializing COM behind
  the program's back is the classic COM bug.
- **The identity query is made outside a safe region**: a proxy's
  `QueryInterface(IID_IUnknown)` is its proxy manager's, answered in the
  calling apartment. A foreign object's last `Release` (a proxy's makes a
  call to its apartment; a destructor may call back into Haxe) is made in
  a safe region.
- **Other systems compile COM code and throw** (`E_NOTIMPL`): the typed
  program (its archive) is one for every native target, so a compile error
  on Linux would reject a program that tests the system at run time.

## Open, in order

1. **Declarations from Windows' metadata**: a separate tool, as
   [hxmc-objc-extern-gen](https://github.com/back2dos/hxmc-objc-extern-gen)
   is Objective-C's: Win32's interfaces, structs, enums and functions from
   win32metadata's `Windows.Win32.winmd` (the slots in order, `[out,
   retval]` and `PreserveSig` from its attributes, C++'s overloads renamed).
   Writing the vtables of IFileDialog or IDWriteTextLayout by hand is what
   this removes.
2. **WinRT**: `HSTRING`s, `IInspectable`, activation factories
   (`RoGetActivationFactory`), async operations as Haxe's, events and
   delegates, `IWeakReferenceSource` for weak fields and detach of peers
   (the kind's weak hooks), from the `.winmd`s of the Windows SDK by the
   same generator.
3. **Haxe objects across apartments**: a Haxe object's COM object is
   called on any thread; one passed to another apartment is marshaled by
   COM's standard marshaler (a proxy: calls on the apartment's thread).
   Aggregating the free-threaded marshaler (`IMarshal`) would let it be
   called directly from every apartment, as an agile WinRT object is.
4. **Smaller gaps**: a typed out parameter (`Out<T>`: a frame's slot,
   read back, an interface's adopted) beside `Ptr`; `IDispatch` and
   automation (`Invoke` with `DISPPARAMS`), `SAFEARRAY`, the other
   `VARIANT` types; connection points
   (`IConnectionPointContainer`) as Haxe events; a COM method as a value;
   aggregation (a Haxe object as an outer object); `RT_STATS` counts of COM
   objects.
5. **Cheaper calls**: the interface pointer of a box read inline (a
   `rt_com_ptr` call per call now), the safe region's fast path inline (as
   Objective-C's messages want: objc.md, open item 1).
