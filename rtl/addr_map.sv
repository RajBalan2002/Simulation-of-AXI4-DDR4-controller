// -----------------------------------------------------------------------------
// addr_map.sv
// AXI byte address -> DRAM coordinates.
//
//   [2:0]   byte within 64-bit word (not used for addressing)
//   [5:3]   word within BL8 burst
//   [12:6]  column[9:3]
//   [14:13] bank
//   [16:15] bank group
//   [32:17] row
// -----------------------------------------------------------------------------
module addr_map
  import ddr4_pkg::*;
(
  input  logic [AXI_ADDR_W-1:0]    addr_i,
  output logic [ROW_W-1:0]         row_o,
  output logic [BG_W-1:0]          bg_o,
  output logic [BA_W-1:0]          ba_o,
  output logic [BURST_COL_W-1:0]   col_hi_o,
  output logic [2:0]               word_o
);
  localparam int WORD_LSB = 3;
  localparam int COL_LSB  = WORD_LSB + 3;
  localparam int BA_LSB   = COL_LSB + BURST_COL_W;
  localparam int BG_LSB   = BA_LSB + BA_W;
  localparam int ROW_LSB  = BG_LSB + BG_W;

  assign word_o   = addr_i[WORD_LSB +: 3];
  assign col_hi_o = addr_i[COL_LSB  +: BURST_COL_W];
  assign ba_o     = addr_i[BA_LSB   +: BA_W];
  assign bg_o     = addr_i[BG_LSB   +: BG_W];
  assign row_o    = addr_i[ROW_LSB  +: ROW_W];
endmodule
