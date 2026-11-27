import hxmc.Obj;
import hxmc.a64.Asm;

class A64BranchCheck {
	static function check(ok:Bool, what:String) {
		if (!ok) throw "AArch64 branches: " + what;
	}

	static function checkB(a:Asm, at:Int, label:Int) {
		var d = a.labelPos(label) - at;
		check(a.b.get32(at) == (0x14000000 | ((d >> 2) & 0x3ffffff)), "long B points to the wrong label");
	}

	public static function run() {
		var text = new Section(".text", Text, 4);
		var a = new Asm(text);
		var callee = new Symbol("callee");
		a.blSym(callee);
		var start = a.pos();
		var entry = a.newLabel(), near = a.newLabel(), far = a.newLabel();
		a.bind(entry);
		// The first TBZ just fits until the TBNZ expands.
		a.tbz(5, 42, near);
		a.tbz(2, 63, far, true);
		a.blSym(callee);
		a.adrLabel(16, near);
		a.b.zeros(start + 32764 - a.pos());
		a.bind(near);
		a.bcond(Asm.NE, near);
		a.b.zeros(start + (1 << 20) + 4 - a.pos());
		a.bind(far);
		a.cbz(false, 7, entry, true);
		var map = a.finish(start, "A64BranchCheck.run");
		check(map != null && map(start) == start && map(start + 4) == start + 8, "wrong offset map");
		check(a.labelPos(near) == start + 32772, "label did not move after both expansions");
		check(a.labelPos(far) == start + (1 << 20) + 12, "label at an expanded branch moved past it");
		check(a.b.get32(start) == 0xb7500045, "TBZ did not become TBNZ over B");
		checkB(a, start + 4, near);
		check(a.b.get32(start + 8) == 0xb6f80042, "TBNZ did not become TBZ over B");
		checkB(a, start + 12, far);
		check(text.relocs[0].offset == 0 && text.relocs[1].offset == start + 16, "wrong relocation offsets");
		check(a.b.get32(start + 20) == (0x10000010 | ((32752 >> 2) << 5)), "wrong ADR displacement");
		check(a.b.get32(a.labelPos(near)) == 0x54000001, "short branch changed");
		check(a.b.get32(a.labelPos(far)) == 0x34000047, "CBNZ did not become CBZ over B");
		checkB(a, a.labelPos(far) + 4, entry);
		Sys.println("AArch64 branches: ok");
	}
}
