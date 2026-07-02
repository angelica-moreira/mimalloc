#!/usr/bin/env bash
#
# Allocator-bound microbenchmark sweep: interleaved, pinned, perf-counter based.
# Compares any number of prebuilt mimalloc shared libraries on the `churn`
# microbenchmark (pure LIFO + windowed reuse). Emits raw per-run samples to CSV.
#
# Usage:
#   build_variants.sh /tmp/mi-st-build
#   run_micro.sh /tmp/mi-st-build/baseline/libmimalloc.so.<v> baseline \
#                /tmp/mi-st-build/single/libmimalloc.so.<v>   single
#   analyze_micro.py micro.csv
#
# Env: CORE (default 4), REPEATS (default 21), OUT (default ./micro.csv)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="${CORE:-4}"; REPEATS="${REPEATS:-21}"; OUT="${OUT:-micro.csv}"
PIN="taskset -c $CORE"

# (label -> libpath) pairs from argv: lib1 label1 lib2 label2 ...
libs=(); labels=()
while [ $# -ge 2 ]; do libs+=("$1"); labels+=("$2"); shift 2; done
[ $# -eq 0 ] || { echo "error: leftover argument '$1' (need <lib> <label> pairs)"; exit 1; }
[ ${#libs[@]} -ge 1 ] || { echo "usage: run_micro.sh <lib> <label> [<lib> <label> ...]"; exit 1; }
for l in "${libs[@]}"; do [ -f "$l" ] || { echo "error: library not found: $l"; exit 1; }; done

bin="$here/../microbench/churn"
g++ -O2 -o "$bin" "$here/../microbench/churn.cpp"

# allocator-bound workloads: "<mode> <iters> [window size]"
workloads=( "1 100000000" "2 100000000 4096 32" "2 100000000 65536 32" )

warm(){ $PIN bash -c 'e=$((SECONDS+2)); while [ $SECONDS -lt $e ]; do :; done' >/dev/null 2>&1; }
sample(){ # <lib> <args>  -> "cycles,instructions"
  LD_PRELOAD="$1" $PIN perf stat -x, -e cycles,instructions $bin $2 2>&1 >/dev/null \
    | awk -F, '$3=="cycles"{c=$1} $3=="instructions"{i=$1} END{print c","i}'
}

echo "workload,variant,run,cycles,instructions" > "$OUT"
warm
for w in "${workloads[@]}"; do
  tag="$(echo "$w" | tr ' ' '_')"
  for r in $(seq 1 "$REPEATS"); do
    for k in "${!libs[@]}"; do
      echo "$tag,${labels[$k]},$r,$(sample "${libs[$k]}" "$w")" >> "$OUT"
    done
  done
  echo "[$tag] done x$REPEATS"
done
echo "raw samples -> $OUT"
