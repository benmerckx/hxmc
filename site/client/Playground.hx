import Protocol;
import Ui.error;
import js.Browser.document;
import js.Browser.window;
import js.Syntax;
import js.html.ButtonElement;
import js.html.Element;
import js.html.SelectElement;
import js.html.TextAreaElement;
import js.lib.Promise;
import js.lib.RegExp;

// The playground. The compiler runs in Web Workers (Worker.hx): one for Run and
// Compile to HXB, one for the editor's display requests (completion, hover,
// signature help, diagnostics), so typing never waits behind a running program.

typedef Program = {main:String, file:String, code:String};
typedef Example = {title:String, file:String, source:String};

/** the parts of the compiler's display JSON (haxe.display.JsonModuleTypes) the editor shows */
typedef JsonType = {kind:String, ?args:Dynamic};

typedef JsonArg = {name:String, ?opt:Bool, t:JsonType};

typedef DisplayItem = {kind:String, ?args:Dynamic, ?type:JsonType};

typedef ItemInfo = {label:String, kind:Int, ?detail:String, ?doc:String};

class Playground {
	static inline final MONACO = "https://cdn.jsdelivr.net/npm/monaco-editor@0.52.2/min/vs";

	static var out:Element;
	static var state:Element;
	static var timing:Element;
	static var members:Element;
	static var runButton:ButtonElement;
	static var hxbButton:ButtonElement;
	static var exampleSelect:SelectElement;

	// The compiler is a 10 MB wasm32-wasi module (MODULE). It is compiled
	// once, only when the playground comes into view (or Run is pressed), and the
	// compiled module is shared with the workers. Phones and low-memory devices
	// skip the background type-checker (diagnostics, completion), the second
	// compiler instance: two of them got mobile browsers' tabs killed.
	static final LOW_MEMORY = {
		final memory:Null<Float> = (cast window.navigator).deviceMemory;
		(memory != null && memory <= 4) || window.matchMedia("(pointer: coarse)").matches;
	};
	// hih.wasm uses exception handling with exnref (Chrome and Edge 137+,
	// Firefox 131+, Safari 18.4+); hih-legacy.wasm, the same compiler built with
	// -D hxmc.wasm-eh=legacy, the legacy instructions (Chrome and Edge 95+,
	// Firefox 100+, Safari 15.2+). Each is detected with a tiny module (a
	// function with an exnref local and a try_table; one with try and
	// catch_all) and only the module chosen is downloaded; ?eh=legacy or
	// ?eh=exnref in the page's address forces one (tests).
	static final EXNREF = validates([0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 0x60, 0, 0, 3, 2, 1, 0, 10, 10, 1, 8, 1, 1, 0x69, 0x1F, 0x40, 0, 0x0B, 0x0B]);
	static final LEGACY_EH = validates([0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 0x60, 0, 0, 3, 2, 1, 0, 10, 8, 1, 6, 0, 0x06, 0x40, 0x19, 0x0B, 0x0B]);
	static final MODULE:Null<String> = {
		switch new js.html.URLSearchParams(window.location.search).get("eh") {
			case "legacy": LEGACY_EH ? "hih-legacy.wasm" : null;
			case "exnref": EXNREF ? "hih.wasm" : null;
			case _: EXNREF ? "hih.wasm" : LEGACY_EH ? "hih-legacy.wasm" : null;
		}
	};

	static function validates(bytes:Array<Int>):Bool
		return try js.lib.WebAssembly.validate(new js.lib.Uint8Array(bytes)) catch (_:Dynamic) false;

	// the playground page (site/playground.html), its script at the end of the body
	static function main() {
		setup();
	}

