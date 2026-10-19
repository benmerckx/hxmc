package hxmc.scene.gltf;

import haxe.io.Bytes;

// A glTF file's two parts: the JSON text and, for a .glb, the BIN chunk.
// Free of the math types, so that macros (Model.of) read files with the
// same code as Gltf.parse.
class GltfFile {
	static inline var GLB_MAGIC = 0x46546C67; // "glTF"
	static inline var CHUNK_JSON = 0x4E4F534A;
	static inline var CHUNK_BIN = 0x004E4942;

	// whether bytes are a .glb file
	public static function isGlb(b:Bytes):Bool
		return b.length >= 12 && b.getInt32(0) == GLB_MAGIC;

	public static function split(bytes:Bytes):{json:String, bin:Null<Bytes>} {
		if (!isGlb(bytes)) return {json: bytes.toString(), bin: null};
		if (bytes.getInt32(4) != 2) throw "glTF: .glb version " + bytes.getInt32(4);
		var length = bytes.getInt32(8);
		if (length > bytes.length) throw "glTF: .glb truncated";
		var p = 12, json:Null<String> = null, bin:Null<Bytes> = null;
		while (p + 8 <= length) {
			var size = bytes.getInt32(p), type = bytes.getInt32(p + 4);
			if (size < 0 || p + 8 + size > length) throw "glTF: .glb chunk out of the file";
			if (type == CHUNK_JSON && json == null) json = bytes.getString(p + 8, size);
			else if (type == CHUNK_BIN && bin == null) bin = bytes.sub(p + 8, size);
			// (chunks are 4-byte aligned)
			p += 8 + ((size + 3) & ~3);
		}
		if (json == null) throw "glTF: .glb without a JSON chunk";
		return {json: json, bin: bin};
	}
}
