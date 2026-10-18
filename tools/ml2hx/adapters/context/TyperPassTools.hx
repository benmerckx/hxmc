// Adapt the persistent OCaml list to the port's existing array API.
class TyperPassTools {
	public static final allTyperPasses:Array<TyperPass> = ml2hx.rt.Runtime.toArray(TyperPassModule.allTyperPasses);
	public static final allTyperPassesLength:Int = TyperPassModule.allTyperPassesLength.toInt();
}
