// `haxe` (@hxmc/cli) under node: the launcher, also where the native
// compiler, run in its place (hxmc/bootstrap/haxe), passes on a build for the
// hxmc target (hxmc.HaxeMain): the launcher gives it the runtime objects
import { main } from './launcher.mjs';
main(process.argv.slice(2));
