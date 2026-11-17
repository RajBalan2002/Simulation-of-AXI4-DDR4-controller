// -----------------------------------------------------------------------------
// dfi_if.sv
// Controller side of the PHY interface, 1:4 frequency ratio.
//
// Timing contract of this version (cycle-aligned; see README):
//   - A command decided by ctrl_core in cycle T appears on phase 0 of the DFI
//     command bus in cycle C = T+1. Phases 1..3 carry deselect.
//   - A write burst is presented whole in cycle C + wr_lat_i, with all four
//     dfi_wrdata_en bits set. The PHY places it on the pins at write latency.
//   - dfi_rddata_en (all four bits) is raised in cycle C + rden_lat_i. The PHY
//     returns the whole burst in one cycle with all dfi_rddata_valid bits set.
//
// A phase-accurate DFI (enable and data starting mid-cycle) needs a shifter on
// each path and is not implemented yet.
// -----------------------------------------------------------------------------
module dfi_if
  import ddr4_pkg::*;
#(
  parameter int MAX_LAT = 8
) (
  input  logic                     clk,
  input  logic                     rst_n,

  // from ctrl_core (this cycle's decision)
  input  var cmd_t                 cmd_i,
  input  logic                     cke_i,
  input  logic                     mem_reset_n_i,
  input  logic                     rd_issued_i,

  input  logic [2:0]               wr_lat_i,
  input  logic [2:0]               rden_lat_i,

  // encoded write burst: valid one cycle after the WR decision
  input  logic                     wr_valid_i,
  input  logic [BURST_CODE_W-1:0]  wr_code_i,
  input  logic [BURST_WORDS-1:0]   wr_mask_i,      // 1 = word is written

  // captured read burst
  output logic                     rd_valid_o,
  output logic [BURST_CODE_W-1:0]  rd_code_o,

  // DFI command
  output logic [DFI_PHASES-1:0]             dfi_reset_n,
  output logic [DFI_PHASES-1:0]             dfi_cke,
  output logic [DFI_PHASES-1:0]             dfi_odt,
  output logic [DFI_PHASES-1:0]             dfi_cs_n,
  output logic [DFI_PHASES-1:0]             dfi_act_n,
  output logic [DFI_PHASES-1:0]             dfi_ras_n,
  output logic [DFI_PHASES-1:0]             dfi_cas_n,
  output logic [DFI_PHASES-1:0]             dfi_we_n,
  output logic [DFI_PHASES-1:0][BG_W-1:0]   dfi_bg,
  output logic [DFI_PHASES-1:0][BA_W-1:0]   dfi_ba,
  output logic [DFI_PHASES-1:0][13:0]       dfi_address,
  // DFI write data
  output logic [DFI_PHASES-1:0]             dfi_wrdata_en,
  output logic [BURST_CODE_W-1:0]           dfi_wrdata,
  output logic [BURST_WORDS*9-1:0]          dfi_wrdata_mask,   // 1 = byte masked
  // DFI read data
  output logic [DFI_PHASES-1:0]             dfi_rddata_en,
  input  logic [BURST_CODE_W-1:0]           dfi_rddata,
  input  logic [DFI_PHASES-1:0]             dfi_rddata_valid
);
  // ------------------------------- command bus ------------------------------
  ca_pins_t pins;
  assign pins = encode_cmd(cmd_i);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dfi_reset_n <= '0;
      dfi_cke     <= '0;
      dfi_cs_n    <= '1;
      dfi_act_n   <= '1;
      dfi_ras_n   <= '1;
      dfi_cas_n   <= '1;
      dfi_we_n    <= '1;
      dfi_bg      <= '0;
      dfi_ba      <= '0;
      dfi_address <= '0;
    end else begin
      dfi_reset_n <= {DFI_PHASES{mem_reset_n_i}};
      dfi_cke     <= {DFI_PHASES{cke_i}};
      // phase 0 carries the command, the other phases stay deselected
      dfi_cs_n    <= {{(DFI_PHASES-1){1'b1}}, pins.cs_n};
      dfi_act_n   <= {{(DFI_PHASES-1){1'b1}}, pins.act_n};
      dfi_ras_n   <= {{(DFI_PHASES-1){1'b1}}, pins.ras_n};
      dfi_cas_n   <= {{(DFI_PHASES-1){1'b1}}, pins.cas_n};
      dfi_we_n    <= {{(DFI_PHASES-1){1'b1}}, pins.we_n};
      dfi_bg      <= '0;
      dfi_ba      <= '0;
      dfi_address <= '0;
      dfi_bg[0]      <= pins.bg;
      dfi_ba[0]      <= pins.ba;
      dfi_address[0] <= pins.a;
    end
  end

  // ------------------------------ write data path ---------------------------
  // The encoder output is already aligned with the command cycle C (latency 0).
  // dly_*[k] holds that burst delayed by k cycles, for k = 1 .. MAX_LAT-1.
  logic                     dly_valid [MAX_LAT];
  logic [BURST_CODE_W-1:0]  dly_code  [MAX_LAT];
  logic [BURST_WORDS-1:0]   dly_mask  [MAX_LAT];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int k = 0; k < MAX_LAT; k++) dly_valid[k] <= 1'b0;
    end else begin
      dly_valid[0] <= 1'b0;                 // index 0 is unused
      dly_valid[1] <= wr_valid_i;
      for (int k = 2; k < MAX_LAT; k++) dly_valid[k] <= dly_valid[k-1];
    end
  end

  always_ff @(posedge clk) begin
    if (wr_valid_i) begin
      dly_code[1] <= wr_code_i;
      dly_mask[1] <= wr_mask_i;
    end
    for (int k = 2; k < MAX_LAT; k++) begin
      if (dly_valid[k-1]) begin
        dly_code[k] <= dly_code[k-1];
        dly_mask[k] <= dly_mask[k-1];
      end
    end
  end

  logic                    wr_now;
  logic [BURST_WORDS-1:0]  wr_now_mask;

  assign wr_now        = (wr_lat_i == 3'd0) ? wr_valid_i : dly_valid[wr_lat_i];
  assign wr_now_mask   = (wr_lat_i == 3'd0) ? wr_mask_i  : dly_mask[wr_lat_i];
  assign dfi_wrdata_en = {DFI_PHASES{wr_now}};
  assign dfi_wrdata    = (wr_lat_i == 3'd0) ? wr_code_i  : dly_code[wr_lat_i];
  assign dfi_odt       = {DFI_PHASES{wr_now}};

  always_comb begin
    for (int w = 0; w < BURST_WORDS; w++)
      dfi_wrdata_mask[w*9 +: 9] = {9{!wr_now_mask[w]}};
  end

  // ------------------------------ read enable path --------------------------
  logic [MAX_LAT-1:0] rp;   // rp[0] is aligned with the command cycle C

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rp <= '0;
    else        rp <= {rp[MAX_LAT-2:0], rd_issued_i};
  end

  assign dfi_rddata_en = {DFI_PHASES{rp[rden_lat_i]}};

  // ------------------------------ read data capture -------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rd_valid_o <= 1'b0;
    else        rd_valid_o <= dfi_rddata_valid[0];
  end

  always_ff @(posedge clk) begin
    if (dfi_rddata_valid[0]) rd_code_o <= dfi_rddata;
  end

`ifndef SYNTHESIS
  a_rdvalid_whole: assert property (@(posedge clk) disable iff (!rst_n)
                                    (dfi_rddata_valid == '0) || (dfi_rddata_valid == '1))
    else $error("dfi_if: this version needs read bursts aligned to one cycle");
`endif
endmodule
