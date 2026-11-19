# Verification

How `ddr4_ctrl_top` is verified, what has been checked, and what is still open.

## Summary

| Item | Result |
| --- | --- |
| UVM regression | **316 / 316 runs pass**: 21 tests, 79 runs per clock ratio, 4 clock ratios |
| Functional coverage (merged) | **97.0 %**: 8 of 12 covergroups at 100 % |
| Code coverage (merged, RTL) | **89.7 %** (statement, branch, condition, expression, FSM, toggle) |
| Assertions | **92 / 92** pass, each with a matching cover |
| Directed testbenches (`tb/`) | All 7 configurations pass in Questa on the v0.5 RTL (Verilator not rerun since v0.5) |

Simulator: Questa 10.7c, UVM 1.1d (`mtiUvm`). Date of the results: 2026-11-19.

## Environment

```
 AXI4 agent ───►┌──────────────────────────┐◄──► DFI agent
 (master)       │       ddr4_ctrl_top      │     monitor + PHY/DRAM responder
 APB agent ────►│  (AXI 100 MHz / ctl 200) │     (stores writes, returns reads,
 + register     └────────────┬─────────────┘      injects ECC errors)
   model                     │ probe: request-FIFO push
                             ▼
     scoreboard · DDR4 protocol checker · functional coverage · SVA
```

| Component | Role |
| --- | --- |
| AXI agent (`dv/agents/axi`) | Drives write and read bursts on independent threads, with configurable BREADY/RREADY backpressure. Changes signals on the falling edge and samples on the rising edge |
| APB agent + RAL (`dv/agents/apb`, `dv/ral`) | Programs and reads the 42 registers through a UVM register model with explicit prediction |
| DFI agent (`dv/agents/dfi`) | The monitor decodes every command from the pins (Micron truth table, Table 23). The responder acts as the PHY and DRAM, checks write-data and read-enable latencies, and injects single- and double-bit errors |
| Scoreboard (`dv/env/ddr4_scoreboard.sv`) | Rebuilds the expected chunk sequence from each AXI burst and orders reads and writes by the request-FIFO push, the point that decides the order in which they take effect. Checks chunking, word masks, data, BRESP/RRESP, and predicts the ECC counters and interrupt bits |
| Protocol checker (`dv/env/ddr4_protocol_checker.sv`) | Independent DDR4 model: every command is judged against the programmed timing by subtracting cycle stamps; it never reads the RTL's own counters. Covers tRCD, tRP, tRAS, tRC, tRTP, tWR, tRRD_S/L, tFAW, tCCD_S/L, tWTR_S/L, tMRD, tMOD, tZQinit, tXS, tCKESR, refresh debt (≤ 8 postponed), initialization order, self-refresh rules |
| Coverage (`dv/env/ddr4_coverage.sv`) | 12 covergroups, including crosses of burst length × start word, error kind × word, every ECC bit × word (576 bins), register × direction |
| SVA (`dv/sva`) | 92 assertions bound into the RTL without editing it (AXI/APB handshakes, DFI, internal FIFO and timer invariants) |

Each run is repeated at four clock ratios, because the AXI-to-controller ratio
changes the clock-crossing behaviour and how often refresh is postponed:
`fast` (AXI 400 MHz), `equal` (200 MHz), `slow` (100 MHz), `odd` (~94 MHz).
The controller clock is always 200 MHz.

## Tests

