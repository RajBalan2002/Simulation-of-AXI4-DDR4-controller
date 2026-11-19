// -----------------------------------------------------------------------------
// init_fsm.sv
// DDR4 power-up and initialization sequence.
//
//   1. RESET_n low, CKE low                      for t_rst_i  cycles
//   2. RESET_n high, CKE low                     for t_cke_i  cycles
//   3. CKE high, deselect                        for t_xpr_i  cycles
//   4. MRS x7 in the order MR3, MR6, MR5, MR4, MR2, MR1, MR0 (tMRD apart)
//   5. wait tMOD, then ZQCL, then wait tZQinit
//   6. wait t_dllk_i cycles for DLL lock, then init_done_o
//
// tMRD, tMOD and tZQinit are enforced by global_timers through mrs_ok_i and
// bus_ok_i; this module only sequences the requests.
// The sequence and mode-register order follow the datasheet's power-up procedure.
// -----------------------------------------------------------------------------
module init_fsm
  import ddr4_pkg::*;
#(
  parameter int INIT_CNT_W = 20
) (
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic                    phy_ready_i,   // PHY has finished its own start-up
  input  logic [INIT_CNT_W-1:0]   t_rst_i,
  input  logic [INIT_CNT_W-1:0]   t_cke_i,
  input  logic [INIT_CNT_W-1:0]   t_xpr_i,
  input  logic [INIT_CNT_W-1:0]   t_dllk_i,
  input  var logic [6:0][13:0]    mr_i,          // mr_i[n] = opcode for MRn

  input  logic                    mrs_ok_i,      // from global_timers
  input  logic                    bus_ok_i,      // from global_timers

  output logic                    cmd_valid_o,   // cmd_o is issued this cycle
  output cmd_t                    cmd_o,
  output logic                    mem_reset_n_o,
  output logic                    cke_o,
  output logic                    init_done_o
);
  typedef enum logic [3:0] {
    I_WAIT_PHY, I_RESET, I_CKE_LOW, I_XPR, I_MRS, I_ZQ, I_ZQ_WAIT, I_DLLK, I_DONE
  } init_state_e;

  // MRS order: element k is the mode register written k-th.
  localparam logic [7*3-1:0] MR_ORDER = {3'd0, 3'd1, 3'd2, 3'd4, 3'd5, 3'd6, 3'd3};

  init_state_e            state;
  logic [INIT_CNT_W-1:0]  cnt;
  logic [2:0]             mr_idx;
  logic [2:0]             mr_sel;
  logic                   issue_mrs, issue_zq;

  assign mr_sel    = MR_ORDER[mr_idx*3 +: 3];
  assign issue_mrs = (state == I_MRS) && mrs_ok_i;
  assign issue_zq  = (state == I_ZQ)  && bus_ok_i;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state  <= I_WAIT_PHY;
      cnt    <= '0;
      mr_idx <= '0;
    end else begin
      case (state)
        I_WAIT_PHY: if (phy_ready_i) begin
          state <= I_RESET;   cnt <= t_rst_i;
        end
        I_RESET: begin
          if (cnt == '0) begin state <= I_CKE_LOW; cnt <= t_cke_i; end
          else cnt <= cnt - 1'b1;
        end
        I_CKE_LOW: begin
          if (cnt == '0) begin state <= I_XPR; cnt <= t_xpr_i; end
          else cnt <= cnt - 1'b1;
        end
        I_XPR: begin
          if (cnt == '0) begin state <= I_MRS; mr_idx <= '0; end
          else cnt <= cnt - 1'b1;
        end
        I_MRS: if (issue_mrs) begin
          if (mr_idx == 3'd6) state <= I_ZQ;
          else                mr_idx <= mr_idx + 1'b1;
        end
        I_ZQ:      if (issue_zq) state <= I_ZQ_WAIT;
        I_ZQ_WAIT: if (bus_ok_i) begin
          state <= I_DLLK;    cnt <= t_dllk_i;
        end
        I_DLLK: begin
          if (cnt == '0) state <= I_DONE;
          else cnt <= cnt - 1'b1;
        end
        I_DONE: ;
        default: state <= I_WAIT_PHY;
      endcase
    end
  end

  always_comb begin
    cmd_o       = '0;
    cmd_o.cmd   = CMD_DES;
    cmd_valid_o = 1'b0;
    if (issue_mrs) begin
      cmd_valid_o       = 1'b1;
      cmd_o.cmd         = CMD_MRS;
      cmd_o.mr_sel      = mr_sel;
      cmd_o.row[13:0]   = mr_i[mr_sel];
    end else if (issue_zq) begin
      cmd_valid_o = 1'b1;
      cmd_o.cmd   = CMD_ZQCL;
    end
  end

  assign mem_reset_n_o = (state != I_WAIT_PHY) && (state != I_RESET);
  assign cke_o         = (state != I_WAIT_PHY) && (state != I_RESET) &&
                         (state != I_CKE_LOW);
  assign init_done_o   = (state == I_DONE);
endmodule
