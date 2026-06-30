# `MI_SINGLE_THREADED` — analysis & reproduction

This directory contains the full investigation behind the opt-in
`MI_SINGLE_THREADED` specialization of the free fast path, plus everything
needed to reproduce it. It documents **two** analyses:

1. **Delivered change** — an idiomatic, safe `MI_SINGLE_THREADED` switch that
   removes the per-free thread-ownership check. It gives a **statistically
   significant 3.5–4.6 % cycle reduction** on allocator-bound single-threaded
   workloads, and is a no-op for the default (multi-threaded) build.
2. **Rejected experiment** — an ExGen-Malloc-style *single free list* (push
   frees straight onto `page->free` for immediate hot-block reuse). It is
   correct and reduces L1 misses, but **regresses 4–4.5 %** because it destroys
   the instruction-level parallelism that mimalloc's `free`/`local_free` split
   provides. Kept on the `single-threaded-sota` branch as a documented negative
   result.

See [`REPORT.md`](REPORT.md) for the full write-up with numbers, counters and
methodology.

## Layout

```
bench/single-threaded/
  REPORT.md                 full analysis (both parts)
  microbench/
    churn.cpp               allocator-bound micro: pure-LIFO + windowed reuse
    reuse.c                 shows whether freed blocks are reused immediately
  scripts/
    build_variants.sh       build baseline + MI_SINGLE_THREADED=ON
    run_micro.sh            interleaved, pinned, perf-counter micro sweep
    analyze_micro.py        p50/p90/p99 + Mann-Whitney U + bootstrap CI
  results/                  reference data from an AMD EPYC 7742 run
```

## Quick reproduce

```bash
# 1. build baseline + single-threaded variants (Release)
bench/single-threaded/scripts/build_variants.sh /tmp/mi-st

# 2. pick the produced .so names (version suffix varies)
BASE=$(ls /tmp/mi-st/baseline/libmimalloc.so.*.* | grep -E '\.[0-9]+$' | head -1)
SINGLE=$(ls /tmp/mi-st/single/libmimalloc.so.*.* | grep -E '\.[0-9]+$' | head -1)

# 3. interleaved, pinned sweep (set CORE to an isolated core; performance governor recommended)
CORE=4 REPEATS=21 OUT=micro.csv \
  bench/single-threaded/scripts/run_micro.sh "$BASE" baseline "$SINGLE" single

# 4. stats
bench/single-threaded/scripts/analyze_micro.py micro.csv --baseline baseline
```

To reproduce the **rejected** single-list experiment, `git checkout
single-threaded-sota`, rebuild `single`, and add it as a third variant.

## Notes on methodology

* Pin to one isolated core (`taskset -c <CORE>`); set the governor to
  `performance` and warm the core before measuring (the runner does a 2 s warm-up).
* Measurements are **interleaved** (baseline/variant alternate every run) so
  slow frequency/thermal drift cancels out.
* We report **cycles** (and IPC) from `perf`, not wall-clock alone, and never
  rely on instruction count as a proxy for speed (see `REPORT.md`, §3).
