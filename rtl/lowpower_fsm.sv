// -----------------------------------------------------------------------------
// lowpower_fsm.sv
// Self-refresh entry and exit.
//
//   ACTIVE -> DRAIN : sr_req_i seen. The arbiter closes every bank and then
//                     issues the self-refresh entry command.
//   DRAIN  -> SR    : entry command issued. CKE is held low.
//   SR     -> ACTIVE: sr_req_i released and tCKESR satisfied; the arbiter
//                     issues the exit command and tXS starts in global_timers.
//
// After an exit, the memory requires at least one REFRESH before it may enter
// self-refresh again (Micron 8Gb DDR4 datasheet, self-refresh section).
// need_ref_o stays set from the exit command until that REFRESH is issued; the
// arbiter sends a REFRESH in place of the entry command while it is set.
//
// Precharge power-down is not implemented in this version.
// -----------------------------------------------------------------------------
module lowpower_fsm
  import ddr4_pkg::*;
(
  input  logic   clk,
  input  logic   rst_n,
  input  logic   init_done_i,
  input  logic   sr_req_i,
  input  var tcnt_t t_ckesr_i,      // minimum cycles with CKE low
  input  logic   sre_issued_i,
  input  logic   srx_issued_i,
  input  logic   ref_issued_i,

  output logic   drain_o,         // arbiter should close banks and enter SR
  output logic   in_sr_o,         // memory is in self-refresh
  output logic   srx_ok_o,        // exit command may be issued now
  output logic   need_ref_o       // a REFRESH is owed before the next entry
);
  typedef enum logic [1:0] {LP_ACTIVE, LP_DRAIN, LP_SR} lp_state_e;

  lp_state_e state;
  tcnt_t     cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= LP_ACTIVE;
      cnt   <= '0;
    end else begin
      case (state)
        LP_ACTIVE: if (init_done_i && sr_req_i) state <= LP_DRAIN;
        LP_DRAIN: begin
          if (sre_issued_i) begin
            state <= LP_SR;
            cnt   <= t_ckesr_i;
          end else if (!sr_req_i) begin
            state <= LP_ACTIVE;
          end
        end
        LP_SR: begin
          cnt <= tcnt_dec(cnt);
          if (srx_issued_i) state <= LP_ACTIVE;
        end
        default: state <= LP_ACTIVE;
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)            need_ref_o <= 1'b0;
    else if (srx_issued_i) need_ref_o <= 1'b1;
    else if (ref_issued_i) need_ref_o <= 1'b0;
  end

  // Gated with the live request: if it is withdrawn while banks are still being
  // closed, no entry command is issued in that final cycle.
  assign drain_o  = (state == LP_DRAIN) && sr_req_i;
  assign in_sr_o  = (state == LP_SR);
  assign srx_ok_o = (state == LP_SR) && (cnt == '0) && !sr_req_i;
endmodule
