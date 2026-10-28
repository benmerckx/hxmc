#!/bin/sh
# Builds the runtime objects of an hxmc target (docs/hxmc.md): the
# runtime is Haxe (hxmc/std/hxmc/rt); rt.o is the parts of the C library
# that generated code and the runtime's Haxe code call (musl's members and
# its startup object on Linux; glibc's import table and libc_nonshared's
# members in Linux's dynamic glibc mode, <target>-glibc; the C runtime's
# startup objects, MinGW-w64's members and the UCRT's imports on Windows;
# nothing on macOS, whose C
# library is libSystem, bound at load time; Bionic's import table and
# compiler-rt's helpers on Android, android-*), partially linked (ld -r) into
# one relocatable object bin/hxmc/rt/<target>/rt.o, which hxmc's linker then
# links with the program (and lays out once, see Link.hx). Next to it, ssl.o
# and uv.o: mbedtls and libuv (which hxmc/std/hxmc/rt/Ssl.hx and Uv.hx call),
# linked only into programs that refer to them, from the libraries
# hxmc/deps/deps.sh built into bin/hxmc/deps/<target> (DEPS); without them,
# neither.
# zig must be the version of hxmc/deps/zig-version (the objects are published
# by a hash of hxmc/deps: hxmc/bootstrap/rt.mjs).
#   sh hxmc/deps/mkrt.sh linux-x86_64
set -eu
target=$1
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ZIG=${ZIG:-zig}
want=$(cat "$ROOT/hxmc/deps/zig-version")
[ "$($ZIG version)" = "$want" ] || echo "mkrt: zig $($ZIG version), hxmc/deps/zig-version says $want" >&2
case $target in
linux-x86_64) triple=x86_64-linux-musl ;;
linux-arm64) triple=aarch64-linux-musl ;;
linux-x86_64-glibc) triple=x86_64-linux-gnu.2.17 ;;
linux-arm64-glibc) triple=aarch64-linux-gnu.2.17 ;;
windows-x86_64) triple=x86_64-windows-gnu ;;
windows-arm64) triple=aarch64-windows-gnu ;;
macos-x86_64) triple=x86_64-macos ;;
macos-arm64) triple=aarch64-macos ;;
android-arm64) triple=aarch64-linux-android.29 ;;
android-x86_64) triple=x86_64-linux-android.29 ;;
*) echo "mkrt: unknown target $target" >&2; exit 1 ;;
esac
out=$ROOT/bin/hxmc/rt/$target
deps=${DEPS:-$ROOT/bin/hxmc/deps/$target}
mkdir -p "$out/obj"
# mbedtls and libuv themselves, when deps.sh built them
if [ -f "$deps/VERSIONS" ]; then
	sslar="$deps/lib/libmbedtls.a $deps/lib/libmbedx509.a $deps/lib/libmbedcrypto.a"
	uvar="$deps/lib/libuv.a"
	cp "$deps/LICENSE.mbedtls" "$deps/LICENSE.libuv" "$out/.."/
else
	echo "mkrt: no $deps/VERSIONS (hxmc/deps/deps.sh): no ssl.o and uv.o" >&2
	sslar=
	uvar=
