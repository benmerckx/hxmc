// A compilation server's builds of small programs are fresh builds (make
// dev-check): each case is a program a
// server of its own builds, then builds again after each edit, its typed
// modules kept in memory (as `hxmc dev` asks) and then read back from HXB
// (the default); each build's output must be the bytes a one-shot build of
// the same sources makes (and on macOS, an Objective-C program built for the
// machine runs as the fresh one does). What it checks is an edit that makes
// the program use code it did not use before while hxmc's LowerCache replays
// the bodies of the modules not typed again, what a macro's callback
// defines while modules are reused, and a macro's persistent state while
// the builds alternate between two signatures (a step's '-D': a define of
// its build and the fresh one's, not a file), also after an error in a macro
// (a step's '!': a build that fails, as the fresh one does).
//   node hxmc/test/dev/server-verify.mjs <compiler> [native|web|frontend]
// (frontend: the compiler is hxmc/test/frontend/Hook.hx's, its own cases)
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../..');
const [compilerArg, mode = 'native'] = process.argv.slice(2);
const compiler = path.resolve(compilerArg ?? 'bin/hxmc/hxmc');
const web = mode === 'web';
const frontend = mode === 'frontend';

// name: [the first sources, then each edit (the files it writes; '#compiled':
// the modules whose objects that build compiles, all others' reused)]
const cases = {
	// a module's functions are compiled in the order of their symbols
	// (Driver.build), not in the order the lowering reaches them: Main calling
	// Lib's functions in another order leaves Lib's object as it was
	"a module's functions reached in another order": [
		{
			'Lib.hx': 'class Lib {\n\tpublic static function a(x:Int):Int\n\t\treturn x + 1;\n\n\tpublic static function b(x:Int):Int\n\t\treturn x * 2;\n\n\tpublic static function c(s:String):String\n\t\treturn s + "!";\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.a(1) + Lib.b(2));\n\t\ttrace(Lib.c("x"));\n\t}\n}\n',
		},
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.c("y"));\n\t\ttrace(Lib.b(2) + Lib.a(1));\n\t}\n}\n', '#compiled': ['Main'] },
	],
	// what Facts found in a body (FuncInfo.gcScan: its callees, its GC
	// points) is kept with the body's LowerCache entry and handed to its
	// replays, but only to a build that reads stacks as the one that
	// scanned it did (Reach drops the calls recording a stack otherwise):
	// haxe.Exception's body, replayed, as the program starts and stops
	// reading stacks
	"a replayed body's facts as the program starts reading stacks": [
		{
			'Lib.hx': 'class Lib {\n\tpublic static function check(x:Int):Int {\n\t\tif (x < 0) throw new haxe.Exception("negative " + x);\n\t\treturn [for (i in 0...x) i].length;\n\t}\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttry trace(Lib.check(-1)) catch (e:haxe.Exception) trace(e.message);\n\t\ttrace(Lib.check(3));\n\t}\n}\n',
		},
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttry trace(Lib.check(-1)) catch (e:haxe.Exception) trace(e.message + " " + (e.stack.length > 0));\n\t\ttrace(Lib.check(3));\n\t}\n}\n' },
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttry trace(Lib.check(-2)) catch (e:haxe.Exception) trace(e.message);\n\t\ttrace(Lib.check(4));\n\t}\n}\n' },
	],
	// a replayed body logs a type once (LowerCache: the types whose objects a
	// type before them in its log bound are not logged): Lib's body names
	// Point, arrays of it, nullable ints and a function type many times
	// over; Main's edit makes the program use a class Lib's types name
	// that it did not before
	"a replayed body's many types": [
		{
			'Lib.hx': 'class Point {\n\tpublic var x:Int;\n\tpublic var y:Null<Int>;\n\n\tpublic function new(x, y) {\n\t\tthis.x = x;\n\t\tthis.y = y;\n\t}\n}\n\nclass Box {\n\tpublic var p:Point;\n\n\tpublic function new(p) this.p = p;\n}\n\nclass Lib {\n\tpublic static function sum(ps:Array<Point>, f:Point->Int):Int {\n\t\tvar t = 0;\n\t\tfor (p in ps) {\n\t\t\tvar q:Point = p;\n\t\t\tvar n:Null<Int> = q.y;\n\t\t\tt += f(q) + (n == null ? 0 : n);\n\t\t}\n\t\tvar more:Array<Point> = ps.copy();\n\t\tvar g:Point->Int = p -> p.x;\n\t\treturn t + more.length + g(ps[0]);\n\t}\n\n\tpublic static function boxed(b:Box):Int\n\t\treturn b.p.x;\n}\n',
			'Main.hx': 'import Lib;\n\nclass Main {\n\tstatic function main() {\n\t\ttrace(Lib.sum([new Point(1, 2), new Point(3, null)], p -> p.x * 10));\n\t}\n}\n',
		},
		{ 'Main.hx': 'import Lib;\n\nclass Main {\n\tstatic function main() {\n\t\ttrace(Lib.sum([new Point(1, 2)], p -> p.x) + Lib.boxed(new Box(new Point(5, 6))));\n\t}\n}\n' },
		{ 'Main.hx': 'import Lib;\n\nclass Main {\n\tstatic function main() {\n\t\ttrace(Lib.sum([new Point(7, null)], p -> p.x - 1));\n\t}\n}\n' },
	],
	// a Dynamic called as a function goes through an adapter per signature
	// (Lower.dynAdapter): Lib's body, replayed, asks for the one of Int->Int,
	// and Main's, lowered anew, for the same one, which the program has once
	'a Dynamic as a function, in a replayed body and a new one': [
		{
			'Lib.hx': 'class Lib {\n\tpublic static function call(d:Dynamic):Int {\n\t\tvar f:Int->Int = d;\n\t\treturn f(1);\n\t}\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.call((x:Int) -> x + 1));\n\t}\n}\n',
		},
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\tvar d:Dynamic = (x:Int) -> x * 2;\n\t\tvar g:Int->Int = d;\n\t\ttrace(Lib.call((x:Int) -> x + 1) + g(3));\n\t}\n}\n' },
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.call((x:Int) -> x + 1));\n\t}\n}\n' },
	],
	// (and a closure converted to another signature: Lower.adapter)
	'a function as one of another signature, in a replayed body and a new one': [
		{
			'Lib.hx': 'class Lib {\n\tpublic static function call(f:Int->Int):Null<Int> {\n\t\tvar g:Int->Null<Int> = f;\n\t\treturn g(1);\n\t}\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.call(x -> x + 1));\n\t}\n}\n',
		},
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\tvar f:Int->Int = x -> x * 2;\n\t\tvar g:Int->Null<Int> = f;\n\t\ttrace(Lib.call(x -> x + 1) + g(3));\n\t}\n}\n' },
	],
	// a dispatched call leaving out an argument gets the default of the
	// override the receiver runs (FnLower.receiverDefault): Lib's body,
	// replayed (Lib does not depend on Sub, so it is not typed again), has
	// Sub's default value, which the edit of Sub changes (LowerQueries.fieldDefaults)
	"an override's default value, in a replayed dispatched call": [
		{
			'Lib.hx': 'class Base {\n\tpublic function new() {}\n\tpublic function f(x:Int = 1):Int\n\t\treturn x;\n}\n\nclass Lib {\n\tpublic static function call(b:Base):Int\n\t\treturn b.f();\n}\n',
			'Sub.hx': 'class Sub extends Lib.Base {\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n\toverride public function f(x:Int = 2):Int\n\t\treturn x * 10;\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.call(new Sub()) + Lib.call(new Lib.Base()));\n\t}\n}\n',
		},
		{ 'Sub.hx': 'class Sub extends Lib.Base {\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n\toverride public function f(x:Int = 3):Int\n\t\treturn x * 10;\n}\n' },
	],
	// a C function's declaration (CInterop.declare: its signature, whether
	// its calls stay outside the safe region) is the program's: an edit of
	// it is the new one, not checked against the previous build's, and a
	// replayed body calling it declares it again (LowerQueries.cExtern)
	'a C function declared again, @:hxmc.fast, called by a replayed body': [
		{
			'CLib.hx': 'extern class CLib {\n\t@:hxmc.c("getpid") static function getpid():Int;\n}\n',
			'Lib.hx': 'class Lib {\n\tpublic static function pid():Int\n\t\treturn CLib.getpid();\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.pid() > 0);\n\t}\n}\n',
		},
		{ 'CLib.hx': 'extern class CLib {\n\t@:hxmc.c("getpid") @:hxmc.fast static function getpid():Int;\n}\n' },
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.pid() != 0);\n\t}\n}\n' },
		{ 'CLib.hx': 'extern class CLib {\n\t@:hxmc.c("getpid") static function getpid():Int;\n}\n' },
	],
	// a class an onAfterTyping callback defines from the program's types
	// (helder's Late_<hash>, named by its code), the callback registered by
	// Tpl's build macro. Tpl edited: the class of the compilation before is
	// not in the program (upstream makes it a dependency of the macro API's
	// current module, Other, whose macro made the macros' context first, and
	// its server restores it with Other beside the new one: [one,two]; a
	// divergence from upstream, MacroContext.defineType, docs/porting.md).
	// Other edited, Tpl reused: Tpl is typed again, so that its macro
	// registers the callback again (hxmc.ServerCallbacks; else no class: null)
	"a class a callback defines, in the next compilations": [
		{
			'Reg.hx': 'class Reg {\n\tpublic static var log:Array<String>;\n\n\tpublic static function add(s:String) {\n\t\tif (log == null) log = [];\n\t\tlog.push(s);\n\t}\n}\n',
			'Gen.hx': `import haxe.macro.Context;

class Gen {
	static var hooked = false;

	public static function build():Array<haxe.macro.Expr.Field> {
		if (!hooked) {
			hooked = true;
			Context.onAfterTyping(late);
		}
		return null;
	}

	public static function other():Array<haxe.macro.Expr.Field>
		return null;

	// (defined already: the callbacks run again)
	static function has(types:Array<haxe.macro.Type.ModuleType>, name:String):Bool {
		for (t in types)
			switch t {
				case TClassDecl(c) if (c.get().name == name): return true;
				case _:
			}
		return false;
	}

	static function late(types:Array<haxe.macro.Type.ModuleType>) {
		for (t in types)
			switch t {
				case TClassDecl(c):
					for (m in c.get().meta.extract(":tpl"))
						switch m.params[0].expr {
							case EConst(CString(s, _)):
								var name = "Late_" + s;
								if (!has(types, name))
									Context.defineType({pack: [], name: name, pos: Context.currentPos(), meta: [{name: ":keep", pos: Context.currentPos()}], kind: TDClass(),
										fields: (macro class {
											static function __init__() Reg.add($v{s});
										}).fields});
							case _:
						}
				case _:
			}
	}
}
`,
			'Tpl.hx': '@:build(Gen.build()) @:tpl("one")\nclass Tpl {\n\tpublic static var x = 1;\n}\n',
			'Other.hx': '@:build(Gen.other())\nclass Other {\n\tpublic static var y = 2;\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Other.y + Tpl.x + " " + Reg.log);\n\t}\n}\n',
		},
		{ 'Tpl.hx': '@:build(Gen.build()) @:tpl("two")\nclass Tpl {\n\tpublic static var x = 1;\n}\n' },
		{ 'Other.hx': '@:build(Gen.other())\nclass Other {\n\tpublic static var y = 3;\n}\n' },
		{},
	],
	// a build macro keeps its class's fields in a @:persistent static, from
	// which a later macro makes a class (helder's HostMacro: its template of
	// ViewRuntime, for ViewRuntime_<renderer>). The builds alternate between
	// two signatures, as a check's --no-output and a build do: two contexts
	// of the server, one macro interpreter. Upstream starts a macro class's
	// statics again from their initializers whenever it is handed over from
	// the other context's module: when -D one comes back, Rt is restored (its
	// build macro does not run), Gen is not (the other context's definition
	// tainted it), and the static is null: "Rt's fields are not known", in
	// every build of that signature after it (a failed build is not cached).
	// Each context gets back the values its own modules left
	// (EvalPrototype.addTypes, persistentStash; a divergence from upstream,
	// docs/porting.md)
	"a build macro's persistent state, in builds of two signatures": [
		{
			'Tpl.hx': `#if macro
import haxe.macro.Context;
#end
import haxe.macro.Expr;

class Tpl {
	#if macro
	@:persistent static var template:Null<Array<Field>> = null;

	public static function build():Array<Field> {
		template = Context.getBuildFields();
		return [];
	}
	#end

	public static macro function use():Expr {
		try {
			Context.getType("Gen");
		} catch (_:Dynamic) {
			if (template == null)
				switch Context.getType("Rt") {
					case TInst(c, _): c.get().statics.get();
					case _:
				}
			if (template == null) Context.fatalError("Rt's fields are not known", Context.currentPos());
			Context.defineType({pack: [], name: "Gen", pos: Context.currentPos(), kind: TDClass(), fields: template.copy()});
		}
		return macro Gen.hello();
	}
}
`,
			'Rt.hx': '@:build(Tpl.build())\nclass Rt {\n\tpublic static function hello():String\n\t\treturn "hello";\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Tpl.use());\n\t}\n}\n',
			'-D': 'one',
		},
		{ '-D': 'two' },
		{ '-D': 'one' },
		{ '-D': 'one' },
		{ '-D': 'two' },
	],
};
{
	const persistent = cases["a build macro's persistent state, in builds of two signatures"];
	// (the static without an initializer: given back all the same)
	const noInit = structuredClone(persistent);
	noInit[0]['Tpl.hx'] = noInit[0]['Tpl.hx'].replace('@:persistent static var template:Null<Array<Field>> = null;', '@:persistent static var template:Null<Array<Field>>;');
	cases["a build macro's persistent state without an initializer, in builds of two signatures"] = noInit;
	// an error in a macro (Bad.hx's, Other's build macro) discards the macro
	// interpreter, persistent statics and all (upstream's
	// MacroContext.create_macro_interp): Rt, restored, would never run its build
	// macro again in the next one, and every build after the fix would fail. The
	// modules whose macros ran in the discarded interpreter are typed again
	// (CompilationCache.taintMacroModules; a divergence from upstream). The
	// erroneous build fails as the fresh one does ('!')
	const good = '#if macro\nclass Bad {\n\tpublic static function build():Array<haxe.macro.Expr.Field>\n\t\treturn null;\n}\n#end\n';
	const bad = '#if macro\nclass Bad {\n\tpublic static function build():Array<haxe.macro.Expr.Field>\n\t\treturn 1 + "x" * 2;\n}\n#end\n';
	cases["a build macro's persistent state, after an error in a macro"] = [
		{
			...persistent[0],
			'Bad.hx': good,
			'Other.hx': '@:build(Bad.build())\nclass Other {\n\tpublic static var y = 3;\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Tpl.use() + Other.y);\n\t}\n}\n',
		},
		{ '-D': 'two' },
		{ '-D': 'one', 'Bad.hx': bad, '!': true },
		{ '-D': 'one', 'Bad.hx': good },
		{ '-D': 'two' },
		{ '-D': 'one' },
	];
}

