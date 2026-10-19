import Examples.Example;
import Layout.*;
import hxmc.view.*;
import hxmc.web.*;
import sys.FileSystem;

using StringTools;

// The site's pages, each a component rendered by Site.renderPage
class Pages implements Markup {
	static final NIGHTLY = "https://github.com/benmerckx/hxmc/releases/download/nightly/";
	static final TOOLS = "https://haxe-in-haxe.ben.mk/tools/";

	public static function all(examples:Array<Example>, api:Api) {
		var measured = Site.tool != null ? Measure.run() : [];
		Site.renderPage("index.html", () -> Static.document(<Home examples={examples}/>));
		Site.renderPage("compiler.html", () -> Static.document(<Compiler/>));
		Site.renderPage("hxmc.html", () -> Static.document(<Hxmc measured={measured} examples={examples}/>));
		Site.renderPage("packages.html", () -> Static.document(<Packages examples={examples}/>));
		Site.renderPage("examples.html", () -> Static.document(<ExamplesPage examples={examples}/>));
		Site.renderPage("playground.html", () -> Static.document(<Playground/>));
		Site.renderPage("story.html", () -> Static.document(<Story/>));
		Docs.all(api);
	}

	// --- numbers the pages quote, from the measured data ---

	static function bench():Dynamic
		return haxe.Json.parse(Site.read("site/data/bench.json"));

	static function result(b:Dynamic, workload:String, runner:String):Dynamic {
		for (r in (b.results : Array<Dynamic>))
			if (r.workload == workload && r.runner == runner && r.status == "ok") return r;
		return null;
	}

	static function fixed(x:Float, digits:Int):String {
		var m = Math.pow(10, digits);
		var s = Std.string(Math.round(x * m) / m);
		if (digits > 0 && s.indexOf(".") < 0) s += "." + [for (_ in 0...digits) "0"].join("");
		return s;
	}

	public static function kb(bytes:Int):String
		return bytes >= 1 << 20 ? fixed(bytes / (1 << 20), 1) + " MB" : Math.round(bytes / 1024) + " KB";

	static function example(examples:Array<Example>, id:String):Null<Example>
		return Lambda.find(examples, e -> e.id == id);

	// what running an example downloads, gzipped: its module, and the fonts
	// (once, for every ui and text example)
	static final fontSizes = new Map<String, Int>();

	static function download(e:Example):Null<String> {
		if (e.gz == null) return null;
		var fonts = Examples.fonts(e.pkg);
		var f = 0;
		if (fonts != null)
			for (p in fonts) {
				if (!fontSizes.exists(p)) {
					var n = FileSystem.exists(Site.out + "/" + p) ? Examples.gzipped(Site.out + "/" + p) : null;
					fontSizes.set(p, n == null ? 0 : n);
				}
				f += fontSizes.get(p);
			}
		return kb(e.gz) + (f > 0 ? " + " + kb(f) + " fonts" : "");
	}

	// a wasm example's island (the cube on the home page, every demo of the
	// gallery), its id demo-<example>: hxmcWasm's and hxmcWasmOptions' key.
	// In the gallery (gallery: true) a canvas demo runs when asked (a tap; a
	// small one on a large screen, once in view: FIT) and stops once out of view
	public static function Demo(props:{e:Example, ?load:Island.Load, ?gallery:Bool, ?children:Any}):View {
		var e = props.e;
		var src = e.wasm == null ? 'examples/${e.id}.wasm' : e.wasm;
		return switch e.demo {
			case Canvas(w, h) if (props.gallery == true):
				var size = download(e);
				// (small ones, under 150 KB gzipped, run once in view on a large screen)
				var small = e.gz != null && e.gz < 150 * 1024 && Examples.fonts(e.pkg) == null;
				<div class={small ? "stage auto" : "stage"} style={'--w:$w;--h:$h'}>
					<Island.Wasm src={src} id={"demo-" + e.id} imports={Examples.imports(e.pkg)} fonts={Examples.fonts(e.pkg)} width={w} height={h}
						load={Island.Load.Click} stop={Island.Stop.Offscreen}>
						<button type="button" class="run" aria-label={"Run " + e.title + (size == null ? "" : ", downloads " + size)}><span class="play" aria-hidden="true"></span><span>Run</span>{size == null ? null : <small>{size}</small>}</button>
					</Island.Wasm>
				</div>;
			case Canvas(w, h):
				<Island.Wasm src={src} id={"demo-" + e.id} imports={Examples.imports(e.pkg)} fonts={Examples.fonts(e.pkg)} width={w} height={h}
					load={props.load}>{props.children}</Island.Wasm>;
			case Sound:
				<Island.Wasm src={src} id={"demo-" + e.id} imports={Examples.imports(e.pkg)} canvas={false} load={Island.Load.Click}>
					<button type="button" class="primary play-sound">Play the tone</button>
					<p class="note">Browsers start audio only after a click: the module loads then.</p>
				</Island.Wasm>;
			case JsIsland:
				<Counter.Island start={0}/>;
			case Module:
				<LabIsland.Lab wasm={Site.asset(src)} imports={[Site.asset("web/imports.mjs")]}/>;
		}
	}

