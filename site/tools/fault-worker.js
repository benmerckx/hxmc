// The playground's worker (worker.js) with the kept compiler's second request (the first
// after the warmup) faulting as the WebKit of Safari 26.0 at times does in correct
// code: browser-test.mjs checks that the worker runs that request again in a fresh
// instance (Worker.engineFault).
const Instance = WebAssembly.Instance;
let n = 0;
WebAssembly.Instance = function (module, imports) {
	const inst = new Instance(module, imports);
	if (++n !== 1) return inst;
	const table = inst.exports.__indirect_function_table;
	let calls = 0;
	const faulty = {
		get(i) {
			const f = table.get(i);
			return function () {
				if (++calls === 2) throw new WebAssembly.RuntimeError('access to a null reference');
				return f.apply(this, arguments);
			};
		}
	};
	return { exports: { ...inst.exports, __indirect_function_table: faulty } };
};
importScripts('worker.js');
