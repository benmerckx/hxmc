import hxmc.x64.Asm;

// Table-driven test of the x86-64 encoder (hxmc/tools/enctest.py): prints
// one line per instruction, `<intel syntax>|<our bytes in hex>`; the script
// assembles the text with llvm-mc and compares the bytes. Runs on Eval:
//   haxe -cp hxmc/src -cp hxmc/test/encoder --run EncTest
class EncTest {
	static var out = new StringBuf();

	static function emit(text:String, f:Asm->Void) {
		var a = new Asm();
		f(a);
		var hex = new StringBuf();
		for (i in 0...a.b.len)
			hex.add(StringTools.hex(a.b.get8(i), 2));
		out.add(text + "|" + hex.toString().toLowerCase() + "\n");
	}

	static function r(n:Int, size:Int)
		return Asm.regName(n, size);

	static function ptr(size:Int)
		return switch size {
			case 1: "byte ptr ";
			case 2: "word ptr ";
			case 4: "dword ptr ";
			case 8: "qword ptr ";
			case _: "xmmword ptr ";
		};

	static function mems():Array<Mem> {
		var ms = [];
		for (base in [0, 3, 4, 5, 8, 12, 13, 15])
			for (disp in [0, 8, -8, 127, 128, -129, 0x12345])
				ms.push(new Mem(base, disp));
		for (base in [0, 4, 5, 12, 13])
			for (index in [1, 5, 9, 13])
				for (scale in [1, 2, 4, 8])
					ms.push(new Mem(base, scale * 4 - 8, index, scale));
		ms.push(new Mem(-1, 0x1000, 3, 8));
		return ms;
	}

	static function memText(m:Mem):String {
		var s = m.toString();
		return s;
	}

