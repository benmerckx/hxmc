import Ui.el;
import Ui.fixed;
import haxe.DynamicAccess;
import js.Browser.document;
import js.Browser.window;
import js.html.Element;
import js.html.TableCellElement;

// The Benchmarks and Target generators sections: tables of bench.json and
// targets.json (measured results, site/data; targets.json from the bench-data
// branch when the build has it), copied by `make site` (Makefile); the
// Programs part from the benchmark history (BenchCharts).
typedef BenchRun = {
	workload:String,
	runner:String,
	status:String,
	?runs:Int,
	?verified:Bool,
	?cpu_min:Float,
	?wall_min:Float,
	?maxrss_mb:Float,
}

typedef BuildFacts = {
	wall:Float,
	cpu:Float,
	size:Float,
	gzip:Float,
}

typedef BenchData = {
	results:Array<BenchRun>,
	?builds:DynamicAccess<BuildFacts>,
	?notes:DynamicAccess<String>,
	?meta:{
		?cpu:String,
		?cores:Int,
		?memory_gb:Float,
		?date:String,
		?commit:String,
		?versions:DynamicAccess<String>,
	},
}

typedef TargetSide = {
	status:String,
	cpu:Float,
	?wall:Float,
	rss_mb:Float,
	members:Int,
	bytes:Float,
}

typedef TargetRun = {
	project:String,
	target:String,
	reference:TargetSide,
	?port:TargetSide,
	identical:Bool,
	/** with the compilers' default parallelism (targets.json since 2026-10-19) **/
	?parallel:{
		reference:TargetSide,
		?port:TargetSide,
		identical:Bool,
		?diff:String,
		/** the reference's own parallel output differs from its sequential one: not comparable byte for byte **/
		?varies:Bool,
	},
}

/** a row in one mode: sequential (CPU time) or parallel (wall time) **/
typedef TargetCell = {
	reference:TargetSide,
	?port:TargetSide,
	identical:Bool,
	?varies:Bool,
	?diff:String,
}

typedef TargetData = {
	results:Array<TargetRun>,
	?meta:{
		?cpu:String,
		?cores:Int,
		?date:String,
		?commit:String,
		?reference:String,
		?runner:String,
		?run_url:String,
	},
}

class Tables {
	static final RUNNERS = [
		["reference", "OCaml reference"],
		["hxmc", "hxmc, x86-64"],
		["hxmc-wasm-node", "hxmc, wasm (Node)"],
		["hxmc-wasm-wasmtime", "hxmc, wasm (wasmtime)"],
	];
	static final WORKLOADS = [
		["self", "The port's own source: 52k lines in 382 modules, with std macros run by the Eval interpreter."],
		["stdlib", "32 standard library modules (JSON, XML, zip, crypto, data structures) as roots."],
		["hello", "Hello world: mostly start-up time and the core standard library."],
	];
	static final TARGETS = [
		["hxb", "HXB"], ["js", "JavaScript"], ["lua", "Lua"], ["python", "Python"], ["php", "PHP"], ["neko", "Neko"],
		["hl", "HashLink"], ["hlc", "HL/C (sources)"], ["cpp", "C++ (sources)"], ["jvm", "JVM"], ["swf", "Flash (SWF)"],
	];
	static final PROJECTS = [
		["formatter", "haxe-formatter 1.9.1 with its six libraries (tokentree, haxeparser, hxparse, json2object, hxargs, hxjsonast): the HaxeBenchmarks formatter case."],
		["self", "The port's own source, about 1,000 modules. Targets without threads or a file system reject it, in both compilers."],
	];

	// the benchmarks page (site/benchmarks.html), its script at the end of the body
	static function main() {
		start();
		Info.fill();
	}

	static function start() {
		load("bench.json", "bench-results", renderBench);
		BenchCharts.load();
		load("targets.json", "targets-results", renderTargets);
	}

	static function load<T>(url:String, id:String, render:(Element, T) -> Void) {
		final root = document.getElementById(id);
		if (root == null) return;
		window.fetch(Version.url(url)).then((r) -> r.ok ? r.json() : null).then((d) -> if (d != null) render(root, d)).catchError((_) -> {});
	}

	static function secs(s:Null<Float>):String {
		return s == null ? "–" : s < 10 ? fixed(s, 2) + " s" : s < 100 ? fixed(s, 1) + " s" : Math.round(s) + " s";
	}

	static function ratio(r:Float):String {
		return r < 10 ? fixed(r, 2) + "×" : r < 100 ? fixed(r, 1) + "×" : Math.round(r) + "×";
	}

	static function mb(m:Null<Float>):String {
		return m == null ? "–" : m >= 1024 ? fixed(m / 1024, 1) + " GB" : Math.round(m) + " MB";
	}

