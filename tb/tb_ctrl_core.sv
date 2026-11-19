// -----------------------------------------------------------------------------
// tb_ctrl_core.sv
// Self-checking testbench for ctrl_core.
//
// A random request stream is applied and every command the controller issues
// is checked by an INDEPENDENT protocol monitor. The monitor does not reuse
// the RTL's down-counters: it records the cycle number of past commands and
// checks "cycles since X >= required spacing" for each rule.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_ctrl_core #(
  parameter int NREQ = 20000,   // requests to complete
  parameter int REFI = 300,     // refresh interval in cycles (real value ~1560)
  parameter bit STRESS = 0      // widen cross-bank spacings so they become the binding rule
);
  import ddr4_pkg::*;

  localparam int INIT_CNT_W = 20;
  localparam int T_RST   = 20;
  localparam int T_CKE   = 30;
  localparam int T_XPR   = 10;
  localparam int T_DLLK  = 15;
  localparam int T_CKESR = 3;
  localparam int NEVER   = -1000000;

  // ------------------------------- DUT hookup -------------------------------
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  timing_t           t;
  logic [6:0][13:0]  mr;
  logic              phy_ready = 0, sr_req = 0;
  logic              req_valid = 0, req_pop;
  req_t              req;
  logic              wdata_valid = 1, rd_space_ok = 1;
  cmd_t              cmd;
  logic              cke, mem_reset_n, wr_issued, rd_issued;
  logic [BURST_WORDS-1:0] issued_mask;
  logic              init_done, in_sr, ref_overflow;
  logic [3:0]        ref_pending;

  ctrl_core #(.INIT_CNT_W(INIT_CNT_W)) dut (
    .clk(clk), .rst_n(rst_n), .t_i(t),
    .t_rst_i(INIT_CNT_W'(T_RST)), .t_cke_i(INIT_CNT_W'(T_CKE)),
    .t_xpr_i(INIT_CNT_W'(T_XPR)), .t_dllk_i(INIT_CNT_W'(T_DLLK)),
    .mr_i(mr), .t_refi_i(16'(REFI)), .ref_thresh_i(4'd6),
    .t_ckesr_i(tcnt_t'(T_CKESR)),
    .phy_ready_i(phy_ready), .sr_req_i(sr_req),
    .req_valid_i(req_valid), .req_i(req), .req_pop_o(req_pop),
    .wdata_valid_i(wdata_valid), .rd_space_ok_i(rd_space_ok),
    .cmd_o(cmd), .cke_o(cke), .mem_reset_n_o(mem_reset_n),
    .wr_issued_o(wr_issued), .rd_issued_o(rd_issued), .issued_mask_o(issued_mask),
    .init_done_o(init_done), .in_self_refresh_o(in_sr),
    .ref_overflow_o(ref_overflow), .ref_pending_o(ref_pending));

  // ------------------------------ bookkeeping -------------------------------
  int cyc = 0;
  int errors = 0;
  int popped = 0;
  int n_act = 0, n_rd = 0, n_wr = 0, n_pre = 0, n_prea = 0, n_ref = 0;
  int n_sre = 0, n_srx = 0, n_mrs = 0, n_zq = 0;
  int done_cyc = 0, init_done_cyc = NEVER;

  // monitor state
  bit               m_open     [NUM_BANKS];
  logic [ROW_W-1:0] m_open_row [NUM_BANKS];
  int               m_last_act [NUM_BANKS];
  int               m_last_pre [NUM_BANKS];
  int               m_last_rd  [NUM_BANKS];
  int               m_last_wr  [NUM_BANKS];
  int               m_act_bg   [NUM_BG];
  int               m_rdwr_bg  [NUM_BG];
  int               m_wr_bg    [NUM_BG];
  int               m_act_hist [4];
  int               m_last_rd_any = NEVER, m_last_ref = NEVER, m_last_mrs = NEVER;
  int               m_last_zq = NEVER, m_zq_need = 0;
  int               m_last_sre = NEVER, m_last_srx = NEVER;
  bit               m_in_sr = 0;
  int               m_rst_release = NEVER, m_cke_high = NEVER, m_phy_ready = NEVER;
  bit               m_prev_reset_n = 0, m_prev_cke = 0, m_prev_phy = 0;
  logic [2:0]       mr_order [7];

  // scratch variables for the monitor (module scope for tool portability)
  cmd_e             c;
  int               b, g;

  // stimulus state
  int               busy_pct = 100;
  int               sr_cnt = 0;
  int               sr_next = 1;
  int               sr_gap = 0;
  bit               sr_again = 0;
  int               m_sr_cycles = 0;
  logic [BANK_W-1:0] last_bank = '0;
  logic [ROW_W-1:0]  row_set [4];

  task automatic fail(input string msg);
    errors++;
    if (errors <= 30) $display("ERROR @%0d: %s", cyc, msg);
  endtask

  // "need" cycles must have passed since cycle "since"
  task automatic spacing(input string rule, input int since, input int need);
    if (cyc - since < need)
      fail($sformatf("%s violated: %0d cycles, need %0d", rule, cyc - since, need));
  endtask

  function automatic req_t random_req();
    req_t r;
    logic [BANK_W-1:0] b;
    b = ($urandom_range(0, 99) < 60) ? last_bank : BANK_W'($urandom_range(0, NUM_BANKS-1));
    r.wr        = 1'($urandom_range(0, 1));
    r.row       = row_set[$urandom_range(0, 3)];
    r.bg        = b[BANK_W-1:BA_W];
    r.ba        = b[BA_W-1:0];
    r.col_hi    = BURST_COL_W'($urandom);
    r.word_mask = BURST_WORDS'($urandom_range(1, 255));
    return r;
  endfunction

  // -------------------------------- stimulus --------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      req_valid <= 1'b0;
    end else begin
      // a new request is presented when the slot is free or was just taken
      if (!req_valid || req_pop) begin
        if ((popped + (req_pop ? 1 : 0) < NREQ) && ($urandom_range(0, 99) < busy_pct)) begin
          req_t r;
          r = random_req();
          req       <= r;
          req_valid <= 1'b1;
          last_bank <= {r.bg, r.ba};
        end else begin
          req_valid <= 1'b0;
        end
      end
      wdata_valid <= ($urandom_range(0, 99) < 90);
      rd_space_ok <= ($urandom_range(0, 99) < 90);

      if (cyc % 4000 == 0) begin
        case ($urandom_range(0, 3))
          0: busy_pct <= 100;
          1: busy_pct <= 90;
          2: busy_pct <= 40;
          default: busy_pct <= 5;
        endcase
      end

      // Self-refresh requests at nine points in the run. Odd ones are long
      // (the memory really enters self-refresh); even ones last 1 to 12 cycles
      // so the request is often withdrawn while banks are still being closed.
      // A long request is followed a few cycles later by a second long one, so
      // the controller is asked to re-enter self-refresh straight after leaving it.
      if (sr_cnt > 0) begin
        sr_cnt <= sr_cnt - 1;
        if (sr_cnt == 1) begin
          sr_req <= 1'b0;
          if (sr_again) sr_gap <= 5;
        end
      end else if (sr_gap > 0) begin
        sr_gap <= sr_gap - 1;
        if (sr_gap == 1) begin
          sr_req <= 1'b1; sr_cnt <= 400; sr_again <= 0;
        end
      end else if (sr_next <= 9 && popped >= (sr_next * NREQ) / 10) begin
        sr_next  <= sr_next + 1;
        sr_req   <= 1'b1;
        sr_cnt   <= (sr_next % 2 == 1) ? 400 : $urandom_range(1, 12);
        sr_again <= (sr_next % 2 == 1);
      end
    end
  end

  // --------------------------------- monitor --------------------------------
  // Samples the values the DUT presented during the cycle that is ending.
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (rst_n) begin
      c = cmd.cmd;
      b = int'({cmd.bg, cmd.ba});
      g = int'(cmd.bg);

      // ---- reset / CKE sequencing ----
      if (phy_ready && !m_prev_phy)        m_phy_ready   = cyc;
      if (mem_reset_n && !m_prev_reset_n) begin
        m_rst_release = cyc;
        spacing("reset low time", m_phy_ready, T_RST);
      end
      if (cke && !m_prev_cke && !init_done) begin
        m_cke_high = cyc;
        spacing("CKE low after reset release", m_rst_release, T_CKE);
      end
      m_prev_phy = phy_ready; m_prev_reset_n = mem_reset_n; m_prev_cke = cke;
      if (init_done && init_done_cyc == NEVER) begin
        init_done_cyc = cyc;
        if (n_mrs != 7 || n_zq != 1) fail("init_done before the full MRS/ZQCL sequence");
        spacing("init_done after ZQCL", m_last_zq, int'(t.t_zqinit) + T_DLLK);
      end

      if (req_pop !== (c == CMD_RD || c == CMD_WR)) fail("req_pop does not match RD/WR");
      if (ref_overflow) fail("refresh overflow flag set");

      // ---- rules common to every real command ----
      if (c != CMD_DES) begin
        if (!mem_reset_n) fail("command while memory reset is asserted");
        if (c != CMD_SRE && !cke) fail("command while CKE is low");
        if (m_in_sr && c != CMD_SRX) fail("command during self-refresh");
        if (c != CMD_SRX) begin
          spacing("tRFC", m_last_ref, int'(t.t_rfc));
          spacing("tZQ",  m_last_zq,  m_zq_need);
          spacing("tXS",  m_last_srx, int'(t.t_xs));
          if (c == CMD_MRS) spacing("tMRD", m_last_mrs, int'(t.t_mrd));
          else              spacing("tMOD", m_last_mrs, int'(t.t_mod));
        end
        if (!init_done && c != CMD_MRS && c != CMD_ZQCL) fail("non-init command before init_done");
        if (!init_done) spacing("tXPR", m_cke_high, T_XPR);
      end else begin
        if (m_in_sr && cke) fail("CKE high during self-refresh");
        if (init_done && !m_in_sr && !cke) fail("CKE low outside self-refresh");
      end

      case (c)
        CMD_MRS: begin
          if (n_mrs >= 7) fail("more than seven MRS commands");
          else begin
            if (cmd.mr_sel !== mr_order[n_mrs]) fail("MRS out of order");
            if (cmd.row[13:0] !== mr[cmd.mr_sel]) fail("MRS opcode mismatch");
          end
          if (n_zq != 0) fail("MRS after ZQCL");
          m_last_mrs = cyc; n_mrs++;
        end

        CMD_ZQCL: begin
          if (n_mrs != 7) fail("ZQCL before all MRS commands");
          m_zq_need = init_done ? int'(t.t_zqoper) : int'(t.t_zqinit);
          m_last_zq = cyc; n_zq++;
        end

        CMD_ACT: begin
          if (m_open[b]) fail("ACT to a bank that is already open");
          spacing("tRP",  m_last_pre[b], int'(t.t_rp));
          spacing("tRC",  m_last_act[b], int'(t.t_rc));
          for (int k = 0; k < NUM_BG; k++)
            spacing((k == g) ? "tRRD_L" : "tRRD_S", m_act_bg[k],
                    (k == g) ? int'(t.t_rrd_l) : int'(t.t_rrd_s));
          spacing("tFAW", m_act_hist[3], int'(t.t_faw));
          if (!req_valid || cmd.row !== req.row) fail("ACT row does not match the request");
          m_open[b] = 1; m_open_row[b] = cmd.row;
          m_last_act[b] = cyc; m_act_bg[g] = cyc;
          m_act_hist[3] = m_act_hist[2]; m_act_hist[2] = m_act_hist[1];
          m_act_hist[1] = m_act_hist[0]; m_act_hist[0] = cyc;
          n_act++;
        end

        CMD_RD, CMD_WR: begin
          if (!req_valid) fail("RD/WR with no request pending");
          if ({cmd.bg, cmd.ba} !== {req.bg, req.ba}) fail("RD/WR bank mismatch");
          if (cmd.col !== {req.col_hi, 3'b000}) fail("RD/WR column mismatch");
          if ((c == CMD_WR) !== req.wr) fail("RD/WR direction mismatch");
          if (issued_mask !== req.word_mask) fail("word mask mismatch");
          if (!m_open[b]) fail("RD/WR to a closed bank");
          else if (m_open_row[b] !== req.row) fail("RD/WR to the wrong open row");
          spacing("tRCD", m_last_act[b], int'(t.t_rcd));
          for (int k = 0; k < NUM_BG; k++)
            spacing((k == g) ? "tCCD_L" : "tCCD_S", m_rdwr_bg[k],
                    (k == g) ? int'(t.t_ccd_l) : int'(t.t_ccd_s));
          if (c == CMD_RD) begin
            for (int k = 0; k < NUM_BG; k++)
              spacing((k == g) ? "WR->RD same group" : "WR->RD other group", m_wr_bg[k],
                      (k == g) ? int'(t.t_wr2rd_l) : int'(t.t_wr2rd_s));
            if (!rd_space_ok) fail("RD issued with no read-data space");
            if (!rd_issued || wr_issued) fail("rd_issued/wr_issued wrong on RD");
            m_last_rd[b] = cyc; m_last_rd_any = cyc; n_rd++;
          end else begin
            spacing("RD->WR", m_last_rd_any, int'(t.t_rd2wr));
            if (!wdata_valid) fail("WR issued with no write data");
            if (!wr_issued || rd_issued) fail("rd_issued/wr_issued wrong on WR");
            m_last_wr[b] = cyc; m_wr_bg[g] = cyc; n_wr++;
          end
          m_rdwr_bg[g] = cyc;
          popped <= popped + 1;
        end

        CMD_PRE: begin
          if (!m_open[b]) fail("PRE to a bank with no open row");
          spacing("tRAS",   m_last_act[b], int'(t.t_ras));
          spacing("tRTP",   m_last_rd[b],  int'(t.t_rtp));
          spacing("WR->PRE", m_last_wr[b], int'(t.t_wr2pre));
          m_open[b] = 0; m_last_pre[b] = cyc; n_pre++;
        end

        CMD_PREA: begin
          for (int k = 0; k < NUM_BANKS; k++) begin
            if (m_open[k]) begin
              spacing("tRAS (PREA)",    m_last_act[k], int'(t.t_ras));
              spacing("tRTP (PREA)",    m_last_rd[k],  int'(t.t_rtp));
              spacing("WR->PRE (PREA)", m_last_wr[k],  int'(t.t_wr2pre));
            end
            m_open[k] = 0; m_last_pre[k] = cyc;
          end
          n_prea++;
        end

        CMD_REF, CMD_SRE: begin
          for (int k = 0; k < NUM_BANKS; k++) begin
            if (m_open[k]) fail("REF/SRE with a bank open");
            spacing("tRP before REF/SRE", m_last_pre[k], int'(t.t_rp));
          end
          if (c == CMD_REF) begin
            m_last_ref = cyc; n_ref++;
          end else begin
            if (cke) fail("CKE high on self-refresh entry");
            if (!sr_req) fail("self-refresh entry without a request");
            // datasheet: after leaving self-refresh, at least one REFRESH is
            // required before self-refresh may be entered again
            if (m_last_srx != NEVER && m_last_ref < m_last_srx)
              fail("self-refresh re-entered with no REFRESH since the last exit");
            m_in_sr = 1; m_last_sre = cyc; n_sre++;
          end
        end

        CMD_SRX: begin
          if (!m_in_sr) fail("SRX while not in self-refresh");
          if (!cke) fail("CKE low on self-refresh exit");
          spacing("tCKESR", m_last_sre, T_CKESR + 1);
          m_in_sr = 0; m_last_srx = cyc; n_srx++;
        end

        CMD_DES: ;
        default: fail("unexpected command type");
      endcase

      if (m_in_sr) m_sr_cycles++;
      if (in_sr !== m_in_sr && c != CMD_SRE && c != CMD_SRX)
        fail("in_self_refresh_o disagrees with the monitor");
    end
  end

  // --------------------------------- control --------------------------------
  initial begin
    t = timing_default_1600();
    if (STRESS) begin
      // With in-order scheduling the default tRRD/tFAW/tCCD values are never the
      // limiting rule. These larger values make the arbiter actually wait on them.
      t.t_faw   = 10'd30;
      t.t_rrd_s = 10'd6;
      t.t_rrd_l = 10'd9;
      t.t_ccd_s = 10'd3;
      t.t_ccd_l = 10'd5;
    end
    mr[0] = 14'h0A10; mr[1] = 14'h0001; mr[2] = 14'h0018; mr[3] = 14'h0000;
    mr[4] = 14'h0000; mr[5] = 14'h0400; mr[6] = 14'h0019;
    mr_order[0] = 3'd3; mr_order[1] = 3'd6; mr_order[2] = 3'd5; mr_order[3] = 3'd4;
    mr_order[4] = 3'd2; mr_order[5] = 3'd1; mr_order[6] = 3'd0;
    row_set[0] = 16'h0000; row_set[1] = 16'hFFFF; row_set[2] = 16'h1234; row_set[3] = 16'hA5A5;
    req = '0;
    for (int k = 0; k < NUM_BANKS; k++) begin
      m_open[k] = 0; m_open_row[k] = '0;
      m_last_act[k] = NEVER; m_last_pre[k] = NEVER;
      m_last_rd[k]  = NEVER; m_last_wr[k]  = NEVER;
    end
    for (int k = 0; k < NUM_BG; k++) begin
      m_act_bg[k] = NEVER; m_rdwr_bg[k] = NEVER; m_wr_bg[k] = NEVER;
    end
    for (int k = 0; k < 4; k++) m_act_hist[k] = NEVER;

    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (7) @(posedge clk);
    phy_ready = 1;

    wait (popped == NREQ);
    done_cyc = cyc;
    // let any pending refreshes drain while idle
    repeat (2000) @(posedge clk);

    if (n_mrs != 7 || n_zq != 1) fail("initialization sequence incomplete");
    if (n_ref == 0)  fail("no refresh was ever issued");
    if (n_prea == 0) fail("precharge-all never exercised");
    if (n_pre == 0)  fail("single-bank precharge never exercised");
    if (n_sre < 5 || n_srx != n_sre) fail("self-refresh entry/exit not exercised enough");
    if (n_rd + n_wr != NREQ) fail("RD+WR count does not equal the request count");
    if (ref_pending != 0) fail("refreshes still pending after an idle period");
    // every refresh interval must eventually be paid, less the postponement allowance
    if (n_ref + 9 + n_sre < (done_cyc - init_done_cyc - m_sr_cycles) / REFI)
      fail($sformatf("too few refreshes: %0d", n_ref));

    $display("ctrl_core REFI=%0d STRESS=%0d: cycles=%0d req=%0d ACT=%0d RD=%0d WR=%0d PRE=%0d PREA=%0d REF=%0d SRE=%0d SRX=%0d errors=%0d  %s",
             REFI, STRESS, cyc, popped, n_act, n_rd, n_wr, n_pre, n_prea, n_ref, n_sre, n_srx,
             errors, errors == 0 ? "PASS" : "FAIL");
    $finish;
  end

  localparam int WATCHDOG_CYCLES = 5_000_000;
  initial begin
    repeat (WATCHDOG_CYCLES) @(posedge clk);
    $display("TIMEOUT FAIL at cycle %0d: popped=%0d init_done=%b in_sr=%b req_valid=%b pending=%0d errors=%0d",
             cyc, popped, init_done, in_sr, req_valid, ref_pending, errors);
    $finish;
  end
endmodule
