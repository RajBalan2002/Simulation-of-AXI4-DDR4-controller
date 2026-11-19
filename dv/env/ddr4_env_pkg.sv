// -----------------------------------------------------------------------------
// ddr4_env_pkg.sv
// The whole UVM environment: types, config, agents, RAL, checkers, coverage,
// sequences. Include paths: dv/env dv/agents/* dv/ral dv/seq
// -----------------------------------------------------------------------------
package ddr4_env_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import ddr4_pkg::*;

  `include "ddr4_types.sv"
  `include "ddr4_env_cfg.sv"
  // agents
  `include "axi_seq_item.sv"
  `include "axi_driver.sv"
  `include "axi_monitor.sv"
  `include "axi_agent.sv"
  `include "apb_agent.sv"
  `include "dfi_agent.sv"
  // registers
  `include "ddr4_ral.sv"
  // judges
  `include "ddr4_scoreboard.sv"
  `include "ddr4_protocol_checker.sv"
  `include "ddr4_coverage.sv"
  // environment and sequences
  `include "ddr4_env.sv"
  `include "ddr4_seq_lib.sv"
endpackage
