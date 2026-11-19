// -----------------------------------------------------------------------------
// cmd_arbiter.sv
// Chooses at most one command per controller cycle. Purely combinational.
//
// Priority, first match wins:
//   1. initialization sequence
//   2. self-refresh: exit command, or hold
//   3. drain (self-refresh entry, urgent refresh, or idle refresh):
//        PREA while any row is open, then SRE or REF once every bank is idle
//        (REF first if one is owed after a self-refresh exit)
//   4. head-of-queue request: RD/WR on a row hit, PRE on a row miss,
//      ACT on a closed bank
//   5. deselect
//
// Every rule is qualified by the guards from bank_fsm and global_timers, so a
// command is only issued in a cycle where it is legal.
// -----------------------------------------------------------------------------
module cmd_arbiter
  import ddr4_pkg::*;
(
  // initialization
  input  logic        init_done_i,
  input  logic        init_cmd_valid_i,
  input  var cmd_t    init_cmd_i,

  // low power
  input  logic        lp_drain_i,
  input  logic        lp_in_sr_i,
  input  logic        lp_srx_ok_i,
  input  logic        lp_need_ref_i,    // REFRESH owed before the next self-refresh entry

  // refresh
  input  logic        ref_any_i,
  input  logic        ref_urgent_i,

  // head-of-queue request and the state of the bank it addresses
  input  logic        hd_valid_i,
  input  var req_t    hd_i,
  input  logic        hd_row_valid_i,   // bank holds an open (or opening) row
  input  logic        hd_hit_i,         // ...and it is the requested row
  input  logic        hd_can_act_i,
  input  logic        hd_can_rdwr_i,
  input  logic        hd_can_pre_i,
  input  logic        hd_act_ok_i,      // global rules for the request's bank group
  input  logic        hd_rd_ok_i,
  input  logic        hd_wr_ok_i,

  // whole-memory status
  input  logic        bus_ok_i,
  input  logic        any_row_valid_i,
  input  logic        all_can_pre_i,
  input  logic        all_idle_i,       // every bank may accept ACT/REF

  // datapath readiness
  input  logic        wdata_valid_i,    // write data word is waiting
  input  logic        rd_space_ok_i,    // room for one more read burst

  output cmd_t        cmd_o
);
  logic drain;
  assign drain = lp_drain_i || ref_urgent_i || (ref_any_i && !hd_valid_i);

  always_comb begin
    cmd_o     = '0;
    cmd_o.cmd = CMD_DES;

    if (!init_done_i) begin
      if (init_cmd_valid_i) cmd_o = init_cmd_i;

    end else if (lp_in_sr_i) begin
      if (lp_srx_ok_i) cmd_o.cmd = CMD_SRX;

    end else if (drain) begin
      if (bus_ok_i) begin
        if (any_row_valid_i) begin
          if (all_can_pre_i) cmd_o.cmd = CMD_PREA;
        end else if (all_idle_i) begin
          cmd_o.cmd = (lp_drain_i && !lp_need_ref_i) ? CMD_SRE : CMD_REF;
        end
      end

    end else if (hd_valid_i && bus_ok_i) begin
      cmd_o.bg  = hd_i.bg;
      cmd_o.ba  = hd_i.ba;
      cmd_o.row = hd_i.row;
      cmd_o.col = {hd_i.col_hi, 3'b000};

      if (hd_row_valid_i) begin
        if (hd_hit_i) begin
          if (hd_can_rdwr_i) begin
            if (hd_i.wr) begin
              if (hd_wr_ok_i && wdata_valid_i) cmd_o.cmd = CMD_WR;
            end else begin
              if (hd_rd_ok_i && rd_space_ok_i) cmd_o.cmd = CMD_RD;
            end
          end
        end else if (hd_can_pre_i) begin
          cmd_o.cmd = CMD_PRE;
        end
      end else if (hd_can_act_i && hd_act_ok_i) begin
        cmd_o.cmd = CMD_ACT;
      end
    end
  end
endmodule
