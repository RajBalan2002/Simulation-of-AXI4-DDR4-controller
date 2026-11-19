// -----------------------------------------------------------------------------
// ddr4_axi_if.sv
// AXI4 bus between the UVM master agent and ddr4_ctrl_top's slave port.
//
// Timing convention used by every component that touches this interface:
//   - drivers change signals on the falling edge of aclk
//   - monitors sample on the rising edge of aclk
// This keeps driver and DUT from racing on the same edge (see bug_log.md,
// the AXI double-acceptance issue in the directed testbench).
// -----------------------------------------------------------------------------
interface ddr4_axi_if
  import ddr4_pkg::*;
#(
  parameter int ID_W = 4
) (
  input logic aclk,
  input logic aresetn
);
  // write address
  logic [ID_W-1:0]       awid    = '0;
  logic [AXI_ADDR_W-1:0] awaddr  = '0;
  logic [7:0]            awlen   = '0;
  logic [2:0]            awsize  = 3'd3;
  logic [1:0]            awburst = 2'b01;
  logic                  awvalid = 1'b0;
  logic                  awready;
  // write data
  logic [DATA_W-1:0]     wdata   = '0;
  logic [DATA_W/8-1:0]   wstrb   = '0;
  logic                  wlast   = 1'b0;
  logic                  wvalid  = 1'b0;
  logic                  wready;
  // write response
  logic [ID_W-1:0]       bid;
  logic [1:0]            bresp;
  logic                  bvalid;
  logic                  bready  = 1'b1;
  // read address
  logic [ID_W-1:0]       arid    = '0;
  logic [AXI_ADDR_W-1:0] araddr  = '0;
  logic [7:0]            arlen   = '0;
  logic [2:0]            arsize  = 3'd3;
  logic [1:0]            arburst = 2'b01;
  logic                  arvalid = 1'b0;
  logic                  arready;
  // read data
  logic [ID_W-1:0]       rid;
  logic [DATA_W-1:0]     rdata;
  logic [1:0]            rresp;
  logic                  rlast;
  logic                  rvalid;
  logic                  rready  = 1'b1;

  // Return every master-driven signal to idle. Called after reset.
  task automatic idle();
    awvalid = 1'b0;  wvalid = 1'b0;  arvalid = 1'b0;
    wlast   = 1'b0;  wstrb  = '0;
    bready  = 1'b1;  rready = 1'b1;
  endtask
endinterface
