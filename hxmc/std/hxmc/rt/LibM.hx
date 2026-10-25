package hxmc.rt;

import hxmc.I64;
import hxmc.unsafe.Mem;
import hxmc.unsafe.Ptr;

// Math on every target (docs/hxmc.md; docs/plans/math.md): the functions
// no instruction computes exactly, as musl computes them (musl's algorithms,
// and zig's ports of them in zig's libc and compiler_rt, which Linux
// executables linked before; see the license notice below), so that results
// are the same on every system and in WebAssembly. Math's natives are bound
// to them (@:hxmc.host: compiled into the programs that call them), Float's
// % to fmod (Lower.bindHosts); sqrt, abs, floor and ceil are instructions or
// inline code (MirBuild). Scoped code (docs/plans/lowlevel.md, "Scoped
// memory"): no GC reference, frame areas and read-only tables only.
//
// musl as a whole is licensed under the following standard MIT license:
//
// Copyright © 2005-2020 Rich Felker, et al.
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
@:keep @:hxmc.scoped
class LibM {
	// ---- the tables (pow_data.c, exp_data.c, log.c's, rem_pio2_large.c's
	// ipio2), as hexadecimal bit patterns: read-only data of the program
	// (Mem.words), indexed by entry

	static inline function powTab(i:Int):Float
		return Mem.getF64At(Mem.words("3ff6a00000000000bfd62c82f2b9c8003cfab424283756803ff6800000000000bfd5d1bdbf580800bd1ca508d8e0f7203ff6600000000000bfd5767717455800bd2362a4d5b6506d3ff6400000000000bfd51aad872df800bce684e49eb067d53ff6200000000000bfd4be5f95777800bd041b6993293ee03ff6000000000000bfd4618bc21c60003d13d82f484c84cc3ff5e00000000000bfd404308686a8003cdc42f3ed820b3a3ff5c00000000000bfd3a64c556948003d20b1c6865194603ff5a00000000000bfd347dd9a9880003d25594dd4c580923ff5800000000000bfd2e8e2bae120003d267b1e99b72bd83ff5600000000000bfd2895a13de88003d15ca14b6cfb03f3ff5600000000000bfd2895a13de88003d15ca14b6cfb03f3ff5400000000000bfd22941fbcf7800bd165a242853da763ff5200000000000bfd1c898c1699800bd1fafbc68e754043ff5000000000000bfd1675cababa8003d1f1fc63382a8f03ff4e00000000000bfd1058bf9ae4800bd26a8c4fd055a663ff4c00000000000bfd0a324e2739000bd0c6bee7ef4030e3ff4a00000000000bfd0402594b4d000bcf036b89ef42d7f3ff4a00000000000bfd0402594b4d000bcf036b89ef42d7f3ff4800000000000bfcfb9186d5e40003d0d572aab993c873ff4600000000000bfcef0adcbdc60003d2b26b79c86af243ff4400000000000bfce27076e2af000bd172f4f543fff103ff4200000000000bfcd5c216b4fc0003d21ba91bbca681b3ff4000000000000bfcc8ff7c79aa0003d27794f689f84343ff4000000000000bfcc8ff7c79aa0003d27794f689f84343ff3e00000000000bfcbc286742d90003d194eb0318bb78f3ff3c00000000000bfcaf3c94e80c0003cba4e633fcd90663ff3a00000000000bfca23bc1fe2b000bd258c64dc46c1ea3ff3a00000000000bfca23bc1fe2b000bd258c64dc46c1ea3ff3800000000000bfc9525a9cf45000bd2ad1d904c1d4e33ff3600000000000bfc87fa06520d0003d2bbdbf7fdbfa093ff3400000000000bfc7ab890210e0003d2bdb9072534a583ff3400000000000bfc7ab890210e0003d2bdb9072534a583ff3200000000000bfc6d60fe719d000bd10e46aa3b2e2663ff3000000000000bfc5ff3070a79000bd1e9e439f1050393ff3000000000000bfc5ff3070a79000bd1e9e439f1050393ff2e00000000000bfc526e5e3a1b000bd20de8b90075b8f3ff2c00000000000bfc44d2b6ccb80003d170cc16135783c3ff2c00000000000bfc44d2b6ccb80003d170cc16135783c3ff2a00000000000bfc371fc201e90003cf178864d27543a3ff2800000000000bfc29552f81ff000bd248d301771c4083ff2600000000000bfc1b72ad52f6000bd2e80a41811a3963ff2600000000000bfc1b72ad52f6000bd2e80a41811a3963ff2400000000000bfc0d77e7cd090003d0a699688e85bf43ff2400000000000bfc0d77e7cd090003d0a699688e85bf43ff2200000000000bfbfec9131dbe000bd2575545ca333f23ff2000000000000bfbe27076e2b00003d2a342c2af0003c3ff2000000000000bfbe27076e2b00003d2a342c2af0003c3ff1e00000000000bfbc5e548f5bc000bd1d0c57585fbe063ff1c00000000000bfba926d3a4ae0003d253935e85baac83ff1c00000000000bfba926d3a4ae0003d253935e85baac83ff1a00000000000bfb8c345d631a0003d137c294d2f56683ff1a00000000000bfb8c345d631a0003d137c294d2f56683ff1800000000000bfb6f0d28ae56000bd269737c93373da3ff1600000000000bfb51b073f0620003d1f025b61c65e573ff1600000000000bfb51b073f0620003d1f025b61c65e573ff1400000000000bfb341d7961be0003d2c5edaccf913df3ff1400000000000bfb341d7961be0003d2c5edaccf913df3ff1200000000000bfb16536eea380003d147c5e768fa3093ff1000000000000bfaf0a30c01180003d2d599e83368e913ff1000000000000bfaf0a30c01180003d2d599e83368e913ff0e00000000000bfab42dd711980003d1c827ae5d6704c3ff0e00000000000bfab42dd711980003d1c827ae5d6704c3ff0c00000000000bfa77458f632c000bd2cfc4634f2a1ee3ff0c00000000000bfa77458f632c000bd2cfc4634f2a1ee3ff0a00000000000bfa39e87b9fec0003cf502b7f526feaa3ff0a00000000000bfa39e87b9fec0003cf502b7f526feaa3ff0800000000000bf9f829b0e780000bd2980267c7e09e43ff0800000000000bf9f829b0e780000bd2980267c7e09e43ff0600000000000bf97b91b07d58000bd288d5493faa6393ff0400000000000bf8fc0a8b0fc0000bcdf1e7cf6d3a69c3ff0400000000000bf8fc0a8b0fc0000bcdf1e7cf6d3a69c3ff0200000000000bf7fe02a6b100000bd19e23f0dda40e43ff0200000000000bf7fe02a6b100000bd19e23f0dda40e43ff0000000000000000000000000000000000000000000003ff0000000000000000000000000000000000000000000003fefc000000000003f80101575890000bd10c76b999d2be83fef8000000000003f90205658938000bd23dc5b06e2f7d23fef4000000000003f98492528c90000bd2aa0ba325a0c343fef0000000000003fa0415d89e740003d0111c05cf1d7533feec000000000003fa466aed42e0000bd2c167375bdfd283fee8000000000003fa894aa149fc000bd197995d05a267d3fee4000000000003faccb73cdddc000bd1a68f247d828073fee2000000000003faeea31c006c000bd0e113e4fc93b7b3fede000000000003fb1973bd1466000bd25325d560d9e9b3feda000000000003fb3bdf5a7d1e0003d2cc85ea5db4ed73fed6000000000003fb5e95a4d97a000bd2c69063c5d1d1e3fed4000000000003fb700d30aeac0003cec1e8da99ded323fed0000000000003fb9335e5d5940003d23115c3abd47da3fecc000000000003fbb6ac88dad6000bd1390802bf768e53feca000000000003fbc885801bc40003d2646d1c65aacd33fec6000000000003fbec739830a2000bd2dc068afe645e03fec4000000000003fbfe89139dbe000bd2534d64fa10afd3fec0000000000003fc1178e8227e0003d21ef78ce2d07f23febe000000000003fc1aa2b7e23f0003d2ca78e443899343feba000000000003fc2d1610c8680003d039d6ccb81b4a13feb8000000000003fc365fcb01590003cc62fa8234b72893feb4000000000003fc4913d8333b0003d25837954fdb6783feb2000000000003fc527e5e4a1b0003d2633e8e5697dc73feae000000000003fc6574ebe8c10003d19cf8b2c3c2e783feac000000000003fc6f0128b757000bd25118de59c21e13feaa000000000003fc7898d85445000bd1c6610709143053fea6000000000003fc8beafeb390000bd073d54aae92cd13fea4000000000003fc95a5adcf700003d07f22858a0ff6f3fea0000000000003fca93ed3c8ae000bd287243505621693fe9e000000000003fcb31d8575bd000bd0c358d4eace1aa3fe9c000000000003fcbd087383be000bd2d4bc4595412b63fe9a000000000003fcc6ffbc6f01000bcf1ec72c5962bd23fe96000000000003fcdb13db0d49000bd2aff2af715b0353fe94000000000003fce530effe710003cc212276041f4303fe92000000000003fcef5ade4dd0000bcca211565bb8e113fe90000000000003fcf991c6cb3b0003d1bcbecca0cdf303fe8c000000000003fd07138604d58003cf89cdb16ed4e913fe8a000000000003fd0c42d676160003d27188b163ceae93fe88000000000003fd1178e8227e800bd2c210e63a5f01c3fe86000000000003fd16b5ccbacf8003d2b9acdf7a516813fe84000000000003fd1bf99635a68003d2ca6ed5147bdb73fe82000000000003fd214456d0eb8003d0a87deba46baea3fe7e000000000003fd2bef07cdc90003d2a9cfa4a5004f43fe7c000000000003fd314f1e1d36000bd28e27ad3213cb83fe7a000000000003fd36b6776be10003d116ecdb0f177c83fe78000000000003fd3c252773330003d183b54b606bd5c3fe76000000000003fd419b423d5e8003d08e436ec90e09d3fe74000000000003fd4718dc271c800bd2f27ce0967d6753fe72000000000003fd4c9e09e173000bd2e20891b0ad8a43fe70000000000003fd522ae0738a0003d2ebe708164c7593fe6e000000000003fd57bf753c8d0003d1fadedee5d40ef3fe6c000000000003fd5d5bddf596000bd0a0b2a08a465dc", 16), 0, i);