// a frontend's hook (hxmc/test/frontend/Hook.hx) changes Lib's bodies, which
// no edit changes, after the lowering: each build must be the fresh one's,
// and Lib's bodies reused (a callee of the body the hook made in an earlier
// build is not this one's: the whole lowering again)
const frontendCases = {
	// (the hook adds a call of a function it makes anew each build)
	"a body a frontend's hook rewrites every build": [
		{
			'Lib.hx': 'class Lib {\n\tpublic static function f(x:Int):Int\n\t\treturn x * 3 + 1;\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.f(2));\n\t}\n}\n',
		},
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.f(3));\n\t}\n}\n' },
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.f(4) + 1);\n\t}\n}\n' },
	],
	// (Lib.g reaches no GC point but when the hook adds the call of Lib.alloc:
	// then main keeps `keep`, live across its call alone, in its frame)
	"a body a frontend's hook makes allocate": [
		{
			'Lib.hx': 'class Lib {\n\t// (too large to be inlined: its own no-GC flag is what main\'s call reads)\n\tpublic static function g(x:Int):Int {\n\t\tvar t = 0;\n\t\tfor (i in 0...x) {\n\t\t\tt += i * 3 + (t >> 1) - (i & 7);\n\t\t\tif (t > 1000) t -= 999;\n\t\t\tt ^= i << 2;\n\t\t}\n\t\treturn t + x * 3 + 1 + (x & 5) * 7 - (x >> 2);\n\t}\n\n\tstatic var made:Array<String> = [];\n\n\tpublic static function alloc():Int {\n\t\tmade.push("x" + made.length);\n\t\treturn made.length;\n\t}\n}\n',
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.g(2) + Lib.alloc());\n\t}\n}\n',
		},
		{ 'Main.hx': 'class Main {\n\tstatic var last:Array<Int>;\n\n\tstatic function extra():Int\n\t\treturn 5;\n\n\tstatic function main() {\n\t\tvar n = Lib.alloc();\n\t\tvar keep = [extra() + n];\n\t\tvar r = Lib.g(2);\n\t\tlast = keep;\n\t\ttrace(keep[0] + r);\n\t}\n}\n' },
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.g(3) + Lib.alloc());\n\t}\n}\n' },
	],
};

