// define: dce=full
// An ObjectMap under --dce full (upstream's unit suite builds with it): the
// runtime's lock word for updating identity hashes (hxmc.rt.IdHash, a static
// variable only named by its symbol) was removed, and the link failed with
// "undefined symbol hxmc_idhash_lock".
class ObjectMapDce {
	static function main() {
		var m = new haxe.ds.ObjectMap<{}, Int>();
		var keys = [for (i in 0...100) {}];
		for (i in 0...keys.length)
			m.set(keys[i], i);
		var sum = 0;
		for (k in keys)
			sum += m.get(k);
		Sys.println(sum);
	}
}
