// The host of WasmTyped.hx: a span by its address alone as one i32, null as
// 0, an out-parameter the address of an i32 slot.
module.exports = (mem, exports) => {
	const dv = () => new DataView(mem().buffer);
	return {
		host: {
			t_dot: (p, n) => {
				if (p == 0) return -1;
				let s = 0;
				for (let i = 0; i < n; i++) s += dv().getInt32(p + 8 * i, true) * dv().getInt32(p + 8 * i + 4, true);
				return s;
			},
			t_swap: (p, n) => {
				for (let i = 0; i < n; i++) {
					const a = dv().getInt32(p + 8 * i, true);
					dv().setInt32(p + 8 * i, dv().getInt32(p + 8 * i + 4, true), true);
					dv().setInt32(p + 8 * i + 4, a, true);
				}
			},
			t_open: (v, out) => {
				if (v == 0) return -1;
				dv().setInt32(out, v * 16, true);
				return 0;
			},
			t_value: o => o == 0 ? -1 : o / 16,
		},
	};
};
