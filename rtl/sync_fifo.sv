// -----------------------------------------------------------------------------
// sync_fifo.sv
// Single-clock first-word-fall-through FIFO. Depth is 2**ADDR_W.
// -----------------------------------------------------------------------------
module sync_fifo #(
  parameter int DATA_W = 8,
  parameter int ADDR_W = 4
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              push_i,
  input  logic [DATA_W-1:0] data_i,
  input  logic              pop_i,
  output logic [DATA_W-1:0] data_o,
  output logic              empty_o,
  output logic              full_o,
  output logic [ADDR_W:0]   count_o
);
  localparam int DEPTH = 1 << ADDR_W;

  logic [DATA_W-1:0] mem [DEPTH];
  logic [ADDR_W:0]   wptr, rptr;
  logic              do_push, do_pop;

  assign count_o = wptr - rptr;
  assign empty_o = (wptr == rptr);
  assign full_o  = (count_o == (ADDR_W+1)'(DEPTH));
  assign do_push = push_i && !full_o;
  assign do_pop  = pop_i  && !empty_o;
  assign data_o  = mem[rptr[ADDR_W-1:0]];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr <= '0;
      rptr <= '0;
    end else begin
      if (do_push) wptr <= wptr + 1'b1;
      if (do_pop)  rptr <= rptr + 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (do_push) mem[wptr[ADDR_W-1:0]] <= data_i;
  end

`ifndef SYNTHESIS
  a_no_overflow:  assert property (@(posedge clk) disable iff (!rst_n) push_i |-> !full_o)
    else $error("sync_fifo: push while full");
  a_no_underflow: assert property (@(posedge clk) disable iff (!rst_n) pop_i |-> !empty_o)
    else $error("sync_fifo: pop while empty");
`endif
endmodule
