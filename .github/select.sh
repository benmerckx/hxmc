#!/bin/sh
# Which parts of build.yml a run needs (its `changes` job), from the files
# that changed since the last commit CI checked (docs/testing.md, "CI"):
#   all       everything: anything outside the cases below (haxe/, hxmc/src,
#             hxmc/std, hxmc/deps, hxmc/test, packages/, the workflows, the
#             Makefile, ...); always on main, on tags, nightly (schedule) and on
#             dispatch
#   web       site/: the website and the playground in the browsers
# (Markdown alone: neither, nothing to build)
# The base of a push to a branch is the previous head (github.event.before)
# when build.yml succeeded on it (a run cancelled by a newer push checked
# nothing), else the branch's merge base with main; without one, everything.
# Writes key=value lines to $GITHUB_OUTPUT (stdout without it).
#   EVENT=push REF=refs/heads/x BEFORE=<sha> sh .github/select.sh
set -eu
out=${GITHUB_OUTPUT:-/dev/stdout}
EVENT=${EVENT:-push}
REF=${REF:-$(git symbolic-ref -q HEAD || echo HEAD)}
BEFORE=${BEFORE:-}
REPO=${REPO:-benmerckx/hxmc}

emit() {
	echo "selection: all=$1 web=$2 ($3)"
	printf 'all=%s\nweb=%s\n' "$1" "$2" >> "$out"
	exit 0
}

case "$EVENT:$REF" in
push:refs/heads/main | push:refs/tags/*) emit true true "$REF" ;;
push:*) ;;
*) emit true true "$EVENT" ;;
esac

base= merge=false
if [ -n "$BEFORE" ] && [ "$BEFORE" != 0000000000000000000000000000000000000000 ] && git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
	BEFORE=$(git rev-parse "$BEFORE^{commit}")
	n=$(gh api "repos/$REPO/actions/workflows/build.yml/runs?head_sha=$BEFORE&status=success&per_page=1" -q .total_count 2>/dev/null || echo 0)
	if [ "${n:-0}" -gt 0 ]; then base=$BEFORE; echo "base: $BEFORE (the previous head, checked)"; fi
fi
if [ -z "$base" ]; then
	base=$(git merge-base origin/main HEAD 2>/dev/null || true)
	if [ -n "$base" ]; then merge=true; echo "base: $base (the merge base with main)"; fi
fi
[ -n "$base" ] || emit true true "no base"

all=false web=false
files=$(git diff --name-only "$base" HEAD)
# (a branch at a commit of main: whatever main's run found, check it again)
if [ -z "$files" ] && [ $merge = true ]; then emit true true "nothing new since the merge base"; fi
echo "changed since $base:"
echo "$files" | sed 's/^/  /'
for f in $files; do
	case "$f" in
	*.md) ;;
	site/*) web=true ;;
	*) all=true ;;
	esac
done
if [ $all = true ]; then emit true true "a change outside docs and site/"; fi
emit false $web "docs or site/ only"
