#!/bin/sh
# packages/3d's frames (Scenes.hx) against <scene>.png, headless (RenderTest:
# Linux on Mesa's llvmpipe through an EGL pbuffer; macOS on Metal; Windows
# (RenderTest.exe) on D3D11's WARP, or on Linux under Wine: wined3d over
# llvmpipe, under Xvfb), as packages/gfx/test/check.sh.
#   sh packages/3d/test/check.sh <dir with RenderTest> [out dir]
set -e
bin=$1
out=${2:-$1}
here=$(dirname "$0")
export LIBGL_ALWAYS_SOFTWARE=1 HXMC_GFX_SOFTWARE=1
if [ -f "$bin/RenderTest.exe" ]; then
	case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*) run() { "$bin/RenderTest.exe" "$@"; } ;;
	*)
		export WINEDEBUG=-all
		run() { xvfb-run -a -s "-screen 0 640x480x24" "${WINE:-/usr/lib/wine/wine64}" "$bin/RenderTest.exe" "$@"; }
		;;
	esac
else
	run() { env -u DISPLAY "$bin/RenderTest" "$@"; }
	# (ARM64's llvmpipe: up to 3 levels from x86-64's, gfx's own frames too)
	case "$(uname -s)-$(uname -m)" in
	Linux-aarch64 | Linux-arm64) export HXMC_3D_TOLERANCE=3 ;;
	esac
fi
for s in gltf orbits shadows physics instances skin overlay textured packed spot sky lazy particles normals blend walker packedskin packednormals cascades environment morph chains packedmorph; do
	g=$s
	# (the packed sample draws the glTF one's frame, the lazy skin the skin's)
	[ $s = packed ] && g=gltf
	[ $s = lazy ] && g=skin
	[ $s = packedskin ] && g=skin
	[ $s = packednormals ] && g=normals
	[ $s = packedmorph ] && g=morph
	code=0
	run $s "$here/$g.png" "$out/$s.png" || code=$?
	# (macOS without a Metal device: GfxTest's 3, skipped)
	[ $code = 3 ] && exit 0
	[ $code = 0 ] || exit $code
done
