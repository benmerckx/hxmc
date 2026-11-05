# Plans: JNI

Java interop through JNI. What is built: [interop.md](../interop.md#java-jni).
The decisions behind it come first, with what was weighed against them;
then the contract with a packager (helder.pack writes and bundles the Java
glue), then what is next.

## Decisions

- **In the compiler, as COM is** ([com.md](com.md)). A call is lowered to
  calls of the runtime's entry points (`rt_jni_*`, `hxmc.rt.JniKind`):
  enter (the thread's `JNIEnv`, a local frame pushed), the class and the
  member resolved into cells, the arguments stored in a `jvalue` array as
  their C types or as local references, the `Call<Type>MethodA`,
  `NewObjectA` or field function, the result converted, leave. The `A`
  variants only: no varargs. The JNI signature is made from the Haxe types
  (`Jni.value`, `Jni.signature`) where the call is lowered, so a
  declaration is the Haxe one and nothing else; `@:hxmc.java.signature`
  overrides it. A macro over the JNIEnv table (helder's `Jni`) does the
  calls but not the natives' C entries, nor the conversions at both ends.
- **Cells in the program's data, not a table.** A class's global reference
  and a member's ID are a word each (`hxmc$jni$<what, in hex>`,
  `DataGen.jniCells`), zero until the first call resolves them: one load
  per call after that, no lock, no hashing.
- **Values are Haxe references, as COM's.** A Java object is a box of the
  kind "jni" holding a global reference; `Dynamic`, fields, closures,
  arrays and type parameters need nothing. Identity: the box's key is
  `System.identityHashCode`, `same` is `IsSameObject` (two references of one
  object are one box), as foreign-objects.md planned.
- **A local frame per call.** Local references live in the frame of the
  call that made them (`PushLocalFrame(16)`, `PopLocalFrame`): code in
  loops on a thread the runtime started never fills the thread's base
  frame. A reference argument is a new local reference of the frame (of a
  box's global one), so a box that dies during the call (its deletion is
  put off, and may run on another thread) does not take the object with it.
- **Exceptions are checked once, at the end.** Every entry point after
  `enter` does nothing while an exception is pending; `leave` clears it and
  throws a `JavaException` after popping the frame. The conversions never
  throw: a misuse (a detached box, a Haxe value Java cannot hold) makes a
  Java exception pending (`IllegalStateException`,
  `IllegalArgumentException`), so the frame is always popped.
- **No counts: the toggle is what the proxies say.** The JVM has no
  reference counts, so a peer's toggle cannot be read in the stop. A Haxe
  object implementing Java interfaces is a peer of the kind "jni-peer"
  (`TOGGLE_NOTIFY`), its proxies counted by the runtime: the first proxy
  made makes the entry strong, Java's collection of the last one
  (`org.hxmc.Peer`'s phantom reference, drained on its daemon thread,
  calling the native `hxmcRelease`) makes it weak. Haxe holds a weak global
  reference to its latest proxy (reused while it lives), so Haxe's side
  keeps no proxy alive. Xamarin.Android's bridge (below) was weighed: it
  collects cycles through both heaps, at the price of a phase before every
  major collection that turns references weak, makes the JVM collect, and
  turns the survivors strong again; this is the simplest sound version, and
  leaks such cycles.
- **Releases put off, any thread** (no `RELEASE_IN_STOP`: JNI may block on
  a JVM safepoint; no `RELEASE_ON_MAKER`: global references belong to no
  thread). The kinds' batch attaches the thread that runs them.
- **Threads attach on demand, as daemons, and detach as they end**: a
  pthread key whose destructor calls `DetachCurrentThread` for the threads
  the runtime attached (Android aborts on a thread that exits attached).
  The env is a thread-local of the runtime.
- **The main thread keeps its own stack in a program that calls Java.**
  HotSpot checks the stack pointer of every Java call against the stack
  the system gave the thread (the primordial thread's, from `/proc`), and
  takes the runtime's 1 GB stack, elsewhere in memory, for an overflow
  (StackOverflowError on every call, then "GC triggered before VM
  initialization completed"). `hxmc_stack_flags`' bit 4 (`StackTable.JNI`)
  says the program refers to cells; `Start.runMain` then runs `main` on the
  thread's own stack. A flag of an existing absolute symbol, so that the
  committed stage0 still links the runtime.
- **Classes through the program's class loader.** `FindClass` on a thread
  the runtime attached asks the system class loader, which on Android does
  not know the app's classes: the runtime keeps the loader of
  `org.hxmc.Peer` (else the context class loader of the thread that loaded
  the library, or the activity's) and calls `loadClass`.
- **Elsewhere, a throw.** As COM's: Windows (no `dlopen` of `jvm.dll` yet)
  and WebAssembly compile Java code and throw `UnsupportedOperationException`.

## The glue

hxmc owns calls and ownership; the Java classes a program needs besides
its own are the packager's (helder.pack): it writes them from hxmc's
manifest, compiles them (javac, d8) and bundles them (classes.dex, a jar).
`hxmc/test/JniGlue.hx` is the reference generator the tests use.

**The manifest**, written next to the output when the program has live
Haxe classes implementing Java interfaces (`<output>.jni.json`,
`Jni.manifest`; none otherwise):

```json
{
  "version": 1,
  "peer": "org.hxmc.Peer",
  "exception": "org.hxmc.HaxeException",
  "proxies": [
    {
      "class": "org.hxmc.proxy.Events",
      "haxe": "Events",
      "interfaces": ["jnitest.JniPeers$Callback"],
      "methods": [
        {"name": "onEvent", "signature": "(Ljava/lang/String;I)I", "native": "hxmc0", "nativeSignature": "(JLjava/lang/String;I)I"},
        {"name": "describe", "signature": "()Ljava/lang/String;", "native": "hxmc1", "nativeSignature": "(J)Ljava/lang/String;"}
      ]
    }
  ]
}
```

**`org.hxmc.Peer`** (JniGlue's `PEER`, to be bundled as it is): an
abstract class with a `protected final long hxmcHandle` (the field the
runtime reads, `J`), a constructor `Peer(long handle)` that registers a
phantom reference of the proxy on a queue, a daemon thread `hxmc-peers`
draining the queue, and `private static native void hxmcRelease(long
handle)`, which the thread calls for each collected proxy (the runtime
registers it).

**`org.hxmc.HaxeException`**: `public class HaxeException extends
RuntimeException` with a `(String message)` constructor: what a Haxe
exception reaching Java is (`ThrowNew`; `RuntimeException` when the class
is missing).

**A proxy** for each entry: the class named `class`, extending
`org.hxmc.Peer` and implementing `interfaces` (binary names: `$` is a
nested class), with

- a constructor `(long handle)` calling `super(handle)` (any access: the
  runtime calls it through JNI, `<init>` `(J)V`);
- for each method, `private static native R <native>(long handle, A...)`
  of `nativeSignature`, and the interface method of `name` and `signature`
  calling it with `hxmcHandle` first and returning its result.

The proxy holds no other state; the Haxe class's subclasses that add no
interface share it.

**Registration at startup** is the runtime's: at the first proxy of a
class it finds `org.hxmc.Peer` and the proxy class through the program's
class loader, registers `hxmcRelease` and the proxy's natives
(`RegisterNatives`, the C entries hxmc compiled), and caches the
constructor. The packager registers nothing; it only makes the classes
loadable by the loader the runtime uses: on Android, the app's (the
activity's `getClassLoader`, `Jvm.useActivity`, or the one that loaded
the library, `Jvm.onLoad`).

**On Android** an app's library exports `JNI_OnLoad` (`-D
hxmc.exports=JNI_OnLoad,ANativeActivity_onCreate`) or calls
`Jvm.useActivity(activity)` from its `ANativeActivity_onCreate`'s
program. helder runs the JNI cases in its emulator jobs: JniCheck
cross-builds them and JniLib for android-arm64 and android-x86_64 (checked
to export `JNI_OnLoad`); a helder test bundles a case's `.so`, its
`<Name>.java` and the glue of its manifest into an APK whose activity
loads it and compares logcat's lines with the golden file.

## Next, in order

1. **The bridge** (foreign-objects.md, JNI): before a major collection,
   the peers unreachable from Haxe's roots get weak global references to
   their proxies in place of the counts, the JVM collects
   (`System.gc`, or a weak reference's clearing), and those still alive
   are made strong again and kept: cycles through both heaps collected, at
   a phase before the stop on a thread attached to the JVM.
2. **Haxe classes extending Java classes** (abstract classes, Android's
   `Activity` and `View` subclasses): the proxy extends the class and calls
   `super`; the constructor's arguments go through the proxy's.
3. **Natives of the program's own Java classes**: a Haxe static function
   as a Java class's `native` method (`@:hxmc.java.native`, registered with
   its class), without a proxy.
4. **Windows**: `jvm.dll` through `LoadLibraryW`, a fiber-local's
   destructor for detach, the main fiber's stack (as on POSIX, the JVM
   checks it).
5. **Cheaper calls**: no frame for calls with no reference argument or
   result; the cells' loads inline; the classes and IDs of a packager's
   list resolved at startup rather than at their first call.
6. **Smaller gaps**: an interface's overloads; `java.nio` direct buffers
   over `IoBuffer`; a Java method as a value; `Std.isOfType` and casts of
   Java classes (`IsInstanceOf`: `Java.isInstance` now); `RT_STATS` counts
   of boxes and proxies; declarations generated from class files (as
   extern-generator is Objective-C's).