fi
rm -f "$out/ssl.o" "$out/uv.o" "$out/obj/ssl.undef" "$out/obj/uv.undef"
# the functions the runtime's Haxe code declares (its externs of mbedtls and
# libuv, hxmc/std/hxmc/rt/Ssl.hx and Uv.hx) are the roots of ssl.o and uv.o
sslroots=; for f in $(grep -o 'static function mbedtls_[a-z0-9_]*' "$ROOT/hxmc/std/hxmc/rt/Ssl.hx" | sed 's/static function //' | sort -u) mbedtls_entropy_func mbedtls_ctr_drbg_random; do sslroots="$sslroots -u $f"; done
uvroots=; for f in $(grep -o 'static function uv_[a-z0-9_]*' "$ROOT/hxmc/std/hxmc/rt/Uv.hx" | sed 's/static function //' | sort -u); do uvroots="$uvroots -u $f"; done
# what generated code calls in the C library (MirBuild), and what the
# runtime's Haxe code calls (hxmc/std/hxmc/unsafe/LibC.hx; the collector and
# the threads: hxmc/std/hxmc/rt/Os.hx, Threads.hx, Start.hx); no math: Math
# is Haxe (hxmc/std/hxmc/rt/LibM.hx) and instructions
libc="memset memcpy"
libc="$libc memmove memcmp strlen strcmp malloc free strtod rand clock_gettime mktime"
libc="$libc getenv exit fflush atexit nanosleep"
case $target in
windows-*)
	libc="$libc _mktime64 _localtime64_s _gmtime64_s"
	# hxmc/std/hxmc/unsafe/Win32.hx (the UCRT's part; kernel32's are imports)
	libc="$libc _write _read _close _wopen _lseeki64 _telli64 _fstat64 _wstat64 _wgetenv _wputenv_s _wgetcwd _wchdir"
	libc="$libc _wsystem _wmkdir _wunlink _wrmdir _getch _getche _errno _open_osfhandle _get_osfhandle fflush exit realloc"
	libc="$libc GetEnvironmentStringsW FreeEnvironmentStringsW Sleep GetSystemTimePreciseAsFileTime GetProcessTimes"
	libc="$libc GetCurrentProcess GetModuleFileNameW GetStdHandle GetFileType GetFileAttributesW SetFileAttributesW MoveFileExW"
	libc="$libc RemoveDirectoryW FindFirstFileW FindNextFileW FindClose GetLastError GetFullPathNameW DuplicateHandle CloseHandle"
	libc="$libc SearchPathW CreateFileW CreatePipe CreateProcessW WaitForSingleObject GetExitCodeProcess TerminateProcess"
	# hxmc/std/hxmc/unsafe/Winsock.hx
	libc="$libc socket closesocket accept bind connect listen getsockname getpeername getsockopt setsockopt recv send"
	libc="$libc select shutdown ioctlsocket gethostname gethostbyname gethostbyaddr WSAGetLastError SetHandleInformation"
	libc="$libc strerror _strdup _setmode"
	case $target in windows-arm64) libc="$libc __mingw_longjmp" ;; *) libc="$libc longjmp" ;; esac ;;
*)
	libc="$libc localtime_r gmtime_r"
	# hxmc/std/hxmc/unsafe/Posix.hx
	libc="$libc write read open close lseek fcntl pipe dup2 isatty tcgetattr tcsetattr getenv setenv unsetenv getcwd chdir"
	libc="$libc nanosleep gettimeofday clock readlink realpath system fork execvp _exit exit fflush waitpid kill mkdir"
	libc="$libc unlink rmdir rename stat fstat opendir readdir closedir realloc environ"
	libc="$libc socket bind connect accept listen getsockname getpeername getsockopt setsockopt recv send select"
	libc="$libc shutdown signal strerror gethostname gethostbyname gethostbyaddr strdup sched_yield"
	# hxmc/std/hxmc/rt/Os.hx, Start.hx
	libc="$libc sysconf mmap munmap mprotect madvise poll _longjmp"
	libc="$libc pthread_mutex_init pthread_mutex_destroy pthread_mutex_lock pthread_mutex_trylock pthread_mutex_unlock"
	libc="$libc pthread_condattr_init pthread_condattr_setclock pthread_cond_init pthread_cond_destroy pthread_cond_wait"
	libc="$libc pthread_cond_timedwait pthread_cond_signal pthread_cond_broadcast pthread_attr_init pthread_attr_destroy"
	libc="$libc pthread_attr_setstacksize pthread_attr_setdetachstate pthread_create"
	case $target in linux-*) libc="$libc __errno_location" ;; android-*) libc="$libc __errno __cxa_atexit" ;; esac
	# the system's random bytes, for programs and the C they link (musl's
	# since 1.1.20; Bionic exports them, macOS's libSystem has getentropy;
	# glibc 2.17, the dynamic mode's floor, has neither: syscall(2) there)
	case $target in linux-x86_64|linux-arm64) libc="$libc getentropy getrandom" ;; esac ;;