	static inline function powPoly(i:Int):Float
		return Mem.getF64At(Mem.words("bfe0000000000000bfe55555555555603fe00000000000063fe999999959554ebfe555555529a47abff2495b9b4845e93ff0002b8b263fc3", 16), 0, i);

	static inline function expTab(i:Int):I64
		return Mem.getI64At(Mem.words("00000000000000003ff00000000000003c9b3b4f1a88bf6e3feff63da9fb3335bc7160139cd8dc5d3fefec9a3e778061bc905e7a108766d13fefe315e86e7f853c8cd2523567f6133fefd9b0d3158574bc8bce8023f98efa3fefd06b29ddf6de3c60f74e61e6c8613fefc74518759bc83c90a3e45b33d3993fefbe3ecac6f3833c979aa65d837b6d3fefb5586cf9890f3c8eb51a92fdeffc3fefac922b7247f73c3ebe3d702f9cd13fefa3ec32d3d1a2bc6a033489906e0b3fef9b66affed31bbc9556522a2fbd0e3fef9301d0125b51bc5080ef8c4eea553fef8abdc06c31ccbc91c923b9d5f4163fef829aaea92de03c80d3e3e95c55af3fef7a98c8a58e51bc801b15eaa593483fef72b83c7d517bbc8f1ff055de323d3fef6af9388c8dea3c8b898c3f1353bf3fef635beb6fcb75bc96d99c7611eb263fef5be084045cd43c9aecf73e3a2f603fef54873168b9aabc8fe782cb86389d3fef4d5022fcd91d3c8a6f4144a6c38d3fef463b88628cd63c807a05b0e4047d3fef3f49917ddc963c968efde3a8a8943fef387a6e7562383c875e18f274487d3fef31ce4fb2a63f3c80472b981fe7f23fef2b4565e27cddbc96b87b3f71085e3fef24dfe1f563813c82f7e16d09ab313fef1e9df51fdee1bc3d219b1a6fbffa3fef187fd0dad9903c8b3782720c0ab43fef1285a6e4030b3c6e149289cecb8f3fef0cafa93e2f563c834d754db0abb63fef06fe0a31b7153c864201e2ac744c3fef0170fc4cd8313c8fdd395dd3f84a3feefc08b26416ffbc86a3803b8e5b043feef6c55f929ff1bc924aedcc4b50683feef1a7373aa9cbbc9907f81b512d8e3feeecae6d05d866bc71d1e83e9436d23feee7db34e59ff7bc991919b3ce1b153feee32dc313a8e53c859f48a72a4c6d3feedea64c123422bc9312607a28698a3feeda4504ac801cbc58a78f4817895b3feed60a21f72e2abc7c2c9b67499a1b3feed1f5d950a8973c4363ed60c2ac113feece086061892d3c9666093b0664ef3feeca41ed1d00573c6ecce1daa103793feec6a2b5c13cd03c93ff8e3f0f12303feec32af0d7d3de3c7690cebb7aafb03feebfdad5362a273c931dbdeb54e0773feebcb299fddd0dbc8f94340071a38e3feeb9b2769d2ca7bc87deccdc93a3493feeb6daa2cf6642bc78dec6bd0f385f3feeb42b569d4f82bc861246ec7b5cf63feeb1a4ca5d920f3c93350518fdd78e3feeaf4736b527da3c7b98b72f8a9b053feead12d497c7fd3c9063e1e21c54093feeab07dd4854293c34c7855019c6ea3feea9268a5946b73c9432e62b64c0353feea76f15ad2148bc8ce44a6199769f3feea5e1b976dc09bc8c33c53bef4da83feea47eb03a5585bc845378892be9ae3feea34634ccc320bc93cedd785658583feea238825522253c5710aa807e19643feea155d44ca973bc93b3efbf5e22283feea09e667f3bcdbc6a12ad8734b9823feea012750bdabfbc6367efb86da9ee3fee9fb23c651a2fbc80dc3d54e088513fee9f7df9519484bc781f647e5a3ecf3fee9f75e8ec5f74bc86ee4ac08b7db03fee9f9a48a58174bc8619321e55e68a3fee9feb564267c93c909ccb5e09d4d33feea0694fde5d3fbc7b32dcb94da51d3feea11473eb01873c94ecfd5467c06b3feea1ed0130c1323c65ebe1abd66c553feea2f336cf4e62bc88a1c52fb3cf423feea427543e1a12bc9369b6f13b37343feea589994cce13bc805e843a19ff1e3feea71a4623c7adbc94d450d872576e3feea8d99b4492ed3c90ad675b0e8a003feeaac7d98a66993c8db72fc1f0eab43feeace5422aa0dbbc65b6609cc5e7ff3feeaf3216b5448c3c7bf68359f35f443feeb1ae99157736bc93091fa71e3d833feeb45b0b91ffc6bc5da9b88b6c1e293feeb737b0cdc5e5bc6c23f97c90b9593feeba44cbc8520fbc92434322f4f9aa3feebd829fde4e50bc85ca6cd7668e4b3feec0f170ca07ba3c71affc2b91ce273feec49182a3f0903c6dd235e10a73bb3feec86319e32323bc87c504226222633feecc667b5de5653c8b1c86e3e231d53feed09bec4a2d33bc91bbd1d3bcbb153feed503b23e255d3c90cc319cee31d23feed99e1330b3583c8469846e735ab33feede6b5579fdbfbc82dfcd978e9db43feee36bbfd3f37a3c8c1a7792cb33873feee89f995ad3adbc907b8f4ad1d9fa3feeee07298db666bc55c3d956dcaeba3feef3a2b84f15fbbc90a40e3da6f6403feef9728de5593abc68d6f438ad93343feeff76f2fb5e47bc91eee26b588a353fef05b030a1064a3c74ffd70a5fddcd3fef0c1e904bc1d2bc91bdfbfa9298ac3fef12c25bd71e093c736eae30af0cb33fef199bdd85529c3c8ee3325c9ffd943fef20ab5fffd07a3c84e08fd10959ac3fef27f12e57d14b3c63cdaf384e1a673fef2f6d9406e7b53c676b2c6c9219683fef3720dcef9069bc808a1883ccb5d23fef3f0b555dc3fabc8fad5d3ffffa6f3fef472d4a07897cbc900dae3875a9493fef4f87080d89f23c74a385a63d07a73fef5818dcfba487bc82919e2040220f3fef60e316c983983c8e5a50d5c192ac3fef69e603db32853c843a59ac016b4b3fef7321f301b460bc82d52107b43e1f3fef7c97337b9b5fbc892ab93b470dc93fef864614f5a1293c74b604603a88d33fef902ee78b3ff63c83c5ec519d72713fef9a51fbc74c83bc8ff7128fd391f03fefa4afa2a490dabc8dae98e223747d3fefaf482d8e67f13c8ec3bc41aa20083fefba1bee615a273c842b94c3a9eb323fefc52b376bba973c8a64a931d185ee3fefd0765b6e4540bc8e37bae43be3ed3fefdbfdad9cbe143c77893b4d91cd9d3fefe7c1819e90d83c5305c14160cc893feff3c22b8f71f1", 16), 0, i);

	static inline function expPoly(i:Int):Float
		return Mem.getF64At(Mem.words("3fdffffffffffdbd3fc555555555543c3fa55555cf172b913f81111167a4d017", 16), 0, i);

