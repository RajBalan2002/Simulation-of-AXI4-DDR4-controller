// Self-checking testbench for async_fifo.
// Random push/pop on two unrelated clocks, compared against a queue model.
`timescale 1ps/1ps
module tb_async_fifo #(
  parameter int WHALF = 5000,    // write clock half period, ps
  parameter int RHALF = 2500,    // read  clock half period, ps
  parameter int N     = 20000    // words to transfer
);
  localparam int DATA_W = 16;
  localparam int ADDR_W = 3;
  localparam int DEPTH  = 1 << ADDR_W;

  logic wclk = 0, rclk = 0, wrst_n = 0, rrst_n = 0;
  logic winc = 0, rinc = 0, wfull, rempty;
  logic [DATA_W-1:0] wdata = '0, rdata;
  logic [ADDR_W:0]   wfree;

  always #(WHALF) wclk = ~wclk;
  always #(RHALF) rclk = ~rclk;

  async_fifo #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) dut (.*);

  logic [DATA_W-1:0] model [$];
  int pushed = 0, popped = 0, errors = 0, max_fill = 0;
  int saw_full = 0, saw_empty_after_start = 0;
  int wr_pct = 90, rd_pct = 20;   // push / pop probability, percent

  // write side: stimulus changes on the falling edge, model samples on rising
  always @(negedge wclk) begin
    winc  <= wrst_n && (pushed < N) && ($urandom_range(0, 99) < wr_pct);
    wdata <= DATA_W'($urandom);
  end
  always @(posedge wclk) if (wrst_n) begin
    if (wfull) saw_full++;
    // wfree must never promise more room than really exists
    if (int'(wfree) > DEPTH - model.size()) begin
      errors++; $display("ERROR: wfree=%0d but only %0d slots free", wfree, DEPTH - model.size());
    end
    // wfull is registered, so it may stay high one cycle after wfree shows room;
    // the reverse (no room but not full) must never happen
    if (wfree == 0 && !wfull) begin
      errors++; $display("ERROR: wfree is 0 but wfull is low");
    end
    if (winc && !wfull) begin
      model.push_back(wdata);
      pushed++;
      if (model.size() > max_fill) max_fill = model.size();
      if (model.size() > DEPTH) begin
        errors++; $display("ERROR: overflow, model holds %0d", model.size());
      end
    end
  end

  // read side
  always @(negedge rclk) rinc <= rrst_n && ($urandom_range(0, 99) < rd_pct);
  always @(posedge rclk) if (rrst_n) begin
    if (rempty && pushed > 0) saw_empty_after_start++;
    if (rinc && !rempty) begin
      if (model.size() == 0) begin
        errors++; $display("ERROR: pop with empty model");
      end else begin
        logic [DATA_W-1:0] exp;
        exp = model.pop_front();
        if (rdata !== exp) begin
          errors++; $display("ERROR: got %h expected %h at pop %0d", rdata, exp, popped);
        end
      end
      popped++;
    end
  end

  // vary the push/pop rates so both full and empty are exercised
  initial begin
    repeat (4) @(posedge wclk);
    wrst_n = 1; rrst_n = 1;
    forever begin
      repeat (2000) @(posedge wclk);
      wr_pct = $urandom_range(10, 100);
      rd_pct = $urandom_range(10, 100);
    end
  end

  initial begin
    wait (popped == N);
    repeat (10) @(posedge rclk);
    if (model.size() != 0) begin errors++; $display("ERROR: model not empty at end"); end
    if (saw_full == 0)              begin errors++; $display("ERROR: full never seen"); end
    if (saw_empty_after_start == 0) begin errors++; $display("ERROR: empty never seen"); end
    $display("async_fifo W=%0d R=%0d: pushed=%0d popped=%0d max_fill=%0d full_cycles=%0d errors=%0d  %s",
             WHALF, RHALF, pushed, popped, max_fill, saw_full, errors,
             errors == 0 ? "PASS" : "FAIL");
    $finish;
  end

  // Watchdog counted in write-clock cycles, so it does not depend on the
  // timescale or on how a simulator sizes a large delay value.
  localparam int WATCHDOG_CYCLES = 2_000_000;
  initial begin
    repeat (WATCHDOG_CYCLES) @(posedge wclk);
    $display("TIMEOUT FAIL at %0t: pushed=%0d popped=%0d wfull=%b rempty=%b",
             $time, pushed, popped, wfull, rempty);
    $finish;
  end
endmodule