esac
case $target in
android-*)
	# Android (Abi.android: a shared library NativeActivity loads): no member
	# of the C library; everything Bionic's libc.so, libm.so and libdl.so
	# export to apps of API 29 (hxmc's floor) is an import, with the version
	# of its block in Bionic's version scripts (LIBC, LIBC_N, ..., LIBC_Q;
	# their arch and introduced= tags applied; deps.sh fetched them with the
	# headers), bound by Bionic's linker at load time. rt.o holds the import
	# table (.hxmc.imports) and compiler-rt's helpers that ssl.o and uv.o need
	# (zig builds compiler-rt for the triple); its memcpy and the like become
	# local, so that Bionic's are the ones bound
	arch=${target#android-}
	printf 'int hxmc_stub(void){return 0;}\n' > "$out/obj/stub.c"
	$ZIG cc -target $triple -fPIC -c "$out/obj/stub.c" -o "$out/obj/stub.o"
	line=$($ZIG cc -target $triple -shared -nostdlib -lcompiler_rt "$out/obj/stub.o" -o "$out/obj/stub.so" -v 2>&1 | grep 'ld.lld' | head -1)
	libs=$(echo "$line" | tr ' ' '\n' | grep -E '/libcompiler_rt\.a$' | tr '\n' ' ')
	[ -n "$sslar" ] && ld.lld -r --strip-debug -o "$out/ssl.o" $sslroots --start-group $sslar --end-group
	[ -n "$uvar" ] && ld.lld -r --strip-debug -o "$out/uv.o" $uvroots --start-group $uvar --end-group
	for m in libc libm libdl; do
		awk -v lib=$m.so -v arch=$arch -v api=29 '
			function tag(t, name,   i, n, w, v) { n = split(t, w, /[ \t]+/); v = ""
				for (i = 1; i <= n; i++) if (w[i] ~ ("^" name "=")) v = substr(w[i], length(name) + 2)
				return v }
			# whether the tags t leave the symbol (or the block) out for arch at api
			function out(t,   n, w, i, arches, mine, v) {
				if (t ~ /platform-only|apex|llndk|systemapi/) return 1
				n = split(t, w, /[ \t]+/); arches = 0; mine = 0
				for (i = 1; i <= n; i++) if (w[i] == "arm" || w[i] == "arm64" || w[i] == "x86" || w[i] == "x86_64" || w[i] == "riscv64") { arches = 1; if (w[i] == arch) mine = 1 }
				if (arches && !mine) return 1
				v = tag(t, "introduced"); if (v != "" && v + 0 > api) return 1
				v = tag(t, "introduced-" arch); if (v != "" && v + 0 > api) return 1
				return 0 }
			/^[A-Z_0-9]+ *\{/ { ver = $1; t = index($0, "#") ? substr($0, index($0, "#") + 1) : ""
				if (ver == "LIBC_PRIVATE" || ver == "LIBC_PLATFORM" || ver == "LIBC_DEPRECATED" || out(t)) ver = ""; next }
			/^\}/ { ver = ""; next }
			ver != "" && /^[ \t]+[A-Za-z_][A-Za-z0-9_]*;/ {
				name = $1; sub(/;$/, "", name); t = index($0, "#") ? substr($0, index($0, "#") + 1) : ""
				if (out(t)) next
				print lib "\t" name "\t" ver "\t" (t ~ /(^| )var( |$)/ ? "object\t8" : "func\t0") "\t" }' "$deps/bionic/$m.map.txt"
	done | sort -u -k2,2 > "$out/obj/imports.txt"
	cut -f2 "$out/obj/imports.txt" | sort -u > "$out/obj/shared.txt"
	# what the runtime and generated code call must be there; what ssl.o and
	# uv.o call beyond them comes from compiler-rt
	# (atexit is Bionic's private one, crtbegin_so.o's elsewhere: the runtime calls __cxa_atexit)
	missing=$(echo "$libc _setjmp" | tr ' ' '\n' | grep -v '^$\|^atexit$' | sort -u | comm -23 - "$out/obj/shared.txt")
	[ -z "$missing" ] || { echo "mkrt: not in Bionic's libraries: $missing" >&2; exit 1; }
	undef=
	for f in $( (nm -u $(ls "$out/ssl.o" "$out/uv.o" 2>/dev/null) | awk 'NF == 2 {print $2}') | grep -v '^hx\|^haxe_\|^$' | sort -u | comm -23 - "$out/obj/shared.txt"); do undef="$undef -u $f"; done
	if [ -n "$undef" ]; then
		ld.lld -r --strip-debug -o "$out/obj/rt1.o" $undef --start-group $libs --end-group
		nm --defined-only -g "$out/obj/rt1.o" | awk '{print $3}' | sort -u | comm -12 - "$out/obj/shared.txt" > "$out/obj/shadow.txt"
		${OBJCOPY:-llvm-objcopy} --localize-symbols="$out/obj/shadow.txt" "$out/obj/rt1.o" "$out/obj/rt0.o"
	fi
	printf '\t.section .hxmc.imports,"a",@progbits\n\t.incbin "%s"\n' "$out/obj/imports.txt" > "$out/obj/imports.s"
	$ZIG cc -target $triple -c "$out/obj/imports.s" -o "$out/obj/imports.o"
	ld.lld -r -o "$out/rt.o" $(ls "$out/obj/rt0.o" 2>/dev/null) "$out/obj/imports.o"
	ls -l "$out/rt.o" "$out/ssl.o" "$out/uv.o"
	exit 0 ;;
*-glibc)
	# the dynamic glibc mode (-D hxmc.libc=glibc, Link.hx): no member of the C
	# library; what the runtime, generated code, ssl.o and uv.o call in it are
	# imports, bound by ld.so at load time with the versions of glibc 2.17
	# (the floor: the first glibc on aarch64). rt.o holds what glibc keeps in
	# libc_nonshared.a (atexit, stat, ... before 2.33), compiler-rt's helpers,
	# and the import table (.hxmc.imports: library, name, version, kind, size
	# and aliases per name), read from the libraries zig links against for
	# the triple (stubs generated from glibc's own version maps, the abilists)
	libc="$libc _setjmp __libc_start_main __cxa_atexit dlopen dlsym dlclose dlerror"
	printf 'int main(void){return 0;}\n' > "$out/obj/stub.c"
	$ZIG cc -target $triple -O2 "$out/obj/stub.c" -o "$out/obj/stub" -lpthread -ldl -lm
	line=$($ZIG cc -target $triple -O2 -v "$out/obj/stub.c" -o "$out/obj/stub" -lpthread -ldl -lm 2>&1 | grep 'ld.lld' | head -1)
	libs=$(echo "$line" | tr ' ' '\n' | grep -E '/lib(c_nonshared|compiler_rt)\.a$' | tr '\n' ' ')
	sos=$(echo "$line" | tr ' ' '\n' | grep -E '/lib(c|m|pthread|dl)\.so\.[0-9]+$' | tr '\n' ' ')
	[ -n "$sslar" ] && ld.lld -r --strip-debug -o "$out/ssl.o" $sslroots --start-group $sslar --end-group
	[ -n "$uvar" ] && ld.lld -r --strip-debug -o "$out/uv.o" $uvroots --start-group $uvar --end-group
	# every default-version definition of the libraries: lib name version kind size
	for so in $sos; do
		readelf --dyn-syms -W "$so" | awk -v lib="${so##*/}" '$7 != "UND" && $8 ~ /@@/ && ($4 == "FUNC" || $4 == "OBJECT" || $4 == "IFUNC") {
			split($8, p, "@@"); print lib "\t" p[1] "\t" p[2] "\t" ($4 == "OBJECT" ? "object" : "func") "\t" $3 }'
	done > "$out/obj/defs.txt"
	cut -f2 "$out/obj/defs.txt" | sort -u > "$out/obj/shared.txt"
	# what the shared libraries lack comes from the archives (libc_nonshared's
	# atexit and stat64, compiler-rt's __udivti3), nothing else: compiler-rt's
	# weak memcpy and the like (compiler-rt is one object) become local, so
	# that glibc's are the ones the program binds to
	want=$( (echo "$libc" | tr ' ' '\n'; nm -u $(ls "$out/ssl.o" "$out/uv.o" 2>/dev/null) | awk 'NF == 2 {print $2}') | grep -v '^hx\|^haxe_\|^$' | sort -u)
	undef=
	for f in $(echo "$want" | comm -23 - "$out/obj/shared.txt"); do undef="$undef -u $f"; done
	ld.lld -r --strip-debug -o "$out/obj/rt1.o" $undef --start-group $libs --end-group
	nm --defined-only -g "$out/obj/rt1.o" | awk '{print $3}' | sort -u | comm -12 - "$out/obj/shared.txt" > "$out/obj/shadow.txt"
	${OBJCOPY:-llvm-objcopy} --localize-symbols="$out/obj/shadow.txt" "$out/obj/rt1.o" "$out/obj/rt0.o"
	nm --defined-only -g "$out/obj/rt0.o" | awk '{print $3}' | sort -u > "$out/obj/defined.txt"
	# the names to import (pthread_* from libpthread, dl* from libdl, as
	# before 2.34; glibc 2.34+ keeps those versions in libc.so.6), and the
	# aliases of a copied variable (ld.so binds the library's own references
	# to the executable's copy through them): what the runtime, rt.o, ssl.o
	# and uv.o name but rt.o does not define (__dso_handle is the linker's)
	(echo "$want"; nm -u "$out/obj/rt0.o" | awk 'NF == 2 {print $2}') | grep -v '^__dso_handle$\|^$' | sort -u |
		comm -23 - "$out/obj/defined.txt" > "$out/obj/names.txt"
	awk -F '\t' 'NR == FNR { if (!($2 in def) || $1 ~ /^libc\.so/) def[$2] = $0; if ($1 ~ /^libpthread/) pt[$2] = $0; if ($1 ~ /^libdl/) dl[$2] = $0; next }
		{ n = $1; d = (n ~ /^pthread_/ && n in pt) ? pt[n] : (n ~ /^dl/ && n in dl) ? dl[n] : def[n]
		  if (d == "") { print "mkrt: " n " is in none of the libraries" > "/dev/stderr"; bad = 1; next }
		  al = n == "environ" ? "__environ,_environ" : ""; print d "\t" al }
		END { exit bad }' "$out/obj/defs.txt" "$out/obj/names.txt" > "$out/obj/imports.txt"
	printf '\t.section .hxmc.imports,"a",@progbits\n\t.incbin "%s"\n' "$out/obj/imports.txt" > "$out/obj/imports.s"
	$ZIG cc -target $triple -c "$out/obj/imports.s" -o "$out/obj/imports.o"
	ld.lld -r -o "$out/rt.o" "$out/obj/rt0.o" "$out/obj/imports.o"
	ls -l "$out/rt.o" "$out/ssl.o" "$out/uv.o"
	exit 0 ;;