	static inline function logTab(i:Int):Float
		return Mem.getF64At(Mem.words("3ff734f0c3e0de9fbfd7cc7f79e690003ff713786a2ce91fbfd76feec20d00003ff6f26008fab5a0bfd713e31351e0003ff6d1a61f138c7dbfd6b85b382878003ff6b1490bc5b4d1bfd65d55908078003ff69147332f0cbabfd602d0761800003ff6719f18224223bfd5a8ca869090003ff6524f99a51ed9bfd54f43560350003ff63356aa8f24c4bfd4f637c36b40003ff614b36b9ddc14bfd49da7fda850003ff5f66452c65c4cbfd445923989a8003ff5d867b5912c4fbfd3edf439b0b8003ff5babccb5b90debfd396ce448f70003ff59d61f2d91a78bfd3401e17bda0003ff5805612465687bfd2e9e2ef4680003ff56397cee76bd3bfd2941b3830e0003ff54725e2a77f93bfd23ec58cda88003ff52aff42064583bfd1e9e1292790003ff50f22dbb2bddfbfd1956d2b48f8003ff4f38f4734ded7bfd141679ab9f8003ff4d843cfde2840bfd0edd094ef98003ff4bd3ec078a3c8bfd09aa518db10003ff4a27fc3e0258abfd047e65263b8003ff4880524d48434bfcfeb224586f0003ff46dce1b192d0bbfcf474a7517b0003ff453d9d3391854bfcea4443d1030003ff43a2744b4845abfce020d44e9b0003ff420b54115f8fbbfcd60a22977f0003ff40782da3ef4b1bfccc001049590003ff3ee8f5d57fe8fbfcc2029568910003ff3d5d9a00b4ce9bfcb81178d8110003ff3bd60c010c12bbfcae2c9ccd3d0003ff3a5242b75dab8bfca45402e1290003ff38d22cd9fd002bfc9a877681df0003ff3755bc5847a1cbfc90c6d694830003ff35dce49ad36e2bfc87120a645c0003ff34679984dd440bfc7d68fb41430003ff32f5cceffcb24bfc73cb83c6270003ff3187775a10d49bfc6a39a9b3760003ff301c8373e3990bfc60b3154b7a0003ff2eb4ebb95f841bfc5737d762430003ff2d50a0219a9d1bfc4dc7b8fc230003ff2bef9a8b7fd2abfc4462c51d200003ff2a91c7a0c1babbfc3b08abc8300003ff293726014b530bfc31b996b4900003ff27dfa5757a1f5bfc2875490a440003ff268b39b1d3bbfbfc1f3b9f879a0003ff2539d838ff5bdbfc160c8252ca0003ff23eb7aac9083bbfc0ce7f57f720003ff22a012ba940b6bfc03cdc49fea0003ff2157996cc4132bfbf57bdbc4b80003ff201201dd2fc9bbfbe3708964040003ff1ecf4494d480bbfbd17983ef940003ff1d8f5528f6569bfbbf9674ed8a0003ff1c52311577e7cbfbadc79202f60003ff1b17c74cb26e9bfb9c0c3e72880003ff19e010c2c1ab6bfb8a646b372c0003ff18ab07bb670bdbfb78d01b3ac00003ff1778a25efbcb6bfb674f1453800003ff1648d354c31dabfb55e0e6d8780003ff151b990275fddbfb4485cdea1e0003ff13f0ea432d24cbfb333d94d6aa0003ff12c8b7210f9dabfb22079f8c560003ff11a3028ecb531bfb10e46986220003ff107fbda8434afbfaffa6c6ad200003ff0f5ee0f4e6bb3bfadda8d4a7740003ff0e4065d2a9fcebfabbcece48500003ff0d244632ca521bfa9a1894012c0003ff0c0a77ce2981abfa788583302c0003ff0af2f83c636d1bfa5715e67d680003ff09ddb98a01339bfa35c8a496580003ff08cabaf52e7dfbfa149e3641540003ff07b9f2f4e28fbbf9e72c082eb80003ff06ab58c358f19bf9a55f1525280003ff059eea5ecf92cbf963d62cf8180003ff04949cdd12c90bf9228fb8caa00003ff038c6c6f0ada9bf8c317b20f900003ff02865137932a9bf8419355daa00003ff0182427ea7348bf781203c2ec00003ff008040614b195bf600409792400003fefe01ff726fa1a3f6feff3849000003fefa11cc261ea743f87dc41353d00003fef6310b081992e3f93cea3c4c280003fef25f63ceeadcd3f9b9fc1148900003feee9c8039113e73fa1b0d8ce1100003feeae8078cbb1ab3fa58a5bd001c0003fee741aa29d0c9b3fa95c8340d880003fee3a91830a99b53fad276aef5780003fee01e009609a563fb07598e598c0003fedca01e577bb983fb253f5e30d20003fed92f20b7c91033fb42edd8b3800003fed5cac66fb5cce3fb606598757c0003fed272caa5ede9d3fb7da76356a00003fecf26e3e6b2ccd3fb9ab434e1c60003fecbe6da2a779023fbb78c7bb0d60003fec8b266d37086d3fbd431332e720003fec5894bd5d58043fbf0a3171de60003fec26b533bb9f8c3fc067152b9140003febf583eeece73f3fc147858292b0003febc4fd75db96c13fc2266ecdca30003feb951e0c864a283fc303d7a6c550003feb65e2c5ef3e2c3fc3dfc33c3310003feb374867c9888b3fc4ba366b7a80003feb094b211d304a3fc5933928d1f0003feadbe885f2ef7e3fc66acd2418f0003feaaf1d31603da23fc740f8ec6690003fea82e63fd358a73fc815c0f51af0003fea5740ef09738b3fc8e92954f680003fea2c2a90ab4b273fc9bb3602f840003fea01a01393f2d13fca8bed1c2c00003fe9d79f24db3c1b3fcb5b515c01d0003fe9ae2505c7b1903fcc2967ccbcc0003fe9852ef297ce2f3fccf635d54860003fe95cbaeea44b753fcdc1bd3446c0003fe934c69de748383fce8c01b8cfe0003fe90d4f2f6752e63fcf5509c01790003fe8e6528effd79d3fd00e6c121fb8003fe8bfce9fcc007c3fd071b80e93d0003fe899c0dabec30e3fd0d46b9e8670003fe87427aa2317fb3fd13687334bd0003fe84f00acb39a083fd1980d672348003fe82a49e8653e553fd1f8ffe0cc80003fe8060195f402603fd2595fd76368003fe7e22563e0a3293fd2b9300914a8003fe7beb377dcb5ad3fd31872104360003fe79baa679725c23fd377266dec18003fe77907f21706573fd3d54ffbaf30003fe756cadbd6130c3fd432eee32fe000", 16), 0, i);

	static inline function logTab2(i:Int):Float
		return Mem.getF64At(Mem.words("3fe61000014fb66b3c7e026c91425b3c3fe63000034db4953c8dbfea48005d413fe650000d94d4783c8e7fa786d6a5b73fe67000074e6fad3c61fcea6b54254c3fe68ffffedf0faebc7c7e274c590efd3fe6b0000763c5bcbc8ac16848dcda013fe6d0001e5cc1f63c833f1c9d4993113fe6efffeb05f63ebc7e80041ae22d533fe710000e8697803c7bff66710979523fe72ffffc67e9123c8c00e226bd87243fe74fffdf81116abc6e02916ef101d23fe770000f679c90bc67fc71cd549c743fe78ffffa7ec8353c81bec19ef504833fe7affffe20c2e6bc707e1729cc64653fe7cfffed3fc900bc808072087b8b1c3fe7efffe9261a763c8dc0286d9df9ae3fe81000049ca3e83c897fd251e54c333fe8300017932c8fbc8afee9b630f3813fe850000633739c3c89bfbf6b6535bc3fe87000204289c6bc8bbf65f3117b753fe88fffebf57904bc89006ea23dcb573fe8b00022bc04dfbc7d00df38e04b0a3fe8cfffe50c1b8abc88007146ff9f053fe8effffc918e433c83817bd07a70383fe910001efa5fc73c893e9176dfb4033fe9300013467bb93c7f804e4b9802763fe94fffe6ee076fbc8f7ef0d9ff622e3fe96fffde3c12d1bc7082aa962638ba3fe98ffff4458a0dbc87801b9164a8ef3fe9afffdd982e3ebc8740e08a5a93373fe9cfffed49fb663c3fce08c19be0003fe9f00020f19c51bc8a3faa27885b0a3fea10001145b0063c74ff489958da563fea300007bbf6fa3c8cbeab8a2b6d183fea500010971d793c88fecadd7879303fea70001df52e48bc8f41763dd8abdb3fea90001c593352bc8ebf0284c276123feab0002a4f3e4bbc69fd043cff3f5f3feacfffd7ae1ed1bc823ee7129070b43feaefffee5104783c6a063ee00edea33feb0fffdb650d5b3c5a06c8381f0ab93feb2ffffeaaca57bc79011e74233c1d3feb4fffd995badcbc79ff1068862a9f3feb7000249e659c3c8aff45d0864f3e3feb8ffff98716403c7cfe7796c2c3f93febafffd204cb4fbc63ff27eef22bc43febcfffd2415c45bc6cffb7ee3bea213febeffff86309dfbc814103972e0b5c3fec0fffe1b576533c8bc16494b76a193fec2ffff1fa57e3bc64feef8d30c6ed3fec4fffdcbfe424bc843f68bcec47753fec6fffed54b9f73c847ea3f053e0ec3fec8fffeb998fd53c7383068df992f13fecb0002125219abc68fd8e64180e043feccfffdd94469c3c8e7ebe1cc7ea723fecefffeafdc4763c8ebe39ad9f88fe3fed1000169af82b3c757d91a8b95a713fed30000d0ff71d3c89c1906970c7da3fed4fffea790fc4bc580e37c558fe0c3fed70002edc87e5bc7f80d64dc10f443fed900021dc82aabc747c8f94fd5c5c3fedafffd86b02833c8c7f1dc521617e3fedd000296c47393c88019eb2ffb1533fedefffe54490f53c6e00d2c652cc893fee0fffcdabf694bc7f8340202d69d23fee2fffdb52c8dd3c7b00c1ca1b08643fee4ffff24216ef3c72ffa8b094ab513fee6fffe88a5e11bc57f673b1efbe593fee9000119eff0dbc84808d5e0bc8013feeafffdfa517443c780006d54320b53feed0001a127fa1bc5002f860565c923feef00007babcc4bc8540445d35e6113fef0ffff57a8d02bc4ffb3139ef91053fef30001ee58ac73c8a81acf27311553fef4ffff58234943c8a3f41d4d7c7433fef6ffffca94c6bbc6202f41c9878753fef8fffe1f9c4413c777dd1f477e74b3fefafffd2e0e37ebc6f01199a7ca3313fefd0001c77e49e3c7181ee4bceacb13fefeffff7e0c331bc6e05370170875a3ff00ffff465606ebc8a7ead491c0ada3ff02ffff3867a58bc977f69c3fcb2e03ff04ffffdfc0d173c97bffe34cb945b3ff0700003cd4d823c820083c0e456cb3ff08ffff9f2cbe8bc6dffdfbe37751a3ff0b000010cda65bc913f7faee626eb3ff0d00001a4d3383c807dfa79489ff73ff0effffadafdfdbc77040570d66bc03ff110000bbafd963c8e80d4846d0b623ff12ffffae5f45d3c9dbffa64fd36ef3ff150000dd59ad93c9a0077701250ae3ff170000f21559a3c8dfdf9e2e3deee3ff18ffffc2754263c910030dc3b72733ff1b000123d3c593c997f79800301883ff1cffff8299eb7bc65f932ab9f8c673ff1effff48ad4003c937fbf9da75beb3ff210000c8b86a43c9f806b91fd5b223ff23000038543033c93ffc2eb9fbf333ff24fffffbcf6843c7601e77e2e2e723ff26ffff52921d93c7ffcbb767f0c613ff2900014933a3cbc7202ca3c02412b3ff2b00014556313bc92808233f21f023ff2cfffebfe523bbc88ff7e384fdcf23ff2f0000bb8ad96bc85ff51503041c53ff30ffffb7ae2afbc810071885e289d3ff32ffffeac5f7fbc91ff5d3fb7b7153ff350000ca667563c957f82228b82bd3ff3700011fbf7213c8000bac40dd5cc3ff38ffff9592fb9bc943f9d2db2a7513ff3b00004ddd2423c857f6b707638e13ff3cffff5b2c9573c7a023a10bf12313ff3efffeab0b4183c987f6d66b152b03ff410001532aff43c67f8375f1985243ff4300017478b293c8301e672dc51433ff44fffe795b4633c89ff69b8b2895a3ff46fffe80475e0bc95c0b19bc2f2543ff48fffef6fc1e73c9b4009f23a2a723ff4afffe5bea704bc94ffb7bf0d7d453ff4d000171027debc99c06471dc6a3d3ff4f0000ff03ee23c977f890b85531c3ff5100012dc4bd13c6004657166a4363ff530001605277abc96bfcece2332093ff54fffecdb704cbc8902720505a1d73ff56fffef5f54a93c9bbfe60ec964123ff5900017e610123c887ec581afef903ff5b00003c93e92bc9f41080abf0cc03ff5d0001d4919bcbc98812afb2547293ff5efffe7b87a89bc947eb780ed6904", 16), 0, i);

