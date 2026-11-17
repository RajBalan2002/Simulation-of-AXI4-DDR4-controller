// -----------------------------------------------------------------------------
// bank_fsm.sv
// State, open-row register and timing counters for ONE bank.
// ctrl_core instantiates NUM_BANKS copies and steers the command strobes.
//
// The can_* outputs are the legality guards used by the arbiter:
//   can_act_o  : an ACT to this bank is legal this cycle
//   can_rdwr_o : a RD/WR to this bank is legal this cycle (per-bank rules only)
//   can_pre_o  : a PRE to this bank is legal this cycle
//                (also true when the bank holds no open row, so PREA can go)
// Cross-bank rules (tRRD, tFAW, tCCD, bus turnaround) live in global_timers.
// -----------------------------------------------------------------------------
module bank_fsm
  import ddr4_pkg::*;
(
  input  logic               clk,
  input  logic               rst_n,
  input  var timing_t        t_i,

  // command strobes, one cycle each, already qualified for this bank
  input  logic               act_i,
  input  logic [ROW_W-1:0]   row_i,
  input  logic               rd_i,
  input  logic               wr_i,
  input  logic               pre_i,       // PRE to this bank, or PREA
  input  logic               ref_i,       // REF issued (all banks)
  input  logic               ref_done_i,  // tRFC has expired

  output bank_state_e        state_o,
  output logic [ROW_W-1:0]   open_row_o,
  output logic               row_valid_o, // open_row_o is meaningful
  output logic               can_act_o,
  output logic               can_rdwr_o,
  output logic               can_pre_o
);
  bank_state_e state, state_nxt;
  tcnt_t act_cnt,  act_cnt_nxt;   // guards ACT   (tRP, tRC)
  tcnt_t rdwr_cnt, rdwr_cnt_nxt;  // guards RD/WR (tRCD)
  tcnt_t pre_cnt,  pre_cnt_nxt;   // guards PRE   (tRAS, tRTP, write recovery)

  // --------------------------------- counters -------------------------------
  always_comb begin
    act_cnt_nxt  = tcnt_dec(act_cnt);
    rdwr_cnt_nxt = tcnt_dec(rdwr_cnt);
    pre_cnt_nxt  = tcnt_dec(pre_cnt);

    if (act_i) begin
      act_cnt_nxt  = tcnt_load(act_cnt,  t_i.t_rc);
      rdwr_cnt_nxt = tcnt_load(rdwr_cnt, t_i.t_rcd);
      pre_cnt_nxt  = tcnt_load(pre_cnt,  t_i.t_ras);
    end
    if (rd_i)  pre_cnt_nxt = tcnt_load(pre_cnt, t_i.t_rtp);
    if (wr_i)  pre_cnt_nxt = tcnt_load(pre_cnt, t_i.t_wr2pre);
    if (pre_i) act_cnt_nxt = tcnt_load(act_cnt, t_i.t_rp);
  end

  // ---------------------------------- state ---------------------------------
  always_comb begin
    state_nxt = state;
    unique case (state)
      BS_IDLE: begin
        if      (act_i) state_nxt = BS_ACTIVATING;
        else if (ref_i) state_nxt = BS_REFRESHING;
      end
      BS_ACTIVATING: begin
        if (rdwr_cnt_nxt == '0) state_nxt = BS_OPEN;
      end
      BS_OPEN: begin
        if (pre_i) state_nxt = BS_PRECHARGING;
      end
      BS_PRECHARGING: begin
        if (act_cnt_nxt == '0) state_nxt = BS_IDLE;
      end
      BS_REFRESHING: begin
        if (ref_done_i) state_nxt = BS_IDLE;
      end
      default: state_nxt = BS_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= BS_IDLE;
      act_cnt  <= '0;
      rdwr_cnt <= '0;
      pre_cnt  <= '0;
    end else begin
      state    <= state_nxt;
      act_cnt  <= act_cnt_nxt;
      rdwr_cnt <= rdwr_cnt_nxt;
      pre_cnt  <= pre_cnt_nxt;
    end
  end

  always_ff @(posedge clk) begin
    if (act_i) open_row_o <= row_i;
  end

  // --------------------------------- outputs --------------------------------
  assign state_o     = state;
  assign row_valid_o = (state == BS_ACTIVATING) || (state == BS_OPEN);
  assign can_act_o   = (state == BS_IDLE) && (act_cnt == '0);
  assign can_rdwr_o  = (state == BS_OPEN) && (rdwr_cnt == '0);
  assign can_pre_o   = (state == BS_IDLE) ||
                       ((state == BS_OPEN) && (pre_cnt == '0));

  // -------------------------------- assertions ------------------------------
`ifndef SYNTHESIS
  // The arbiter must never issue a command the bank is not ready for.
  a_act_legal:  assert property (@(posedge clk) disable iff (!rst_n) act_i |-> can_act_o)
    else $error("bank_fsm: ACT issued while not legal");
  a_rd_legal:   assert property (@(posedge clk) disable iff (!rst_n) rd_i |-> can_rdwr_o)
    else $error("bank_fsm: RD issued while not legal");
  a_wr_legal:   assert property (@(posedge clk) disable iff (!rst_n) wr_i |-> can_rdwr_o)
    else $error("bank_fsm: WR issued while not legal");
  a_pre_legal:  assert property (@(posedge clk) disable iff (!rst_n) pre_i |-> can_pre_o)
    else $error("bank_fsm: PRE issued while not legal");
  a_ref_legal:  assert property (@(posedge clk) disable iff (!rst_n)
                                 ref_i |-> (state == BS_IDLE) && (act_cnt == '0))
    else $error("bank_fsm: REF issued while bank not idle");
`endif
endmodule