macos-*)
	# nothing of the C library (libSystem, bound at load time): an empty object
	"${HXMC:-$ROOT/bin/hxmc/hxmc}" --mkrt-macho "$out/rt.o" $([ $target = macos-arm64 ] && echo --arm64)
	[ -n "$sslar" ] && "${HXMC:-$ROOT/bin/hxmc/hxmc}" --mkrt-macho "$out/ssl.o" $sslar $sslroots
	[ -n "$uvar" ] && "${HXMC:-$ROOT/bin/hxmc/hxmc}" --mkrt-macho "$out/uv.o" $uvar $uvroots
	ls -l "$out/rt.o" "$out/ssl.o" "$out/uv.o"
	exit 0 ;;
windows-*)
	# the runtime's own COFF objects, the C runtime's startup object and the
	# archives zig links (the MinGW-w64 libraries, compiler-rt, the import
	# libraries of the UCRT and the Windows DLLs the runtime uses), selected
	# and resolved by hxmc itself (hxmc --mkrt)
	printf 'int main(void){return 0;}\n' > "$out/obj/stub.c"
	WINLIBS="-lws2_32 -liphlpapi -luserenv -lpsapi -ldbghelp -lole32 -lshell32 -luser32 -ladvapi32 -lcrypt32 -lbcrypt"
	$ZIG cc -target $triple -O2 "$out/obj/stub.c" -o "$out/obj/stub.exe" $WINLIBS
	line=$($ZIG cc -target $triple -O2 -v "$out/obj/stub.c" -o "$out/obj/stub.exe" $WINLIBS 2>&1 | grep 'lld-link' | head -1)
	inputs=$(echo "$line" | tr ' ' '\n' | grep -E '\.(obj|lib)$' | grep -v '^-' | grep -v '/stub.obj$' | tr '\n' ' ')
	# ssl.o, uv.o: their objects and libraries, the C library for imports
	# only; the rest of the C library they need comes with rt.o
	sysar=
	for a in $inputs; do case $a in *.lib|*.a) sysar="$sysar -i $a" ;; esac; done
	touch "$out/obj/ssl.undef"
	[ -n "$sslar" ] && "${HXMC:-$ROOT/bin/hxmc/hxmc}" --mkrt "$out/ssl.o" $sslar $sysar $sslroots -U "$out/obj/ssl.undef"
	touch "$out/obj/uv.undef"
	[ -n "$uvar" ] && "${HXMC:-$ROOT/bin/hxmc/hxmc}" --mkrt "$out/uv.o" $uvar $sysar $uvroots -U "$out/obj/uv.undef"
	sj=_setjmp; [ $target = windows-arm64 ] && sj=__mingw_setjmp
	undef="-u mainCRTStartup -u $sj -u _tls_index -u _tls_used -x main"
	for f in $libc $(cat "$out/obj/ssl.undef" "$out/obj/uv.undef" | grep -v '^hx\|^rt_\|^haxe_') ; do undef="$undef -u $f"; done
	for f in $(cat "$out/obj/ssl.undef" "$out/obj/uv.undef" | grep '^hx\|^haxe_'); do undef="$undef -x $f"; done
	"${HXMC:-$ROOT/bin/hxmc/hxmc}" --mkrt "$out/rt.o" $inputs $undef
	ls -l "$out/rt.o" "$out/ssl.o" "$out/uv.o"
	exit 0 ;;
