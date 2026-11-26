package generators;

// port: optional Genesm backend (-D esm); hxmc sets generate in EsmInstall.
// ... the reference port leaves null; Generate rejects -D esm* when unset.
class EsmHook {
	public static var generate:Null<Gctx->Void> = null;
	// port: hxmc GenesmProd (-D esm without esm.hot) — static import prod emit.
	public static var isProdEsm:Null<() -> Bool> = null;
	// port: hxmc GenesmProd — std modules keep $global publish (no deferProto).
	public static var isProdEsmStd:Null<String -> Bool> = null;
}