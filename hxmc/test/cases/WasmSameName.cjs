// The host of WasmSameName.hx: functions of the same name in several modules,
// each recording which one ran (rec.last).
let last = 0;
module.exports = mem => ({
	a: { start: x => { last = 100 + x; }, tick: x => x + 1, "b.c": () => 7 },
	b: { start: x => { last = 200 + x; }, tick: (x, y) => x * y },
	"a.b": { c: () => 8 },
	env: { start: x => { last = 300 + x; } },
	rec: { last: () => last },
});
