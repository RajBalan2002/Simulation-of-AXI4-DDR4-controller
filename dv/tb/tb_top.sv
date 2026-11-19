// -----------------------------------------------------------------------------
// tb_top.sv
// UVM top: clocks, interfaces, DUT, config_db handoff, run_test().
//
// Clock settings (+CLK_SET=...), controller clock fixed at 200 MHz:
//   fast  : aclk 400 MHz  (2.5 ns)
//   equal : aclk 200 MHz  (5.0 ns)
//   slow  : aclk 100 MHz  (10.0 ns)  default
//   odd   : aclk ~94 MHz  (10.6 ns)  unrelated ratio
// The same table is in ddr4_env_cfg::read_plusargs().
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import ddr4_pkg::*;
  import ddr4_test_pkg::*;

  localparam int ID_W = 4;

  // ------------------------------------------------------------------ clocks
  real  aclk_half = 5.0;
  real  cclk_half = 2.5;
  logic aclk = 1'b0;
  logic cclk = 1'b0;

  initial begin
    static string s = "slow";
    void'($value$plusargs("CLK_SET=%s", s));
    case (s)
      "fast":  aclk_half = 1.25;
      "equal": aclk_half = 2.5;
      "slow":  aclk_half = 5.0;
      "odd":   aclk_half = 5.3;
      default: aclk_half = 5.0;   // ddr4_env_cfg reports the bad value
    endcase
  end

  always #(aclk_half) aclk = ~aclk;
  always #(cclk_half) cclk = ~cclk;

  // -------------------------------------------------------------- interfaces
  ddr4_ctrl_if             ctrl_if (.aclk(aclk), .cclk(cclk));
  ddr4_axi_if #(.ID_W(ID_W)) axi_if (.aclk(aclk), .aresetn(ctrl_if.aresetn));
  ddr4_apb_if              apb_if (.pclk(aclk), .presetn(ctrl_if.aresetn));
  ddr4_dfi_if              dfi_if (.cclk(cclk), .crst_n(ctrl_if.crst_n));
  ddr4_probe_if            probe_if (.aclk(aclk), .cclk(cclk));

  // --------------------------------------------------------------------- DUT
  ddr4_ctrl_top #(.ID_W(ID_W), .AUTO_START(1'b0)) dut (
    .aclk(aclk), .aresetn(ctrl_if.aresetn),
    .cclk(cclk), .crst_n(ctrl_if.crst_n),

    .s_axi_awid(axi_if.awid),       .s_axi_awaddr(axi_if.awaddr),
    .s_axi_awlen(axi_if.awlen),     .s_axi_awsize(axi_if.awsize),
    .s_axi_awburst(axi_if.awburst), .s_axi_awvalid(axi_if.awvalid),
    .s_axi_awready(axi_if.awready),
    .s_axi_wdata(axi_if.wdata),     .s_axi_wstrb(axi_if.wstrb),
    .s_axi_wlast(axi_if.wlast),     .s_axi_wvalid(axi_if.wvalid),
    .s_axi_wready(axi_if.wready),
    .s_axi_bid(axi_if.bid),         .s_axi_bresp(axi_if.bresp),
    .s_axi_bvalid(axi_if.bvalid),   .s_axi_bready(axi_if.bready),
    .s_axi_arid(axi_if.arid),       .s_axi_araddr(axi_if.araddr),
    .s_axi_arlen(axi_if.arlen),     .s_axi_arsize(axi_if.arsize),
    .s_axi_arburst(axi_if.arburst), .s_axi_arvalid(axi_if.arvalid),
    .s_axi_arready(axi_if.arready),
    .s_axi_rid(axi_if.rid),         .s_axi_rdata(axi_if.rdata),
    .s_axi_rresp(axi_if.rresp),     .s_axi_rlast(axi_if.rlast),
    .s_axi_rvalid(axi_if.rvalid),   .s_axi_rready(axi_if.rready),

    .psel(apb_if.psel),     .penable(apb_if.penable), .pwrite(apb_if.pwrite),
    .paddr(apb_if.paddr),   .pwdata(apb_if.pwdata),   .prdata(apb_if.prdata),
    .pready(apb_if.pready), .pslverr(apb_if.pslverr), .irq(apb_if.irq),

    .dfi_init_complete(dfi_if.init_complete),
    .dfi_reset_n(dfi_if.reset_n),   .dfi_cke(dfi_if.cke),     .dfi_odt(dfi_if.odt),
    .dfi_cs_n(dfi_if.cs_n),         .dfi_act_n(dfi_if.act_n),
    .dfi_ras_n(dfi_if.ras_n),       .dfi_cas_n(dfi_if.cas_n), .dfi_we_n(dfi_if.we_n),
    .dfi_bg(dfi_if.bg),             .dfi_ba(dfi_if.ba),       .dfi_address(dfi_if.address),
    .dfi_wrdata_en(dfi_if.wrdata_en), .dfi_wrdata(dfi_if.wrdata),
    .dfi_wrdata_mask(dfi_if.wrdata_mask),
    .dfi_rddata_en(dfi_if.rddata_en), .dfi_rddata(dfi_if.rddata),
    .dfi_rddata_valid(dfi_if.rddata_valid)
  );

  // ------------------------------------------------- white-box probe taps
  assign probe_if.arst_n    = dut.arst_n;
  assign probe_if.req_push  = dut.req_push;
  assign probe_if.req       = dut.req_w;
  assign probe_if.wd        = dut.wd_w;
  assign probe_if.crst_n    = dut.crst_sync_n;
  assign probe_if.init_done = dut.init_done_c;
  assign probe_if.sr_req    = dut.sr_req_c;
  assign probe_if.in_sr     = dut.in_sr_c;
  assign probe_if.ref_ovf   = dut.ref_ovf_c;

  // force/release keeps the value on the variable until the RTL next assigns it
  initial forever begin
    @(posedge probe_if.force_req);
    force dut.u_csr.ce_cnt = probe_if.force_ce;
    force dut.u_csr.ue_cnt = probe_if.force_ue;
    @(negedge aclk);
    release dut.u_csr.ce_cnt;
    release dut.u_csr.ue_cnt;
  end

  // ------------------------------------------------------------- UVM handoff
  initial begin
    uvm_config_db#(virtual ddr4_ctrl_if)::set(null, "uvm_test_top", "ctrl_vif", ctrl_if);
    uvm_config_db#(virtual ddr4_axi_if )::set(null, "uvm_test_top", "axi_vif",  axi_if);
    uvm_config_db#(virtual ddr4_apb_if  )::set(null, "uvm_test_top", "apb_vif",  apb_if);
    uvm_config_db#(virtual ddr4_dfi_if  )::set(null, "uvm_test_top", "dfi_vif",  dfi_if);
    uvm_config_db#(virtual ddr4_probe_if)::set(null, "uvm_test_top", "probe_vif", probe_if);
    run_test("ddr4_base_test");
  end
endmodule
