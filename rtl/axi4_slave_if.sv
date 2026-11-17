// -----------------------------------------------------------------------------
// axi4_slave_if.sv
// AXI4 slave front end, 64-bit data. Converts AXI bursts into controller
// requests, each covering one memory burst of eight 64-bit words.
//
// Supported: INCR bursts with full-width beats (AxSIZE = 3). The low three
// address bits are ignored (word-aligned access).
// Anything else is answered with SLVERR; such writes store nothing.
//
// Write strobes: a beat is stored only when WSTRB is 0xFF. A beat with 0x00 is
// skipped. Any other value sets SLVERR for the burst and that word is not
// stored, because a partial word would break its ECC check bits.
//
// BRESP is sent once the last request and its data are in the FIFOs.
// Read data returns in request order, so AXI IDs are kept on this side only.
// -----------------------------------------------------------------------------
module axi4_slave_if
  import ddr4_pkg::*;
#(
  parameter int ID_W        = 4,
  parameter int PEND_ADDR_W = 4      // read chunks that may be outstanding: 2**N
) (
  input  logic                    aclk,
  input  logic                    aresetn,

  // write address
  input  logic [ID_W-1:0]         awid,
  input  logic [AXI_ADDR_W-1:0]   awaddr,
  input  logic [7:0]              awlen,
  input  logic [2:0]              awsize,
  input  logic [1:0]              awburst,
  input  logic                    awvalid,
  output logic                    awready,
  // write data
  input  logic [DATA_W-1:0]       wdata,
  input  logic [DATA_W/8-1:0]     wstrb,
  input  logic                    wlast,
  input  logic                    wvalid,
  output logic                    wready,
  // write response
  output logic [ID_W-1:0]         bid,
  output logic [1:0]              bresp,
  output logic                    bvalid,
  input  logic                    bready,
  // read address
  input  logic [ID_W-1:0]         arid,
  input  logic [AXI_ADDR_W-1:0]   araddr,
  input  logic [7:0]              arlen,
  input  logic [2:0]              arsize,
  input  logic [1:0]              arburst,
  input  logic                    arvalid,
  output logic                    arready,
  // read data
  output logic [ID_W-1:0]         rid,
  output logic [DATA_W-1:0]       rdata,
  output logic [1:0]              rresp,
  output logic                    rlast,
  output logic                    rvalid,
  input  logic                    rready,

  // request FIFO, write side
  output logic                    req_push_o,
  output req_t                    req_o,
  input  logic                    req_full_i,
  // write-data FIFO, write side
  output logic                    wd_push_o,
  output logic [BURST_DATA_W-1:0] wd_o,
  input  logic                    wd_full_i,
  // read-data FIFO, read side: {ue[7:0], data[511:0]}
  input  logic                    rd_empty_i,
  input  logic [BURST_WORDS+BURST_DATA_W-1:0] rd_i,
  output logic                    rd_pop_o
);
  localparam int WADDR_W = AXI_ADDR_W - 3;     // address in 64-bit words
  localparam int CADDR_W = WADDR_W - 3;        // address in 8-word chunks
  localparam logic [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;

  // ============================== write channel =============================
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_FLUSH, W_RESP} w_state_e;

  w_state_e                 w_state;
  logic [ID_W-1:0]          w_id;
  logic [WADDR_W-1:0]       w_waddr;      // word address of the next beat
  logic [CADDR_W-1:0]       w_chunk;      // chunk address of the buffered words
  logic                     w_bad;        // unsupported burst: store nothing
  logic                     w_err;
  logic                     w_last_seen;
  logic [BURST_DATA_W-1:0]  w_buf;
  logic [BURST_WORDS-1:0]   w_mask;

  logic wr_req_valid, grant_wr;
  logic w_beat;

  assign awready      = (w_state == W_IDLE);
  assign wready       = (w_state == W_DATA);
  assign bvalid       = (w_state == W_RESP);
  assign bid          = w_id;
  assign bresp        = w_err ? RESP_SLVERR : RESP_OKAY;
  assign w_beat       = wvalid && wready;
  assign wr_req_valid = (w_state == W_FLUSH) && (w_mask != '0);

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      w_state     <= W_IDLE;
      w_id        <= '0;
      w_waddr     <= '0;
      w_chunk     <= '0;
      w_bad       <= 1'b0;
      w_err       <= 1'b0;
      w_last_seen <= 1'b0;
      w_mask      <= '0;
    end else begin
      case (w_state)
        W_IDLE: if (awvalid) begin
          w_id    <= awid;
          w_waddr <= awaddr[AXI_ADDR_W-1:3];
          w_bad   <= (awburst != 2'b01) || (awsize != 3'd3);
          w_err   <= (awburst != 2'b01) || (awsize != 3'd3);
          w_mask  <= '0;
          w_state <= W_DATA;
        end

        W_DATA: if (w_beat) begin
          w_chunk     <= w_waddr[WADDR_W-1:3];
          w_waddr     <= w_waddr + 1'b1;
          w_last_seen <= wlast;
          if (!w_bad && (wstrb == '1)) w_mask[w_waddr[2:0]] <= 1'b1;
          if ((wstrb != '1) && (wstrb != '0)) w_err <= 1'b1;
          if ((w_waddr[2:0] == 3'd7) || wlast) w_state <= W_FLUSH;
        end

        W_FLUSH: begin
          // nothing to store, or the request has just been accepted
          if ((w_mask == '0) || grant_wr) begin
            w_mask  <= '0;
            w_state <= w_last_seen ? W_RESP : W_DATA;
          end
        end

        W_RESP: if (bready) w_state <= W_IDLE;

        default: w_state <= W_IDLE;
      endcase
    end
  end

  always_ff @(posedge aclk) begin
    if (w_beat) w_buf[w_waddr[2:0]*DATA_W +: DATA_W] <= wdata;
  end

  // =============================== read channel =============================
  typedef enum logic {R_IDLE, R_REQ} r_state_e;

  r_state_e                 r_state;
  logic [ID_W-1:0]          r_id;
  logic [WADDR_W-1:0]       r_waddr;      // word address of the next chunk start
  logic [8:0]               r_left;       // beats not yet requested
  logic                     r_err;

  logic [3:0]               r_n;          // words covered by the next chunk
  logic [BURST_WORDS-1:0]   r_mask;
  logic                     r_final;
  logic                     rd_req_valid, grant_rd;

  assign arready      = (r_state == R_IDLE);
  assign rd_req_valid = (r_state == R_REQ);

  always_comb begin
    logic [3:0] room;
    room    = 4'd8 - {1'b0, r_waddr[2:0]};
    r_n     = (r_left < {5'd0, room}) ? r_left[3:0] : room;
    r_final = (r_left == {5'd0, r_n});
    r_mask  = '0;
    for (int w = 0; w < BURST_WORDS; w++)
      r_mask[w] = (w >= int'(r_waddr[2:0])) && (w < int'(r_waddr[2:0]) + int'(r_n));
  end

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      r_state <= R_IDLE;
      r_id    <= '0;
      r_waddr <= '0;
      r_left  <= '0;
      r_err   <= 1'b0;
    end else begin
      case (r_state)
        R_IDLE: if (arvalid) begin
          r_id    <= arid;
          r_waddr <= araddr[AXI_ADDR_W-1:3];
          r_left  <= {1'b0, arlen} + 9'd1;
          r_err   <= (arburst != 2'b01) || (arsize != 3'd3);
          r_state <= R_REQ;
        end
        R_REQ: if (grant_rd) begin
          r_waddr <= r_waddr + {{(WADDR_W-4){1'b0}}, r_n};
          r_left  <= r_left - {5'd0, r_n};
          if (r_final) r_state <= R_IDLE;
        end
        default: r_state <= R_IDLE;
      endcase
    end
  end

  // =========================== request arbitration ==========================
  // Reads and writes share one request FIFO; alternate when both are waiting.
  logic prio_rd;
  logic pend_full, pend_empty;
  logic wr_can, rd_can;

  assign wr_can   = !req_full_i && !wd_full_i;
  assign rd_can   = !req_full_i && !pend_full;
  assign grant_wr = wr_req_valid && wr_can && !(rd_req_valid && rd_can && prio_rd);
  assign grant_rd = rd_req_valid && rd_can && !grant_wr;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn)      prio_rd <= 1'b0;
    else if (grant_wr) prio_rd <= 1'b1;
    else if (grant_rd) prio_rd <= 1'b0;
  end

  logic [CADDR_W-1:0] sel_chunk;
  assign sel_chunk = grant_wr ? w_chunk : r_waddr[WADDR_W-1:3];

  logic [ROW_W-1:0]       m_row;
  logic [BG_W-1:0]        m_bg;
  logic [BA_W-1:0]        m_ba;
  logic [BURST_COL_W-1:0] m_col_hi;

  addr_map u_map (
    .addr_i   ({sel_chunk, 6'b000000}),
    .row_o    (m_row),
    .bg_o     (m_bg),
    .ba_o     (m_ba),
    .col_hi_o (m_col_hi),
    .word_o   ()
  );

  always_comb begin
    req_o.wr        = grant_wr;
    req_o.row       = m_row;
    req_o.bg        = m_bg;
    req_o.ba        = m_ba;
    req_o.col_hi    = m_col_hi;
    req_o.word_mask = grant_wr ? w_mask : r_mask;
  end

  assign req_push_o = grant_wr || grant_rd;
  assign wd_push_o  = grant_wr;
  assign wd_o       = w_buf;

  // ============================ read data return ============================
  // One entry per read chunk: which words to return, and under which ID.
  localparam int PEND_W = 2 + ID_W + BURST_WORDS;

  logic [PEND_W-1:0]       pend_in, pend_out;
  logic                    p_err, p_last;
  logic [ID_W-1:0]         p_id;
  logic [BURST_WORDS-1:0]  p_mask;
  logic                    chunk_done;

  assign pend_in = {r_err, r_final, r_id, r_mask};
  assign {p_err, p_last, p_id, p_mask} = pend_out;

  sync_fifo #(.DATA_W(PEND_W), .ADDR_W(PEND_ADDR_W)) u_pend (
    .clk     (aclk),
    .rst_n   (aresetn),
    .push_i  (grant_rd),
    .data_i  (pend_in),
    .pop_i   (chunk_done),
    .data_o  (pend_out),
    .empty_o (pend_empty),
    .full_o  (pend_full),
    .count_o ()
  );

  logic [2:0] first_w, last_w;
  always_comb begin
    first_w = 3'd0;
    last_w  = 3'd0;
    for (int w = BURST_WORDS-1; w >= 0; w--) if (p_mask[w]) first_w = 3'(w);
    for (int w = 0; w < BURST_WORDS; w++)    if (p_mask[w]) last_w  = 3'(w);
  end

  logic       ret_active;
  logic [2:0] ret_idx;

  assign rvalid     = ret_active;
  assign rid        = p_id;
  assign rdata      = rd_i[ret_idx*DATA_W +: DATA_W];
  assign rresp      = (p_err || rd_i[BURST_DATA_W + int'(ret_idx)]) ? RESP_SLVERR : RESP_OKAY;
  assign rlast      = p_last && (ret_idx == last_w);
  assign chunk_done = ret_active && rready && (ret_idx == last_w);
  assign rd_pop_o   = chunk_done;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      ret_active <= 1'b0;
      ret_idx    <= '0;
    end else if (!ret_active) begin
      if (!rd_empty_i && !pend_empty) begin
        ret_active <= 1'b1;
        ret_idx    <= first_w;
      end
    end else if (rready) begin
      if (ret_idx == last_w) ret_active <= 1'b0;
      else                   ret_idx    <= ret_idx + 1'b1;
    end
  end
endmodule
