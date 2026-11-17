// -----------------------------------------------------------------------------
// global_timers.sv
// Timing rules that span banks or involve the shared data bus.
//
//   act_ok_o[g] : an ACT to bank group g meets tRRD_S/L and tFAW
//   rd_ok_o[g]  : a RD  to bank group g meets tCCD_S/L and write-to-read
//   wr_ok_o[g]  : a WR  to bank group g meets tCCD_S/L and read-to-write
//   bus_ok_o    : no device-wide wait (tRFC, tMOD, tZQ, tXS, tXP) is running
//   mrs_ok_o    : another MRS is legal (tMRD, plus the device-wide waits)
// -----------------------------------------------------------------------------
module global_timers
  import ddr4_pkg::*;
(
  input  logic               clk,
  input  logic               rst_n,
  input  var timing_t        t_i,

  input  logic               act_i,
  input  logic               rd_i,
  input  logic               wr_i,
  input  logic [BG_W-1:0]    bg_i,         // bank group of the ACT/RD/WR
  input  logic               ref_i,
  input  logic               mrs_i,
  input  logic               zqcl_init_i,  // ZQCL during initialization
  input  logic               zqcl_i,       // ZQCL in normal operation
  input  logic               zqcs_i,
  input  logic               srx_i,        // self-refresh exit
  input  logic               pdx_i,        // power-down exit

  output logic [NUM_BG-1:0]  act_ok_o,
  output logic [NUM_BG-1:0]  rd_ok_o,
  output logic [NUM_BG-1:0]  wr_ok_o,
  output logic               bus_ok_o,
  output logic               mrs_ok_o,
  output logic               ref_done_o
);
  localparam int FAW_SLOTS = 4;

  tcnt_t rrd_cnt   [NUM_BG];
  tcnt_t ccd_cnt   [NUM_BG];
  tcnt_t wr2rd_cnt [NUM_BG];
  tcnt_t faw_cnt   [FAW_SLOTS];
  tcnt_t rd2wr_cnt, rfc_cnt, mrd_cnt, mod_cnt, zq_cnt, xs_cnt, xp_cnt;

  // ------------------------- four-activate window ---------------------------
  // Each ACT occupies one slot for tFAW. A fifth ACT needs a free slot.
  logic [FAW_SLOTS-1:0] faw_free;
  logic [FAW_SLOTS-1:0] faw_take;   // one-hot: lowest free slot
  logic                 faw_ok;

  always_comb begin
    for (int s = 0; s < FAW_SLOTS; s++) faw_free[s] = (faw_cnt[s] == '0);
    faw_take = faw_free & (~faw_free + 1'b1);
    faw_ok   = |faw_free;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < FAW_SLOTS; s++) faw_cnt[s] <= '0;
    end else begin
      for (int s = 0; s < FAW_SLOTS; s++) begin
        if (act_i && faw_take[s]) faw_cnt[s] <= tcnt_load(faw_cnt[s], t_i.t_faw);
        else                      faw_cnt[s] <= tcnt_dec(faw_cnt[s]);
      end
    end
  end

  // ------------------------- per-bank-group counters ------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int g = 0; g < NUM_BG; g++) begin
        rrd_cnt[g]   <= '0;
        ccd_cnt[g]   <= '0;
        wr2rd_cnt[g] <= '0;
      end
    end else begin
      for (int g = 0; g < NUM_BG; g++) begin
        // ACT -> ACT
        if (act_i)
          rrd_cnt[g] <= tcnt_load(rrd_cnt[g],
                                  (bg_i == BG_W'(g)) ? t_i.t_rrd_l : t_i.t_rrd_s);
        else
          rrd_cnt[g] <= tcnt_dec(rrd_cnt[g]);

        // RD/WR -> RD/WR
        if (rd_i || wr_i)
          ccd_cnt[g] <= tcnt_load(ccd_cnt[g],
                                  (bg_i == BG_W'(g)) ? t_i.t_ccd_l : t_i.t_ccd_s);
        else
          ccd_cnt[g] <= tcnt_dec(ccd_cnt[g]);

        // WR -> RD
        if (wr_i)
          wr2rd_cnt[g] <= tcnt_load(wr2rd_cnt[g],
                                    (bg_i == BG_W'(g)) ? t_i.t_wr2rd_l : t_i.t_wr2rd_s);
        else
          wr2rd_cnt[g] <= tcnt_dec(wr2rd_cnt[g]);
      end
    end
  end

  // ----------------------------- single counters ----------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd2wr_cnt <= '0;
      rfc_cnt   <= '0;
      mrd_cnt   <= '0;
      mod_cnt   <= '0;
      zq_cnt    <= '0;
      xs_cnt    <= '0;
      xp_cnt    <= '0;
    end else begin
      rd2wr_cnt <= rd_i  ? tcnt_load(rd2wr_cnt, t_i.t_rd2wr) : tcnt_dec(rd2wr_cnt);
      rfc_cnt   <= ref_i ? tcnt_load(rfc_cnt,   t_i.t_rfc)   : tcnt_dec(rfc_cnt);
      mrd_cnt   <= mrs_i ? tcnt_load(mrd_cnt,   t_i.t_mrd)   : tcnt_dec(mrd_cnt);
      mod_cnt   <= mrs_i ? tcnt_load(mod_cnt,   t_i.t_mod)   : tcnt_dec(mod_cnt);
      xs_cnt    <= srx_i ? tcnt_load(xs_cnt,    t_i.t_xs)    : tcnt_dec(xs_cnt);
      xp_cnt    <= pdx_i ? tcnt_load(xp_cnt,    t_i.t_xp)    : tcnt_dec(xp_cnt);

      if      (zqcl_init_i) zq_cnt <= tcnt_load(zq_cnt, t_i.t_zqinit);
      else if (zqcl_i)      zq_cnt <= tcnt_load(zq_cnt, t_i.t_zqoper);
      else if (zqcs_i)      zq_cnt <= tcnt_load(zq_cnt, t_i.t_zqcs);
      else                  zq_cnt <= tcnt_dec(zq_cnt);
    end
  end

  // --------------------------------- outputs --------------------------------
  logic dev_ok;   // device-wide waits other than tMOD/tMRD
  assign dev_ok     = (rfc_cnt == '0) && (zq_cnt == '0) &&
                      (xs_cnt  == '0) && (xp_cnt == '0);
  assign bus_ok_o   = dev_ok && (mod_cnt == '0);
  assign mrs_ok_o   = dev_ok && (mrd_cnt == '0);
  assign ref_done_o = (rfc_cnt == '0);

  always_comb begin
    for (int g = 0; g < NUM_BG; g++) begin
      act_ok_o[g] = (rrd_cnt[g] == '0) && faw_ok;
      rd_ok_o[g]  = (ccd_cnt[g] == '0) && (wr2rd_cnt[g] == '0);
      wr_ok_o[g]  = (ccd_cnt[g] == '0) && (rd2wr_cnt == '0);
    end
  end

`ifndef SYNTHESIS
  a_act_spacing: assert property (@(posedge clk) disable iff (!rst_n)
                                  act_i |-> act_ok_o[bg_i] && bus_ok_o)
    else $error("global_timers: ACT violates tRRD/tFAW or a device-wide wait");
  a_rd_spacing:  assert property (@(posedge clk) disable iff (!rst_n)
                                  rd_i |-> rd_ok_o[bg_i] && bus_ok_o)
    else $error("global_timers: RD violates tCCD/tWTR or a device-wide wait");
  a_wr_spacing:  assert property (@(posedge clk) disable iff (!rst_n)
                                  wr_i |-> wr_ok_o[bg_i] && bus_ok_o)
    else $error("global_timers: WR violates tCCD/turnaround or a device-wide wait");
  a_one_cmd:     assert property (@(posedge clk) disable iff (!rst_n)
                                  $onehot0({act_i, rd_i, wr_i, ref_i, mrs_i,
                                            zqcl_init_i, zqcl_i, zqcs_i, srx_i, pdx_i}))
    else $error("global_timers: more than one command strobe in a cycle");
`endif
endmodule
