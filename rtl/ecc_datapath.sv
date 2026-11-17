// -----------------------------------------------------------------------------
// ecc_datapath.sv
// Burst-wide ECC: eight independent Hsiao (72,64) encoders and decoders.
// Word w of a burst occupies data bits [w*64 +: 64] and code bits [w*72 +: 72].
//
//   write: 1 cycle   (wr_valid_i -> wr_valid_o)
//   read:  2 cycles  (rd_valid_i -> rd_valid_o)
// -----------------------------------------------------------------------------
module ecc_datapath
  import ddr4_pkg::*;
(
  input  logic                     clk,
  input  logic                     rst_n,

  // write side
  input  logic                     wr_valid_i,
  input  logic [BURST_DATA_W-1:0]  wr_data_i,
  input  logic [BURST_WORDS-1:0]   wr_mask_i,     // 1 = word is written
  output logic                     wr_valid_o,
  output logic [BURST_CODE_W-1:0]  wr_code_o,
  output logic [BURST_WORDS-1:0]   wr_mask_o,

  // read side
  input  logic                     rd_valid_i,
  input  logic [BURST_CODE_W-1:0]  rd_code_i,
  output logic                     rd_valid_o,
  output logic [BURST_DATA_W-1:0]  rd_data_o,
  output logic [BURST_WORDS-1:0]   rd_ce_o,       // per word: corrected
  output logic [BURST_WORDS-1:0]   rd_ue_o        // per word: uncorrectable
);
  logic [BURST_WORDS-1:0] enc_valid, dec_valid;

  for (genvar w = 0; w < BURST_WORDS; w++) begin : g_word
    ecc_enc u_enc (
      .clk     (clk),
      .rst_n   (rst_n),
      .valid_i (wr_valid_i),
      .data_i  (wr_data_i[w*DATA_W +: DATA_W]),
      .valid_o (enc_valid[w]),
      .code_o  (wr_code_o[w*CODE_W +: CODE_W])
    );

    ecc_dec u_dec (
      .clk        (clk),
      .rst_n      (rst_n),
      .valid_i    (rd_valid_i),
      .code_i     (rd_code_i[w*CODE_W +: CODE_W]),
      .valid_o    (dec_valid[w]),
      .data_o     (rd_data_o[w*DATA_W +: DATA_W]),
      .ce_o       (rd_ce_o[w]),
      .ue_o       (rd_ue_o[w]),
      .syndrome_o ()
    );
  end

  assign wr_valid_o = enc_valid[0];
  assign rd_valid_o = dec_valid[0];

  always_ff @(posedge clk) begin
    if (wr_valid_i) wr_mask_o <= wr_mask_i;
  end
endmodule
