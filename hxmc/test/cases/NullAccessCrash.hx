// A fault that is not a null access still ends the program as it did before
// the fault handler (docs/hxmc.md, "Null access"): a read of an address that
// nothing maps, far from null (1 MB: below the image on Linux, in macOS's
// page zero), goes to the default action, SIGSEGV (exit 139). Linux and
// macOS (Windows reports the exception's code; WebAssembly has no protection).
class NullAccessCrash {
	static function main() {
		var a:Array<Int> = Sys.args().length > 99 ? [1] : null;
		var r = try Std.string(a.length) catch (e:String) "caught " + e;
		Sys.println("a null access: " + r);
		Sys.println("a fault at 1 MB:");
		Sys.println(hxmc.unsafe.Mem.getI32(hxmc.unsafe.Ptr.ofI64(0x100000), 0));
		Sys.println("not reached");
	}
}
