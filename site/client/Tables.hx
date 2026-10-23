import Ui.el;
import Ui.fixed;
import haxe.DynamicAccess;
import js.Browser.document;
import js.Browser.window;
import js.html.Element;
import js.html.TableCellElement;

// The benchmarks page (site/benchmarks.html). The compiler: hxmc's history
// (compile-history.json: one chart per workload, HistoryChart) and the latest
// run of every runner (bench.json's format); both from the bench-data branch
// when the build has it (bench/compile-*.json, make site BENCH_DATA=...), else
// the committed site/data files (hxmc/test/CompileBench.hx). Programs:
// BenchCharts. Target generators: targets.json.
typedef BenchRun = {
	workload:String,
	runner:String,
	status:String,
	?runs:Int,
	?verified:Bool,
	?cpu_min:Float,
	?cpu_median:Float,
	?wall_min:Float,
	?wall_median:Float,
	?wall_max:Float,
	?maxrss_mb:Float,
}

typedef CompileHistory = {
	fields:Array<String>,
	runs:Array<{
		date:String,
		commit:String,
		source:String,
		?machine:String,
		?runs:Int,
		results:DynamicAccess<DynamicAccess<Array<Null<Float>>>>,
	}>,
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
		["reference", "Reference"],
		["hxmc", "hxmc"],
		["hxmc-wasm-node", "wasm, Node"],
		["hxmc-wasm-wasmtime", "wasm, wasmtime"],
	];
	static final WORKLOADS = [
		["hello", "Hello world: start-up and the core std"],
		["stdlib", "32 std modules as roots"],
		["self", "The port's own source, std macros run by Eval"],
	];
	static final TARGETS = [
		["hxb", "HXB"], ["js", "JavaScript"], ["lua", "Lua"], ["python", "Python"], ["php", "PHP"], ["neko", "Neko"],
		["hl", "HashLink"], ["hlc", "HL/C (sources)"], ["cpp", "C++ (sources)"], ["jvm", "JVM"], ["swf", "Flash (SWF)"],
	];
	static final PROJECTS = [
		["formatter", "haxe-formatter 1.9.1 and its libraries"],
		["self", "The port's own source"],
	];

	// the benchmarks page (site/benchmarks.html), its script at the end of the body
	static function main() {
		start();
		Info.fill();
	}

	static function start() {
		loadCompiler();
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

	// ---- the compiler: compile-history.json (hxmc over time) and the latest run (bench.json's format)

	static function loadCompiler() {
		final hist = document.getElementById("compiler-history");
		final latest = document.getElementById("compiler-results");
		if (latest == null) return;
		// (the bench-data branch's when the build has it, else the committed fallback)
		final get = (a:String, b:String) -> (cast window.fetch(Version.url(a)).then((r) -> r.ok ? r.json() : null).catchError((_) -> null).then((d) -> d != null ? d : window.fetch(Version.url(b))
			.then((r) -> r.ok ? r.json() : null)
			.catchError((_) -> null)) : js.lib.Promise<Dynamic>);
		get("bench/compile-latest.json", "bench.json").then((d:Null<BenchData>) -> if (d != null) renderCompilerLatest(latest, d));
		if (hist != null) get("bench/compile-history.json", "compile-history.json").then((h:Null<CompileHistory>) -> renderCompilerHistory(hist, h));
	}

	/** the charts of the workloads whose hxmc series has HistoryChart.MIN_POINTS runs; none: the whole block hidden **/
	static function renderCompilerHistory(root:Element, h:Null<CompileHistory>) {
		root.textContent = "";
		final f = (n:String) -> h == null ? -1 : h.fields.indexOf(n);
		final iMed = f("wall_median"), iMin = f("wall_min"), iMax = f("wall_max");
		final shown = h == null ? [] : [
			for (w in WORKLOADS)
				if (Lambda.count(h.runs, (r) -> r.results[w[0]] != null && r.results[w[0]]["hxmc"] != null && r.results[w[0]]["hxmc"][iMed] != null) >= HistoryChart.MIN_POINTS) w
		];
		if (shown.length == 0) {
			root.hidden = true;
			return;
		}
		root.hidden = false;
		final bar = el("div", "tabs");
		bar.setAttribute("role", "tablist");
		final grid = el("div", "charts");
		root.append(bar, grid);
		final modes = [["abs", "Seconds"], ["rel", "vs. reference"]];
		final draw = (mode:String) -> {
			for (i => m in modes) bar.children[i].setAttribute("aria-selected", m[0] == mode ? "true" : "false");
			grid.textContent = "";
			for (w in shown) {
				final pts:Array<HistoryChart.ChartPoint> = [];
				for (r in h.runs) {
					final row = r.results[w[0]];
					final e = row == null ? null : row["hxmc"];
					if (e == null || e[iMed] == null) continue;
					var div = 1.0;
					if (mode == "rel") {
						final ref = row["reference"];
						if (ref == null || ref[iMed] == null) continue;
						div = ref[iMed];
					}
					final sc = (v:Null<Float>) -> v == null ? null : v / div;
					pts.push({date: r.date, commit: r.commit, source: r.source, median: sc(e[iMed]), min: sc(e[iMin]), max: sc(e[iMax]), runs: r.runs, machine: r.machine});
				}
				HistoryChart.draw(HistoryChart.figure(grid, w[0]), w[0], pts, mode == "rel" ? ratio : secs, mode == "rel" ? 1.0 : null, mode == "rel" ? "×" : " s");
			}
		};
		for (m in modes) {
			final b = el("button", "", m[1]);
			b.setAttribute("role", "tab");
			b.onclick = () -> draw(m[0]);
			bar.append(b);
		}
		draw("abs");
	}

	static function renderCompilerLatest(root:Element, data:BenchData) {
		final runs = new Map<String, Map<String, BenchRun>>();
		for (r in data.results) {
			if (!runs.exists(r.workload)) runs[r.workload] = new Map();
			runs[r.workload][r.runner] = r;
		}
		final runners = [for (r in RUNNERS) if (Lambda.exists(data.results, (x) -> x.runner == r[0])) r];
		final t = el("table", "bench matrix");
		final head = el("tr");
		head.append(el("th", "", "Workload"));
		// (wasmtime's column: not on a phone's width)
		final cls = (r:Array<String>) -> r[0] == "hxmc-wasm-wasmtime" ? "num wide" : "num";
		for (r in runners) head.append(el("th", cls(r), r[1]));
		final thead = el("thead");
		thead.append(head);
		t.append(thead);
		final body = el("tbody");
		for (w in WORKLOADS) {
			final row = runs[w[0]];
			if (row == null) continue;
			final ref = row["reference"];
			final tr = el("tr");
			final name = el("td", "runner", w[0]);
			name.title = w[1];
			tr.append(name);
			for (r in runners) {
				final x = row[r[0]];
				final td = el("td", cls(r));
				final wall = x == null ? null : x.wall_median ?? x.wall_min;
				if (x == null) td.textContent = "–";
				else if (wall == null) {
					td.textContent = "✗";
					td.className = "num fail";
					td.title = x.status;
				} else {
					td.textContent = secs(wall);
					final refWall = ref == null ? null : ref.wall_median ?? ref.wall_min;
					if (r[0] != "reference" && refWall != null) td.append(el("span", "parts", ratio(wall / refWall)));
					td.title = 'CPU ${secs(x.cpu_median ?? x.cpu_min)}; peak RSS ${mb(x.maxrss_mb)}; ${x.runs} runs' + (x.verified ? "; output identical to the reference's" : "");
				}
				tr.append(td);
			}
			body.append(tr);
		}
		t.append(body);
		root.textContent = "";
		final scroll = el("div", "scroll");
		scroll.append(t);
		root.append(scroll);
		final facts = document.getElementById("compiler-machine");
		final m = data.meta;
		if (facts == null || m == null) return;
		final parts = [];
		final b = data.builds;
		if (b != null && b["native"] != null && b["wasm"] != null)
			parts.push('hxmc builds the port cold in ${secs(b["native"].wall)} (x86-64, ${size(b["native"].gzip)} gzipped) and ${secs(b["wasm"].wall)} (wasm, ${size(b["wasm"].gzip)}).');
		if (m.cpu != null) parts.push('${m.cpu}, ${m.cores} cores; ${m.date != null ? m.date.substring(0, 10) : ""}, ');
		facts.textContent = parts.join(" ");
		if (m.commit != null) {
			final a:js.html.AnchorElement = cast el("a", "", m.commit);
			a.href = '${HistoryChart.REPO}/commit/${m.commit}';
			facts.append(a, document.createTextNode("."));
		}
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
				final out = el("td", "out " + (c.identical ? "ok" : c.varies == true ? "muted" : "fail"), c.identical ? "identical" : c.varies == true ? "varies" : "different");
				out.title = c.diff ?? '$files${size(c.port.bytes)}';
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
			final summary = n > 0 ? ' All $n targets: ${secs(port)} vs. ${secs(ref)} (${ratio(port / ref)}); $same of $n identical${varies > 0 ? ', $varies varying' : ""}.' : "";
			final outro = m == "seq"
				? "Sequential (-D disable-parallelism): CPU time, best of the runs. RSS: port / reference."
				: "Default parallelism: wall time, best of the runs. ~: the reference's own parallel output varies, so it cannot match byte for byte.";
			paneBox.textContent = "";
			paneBox.append(pane(p[1] + "." + summary, targetsTable(rows, m), outro));
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
		if (m.cpu != null) parts.push('${m.cpu}, ${m.cores} cores${m.runner != null ? " (GitHub Actions)" : ""}');
		if (m.date != null) parts.push(m.date.substring(0, 10));
		facts.textContent = parts.join("; ") + (m.commit != null ? ", " : ".");
		if (m.commit != null) {
			final a:js.html.AnchorElement = cast el("a", "", m.commit);
			a.href = '${HistoryChart.REPO}/commit/${m.commit}';
			facts.append(a, document.createTextNode("."));
		}
	}
}
