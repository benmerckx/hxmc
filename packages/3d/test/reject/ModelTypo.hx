// Model.of types a model's names from its file: a name it does not have
// must not compile (make 3d-check expects "has no field bal").
class ModelTypo {
	static function main() {
		var m = hxmc.scene.render.Model.of("sample.glb");
		trace(m.nodes.bal);
	}
}