	static function size(b:Float):String {
		return b >= 1 << 20 ? fixed(b / (1 << 20), 1) + " MB" : Math.max(1, Math.round(b / 1024)) + " KB";
	}

	/** the last line of a failed run's log ("exit 1: <log tail, | for newlines>"), without the exit code */
	static function lastLine(status:String):String {
		final lines = [for (s in status.split(" | ")) if (StringTools.trim(s) != "") StringTools.trim(s)];
		return ~/^(exit \d+: )?[| ]*/.replace(lines.length > 0 ? lines[lines.length - 1] : "", "");
	}

	/** a cell with a bar for each ratio to the reference, on a log scale shared by the table */
	static function scale(ratios:Array<Float>):(x:Float, ?base:Bool) -> Element {
		var lo = 0.5, hi = 2.0;
		for (r in ratios) {
			lo = Math.min(lo, r);
			hi = Math.max(hi, r);
		}
		final pos = (r:Float) -> 100 * (Math.log(r) - Math.log(lo)) / (Math.log(hi) - Math.log(lo));
		return (x, base = false) -> {
			final bar = el("td", "barcol");
			final track = el("div", "track");
			final fill = el("div", "fill" + (base ? " base" : x < 0.995 ? " fast" : ""));
			fill.style.width = Math.max(1.5, pos(x)) + "%";
			final mark = el("div", "mark");
			mark.style.left = pos(1) + "%";
			track.append(fill, mark, el("span", "lbl", ratio(x)));
			bar.append(track);
			return bar;
		}
	}

	static function failure(text:String, cls:String, span:Int):Element {
		final td:TableCellElement = cast el("td", cls, text);
		td.colSpan = span;
		return td;
	}

	/** one tab and pane per entry, the first one shown */
	static function tabs(root:Element, entries:Array<{label:String, pane:Element}>) {
		root.textContent = "";
		final tabs = el("div", "tabs");
		tabs.setAttribute("role", "tablist");
		for (i => e in entries) {
			final b = el("button", "", e.label);
			b.setAttribute("role", "tab");
			b.setAttribute("aria-selected", i == 0 ? "true" : "false");
			b.onclick = () -> for (j => f in entries) {
				tabs.children[j].setAttribute("aria-selected", j == i ? "true" : "false");
				f.pane.hidden = j != i;
			};
			tabs.append(b);
			e.pane.hidden = i != 0;
		}
		root.append(tabs);
		for (e in entries) root.append(e.pane);
	}

	static function pane(intro:String, table:Element, outro:String):Element {
		final pane = el("div", "pane");
		pane.append(el("p", "note", intro));
		final scroll = el("div", "scroll");
		scroll.append(table);
		pane.append(scroll);
		pane.append(el("p", "note", outro));
		return pane;
	}