	// the gallery's stages scaled to their column (--k), and on a large screen
	// with a mouse (and no Save-Data) the small demos (.auto) run once in view
	// rather than on a tap; before the loader starts (a deferred script)
	static final FIT = "(()=>{var big=matchMedia('(min-width: 900px) and (pointer: fine)').matches&&!(navigator.connection&&navigator.connection.saveData);"
		+ "var fit=function(s){s.style.setProperty('--k',Math.min(1,s.clientWidth/+s.style.getPropertyValue('--w')))};"
		+ "var o=new ResizeObserver(function(es){es.forEach(function(e){fit(e.target)})});"
		+ "document.querySelectorAll('.stage').forEach(function(s){fit(s);o.observe(s);var i=s.querySelector('hxmc-island');if(big&&i&&s.classList.contains('auto'))i.dataset.load='visible'})})()";

	// --- Home ---

	static function Home(props:{examples:Array<Example>}):View {
		var b = bench();
		var self = result(b, "self", "hxmc"), ref = result(b, "self", "reference");
		var cube = example(props.examples, "gfx-cube");
		var cubeSize = cube != null && cube.gz != null ? kb(cube.gz) + " gzipped" : "";
		var install = "<span class=\"p\">$</span> npm i -D @hxmc/cli\n<span class=\"p\">$</span> npx haxe -main Main --custom-target hxmc=app";
		return <Page title="hxmc: the Haxe compiler in Haxe, compiled to machine code" section="Home"
			description="The Haxe compiler ported to Haxe, and hxmc, a Haxe target that writes machine code and WebAssembly itself, with packages for windows, graphics, text and UI in pure Haxe.">
			<section class="home-hero">
				<div class="wrap">
					<div>
						<h1>Haxe, all the way down.</h1>
						<p class="lead">The Haxe compiler ported to Haxe, and <b>hxmc</b>: a target that writes x86-64, ARM64 and WebAssembly itself. No C compiler, no linker, no SDK.</p>
						<div class="install"><pre class="code"><code innerHTML={install}></code></pre></div>
						<p class="actions"><a class="button primary" href={Site.link("docs/using.html")}>Get started</a><a class="button" href={Site.link("playground.html")}>Try the playground</a></p>
					</div>
					{cube == null ? null : <figure class="cube">
						<div class="frame"><Demo e={cube}/></div>
						<figcaption><span>Haxe, compiled to WebAssembly by hxmc. Drag it.</span><span>{cubeSize}</span></figcaption>
					</figure>}
				</div>
			</section>
			<div class="wrap">
				<dl class="stats" aria-label="In numbers">
					<div><dt>279<small>/279</small></dt><dd>HXB cases, byte for byte</dd></div>
					<div><dt>10</dt><dd>targets, identical output</dd></div>
					{self == null || ref == null ? null : <div><dt>{fixed(self.cpu_min, 1)}<small>s</small></dt><dd>to compile itself (OCaml: {fixed(ref.cpu_min, 1)} s)</dd></div>}
					{self == null || ref == null ? null : <div><dt>−{Math.round(100 - 100 * self.maxrss_mb / ref.maxrss_mb)}<small>%</small></dt><dd>memory, against OCaml</dd></div>}
				</dl>
				<section class="feature">
					<div>
						<h2>A port, not a rewrite.</h2>
						<p>Every OCaml module, translated at the same path, in the same order. Same arguments, same output.</p>
						<p class="more"><a href={Site.link("compiler.html")}>The compiler →</a></p>
					</div>
					<div>
						<dl class="facts">
							<div><dt>HXB</dt><dd><b>279 / 279</b> conformance cases, <b>66 / 66</b> macro cases</dd></div>
							<div><dt>Targets</dt><dd class="targets">JS · Lua · Python · PHP · Neko · HashLink · HL/C · JVM · C++ · SWF</dd></div>
							<div><dt>Tooling</dt><dd><code>--interp</code>, display, the server, the debugger</dd></div>
						</dl>
					</div>
				</section>
				<section class="feature">
					<div>
						<h2>Machine code, no toolchain.</h2>
						<p>SSA, optimized, encoded as x86-64, ARM64 or WebAssembly, and linked by its own linkers. Any target from any machine. It builds itself.</p>
						<p class="more"><a href={Site.link("hxmc.html")}>How hxmc works →</a></p>
					</div>
					<div>
						<Code lang="hxml" code={"-cp src\n-main Main\n--custom-target hxmc=bin/app\n-D hxmc.target=windows-arm64   # from Linux, macOS or Windows"}/>
						<ol class="pipeline" aria-label="The pipeline">
							<li>typed AST</li><li class="to" aria-hidden="true">→</li><li>SSA</li><li class="to" aria-hidden="true">→</li><li>x86-64 · ARM64 · wasm</li><li class="to" aria-hidden="true">→</li><li class="out">ELF · PE · Mach-O</li>
						</ol>
					</div>
				</section>
				<section class="feature">
					<div>
						<h2>Packages in pure Haxe.</h2>
						<p>Windows, the GPU, fonts and UI, calling the system directly. Native and in the browser.</p>
						<p class="more"><a href={Site.link("examples.html")}>See them run →</a></p>
					</div>
					<div class="pkgs">{[
						for (p in PACKAGES)
							<a href={Site.link("packages.html#" + p[0])}><strong>{p[1]}</strong><span>{p[3]}</span></a>
					]}</div>
				</section>
				<section class="closing">
					<h2>Try the compiler in your browser.</h2>
					<p class="actions"><a class="button primary" href={Site.link("playground.html")}>Open the playground</a><a class="button" href={Site.link("compiler.html#download")}>Download</a></p>
				</section>
			</div>
		</Page>;
	}

