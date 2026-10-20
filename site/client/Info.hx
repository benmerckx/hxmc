import js.Browser.document;
import js.Browser.window;
import js.html.Element;

// The build facts on every page ([data-info] elements: date, commit, sizes)
// from build-info.json, which `make site` writes (Makefile)
class Info {
	static function main() {
		fill();
	}

	public static function fill() {
		window.fetch(Version.url("build-info.json")).then((r) -> r.ok ? r.json() : null).then((info:haxe.DynamicAccess<String>) -> {
			if (info == null) return;
			for (node in document.querySelectorAll("[data-info]")) {
				final el:Element = cast node;
				final v = info.get(el.dataset.info);
				if (v != null && v != "-") el.textContent = v;
			}
		}).catchError((_) -> {});
	}
}
