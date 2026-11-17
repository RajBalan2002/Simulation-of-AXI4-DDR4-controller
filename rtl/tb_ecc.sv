// Self-checking testbench for ecc_enc / ecc_dec.
//   - clean words decode unchanged with no flags
//   - every single-bit error (72 positions) is corrected and flagged ce
//   - every double-bit error (2556 pairs) is flagged ue and never "corrected"
`timescale 1ns/1ps
module tb_ecc;
  import ddr4_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic              enc_vi = 0, enc_vo;
  logic [DATA_W-1:0] enc_d = '0;
  logic [CODE_W-1:0] enc_code;
  ecc_enc u_enc (.clk, .rst_n, .valid_i(enc_vi), .data_i(enc_d),
                 .valid_o(enc_vo), .code_o(enc_code));

  logic              dec_vi = 0, dec_vo, ce, ue;
  logic [CODE_W-1:0] dec_code = '0;
  logic [DATA_W-1:0] dec_d;
  logic [CHK_W-1:0]  synd;
  ecc_dec u_dec (.clk, .rst_n, .valid_i(dec_vi), .code_i(dec_code),
                 .valid_o(dec_vo), .data_o(dec_d), .ce_o(ce), .ue_o(ue),
                 .syndrome_o(synd));

  int errors = 0, n_clean = 0, n_single = 0, n_double = 0;

  function automatic logic [DATA_W-1:0] rand64();
    return {$urandom, $urandom};
  endfunction

  // Send one (possibly corrupted) code word through the decoder and check it.
  task automatic check(input logic [DATA_W-1:0] d, input logic [CODE_W-1:0] flipmask,
                       input int nflips);
    logic [CODE_W-1:0] cw;
    cw = {ecc_check_bits(d), d} ^ flipmask;
    @(negedge clk); dec_vi = 1; dec_code = cw;
    @(negedge clk); dec_vi = 0;
    @(negedge clk);                       // two-stage pipeline
    if (!dec_vo) begin errors++; $display("ERROR: no valid out"); end
    case (nflips)
      0: begin
        n_clean++;
        if (dec_d !== d || ce || ue) begin
          errors++; $display("ERROR clean: d=%h got=%h ce=%b ue=%b", d, dec_d, ce, ue);
        end
      end
      1: begin
        n_single++;
        if (dec_d !== d || !ce || ue) begin
          errors++; $display("ERROR single: mask=%h d=%h got=%h ce=%b ue=%b",
                             flipmask, d, dec_d, ce, ue);
        end
      end
      default: begin
        n_double++;
        if (!ue || ce) begin
          errors++; $display("ERROR double: mask=%h ce=%b ue=%b synd=%h",
                             flipmask, ce, ue, synd);
        end
      end
    endcase
  endtask

  initial begin
    logic [DATA_W-1:0] d;
    repeat (3) @(negedge clk);
    rst_n = 1;

    // encoder module agrees with the package function
    repeat (50) begin
      d = rand64();
      @(negedge clk); enc_vi = 1; enc_d = d;
      @(negedge clk); enc_vi = 0;
      if (!enc_vo || enc_code !== {ecc_check_bits(d), d}) begin
        errors++; $display("ERROR: encoder mismatch for %h", d);
      end
    end

    check(64'h0, '0, 0);
    check('1, '0, 0);
    repeat (200) check(rand64(), '0, 0);

    for (int i = 0; i < CODE_W; i++)
      check(rand64(), CODE_W'(1) << i, 1);

    for (int i = 0; i < CODE_W; i++)
      for (int j = i + 1; j < CODE_W; j++)
        check(rand64(), (CODE_W'(1) << i) | (CODE_W'(1) << j), 2);

    $display("ecc: clean=%0d single=%0d double=%0d errors=%0d  %s",
             n_clean, n_single, n_double, errors, errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
