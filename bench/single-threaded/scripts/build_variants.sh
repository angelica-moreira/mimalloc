#!/usr/bin/env bash
#
# Build the mimalloc variants used in the single-threaded analysis.
#
#   baseline   : current branch, default build (MI_SINGLE_THREADED off)
#   single     : current branch, -DMI_SINGLE_THREADED=ON  (the deliverable)
#
# The "single-list" (rejected) experiment lives on the `single-threaded-sota`
# branch; check it out and re-run this script to build it the same way.
#
# Usage:  bench/single-threaded/scripts/build_variants.sh [<build-root>]
# Output: <build-root>/{baseline,single}/libmimalloc.so*
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"   # repo root
out="${1:-/tmp/mi-st-build}"
jobs="$(nproc)"

build() { # <name> <extra-cmake-args...>
  local name="$1"; shift
  local d="$out/$name"
  echo ">> building '$name' in $d"
  rm -rf "$d"; mkdir -p "$d"
  ( cd "$d" && cmake "$here" -DCMAKE_BUILD_TYPE=Release "$@" >cmake.log 2>&1 \
      && cmake --build . -j "$jobs" >make.log 2>&1 )
  echo "   -> $(ls "$d"/libmimalloc.so.*.* 2>/dev/null | grep -E '\.[0-9]+$' | head -1)"
}

build baseline
build single  -DMI_SINGLE_THREADED=ON
echo "done. libs under $out/{baseline,single}/"
