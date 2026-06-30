# Single-threaded specialization of mimalloc — full analysis

**Hardware:** AMD EPYC 7742 (Zen 2, 64C/128T, 1 NUMA node), `performance`
governor, single pinned core, interleaved runs.
**Toolchain:** gcc 13.3, `-O3` Release, mimalloc `dev` @ `92854277`.
**Stats:** medians with p90/p99, Mann-Whitney U, 95 % bootstrap CI on the
median delta. All raw samples are in [`results/`](results/).

---

## 0. The change

In `mi_free_ex` (`src/free.c`) the free fast path performs a thread-ownership
test on every free:

```c
const bool is_local = (_mi_prim_thread_id() == mi_atomic_load_relaxed(&segment->thread_id));
```

If the program only ever calls mimalloc from one thread, every block is
thread-local and that test is redundant. `MI_SINGLE_THREADED` forces
`is_local = true` and (in debug builds) asserts the invariant instead:

```c
#if MI_SINGLE_THREADED
  mi_assert_internal(_mi_prim_thread_id() == mi_atomic_load_relaxed(&segment->thread_id));
  const bool is_local = true;
#else
  const bool is_local = (_mi_prim_thread_id() == mi_atomic_load_relaxed(&segment->thread_id));
#endif
```

This is wired as a documented default in `include/mimalloc/types.h`
(`#if !defined(MI_SINGLE_THREADED) #define MI_SINGLE_THREADED 0`) and a CMake
option (`-DMI_SINGLE_THREADED=ON`), matching the existing `MI_*` switches. The
default build is byte-identical to baseline.

### Safety

The flag is a single-thread-only contract. With it on, calling mimalloc from
more than one thread is undefined. Unlike a bare branch removal, the debug build
keeps the ownership check as `mi_assert_internal`, so multithreaded misuse aborts
immediately (verified: `test-stress` trips it at `free.c` with SIGABRT) instead
of silently corrupting the heap. Zero cost in release.

---

## 1. Codegen verification

`objdump` of `mi_ufree` (which inlines `mi_free_ex`):

| build | instructions | `%fs:0x0` reads | mt branch |
|---|---|---|---|
| baseline | 48 | yes | `jne mi_free_generic_mt` |
| `MI_SINGLE_THREADED` | 41 | **none** | gone |

The TLS read, the relaxed atomic load of `segment->thread_id`, the compare and
the `mt` branch are all removed. Output of `cfrac`/`espresso` is byte-identical.

---

## 2. Why the gain depends on the workload

The eliminated branch is **loop-invariant and always true**, so the hardware
predicts it perfectly: removing it does **not** change branch-miss counts. Its
only value is fewer *instructions*, which helps only when the allocator fast
path is actually on the critical path.

`perf` branch-miss attribution on `alloc-test 1` (a common allocator benchmark):

| where | share of branch-misses |
|---|---|
| **the benchmark's own RNG** (`randomPos_RandomSize<…>`) | **78.5 %** |
| libmimalloc (spread across alloc/free thunks) | 17.0 % |
| libc | 4.2 % |

So on `alloc-test`/`sh6bench` most cycles are *not* in the allocator, and the
few saved instructions are hidden. That is why the original PR's wall-clock
claims did not reproduce here — and on `sh6bench` the change even regressed
+3.7 % from a **code-layout** artifact (instructions −4.4 %, but cycles +3.4 %,
IPC −7.5 %; the regression vanishes under PGO). Instruction count is not a
proxy for speed on an out-of-order core.

(Real-benchmark sweep, n=51, is in `results/real_benchmarks_n51.csv`.)

---

## 3. Where the gain is real — allocator-bound microbenchmarks

`microbench/churn.cpp` keeps the harness work minimal so the allocator fast
path *is* the hot loop (pure LIFO, and windowed reuse of N live objects).

**Cycles, baseline vs `MI_SINGLE_THREADED` (`single`), n=21, interleaved:**

| workload | Δ cycles | IPC | Mann-Whitney p | 95 % CI |
|---|---|---|---|---|
| pure LIFO churn | **−4.61 %** | 2.98 → 3.04 | 2.4e-3 | excludes 0 |
| windowed, 4 K live | **−4.15 %** | flat | 4.4e-6 | excludes 0 |
| windowed, 64 K live | **−3.45 %** | flat | 2.9e-8 | excludes 0 |

A genuine, significant **3.5–4.6 %** when the allocator is the bottleneck, with
IPC neutral-to-better (the saving converts cleanly). Reproduce with
`scripts/run_micro.sh` + `scripts/analyze_micro.py`; reference data in
`results/microbench_base_pron_sota_n21.csv`.

---

## 4. Rejected experiment — ExGen-style single free list

Motivated by *"Old is Gold: Optimizing Single-threaded Applications with
ExGen-Malloc"* (Li, John, Yadwadkar, IEEE CAL 2025, arXiv:2510.10219), which
uses a single free-block list. mimalloc instead splits `free` (malloc pops) from
`local_free` (free pushes), reconciling them in `_mi_page_free_collect`. A
consequence (`microbench/reuse.c`): a freed block is **not** reused on the next
allocation — it stays in `local_free` until a migration, so it goes cold.

On the `single-threaded-sota` branch, under `MI_SINGLE_THREADED` the free path
pushes directly onto `page->free` (clearing `free_is_zero` for calloc
correctness):

```c
#if MI_SINGLE_THREADED
  mi_block_set_next(page, block, page->free);
  page->free = block;
  page->free_is_zero = false;
#else
  mi_block_set_next(page, block, page->local_free);
  page->local_free = block;
#endif
```

* **Correct:** 43/43 api tests pass and heavy churn runs clean under
  `MI_DEBUG_FULL`; `reuse.c` confirms immediate LIFO reuse.
* **Helps the metrics it targets:** L1-dcache-load-misses −6.7 %, instructions
  −3.5 % on large-window churn.
* **But it regresses (cycles):** pure LIFO −3.7 % (worse than `single`'s
  −4.6 %), windowed 4 K **+4.34 %**, windowed 64 K **+4.55 %** — all significant.
  IPC drops 2.57 → 2.36.

**Root cause.** mimalloc's `free`/`local_free` split is not only for
thread-safety: it decouples the pointer malloc reads (`page->free`) from the
pointer free writes (`page->local_free`), letting the out-of-order core overlap
alloc and free. Merging them serializes the chain (free's store to `page->free`
must retire before the next malloc's load), so IPC collapses and the change
loses despite fewer instructions and fewer cache misses. ExGen is a from-scratch
design without this property; porting just the list-merge into mimalloc
backfires. **Rejected.**

Reference data: `results/microbench_base_pron_sota_n21.csv` (the `sota` column).

---

## 5. Conclusions

* `MI_SINGLE_THREADED` (idiomatic + debug assert) is a safe, no-op-by-default
  switch that delivers a real, significant **3.5–4.6 %** on allocator-bound
  single-threaded workloads. Recommended to ship as such — **not** as a general
  speedup, since workloads where the allocator isn't the bottleneck see ~0.
* On x86 the release fast path is already minimal (`MI_STAT=0`, security/debug
  checks compile out), so the predicted-branch elimination is the realistic
  ceiling for a *safe* single-thread fast-path specialization.
* The single-list idea, though SOTA-motivated, is the wrong port for mimalloc
  and is rejected on evidence (ILP loss).
* Larger single-thread wins, if pursued, lie in ExGen's *other* lever —
  memory-footprint / metadata compaction — validated against RSS and LLC/dTLB,
  not instruction count.
