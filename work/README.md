# AXI4 DDR4 memory controller

Work in progress. This drop contains everything in the controller clock domain:
the control path, ECC and the DFI interface, integrated as `ddr4_core`.

## Contents

| File | Module(s) | Status |
| --- | --- | --- |
| `rtl/ddr4_pkg.sv` | types, command encoding, timing struct, Hsiao matrix | lint clean |
| `rtl/cdc_cells.sv` | `sync_ff`, `reset_sync` | lint clean; used by the FIFO test |
| `rtl/async_fifo.sv` | `async_fifo` | simulated at three clock ratios |
| `rtl/ecc.sv` | `ecc_enc`, `ecc_dec` | all 72 single-bit and 2,556 double-bit errors checked |
| `rtl/addr_map.sv` | `addr_map` | lint clean only |
| `rtl/bank_fsm.sv` | `bank_fsm` | directed timing checks |
| `rtl/global_timers.sv` | `global_timers` | directed timing checks |
| `rtl/refresh_mgr.sv` | `refresh_mgr` | directed checks |
| `rtl/init_fsm.sv` | `init_fsm` | checked inside `tb_ctrl_core` |
| `rtl/lowpower_fsm.sv` | `lowpower_fsm` (self-refresh only) | checked inside `tb_ctrl_core` |
| `rtl/cmd_arbiter.sv` | `cmd_arbiter` | checked inside `tb_ctrl_core` |
| `rtl/ctrl_core.sv` | `ctrl_core` | 20,000 random requests, independent protocol monitor |
| `rtl/sync_fifo.sv` | `sync_fifo` | used as the read-tag queue in `tb_ddr4_core` |
| `rtl/ecc_datapath.sv` | `ecc_datapath` | checked inside `tb_ddr4_core` |
| `rtl/dfi_if.sv` | `dfi_if` | checked inside `tb_ddr4_core` |
| `rtl/ddr4_core.sv` | `ddr4_core` | end-to-end data integrity with injected bit errors |

## Running

    ./scripts/run_sims.sh        # needs Verilator 5.x

`scripts/gen_hsiao.py` regenerates the ECC matrix constants in `ddr4_pkg.sv`.

## Not done yet

`axi4_slave_if`, `apb_csr`, `cdc_fifos`, `ddr4_ctrl_top`, a pin-level PHY model for
use with the Micron memory model, and the UVM environment. Inside the control path: precharge
power-down, periodic ZQCS, and any refresh required after self-refresh exit.

## Running in Questa

    vlog -sv -f rtl/files.f tb/*.sv
    vsim -c tb_ctrl_core -do "run -all; quit"
    vsim -c tb_ctrl_core -gREFI=1560 -do "run -all; quit"
    vsim -c tb_ctrl_core -gSTRESS=1  -do "run -all; quit"
    vsim -c tb_ddr4_core -do "run -all; quit"
    vsim -c tb_ddr4_core -gWR_LAT=0 -gRDEN_LAT=1 -gRD_PHY_LAT=1 -do "run -all; quit"
    vsim -c tb_ddr4_core -gWR_LAT=4 -gRDEN_LAT=5 -gRD_PHY_LAT=3 -do "run -all; quit"

## Known limits of what has been checked

- The DFI data timing is cycle-aligned: a whole burst and its enable occupy one
  controller cycle, and the PHY is assumed to place it at the right sub-cycle
  position. A phase-accurate DFI is not implemented.
- `tb_ddr4_core` uses a behavioral PHY and memory written for this project. It
  checks data integrity, masking, ECC and backpressure, but not DDR4 pin timing.
- Reading a location that was never written returns whatever the memory holds,
  so ECC will flag it. Real systems initialize memory first; this design has no
  initialization or scrubbing logic yet.
- `tb_ctrl_core` checks command legality and spacing with a monitor that is
  independent of the RTL counters, but both were written from the same reading of
  the DDR4 rules. Only the Micron model can confirm that reading.
- With strict in-order scheduling the default tRRD, tFAW and tCCD values never
  limit the command stream; they are exercised only in the STRESS configuration.

- Timing defaults and the command truth table in `ddr4_pkg.sv` were written from
  memory and have not been checked against JESD79-4 or a Micron datasheet.
- Verilator is a two-state simulator: no X-propagation or metastability modelling.
  The FIFO test shows functional correctness, not CDC sign-off.
- Nothing has been run in Questa, VCS or Xcelium, synthesized, or tried against the
  Micron model.