// the cases built for this machine and run (their arguments), the server's
// output as the fresh one
const runs = new Map();
// Objective-C (macOS only): what Lib's bodies declare for the link (a
// message's C function, libobjc's functions, a class's framework, a
// category's: LowerQueries.objcDeclare) and read of a Haxe class extending
// an Objective-C one (its registration, its id fields: LowerQueries.objcPeer
// and idFields), replayed after an edit of Main alone
if (process.platform === 'darwin' && !web) {
	const name = 'Objective-C messages and a Haxe subclass, in replayed bodies';
	runs.set(name, ['-D', 'hxmc.target=macos-' + (process.arch === 'arm64' ? 'arm64' : 'x86_64')]);
	cases[name] = [
		{
			'Lib.hx': `import hxmc.unsafe.CString;

@:hxmc.struct class Rect {
	public var x:Float; public var y:Float; public var w:Float; public var h:Float;
	public inline function new(x, y, w, h) { this.x = x; this.y = y; this.w = w; this.h = h; }
}
@:hxmc.lib("/usr/lib/libobjc.A.dylib") @:hxmc.objc extern class NSObject {
	static function alloc():NSObject;
	function init():NSObject;
	@:hxmc.framework("Foundation") function description():NSString;
}
@:hxmc.framework("Foundation") @:hxmc.objc extern class NSString extends NSObject {
	var UTF8String(get, never):CString;
	function get_UTF8String():CString;
}
@:hxmc.framework("AppKit") @:hxmc.objc extern class NSView extends NSObject {
	static function alloc():NSView;
	function initWithFrame(frame:Rect):NSView;
	var flipped(get, never):Bool;
	@:selector("isFlipped") function get_flipped():Bool;
	function addSubview(v:NSView):Void;
}
class Flipped extends NSView {
	public var child:Null<NSView>;
	public function new(r:Rect) super.initWithFrame(r);
	override function get_flipped() return true;
}
class Lib {
	public static function run():String {
		var f = new Flipped(new Rect(0, 0, 10, 10));
		f.child = NSView.alloc().initWithFrame(new Rect(0, 1, 2, 2));
		f.addSubview(f.child);
		return NSObject.alloc().init().description().UTF8String.toString().substr(0, 10) + " " + (f : NSView).flipped;
	}
}
`,
			'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace(Lib.run());\n\t}\n}\n',
		},
		{ 'Main.hx': 'class Main {\n\tstatic function main() {\n\t\ttrace("again " + Lib.run());\n\t}\n}\n' },
	];
}

