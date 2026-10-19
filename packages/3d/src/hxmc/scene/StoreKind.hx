package hxmc.scene;

// A kind of component (a camera, a mesh, a light): its store's index in
// each world, given when the kind is made (a static of the kind's module)
class StoreKind<T> {
	static var next = 0;

	public final id:Int;
	public final name:String;

	public function new(name:String) {
		this.name = name;
		id = next++;
	}
}
