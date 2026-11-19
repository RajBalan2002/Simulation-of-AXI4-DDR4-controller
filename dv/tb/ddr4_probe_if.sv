// -----------------------------------------------------------------------------
// ddr4_probe_if.sv
// White-box signals the testbench reads from inside the DUT. tb_top drives
// them with hierarchical assigns. Nothing here is driven back into the DUT
// except through force_ecc_counts(), used only by ecc_counter_sat_test.
//
//   aclk side : request-FIFO and write-data-FIFO pushes. The scoreboard uses
//               the push order as the order in which reads and writes take
//               effect, which is how the controller serialises them.
//   cclk side : synchronised control/status the protocol checker needs.
// -----------------------------------------------------------------------------
interface ddr4_probe_if
  import ddr4_pkg::*;
(
  input logic aclk,
  input logic cclk
);
  // aclk domain
  logic                    arst_n;        // reset after the synchroniser
  logic                    req_push;
  req_t                    req;
  logic [BURST_DATA_W-1:0] wd;
  // cclk domain
  logic                    crst_n;        // reset after the synchroniser
  logic                    init_done;
  logic                    sr_req;
  logic                    in_sr;
  logic                    ref_ovf;

  // Preload the saturating ECC counters (ecc_counter_sat_test). tb_top does
  // the force/release when force_req pulses; a virtual interface may not
  // reach into the DUT itself.
  logic [31:0] force_ce = '0;
  logic [31:0] force_ue = '0;
  logic        force_req = 1'b0;

  task automatic force_ecc_counts(input logic [31:0] ce, input logic [31:0] ue);
    @(negedge aclk);
    force_ce  = ce;
    force_ue  = ue;
    force_req = 1'b1;
    @(negedge aclk);
    @(negedge aclk);
    force_req = 1'b0;
  endtask
endinterface
