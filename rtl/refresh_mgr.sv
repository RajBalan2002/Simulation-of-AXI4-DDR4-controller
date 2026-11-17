// -----------------------------------------------------------------------------
// refresh_mgr.sv
// Tracks how many refreshes are owed to the memory.
//
//   Every t_refi_i cycles one refresh becomes pending. DDR4 allows up to eight
//   to be postponed. The arbiter refreshes opportunistically while any_o is
//   set and the bus is idle, and must preempt traffic while urgent_o is set.
//   overflow_o is sticky and means a refresh was lost: a design bug.
// -----------------------------------------------------------------------------
module refresh_mgr #(
  parameter int REFI_W      = 16,
  parameter int MAX_PENDING = 8
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               en_i,          // low during init and self-refresh
  input  logic [REFI_W-1:0]  t_refi_i,      // refresh interval in cycles (>= 2)
  input  logic [3:0]         urgent_thresh_i,
  input  logic               ref_issued_i,  // a REF command went out this cycle

  output logic [3:0]         pending_o,
  output logic               any_o,
  output logic               urgent_o,
  output logic               overflow_o
);
  logic [REFI_W-1:0] interval_cnt;
  logic              tick;
  logic [3:0]        pending, pending_nxt;

  assign tick = en_i && (interval_cnt == '0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)       interval_cnt <= '0;
    else if (!en_i)   interval_cnt <= t_refi_i - 1'b1;
    else if (tick)    interval_cnt <= t_refi_i - 1'b1;
    else              interval_cnt <= interval_cnt - 1'b1;
  end

  always_comb begin
    pending_nxt = pending;
    unique case ({tick, ref_issued_i})
      2'b10:   if (pending != 4'(MAX_PENDING)) pending_nxt = pending + 1'b1;
      2'b01:   if (pending != '0)              pending_nxt = pending - 1'b1;
      default: ;   // both or neither: no change
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pending    <= '0;
      overflow_o <= 1'b0;
    end else begin
      pending <= pending_nxt;
      if (tick && !ref_issued_i && (pending == 4'(MAX_PENDING))) overflow_o <= 1'b1;
    end
  end

  assign pending_o = pending;
  assign any_o     = (pending != '0);
  assign urgent_o  = (pending >= urgent_thresh_i);
endmodule