	static function setup() {
		out = document.getElementById("out");
		state = document.getElementById("state");
		timing = document.getElementById("timing");
		members = document.getElementById("members");
		runButton = cast document.getElementById("run");
		hxbButton = cast document.getElementById("hxb");
		exampleSelect = cast document.getElementById("example");

		saved = try window.localStorage.getItem("hih-code") catch (_:Dynamic) null;
		window.fetch(Version.url("playground/index.json")).then((r) -> r.json()).then((list:Array<Example>) -> {
			examples = list;
			final groups = new Map<String, Element>();
			for (i => ex in list) {
				final label = ex.source == "try.haxe.org" ? "From try.haxe.org" : "haxe-in-haxe";
				if (!groups.exists(label)) {
					final group = document.createOptGroupElement();
					group.label = label;
					exampleSelect.append(group);
					groups[label] = group;
				}
				groups[label].append(new js.html.Option(ex.title, Std.string(i)));
			}
			if (saved == null) loadExample(0);
		});
		exampleSelect.addEventListener("change", () -> loadExample(Std.parseInt(exampleSelect.value)));

		final loader = document.createScriptElement();
		loader.src = MONACO + "/loader.js";
		loader.onerror = fallbackEditor;
		loader.onload = () -> {
			js.Lib.global.MonacoEnvironment = {
				getWorkerUrl: () -> "data:text/javascript;charset=utf-8,"
					+ StringTools.urlEncode('self.MonacoEnvironment = {baseUrl: "${MONACO}/../"}; importScripts("${MONACO}/base/worker/workerMain.js");')
			};
			final require:Dynamic = js.Lib.global.require;
			require.config({paths: {vs: MONACO}});
			require(["vs/editor/editor.main"], setupMonaco, fallbackEditor);
		};
		document.head.append(loader);

		if (MODULE == null) {
			setBusy(true, "This browser cannot run the compiler: it needs WebAssembly exception handling (Chrome or Edge 95+, Firefox 100+, Safari 15.2+).");
		} else {
			setBusy(true, "The compiler loads when the playground is in view…");
			final playground = document.getElementById("playground");
			if (playground != null && js.Lib.global.IntersectionObserver != null) {
				var observer:js.html.IntersectionObserver = null;
				observer = new js.html.IntersectionObserver((entries, _) -> if (Lambda.exists(entries, (e) -> e.isIntersecting)) {
					observer.disconnect();
					startRunner();
				});
				observer.observe(playground);
			} else {
				startRunner();
			}
		}
		runButton.onclick = () -> start("run");
		hxbButton.onclick = () -> start("hxb");

		// build facts (sizes, date, commit) from build-info.json, written by `make site` (Makefile)
		Info.fill();
	}

	// ---- the program: Main.hx / Test.hx, main class detected from the source

