// -----------------------------------------------------------------------------
// apb_csr.sv
// Configuration and status registers (APB, same clock as the AXI interface).
//
//   0x000 CTRL      [0] self-refresh request   [1] init start
//   0x004 STATUS    [0] init done  [1] in self-refresh  [2] refresh overflow   (RO)
//   0x008 INT_EN    [0] corrected error  [1] uncorrectable error  [2] refresh overflow
//   0x00C INT_STAT  same bits, write 1 to clear
//   0x010 ECC_CE    corrected-word count, saturating; any write clears
//   0x014 ECC_UE    uncorrectable-word count, saturating; any write clears
//   0x018 LATENCY   [2:0] write latency  [6:4] read-enable latency   (cycles)
//   0x01C REFRESH   [15:0] interval  [19:16] urgent threshold
//   0x020 T_RST   0x024 T_CKE   0x028 T_XPR   0x02C T_DLLK        (init waits)
//   0x030 T_CKESR
//   0x040 + 4*n     MRn opcode, n = 0..6
//   0x080 + 4*k     timing field k of ddr4_pkg::timing_t, k = 0 is t_rcd
//
// Configuration outputs are quasi-static: program them before setting
// CTRL.init_start and do not change them while traffic is running.
// -----------------------------------------------------------------------------
module apb_csr
  import ddr4_pkg::*;