	/** a version string without build details ("(…)", "version", quotes, dates) */
	static function version(v:String):String {
		return ~/ \d{4}-\d\d-\d\d$/.replace(~/"/g.replace(~/ version /.replace(~/\s*\([^)]*\)/g.replace(v, ""), " "), ""), "");
	}

	// ---- bench.json

	static function benchTable(rows:Array<{label:String, run:BenchRun}>, ref:BenchRun):Element {
		final t = el("table", "bench");
		t.innerHTML = "<thead><tr><th>Runner</th><th class=\"num\">CPU</th><th class=\"barcol\">CPU vs. reference <span class=\"muted\">(log scale)</span></th><th class=\"num wall\">Wall</th><th class=\"num\">Peak RSS</th><th class=\"out\">Output</th></tr></thead>";
		final body = el("tbody");
		final bar = scale([for (r in rows) if (r.run.cpu_min != null) r.run.cpu_min / ref.cpu_min]);
		for (row in rows) {
			final r = row.run, isRef = r.runner == "reference";
			final tr = el("tr", isRef ? "ref" : "");
			final name = el("td", "runner", row.label);
			// on narrow screens the Output column is hidden: a check mark marks verified runs
			if (r.verified) name.append(el("span", "chk", " ✓"));
			if (r.runs != null && r.runs >= 1) name.title = '${r.runs} run${r.runs > 1 ? "s" : ""}';
			tr.append(name);
			if (r.cpu_min == null) {
				tr.append(failure(StringTools.startsWith(r.status, "exit") ? "failed: " + lastLine(r.status).substring(0, 120) : r.status, "fail", 5));
			} else {
				tr.append(el("td", "num", secs(r.cpu_min) + (r.runs == 1 ? "¹" : "")));
				tr.append(bar(r.cpu_min / ref.cpu_min, isRef));
				tr.append(el("td", "num wall", secs(r.wall_min)));
				tr.append(el("td", "num", mb(r.maxrss_mb)));
				tr.append(el("td", "out " + (r.verified ? "ok" : "muted"), isRef ? "baseline" : r.verified ? "identical" : "–"));
			}
			body.append(tr);
		}
		t.append(body);
		return t;
	}

	static function renderBench(root:Element, data:BenchData) {
		final byWorkload = new Map<String, Map<String, BenchRun>>();
		for (r in data.results) {
			if (!byWorkload.exists(r.workload)) byWorkload[r.workload] = new Map();
			byWorkload[r.workload][r.runner] = r;
		}
		final entries = [];
		for (w in WORKLOADS) {
			final runs = byWorkload[w[0]];
			if (runs == null || !runs.exists("reference")) continue;
			final ref = runs["reference"];
			final rows = [for (r in RUNNERS) if (runs.exists(r[0])) {label: r[1], run: runs[r[0]]}];
			final single = Lambda.exists(rows, (r) -> r.run.runs == 1);
			entries.push({
				label: w[0],
				pane: pane(w[1] + ' Reference: ${secs(ref.cpu_min)} CPU, ${mb(ref.maxrss_mb)}.', benchTable(rows, ref),
					"Identical (✓): every .hxb member byte-identical to the reference's. The dashed line marks the reference." + (single ? " ¹ Single run (slow runner)." : ""))
			});
		}
		if (entries.length == 0) return;
		tabs(root, entries);
		final facts = document.getElementById("bench-machine");
		final m = data.meta;
		if (facts == null || m == null) return;
		final parts = [];
		if (m.cpu != null) parts.push('${m.cpu}, ${m.cores} cores${m.memory_gb != null ? ', ${Math.round(m.memory_gb)} GB' : ""}');
		if (m.date != null) parts.push('measured ${m.date.substring(0, 10)}');
		if (m.commit != null) parts.push('commit ${m.commit}');
		final v = m.versions != null ? m.versions : new DynamicAccess();
		final tools = [
			for (t in [["reference", "Haxe"], ["node", "Node"], ["wasmtime", ""]])
				if (v[t[0]] != null) (t[1] != "" ? t[1] + " " : "") + version(v[t[0]])
		];
		facts.textContent = parts.join("; ") + (tools.length > 0 ? ". Tools: " + tools.join(", ") + "." : ".");
		final b = data.builds;
		final builds = document.getElementById("bench-builds");
		if (b == null || builds == null) return;
		final line = [];
		if (b["native"] != null) line.push('the x86-64 executable in ${secs(b["native"].wall)} (${size(b["native"].size)}, ${size(b["native"].gzip)} gzipped)');
		if (b["wasm"] != null) line.push('the WebAssembly module in ${secs(b["wasm"].wall)} (${size(b["wasm"].size)}, ${size(b["wasm"].gzip)} gzipped)');
		builds.textContent = "hxmc builds the port from source, cold: " + line.join("; ") + ".";
	}

	// ---- targets.json

	static function targetIndex(target:String):Int {
		for (i => t in TARGETS) if (t[0] == target) return i;
		return -1;
	}

	static final MODES = [
		["seq", "sequential · CPU"],
		["par", "parallel · wall"],
	];

	/** a row's measurement in `mode`, null when not measured that way **/
	static function cell(r:TargetRun, mode:String):Null<TargetCell> {
		if (mode == "seq") return {reference: r.reference, port: r.port, identical: r.identical};
		final p = r.parallel;
		if (p == null) return r.reference.status != "ok" ? {reference: r.reference, identical: false} : null;
		return {reference: p.reference, port: p.port, identical: p.identical, varies: p.varies, diff: p.diff};
	}

	static function time(s:TargetSide, mode:String):Float return mode == "seq" ? s.cpu : s.wall;

	static function targetsTable(rows:Array<TargetRun>, mode:String):Element {
		final t = el("table", "bench");
		final what = mode == "seq" ? "CPU" : "wall";
		t.innerHTML = '<thead><tr><th>Target</th><th class="num">Reference</th><th class="num">Port</th><th class="barcol">Port $what vs. reference <span class="muted">(log scale)</span></th><th class="num wall">Peak RSS</th><th class="out">Output</th></tr></thead>';
		final body = el("tbody");
		final cells = [for (r in rows) cell(r, mode)];
		final bar = scale([for (c in cells) if (c != null && c.port != null && c.port.status == "ok") time(c.port, mode) / time(c.reference, mode)]);
		for (i => r in rows) {
			final c = cells[i];
			final tr = el("tr");
			final ti = targetIndex(r.target);
			final name = el("td", "runner", ti >= 0 ? TARGETS[ti][1] : r.target);
			if (c != null && (c.identical || c.varies == true)) name.append(el("span", "chk", c.identical ? " ✓" : " ~"));
			tr.append(name);
			if (c == null) {
				tr.append(failure("not measured in this mode", "muted", 5));
			} else if (c.reference.status != "ok") {
				tr.append(failure("the reference compiler rejects this project: " + lastLine(c.reference.status).substring(0, 110), "fail muted", 5));
			} else if (c.port == null || c.port.status != "ok") {
				tr.append(el("td", "num", secs(time(c.reference, mode))));
				tr.append(failure("port failed: " + (c.port != null ? c.port.status.substring(0, 110) : "not run"), "fail", 4));
			} else {
				tr.append(el("td", "num", secs(time(c.reference, mode))));
				tr.append(el("td", "num", secs(time(c.port, mode))));
				tr.append(bar(time(c.port, mode) / time(c.reference, mode)));
				tr.append(el("td", "num wall", mb(c.port.rss_mb) + " / " + mb(c.reference.rss_mb)));
				final files = c.port.members > 1 ? c.port.members + " files, " : "";
				final out = el("td", "out " + (c.identical ? "ok" : c.varies == true ? "muted" : "fail"),
					c.identical ? 'identical, $files${size(c.port.bytes)}' : c.varies == true ? 'varies, $files${size(c.port.bytes)}' : "different");
				if (c.diff != null) out.title = c.diff;
				tr.append(out);
			}
			body.append(tr);
		}
		t.append(body);
		return t;
	}

	static function renderTargets(root:Element, data:TargetData) {
		final projects = [for (p in PROJECTS) if (Lambda.exists(data.results, (r) -> r.project == p[0])) p];
		if (projects.length == 0) return;
		final modes = Lambda.exists(data.results, (r) -> r.parallel != null) ? MODES : [MODES[0]];
		var project = 0, mode = 0;
		root.textContent = "";
		final bar = el("div", "tabs");
		bar.setAttribute("role", "tablist");
		final paneBox = el("div");
		root.append(bar, paneBox);
		final buttons = [];
		final show = () -> {
			for (i => b in buttons) b.setAttribute("aria-selected", (i < projects.length ? i == project : i - projects.length == mode) ? "true" : "false");
			final p = projects[project], m = modes[mode][0];
			final rows = data.results.filter((r) -> r.project == p[0]);
			rows.sort((a, b) -> targetIndex(a.target) - targetIndex(b.target));
			var ref = 0.0, port = 0.0, same = 0, varies = 0, n = 0;
			for (r in rows) {
				final c = cell(r, m);
				if (c == null || c.port == null || c.port.status != "ok") continue;
				n++;
				ref += time(c.reference, m);
				port += time(c.port, m);
				if (c.identical) same++ else if (c.varies == true) varies++;
			}
			final what = m == "seq" ? "CPU" : "wall time";
			final summary = n > 0 ? ' Over the $n targets: ${secs(port)} of $what for the port, ${secs(ref)} for the reference (${ratio(port / ref)}); $same of $n outputs identical${varies > 0 ? ', $varies varying' : ""}.' : "";
			final outro = m == "seq"
				? "Sequential: -D disable-parallelism, one core each (per-core efficiency). CPU: user + system, minimum of the runs. Peak RSS: port / reference. The dashed line marks the reference; green bars are faster than it."
				: "Parallel: each compiler's default parallelism, what a plain build gets. Wall time, minimum of the runs. Peak RSS: port / reference. Varies (~): the reference's own parallel output differs from its sequential one and from run to run (e.g. genjvm's closures, HXB's string pools), so the port's is compared member by member but cannot match byte for byte.";
			paneBox.textContent = "";
			paneBox.append(pane(p[1] + summary, targetsTable(rows, m), outro));
		};
		for (i => p in projects) {
			final b = el("button", "", p[0]);
			b.setAttribute("role", "tab");
			b.onclick = () -> {
				project = i;
				show();
			};
			buttons.push(b);
			bar.append(b);
		}
		if (modes.length > 1) for (i => m in modes) {
			final b = el("button", "", m[1]);
			b.setAttribute("role", "tab");
			if (i == 0) b.style.marginLeft = "auto";
			b.onclick = () -> {
				mode = i;
				show();
			};
			buttons.push(b);
			bar.append(b);
		}
		show();
		final facts = document.getElementById("targets-machine");
		final m = data.meta;
		if (facts == null || m == null) return;
		final parts = [];
		if (m.cpu != null) parts.push('${m.cpu}, ${m.cores} cores${m.runner != null ? " (GitHub Actions, " + StringTools.trim(m.runner) + ")" : ""}');
		if (m.date != null) parts.push('measured ${m.date.substring(0, 10)}');
		if (m.commit != null) parts.push('commit ${m.commit}');
		if (m.reference != null) parts.push('reference: ${m.reference}');
		facts.textContent = parts.join("; ") + ".";
	}
}
