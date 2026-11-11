// The host of WasmSpans.hx: typed C functions as wasm32's C ABI has them, a
// span as two i32s (its address, then its length as a size_t), a span
// passed by its address alone as one, a handle as its i32 value.
module.exports = (mem, exports) => {
	const bytes = () => new Uint8Array(mem().buffer);
	const dv = () => new DataView(mem().buffer);
	return {
		host: {
			h_sum: (p, n) => {
				console.log(`host: h_sum(${typeof p} ${p > 0}, ${typeof n} ${n})`);
				let s = 0;
				for (let i = 0; i < n; i++) s += bytes()[p + i];
				return s;
			},
			h_fill: (p, v, n) => { for (let i = 0; i < n; i++) bytes()[p + i] = v + i; },
			h_minmax: (p, n, out) => {
				let lo = Infinity, hi = -Infinity;
				for (let i = 0; i < n; i++) { const x = dv().getInt32(p + 4 * i, true); lo = Math.min(lo, x); hi = Math.max(hi, x); }
				dv().setInt32(out, lo, true);
				dv().setInt32(out + 4, hi, true);
			},
			h_open: v => v > 0 ? v * 16 : 0,
			h_close: h => h / 16,
		},
	};
};
