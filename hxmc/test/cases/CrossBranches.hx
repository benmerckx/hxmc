// arm64 conditional and test-bit branches to code of other sections (b.cond,
// cbz and cbnz: R_AARCH64_CONDBR19; tbz and tbnz: R_AARCH64_TSTBR14), which
// the linker resolves (LinkCore, A64Reloc): CrossBranches.c, a prebuilt
// object whose functions each have a section, as -ffunction-sections writes
// them, some placed before the branch and some after. Elsewhere the C
// fallback computes the same.
@:hxmc.c @:hxmc.fast extern class CB {
	static function cb_classify(x:Int):Int;
	static function cb_bit(x:Int):Int;
}

class CrossBranches {
	static function main() {
		for (x in [0, 1, 7, 99, 100, 12345, -1, -100])
			Sys.println('classify($x) = ${CB.cb_classify(x)}');
		for (x in [0, 8, 9, 7, 0x10008])
			Sys.println('bit($x) = ${CB.cb_bit(x)}');
	}
}