const out = web ? 'out/app.wasm' : process.platform === 'win32' ? 'out/app.exe' : 'out/app';
const ref = 'ref/' + path.basename(out);
const args = (o, more = []) => [...more, '-cp', 'src', '-main', 'Main', ...(web ? ['-D', 'hxmc.target=wasm32-wasi'] : process.platform === 'linux' ? ['-D', 'hxmc.libc=glibc'] : []),
	'--custom-target', 'hxmc=' + o];
// (hxmc's std as an installation gives it, HXMC_STD: the server adds it to the
// requests for hxmc, which name no std, as an editor's client sends them)
const std = path.join(path.dirname(compiler), 'std');
const env = { ...process.env, HXMC_MODULE_CACHE: '0', HXMC_STATS: '1', HAXE_STD_PATH: process.env.HAXE_STD_PATH ?? path.join(repo, 'haxe/upstream/std'),
	...(fs.existsSync(std) ? { HXMC_STD: std } : {}) };

// a compilation server per case (its modules by path: a case's Main is not
// another's): one waiting for connections (--wait, a request per connection),
// or one connected to us (--server-connect, as helder's studio and helder dev
// run it: requests and answers on one connection, each after its length)
async function serve(connected, env, run) {
	if (connected) return serveConnected(env, run);
	const port = await new Promise((r) => {
		const s = net.createServer().listen(0, '127.0.0.1', () => {
			const p = s.address().port;
			s.close(() => r(p));
		});
	});
	const server = spawn(compiler, ['--wait', String(port)], { env, stdio: ['ignore', 'pipe', 'pipe'] });
	let output = '';
	server.stdout.on('data', (d) => (output += d));
	server.stderr.on('data', (d) => (output += d));
	const request = (cwd, words) => new Promise((resolve) => {
		const go = (n) => {
			const s = net.connect(port, '127.0.0.1');
			const chunks = [];
			s.on('error', () => (n > 0 ? setTimeout(() => go(n - 1), 50) : resolve('\x02 no compilation server')));
			s.on('connect', () => s.write(['--cwd', cwd, ...words].map((a) => a + '\n').join('') + '\0'));
			s.on('data', (d) => chunks.push(d));
			s.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
		};
		go(100);
	});
	try {
		await run(request, () => output.slice(-2000), () => output.length, (from) => output.slice(from));
	} finally {
		server.kill();
	}
}

