# AXI4 DDR4 Memory Controller

A synthesizable DDR4 SDRAM controller in SystemVerilog with an AXI4 slave data
interface, an APB register interface, SECDED error correction and a DFI-style
PHY interface.

**Status: RTL complete, simulation-verified against behavioral models.**
It has not been run against a vendor memory model, synthesized, or taken through
CDC or formal analysis. See [Verification status](docs/verification_status.md)
for exactly what has and has not been checked.

## Features

- AXI4 slave, 64-bit data, INCR bursts up to 256 beats
- APB register block: every JEDEC timing parameter, mode-register values and
  latencies are programmable at run time
- DDR4 power-up initialization, auto-refresh with postponement, self-refresh
- Open-page scheduling with one state machine and timer set per bank (16 banks)
- Hsiao (72,64) SECDED ECC on every 64-bit word, with error counters and interrupt
- Two clock domains joined by Gray-pointer asynchronous FIFOs
- DFI-style command, write-data and read-data interface at a 1:4 clock ratio

Target configuration: 8 Gb x8 DDR4 devices (nine of them for a 72-bit bus),
DDR4-1600, 200 MHz controller clock, 100 MHz AXI clock.

## Architecture

```mermaid
flowchart LR
    AXI[AXI4 master] <--> FE[axi4_slave_if]
    APB[APB master] --> CSR[apb_csr]

    subgraph aclk [AXI clock domain]
        FE
        CSR
    end

    FE <--> FIFO[async FIFOs<br/>request, write data, read data]

    subgraph cclk [Controller clock domain: ddr4_core]
        CTRL[ctrl_core<br/>init, refresh, scheduling]
        ECC[ecc_datapath]
        DFI[dfi_if]
        CTRL --> DFI
        ECC <--> DFI
    end

    FIFO --> CTRL
    FIFO <--> ECC
    CSR -. timing and control .-> CTRL
    DFI <--> PHY[DDR PHY and DDR4 devices]
```

A request enters over AXI4, is packed into one memory burst of eight 64-bit
words, crosses into the controller clock domain, and is turned into a legal
sequence of DDR4 commands. Write data gains check bits on the way out; read data
is corrected on the way back.

Inside `ctrl_core`, one arbiter chooses a command each cycle from the guards
supplied by the bank state machines, the cross-bank timers and the refresh
manager:

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> ACTIVATING: ACT
    ACTIVATING --> OPEN: tRCD expires
    OPEN --> OPEN: RD / WR
    OPEN --> PRECHARGING: PRE
    PRECHARGING --> IDLE: tRP expires
    IDLE --> REFRESHING: REF
    REFRESHING --> IDLE: tRFC expires
```

More detail: [Architecture](docs/architecture.md) ·
[Specification](docs/specification.md) · [Register map](docs/register_map.md)

## Repository layout

| Path | Contents |
| --- | --- |
| `rtl/` | Synthesizable RTL (20 files) and `files.f` compile order |
| `tb/` | Self-checking testbenches and the behavioral PHY/memory model |
| `scripts/` | Regression script and the ECC matrix generator |
| `docs/` | Specification, architecture, register map, verification status, bug log |

### RTL files

| File | Purpose |
| --- | --- |
| `ddr4_pkg.sv` | Shared types, command encoding, timing struct, ECC matrix |
| `cdc_cells.sv` | Two-flop synchronizer and reset synchronizer |
| `async_fifo.sv` | Dual-clock FIFO with Gray-coded pointers |
| `sync_fifo.sv` | Single-clock FIFO |
| `addr_map.sv` | AXI address to row, bank group, bank and column |
| `axi4_slave_if.sv` | AXI4 front end: bursts to memory requests and back |
| `apb_csr.sv` | Configuration and status registers, interrupt |
| `bank_fsm.sv` | Per-bank state, open row and timers |
| `global_timers.sv` | Cross-bank and bus-turnaround timers |
| `refresh_mgr.sv` | Pending-refresh accounting |
| `init_fsm.sv` | Power-up and mode-register sequence |
| `lowpower_fsm.sv` | Self-refresh entry and exit |
| `cmd_arbiter.sv` | Priority selection of one legal command per cycle |
| `ctrl_core.sv` | Control path integration |
| `ecc.sv` | Hsiao (72,64) encoder and decoder |
| `ecc_datapath.sv` | Burst-wide ECC (eight words in parallel) |
| `dfi_if.sv` | DFI command and data timing |
| `ddr4_core.sv` | Controller-clock-domain integration |
| `ddr4_ctrl_top.sv` | Top level |

## Running the tests

With Verilator 5.x:

```sh
./scripts/run_sims.sh
```

With Questa:

```sh
vlib work
vlog -sv -f rtl/files.f tb/*.sv
vsim -c tb_async_fifo     -do "run -all; quit"
vsim -c tb_ecc            -do "run -all; quit"
vsim -c tb_timers         -do "run -all; quit"
vsim -c tb_ctrl_core      -do "run -all; quit"
vsim -c tb_ctrl_core -gSTRESS=1 -do "run -all; quit"
vsim -c tb_ddr4_core      -do "run -all; quit"
vsim -c tb_ddr4_ctrl_top  -do "run -all; quit"
```

Each test prints one summary line ending in `PASS` or `FAIL`.

## Verification summary

| Testbench | What it checks |
| --- | --- |
| `tb_async_fifo` | 20,000 random words at three clock ratios; ordering, full, empty, free count |
| `tb_ecc` | Every single-bit error corrected (72), every double-bit error detected (2,556) |
| `tb_timers` | Each timing guard opens in exactly the required cycle |
| `tb_ctrl_core` | 20,000 random requests; an independent protocol monitor checks every command |
| `tb_ddr4_core` | End-to-end data integrity with injected bit errors and read backpressure |
| `tb_ddr4_ctrl_top` | AXI4 and APB traffic through the whole design, including error cases |

The command truth table, initialization order and timing defaults were checked
against the Micron 8 Gb DDR4 SDRAM datasheet (MT40A1G8, Rev. N).

## Known limitations

- AXI: INCR bursts of full-width beats only; a beat is stored only when all
  eight strobes are set. Other cases return SLVERR.
- DFI data timing is cycle-aligned, not phase-accurate.
- No precharge power-down, periodic ZQ calibration, memory initialization or scrubbing.
- Requests are served strictly in order (no look-ahead scheduling).
- Mode-register default opcodes are placeholders and are not verified.

## Roadmap

- [ ] UVM environment with functional coverage
- [ ] Formal proofs: FIFO pointers, bank timers, refresh starvation
- [ ] CDC analysis
- [ ] Synthesis and timing at 200 MHz
- [ ] Phase-accurate DFI write alignment
- [ ] Pin-level PHY model and a run against a vendor DDR4 model

## References

- Micron, *8Gb: x4, x8, x16 DDR4 SDRAM* datasheet (MT40A1G8), Rev. N
- JEDEC JESD79-4, *DDR4 SDRAM Standard*
- DFI Specification, ddr-phy.org
- C. Cummings, "Simulation and Synthesis Techniques for Asynchronous FIFO Design", SNUG 2002
- M. Y. Hsiao, "A Class of Optimal Minimum Odd-weight-column SEC-DED Codes", IBM J. R&D, 1970
- Arm, *AMBA AXI and ACE Protocol Specification*; *AMBA APB Protocol Specification*
