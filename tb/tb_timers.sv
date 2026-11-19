// Directed, self-checking testbench for bank_fsm, global_timers, refresh_mgr.
// Checks that each guard opens in exactly the cycle the spec'd spacing allows:
// a command in cycle T with spacing N must make the guard true first in T+N.
`timescale 1ns/1ps
module tb_timers;
  import ddr4_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  timing_t t;
  int cyc = 0;
  int errors = 0;

  // ------------------------------ bank_fsm ---------------------------------
  logic b_act = 0, b_rd = 0, b_wr = 0, b_pre = 0, b_ref = 0, b_ref_done = 0;
  logic [ROW_W-1:0] b_row = '0, b_open_row;
  bank_state_e b_state;
  logic b_row_valid, b_can_act, b_can_rdwr, b_can_pre;

  bank_fsm u_bank (.clk, .rst_n, .t_i(t),
    .act_i(b_act), .row_i(b_row), .rd_i(b_rd), .wr_i(b_wr), .pre_i(b_pre),
    .ref_i(b_ref), .ref_done_i(b_ref_done),
    .state_o(b_state), .open_row_o(b_open_row), .row_valid_o(b_row_valid),
    .can_act_o(b_can_act), .can_rdwr_o(b_can_rdwr), .can_pre_o(b_can_pre));

  // ---------------------------- global_timers ------------------------------
  logic g_act = 0, g_rd = 0, g_wr = 0, g_ref = 0, g_mrs = 0;
  logic g_zqi = 0, g_zql = 0, g_zqs = 0, g_srx = 0, g_pdx = 0;
  logic [BG_W-1:0] g_bg = '0;
  logic [NUM_BG-1:0] g_act_ok, g_rd_ok, g_wr_ok;
  logic g_bus_ok, g_mrs_ok, g_ref_done;

  global_timers u_glob (.clk, .rst_n, .t_i(t),
    .act_i(g_act), .rd_i(g_rd), .wr_i(g_wr), .bg_i(g_bg), .ref_i(g_ref),
    .mrs_i(g_mrs), .zqcl_init_i(g_zqi), .zqcl_i(g_zql), .zqcs_i(g_zqs),
    .srx_i(g_srx), .pdx_i(g_pdx),
    .act_ok_o(g_act_ok), .rd_ok_o(g_rd_ok), .wr_ok_o(g_wr_ok),
    .bus_ok_o(g_bus_ok), .mrs_ok_o(g_mrs_ok), .ref_done_o(g_ref_done));

  // ------------------------------ refresh_mgr ------------------------------
  logic r_en = 0, r_issued = 0, r_any, r_urgent, r_ovf;
  logic [3:0] r_pending;
  refresh_mgr u_ref (.clk, .rst_n, .en_i(r_en), .t_refi_i(16'd10),
    .urgent_thresh_i(4'd6), .ref_issued_i(r_issued),
    .pending_o(r_pending), .any_o(r_any), .urgent_o(r_urgent), .overflow_o(r_ovf));

  // Advance one cycle. After this returns, outputs reflect the new cycle and
  // inputs driven now are seen by the DUT at the next edge.
  task automatic step();
    @(posedge clk); #1; cyc++;
    b_act = 0; b_rd = 0; b_wr = 0; b_pre = 0; b_ref = 0;
    g_act = 0; g_rd = 0; g_wr = 0; g_ref = 0; g_mrs = 0;
    g_zqi = 0; g_zql = 0; g_zqs = 0; g_srx = 0; g_pdx = 0;
    r_issued = 0;
  endtask

  task automatic expect_eq(input string what, input int got, input int exp);
    if (got !== exp) begin
      errors++;
      $display("ERROR: %s = %0d, expected %0d (cycle %0d)", what, got, exp, cyc);
    end
  endtask

  // Step until sig() is true; return how many cycles after t0 that happened.
  `define WAIT_FOR(sig, t0, result) \
    begin int guard_; guard_ = 0; \
      while (!(sig)) begin step(); guard_++; \
        if (guard_ > 2000) begin errors++; $display("ERROR: timeout waiting"); break; end end \
      result = cyc - (t0); end

  initial begin
    int t0, t_act, d;
    t = timing_default_1600();
    repeat (3) step();
    rst_n = 1;
    step();

    // ===================== bank_fsm: ACT -> RD -> PRE -> ACT ================
    expect_eq("bank can_act after reset", b_can_act, 1);
    expect_eq("bank can_rdwr after reset", b_can_rdwr, 0);
    b_act = 1; b_row = 16'hBEEF; t_act = cyc; step();
    expect_eq("row_valid after ACT", b_row_valid, 1);
    expect_eq("open_row", b_open_row, 16'hBEEF);
    `WAIT_FOR(b_can_rdwr, t_act, d)  expect_eq("ACT->RD spacing (tRCD)", d, int'(t.t_rcd));
    b_rd = 1; t0 = cyc; step();
    `WAIT_FOR(b_can_pre, t_act, d)   expect_eq("ACT->PRE spacing (tRAS)", d, int'(t.t_ras));
    b_pre = 1; t0 = cyc; step();
    expect_eq("row_valid after PRE", b_row_valid, 0);
    `WAIT_FOR(b_can_act, t0, d)      expect_eq("PRE->ACT spacing (tRP, tRC)", d,
                                      (int'(t.t_rc) - (t0 - t_act) > int'(t.t_rp)) ?
                                       int'(t.t_rc) - (t0 - t_act) : int'(t.t_rp));

    // write recovery: ACT, WR as soon as allowed, PRE must wait t_wr2pre from WR
    repeat (20) step();
    b_act = 1; b_row = 16'h1234; t_act = cyc; step();
    `WAIT_FOR(b_can_rdwr, t_act, d)
    b_wr = 1; t0 = cyc; step();
    `WAIT_FOR(b_can_pre, t0, d)      expect_eq("WR->PRE spacing", d, int'(t.t_wr2pre));
    b_pre = 1; step();
    repeat (20) step();

    // refresh: only from idle, leaves on ref_done
    b_ref = 1; step();
    expect_eq("state REFRESHING", int'(b_state), int'(BS_REFRESHING));
    expect_eq("can_act during refresh", b_can_act, 0);
    b_ref_done = 1; step(); b_ref_done = 0;
    expect_eq("state IDLE after refresh", int'(b_state), int'(BS_IDLE));

    // ===================== global_timers ===================================
    // tRRD: ACT to group 0 -> same group waits t_rrd_l, other groups t_rrd_s
    repeat (20) step();
    g_act = 1; g_bg = 2'd0; t0 = cyc; step();
    `WAIT_FOR(g_act_ok[1], t0, d)    expect_eq("tRRD_S", d, int'(t.t_rrd_s));
    `WAIT_FOR(g_act_ok[0], t0, d)    expect_eq("tRRD_L", d, int'(t.t_rrd_l));

    // tFAW: four ACTs in consecutive cycles to four groups, fifth must wait
    repeat (20) step();
    t0 = cyc;
    for (int g = 0; g < 4; g++) begin
      if (!g_act_ok[g]) begin errors++; $display("ERROR: ACT %0d not allowed", g); end
      g_act = 1; g_bg = BG_W'(g); step();
    end
    expect_eq("fifth ACT blocked by tFAW", int'(|g_act_ok), 0);
    `WAIT_FOR(g_act_ok[0], t0, d)    expect_eq("tFAW", d, int'(t.t_faw));

    // tCCD
    repeat (20) step();
    g_rd = 1; g_bg = 2'd2; t0 = cyc; step();
    `WAIT_FOR(g_rd_ok[1], t0, d)     expect_eq("tCCD_S", d, int'(t.t_ccd_s));
    `WAIT_FOR(g_rd_ok[2], t0, d)     expect_eq("tCCD_L", d, int'(t.t_ccd_l));

    // RD -> WR turnaround
    repeat (20) step();
    g_rd = 1; g_bg = 2'd0; t0 = cyc; step();
    `WAIT_FOR(g_wr_ok[1], t0, d)     expect_eq("RD->WR", d, int'(t.t_rd2wr));

    // WR -> RD
    repeat (20) step();
    g_wr = 1; g_bg = 2'd3; t0 = cyc; step();
    `WAIT_FOR(g_rd_ok[0], t0, d)     expect_eq("WR->RD other group", d, int'(t.t_wr2rd_s));
    `WAIT_FOR(g_rd_ok[3], t0, d)     expect_eq("WR->RD same group", d, int'(t.t_wr2rd_l));

    // device-wide waits
    repeat (20) step();
    g_ref = 1; t0 = cyc; step();
    expect_eq("bus_ok after REF", g_bus_ok, 0);
    `WAIT_FOR(g_bus_ok, t0, d)       expect_eq("tRFC", d, int'(t.t_rfc));
    expect_eq("ref_done", g_ref_done, 1);

    g_mrs = 1; t0 = cyc; step();
    `WAIT_FOR(g_mrs_ok, t0, d)       expect_eq("tMRD", d, int'(t.t_mrd));
    `WAIT_FOR(g_bus_ok, t0, d)       expect_eq("tMOD", d, int'(t.t_mod));

    g_zqi = 1; t0 = cyc; step();
    `WAIT_FOR(g_bus_ok, t0, d)       expect_eq("tZQinit", d, int'(t.t_zqinit));
    g_zqs = 1; t0 = cyc; step();
    `WAIT_FOR(g_bus_ok, t0, d)       expect_eq("tZQCS", d, int'(t.t_zqcs));
    g_srx = 1; t0 = cyc; step();
    `WAIT_FOR(g_bus_ok, t0, d)       expect_eq("tXS", d, int'(t.t_xs));
    g_pdx = 1; t0 = cyc; step();
    `WAIT_FOR(g_bus_ok, t0, d)       expect_eq("tXP", d, int'(t.t_xp));

    // ===================== refresh_mgr =====================================
    expect_eq("pending while disabled", int'(r_pending), 0);
    r_en = 1; step();
    repeat (10 * 3) step();
    expect_eq("pending after 3 intervals", int'(r_pending), 3);
    expect_eq("urgent below threshold", r_urgent, 0);
    r_issued = 1; step();
    expect_eq("pending after one REF", int'(r_pending), 2);
    repeat (10 * 4) step();
    expect_eq("pending after 4 more", int'(r_pending), 6);
    expect_eq("urgent at threshold", r_urgent, 1);
    repeat (10 * 2) step();
    expect_eq("pending saturates at 8", int'(r_pending), 8);
    expect_eq("no overflow yet", r_ovf, 0);
    repeat (10) step();
    expect_eq("overflow flagged", r_ovf, 1);

    $display("timers: cycles=%0d errors=%0d  %s", cyc, errors, errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
