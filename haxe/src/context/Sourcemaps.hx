package context;

import core.Globals;
import core.Globals.Pos;
import generators.Gctx;
import core.ds.VectorTools.vector;

class Sourcemaps {
	/**
		Characters used for base64 VLQ encoding
	*/
	static final chars:haxe.ds.Vector<String> = vector(
		'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P',
		'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
		'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v',
		'w', 'x', 'y', 'z', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '/'
	);

	/**
		Encode an integer in range 0...63 (including 63)
	*/
	public static inline function encodeDigit(digit:Int):String return chars[digit];

	/**
		Move the sign bit to the least significant bit.
		E.g.:
			1 becomes 2 (10 binary), -1 becomes 3 (11 binary)
			2 becomes 4 (100 binary), -2 becomes 5 (101 binary)
	*/
	public static function toVlq(number:Int):Int {
		return if (number < 0) ((-number) << 1) + 1 else number << 1;
	}

	public static function initSourcemapNodeList():SmNode {
		var first = new SmNode(null, null, SMNil);
		var last = new SmNode(first, null, SMNil);
		first.smnRight = last;
		return first;
	}

	public static function getSourcemapPointer(builder:Null<SourcemapBuilder>):Null<SmNode> {
		return switch builder {
			case null: null;
			case builder: builder.getPointer();
		}
	}

	public static function setSourcemapPointer(builder:Null<SourcemapBuilder>, pointer:Null<SmNode>):Void {
		switch builder {
			case null:
			case builder:
				switch pointer {
					case null:
					case node: builder.seek(node);
				}
		}
	}
}

/**
	Writes sourcemap for a signle `generated_file` to disk.
	If your code generation is straightforward, you can use this class directly.
	Otherwise use `sourcemap_builder` (e.g. if you need to generate some middle parts of a code and then generate the beginning).
*/
class SourcemapWriter {
	final generatedFile:String;

	/** Output buffer for generated sourcemap */
	final buffer = new StringBuf();

	/** Source Haxe files referenced by this sourcemap */
	final files:Array<String> = [];

	/** Positions of source Haxe files in `files` list */
	final filesIndexes = new haxe.ds.StringMap<Int>();

	/** Index of a source file referenced in previous `map` call */
	var lastSrcFile = 0;

	/** Zero-based index of a source line referenced in previous `map` call */
	var lastSrcLine = 0;

	/** Zero-based index of a source column in a line referenced in previous `map` call */
	var lastSrcCol = 0;

	/** Zero based index of a column in `generated_file` where last written string ended */
	var currentOutCol = 0;

	/** `current_out_col` value as it was when previous call to `map` was performed */
	var lastOutCol = 0;

	/** Indicates whether comma should be written to output buffer on next `map` call */
	var printComma = false;

	/** Last position passed to `map` */
	var lastMappedPos:Null<Pos> = null;

	public function new(generatedFile:String) {
		this.generatedFile = generatedFile;
	}

	/**
		Map specified haxe position.
		This method should be called right before an expression in `pos` is writtend to generated file.
	*/
	public function map(pos:Pos):Void {
		lastMappedPos = pos;
		var srcFile = getFileIndex(pos);
		var lc = syntax.Lexer.findPos(pos);
		var srcLine = lc.line - 1, srcCol = lc.column;
		if (printComma) buffer.add(",") else printComma = true;
		/*
			We need to map the start of each line to the first expression on that line.
			Otherwise languages, which don't provide column in stack trace, will point one line above the correct line.
		*/
		if (lastOutCol == 0) writeBase64Vlq(0) else writeBase64Vlq(currentOutCol - lastOutCol);
		writeBase64Vlq(srcFile - lastSrcFile);
		writeBase64Vlq(srcLine - lastSrcLine);
		writeBase64Vlq(srcCol - lastSrcCol);
		lastSrcFile = srcFile;
		lastSrcLine = srcLine;
		lastSrcCol = srcCol;
		lastOutCol = currentOutCol;
	}

	/**
		Should be called every time something is written to `generated_file`
	*/
	public function stringWritten(str:String):Void {
		// port: OCaml strings are UTF-8 bytes; lengths and indexes below are byte counts.
		var bytes = haxe.io.Bytes.ofString(str);
		var length = bytes.length;
		function indexFrom(start:Int):Int {
			for (i in start...length) if (bytes.get(i) == "\n".code) return i;
			return -1;
		}
		var previousIndex = -1;
		while (true) {
			var nextIndex = indexFrom(previousIndex + 1);
			if (nextIndex < 0) {
				if (previousIndex >= 0) {
					printComma = false;
					currentOutCol = length - previousIndex;
					lastOutCol = 0;
				} else
					currentOutCol = currentOutCol + length;
				break;
			} else {
				buffer.add(";");
				previousIndex = nextIndex;
			}
		}
	}

