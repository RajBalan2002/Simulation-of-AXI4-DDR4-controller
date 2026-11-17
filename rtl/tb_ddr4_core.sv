// -----------------------------------------------------------------------------
// tb_ddr4_core.sv
// End-to-end test of the controller-clock-domain core (ctrl_core + ECC + DFI).
//
//   - A behavioral PHY and memory sit on the DFI pins. They decode commands
//     from the pin levels, check that write data and read enables arrive in
//     exactly the agreed cycle, store the encoded bursts, and return read data
//     with single- and double-bit errors injected.
//   - A scoreboard keeps its own word-level copy of what was written and checks
//     every returned word and its error flag.
//   - The read FIFO is modelled with a random drain rate, to exercise the
//     in-flight read accounting.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_ddr4_core #(
  parameter int NREQ       = 20000,
  parameter int REFI       = 300,
  parameter int WR_LAT     = 2,     // cycles, command -> write data on DFI
  parameter int RDEN_LAT   = 3,     // cycles, command -> read enable on DFI
  parameter int RD_PHY_LAT = 2,     // cycles, read enable -> read data valid
  parameter int INJ1_PCT   = 8,     // % of returned words with a 1-bit error
  parameter int INJ2_PCT   = 2      // % of returned words with a 2-bit error
);
  import ddr4_pkg::*;

  localparam int INIT_CNT_W = 20;
  localparam int RD_DEPTH   = 16;
  localparam int FREE_W     = 8;
  localparam int KEY_W      = BANK_W + ROW_W + BURST_COL_W;   // one burst

  // ------------------------------- DUT hookup -------------------------------
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  timing_t           t;
  logic [6:0][13:0]  mr;
  logic              sr_req = 0, dfi_init_complete = 0;
  logic              req_valid = 0, req_pop;
  req_t              req;
  logic              wdata_valid = 0, wdata_pop;
  logic [BURST_DATA_W-1:0] wdata = '0;
  logic              rdata_push;
  logic [BURST_WORDS+BURST_DATA_W-1:0] rdata;
  logic [FREE_W-1:0] rdata_free = FREE_W'(RD_DEPTH);

  logic [DFI_PHASES-1:0]            dfi_reset_n, dfi_cke, dfi_odt, dfi_cs_n, dfi_act_n;
  logic [DFI_PHASES-1:0]            dfi_ras_n, dfi_cas_n, dfi_we_n;
  logic [DFI_PHASES-1:0][BG_W-1:0]  dfi_bg;
  logic [DFI_PHASES-1:0][BA_W-1:0]  dfi_ba;
  logic [DFI_PHASES-1:0][13:0]      dfi_address;
  logic [DFI_PHASES-1:0]            dfi_wrdata_en, dfi_rddata_en;
  logic [BURST_CODE_W-1:0]          dfi_wrdata;
  logic [BURST_WORDS*9-1:0]         dfi_wrdata_mask;
  logic [BURST_CODE_W-1:0]          dfi_rddata = '0;
  logic [DFI_PHASES-1:0]            dfi_rddata_valid = '0;

  logic              init_done, in_sr, ref_overflow, ecc_evt;
  logic [3:0]        ref_pending, ecc_ce_cnt, ecc_ue_cnt;

  ddr4_core #(.INIT_CNT_W(INIT_CNT_W), .FREE_W(FREE_W)) dut (
    .clk(clk), .rst_n(rst_n), .t_i(t),
    .t_rst_i(INIT_CNT_W'(20)), .t_cke_i(INIT_CNT_W'(30)),
    .t_xpr_i(INIT_CNT_W'(10)), .t_dllk_i(INIT_CNT_W'(15)),
    .mr_i(mr), .t_refi_i(16'(REFI)), .ref_thresh_i(4'd6), .t_ckesr_i(tcnt_t'(3)),
    .wr_lat_i(3'(WR_LAT)), .rden_lat_i(3'(RDEN_LAT)), .sr_req_i(sr_req),
    .req_valid_i(req_valid), .req_i(req), .req_pop_o(req_pop),
    .wdata_valid_i(wdata_valid), .wdata_i(wdata), .wdata_pop_o(wdata_pop),
    .rdata_push_o(rdata_push), .rdata_o(rdata), .rdata_free_i(rdata_free),
    .dfi_init_complete(dfi_init_complete),
    .dfi_reset_n(dfi_reset_n), .dfi_cke(dfi_cke), .dfi_odt(dfi_odt),
    .dfi_cs_n(dfi_cs_n), .dfi_act_n(dfi_act_n), .dfi_ras_n(dfi_ras_n),
    .dfi_cas_n(dfi_cas_n), .dfi_we_n(dfi_we_n), .dfi_bg(dfi_bg), .dfi_ba(dfi_ba),
    .dfi_address(dfi_address), .dfi_wrdata_en(dfi_wrdata_en), .dfi_wrdata(dfi_wrdata),
    .dfi_wrdata_mask(dfi_wrdata_mask), .dfi_rddata_en(dfi_rddata_en),
    .dfi_rddata(dfi_rddata), .dfi_rddata_valid(dfi_rddata_valid),
    .init_done_o(init_done), .in_self_refresh_o(in_sr),
    .ref_overflow_o(ref_overflow), .ref_pending_o(ref_pending),
    .ecc_evt_o(ecc_evt), .ecc_ce_cnt_o(ecc_ce_cnt), .ecc_ue_cnt_o(ecc_ue_cnt));

  // ------------------------------ bookkeeping -------------------------------
  int cyc = 0, errors = 0, popped = 0;
  int n_wr = 0, n_rd = 0, n_rdpush = 0, n_words_checked = 0, n_words_compared = 0;
  int exp_ce_total = 0, exp_ue_total = 0, dut_ce_total = 0, dut_ue_total = 0;
  int n_full_cycles = 0;

  // behavioral PHY + memory
  bit                       p_open [NUM_BANKS];
  logic [ROW_W-1:0]         p_row  [NUM_BANKS];
  logic [BURST_CODE_W-1:0]  mem [bit [KEY_W-1:0]];
  int                       wr_due_q [$];
  bit [KEY_W-1:0]           wr_key_q [$];
  int                       rd_due_q [$];
  bit [KEY_W-1:0]           rd_key_q [$];
  int                       ret_due_q [$];
  logic [BURST_CODE_W-1:0]  ret_code_q [$];
  bit [15:0]                inj_q [$];          // 2 bits per word: 0 none, 1 single, 2 double

  // scoreboard
  logic [DATA_W-1:0]        refm [bit [KEY_W+2:0]];
  bit [BURST_WORDS-1:0]     exp_mask_q [$];
  bit [BURST_WORDS-1:0]     exp_has_q [$];
  logic [BURST_DATA_W-1:0]  exp_data_q [$];
  logic [BURST_DATA_W-1:0]  wq [$];             // write data waiting, in request order

  // stimulus
  int                       busy_pct = 100, drain_pct = 100, used = 0;
  int                       sr_cnt = 0, sr_next = 1;
  logic [BANK_W-1:0]        last_bank = '0;
  logic [ROW_W-1:0]         row_set [4];

  // scratch (module scope for tool portability)
  int                       pb, k_push, k_pop, bit_a, bit_b, roll;
  bit [KEY_W-1:0]           key;
  logic [ROW_W-1:0]         prow;
  logic [BURST_CODE_W-1:0]  code;
  logic [BURST_DATA_W-1:0]  wdat, edat;
  bit [15:0]                inj;
  bit [BURST_WORDS-1:0]     emask, ehas;
  logic [BURST_WORDS-1:0]   ue;
  req_t                     rnew;

  task automatic fail(input string msg);
    errors++;
    if (errors <= 30) $display("ERROR @%0d: %s", cyc, msg);
  endtask

  function automatic logic [BURST_DATA_W-1:0] rand_burst();
    logic [BURST_DATA_W-1:0] d;
    for (int i = 0; i < BURST_DATA_W / 32; i++) d[i*32 +: 32] = $urandom;
    return d;
  endfunction

  function automatic req_t random_req();
    req_t r;
    logic [BANK_W-1:0] b;
    b = ($urandom_range(0, 99) < 60) ? last_bank : BANK_W'($urandom_range(0, NUM_BANKS-1));
    r.wr        = 1'($urandom_range(0, 1));
    r.row       = row_set[$urandom_range(0, 3)];
    r.bg        = b[BANK_W-1:BA_W];
    r.ba        = b[BA_W-1:0];
    r.col_hi    = BURST_COL_W'($urandom_range(0, 3));   // small space: reads hit written data
    r.word_mask = BURST_WORDS'($urandom_range(1, 255));
    return r;
  endfunction

  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (rst_n) begin
      // =================== behavioral PHY: command decode ===================
      if (dfi_cs_n[DFI_PHASES-1:1] != '1) fail("command on a phase other than 0");
      if (!dfi_cs_n[0]) begin
        pb = int'({dfi_bg[0], dfi_ba[0]});
        if (!dfi_act_n[0]) begin
          p_open[pb] = 1;
          p_row[pb]  = {dfi_cas_n[0], dfi_we_n[0], dfi_address[0]};
        end else begin
          case ({dfi_ras_n[0], dfi_cas_n[0], dfi_we_n[0]})
            3'b010: begin                                  // precharge
              if (dfi_address[0][10]) begin
                for (int i = 0; i < NUM_BANKS; i++) p_open[i] = 0;
              end else p_open[pb] = 0;
            end
            3'b100, 3'b101: begin                          // write, read
              if (!p_open[pb]) fail("PHY: RD/WR to a closed bank");
              if (dfi_address[0][2:0] != 3'b000) fail("PHY: burst not column-aligned");
              if (dfi_address[0][10]) fail("PHY: auto-precharge bit set");
              prow = p_row[pb];
              key  = {dfi_bg[0], dfi_ba[0], prow, dfi_address[0][9:3]};
              if (dfi_we_n[0]) begin
                rd_due_q.push_back(cyc + RDEN_LAT); rd_key_q.push_back(key);
              end else begin
                wr_due_q.push_back(cyc + WR_LAT);   wr_key_q.push_back(key);
              end
            end
            default: ;                                     // MRS, REF, ZQ, NOP
          endcase
        end
      end

      // ====================== behavioral PHY: write data ====================
      if (dfi_wrdata_en != '0) begin
        if (dfi_wrdata_en != '1) fail("PHY: partial dfi_wrdata_en");
        if (wr_due_q.size() == 0 || wr_due_q[0] != cyc) fail("PHY: write data in the wrong cycle");
        else begin
          key  = wr_key_q[0];
          if (!mem.exists(key)) mem[key] = '0;
          code = mem[key];
          for (int w = 0; w < BURST_WORDS; w++) begin
            if (dfi_wrdata_mask[w*9 +: 9] == '0)
              code[w*CODE_W +: CODE_W] = dfi_wrdata[w*CODE_W +: CODE_W];
            else if (dfi_wrdata_mask[w*9 +: 9] != '1)
              fail("PHY: partial byte mask within a word");
          end
          mem[key] = code;
          void'(wr_due_q.pop_front()); void'(wr_key_q.pop_front());
        end
      end else if (wr_due_q.size() != 0 && wr_due_q[0] <= cyc) begin
        fail("PHY: write data did not arrive");
        void'(wr_due_q.pop_front()); void'(wr_key_q.pop_front());
      end

      // ===================== behavioral PHY: read enable ====================
      if (dfi_rddata_en != '0) begin
        if (dfi_rddata_en != '1) fail("PHY: partial dfi_rddata_en");
        if (rd_due_q.size() == 0 || rd_due_q[0] != cyc) fail("PHY: read enable in the wrong cycle");
        else begin
          key  = rd_key_q[0];
          // A never-written burst reads as all-zero, which is a valid code word.
          // The entry is created before it is read, so no simulator ever reads a
          // missing associative-array element (the value of that is tool-dependent).
          if (!mem.exists(key)) mem[key] = '0;
          code = mem[key];
          inj  = '0;
          for (int w = 0; w < BURST_WORDS; w++) begin
            roll = $urandom_range(0, 99);
            if (roll < INJ1_PCT) begin
              bit_a = $urandom_range(0, CODE_W-1);
              code[w*CODE_W + bit_a] = ~code[w*CODE_W + bit_a];
              inj[w*2 +: 2] = 2'd1;
            end else if (roll < INJ1_PCT + INJ2_PCT) begin
              bit_a = $urandom_range(0, CODE_W-1);
              bit_b = (bit_a + $urandom_range(1, CODE_W-1)) % CODE_W;
              code[w*CODE_W + bit_a] = ~code[w*CODE_W + bit_a];
              code[w*CODE_W + bit_b] = ~code[w*CODE_W + bit_b];
              inj[w*2 +: 2] = 2'd2;
            end
          end
          ret_due_q.push_back(cyc + RD_PHY_LAT); ret_code_q.push_back(code);
          inj_q.push_back(inj);
          void'(rd_due_q.pop_front()); void'(rd_key_q.pop_front());
        end
      end else if (rd_due_q.size() != 0 && rd_due_q[0] <= cyc) begin
        fail("PHY: read enable did not arrive");
        void'(rd_due_q.pop_front()); void'(rd_key_q.pop_front());
      end

      // ===================== behavioral PHY: read data out ==================
      if (ret_due_q.size() != 0 && ret_due_q[0] == cyc + 1) begin
        dfi_rddata_valid <= '1;
        dfi_rddata       <= ret_code_q[0];
        void'(ret_due_q.pop_front()); void'(ret_code_q.pop_front());
      end else begin
        dfi_rddata_valid <= '0;
      end

      // ========================= scoreboard: requests =======================
      if (ref_overflow) fail("refresh overflow flag set");
      if (wdata_pop !== (req_pop && req.wr)) fail("wdata_pop does not match a write being issued");
      k_pop = 0;
      if (req_pop) begin
        if (!req_valid) fail("request popped while not valid");
        key = {req.bg, req.ba, req.row, req.col_hi};
        if (req.wr) begin
          if (wq.size() == 0 || !wdata_valid) fail("write issued with no data presented");
          else begin
            wdat = wq.pop_front();
            if (wdat !== wdata) fail("testbench write data out of step");
            for (int w = 0; w < BURST_WORDS; w++)
              if (req.word_mask[w]) refm[{key, 3'(w)}] = wdat[w*DATA_W +: DATA_W];
          end
          n_wr++;
        end else begin
          ehas = '0; edat = '0;
          for (int w = 0; w < BURST_WORDS; w++) begin
            if (refm.exists({key, 3'(w)})) begin
              ehas[w] = 1; edat[w*DATA_W +: DATA_W] = refm[{key, 3'(w)}];
            end
          end
          exp_mask_q.push_back(req.word_mask); exp_has_q.push_back(ehas);
          exp_data_q.push_back(edat);
          n_rd++;
        end
        popped <= popped + 1;
        k_pop = 1;
      end

      // ========================= scoreboard: read data ======================
      k_push = 0;
      if (ecc_evt) begin
        dut_ce_total += int'(ecc_ce_cnt);
        dut_ue_total += int'(ecc_ue_cnt);
      end
      if (rdata_push) begin
        k_push = 1;
        if (used >= RD_DEPTH) fail("read FIFO overflow");
        if (exp_mask_q.size() == 0 || inj_q.size() == 0) fail("read data with nothing outstanding");
        else begin
          emask = exp_mask_q.pop_front(); ehas = exp_has_q.pop_front();
          edat  = exp_data_q.pop_front(); inj  = inj_q.pop_front();
          ue    = rdata[BURST_DATA_W +: BURST_WORDS];
          for (int w = 0; w < BURST_WORDS; w++) begin
            if (!emask[w]) begin
              if (ue[w]) fail("error flag on a word outside the request mask");
            end else begin
              n_words_checked++;
              if (inj[w*2 +: 2] == 2'd2) begin
                exp_ue_total++;
                if (!ue[w]) fail("double-bit error not flagged");
              end else begin
                if (inj[w*2 +: 2] == 2'd1) exp_ce_total++;
                if (ue[w]) fail("uncorrectable flag on a correctable or clean word");
                if (ehas[w]) begin
                  n_words_compared++;
                  if (rdata[w*DATA_W +: DATA_W] !== edat[w*DATA_W +: DATA_W])
                    fail($sformatf("read data mismatch, word %0d: got %h expected %h", w,
                                   rdata[w*DATA_W +: DATA_W], edat[w*DATA_W +: DATA_W]));
                end
              end
            end
          end
        end
        n_rdpush++;
      end

      // ========================== read FIFO model ===========================
      if (used == RD_DEPTH) n_full_cycles++;
      used = used + k_push;
      if (used > 0 && $urandom_range(0, 99) < drain_pct) used = used - 1;
      rdata_free <= FREE_W'(RD_DEPTH - used);

      // =============================== stimulus =============================
      if (!req_valid || req_pop) begin
        if ((popped + k_pop < NREQ) && ($urandom_range(0, 99) < busy_pct)) begin
          rnew = random_req();
          req       <= rnew;
          req_valid <= 1'b1;
          last_bank <= {rnew.bg, rnew.ba};
          if (rnew.wr) wq.push_back(rand_burst());
        end else begin
          req_valid <= 1'b0;
        end
      end
      if (wq.size() != 0) wdata <= wq[0];
      wdata_valid <= (wq.size() != 0) && ($urandom_range(0, 99) < 90);

      if (cyc % 4000 == 0) begin
        case ($urandom_range(0, 3))
          0: busy_pct <= 100;
          1: busy_pct <= 90;
          2: busy_pct <= 40;
          default: busy_pct <= 5;
        endcase
        case ($urandom_range(0, 3))
          0: drain_pct <= 100;
          1: drain_pct <= 30;
          2: drain_pct <= 3;
          default: drain_pct <= 0;     // reader stalled: the FIFO must fill and hold
        endcase
      end

      if (sr_cnt > 0) begin
        sr_cnt <= sr_cnt - 1;
        if (sr_cnt == 1) sr_req <= 1'b0;
      end else if (sr_next <= 9 && popped >= (sr_next * NREQ) / 10) begin
        sr_next <= sr_next + 1;
        sr_req  <= 1'b1;
        sr_cnt  <= (sr_next % 2 == 1) ? 400 : $urandom_range(1, 12);
      end
    end
  end

  // --------------------------------- control --------------------------------
  initial begin
    t = timing_default_1600();
    mr[0] = 14'h0A10; mr[1] = 14'h0001; mr[2] = 14'h0018; mr[3] = 14'h0000;
    mr[4] = 14'h0000; mr[5] = 14'h0400; mr[6] = 14'h0019;
    row_set[0] = 16'h0000; row_set[1] = 16'hFFFF; row_set[2] = 16'h1234; row_set[3] = 16'hA5A5;
    req = '0;
    for (int i = 0; i < NUM_BANKS; i++) begin p_open[i] = 0; p_row[i] = '0; end

    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (7) @(posedge clk);
    dfi_init_complete = 1;

    wait (popped == NREQ);
    repeat (500) @(posedge clk);

    if (exp_mask_q.size() != 0) fail("reads still outstanding at the end");
    if (wr_due_q.size() != 0 || rd_due_q.size() != 0 || ret_due_q.size() != 0)
      fail("PHY queues not empty at the end");
    if (wq.size() != 0) fail("write data left over");
    if (n_rdpush != n_rd) fail("read bursts returned != read requests");
    if (dut_ce_total != exp_ce_total)
      fail($sformatf("corrected-word count: DUT %0d, expected %0d", dut_ce_total, exp_ce_total));
    if (dut_ue_total != exp_ue_total)
      fail($sformatf("uncorrectable-word count: DUT %0d, expected %0d", dut_ue_total, exp_ue_total));
    if (INJ1_PCT > 0 && exp_ce_total == 0) fail("no single-bit errors were exercised");
    if (INJ2_PCT > 0 && exp_ue_total == 0) fail("no double-bit errors were exercised");
    if (n_words_compared == 0) fail("no read data was ever compared");
    if (n_full_cycles == 0) fail("read FIFO backpressure never exercised");

    $display("ddr4_core lat=%0d/%0d/%0d: cycles=%0d wr=%0d rd=%0d words_checked=%0d compared=%0d corrected=%0d uncorrectable=%0d fifo_full_cycles=%0d errors=%0d  %s",
             WR_LAT, RDEN_LAT, RD_PHY_LAT, cyc, n_wr, n_rd, n_words_checked, n_words_compared,
             dut_ce_total, dut_ue_total, n_full_cycles, errors, errors == 0 ? "PASS" : "FAIL");
    $finish;
  end

  localparam int WATCHDOG_CYCLES = 5_000_000;
  initial begin
    repeat (WATCHDOG_CYCLES) @(posedge clk);
    $display("TIMEOUT FAIL at cycle %0d: popped=%0d init_done=%b in_sr=%b req_valid=%b used=%0d outstanding=%0d errors=%0d",
             cyc, popped, init_done, in_sr, req_valid, used, exp_mask_q.size(), errors);
    $finish;
  end
endmodule
