# UVM verification environment

Top-level UVM testbench for `ddr4_ctrl_top`. See
[docs/verification.md](../docs/verification.md) for what each part checks,
the results and the open coverage items.

## Layout

| Folder | Contents |
| --- | --- |
| `tb/` | `tb_top`, interfaces (AXI, APB, DFI, clocks/resets, white-box probe) |
| `agents/axi/` | AXI4 master: item, driver, monitor, agent |
| `agents/apb/` | APB master: item, driver, monitor, agent |
| `agents/dfi/` | DFI command monitor and the PHY + DRAM responder |
| `ral/` | Register model and APB adapter |
| `env/` | Config, scoreboard, DDR4 protocol checker, coverage, env, package |
| `seq/` | AXI traffic sequences |
| `tests/` | Base test and the 21 tests |
| `sva/` | Assertion modules and their bind statements |
| `scripts/` | `run_test.py`, `regress.py`, `run.do`, `run_test.sh`, `testlist.txt` |

## Running (Questa)

Run from the repository root. `run_test.py` and `regress.py` work on Windows,
Linux and macOS; `run_test.sh` is the same flow for a POSIX shell.

```
python dv/scripts/run_test.py sanity_test                   # compile + run, seed 1, AXI 100 MHz
python dv/scripts/run_test.py axi_rand_test 7 fast          # seed 7, AXI clock 2x the controller
python dv/scripts/run_test.py axi_rand_test 1 slow +NBURSTS=50 +UVM_VERBOSITY=UVM_HIGH
python dv/scripts/run_test.py refresh_test --nocompile      # reuse the last compile
python dv/scripts/run_test.py sanity_test --gui             # waveforms
python dv/scripts/regress.py                                # whole test list, clock 'slow'
python dv/scripts/regress.py --clk all --cov                # all clock settings, merged coverage
```

Inside the Questa GUI, from the repository root: `do dv/scripts/run.do sanity_test 1 slow`.

Logs go to `sim/<test>_<seed>_<clock>/run.log` and `sim/compile.log`; the
regression summary to `sim/regress_summary.txt`; merged coverage to
`sim/merged.ucdb`, `sim/coverage_summary.txt` (code) and `sim/coverage_cvg.txt`
(functional).

**UVM version.** The flow links Questa's precompiled `mtiUvm` library, which in
Questa 10.7c is UVM-1.1d, so the macros are taken from `verilog_src/uvm-1.1d`.
Mixing 1.2 macros with the 1.1d library fails on every `` `uvm_* `` line. Set
`UVM_HOME` to override. The code keeps to the API common to UVM 1.1d and 1.2.

## Plusargs

| Plusarg | Effect |
| --- | --- |
| `+CLK_SET=fast\|equal\|slow\|odd` | AXI clock 400 / 200 / 100 / ~94 MHz (controller fixed at 200 MHz) |
| `+NBURSTS=<n>` | Burst count for the traffic tests |
| `+FULL_INIT` | Use the full 200 us / 500 us power-up waits |
| `+FIELD=<k>` | `timing_sweep_test`: which timing register to raise (0..21) |