	/**
		Write generated map to disk.
		If `file_name` is not provided then `generated_file` will be used with additional `.map` extension.
		E.g if `generated_file` is `path/to/file.js`, then sourcemap will be written to `path/to/file.js.map`.
		This function does not try to create missing directories.
	*/
	public function generate(?fileName:String, ?sourceRoot:String, com:Gctx):Void {
		var fileName = fileName != null ? fileName : generatedFile + ".map";
		var sourceRoot = sourceRoot != null ? sourceRoot : "";
		var channel = new StringBuf();
		var sources = files.copy();
		function toUrl(file:String):String return core.Path.getFullPath(file).split("\\").join("/");
		channel.add("{\n");
		channel.add("\"version\":3,\n");
		channel.add("\"file\":\"" + generatedFile.split("\\").join("\\\\") + "\",\n");
		channel.add("\"sourceRoot\":\"" + sourceRoot + "\",\n");
		channel.add("\"sources\":[" + sources.map(s -> "\"" + toUrl(s) + "\"").join(",") + "],\n");
		if (Gctx.defined(com, core.Define.SourceMapContent)) {
			channel.add("\"sourcesContent\":["
				+ sources.map(s -> try "\"" + core.StringHelper.sEscape(sys.io.File.getContent(s)) + "\"" catch (_:Dynamic) "null").join(",")
				+ "],\n");
		}
		channel.add("\"names\":[],\n");
		channel.add("\"mappings\":\"");
		channel.add(buffer.toString());
		channel.add("\"\n");
		channel.add("}");
		sys.io.File.saveContent(fileName, channel.toString());
	}

	/**
		Get source Haxe file position in a list of files referenced by this sourcemap
	*/
	function getFileIndex(pos:Pos):Int {
		var index = filesIndexes.get(pos.pfile);
		if (index != null) return index;
		var index = files.length;
		filesIndexes.set(pos.pfile, index);
		files.push(pos.pfile);
		return index;
	}

	/**
		Apply base64 VLQ encoding to `number` and write it to output buffer
	*/
	function writeBase64Vlq(number:Int):Void {
		var vlq = Sourcemaps.toVlq(number);
		while (true) {
			var shift = 5;
			var base = 1 << shift;
			var mask = base - 1;
			var continuationBit = base;
			var digit = vlq & mask;
			var next = vlq >> shift;
			buffer.add(Sourcemaps.encodeDigit(if (next > 0) digit | continuationBit else digit));
			if (next > 0) vlq = next else break;
		}
	}
}

enum SmNodeData {
	SMPos(pos:Pos);
	SMStr(str:String);
	SMNil; /* this data type marks the beginning and the end of a list */
}

class SmNode {
	public var smnLeft:Null<SmNode>;
	public var smnRight:Null<SmNode>;
	public final smnData:SmNodeData;

	public function new(smnLeft:Null<SmNode>, smnRight:Null<SmNode>, smnData:SmNodeData) {
		this.smnLeft = smnLeft;
		this.smnRight = smnRight;
		this.smnData = smnData;
	}
}

/**
	Builds data for sourcemap.
*/
class SourcemapBuilder {
	final generatedFile:String;

	/** Current node */
	var current = Sourcemaps.initSourcemapNodeList();

	public function new(generatedFile:String) {
		this.generatedFile = generatedFile;
	}

	/**
		Add data to sourcemap.
		1. `#insert (SMPos pos)` should be called right before an expression in `pos` is writtend to generated file.
		2. `#insert (SMStr str)` should be called every time some string is written to generated file.
	*/
	public function insert(data:SmNodeData):Void {
		/* new node which will be inserted after current one */
		var inserted = new SmNode(current, current.smnRight, data);
		/* link new node with current and next to current one */
		current.smnRight = inserted;
		switch inserted.smnRight {
			case null:
			case right: right.smnLeft = current.smnRight;
		}
		/* inserted node becomes current */
		current = inserted;
	}

	/**
		Rewind builder so that next `#insert data` call will insert data in the beginning of this sourcemap.
	*/
	public function rewind():Void {
		var node:Null<SmNode> = current;
		while (true) {
			switch node {
				case null: Globals.die("", "Sourcemaps.rewind");
				case node0 if (node0.smnData.match(SMNil)):
					current = node0;
					return;
				case node0: node = node0.smnLeft;
			}
		}
	}

	/**
		Fast forward builder so that next `#insert data` call will attach data to the end of this sourcemap.
	*/
	public function fastForward():Void {
		var node = current;
		while (true) {
			switch node.smnRight {
				case null: Globals.die("", "Sourcemaps.fast_forward");
				case right if (right.smnData.match(SMNil)):
					current = node;
					return;
				case right: node = right;
			}
		}
	}

	/**
		Set builder pointer to `node` so that next `#insert data` call will insert data right after this `node`.
	*/
	public function seek(node:SmNode):Void current = node;

	/**
		Get current node in this builder
	*/
	public function getPointer():SmNode return current;

	/**
		Write source map to disk.
		If `file_name` is not provided then `generated_file` will be used with additional `.map` extension.
		E.g if `generated_file` is `path/to/file.js`, then sourcemap will be written to `path/to/file.js.map`.
		This function does not try to create missing directories.
	*/
	public function generate(?fileName:String, ?sourceRoot:String, com:Gctx):Void {
		/* remember position */
		var pointer = getPointer();
		rewind();
		/* write source map to a buffer */
		var writer = new SourcemapWriter(generatedFile);
		var node:Null<SmNode> = current;
		while (node != null) {
			switch node.smnData {
				case SMPos(pos): writer.map(pos);
				case SMStr(str): writer.stringWritten(str);
				case SMNil:
			}
			node = node.smnRight;
		}
		/* dump source map to a file */
		var fileName = fileName != null ? fileName : generatedFile + ".map";
		var sourceRoot = sourceRoot != null ? sourceRoot : "";
		writer.generate(fileName, sourceRoot, com);
		/* restore position */
		seek(pointer);
	}
}
