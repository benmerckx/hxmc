package generators;

// Optional prod ESM backend (hxmc Genesm). Set by hxmc when its generators are
// linked in; the reference-style port alone leaves this null so -D esm still
// uses Genjs.
class EsmHook {
	public static var generate:Null<Gctx->Void> = null;
}