import Ui.el;
import Ui.fixed;
import haxe.DynamicAccess;
import js.Browser.document;
import js.Browser.window;
import js.html.Element;

// The Programs section: the HaxeBenchmarks cases (hxmc/test/Bench.hx,
// .github/workflows/bench.yml). bench/history.json (every run: per case and
// target the median, min, max, peak RSS, compile times) and bench/latest.json
// (the newest CI run in full) come from the bench-data branch, copied by
// `make site BENCH_DATA=<dir>`. hxmc's history as one chart per case
// (HistoryChart); the other targets, which change only with their pinned
// toolchains, in one table of the latest run (time, vs. hxmc, peak RSS, size,
// compile time).
typedef HistoryRun = {
	file:String,
	date:String,
	commit:String,
	source:String,
	?machine:String,
	?runs:Int,
	?stat:String,
	?note:String,
	?run_url:String,
	results:DynamicAccess<DynamicAccess<Array<Null<Float>>>>,
}

// (schema 2: each run's per case and target array holds `fields`: median, min,
// max, rss_mb, build_s, haxe_s, cc_s; schema 1 the first four)
typedef History = {
	?schema:Int,
	?fields:Array<String>,
	targets:Array<String>,
	runs:Array<HistoryRun>,
}

typedef LatestEntry = {
	?median:Float,
	?min:Float,
	?max:Float,
	?times:Array<Float>,
	?cpu:Float,
	?rss_mb:Float,
	?build_s:Float,
	?haxe_s:Float,
	?cc_s:Float,
	?size:Float,
	?gzip:Float,
	?check:String,
	?error:String,
}

typedef Latest = {
	date:String,
	short:String,
	runs:Int,
	?run_url:String,
	?machine:{?cpu:String, ?cores:Int, ?memory_gb:Float, ?runner:String},
	?versions:DynamicAccess<String>,
	targets:Array<String>,
	cases:Array<String>,
	results:DynamicAccess<DynamicAccess<LatestEntry>>,
	?checks:DynamicAccess<{?output:String, differ:Array<String>}>,
}

class BenchCharts {
	// the targets in their table order
	static final TARGETS = [
		["hxmc", "hxmc"], ["hxmc-wasm", "hxmc wasm"], ["hxmc-wasmgc", "hxmc WasmGC"], ["cpp", "C++"], ["jvm", "JVM"], ["js", "JS"], ["hlc", "HL/C"],
		["hl", "HL JIT"],
	];
	static final CASES = [
		["alloc", "alloc"], ["bcrypt", "bcrypt"], ["binarytrees", "binarytrees"], ["json", "json"], ["mandelbrot", "mandelbrot"],
		["mandelbrot_anon", "mandelbrot (anon)"], ["nbody", "nbody"], ["sha256", "sha256"], ["sha512", "sha512"],
		["formatter_noio", "formatter"],
	];
	static final METRICS = [
		["time", "Time"], ["rel", "vs. hxmc"], ["rss", "Peak RSS"], ["size", "Size"], ["build", "Compile"],
	];
	static final NOTES = [
		"time" => "Median wall time; bold: fastest.",
		"rel" => "Median time relative to hxmc (below 1×: faster); last row: geometric mean.",
		"rss" => "Peak resident set size (VMs included).",
		"size" => "The artifact, gzip -9 (stripped executables for C++ and HL/C).",
		"build" => "Cold build: hxmc's whole build; the port, plus g++ or gcc for C++ and HL/C (small print).",
	];

	public static function load() {
		final get = (f:String) -> (cast window.fetch(Version.url(f)).then((r) -> r.ok ? r.json() : null).catchError((_) -> null) : js.lib.Promise<Dynamic>);
		final root = document.getElementById("programs-results");
		final hist = document.getElementById("programs-history");
		if (root == null) return;
		get("bench/history.json").then((h:Null<History>) -> {
			if (hist != null && h != null) renderHistory(hist, h);
		});
		get("bench/latest.json").then((latest:Null<Latest>) -> {
			if (latest != null) renderLatest(root, latest)
			else root.innerHTML = "<p class=\"note\">No results in this build of the site (<code>make site BENCH_DATA=&lt;bench-data checkout&gt;</code>).</p>";
		});
	}

