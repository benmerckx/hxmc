package hxmc;

import haxe.io.Bytes;
import hxmc.LinkMachO.BeBuf;

// The embedded code signature of a Mach-O image (LC_CODE_SIGNATURE, at
// the end of __LINKEDIT), written as ld64 and codesign (or rcodesign and
// ldid, without Apple's tools) write it: a SuperBlob (big-endian) of
// blobs, first the CodeDirectory: the SHA-256 of each 4 KB page of the
// file up to the signature, and before them, at negative indices, the
// "special slots": the hashes of what the signature binds outside the
// code (1 the bundle's Info.plist, 2 the requirements blob, 3 the bundle's
// _CodeSignature/CodeResources, 5 the entitlements blob, 7 their DER form).
// Two kinds here:
//   - linker-signed (the default, what ld64 writes for arm64 executables):
//     ad hoc, the CodeDirectory alone, identifier "hxmc";
//   - a bundle's (adhoc: hxmc.ios.Bundle, or -D hxmc.codesign-id,
//     -info-plist, -resources, -entitlements for a packager that writes the
//     bundle, Options): ad hoc, identified by the bundle id, with the
//     Info.plist's and CodeResources' hashes, an empty requirement set and
//     the entitlements if any (an XML plist): what `codesign -s -` writes,
//     which the iOS simulator runs.
// A device needs more (docs/hxmc.md, iOS): a CMS signature blob (slot
// 0x10000) by the developer's certificate over the CodeDirectory, the
// entitlements of the provisioning profile (also as DER), the designated
// requirement naming the certificate's chain, the team id; `identity`
// stays null until that is written (Identity: the certificate and its key).
class CodeSign {
	// CodeDirectory flags
	public static inline var ADHOC = 0x2;
	public static inline var LINKER_SIGNED = 0x20000;
	static inline var PAGE_LOG2 = 12;
	static inline var HEADER = 88; // CodeDirectory 0x20400 up to the identifier

	public var identifier = "hxmc";
	// an executable (CS_EXECSEG_MAIN_BINARY); false: a dylib
	public var mainBinary = true;
	public var linkerSigned = true;
	// the bundle's Info.plist and _CodeSignature/CodeResources (slots 1, 3)
	public var infoPlist:Null<Bytes> = null;
	public var resources:Null<Bytes> = null;
	// the entitlements (an XML plist; slot 5), null: none
	public var entitlements:Null<Bytes> = null;
	// a device's signature: not written yet (null: ad hoc)
	public var identity:Null<Identity> = null;

	public function new() {}

	// ad hoc as `codesign -s -` signs a bundle's executable: identified by
	// identifier, binding the bundle's Info.plist (slot 1), its
	// _CodeSignature/CodeResources (slot 3) and the entitlements (slot 5),
	// each optional
	public static function adhoc(identifier:String, infoPlist:Null<Bytes>, resources:Null<Bytes>, entitlements:Null<Bytes>):CodeSign {
		var s = new CodeSign();
		s.linkerSigned = false;
		s.identifier = identifier;
		s.infoPlist = infoPlist;
		s.resources = resources;
		s.entitlements = entitlements;
		return s;
	}

	// the blobs after the CodeDirectory, by slot
	function blobs():Array<{slot:Int, data:Bytes}> {
		if (linkerSigned) return [];
		var out = [{slot: 2, data: requirements()}];
		if (entitlements != null) out.push({slot: 5, data: blob(0xfade7171, entitlements)});
		return out;
	}

	function specialSlots():Int
		return linkerSigned ? 0 : entitlements != null ? 5 : resources != null ? 3 : 2;

	// the bytes the signature takes for a file whose signed part ends at
	// codeLimit (16-byte aligned: LC_CODE_SIGNATURE's size)
	public function size(codeLimit:Int):Int {
		var b = blobs();
		var n = 12 + 8 * (1 + b.length) + cdLength(codeLimit);
		for (x in b)
			n += x.data.length;
		return (n + 15) & ~15;
	}

	function cdLength(codeLimit:Int):Int {
		var pages = (codeLimit + (1 << PAGE_LOG2) - 1) >> PAGE_LOG2;
		return HEADER + Bytes.ofString(identifier).length + 1 + 32 * (specialSlots() + pages);
	}

