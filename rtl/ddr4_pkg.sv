// -----------------------------------------------------------------------------
// ddr4_pkg.sv
// Shared types, command encodings and timing-parameter structs for the
// AXI4 DDR4 controller.
//
// NOTE: every timing value in timing_default_1600() was derived from memory of
// the DDR4-1600 speed bin and MUST be checked against JESD79-4 and the Micron
// datasheet before the design is trusted. They are register-programmable.
// -----------------------------------------------------------------------------
package ddr4_pkg;

  // ---------------------------------------------------------------------------
  // Memory geometry (8 Gb x8 device, nine devices -> 72-bit data bus)
  // ---------------------------------------------------------------------------
  parameter int ROW_W       = 16;
  parameter int COL_W       = 10;
  parameter int BG_W        = 2;
  parameter int BA_W        = 2;
  parameter int NUM_BG      = 1 << BG_W;
  parameter int BANK_W      = BG_W + BA_W;
  parameter int NUM_BANKS   = 1 << BANK_W;
  parameter int BURST_WORDS = 8;                 // BL8
  parameter int DATA_W      = 64;                // one ECC word
  parameter int CHK_W       = 8;
  parameter int CODE_W      = DATA_W + CHK_W;    // 72
  parameter int BURST_COL_W = COL_W - 3;         // burst-aligned column bits
  parameter int BURST_DATA_W = BURST_WORDS * DATA_W;   // 512: one burst, data only
  parameter int BURST_CODE_W = BURST_WORDS * CODE_W;   // 576: one burst with check bits
  parameter int DFI_PHASES   = 4;                      // 1:4 frequency ratio

  parameter int AXI_ADDR_W  = 3 + COL_W + BANK_W + ROW_W;   // 33

  // ---------------------------------------------------------------------------
  // Timing counters. All values are in controller-clock cycles
  // (one cycle = four memory clocks at the 1:4 DFI ratio).
  // ---------------------------------------------------------------------------
  parameter int TCNT_W = 10;
  typedef logic [TCNT_W-1:0] tcnt_t;

  typedef struct packed {
    // per-bank
    tcnt_t t_rcd;      // ACT  -> RD/WR
    tcnt_t t_rp;       // PRE  -> ACT
    tcnt_t t_ras;      // ACT  -> PRE
    tcnt_t t_rc;       // ACT  -> ACT (same bank)
    tcnt_t t_rtp;      // RD   -> PRE
    tcnt_t t_wr2pre;   // WR   -> PRE   (CWL + 4 + tWR)
    // cross-bank
    tcnt_t t_rrd_s;    // ACT  -> ACT, different bank group
    tcnt_t t_rrd_l;    // ACT  -> ACT, same bank group
    tcnt_t t_faw;      // four-activate window
    tcnt_t t_ccd_s;    // RD/WR -> RD/WR, different bank group
    tcnt_t t_ccd_l;    // RD/WR -> RD/WR, same bank group
    tcnt_t t_wr2rd_s;  // WR   -> RD, different bank group (CWL + 4 + tWTR_S)
    tcnt_t t_wr2rd_l;  // WR   -> RD, same bank group      (CWL + 4 + tWTR_L)
    tcnt_t t_rd2wr;    // RD   -> WR (bus turnaround)
    // whole-device
    tcnt_t t_rfc;      // REF  -> any
    tcnt_t t_mrd;      // MRS  -> MRS
    tcnt_t t_mod;      // MRS  -> any non-MRS
    tcnt_t t_zqinit;   // ZQCL during initialization
    tcnt_t t_zqoper;   // ZQCL after initialization
    tcnt_t t_zqcs;     // ZQCS
    tcnt_t t_xs;       // self-refresh exit -> any
    tcnt_t t_xp;       // power-down exit   -> any
  } timing_t;

  // DDR4-1600, tCK = 1.25 ns, CL = 11, CWL = 9.  cycles = ceil(nCK / 4).
  // VERIFY EVERY VALUE AGAINST THE DATASHEET.
  function automatic timing_t timing_default_1600();
    timing_t t;
    t.t_rcd     = 10'd3;    // 11 nCK
    t.t_rp      = 10'd3;    // 11 nCK
    t.t_ras     = 10'd7;    // 28 nCK
    t.t_rc      = 10'd10;   // 39 nCK
    t.t_rtp     = 10'd2;    //  6 nCK
    t.t_wr2pre  = 10'd7;    //  9 + 4 + 12 = 25 nCK
    t.t_rrd_s   = 10'd1;    //  4 nCK
    t.t_rrd_l   = 10'd2;    //  5 nCK
    t.t_faw     = 10'd5;    // 20 nCK
    t.t_ccd_s   = 10'd1;    //  4 nCK
    t.t_ccd_l   = 10'd2;    //  5 nCK
    t.t_wr2rd_s = 10'd4;    //  9 + 4 + 2 = 15 nCK
    t.t_wr2rd_l = 10'd5;    //  9 + 4 + 6 = 19 nCK
    t.t_rd2wr   = 10'd2;    // 11 - 9 + 4 + 2 = 8 nCK
    t.t_rfc     = 10'd70;   // 280 nCK (350 ns, 8 Gb)
    t.t_mrd     = 10'd2;    //   8 nCK
    t.t_mod     = 10'd6;    //  24 nCK
    t.t_zqinit  = 10'd256;  // 1024 nCK
    t.t_zqoper  = 10'd128;  //  512 nCK
    t.t_zqcs    = 10'd32;   //  128 nCK
    t.t_xs      = 10'd72;   // tRFC + 10 ns = 288 nCK
    t.t_xp      = 10'd2;    //   5 nCK
    return t;
  endfunction

  // Counter helpers.
  // A command issued in cycle T with spacing N allows the guarded command in
  // cycle T+N: the counter is loaded with N-1 and the guard is "counter == 0".
  function automatic tcnt_t tcnt_dec(input tcnt_t c);
    return (c == '0) ? '0 : c - 1'b1;
  endfunction

  // Load that never shortens a wait already in progress.
  function automatic tcnt_t tcnt_load(input tcnt_t cur, input tcnt_t n);
    tcnt_t d, m;
    d = tcnt_dec(cur);
    m = (n == '0) ? '0 : n - 1'b1;
    return (d > m) ? d : m;
  endfunction

  // ---------------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    CMD_DES  = 4'd0,   // deselect (CS_n high)
    CMD_NOP  = 4'd1,
    CMD_MRS  = 4'd2,   // mode register set
    CMD_REF  = 4'd3,   // refresh
    CMD_SRE  = 4'd4,   // self-refresh entry (REF encoding with CKE falling)
    CMD_SRX  = 4'd5,   // self-refresh exit  (DES with CKE rising)
    CMD_PRE  = 4'd6,   // precharge one bank
    CMD_PREA = 4'd7,   // precharge all banks
    CMD_ACT  = 4'd8,   // activate
    CMD_WR   = 4'd9,
    CMD_RD   = 4'd10,
    CMD_ZQCL = 4'd11,
    CMD_ZQCS = 4'd12,
    CMD_PDE  = 4'd13,  // power-down entry (DES with CKE falling)
    CMD_PDX  = 4'd14   // power-down exit  (DES with CKE rising)
  } cmd_e;

  // Decoded command produced by the arbiter / init FSM.
  typedef struct packed {
    cmd_e               cmd;
    logic [BG_W-1:0]    bg;
    logic [BA_W-1:0]    ba;
    logic [ROW_W-1:0]   row;     // ACT: row address.  MRS: opcode in [13:0]
    logic [COL_W-1:0]   col;     // RD/WR: column address
    logic [2:0]         mr_sel;  // MRS: which mode register (0..6)
  } cmd_t;

  // Command/address pins for one DFI phase (CKE, ODT, RESET_n travel separately).
  typedef struct packed {
    logic               cs_n;
    logic               act_n;
    logic               ras_n;   // shared with A16
    logic               cas_n;   // shared with A15
    logic               we_n;    // shared with A14
    logic [BG_W-1:0]    bg;
    logic [BA_W-1:0]    ba;
    logic [13:0]        a;
  } ca_pins_t;

  // DDR4 command truth table (CS_n, ACT_n, RAS_n, CAS_n, WE_n).
  // VERIFY against JESD79-4 Table "Command Truth Table".
  function automatic ca_pins_t encode_cmd(input cmd_t c);
    ca_pins_t p;
    // default: deselect
    p.cs_n  = 1'b1;
    p.act_n = 1'b1;
    p.ras_n = 1'b1;
    p.cas_n = 1'b1;
    p.we_n  = 1'b1;
    p.bg    = c.bg;
    p.ba    = c.ba;
    p.a     = '0;
    case (c.cmd)
      CMD_NOP: begin
        p.cs_n = 1'b0;
      end
      CMD_MRS: begin
        p.cs_n = 1'b0; p.ras_n = 1'b0; p.cas_n = 1'b0; p.we_n = 1'b0;
        p.bg   = {1'b0, c.mr_sel[2]};
        p.ba   = c.mr_sel[1:0];
        p.a    = c.row[13:0];
      end
      CMD_REF, CMD_SRE: begin
        p.cs_n = 1'b0; p.ras_n = 1'b0; p.cas_n = 1'b0;
      end
      CMD_PRE: begin
        p.cs_n = 1'b0; p.ras_n = 1'b0; p.we_n = 1'b0;      // A10 = 0
      end
      CMD_PREA: begin
        p.cs_n = 1'b0; p.ras_n = 1'b0; p.we_n = 1'b0;
        p.a[10] = 1'b1;
      end
      CMD_ACT: begin
        // ACT_n low; RAS/CAS/WE pins carry row address bits 16/15/14.
        p.cs_n  = 1'b0; p.act_n = 1'b0;
        p.ras_n = 1'b1;                 // A16 unused on an 8 Gb x8 part
        p.cas_n = c.row[15];
        p.we_n  = c.row[14];
        p.a     = c.row[13:0];
      end
      CMD_WR: begin
        p.cs_n = 1'b0; p.cas_n = 1'b0; p.we_n = 1'b0;
        p.a[COL_W-1:0] = c.col;         // A10 = 0: no auto-precharge
        p.a[12]        = 1'b1;          // BC_n high: full BL8
      end
      CMD_RD: begin
        p.cs_n = 1'b0; p.cas_n = 1'b0;
        p.a[COL_W-1:0] = c.col;
        p.a[12]        = 1'b1;
      end
      CMD_ZQCL: begin
        p.cs_n = 1'b0; p.we_n = 1'b0;
        p.a[10] = 1'b1;
      end
      CMD_ZQCS: begin
        p.cs_n = 1'b0; p.we_n = 1'b0;
      end
      default: ;                        // DES, SRX, PDE, PDX: deselect pins
    endcase
    return p;
  endfunction

  // ---------------------------------------------------------------------------
  // Request word carried by the request FIFO (aclk -> cclk). 36 bits.
  // One request = one BL8 burst = eight 64-bit words.
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic                     wr;
    logic [ROW_W-1:0]         row;
    logic [BG_W-1:0]          bg;
    logic [BA_W-1:0]          ba;
    logic [BURST_COL_W-1:0]   col_hi;     // column[9:3]
    logic [BURST_WORDS-1:0]   word_mask;  // which of the eight words are used
  } req_t;
  parameter int REQ_W = $bits(req_t);

  // ---------------------------------------------------------------------------
  // Bank state
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    BS_IDLE        = 3'd0,
    BS_ACTIVATING  = 3'd1,
    BS_OPEN        = 3'd2,
    BS_PRECHARGING = 3'd3,
    BS_REFRESHING  = 3'd4
  } bank_state_e;

  // ---------------------------------------------------------------------------
  // Hsiao (72,64) SEC-DED code
  // ---------------------------------------------------------------------------
  // Generated by scripts/gen_hsiao.py -- do not edit by hand.
  // Row weight (data part) = 26 for every check bit.
  // HSIAO_ROWS[i*64 +: 64] : data bits that feed check bit i.
  localparam logic [8*64-1:0] HSIAO_ROWS =
    {64'hf8ed348d221a4420, 64'h7cdaaa4a91152210, 64'h3eb65926488c9108, 64'h1f71c711c4438884, 64'h8f0fc0f03c207842, 64'hc7003ff003e007c1, 64'he300000fffe0003f, 64'hf1000000001fffff};
  // HSIAO_COLS[j*8 +: 8]   : syndrome produced by an error in data bit j.
  localparam logic [64*8-1:0] HSIAO_COLS =
    {8'h8f, 8'hc7, 8'he3, 8'hf1, 8'hf8, 8'h7c, 8'h3e, 8'h1f, 8'he0, 8'hd0, 8'hb0, 8'h70, 8'hc8, 8'ha8, 8'h68, 8'h98, 8'h58, 8'h38, 8'hc4, 8'ha4, 8'h64, 8'h94, 8'h54, 8'h34, 8'h8c, 8'h4c, 8'h2c, 8'h1c, 8'hc2, 8'ha2, 8'h62, 8'h92, 8'h52, 8'h32, 8'h8a, 8'h4a, 8'h2a, 8'h1a, 8'h86, 8'h46, 8'h26, 8'h16, 8'h0e, 8'hc1, 8'ha1, 8'h61, 8'h91, 8'h51, 8'h31, 8'h89, 8'h49, 8'h29, 8'h19, 8'h85, 8'h45, 8'h25, 8'h15, 8'h0d, 8'h83, 8'h43, 8'h23, 8'h13, 8'h0b, 8'h07};

  function automatic logic [CHK_W-1:0] ecc_check_bits(input logic [DATA_W-1:0] d);
    logic [CHK_W-1:0] c;
    for (int i = 0; i < CHK_W; i++) c[i] = ^(d & HSIAO_ROWS[i*DATA_W +: DATA_W]);
    return c;
  endfunction

endpackage : ddr4_pkg
