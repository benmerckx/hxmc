package hxmc.rt.wasm;

import hxmc.I64;

// WASI preview 1 (wasi_snapshot_preview1), the system interface of
// WebAssembly programs: pointers are 32-bit offsets into linear memory
// (Int here), results are errno codes (0: success).
@:hxmc.c @:hxmc.fast extern class WasiApi {
	static function args_sizes_get(argc:Int, bufSize:Int):Int;
	static function args_get(argv:Int, buf:Int):Int;
	static function environ_sizes_get(n:Int, bufSize:Int):Int;
	static function environ_get(env:Int, buf:Int):Int;
	static function clock_time_get(id:Int, precision:I64, out:Int):Int;
	static function fd_write(fd:Int, iovs:Int, n:Int, written:Int):Int;
	static function fd_read(fd:Int, iovs:Int, n:Int, read:Int):Int;
	static function fd_close(fd:Int):Int;
	static function fd_seek(fd:Int, offset:I64, whence:Int, newOffset:Int):Int;
	static function fd_tell(fd:Int, offset:Int):Int;
	static function fd_filestat_get(fd:Int, buf:Int):Int;
	static function fd_fdstat_get(fd:Int, buf:Int):Int;
	static function fd_fdstat_set_flags(fd:Int, flags:Int):Int;
	static function fd_prestat_get(fd:Int, buf:Int):Int;
	static function fd_prestat_dir_name(fd:Int, path:Int, len:Int):Int;
	static function fd_readdir(fd:Int, buf:Int, len:Int, cookie:I64, used:Int):Int;
	static function path_open(fd:Int, dirflags:Int, path:Int, len:Int, oflags:Int, rightsBase:I64, rightsInheriting:I64, fdflags:Int, out:Int):Int;
	static function path_filestat_get(fd:Int, flags:Int, path:Int, len:Int, buf:Int):Int;
	static function path_create_directory(fd:Int, path:Int, len:Int):Int;
	static function path_remove_directory(fd:Int, path:Int, len:Int):Int;
	static function path_unlink_file(fd:Int, path:Int, len:Int):Int;
	static function path_rename(fd:Int, path:Int, len:Int, fd2:Int, path2:Int, len2:Int):Int;
	static function poll_oneoff(subs:Int, events:Int, n:Int, nevents:Int):Int;
	static function random_get(buf:Int, len:Int):Int;
	static function proc_exit(code:Int):Void;
}
