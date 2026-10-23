import Ui.el;
import Ui.fixed;
import js.Browser.document;
import js.html.Element;
import js.html.PointerEvent;

/** one run: its median and spread (null where the run lacks the value) **/
typedef ChartPoint = {
	date:String,
	commit:String,
	source:String,
	median:Null<Float>,
	?min:Float,
	?max:Float,
	?runs:Int,
	?machine:String,
}

// A line chart over runs (inline SVG): x the runs in order, y the median with
// the min-max band of each run's samples. Points not measured on CI (imported
// from the repository's history, or local) are hollow on a shaded background.
// Pointer or tap: a tooltip with the date, the commit (a link) and the values.
class HistoryChart {
	public static final REPO = "https://github.com/benmerckx/hxmc";
	/** a series is charted from this many runs on; before that its section shows the latest run's table only **/
	public static final MIN_POINTS = 10;

	static final W = 340.0;
	static final H = 170.0;
	static final L = 40.0;
	static final R = 8.0;
	static final T = 8.0;
	static final B = 22.0;

	/** draws `points` into `box`; `format` writes a value **/
	public static function draw(box:Element, title:String, points:Array<ChartPoint>, format:Float->String, ?unit:Float, suffix = " s") {
		final pts = [for (p in points) if (p.median != null) p];
		if (pts.length == 0) {
			box.innerHTML = '<p class="note">No runs.</p>';
			return;
		}
		var lo = Math.POSITIVE_INFINITY, hi = Math.NEGATIVE_INFINITY;
		for (p in pts) {
			lo = Math.min(lo, p.min ?? p.median);
			hi = Math.max(hi, p.max ?? p.median);
		}
		if (unit != null) {
			lo = Math.min(lo, unit);
			hi = Math.max(hi, unit);
		}
		// (from zero unless the values sit far above it: changes stay visible)
		if (lo < hi * 0.6) lo = 0;
		if (hi <= lo) hi = lo + (lo == 0 ? 1 : lo * 0.1);
		final step = niceStep((hi - lo) / 4);
		lo = Math.floor(lo / step) * step;
		hi = Math.ceil(hi / step) * step;
		final n = pts.length;
		final xAt = (i:Int) -> n == 1 ? L + (W - L - R) / 2 : L + i * (W - L - R) / (n - 1);
		final yAt = (v:Float) -> T + (H - T - B) * (1 - (v - lo) / (hi - lo));
		final f1 = (v:Float) -> fixed(v, 1);
		final s = new StringBuf();
		s.add('<svg viewBox="0 0 $W $H" role="img" aria-label="${esc(title)}: ${n} runs">');
		// the runs not measured on CI: shaded
		var i = 0;
		while (i < n) {
			if (pts[i].source == "ci") {
				i++;
				continue;
			}
			var j = i;
			while (j + 1 < n && pts[j + 1].source != "ci") j++;
			final half = n == 1 ? (W - L - R) / 2 : (W - L - R) / (n - 1) / 2;
			final x0 = Math.max(L, xAt(i) - half), x1 = Math.min(W - R, xAt(j) + half);
			s.add('<rect class="offci" x="${f1(x0)}" y="$T" width="${f1(x1 - x0)}" height="${H - T - B}"/>');
			i = j + 1;
		}
		// (the ticks with as many digits as the step needs; milliseconds below a second)
		final digits = Std.int(Math.max(0, Math.min(3, -Math.floor(Math.log(step) / Math.log(10) + 1e-9))));
		final tick = (v:Float) -> v == 0 ? "0" : suffix == " s" && hi < 1 ? fixed(v * 1000, Std.int(Math.max(0, digits - 3))) + " ms" : fixed(v, digits) + suffix;
		var v = lo;
		while (v <= hi + step / 2) {
			final y = f1(yAt(v));
			s.add('<line class="grid" x1="$L" x2="${W - R}" y1="$y" y2="$y"/>');
			s.add('<text class="tick" x="${L - 4}" y="${f1(yAt(v) + 3.5)}" text-anchor="end">${esc(tick(v))}</text>');
			v += step;
		}
		if (unit != null) s.add('<line class="unit" x1="$L" x2="${W - R}" y1="${f1(yAt(unit))}" y2="${f1(yAt(unit))}"/>');
		s.add('<text class="tick" x="$L" y="${H - 5}">${pts[0].date.substring(0, 10)}</text>');
		if (n > 1) s.add('<text class="tick" x="${W - R}" y="${H - 5}" text-anchor="end">${pts[n - 1].date.substring(0, 10)}</text>');
		// the band: min to max
		if (Lambda.exists(pts, (p) -> p.min != null && p.max != null)) {
			final top = [for (k => p in pts) f1(xAt(k)) + " " + f1(yAt(p.max ?? p.median))];
			final bottom = [for (k => p in pts) f1(xAt(k)) + " " + f1(yAt(p.min ?? p.median))];
			bottom.reverse();
			if (n == 1) s.add('<line class="band1" x1="${f1(xAt(0))}" x2="${f1(xAt(0))}" y1="${top[0].split(" ")[1]}" y2="${bottom[0].split(" ")[1]}"/>');
			else s.add('<path class="band" d="M${top.join("L")}L${bottom.join("L")}Z"/>');
		}
		s.add('<path class="line" d="M${[for (k => p in pts) f1(xAt(k)) + " " + f1(yAt(p.median))].join("L")}"/>');
		final r = n > 40 ? 2 : 3;
		for (k => p in pts) s.add('<circle class="${p.source == "ci" ? "pt" : "pt off"}" cx="${f1(xAt(k))}" cy="${f1(yAt(p.median))}" r="$r"/>');
		s.add('<line class="cross" x1="0" x2="0" y1="$T" y2="${H - B}" visibility="hidden"/>');
		s.add('<rect class="hit" x="0" y="0" width="$W" height="$H"/></svg>');
		box.innerHTML = s.toString();
		final tip = el("div", "tip");
		tip.hidden = true;
		box.append(tip);
		final svg = box.firstElementChild;
		final cross = svg.querySelector(".cross");
		var current = -1;
		final show = (e:PointerEvent) -> {
			final rect = svg.getBoundingClientRect();
			final px = (e.clientX - rect.left) * W / rect.width;
			var best = 0;
			for (k in 0...n) if (Math.abs(xAt(k) - px) < Math.abs(xAt(best) - px)) best = k;
			if (best == current && !tip.hidden) return;
			current = best;
			final p = pts[best];
			cross.setAttribute("x1", "" + xAt(best));
			cross.setAttribute("x2", "" + xAt(best));
			cross.setAttribute("visibility", "visible");
			final spread = p.min != null && p.max != null ? ' <span class="muted">(${format(p.min)}–${format(p.max)})</span>' : "";
			final where = p.source == "ci" ? "" : '<div class="muted">${p.source == "imported" ? "imported: a dev VM" : p.source}${p.machine != null ? ", " + esc(p.machine) : ""}</div>';
			tip.innerHTML = '<div><b>${p.date.substring(0, 10)}</b> <a href="$REPO/commit/${esc(p.commit)}" target="_blank" rel="noopener"><code>${esc(p.commit)}</code></a></div>'
				+ '<div><b>${format(p.median)}</b>$spread</div>$where';
			tip.hidden = false;
			final left = xAt(best) / W * rect.width;
			tip.style.left = (left > rect.width / 2 ? Math.max(0, left - tip.offsetWidth - 8) : Math.min(rect.width - tip.offsetWidth, left + 8)) + "px";
		};
		final hide = () -> {
			tip.hidden = true;
			current = -1;
			cross.setAttribute("visibility", "hidden");
		};
		svg.addEventListener("pointermove", (e:PointerEvent) -> if (e.pointerType == "mouse") show(e));
		svg.addEventListener("pointerdown", show);
		// (a mouse leaving for the tooltip keeps it, to reach its link; a touch keeps it until a tap elsewhere)
		svg.addEventListener("pointerleave", (e:PointerEvent) -> if (e.pointerType == "mouse" && !tip.contains(cast e.relatedTarget)) hide());
		tip.addEventListener("pointerleave", (e:PointerEvent) -> if (e.pointerType == "mouse" && e.relatedTarget != svg && !svg.contains(cast e.relatedTarget)) hide());
		document.addEventListener("pointerdown", (e:PointerEvent) -> if (!box.contains(cast e.target)) hide());
	}

	static function esc(s:String):String return StringTools.htmlEscape(s, true);

	static function niceStep(raw:Float):Float {
		if (raw <= 0) return 1;
		final p = Math.pow(10, Math.floor(Math.log(raw) / Math.log(10)));
		final f = raw / p;
		return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * p;
	}

	/** a figure: caption, plot box **/
	public static function figure(parent:Element, caption:String):Element {
		final fig = el("figure", "chart");
		final box = el("div", "plot");
		fig.append(el("figcaption", "", caption), box);
		parent.append(fig);
		return box;
	}
}