	// --- Compiler ---

	static function Compiler(props:{}):View {
		var lixUnix = "# Linux x86-64; also lix-linux-arm64, lix-macos-arm64, lix-macos-x86_64\ncurl -fLo ~/bin/lix " + TOOLS
			+ "lix-linux-x86_64 && chmod +x ~/bin/lix\nlix shims     # links ~/bin/haxe, ~/bin/haxelib, ~/bin/neko";
		var lixWin = "# PowerShell, into a directory on PATH; also lix-windows-arm64.exe\ncurl.exe -fLo C:\\tools\\lix.exe " + TOOLS
			+ "lix-windows-x86_64.exe\nlix shims     # hard links haxe.exe, haxelib.exe, neko.exe";
		var lixUse = "lix scope create                # a .haxerc here\nlix install haxe 4.3.7          # download it, use it here\nlix +lib tink_core              # haxe_libraries/tink_core.hxml\nhaxe -lib tink_core --run Main  # Haxe 4.3.7 with tink_core\nlix download                    # after a clone: what the scope needs";
		return <Page title="The compiler" section="Compiler" description="The Haxe compiler ported from OCaml to Haxe: conformance, downloads, benchmarks and the target generators.">
			<Hero title="Haxe's compiler, in Haxe">
				<p class="lead">Every OCaml module of the upstream compiler, translated to Haxe at the same path, in the same order. Built by hxmc for Linux, macOS, Windows and the browser.</p>
				<nav class="links" aria-label="On this page">
					<a href="#status">Status</a><a href="#download">Download</a><a href="#benchmarks">Benchmarks</a><a href="#targets">Target generators</a><a href="#tools">lix</a>
				</nav>
			</Hero>
			<div class="wrap">
				<section class="block" id="status">
					<header><h2>Status</h2><p>Pinned to upstream <code>fef2847</code>.</p></header>
					<div>
						<p>Same arguments, same output as the reference compiler:</p>
						<dl class="facts">
							<div><dt>HXB</dt><dd><b>279 / 279</b> conformance cases (and the 7 the reference rejects); <b>66 / 66</b> macro cases</dd></div>
							<div><dt>Targets</dt><dd>JS, Lua, Python, PHP, Neko, HashLink, HL/C, JVM, C++, SWF, <code>--xml</code>, <code>--json</code>: a differential fuzzer and upstream's test projects</dd></div>
							<div><dt>Tooling</dt><dd><code>--interp</code>, display requests, the compilation server, the Eval debugger</dd></div>
							<div><dt>Upstream CI</dt><dd>the target-independent job (unit, misc, threads, tink_core, hxcoro) passes on the native build</dd></div>
						</dl>
						<p class="note">More: <a href={Site.link("docs/testing.html")}>testing</a>, <a href={Site.link("story.html")}>the story</a>.</p>
					</div>
				</section>
				<section class="block" id="download">
					<header><h2>Download</h2><p>Nightly builds of <code>main</code>, with the standard library.</p></header>
					<div>
						<table class="downloads"><tbody>
							<tr><td>Linux</td><td><a href={NIGHTLY + "hxmc-haxe-linux-x86_64.tar.gz"}>x86-64</a><a href={NIGHTLY + "hxmc-haxe-linux-aarch64.tar.gz"}>ARM64</a></td></tr>
							<tr><td>macOS</td><td><a href={NIGHTLY + "hxmc-haxe-macos-x86_64.tar.gz"}>x86-64</a><a href={NIGHTLY + "hxmc-haxe-macos-aarch64.tar.gz"}>ARM64</a></td></tr>
							<tr><td>Windows</td><td><a href={NIGHTLY + "hxmc-haxe-windows-x86_64.zip"}>x86-64</a><a href={NIGHTLY + "hxmc-haxe-windows-aarch64.zip"}>ARM64</a></td></tr>
						</tbody></table>
						<Code lang="sh" code={"haxe -cp src --main Main --interp\nhaxe -cp src --main Main --js out.js"}/>
						<ul class="small">
							<li>The same arguments as <code>haxe</code>. Set <code>HAXE_STD_PATH</code> to the archive's <code>std</code>.</li>
							<li>Built by hxmc on Linux, with mbedtls and libuv: <code>sys.ssl</code> and <code>eval.luv</code> work in macros and <code>--interp</code>.</li>
							<li>macOS quarantines browser downloads: <code>xattr -d com.apple.quarantine haxe</code>.</li>
							<li>All files: <a href="https://github.com/benmerckx/hxmc/releases/tag/nightly">nightly release</a>. npm: <code>npm i -D @hxmc/cli</code>.</li>
						</ul>
					</div>
				</section>
				<ScriptIsland name="tables" script="tables.js">
					<section class="block" id="benchmarks">
						<header><h2>Benchmarks</h2></header>
						<div>
							<p>The port (hxmc: x86-64 and WebAssembly) compiling to HXB, against the OCaml reference. CPU time, best of 3, <code>-D disable-parallelism</code>; only runs with identical output count.</p>
							<div id="bench-results"><p class="note">Loading results…</p></div>
							<p class="note" id="bench-builds"></p>
							<p class="note" id="bench-machine"></p>
							<h3>Programs</h3>
							<p><a href="https://github.com/HaxeBenchmarks/benchmark-runner">HaxeBenchmarks</a> on hxmc (native, WebAssembly, WasmGC), C++, the JVM, Node, HL/C and HashLink, all compiled by the port. Nightly, on a GitHub Actions runner.</p>
							<div id="programs-results"><p class="note">Loading results…</p></div>
							<div id="programs-compile"></div>
							<p class="note" id="programs-machine"></p>
							<p class="note" id="programs-noise"></p>
							<div id="programs-over-time" hidden>
								<h3>Over time</h3>
								<div id="programs-history"><p class="note">Loading history…</p></div>
							</div>
							<p class="note">Reproduce: <code>make bench</code>. Every run's results: the <a href="https://github.com/benmerckx/hxmc/tree/bench-data">bench-data</a> branch.</p>
						</div>
					</section>
					<section class="block" id="targets">
						<header><h2>Target generators</h2></header>
						<div>
							<p>Compile time per target, port against reference, on two projects: sequential (one core, CPU time) and with each compiler's default parallelism (wall time), best of 3, nightly on a GitHub Actions runner. Every sequential output file identical (HL/C: after renaming a few type names that hash the reference binary). C++ and HL/C stop at the sources.</p>
							<div id="targets-results"><p class="note">Loading results…</p></div>
							<p class="note" id="targets-machine"></p>
						</div>
					</section>
				</ScriptIsland>
				<section class="block" id="tools">
					<header><h2>lix</h2><p>The Haxe package manager, native.</p></header>
					<div>
						<p><a href="https://github.com/lix-pm/lix.client">lix</a> and <a href="https://github.com/lix-pm/haxeshim">haxeshim</a>, built by hxmc: one file (<span data-info="lixSize">about 2 MB</span>) that acts as <code>lix</code>, <code>haxe</code>, <code>haxelib</code> or <code>neko</code> by its name.</p>
						<table class="downloads"><tbody>
							<tr><td>Linux</td><td><a href={Site.link("tools/lix-linux-x86_64")}>x86-64</a><a href={Site.link("tools/lix-linux-arm64")}>ARM64</a></td></tr>
							<tr><td>macOS</td><td><a href={Site.link("tools/lix-macos-x86_64")}>x86-64</a><a href={Site.link("tools/lix-macos-arm64")}>ARM64</a></td></tr>
							<tr><td>Windows</td><td><a href={Site.link("tools/lix-windows-x86_64.exe")}>x86-64</a><a href={Site.link("tools/lix-windows-arm64.exe")}>ARM64</a></td></tr>
						</tbody></table>
						<Code lang="sh" code={lixUnix}/>
						<Code lang="sh" code={lixWin}/>
						<p>Per project:</p>
						<Code lang="sh" code={lixUse}/>
						<p class="note">The shim adds about 2 ms a call (Node.js: 60 ms). Output and installed files match the npm package on 26 scenarios. More: <a href={Site.link("docs/using.html")}>using</a>.</p>
					</div>
				</section>
			</div>
		</Page>;
	}

