// The C side of CrossBranches.hx: on arm64 ELF, functions in sections of
// their own that branch to each other with b.cond, cbz, cbnz, tbz and tbnz;
// the assembler leaves those branches to the linker (relocations against
// symbols of other sections). Elsewhere: the same in C.
#include <stdint.h>
#if defined(__aarch64__) && defined(__ELF__)
__asm__(
	// (before the branches: reached backward)
	".section .text.cb_negative,\"ax\",%progbits\n"
	".globl cb_negative\n"
	".type cb_negative,%function\n"
	"cb_negative:\n"
	"	mov w0, #20\n"
	"	ret\n"
	".section .text.cb_classify,\"ax\",%progbits\n"
	".globl cb_classify\n"
	".type cb_classify,%function\n"
	"cb_classify:\n"
	"	cbz w0, cb_zero\n"
	"	tbnz w0, #31, cb_negative\n"
	"	cmp w0, #100\n"
	"	b.ge cb_big\n"
	"	mov w0, #1\n"
	"	ret\n"
	".section .text.cb_bit,\"ax\",%progbits\n"
	".globl cb_bit\n"
	".type cb_bit,%function\n"
	"cb_bit:\n"
	"	tbz w0, #3, cb_zero\n"
	"	cbnz w0, cb_big\n"
	"	ret\n"
	// (after: reached forward)
	".section .text.cb_zero,\"ax\",%progbits\n"
	".globl cb_zero\n"
	".type cb_zero,%function\n"
	"cb_zero:\n"
	"	mov w0, #10\n"
	"	ret\n"
	".section .text.cb_big,\"ax\",%progbits\n"
	".globl cb_big\n"
	".type cb_big,%function\n"
	"cb_big:\n"
	"	mov w0, #30\n"
	"	ret\n"
	".text\n");
#else
int32_t cb_classify(int32_t x) { return x == 0 ? 10 : x < 0 ? 20 : x >= 100 ? 30 : 1; }
int32_t cb_bit(int32_t x) { return (x & 8) == 0 ? 10 : 30; }
#endif