async function serveConnected(env, run) {
	const listener = net.createServer();
	await new Promise((r) => listener.listen(0, '127.0.0.1', r));
	const server = spawn(compiler, ['--server-connect', '127.0.0.1:' + listener.address().port], { env, stdio: ['ignore', 'pipe', 'pipe'] });
	let output = '';
	server.stdout.on('data', (d) => (output += d));
	server.stderr.on('data', (d) => (output += d));
	const sock = await new Promise((r) => listener.once('connection', r));
	listener.close();
	let buf = Buffer.alloc(0), waiting = null, reads = 0;
	const take = () => {
		if (waiting && buf.length >= 4 && buf.length >= 4 + buf.readInt32LE(0)) {
			// (a small answer in one write arrives in one read)
			answers++;
			if (reads > 1 && buf.readInt32LE(0) < 16384) split++;
			const n = buf.readInt32LE(0), answer = buf.subarray(4, 4 + n).toString('utf8');
			buf = buf.subarray(4 + n);
			const w = waiting;
			waiting = null;
			w(answer);
		}
	};
	sock.on('data', (d) => {
		reads = buf.length === 0 ? 1 : reads + 1;
		buf = Buffer.concat([buf, d]);
		take();
	});
	sock.on('close', () => waiting && waiting('\x02 the compilation server closed the connection'));
	// (the length and the request in one write, as each answer comes)
	const request = (cwd, words) => new Promise((resolve) => {
		waiting = resolve;
		const body = Buffer.from(['--cwd', cwd, ...words].join('\n'));
		const head = Buffer.alloc(4);
		head.writeInt32LE(body.length);
		sock.write(Buffer.concat([head, body]));
		take();
	});
	try {
		await run(request, () => output.slice(-2000), () => output.length, (from) => output.slice(from));
	} finally {
		sock.destroy();
		server.kill();
	}
}