esac
# the C library: zig builds it on first use; a static link of a stub tells where
printf 'int main(void){return 0;}\n' > "$out/obj/stub.c"
# (twice: the first run may build the C library and name temporary paths)
$ZIG cc -target $triple -static -O2 "$out/obj/stub.c" -o "$out/obj/stub"
line=$($ZIG cc -target $triple -static -O2 -v "$out/obj/stub.c" -o "$out/obj/stub" 2>&1 | grep 'ld.lld' | head -1)
crt1=$(echo "$line" | tr ' ' '\n' | grep '/crt1.o$')
libs=$(echo "$line" | tr ' ' '\n' | grep -E '/lib(c|zigc|compiler_rt)\.a$' | tr '\n' ' ')
# ssl.o, uv.o: their objects and libraries; the C library they need comes with rt.o
[ -n "$sslar" ] && ld.lld -r --strip-debug -o "$out/ssl.o" $sslroots --start-group $sslar --end-group
[ -n "$uvar" ] && ld.lld -r --strip-debug -o "$out/uv.o" $uvroots --start-group $uvar --end-group
undef="-u _setjmp"
for f in $libc $(nm -u $(ls "$out/ssl.o" "$out/uv.o" 2>/dev/null) | awk '{print $2}' | grep -v '^hx\|^haxe_' | sort -u); do undef="$undef -u $f"; done
ld.lld -r --strip-debug -o "$out/rt.o" $undef "$crt1" --start-group $libs --end-group
ls -l "$out/rt.o" "$out/ssl.o" "$out/uv.o"
