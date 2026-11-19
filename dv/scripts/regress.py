#!/usr/bin/env python3
"""
regress.py - run a test list in Questa and summarise the results.

  python dv/scripts/regress.py                   # every test, its seed count, clock 'slow'
  python dv/scripts/regress.py --clk all         # repeat for fast, equal, slow, odd
  python dv/scripts/regress.py --tests sanity_test axi_rand_test --seeds 3
  python dv/scripts/regress.py --cov             # coverage on, merged into sim/merged.ucdb

Compiles once, then runs every (test, seed, clock) with run_test.py --nocompile.
Writes sim/regress_summary.txt. Exit status is non-zero if anything failed.
"""
import argparse, os, re, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RUN = [sys.executable, os.path.join(ROOT, "dv", "scripts", "run_test.py")]
SIM = os.path.join(ROOT, "sim")

def read_list(path):
    tests = []
    for line in open(path):
        line = line.split("#", 1)[0].split()
        if line:
            tests.append((line[0], int(line[1]) if len(line) > 1 else 1, line[2:]))
    return tests

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", default=os.path.join(ROOT, "dv", "scripts", "testlist.txt"))
    ap.add_argument("--tests", nargs="*", help="only these tests")
    ap.add_argument("--seeds", type=int, help="override the seed count")
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--clk", default="slow", help="fast|equal|slow|odd|all")
    ap.add_argument("--cov", action="store_true")
    args = ap.parse_args()

    tests = read_list(args.list)
    if args.tests:
        tests = [t for t in tests if t[0] in args.tests] or [(t, 1, []) for t in args.tests]
    clks = ["fast", "equal", "slow", "odd"] if args.clk == "all" else [args.clk]
    env = dict(os.environ)
    flags = ["--cov"] if args.cov else []

    # compile once through the run script (runs sanity_test as a smoke test)
    print("compiling ...")
    r = subprocess.run(RUN + ["sanity_test", "1", clks[0]] + flags, env=env)
    if r.returncode not in (0, 1):
        sys.exit("compile or smoke test failed to run")
    flags.append("--nocompile")

    results = []
    for clk in clks:
        for name, n, extra in tests:
            for s in range(args.first_seed, args.first_seed + (args.seeds or n)):
                t0 = time.time()
                r = subprocess.run(RUN + [name, str(s), clk] + flags + extra, env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                log = os.path.join(SIM, f"{name}_{s}_{clk}", "run.log")
                why = ""
                if r.returncode != 0 and os.path.exists(log):
                    for line in open(log, errors="replace"):
                        if re.search(r"UVM_(ERROR|FATAL) .*@", line) or "** Error" in line:
                            why = line.strip()[:160]
                            break
                ok = r.returncode == 0
                results.append((name, s, clk, ok, time.time() - t0, why))
                print(f"{'PASS' if ok else 'FAIL'}  {name:24s} seed {s:<4d} {clk:6s} {time.time()-t0:7.1f}s  {why}")

    n_fail = sum(1 for r in results if not r[3])
    lines = [f"{'PASS' if ok else 'FAIL'}  {n:24s} seed {s:<4d} {c:6s} {t:7.1f}s  {w}"
             for n, s, c, ok, t, w in results]
    lines.append(f"\n{len(results) - n_fail} passed, {n_fail} failed, {len(results)} runs")
    with open(os.path.join(SIM, "regress_summary.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(lines[-1].strip())

    if args.cov:
        ucdbs = [os.path.join(SIM, f"{n}_{s}_{c}", "cov.ucdb") for n, s, c, *_ in results]
        ucdbs = [u for u in ucdbs if os.path.exists(u)]
        if ucdbs:
            merged = os.path.join(SIM, "merged.ucdb")
            subprocess.run(["vcover", "merge", "-out", merged] + ucdbs)
            # Questa 10.7c: plain "report" is the per-file summary; "-summary" is not
            # valid in this form. Functional coverage goes to its own detailed file.
            subprocess.run(["vcover", "report", "-output",
                            os.path.join(SIM, "coverage_summary.txt"), merged])
            subprocess.run(["vcover", "report", "-details", "-cvg", "-output",
                            os.path.join(SIM, "coverage_cvg.txt"), merged])
            print("coverage:", os.path.join(SIM, "coverage_summary.txt"),
                  os.path.join(SIM, "coverage_cvg.txt"))
    sys.exit(1 if n_fail else 0)

if __name__ == "__main__":
    main()
