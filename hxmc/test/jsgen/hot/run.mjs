// -D hxmc.js.hot: a case of hxmc/test/jsgen/hot (JsGenCheck) run through its versions, in one process: the first
// version built and run, then each next one built and its patch applied (or the reason it is none printed), the
// program's `tick()` printed after each. `node run.mjs <haxe> <case dir> <out dir> <portable> v1 v2 ...`
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [haxe, dir, out, portable, ...versions] = process.argv.slice(2);
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
writeFileSync(out + "/package.json", '{"type": "module"}\n');
const build = (v) => {
	try {
		execFileSync(haxe, ["-cp", `${dir}/${v}`, "-cp", `${dir}/common`, "-cp", portable, "-main", "Main",
			"-D", "hxmc.js=es-modules", "-D", "hxmc.js.hot", "--js", `${out}/index.js`], { stdio: "pipe" });
	} catch (e) {
		console.log(`${v}: build failed\n${e.stdout}${e.stderr}`);
		process.exit(1);
	}
};
build(versions[0]);
await import(pathToFileURL(`${out}/index.js`));
console.log(`${versions[0]}: ${globalThis.tick()}`);
for (const v of versions.slice(1)) {
	build(v);
	const rec = JSON.parse(readFileSync(`${out}/_hx_hot.json`, "utf8"));
	if (rec.reload) console.log(`${v}: reload: ${rec.reload}`);
	else if (rec.patch) {
		await import(pathToFileURL(`${out}/${rec.patch}`));
		console.log(`${v}: ${globalThis.tick()}`);
	} else console.log(`${v}: unchanged: ${globalThis.tick()}`);
}
