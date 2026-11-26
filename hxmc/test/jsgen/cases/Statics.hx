// statics whose values call other modules (es-modules: a module runs after those it imports, but those running): of
// a cycle of modules, where the one whose static needs the other runs second (the entry imports it first), of a cycle
// of statics, where no order has both ready (one initialized when first read); one that constructs a class whose
// constructor names the static's own (assigned after the file's classes)
// ts output has: main.ts: import "./statics/Celsius.ts";
// ts output has: statics/Celsius.ts: export const Celsius = {
// ts output lacks: statics/Celsius.ts: #freezing
// ts output has: statics/Ping.ts: static #x_ready = false;
// ts output lacks: statics/Holder.ts: #NULL
// ts output has: statics/Holder.ts: static readonly NULL: Named;
// ts output has: statics/Holder.ts: (Holder as any).NULL = new NullNamed();
// ts: // (readonly, though assigned after its class)
// ts: // @ts-expect-error
// ts: Holder.NULL = null;
// ts: import { Scale } from "./statics/Scale.ts";
// ts: import { Holder } from "./statics/Holder.ts";
// ts: const c: number = Scale.room();
class Statics {
	static function main() {
		trace(statics.Scale.room(), statics.Ping.x, statics.Pong.y, statics.Holder.NULL.name());
	}
}
