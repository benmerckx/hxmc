#!/bin/sh
# packages/3d's cost per feature (Size.hx): each level built for Linux
# x86-64 (the glibc mode) and wasm32-wasi; prints a table of the sizes and
# what each level adds.
#   sh packages/3d/test/size/sizes.sh <tool> <out dir> <class path args...>
set -e
tool=$1
out=$2
shift 2
mkdir -p "$out"
names="gfx-alone math world gltf renderer shadows input animation skinning normalmaps"
printf '%-12s %10s %8s %10s %8s\n' level native +native wasm +wasm
pn=0 pw=0 l=0
for n in $names; do
	"$tool" "$out/size$l" "$@" -main Size -D size_level=$l -D hxmc.libc=glibc -D hxmc.target=linux-x86_64 > "$out/size$l.log" 2>&1 || { cat "$out/size$l.log"; exit 1; }
	"$tool" "$out/size$l.wasm" "$@" -main Size -D size_level=$l -D hxmc.target=wasm32-wasi > "$out/size$l.wasm.log" 2>&1 || { cat "$out/size$l.wasm.log"; exit 1; }
	sn=$(wc -c < "$out/size$l") sw=$(wc -c < "$out/size$l.wasm")
	if [ $l = 0 ]; then dn=- dw=-; else dn=$((sn - pn)) dw=$((sw - pw)); fi
	printf '%-12s %10d %8s %10d %8s\n' $n $sn $dn $sw $dw
	pn=$sn pw=$sw l=$((l + 1))
done
# (the renderer on a model packed at build time, against the glTF level's renderer)
"$tool" "$out/packed" "$@" -main Size -D size_level=4 -D size_packed -D hxmc.libc=glibc -D hxmc.target=linux-x86_64 > "$out/packed.log" 2>&1 || { cat "$out/packed.log"; exit 1; }
"$tool" "$out/packed.wasm" "$@" -main Size -D size_level=4 -D size_packed -D hxmc.target=wasm32-wasi > "$out/packed.wasm.log" 2>&1 || { cat "$out/packed.wasm.log"; exit 1; }
sn=$(wc -c < "$out/packed") sw=$(wc -c < "$out/packed.wasm") rn=$(wc -c < "$out/size4") rw=$(wc -c < "$out/size4.wasm")
printf '%-12s %10d %8d %10d %8d  (against renderer)\n' packed $sn $((sn - rn)) $sw $((sw - rw))
