#!/bin/sh
# Builds mbedtls and libuv as static libraries for an hxmc target, with zig cc
# and the flags of the target's runtime object (hxmc/deps/mkrt.sh), which
# turns them into the separate objects ssl.o and uv.o (docs/hxmc.md):
#
#   sh hxmc/deps/deps.sh <target> <out dir>     e.g. linux-x86_64 bin/hxmc/deps/linux-x86_64
#
# Installs into the out dir:
#   include/mbedtls, include/psa, include/uv.h, include/uv/
#   lib/libmbedtls.a lib/libmbedx509.a lib/libmbedcrypto.a lib/libuv.a
#   LICENSE.mbedtls, LICENSE.libuv
#   VERSIONS                versions, commits and toolchain of this build
#
# The sources are fetched with git at pinned tags and checked against the
# pinned commits (git's object ids are checksums of the whole tree), and used
# as released. libuv is built from the source lists of its CMakeLists.txt for
# the target's OS (linux, darwin, win). Nothing is rebuilt when VERSIONS
# already matches. Needs git and zig (ZIG, default zig). About a minute on 4
# cores per target.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$PWD
T=${1:?usage: deps.sh <target> <out dir>}
OUT=${2:?usage: deps.sh <target> <out dir>}
case $OUT in /*) ;; *) OUT=$ROOT/$OUT ;; esac

# mbedtls 2.28 (LTS): the API hxmc/std/hxmc/rt/Ssl.hx is written against (its struct layouts too), as
# upstream Haxe's bindings (haxe/libs/mbedtls) and the system 2.28 packages
MBEDTLS_VERSION=2.28.10
MBEDTLS_URL=https://github.com/Mbed-TLS/mbedtls.git
MBEDTLS_COMMIT=2fc8413bfcb51354c8e679141b17b3f1a5942561
# libuv 1.48: the version hxmc/std/hxmc/rt/Uv.hx was checked with (Layouts.hx reads its layouts) (Ubuntu 24.04)
LIBUV_VERSION=1.48.0
LIBUV_URL=https://github.com/libuv/libuv.git
LIBUV_COMMIT=e9f29cb984231524e3931aa0ae2c5dae1a32884e
# Android: Bionic's headers (libc/include and the kernel's uapi headers, merged
# into include/) and its version scripts (libc.map.txt, libm.map.txt,
# libdl.map.txt into bionic/: mkrt.sh's import table), at a pinned commit of
# AOSP's bionic (a sparse, blobless fetch: a few MB); mbedtls and libuv are
# compiled against them (zig has no Bionic of its own)
BIONIC_URL=https://android.googlesource.com/platform/bionic
BIONIC_COMMIT=731631f300090436d7f5df80d50b6275c8c60a93

ZIG=${ZIG:-zig}
command -v "$ZIG" >/dev/null || { echo "deps: zig not found (set ZIG)" >&2; exit 1; }
# the runtime object's flags (mkrt.sh): Linux static and position-dependent
# with a section per function (hxmc's ELF linker drops what is not reached),
# macOS position-independent with the minimum versions hxmc's Mach-O writes
CFLAGS="-O2 -g0 -w -fno-strict-aliasing"
case $T in
	linux-x86_64) TRIPLE=x86_64-linux-musl OS=linux ;;
	linux-arm64) TRIPLE=aarch64-linux-musl OS=linux ;;
	# the dynamic glibc mode (-D hxmc.libc=glibc): glibc 2.17, the first with aarch64, as the floor
	linux-x86_64-glibc) TRIPLE=x86_64-linux-gnu.2.17 OS=linux ;;
	linux-arm64-glibc) TRIPLE=aarch64-linux-gnu.2.17 OS=linux ;;
	windows-x86_64) TRIPLE=x86_64-windows-gnu OS=win ;;
	windows-arm64) TRIPLE=aarch64-windows-gnu OS=win ;;
	macos-x86_64) TRIPLE=x86_64-macos OS=darwin CFLAGS="$CFLAGS -mmacosx-version-min=10.15" ;;
	macos-arm64) TRIPLE=aarch64-macos OS=darwin CFLAGS="$CFLAGS -mmacosx-version-min=11.0" ;;
	# Android 10 (API 29): ELF TLS (TLSDESC) in Bionic, hxmc's floor
	android-arm64) TRIPLE=aarch64-linux-android.29 OS=linux BIONIC_ARCH=arm64 ;;
	android-x86_64) TRIPLE=x86_64-linux-android.29 OS=linux BIONIC_ARCH=x86 ;;
	*) echo "deps: unknown target $T" >&2; exit 1 ;;
esac
# (glibc: zig compiles position-independent code for dynamically linked
# targets; -fPIE reaches the C library through the GOT, hxmc's ELF linker
# binds those slots at load time, and the rest pc-relatively)
case $T in
	*-glibc) CFLAGS="$CFLAGS -fPIE -ffunction-sections -fdata-sections" ;;
	# (Android: a shared library, position-independent; Bionic's headers)
	android-*) CFLAGS="$CFLAGS -fPIC -ffunction-sections -fdata-sections -isystem $OUT/include" ;;
	linux-*) CFLAGS="$CFLAGS -fno-pie -fno-pic -ffunction-sections -fdata-sections" ;;
esac
# (arm64 but Apple's: return addresses signed, as hxmc's own functions whose
# frames C writes are (Abi.pac); Windows with key B, its unwind codes' key)
case $T in
	linux-arm64 | linux-arm64-glibc | android-arm64) CFLAGS="$CFLAGS -mbranch-protection=pac-ret" ;;
	windows-arm64) CFLAGS="$CFLAGS -mbranch-protection=pac-ret+b-key" ;;
esac
CC="$ZIG cc -target $TRIPLE"
AR="$ZIG ar"
TOOLCHAIN="zig $("$ZIG" version) -target $TRIPLE"
JOBS=${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}

STAMP="mbedtls $MBEDTLS_VERSION $MBEDTLS_COMMIT
libuv $LIBUV_VERSION $LIBUV_COMMIT
cflags $CFLAGS
$TOOLCHAIN"
case $T in android-*) STAMP="$STAMP
bionic $BIONIC_COMMIT" ;; esac
if [ -f "$OUT/VERSIONS" ] && [ "$(cat "$OUT/VERSIONS")" = "$STAMP" ]; then
	echo "deps: $OUT is up to date"
	exit 0
fi

W=$OUT/build
rm -rf "$W" "$OUT/include" "$OUT/lib" "$OUT/bionic" "$OUT/VERSIONS"
mkdir -p "$W" "$OUT/include" "$OUT/lib"

# fetch <name> <url> <tag> <commit>
fetch() {
	git clone -q -c advice.detachedHead=false --depth 1 --branch "$3" "$2" "$W/$1"
	got=$(git -C "$W/$1" rev-parse HEAD)
	if [ "$got" != "$4" ]; then
		echo "deps: $1: tag $3 is commit $got, expected $4" >&2
		exit 1
	fi
}

# compile <src dir> <obj dir> <cflags> <files...>: in parallel
compile() {
	src=$1 obj=$2 flags=$3
	shift 3
	mkdir -p "$obj"
	for f; do echo "$f"; done | xargs -P "$JOBS" -I{} sh -c \
		'f={}; o='"$obj"'/$(echo "$f" | tr / _); cd '"$src"' && '"$CC $CFLAGS $flags"' -c "$f" -o "${o%.c}.o"'
}

# archive <lib> <obj dir> <sources...>
archive() {
	lib=$1 obj=$2
	shift 2
	objs=
	for f; do objs="$objs $obj/$(echo "$f" | tr / _ | sed 's/\.c$/.o/')"; done
	# (GNU format everywhere: hxmc --mkrt and --mkrt-macho read its index)
	$AR --format=gnu rcs "$OUT/lib/$lib" $objs
}

case $T in
android-*)
	echo "deps: bionic $BIONIC_COMMIT"
	B=$W/bionic
	mkdir -p "$B"
	git -C "$B" init -q
	git -C "$B" fetch -q --depth 1 --filter=blob:none "$BIONIC_URL" "$BIONIC_COMMIT"
	git -C "$B" sparse-checkout set --no-cone /libc/include /libc/kernel/uapi /libc/kernel/android/uapi /libc/libc.map.txt /libm/libm.map.txt /libdl/libdl.map.txt /libc/NOTICE
	git -C "$B" checkout -q FETCH_HEAD
	got=$(git -C "$B" rev-parse HEAD)
	[ "$got" = "$BIONIC_COMMIT" ] || { echo "deps: bionic: got $got, expected $BIONIC_COMMIT" >&2; exit 1; }
	cp -r "$B/libc/include/." "$OUT/include/"
	for d in "$B"/libc/kernel/uapi/*; do
		case ${d##*/} in asm-generic) cp -r "$d" "$OUT/include/" ;; asm-*) ;; *) cp -r "$d" "$OUT/include/" ;; esac
	done
	cp -r "$B/libc/kernel/uapi/asm-$BIONIC_ARCH/asm" "$OUT/include/asm"
	cp -r "$B/libc/kernel/android/uapi/." "$OUT/include/"
	mkdir -p "$OUT/bionic"
	cp "$B/libc/libc.map.txt" "$B/libm/libm.map.txt" "$B/libdl/libdl.map.txt" "$OUT/bionic/"
	cp "$B/libc/NOTICE" "$OUT/LICENSE.bionic" ;;
