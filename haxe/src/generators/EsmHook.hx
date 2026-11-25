package generators;

// port: optional Genesm backend (-D esm); hxmc sets generate in EsmInstall.
// ... the reference port leaves null; Generate rejects -D esm* when unset.
class EsmHook {
	public static var generate:Null<Gctx->Void> = null;
}