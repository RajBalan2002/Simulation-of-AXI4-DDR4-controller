#!/usr/bin/env python3
"""
run_test.py - compile and run one UVM test in Questa (Windows, Linux, macOS).

Run from the project root (the folder that holds rtl/ and dv/):

  python dv/scripts/run_test.py sanity_test
  python dv/scripts/run_test.py axi_rand_test 7 fast
  python dv/scripts/run_test.py axi_rand_test 1 slow +NBURSTS=50 +UVM_VERBOSITY=UVM_HIGH
  python dv/scripts/run_test.py sanity_test --gui           # waveforms in the GUI
  python dv/scripts/run_test.py axi_rand_test 3 --cov       # coverage -> cov.ucdb
  python dv/scripts/run_test.py refresh_test --nocompile    # reuse the last compile

CLK_SET: fast | equal | slow | odd   (AXI clock vs the 200 MHz controller clock)
Output:  sim/<TEST>_<SEED>_<CLK>/run.log   (compile log: sim/compile.log)
Exit status 0 = TEST PASSED.
"""
import argparse, os, re, shutil, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SIM = os.path.join(ROOT, "sim")


def p(path):
    """Forward slashes: Questa accepts them on every OS."""
    return path.replace("\\", "/")


def read_list(name, prefix=""):
    out = []
    for line in open(os.path.join(ROOT, name)):
        line = line.strip()
        if line and not line.startswith("//"):
            out.append(p(os.path.join(ROOT, prefix, line)))
    return out


def find_uvm_home():
    if os.environ.get("UVM_HOME"):
        return os.environ["UVM_HOME"]
    vsim = shutil.which("vsim")
    if not vsim:
        sys.exit("vsim not found on PATH - add the Questa bin folder (e.g. ...\\win64) to PATH")
    base = os.path.join(os.path.dirname(vsim), "..", "verilog_src")
    # mtiUvm in Questa 10.7c is UVM-1.1d: the macros must come from the same release
    for name in ("uvm-1.1d", "uvm-1.2"):
        if os.path.exists(os.path.join(base, name, "src", "uvm_macros.svh")):
            return os.path.abspath(os.path.join(base, name))
    sys.exit(f"no UVM source found under {os.path.abspath(base)} - set UVM_HOME")


def run(cmd, log=None, cwd=None):
    r = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, errors="replace")
    if log:
        with open(log, "a") as f:
            f.write(r.stdout)
    return r


def compile_all(cov):
    os.makedirs(SIM, exist_ok=True)
    log = os.path.join(SIM, "compile.log")
    open(log, "w").close()
    shutil.rmtree(os.path.join(SIM, "work"), ignore_errors=True)  # never simulate a stale build
    run(["vlib", "work"], log, SIM)

    rtl = [f if os.path.isabs(f) else f for f in read_list(os.path.join("rtl", "files.f"))]
    dv = read_list(os.path.join("dv", "dv_files.f"))
    inc = ["+incdir+" + d for d in read_list(os.path.join("dv", "dv_incdirs.f"))]
    uvm = p(find_uvm_home())

    rtl_cmd = ["vlog", "-sv", "-timescale", "1ns/1ps"] + (["+cover=bcesft"] if cov else []) + rtl
    dv_cmd = ["vlog", "-sv", "-timescale", "1ns/1ps", "-L", "mtiUvm",
              "+incdir+" + uvm + "/src"] + inc + dv
    ok = True
    for cmd in (rtl_cmd, dv_cmd):
        r = run(cmd, log, SIM)
        if r.returncode != 0 or re.search(r"^\*\* Error", r.stdout, re.M):
            ok = False
            break
    lines = open(log, errors="replace").read().splitlines()
    errs = [i for i, l in enumerate(lines) if l.startswith("** Error")]
    if not ok or errs:
        print(f"COMPILE FAILED - see {log}")
        shown = set()
        for i in errs[:6]:                      # each error with the lines that explain it
            for j in range(i, min(i + 3, len(lines))):
                if j not in shown:
                    print("  " + lines[j].rstrip())
                    shown.add(j)
        sys.exit(2)
    print(f"compiled ({log})")


def main():
    ap = argparse.ArgumentParser(description="Run one UVM test in Questa")
    ap.add_argument("test", nargs="?", default="sanity_test")
    ap.add_argument("seed", nargs="?", default="1")
    ap.add_argument("clk", nargs="?", default="slow", choices=["fast", "equal", "slow", "odd"])
    ap.add_argument("--gui", action="store_true", help="open the Questa GUI with waves")
    ap.add_argument("--cov", action="store_true", help="collect code and functional coverage")
    ap.add_argument("--nocompile", action="store_true", help="reuse sim/work")
    args, plusargs = ap.parse_known_args()

    if not args.nocompile:
        compile_all(args.cov)

    rundir = os.path.join(SIM, f"{args.test}_{args.seed}_{args.clk}")
    os.makedirs(rundir, exist_ok=True)
    log = os.path.join(rundir, "run.log")
    print(f"running {args.test} seed {args.seed} clock {args.clk} in {rundir}")

    # unique test name per run, or vcover merge reports duplicate test records (vcover-6854)
    do = (f"coverage save -onexit -testname {args.test}_{args.seed}_{args.clk} cov.ucdb; "
          if args.cov else "")
    vsim = ["vsim", "-lib", p(os.path.join(SIM, "work")), "-L", "mtiUvm"]
    if args.cov:
        vsim.append("-coverage")
    vsim += ["tb_top", f"+UVM_TESTNAME={args.test}", f"+CLK_SET={args.clk}",
             "-sv_seed", str(args.seed), "-l", "run.log"] + plusargs

    if args.gui:
        subprocess.run(vsim + ["-voptargs=+acc", "-do", do + "log -r /*; run -all"], cwd=rundir)
        return

    run(["vsim", "-c"] + vsim[1:] + ["-do", do + "run -all; quit -f"], cwd=rundir)
    if not os.path.exists(log):
        sys.exit(f"no run.log in {rundir} - vsim did not start")
    text = open(log, errors="replace").read()
    for l in re.findall(r"^.*UVM_(?:ERROR|FATAL) .*@.*$", text, re.M)[:5]:
        print("  " + l.strip())
    m = re.search(r"\*\* TEST (PASSED|FAILED).*", text)
    print(m.group(0) if m else "no verdict in run.log (look for UVM_FATAL or ** Error)")
    print(f"log: {log}")
    sys.exit(0 if m and m.group(1) == "PASSED" else 1)


if __name__ == "__main__":
    main()
