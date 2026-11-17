// -----------------------------------------------------------------------------
// ecc.sv
// Hsiao (72,64) single-error-correct, double-error-detect encoder and decoder.
// Code word layout: {check[7:0], data[63:0]}.
// -----------------------------------------------------------------------------

// One pipeline stage.
module ecc_enc
  import ddr4_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,
  input  logic              valid_i,
  input  logic [DATA_W-1:0] data_i,
  output logic              valid_o,
  output logic [CODE_W-1:0] code_o
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) valid_o <= 1'b0;
    else        valid_o <= valid_i;
  end

  always_ff @(posedge clk) begin
    if (valid_i) code_o <= {ecc_check_bits(data_i), data_i};
  end
endmodule

// Two pipeline stages: syndrome, then correct.
//   ce_o : a single-bit error was corrected (in data or in a check bit)
//   ue_o : uncorrectable error detected; data_o is not trustworthy
module ecc_dec
  import ddr4_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,
  input  logic              valid_i,
  input  logic [CODE_W-1:0] code_i,
  output logic              valid_o,
  output logic [DATA_W-1:0] data_o,
  output logic              ce_o,
  output logic              ue_o,
  output logic [CHK_W-1:0]  syndrome_o
);
  // ---- stage 1: syndrome ----
  logic              s1_valid;
  logic [DATA_W-1:0] s1_data;
  logic [CHK_W-1:0]  s1_synd;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s1_valid <= 1'b0;
    else        s1_valid <= valid_i;
  end

  always_ff @(posedge clk) begin
    if (valid_i) begin
      s1_data <= code_i[DATA_W-1:0];
      s1_synd <= ecc_check_bits(code_i[DATA_W-1:0]) ^ code_i[CODE_W-1:DATA_W];
    end
  end

  // ---- stage 2: locate and correct ----
  logic [DATA_W-1:0] flip;
  logic              data_hit;    // syndrome equals a data column
  logic              chk_hit;     // syndrome has exactly one bit set

  always_comb begin
    for (int j = 0; j < DATA_W; j++)
      flip[j] = (s1_synd == HSIAO_COLS[j*CHK_W +: CHK_W]);
  end

  assign data_hit = |flip;
  assign chk_hit  = (s1_synd != '0) && ((s1_synd & (s1_synd - 1'b1)) == '0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) valid_o <= 1'b0;
    else        valid_o <= s1_valid;
  end

  always_ff @(posedge clk) begin
    if (s1_valid) begin
      data_o     <= s1_data ^ flip;
      ce_o       <= data_hit || chk_hit;
      ue_o       <= (s1_synd != '0) && !data_hit && !chk_hit;
      syndrome_o <= s1_synd;
    end
  end
endmodule
