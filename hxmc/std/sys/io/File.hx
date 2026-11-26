// hxmc: haxe/upstream/std/sys/io/File.hx over hxmc.NativeSys

package sys.io;

import hxmc.NativeSys;

/**
	API for reading and writing files.

	See `sys.FileSystem` for the complementary file system API.
**/
class File {
	// hxmc: in macro code (-D hxmc.macros=mir), a path relative to the macro's working
	// directory, and a path written dropped from the compilation server's view of
	// the files, as Eval's
	static inline function at(path:String):String
		return #if macro hxmc.MacroHost.resolve(path) #else path #end;

	static inline function written(path:String):Void {
		#if macro hxmc.MacroHost.invalidate(path); #end
	}

	/**
		Retrieves the content of the file specified by `path` as a String.

		If the file does not exist or can not be read, an exception is thrown.

		`sys.FileSystem.exists` can be used to check for existence.

		If `path` is null, the result is unspecified.
	**/
	public static function getContent(path:String):String
		return getBytes(path).toString();

	/**
		Stores `content` in the file specified by `path`.

		If the file cannot be written to, an exception is thrown.

		If `path` or `content` are null, the result is unspecified.
	**/
	public static function saveContent(path:String, content:String):Void
		saveBytes(path, haxe.io.Bytes.ofString(content));

	/**
		Retrieves the binary content of the file specified by `path`.

		If the file does not exist or can not be read, an exception is thrown.

		`sys.FileSystem.exists` can be used to check for existence.

		If `path` is null, the result is unspecified.
	**/
	public static function getBytes(path:String):haxe.io.Bytes {
		var b = NativeSys.fileContent(at(path));
		if (b == null) throw "Could not read file " + path;
		return b;
	}

	/**
		Stores `bytes` in the file specified by `path` in binary mode.

		If the file cannot be written to, an exception is thrown.

		If `path` or `bytes` are null, the result is unspecified.
	**/
	public static function saveBytes(path:String, bytes:haxe.io.Bytes):Void {
		if (!NativeSys.fileSave(at(path), bytes, false)) throw "Could not write file " + path;
		written(at(path));
	}

	static function open(path:String, mode:Int):Int {
		if (mode != 0) written(at(path));
		var fd = NativeSys.fileOpen(at(path), mode);
		if (fd < 0) throw "Could not open file " + path;
		return fd;
	}

	/**
		Returns an `FileInput` handle to the file specified by `path`.

		If `binary` is true, the file is opened in binary mode. Otherwise it is
		opened in non-binary mode.

		If the file does not exist or can not be read, an exception is thrown.

		Operations on the returned `FileInput` handle read on the opened file.

		File handles should be closed via `FileInput.close` once the operation
		is complete.

		If `path` is null, the result is unspecified.
	**/
	public static function read(path:String, binary:Bool = true):FileInput
		return @:privateAccess new FileInput(open(path, 0));

	/**
		Returns an `FileOutput` handle to the file specified by `path`.

		If `binary` is true, the file is opened in binary mode. Otherwise it is
		opened in non-binary mode.

		If the file cannot be written to, an exception is thrown.

		Operations on the returned `FileOutput` handle write to the opened file.
		If the file existed, its previous content is overwritten.

		File handles should be closed via `FileOutput.close` once the operation
		is complete.

		If `path` is null, the result is unspecified.
	**/
	public static function write(path:String, binary:Bool = true):FileOutput
		return @:privateAccess new FileOutput(open(path, 1));

	/**
		Similar to `sys.io.File.write`, but appends to the file if it exists
		instead of overwriting its contents.
	**/
	public static function append(path:String, binary:Bool = true):FileOutput
		return @:privateAccess new FileOutput(open(path, 2));

	/**
		Similar to `sys.io.File.append`. While `append` can only seek or write
		starting from the end of the file's previous contents, `update` can
		seek to any position, so the file's previous contents can be
		selectively overwritten.
	**/
	public static function update(path:String, binary:Bool = true):FileOutput
		return @:privateAccess new FileOutput(open(path, 3));

	/**
		Copies the contents of the file specified by `srcPath` to the file
		specified by `dstPath`.

		If the `srcPath` does not exist or cannot be read, or if the `dstPath`
		file cannot be written to, an exception is thrown.

		If the file at `dstPath` exists, its contents are overwritten.

		If `srcPath` or `dstPath` are null, the result is unspecified.
	**/
	public static function copy(srcPath:String, dstPath:String):Void
		saveBytes(dstPath, getBytes(srcPath));
}