	static inline function logPoly1(i:Int):Float
		return Mem.getF64At(Mem.words("bfe00000000000003fd5555555555577bfcffffffffffdcb3fc999999995dd0cbfc55555556745a73fc24924a344de30bfbfffffa4423d653fbc7184282ad6cabfb999eb43b068ff3fb78182f7afd085bfb5521375d145cd", 16), 0, i);

	static inline function logPoly(i:Int):Float
		return Mem.getF64At(Mem.words("bfe00000000000013fd555555551305bbfcfffffffeb45903fc999b324f10111bfc55575e506c89f", 16), 0, i);

	static inline function ipio2(i:Int):Int
		return Mem.getI64At(Mem.words("a2f9836e4e441529fc2757d1f534ddc0db6295993c439041fe5163abdebbc561b7246e3a424dd2e006492eea09d1921cfe1deb1cb129a73ee88235f52ebb4484e99c7026b45f7e413991d639835339f49c845f8bbdf9283b1ff897ffde05980fef2f118b5a0a6d1f6d367ecf27cb09b74f463f669e5fea2d7527bac7ebe5f17b3d0739f78a5292ea6bfb5fb11f8d5d0856033046fc7b6babf0cfbc209af4361da9e391615ee61b086599855f14a068408dffd8804d73273106061556ca73a8c960e27bc08c6b47c419c367cddce8092a8359c4768b961ca6", 6), 0, i).toInt();

	// ---- bits

	static inline function bits(v:Float):I64
		return Mem.f64Bits(v);

	static inline function ofBits(b:I64):Float
		return Mem.bitsF64(b);

	// the high word (as an unsigned 32-bit pattern in an Int)
	static inline function hi(v:Float):Int
		return (bits(v) >>> 32).toInt();

	static inline function lo(v:Float):Int
		return bits(v).toInt();

	// unsigned comparisons of 32-bit patterns
	static inline function ult(a:Int, b:Int):Bool
		return (a ^ 0x80000000) < (b ^ 0x80000000);

	static inline function uge(a:Int, b:Int):Bool
		return !ult(a, b);

	static inline function inf():Float
		return ofBits((0x7FF : I64) << 52);

	// musl's scalbn
	static function scalbn(x:Float, n:Int):Float {
		var y = x;
		if (n > 1023) {
			y *= ofBits((0x7FE : I64) << 52); // 0x1p1023
			n -= 1023;
			if (n > 1023) {
				y *= ofBits((0x7FE : I64) << 52);
				n -= 1023;
				if (n > 1023) n = 1023;
			}
		} else if (n < -1022) {
			// make sure the final n < -53 to avoid double rounding in the subnormal range
			var s = ofBits((0x001 : I64) << 52) * ofBits(((0x3FF + 53) : I64) << 52); // 0x1p-1022 * 0x1p53
			y *= s;
			n += 1022 - 53;
			if (n < -1022) {
				y *= s;
				n += 1022 - 53;
				if (n < -1022) n = -1022;
			}
		}
		return y * ofBits(((0x3ff + n) : I64) << 52);
	}

	// ---- sin, cos, tan (musl: __sin.c, __cos.c, __tan.c, __rem_pio2.c, __rem_pio2_large.c)
	// (the kernels inline, as zig's compiler_rt has them)

	static inline function kcos(x:Float, y:Float):Float {
		var z = x * x;
		var zs = z * z;
		var r = z * (4.16666666666666019037e-02 + z * (-1.38888888888741095749e-03 + z * 2.48015872894767294178e-05))
			+ zs * zs * (-2.75573143513906633035e-07 + z * (2.08757232129817482790e-09 + z * -1.13596475577881948265e-11));
		var hz = 0.5 * z;
		var w = 1.0 - hz;
		return w + (((1.0 - w) - hz) + (z * r - x * y));
	}

	static inline function ksin(x:Float, y:Float, iy:Int):Float {
		var S1 = -1.66666666666666324348e-01;
		var z = x * x;
		var w = z * z;
		var r = 8.33333333332248946124e-03 + z * (-1.98412698298579493134e-04 + z * 2.75573137070700676789e-06)
			+ z * w * (-2.50507602534068634195e-08 + z * 1.58969099521155010221e-10);
		var v = z * x;
		return iy == 0 ? x + v * (S1 + z * r) : x - ((z * (0.5 * y - v * r) - y) - v * S1);
	}

	static inline function ktan(x:Float, y:Float, odd:Bool):Float {
		var pio4 = 7.85398163397448278999e-01;
		var pio4lo = 3.06161699786838301793e-17;
		var hx = hi(x);
		var big = (hx & 0x7fffffff) >= 0x3FE59428;
		var sign = false;
		if (big) {
			sign = (hx >>> 31) != 0;
			if (sign) {
				x = -x;
				y = -y;
			}
			x = (pio4 - x) + (pio4lo - y);
			y = 0.0;
		}
		var z = x * x;
		var w = z * z;
		var r = 1.33333333333201242699e-01
			+ w * (2.18694882948595424599e-02
				+ w * (3.59207910759131235356e-03 + w * (5.88041240820264096874e-04 + w * (7.81794442939557092300e-05 + w * -1.85586374855275456654e-05))));
		var v = z * (5.39682539762260521377e-02
			+ w * (8.86323982359930005737e-03
				+ w * (1.45620945432529025516e-03 + w * (2.46463134818469906812e-04 + w * (7.14072491382608190305e-05 + w * 2.59073051863633712884e-05)))));
		var s = z * x;
		r = y + z * (s * (r + v) + y) + s * 3.33333333333334091986e-01;
		w = x + r;
		if (big) {
			s = odd ? -1.0 : 1.0;
			v = s - 2.0 * (x + (r - w * w / (w + s)));
			w = sign ? -v : v;
		} else if (odd) {
			// -1.0/(x+r) has up to 2ulp error, so compute it accurately
			var w0 = ofBits(bits(w) & ((-1 : I64) << 32));
			v = r - (w0 - x); // w0+v = r+x
			var a = -1.0 / w;
			var a0 = ofBits(bits(a) & ((-1 : I64) << 32));
			w = a0 + a * (1.0 + a0 * w0 + a0 * v);
		}
		return w;
	}

	static inline var PIO2_1 = 1.57079632673412561417e+00;
	static inline var PIO2_1T = 6.07710050650619224932e-11;

	// x reduced by multiples of pi/2: n (the result in y[0], y[1] at yp)
	static inline function medium(ix:Int, x:Float, yp:Ptr):Int {
		var toint = 6755399441055744.0;
		var pio4 = 0.7853981633974483;
		var invpio2 = 6.36619772367581382433e-01;
		var pio2_2 = 6.07710050630396597660e-11;
		var pio2_2t = 2.02226624879595063154e-21;
		var pio2_3 = 2.02226624871116645580e-21;
		var pio2_3t = 8.47842766036889956997e-32;
		// rint(x/(pi/2))
		var fn = x * invpio2 + toint - toint;
		var n = Std.int(fn);
		var r = x - fn * PIO2_1;
		var w = fn * PIO2_1T; // 1st round, good to 85 bits
		// matters with directed rounding
		if (r - w < -pio4) {
			n--;
			fn--;
			r = x - fn * PIO2_1;
			w = fn * PIO2_1T;
		} else if (r - w > pio4) {
			n++;
			fn++;
			r = x - fn * PIO2_1;
			w = fn * PIO2_1T;
		}
		var y0 = r - w;
		var ey = (hi(y0) >>> 20) & 0x7ff;
		var ex = ix >>> 20;
		if (ex - ey > 16) { // 2nd round, good to 118 bits
			var t = r;
			w = fn * pio2_2;
			r = t - w;
			w = fn * pio2_2t - ((t - r) - w);
			y0 = r - w;
			ey = (hi(y0) >>> 20) & 0x7ff;
			if (ex - ey > 49) { // 3rd round, good to 151 bits, covers all cases
				t = r;
				w = fn * pio2_3;
				r = t - w;
				w = fn * pio2_3t - ((t - r) - w);
				y0 = r - w;
			}
		}
		Mem.setF64(yp, 0, y0);
		Mem.setF64(yp, 8, (r - y0) - w);
		return n;
	}