	static function main() {
		var sizes = [4, 8];
		var names = ["add", "or", "", "", "and", "sub", "xor", "cmp"];
		for (o in [0, 1, 4, 5, 6, 7])
			for (size in [1, 4, 8]) {
				for (d in 0...16)
					for (s in [0, 5, 7, 8, 13])
						emit('${names[o]} ${r(d, size)}, ${r(s, size)}', a -> a.aluRR(o, size, d, s));
				for (d in [0, 4, 9])
					for (v in [1, -1, 127, 128, -128, -129, 0x12345678])
						if (size != 1 || (v >= -128 && v <= 127)) emit('${names[o]} ${r(d, size)}, $v', a -> a.aluRI(o, size, d, v));
				for (m in mems())
					for (s in [2, 10]) {
						emit('${names[o]} ${ptr(size)}${memText(m)}, ${r(s, size)}', a -> a.aluMR(o, size, m, s));
						emit('${names[o]} ${r(s, size)}, ${ptr(size)}${memText(m)}', a -> a.aluRM(o, size, s, m));
					}
				for (v in [5, 300])
					emit('${names[o]} ${ptr(size)}${memText(new Mem(12, 16))}, ${size == 1 ? 5 : v}', a -> a.aluMI(o, size, new Mem(12, 16), size == 1 ? 5 : v));
			}
		for (size in [1, 2, 4, 8])
			for (m in mems())
				for (s in [0, 6, 11]) {
					if (size >= 4) emit('mov ${r(s, size)}, ${ptr(size)}${memText(m)}', a -> a.load(size, s, m));
					emit('mov ${ptr(size)}${memText(m)}, ${r(s, size)}', a -> a.store(size, m, s));
				}
		for (size in [1, 2, 4, 8])
			emit('mov ${ptr(size)}${memText(new Mem(5, 8))}, 7', a -> a.storeI(size, new Mem(5, 8), 7));
		for (size in sizes)
			for (d in 0...16)
				for (s in [0, 7, 8, 15])
					if (d != s || size != 8) emit('mov ${r(d, size)}, ${r(s, size)}', a -> a.movRR(size, d, s));
		for (d in [0, 7, 8, 15]) {
			emit('mov ${r(d, 4)}, 305419896', a -> a.movRI(4, d, 305419896));
			emit('mov ${r(d, 8)}, -5', a -> a.movRI(8, d, -5));
			emit('movabs ${r(d, 8)}, 81985529216486895', a -> a.movRI64(d, 0x89abcdef, 0x01234567));
			for (m in [new Mem(4, 3), new Mem(13, 0), new Mem(1, 4, 2, 4)]) {
				emit('movzx ${r(d, 4)}, byte ptr ${memText(m)}', a -> a.movzx8(d, m));
				emit('movzx ${r(d, 4)}, word ptr ${memText(m)}', a -> a.movzx16(d, m));
				emit('movsx ${r(d, 8)}, byte ptr ${memText(m)}', a -> a.movsx8(8, d, m));
				emit('movsx ${r(d, 4)}, word ptr ${memText(m)}', a -> a.movsx16(4, d, m));
				emit('movsxd ${r(d, 8)}, dword ptr ${memText(m)}', a -> a.movsxd(d, m));
				emit('lea ${r(d, 8)}, ${memText(m)}', a -> a.lea(8, d, m));
				emit('lea ${r(d, 4)}, ${memText(m)}', a -> a.lea(4, d, m));
				emit('imul ${r(d, 8)}, qword ptr ${memText(m)}', a -> a.imulRM(8, d, m));
				emit('movsd ${r(d + 16, 8)}, qword ptr ${memText(m)}', a -> a.movsdRM(d + 16, m));
				emit('movsd qword ptr ${memText(m)}, ${r(d + 16, 8)}', a -> a.movsdMR(m, d + 16));
				emit('ucomisd ${r(d + 16, 8)}, qword ptr ${memText(m)}', a -> a.ucomisdRM(d + 16, m));
				emit('addsd ${r(d + 16, 8)}, qword ptr ${memText(m)}', a -> a.sdRM(0x58, d + 16, m));
				emit('call qword ptr ${memText(m)}', a -> a.callM(m));
				emit('jmp qword ptr ${memText(m)}', a -> a.jmpM(m));
			}
			for (s in [1, 6, 9, 14]) {
				emit('movzx ${r(d, 4)}, ${r(s, 1)}', a -> a.movzx8R(d, s));
				emit('movzx ${r(d, 4)}, ${r(s, 2)}', a -> a.movzx16R(d, s));
				emit('movsxd ${r(d, 8)}, ${r(s, 4)}', a -> a.movsxdR(d, s));
				for (size in sizes) {
					emit('imul ${r(d, size)}, ${r(s, size)}', a -> a.imulRR(size, d, s));
					emit('imul ${r(d, size)}, ${r(s, size)}, 3', a -> a.imulRRI(size, d, s, 3));
					emit('imul ${r(d, size)}, ${r(s, size)}, 1000', a -> a.imulRRI(size, d, s, 1000));
					emit('test ${r(d, size)}, ${r(s, size)}', a -> a.testRR(size, d, s));
					emit('cmove ${r(d, size)}, ${r(s, size)}', a -> a.cmovRR(E, size, d, s));
					emit('cmovl ${r(d, size)}, ${r(s, size)}', a -> a.cmovRR(L, size, d, s));
				}
				emit('movapd ${r(d + 16, 8)}, ${r(s + 16, 8)}', a -> a.movsdRR(d + 16, s + 16));
				for (o in [0x58, 0x59, 0x5c, 0x5e, 0x51, 0x5d, 0x5f]) {
					var n = switch o {
						case 0x58: "addsd";
						case 0x59: "mulsd";
						case 0x5c: "subsd";
						case 0x5e: "divsd";
						case 0x51: "sqrtsd";
						case 0x5d: "minsd";
						case _: "maxsd";
					};
					emit('$n ${r(d + 16, 8)}, ${r(s + 16, 8)}', a -> a.sdRR(o, d + 16, s + 16));
				}
				emit('ucomisd ${r(d + 16, 8)}, ${r(s + 16, 8)}', a -> a.ucomisdRR(d + 16, s + 16));
				emit('xorpd ${r(d + 16, 8)}, ${r(s + 16, 8)}', a -> a.xorpd(d + 16, s + 16));
				emit('andpd ${r(d + 16, 8)}, ${r(s + 16, 8)}', a -> a.andpd(d + 16, s + 16));
				emit('cvtsi2sd ${r(d + 16, 8)}, ${r(s, 4)}', a -> a.cvtsi2sd(4, d + 16, s));
				emit('cvtsi2sd ${r(d + 16, 8)}, ${r(s, 8)}', a -> a.cvtsi2sd(8, d + 16, s));
				emit('cvttsd2si ${r(d, 4)}, ${r(s + 16, 8)}', a -> a.cvttsd2si(4, d, s + 16));
				emit('cvttsd2si ${r(d, 8)}, ${r(s + 16, 8)}', a -> a.cvttsd2si(8, d, s + 16));
				emit('movq ${r(d + 16, 8)}, ${r(s, 8)}', a -> a.movqXR(d + 16, s));
				emit('movq ${r(d, 8)}, ${r(s + 16, 8)}', a -> a.movqRX(d, s + 16));
				emit('roundsd ${r(d + 16, 8)}, ${r(s + 16, 8)}, 1', a -> a.roundsd(d + 16, s + 16, 1));
				emit('movd ${r(d + 16, 8)}, ${r(s, 4)}', a -> a.movdXR(d + 16, s));
				emit('movd ${r(d, 4)}, ${r(s + 16, 8)}', a -> a.movdRX(d, s + 16));
				emit('cvtss2sd ${r(d + 16, 8)}, ${r(s + 16, 8)}', a -> a.cvtss2sd(d + 16, s + 16));
				emit('cvtsd2ss ${r(d + 16, 8)}, ${r(s + 16, 8)}', a -> a.cvtsd2ss(d + 16, s + 16));
			}
			for (size in sizes) {
				emit('neg ${r(d, size)}', a -> a.neg(size, d));
				emit('not ${r(d, size)}', a -> a.not(size, d));
				emit('idiv ${r(d, size)}', a -> a.idiv(size, d));
				emit('shl ${r(d, size)}, cl', a -> a.shiftCl(Asm.SHL, size, d));
				emit('shr ${r(d, size)}, cl', a -> a.shiftCl(Asm.SHR, size, d));
				emit('sar ${r(d, size)}, cl', a -> a.shiftCl(Asm.SAR, size, d));
				emit('shl ${r(d, size)}, 5', a -> a.shiftI(Asm.SHL, size, d, 5));
				emit('sar ${r(d, size)}, 1', a -> a.shiftI(Asm.SAR, size, d, 1));
				emit('test ${r(d, size)}, 256', a -> a.testRI(size, d, 256));
			}
			emit('test ${r(d, 1)}, 1', a -> a.testRI(1, d, 1));
			emit('sete ${r(d, 1)}', a -> a.setcc(E, d));
			emit('setg ${r(d, 1)}', a -> a.setcc(G, d));
			emit('push ${r(d, 8)}', a -> a.push(d));
			emit('pop ${r(d, 8)}', a -> a.pop(d));
			emit('call ${r(d, 8)}', a -> a.callR(d));
			emit('jmp ${r(d, 8)}', a -> a.jmpR(d));
		}
		emit('cdq', a -> a.signExtendAx(4));
		emit('cqo', a -> a.signExtendAx(8));
		emit('ret', a -> a.ret());
		emit('ud2', a -> a.ud2());
		// atomics
		for (m in mems())
			for (s in [0, 3, 9, 15])
				for (size in sizes) {
					emit('xchg ${ptr(size)}${memText(m)}, ${r(s, size)}', a -> a.xchgMR(size, m, s));
					emit('lock xadd ${ptr(size)}${memText(m)}, ${r(s, size)}', a -> a.lockXaddMR(size, m, s));
					emit('lock cmpxchg ${ptr(size)}${memText(m)}, ${r(s, size)}', a -> a.lockCmpxchgMR(size, m, s));
				}
		emit('mfence', a -> a.mfence());
		Sys.print(out.toString());
	}
}
