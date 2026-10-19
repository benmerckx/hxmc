package core;

import haxe.ds.List;
import haxe.io.Bytes;
import haxe.zip.Entry;
import haxe.zip.Writer;
import sys.io.File;

// port: `class virtual any_output`: the virtual methods fail if not overridden.
class AnyOutput {
	public function new() {}

	public function addEntry(content:String, name:String):Void {
		throw "Not implemented";
	}

	public function close():Void {
		throw "Not implemented";
	}
}

// port: `Zip.open_out`/`add_entry`/`close_out` (libs/extlib-leftovers zip.ml) over haxe.zip.Writer:
// the entries are collected and the archive is written on close.
class ZipOutput extends AnyOutput {
	final output:sys.io.FileOutput;
	final writer:Writer;
	final compressionLevel:Int;
	final entries:List<Entry> = new List();
	var closed = false;

	public function new(zipPath:String, compressionLevel:Int) {
		super();
		this.output = File.write(zipPath, true);
		this.writer = new Writer(output);
		this.compressionLevel = compressionLevel;
	}

	override public function addEntry(content:String, name:String):Void {
		addBytesEntry(Bytes.ofString(content), name);
	}

	// port: adds binary data without round-tripping it through a Haxe String. HXB
	// modules are byte streams, so archive generation must retain every byte.
	public function addBytesEntry(content:Bytes, name:String):Void {
		if (closed) throw "Output is closed";
		addPreparedEntry(makeEntry(content, name));
	}

	// port: addBytesEntry in two steps: makeEntry (the CRC and the compression) leaves the
	// ... output untouched and may run on several threads at once (genjvm's write_class);
	// ... addPreparedEntry adds the entry, one thread at a time.
	public function makeEntry(content:Bytes, name:String):Entry {
		var data = content;
		var fileSize = data.length;
		var compressed = compressionLevel != 0;
		var crc32 = crc32Of(data);
		if (compressed) {
			// port: raw DEFLATE, as Zip.add_entry (Zlib.compress ~header:false), in one call
			var z = libs.extc.Extc.zlibDeflateInit2(compressionLevel, -15);
			var d = Bytes.alloc(libs.extc.Extc.zlibDeflateBound(z, data.length));
			var r = libs.extc.Extc.zlibDeflate(z, data, 0, data.length, d, 0, d.length, libs.extc.Zlib.Z_FINISH);
			libs.extc.Extc.zlibDeflateEnd(z);
			data = d.sub(0, r.z_wrote);
		}
		return {
			fileName: name,
			fileSize: fileSize,
			fileTime: null,
			compressed: compressed,
			dataSize: data.length,
			data: data,
			crc32: crc32
		};
	}

	public function addPreparedEntry(entry:Entry):Void {
		if (closed) throw "Output is closed";
		entry.fileTime = Date.now();
		entries.add(entry);
	}

	// port: table-driven CRC-32, as in zlib (upstream's Zip uses zlib's crc32);
	// haxe.crypto.Crc32 computes it bit by bit.
	static final crcTable:haxe.ds.Vector<Int> = {
		var t = new haxe.ds.Vector<Int>(256);
		for (n in 0...256) {
			var c = n;
			for (_ in 0...8) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
			t[n] = c;
		}
		t;
	};

	static function crc32Of(b:Bytes):Int {
		var crc = 0xFFFFFFFF, table = crcTable;
		for (i in 0...b.length) crc = table[(crc ^ b.get(i)) & 0xFF] ^ (crc >>> 8);
		return crc ^ 0xFFFFFFFF;
	}

	override public function close():Void {
		if (closed) return;
		writer.write(entries);
		output.close();
		closed = true;
	}
}