	static function remPio2(x:Float, yp:Ptr):Int {
		var u = bits(x);
		var sign = !((u >>> 63) == 0);
		var ix = (u >>> 32).toInt() & 0x7fffffff;
		inline function set(a:Float, b:Float) {
			Mem.setF64(yp, 0, a);
			Mem.setF64(yp, 8, b);
		}
		// (musl's gotos to medium: one call below)
		if (ix <= 0x400f6a7a && (ix & 0xfffff) != 0x921fb) { // |x| ~<= 5pi/4, not ~= pi/2 or 2pi/2
			if (ix <= 0x4002d97c) { // |x| ~<= 3pi/4
				if (!sign) {
					var z = x - PIO2_1; // one round good to 85 bits
					var y0 = z - PIO2_1T;
					set(y0, (z - y0) - PIO2_1T);
					return 1;
				} else {
					var z = x + PIO2_1;
					var y0 = z + PIO2_1T;
					set(y0, (z - y0) + PIO2_1T);
					return -1;
				}
			} else {
				if (!sign) {
					var z = x - 2 * PIO2_1;
					var y0 = z - 2 * PIO2_1T;
					set(y0, (z - y0) - 2 * PIO2_1T);
					return 2;
				} else {
					var z = x + 2 * PIO2_1;
					var y0 = z + 2 * PIO2_1T;
					set(y0, (z - y0) + 2 * PIO2_1T);
					return -2;
				}
			}
		}
		if (ix > 0x400f6a7a && ix <= 0x401c463b && ix != 0x4012d97c && ix != 0x401921fb) { // |x| ~<= 9pi/4, not ~= 3pi/2 or 4pi/2
			if (ix <= 0x4015fdbc) { // |x| ~<= 7pi/4
				if (!sign) {
					var z = x - 3 * PIO2_1;
					var y0 = z - 3 * PIO2_1T;
					set(y0, (z - y0) - 3 * PIO2_1T);
					return 3;
				} else {
					var z = x + 3 * PIO2_1;
					var y0 = z + 3 * PIO2_1T;
					set(y0, (z - y0) + 3 * PIO2_1T);
					return -3;
				}
			} else {
				if (!sign) {
					var z = x - 4 * PIO2_1;
					var y0 = z - 4 * PIO2_1T;
					set(y0, (z - y0) - 4 * PIO2_1T);
					return 4;
				} else {
					var z = x + 4 * PIO2_1;
					var y0 = z + 4 * PIO2_1T;
					set(y0, (z - y0) + 4 * PIO2_1T);
					return -4;
				}
			}
		}
		if (ix < 0x413921fb) return medium(ix, x, yp); // |x| ~< 2^20*(pi/2), medium size (and the cases above)
		// all other (large) arguments
		if (ix >= 0x7ff00000) { // x is inf or NaN
			set(x - x, x - x);
			return 0;
		}
		return remPio2Large1(x, yp, ix, sign);
	}

	// (apart: remPio2 stays a leaf function, without a frame)
	static function remPio2Large1(x:Float, yp:Ptr, ix:Int, sign:Bool):Int {
		inline function set(a:Float, b:Float) {
			Mem.setF64(yp, 0, a);
			Mem.setF64(yp, 8, b);
		}
		// set z = scalbn(|x|,-ilogb(x)+23)
		var ui = bits(x);
		ui = ui & ((-1 : I64) >>> 12);
		ui = ui | (((0x3ff + 23) : I64) << 52);
		var z = ofBits(ui);
		var tx = Mem.stack(24), ty = Mem.stack(16);
		var i = 0;
		while (i < 2) {
			var t:Float = Std.int(z);
			Mem.setF64(tx, 8 * i, t);
			z = (z - t) * 16777216.0;
			i++;
		}
		Mem.setF64(tx, 8 * i, z);
		// skip zero terms, first term is non-zero
		while (Mem.getF64(tx, 8 * i) == 0.0)
			i--;
		var n = remPio2Large(tx, ty, (ix >>> 20) - (0x3ff + 23), i + 1);
		if (sign) {
			set(-Mem.getF64(ty, 0), -Mem.getF64(ty, 8));
			return -n;
		}
		set(Mem.getF64(ty, 0), Mem.getF64(ty, 8));
		return n;
	}


	// __rem_pio2_large for prec = 1 (doubles): x[nx] (24-bit chunks) in tx, y[2] into ty
	static function remPio2Large(x:Ptr, y:Ptr, e0:Int, nx:Int):Int {
		var PIo2 = Mem.stack(64);
		Mem.setF64(PIo2, 0, 1.57079625129699707031e+00);
		Mem.setF64(PIo2, 8, 7.54978941586159635335e-08);
		Mem.setF64(PIo2, 16, 5.39030252995776476554e-15);
		Mem.setF64(PIo2, 24, 3.28200341580791294123e-22);
		Mem.setF64(PIo2, 32, 1.27065575308067607349e-29);
		Mem.setF64(PIo2, 40, 1.22933308981111328932e-36);
		Mem.setF64(PIo2, 48, 2.73370053816464559624e-44);
		Mem.setF64(PIo2, 56, 2.16741683877804819444e-51);
		var iq = Mem.stack(80), f = Mem.stack(160), fq = Mem.stack(160), q = Mem.stack(160);
		inline function geti(p:Ptr, k:Int):Int
			return Mem.getI32(p, 4 * k);
		inline function seti(p:Ptr, k:Int, v:Int)
			Mem.setI32(p, 4 * k, v);
		inline function getf(p:Ptr, k:Int):Float
			return Mem.getF64(p, 8 * k);
		inline function setf(p:Ptr, k:Int, v:Float)
			Mem.setF64(p, 8 * k, v);
		var jk = 4; // init_jk[prec = 1]
		var jp = jk;
		// determine jx,jv,q0, note that 3>q0
		var jx = nx - 1;
		var jv = e0 - 3;
		jv = jv >= 0 ? Std.int(jv / 24) : -Std.int((-jv + 23) / 24); // floor division
		if (jv < 0) jv = 0;
		var q0 = e0 - 24 * (jv + 1);
		// set up f[0] to f[jx+jk] where f[jx+jk] = ipio2[jv+jk]
		var j = jv - jx;
		var m = jx + jk;
		var i = 0;
		while (i <= m) {
			setf(f, i, j < 0 ? 0.0 : ipio2(j));
			i++;
			j++;
		}
		// compute q[0],q[1],...q[jk]
		i = 0;
		while (i <= jk) {
			var fw = 0.0;
			j = 0;
			while (j <= jx) {
				fw += getf(x, j) * getf(f, jx + i - j);
				j++;
			}
			setf(q, i, fw);
			i++;
		}
		var jz = jk;
		var n = 0, ih = 0;
		var z = 0.0;
		while (true) { // recompute
			// distill q[] into iq[] reversingly
			i = 0;
			j = jz;
			z = getf(q, jz);
			while (j > 0) {
				var fw:Float = Std.int(5.9604644775390625e-08 * z);
				seti(iq, i, Std.int(z - 16777216.0 * fw));
				z = getf(q, j - 1) + fw;
				i++;
				j--;
			}
			// compute n
			z = scalbn(z, q0); // actual value of z
			z -= 8.0 * Math.ffloor(z * 0.125); // trim off integer >= 8
			n = Std.int(z);
			z -= n;
			ih = 0;
			if (q0 > 0) { // need iq[jz-1] to determine n
				i = geti(iq, jz - 1) >> (24 - q0);
				n += i;
				seti(iq, jz - 1, geti(iq, jz - 1) - (i << (24 - q0)));
				ih = geti(iq, jz - 1) >> (23 - q0);
			} else if (q0 == 0)
				ih = geti(iq, jz - 1) >> 23;
			else if (z >= 0.5) ih = 2;
			if (ih > 0) { // q > 0.5
				n += 1;
				var carry = 0;
				i = 0;
				while (i < jz) { // compute 1-q
					j = geti(iq, i);
					if (carry == 0) {
						if (j != 0) {
							carry = 1;
							seti(iq, i, 0x1000000 - j);
						}
					} else
						seti(iq, i, 0xffffff - j);
					i++;
				}
				if (q0 > 0) { // rare case: chance is 1 in 12
					if (q0 == 1) seti(iq, jz - 1, geti(iq, jz - 1) & 0x7fffff);
					if (q0 == 2) seti(iq, jz - 1, geti(iq, jz - 1) & 0x3fffff);
				}
				if (ih == 2) {
					z = 1.0 - z;
					if (carry != 0) z -= scalbn(1.0, q0);
				}
			}
			// check if recomputation is needed
			if (z == 0.0) {
				j = 0;
				i = jz - 1;
				while (i >= jk) {
					j |= geti(iq, i);
					i--;
				}
				if (j == 0) { // need recomputation
					var k = 1;
					while (geti(iq, jk - k) == 0)
						k++; // k = no. of terms needed
					i = jz + 1;
					while (i <= jz + k) { // add q[jz+1] to q[jz+k]
						setf(f, jx + i, ipio2(jv + i));
						var fw = 0.0;
						j = 0;
						while (j <= jx) {
							fw += getf(x, j) * getf(f, jx + i - j);
							j++;
						}
						setf(q, i, fw);
						i++;
					}
					jz += k;
					continue;
				}
			}
			break;
		}
		// chop off zero terms
		if (z == 0.0) {
			jz -= 1;
			q0 -= 24;
			while (geti(iq, jz) == 0) {
				jz--;
				q0 -= 24;
			}
		} else { // break z into 24-bit if necessary
			z = scalbn(z, -q0);
			if (z >= 16777216.0) {
				var fw:Float = Std.int(5.9604644775390625e-08 * z);
				seti(iq, jz, Std.int(z - 16777216.0 * fw));
				jz += 1;
				q0 += 24;
				seti(iq, jz, Std.int(fw));
			} else
				seti(iq, jz, Std.int(z));
		}
		// convert integer "bit" chunk to floating-point value
		var fw = scalbn(1.0, q0);
		i = jz;
		while (i >= 0) {
			setf(q, i, fw * geti(iq, i));
			fw *= 5.9604644775390625e-08;
			i--;
		}
		// compute PIo2[0,...,jp]*q[jz,...,0]
		i = jz;
		while (i >= 0) {
			fw = 0.0;
			var k = 0;
			while (k <= jp && k <= jz - i) {
				fw += getf(PIo2, k) * getf(q, i + k);
				k++;
			}
			setf(fq, jz - i, fw);
			i--;
		}
		// compress fq[] into y[] (prec 1)
		fw = 0.0;
		i = jz;
		while (i >= 0) {
			fw += getf(fq, i);
			i--;
		}
		setf(y, 0, ih == 0 ? fw : -fw);
		fw = getf(fq, 0) - fw;
		i = 1;
		while (i <= jz) {
			fw += getf(fq, i);
			i++;
		}
		setf(y, 1, ih == 0 ? fw : -fw);
		return n & 7;
	}

