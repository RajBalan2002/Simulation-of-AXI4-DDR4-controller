// -----------------------------------------------------------------------------
// phy_mem_bfm.sv  (testbench only)
// Cycle-level behavioral PHY and memory for the DFI side of the controller.
//
//   - decodes commands from the phase-0 DFI pin levels
//   - checks that write data and read enables arrive in exactly the agreed cycle
//   - stores encoded bursts, honouring the per-word write mask
//   - returns read bursts after RD_PHY_LAT cycles, optionally with bit errors
//
// inj1_pct / inj2_pct are plain variables so a test can change them at run time.
// This model does not check DDR4 pin timing; that needs the vendor model.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module phy_mem_bfm
  import ddr4_pkg::*;
#(
  parameter int WR_LAT     = 2,
  parameter int RDEN_LAT   = 3,
  parameter int RD_PHY_LAT = 2
) (
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic [DFI_PHASES-1:0]             dfi_cs_n,
  input  logic [DFI_PHASES-1:0]             dfi_act_n,
  input  logic [DFI_PHASES-1:0]             dfi_ras_n,
  input  logic [DFI_PHASES-1:0]             dfi_cas_n,
  input  logic [DFI_PHASES-1:0]             dfi_we_n,
  input  logic [DFI_PHASES-1:0][BG_W-1:0]   dfi_bg,
  input  logic [DFI_PHASES-1:0][BA_W-1:0]   dfi_ba,
  input  logic [DFI_PHASES-1:0][13:0]       dfi_address,
  input  logic [DFI_PHASES-1:0]             dfi_wrdata_en,
  input  logic [BURST_CODE_W-1:0]           dfi_wrdata,
  input  logic [BURST_WORDS*9-1:0]          dfi_wrdata_mask,
  input  logic [DFI_PHASES-1:0]             dfi_rddata_en,
  output logic [BURST_CODE_W-1:0]           dfi_rddata,
  output logic [DFI_PHASES-1:0]             dfi_rddata_valid
);
  localparam int KEY_W = BANK_W + ROW_W + BURST_COL_W;

  int inj1_pct = 0;      // % of returned words given a single-bit error
  int inj2_pct = 0;      // % of returned words given a double-bit error
  int errors   = 0;
  int n_single = 0, n_double = 0, n_wr = 0, n_rd = 0;
  int cyc      = 0;

  bit                       p_open [NUM_BANKS];
  logic [ROW_W-1:0]         p_row  [NUM_BANKS];
  logic [BURST_CODE_W-1:0]  mem [bit [KEY_W-1:0]];
  int                       wr_due_q [$];
  bit [KEY_W-1:0]           wr_key_q [$];
  int                       rd_due_q [$];
  bit [KEY_W-1:0]           rd_key_q [$];
  int                       ret_due_q [$];
  logic [BURST_CODE_W-1:0]  ret_code_q [$];

  int                       pb, bit_a, bit_b, roll;
  bit [KEY_W-1:0]           key;
  logic [ROW_W-1:0]         prow;
  logic [BURST_CODE_W-1:0]  code;

  task automatic fail(input string msg);
    errors++;
    if (errors <= 20) $display("PHY ERROR @%0d: %s", cyc, msg);
  endtask

  function automatic bit idle();
    return (wr_due_q.size() == 0) && (rd_due_q.size() == 0) && (ret_due_q.size() == 0);
  endfunction

  initial begin
    dfi_rddata       = '0;
    dfi_rddata_valid = '0;
    for (int i = 0; i < NUM_BANKS; i++) begin p_open[i] = 0; p_row[i] = '0; end
  end

  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (rst_n) begin
      // ------------------------------ commands ------------------------------
      if (dfi_cs_n[DFI_PHASES-1:1] != '1) fail("command on a phase other than 0");
      if (!dfi_cs_n[0]) begin
        pb = int'({dfi_bg[0], dfi_ba[0]});
        if (!dfi_act_n[0]) begin
          p_open[pb] = 1;
          p_row[pb]  = {dfi_cas_n[0], dfi_we_n[0], dfi_address[0]};
        end else begin
          case ({dfi_ras_n[0], dfi_cas_n[0], dfi_we_n[0]})
            3'b010: begin
              if (dfi_address[0][10]) begin
                for (int i = 0; i < NUM_BANKS; i++) p_open[i] = 0;
              end else p_open[pb] = 0;
            end
            3'b100, 3'b101: begin
              if (!p_open[pb]) fail("RD/WR to a closed bank");
              if (dfi_address[0][2:0] != 3'b000) fail("burst not column-aligned");
              prow = p_row[pb];
              key  = {dfi_bg[0], dfi_ba[0], prow, dfi_address[0][9:3]};
              if (dfi_we_n[0]) begin
                rd_due_q.push_back(cyc + RDEN_LAT); rd_key_q.push_back(key); n_rd++;
              end else begin
                wr_due_q.push_back(cyc + WR_LAT);   wr_key_q.push_back(key); n_wr++;
              end
            end
            default: ;
          endcase
        end
      end

      // ----------------------------- write data -----------------------------
      if (dfi_wrdata_en != '0) begin
        if (wr_due_q.size() == 0 || wr_due_q[0] != cyc) fail("write data in the wrong cycle");
        else begin
          key = wr_key_q[0];
          if (!mem.exists(key)) mem[key] = '0;
          code = mem[key];
          for (int w = 0; w < BURST_WORDS; w++)
            if (dfi_wrdata_mask[w*9 +: 9] == '0)
              code[w*CODE_W +: CODE_W] = dfi_wrdata[w*CODE_W +: CODE_W];
          mem[key] = code;
          void'(wr_due_q.pop_front()); void'(wr_key_q.pop_front());
        end
      end else if (wr_due_q.size() != 0 && wr_due_q[0] <= cyc) begin
        fail("write data did not arrive");
        void'(wr_due_q.pop_front()); void'(wr_key_q.pop_front());
      end

      // ----------------------------- read enable ----------------------------
      if (dfi_rddata_en != '0) begin
        if (rd_due_q.size() == 0 || rd_due_q[0] != cyc) fail("read enable in the wrong cycle");
        else begin
          key = rd_key_q[0];
          if (!mem.exists(key)) mem[key] = '0;      // never written: valid all-zero code
          code = mem[key];
          for (int w = 0; w < BURST_WORDS; w++) begin
            roll = $urandom_range(0, 99);
            if (roll < inj1_pct) begin
              bit_a = $urandom_range(0, CODE_W-1);
              code[w*CODE_W + bit_a] = ~code[w*CODE_W + bit_a];
              n_single++;
            end else if (roll < inj1_pct + inj2_pct) begin
              bit_a = $urandom_range(0, CODE_W-1);
              bit_b = (bit_a + $urandom_range(1, CODE_W-1)) % CODE_W;
              code[w*CODE_W + bit_a] = ~code[w*CODE_W + bit_a];
              code[w*CODE_W + bit_b] = ~code[w*CODE_W + bit_b];
              n_double++;
            end
          end
          ret_due_q.push_back(cyc + RD_PHY_LAT); ret_code_q.push_back(code);
          void'(rd_due_q.pop_front()); void'(rd_key_q.pop_front());
        end
      end else if (rd_due_q.size() != 0 && rd_due_q[0] <= cyc) begin
        fail("read enable did not arrive");
        void'(rd_due_q.pop_front()); void'(rd_key_q.pop_front());
      end

      // ---------------------------- read data out ---------------------------
      if (ret_due_q.size() != 0 && ret_due_q[0] == cyc + 1) begin
        dfi_rddata_valid <= '1;
        dfi_rddata       <= ret_code_q[0];
        void'(ret_due_q.pop_front()); void'(ret_code_q.pop_front());
      end else begin
        dfi_rddata_valid <= '0;
      end
    end
  end
endmodule
