// -----------------------------------------------------------------------------
// ddr4_ctrl_if.sv
// Clocks and resets. tb_top generates the clocks; tests drive the resets
// through apply_reset(), so a test can also reset the DUT mid-traffic (F28).
// -----------------------------------------------------------------------------
interface ddr4_ctrl_if (
  input logic aclk,
  input logic cclk
);
  logic aresetn = 1'b1;
  logic crst_n  = 1'b1;

  // Assert both asynchronous resets together, hold them for the given number
  // of cycles of the slower clock, then release them independently on each
  // domain's falling edge.
  task automatic apply_reset(input int unsigned hold_cycles = 16);
    #1;                         // make the falling edge visible after time 0
    aresetn = 1'b0;
    crst_n  = 1'b0;
    repeat (hold_cycles) begin
      @(posedge aclk);
      @(posedge cclk);
    end
    fork
      begin @(negedge aclk); aresetn = 1'b1; end
      begin @(negedge cclk); crst_n  = 1'b1; end
    join
  endtask

  task automatic wait_aclk(input int unsigned n);
    repeat (n) @(posedge aclk);
  endtask

  task automatic wait_cclk(input int unsigned n);
    repeat (n) @(posedge cclk);
  endtask
endinterface