#(
  parameter int  INIT_CNT_W = 20,
  parameter int  REFI_W     = 16,
  parameter bit  AUTO_START = 1'b1    // reset value of CTRL.init_start
) (
  input  logic                    pclk,
  input  logic                    presetn,
  input  logic                    psel,
  input  logic                    penable,
  input  logic                    pwrite,
  input  logic [11:0]             paddr,
  input  logic [31:0]             pwdata,
  output logic [31:0]             prdata,
  output logic                    pready,
  output logic                    pslverr,

  // configuration to the controller domain
  output timing_t                 t_o,
  output logic [INIT_CNT_W-1:0]   t_rst_o,
  output logic [INIT_CNT_W-1:0]   t_cke_o,
  output logic [INIT_CNT_W-1:0]   t_xpr_o,
  output logic [INIT_CNT_W-1:0]   t_dllk_o,
  output logic [6:0][13:0]        mr_o,
  output logic [REFI_W-1:0]       t_refi_o,
  output logic [3:0]              ref_thresh_o,
  output tcnt_t                   t_ckesr_o,
  output logic [2:0]              wr_lat_o,
  output logic [2:0]              rden_lat_o,
  output logic                    sr_req_o,
  output logic                    init_start_o,

  // status, already synchronized to pclk
  input  logic                    init_done_i,
  input  logic                    in_self_refresh_i,
  input  logic                    ref_overflow_i,
  // ECC events, already in the pclk domain
  input  logic                    ecc_evt_i,
  input  logic [3:0]              ecc_ce_cnt_i,
  input  logic [3:0]              ecc_ue_cnt_i,

  output logic                    irq_o
);
  localparam int N_TIMING = $bits(timing_t) / TCNT_W;      // 22 fields

  // Default mode-register opcodes are placeholders. VERIFY against the
  // datasheet for the chosen speed bin, CL and CWL before use.
  localparam logic [6:0][13:0] MR_RESET = {14'h0000, 14'h0400, 14'h0000, 14'h0000,
                                           14'h0018, 14'h0001, 14'h0A10};

  logic        wr_en, rd_en;
  logic [2:0]  int_en, int_stat;
  logic [31:0] ce_cnt, ue_cnt;
  logic [TCNT_W-1:0] t_field [N_TIMING];

  assign pready  = 1'b1;
  assign pslverr = 1'b0;
  assign wr_en   = psel && penable && pwrite;
  assign rd_en   = psel && !pwrite;

  // The timing struct is stored as an array of fields; field 0 is the first
  // member of timing_t (the most significant bits of the packed struct).
  timing_t t_reset;
  assign t_reset = timing_default_1600();

  always_comb begin
    for (int k = 0; k < N_TIMING; k++)
      t_o[(N_TIMING-1-k)*TCNT_W +: TCNT_W] = t_field[k];
  end

  function automatic logic [31:0] sat_add(input logic [31:0] a, input logic [3:0] b);
    logic [32:0] s;
    s = {1'b0, a} + {29'd0, b};
    return s[32] ? 32'hFFFF_FFFF : s[31:0];
  endfunction

  always_ff @(posedge pclk or negedge presetn) begin
    if (!presetn) begin
      sr_req_o     <= 1'b0;
      init_start_o <= AUTO_START;
      int_en       <= '0;
      int_stat     <= '0;
      ce_cnt       <= '0;
      ue_cnt       <= '0;
      wr_lat_o     <= 3'd2;
      rden_lat_o   <= 3'd3;
      t_refi_o     <= REFI_W'(1560);         // 7.8 us at 200 MHz
      ref_thresh_o <= 4'd6;
      t_rst_o      <= INIT_CNT_W'(40000);    // 200 us
      t_cke_o      <= INIT_CNT_W'(100000);   // 500 us
      t_xpr_o      <= INIT_CNT_W'(72);
      t_dllk_o     <= INIT_CNT_W'(150);
      t_ckesr_o    <= tcnt_t'(2);
      mr_o         <= MR_RESET;
      for (int k = 0; k < N_TIMING; k++)
        t_field[k] <= t_reset[(N_TIMING-1-k)*TCNT_W +: TCNT_W];
    end else begin
      // ---- event capture ----
      if (ecc_evt_i) begin
        ce_cnt <= sat_add(ce_cnt, ecc_ce_cnt_i);
        ue_cnt <= sat_add(ue_cnt, ecc_ue_cnt_i);
        if (ecc_ce_cnt_i != '0) int_stat[0] <= 1'b1;
        if (ecc_ue_cnt_i != '0) int_stat[1] <= 1'b1;
      end
      if (ref_overflow_i) int_stat[2] <= 1'b1;

      // ---- register writes ----
      if (wr_en) begin
        if (paddr[11:7] == 5'd0) begin
          case (paddr[6:2])
            5'h00: begin sr_req_o <= pwdata[0]; init_start_o <= pwdata[1]; end
            5'h02: int_en <= pwdata[2:0];
            5'h03: int_stat <= int_stat & ~pwdata[2:0];
            5'h04: ce_cnt <= '0;
            5'h05: ue_cnt <= '0;
            5'h06: begin wr_lat_o <= pwdata[2:0]; rden_lat_o <= pwdata[6:4]; end
            5'h07: begin t_refi_o <= pwdata[REFI_W-1:0]; ref_thresh_o <= pwdata[19:16]; end
            5'h08: t_rst_o   <= pwdata[INIT_CNT_W-1:0];
            5'h09: t_cke_o   <= pwdata[INIT_CNT_W-1:0];
            5'h0A: t_xpr_o   <= pwdata[INIT_CNT_W-1:0];
            5'h0B: t_dllk_o  <= pwdata[INIT_CNT_W-1:0];
            5'h0C: t_ckesr_o <= pwdata[TCNT_W-1:0];
            5'h10, 5'h11, 5'h12, 5'h13, 5'h14, 5'h15, 5'h16:
                   mr_o[paddr[4:2]] <= pwdata[13:0];
            default: ;
          endcase
        end else if (paddr[11:7] == 5'd1) begin
          if (int'(paddr[6:2]) < N_TIMING) t_field[paddr[6:2]] <= pwdata[TCNT_W-1:0];
        end
      end
    end
  end

  // ---- register reads (combinational; APB samples in the access phase) ----
  always_comb begin
    prdata = '0;
    if (rd_en) begin
      if (paddr[11:7] == 5'd0) begin
        case (paddr[6:2])
          5'h00: prdata = {30'd0, init_start_o, sr_req_o};
          5'h01: prdata = {29'd0, ref_overflow_i, in_self_refresh_i, init_done_i};
          5'h02: prdata = {29'd0, int_en};
          5'h03: prdata = {29'd0, int_stat};
          5'h04: prdata = ce_cnt;
          5'h05: prdata = ue_cnt;
          5'h06: prdata = {25'd0, rden_lat_o, 1'b0, wr_lat_o};
          5'h07: prdata = {12'd0, ref_thresh_o, t_refi_o};
          5'h08: prdata = {{(32-INIT_CNT_W){1'b0}}, t_rst_o};
          5'h09: prdata = {{(32-INIT_CNT_W){1'b0}}, t_cke_o};
          5'h0A: prdata = {{(32-INIT_CNT_W){1'b0}}, t_xpr_o};
          5'h0B: prdata = {{(32-INIT_CNT_W){1'b0}}, t_dllk_o};
          5'h0C: prdata = {{(32-TCNT_W){1'b0}}, t_ckesr_o};
          5'h10, 5'h11, 5'h12, 5'h13, 5'h14, 5'h15, 5'h16:
                 prdata = {18'd0, mr_o[paddr[4:2]]};
          default: ;
        endcase
      end else if (paddr[11:7] == 5'd1) begin
        if (int'(paddr[6:2]) < N_TIMING)
          prdata = {{(32-TCNT_W){1'b0}}, t_field[paddr[6:2]]};
      end
    end
  end

  assign irq_o = |(int_stat & int_en);
endmodule