	// --- hxmc ---

	static function Hxmc(props:{measured:Array<Measure.Measured>, examples:Array<Example>}):View {
		var pipeline = "typed AST --(ir.Lower)--> hxmc IR --(Prep)--> Mir (SSA) --(Inline, Sroa, Opt)-->\n    --(x64 | a64 Isel)--> LIR --(Regalloc, Emit)--> object (per module, cached)\n    --(wasm/WasmGen)--> wasm\n    --(Link: ELF | PE | Mach-O | wasm)--> executable";
		var interop = "import hxmc.unsafe.*;\n\n// a C function of a system library, called directly\n@:hxmc.lib(\"libc\") extern class C {\n\t@:hxmc.c(\"getpid\") static function getpid():Int;\n}\n\n// a C struct, as a value: on the stack, copied on assignment\n@:hxmc.struct class Point {\n\tpublic var x:Float32;\n\tpublic var y:Float32;\n}\n\nclass Main {\n\tstatic function main() {\n\t\tvar buf:Ptr<Float32> = Mem.alloc(4 * 1024);\n\t\tfor (i in 0...1024) buf[i] = i * 0.5;  // loads and stores, no bounds\n\t\ttrace(C.getpid(), buf[10]);\n\t}\n}";
		return <Page title="hxmc" section="hxmc" description="hxmc, a Haxe target that writes x86-64, ARM64 and WebAssembly itself: targets, sizes, build times, how it works, low-level Haxe and C interop.">
			<Hero title="hxmc">
				<p class="lead">A Haxe target with its own code generator and linkers. No C compiler, assembler, system linker or SDK runs at build time, on any target, cross-compiling included.</p>
				<nav class="links" aria-label="On this page"><a href="#targets">Targets</a><a href="#sizes">Sizes</a><a href="#how">How it works</a><a href="#runtime">Runtime</a><a href="#interop">Low-level Haxe</a></nav>
			</Hero>
			<div class="wrap">
				<section class="block" id="targets">
					<header><h2>Targets</h2><p>Any target, from any host.</p></header>
					<div>
						<Code lang="hxml" code={"-cp src\n-main Main\n--custom-target hxmc=bin/app\n-D hxmc.target=windows-arm64"}/>
						<div class="table"><table>
							<thead><tr><th>Target</th><th>Output</th><th>Notes</th></tr></thead>
							<tbody>
								<tr><td><code>linux-x86_64</code> <code>linux-arm64</code></td><td>static ELF (musl), or dynamic, glibc 2.17+</td><td><code>-D hxmc.libc=glibc</code> loads shared libraries (GPU drivers, GTK)</td></tr>
								<tr><td><code>macos-x86_64</code> <code>macos-arm64</code></td><td>Mach-O, ad-hoc signed</td><td>frameworks through the Objective-C runtime</td></tr>
								<tr><td><code>windows-x86_64</code> <code>windows-arm64</code></td><td>PE</td><td>imports written directly: no import libraries, no MSVC</td></tr>
								<tr><td><code>wasm32-wasi</code></td><td>WebAssembly</td><td><code>exnref</code> exceptions, or legacy (<code>-D hxmc.wasm-eh=legacy</code>); node, wasmtime, browsers</td></tr>
							</tbody>
						</table></div>
						<p class="note">Every native target has threads, a precise generational collector, TLS (mbedtls) and libuv. A rebuild compiles only the modules that changed.</p>
					</div>
				</section>
				<section class="block" id="sizes">
					<header><h2>Sizes and build times</h2></header>
					<div>
						{props.measured.length == 0 ? <p class="note">(Measured by the site build.)</p> : <MeasuredTable measured={props.measured}/>}
						<p class="note">Measured by this site's build: cold builds, empty cache. Sizes include the runtime and C library (static musl on Linux; glibc for graphics).</p>
					</div>
				</section>
				<section class="block" id="how">
					<header><h2>How it works</h2></header>
					<div>
						<p>The port types the program; hxmc lowers each module to SSA, optimizes it (inlining, scalar replacement, value numbering, store forwarding, LICM), then selects instructions, allocates registers and encodes them, or emits structured WebAssembly. One cached object per module.</p>
						<Code lang="text" code={pipeline}/>
						<ul>
							<li>Program-wide numbers (type ids, field ids, offsets) are linker symbols, so a module's cached object survives renumbering.</li>
							<li>Unwind tables, frame pointers, and DWARF line tables with <code>-debug</code>: gdb, lldb and perf see Haxe functions and lines.</li>
							<li>Self-hosting: a committed WebAssembly stage0 builds the first native tool, which rebuilds itself byte for byte.</li>
						</ul>
						<p class="note">More: <a href={Site.link("docs/hxmc.html")}>docs/hxmc.md</a>.</p>
					</div>
				</section>
				<section class="block" id="runtime">
					<header><h2>The runtime</h2><p>Haxe, too.</p></header>
					<div>
						<p>Strings, Dynamic, reflection, the OS layers, Math (musl's libm, ported), threads, exceptions and the collector: precise and generational, a nursery per thread, a mark-sweep old space. The only C linked: the C library, mbedtls, libuv.</p>
					</div>
				</section>
				<section class="block" id="interop">
					<header><h2>Low-level Haxe</h2><p><code>hxmc.unsafe</code></p></header>
					<div>
						<p>Pointers, C-layout structs, C externs, callbacks, thread-locals: how the packages call X11, Cocoa, Win32, Metal, Direct3D and the browser.</p>
						<Code code={interop}/>
						<p class="note">The design, built in part: <a href={Site.link("docs/plans/lowlevel.html")}>docs/plans/lowlevel.md</a>.</p>
					</div>
				</section>
			</div>
		</Page>;
	}

	static function MeasuredTable(props:{measured:Array<Measure.Measured>}):View {
		var programs = [for (p in Measure.PROGRAMS) p.name];
		function cell(t:String, p:String):View {
			var m = Lambda.find(props.measured, m -> m.target == t && m.program == p);
			return m == null ? <td class="num">–</td> : <td class="num"><b>{kb(m.size)}</b><span class="sub">{fixed(m.seconds, 1)} s</span></td>;
		}
		return <div class="table"><table class="measured">
			<thead><tr><th>Target</th>{[for (p in Measure.PROGRAMS) <th class="num" title={p.note}>{p.name}</th>]}</tr></thead>
			<tbody>{[
				for (t in Measure.TARGETS)
					<tr><td><code>{t}</code></td>{[for (p in programs) cell(t, p)]}</tr>
			]}</tbody>
		</table></div>;
	}

	// --- Packages ---

	// [folder, npm name, what it is, in a line]
	public static final PACKAGES = [
		["os", "@hxmc/os", "Windows, input, the app loop and audio: X11, Cocoa, Win32 and the browser's canvas; ALSA, Core Audio, WASAPI and WebAudio.", "Windows, input, audio"],
		["gfx", "@hxmc/gfx", "A portable GPU API shaped like WebGPU, on OpenGL and GLES, Metal, Direct3D 11, WebGPU and WebGL2, with shaders written in Haxe.", "A GPU API, shaders in Haxe"],
		["text", "@hxmc/text", "TrueType in pure Haxe: parsing, an anti-aliased rasterizer, shaping with kerning and fallback fonts, bidi and Arabic, line layout, a glyph atlas.", "Fonts, shaping, layout"],
		["view", "@hxmc/view", "Signals and JSX-like markup on every target: fine-grained reactivity, markup compiled to direct calls on a renderer chosen at compile time.", "Signals and markup"],
		["ui", "@hxmc/ui", "A UI toolkit: flexbox layout checked against Chromium's, events and focus, widgets, drawn on the GPU or as the platform's own controls.", "Layout, widgets, focus"],
		["web", "@hxmc/web", "@hxmc/view on the web: a DOM renderer, static pages, hydration, islands in JavaScript or WebAssembly. This site is built with it.", "Static pages and islands"],
	];

	// the first ```haxe block of a README (after a heading, when given)
	static function sample(readme:String, ?after:String):Null<String> {
		var text = Site.read(readme);
		if (after != null) {
			var at = text.indexOf(after);
			if (at < 0) return null;
			text = text.substr(at);
		}
		var start = text.indexOf("```haxe\n");
		if (start < 0) return null;
		var end = text.indexOf("\n```", start + 8);
		var code = text.substring(start + 8, end);
		var lines = code.split("\n");
		return lines.length > 26 ? lines.slice(0, 25).join("\n") + "\n// ..." : code;
	}

	static function Packages(props:{examples:Array<Example>}):View {
		return <Page title="Packages" section="Packages" description="The hxmc packages, in pure Haxe: os, gfx, text, view, ui and web.">
			<Hero title="Packages">
				<p class="lead">Libraries in pure Haxe that call the system directly, with no C of their own. On npm, found by <code>-lib</code>; native on every desktop target, and WebAssembly in the browser.</p>
				<nav class="links" aria-label="Packages">{[for (p in PACKAGES) <a href={"#" + p[0]}>{p[1]}</a>]}</nav>
			</Hero>
			<div class="wrap">{[
				for (p in PACKAGES) {
					var readme = 'packages/${p[0]}/README.md';
					var code = sample(readme);
					var audio = p[0] == "os" ? sample(readme, "## Audio") : null;
					var exs = props.examples.filter(e -> e.pkg == p[0]);
					<section class="package" id={p[0]}>
						<div class="package-text">
							<h2>{p[1]}</h2>
							<p>{p[2]}</p>
							<Code lang="sh" code={'npm i -D ${p[1]}    # -lib hxmc.${p[0]}'}/>
							<p class="links">
								<a href={Site.link('docs/packages/${p[0]}.html')}>README</a>
								<a href={Site.link('docs/api/${p[0]}.html')}>API</a>
								{p[0] == "ui" ? <a href={Site.link("docs/packages/ui-guide.html")}>Guide</a> : null}
								<a href={Site.github('packages/${p[0]}')}>Source</a>
							</p>
							{exs.length == 0 ? null : <p class="note">Examples: {[for (k in 0...exs.length) <span>{k > 0 ? ", " : ""}<a href={Site.link("examples.html#" + exs[k].id)}>{exs[k].title}</a></span>]}</p>}
						</div>
						<div class="package-code">
							{code == null ? null : <Code code={code}/>}
							{audio == null ? null : <Code code={audio}/>}
						</div>
					</section>;
				}
			]}</div>
		</Page>;
	}

	// --- Examples ---

	static function ExamplesPage(props:{examples:Array<Example>}):View {
		var order = ["gfx", "ui", "text", "os", "view", "web"];
		var sorted = props.examples.copy();
		sorted.sort((a, b) -> order.indexOf(a.pkg) - order.indexOf(b.pkg));
		var groups = [for (p in order) if (Lambda.exists(sorted, e -> e.pkg == p)) p];
		return <Page title="Examples" section="Examples" description="Live examples of the hxmc packages, each running in the page as WebAssembly or JavaScript next to its source.">
			<Hero title="Examples">
				<p class="lead">Programs from the packages' <code>examples/</code> folders, built for the browser by this site's build and running here. The same source builds natively for Linux, macOS and Windows.</p>
				<nav class="toc-line" aria-label="Examples">{[
					for (g in groups)
						<span><b>{g}</b>{[for (e in sorted) if (e.pkg == g) <a href={"#" + e.id}>{e.title}</a>]}</span>
				]}</nav>
			</Hero>
			<div class="wrap gallery">{[for (e in sorted) <ExampleCard e={e}/>]}</div>
			<script>{FIT}</script>
		</Page>;
	}

	static function ExampleCard(props:{e:Example}):View {
		var e = props.e;
		var labels = [for (s in e.sources) haxe.io.Path.withoutDirectory(s)];
		var wide = switch e.demo {
			case Canvas(w, _): w > 600;
			case _: false;
		}
		return <article class={"example" + (wide ? " wide" : "")} id={e.id}>
			<header class="example-head">
				<h2><a href={"#" + e.id}>{e.title}</a></h2>
				<span class="pkg">{"@hxmc/" + e.pkg}</span>
				<div class="example-tools"></div>
				<p>{e.summary}</p>
			</header>
			<div class="example-body">
				<div class="example-demo"><Demo e={e} gallery={true}/></div>
				<div class="example-source">
					{labels.length > 1 ? <SiteIslands.Tabs id={"src-" + e.id} labels={labels}/> : <div class="tabs single"><span>{labels[0]}</span></div>}
					{[
						for (k in 0...e.sources.length)
							<div class="file" id={"src-" + e.id + "-" + k} hidden={k > 0}>
								<Raw html={Highlight.block(Site.read(e.sources[k]), "haxe")}/>
							</div>
					]}
					<p class="meta"><a href={Site.github(e.file)}>{e.file}</a>{download(e) == null ? null : <span>{download(e) + ", gzipped"}</span>}</p>
				</div>
			</div>
		</article>;
	}

	// --- Playground ---

	static function Playground(props:{}):View {
		return <Page title="Playground" section="Playground" description="The Haxe compiler, ported to Haxe and compiled to WebAssembly by hxmc, running in your browser: --interp and HXB, with completion and diagnostics."
			bodyClass="playground-page">
			<ScriptIsland name="playground" script="playground.js">
				<section id="playground">
					<Hero title="Playground">
						<p class="lead">The compiler, as WebAssembly, in this page. <em>Run</em> type-checks and runs with <code>--interp</code>; <em>Compile to HXB</em> writes an archive.</p>
					</Hero>
					<div class="wrap">
						<div class="toolbar">
							<label>Example <select id="example"></select></label>
							<button id="run" class="primary" disabled>Run</button>
							<button id="hxb" disabled>Compile to HXB</button>
							<span id="state" class="state">Loading compiler…</span>
						</div>
						<div class="play">
							<div id="editor" aria-label="Haxe source"></div>
							<div class="output">
								<div class="outhead">Output <span id="timing"></span></div>
								<pre id="out"></pre>
								<div id="members" hidden></div>
							</div>
						</div>
						<p class="note">Completion, hover and diagnostics come from the same compiler. Download: <span data-info="wasmGz">about 2 MB</span> of WebAssembly and <span data-info="dataGz">about 0.2 MB</span> of std, gzipped. Needs WebAssembly exceptions (Chrome and Edge 95+, Firefox 100+, Safari 15.2+). Some examples are from <a href="https://try.haxe.org/">try.haxe.org</a> (<a href={Site.link("playground/LICENSE-try-haxe.txt")}>MIT</a>).</p>
					</div>
				</section>
			</ScriptIsland>
		</Page>;
	}

	// --- Story ---

	static function Story(props:{}):View {
		return <Page title="Story" section="Story" description="How the Haxe compiler was ported from OCaml to Haxe and given its own machine-code back end.">
			<Hero title="How it was made">
				<p class="lead">A line-by-line port checked against the real compiler, then a back end of its own.</p>
			</Hero>
			<div class="wrap"><Raw cls="story" html={Site.read("site/content/story.html")} tag="section"/></div>
		</Page>;
	}
}