	static function label(id:String, list:Array<Array<String>>):String {
		for (t in list) if (t[0] == id) return t[1];
		return id;
	}

	static function secs(s:Float):String {
		return s < 0.1 ? fixed(s * 1000, 0) + " ms" : s < 10 ? fixed(s, 2) + " s" : fixed(s, 1) + " s";
	}

	static function bytes(b:Float):String {
		return b >= 1 << 20 ? fixed(b / (1 << 20), 1) + " MB" : Math.max(1, Math.round(b / 1024)) + " KB";
	}

	static function ratio(r:Float):String {
		return (r < 10 ? fixed(r, 2) : fixed(r, 1)) + "×";
	}

	static function geomean(xs:Array<Float>):Float {
		var s = 0.0;
		for (x in xs) s += Math.log(x);
		return Math.exp(s / xs.length);
	}

	// ---- hxmc over time

	static function renderHistory(root:Element, h:History) {
		root.textContent = "";
		final fields = h.fields ?? ["median", "min", "max", "rss_mb"];
		final iMed = fields.indexOf("median"), iMin = fields.indexOf("min"), iMax = fields.indexOf("max");
		// (on a phone's width one chart at a time, picked by the tabs)
		final pick = el("div", "tabs narrow");
		pick.setAttribute("role", "tablist");
		final grid = el("div", "charts pick");
		root.append(pick, grid);
		final figs:Array<Element> = [];
		for (c in CASES) {
			final pts:Array<HistoryChart.ChartPoint> = [];
			for (r in h.runs) {
				final row = r.results[c[0]];
				final e = row == null ? null : row["hxmc"];
				if (e == null || e[iMed] == null) continue;
				pts.push({
					date: r.date,
					commit: r.commit,
					source: r.source,
					median: e[iMed],
					min: iMin >= 0 ? e[iMin] : null,
					max: iMax >= 0 ? e[iMax] : null,
					runs: r.runs,
					machine: r.machine
				});
			}
			if (pts.length < HistoryChart.MIN_POINTS) continue;
			final box = HistoryChart.figure(grid, c[1]);
			HistoryChart.draw(box, c[1], pts, secs);
			final b = el("button", "", c[1]);
			b.setAttribute("role", "tab");
			final i = figs.length;
			b.onclick = () -> for (j => f in figs) {
				if (j == i) f.classList.add("on") else f.classList.remove("on");
				pick.children[j].setAttribute("aria-selected", j == i ? "true" : "false");
			};
			pick.append(b);
			figs.push(box.parentElement);
		}
		// (no series long enough yet: no charts, the latest run's table only)
		root.hidden = figs.length == 0;
		if (figs.length > 0) pick.children[0].click();
	}

	// ---- the latest run

	static function renderLatest(root:Element, d:Latest) {
		root.textContent = "";
		final targets = [for (t in TARGETS) if (d.targets.indexOf(t[0]) >= 0) t[0]];
		final cases = [for (c in CASES) if (d.results.exists(c[0])) c[0]];
		final bar = el("div", "tabs");
		bar.setAttribute("role", "tablist");
		final scroll = el("div", "scroll");
		final legendNote = el("p", "note");
		root.append(bar, scroll, legendNote);
		final show = (metric:String) -> {
			for (i => m in METRICS) bar.children[i].setAttribute("aria-selected", m[0] == metric ? "true" : "false");
			scroll.textContent = "";
			scroll.append(latestTable(d, targets, cases, metric));
			legendNote.textContent = NOTES[metric];
		};
		for (m in METRICS) {
			final b = el("button", "", m[1]);
			b.setAttribute("role", "tab");
			b.onclick = () -> show(m[0]);
			bar.append(b);
		}
		show("time");
		final facts = document.getElementById("programs-machine");
		if (facts != null) {
			final m = d.machine;
			facts.textContent = '${d.runs} runs per target'
				+ (m != null && m.cpu != null ? ' on ${m.cpu}, ${m.cores} cores (GitHub Actions)' : "")
				+ '; latest ${d.date.substring(0, 10)}, ';
			final a:js.html.AnchorElement = cast el("a", "", d.short);
			a.href = '${HistoryChart.REPO}/commit/${d.short}';
			facts.append(a, document.createTextNode("."));
		}
	}