	// the signature of file[0, codeLimit) (execSegLimit: the end of
	// __TEXT, the executable segment), size(codeLimit) bytes
	public function sign(file:Bytes, codeLimit:Int, execSegLimit:Int):Bytes {
		if (identity != null) throw "hxmc: code signing with a certificate is not supported yet (ad hoc only)";
		var extra = blobs();
		var nSpecial = specialSlots();
		var pages = (codeLimit + (1 << PAGE_LOG2) - 1) >> PAGE_LOG2;
		var ident = Bytes.ofString(identifier);
		var cdLen = cdLength(codeLimit);
		var count = 1 + extra.length;
		var total = 12 + 8 * count + cdLen;
		for (x in extra)
			total += x.data.length;
		var sig = new BeBuf();
		sig.u32(0xfade0cc0); // CSMAGIC_EMBEDDED_SIGNATURE
		sig.u32(total);
		sig.u32(count);
		sig.u32(0); // CSSLOT_CODEDIRECTORY
		var at = 12 + 8 * count;
		sig.u32(at);
		at += cdLen;
		for (x in extra) {
			sig.u32(x.slot);
			sig.u32(at);
			at += x.data.length;
		}
		sig.u32(0xfade0c02); // CSMAGIC_CODEDIRECTORY
		sig.u32(cdLen);
		sig.u32(0x20400);
		sig.u32(linkerSigned ? ADHOC | LINKER_SIGNED : ADHOC);
		sig.u32(HEADER + ident.length + 1 + 32 * nSpecial); // hashOffset
		sig.u32(HEADER); // identOffset
		sig.u32(nSpecial);
		sig.u32(pages);
		sig.u32(codeLimit);
		sig.u8(32); // hashSize
		sig.u8(2); // CS_HASHTYPE_SHA256
		sig.u8(0); // platform
		sig.u8(PAGE_LOG2);
		sig.u32(0); // spare2
		sig.u32(0); // scatterOffset
		sig.u32(0); // teamOffset
		sig.u32(0); // spare3
		sig.u64(0); // codeLimit64
		sig.u64(0); // execSegBase
		sig.u64(execSegLimit);
		sig.u64(mainBinary ? 1 : 0); // CS_EXECSEG_MAIN_BINARY
		sig.b.bytes(ident);
		sig.u8(0);
		// the special slots, from -nSpecial up to -1 (absent ones zero)
		var bySlot = new Map<Int, Bytes>();
		if (infoPlist != null) bySlot.set(1, infoPlist);
		if (resources != null) bySlot.set(3, resources);
		for (x in extra)
			bySlot.set(x.slot, x.data);
		var k = nSpecial;
		while (k >= 1) {
			var d = bySlot.get(k);
			if (d == null) sig.b.zeros(32) else sig.b.bytes(haxe.crypto.Sha256.make(d));
			k--;
		}
		for (p in 0...pages) {
			var off = p << PAGE_LOG2;
			var n = codeLimit - off < 1 << PAGE_LOG2 ? codeLimit - off : 1 << PAGE_LOG2;
			sig.b.bytes(haxe.crypto.Sha256.make(file.sub(off, n)));
		}
		for (x in extra)
			sig.b.bytes(x.data);
		sig.b.align(16);
		return sig.toBytes();
	}

	// an empty requirement set (CSMAGIC_REQUIREMENTS, no requirements), as
	// `codesign -s -` writes
	static function requirements():Bytes {
		var b = new BeBuf();
		b.u32(0xfade0c01);
		b.u32(12);
		b.u32(0);
		return b.toBytes();
	}

	static function blob(magic:Int, data:Bytes):Bytes {
		var b = new BeBuf();
		b.u32(magic);
		b.u32(8 + data.length);
		b.b.bytes(data);
		return b.toBytes();
	}
}

// What a device's signature will need (not used yet): the signing
// certificate (DER) with its chain up to Apple's root, and its private key
// (RSA 2048 or ECDSA P-256, as Apple issues them), the team id, and the
// provisioning profile (embedded.mobileprovision: a CMS-signed plist whose
// entitlements and devices the signature must match)
typedef Identity = {
	var certificates:Array<Bytes>;
	var key:Bytes;
	var team:String;
	var profile:Bytes;
}
