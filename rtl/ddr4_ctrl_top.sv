// -----------------------------------------------------------------------------
// ddr4_ctrl_top.sv
// AXI4 DDR4 memory controller, top level.
//
//   aclk domain : AXI4 slave front end, APB registers
//   cclk domain : ddr4_core (scheduling, ECC, DFI)
//   crossings   : three data FIFOs and one event FIFO (async_fifo), plus
//                 two-flop synchronizers for single-bit control and status
//
// Multi-bit configuration from apb_csr crosses without synchronizers and must
// be treated as quasi-static (constrain as false paths; see apb_csr).
// -----------------------------------------------------------------------------
module ddr4_ctrl_top
  import ddr4_pkg::*;
#(
  parameter int ID_W       = 4,
  parameter int REQ_AW     = 4,     // request FIFO depth  = 2**REQ_AW
  parameter int WD_AW      = 4,     // write-data FIFO depth
  parameter int RD_AW      = 4,     // read-data FIFO depth
  parameter bit AUTO_START = 1'b1
) (
  // AXI / APB clock domain
  input  logic                    aclk,
  input  logic                    aresetn,       // asynchronous, active low
  // controller clock domain
  input  logic                    cclk,
  input  logic                    crst_n,        // asynchronous, active low

  // AXI4 slave
  input  logic [ID_W-1:0]         s_axi_awid,
  input  logic [AXI_ADDR_W-1:0]   s_axi_awaddr,
  input  logic [7:0]              s_axi_awlen,
  input  logic [2:0]              s_axi_awsize,
  input  logic [1:0]              s_axi_awburst,
  input  logic                    s_axi_awvalid,
  output logic                    s_axi_awready,
  input  logic [DATA_W-1:0]       s_axi_wdata,
  input  logic [DATA_W/8-1:0]     s_axi_wstrb,
  input  logic                    s_axi_wlast,
  input  logic                    s_axi_wvalid,
  output logic                    s_axi_wready,
  output logic [ID_W-1:0]         s_axi_bid,
  output logic [1:0]              s_axi_bresp,
  output logic                    s_axi_bvalid,
  input  logic                    s_axi_bready,
  input  logic [ID_W-1:0]         s_axi_arid,
  input  logic [AXI_ADDR_W-1:0]   s_axi_araddr,
  input  logic [7:0]              s_axi_arlen,
  input  logic [2:0]              s_axi_arsize,
  input  logic [1:0]              s_axi_arburst,
  input  logic                    s_axi_arvalid,
  output logic                    s_axi_arready,
  output logic [ID_W-1:0]         s_axi_rid,
  output logic [DATA_W-1:0]       s_axi_rdata,
  output logic [1:0]              s_axi_rresp,
  output logic                    s_axi_rlast,
  output logic                    s_axi_rvalid,
  input  logic                    s_axi_rready,

  // APB slave (clocked by aclk)
  input  logic                    psel,
  input  logic                    penable,
  input  logic                    pwrite,
  input  logic [11:0]             paddr,
  input  logic [31:0]             pwdata,
  output logic [31:0]             prdata,
  output logic                    pready,
  output logic                    pslverr,
  output logic                    irq,

  // DFI (clocked by cclk)
  input  logic                              dfi_init_complete,
  output logic [DFI_PHASES-1:0]             dfi_reset_n,
  output logic [DFI_PHASES-1:0]             dfi_cke,
  output logic [DFI_PHASES-1:0]             dfi_odt,
  output logic [DFI_PHASES-1:0]             dfi_cs_n,
  output logic [DFI_PHASES-1:0]             dfi_act_n,
  output logic [DFI_PHASES-1:0]             dfi_ras_n,
  output logic [DFI_PHASES-1:0]             dfi_cas_n,
  output logic [DFI_PHASES-1:0]             dfi_we_n,
  output logic [DFI_PHASES-1:0][BG_W-1:0]   dfi_bg,
  output logic [DFI_PHASES-1:0][BA_W-1:0]   dfi_ba,
  output logic [DFI_PHASES-1:0][13:0]       dfi_address,
  output logic [DFI_PHASES-1:0]             dfi_wrdata_en,
  output logic [BURST_CODE_W-1:0]           dfi_wrdata,
  output logic [BURST_WORDS*9-1:0]          dfi_wrdata_mask,
  output logic [DFI_PHASES-1:0]             dfi_rddata_en,
  input  logic [BURST_CODE_W-1:0]           dfi_rddata,
  input  logic [DFI_PHASES-1:0]             dfi_rddata_valid
);
  localparam int INIT_CNT_W = 20;
  localparam int REFI_W     = 16;
  localparam int FREE_W     = 8;
  localparam int RDW        = BURST_WORDS + BURST_DATA_W;   // 520
  localparam int EVT_AW     = 4;

  // --------------------------------- resets ---------------------------------
  logic arst_n, crst_sync_n;
  reset_sync u_rst_a (.clk(aclk), .arst_n(aresetn), .rst_n(arst_n));
  reset_sync u_rst_c (.clk(cclk), .arst_n(crst_n),  .rst_n(crst_sync_n));

  // ------------------------------ aclk: AXI side ----------------------------
  logic                     req_push, req_full, wd_push, wd_full, rd_pop, rd_empty;
  req_t                     req_w;
  logic [BURST_DATA_W-1:0]  wd_w;
  logic [RDW-1:0]           rd_r;

  axi4_slave_if #(.ID_W(ID_W)) u_axi (
    .aclk(aclk), .aresetn(arst_n),
    .awid(s_axi_awid), .awaddr(s_axi_awaddr), .awlen(s_axi_awlen), .awsize(s_axi_awsize),
    .awburst(s_axi_awburst), .awvalid(s_axi_awvalid), .awready(s_axi_awready),
    .wdata(s_axi_wdata), .wstrb(s_axi_wstrb), .wlast(s_axi_wlast),
    .wvalid(s_axi_wvalid), .wready(s_axi_wready),
    .bid(s_axi_bid), .bresp(s_axi_bresp), .bvalid(s_axi_bvalid), .bready(s_axi_bready),
    .arid(s_axi_arid), .araddr(s_axi_araddr), .arlen(s_axi_arlen), .arsize(s_axi_arsize),
    .arburst(s_axi_arburst), .arvalid(s_axi_arvalid), .arready(s_axi_arready),
    .rid(s_axi_rid), .rdata(s_axi_rdata), .rresp(s_axi_rresp), .rlast(s_axi_rlast),
    .rvalid(s_axi_rvalid), .rready(s_axi_rready),
    .req_push_o(req_push), .req_o(req_w), .req_full_i(req_full),
    .wd_push_o(wd_push), .wd_o(wd_w), .wd_full_i(wd_full),
    .rd_empty_i(rd_empty), .rd_i(rd_r), .rd_pop_o(rd_pop)
  );

  // ----------------------------- aclk: registers ----------------------------
  timing_t                 cfg_t;
  logic [INIT_CNT_W-1:0]   cfg_t_rst, cfg_t_cke, cfg_t_xpr, cfg_t_dllk;
  logic [6:0][13:0]        cfg_mr;
  logic [REFI_W-1:0]       cfg_t_refi;
  logic [3:0]              cfg_ref_thresh;
  tcnt_t                   cfg_t_ckesr;
  logic [2:0]              cfg_wr_lat, cfg_rden_lat;
  logic                    sr_req_a, init_start_a;
  logic                    init_done_a, in_sr_a, ref_ovf_a;
  logic                    evt_empty;
  logic [7:0]              evt_r;

  apb_csr #(.INIT_CNT_W(INIT_CNT_W), .REFI_W(REFI_W), .AUTO_START(AUTO_START)) u_csr (
    .pclk(aclk), .presetn(arst_n),
    .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
    .prdata(prdata), .pready(pready), .pslverr(pslverr),
    .t_o(cfg_t), .t_rst_o(cfg_t_rst), .t_cke_o(cfg_t_cke), .t_xpr_o(cfg_t_xpr),
    .t_dllk_o(cfg_t_dllk), .mr_o(cfg_mr), .t_refi_o(cfg_t_refi),
    .ref_thresh_o(cfg_ref_thresh), .t_ckesr_o(cfg_t_ckesr),
    .wr_lat_o(cfg_wr_lat), .rden_lat_o(cfg_rden_lat),
    .sr_req_o(sr_req_a), .init_start_o(init_start_a),
    .init_done_i(init_done_a), .in_self_refresh_i(in_sr_a), .ref_overflow_i(ref_ovf_a),
    .ecc_evt_i(!evt_empty), .ecc_ce_cnt_i(evt_r[3:0]), .ecc_ue_cnt_i(evt_r[7:4]),
    .irq_o(irq)
  );

  // ----------------------------- clock crossings ----------------------------
  // aclk -> cclk
  logic                     req_empty, req_pop, wd_empty, wd_pop;
  logic [REQ_W-1:0]         req_r_bits;
  req_t                     req_r;
  logic [BURST_DATA_W-1:0]  wd_r;
  assign req_r = req_t'(req_r_bits);

  async_fifo #(.DATA_W(REQ_W), .ADDR_W(REQ_AW)) u_req_fifo (
    .wclk(aclk), .wrst_n(arst_n), .winc(req_push), .wdata(req_w), .wfull(req_full), .wfree(),
    .rclk(cclk), .rrst_n(crst_sync_n), .rinc(req_pop), .rdata(req_r_bits), .rempty(req_empty));

  async_fifo #(.DATA_W(BURST_DATA_W), .ADDR_W(WD_AW)) u_wd_fifo (
    .wclk(aclk), .wrst_n(arst_n), .winc(wd_push), .wdata(wd_w), .wfull(wd_full), .wfree(),
    .rclk(cclk), .rrst_n(crst_sync_n), .rinc(wd_pop), .rdata(wd_r), .rempty(wd_empty));

  // cclk -> aclk
  logic            rd_push, rd_full;
  logic [RDW-1:0]  rd_w;
  logic [RD_AW:0]  rd_free;

  async_fifo #(.DATA_W(RDW), .ADDR_W(RD_AW)) u_rd_fifo (
    .wclk(cclk), .wrst_n(crst_sync_n), .winc(rd_push), .wdata(rd_w), .wfull(rd_full), .wfree(rd_free),
    .rclk(aclk), .rrst_n(arst_n), .rinc(rd_pop), .rdata(rd_r), .rempty(rd_empty));

  // ECC events: {ue_cnt, ce_cnt}. Only non-zero events are sent. If the FIFO
  // is ever full the event is dropped, so the counters are a lower bound.
  logic        ecc_evt_c, evt_full;
  logic [3:0]  ecc_ce_c, ecc_ue_c;

  async_fifo #(.DATA_W(8), .ADDR_W(EVT_AW)) u_evt_fifo (
    .wclk(cclk), .wrst_n(crst_sync_n),
    .winc(ecc_evt_c && ((ecc_ce_c != '0) || (ecc_ue_c != '0)) && !evt_full),
    .wdata({ecc_ue_c, ecc_ce_c}), .wfull(evt_full), .wfree(),
    .rclk(aclk), .rrst_n(arst_n), .rinc(!evt_empty), .rdata(evt_r), .rempty(evt_empty));

  // single-bit control, aclk -> cclk
  logic sr_req_c, init_start_c;
  sync_ff #(.WIDTH(2)) u_sync_ctl (
    .clk(cclk), .rst_n(crst_sync_n), .d({init_start_a, sr_req_a}), .q({init_start_c, sr_req_c}));

  // single-bit status, cclk -> aclk
  logic init_done_c, in_sr_c, ref_ovf_c;
  sync_ff #(.WIDTH(3)) u_sync_sts (
    .clk(aclk), .rst_n(arst_n), .d({ref_ovf_c, in_sr_c, init_done_c}),
    .q({ref_ovf_a, in_sr_a, init_done_a}));

  // ------------------------------ cclk: the core ----------------------------
  ddr4_core #(.INIT_CNT_W(INIT_CNT_W), .REFI_W(REFI_W), .FREE_W(FREE_W)) u_core (
    .clk(cclk), .rst_n(crst_sync_n),
    .t_i(cfg_t), .t_rst_i(cfg_t_rst), .t_cke_i(cfg_t_cke), .t_xpr_i(cfg_t_xpr),
    .t_dllk_i(cfg_t_dllk), .mr_i(cfg_mr), .t_refi_i(cfg_t_refi),
    .ref_thresh_i(cfg_ref_thresh), .t_ckesr_i(cfg_t_ckesr),
    .wr_lat_i(cfg_wr_lat), .rden_lat_i(cfg_rden_lat), .sr_req_i(sr_req_c),
    .req_valid_i(!req_empty), .req_i(req_r), .req_pop_o(req_pop),
    .wdata_valid_i(!wd_empty), .wdata_i(wd_r), .wdata_pop_o(wd_pop),
    .rdata_push_o(rd_push), .rdata_o(rd_w),
    .rdata_free_i({{(FREE_W-RD_AW-1){1'b0}}, rd_free}),
    .dfi_init_complete(dfi_init_complete && init_start_c),
    .dfi_reset_n(dfi_reset_n), .dfi_cke(dfi_cke), .dfi_odt(dfi_odt),
    .dfi_cs_n(dfi_cs_n), .dfi_act_n(dfi_act_n), .dfi_ras_n(dfi_ras_n),
    .dfi_cas_n(dfi_cas_n), .dfi_we_n(dfi_we_n), .dfi_bg(dfi_bg), .dfi_ba(dfi_ba),
    .dfi_address(dfi_address), .dfi_wrdata_en(dfi_wrdata_en), .dfi_wrdata(dfi_wrdata),
    .dfi_wrdata_mask(dfi_wrdata_mask), .dfi_rddata_en(dfi_rddata_en),
    .dfi_rddata(dfi_rddata), .dfi_rddata_valid(dfi_rddata_valid),
    .init_done_o(init_done_c), .in_self_refresh_o(in_sr_c),
    .ref_overflow_o(ref_ovf_c), .ref_pending_o(),
    .ecc_evt_o(ecc_evt_c), .ecc_ce_cnt_o(ecc_ce_c), .ecc_ue_cnt_o(ecc_ue_c)
  );

`ifndef SYNTHESIS
  a_rd_fifo_never_full: assert property (@(posedge cclk) disable iff (!crst_sync_n)
                                         rd_push |-> !rd_full)
    else $error("ddr4_ctrl_top: read data pushed into a full FIFO");
`endif
endmodule
