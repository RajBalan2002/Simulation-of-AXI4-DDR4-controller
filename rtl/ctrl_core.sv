// -----------------------------------------------------------------------------
// ctrl_core.sv
// Control path of the DDR4 controller: initialization, refresh, self-refresh
// and request scheduling. Produces one decoded command per controller cycle.
//
// cmd_o, cke_o and the *_issued_o strobes are combinational outputs of this
// cycle's decision; dfi_if registers them.
//
// Not yet implemented: precharge power-down, periodic ZQCS, and the extra
// refresh JEDEC asks for after self-refresh exit (to be confirmed).
// -----------------------------------------------------------------------------
module ctrl_core
  import ddr4_pkg::*;
#(
  parameter int INIT_CNT_W = 20,
  parameter int REFI_W     = 16
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // configuration (quasi-static, from apb_csr)
  input  var timing_t             t_i,
  input  logic [INIT_CNT_W-1:0]   t_rst_i,
  input  logic [INIT_CNT_W-1:0]   t_cke_i,
  input  logic [INIT_CNT_W-1:0]   t_xpr_i,
  input  logic [INIT_CNT_W-1:0]   t_dllk_i,
  input  logic [6:0][13:0]        mr_i,
  input  logic [REFI_W-1:0]       t_refi_i,
  input  logic [3:0]              ref_thresh_i,
  input  var tcnt_t               t_ckesr_i,

  input  logic                    phy_ready_i,
  input  logic                    sr_req_i,

  // request FIFO, read side
  input  logic                    req_valid_i,
  input  var req_t                req_i,
  output logic                    req_pop_o,

  // datapath readiness
  input  logic                    wdata_valid_i,
  input  logic                    rd_space_ok_i,

  // command to dfi_if
  output cmd_t                    cmd_o,
  output logic                    cke_o,
  output logic                    mem_reset_n_o,
  output logic                    wr_issued_o,
  output logic                    rd_issued_o,
  output logic [BURST_WORDS-1:0]  issued_mask_o,

  // status
  output logic                    init_done_o,
  output logic                    in_self_refresh_o,
  output logic                    ref_overflow_o,
  output logic [3:0]              ref_pending_o
);
  // ------------------------------ command decode ----------------------------
  cmd_t cmd;
  logic is_act, is_rd, is_wr, is_pre, is_prea, is_ref, is_mrs, is_zqcl;
  logic is_sre, is_srx;
  logic [BANK_W-1:0] cmd_bank;

  assign is_act   = (cmd.cmd == CMD_ACT);
  assign is_rd    = (cmd.cmd == CMD_RD);
  assign is_wr    = (cmd.cmd == CMD_WR);
  assign is_pre   = (cmd.cmd == CMD_PRE);
  assign is_prea  = (cmd.cmd == CMD_PREA);
  assign is_ref   = (cmd.cmd == CMD_REF);
  assign is_mrs   = (cmd.cmd == CMD_MRS);
  assign is_zqcl  = (cmd.cmd == CMD_ZQCL);
  assign is_sre   = (cmd.cmd == CMD_SRE);
  assign is_srx   = (cmd.cmd == CMD_SRX);
  assign cmd_bank = {cmd.bg, cmd.ba};

  // --------------------------------- banks ----------------------------------
  logic [NUM_BANKS-1:0] bk_row_valid, bk_can_act, bk_can_rdwr, bk_can_pre;
  logic [ROW_W-1:0]     bk_open_row [NUM_BANKS];
  logic                 ref_done;

  for (genvar b = 0; b < NUM_BANKS; b++) begin : g_bank
    logic sel;
    assign sel = (cmd_bank == BANK_W'(b));

    bank_fsm u_bank (
      .clk         (clk),
      .rst_n       (rst_n),
      .t_i         (t_i),
      .act_i       (is_act && sel),
      .row_i       (cmd.row),
      .rd_i        (is_rd && sel),
      .wr_i        (is_wr && sel),
      .pre_i       ((is_pre && sel) || is_prea),
      .ref_i       (is_ref),
      .ref_done_i  (ref_done),
      .state_o     (),
      .open_row_o  (bk_open_row[b]),
      .row_valid_o (bk_row_valid[b]),
      .can_act_o   (bk_can_act[b]),
      .can_rdwr_o  (bk_can_rdwr[b]),
      .can_pre_o   (bk_can_pre[b])
    );
  end

  // ------------------------------ global timers -----------------------------
  logic [NUM_BG-1:0] g_act_ok, g_rd_ok, g_wr_ok;
  logic              bus_ok, mrs_ok;

  global_timers u_glob (
    .clk         (clk),
    .rst_n       (rst_n),
    .t_i         (t_i),
    .act_i       (is_act),
    .rd_i        (is_rd),
    .wr_i        (is_wr),
    .bg_i        (cmd.bg),
    .ref_i       (is_ref),
    .mrs_i       (is_mrs),
    .zqcl_init_i (is_zqcl && !init_done_o),
    .zqcl_i      (is_zqcl &&  init_done_o),
    .zqcs_i      (1'b0),
    .srx_i       (is_srx),
    .pdx_i       (1'b0),
    .act_ok_o    (g_act_ok),
    .rd_ok_o     (g_rd_ok),
    .wr_ok_o     (g_wr_ok),
    .bus_ok_o    (bus_ok),
    .mrs_ok_o    (mrs_ok),
    .ref_done_o  (ref_done)
  );

  // ------------------------------- initialization ---------------------------
  logic init_cmd_valid, init_cke;
  cmd_t init_cmd;

  init_fsm #(.INIT_CNT_W(INIT_CNT_W)) u_init (
    .clk           (clk),
    .rst_n         (rst_n),
    .phy_ready_i   (phy_ready_i),
    .t_rst_i       (t_rst_i),
    .t_cke_i       (t_cke_i),
    .t_xpr_i       (t_xpr_i),
    .t_dllk_i      (t_dllk_i),
    .mr_i          (mr_i),
    .mrs_ok_i      (mrs_ok),
    .bus_ok_i      (bus_ok),
    .cmd_valid_o   (init_cmd_valid),
    .cmd_o         (init_cmd),
    .mem_reset_n_o (mem_reset_n_o),
    .cke_o         (init_cke),
    .init_done_o   (init_done_o)
  );

  // --------------------------------- low power ------------------------------
  logic lp_drain, lp_in_sr, lp_srx_ok;

  lowpower_fsm u_lp (
    .clk          (clk),
    .rst_n        (rst_n),
    .init_done_i  (init_done_o),
    .sr_req_i     (sr_req_i),
    .t_ckesr_i    (t_ckesr_i),
    .sre_issued_i (is_sre),
    .srx_issued_i (is_srx),
    .drain_o      (lp_drain),
    .in_sr_o      (lp_in_sr),
    .srx_ok_o     (lp_srx_ok)
  );

  // ---------------------------------- refresh -------------------------------
  logic ref_any, ref_urgent;

  refresh_mgr #(.REFI_W(REFI_W)) u_ref (
    .clk             (clk),
    .rst_n           (rst_n),
    .en_i            (init_done_o && !lp_in_sr),
    .t_refi_i        (t_refi_i),
    .urgent_thresh_i (ref_thresh_i),
    .ref_issued_i    (is_ref),
    .pending_o       (ref_pending_o),
    .any_o           (ref_any),
    .urgent_o        (ref_urgent),
    .overflow_o      (ref_overflow_o)
  );

  // ---------------------------------- arbiter -------------------------------
  logic [BANK_W-1:0] hd_bank;
  assign hd_bank = {req_i.bg, req_i.ba};

  cmd_arbiter u_arb (
    .init_done_i      (init_done_o),
    .init_cmd_valid_i (init_cmd_valid),
    .init_cmd_i       (init_cmd),
    .lp_drain_i       (lp_drain),
    .lp_in_sr_i       (lp_in_sr),
    .lp_srx_ok_i      (lp_srx_ok),
    .ref_any_i        (ref_any),
    .ref_urgent_i     (ref_urgent),
    .hd_valid_i       (req_valid_i),
    .hd_i             (req_i),
    .hd_row_valid_i   (bk_row_valid[hd_bank]),
    .hd_hit_i         (bk_row_valid[hd_bank] && (bk_open_row[hd_bank] == req_i.row)),
    .hd_can_act_i     (bk_can_act[hd_bank]),
    .hd_can_rdwr_i    (bk_can_rdwr[hd_bank]),
    .hd_can_pre_i     (bk_can_pre[hd_bank]),
    .hd_act_ok_i      (g_act_ok[req_i.bg]),
    .hd_rd_ok_i       (g_rd_ok[req_i.bg]),
    .hd_wr_ok_i       (g_wr_ok[req_i.bg]),
    .bus_ok_i         (bus_ok),
    .any_row_valid_i  (|bk_row_valid),
    .all_can_pre_i    (&bk_can_pre),
    .all_idle_i       (&bk_can_act),
    .wdata_valid_i    (wdata_valid_i),
    .rd_space_ok_i    (rd_space_ok_i),
    .cmd_o            (cmd)
  );

  // ---------------------------------- outputs -------------------------------
  assign cmd_o             = cmd;
  assign req_pop_o         = is_rd || is_wr;
  assign wr_issued_o       = is_wr;
  assign rd_issued_o       = is_rd;
  assign issued_mask_o     = req_i.word_mask;
  assign in_self_refresh_o = lp_in_sr;

  // CKE: owned by init_fsm until initialization completes. Afterwards it is
  // low from the self-refresh entry command until the exit command.
  assign cke_o = !init_done_o ? init_cke
                              : !(is_sre || (lp_in_sr && !is_srx));
endmodule
