// `haxe` (@hxmc/haxe) under node: the launcher, also where the native
// compiler, run in its place (hxmc/bootstrap/haxe), passes on a build for the
// hxmc target (hxmc.HaxeMain): the launcher finds hxmc's std and the runtime
// objects for it
import { main } from './launcher.mjs';
main(process.argv.slice(2));
