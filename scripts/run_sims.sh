#!/usr/bin/env bash
# Lint every module and run the block-level testbenches with Verilator (>= 5.0).
set -u
cd "$(dirname "$0")/.."
WARN="-Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY"
status=0

echo "=== lint ==="
for top in async_fifo ecc_enc ecc_dec addr_map bank_fsm global_timers refresh_mgr \
           init_fsm lowpower_fsm cmd_arbiter ctrl_core \
           sync_fifo ecc_datapath dfi_if ddr4_core; do
  if verilator --lint-only $WARN -f rtl/files.f --top-module "$top"; then
    echo "lint $top: clean"
  else
    echo "lint $top: FAILED"; status=1
  fi
done

run() {  # run <tb> <extra verilator args...>
  local tb=$1; shift
  local dir="build/${tb}_$(echo "$*" | tr -c 'A-Za-z0-9' '_')"
  verilator --binary --timing --assert -Wno-fatal -Wno-WIDTH -Wno-STMTDLY \
    -f rtl/files.f "tb/$tb.sv" --top-module "$tb" "$@" --Mdir "$dir" -o sim \
    > "$dir.log" 2>&1 || { echo "$tb: BUILD FAILED (see $dir.log)"; status=1; return; }
  "$dir/sim" | tee -a "$dir.log" | grep -E "PASS|FAIL|ERROR|rror" || status=1
}

mkdir -p build
echo "=== simulate ==="
run tb_async_fifo -GWHALF=5000 -GRHALF=2500     # write slower than read (AXI -> controller)
run tb_async_fifo -GWHALF=2500 -GRHALF=5000     # write faster than read (controller -> AXI)
run tb_async_fifo -GWHALF=3333 -GRHALF=4177     # unrelated clocks
run tb_ecc
run tb_timers
run tb_ctrl_core                         # default timing, fast refresh
run tb_ctrl_core -GREFI=1560             # realistic refresh interval
run tb_ctrl_core -GSTRESS=1              # widened tRRD/tFAW/tCCD
run tb_ddr4_core                         # end to end: commands, data, ECC, backpressure
run tb_ddr4_core -GWR_LAT=0 -GRDEN_LAT=1 -GRD_PHY_LAT=1
run tb_ddr4_core -GWR_LAT=4 -GRDEN_LAT=5 -GRD_PHY_LAT=3
exit $status
