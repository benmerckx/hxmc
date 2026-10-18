package context;
// Generated from src/context/typerPass.ml. Do not edit.
/* build the module structure and setup module type parameters */
/* build the class structure */
/* handle associated fields, which may affect each other. E.g. a property and its getter */
/* type the class field, allow access to types structures */
/* perform late constraint checks with inferred types */
/* usually ensure that lazy have been evaluated */
/* not used, only mark for finalize */
enum TyperPass {
	PBuildModule;
	PBuildClass;
	PConnectField;
	PTypeField;
	PCheckConstraint;
	PForce;
	PFinal;
}
class TyperPassModule {
	public static final allTyperPasses:ml2hx.rt.MlList<TyperPass> = (function() {
		var _ml1 = (function() {
			var _ml3 = (function() {
				var _ml5 = (function() {
					var _ml7 = (function() {
						var _ml9 = (function() {
							var _ml11 = (function() {
								var _ml13 = ml2hx.rt.MlList.Nil;
								var _ml12 = TyperPass.PFinal;
								return ml2hx.rt.MlList.Cons(_ml12, _ml13);
							})();
							var _ml10 = TyperPass.PForce;
							return ml2hx.rt.MlList.Cons(_ml10, _ml11);
						})();
						var _ml8 = TyperPass.PCheckConstraint;
						return ml2hx.rt.MlList.Cons(_ml8, _ml9);
					})();
					var _ml6 = TyperPass.PTypeField;
					return ml2hx.rt.MlList.Cons(_ml6, _ml7);
				})();
				var _ml4 = TyperPass.PConnectField;
				return ml2hx.rt.MlList.Cons(_ml4, _ml5);
			})();
			var _ml2 = TyperPass.PBuildClass;
			return ml2hx.rt.MlList.Cons(_ml2, _ml3);
		})();
		var _ml0 = TyperPass.PBuildModule;
		return ml2hx.rt.MlList.Cons(_ml0, _ml1);
	})();
	public static final allTyperPassesLength:ml2hx.rt.Int63 = (function() {
		var _ml14 = allTyperPasses;
		return ml2hx.rt.Runtime.listLength(_ml14);
	})();
}
// Adapt the persistent OCaml list to the port's existing array API.
class TyperPassTools {
	public static final allTyperPasses:Array<TyperPass> = ml2hx.rt.Runtime.toArray(TyperPassModule.allTyperPasses);
	public static final allTyperPassesLength:Int = TyperPassModule.allTyperPassesLength.toInt();
}
