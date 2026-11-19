// -----------------------------------------------------------------------------
// ddr4_types.sv
// Constants, enums and small transaction classes shared by the environment.
// -----------------------------------------------------------------------------

localparam int AXI_ID_W = 4;
localparam logic [1:0] RESP_OKAY   = 2'b00;
localparam logic [1:0] RESP_SLVERR = 2'b10;
localparam logic [1:0] BURST_FIXED = 2'b00;
localparam logic [1:0] BURST_INCR  = 2'b01;
localparam logic [1:0] BURST_WRAP  = 2'b10;
localparam longint NEVER = -64'sd1_000_000_000;

// Register offsets (also in the RAL model)
localparam logic [11:0] REG_CTRL      = 12'h000;
localparam logic [11:0] REG_STATUS    = 12'h004;
localparam logic [11:0] REG_INT_EN    = 12'h008;
localparam logic [11:0] REG_INT_STAT  = 12'h00C;
localparam logic [11:0] REG_ECC_CE    = 12'h010;
localparam logic [11:0] REG_ECC_UE    = 12'h014;
localparam logic [11:0] REG_LATENCY   = 12'h018;
localparam logic [11:0] REG_REFRESH   = 12'h01C;
localparam logic [11:0] REG_T_RST     = 12'h020;
localparam logic [11:0] REG_T_CKE     = 12'h024;
localparam logic [11:0] REG_T_XPR     = 12'h028;
localparam logic [11:0] REG_T_DLLK    = 12'h02C;
localparam logic [11:0] REG_T_CKESR   = 12'h030;
localparam logic [11:0] REG_MR0       = 12'h040;
localparam logic [11:0] REG_TIMING0   = 12'h080;
localparam int          N_TIMING      = $bits(timing_t) / TCNT_W;   // 22

// Mode-register reset values (apb_csr MR_RESET), index = MR number
localparam logic [13:0] MR_DEFAULT [7] = '{14'h0A10, 14'h0001, 14'h0018, 14'h0000,
                                           14'h0000, 14'h0400, 14'h0000};

// Which timing rule was the last one holding a command back (its slack was 0).
typedef enum int {
  R_NONE, R_RCD, R_RP, R_RAS, R_RC, R_RTP, R_WR2PRE, R_RRD_S, R_RRD_L, R_FAW,
  R_CCD_S, R_CCD_L, R_WTR_S, R_WTR_L, R_RD2WR, R_RFC, R_MRD, R_MOD, R_XS, R_ZQ,
  R_XPR, R_CKESR, R_OTHER
} rule_e;

// Read a timing field by index k (0 = t_rcd ... 21 = t_xp), as the registers do.
function automatic tcnt_t timing_get(timing_t t, int k);
  return t[(N_TIMING-1-k)*TCNT_W +: TCNT_W];
endfunction

function automatic void timing_set(ref timing_t t, input int k, input tcnt_t v);
  t[(N_TIMING-1-k)*TCNT_W +: TCNT_W] = v;
endfunction

function automatic string timing_name(int k);
  string n [N_TIMING] = '{"t_rcd", "t_rp", "t_ras", "t_rc", "t_rtp", "t_wr2pre",
                          "t_rrd_s", "t_rrd_l", "t_faw", "t_ccd_s", "t_ccd_l",
                          "t_wr2rd_s", "t_wr2rd_l", "t_rd2wr", "t_rfc", "t_mrd",
                          "t_mod", "t_zqinit", "t_zqoper", "t_zqcs", "t_xs", "t_xp"};
  return n[k];
endfunction

