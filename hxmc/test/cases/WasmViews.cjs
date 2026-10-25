// The host of WasmViews.hx: functions taking views of scoped memory, each an
// address and a length (i32 both on wasm32).
module.exports = mem => ({
	host: {
		// the sum of n bytes at p
		h_sum: (p, n) => { const m = new Uint8Array(mem().buffer, p, n); let s = 0; for (const b of m) s += b; return s; },
		// the UTF-16 units at p, n of them, as a string's length in UTF-8 bytes
		h_utf8: (p, n) => Buffer.byteLength(String.fromCharCode(...new Uint16Array(mem().buffer, p, n))),
		// n bytes at p set to v
		h_fill: (p, n, v) => { new Uint8Array(mem().buffer, p, n).fill(v); },
	},
});
