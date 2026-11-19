# Bug log

Bugs found while bringing up the UVM environment. Each entry says whether the
bug was in the design (RTL) or the testbench (TB), how it was found, and how it
was confirmed.

| ID | Where | Summary | Found by |
| --- | --- | --- | --- |
| RTL-1 | `async_fifo`, `ddr4_ctrl_top` | Read-FIFO free count undriven: no read ever issued | `sanity_test` hang |
| TB-1 | `dv/scripts` | UVM 1.2 macros compiled against the 1.1d library | First compile |
| TB-2 | `ddr4_base_test` | Test timeout 1000× too short | `sanity_test` killed at 50 µs |
| TB-3 | `rtl/files.f` | Top-level files missing from the compile list | First elaboration |
| TB-4 | `self_refresh_test` | "In self-refresh" check too early at the fast AXI clock | Regression, `--clk all` |
| TB-5 | `axi_rand_seq` | Strobe and unsupported-burst knobs had no effect | Functional coverage |

---

## RTL-1: read-FIFO free count undriven, controller never issues RD

**Symptom.** `sanity_test` (one write, one read) never finished. Over 4 ms the
protocol checker saw 508 ACT, 508 PREA and 508 REF, and no RD or WR.

**Cause.** `async_fifo` had lost its `wfree` output, and with it the connection
`.wfree(rd_free)` in `ddr4_ctrl_top`. `rd_free` was declared but never driven,
so it stayed X. `ddr4_core` only allows a read while
`bursts in flight < free slots`, so `rd_space_ok` was never true and the
arbiter never issued RD. The read sat at the head of the in-order queue, and the
write behind it never ran. The row was opened, closed by the next refresh, and
opened again, indefinitely.

**How it was confirmed.** A signal trace showed the read pushed first (AR
overtakes the write while its eight beats arrive, which AXI allows), one ACT,
then no RD with `req_valid = 1` throughout. `rd_free` had no driver. Release
v0.5 of the RTL has the port; the working copy had it removed by hand.

**Fix.** Restore `wfree` in `async_fifo` and connect it (commit "RTL v0.5").
`tb_async_fifo` already checked `wfree`, so the directed test would also have
failed to compile against the broken file.

**Lesson.** An undriven signal that gates progress turns into a silent hang
rather than an error. Candidates for a lint rule (undriven nets) and for an
assertion that `rd_free` is never X after reset.

## TB-1: UVM 1.2 macros with the UVM 1.1d library

77 compile errors, "Number of actuals and formals does not match", one on
every `` `uvm_info/`uvm_error/`uvm_fatal `` line. The scripts took the macros
from `verilog_src/uvm-1.2`, but Questa 10.7c's precompiled `mtiUvm` is UVM-1.1d.
The 1.2 macros pass seven arguments to `uvm_report_*`; 1.1d's take six. Fixed by
taking the macros from `uvm-1.1d`.

## TB-2: test timeout read in the wrong timescale

`uvm_root::set_timeout(50ms)` killed every test at 50 µs. The value is
converted to an integer in the caller's timescale (1 ns → 50 000 000) and read
inside the precompiled UVM package, whose unit is 1 ps. Replaced with a
watchdog in the base test's `run_phase`, which waits in the test's own
timescale.

## TB-3: compile list missing the top level

`rtl/files.f` listed 16 files and left out `axi4_slave_if`, `apb_csr` and
`ddr4_ctrl_top`, so `tb_top` could not elaborate. The v0.5 list is complete.

## TB-4: self-refresh check too early at the fast AXI clock

**Symptom.** One failure in 316 runs: `self_refresh_test` seed 3 at
`CLK_SET=fast`, "STATUS.in_self_refresh not set during a long request".

**Decision: testbench, not RTL.** The test read STATUS after a fixed 300 AXI
cycles: 3 µs at the default clock but only 0.75 µs at 400 MHz. A trace of the
failing run showed SRX at 23 037.5 ns, the request re-raised at 23 062.5 ns,
the REF required after an exit at 23 787.5 ns (SRX + tXS, exactly 750 ns),
and entry due after a further tRFC (350 ns). STATUS was read at 24 062.5 ns,
about 75 ns before entry was allowed. The DUT met every rule; the protocol
checker reported nothing.

**Fix.** The bound is computed from the programmed tXS + tRFC + tRP plus
64 controller cycles for the APB clock crossing and queued commands, and
converted to AXI cycles for the clock in use. The check is as strict as before,
and it still runs (26 checks over 5 seeds at the fast clock, bound 574 cycles).

## TB-5: strobe and unsupported-burst stimulus never generated

**Symptom.** None: every test passed. Merged coverage showed zero partial or
zero-strobe writes and zero FIXED or WRAP bursts, even in `axi_strobe_test`
and `axi_unsupported_test`. A single `axi_strobe_test` run had 180 writes, all
with full strobes.

**Cause.** `axi_seq_item` has soft defaults (`strb == 8'hFF`, `burst == INCR`,
`size == 3`). The sequence added `strb dist { 8'hFF := 85, 8'h00 := 15 }`, but
a `dist` only weights values: its hard part is "one of {FF, 00}", which the soft
default also satisfies, so the solver kept it. `!(burst == INCR && size == 3)`
was always met by dropping only the soft `size`, so the burst stayed INCR.

**Fix.** Turn `c_strb` off when a strobe mode is selected, and pick FIXED, WRAP
or narrow INCR explicitly. After the fix, `axi_strobe_test` produced 96 SLVERR
writes (previously 0) and `axi_unsupported_test` 22 FIXED, 12 WRAP and 11
narrow bursts. All passed, so the DUT's error paths behave correctly; they had
simply never been exercised.

**Lesson.** A passing test is only evidence when coverage confirms the stimulus
actually happened.