	@:hxmc.host("Math_sin") static function sin(x:Float):Float {
		var ix = hi(x) & 0x7fffffff;
		// |x| ~< pi/4
		if (ix <= 0x3fe921fb) {
			if (ix < 0x3e500000) return x; // |x| < 2**-26
			return ksin(x, 0.0, 0);
		}
		// sin(Inf or NaN) is NaN
		if (ix >= 0x7ff00000) return x - x;
		var y = Mem.stack(16);
		var n = remPio2(x, y);
		var y0 = Mem.getF64(y, 0), y1 = Mem.getF64(y, 8);
		return switch n & 3 {
			case 0: ksin(y0, y1, 1);
			case 1: kcos(y0, y1);
			case 2: -ksin(y0, y1, 1);
			case _: -kcos(y0, y1);
		}
	}

	@:hxmc.host("Math_cos") static function cos(x:Float):Float {
		var ix = hi(x) & 0x7fffffff;
		// |x| ~< pi/4
		if (ix <= 0x3fe921fb) {
			if (ix < 0x3e46a09e) return 1.0; // |x| < 2**-27 * sqrt(2)
			return kcos(x, 0);
		}
		// cos(Inf or NaN) is NaN
		if (ix >= 0x7ff00000) return x - x;
		var y = Mem.stack(16);
		var n = remPio2(x, y);
		var y0 = Mem.getF64(y, 0), y1 = Mem.getF64(y, 8);
		return switch n & 3 {
			case 0: kcos(y0, y1);
			case 1: -ksin(y0, y1, 1);
			case 2: -kcos(y0, y1);
			case _: ksin(y0, y1, 1);
		}
	}

	@:hxmc.host("Math_tan") static function tan(x:Float):Float {
		var ix = hi(x) & 0x7fffffff;
		// |x| ~< pi/4
		if (ix <= 0x3fe921fb) {
			if (ix < 0x3e400000) return x; // |x| < 2**-27
			return ktan(x, 0.0, false);
		}
		// tan(Inf or NaN) is NaN
		if (ix >= 0x7ff00000) return x - x;
		var y = Mem.stack(16);
		var n = remPio2(x, y);
		return ktan(Mem.getF64(y, 0), Mem.getF64(y, 8), (n & 1) != 0);
	}

	// ---- asin, acos (zig std.math: musl's asin.c, acos.c), atan, atan2 (musl's)

	static inline function asinR(z:Float):Float {
		var p = z * (1.66666666666666657415e-01
			+ z * (-3.25565818622400915405e-01
				+ z * (2.01212532134862925881e-01 + z * (-4.00555345006794114027e-02 + z * (7.91534994289814532176e-04 + z * 3.47933107596021167570e-05)))));
		var q = 1.0 + z * (-2.40339491173441421878e+00 + z * (2.02094576023350569471e+00 + z * (-6.88283971605453293030e-01 + z * 7.70381505559019352791e-02)));
		return p / q;
	}

	static inline var PIO2_HI = 1.57079632679489655800e+00;
	static inline var PIO2_LO = 6.12323399573676603587e-17;

	@:hxmc.host("Math_asin") static function asin(x:Float):Float {
		var hx = hi(x);
		var ix = hx & 0x7fffffff;
		// |x| >= 1 or nan
		if (ix >= 0x3ff00000) {
			// asin(1) = +-pi/2 with inexact
			if (((ix - 0x3ff00000) | lo(x)) == 0) return x * PIO2_HI + 7.52316384526264005099991383822e-37;
			return 0.0 / (x - x);
		}
		// |x| < 0.5
		if (ix < 0x3fe00000) {
			// if 0x1p-1022 <= |x| < 0x1p-26 avoid raising overflow
			if (ix < 0x3e500000 && ix >= 0x00100000) return x;
			return x + x * asinR(x * x);
		}
		// 1 > |x| >= 0.5
		var z = (1.0 - Math.abs(x)) * 0.5;
		var s = Math.sqrt(z);
		var r = asinR(z);
		var res:Float;
		if (ix >= 0x3fef3333) { // |x| > 0.975
			res = PIO2_HI - (2 * (s + s * r) - PIO2_LO);
		} else {
			// f+c = sqrt(z)
			var f = ofBits(bits(s) & ((-1 : I64) << 32));
			var c = (z - f * f) / (s + f);
			res = 0.5 * PIO2_HI - (2.0 * s * r - (PIO2_LO - 2.0 * c) - (0.5 * PIO2_HI - 2.0 * f));
		}
		return (hx >>> 31) != 0 ? -res : res;
	}

	@:hxmc.host("Math_acos") static function acos(x:Float):Float {
		var hx = hi(x);
		var ix = hx & 0x7fffffff;
		// |x| >= 1 or nan
		if (ix >= 0x3ff00000) {
			if (((ix - 0x3ff00000) | lo(x)) == 0) {
				if ((hx >>> 31) != 0) return 2.0 * PIO2_HI + 7.52316384526264005099991383822e-37;
				return 0.0;
			}
			return 0.0 / (x - x);
		}
		// |x| < 0.5
		if (ix < 0x3fe00000) {
			if (ix <= 0x3c600000) return PIO2_HI + 7.52316384526264005099991383822e-37; // |x| < 2^(-57)
			return PIO2_HI - (x - (PIO2_LO - x * asinR(x * x)));
		}
		// x < -0.5
		if ((hx >>> 31) != 0) {
			var z = (1.0 + x) * 0.5;
			var s = Math.sqrt(z);
			var w = asinR(z) * s - PIO2_LO;
			return 2 * (PIO2_HI - (s + w));
		}
		// x > 0.5
		var z = (1.0 - x) * 0.5;
		var s = Math.sqrt(z);
		var df = ofBits(bits(s) & ((-1 : I64) << 32));
		var c = (z - df * df) / (s + df);
		var w = asinR(z) * s + c;
		return 2.0 * (df + w);
	}

	@:hxmc.host("Math_atan") static function atan(x:Float):Float {
		var u = bits(x);
		var ix = (u >>> 32).toInt() & 0x7fffffff;
		var sign = !((u >>> 63) == 0);
		// |x| >= 2^66
		if (ix >= 0x44100000) {
			if (x != x) return x;
			var z = 1.57079632679489655800e+00 + 7.52316384526264005099991383822e-37;
			return sign ? -z : z;
		}
		var id = -1;
		var xr = x;
		// (atanhi[id], atanlo[id])
		var ahi = 0.0, alo = 0.0;
		if (ix < 0x3fdc0000) { // |x| < 0.4375
			if (ix < 0x3e400000) return x; // |x| < 2^(-27)
		} else {
			var xa = Math.abs(x);
			if (ix < 0x3ff30000) { // |x| < 1.1875
				if (ix < 0x3fe60000) { // 7/16 <= |x| < 11/16
					xr = (2.0 * xa - 1.0) / (2.0 + xa);
					id = 0;
					ahi = 4.63647609000806093515e-01;
					alo = 2.26987774529616870924e-17;
				} else { // 11/16 <= |x| < 19/16
					xr = (xa - 1.0) / (xa + 1.0);
					id = 1;
					ahi = 7.85398163397448278999e-01;
					alo = 3.06161699786838301793e-17;
				}
			} else {
				if (ix < 0x40038000) { // |x| < 2.4375
					xr = (xa - 1.5) / (1.0 + 1.5 * xa);
					id = 2;
					ahi = 9.82793723247329054082e-01;
					alo = 1.39033110312309984516e-17;
				} else { // 2.4375 <= |x| < 2^66
					xr = -1.0 / xa;
					id = 3;
					ahi = 1.57079632679489655800e+00;
					alo = 6.12323399573676603587e-17;
				}
			}
		}
		// end of argument reduction
		var z = xr * xr;
		var w = z * z;
		// break sum from i=0 to 10 aT[i]z^(i+1) into odd and even poly
		var s1 = z * (3.33333333333329318027e-01
			+ w * (1.42857142725034663711e-01
				+ w * (9.09088713343650656196e-02 + w * (6.66107313738753120669e-02 + w * (4.97687799461593236017e-02 + w * 1.62858201153657823623e-02)))));
		var s2 = w * (-1.99999999998764832476e-01
			+ w * (-1.11111104054623557880e-01 + w * (-7.69187620504482999495e-02 + w * (-5.83357013379057348645e-02 + w * -3.65315727442169155270e-02))));
		if (id < 0) return xr - xr * (s1 + s2);
		var zr = ahi - (xr * (s1 + s2) - alo - xr);
		return sign ? -zr : zr;
	}

