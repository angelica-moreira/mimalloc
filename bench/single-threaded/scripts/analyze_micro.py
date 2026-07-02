#!/usr/bin/env python3
"""Analyze microbenchmark samples: median + p90/p99, IPC, Mann-Whitney U and a
95% bootstrap CI of the (variant - baseline) median delta. Baseline variant is
the one literally named 'baseline' (override with --baseline).

Usage: analyze_micro.py micro.csv [--metric cycles] [--baseline baseline]
"""
import csv, sys, math, random, statistics as st
from collections import defaultdict

def pct(xs, p):
    xs = sorted(xs); k = (len(xs)-1)*p/100.0; lo = int(k); hi = min(lo+1, len(xs)-1)
    return xs[lo] + (xs[hi]-xs[lo])*(k-lo)

def mwu(a, b):
    comb = sorted([(v,0) for v in a] + [(v,1) for v in b]); n1, n2 = len(a), len(b)
    rs = [0.0, 0.0]; i = 0
    while i < len(comb):
        j = i
        while j < len(comb) and comb[j][0] == comb[i][0]: j += 1
        avg = (i+1+j)/2.0
        for k in range(i, j): rs[comb[k][1]] += avg
        i = j
    U1 = rs[0] - n1*(n1+1)/2.0; U = min(U1, n1*n2 - U1)
    mu = n1*n2/2.0; sd = (n1*n2*(n1+n2+1)/12.0)**0.5
    if sd == 0: return 1.0
    z = (U - mu)/sd
    return max(min(2*(1 - 0.5*(1+math.erf(abs(z)/2**0.5))), 1.0), 0.0)

def boot_ci(a, b, it=20000):
    ds = sorted(st.median([random.choice(b) for _ in b]) -
                st.median([random.choice(a) for _ in a]) for _ in range(it))
    return ds[int(0.025*it)], ds[int(0.975*it)]

def main():
    path = sys.argv[1]
    metric = "cycles"; baseline = "baseline"; seed = 12345
    for i, a in enumerate(sys.argv):
        if a == "--metric": metric = sys.argv[i+1]
        if a == "--baseline": baseline = sys.argv[i+1]
        if a == "--seed": seed = int(sys.argv[i+1])
    random.seed(seed)   # deterministic bootstrap CI for reproducible analysis
    d = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    with open(path) as f:
        for r in csv.DictReader(f):
            wl = r.get("workload") or r.get("mode")   # accept either column name
            for k in ("cycles", "instructions"):
                if r.get(k): d[wl][r["variant"]][k].append(float(r[k]))
    for wl in d:
        variants = list(d[wl]); base = d[wl].get(baseline, {})
        bvals = base.get(metric, [])
        bmed = st.median(bvals) if bvals else float("nan")
        print(f"\n=== {wl}  (metric={metric}, baseline median={bmed:,.0f}) ===")
        for v in variants:
            xs = d[wl][v].get(metric, [])
            if not xs: continue
            m = st.median(xs)
            cyc = d[wl][v].get("cycles"); ins = d[wl][v].get("instructions")
            ipc = (st.median(ins)/st.median(cyc)) if (cyc and ins) else float("nan")
            line = (f"  {v:9s} p50={m:14,.0f}  p90={pct(xs,90):14,.0f}  "
                    f"p99={pct(xs,99):14,.0f}  ipc={ipc:.3f}")
            if v != baseline and bvals:
                p = mwu(bvals, xs); lo, hi = boot_ci(bvals, xs)
                sig = "SIGNIFICANT" if p < 0.05 else "ns"
                excl = "excludes 0" if (lo < 0) == (hi < 0) else "INCLUDES 0"
                line += (f"\n             vs {baseline}: {(m-bmed)/bmed*100:+.2f}%  "
                         f"p={p:.2e} ({sig})  95%CI=[{lo:,.0f},{hi:,.0f}] ({excl})")
            print(line)

if __name__ == "__main__":
    main()