	static function program(code:String):Program {
		// the class declaring `static function main`: the nearest class before it
		var main = ~/^\s*function\s+main\s*\(/m.match(code) ? "Test" : "Main"; // module-level main
		final mainFunction = ~/\b(?:static\s+(?:public\s+|private\s+)?|(?:public|private)\s+static\s+)function\s+main\s*\(/;
		if (mainFunction.match(code)) {
			var before = mainFunction.matchedLeft();
			final cls = ~/\bclass\s+([A-Z]\w*)/;
			while (cls.match(before)) {
				main = cls.matched(1);
				before = cls.matchedRight();
			}
		}
		return {main: main, file: main + ".hx", code: code};
	}

	// ---- editor: Monaco when it loads, a textarea otherwise

	static var monaco:Dynamic;
	static var editor:Dynamic;
	static var textarea:TextAreaElement;
	static var early = ""; // code set before an editor exists
	static var saved:Null<String>;
	static var examples:Array<Example> = [];

	static function getCode():String {
		return editor != null ? editor.getValue() : textarea != null ? textarea.value : early;
	}

	static function setCode(code:String) {
		if (editor != null) editor.setValue(code) else if (textarea != null) textarea.value = code else early = code;
	}

	static function save() {
		try window.localStorage.setItem("hih-code", getCode()) catch (_:Dynamic) {}
	}

	static function loadExample(i:Int) {
		window.fetch(Version.url("playground/" + examples[i].file)).then((r) -> r.text()).then((code) -> {
			setCode(code);
			save();
		});
	}

	static function fallbackEditor() {
		textarea = document.createTextAreaElement();
		textarea.spellcheck = false;
		textarea.wrap = "off";
		textarea.setAttribute("aria-label", "Haxe source");
		textarea.value = saved != null ? saved : early;
		textarea.addEventListener("input", save);
		textarea.addEventListener("keydown", (e:js.html.KeyboardEvent) -> {
			if (e.key == "Tab") {
				e.preventDefault();
				textarea.setRangeText("\t", textarea.selectionStart, textarea.selectionEnd, END);
				save();
			} else if (e.key == "Enter" && (e.ctrlKey || e.metaKey)) {
				e.preventDefault();
				start("run");
			}
		});
		document.getElementById("editor").replaceWith(textarea);
	}

	static function setupMonaco() {
		monaco = js.Lib.global.monaco;
		defineHaxe();
		final dark = window.matchMedia("(prefers-color-scheme: dark)");
		editor = monaco.editor.create(document.getElementById("editor"), {
			value: saved != null ? saved : early,
			language: "haxe",
			theme: dark.matches ? "vs-dark" : "vs",
			automaticLayout: true,
			minimap: {enabled: false},
			fontSize: 14,
			tabSize: 4,
			insertSpaces: false,
			scrollBeyondLastLine: false,
			fixedOverflowWidgets: true,
		});
		dark.addEventListener("change", () -> monaco.editor.setTheme(dark.matches ? "vs-dark" : "vs"));
		editor.onDidChangeModelContent(() -> {
			save();
			scheduleCheck();
		});
		editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, () -> start("run"));
		registerProviders();
		scheduleCheck();
	}

	// ---- running programs

	static var compiledModule:Promise<js.lib.webassembly.Module>;
	static var runner:js.html.Worker;
	static var runnerReady = false;
	static var busy = false;
	static var zipUrl:Null<String>;

	static function startWorker(onReply:Reply->Void):js.html.Worker {
		if (compiledModule == null) compiledModule = js.lib.WebAssembly.compileStreaming(cast window.fetch(Version.url(MODULE)));
		final w = new js.html.Worker(Version.url("worker.js"));
		w.onmessage = (e) -> onReply(e.data);
		compiledModule.then((m) -> w.postMessage(({type: "module", module: m} : Request)),
			(e) -> setBusy(true, "The compiler could not be loaded: " + error(e)));
		return w;
	}

	static function startRunner() {
		if (runner != null) return;
		setBusy(true, "Loading compiler…");
		runner = startWorker(onRunnerReply);
		runner.postMessage(({type: "warmup"} : Request));
	}

	static function setBusy(b:Bool, text = "") {
		busy = b;
		runButton.disabled = hxbButton.disabled = b;
		state.textContent = text;
	}

	static function print(text:String, cls = "") {
		final span = document.createSpanElement();
		span.className = cls;
		span.textContent = text + "\n";
		out.append(span);
	}

	static function start(mode:String) {
		if (busy) return;
		out.textContent = "";
		members.hidden = true;
		members.textContent = "";
		timing.textContent = "";
		setBusy(true, mode == "run" ? "Compiling and running…" : "Compiling to HXB…");
		final p = program(getCode());
		runner.postMessage(({type: "compile", mode: mode, main: p.main, file: p.file, code: p.code} : Request));
	}

	static function onRunnerReply(m:Reply) {
		switch m.type {
			case "ready":
				runnerReady = true;
				setBusy(false, "Ready. Ctrl+Enter runs.");
				scheduleCheck();
			case "out":
				print(m.text);
			case "err":
				print(m.text, "err");
			case "done":
				timing.textContent = 'exit ${m.status}, ${Ui.fixed(m.ms, 0)} ms';
				if (m.zip != null) showZip(m.zip);
				setBusy(false);
			case "failed":
				print(m.message, "err");
				// a crashed instance (stack or memory exhausted): start over
				runner.terminate();
				runner = null;
				startRunner();
				setBusy(true, "Restarting compiler…");
		}
	}

	static function localeNumber(n:Int):String {
		return (cast n).toLocaleString();
	}

	// the members of the HXB archive, from the ZIP central directory
	static function showZip(buf:js.lib.ArrayBuffer) {
		final bytes = new js.lib.Uint8Array(buf), view = new js.lib.DataView(buf);
		var eocd = bytes.length - 22;
		while (eocd >= 0 && view.getUint32(eocd, true) != 0x06054b50) eocd--;
		if (eocd < 0) return;
		final count = view.getUint16(eocd + 10, true);
		var p = view.getUint32(eocd + 16, true);
		final rows = [];
		var total = 0;
		final decoder = new js.html.TextDecoder();
		for (_ in 0...count) {
			final size = view.getUint32(p + 24, true), nameLength = view.getUint16(p + 28, true);
			final extraLength = view.getUint16(p + 30, true), commentLength = view.getUint16(p + 32, true);
			rows.push({name: decoder.decode(bytes.subarray(p + 46, p + 46 + nameLength)), size: size});
			total += size;
			p += 46 + nameLength + extraLength + commentLength;
		}
		if (zipUrl != null) js.html.URL.revokeObjectURL(zipUrl);
		zipUrl = js.html.URL.createObjectURL(new js.html.Blob([buf], {type: "application/zip"}));
		print('${count} HXB modules, ${localeNumber(total)} bytes uncompressed.');
		final a = document.createAnchorElement();
		a.href = zipUrl;
		a.download = "out.hxb.zip";
		a.textContent = "Download the archive";
		final table = document.createTableElement();
		table.innerHTML = "<thead><tr><th>module</th><th>bytes</th></tr></thead>";
		final body = document.createElement("tbody");
		rows.sort((x, y) -> (cast x.name).localeCompare(y.name));
		for (row in rows) {
			final tr = document.createTableRowElement();
			tr.append(Ui.el("td", "", row.name), Ui.el("td", "", localeNumber(row.size)));
			body.append(tr);
		}
		table.append(body);
		members.append(a, table);
		members.hidden = false;
	}

	// ---- display requests (JSON-RPC, as an IDE sends them), on their own worker

	static var lsp:js.html.Worker;
	static var lspSeq = 0;
	static final pending = new Map<Int, Null<Reply>->Void>();

	static function startLsp() {
		lsp = startWorker((m) -> {
			final resolve = pending[m.id];
			if (resolve == null) return;
			pending.remove(m.id);
			if (m.type == "failed") {
				lsp.terminate();
				startLsp();
				resolve(null);
			} else {
				resolve(m);
			}
		});
	}

	// one request at a time; a newer request of the same kind replaces a queued one
	// (a js.lib.Map: its keys keep their insertion order)
	static final queue = new js.lib.Map<String, {request:Request, resolve:Null<Reply>->Void}>();
	static var inflight = false;

	static function request(r:Request):Promise<Null<Reply>> {
		// the type-checker starts once the compiler has loaded, and not on small devices
		if (LOW_MEMORY || MODULE == null || !runnerReady) return Promise.resolve(null);
		if (lsp == null) startLsp();
		final kind = r.type == "display" ? r.request.method : r.type;
		return new Promise((resolve, _) -> {
			final previous = queue.get(kind);
			if (previous != null) previous.resolve(null);
			queue.set(kind, {request: r, resolve: resolve});
			pump();
		});
	}

	static function pump() {
		if (inflight || queue.size == 0) return;
		final kind = queue.keys().next().value;
		final q = queue.get(kind);
		queue.delete(kind);
		inflight = true;
		final id = ++lspSeq;
		pending[id] = (m) -> {
			inflight = false;
			q.resolve(m);
			pump();
		};
		q.request.id = id;
		lsp.postMessage(q.request);
	}

	static final encoder = new js.html.TextEncoder();

	/** a JSON-RPC display request at the editor position; the result, or null */
	static function display(method:String, model:Dynamic, position:Dynamic, ?extra:{wasAutoTriggered:Bool}):Promise<Dynamic> {
		final p = program(model.getValue());
		final code:String = model.getValue();
		final params:Dynamic = {file: "/work/" + p.file, offset: encoder.encode(code.substring(0, model.getOffsetAt(position))).length};
		if (extra != null) params.wasAutoTriggered = extra.wasAutoTriggered;
		final r:Request = {type: "display", main: p.main, file: p.file, code: p.code, request: {jsonrpc: "2.0", id: 1, method: method, params: params}};
		return request(r).then((m) -> {
			if (m == null) return null;
			for (line in m.output.split("\n")) if (StringTools.startsWith(line, '{"jsonrpc"')) {
				final reply:Dynamic = try haxe.Json.parse(line) catch (_:Dynamic) null;
				return reply != null && reply.result != null ? reply.result.result : null;
			}
			return null;
		});
	}

	/** a type of the display JSON as Haxe source */
	static function typeString(t:Null<JsonType>):String {
		if (t == null) return "?";
		final a:Dynamic = t.args;
		function params(ps:Null<Array<JsonType>>) return ps != null && ps.length > 0 ? "<" + ps.map(typeString).join(", ") + ">" : "";
		return switch t.kind {
			case "TMono": "Unknown";
			case "TInst" | "TEnum" | "TType" | "TAbstract": a.path.typeName + params(a.params);
			case "TFun": "(" + (a.args : Array<JsonArg>).map((x) -> (x.opt ? "?" : "") + (x.name != null && x.name != "" ? x.name + ":" : "") + typeString(x.t)).join(", ") + ") -> " + typeString(a.ret);
			case "TAnonymous": "{ " + (a.fields != null ? (a.fields : Array<Dynamic>) : []).map((f) -> f.name + ":" + typeString(f.type)).join(", ") + " }";
			case "TDynamic": a != null ? "Dynamic<" + typeString(a) + ">" : "Dynamic";
			case kind: kind;
		}
	}

	static function itemInfo(item:DisplayItem):ItemInfo {
		final a:Dynamic = item.args != null ? item.args : {};
		final f:Dynamic = a.field;
		final K:Dynamic = monaco.languages.CompletionItemKind;
		return switch item.kind {
			case "ClassField" | "EnumAbstractField" | "AnonField":
				{label: f.name, kind: f.kind != null && f.kind.kind == "FMethod" ? K.Method : K.Field, detail: typeString(f.type), doc: f.doc};
			case "EnumField": {label: f.name, kind: K.EnumMember, detail: typeString(f.type), doc: f.doc};
			case "Local": {label: a.name, kind: K.Variable, detail: typeString(a.type)};
			case "Type":
				final pack:Array<String> = a.path.pack != null ? a.path.pack : [];
				{label: a.path.typeName, kind: a.kind == "Interface" ? K.Interface : a.kind == "Enum" ? K.Enum : K.Class, detail: pack.concat([a.path.typeName]).join("."), doc: a.doc};
			case "Package": {label: a.path != null && a.path.pack != null ? a.path.pack[(a.path.pack.length : Int) - 1] : Std.string(a), kind: K.Module};
			case "Module": {label: a.path != null ? a.path.moduleName : Std.string(a), kind: K.Module};
			case "Keyword": {label: a.name, kind: K.Keyword};
			case "Literal": {label: a.name, kind: K.Value, detail: typeString(a.type)};
			case "Metadata": {label: a.name, kind: K.Property, doc: a.doc};
			case "TypeParameter": {label: a.name, kind: K.TypeParameter};
			case kind: {label: f != null && f.name != null ? f.name : a.name != null ? a.name : kind, kind: K.Text};
		}
	}

	static function registerProviders() {
		monaco.languages.registerCompletionItemProvider("haxe", {
			triggerCharacters: [".", ":", " "],
			provideCompletionItems: (model:Dynamic, position:Dynamic, context:Dynamic) -> {
				final ch:Null<String> = context.triggerCharacter;
				if (ch == " ") { // only after `new`, `extends`, `implements`, `import`, `using`, `case`
					final before = (model.getLineContent(position.lineNumber) : String).substring(0, (position.column : Int) - 1);
					if (!~/\b(new|extends|implements|import|using|case|cast)\s$/.match(before)) return Promise.resolve({suggestions: []});
				}
				return display("display/completion", model, position, {wasAutoTriggered: ch != null}).then((r) -> {
					if (r == null || r.items == null) return {suggestions: []};
					final word = model.getWordUntilPosition(position);
					final range = Syntax.construct(monaco.Range, position.lineNumber, word.startColumn, position.lineNumber, word.endColumn);
					final seen = new Map<String, Bool>();
					final suggestions = [];
					for (item in (r.items : Array<DisplayItem>)) {
						final i = itemInfo(item);
						final key = i.label + "/" + i.kind;
						if (i.label == null || i.label == "" || seen.exists(key)) continue;
						seen[key] = true;
						suggestions.push({
							label: i.label,
							kind: i.kind,
							detail: i.detail,
							documentation: i.doc != null && i.doc != "" ? {value: StringTools.trim(i.doc)} : null,
							insertText: i.label,
							range: range,
							sortText: StringTools.lpad(Std.string(suggestions.length), "0", 5)
						});
					}
					return {suggestions: suggestions};
				});
			},
		});
		monaco.languages.registerHoverProvider("haxe", {
			provideHover: (model:Dynamic, position:Dynamic) -> display("display/hover", model, position).then((r) -> {
				if (r == null || r.item == null) return null;
				final item:DisplayItem = r.item;
				final type = item.type != null ? typeString(item.type) : itemInfo(item).detail;
				final args:Dynamic = item.args;
				final doc:Null<String> = args == null ? null : args.doc != null ? args.doc : args.field != null ? args.field.doc : null;
				final contents = [{value: "```haxe\n" + (type != null ? type : item.kind) + "\n```"}];
				if (doc != null && doc != "") contents.push({value: StringTools.trim(doc)});
				return {contents: contents};
			}),
		});
		monaco.languages.registerSignatureHelpProvider("haxe", {
			signatureHelpTriggerCharacters: ["(", ","],
			provideSignatureHelp: (model:Dynamic, position:Dynamic) -> display("display/signatureHelp", model, position, {wasAutoTriggered: true}).then((r) -> {
				if (r == null || r.signatures == null || r.signatures.length == 0) return null;
				final signatures:Array<{args:Array<JsonArg>, ret:JsonType, ?documentation:String}> = r.signatures;
				return {
					value: {
						activeSignature: r.activeSignature != null ? r.activeSignature : 0,
						activeParameter: r.activeParameter != null ? r.activeParameter : 0,
						signatures: signatures.map((s) -> {
							final ps = s.args.map((x) -> (x.opt ? "?" : "") + x.name + ":" + typeString(x.t));
							return {label: "(" + ps.join(", ") + ") -> " + typeString(s.ret), documentation: s.documentation != null ? s.documentation : "", parameters: ps.map((label) -> {label: label})};
						}),
					},
					dispose: () -> {},
				};
			}),
		});
		monaco.languages.registerDefinitionProvider("haxe", {
			provideDefinition: (model:Dynamic, position:Dynamic) -> display("display/definition", model, position).then((r) -> {
				if (r == null || r.length == 0) return null;
				final locations:Array<{file:String, range:{start:{line:Int, character:Int}, end:{line:Int, character:Int}}}> = r;
				return [
					for (d in locations) if (StringTools.startsWith(d.file, "/work/")) {
						uri: model.uri,
						range: Syntax.construct(monaco.Range, d.range.start.line + 1, d.range.start.character + 1, d.range.end.line + 1, d.range.end.character + 1),
					}
				];
			}),
		});
	}

	// diagnostics: type-check after typing stops, errors as editor markers
	static var checkTimer = 0;

	static function scheduleCheck() {
		window.clearTimeout(checkTimer);
		// right after a `.` (completion territory) the line is usually incomplete:
		// wait longer before reporting it as an error
		var delay = 700;
		final pos:Dynamic = editor != null ? editor.getPosition() : null;
		if (pos != null) {
			final before = (editor.getModel().getLineContent(pos.lineNumber) : String).substring(0, (pos.column : Int) - 1);
			if (~/\.\w*$/.match(before)) delay = 2500;
		}
		checkTimer = window.setTimeout(check, delay);
	}

	static function check() {
		if (editor == null) return;
		final model:Dynamic = editor.getModel();
		final p = program(model.getValue());
		request({type: "check", main: p.main, file: p.file, code: p.code}).then((m) -> {
			if (m == null || model.getValue() != p.code) return;
			final markers = [];
			// classic message format: File.hx:LINE: characters A-B : message (or lines A-B)
			final re = ~/^(?:\/work\/)?([\w.]+\.hx):(\d+): (characters|lines) (\d+)-(\d+) : (.*)$/;
			for (l in m.output.split("\n")) {
				if (!re.match(l) || re.matched(1) != p.file) continue;
				final line = Std.parseInt(re.matched(2)), a = Std.parseInt(re.matched(4)), b = Std.parseInt(re.matched(5));
				final message = re.matched(6);
				final severity = ~/^Warning ?:/.match(message) ? monaco.MarkerSeverity.Warning : monaco.MarkerSeverity.Error;
				markers.push(re.matched(3) == "characters"
					? {startLineNumber: line, startColumn: a + 1, endLineNumber: line, endColumn: Std.int(Math.max(b + 1, a + 2)), message: message, severity: severity}
					: {startLineNumber: a, startColumn: 1, endLineNumber: b, endColumn: 1000, message: message, severity: monaco.MarkerSeverity.Error});
			}
			monaco.editor.setModelMarkers(model, "haxe", markers);
		});
	}

	// a Monarch rule: [regex, action] or [regex, action, next state]
	static function rule(re:String, action:Dynamic, ?next:String):Array<Dynamic> {
		final r:Array<Dynamic> = [new RegExp(re), action];
		if (next != null) r.push(next);
		return r;
	}

	// Monarch tokenizer for Haxe
	static function defineHaxe() {
		monaco.languages.register({id: "haxe", extensions: [".hx"]});
		monaco.languages.setLanguageConfiguration("haxe", {
			comments: {lineComment: "//", blockComment: ["/*", "*/"]},
			brackets: [["{", "}"], ["[", "]"], ["(", ")"]],
			autoClosingPairs: [{open: "{", close: "}"}, {open: "[", close: "]"}, {open: "(", close: ")"}, {open: '"', close: '"'}, {open: "'", close: "'"}],
		});
		monaco.languages.setMonarchTokensProvider("haxe", {
			keywords: [
				"abstract", "break", "case", "cast", "catch", "class", "continue", "default", "do", "dynamic", "else", "enum", "extends", "extern", "false", "final", "for",
				"function", "if", "implements", "import", "in", "inline", "interface", "macro", "new", "null", "operator", "overload", "override", "package", "private",
				"public", "return", "static", "switch", "this", "throw", "true", "try", "typedef", "untyped", "using", "var", "while", "from", "to", "is"
			],
			tokenizer: {
				root: ([
					rule("@:?[\\w.]+", "annotation"),
					rule("#(if|elseif|else|end|error)\\b.*$", "keyword.directive"),
					rule("[A-Z][\\w]*", "type.identifier"),
					rule("[a-z_$][\\w$]*", {cases: {"@keywords": "keyword", "@default": "identifier"}}),
					{include: "@whitespace"},
					rule("[{}()\\[\\]]", "@brackets"),
					rule("0x[0-9a-fA-F_]+", "number.hex"),
					rule("\\d[\\d_]*(\\.\\d+)?([eE][-+]?\\d+)?", "number"),
					rule("\"", "string", "@dstring"),
					rule("'", "string", "@sstring"),
					rule("~\\/(\\\\.|[^\\/\\\\])+\\/[gimsu]*", "regexp"),
					rule("[;,.]", "delimiter"),
					rule("[=><!~?:&|+\\-*\\/^%]+", "operator"),
				] : Array<Dynamic>),
				whitespace: [rule("[ \\t\\r\\n]+", ""), rule("\\/\\*", "comment", "@comment"), rule("\\/\\/.*$", "comment")],
				comment: [rule("[^\\/*]+", "comment"), rule("\\*\\/", "comment", "@pop"), rule("[\\/*]", "comment")],
				dstring: [rule("[^\\\\\"]+", "string"), rule("\\\\.", "string.escape"), rule("\"", "string", "@pop")],
				sstring: [
					rule("\\$\\{", "delimiter.bracket", "@interp"), rule("\\$\\w+", "variable"), rule("[^\\\\'$]+", "string"), rule("\\\\.", "string.escape"),
					rule("\\$", "string"), rule("'", "string", "@pop")
				],
				interp: ([rule("\\}", "delimiter.bracket", "@pop"), {include: "root"}] : Array<Dynamic>),
			},
		});
	}
}
