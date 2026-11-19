// -----------------------------------------------------------------------------
// ddr4_test_pkg.sv
// -----------------------------------------------------------------------------
package ddr4_test_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import ddr4_pkg::*;
  import ddr4_env_pkg::*;

  `include "ddr4_base_test.sv"
  `include "ddr4_tests.sv"
endpackage
