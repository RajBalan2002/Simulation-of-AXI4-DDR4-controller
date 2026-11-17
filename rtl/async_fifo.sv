// -----------------------------------------------------------------------------
// async_fifo.sv
// Dual-clock FIFO with Gray-coded pointers synchronized into the opposite
// domain before the full/empty comparison (Cummings SNUG 2002, style #1).
//
//  - Depth is 2**ADDR_W (ADDR_W >= 2).
//  - Read data is first-word-fall-through: rdata is valid whenever !rempty.
//  - wfull and rempty are registered in their own domains. Each may be asserted
//    slightly longer than strictly necessary, never shorter.
// -----------------------------------------------------------------------------
module async_fifo #(
  parameter int DATA_W = 8,
  parameter int ADDR_W = 4
) (
  // write side
  input  logic              wclk,
  input  logic              wrst_n,
  input  logic              winc,
  input  logic [DATA_W-1:0] wdata,
  output logic              wfull,
  // read side
  input  logic              rclk,
  input  logic              rrst_n,
  input  logic              rinc,
  output logic [DATA_W-1:0] rdata,
  output logic              rempty
);
  localparam int DEPTH = 1 << ADDR_W;

  logic [DATA_W-1:0] mem [DEPTH];

  logic [ADDR_W:0] wbin, wbin_nxt, wgray, wgray_nxt;
  logic [ADDR_W:0] rbin, rbin_nxt, rgray, rgray_nxt;
  logic [ADDR_W:0] wgray_rclk;   // write pointer seen by the read side
  logic [ADDR_W:0] rgray_wclk;   // read pointer seen by the write side

  logic wr_en, rd_en;
  logic wfull_nxt, rempty_nxt;

  // ------------------------------ write domain ------------------------------
  assign wr_en     = winc && !wfull;
  assign wbin_nxt  = wbin + {{ADDR_W{1'b0}}, wr_en};
  assign wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;

  // Full when the next write pointer is one full lap ahead of the read
  // pointer: top two Gray bits inverted, the rest equal.
  assign wfull_nxt = (wgray_nxt ==
                      {~rgray_wclk[ADDR_W:ADDR_W-1], rgray_wclk[ADDR_W-2:0]});

  always_ff @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) begin
      wbin  <= '0;
      wgray <= '0;
      wfull <= 1'b0;
    end else begin
      wbin  <= wbin_nxt;
      wgray <= wgray_nxt;
      wfull <= wfull_nxt;
    end
  end

  always_ff @(posedge wclk) begin
    if (wr_en) mem[wbin[ADDR_W-1:0]] <= wdata;
  end

  // ------------------------------- read domain ------------------------------
  assign rd_en     = rinc && !rempty;
  assign rbin_nxt  = rbin + {{ADDR_W{1'b0}}, rd_en};
  assign rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

  assign rempty_nxt = (rgray_nxt == wgray_rclk);

  always_ff @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) begin
      rbin   <= '0;
      rgray  <= '0;
      rempty <= 1'b1;
    end else begin
      rbin   <= rbin_nxt;
      rgray  <= rgray_nxt;
      rempty <= rempty_nxt;
    end
  end

  assign rdata = mem[rbin[ADDR_W-1:0]];

  // --------------------------- pointer synchronizers ------------------------
  sync_ff #(.WIDTH(ADDR_W+1)) u_sync_w2r (
    .clk(rclk), .rst_n(rrst_n), .d(wgray), .q(wgray_rclk));

  sync_ff #(.WIDTH(ADDR_W+1)) u_sync_r2w (
    .clk(wclk), .rst_n(wrst_n), .d(rgray), .q(rgray_wclk));

endmodule