	@:hxmc.host("Math_atan2") static function atan2(y:Float, x:Float):Float {
		var pi = 3.1415926535897931160E+00;
		var pi_lo = 1.2246467991473531772E-16;
		if (x != x || y != y) return x + y;
		var ix = hi(x), lx = lo(x);
		var iy = hi(y), ly = lo(y);
		if (((ix - 0x3ff00000) | lx) == 0) return atan(y); // x = 1.0
		var m = ((iy >>> 31) & 1) | ((ix >>> 30) & 2); // 2*sign(x)+sign(y)
		ix = ix & 0x7fffffff;
		iy = iy & 0x7fffffff;
		// when y = 0
		if ((iy | ly) == 0) {
			switch m {
				case 0 | 1:
					return y; // atan(+-0,+anything)=+-0
				case 2:
					return pi; // atan(+0,-anything) = pi
				case _:
					return -pi; // atan(-0,-anything) =-pi
			}
		}
		// when x = 0
		if ((ix | lx) == 0) return (m & 1) != 0 ? -pi / 2 : pi / 2;
		// when x is INF
		if (ix == 0x7ff00000) {
			if (iy == 0x7ff00000) {
				switch m {
					case 0:
						return pi / 4; // atan(+INF,+INF)
					case 1:
						return -pi / 4; // atan(-INF,+INF)
					case 2:
						return 3 * pi / 4; // atan(+INF,-INF)
					case _:
						return -3 * pi / 4; // atan(-INF,-INF)
				}
			} else {
				switch m {
					case 0:
						return 0.0; // atan(+...,+INF)
					case 1:
						return -0.0; // atan(-...,+INF)
					case 2:
						return pi; // atan(+...,-INF)
					case _:
						return -pi; // atan(-...,-INF)
				}
			}
		}
		// |y/x| > 0x1p64
		if (ult(ix + (64 << 20), iy) || iy == 0x7ff00000) return (m & 1) != 0 ? -pi / 2 : pi / 2;
		// z = atan(|y/x|) without spurious underflow
		var z:Float;
		if ((m & 2) != 0 && ult(iy + (64 << 20), ix)) z = 0; // |y/x| < 0x1p-64, x<0
		else z = atan(Math.abs(y / x));
		return switch m {
			case 0: z; // atan(+,+)
			case 1: -z; // atan(-,+)
			case 2: pi - (z - pi_lo); // atan(+,-)
			case _: (z - pi_lo) - pi; // atan(-,-)
		}
	}

	// ---- exp (zig's exp: musl's former exp.c), log (musl's log.c)

	@:hxmc.host("Math_exp") static function exp(x:Float):Float {
		var ln2hi = 6.93147180369123816490e-01;
		var ln2lo = 1.90821492927058770002e-10;
		var invln2 = 1.44269504088896338700e+00;
		var hx = hi(x);
		var sign = hx >>> 31;
		hx = hx & 0x7FFFFFFF;
		if (x != x) return x;
		// |x| >= 708.39 or nan
		if (hx >= 0x4086232B) {
			if (hx > 0x7FF00000) return x; // nan
			if (x > 709.782712893383973096) return inf(); // overflow
			if (x < -708.39641853226410622) {
				if (x < -745.13321910194110842) return 0;
			}
		}
		// argument reduction
		var k = 0;
		var hi_ = 0.0, lo_ = 0.0;
		if (hx > 0x3FD62E42) { // |x| > 0.5 * ln2
			if (hx > 0x3FF0A2B2) // |x| >= 1.5 * ln2
				// (copysign(0.5, x) for musl's half[sign]: no branch on the
				// sign, which random signs mispredict half the time)
				k = Std.int(invln2 * x + ofBits(bits(0.5) | (bits(x) & ((1 : I64) << 63))));
			else
				k = 1 - sign - sign;
			var dk:Float = k;
			hi_ = x - dk * ln2hi;
			lo_ = dk * ln2lo;
			x = hi_ - lo_;
		} else if (hx > 0x3E300000) { // |x| > 2^(-28)
			k = 0;
			hi_ = x;
			lo_ = 0;
		} else
			return 1 + x;
		var xx = x * x;
		var c = x - xx * (1.66666666666666019037e-01
			+ xx * (-2.77777777770155933842e-03 + xx * (6.61375632143793436117e-05 + xx * (-1.65339022054652515390e-06 + xx * 4.13813679705723846039e-08))));
		var y = 1 + (x * c / (2 - c) - lo_ + hi_);
		// (scalbn's common case inline: one multiplication by 2^k, exact;
		// y * 1.0 is y for k == 0)
		return k >= -1022 && k <= 1023 ? y * ofBits(((0x3ff + k) : I64) << 52) : scalbn(y, k);
	}

	@:hxmc.host("Math_log") static function log(x:Float):Float {
		var ix = bits(x);
		var LO = bits(1.0 - 0.0625);
		var HI = bits(1.0 + 0.064697265625); // 1.0 + 0x1.09p-4
		if (!(ix < LO) && ix < HI) {
			if (ix == bits(1.0)) return 0;
			var r = x - 1;
			var r2 = r * r;
			var r3 = r * r2;
			inline function p1(i:Int):Float
				return logPoly1(i);
			var y = r3 * (p1(1) + r * p1(2) + r2 * p1(3) + r3 * (p1(4) + r * p1(5) + r2 * p1(6) + r3 * (p1(7) + r * p1(8) + r2 * p1(9) + r3 * p1(10))));
			var w = r * 134217728.0; // 0x1p27
			var rhi = r + w - w;
			var rlo = r - rhi;
			w = rhi * rhi * p1(0);
			var hi_ = r + w;
			var lo_ = r - hi_ + w + p1(0) * rlo * (rhi + r);
			return y + lo_ + hi_;
		}
		var top = (ix >>> 48).toInt();
		if (top < 0x0010 || 0x7ff0 <= top) {
			if ((ix << 1) == 0) return -inf();
			if (ix == bits(inf())) return x;
			if ((top & 0x8000) != 0 || (top & 0x7ff0) == 0x7ff0) return (x - x) / 0.0;
			ix = bits(x * 4503599627370496.0) - ((52 : I64) << 52); // x * 0x1p52
		}
		var tmp = ix - ((0x3fe60000 : I64) << 32);
		var i = ((tmp >>> 45) & 127).toInt();
		var k = (tmp >> 52).toInt();
		var iz = ix - (tmp & (((0xfff : I64)) << 52));
		var invc = logTab(2 * i);
		var logc = logTab(2 * i + 1);
		var z = ofBits(iz);
		var r = (z - logTab2(2 * i) - logTab2(2 * i + 1)) * invc;
		var kd:Float = k;
		var w = kd * 0.6931471805598903 + logc;
		var hi_ = w + r;
		var lo_ = w - hi_ + r + kd * 5.497923018708371e-14;
		var r2 = r * r;
		inline function p(i:Int):Float
			return logPoly(i);
		return lo_ + r2 * p(0) + r * r2 * (p(1) + r * p(2) + r2 * (p(3) + r * p(4))) + hi_;
	}

	// ---- pow (musl's pow.c, ARM's optimized routines)

	static inline function top12(x:Float):Int
		return (bits(x) >>> 52).toInt();

	// log(x) for the bits ix of x (normalized): hi, and its tail at *tail
	// (inline, as musl's static inline log_inline)
	static inline function logInline(ix:I64, tail:Ptr):Float {
		var OFF = ((0x3fe69555 : I64) << 32);
		var tmp = ix - OFF;
		var i = ((tmp >>> 45) & 127).toInt();
		var k = (tmp >> 52).toInt(); // arithmetic shift
		var iz = ix - (tmp & ((0xfff : I64) << 52));
		var z = ofBits(iz);
		var kd:Float = k;
		// log(x) = k*Ln2 + log(c) + log1p(z/c-1)
		var invc = powTab(3 * i);
		var logc = powTab(3 * i + 1);
		var logctail = powTab(3 * i + 2);
		// split z such that rhi, rlo and rhi*rhi are exact and |rlo| <= |r|
		var zhi = ofBits((iz + ((1 : I64) << 31)) & ((-1 : I64) << 32));
		var zlo = z - zhi;
		var rhi = zhi * invc - 1.0;
		var rlo = zlo * invc;
		var r = rhi + rlo;
		// k*Ln2 + log(c) + r
		var t1 = kd * 0.6931471805598903 + logc;
		var t2 = t1 + r;
		var lo1 = kd * 5.497923018708371e-14 + logctail;
		var lo2 = t1 - t2 + r;
		inline function A(i:Int):Float
			return powPoly(i);
		var ar = A(0) * r; // A[0] = -0.5
		var ar2 = r * ar;
		var ar3 = r * ar2;
		// k*Ln2 + log(c) + r + A[0]*r*r
		var arhi = A(0) * rhi;
		var arhi2 = rhi * arhi;
		var hi_ = t2 + arhi2;
		var lo3 = rlo * (ar + arhi);
		var lo4 = t2 - hi_ + arhi2;
		// p = log1p(r) - r - A[0]*r*r
		var p = ar3 * (A(1) + r * A(2) + ar2 * (A(3) + r * A(4) + ar2 * (A(5) + r * A(6))));
		var lo_ = lo1 + lo2 + lo3 + lo4 + p;
		var y = hi_ + lo_;
		Mem.setF64(tail, 0, hi_ - y + lo_);
		return y;
	}