	static function latestTable(d:Latest, targets:Array<String>, cases:Array<String>, metric:String):Element {
		final t = el("table", "bench matrix");
		final head = el("tr");
		head.append(el("th", "", "Case"));
		for (x in targets) head.append(el("th", "num", label(x, TARGETS)));
		final thead = el("thead");
		thead.append(head);
		t.append(thead);
		final body = el("tbody");
		final rels = [for (x in targets) x => []];
		final sums = [for (x in targets) x => 0.0], counts = [for (x in targets) x => 0];
		for (c in cases) {
			final row = d.results[c];
			final tr = el("tr");
			tr.append(el("td", "runner", label(c, CASES)));
			final base = row["hxmc"] != null ? row["hxmc"].median : null;
			final value = (r:LatestEntry) -> r == null || (r.error != null && metric != "build") ? null : switch metric {
				case "time": r.median;
				case "rel": base == null || r.median == null ? null : r.median / base;
				case "rss": r.rss_mb;
				case "size": r.gzip;
				case _: r.build_s;
			};
			var best = Math.POSITIVE_INFINITY;
			for (x in targets) {
				final v = value(row[x]);
				if (v != null && v < best) best = v;
			}
			for (x in targets) {
				final r = row[x];
				final v = value(r);
				final td = el("td", "num");
				if (r == null) td.textContent = "–";
				else if (v == null && r.error != null) {
					td.textContent = "✗";
					td.className = "num fail";
					td.title = r.error.substring(0, 400);
				} else if (v == null) td.textContent = "–";
				else {
					td.textContent = switch metric {
						case "time": secs(v);
						case "rel": ratio(v);
						case "rss": v < 10 ? fixed(v, 1) + " MB" : Math.round(v) + " MB";
						case "size": bytes(v);
						case _: secs(v);
					};
					if (metric == "rel") rels[x].push(v);
					if (metric == "build") {
						sums[x] += v;
						counts[x]++;
						if (r.cc_s != null && r.haxe_s != null) td.append(el("span", "parts", fixed(r.haxe_s, 2) + " + " + fixed(r.cc_s, 2)));
					}
					if (v == best && metric != "rel") td.classList.add("best");
					if (metric == "rel" && x != "hxmc" && v < 0.995) td.classList.add("best");
					if (r.median != null) td.title = 'median ${secs(r.median)} (${secs(r.min)}–${secs(r.max)}); CPU ${r.cpu != null ? secs(r.cpu) : "–"}; ${r.rss_mb} MB';
				}
				if (r != null && r.check == "differs") {
					td.append(el("span", "warnmark", " ⚠"));
					td.title = "check output differs. " + td.title;
				}
				tr.append(td);
			}
			body.append(tr);
		}
		if (metric == "rel" || metric == "build") {
			final tr = el("tr", "ref");
			tr.append(el("td", "runner", metric == "rel" ? "geomean" : "total"));
			for (x in targets)
				tr.append(el("td", "num",
					metric == "rel" ? (rels[x].length == cases.length ? ratio(geomean(rels[x])) : "–") : (counts[x] == cases.length ? secs(sums[x]) : "–")));
			body.append(tr);
		}
		t.append(body);
		return t;
	}
}
