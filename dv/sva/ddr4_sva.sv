// -----------------------------------------------------------------------------
// ddr4_sva.sv
// Assertion modules bound into the DUT without editing the RTL
// (see ddr4_sva_bind.sv). Every assert has a matching cover so a regression
// can show each property was actually exercised.
// -----------------------------------------------------------------------------

// ---------------------------------------------------------------- AXI4 slave
module ddr4_axi_sva
  import ddr4_pkg::*;
#(parameter int ID_W = 4) (
  input logic                  aclk, aresetn,
  input logic [ID_W-1:0]       s_axi_awid,
  input logic [AXI_ADDR_W-1:0] s_axi_awaddr,
  input logic [7:0]            s_axi_awlen,
  input logic [2:0]            s_axi_awsize,
  input logic [1:0]            s_axi_awburst,
  input logic                  s_axi_awvalid, s_axi_awready,
  input logic [DATA_W-1:0]     s_axi_wdata,
  input logic [DATA_W/8-1:0]   s_axi_wstrb,
  input logic                  s_axi_wlast, s_axi_wvalid, s_axi_wready,
  input logic [ID_W-1:0]       s_axi_bid,
  input logic [1:0]            s_axi_bresp,
  input logic                  s_axi_bvalid, s_axi_bready,
  input logic [ID_W-1:0]       s_axi_arid,
  input logic [AXI_ADDR_W-1:0] s_axi_araddr,
  input logic [7:0]            s_axi_arlen,
  input logic [2:0]            s_axi_arsize,
  input logic [1:0]            s_axi_arburst,
  input logic                  s_axi_arvalid, s_axi_arready,
  input logic [ID_W-1:0]       s_axi_rid,
  input logic [DATA_W-1:0]     s_axi_rdata,
  input logic [1:0]            s_axi_rresp,
  input logic                  s_axi_rlast, s_axi_rvalid, s_axi_rready
);
  default clocking cb @(posedge aclk); endclocking
  default disable iff (!aresetn);

  // ---- slave outputs ----
  a_ctrl_known: assert property (!$isunknown({s_axi_awready, s_axi_wready, s_axi_bvalid,
                                              s_axi_arready, s_axi_rvalid}));
  a_b_stable:   assert property (s_axi_bvalid && !s_axi_bready |=>
                                 s_axi_bvalid && $stable({s_axi_bid, s_axi_bresp}));
  a_b_known:    assert property (s_axi_bvalid |-> !$isunknown({s_axi_bid, s_axi_bresp}));
  a_r_stable:   assert property (s_axi_rvalid && !s_axi_rready |=>
                                 s_axi_rvalid && $stable({s_axi_rid, s_axi_rdata, s_axi_rresp, s_axi_rlast}));
  a_r_known:    assert property (s_axi_rvalid |-> !$isunknown({s_axi_rid, s_axi_rdata, s_axi_rresp, s_axi_rlast}));
  a_resp_legal: assert property (s_axi_bvalid |-> s_axi_bresp inside {2'b00, 2'b10});

  // ---- master (testbench driver) side: catches driver bugs ----
  a_aw_stable: assert property (s_axi_awvalid && !s_axi_awready |=> s_axi_awvalid &&
                                $stable({s_axi_awid, s_axi_awaddr, s_axi_awlen, s_axi_awsize, s_axi_awburst}));
  a_w_stable:  assert property (s_axi_wvalid && !s_axi_wready |=> s_axi_wvalid &&
                                $stable({s_axi_wdata, s_axi_wstrb, s_axi_wlast}));
  a_ar_stable: assert property (s_axi_arvalid && !s_axi_arready |=> s_axi_arvalid &&
                                $stable({s_axi_arid, s_axi_araddr, s_axi_arlen, s_axi_arsize, s_axi_arburst}));

  // ---- a write response only after that write's last data beat ----
  int unsigned n_wlast, n_b;
  always_ff @(posedge aclk or negedge aresetn)
    if (!aresetn) begin n_wlast <= 0; n_b <= 0; end
    else begin
      if (s_axi_wvalid && s_axi_wready && s_axi_wlast) n_wlast <= n_wlast + 1;
      if (s_axi_bvalid && s_axi_bready)                n_b     <= n_b + 1;
    end
  a_b_after_wlast: assert property (s_axi_bvalid |-> n_wlast > n_b);

  // ---- RLAST exactly on beat ARLEN ----
  byte unsigned ar_len_q [$];
  int unsigned  r_beat;
  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      ar_len_q.delete();  r_beat = 0;
    end else begin
      if (s_axi_rvalid && s_axi_rready) begin
        if (ar_len_q.size() == 0)
          $error("ddr4_axi_sva: read data with no read address outstanding");
        else begin
          a_rlast_position: assert (s_axi_rlast == (r_beat == ar_len_q[0]))
            else $error("ddr4_axi_sva: RLAST=%0b on beat %0d of a %0d-beat read",
                        s_axi_rlast, r_beat + 1, ar_len_q[0] + 1);
          if (s_axi_rlast) begin void'(ar_len_q.pop_front()); r_beat = 0; end
          else r_beat++;
        end
      end
      if (s_axi_arvalid && s_axi_arready) ar_len_q.push_back(s_axi_arlen);
    end
  end

  c_b_stall:       cover property (s_axi_bvalid && !s_axi_bready ##1 s_axi_bvalid && s_axi_bready);
  c_r_stall:       cover property (s_axi_rvalid && !s_axi_rready ##1 s_axi_rvalid && s_axi_rready);
  c_b_slverr:      cover property (s_axi_bvalid && s_axi_bready && s_axi_bresp == 2'b10);
  c_r_slverr:      cover property (s_axi_rvalid && s_axi_rready && s_axi_rresp == 2'b10);
  c_aw_wait:       cover property (s_axi_awvalid && !s_axi_awready);
  c_ar_wait:       cover property (s_axi_arvalid && !s_axi_arready);
  c_wr_rd_overlap: cover property (s_axi_wvalid && s_axi_wready && s_axi_rvalid && s_axi_rready);
endmodule

// ---------------------------------------------------------------------- APB
module ddr4_apb_sva (
  input logic        aclk, aresetn,
  input logic        psel, penable, pwrite,
  input logic [31:0] prdata,
  input logic        pready, pslverr, irq
);
  default clocking cb @(posedge aclk); endclocking
  default disable iff (!aresetn);

  a_pready_known: assert property (!$isunknown({pready, pslverr, irq}));
  a_prdata_known: assert property (psel && penable && !pwrite |-> !$isunknown(prdata));
  a_no_slverr:    assert property (psel && penable |-> !pslverr);
  a_setup_first:  assert property ($rose(penable) |-> $past(psel && !penable));

  c_read:  cover property (psel && penable && !pwrite);
  c_write: cover property (psel && penable && pwrite);
  c_irq:   cover property ($rose(irq));
endmodule

// ---------------------------------------------------------------------- DFI
module ddr4_dfi_sva
  import ddr4_pkg::*;
(
  input logic                  cclk, crst_n,
  input logic [DFI_PHASES-1:0] dfi_reset_n, dfi_cke, dfi_odt, dfi_cs_n,
  input logic [DFI_PHASES-1:0] dfi_wrdata_en, dfi_rddata_en,
  input logic [DFI_PHASES-1:0] dfi_act_n, dfi_ras_n, dfi_cas_n, dfi_we_n
);
  default clocking cb @(posedge cclk); endclocking
  default disable iff (!crst_n);

  a_known:          assert property (!$isunknown({dfi_reset_n, dfi_cke, dfi_odt, dfi_cs_n,
                                                  dfi_wrdata_en, dfi_rddata_en}));
  a_phase0_only:    assert property (dfi_cs_n[DFI_PHASES-1:1] == '1);
  a_wren_all:       assert property (dfi_wrdata_en == '0 || dfi_wrdata_en == '1);
  a_rden_all:       assert property (dfi_rddata_en == '0 || dfi_rddata_en == '1);
  a_odt_with_write: assert property (dfi_odt == dfi_wrdata_en);
  a_cke_phases:     assert property (dfi_cke == '0 || dfi_cke == '1);
  a_reset_phases:   assert property (dfi_reset_n == '0 || dfi_reset_n == '1);
  a_no_cmd_in_rst:  assert property (!dfi_reset_n[0] |-> dfi_cs_n[0]);
  a_cmd_known:      assert property (!dfi_cs_n[0] |-> !$isunknown({dfi_act_n[0], dfi_ras_n[0],
                                                                  dfi_cas_n[0], dfi_we_n[0]}));

  c_write_data: cover property (dfi_wrdata_en[0]);
  c_read_en:    cover property (dfi_rddata_en[0]);
  c_wr_rd_same: cover property (dfi_wrdata_en[0] && dfi_rddata_en[0]);
  c_cke_low:    cover property ($fell(dfi_cke[0]));
endmodule

// --------------------------------------------- inside ddr4_ctrl_top: FIFOs
module ddr4_internal_sva (
  input logic aclk, arst_n, cclk, crst_n,
  input logic req_push, req_full, wd_push, wd_full, rd_pop, rd_empty,
  input logic req_pop, req_empty, wd_pop, wd_empty, rd_push, rd_full
);
  a_req_no_overflow:  assert property (@(posedge aclk) disable iff (!arst_n) req_push |-> !req_full);
  a_wd_no_overflow:   assert property (@(posedge aclk) disable iff (!arst_n) wd_push  |-> !wd_full);
  a_rd_no_underflow:  assert property (@(posedge aclk) disable iff (!arst_n) rd_pop   |-> !rd_empty);
  a_wr_pushes_paired: assert property (@(posedge aclk) disable iff (!arst_n) wd_push  |-> req_push);
  a_req_no_underflow: assert property (@(posedge cclk) disable iff (!crst_n) req_pop  |-> !req_empty);
  a_wd_no_underflow:  assert property (@(posedge cclk) disable iff (!crst_n) wd_pop   |-> !wd_empty);
  a_rd_no_overflow:   assert property (@(posedge cclk) disable iff (!crst_n) rd_push  |-> !rd_full);

  c_req_full: cover property (@(posedge aclk) disable iff (!arst_n) req_full);
  c_wd_full:  cover property (@(posedge aclk) disable iff (!arst_n) wd_full);
  c_rd_full:  cover property (@(posedge cclk) disable iff (!crst_n) rd_full);
endmodule

// ---------------------------------------------- inside apb_csr: interrupt
module ddr4_csr_sva (
  input logic       pclk, presetn,
  input logic [2:0] int_stat, int_en,
  input logic       irq_o
);
  a_irq: assert property (@(posedge pclk) disable iff (!presetn) irq_o == |(int_stat & int_en));
  c_irq_each: cover property (@(posedge pclk) disable iff (!presetn) irq_o && $onehot(int_stat & int_en));
endmodule
