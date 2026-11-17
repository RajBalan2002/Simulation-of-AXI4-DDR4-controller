// -----------------------------------------------------------------------------
// cdc_cells.sv
// Clock-domain-crossing primitives. Keep these as separate modules so CDC tools
// and synthesis constraints (set_max_delay / set_false_path) can find them.
// -----------------------------------------------------------------------------

// Multi-flop synchronizer for a level signal or a Gray-coded bus.
module sync_ff #(
  parameter int WIDTH  = 1,
  parameter int STAGES = 2,
  parameter logic [WIDTH-1:0] RESET_VAL = '0
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [WIDTH-1:0] d,
  output logic [WIDTH-1:0] q
);
  logic [WIDTH-1:0] ff [STAGES];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < STAGES; i++) ff[i] <= RESET_VAL;
    end else begin
      ff[0] <= d;
      for (int i = 1; i < STAGES; i++) ff[i] <= ff[i-1];
    end
  end

  assign q = ff[STAGES-1];
endmodule

// Reset synchronizer: asynchronous assert, synchronous release.
module reset_sync #(
  parameter int STAGES = 2
) (
  input  logic clk,
  input  logic arst_n,
  output logic rst_n
);
  logic [STAGES-1:0] ff;

  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) ff <= '0;
    else         ff <= {ff[STAGES-2:0], 1'b1};
  end

  assign rst_n = ff[STAGES-1];
endmodule
