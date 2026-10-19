package ml2hx.std;

import String;
import StdTypes;
import ml2hx.rt.*;

// luv's Luv.File.Dirent.t: a directory entry ({kind; name}, kind a
// polymorphic variant of Luv.File.Dirent.Kind). Made by Luv.File.readdir
// and scandir_next.
class LuvFileDirentT implements Block {
	public final kind:PolyVariant;
	public final name:String;
	public function new(kind:PolyVariant, name:String) {
		this.kind = kind;
		this.name = name;
	}
	public function blockTag():Int return 0;
	public function blockSize():Int return 2;
	public function blockField(i:Int):Dynamic return i == 0 ? kind : name;
}

class Luv__File_Dirent {
}
