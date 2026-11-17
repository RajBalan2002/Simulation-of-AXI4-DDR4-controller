// -----------------------------------------------------------------------------
// ddr4_core.sv
// Everything in the controller clock domain: control path, ECC and DFI.
// The asynchronous FIFOs, AXI front end and registers attach around this.
//
//   request FIFO  -> req_*    (read side)
//   write FIFO    -> wdata_*  (read side)
//   read FIFO     <- rdata_*  (write side); rdata_free_i is its free-slot count
//
// Read bursts in flight are counted so that the read FIFO can never overflow:
// a read is only issued while (bursts in flight) < (free slots).
// -----------------------------------------------------------------------------
module ddr4_core
  import ddr4_pkg::*;
#(
  parameter int INIT_CNT_W = 20,
  parameter int REFI_W     = 16,
  parameter int FREE_W     = 8,     // width of rdata_free_i
  parameter int TAG_ADDR_W = 5      // 32 read bursts may be in flight
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // configuration (quasi-static)
  input  var timing_t             t_i,
  input  logic [INIT_CNT_W-1:0]   t_rst_i,
  input  logic [INIT_CNT_W-1:0]   t_cke_i,
  input  logic [INIT_CNT_W-1:0]   t_xpr_i,
  input  logic [INIT_CNT_W-1:0]   t_dllk_i,
  input  logic [6:0][13:0]        mr_i,
  input  logic [REFI_W-1:0]       t_refi_i,
  input  logic [3:0]              ref_thresh_i,
  input  var tcnt_t               t_ckesr_i,
  input  logic [2:0]              wr_lat_i,
  input  logic [2:0]              rden_lat_i,
  input  logic                    sr_req_i,

  // request FIFO, read side
  input  logic                    req_valid_i,
  input  var req_t                req_i,
  output logic                    req_pop_o,

  // write-data FIFO, read side
  input  logic                    wdata_valid_i,
  input  logic [BURST_DATA_W-1:0] wdata_i,
  output logic                    wdata_pop_o,

  // read-data FIFO, write side: {ue[7:0], data[511:0]}
  output logic                    rdata_push_o,
  output logic [BURST_WORDS+BURST_DATA_W-1:0] rdata_o,
  input  logic [FREE_W-1:0]       rdata_free_i,

  // DFI
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
  input  logic [DFI_PHASES-1:0]             dfi_rddata_valid,

  // status
  output logic                    init_done_o,
  output logic                    in_self_refresh_o,
  output logic                    ref_overflow_o,
  output logic [3:0]              ref_pending_o,
  output logic                    ecc_evt_o,        // a read burst was checked
  output logic [3:0]              ecc_ce_cnt_o,     // words corrected in it
  output logic [3:0]              ecc_ue_cnt_o      // words uncorrectable in it
);
  // ------------------------------- control path -----------------------------
  cmd_t                    cmd;
  logic                    cke, mem_reset_n;
  logic                    wr_issued, rd_issued;
  logic [BURST_WORDS-1:0]  issued_mask;
  logic                    rd_space_ok;

  ctrl_core #(.INIT_CNT_W(INIT_CNT_W), .REFI_W(REFI_W)) u_ctrl (
    .clk               (clk),
    .rst_n             (rst_n),
    .t_i               (t_i),
    .t_rst_i           (t_rst_i),
    .t_cke_i           (t_cke_i),
    .t_xpr_i           (t_xpr_i),
    .t_dllk_i          (t_dllk_i),
    .mr_i              (mr_i),
    .t_refi_i          (t_refi_i),
    .ref_thresh_i      (ref_thresh_i),
    .t_ckesr_i         (t_ckesr_i),
    .phy_ready_i       (dfi_init_complete),
    .sr_req_i          (sr_req_i),
    .req_valid_i       (req_valid_i),
    .req_i             (req_i),
    .req_pop_o         (req_pop_o),
    .wdata_valid_i     (wdata_valid_i),
    .rd_space_ok_i     (rd_space_ok),
    .cmd_o             (cmd),
    .cke_o             (cke),
    .mem_reset_n_o     (mem_reset_n),
    .wr_issued_o       (wr_issued),
    .rd_issued_o       (rd_issued),
    .issued_mask_o     (issued_mask),
    .init_done_o       (init_done_o),
    .in_self_refresh_o (in_self_refresh_o),
    .ref_overflow_o    (ref_overflow_o),
    .ref_pending_o     (ref_pending_o)
  );

  assign wdata_pop_o = wr_issued;

  // ----------------------------------- ECC ----------------------------------
  logic                     enc_valid, cap_valid, dec_valid;
  logic [BURST_CODE_W-1:0]  enc_code, cap_code;
  logic [BURST_WORDS-1:0]   enc_mask;
  logic [BURST_DATA_W-1:0]  dec_data;
  logic [BURST_WORDS-1:0]   dec_ce, dec_ue;

  ecc_datapath u_ecc (
    .clk        (clk),
    .rst_n      (rst_n),
    .wr_valid_i (wr_issued),
    .wr_data_i  (wdata_i),
    .wr_mask_i  (issued_mask),
    .wr_valid_o (enc_valid),
    .wr_code_o  (enc_code),
    .wr_mask_o  (enc_mask),
    .rd_valid_i (cap_valid),
    .rd_code_i  (cap_code),
    .rd_valid_o (dec_valid),
    .rd_data_o  (dec_data),
    .rd_ce_o    (dec_ce),
    .rd_ue_o    (dec_ue)
  );

  // ----------------------------------- DFI ----------------------------------
  dfi_if u_dfi (
    .clk              (clk),
    .rst_n            (rst_n),
    .cmd_i            (cmd),
    .cke_i            (cke),
    .mem_reset_n_i    (mem_reset_n),
    .rd_issued_i      (rd_issued),
    .wr_lat_i         (wr_lat_i),
    .rden_lat_i       (rden_lat_i),
    .wr_valid_i       (enc_valid),
    .wr_code_i        (enc_code),
    .wr_mask_i        (enc_mask),
    .rd_valid_o       (cap_valid),
    .rd_code_o        (cap_code),
    .dfi_reset_n      (dfi_reset_n),
    .dfi_cke          (dfi_cke),
    .dfi_odt          (dfi_odt),
    .dfi_cs_n         (dfi_cs_n),
    .dfi_act_n        (dfi_act_n),
    .dfi_ras_n        (dfi_ras_n),
    .dfi_cas_n        (dfi_cas_n),
    .dfi_we_n         (dfi_we_n),
    .dfi_bg           (dfi_bg),
    .dfi_ba           (dfi_ba),
    .dfi_address      (dfi_address),
    .dfi_wrdata_en    (dfi_wrdata_en),
    .dfi_wrdata       (dfi_wrdata),
    .dfi_wrdata_mask  (dfi_wrdata_mask),
    .dfi_rddata_en    (dfi_rddata_en),
    .dfi_rddata       (dfi_rddata),
    .dfi_rddata_valid (dfi_rddata_valid)
  );

  // ---------------------- read tags and in-flight accounting ----------------
  // The word mask of each read waits here until its data comes back.
  logic [BURST_WORDS-1:0]  tag_mask;
  logic                    tag_empty, tag_full;
  logic [TAG_ADDR_W:0]     tag_count;    // = read bursts in flight

  sync_fifo #(.DATA_W(BURST_WORDS), .ADDR_W(TAG_ADDR_W)) u_tags (
    .clk     (clk),
    .rst_n   (rst_n),
    .push_i  (rd_issued),
    .data_i  (issued_mask),
    .pop_i   (dec_valid),
    .data_o  (tag_mask),
    .empty_o (tag_empty),
    .full_o  (tag_full),
    .count_o (tag_count)
  );

  // Invariant: bursts in flight <= free slots in the read FIFO.
  assign rd_space_ok = !tag_full && ({{(32-TAG_ADDR_W-1){1'b0}}, tag_count} <
                                     {{(32-FREE_W){1'b0}}, rdata_free_i});

  // ------------------------------ read data output --------------------------
  logic [BURST_WORDS-1:0] ce_used, ue_used;
  assign ce_used = dec_ce & tag_mask;
  assign ue_used = dec_ue & tag_mask;

  assign rdata_push_o = dec_valid;
  assign rdata_o      = {ue_used, dec_data};

  always_comb begin
    ecc_ce_cnt_o = '0;
    ecc_ue_cnt_o = '0;
    for (int w = 0; w < BURST_WORDS; w++) begin
      ecc_ce_cnt_o = ecc_ce_cnt_o + {3'b000, ce_used[w]};
      ecc_ue_cnt_o = ecc_ue_cnt_o + {3'b000, ue_used[w]};
    end
  end
  assign ecc_evt_o = dec_valid;

`ifndef SYNTHESIS
  a_tag_present: assert property (@(posedge clk) disable iff (!rst_n) dec_valid |-> !tag_empty)
    else $error("ddr4_core: read data returned with no read outstanding");
  a_rd_fifo_room: assert property (@(posedge clk) disable iff (!rst_n)
                                   rdata_push_o |-> (rdata_free_i != '0))
    else $error("ddr4_core: read data pushed with the read FIFO full");
`endif
endmodule