esac

echo "deps: mbedtls $MBEDTLS_VERSION ($TOOLCHAIN)"
fetch mbedtls-$MBEDTLS_VERSION "$MBEDTLS_URL" v$MBEDTLS_VERSION $MBEDTLS_COMMIT
M=$W/mbedtls-$MBEDTLS_VERSION
# the library's own lists (library/Makefile): crypto, x509 and tls objects
objs() { sed -n "/^$1=/,/^\$/p" "$M/library/Makefile" | tr ' \\\t' '\n\n\n' | grep '\.o$' | sed 's/\.o$/.c/'; }
CRYPTO=$(objs OBJS_CRYPTO)
X509=$(objs OBJS_X509)
TLS=$(objs OBJS_TLS)
MBEDTLS_FLAGS="-I. -I../include -D_FILE_OFFSET_BITS=64"
# Windows on arm64: timing.c's portable hardclock calls gettimeofday without
# including MinGW's sys/time.h, which declares it
[ "$OS" = win ] && MBEDTLS_FLAGS="$MBEDTLS_FLAGS -include sys/time.h"
compile "$M/library" "$W/obj-mbedtls" "$MBEDTLS_FLAGS" $CRYPTO $X509 $TLS
archive libmbedcrypto.a "$W/obj-mbedtls" $CRYPTO
archive libmbedx509.a "$W/obj-mbedtls" $X509
archive libmbedtls.a "$W/obj-mbedtls" $TLS
cp -r "$M/include/mbedtls" "$M/include/psa" "$OUT/include/"