let failures = 0;
// the connected server's answers, and the small ones that took more than one
// read: written as two writes (its length, then its text), an answer waits
// for the client's delayed ACK of the first (40 ms), and its text comes in a
// read of its own; one write comes in one
let answers = 0, split = 0;
// (the server's typed modules kept in memory, as `hxmc dev` asks, and read
// back from HXB, its default; and the connected server, in memory, as helder's)
for (const [hxb, connected] of [[false, false], [true, false], [false, true]])
	for (const [name, steps] of Object.entries(frontend ? frontendCases : cases)) {
		const work = fs.mkdtempSync(path.join(os.tmpdir(), 'hxmc-server-verify-'));
		fs.mkdirSync(path.join(work, 'src'));
		// (an object store of its own: what '#compiled' counts is what this
		// server, and the fresh builds after each of its builds, made)
		const caseEnv = { ...env, HXMC_CACHE: path.join(work, 'cache') };
		await serve(connected, caseEnv, async (request, serverOutput, mark = () => 0, since = () => '') => {
			for (let i = 0; i < steps.length; i++) {
				const { '-D': define, '!': fails, ...files } = steps[i];
				const more = [...(runs.get(name) ?? []), ...(define ? ['-D', define] : [])];
				for (const [f, text] of Object.entries(files)) {
					if (f.startsWith('#')) continue;
					fs.writeFileSync(path.join(work, 'src', f), text);
					await request(work, ['--display', JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'server/invalidate', params: { file: path.join(work, 'src', f) } })]);
				}
				const from = mark();
				const answer = await request(work, [...args(out, more), ...(hxb ? [] : ['-D', 'disable-hxb-cache'])]);
				const fresh = spawnSync(compiler, args(ref, more), { cwd: work, env: caseEnv, encoding: 'utf8' });
				// (a build that fails, as the fresh one does)
				if (fails) {
					const ok = answer.includes('\x02') && fresh.status !== 0;
					console.log((ok ? 'ok   ' : 'FAIL ') + `${name} (${mode}${hxb ? ', HXB' : ''}${connected ? ', connected' : ''}): edit ${i} (-D ${define}), fails as the fresh build`);
					if (!ok) failures++;
					continue;
				}
				let same = !answer.includes('\x02') && fresh.status === 0 && Buffer.compare(fs.readFileSync(path.join(work, out)), fs.readFileSync(path.join(work, ref))) === 0;
				// (and the server's output runs as the fresh one does)
				const ran = same && runs.has(name) ? [out, ref].map((o) => spawnSync(path.join(work, o), { cwd: work, encoding: 'utf8' })) : null;
				if (ran) same = ran[0].status === 0 && ran[0].stdout === ran[1].stdout;
				// (the modules whose objects the build compiled: HXMC_STATS, the
				// server's output, or the answer's, after the request)
				const expect = steps[i]['#compiled'];
				let compiled = null, counted = false, restarted = null;
				// (a frontend's: Lib's bodies reused, the lowering not done again)
				if (frontend && same && i > 0) {
					await new Promise((r) => setTimeout(r, 100));
					restarted = /lowered again: ([^)\n]*)/.exec(since(from) + answer)?.[1] ?? null;
					if (restarted != null) same = false;
				}
				if (expect && same) {
					counted = true;
					await new Promise((r) => setTimeout(r, 100));
					const text = since(from) + answer;
					const m = /hxmc: compiled ([^\n\x01]*)/.exec(text);
					compiled = /hxmc: modules \d+: \d+ cached, 0 compiled/.test(text) ? [] : m ? m[1].split(', ') : null;
					same = compiled != null && compiled.join(',') === expect.join(',');
				}
				const what = `${name} (${mode}${hxb ? ', HXB' : ''}${connected ? ', connected' : ''}): ` + (i === 0 ? 'the first build' : `edit ${i}`) + (define ? ` (-D ${define})` : '');
				console.log((same ? 'ok   ' : 'FAIL ') + what);
				if (!same) {
					failures++;
					console.log(answer.includes('\x02') ? answer + serverOutput() : fresh.status !== 0 ? fresh.stdout + fresh.stderr : ran ? `the run: exit ${ran[0].status}\n${ran[0].stdout}${ran[0].stderr}`
						: restarted != null ? `the lowering was done again (${restarted})` : counted ? `compiled ${compiled == null ? '(no stats)' : '[' + compiled.join(', ') + ']'}, expected [${expect.join(', ')}]` : 'the outputs differ');
				}
			}
		});
		fs.rmSync(work, { recursive: true, force: true });
	}
// (the connected server answers at once: its length and text in one write, Server.mkLengthPrefixedCommunication)
const prompt = split === 0;
console.log((prompt ? 'ok   ' : 'FAIL ') + `the connected server's answers come in one write: ${split} of ${answers} came in more than one read`);
if (!prompt) failures++;
console.log(failures === 0 ? 'server-verify: ok' : `server-verify: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