function automatic logic [31:0] sat_add32(logic [31:0] a, int unsigned b);
  longint unsigned s = longint'(a) + b;
  return (s > 64'hFFFF_FFFF) ? 32'hFFFF_FFFF : s[31:0];
endfunction

// ---------------------------------------------------------------------------
// One DDR4 command (or CKE / RESET_n / status change) seen on the DFI bus.
// ---------------------------------------------------------------------------
class dfi_cmd_item extends uvm_sequence_item;
  `uvm_object_utils(dfi_cmd_item)
  longint          cyc;          // cclk cycles since reset release
  cmd_e            cmd;
  logic [BG_W-1:0] bg;
  logic [BA_W-1:0] ba;
  logic [ROW_W-1:0] row;         // ACT
  logic [COL_W-1:0] col;         // RD / WR
  logic [13:0]     opcode;       // MRS
  logic [2:0]      mr_sel;       // MRS
  bit              cke, prev_cke;
  bit              reset_n, prev_reset_n;
  bit              init_done, prev_init_done;
  bit              sr_req;
  bit              ref_ovf;
  bit              first;        // first sample after reset release

  function new(string name = "dfi_cmd_item");
    super.new(name);
  endfunction

  function int bank();
    return int'({bg, ba});
  endfunction

  function string convert2string();
    case (cmd)
      CMD_ACT:          return $sformatf("@%0d ACT  bank %0d row 0x%04h", cyc, bank(), row);
      CMD_RD, CMD_WR:   return $sformatf("@%0d %s   bank %0d col 0x%03h", cyc, cmd.name(), bank(), col);
      CMD_MRS:          return $sformatf("@%0d MRS  MR%0d 0x%04h", cyc, mr_sel, opcode);
      CMD_PRE:          return $sformatf("@%0d PRE  bank %0d", cyc, bank());
      default:          return $sformatf("@%0d %s cke=%0b reset_n=%0b", cyc, cmd.name(), cke, reset_n);
    endcase
  endfunction
endclass

// ---------------------------------------------------------------------------
// A command the protocol checker accepted, with the rule that limited it.
// ---------------------------------------------------------------------------
class ddr4_check_item extends uvm_sequence_item;
  `uvm_object_utils(ddr4_check_item)
  cmd_e   cmd;
  rule_e  rule;
  cmd_e   prev_same_bank;    // previous command to the same bank (ACT/RD/WR/PRE)
  bit     same_bg_as_last_cas;
  int     owed;              // refreshes owed when a REF was issued
  longint sr_cycles;         // time in self-refresh, on SRX
  longint gap_since_srx;     // on SRE: cycles since the previous SRX (-1 if none)
  bit     sre_after_prea;    // on SRE: banks were open and had to be closed first

  function new(string name = "ddr4_check_item");
    super.new(name);
  endfunction
endclass

// ---------------------------------------------------------------------------
// One read burst returned by the DFI responder, with any injected errors.
// ---------------------------------------------------------------------------
class ddr4_rd_evt extends uvm_sequence_item;
  `uvm_object_utils(ddr4_rd_evt)
  longint                 cyc;
  bit [BURST_WORDS-1:0]   single;     // word had one bit flipped
  bit [BURST_WORDS-1:0]   double;     // word had two bits flipped
  int                     bit_a [BURST_WORDS];
  int                     bit_b [BURST_WORDS];

  function new(string name = "ddr4_rd_evt");
    super.new(name);
  endfunction
endclass

// ---------------------------------------------------------------------------
// One request pushed into the request FIFO (white-box probe).
// ---------------------------------------------------------------------------
class ddr4_req_item extends uvm_sequence_item;
  `uvm_object_utils(ddr4_req_item)
  req_t                    req;
  logic [BURST_DATA_W-1:0] wd;

  function new(string name = "ddr4_req_item");
    super.new(name);
  endfunction

  function logic [26:0] chunk();
    return {req.row, req.bg, req.ba, req.col_hi};
  endfunction
endclass

// ---------------------------------------------------------------------------
// One returned read word as the scoreboard judged it (feeds ECC coverage).
// ---------------------------------------------------------------------------
class ddr4_ecc_obs extends uvm_sequence_item;
  `uvm_object_utils(ddr4_ecc_obs)
  int  word;
  int  kind;        // 0 none, 1 single, 2 double
  int  bit_a, bit_b;
  bit  in_mask;

  function new(string name = "ddr4_ecc_obs");
    super.new(name);
  endfunction
endclass

// Directed error injection: applied to the next read burst the responder returns.
typedef struct {
  int word;      // 0..7
  int bit_a;     // 0..71
  int bit_b;     // -1 for a single-bit error
} inj_t;