	static function specialcase(tmp:Float, sbits:I64, ki:I64):Float {
		if ((ki & ((1 : I64) << 31)) == 0) {
			// k > 0, the exponent of scale might have overflowed by <= 460
			sbits = sbits - ((1009 : I64) << 52);
			var scale = ofBits(sbits);
			return ofBits(((0x3ff + 1009) : I64) << 52) * (scale + scale * tmp); // 0x1p1009
		}
		// k < 0, need special care in the subnormal range
		sbits = sbits + ((1022 : I64) << 52);
		var scale = ofBits(sbits);
		var y = scale + scale * tmp;
		if (Math.abs(y) < 1.0) {
			var one = y < 0.0 ? -1.0 : 1.0;
			var lo_ = scale - y + scale * tmp;
			var hi_ = one + y;
			lo_ = one - hi_ + y + lo_;
			y = (hi_ + lo_) - one;
			// fix the sign of 0
			if (y == 0.0) y = ofBits(sbits & ((1 : I64) << 63));
		}
		return ofBits((1 : I64) << 52) * y; // 0x1p-1022
	}

	static inline var SIGN_BIAS = 0x800 << 7;

	// (inline, as musl's static inline exp_inline; its rare cases apart)
	static inline function expInline(x:Float, xtail:Float, signBias:Int):Float {
		var abstop = top12(x) & 0x7ff;
		var small = top12(5.551115123125783e-17); // 0x1p-54
		// large x is special cased below (specialcase)
		var large = uge(abstop - small, top12(512.0) - small);
		return large && (uge(abstop - small, 0x80000000) || abstop >= top12(1024.0)) ? expEdge(x, signBias) : expTail(x, xtail, signBias, large);
	}

	// exp_inline for tiny x, and for huge x (inf and nan are already handled)
	static function expEdge(x:Float, signBias:Int):Float {
		var abstop = top12(x) & 0x7ff;
		var small = top12(5.551115123125783e-17); // 0x1p-54
		if (uge(abstop - small, 0x80000000)) {
			// avoid spurious underflow for tiny x; 0 is common input
			var one = 1.0 + x;
			return signBias != 0 ? -one : one;
		}
		if (!((bits(x) >>> 63) == 0)) return signBias != 0 ? -0.0 : 0.0; // __math_uflow
		return signBias != 0 ? -inf() : inf(); // __math_oflow
	}

	static inline function expTail(x:Float, xtail:Float, signBias:Int, large:Bool):Float {
		// exp(x) = 2^(k/N) * exp(r), with exp(r) in [2^(-1/2N),2^(1/2N)]
		var z = 184.6649652337873 * x; // InvLn2N
		var shift = 6755399441055744.0;
		var kd = z + shift;
		var ki = bits(kd);
		kd -= shift;
		var r = x + kd * -0.005415212348111709 + kd * -1.2864023111638346e-14;
		// the code assumes 2^-200 < |xtail| < 2^-8/N
		r += xtail;
		// 2^(k/N) ~= scale * (1 + tail)
		var idx = 2 * (ki & 127).toInt();
		var top = (ki + signBias) << (52 - 7);
		var tail = ofBits(expTab(idx));
		// this is only a valid scale when -1023*N < k < 1024*N
		var sbits = expTab(idx + 1) + top;
		// exp(x) = 2^(k/N) * exp(r) ~= scale + scale * (tail + exp(r) - 1)
		var r2 = r * r;
		inline function C(i:Int):Float
			return expPoly(i);
		var tmp = tail + r + r2 * (C(0) + r * C(1)) + r2 * r2 * (C(2) + r * C(3));
		var scale = ofBits(sbits);
		return large ? specialcase(tmp, sbits, ki) : scale + scale * tmp;
	}

	// 0 if not int, 1 if odd int, 2 if even int (iy: a non-zero finite double)
	static function checkint(iy:I64):Int {
		var e = ((iy >>> 52) & 0x7ff).toInt();
		if (e < 0x3ff) return 0;
		if (e > 0x3ff + 52) return 2;
		if (!((iy & (((1 : I64) << (0x3ff + 52 - e)) - 1)) == 0)) return 0;
		if (!((iy & ((1 : I64) << (0x3ff + 52 - e))) == 0)) return 1;
		return 2;
	}

	// 0, infinity or nan
	static inline function zeroinfnan(i:I64):Bool
		return !Mem.ult(i * 2 - 1, bits(inf()) * 2 - 1);

	@:hxmc.host("Math_pow") static function pow(x:Float, y:Float):Float {
		var topx = top12(x), topy = top12(y);
		// (the special cases apart: nothing lives across a call here)
		if (uge(topx - 0x001, 0x7ff - 0x001) || uge((topy & 0x7ff) - 0x3be, 0x43e - 0x3be)) return powSpecial(x, y);
		return powCore(bits(x), y, 0);
	}

	// pow for (x < 0x1p-126 or inf or nan) or (|y| < 0x1p-65 or |y| >= 0x1p63 or nan)
	static function powSpecial(x:Float, y:Float):Float {
		var signBias = 0;
		var ix = bits(x), iy = bits(y);
		var topx = top12(x), topy = top12(y);
		if (zeroinfnan(iy)) {
			if (iy * 2 == 0) return 1.0;
			if (ix == bits(1.0)) return 1.0;
			if (Mem.ult(bits(inf()) * 2, ix * 2) || Mem.ult(bits(inf()) * 2, iy * 2)) return x + y;
			if (ix * 2 == bits(1.0) * 2) return 1.0;
			if (Mem.ult(ix * 2, bits(1.0) * 2) == ((iy >>> 63) == 0)) return 0.0; // |x|<1 && y==inf or |x|>1 && y==-inf
			return y * y;
		}
		if (zeroinfnan(ix)) {
			var x2 = x * x;
			if (!((ix >>> 63) == 0) && checkint(iy) == 1) x2 = -x2;
			return !((iy >>> 63) == 0) ? 1 / x2 : x2;
		}
		// here x and y are non-zero finite
		if (!((ix >>> 63) == 0)) {
			// finite x < 0
			var yint = checkint(iy);
			if (yint == 0) return (x - x) / (x - x); // __math_invalid
			if (yint == 1) signBias = SIGN_BIAS;
			ix = ix & ((-1 : I64) >>> 1);
			topx = topx & 0x7ff;
		}
		if (uge((topy & 0x7ff) - 0x3be, 0x43e - 0x3be)) {
			// note: sign_bias == 0 here because y is not odd
			if (ix == bits(1.0)) return 1.0;
			if ((topy & 0x7ff) < 0x3be) {
				// |y| < 2^-65, x^y ~= 1 + y*log(x)
				return Mem.ult(bits(1.0), ix) ? 1.0 + y : 1.0 - y;
			}
			return (Mem.ult(bits(1.0), ix)) == (topy < 0x800) ? inf() : 0.0;
		}
		if (topx == 0) {
			// normalize subnormal x so exponent becomes negative
			ix = bits(x * 4503599627370496.0);
			ix = ix & ((-1 : I64) >>> 1);
			ix = ix - ((52 : I64) << 52);
		}
		return powCore(ix, y, signBias);
	}

	// x^y from the bits of x (normalized, made positive)
	static inline function powCore(ix:I64, y:Float, signBias:Int):Float {
		var iy = bits(y);
		var lop = Mem.stack(8);
		var hi_ = logInline(ix, lop);
		var lo_ = Mem.getF64(lop, 0);
		var yhi = ofBits(iy & ((-1 : I64) << 27));
		var ylo = y - yhi;
		var lhi = ofBits(bits(hi_) & ((-1 : I64) << 27));
		var llo = hi_ - lhi + lo_;
		var ehi = yhi * lhi;
		var elo = ylo * lhi + y * llo; // |elo| < |ehi| * 2^-25
		return expInline(ehi, elo, signBias);
	}

	// musl's fmod (src/math/fmod.c)
	@:hxmc.host("fmod") static function fmod(x:Float, y:Float):Float {
		var ux = bits(x), uy = bits(y);
		var ex = ((ux >>> 52) & 0x7ff).toInt();
		var ey = ((uy >>> 52) & 0x7ff).toInt();
		var sx = ux >>> 63;
		var uxi = ux;
		if ((uy << 1) == 0 || y != y || ex == 0x7ff) return (x * y) / (x * y);
		if (Mem.ult(ux << 1, uy << 1) || (ux << 1) == (uy << 1)) {
			if ((ux << 1) == (uy << 1)) return 0 * x;
			return x;
		}
		// normalize x and y
		if (ex == 0) {
			var i = uxi << 12;
			while ((i >>> 63) == 0) {
				ex--;
				i = i << 1;
			}
			uxi = uxi << (-ex + 1);
		} else {
			uxi = uxi & ((-1 : I64) >>> 12);
			uxi = uxi | ((1 : I64) << 52);
		}
		if (ey == 0) {
			var i = uy << 12;
			while ((i >>> 63) == 0) {
				ey--;
				i = i << 1;
			}
			uy = uy << (-ey + 1);
		} else {
			uy = uy & ((-1 : I64) >>> 12);
			uy = uy | ((1 : I64) << 52);
		}
		// x mod y (`if (i >> 63 == 0) { if (i == 0) return 0*x; uxi = i; }`
		// without a branch on the sign: a mask, as C compilers make it)
		while (ex > ey) {
			var i = uxi - uy;
			if (i == 0) return 0 * x;
			var neg = i >> 63;
			uxi = (i & ~neg) | (uxi & neg);
			uxi = uxi << 1;
			ex--;
		}
		var i = uxi - uy;
		if (i == 0) return 0 * x;
		var neg = i >> 63;
		uxi = (i & ~neg) | (uxi & neg);
		while ((uxi >>> 52) == 0) {
			uxi = uxi << 1;
			ex--;
		}
		// scale result
		if (ex > 0) {
			uxi = uxi - ((1 : I64) << 52);
			uxi = uxi | ((ex : I64) << 52);
		} else
			uxi = uxi >>> (-ex + 1);
		uxi = uxi | (sx << 63);
		return ofBits(uxi);
	}
}
