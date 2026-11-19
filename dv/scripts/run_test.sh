#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_test.sh  -  compile and run one UVM test in Questa
#
# Usage (from anywhere; paths are relative to the repository root):
#   dv/scripts/run_test.sh [TEST] [SEED] [CLK_SET] [extra vsim args...]
#
#   dv/scripts/run_test.sh sanity_test
#   dv/scripts/run_test.sh axi_rand_test 7 fast
#   dv/scripts/run_test.sh axi_rand_test 1 slow +NBURSTS=50 +UVM_VERBOSITY=UVM_HIGH
#   GUI=1 dv/scripts/run_test.sh sanity_test           # waves in the GUI
#   COV=1 dv/scripts/run_test.sh axi_rand_test 3       # code + functional coverage -> cov.ucdb
#   NOCOMPILE=1 dv/scripts/run_test.sh ...              # reuse sim/work from the last compile
#
# CLK_SET: fast | equal | slow | odd   (AXI clock vs the 200 MHz controller clock)
# Output: sim/<TEST>_<SEED>_<CLK_SET>/run.log  (compile.log in sim/)
# -----------------------------------------------------------------------------
set -euo pipefail

TEST=${1:-sanity_test}
SEED=${2:-1}
CLK=${3:-slow}
shift $(( $# < 3 ? $# : 3 ))

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
UVM_HOME=${UVM_HOME:-$(dirname "$(which vsim)")/../verilog_src/uvm-1.1d}  # must match mtiUvm (1.1d in Questa 10.7c)
SIM="$ROOT/sim"
RUN="$SIM/${TEST}_${SEED}_${CLK}"

if [ ! -f "$UVM_HOME/src/uvm_macros.svh" ]; then
  echo "uvm_macros.svh not found under $UVM_HOME/src - set UVM_HOME" >&2
  exit 1
fi

mkdir -p "$SIM" "$RUN"
cd "$SIM"

if [ "${NOCOMPILE:-0}" != "1" ]; then
  # fresh library every time, so a stale build can never be simulated
  rm -rf work
  vlib work
  RTL=$(grep -v '^//' "$ROOT/rtl/files.f" | grep . | sed "s#^rtl/##; s#^#$ROOT/rtl/#")
  DV=$(grep -v '^//' "$ROOT/dv/dv_files.f" | grep . | sed "s#^#$ROOT/#")
  INC=$(grep -v '^//' "$ROOT/dv/dv_incdirs.f" | grep . | sed "s#^#+incdir+$ROOT/#")
  COVOPT=""
  [ "${COV:-0}" = "1" ] && COVOPT="+cover=bcesft"
  {
    vlog -sv -timescale 1ns/1ps $COVOPT $RTL
    vlog -sv -timescale 1ns/1ps -L mtiUvm +incdir+"$UVM_HOME/src" $INC $DV
  } 2>&1 | tee compile.log
  if grep -q "^\*\* Error" compile.log; then echo "compile failed - see $SIM/compile.log"; exit 1; fi
fi

cd "$RUN"
echo "run folder: $RUN"
VSIM_COV=""
DO_COV=""
if [ "${COV:-0}" = "1" ]; then
  VSIM_COV="-coverage"
  DO_COV="coverage save -onexit -testname ${TEST}_${SEED}_${CLK} cov.ucdb;"
fi

if [ "${GUI:-0}" = "1" ]; then
  vsim -lib "$SIM/work" -L mtiUvm -voptargs=+acc $VSIM_COV tb_top \
       +UVM_TESTNAME="$TEST" +CLK_SET="$CLK" -sv_seed "$SEED" "$@" \
       -do "$DO_COV log -r /*; run -all" -l run.log
else
  vsim -c -lib "$SIM/work" -L mtiUvm $VSIM_COV tb_top \
       +UVM_TESTNAME="$TEST" +CLK_SET="$CLK" -sv_seed "$SEED" "$@" \
       -do "$DO_COV run -all; quit -f" -l run.log > /dev/null
  echo "log: $RUN/run.log"
  grep -E "UVM_(ERROR|FATAL) .*@" run.log | head -5 || true
  grep -E "\*\* TEST (PASSED|FAILED)" run.log || { echo "no verdict in run.log (look for UVM_FATAL)"; exit 1; }
  grep -q "TEST PASSED" run.log
fi