echo "deps: libuv $LIBUV_VERSION ($TOOLCHAIN)"
fetch libuv-$LIBUV_VERSION "$LIBUV_URL" v$LIBUV_VERSION $LIBUV_COMMIT
U=$W/libuv-$LIBUV_VERSION
# CMakeLists.txt's common and unix sources (Windows: its win sources), then the OS's
UV_COMMON="src/fs-poll.c src/idna.c src/inet.c src/random.c src/strscpy.c src/strtok.c
src/thread-common.c src/threadpool.c src/timer.c src/uv-common.c src/uv-data-getter-setters.c src/version.c"
UV="$UV_COMMON
src/unix/async.c src/unix/core.c src/unix/dl.c src/unix/fs.c src/unix/getaddrinfo.c src/unix/getnameinfo.c
src/unix/loop-watcher.c src/unix/loop.c src/unix/pipe.c src/unix/poll.c src/unix/process.c
src/unix/random-devurandom.c src/unix/signal.c src/unix/stream.c src/unix/tcp.c src/unix/thread.c
src/unix/tty.c src/unix/udp.c"
UV_FLAGS="-Iinclude -Isrc -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE"
case $OS in
	linux)
		UV="$UV src/unix/proctitle.c src/unix/linux.c src/unix/procfs-exepath.c src/unix/random-getrandom.c
src/unix/random-sysctl-linux.c"
		UV_FLAGS="$UV_FLAGS -D_GNU_SOURCE -D_POSIX_C_SOURCE=200112"
		# (Android: CMakeLists.txt's list for it, getentropy too)
		case $T in android-*) UV="$UV src/unix/random-getentropy.c" UV_FLAGS="-Iinclude -Isrc -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_GNU_SOURCE" ;; esac ;;
	darwin)
		# fsevents.c and darwin*.c load CoreFoundation/CoreServices with dlopen
		# (declarations from src/unix/darwin-stub.h): no SDK frameworks to link
		UV="$UV src/unix/proctitle.c src/unix/bsd-ifaddrs.c src/unix/kqueue.c src/unix/random-getentropy.c
src/unix/darwin-proctitle.c src/unix/darwin.c src/unix/fsevents.c"
		UV_FLAGS="$UV_FLAGS -D_DARWIN_UNLIMITED_SELECT=1 -D_DARWIN_USE_64_BIT_INODE=1" ;;
	win)
		UV="$UV_COMMON src/win/async.c src/win/core.c src/win/detect-wakeup.c src/win/dl.c src/win/error.c src/win/fs.c
src/win/fs-event.c src/win/getaddrinfo.c src/win/getnameinfo.c src/win/handle.c src/win/loop-watcher.c src/win/pipe.c
src/win/thread.c src/win/poll.c src/win/process.c src/win/process-stdio.c src/win/signal.c src/win/snprintf.c
src/win/stream.c src/win/tcp.c src/win/tty.c src/win/udp.c src/win/util.c src/win/winapi.c src/win/winsock.c"
		UV_FLAGS="-Iinclude -Isrc -DWIN32_LEAN_AND_MEAN -D_WIN32_WINNT=0x0602 -D_CRT_DECLARE_NONSTDC_NAMES=0" ;;
esac
compile "$U" "$W/obj-uv" "$UV_FLAGS" $UV
archive libuv.a "$W/obj-uv" $UV
cp "$U/include/uv.h" "$OUT/include/"
cp -r "$U/include/uv" "$OUT/include/"
cp "$M/LICENSE" "$OUT/LICENSE.mbedtls"
cp "$U/LICENSE" "$OUT/LICENSE.libuv"

rm -rf "$W"
echo "$STAMP" > "$OUT/VERSIONS"
ls -l "$OUT/lib"