| Test | Seeds | What it does |
| --- | --- | --- |
| `sanity_test` | 1 | One write and one read after initialization |
| `reg_reset_test` | 1 | Every register's reset value |
| `reg_bitbash_test` | 1 | Every read-write bit can be set and cleared |
| `init_test` | 3 | Power-up with randomized init waits, three times, with traffic in between |
| `axi_rand_test` | 5 | Random legal traffic, all lengths and start words |
| `axi_strobe_test` | 3 | WSTRB 0xFF, 0x00 and partial values |
| `axi_unsupported_test` | 3 | FIXED, WRAP and narrow bursts mixed with legal ones |
| `axi_backpressure_test` | 3 | Slow and stalling BREADY / RREADY |
| `concurrent_rw_test` | 3 | Reads and writes from two sequences at once on a small address window |
| `page_policy_test` | 3 | Row hits, row misses and empty banks in every bank |
| `timing_stress_test` | 3 | Widened cross-bank timing so tRRD, tFAW and tCCD become the limiting rules |
| `timing_sweep_test` | 10 | One timing register above its minimum per run |
| `refresh_test` | 5 | Short refresh interval: refresh under load, when idle, at the urgent limit |
| `self_refresh_test` | 5 | Self-refresh entry/exit with traffic waiting, withdrawn requests, re-entry straight after an exit |
| `ecc_single_test` | 2 | Single-bit errors at every bit of every word, plus random ones |
| `ecc_double_test` | 3 | Double-bit errors at increasing rates |
| `ecc_counter_sat_test` | 2 | Error counters saturate at 2^32 − 1 |
| `interrupt_test` | 2 | Each interrupt cause with its enable off and on, then cleared |
| `latency_test` | 8 | Random DFI write, read-enable and PHY read latencies |
| `reset_test` | 3 | Reset in the middle of traffic, then full recovery |
| `random_all_test` | 10 | Everything randomized: latencies, refresh, strobes, unsupported bursts, backpressure, errors |

How to run them: [dv/README.md](../dv/README.md).

## Coverage

Functional coverage, merged over all 316 runs:

| Covergroup | Coverage | Covergroup | Coverage |
| --- | --- | --- | --- |
| AXI writes | 95.4 % | Refresh debt at each REF | 100 % |
| AXI reads | 100 % | Self-refresh entry / exit | 100 % / 100 % |
| DFI commands and sequences | 100 % | ECC (kind × word × mask) | 100 % |
| Binding timing rule | 94.4 % | ECC single-bit position (72 × 8) | 100 % |
| Registers × direction | 95.8 % | ECC double-bit pairs | 100 % |
| Configuration | 78.1 % | | |

Coverage has already found one stimulus bug: the strobe and unsupported-burst
tests passed while generating none of the traffic they exist for (see
[bug_log.md](bug_log.md), TB-5).

## Open items

Functional coverage holes, each traced to its cause:

1. **ECC counter clear and read-only STATUS are never written.** "Any write
   clears ECC_CE / ECC_UE" and "writes to STATUS are ignored" are unverified;
   bit-bash excludes these registers on purpose. Needs a directed test.
2. **`latency_test` reaches only 8 configurations.** Latencies are drawn from
   the seed, and the seed is the same at every clock ratio, so write latency
   0, 1, 4 and read-enable latency 0, 1, 4, 6 are never used. Needs a
   deterministic sweep.
3. **FIXED/WRAP bursts with narrow beats.** The unsupported-burst knob picks one
   kind at a time, so the combination never occurs.
4. **256-beat bursts at start words 0, 2, 4–7.** Legal under the 4 KB rule but
   rare with random lengths; needs a few directed bursts.
5. **tRFC is never the binding rule.** After a REFRESH a bank returns to IDLE one
   cycle after the tRFC counter expires (`bank_fsm` waits for the registered
   `ref_done`, while the precharge path looks ahead), so every refresh costs
   tRFC + 1 cycle. This is legal and costs about 0.06 % of bandwidth, but it is
   an asymmetry: either fix it with a look-ahead or document it and exclude the bin.

Code coverage: the low spots are condition coverage in `refresh_mgr` (20 %) and
`apb_csr` (50 %), toggle coverage in `lowpower_fsm` (48 %) and `cmd_arbiter`
(63 %), and FSM coverage in `init_fsm` (78 %). They have not yet been sorted
into missing tests versus logic that cannot be reached by design.

Beyond simulation, not done: a run against a vendor DDR4 model, formal proofs,
CDC analysis, synthesis.
